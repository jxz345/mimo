#!/usr/bin/env python3
"""Installed failure traffic on the isolated VM; external lab denial contains probes.

The lab anchor is after Mimo, so logged native packets prove Mimo admitted that
attempt. They are blocked by the lab and never deliberately sent to the Internet.
Raw captures and state stay private; export only sanitized case summaries.
"""
import itertools
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import v3_installed_test as t
from dualstack_fixture import dns_query

ROOT = Path(sys.argv[1])
LAB = 'com.apple/999.mimo-qualification'
F = json.loads((ROOT / 'fixture.json').read_text())
RESULTS = []
FAULTS = ('engine-kill', 'engine-stall', 'core-stall', 'supervisor-stall', 'owners-stall', 'native-route', 'owners-stall-engine-kill')


def echo_reply_matches(response, source, target, family, identifier, sequence):
    """Raw sockets can also receive another process's native ping replies."""
    if ipaddress.ip_address(source.split('%')[0]) != ipaddress.ip_address(target):
        return False
    offset = (response[0] & 15) * 4 if family == 4 and response else 0
    if family == 4 and (not response or response[0] >> 4 != 4 or offset < 20):
        return False
    if len(response) < offset + 8:
        return False
    kind, code, _, actual_id, actual_sequence = struct.unpack('!BBHHH', response[offset:offset + 8])
    return (kind == (0 if family == 4 else 129) and code == 0 and actual_id == identifier
            and actual_sequence == sequence and response[offset + 8:] == b'mimo-test')


def save():
    (ROOT / 'traffic-results.json').write_text(json.dumps(RESULTS, indent=2))


def pid(role):
    r = t.run(['/bin/launchctl', 'print', 'system/com.mimo.' + role], 5)
    match = re.search(r'^\s*pid = (\d+)$', r.stdout, re.M)
    assert match, 'No PID for ' + role
    return int(match[1])


def pf_kind():
    r = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr'], 3)
    if r.returncode: return 'unknown'
    if not r.stdout.strip(): return 'empty'
    if t.active_guard(r.stdout): return 'active'
    if 'mimo:probe:deny' in r.stdout: return 'probe'
    if 'mimo:transition:deny' in r.stdout: return 'closed'
    return 'other'


def approved(mode, family):
    # Core may deliver its last Active snapshot immediately after SIGCONT,
    # while the supervisor has already closed the gate. Poll the complete
    # effective state; a cached phase is not evidence of recovery.
    deadline = time.monotonic() + 100
    last = 'No effective-state sample'
    while time.monotonic() < deadline:
        try:
            r = t.state()['routing']
            assert r['phase'] == 'active' and r.get('effectiveMode') == mode, r.get('reason')
            c = t.api('/configs')
            assert c['mode'] == mode and c['mimo-destination-family'] == family, 'Engine mode/family differs'
            assert pf_kind() == 'active', 'PF active guard has not been installed'
            assert r['exitObservations']['ipv4']['ipAddress'] == '203.0.113.10', 'Missing fixture IPv4 observation'
            if family == 'dual':
                assert r['exitObservations']['ipv6']['ipAddress'] == '2001:db8::10', 'Missing fixture IPv6 observation'
            return r['exitObservations']['verification']['id']
        except (AssertionError, KeyError, OSError, subprocess.TimeoutExpired) as error:
            last = str(error)
            time.sleep(.4)
    raise AssertionError('Effective recovery timed out: ' + last)


def containment():
    assert not t.run(['/sbin/pfctl', '-a', LAB, '-sr']).stdout.strip(), 'Lab anchor already occupied'
    rules = ('block drop out log quick on en0 inet from any to {203.0.113.70,203.0.113.53,198.18.0.0/16} label "mimo:test:containment-v4"\n'
             'block drop out log quick on en0 inet6 from any to {2001:db8:33::10,2001:db8:33::53,fdfe:dcba:9876::/48} label "mimo:test:containment-v6"\n')
    r = subprocess.run(['/sbin/pfctl', '-a', LAB, '-f', '-'], input=rules, text=True, capture_output=True)
    assert r.returncode == 0, r.stderr


