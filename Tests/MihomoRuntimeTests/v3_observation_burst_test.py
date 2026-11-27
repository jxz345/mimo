#!/usr/bin/env python3
"""Rapid production RPCs with closed native/proxy provider paths; not UI clicks."""
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import sys
import time
import urllib.error
import urllib.request
import uuid

import v3_installed_test as t
import v3_service_command_test as service
import v3_observation_test as observation
import v3_native_provider_dns as native_dns
from v3_observation_transport import audit_provider_transport
from v3_gui_event_audit import GUICaseAudit
from v3_health_trace import HealthTrace, guard_health, wait_for_phase

ROOT = Path(sys.argv[1])
REPORT = ROOT / 'burst-results.json'
PROVIDER_HOSTS = {'ipWhois':'ipwho.is', 'ipapiCo':'ipapi.co', 'ipapiIs':'api.ipapi.is',
                  'ipinfoLite':'v4.api.ipinfo.io'}



def health_sample(state, index):
    """Retain the exact inputs behind the existing health predicate."""
    started = time.time()
    healthy = bool(service.healthy(state))
    finished = time.time()
    routing = state['routing']
    infra = routing.get('infrastructure') or {}
    checked = infra.get('checkedAt')
    checked_epoch = checked + 978307200 if isinstance(checked, (int, float)) else None
    age_start = started - checked_epoch if checked_epoch is not None else None
    age_end = finished - checked_epoch if checked_epoch is not None else None
    failed = []
    if routing.get('heartbeatHealth') != 'healthy': failed.append('heartbeat')
    if infra.get('launchd') != 'healthy': failed.append('launchd')
    if infra.get('pf') not in ('healthy', 'released'): failed.append('pf')
    if age_end is None or age_end >= 35: failed.append('infrastructure_age')
    return {'index': index, 'sampled_start_epoch': started, 'sampled_end_epoch': finished,
        'mode': routing['configuration']['mode'], 'phase': routing['phase'],
        'healthy': healthy, 'status': list(state['status']),
        'heartbeat_health': routing.get('heartbeatHealth'),
        'heartbeat_checked_at': routing.get('heartbeatCheckedAt'),
        'infrastructure': {key: infra.get(key) for key in ('pf', 'launchd', 'checkedAt',
            'pfCheckedAt', 'launchdCheckedAt', 'completedAt', 'inspection', 'pfEvidenceCurrent')},
        'infrastructure_age_start_seconds': age_start, 'infrastructure_age_end_seconds': age_end,
        'failed_components': failed,
        'services': [{key: item.get(key) for key in ('id', 'health', 'checkedAt')}
                     for item in routing.get('services', [])]}

def fixture_response():
    f = observation.F
    request = urllib.request.Request('http://%s:%s' % (f.get('control_host',f['bridge4']),f['control_port']),
        headers={'Authorization':'Bearer '+f['token']})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request,timeout=3) as response:
                assert response.status == 200
                return json.load(response)
        except (OSError, urllib.error.URLError):
            if attempt:raise
            time.sleep(1)


def fixture_events():
    return fixture_response()['events']


def fixture_clock_samples():
    """Bound host/guest clock offset using authenticated response round trips."""
    samples=[]
    for _ in range(3):
        started=time.time()
        response=fixture_response()
        ended=time.time()
        host=response['fixture_clock_epoch']
        assert type(host) in (int,float) and math.isfinite(host), 'Invalid fixture clock'
        samples.append({'guest_start_epoch':started,'host_epoch':host,'guest_end_epoch':ended})
    return samples




def closed_path_evidence(core, events, provider, host, path, ingress):
    """Require the actual core request and the designated closed-fixture ingress."""
    starts = [x for x in core if x.get('event')=='mimo_probe_http_started' and
              x.get('fields',{}).get('provider')==provider and x['fields'].get('path')==path]
    successes = [x for x in core if x.get('event')=='lookup_succeeded' and
                 x.get('fields',{}).get('provider')==provider]
    started_ids={x['fields'].get('lookup') for x in starts}-{None,''}
    succeeded_ids={x['fields'].get('lookup') for x in successes}-{None,''}
    matched_ids=started_ids & succeeded_ids
    incoming = [x for x in events if x.get('event')=='provider_ingress' and
                x.get('ingress')==ingress and x.get('host')==host]
    replies = [x for x in events if x.get('event')=='provider_http' and x.get('host')==host]
    rejected = [x for x in events if x.get('event')=='provider_ingress_rejected']
    return dict(passed=bool(matched_ids and incoming and replies and not rejected),
        path=path,ingress=ingress,core_starts=len(starts),core_successes=len(successes),
        correlated_lookups=len(matched_ids),
        fixture_ingress=len(incoming),fixture_replies=len(replies),fixture_rejections=len(rejected))


