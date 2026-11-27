#!/usr/bin/env python3
"""Pure latest-pending-mode and packet-boundary checks for new VM cases."""
from datetime import datetime


def epoch(row):
    return datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00')).timestamp()


def audit_queue(rows, replies, ids, base_revision, final_mode, delayed_intent=False):
    failures = []
    names = ('first_old', 'first_kept', 'barrier', 'last_old', 'last_kept')
    for name in names:
        if not ids.get(name): failures.append('missing_queue_identity_' + name)
    if len({ids.get(name) for name in names}) != len(names): failures.append('queue_identities_not_unique')
    for name, reply in replies.items():
        if reply.get('failure'): failures.append('request_rejected_' + name)
    queued = [row for row in rows if row['event'] == 'mimo_control_queued']
    resumed = [row for row in rows if row['event'] == 'mimo_control_resumed']
    replaced = [row for row in rows if row['event'] == 'mimo_control_superseded']
    commits = [row for row in rows if row['event'] == 'mimo_routing_configuration_committed']
    for name in names:
        if sum(row.get('fields', {}).get('request') == ids.get(name) for row in queued) != 1:
            failures.append('request_not_proven_queued_' + name)
    for old, kept in (('first_old', 'first_kept'), ('last_old', 'last_kept')):
        matching = [row for row in replaced if row.get('fields', {}).get('request') == ids.get(old)
                    and row.get('fields', {}).get('replacement') == ids.get(kept)]
        if len(matching) != 1: failures.append('missing_exact_supersession_' + old)
        if replies.get(old, {}).get('controlOutcome') != 'superseded': failures.append('wrong_superseded_reply_' + old)
        if any(row.get('fields', {}).get('request') == ids.get(old) for row in resumed + commits):
            failures.append('superseded_request_mutated_' + old)
    ordered = []; positions = []
    for name in ('first_kept', 'barrier', 'last_kept'):
        matches = [row for row in resumed if row.get('fields', {}).get('request') == ids.get(name)]
        if len(matches) != 1: failures.append('missing_admission_' + name)
        else:
            ordered.append(epoch(matches[0])); positions.append(rows.index(matches[0]))
    if len(ordered) != 3 or ordered != sorted(ordered) or positions != sorted(positions):
        failures.append('ordering_barrier_crossed')
    if any(row.get('fields', {}).get('request') == ids.get('barrier') for row in replaced):
        failures.append('allowlist_edit_superseded')
    for name, mode, revision in (('first_kept', 'global', base_revision + 1),
                                 ('last_kept', final_mode, base_revision + 3)):
        matching = [row for row in commits if row.get('fields', {}).get('request') == ids.get(name)
                    and row.get('fields', {}).get('mode') == mode
                    and str(row.get('fields', {}).get('revision')) == str(revision)]
        if len(matching) != 1: failures.append('wrong_committed_intent_' + name)
        if replies.get(name, {}).get('controlOutcome') != 'applied': failures.append('wrong_applied_reply_' + name)
    barrier_state = replies.get('barrier', {}).get('state') or {}
    if barrier_state.get('revision') != base_revision + 2: failures.append('allowlist_revision_not_preserved')
    if (barrier_state.get('settings') or {}).get('allowlist') != {'addresses': ['203.0.113.99']}:
        failures.append('allowlist_value_not_preserved')
    edits = [row for row in rows if row['event'] == 'shared_settings_changed'
             and str(row.get('fields', {}).get('revision')) == str(base_revision + 2)]
    if len(edits) != 1: failures.append('allowlist_commit_not_observed')
    elif any(row['event'] == 'mimo_traffic_opened' and epoch(row) >= epoch(edits[0]) for row in rows):
        failures.append('traffic_approved_after_denied_allowlist_commit')
    latest_state = replies.get('last_kept', {}).get('state') or {}
    if latest_state.get('revision') != base_revision + 3: failures.append('latest_revision_missing')
    if ((latest_state.get('routing') or {}).get('configuration') or {}).get('mode') != final_mode:
        failures.append('latest_mode_missing')
    if delayed_intent:
        late = ids.get('late_older')
        if not late or late in [ids.get(name) for name in names]: failures.append('late_intent_identity_missing')
        ignored = [row for row in rows if row['event'] == 'mimo_mode_intent_superseded'
            and row.get('fields', {}).get('request') == late
            and row.get('fields', {}).get('reason') == 'older_or_duplicate_sequence']
        if len(ignored) != 1 or replies.get('late_older', {}).get('controlOutcome') != 'superseded':
            failures.append('delayed_older_intent_not_rejected')
        if any(row.get('fields', {}).get('request') == late for row in queued + resumed + commits):
            failures.append('delayed_older_intent_entered_queue')
        if any(row.get('fields', {}).get('replacement') == late for row in replaced):
            failures.append('delayed_older_intent_replaced_newer')
    return {'passed': not failures, 'failures': failures, 'request_ids': ids,
            'base_revision': base_revision, 'final_revision': base_revision + 3,
            'queued_request_count': len(queued), 'expected_superseded_count': 2,
            'barrier_admission_epochs': ordered,
            'queued_epochs': {name: [epoch(row) for row in queued
                if row.get('fields', {}).get('request') == ids.get(name)] for name in names},
            'delayed_older_intent_checked': delayed_intent}


