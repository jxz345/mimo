#!/usr/bin/env python3
"""Preempt initial private HTTP with a real family configuration change.

VM only; production RPC, not a native click. No process signals or route changes.
Raw events/captures stay private; the shared wrapper owns LAB cleanup.
"""
import sys
import time
from pathlib import Path

import v3_installed_test as t
import v3_service_command_test as service
import v3_fault_traffic_test as packets
import v3_observation_test as observation
import v3_observation_packet_test as audit


def native_fixture(enabled):
    """Keep an installed scoped fixture stable; retain legacy standalone setup."""
    root = observation.ROOT
    if (root / 'native-resolver.json').exists():
        import v3_native_provider_dns as native_dns
        native_dns.verify(root, observation.F)
        assert Path('/etc/hosts').read_bytes() == (root / 'hosts.original').read_bytes(), \
            'Scoped native DNS requires unchanged original hosts'
        return
    observation.native_hosts(enabled)


def prepare_direct():
    observation.fixture(provider_delay=0,provider_status=200,provider_retry_after=None,
                        provider_ip='203.0.113.10',proxy_off=False)
    native_fixture(True)
    t.route('direct'); observation.idle('direct',status=None)
    began=time.monotonic(); deadline=began+610
    while time.monotonic()<deadline:
        state=t.state(); value=state.get('cooldowns') or {}
        cooldowns=value if isinstance(value,dict) else dict(zip(value[::2],value[1::2]))
        providers=list(dict.fromkeys([state['settings']['provider'],'ipWhois','ipapiCo','ipapiIs']))
        provider=next((name for name in providers if name in ('ipWhois','ipapiCo','ipapiIs') and
                       cooldowns.get(name,0)+978307200<=time.time()),None)
        if provider is not None: break
        time.sleep(5)
    else: raise AssertionError('No fixture provider became eligible')
    settings=state['settings']
    settings.update(provider=provider,providerPool=[provider],allowlist={'addresses':['203.0.113.10']})
    t.request('configure',settings=settings); observation.idle('direct')
    return dict(provider=provider,cooldown_wait_seconds=round(time.monotonic()-began,2))


def execute(evidence_id):
    family,mode,kind=sys.argv[3:6]
    assert kind=='verification-preemption' and family in ('ipv4','dual') and mode in ('rule','global')
    initial_family='dual' if family=='ipv4' else 'ipv4'
    setup=prepare_direct(); setup.update(initial_family=initial_family,final_family=family)
    native_fixture(False)
    observation.fixture(provider_delay=12)
    def pending():
        routing=t.state()['routing']
        return routing.get('verification') if routing['phase']=='checking' else None
    try:
        fixture_offset=len(audit.fixture_events()); offsets=service.cursor()
        t.route(mode,initial_family)
        held=service.wait(pending,30)
        ingress=service.wait(lambda:audit.held_ingress(offsets,held['id'],fixture_offset,setup['provider'],
                                                     'mimo_private_probe_ready'),20)
        assert ingress['received_count']==1, 'Multiple initial provider requests entered fixture'
    finally:
        observation.fixture(provider_delay=0)
    assert (pending() or {}).get('id')==held['id'], 'Initial verification completed before preemption'
    engine_before=packets.engine_identity()
    worker=packets.Traffic(evidence_id+'-verification-preemption')
    start=None; ended=None; recovered=False; error=None; engine_after=None
    try:
        start=time.time(); t.route(mode,family); ended=time.time()
        packets.approved(mode,family)
        engine_after=packets.engine_identity(); recovered=True
        time.sleep(2)
    except Exception as failure:
        error=type(failure).__name__
    finally:
        native=worker.finish()
    assert not any(thread.is_alive() for thread in worker.threads), 'Packet worker did not stop'
    closed=next((sample['t']-start for sample in worker.samples if start and sample['t']>=start and
                 sample['pf'] in ('closed','probe')),None)
    echoes={str(af):sum(event['success'] for event in worker.events if event['kind']=='echo' and event['family']==af)
            for af in (4,6)}
    attempts={str(af):sum(event.get('send_attempted',False) for event in worker.events if
              event['kind']=='echo' and event['family']==af and start is not None and event['t']>=start)
              for af in (4,6)}
    outcome=dict(fault_started_at=start,fault_ended_at=ended,fault_variant='family-change-during-initial-verification',
        engine_before=engine_before,engine_after=engine_after,engine_unchanged=engine_before==engine_after,
        first_sampled_closed_seconds=closed,native_attempts=len(native),public_echo_successes=echoes,
        echo_send_attempts_after_preemption=attempts,recovered=recovered,error_type=error)
    observation.save(evidence_id+'-fault-result.json',outcome)
    quiet=service.cursor(); time.sleep(35)
    rows=service.events(offsets); late=service.events(quiet); final=t.state()
    observation.save(evidence_id+'-fault-events.json',rows)
    failures,fencing=audit.fault_checks(rows,None,held,final['routing'],outcome,mode,family,kind)
    receipt=(final['routing'].get('exitObservations') or {}).get('verification') or {}
    if receipt.get('networkGeneration',-1)<=held['networkGeneration']: failures.append('replacement generation did not advance')
    higher_close=[row for row in rows if row['event']=='mimo_core_command_started' and
                  row.get('fields',{}).get('command')=='close' and
                  int(row.get('fields',{}).get('generation',-1))>held['networkGeneration'] and
                  audit.datetime.fromisoformat(row['timestamp'].replace('Z','+00:00')).timestamp()>=(start or float('inf'))]
    if not higher_close: failures.append('superseding configuration close not correlated')
    if native: failures.append('native bypass attempts')
    if any(echoes.values()) or not all(attempts.values()): failures.append('public ping coverage failed')
    if not recovered: failures.append('protected recovery failed')
    if engine_before!=engine_after: failures.append('configuration change restarted engine')
    bad=[row['event'] for row in late if row['event'] in service.FORBIDDEN or row.get('level')=='error']
    if bad: failures.append('unexpected settled work')
    if not observation.healthy_state(mode,'active','ready',final): failures.append('unhealthy recovered state')
    if final['routing']['configuration']['networkFamily']!=family: failures.append('wrong final family')
    fencing['higher_generation_close_count']=len(higher_close)
    return dict(name='packets-'+family+'-'+mode+'-'+kind,passed=not failures,failures=failures,
        setup=setup,held_fixture_ingress=ingress,fault_fencing=fencing,packet_result=outcome,
        late_errors=bad,settled_seconds=35,
        method='production configureRouting RPC; initial private HTTP held across family change',
        evidence_files=[evidence_id+'-fault-events.json',evidence_id+'-fault-result.json'],packet_evidence_prefix=worker.label)


if __name__=='__main__':
    audit.execute=execute
    audit.main()