def eligible_provider():
    s = t.state();provider=s['settings']['provider']
    cooldowns=s.get('cooldowns',{})
    if isinstance(cooldowns,list):cooldowns=dict(zip(cooldowns[::2],cooldowns[1::2]))
    until=cooldowns.get(provider)
    assert until is None or float(until)+978307200<=time.time(), 'Selected provider is paused; preserve its cooldown'
    assert provider in PROVIDER_HOSTS, 'Unsupported provider fixture'
    usage=s.get('budget',{}).get('usage',{}).get(provider,{})
    day=float(usage.get('day',0))+978307200
    used=usage.get('count',0) if int(day//86400)==int(time.time()//86400) else 0
    limit={'ipWhois':800,'ipapiCo':800,'ipapiIs':24}.get(provider)
    assert limit is None or used<limit, 'Selected provider daily budget is exhausted; preserve its quota'
    return provider


def native_fixture_proof(provider):
    f=observation.F;host=PROVIDER_HOSTS[provider]
    assert f.get('loopback_provider_alias') is True, 'Closed provider alias fixture is required'
    assert host in f.get('loopback_provider_names',[]), 'Selected provider lacks fixture TLS qualification'
    assert isinstance(f.get('native_provider_port'),int), 'Dedicated native provider ingress is required'
    assert f.get('protected_provider_ingress')=='proxy_configured_dns' and \
        isinstance(f.get('protected_provider_port'),int), 'Dedicated resolved-provider ingress is required'
    proof=native_dns.verify(ROOT,f)
    assert proof.get('installed') is True and host in proof.get('names',[]), 'Owned native provider resolver is required'
    assert isinstance(proof.get('file_sha256'),dict) and proof['file_sha256'], 'Resolver content proof is required'
    assert proof.get('nameserver')=='127.0.0.1' and proof.get('instance'), 'Scoped resolver instance proof is required'
    return {'nameserver':proof['nameserver'],'names':sorted(proof['names']),'port':proof['port'],
            'file_sha256':proof['file_sha256'],'instance':proof['instance']}


def preflight(family,initial,provider,proofs,check_dns):
    f=observation.F;host=PROVIDER_HOSTS[provider]
    configuration=t.state()['routing']['configuration']
    proxy=next((x for x in configuration['proxies'] if x['id']==configuration.get('activeProxyID')),None)
    assert proxy and proxy['proxy']['name']==observation.NAME, 'Select the owned qualification proxy first'
    assert proxy['proxy']['server']==f['bridge4'] and proxy['proxy']['port']==f['proxy_port'], 'Fixture endpoint changed'
    # Native macOS queries use exact scoped resolvers. Mihomo keeps its closed
    # DoH path and original hostname; /etc/hosts must remain unchanged.
    for mode,path,ingress in [('direct','native_direct','native_relay'),
                              (initial,'private_proxy_probe',f['protected_provider_ingress'])]:
        check_dns()
        offsets=service.cursor();before=fixture_events();old=t.state().get('snapshot')
        t.route(mode,family)
        if mode=='direct':t.request('refresh')
        observation.idle(mode)
        service.wait(lambda:t.state().get('snapshot')!=old,35)
        after=fixture_events();assert len(after)>=len(before), 'Fixture restarted during preflight'
        proof=closed_path_evidence(service.events(offsets),after[len(before):],provider,host,path,ingress)
        proof['fixture_answer']=t.state().get('snapshot',{}).get('ipAddress')=='203.0.113.10'
        proof['passed']=proof['passed'] and proof['fixture_answer']
        proofs.append(proof)
        assert proof['passed'], 'Closed provider path preflight failed: '+path
        check_dns()
    return proofs


def main():
    assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid==0 and ROOT.stat().st_mode & 0o077==0
    os.umask(0o077)
    family,initial,final,scenario=sys.argv[3:7]
    phase = next((value.split('=', 1)[1] for value in sys.argv[7:] if value.startswith('--health-phase=')), None)
    if phase is not None:
        assert (family,initial,final,scenario)==('dual','global','rule','allowed')
        assert phase in ('early','late')
    evidence_id=uuid.uuid4().hex
    name='burst-'+family+'-'+initial+'-to-'+final+'-'+scenario
    started=time.monotonic();offsets=service.cursor()
    stage='preflight';failures=[];samples=[];proofs=[];rows=[];unexpected=[];manual={}
    before=None;after=None;fixture_before=[];fixture_after=[];per_lookup={};counts={}
    settled_seconds=0;raised=None;provider=None;original=None
    dns_proof=None;dns_checks=0;dns_preserved=False;hosts_unchanged=False
    clock_samples={'before':[],'after':[]};transport_audit=None;gui_audit=None;gui_communication=None
    communication=GUICaseAudit(ROOT,service.cursor,service.events,
        observation.read_only_state_probe,observation.gui_process_ids,
        active_process_ids=observation.active_mimo_process_ids)
    def state_probe():
        answer=t.run([t.CONTROLS],3)
        assert answer.returncode==0
        value=json.loads(answer.stdout)
        assert value.get('state') and not value.get('failure')
        return value['state']
    health=HealthTrace(ROOT,state_probe,service.cursor,service.events) if phase else None
    phase_proof=None;continuous_health=None
    hosts=Path('/etc/hosts')

    def check_dns():
        nonlocal dns_proof,dns_checks
        assert original is not None and hosts.read_bytes()==original, 'Hosts must remain exactly original'
        assert (ROOT/'hosts.original').read_bytes()==original, 'Original hosts backup changed'
        current=native_fixture_proof(provider)
        if dns_proof is None:dns_proof=current
        else:assert current==dns_proof, 'Owned scoped provider resolvers changed'
        dns_checks+=1

    try:
        communication.start()
        if health:health.start()
        provider=eligible_provider()
        original=(ROOT/'hosts.original').read_bytes()
        assert b'# mimo:observation-test' not in original, 'Original hosts contains a fixture override'
        # Even allowlist setup can start a native Direct lookup. The owner must
        # install the stable scoped fixture before this harness changes settings.
        check_dns()
        observation.fixture(provider_delay=0,provider_status=200,provider_retry_after=None,
                            provider_ip='203.0.113.10',proxy_off=False)
        settings=t.state()['settings'];settings['allowlist']={'addresses':['203.0.113.10']}
        t.request('configure',settings=settings)
        preflight(family,initial,provider,proofs,check_dns)
        stage='scenario_setup'
        if scenario=='denied':
            observation.fixture(provider_ip='203.0.113.99')
            t.request('refresh');observation.idle(initial,'blocked')
        elif scenario=='proxy-down':
            t.route('direct');observation.idle('direct')
            observation.fixture(proxy_off=True)
            t.route(initial,family);observation.idle(initial,'blocked','coolingDown')
        else:
            assert scenario=='allowed'
        observation.fixture(provider_delay=8)
        check_dns()
        clock_samples['before']=fixture_clock_samples()
        if phase:
            phase_proof=wait_for_phase(phase,lambda:guard_health(health.guard_path),state_probe,service.healthy)
            observation.save(evidence_id+'-scan-phase.json',phase_proof)
        before=observation.fingerprint();offsets=service.cursor();fixture_before=fixture_events()
        configuration=t.state()['routing']['configuration']
        def mode(value):return {'command':'configureRouting','routing':dict(configuration,mode=value)}
        # Preserve the original rapid overlapping order. No DNS changes, mode
        # completion waits or fixture rewrites occur between these launches.
        requests=([{'command':'refresh'}]*4+[mode('direct')]+[{'command':'refresh'}]*4+
                  [mode('global'),mode('rule')]+[{'command':'refresh'}]*4)
        stage='burst'
        observation.burst(requests,spacing=.12)
        t.route(final)
        observation.burst([{'command':'refresh'}]*8)
        check_dns()
        expected_phase='active' if scenario=='allowed' or final=='direct' else 'blocked'
        expected_status='coolingDown' if scenario=='proxy-down' and final!='direct' else 'ready'
        stage='terminal_state'
        observation.idle(final,expected_phase,expected_status)
        settled=service.cursor();stage='settled_audit'
        for _ in range(18):
            check_dns()
            s=t.state();r=s['routing']
            samples.append(health_sample(s, len(samples)))
            time.sleep(2)
        settled_seconds=36
        if any(x['mode']!=final or x['phase']!=expected_phase or expected_status not in x['status'] or not x['healthy'] for x in samples):
            failures.append('unstable final mode or health')
        if any(x['event'] in service.FORBIDDEN for x in service.events(settled)):
            failures.append('unexpected settled work')
        manual=t.state().get('manualRefresh') or {}
        if manual.get('phase')!='succeeded':failures.append('latest manual refresh did not reach success')
        after=observation.fingerprint()
        if before['engine']!=after['engine'] or before['peers']!=after['peers']:
            failures.append('burst restarted infrastructure')
        if final=='direct' and not service.native():failures.append('Direct did not release network controls')
        stage='complete'
    except Exception as error:
        raised=type(error).__name__
        failures.append(stage+' did not complete ('+raised+')')
    finally:
        # Export even a terminal-state timeout; do not lose the event/request
        # IDs merely because the postcondition was never reached.
        try:rows=service.events(offsets)
        except Exception:failures.append('event export failed')
        counts=dict(collections.Counter(x['event'] for x in rows))
        per_lookup=dict(collections.Counter(x.get('fields',{}).get('lookup') for x in rows if x['event']=='lookup_http_request'))
        if stage not in ('preflight','scenario_setup'):
            if any(value!=1 for value in per_lookup.values()):failures.append('duplicate HTTP within lookup')
            if not 1<=sum(per_lookup.values())<=6:failures.append('unbounded provider requests')
        unexpected=[x['event'] for x in rows if x.get('level')=='error' and x['event'] not in
                    ({'lookup_failed','indicator_error_set'} if scenario=='proxy-down' else set())]
        if unexpected:failures.append('unexpected runtime errors')
        if health:
            try:
                trace=health.finish(evidence_id)
                continuous_health={key:value for key,value in trace.items() if key not in ('samples','scan_events')}
                if not trace['passed']:failures.append('continuous health evidence failed')
            except Exception:failures.append('continuous health export failed')
        try:
            gui_communication=communication.finish(evidence_id)
            gui_audit=gui_communication['event_audit']
            if not gui_communication['passed']:failures.append('GUI communication or lifecycle audit failed')
        except Exception:failures.append('whole-case communication export failed')
        try:
            clock_samples['after']=fixture_clock_samples()
            fixture_after=fixture_events()
            assert len(fixture_after)>=len(fixture_before), 'Fixture restarted during burst'
            transport_audit=audit_provider_transport(fixture_after[len(fixture_before):],rows,
                provider,PROVIDER_HOSTS.get(provider),clock_samples)
            if not transport_audit['passed']:
                failures.append('provider transport or clock audit failed')
        except Exception:failures.append('fixture ingress export failed')
        # The fixture stays installed across cases and final Direct monitoring.
        # Only the campaign owner removes it during the final cleanup.
        try:
            hosts_unchanged=original is not None and hosts.read_bytes()==original and \
                (ROOT/'hosts.original').read_bytes()==original
        except Exception:hosts_unchanged=False
        try:
            check_dns();dns_preserved=True
        except Exception:failures.append('native DNS fixture or original hosts changed')
        result={'name':name,'evidence_id':evidence_id,'passed':not failures,
            'core_sha256':hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest(),
            'failures':sorted(set(failures)),'method':'overlapping production RPCs; not native clicks',
            'refresh_requests':20,'mode_requests':4,'launch_spacing_seconds':[.12,.08],
            'http_requests':sum(per_lookup.values()),'max_http_per_lookup':max(per_lookup.values(),default=0),
            'counts':counts,'errors':unexpected,'duration':round(time.monotonic()-started,2),
            'manual_refresh_phase':manual.get('phase'),'settled_seconds':settled_seconds,'samples':samples,
            'health_failures':[sample for sample in samples if not sample['healthy']],
            'health_phase':phase_proof,'continuous_health':continuous_health,
            'final_mode':final,'scenario':scenario,'family':family,'last_stage':stage,
            'fixture_preflight':proofs,'stable_native_dns':before is not None,
            'hosts_unchanged':hosts_unchanged,'native_resolvers_preserved':dns_preserved,
            'native_resolver_proof':dns_proof,'native_fixture_checks':dns_checks,
            'transport_audit':transport_audit,'fixture_clock_samples':clock_samples,
            'communication_disconnects':len(gui_audit['disconnects']) if gui_audit else None,
            'gui_audit':gui_audit,'gui_communication':gui_communication,
            'preflight_error':raised if stage=='preflight' else None}
        results=json.loads(REPORT.read_text()) if REPORT.exists() else []
        results.append(result);REPORT.write_text(json.dumps(results,indent=2))
        observation.save(evidence_id+'-health-samples.json',samples)
        observation.save(evidence_id+'-raw-events.json',rows)
        observation.save(evidence_id+'-fixture-events.json',fixture_after[len(fixture_before):])
        print(json.dumps({k:v for k,v in result.items() if k not in ('samples','counts')}),flush=True)
    assert result['passed'],'Burst regression failed; inspect private logs'


if __name__=='__main__':main()
