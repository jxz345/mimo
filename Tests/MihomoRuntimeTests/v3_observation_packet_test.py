#!/usr/bin/env python3
"""Installed observation packet regression. VM only; raw captures stay private.

Uses the established dual-family packet worker and lower containment anchor.
Run control, then one case per process; never overlap campaigns on the same VM.
Separate VMs with independent fixtures and control channels may run in parallel.
The host restores its saved settings after all observation tests finish.
"""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import time
import traceback
import urllib.request
import uuid

import v3_installed_test as t
import v3_service_command_test as service
import v3_fault_traffic_test as packets
import v3_observation_test as observation
from v3_gui_event_audit import GUICaseAudit

ROOT = Path(sys.argv[1])
ACTION = sys.argv[2]
REPORT = ROOT / 'observation-packets.json'


def record(row):
    row['core_sha256'] = hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest()
    rows = json.loads(REPORT.read_text()) if REPORT.exists() else []
    rows.append(row)
    REPORT.write_text(json.dumps(rows, indent=2))
    print(json.dumps(row), flush=True)
    assert row['passed'], 'Packet regression failed; inspect private captures'


def fault_checks(rows, previous, held, final, outcome, mode, family, kind):
    """Do not call eventual Active plus zero native packets fault recovery."""
    fault_started = outcome.get('fault_started_at')
    fault_ended = outcome.get('fault_ended_at')
    timed_fault = isinstance(fault_started, (int,float)) and isinstance(fault_ended, (int,float)) and \
        fault_started > 0 and fault_ended >= fault_started

    def stamp(row):
        return datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00')).timestamp()

    def at_or_after(row, boundary):
        # Older RuntimeLog records have whole-second precision; current ones
        # include fractions. Never round a precise record back into validity.
        second = stamp(row)
        return timed_fault and (second >= boundary or
            ('.' not in row['timestamp'] and second == int(boundary)))

    def during_fault_window(row):
        return at_or_after(row, fault_started)

    held_id = held.get('id')
    initial_verification = kind in ('verification-stall', 'verification-preemption')
    stalled = kind in ('engine-stall', 'verification-stall')
    killed_engine = outcome.get('fault_variant') == 'engine-kill-with-core-delivery-delay'
    start_event = 'mimo_private_probe_ready' if initial_verification else 'mimo_observation_started'
    final_id = (final.get('exitObservations') or {}).get('verification', {}).get('id')
    started = [row for row in rows if row['event']==start_event and
               row.get('fields', {}).get('attempt')==held_id]
    lookup_ids = {row.get('fields', {}).get('lookup') for row in started} - {None, ''}
    closes = [row for row in rows if row['event']=='mimo_gate_closed' and
              str(row.get('fields', {}).get('confirmed')).lower()=='true' and during_fault_window(row)]
    openings = [row for row in rows if row['event']=='mimo_traffic_opened' and
                row.get('fields', {}).get('attempt')==final_id and
                row.get('fields', {}).get('mode')==mode and row.get('fields', {}).get('family')==family and
                during_fault_window(row)]
    approvals = [row for row in rows if row['event'] in ('mimo_observation_approved','mimo_traffic_opened') and
                 row.get('fields', {}).get('attempt')==held_id]
    held_pauses = [row for row in rows if row['event']=='provider_failure_paused' and
                  row.get('fields', {}).get('lookup') in lookup_ids]

    # Diagnostic timestamps can have one-second precision. The packet worker
    # separately requires an actual closed/probe sample after fault injection;
    # a same-second close/open pair is therefore valid evidence here.
    ordered = bool(closes) and any(stamp(opened)>=max(stamp(closed) for closed in closes) for opened in openings)
    # Engine-kill's end is only an observation-window boundary. For a stall,
    # recovery can follow SIGCONT or a supervisor replacement of that PID.
    # A replacement must be responsive on the expected profile, remain the
    # recovered identity, and be observed before the matching fresh opening.
    reopened_after_resume = any(at_or_after(opened, fault_ended) for opened in openings) if stalled and not killed_engine else None
    stalled_engine = outcome.get('faulted_engine_identity') or outcome.get('stalled_engine_identity')
    recovered_engine = outcome.get('recovered_engine_identity')
    replacements = [sample for sample in outcome.get('responsive_replacement_samples', []) if
                    timed_fault and sample.get('t',0)>=fault_started and
                    sample.get('identity')==recovered_engine and recovered_engine!=stalled_engine and
                    sample.get('mode')==mode and sample.get('family')==family]
    replacement_opened = bool(stalled_engine and recovered_engine) and any(
        at_or_after(opened, sample['t']) for sample in replacements for opened in openings)
    recovered_after_usable_engine = (bool(stalled_engine and recovered_engine) and
        ((not killed_engine and stalled_engine==recovered_engine and reopened_after_resume) or replacement_opened)) if stalled else None
    cancellations = [row for row in rows if row['event'] in ('lookup_cancelled','mimo_probe_result_cancelled') and
                     row.get('fields',{}).get('lookup') in lookup_ids]
    held_http_finished = [row for row in rows if row['event']=='mimo_probe_http_finished' and
                          row.get('fields',{}).get('lookup') in lookup_ids]
    invalidated_before_http_result = bool(closes and held_http_finished) and any(
        stamp(closed)<min(stamp(finished) for finished in held_http_finished) for closed in closes)
    held_closes = [row for row in rows if row['event']=='mimo_supervisor_command_received' and
                   row.get('fields',{}).get('command')=='close' and row.get('fields',{}).get('lookup') in lookup_ids]
    ignored_closes = [row for row in rows if row['event']=='mimo_verification_failure_ignored' and
                      row.get('fields',{}).get('lookup') in lookup_ids]
    closed_after_fault = outcome.get('first_sampled_closed_seconds') is not None and \
        outcome['first_sampled_closed_seconds'] >= 0
    failures = []
    if not timed_fault: failures.append('missing injection timestamps')
    if not held_id or not started or len(lookup_ids)!=1: failures.append('held observation not correlated')
    if not closes or not closed_after_fault: failures.append('fault did not confirm gate closure')
    if (not initial_verification and not previous) or not final_id or final_id in (previous, held_id): failures.append('fault reused old approval')
    if not openings or not ordered: failures.append('new verification did not reopen after closure')
    if approvals: failures.append('held observation approved after fault window began')
    if held_pauses: failures.append('invalidated held lookup paused its provider')
    if stalled and not recovered_after_usable_engine: failures.append('new verification did not follow usable engine recovery')
    if initial_verification and not cancellations: failures.append('obsolete initial verification did not cancel')
    if kind=='verification-stall' and not invalidated_before_http_result: failures.append('fault did not invalidate initial verification before HTTP result')
    if initial_verification and len(held_closes)>len(ignored_closes): failures.append('obsolete verification sent an accepted close')
    selected = {'mimo_observation_started','mimo_private_probe_ready','mimo_observation_approved','mimo_gate_closed','mimo_traffic_opened',
                'mimo_liveness_lost','mimo_verification_audit_failed','mimo_network_changed',
                'mimo_core_command_started','mimo_core_command_failed','mimo_supervisor_command_received','mimo_verification_failure_ignored',
                'lookup_cancelled','mimo_probe_result_cancelled','lookup_finished','lookup_failed','provider_failure_paused','mimo_probe_http_finished'}
    fields = {'attempt','lookup','generation','revision','confirmed','mode','family','source','outcome','command',
              'provider','category','resumeAt','seconds','explicitRetry'}
    evidence = dict(previous_approval=previous,
        fault_started_at=fault_started, fault_ended_at=fault_ended,
        held_observation={key:held.get(key) for key in ('id','revision','networkGeneration','startedAt')},
        recovered_approval=final_id, held_lookup_ids=sorted(lookup_ids),
        confirmed_close_count=len(closes), sampled_closed_after_fault=closed_after_fault,
        matching_open_count=len(openings), held_approval_count=len(approvals),
        held_provider_pause_count=len(held_pauses), reopened_after_engine_resume=reopened_after_resume,
        reopened_after_usable_engine=recovered_after_usable_engine,
        responsive_replacement_count=len(replacements),
        held_lookup_cancelled_count=len(cancellations), held_close_request_count=len(held_closes),
        held_close_ignored_count=len(ignored_closes),
        initial_verification_invalidated_before_http_result=invalidated_before_http_result if kind=='verification-stall' else None,
        held_lookup_finished_count=sum(row['event']=='lookup_finished' and row.get('fields',{}).get('lookup') in lookup_ids for row in rows),
        events=[dict(timestamp=row.get('timestamp'), event=row['event'],
                     fields={key:value for key,value in row.get('fields',{}).items() if key in fields or
                             (row['event']=='provider_failure_paused' and key=='reason')})
                for row in rows if row['event'] in selected])
    return failures, evidence