def audit_native_boundaries(rows, native, started, final_mode):
    """An admitted Direct transition may release; queued intents never do."""
    boundaries = [(started, 'protected', 'initial_active')]
    for row in rows:
        fields = row.get('fields', {})
        if epoch(row) < started: continue
        if row['event'] == 'mimo_supervisor_command_received' and fields.get('command') == 'direct':
            boundaries.append((epoch(row), 'direct', 'admitted_direct'))
        elif row['event'] == 'mimo_gate_closed' and str(fields.get('confirmed')).lower() == 'true':
            boundaries.append((epoch(row), 'protected', 'confirmed_close'))
    boundaries.sort()
    leaks, direct = [], []
    for packet in native:
        if packet['t'] < started: continue
        prior = [point for point in boundaries if point[0] <= packet['t']]
        if not prior or prior[-1][1] == 'protected': leaks.append(packet)
        else: direct.append(packet)
    final_closed = final_mode == 'direct' or boundaries[-1][1] == 'protected'
    return {'passed': not leaks and final_closed, 'protected_native_attempts': len(leaks),
            'authorized_direct_native_attempts': len(direct), 'boundaries': boundaries,
            'final_protected_closure_observed': final_closed if final_mode != 'direct' else None,
            'leak_samples': leaks[:10],
            'scope': 'zero native after confirmed closure; explicitly admitted Direct windows reported separately'}


def audit_traffic_precondition(events, start, end, family):
    rows = [row for row in events if start <= row['t'] <= end]
    failures = []
    families = (4, 6) if family == 'dual' else (4,)
    counts = {}
    for version in families:
        for protocol in ('tcp', 'udp'):
            matching = [row for row in rows if row['family'] == version and row['kind'] == protocol]
            count = sum(bool(row['success']) for row in matching)
            counts[str(version) + ':' + protocol] = count
            if not count: failures.append('missing_proxied_' + str(version) + '_' + protocol)
    for version in (4, 6):
        matching = [row for row in rows if row['family'] == version and row['kind'] == 'echo']
        if not any(row.get('send_attempted') for row in matching): failures.append('missing_ping_attempt_' + str(version))
        if any(row['success'] for row in matching): failures.append('public_ping_succeeded_' + str(version))
    # TUN intercepts port-53 A queries even when the client sends them over
    # IPv6. Those local DNS replies do not establish IPv6 application egress.
    # Exclude only these two known probe kinds; unknown successes still fail.
    dns_kinds = ('dns-udp', 'dns-tcp')
    dns_counts = {}
    for row in rows:
        if row['kind'] in dns_kinds and row['success']:
            key = str(row['family']) + ':' + row['kind']
            dns_counts[key] = dns_counts.get(key, 0) + 1
    if family == 'ipv4' and any(row['family'] == 6 and row['success']
                               and row['kind'] not in dns_kinds for row in rows):
        failures.append('IPv6_succeeded_under_IPv4_policy')
    return {'passed': not failures, 'failures': failures, 'proxied_successes': counts,
            'captured_dns_successes': dns_counts,
            'started_epoch': start, 'ended_epoch': end}


def audit_protected_precondition_native(native, start, end):
    rows = [row for row in native if start <= row['t'] <= end]
    return {'passed': not rows, 'native_attempts': len(rows),
            'started_epoch': start, 'ended_epoch': end,
            'failures': ['native_escape_during_protected_precondition'] if rows else []}


