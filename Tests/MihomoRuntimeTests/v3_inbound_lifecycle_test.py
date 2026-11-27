#!/usr/bin/env python3
"""Three installed primary-VM supplements, using real RPC/dashboard backends.

Private snapshots and raw logs never leave the owner-only evidence directory.
No native UI clicks, UDP, IPv6, Screen Sharing or general leakage claim.
"""
import argparse
import base64
import collections
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import tarfile
import threading
import time
import uuid

VM = 'mimo-test-macos'
IP = '192.168.64.2'
UUID = 'B7E215A5-5447-584C-98F9-809346832111'
ANCHOR = 'com.apple/000.mimo'
SUPPORT = Path('/Library/Application Support/Mimo')
DAEMON = '/Applications/Mimo.app/Contents/Resources/daemon.sh'
JOBS = ['com.mimo.core', 'com.mimo.supervisor', 'com.mimo.mihomo',
        'com.mimo.pf-boot', 'com.mimo.infrastructure']
ALIASES = [('inet', '192.0.2.253'), ('inet6', 'fd00:6d69:6d6f::fe')]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def fresh_checked_denial(state, since):
    """Require the same typed, fresh successful observation behind a rejection."""
    routing = state.get('routing') or {}
    blocked = routing.get('blockingIP')
    observed = routing.get('observedIP')
    if routing.get('phase') != 'blocked' or routing.get('configuration', {}).get('mode') != 'rule' or \
            'ready' not in state.get('status', {}) or not isinstance(blocked, dict) or not isinstance(observed, dict):
        return False
    address = observed.get('address')
    checked = observed.get('checkedAt')
    return isinstance(address, str) and bool(address) and blocked.get('address') == address and \
        isinstance(checked, (int, float)) and not isinstance(checked, bool) and \
        blocked.get('checkedAt') == checked and checked + 978307200 >= since


def run(args, timeout=10):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return dict(args=args, status=p.returncode, stdout=p.stdout, stderr=p.stderr, epoch=time.time())


def logs():
    return list(Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')) + list(
        Path('/Users').glob('*/Library/Application Support/Mimo/Logs/runtime-*.jsonl'))


def events(since):
    rows = []
    for path in logs():
        try:
            with path.open() as f:
                for line in f:
                    try:
                        row = json.loads(line)
                        stamp = row.get('timestamp', '')
                        import datetime
                        epoch = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp()
                        if epoch >= since:
                            rows.append(row)
                    except (ValueError, TypeError):
                        continue
        except FileNotFoundError:
            continue
    return rows


def loopback_addresses():
    result=run(['/sbin/ifconfig','lo0'])
    assert result['status']==0
    return {str(ipaddress.ip_address(match[1].split('%',1)[0]))
            for line in result['stdout'].splitlines()
            if (match := re.match(r'^\s+inet6?\s+(\S+)',line))}


def remove_owned_aliases(root):
    path=root/'aliases.json'
    if not path.exists():
        return {'not_installed':True}
    journal=json.loads(path.read_text())
    assert journal['root']==str(root) and journal['aliases']==[list(x) for x in ALIASES]
    assert journal['original_absent'] and path.stat().st_uid==0 and not path.is_symlink()
    removed=[]
    for family,address in ALIASES:
        if address in loopback_addresses():
            assert [family,address] in journal['intents'], 'Alias has no owned installation intent'
            result=run(['/sbin/ifconfig','lo0',family,address,'-alias'],5)
            assert result['status']==0,'owned_alias_removal_failed'
            removed.append(address)
    assert not any(address in loopback_addresses() for _,address in ALIASES)
    result={'aliases_absent':True,'removed':removed,'epoch':time.time()}
    save(root/'aliases-cleaned.json',result)
    return result


def alias_watchdog(root):
    root=Path(root);assert re.fullmatch(r'/var/tmp/mimo-inbound-lifecycle-[0-9a-f]{32}',str(root))
    assert os.geteuid()==0 and root.stat().st_uid==0 and root.stat().st_mode&0o077==0
    journal=json.loads((root/'aliases.json').read_text())
    while time.monotonic()<journal['deadline_uptime'] and not (root/'aliases-cleaned.json').exists():
        time.sleep(.2)
    if not (root/'aliases-cleaned.json').exists():
        save(root/'alias-watchdog-result.json',remove_owned_aliases(root))