def preserve_fault_evidence(label, evidence_id):
    # The shared fault worker uses a fixed case label. Copy immediately so a
    # later retry cannot overwrite the evidence named by an earlier row.
    names = []
    for suffix in ('-en0.pcap','-pflog0.pcap','-en0.capture.log','-pflog0.capture.log','-observations.json'):
        name = evidence_id+suffix
        shutil.copyfile(ROOT/(label+suffix), ROOT/name)
        names.append(name)
    return names


def prepare(mode, family):
    """Settle fixture setup separately; retain real provider refusal cooldowns."""
    observation.fixture(provider_delay=0, provider_status=200, provider_retry_after=None,
                        provider_ip='203.0.113.10', proxy_off=False)
    observation.native_hosts(True)
    t.route('direct'); observation.idle('direct', status=None)
    began = time.monotonic(); deadline = began+610
    while time.monotonic()<deadline:
        state = t.state(); value = state.get('cooldowns') or {}
        cooldowns = value if isinstance(value, dict) else dict(zip(value[::2],value[1::2]))
        preferred = state['settings']['provider']
        providers = list(dict.fromkeys([preferred,'ipWhois','ipapiCo','ipapiIs']))
        provider = next((name for name in providers if name in ('ipWhois','ipapiCo','ipapiIs') and
                         cooldowns.get(name,0)+978307200 <= time.time()), None)
        if provider is not None: break
        time.sleep(5)
    else: raise AssertionError('No fixture provider became eligible')
    cooldown_wait = round(time.monotonic()-began,2)
    settings = state['settings']
    settings.update(provider=provider, providerPool=[provider], allowlist={'addresses':['203.0.113.10']})
    t.request('configure', settings=settings)
    observation.idle('direct')
    # Remove only the native fixture mapping before loading protected DNS.
    # Leaving the map in place redirects the engine's provider TLS request to
    # its own loopback instead of the closed SOCKS fixture.
    observation.native_hosts(False)
    t.route(mode, family); observation.idle(mode)
    result = dict(provider=provider, cooldown_wait_seconds=cooldown_wait)
    print(json.dumps(dict(packet_setup=result)), flush=True)
    return result


