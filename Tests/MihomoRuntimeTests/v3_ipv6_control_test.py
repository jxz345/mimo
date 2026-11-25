#!/usr/bin/env python3
"""VM-only live IPv6 control/PMTU qualification against the closed Delta fixture.

Inject a valid ICMPv6 Packet Too Big quoting the installed stack's actual TCP
output. Require packet-size adaptation on that same connection, plus unchanged
payload. Raw captures and fixture credentials remain in the private test root.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import v3_installed_test as t
from v3_fault_traffic_test import approved

ROOT = Path(sys.argv[1])
F = json.loads((ROOT / 'fixture.json').read_text())
RESULTS = []


def packets(path):
    data = path.read_bytes()
    if len(data) < 24: return []
    endian = '<' if data[:4] == b'\xd4\xc3\xb2\xa1' else '>'
    link = struct.unpack_from(endian+'I', data, 20)[0]
    assert link in (0, 12, 108), 'Unsupported TUN capture link type ' + str(link)
    offset = 4 if link in (0, 108) else 0
    result = []
    at = 24
    while at + 16 <= len(data):
        sec, usec, size, original = struct.unpack_from(endian+'IIII', data, at)
        at += 16
        if at + size > len(data): break
        packet = data[at+offset:at+size]; at += size
        if len(packet) >= 40 and packet[0] >> 4 == 6:
            result.append((sec+usec/1e6, packet))
    return result


def exchange(sock, value):
    sock.sendall(value)
    answer = bytearray()
    while len(answer) < len(value):
        part = sock.recv(len(value)-len(answer))
        if not part: raise EOFError('Fixture stream closed')
        answer.extend(part)
    assert bytes(answer) == value, 'Payload differs'


def run(mode):
    t.route(mode, 'dual'); approved(mode, 'dual')
    label = 'dual-' + mode
    route = t.run(['/sbin/route', '-n', 'get', '-inet6', F['public6']]).stdout
    interface = re.search(r'interface: (utun\d+)', route).group(1)
    path = ROOT / (label + '-ptb.pcap')
    error = (ROOT / (label + '-ptb.capture.log')).open('w')
    capture = subprocess.Popen(['/usr/sbin/tcpdump', '-p', '-U', '--immediate-mode', '-n', '-i', interface,
                                '-s', '0', '-w', str(path), 'ip6 and host '+F['public6']],
                               stdout=subprocess.DEVNULL, stderr=error)
    start = time.time(); injected = None; payload_ok = False; error_text = None
    source = socket.inet_pton(socket.AF_INET6, F['public6'])
    try:
        time.sleep(.5)
        assert capture.poll() is None, 'TUN capture unavailable'
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as client:
            client.settimeout(5); client.connect((F['public6'], F['stream_port']))
            port = client.getsockname()[1]
            value = (F['token']+':').encode()+os.urandom(3000)
            for _ in range(4): exchange(client, value)
            time.sleep(.4)
            before = [(ts,p) for ts,p in packets(path) if p[6] == 6 and p[8:24] == source
                      and len(p) >= 60 and struct.unpack_from('!H',p,42)[0] == port and len(p) > 1280]
            assert before, 'No pre-injection TCP packet larger than 1280; PMTU adaptation cannot be demonstrated'
            quote = before[-1][1][:1232]
            with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as raw:
                # The macOS kernel supplies the ICMPv6 checksum and IPv6 header.
                injected = time.time()
                raw.sendto(struct.pack('!BBHI',2,0,0,1280)+quote,(F['public6'],0))
            time.sleep(.5)
            for _ in range(12): exchange(client,value); time.sleep(.05)
            payload_ok = True
    except Exception as error_value:
        error_text = type(error_value).__name__ + ': ' + str(error_value)
    finally:
        time.sleep(.3)
        capture.send_signal(signal.SIGINT); capture.wait(timeout=5); error.close()
    observed = packets(path)
    ptb = [p for ts,p in observed if p[6] == 58 and len(p) >= 48 and p[40] == 2]
    pre = [len(p) for ts,p in observed if p[6] == 6 and p[8:24] == source and (injected is None or ts < injected)]
    post = [len(p) for ts,p in observed if p[6] == 6 and p[8:24] == source and injected and ts > injected+.3 and len(p)>80]
    passed = payload_ok and bool(ptb) and bool(post) and max(post) <= 1280 and max(pre,default=0)>1280
    RESULTS.append(dict(id=label+'-live-ptb',result='PASS' if passed else 'NOT_QUALIFIED',
                        injected_packets=len(ptb), payload_ok=payload_ok, before_max=max(pre,default=0),
                        after_max=max(post,default=0), error=error_text))
    # Independently exercise native IPv6 neighbor reachability and large proxied
    # exchange. This does not pretend that an ordinary TCP test injects ND.
    native = t.run(['/sbin/ping6','-c','2',F['data6']],8)
    url='https://['+F['public6']+']:'+str(F['https_port'])+'/'+F['token']+'/'+label+'-large?size=262144'
    response=t.run(['/usr/bin/curl','--noproxy','*','-sS','--max-time','10',url],12)
    body=json.loads(response.stdout) if response.returncode==0 else {}
    large_ok=body.get('payload')=='m'*262144 and body.get('family')==6
    RESULTS.append(dict(id=label+'-native-control-and-payload',
                        result='PASS' if native.returncode==0 and response.returncode==0 and large_ok else 'FAIL',
                        native_ping_status=native.returncode,tls_status=response.returncode,
                        response_bytes=len(response.stdout.encode()),response_sha256=hashlib.sha256(response.stdout.encode()).hexdigest(),
                        scope='Real native IPv6 echo/neighbor path and proxied TLS; no injected neighbor-advertisement attack'))
    (ROOT/'ipv6-control-results.json').write_text(json.dumps(RESULTS,indent=2))
    for row in RESULTS[-2:]: print(row['id']+': '+row['result'],flush=True)


if __name__ == '__main__':
    assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    try:
        for mode in ('rule','global'): run(mode)
    finally:
        t.route('direct'); t.wait_active('direct',100)