def guest(root, action):
    os.umask(0o077)
    root = Path(root)
    assert os.geteuid() == 0 and re.fullmatch(r'/var/tmp/mimo-inbound-lifecycle-[0-9a-f]{32}', str(root))
    assert root.is_dir() and root.stat().st_uid == 0 and root.stat().st_mode & 0o077 == 0
    manifest = json.loads((root / 'manifest.json').read_text())
    hw = run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'])
    assert re.search(r'"IOPlatformUUID"\s*=\s*"' + UUID + '"', hw['stdout'])
    assert digest(Path(__file__).read_bytes()) == manifest['harness_sha256']
    controls = str(root / 'controls')
    assert digest(Path(controls).read_bytes()) == manifest['controls_sha256']
    exporter = root/'policy-exporter'
    assert digest(exporter.read_bytes()) == manifest['policy_exporter_sha256']
    exported = run([str(exporter)], 3)
    assert exported['status'] == 0, 'production_policy_export_failed'
    policy = json.loads(exported['stdout'])
    assert policy['schema'] == 2 and policy['local_destinations'] == policy['parsed_destinations']
    assert policy['direct_readback_accepted'] and '(self)' not in policy['inbound_tcp']
    save(root/('policy-'+action+'-'+uuid.uuid4().hex+'.json'), policy)
    expected = policy['direct_tracking']

    def state(timeout=3):
        p = run([controls], timeout)
        assert p['status'] == 0, 'state_rpc_failed'
        r = json.loads(p['stdout'])
        assert r.get('state') and not r.get('failure'), 'state_reply_failed'
        return r['state']

    def request(command, **kw):
        path = root / ('request-' + uuid.uuid4().hex + '.json')
        save(path, dict(command=command, protocolVersion=8, **kw))
        result = run([controls, 'request', str(path)], 90)
        save(root / ('reply-' + path.stem + '.json'), result)
        assert result['status'] == 0, 'request_transport_failed'
        response = json.loads(result['stdout'])
        assert not response.get('failure'), 'request_failed'
        return response

    def mode(value):
        config = state()['routing']['configuration']
        config['mode'] = value
        return request('configureRouting', routing=config)

    def pf():
        r = run(['/sbin/pfctl', '-a', ANCHOR, '-sr'])
        assert r['status'] == 0
        return r['stdout']

    def healthy(s):
        r = s['routing']; i = r.get('infrastructure') or {}
        ages = [time.time() - (i.get(k, i.get('checkedAt', 0)) + 978307200)
                for k in ('pfCheckedAt', 'launchdCheckedAt')]
        return r.get('heartbeatHealth') == 'healthy' and i.get('pf') == 'healthy' and \
            i.get('launchd') == 'healthy' and i.get('pfEvidenceCurrent') is True and \
            all(-5 <= age <= 35 for age in ages)

    def wait(predicate, maximum=70):
        end = time.monotonic() + maximum; last = None
        while time.monotonic() < end:
            last = state()
            if predicate(last):
                return last
            time.sleep(.5)
        save(root / ('deadline-' + uuid.uuid4().hex + '.json'), last)
        raise AssertionError('terminal_deadline')

    def direct():
        return wait(lambda s: s['routing']['configuration']['mode'] == 'direct' and
                    s['routing']['phase'] == 'active' and s['routing'].get('effectiveMode') == 'direct'
                    and healthy(s) and pf() == expected)

    def settled(name, predicate):
        began = time.time(); samples = []; deadline = time.monotonic() + 35
        failures = []
        while time.monotonic() < deadline:
            started = time.monotonic(); s = state()
            gui = run(['/usr/bin/pgrep', '-x', 'mimo-gui'], 2)
            pids = gui['stdout'].split()
            baseline_gui = json.loads((root/'gui-baseline.json').read_text())['pid']
            item = dict(epoch=time.time(), rpc_seconds=time.monotonic()-started,
                        state=s, gui_pids=pids,
                        passed=bool(predicate(s) and healthy(s) and pids == [baseline_gui]))
            samples.append(item)
            save(root / (name + '-settled.json'), samples)
            if not item['passed']:
                failures.append('settled_health_or_state')
            time.sleep(1)
        rows = events(began)
        save(root / (name + '-settled-events.json'), rows)
        forbidden = {'lookup_started', 'mimo_gate_closed', 'mimo_traffic_opened',
                     'mimo_peer_repair_started', 'mimo_peer_recovery_wait',
                     'mimo_core_command_failed', 'mimo_command_rejected',
                     'daemon_client_disconnected', 'daemon_client_stopped'}
        bad = [r for r in rows if r.get('event') in forbidden or r.get('level') == 'error']
        save(root / (name + '-settled-verdict.json'), dict(passed=not failures and not bad,
             failures=failures, unexpected_events=bad, sample_count=len(samples), seconds=35))
        assert not failures and not bad, 'settled_event_or_health_failure'
        return dict(samples=len(samples), seconds=35)

    def backend(operation):
        result = run(['/usr/bin/env', 'SUDO_USER=mimotest', '/bin/bash', DAEMON, operation], 160)
        save(root / ('backend-' + operation + '-' + uuid.uuid4().hex + '.json'), result)
        assert result['status'] == 0, operation + '_failed'
        return dict(operation=operation, status=0, epoch=result['epoch'])

    def release_snapshot():
        result = {'jobs': {j: run(['/bin/launchctl', 'print', 'system/' + j]) for j in JOBS},
                  'rules': run(['/sbin/pfctl', '-a', ANCHOR, '-sr']),
                  'root_rules': run(['/sbin/pfctl', '-sr']),
                  'all_rules': run(['/sbin/pfctl', '-a', '*', '-sr']),
                  'tun': run(['/sbin/ifconfig', 'utun239']),
                  'dns': run(['/usr/sbin/scutil', '--dns']),
                  'hosts_sha256': digest(Path('/etc/hosts').read_bytes())}
        save(root / 'released.json', result)
        assert all(v['status'] != 0 for v in result['jobs'].values()), 'jobs_remain'
        assert not result['rules']['stdout'].strip(), 'owned_rules_remain'
        assert 'mimo' not in result['root_rules']['stdout'].lower(), 'owned_root_reference_remains'
        assert 'mimo:' not in result['all_rules']['stdout'].lower(), 'owned_child_rules_remain'
        assert result['tun']['status'] != 0 and '1053' not in result['dns']['stdout'], 'native_controls_remain'
        return dict(released=True, jobs_absent=True, dns_released=True, tun_absent=True)

    if action == 'baseline':
        assert digest(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()) == manifest['core_sha256']
        if manifest.get('comparison_exporter_sha256'):
            comparison=root/'policy-exporter-comparison'
            assert digest(comparison.read_bytes())==manifest['comparison_exporter_sha256']
            previous=run([str(comparison)],3);assert previous['status']==0
            value=json.loads(previous['stdout'])
            fields=['local_destinations','direct_tracking','startup_blocking','fully_released',
                    'inbound_tcp','inbound_loopback','direct_readback_accepted','parsed_destinations']
            same={key:value[key] for key in fields}=={key:policy[key] for key in fields}
            save(root/'renderer-equivalence.json',dict(passed=same,previous=value,current=policy))
            assert same,'production_renderer_output_changed'
        original = state()
        assert original['routing']['configuration']['mode'] == 'direct'
        assert original['routing']['configuration'].get('activeProxyID'), 'no_real_proxy_selected'
        assert not (root / 'original.json').exists()
        save(root / 'original.json', original)
        pids = run(['/usr/bin/pgrep', '-x', 'mimo-gui'], 2)['stdout'].split()
        assert len(pids) == 1, 'one_GUI_required'
        gui_events = sorted([r for r in events(0) if r.get('fields', {}).get('processRole') == 'gui'
            and r['fields'].get('pid') == pids[0] and r.get('event') in
            ('daemon_client_connected','daemon_client_disconnected','daemon_client_stopped','process_entered')],
            key=lambda r:r.get('timestamp',''))
        assert gui_events and gui_events[-1]['event'] == 'daemon_client_connected', 'GUI_connection_receipt_missing'
        save(root/'gui-baseline.json',dict(pid=pids[0],connected=gui_events[-1]))
        save(root / 'baseline.json', dict(epoch=time.time(), hosts_sha256=digest(Path('/etc/hosts').read_bytes()),
             root_rules=run(['/sbin/pfctl', '-sr']), state=original, rules=pf()))
        direct()
        settings = original['settings'].copy()
        settings.update(allowlist={'addresses': []}, refreshInterval=-1)
        request('configure', settings=settings)
        direct()
        print(json.dumps({'baseline_saved': True, 'direct_tracking': True}))
    elif action == 'snapshot':
        result = dict(epoch=time.time(), state=state(), rules=pf(), states=run(['/sbin/pfctl', '-ss', '-vv']))
        save(root / ('snapshot-' + uuid.uuid4().hex + '.json'), result)
        print(json.dumps(result))
    elif action == 'rule-denied':
        began = time.time(); mode('rule')
        blocked = wait(lambda s: s['routing']['phase'] == 'blocked' and
                       bool(s['routing'].get('blockingIP')) and 'ready' in s['status'] and healthy(s))
        save(root / 'rule-blocked.json', blocked)
        assert fresh_checked_denial(blocked, began), 'blocked_successful_observation_not_fresh_or_matching'
        assert 'block drop out quick' in pf(), 'closed_policy_missing'
        proof = settled('rule', lambda s: s['routing']['phase'] == 'blocked' and
                        s['routing'].get('blockingIP') == blocked['routing']['blockingIP'] and 'ready' in s['status'])
        print(json.dumps(dict(blocked_fresh_ip=True, **proof)))
    elif action == 'direct':
        mode('direct'); direct()
        print(json.dumps({'direct_tracking': True}))
    elif action == 'deactivate':
        backend('deactivate'); print(json.dumps(release_snapshot()))
    elif action == 'activate':
        backend('activate')
        assert digest(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()) == manifest['core_sha256']
        direct(); print(json.dumps(settled('activated', lambda s: s['routing']['phase'] == 'active'
            and s['routing'].get('effectiveMode') == 'direct' and pf() == expected)))
    elif action == 'restore':
        if not Path('/Library/PrivilegedHelperTools/mimo-core').exists():
            backend('activate')
        original = json.loads((root / 'original.json').read_text())
        mode('direct'); direct()
        request('configure', settings=original['settings'])
        request('configureRouting', routing=original['routing']['configuration'])
        current = direct()
        result = dict(settings_restored=current['settings'] == original['settings'],
                      routing_restored=current['routing']['configuration'] == original['routing']['configuration'],
                      hosts_unchanged=digest(Path('/etc/hosts').read_bytes()) == json.loads((root/'baseline.json').read_text())['hosts_sha256'],
                      direct_tracking=pf() == expected, healthy=healthy(current))
        save(root/'restoration.json', result)
        assert all(result.values()), 'baseline_restoration_failed'
        print(json.dumps(result))
    elif action == 'capture-start':
        path=root/'ssh.pcap'; log=(root/'tcpdump.log').open('x')
        argv=['/usr/sbin/tcpdump','-U','-n','-s','0','-i','en0','-w',str(path),
              'tcp port 22 and host 192.168.64.1']
        process=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        time.sleep(.3);assert process.poll() is None
        save(root/'capture.json',dict(pid=process.pid,args=argv,path=str(path)))
        print(json.dumps({'capture_started':True}))
    elif action == 'capture-stop':
        owned=root/'capture.json'
        if owned.exists():
            spec=json.loads(owned.read_text());pid=spec['pid']
            ps=run(['/bin/ps','-ww','-p',str(pid),'-o','command='])
            if ps['status']==0:
                assert spec['path'] in ps['stdout'] and 'tcpdump' in ps['stdout']
                os.kill(pid,signal.SIGINT)
                deadline=time.monotonic()+6
                while run(['/bin/ps','-p',str(pid),'-o','pid='])['status']==0 and time.monotonic()<deadline:
                    time.sleep(.1)
                assert run(['/bin/ps','-p',str(pid),'-o','pid='])['status']!=0, 'capture_not_joined'
            save(root/'capture-stopped.json',dict(joined=True,pid=pid))
        print(json.dumps({'capture_joined':True}))
    elif action == 'l1-events':
        rows=events(manifest['started_epoch'])
        save(root/'L1-all-events.json',rows)
        bad=[r for r in rows if r.get('event') in
             ('daemon_client_disconnected','daemon_client_stopped','mimo_peer_repair_started',
              'mimo_peer_recovery_wait','mimo_core_command_failed','mimo_command_rejected') or r.get('level')=='error']
        save(root/'L1-event-verdict.json',dict(passed=not bad,unexpected=bad,
             counts=dict(collections.Counter(r.get('event') for r in rows))))
        assert not bad,'unexpected_whole_L1_events'
        print(json.dumps({'whole_case_events_passed':True}))
    elif action == 'event-export':
        rows=events(manifest['started_epoch']);save(root/'all-events.json',rows)
        print(json.dumps({'events_archived':len(rows)}))
    elif action == 'address-change':
        direct()
        assert not any(address in loopback_addresses() for _,address in ALIASES), 'fixture_address_preexists'
        assert not (root/'aliases.json').exists(), 'alias_journal_preexists'
        began=time.time()
        journal={'root':str(root),'aliases':[list(x) for x in ALIASES],
                 'original_absent':True,'started_epoch':began,'deadline_epoch':began+150,
                 'deadline_uptime':time.monotonic()+150,'intents':[]}
        save(root/'aliases.json',journal)
        watchdog=subprocess.Popen(['/usr/bin/python3',__file__,'alias-watchdog',str(root)],
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        save(root/'alias-watchdog.json',dict(pid=watchdog.pid,deadline_epoch=journal['deadline_epoch']))

        def stable_controls():
            runtime=SUPPORT/'Runtime'
            dns=subprocess.run(['/usr/sbin/scutil'],input='show State:/Network/Service/com.mimo.dns/DNS\nquit\n',
                               capture_output=True,text=True,timeout=5)
            profiles={str(path):{'sha256':digest(path.read_bytes()),'mtime_ns':path.stat().st_mtime_ns}
                      for directory in (SUPPORT/'Runtime',SUPPORT/'Mihomo') for path in directory.glob('*.yaml')}
            jobs={}
            for label in JOBS[:3]:
                result=run(['/bin/launchctl','print','system/'+label])
                match=re.search(r'^\s*pid = (\d+)',result['stdout'],re.M)
                assert result['status']==0 and match, 'owned_job_missing'
                jobs[label]=int(match[1])
            return dict(gate=(runtime/'gate.state').read_text(),
                        close_epoch=(runtime/'pf-close.epoch').read_text(),
                        dns=dns.stdout,profiles=profiles,jobs=jobs)

        def current_policy():
            result=run([str(exporter)],3);assert result['status']==0
            value=json.loads(result['stdout'])
            assert value['local_destinations']==value['parsed_destinations'] and value['direct_readback_accepted']
            return value

        def match_inventory(want):
            end=time.monotonic()+20;samples=[]
            while time.monotonic()<end:
                s=state();r=s['routing'];live=pf();current=current_policy()
                safe=r['configuration']['mode']=='direct' and r['phase']=='active' and r.get('effectiveMode')=='direct'
                safe=safe and (SUPPORT/'Runtime/gate.state').read_text().strip()=='direct' and 'block ' not in live
                item=dict(epoch=time.time(),state=s,policy=live,export=current,direct_open=safe)
                samples.append(item);save(root/('address-'+('added' if want else 'removed')+'-transition.json'),samples)
                assert safe,'Direct_gate_changed_during_address_refresh'
                if all((address in current['local_destinations'])==want for _,address in ALIASES) and live==current['direct_tracking'] and healthy(s):
                    return current
                time.sleep(.5)
            raise AssertionError('literal_inventory_refresh_deadline')

        before=stable_controls();save(root/'address-before.json',before)
        try:
            for family,address in ALIASES:
                journal['intents'].append([family,address]);save(root/'aliases.json',journal)
                argv=['/sbin/ifconfig','lo0',family,address]+(['netmask','255.255.255.255'] if family=='inet' else ['prefixlen','128'])+['alias']
                result=run(argv,5);save(root/('alias-'+family+'-add.json'),result)
                assert result['status']==0 and address in loopback_addresses(),'alias_install_failed'
            added=match_inventory(True)
            settled('address-added',lambda s:s['routing']['phase']=='active' and s['routing'].get('effectiveMode')=='direct' and pf()==added['direct_tracking'])
            remove_owned_aliases(root)
            removed=match_inventory(False)
            settled('address-removed',lambda s:s['routing']['phase']=='active' and s['routing'].get('effectiveMode')=='direct' and pf()==removed['direct_tracking'])
            after=stable_controls();save(root/'address-after.json',after)
            assert before==after,'address_refresh_changed_other_controls'
            rows=events(began);save(root/'address-all-events.json',rows)
            forbidden={'lookup_started','mimo_gate_closed','mimo_traffic_opened','mimo_final_profile_loaded',
                       'mimo_final_profile_reused','mimo_dns_removed_and_drained','mimo_direct_network_released',
                       'mimo_peer_repair_started','mimo_peer_recovery_wait','mimo_core_command_failed',
                       'mimo_command_rejected','daemon_client_disconnected','daemon_client_stopped'}
            bad=[r for r in rows if r.get('event') in forbidden or r.get('level')=='error']
            updates=[r for r in rows if r.get('event')=='mimo_direct_tracking_updated']
            verdict=dict(passed=not bad and len(updates)>=2,unexpected_events=bad,tracking_updates=len(updates),
                         counts=dict(collections.Counter(r.get('event') for r in rows)))
            save(root/'address-event-verdict.json',verdict)
            assert verdict['passed'],'address_refresh_event_failure'
            print(json.dumps({'literal_add_remove':True,'settled_seconds_each':35,'tracking_updates':len(updates)}))
        finally:
            remove_owned_aliases(root)
            watchdog.wait(3)
            save(root/'alias-watchdog-joined.json',dict(pid=watchdog.pid,joined=True,status=watchdog.returncode))
    else:
        raise ValueError('Unknown guest action')


class SSHObserver:
    def __init__(self, output):
        self.output = output; self.samples = []; self.done = threading.Event(); self.pending = b''
        remote = 'import json,sys,time\nprint(json.dumps({"ready":True}),flush=True)\nfor line in sys.stdin:\n print(json.dumps({"echo":line.strip(),"guest_epoch":time.time()}),flush=True)'
        args = ['/usr/bin/ssh', '-T', '-vv', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                '-o', 'ServerAliveInterval=0', '-o', 'StrictHostKeyChecking=yes', '-o', 'IdentitiesOnly=yes',
                '-o', 'HostKeyAlias=mimo-test-macos', '-o', 'UserKnownHostsFile='+str(Path.home()/'.ssh/known_hosts_mimo-test-macos'),
                '-i', str(Path.home()/'.ssh/mimo-vm-admin_ed25519'), 'mimotest@'+IP,
                shlex.join(['/usr/bin/python3', '-u', '-c', remote])]
        self.log = (output/'ssh.log').open('x')
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        ready = self.receive(8)
        assert ready.get('ready'), 'ssh_ready_failed'
        assert 'Authenticated to' in (output/'ssh.log').read_text(), 'ssh_auth_missing'
        endpoint = run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.process.pid), '-iTCP', '-FpnT'])
        match = re.search(r'n192\.168\.64\.1:(\d+)->192\.168\.64\.2:22', endpoint['stdout'])
        assert match, 'ssh_tuple_missing'
        save(output/'ssh-owner.json', dict(pid=self.process.pid, args=args, tuple=['192.168.64.1',int(match[1]),IP,22], epoch=time.time()))
        self.thread = threading.Thread(target=self.work, daemon=True); self.thread.start()

    def receive(self, timeout):
        end = time.monotonic() + timeout
        while b'\n' not in self.pending:
            ready, _, _ = select.select([self.process.stdout], [], [], max(0,end-time.monotonic()))
            if not ready: raise TimeoutError('ssh_echo_timeout')
            data = os.read(self.process.stdout.fileno(), 4096)
            if not data: raise EOFError('ssh_closed')
            self.pending += data
        line, self.pending = self.pending.split(b'\n',1)
        return json.loads(line)

    def work(self):
        while not self.done.is_set():
            nonce = uuid.uuid4().hex; started = time.time(); row = dict(started_epoch=started, passed=False)
            try:
                self.process.stdin.write((nonce+'\n').encode()); self.process.stdin.flush()
                r = self.receive(3)
                row.update(passed=r.get('echo')==nonce, finished_epoch=time.time(), guest_epoch=r.get('guest_epoch'))
            except Exception as e:
                row['error_class'] = type(e).__name__
            self.samples.append(row); save(self.output/'ssh-samples.json', self.samples)
            if not row['passed']: break
            self.done.wait(.5)

    def finish(self):
        self.done.set(); self.thread.join(5)
        self.process.stdin.close()
        try: self.process.wait(3)
        except subprocess.TimeoutExpired: self.process.terminate(); self.process.wait(3)
        self.log.close()
        result = dict(passed=bool(self.samples) and all(r['passed'] for r in self.samples) and not self.thread.is_alive(),
                      samples=len(self.samples), joined=self.process.poll() is not None)
        save(self.output/'ssh-verdict.json', result)
        return result