def current_component_evidence(sample):
    infrastructure = sample.get('infrastructure') or {}
    return not (infrastructure.get('pf') in ('healthy', 'released')
                and infrastructure.get('pfEvidenceCurrent') is False)


def audit_current_refresh(response, state, rows, requested_epoch, final_mode, pf):
    failures = []
    acknowledged = response.get('state', {}).get('manualRefresh') or {}
    manual = state.get('manualRefresh') or {}
    identity = acknowledged.get('id')
    if not identity or manual.get('id') != identity: failures.append('manual_identity_mismatch')
    requested = manual.get('requestedAt')
    finished = manual.get('finishedAt')
    if (not isinstance(requested, (float, int)) or requested != acknowledged.get('requestedAt')
            or requested + 978307200 < requested_epoch): failures.append('manual_request_not_current')
    if not isinstance(finished, (float, int)) or not isinstance(requested, (float, int)) or finished < requested:
        failures.append('manual_not_finished')
    if response.get('failure') or state.get('revision') != response.get('state', {}).get('revision'):
        failures.append('manual_revision_changed_or_rejected')
    routing = state.get('routing') or {}
    if routing.get('configuration', {}).get('mode') != final_mode or 'ready' not in state.get('status', {}):
        failures.append('manual_final_state_not_ready')
    current = [row for row in rows if epoch(row) >= requested_epoch]
    outcome = 'blocked' if final_mode == 'rule' else 'succeeded'
    typed_result = 'checkedBlocked' if final_mode == 'rule' else 'checkedAllowed'
    generation = manual.get('lifecycleGeneration')
    if manual.get('result') != typed_result: failures.append('manual_typed_result_mismatch')
    if not isinstance(generation, int) or generation != acknowledged.get('lifecycleGeneration'):
        failures.append('manual_lifecycle_identity_mismatch')
    terminals = [row for row in current if row['event'] == 'manual_refresh_finished']
    if (len(terminals) != 1 or terminals[0].get('fields', {}).get('outcome') != outcome
            or not isinstance(finished, (float, int))
            or abs(epoch(terminals[0]) - (finished + 978307200)) > .02):
        failures.append('manual_terminal_event_mismatch')
    starts = [row for row in current if row['event'] == 'lookup_started'
              and row.get('fields', {}).get('trigger') == 'manual']
    lookup = starts[0].get('fields', {}).get('lookup') if len(starts) == 1 else None
    successes = [row for row in current if row['event'] == 'lookup_succeeded'
                 and lookup and row.get('fields', {}).get('lookup') == lookup]
    http = [row for row in current if row['event'] == 'lookup_http_request'
            and lookup and row.get('fields', {}).get('lookup') == lookup]
    if not lookup or len(http) != 1 or len(successes) != 1:
        failures.append('current_successful_http_lookup_missing')
    elif (not terminals or epoch(successes[0]) > epoch(terminals[0])
          or epoch(http[0]) < epoch(starts[0])):
        failures.append('current_lookup_completion_order')
    if manual.get('lookupID') != lookup or not starts or starts[0].get('fields', {}).get('lifecycle_generation') != str(generation):
        failures.append('manual_lookup_owner_mismatch')
    bound = [row for row in current if row['event'] in ('manual_refresh_started', 'manual_refresh_joined')
             and row.get('fields', {}).get('request') == identity
             and row.get('fields', {}).get('generation') == str(generation)
             and row.get('fields', {}).get('lookup') == lookup]
    if len(bound) != 1: failures.append('manual_execution_binding_missing')
    if terminals:
        fields = terminals[0].get('fields', {})
        if (fields.get('request') != identity or fields.get('result') != typed_result
                or fields.get('generation') != str(generation) or fields.get('lookup') != lookup
                or fields.get('revision') != str(state.get('revision'))):
            failures.append('manual_terminal_owner_mismatch')
    if any(row['event'] in ('provider_failure_paused', 'lookup_failed', 'lookup_cancelled') for row in current):
        failures.append('current_provider_failure_pause_or_cancel')
    snapshot = state.get('snapshot') or {}
    checked = snapshot.get('checkedAt')
    if snapshot.get('ipAddress') != '203.0.113.10' or not isinstance(checked, (float, int)) or checked + 978307200 < requested_epoch:
        failures.append('fresh_expected_exit_missing')
    elif len(http) != 1 or len(successes) != 1 or not (epoch(http[0]) <= checked + 978307200 <= epoch(successes[0]) + .02):
        failures.append('snapshot_outside_final_http')
    if final_mode == 'rule':
        blocked_checked = routing.get('blockingIP', {}).get('checkedAt')
        if not isinstance(checked, (float, int)) or blocked_checked != checked:
            failures.append('blocked_ip_not_from_final_snapshot')
        if (manual.get('phase') != 'failed'
                or not manual.get('message', '').startswith('Exit IP checked. Outbound access remains blocked.')
                or routing.get('phase') != 'blocked'
                or routing.get('blockingIP', {}).get('address') != '203.0.113.10'
                or pf not in ('closed', 'probe')):
            failures.append('blocked_result_not_confirmed')
    elif manual.get('phase') != 'succeeded' or routing.get('phase') != 'active' or pf != 'empty':
        failures.append('direct_completion_not_confirmed')
    return {'passed': not failures, 'failures': failures, 'manual_id': identity,
            'requested_epoch': requested_epoch, 'manual_requested_at': requested,
            'manual_finished_at': finished, 'phase': manual.get('phase'),
            'expected_outcome': outcome, 'successful_lookup': lookup,
            'typed_result': manual.get('result'), 'lifecycle_generation': generation,
            'snapshot_checked_at': checked,
            'blocking_ip_checked_at': routing.get('blockingIP', {}).get('checkedAt'),
            'date_normalization': 'Swift Date seconds + 978307200 = Unix/log seconds'}


