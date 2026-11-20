#!/usr/bin/env python3
"""Normal installed Release, real saved proxy, ordinary-user packets in mimo-vm.

No helper replacement or synthetic events. Private captures/settings remain in VM.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

from monotonic_uptime import uptime_ms
from parallel_timing_contract import verify_trial
from installed_acceptance_test import command
from saved_proxy_test import WORKER
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from upgrade_test import FLAGS, HELPER, ENGINE, RUNTIME, read_settings

BASE = Path(__file__).resolve().parent
CONTROLLER = '/Library/Application Support/Mimo/Mihomo/controller.sock'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings(); flags = FLAGS.read_bytes()
    routing = json.loads(original['service.routing']); original_mode = routing['mode']
    approved = json.loads(original['service.settings'])['allowlist']['addresses']; assert approved
    credential = command(BASE/'acceptance-client', 'credential-digest').stdout.strip()
    build = json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    assert HELPER.read_bytes() == Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-single-profile-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed = []; errors = []; trials = []; phases = []; capture = None; worker = None
    blockers = []; route_added = False
    account = pwd.getpwnam('jay')
    def identity(): os.setgroups([]); os.setgid(account.pw_gid); os.setuid(account.pw_uid)
    def client(*args): return command(BASE/'acceptance-client', *args, timeout=70)
    def state(): return json.loads(client('state').stdout)['routing']
    def active(mode):
        v = state(); return v['phase'] == 'active' and v.get('effectiveMode') == mode
    def wait(predicate, label, seconds=90):
        deadline = time.monotonic()+seconds
        while time.monotonic()<deadline:
            if predicate(): return
            time.sleep(.15)
        raise AssertionError(label+' timed out')
    def record(label): passed.append(label); print('PASS:', label, flush=True)
    def request(op, **kwargs):
        worker.stdin.write(json.dumps(dict(op=op, **kwargs))+'\n'); worker.stdin.flush()
        return json.loads(worker.stdout.readline())['ok']
    def engine_pid():
        return int(re.search(r'^\s*pid = (\d+)$', command('/bin/launchctl','print','system/'+ENGINE).stdout,re.M)[1])
    def config():
        return json.loads(command('/usr/bin/curl','--silent','--fail','--max-time','3','--unix-socket',CONTROLLER,'http://localhost/configs').stdout)
    @contextmanager
    def packets(label, empty=True):
        value = dict(name=label, started=time.time(), subjects=[worker.pid, engine_pid()], empty=empty)
        try: yield
        finally: value['ended']=time.time(); phases.append(value)
    def deny(label, existing=False):
        with packets(label):
            if existing:
                assert not request('existing',key='tun'), 'An old TUN connection survived'
                assert not request('existing',key='mixed'), 'An old local proxy connection survived'
            assert not request('https'), 'Ordinary TUN HTTPS passed a closed gate'
            assert not request('https',mixed=True), 'Ordinary local proxy HTTPS passed a closed gate'
            assert not request('udp'), 'Ordinary DNS/UDP passed a closed gate'
            assert not request('ipv6'), 'IPv6 connected'
        record(label+'-denies-existing-and-new-ordinary-traffic' if existing else label+'-denies-ordinary-traffic')
    def ready_events(baseline, mode, label, started, requested_uptime):
        wait(lambda: any(v['event']=='mimo_traffic_opened' for v in events(LOGS,baseline)) and active(mode), label)
        elapsed=time.monotonic()-started
        rows=events(LOGS,baseline); (root/(label+'-private-events.json')).write_text(json.dumps(rows))
        opened=next(v for v in rows if v['event']=='mimo_traffic_opened')
        ordered=[v for v in rows if v['file']==opened['file']]
        names=[v['event'] for v in ordered]
        assert names.count('mimo_final_profile_loaded')==0 and names.count('mimo_final_profile_reused')==1, 'Expected unchanged-profile reuse without reload'
        assert names.index('mimo_final_profile_reused') < names.index('mimo_private_probe_ready') < names.index('mimo_traffic_opened')
        assert names.index('mimo_readiness_passed') < names.index('mimo_traffic_opened')
        assert names.index('mimo_exit_ip_approved') < names.index('mimo_traffic_opened')
        assert any(v['event']=='mimo_gate_closed' and v['fields'].get('confirmed')=='true' for v in ordered[:names.index('mimo_private_probe_ready')])
        writes=[v['fields']['policy'] for v in ordered[:names.index('mimo_traffic_opened')+1] if v['event']=='mimo_pf_policy_installed']
        assert writes==['probe','active'], 'Unexpected full parent firewall writes: '+str(writes)
        spans = [v['fields'] for v in rows if v['event']=='mimo_transition_timing']
        span = lambda name: next(v for v in spans if v['stage']==name)
        assert int(span('connection_cleanup')['start_uptime_ms']) < int(span('confirmed_close')['end_uptime_ms']), 'Cleanup waited for PF confirmation'
        assert int(span('profile_preflight')['end_uptime_ms']) < int(span('probe_policy')['end_uptime_ms']), 'Profile reuse was left behind probe setup'
        assert int(span('critical_checks')['start_uptime_ms']) < int(span('private_probe_join')['end_uptime_ms']), 'Inspection did not start before the private-probe join'
        assert names.index('mimo_private_probe_barrier_ready') < names.index('mimo_private_probe_ready')
        assert names.index('mimo_opening_barrier_ready') < names.index('mimo_traffic_opened')
        opening = next(v['fields'] for v in ordered if v['event']=='mimo_transition_timing' and v['fields'].get('stage')=='open_gate')
        opened_after = (int(opening['end_uptime_ms'])-requested_uptime)/1000
        assert 0 < opened_after <= elapsed + 0.1, 'Monotonic clocks must agree before reporting open time'
        trials.append(dict(name=label, seconds=round(elapsed,3), firewallOpenSeconds=round(opened_after,3), eventRequestedUptimeMS=requested_uptime, finalProfileLoads=0, finalProfileReuses=1, parentPolicyWrites=writes,
            criticalChecksBeforeOpen=True, stages=[v['fields'] for v in rows if v['event']=='mimo_transition_timing']))
        verify_trial(trials[-1])
        record(label+'-reuses-profile-with-fresh-concurrent-checks-before-open')
        print('Timing:',label,round(elapsed,3),'seconds',flush=True)
    try:
        wait(lambda:active(original_mode),'original mode')
        worker=subprocess.Popen([sys.executable,'-u','-c',WORKER],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,preexec_fn=identity)
        proxy=routing['proxy']
        expression=f'(tcp dst port 443 or udp dst port 53 or ip6) and not (host {proxy["server"]} and port {proxy["port"]})'
        with (root/'capture.log').open('w') as log:
            capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i','pktap,en0','-w',str(root/'traffic.pcap'),expression],stdout=log,stderr=log)
        wait(lambda:'listening on' in (root/'capture.log').read_text(),'packet capture',5)
        # pktap creates a real interface: allow that deliberately observed
        # change to complete verification before establishing test connections.
        quiet_since=None
        def capture_settled():
            nonlocal quiet_since
            if not active(original_mode): quiet_since=None; return False
            if quiet_since is None: quiet_since=time.monotonic()
            return time.monotonic()-quiet_since>=5
        wait(capture_settled,'capture interface settled')
        for mode in ('rule','global'):
            if not active(mode): client('mode',mode); wait(lambda:active(mode),mode+' selected')
            assert request('https',key='tun',keep=True)
            assert request('https',key='mixed',mixed=True,keep=True)
            baseline=offsets(LOGS); client('allow')
            wait(lambda: state()['phase']=='blocked' and bool(state().get('blockingIP')),mode+' empty list')
            live=config(); assert live['tun']['enable'] is True and live['mixed-port']==7890
            client('check-private-profile'); client('check-protected-dns')
            record(mode+'-final-profile-and-private-proxied-DNS-loaded-while-blocked')
            deny(mode+'-empty-allowlist',existing=True)
            client('allow','192.0.2.254')
            wait(lambda: state()['phase']=='blocked' and bool(state().get('blockingIP')),mode+' mismatched list')
            deny(mode+'-mismatched-allowlist')
            client('allow',*approved); wait(lambda:active(mode),mode+' recovered')
            assert request('https') and request('https',mixed=True)
            record(mode+'-original-allowlist-restores-ordinary-HTTPS')
            # Full repeated transitions using real kernel route notifications.
            gateway=re.search(r'gateway: (\S+)',command('/sbin/route','-n','get','default').stdout)[1]
            assert DESTINATION not in command('/usr/sbin/netstat','-rn','-f','inet').stdout
            for add in (True,False):
                baseline=offsets(LOGS); started=time.monotonic();requested_uptime=uptime_ms()
                if add:
                    command('/sbin/route','-n','add','-host',DESTINATION,gateway); route_added=True
                else:
                    command('/sbin/route','-n','delete','-host',DESTINATION); route_added=False
                ready_events(baseline,mode,mode+('-route-added' if add else '-route-removed'),started,requested_uptime)
                time.sleep(3)
        # A real port conflict: another process owns both protected DNS bindings.
        # Never replace the helper or feed a test-only profile to the engine.
        command(BASE/'installation-check','mihomo','stop')
        for kind in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
            sock=socket.socket(socket.AF_INET,kind);sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);sock.bind(('127.0.0.1',1053))
            if kind==socket.SOCK_STREAM:sock.listen(1)
            blockers.append(sock)
        baseline=offsets(LOGS)
        command(BASE/'installation-check','mihomo','start');client('refresh')
        wait(lambda:any(v['event']=='mimo_final_profile_loaded' for v in events(LOGS,baseline)), 'DNS-conflict final profile')
        wait(lambda:state()['phase'] in ('blocked','unavailable') and any(
            v['event']=='mimo_gate_closed' and 'protected DNS' in v['fields'].get('reason','')
            for v in events(LOGS,baseline)), 'DNS conflict blocked with recorded critical failure')
        rows=events(LOGS,baseline);(root/'dns-conflict-private-events.json').write_text(json.dumps(rows))
        assert any(v['event']=='mimo_readiness_started' for v in rows)
        assert not any(v['event']=='mimo_traffic_opened' for v in rows)
        deny('foreign-DNS-listener')
        record('foreign-DNS-owner-fails-concurrent-readiness-without-opening')
        for sock in blockers:sock.close()
        blockers=[]
        # Pinned mihomo retains failed DNS listener state across a same-profile
        # reload. Exercise the supported Restart action after freeing the port.
        command(BASE/'installation-check','mihomo','restart')
        client('refresh');wait(lambda:active('global'),'DNS conflict recovered')
        record('DNS-conflict-removal-plus-mihomo-Restart-recovers-after-fresh-verification')
        baseline=offsets(LOGS)
        command(BASE/'installation-check','profileHosting','restart')
        client('refresh');wait(lambda:active('global'),'manual Reload recovery')
        rows=events(LOGS,baseline)
        assert any(v['event']=='mimo_final_profile_loaded' for v in rows), 'Manual Reload reused the profile'
        record('manual-Reload-forces-final-profile-load-and-fresh-verification')
        # An actual engine crash must close/reverify under launchd recovery.
        baseline=offsets(LOGS);old_pid=engine_pid();os.kill(old_pid,signal.SIGKILL)
        wait(lambda:any(v['event']=='mimo_gate_closed' for v in events(LOGS,baseline)),'engine crash closes')
        wait(lambda: command('/bin/launchctl','print','system/'+ENGINE,check=False).returncode==0 and re.search(r'^\s*pid = (\d+)$',command('/bin/launchctl','print','system/'+ENGINE).stdout,re.M) is not None and engine_pid()!=old_pid,'launchd engine restart')
        client('refresh');wait(lambda:active('global'),'engine crash recovery')
        assert any(v['event']=='mimo_final_profile_loaded' for v in events(LOGS,baseline)), 'New engine process reused old profile'
        record('engine-crash-closes-launchd-restarts-and-fresh-refresh-recovers')
        client('mode','direct');wait(lambda:active('direct'),'Direct selected')
        client('allow')
        with packets('Direct-positive-control',empty=False):assert request('https')
        baseline=offsets(LOGS);client('refresh');time.sleep(2)
        assert active('direct') and not request('ipv6')
        assert not any(v['event'] in ('mimo_gate_closed','mimo_private_probe_ready') for v in events(LOGS,baseline))
        record('Direct-with-empty-allowlist-refreshes-without-protected-blocking')
        capture.send_signal(signal.SIGINT);capture.wait(timeout=5);capture=None
        (root/'private-packet-phases.json').write_text(json.dumps(phases))
        for phase in phases:
            output=command('/usr/sbin/tcpdump','-tt','-nn','-k','NP','-r',root/'traffic.pcap','dst host 1.1.1.1 or dst host 8.8.8.8 or ip6').stdout
            selected=[line for line in output.splitlines() if line and phase['started']<=float(line.split()[0])<=phase['ended'] and any(re.search(r':'+str(pid)+r'[,)]',line) for pid in phase['subjects'])]
            (root/(phase['name']+'-private-packets.txt')).write_text('\n'.join(selected))
            assert (not selected) if phase['empty'] else bool(selected), phase['name']+' packet boundary failed'
        record('physical-interface-capture-confirms-blocked-paths-and-Direct-positive-control')
    except Exception as error:
        errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
        (root/'private-failure.txt').write_text(traceback.format_exc())
    finally:
        for sock in blockers:sock.close()
        if blockers:
            # A failed assertion during the port conflict still needs the same
            # supported engine Restart used by the successful recovery path.
            command(BASE/'installation-check','mihomo','restart',check=False)
            blockers=[]
        (root/'private-packet-phases.json').write_text(json.dumps(phases))
        if route_added:command('/sbin/route','-n','delete','-host',DESTINATION,check=False)
        if capture and capture.poll() is None:capture.send_signal(signal.SIGINT);capture.wait(timeout=5)
        if worker and worker.poll() is None:worker.terminate();worker.wait(timeout=5)
        try:
            if json.loads(read_settings()['service.settings'])['allowlist']['addresses']!=approved:client('allow',*approved)
            if json.loads(read_settings()['service.routing'])['mode']!=original_mode:client('mode',original_mode)
            if not active(original_mode):client('refresh')
            wait(lambda:active(original_mode),'original mode restored')
            assert configuration_values(read_settings())==configuration_values(original), "Saved configuration changed"
            assert json.loads(FLAGS.read_bytes())==json.loads(flags), "Service intent changed"
            assert client('credential-digest').stdout.strip()==credential, 'Credential changed'
            record('original-mode-proxy-allowlist-credentials-and-service-intent-restored')
        except Exception as error:errors.append('Restoration: '+type(error).__name__+': '+str(error))
        report=dict(success=not errors,passed=passed,errors=errors,trials=trials,packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],
            scope='Exact installed Release in mimo-vm, saved real proxy, Rule/Global/Direct, real route events, foreign DNS owner, engine crash, ordinary-user connections and physical-interface captures. No physical sleep/unlock or simultaneous-login claim.')
        (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    return 1 if errors else 0


if __name__=='__main__':sys.exit(main())