class Traffic:
    def __init__(self, label):
        self.label = label
        self.done = threading.Event()
        self.lock = threading.Lock()
        self.events, self.samples, self.threads = [], [], []
        self.captures = []
        for interface in ('en0', 'pflog0'):
            path = ROOT / (label + '-' + interface + '.pcap')
            error = (ROOT / (label + '-' + interface + '.capture.log')).open('w')
            bpf = '(host 203.0.113.70 or host 203.0.113.53 or host 2001:db8:33::10 or host 2001:db8:33::53 or net 198.18.0.0/16 or net fdfe:dcba:9876::/48)'
            # Promiscuous capture toggles interface flags and would itself cause
            # a real protected revalidation before the intended injected fault.
            p = subprocess.Popen(['/usr/sbin/tcpdump','-p','-n','-U','--immediate-mode','-i',interface,'-s','128','-w',str(path),bpf],
                                 stdout=subprocess.DEVNULL, stderr=error)
            self.captures.append((p,error,path))
        time.sleep(.3)
        assert all(p.poll() is None for p,_,_ in self.captures), 'Capture unavailable'
        for family, host in ((4,F['public4']),(6,F['public6'])):
            for kind in ('tcp','stream','udp','dns-udp','dns-tcp','echo','fake-tcp','fake-udp'):
                thread = threading.Thread(target=self.worker,args=(family,host,kind),daemon=True)
                self.threads.append(thread); thread.start()
        thread = threading.Thread(target=self.sample,daemon=True)
        self.threads.append(thread); thread.start()

    def record(self, family, kind, ok, **details):
        with self.lock: self.events.append({'t':time.time(),'family':family,'kind':kind,'success':ok,**details})

    def sample(self):
        while not self.done.is_set():
            try: self.samples.append({'t':time.time(),'pf':pf_kind()})
            except subprocess.TimeoutExpired: self.samples.append({'t':time.time(),'pf':'timeout'})
            self.done.wait(.25)

    def worker(self, family, host, kind):
        af = socket.AF_INET if family == 4 else socket.AF_INET6
        recorded_kind = kind
        if kind.startswith('fake-'):
            host = '198.18.0.123' if family == 4 else 'fdfe:dcba:9876:1::abcd'
            kind = kind.removeprefix('fake-')
        sock = None
        count = 0
        while not self.done.is_set():
            count += 1
            nonce = (F['token'] + ':' + self.label + ':' + str(count)).encode()
            ok = False
            echo_send_attempted = False
            try:
                if kind.startswith('dns-'):
                    r = dns_query(F['dns'+str(family)],53,'aonly-'+self.label+'-'+str(count)+'.mimo-lab.test',1,
                                  kind.split('-')[1],.7)
                    ok = r['rcode'] == 0
                elif kind == 'tcp':
                    with socket.socket(af,socket.SOCK_STREAM) as fresh:
                        fresh.settimeout(.7); fresh.connect((host,F['http_port']))
                        fresh.sendall(('GET /'+F['token']+'/'+self.label+' HTTP/1.0\r\nHost: '+host+'\r\n\r\n').encode())
                        ok = b'200' in fresh.recv(2048).split(b'\r\n')[0]
                elif kind == 'echo':
                    protocol = socket.IPPROTO_ICMP if family == 4 else socket.IPPROTO_ICMPV6
                    with socket.socket(af,socket.SOCK_RAW,protocol) as raw:
                        raw.settimeout(.4)
                        packet = struct.pack('!BBHHH',8 if family==4 else 128,0,0,0x4d33,count%65536)+b'mimo-test'
                        if family == 4:
                            padded=packet+b'\0'*(len(packet)%2)
                            words=struct.unpack('!'+str(len(padded)//2)+'H',padded); total=sum(words)
                            while total>>16: total=(total&65535)+(total>>16)
                            packet=packet[:2]+struct.pack('!H',(~total)&65535)+packet[4:]
                        echo_send_attempted = True
                        raw.sendto(packet,(host,0)); deadline=time.monotonic()+.4
                        while time.monotonic()<deadline:
                            raw.settimeout(max(.001,deadline-time.monotonic()))
                            response,source=raw.recvfrom(2048)
                            if echo_reply_matches(response,source[0],host,family,0x4d33,count%65536):
                                ok=True; break
                else:
                    if sock is None:
                        sock=socket.socket(af,socket.SOCK_STREAM if kind=='stream' else socket.SOCK_DGRAM)
                        sock.settimeout(.7); sock.connect((host,F['stream_port' if kind=='stream' else 'udp_port']))
                    value=nonce
                    sock.sendall(value); response=sock.recv(4096)
                    ok=response==(value if kind=='stream' else str(family).encode()+b':'+value)
            except (OSError,ValueError,EOFError,struct.error):
                if sock is not None: sock.close(); sock=None
            self.record(family,recorded_kind,ok,
                        **({'send_attempted':echo_send_attempted} if recorded_kind == 'echo' else {}))
            self.done.wait(.15)
        if sock is not None: sock.close()

    def finish(self):
        self.done.set()
        for thread in self.threads: thread.join(4)
        for p, error, _ in self.captures:
            p.send_signal(signal.SIGINT); p.wait(timeout=5); error.close()
        log_path=self.captures[1][2]
        r=t.run(['/usr/sbin/tcpdump','-nn','-tt','-r',str(log_path)],10)
        assert r.returncode==0,r.stderr
        packets=[]
        for line in r.stdout.splitlines():
            match=re.match(r'^(\d+\.\d+) ',line)
            if match:
                packets.append({'t':float(match[1]),'family':6 if 'IP6 ' in line else 4,
                                'protocol':'dns' if '.53:' in line or '.53 ' in line else 'icmp' if 'ICMP' in line else 'udp' if 'UDP' in line else 'tcp'})
        (ROOT/(self.label+'-observations.json')).write_text(json.dumps({'events':self.events,'pf':self.samples,'native_attempts':packets}))
        return packets


def run_case(family, mode, fault):
    label=family+'-'+mode+'-'+fault
    t.route(mode,family); old=approved(mode,family)
    traffic=Traffic(label)
    stopped=[]; routes=[]
    start=None; fault_ended=None; recovered=False; error=None
    try:
        time.sleep(2)
        start=time.time()
        if fault=='engine-kill': os.kill(pid('mihomo'),signal.SIGKILL)
        elif fault.endswith('stall') or fault == 'owners-stall-engine-kill':
            roles={'engine-stall':['mihomo'],'core-stall':['core'],'supervisor-stall':['supervisor'],'owners-stall':['core','supervisor'],'owners-stall-engine-kill':['core','supervisor']}[fault]
            stopped=[pid(role) for role in roles]
            (ROOT/'stalled.json').write_text(json.dumps(stopped))
            # Independent continuation survives a killed test process.
            code='import os,signal,time; time.sleep(14)\nfor p in '+repr(stopped)+':\n try: os.kill(p,signal.SIGCONT)\n except ProcessLookupError: pass'
            subprocess.Popen(['/usr/bin/python3','-c',code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
            for p in stopped: os.kill(p,signal.SIGSTOP)
            if fault == 'owners-stall-engine-kill': os.kill(pid('mihomo'),signal.SIGKILL)
        elif fault=='native-route':
            candidates=[['-host',F['public4'],F['bridge4']],['-inet6','-host',F['public6'],F['data6']]]
            for args in candidates:
                r=t.run(['/sbin/route','-n','add',*args],4)
                assert r.returncode==0,r.stderr
                routes.append(args)
                (ROOT/'routes.json').write_text(json.dumps(routes))
        time.sleep(14 if stopped else 8)
        for p in stopped:
            try: os.kill(p,signal.SIGCONT)
            except ProcessLookupError: pass
        for args in routes: t.run(['/sbin/route','-n','delete',*args],4)
        routes=[]
        fault_ended=time.time()
        approved(mode,family); recovered=True
        time.sleep(2)
    except Exception as e: error=str(e)
    finally:
        for p in stopped:
            try: os.kill(p,signal.SIGCONT)
            except ProcessLookupError: pass
        for args in routes: t.run(['/sbin/route','-n','delete',*args],4)
        (ROOT/'stalled.json').write_text('[]'); (ROOT/'routes.json').write_text('[]')
        packets=traffic.finish()
        after=[x for x in packets if start and x['t']>=start]
        before=[x for x in packets if start and x['t']<start]
        closed=next((x['t']-start for x in traffic.samples if start and x['t']>=start and x['pf'] in ('closed','probe')),None)
        echo=[e for e in traffic.events if e['kind']=='echo']
        echo_successes={str(af):sum(e['success'] for e in echo if e['family']==af) for af in (4,6)}
        fault_echo_attempts={str(af):sum(e.get('send_attempted',False) for e in echo
                            if e['family']==af and start is not None and start<=e['t']<=(fault_ended or time.time()))
                            for af in (4,6)}
        row={'id':label,'native_attempts_before_fault':len(before),'native_attempts_after_fault':len(after),
             'native_attempts_by_family':{str(af):sum(x['family']==af for x in after) for af in (4,6)},
             'first_native_attempt_seconds':round(after[0]['t']-start,4) if after else None,
             'first_sampled_closed_seconds':round(closed,4) if closed is not None else None,
             'public_echo_successes':echo_successes,'echo_send_attempts_during_fault':fault_echo_attempts,
             'recovered':recovered,'error':error,
             'result':'FAIL_NATIVE_BYPASS' if after or before else 'FAIL_RECOVERY' if not recovered
                      else 'FAIL_PUBLIC_ECHO' if any(echo_successes.values())
                      else 'FAIL_ICMP_COVERAGE' if not all(fault_echo_attempts.values()) else 'PASS'}
        RESULTS.append(row);save(); print(label+': '+row['result']+' native attempts='+str(len(after)),flush=True)
        if not recovered: t.route('direct');t.wait_active('direct')


def setup():
    assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
    assert t.run(['/usr/sbin/sysctl','-n','hw.model']).stdout.startswith('VirtualMac')
    os.umask(0o077)
    original=t.state()
    assert (ROOT/'before.json').exists()
    settings=original['settings']
    settings.update(provider='ipWhois',providerPool=['ipWhois','ipapiCo','ipapiIs'],refreshInterval=-1,
                    allowlist={'addresses':['203.0.113.10','2001:db8::10']},bypassBlocks=[])
    t.request('configure',settings=settings)
    name='V3 closure qualification'
    existing=next((p for p in original['routing']['configuration']['proxies'] if p['proxy']['name']==name),None)
    t.request('saveProxy',proxy={'name':name,'type':'socks5','server':F['bridge4'],'port':F['proxy_port'],'username':''},
              **({'proxyID':existing['id']} if existing else {}),proxyPassword='')
    entry=next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name']==name)
    t.request('selectProxy',proxyID=entry['id'])


def main(prepared=False, faults=FAULTS):
    assert faults and set(faults) <= set(FAULTS)
    containment()
    try:
        # A Direct positive control proves the native-attempt detector works.
        traffic=Traffic('detector-direct-control');time.sleep(2);packets=traffic.finish()
        assert {x['family'] for x in packets}=={4,6}, 'Detector lacks a family positive control'
        (ROOT/'detector.json').write_text(json.dumps({'both_families_detected':True,'native_attempts':len(packets)}))
        if not prepared: setup()
        for family,mode in itertools.product(('ipv4','dual'),('rule','global')):
            t.route(mode,family);approved(mode,family)
            label=family+'-'+mode+'-baseline'; traffic=Traffic(label);time.sleep(3);packets=traffic.finish()
            successes={(af,kind):sum(e['success'] for e in traffic.events if e['family']==af and e['kind']==kind)
                       for af in (4,6) for kind in ('tcp','stream','udp','echo')}
            valid=not packets and all(successes[(af,k)]>0 for af in ((4,6) if family=='dual' else (4,)) for k in ('tcp','stream','udp'))
            valid &= not successes[(4,'echo')] and not successes[(6,'echo')]
            echo_attempts={str(af):sum(e.get('send_attempted',False) for e in traffic.events
                           if e['family']==af and e['kind']=='echo') for af in (4,6)}
            valid &= all(echo_attempts.values())
            if family=='ipv4': valid &= all(successes[(6,k)]==0 for k in ('tcp','stream','udp'))
            RESULTS.append({'id':label,'result':'PASS' if valid else 'FAIL_BASELINE','native_attempts':len(packets),
                            'successes':{str(af)+'-'+k:v for (af,k),v in successes.items()},
                            'echo_send_attempts':echo_attempts});save()
            print(label+': '+RESULTS[-1]['result'],flush=True)
            assert valid,label
            for fault in faults: run_case(family,mode,fault)
    finally:
        try: t.route('direct'); t.wait_active('direct')
        finally: t.run(['/sbin/pfctl','-a',LAB,'-F','rules'])


if __name__=='__main__': main()