def fixture_events():
    config = observation.F
    request = urllib.request.Request('http://%s:%s' % (config.get('control_host',config['bridge4']), config['control_port']),
        headers={'Authorization':'Bearer '+config['token']})
    with urllib.request.urlopen(request, timeout=8) as response:
        assert response.status==200
        return json.load(response)['events']


def held_ingress(offsets, held_id, fixture_offset, provider, start_event='mimo_observation_started'):
    rows = service.events(offsets)
    lookups = {row.get('fields',{}).get('lookup') for row in rows if row['event']==start_event and
               row.get('fields',{}).get('attempt')==held_id} - {None, ''}
    if len(lookups)!=1: return None
    lookup = next(iter(lookups))
    if not any(row['event']=='lookup_http_request' and row.get('fields',{}).get('lookup')==lookup for row in rows): return None
    host = {'ipWhois':'ipwho.is','ipapiCo':'ipapi.co','ipapiIs':'api.ipapi.is'}[provider]
    received = [row for row in fixture_events()[fixture_offset:] if row['event']=='provider_http' and
                row.get('host')==host and row.get('family')==4]
    if not received: return None
    return dict(lookup=lookup, provider=provider, received_count=len(received),
                held_response_delay=12, subsequent_response_delay=0)


def execute(evidence_id):
    if ACTION == 'control':
        observation.native_hosts(True)
        t.route('direct'); observation.idle('direct')
        worker = packets.Traffic(evidence_id+'-observation-detector-control')
        try:
            time.sleep(3)
        finally:
            native = worker.finish()
        assert not any(thread.is_alive() for thread in worker.threads), 'Packet worker did not stop'
        return dict(name='detector-Direct-control', passed={p['family'] for p in native} == {4, 6},
                    native_attempts=len(native), families=sorted({p['family'] for p in native}),
                    packet_evidence_prefix=worker.label)
    family, mode, kind = sys.argv[3:6]
    setup = prepare(mode, family)
    name = 'packets-' + family + '-' + mode + '-' + kind
    if kind in ('engine-kill', 'engine-stall', 'native-route'):
        # Fault the real path while an otherwise non-blocking observation is
        # outstanding. Capture both tokens before the fault can invalidate one.
        previous = t.state()['routing']['exitObservations']['verification']['id']
        observation.fixture(provider_delay=12)
        fixture_offset = len(fixture_events())
        offsets = service.cursor()
        t.request('refresh')
        held = service.wait(lambda:t.state()['routing'].get('observation'),20)
        try:
            ingress = service.wait(lambda:held_ingress(offsets, held['id'], fixture_offset, setup['provider']),20)
            assert ingress['received_count']==1, 'Multiple provider requests entered fixture before fault'
        finally:
            # provider_reply records actual ingress before entering its sleep;
            # that sleep retains its argument. Restore prompt replies for every
            # fresh recovery request instead of testing at the client's 12s
            # request timeout for the whole fault/recovery sequence.
            observation.fixture(provider_delay=0)
        assert (t.state()['routing'].get('observation') or {}).get('id')==held['id'], 'Held observation completed before fault'
        try:
            packets.run_case(family, mode, kind)
        finally:
            observation.save(evidence_id+'-fault-events.json', service.events(offsets))
        outcome = packets.RESULTS[-1]
        artifacts = preserve_fault_evidence(family+'-'+mode+'-'+kind, evidence_id)
        quiet = service.cursor(); time.sleep(35)
        late = service.events(quiet); rows = service.events(offsets); final = t.state()
        observation.save(evidence_id+'-fault-events.json', rows)
        bad = [x['event'] for x in late if x['event'] in service.FORBIDDEN or x.get('level') == 'error']
        failures, fencing = fault_checks(rows, previous, held, final['routing'], outcome, mode, family, kind)
        if outcome['result'] != 'PASS': failures.append('packet fault checks failed')
        if bad: failures.append('unexpected settled work')
        if not observation.healthy_state(mode,'active','ready',final): failures.append('unhealthy recovered state')
        # The shared worker's free-form error can contain runtime state. Keep it
        # in private raw evidence; export only whether it was present.
        observation.save(evidence_id+'-fault-result.json', outcome)
        sanitized_outcome = {key:value for key,value in outcome.items() if key!='error'}
        sanitized_outcome['has_error'] = bool(outcome.get('error'))
        return dict(name=name, passed=not failures, failures=failures, packet_result=sanitized_outcome,
                    setup=setup, held_fixture_ingress=ingress, fault_fencing=fencing, late_errors=bad, settled_seconds=35,
                    evidence_files=artifacts+[evidence_id+'-fault-events.json', evidence_id+'-fault-result.json'])
    assert kind in ('refresh', 'provider-failure')
    observation.fixture(provider_delay=3, provider_status=503 if kind == 'provider-failure' else 200)
    worker = packets.Traffic(evidence_id+'-'+name)
    try:
        result = observation.observe(name, lambda:t.request('refresh'), mode,
                                     status='coolingDown' if kind == 'provider-failure' else 'ready')
    finally:
        native = worker.finish()
    assert not any(thread.is_alive() for thread in worker.threads), 'Packet worker did not stop'
    successes = {str(af) + '-' + k:sum(e['success'] for e in worker.events if e['family']==af and e['kind']==k)
                 for af in (4,6) for k in ('tcp','stream','udp','echo')}
    required = (4,6) if family == 'dual' else (4,)
    valid = not native and all(successes[str(af)+'-'+k] > 0 for af in required for k in ('tcp','stream','udp'))
    valid &= not successes['4-echo'] and not successes['6-echo']
    if family == 'ipv4':
        valid &= all(successes['6-'+k] == 0 for k in ('tcp','stream','udp'))
    return dict(name=name, passed=bool(valid), native_attempts=len(native), successes=successes,
                setup=setup,
                observation_evidence_id=result['evidence_id'], packet_evidence_prefix=worker.label,
                packet_types=sorted({e['kind'] for e in worker.events}), settled_seconds=35)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    evidence_id = uuid.uuid4().hex
    row = dict(name='detector-Direct-control' if ACTION=='control' else 'packets-'+'-'.join(sys.argv[3:6]), passed=False)
    cleanup_needed = False; cleanup = dict(attempted=False, passed=False)
    communication = GUICaseAudit(ROOT, service.cursor, service.events,
        observation.read_only_state_probe, observation.gui_process_ids,
        active_process_ids=observation.active_mimo_process_ids)
    try:
        communication.start()
        existing = t.run(['/sbin/pfctl','-a',packets.LAB,'-sr'])
        assert existing.returncode == 0 and not existing.stdout.strip(), 'Lab anchor not available'
        # Claim cleanup before installation: a failed install still gets its
        # owned empty anchor flushed. Never remove a pre-existing lab policy.
        cleanup_needed = True
        packets.containment()
        row = execute(evidence_id)
    except Exception as error:
        row.update(passed=False, harness_error=type(error).__name__)
        (ROOT/(evidence_id+'-harness-error.txt')).write_text(traceback.format_exc())
        row['private_error_file'] = evidence_id+'-harness-error.txt'
    finally:
        if cleanup_needed:
            cleanup['attempted'] = True
            try:
                flushed = t.run(['/sbin/pfctl','-a',packets.LAB,'-F','rules'])
                readback = t.run(['/sbin/pfctl','-a',packets.LAB,'-sr'])
                cleanup.update(flush_status=flushed.returncode, readback_status=readback.returncode,
                               empty=not readback.stdout.strip())
                cleanup['passed'] = flushed.returncode == 0 and readback.returncode == 0 and cleanup['empty']
            except Exception as error:
                cleanup['error'] = type(error).__name__
        row.update(evidence_id=evidence_id, lab_cleanup=cleanup)
        if not cleanup['passed']: row['passed'] = False
        try:
            proof = communication.finish(evidence_id)
            row['gui_communication'] = proof
            row['communication_disconnects'] = len(proof['event_audit']['disconnects'])
            if not proof['passed']:
                row['passed'] = False
                row.setdefault('failures', []).append('whole-case GUI communication audit failed')
        except Exception as error:
            row['passed'] = False
            row['communication_export_error'] = type(error).__name__
    # No PASS is exported until the containment policy is confirmed removed.
    record(row)


if __name__ == '__main__':
    main()
