#!/usr/bin/env python3
"""VM-only observation/transition audit using production RPC and closed fixture.
Raw state remains root-private. Export only report.json, which contains no secrets.
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
import uuid

import v3_installed_test as t
import v3_service_command_test as service
from v3_gui_event_audit import GUICaseAudit

ROOT = Path(sys.argv[1])
ACTION = sys.argv[2]
F = json.loads((ROOT / 'fixture.json').read_text())
REPORT = ROOT / 'report.json'
NAME = 'Observation qualification'
GUI_AUDIT = None


def gui_process_ids():
    result = subprocess.run(['/usr/bin/pgrep', '-x', 'mimo-gui'],
                            capture_output=True, text=True, timeout=2)
    assert result.returncode in (0, 1), 'Cannot inspect GUI identity'
    return sorted(result.stdout.split())


def active_mimo_process_ids():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='],
                            capture_output=True, text=True, timeout=2)
    assert result.returncode == 0, 'Cannot inspect active Mimo process identities'
    pids = []
    for line in result.stdout.splitlines():
        values = line.strip().split(None, 1)
        if len(values) != 2 or not values[0].isdigit(): continue
        name = Path(values[1]).name
        if name == 'mimo-gui' or name.startswith('mimo-core'):
            pids.append(values[0])
    return sorted(pids)


def read_only_state_probe():
    result = subprocess.run([t.CONTROLS], capture_output=True, text=True, timeout=3)
    assert result.returncode == 0, 'Read-only state RPC failed'
    response = json.loads(result.stdout)
    assert response.get('state') and not response.get('failure'), 'Read-only state reply missing'


def save(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2) + '\n')


def native_hosts(enabled):
    """The native-only fixture must not alter mihomo's protected DNS answers."""
    backup=ROOT/'hosts.original';installed=ROOT/'hosts.installed'
    if F.get('protected_provider_ingress') == 'proxy_configured_dns':
        # The new closed fixture preserves hostnames at the private probe ACL.
        # Its separate lifecycle owns resolver files; individual cases only
        # verify them, never rewrite DNS while operations are in flight.
        import v3_native_provider_dns as native_dns
        assert backup.exists() and Path('/etc/hosts').read_bytes() == backup.read_bytes(), 'Original hosts required'
        native_dns.verify(ROOT, F)
        return
    if not backup.exists():return
    hosts=Path('/etc/hosts');current=hosts.read_bytes()
    assert current in (backup.read_bytes(),installed.read_bytes()), 'Hosts changed independently'
    desired=(installed if enabled else backup).read_bytes()
    if current!=desired:
        hosts.write_bytes(desired)
        assert t.run(['/usr/bin/dscacheutil','-flushcache']).returncode == 0, 'Hosts cache flush failed'


def fixture(**value):
    # The host may provide a loopback-only reverse SSH channel. Test control
    # must remain independent of deliberately blocked application outbound.
    request = urllib.request.Request('http://%s:%s' % (F.get('control_host',F['bridge4']), F['control_port']),
        data=json.dumps(value).encode(), headers={'Authorization': 'Bearer ' + F['token']})
    # Fixture mutations are idempotent. A session established in released
    # Direct can lose its old PF state at a later closure; allow the host to
    # establish a fresh incoming management connection. Record, do not hide,
    # this control-transport limitation separately from observation traffic.
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                assert response.status == 204
            return
        except (OSError, urllib.error.URLError):
            if attempt==3:raise
            print('Fixture control transport retry '+str(attempt+1),flush=True)
            time.sleep(1)