def audit_prior_manual_terminal(state, rows):
    """Every manual ticket accepted during the burst needs its own terminal."""
    failures = []
    queued = [row for row in rows if row['event'] == 'manual_refresh_queued']
    identities = [row.get('fields', {}).get('request') for row in queued]
    if not identities or any(not item for item in identities) or len(set(identities)) != len(identities):
        failures.append('accepted_manual_identities_missing')
    terminals = []
    allowed = {'checkedAllowed': 'succeeded', 'checkedBlocked': 'blocked',
               'superseded': 'superseded', 'cancelled': 'cancelled'}
    for queue in queued:
        fields = queue.get('fields', {}); identity = fields.get('request')
        matches = [row for row in rows if row['event'] == 'manual_refresh_finished'
                   and row.get('fields', {}).get('request') == identity]
        if len(matches) != 1:
            failures.append('manual_terminal_missing_or_duplicate'); continue
        terminal = matches[0]; end = terminal.get('fields', {})
        if (end.get('generation') != fields.get('generation') or not fields.get('generation')
                or epoch(terminal) < epoch(queue)
                or end.get('result') not in allowed or end.get('outcome') != allowed.get(end.get('result'))):
            failures.append('manual_terminal_not_owned')
        if end.get('result') in ('checkedAllowed', 'checkedBlocked'):
            if not end.get('lookup') or not any(row['event'] == 'lookup_succeeded'
                    and row.get('fields', {}).get('lookup') == end['lookup']
                    and epoch(queue) <= epoch(row) <= epoch(terminal) for row in rows):
                failures.append('manual_checked_without_successful_lookup')
        terminals.append({'id': identity, 'generation': end.get('generation'), 'result': end.get('result'),
                          'queued_epoch': epoch(queue), 'finished_epoch': epoch(terminal)})
    manual = state.get('manualRefresh') or {}
    current = [row for row in rows if row['event'] == 'manual_refresh_finished'
               and row.get('fields', {}).get('request') == manual.get('id')]
    finished = manual.get('finishedAt')
    if (manual.get('id') not in identities or len(current) != 1
            or manual.get('result') not in allowed or manual.get('phase') in ('queued', 'checking')
            or not isinstance(finished, (float, int))):
        failures.append('displayed_prior_manual_not_terminal')
    elif (current[0].get('fields', {}).get('result') != manual.get('result')
          or current[0].get('fields', {}).get('generation') != str(manual.get('lifecycleGeneration'))
          or abs(epoch(current[0]) - (finished + 978307200)) > .02):
        failures.append('displayed_prior_manual_owner_mismatch')
    return {'passed': not failures, 'failures': failures, 'accepted_manual_count': len(identities),
            'terminal_results': terminals, 'displayed_id': manual.get('id'), 'displayed_result': manual.get('result')}