def host(args):
    os.umask(0o077); repo = Path(__file__).resolve().parents[2]
    output = Path(args.output).resolve(); output.mkdir(mode=0o700)
    core = args.core_sha256; assert re.fullmatch('[0-9a-f]{64}',core)
    policy_exporter = Path(args.policy_exporter).read_bytes()
    comparison_exporter=Path(args.compare_exporter).read_bytes() if args.compare_exporter else None
    source = Path(__file__).read_bytes(); controls = Path(args.controls).read_bytes()
    root = '/var/tmp/mimo-inbound-lifecycle-' + uuid.uuid4().hex
    manifest = dict(core_sha256=core,harness_sha256=digest(source),controls_sha256=digest(controls),
                    policy_exporter_sha256=digest(policy_exporter), vm=VM, uuid=UUID, root=root, started_epoch=time.time())
    if comparison_exporter:
        manifest['comparison_exporter_sha256']=digest(comparison_exporter)
    save(output/'manifest.json',manifest)
    admin_path = repo/'.build/observation-parallel/vm-admin.py'; seq=0

    def admin(label, code, timeout=190):
        nonlocal seq
        seq += 1
        p=subprocess.run([sys.executable,str(admin_path),'--vm',VM,'/usr/bin/python3','-c',code],capture_output=True,text=True,timeout=timeout)
        (output/(str(seq).zfill(3)+'-'+label+'.log')).write_text(p.stdout+p.stderr)
        assert p.returncode==0,label+'_failed'
        return json.loads(p.stdout)

    admin('identity', 'import subprocess,json;hw=subprocess.check_output(["/usr/sbin/ioreg","-rd1","-c","IOPlatformExpertDevice"],text=True);assert '+repr(UUID)+' in hw;print(json.dumps({"expected_vm":True}))')
    payload={'harness.py':source,'controls':controls,'policy-exporter':policy_exporter,
             'manifest.json':json.dumps(manifest).encode()}
    if comparison_exporter:
        payload['policy-exporter-comparison']=comparison_exporter
    bundle=output/'staging.tar.gz'
    with tarfile.open(bundle,'w:gz') as tar:
        for name,data in payload.items():
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o700 if name=='controls' or name.startswith('policy-exporter') else 0o600
            tar.addfile(info,io.BytesIO(data))
    transfer='/tmp/mimo-inbound-lifecycle-'+uuid.uuid4().hex+'.tar.gz'
    p=run(['/usr/bin/scp','-q','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
           '-o','HostKeyAlias=mimo-test-macos','-o','UserKnownHostsFile='+str(Path.home()/'.ssh/known_hosts_mimo-test-macos'),
           '-i',str(Path.home()/'.ssh/mimo-vm-admin_ed25519'),str(bundle),'mimotest@'+IP+':'+transfer],20)
    save(output/'transfer.json',dict(status=p['status'],target=IP,path=transfer,sha256=digest(bundle.read_bytes())))
    assert p['status']==0,'pinned_SCP_failed'
    admin('stage', 'import pathlib,hashlib,tarfile,json,os,subprocess;os.umask(0o077);hw=subprocess.check_output(["/usr/sbin/ioreg","-rd1","-c","IOPlatformExpertDevice"],text=True);assert '+repr(UUID)+' in hw;p=pathlib.Path('+repr(root)+');bundle=pathlib.Path('+repr(transfer)+');assert not bundle.is_symlink() and hashlib.sha256(bundle.read_bytes()).hexdigest()=='+repr(digest(bundle.read_bytes()))+';p.mkdir(mode=0o700);\nwith tarfile.open(bundle) as t:\n assert set(t.getnames())=='+repr(set(payload))+'\n for m in t:\n  assert m.isfile();q=p/m.name;q.write_bytes(t.extractfile(m).read());q.chmod(0o700 if m.name=="controls" or m.name.startswith("policy-exporter") else 0o600)\nbundle.unlink();print(json.dumps({"staged":True}))')

    def action(name):
        return admin(name,'import runpy,sys;sys.argv=['+repr(root+'/harness.py')+',"guest",'+repr(root)+','+repr(name)+'];runpy.run_path(sys.argv[0],run_name="__main__")')

    results=[]; observer=None; restore=None
    try:
        action('baseline')
        action('capture-start')
        print('Installed supplements:0/3; Direct tracking verified; establishing authenticated SSH.',flush=True)
        observer=SSHObserver(output); birth=action('snapshot'); save(output/'ssh-birth.json',birth)
        owner=json.loads((output/'ssh-owner.json').read_text());a,ap,b,bp=owner['tuple']
        lines=[line for line in birth['states']['stdout'].splitlines() if a+':'+str(ap) in line and b+':'+str(bp) in line]
        assert any(' <- ' in line for line in lines),'incoming_state_missing_at_birth'
        denied=action('rule-denied'); closed=action('snapshot');save(output/'ssh-closed.json',closed)
        action('direct'); ssh=observer.finish();observer=None
        assert ssh['passed'],'incoming_continuity_failed'
        event_proof=action('l1-events')
        results.append(dict(id='L1',passed=True,denied=denied,ssh=ssh,events=event_proof))
        save(output/'case-L1.json',results[-1]);print('Installed supplements:1/3 PASS; testing dashboard Stop/Start backend.',flush=True)
        stopped=action('deactivate'); activated=action('activate')
        results.append(dict(id='L2',passed=True,released=stopped,activated=activated))
        save(output/'case-L2.json',results[-1]);print('Installed supplements:2/3 PASS; checking Direct local address add/remove.',flush=True)
        changed=action('address-change');results.append(dict(id='L3',passed=True,address_change=changed))
        save(output/'case-L3.json',results[-1]);print('Installed supplements:3/3 PASS; restoring original settings.',flush=True)
    except Exception as e:
        save(output/'failure.json',dict(error_class=type(e).__name__,reason=str(e),completed=len(results)))
    finally:
        if observer is not None:
            try: observer.finish()
            except Exception as e: save(output/'ssh-cleanup-error.json',dict(error_class=type(e).__name__))
        try: restore=action('restore')
        except Exception as e: restore=dict(passed=False,error_class=type(e).__name__)
        try: action('capture-stop')
        except Exception as e:
            save(output/'capture-cleanup-error.json',dict(error_class=type(e).__name__))
            restore['capture_joined']=False
        try: action('event-export')
        except Exception as e:
            save(output/'event-export-error.json',dict(error_class=type(e).__name__))
            restore['events_archived']=False
        export=admin('archive','import io,tarfile,pathlib,base64,hashlib,json;p=pathlib.Path('+repr(root)+');b=io.BytesIO();\nwith tarfile.open(fileobj=b,mode="w:gz") as t:\n for f in p.iterdir():\n  assert f.is_file() and not f.is_symlink();t.add(f,arcname=f.name)\ndata=b.getvalue();print(json.dumps({"sha256":hashlib.sha256(data).hexdigest(),"data":base64.b64encode(data).decode()}))')
        data=base64.b64decode(export.pop('data'));assert digest(data)==export['sha256']
        (output/'guest-private.tar.gz').write_bytes(data)
        save(output/(str(seq).zfill(3)+'-archive.log'),export)
        summary=dict(planned=3,completed=len(results),passed=sum(r['passed'] for r in results),results=results,restoration=restore,
                     archive_sha256=export['sha256'],core_sha256=core,harness_sha256=digest(source),controls_sha256=digest(controls),
                     policy_exporter_sha256=digest(policy_exporter),
                     guest_root=root,scope='Actual installed RPC plus dashboard daemon.sh deactivate/activate; no native clicks')
        summary['all_passed']=len(results)==3 and restore is not None and all(restore.values())
        save(output/'summary.json',summary);print(json.dumps(summary),flush=True)
    return 0 if summary['all_passed'] else 1


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='alias-watchdog':
        alias_watchdog(sys.argv[2]);sys.exit(0)
    if len(sys.argv)>1 and sys.argv[1]=='guest':
        guest(sys.argv[2],sys.argv[3]);sys.exit(0)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True);parser.add_argument('--core-sha256',required=True)
    parser.add_argument('--controls',required=True);parser.add_argument('--policy-exporter',required=True)
    parser.add_argument('--compare-exporter')
    parser.add_argument('--start',action='store_true');args=parser.parse_args()
    if not args.start:parser.error('--start required for VM actions')
    sys.exit(host(args))