def burst(requests, spacing=.08):
    """Separate request files prevent the harness itself racing shared JSON."""
    pending = []
    for request in requests:
        path = ROOT / ('burst-' + uuid.uuid4().hex + '.json')
        path.write_text(json.dumps(dict(protocolVersion=8, **request)))
        path.chmod(0o600)
        process = subprocess.Popen([t.CONTROLS, 'request', str(path)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pending.append((process,path))
        time.sleep(spacing)
    deadline = time.monotonic() + 85
    try:
        for process,path in pending:
            output,error = process.communicate(timeout=max(.01,deadline-time.monotonic()))
            assert process.returncode == 0, 'burst RPC transport failed'
            assert not json.loads(output).get('failure'), 'burst RPC rejected'
    finally:
        for process,path in pending:
            if process.poll() is None:
                process.kill(); process.wait()
            path.unlink()


def healthy_state(mode, phase, status=None, state=None):
    s = state if state is not None else t.state(); r = s['routing']
    return s if (r['phase'] == phase and r['configuration']['mode'] == mode and
        service.healthy(s) and all(x == 'running' for x in service.service_health(s).values()) and
        (status is None or status in s['status'])) else None


def idle(mode, phase='active', status='ready'):
    return service.wait(lambda: healthy_state(mode, phase, status), 100)


def fingerprint():
    runtime = Path('/Library/Application Support/Mimo/Runtime')
    return dict(epoch=(runtime / 'pf-close.epoch').read_text(),
                policy=t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr'], 8).stdout,
                engine=service.job('com.mimo.mihomo'), peers=service.peers())


def stable_fingerprint(value):
    # Signed native-VPN socket scopes are independently refreshed by the
    # infrastructure audit. They are not the observation's permission gate.
    # Accept only those exact rule forms, never arbitrary label-only filtering.
    patterns = [r'pass out quick inet6? proto udp from (?:any|[0-9a-fA-F:.]+) port = [0-9]+ to any user = 0 no state label "mimo:active:native-vpn-udp"',
                r'pass out quick inet6? proto tcp from any to [0-9a-fA-F:.]+ port = 443 user = 0 no state label "mimo:active:native-vpn-https"']
    stable = dict(value)
    stable['policy'] = '\n'.join(line for line in value['policy'].splitlines()
        if not any(re.fullmatch(pattern, line) for pattern in patterns))
    return stable


class Stream:
    def __init__(self, family=4):
        self.family = family
        self.done = threading.Event(); self.ready = threading.Event()
        self.sent = 0; self.errors = 0; self.stopped = False
        self.sock = socket.create_connection((F['public'+str(family)], F['stream_port']), timeout=3)
        self.worker = threading.Thread(target=self.work, daemon=True); self.worker.start()

    def exchange(self, message):
        # TCP may split one echo into several reads. Bound the whole exchange,
        # rather than treating a short read as proof that the stream broke.
        deadline = time.monotonic() + 3
        self.sock.settimeout(3)
        self.sock.sendall(message)
        response = bytearray()
        while len(response) < len(message):
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError('echo deadline')
            self.sock.settimeout(remaining)
            part = self.sock.recv(len(message)-len(response))
            if not part: raise OSError('echo stream closed')
            response.extend(part)
        if response != message: raise OSError('echo mismatch')

    def work(self):
        while not self.done.is_set():
            try:
                message = (F['token'] + ':continuity').encode()
                self.exchange(message)
                self.sent += 1
                self.ready.set()
            except OSError:
                self.errors += 1; self.ready.set(); break
            self.done.wait(.1)

    def stop(self):
        if self.stopped: return
        self.done.set(); self.worker.join(4)
        if self.worker.is_alive():
            self.errors += 1
            try: self.sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        self.sock.close(); self.worker.join(1); self.stopped = True
        assert not self.worker.is_alive(), 'Continuity worker did not stop'


def observe(name, action, mode, phase='active', status='ready', preserve=True, expected_http=1, detail=None,
            method='production RPC', deadline_seconds=100):
    evidence_id = uuid.uuid4().hex
    before = fingerprint(); offsets = service.cursor(); initial = t.state(); snapshot = initial.get('snapshot')
    streams = []
    started = time.monotonic(); failures = []; state_samples = []; unhealthy_samples = []
    try:
        if preserve and mode != 'direct':
            for family in ((4,6) if initial['routing']['configuration']['networkFamily']=='dual' else (4,)):
                stream = Stream(family); streams.append(stream)
                assert stream.ready.wait(4) and stream.sent and not stream.errors, 'Continuity stream not ready'
        action()
        deadline = time.monotonic() + deadline_seconds
        while time.monotonic() < deadline:
            s = t.state(); r = s['routing']; rows = service.events(offsets)
            state_samples.append(dict(phase=r['phase'], effective=r.get('effectiveMode'),
                                     observation=bool(r.get('observation'))))
            if preserve and r['phase'] != 'active': failures.append('access closed during observation')
            finished = sum(x['event'] == 'lookup_finished' for x in rows)
            if finished >= expected_http and healthy_state(mode, phase, status, s): break
            time.sleep(.3)
        else: failures.append('completion deadline')
        # Health, state, logs and traffic are sampled through multiple audit periods.
        quiet = service.cursor(); settle_end = time.monotonic() + 35
        while time.monotonic() < settle_end:
            settled = t.state()
            if not healthy_state(mode, phase, status, settled):
                failures.append('unhealthy settled state')
                routing = settled['routing']; infra = routing.get('infrastructure') or {}
                unhealthy_samples.append(dict(elapsed=round(time.monotonic()-started,2),
                    mode=routing['configuration']['mode'], phase=routing['phase'],
                    status=list(settled['status']), heartbeat=routing.get('heartbeatHealth'),
                    infrastructure=infra, services=service.service_health(settled),
                    audit_age=round(time.time()-(infra.get('checkedAt',0)+978307200),2)))
            time.sleep(2)
        rows = service.events(offsets); late = service.events(quiet)
        counts = dict(collections.Counter(x['event'] for x in rows))
        after = fingerprint(); end = t.state(); commands = dict(collections.Counter(
            r.get('fields', {}).get('command') for r in rows if r['event'] == 'mimo_core_command_started'))
        http = counts.get('lookup_http_request', 0)
        triggers = dict(collections.Counter(r.get('fields', {}).get('trigger')
            for r in rows if r['event'] == 'lookup_started'))
        if http != expected_http: failures.append('unexpected HTTP count')
        if method == 'installed five-minute timer' and triggers != {'periodic':1}:
            failures.append('timer did not own the single lookup')
        manual = end.get('manualRefresh') or {}
        if method == 'native dashboard button':
            if triggers != {'manual':1}: failures.append('native click did not own the single lookup')
            if manual.get('phase') != 'succeeded': failures.append('manual refresh feedback did not succeed')
            if end.get('snapshot') == snapshot: failures.append('native refresh did not update snapshot')
        if any(r['event'] in service.FORBIDDEN for r in late): failures.append('unexpected settled work')
        # A provider failure intentionally publishes an error indicator as well
        # as lookup_failed. Infrastructure/command errors are still failures.
        expected_errors = {'lookup_failed', 'indicator_error_set'} if status != 'ready' else set()
        errors = [r['event'] for r in rows if r.get('level') == 'error' and r['event'] not in expected_errors]
        if errors: failures.append('unexpected runtime errors')
        stable_unchanged = stable_fingerprint(before) == stable_fingerprint(after)
        native_scope_only = before != after and stable_unchanged and counts.get('mimo_native_egress_updated',0) > 0
        if preserve and before != after and not native_scope_only:
            failures.append('observation mutated firewall or process identity')
        if preserve and any(counts.get(e, 0) for e in ('mimo_gate_closed', 'mimo_final_profile_loaded',
                                                       'mimo_final_profile_reused', 'mimo_traffic_opened')):
            failures.append('observation entered transition workflow')
        # Bound a public-looking fixture target to the native NIC. This must fail
        # while protected; the normal unbound stream above must succeed via SOCKS.
        native_blocked = None
        if mode != 'direct':
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(1)
                sock.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex('en0'))
                try: sock.connect((F['public4'], F['stream_port'])); native_blocked = False
                except OSError: native_blocked = True
            if not native_blocked: failures.append('native bypass connected')
        # Join before reading counters or deciding the verdict. The last echo
        # must not fail after a PASS row has already been written.
        for stream in streams: stream.stop()
        continuity = {str(stream.family):dict(echoes=stream.sent, errors=stream.errors) for stream in streams}
        if any(stream.errors or stream.sent < 10 for stream in streams): failures.append('persistent traffic interrupted')
        stream = next((value for value in streams if value.family==4),None)
        communication = GUI_AUDIT.finish(evidence_id) if GUI_AUDIT is not None else None
        if communication is None or not communication['passed']:
            failures.append('whole-case GUI communication audit failed')
        result = dict(name=name, evidence_id=evidence_id,
            core_sha256=hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest(), mode=mode, family=end['routing']['configuration']['networkFamily'],
            passed=not failures, failures=sorted(set(failures)), duration=round(time.monotonic()-started,2),
            http_requests=http, triggers=triggers, commands=commands, counts=counts, errors=errors,
            state_samples=state_samples, unhealthy_samples=unhealthy_samples,
            continuity=continuity,
            persistent_echoes=stream.sent if stream else None,
            persistent_errors=stream.errors if stream else None, native_bypass_blocked=native_blocked,
            unchanged_gate_and_processes=all(before[k] == after[k] for k in ('epoch','engine','peers')),
            full_firewall_readback_unchanged=before['policy'] == after['policy'], settled_seconds=35,
            stable_guard_and_processes=stable_unchanged, audited_native_scope_update=native_scope_only,
            rejected_ip_visible=end['routing'].get('blockingIP',{}).get('address') == '203.0.113.99',
            fresh_snapshot=end.get('snapshot') != snapshot, method=method, detail=detail,
            gui_communication=communication,
            communication_disconnects=len(communication['event_audit']['disconnects']) if communication else None)
        if method == 'native dashboard button': result['manual_refresh_phase'] = manual.get('phase')
        results = json.loads(REPORT.read_text()) if REPORT.exists() else []
        results.append(result); save('report.json', results)
        save(evidence_id + '-raw-events.json', rows)
        save(evidence_id + '-raw-fingerprints.json', {'before':before,'after':after})
        print(json.dumps({k:v for k,v in result.items() if k not in ('state_samples','counts')}), flush=True)
        assert result['passed'], 'case failed; stop and inspect private evidence'
        return result
    finally:
        for stream in streams: stream.stop()


def restore_original():
    """Attempt each independent restoration even if fixture control is down."""
    failures = []; completed = []; evidence_id = uuid.uuid4().hex

    def attempt(stage, action):
        try:
            result = action(); completed.append(stage); return result
        except Exception as error:
            # Never put saved settings, provider credentials or arbitrary RPC
            # errors into the exportable cleanup summary.
            failures.append(dict(stage=stage, error=type(error).__name__))
            return None

    original = None
    try:
        original = attempt('read_original', lambda:json.loads((ROOT/'original.json').read_text()))
        # Releasing Mimo uses its local control channel. It must not depend on
        # the separately faulted HTTP fixture or its native DNS mapping.
        attempt('request_direct', lambda:t.route('direct'))
        attempt('wait_direct', lambda:idle('direct', status=None))
        attempt('reset_fixture', lambda:fixture(provider_delay=0, provider_status=200,
            provider_retry_after=None, provider_ip='203.0.113.10', proxy_off=False))
        if original is not None:
            attempt('restore_settings', lambda:t.request('configure', settings=original['settings']))
            selected = original['routing']['configuration'].get('activeProxyID')
            attempt('restore_proxy_selection', lambda:t.request('selectProxy', **({'proxyID':selected} if selected else {})))
            current = attempt('read_proxies', t.state)
            if current is not None:
                original_ids = {proxy['id'] for proxy in original['routing']['configuration']['proxies']}
                for proxy in current['routing']['configuration']['proxies']:
                    if proxy['proxy']['name'] == NAME and proxy['id'] not in original_ids:
                        attempt('remove_fixture_proxy', lambda proxy=proxy:t.request('removeProxy', proxyID=proxy['id']))
            attempt('restore_routing', lambda:t.request('configureRouting', routing=original['routing']['configuration']))
    finally:
        # Keep the original backup for independent recovery. Always restore
        # hosts, even if an earlier fixture/RPC/settings restoration failed.
        attempt('restore_hosts', lambda:native_hosts(False))

    state = attempt('read_restored_state', t.state)
    settings_restored = bool(original is not None and state is not None and state['settings'] == original['settings'])
    routing_restored = bool(original is not None and state is not None and
        state['routing']['configuration'] == original['routing']['configuration'])
    for stage, passed in (('settings_readback', settings_restored), ('routing_readback', routing_restored)):
        if not passed: failures.append(dict(stage=stage, error='ReadbackMismatch'))
    released = attempt('native_release_readback', service.native)
    if original is not None and original['routing']['configuration']['mode'] == 'direct' and not released:
        failures.append(dict(stage='native_release_readback', error='ControlsNotReleased'))
    result = dict(evidence_id=evidence_id, passed=not failures, completed=completed, failures=failures,
        settings_restored=settings_restored, routing_restored=routing_restored,
        hosts_restored='restore_hosts' in completed, native_controls_released=released)
    save(evidence_id+'-cleanup.json', result)
    print(json.dumps(result), flush=True)
    assert result['passed'], 'Restoration incomplete; inspect cleanup summary and retained original backup'


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    if ACTION=='native-hosts':
        hosts=Path('/etc/hosts'); backup=ROOT/'hosts.original'; installed=ROOT/'hosts.installed'
        assert not backup.exists(), 'Native fixture already installed; preserve original backup'
        original=hosts.read_bytes();backup.write_bytes(original)
        names='ipwho.is ipapi.co api.ipapi.is api.ipinfo.io v4.api.ipinfo.io v6.api.ipinfo.io'
        changed=original+b'\n# mimo:observation-test native provider fixture\n'+('127.0.0.1 '+names+'\n').encode()
        installed.write_bytes(changed);hosts.write_bytes(changed)
        t.run(['/usr/bin/dscacheutil','-flushcache'])
        print('Native provider names pinned to closed fixture; original hosts backed up',flush=True)
    elif ACTION=='restore-native-hosts':
        native_hosts(False)
        print('Original hosts restored exactly',flush=True)
    elif ACTION in ('init', 'select-fixture'):
        if ACTION == 'init':
            assert not (ROOT / 'original.json').exists()
            save('original.json', t.state())
        else:
            assert (ROOT / 'original.json').exists()
        native_hosts(True)
        t.route('direct'); idle('direct', status=None)
        existing = next((entry for entry in t.state()['routing']['configuration']['proxies']
                         if entry['proxy']['name'] == NAME), None)
        t.request('saveProxy', proxy=dict(name=NAME, type='socks5', server=F['bridge4'],
                                         port=F['proxy_port'], username=''), proxyPassword='',
                  **({'proxyID': existing['id']} if existing else {}))
        entry = next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name'] == NAME)
        t.request('selectProxy', proxyID=entry['id'])
        settings = t.state()['settings']; settings.update(provider='ipWhois', providerPool=['ipWhois'],
            refreshInterval=-1, bypassBlocks=[], allowlist={'addresses':['203.0.113.10']})
        t.request('configure', settings=settings)
        print('Private baseline saved; closed fixture selected', flush=True)
    elif ACTION == 'setup':
        mode,family=sys.argv[3:5]
        native_hosts(mode=='direct')
        fixture(provider_delay=0,provider_status=200,provider_retry_after=None,provider_ip='203.0.113.10',proxy_off=False)
        settings=t.state()['settings']; settings['allowlist']={'addresses':['203.0.113.10']}
        t.request('configure',settings=settings)
        t.route(mode,family); idle(mode); time.sleep(35)
        assert healthy_state(mode,'active','ready')
        print('Setup settled: '+mode+'/'+family,flush=True)
    elif ACTION=='provider':
        provider=sys.argv[3]
        assert provider in ('ipWhois','ipapiCo','ipapiIs')
        fixture(provider_delay=3,provider_status=200,provider_retry_after=None,provider_ip='203.0.113.10',proxy_off=False)
        mode=t.state()['routing']['configuration']['mode']
        native_hosts(mode=='direct')
        def change_provider():
            settings=t.state()['settings'];settings.update(provider=provider,providerPool=[provider])
            t.request('configure',settings=settings)
        observe('explicit-provider-'+provider,change_provider,mode,
                detail='Explicit selection of a different healthy provider; previous refusal cooldown remains intact')
    elif ACTION == 'case':
        case=sys.argv[3]; mode=t.state()['routing']['configuration']['mode']
        native_hosts(mode=='direct')
        family=t.state()['routing']['configuration']['networkFamily']
        sequence=len(json.loads(REPORT.read_text())) if REPORT.exists() else 0
        name=str(sequence+1)+'-'+mode+'-'+family+'-'+case
        fixture(provider_delay=3,provider_status=200,provider_retry_after=None,provider_ip='203.0.113.10',proxy_off=False)
        if case=='rapid-refresh':
            fixture(provider_delay=8)
            observe(name,lambda:burst([{'command':'refresh'} for _ in range(12)]),mode,
                    detail='12 overlapping Refresh requests, 80 ms launch spacing')
        elif case in ('refresh','concurrent'):
            def action():
                t.request('refresh')
                if case=='concurrent':
                    time.sleep(1.1);t.request('refresh')
            observe(name,action,mode)
        elif case=='policy-retain':
            def action():
                settings=t.state()['settings'];settings['allowlist']={'addresses':['203.0.113.10','203.0.113.99']}
                t.request('configure',settings=settings)
            observe(name,action,mode)
        elif case in ('inflight-retain','inflight-revoke'):
            fixture(provider_delay=8)
            def action():
                t.request('refresh')
                service.wait(lambda:t.state()['routing'].get('observation'),20)
                time.sleep(1)
                settings=t.state()['settings']
                settings['allowlist']={'addresses':[] if case=='inflight-revoke' else ['203.0.113.10','203.0.113.99']}
                response=t.request('configure',settings=settings)
                if case=='inflight-revoke':
                    assert response['state']['routing']['phase']=='blocked'
            observe(name,action,mode,phase='blocked' if case=='inflight-revoke' else 'active',
                    preserve=case=='inflight-retain',expected_http=2 if case=='inflight-revoke' else 1)
        elif case in ('503','invalid','429'):
            fixture(**({'provider_status':503} if case=='503' else {'provider_ip':'invalid'} if case=='invalid'
                       else {'provider_status':429,'provider_retry_after':45}))
            observe(name,lambda:t.request('refresh'),mode,status='coolingDown')
        elif case in ('paused-refresh', 'paused-direct-refresh'):
            if case == 'paused-direct-refresh':
                # Count the Direct paused-refresh case; retain mode-change
                # setup inside its whole-case GUI audit, before observe's
                # expected-zero-HTTP measurement starts.
                native_hosts(True)
                t.route('direct')
                idle('direct', status='coolingDown')
                mode='direct'
            observe(name,lambda:t.request('refresh'),mode,status='coolingDown',expected_http=0,
                    detail='Explicit Refresh respects provider refusal while preserving approved traffic')
            assert t.state()['manualRefresh']['phase']=='deferred'
        elif case=='recover':
            observe(name,lambda:t.request('refresh'),mode)
        elif case=='denied':
            # Ensure the changed fixture IP is not permitted before measuring.
            settings=t.state()['settings'];settings['allowlist']={'addresses':['203.0.113.10']}
            before=t.state().get('snapshot')
            t.request('configure',settings=settings)
            service.wait(lambda:t.state().get('snapshot')!=before,60);idle(mode);time.sleep(2)
            fixture(provider_ip='203.0.113.99')
            observe(name,lambda:t.request('refresh'),mode,phase='blocked',preserve=False)
            assert t.state()['routing']['blockingIP']['address']=='203.0.113.99'
        elif case=='approve-rejected':
            fixture(provider_ip='203.0.113.99')
            def action():
                settings=t.state()['settings'];settings['allowlist']={'addresses':['203.0.113.10','203.0.113.99']}
                t.request('configure',settings=settings)
            observe(name,action,mode,preserve=False)
        elif case=='policy-revoke':
            def action():
                settings=t.state()['settings'];settings['allowlist']={'addresses':[]}
                response=t.request('configure',settings=settings)
                assert response['state']['routing']['phase']=='blocked','revocation acknowledgement preceded block'
            observe(name,action,mode,phase='blocked',preserve=False)
        elif case=='policy-repair':
            def action():
                settings=t.state()['settings'];settings['allowlist']={'addresses':['203.0.113.10']}
                t.request('configure',settings=settings)
            observe(name,action,mode,preserve=False)
        elif case=='direct':
            def direct():
                native_hosts(True)
                t.route('direct')
            observe(name,direct,'direct',preserve=False)
            assert service.native()
        else: raise ValueError(case)
    elif ACTION=='transition':
        mode,family,kind=sys.argv[3:6]
        native_hosts(False)
        if kind=='refused':
            fixture(provider_delay=0,provider_status=200,provider_retry_after=None,proxy_off=False)
            assert t.state()['routing']['configuration']['mode']=='direct'
            entry=next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name']==NAME)
            proxy=dict(entry['proxy']);proxy['port']=F['refused_port']
            t.request('saveProxy',proxyID=entry['id'],proxy=proxy)
            observe(mode+'-'+family+'-direct-to-refused-proxy',lambda:t.route(mode,family),mode,
                    phase='blocked',status='coolingDown',preserve=False)
        elif kind=='repair':
            entry=next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name']==NAME)
            proxy=dict(entry['proxy']);proxy['port']=F['proxy_port']
            observe(mode+'-'+family+'-repair-proxy',lambda:t.request('saveProxy',proxyID=entry['id'],proxy=proxy),mode,preserve=False)
        else:raise ValueError(kind)
    elif ACTION=='native':
        mode=t.state()['routing']['configuration']['mode']
        fixture(provider_delay=5,provider_status=200,provider_retry_after=None,provider_ip='203.0.113.10',proxy_off=False)
        observe('native-'+sys.argv[3],lambda:print('ARMED: activate Refresh now once',flush=True),mode,
                method='native dashboard button',detail='Five-second held reply; one dashboard activation with simultaneous event and traffic audit',
                deadline_seconds=300)
    elif ACTION=='periodic':
        mode=t.state()['routing']['configuration']['mode']
        fixture(provider_delay=3,provider_status=200,provider_retry_after=None,provider_ip='203.0.113.10',proxy_off=False)
        settings=t.state()['settings'];settings['refreshInterval']=300
        t.request('configure',settings=settings)
        old=t.state().get('snapshot');t.request('refresh')
        service.wait(lambda:t.state().get('snapshot')!=old,60);idle(mode)
        observe('installed-periodic',lambda:None,mode,deadline_seconds=360,
                method='installed five-minute timer',detail='Manual success establishes the next full interval')
        settings=t.state()['settings'];settings['refreshInterval']=-1
        t.request('configure',settings=settings)
    elif ACTION=='restore':
        restore_original()
    else:raise ValueError(ACTION)

def audited_main():
    """Start before any setup; always retain evidence if preparation fails."""
    global GUI_AUDIT
    audited = ACTION in ('select-fixture', 'setup', 'provider', 'case', 'transition', 'native', 'periodic')
    error = None
    if audited:
        assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
        assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
        os.umask(0o077)
        GUI_AUDIT = GUICaseAudit(ROOT, service.cursor, service.events, read_only_state_probe, gui_process_ids,
                               active_process_ids=active_mimo_process_ids)
    try:
        if GUI_AUDIT: GUI_AUDIT.start()
        main()
    except Exception as failure:
        error = type(failure).__name__
        raise
    finally:
        if GUI_AUDIT and GUI_AUDIT.result is None:
            evidence_id = uuid.uuid4().hex
            audit = GUI_AUDIT.finish(evidence_id)
            result = dict(name=ACTION+'-whole-case', evidence_id=evidence_id,
                core_sha256=hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest(),
                passed=error is None and audit['passed'], gui_communication=audit,
                communication_disconnects=len(audit['event_audit']['disconnects']),
                failure_class=error, support_only=ACTION=='setup')
            save(evidence_id+'-whole-case.json', result)
            print(json.dumps(result), flush=True)
            if error is None: assert result['passed'], 'Whole-case communication audit failed'


if __name__=='__main__':audited_main()
