"""Read-only queue evidence synchronization; the production oracle is unchanged."""
from collections import Counter
import json
import time
from v3_rapid_policy_oracle import audit_queue, epoch

OWNED_EVENTS = frozenset(('mimo_control_queued', 'mimo_control_resumed',
    'mimo_control_superseded', 'mimo_mode_intent_superseded',
    'mimo_routing_configuration_committed'))


def audit_queue_window(rows, replies, ids, base_revision, final_mode, window_start, window_end):
    """Keep unrelated activity in-window; owned late records are faults, not proof."""
    assert window_start <= window_end
    owned = set(ids.values())
    scoped, outside = [], []
    for row in rows:
        fields = row.get('fields', {})
        belongs = (row['event'] in OWNED_EVENTS and
                   (fields.get('request') in owned or fields.get('replacement') in owned))
        stamp = epoch(row)
        if window_start <= stamp <= window_end:
            scoped.append(row)
        elif belongs:
            outside.append({'event': row['event'], 'timestamp': row['timestamp'],
                            'request': fields.get('request'), 'replacement': fields.get('replacement'),
                            'boundary': 'before' if stamp < window_start else 'after'})
    proof = audit_queue(scoped, replies, ids, base_revision, final_mode, delayed_intent=True)
    # The existing oracle checks exact expected commits; reject a second wrong
    # commit for that same request too, rather than counting only the good one.
    for name in ('first_kept', 'last_kept'):
        count = sum(row['event'] == 'mimo_routing_configuration_committed' and
                    row.get('fields', {}).get('request') == ids.get(name) for row in scoped)
        if count > 1: proof['failures'].append('duplicate_owned_commit_' + name)
    if any(row['boundary'] == 'before' for row in outside):
        proof['failures'].append('owned_queue_record_before_operation')
    if any(row['boundary'] == 'after' for row in outside):
        proof['failures'].append('owned_queue_record_after_rpc_join')
    proof['passed'] = not proof['failures']
    proof['owned_records_outside_window'] = outside
    proof['operation_window'] = [window_start, window_end]
    return proof


def collect_queue_records(read_rows, replies, ids, base_revision, final_mode, *,
                          window_start, window_end, timeout=3.0, interval=.02,
                          clock=time.monotonic, sleep=time.sleep):
    """Wait only for absent persisted commits, never for a wrong verdict to improve.

    Repeated snapshots are accumulated without losing previously seen wrong or
    duplicate records. Late owned records are retained and fail even outside the
    operation window. Call audit_queue_window again at case completion to catch
    owned records persisted after this collector returned.
    """
    assert 0 < timeout <= 5 and 0 < interval <= timeout
    deadline = clock() + timeout
    initial, observed, counts, polls = None, [], Counter(), 0
    while True:
        snapshot = read_rows()
        if initial is None: initial = snapshot
        polls += 1
        current = Counter(json.dumps(row, sort_keys=True, separators=(',', ':')) for row in snapshot)
        for encoded, count in current.items():
            for _ in range(max(0, count - counts[encoded])): observed.append(json.loads(encoded))
            counts[encoded] = max(counts[encoded], count)
        # Keep each process's recorded order even if its wall clock moved.
        # Cross-process ordering remains timestamp-based inside audit_queue.
        observed.sort(key=lambda row: (row.get('fields', {}).get('pid', ''),
            int(row.get('fields', {}).get('recordSequence', '0')), epoch(row)))
        proof = audit_queue_window(observed, replies, ids, base_revision, final_mode, window_start, window_end)
        scoped = [row for row in observed if window_start <= epoch(row) <= window_end]
        absent = set()
        for name in ('first_kept', 'last_kept'):
            if not any(row['event'] == 'mimo_routing_configuration_committed' and
                       row.get('fields', {}).get('request') == ids.get(name) for row in scoped):
                absent.add('wrong_committed_intent_' + name)
        if not any(row['event'] == 'shared_settings_changed' and
                   str(row.get('fields', {}).get('revision')) == str(base_revision + 2) for row in scoped):
            absent.add('allowlist_commit_not_observed')
        hard = set(proof['failures']) - absent
        timed_out = not proof['passed'] and not hard and clock() >= deadline
        if proof['passed'] or hard or timed_out:
            return {'proof': proof, 'initial_rows': initial, 'final_rows': observed,
                    'polls': polls, 'timed_out': timed_out,
                    'missing_terminal_failures': sorted(set(proof['failures']) & absent),
                    'window_start': window_start, 'window_end': window_end}
        sleep(min(interval, max(0, deadline - clock())))
