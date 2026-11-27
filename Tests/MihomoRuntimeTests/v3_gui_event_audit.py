"""Pure whole-case GUI event audit shared by installed test harnesses."""
import datetime
import re
import threading
import time


def event_order(row):
    sequence = str(row.get('fields', {}).get('recordSequence', '0'))
    return row.get('timestamp', ''), int(sequence) if sequence.isdigit() else 0


def latest_live_segments(cursor, process_ids):
    """Old dead-process segments are outside a new case's byte coverage."""
    live = {str(pid) for pid in process_ids}
    latest = {}
    for path in cursor:
        match = re.fullmatch(r'runtime-.+-(\d+)-[0-9A-Fa-f-]{36}\.jsonl', path.rsplit('/',1)[-1])
        if match and match[1] in live:
            if path > latest.get(match[1], ''):
                latest[match[1]] = path
    return {path:cursor[path] for path in latest.values()}


def connected_checkpoint(rows, process_ids):
    """Require an existing connection receipt for the one currently live GUI."""
    if len(process_ids) != 1:
        raise AssertionError('Expected one live GUI process')
    pid = str(process_ids[0])
    connection_events = sorted((r for r in rows
        if r.get('fields', {}).get('processRole') == 'gui'
        and r['fields'].get('pid') == pid
        and r.get('event') in {'daemon_client_connected', 'daemon_client_connecting',
            'daemon_client_disconnected', 'daemon_client_stopped', 'process_entered', 'app_terminating'}),
        key=event_order)
    if not connection_events or connection_events[-1]['event'] != 'daemon_client_connected':
        raise AssertionError('Current GUI connection has no retained connected receipt')
    last = connection_events[-1]
    return dict(pid=pid, connected_at=last.get('timestamp'),
                generation=last['fields'].get('generation'))


class GUICaseAudit:
    """Retain all case events and independently sample bounded read-only RPCs.

    Callbacks are injected so local controls never touch a VM. read_state must
    enforce its own three-second subprocess deadline. This observes service
    responsiveness and the existing GUI channel; it is not a native UI click.
    """
    def __init__(self, root, cursor, events, read_state, process_ids, interval=1, active_process_ids=None):
        self.root, self.cursor, self.events = root, cursor, events
        self.read_state, self.process_ids = read_state, process_ids
        self.interval = interval
        self.active_process_ids = active_process_ids or process_ids
        self.offsets = None
        self.checkpoint = None
        self.samples = []
        self.done = threading.Event()
        self.worker = None
        self.result = None
        self.required_segments = {}
        self.segment_loss = False

    def track_cursor(self):
        current = self.cursor()
        for path, identity in current.items():
            initial = (self.offsets or {}).get(path)
            if initial is None or identity[0] != initial[0] or identity[1] > initial[1]:
                self.required_segments.setdefault(path, (identity[0], 0 if initial is None else initial[1]))
        for path, previous in list(self.required_segments.items()):
            now = current.get(path)
            if now is None or now[0] != previous[0] or now[1] < previous[1]:
                self.segment_loss = True
            else:
                self.required_segments[path] = now

    def start(self):
        self.offsets = self.cursor()  # before setup or the connection preflight
        self.started = time.monotonic()
        self.checkpoint = connected_checkpoint(self.events({}), self.process_ids())
        self.required_segments = latest_live_segments(self.offsets, self.active_process_ids())
        if not latest_live_segments(self.offsets, [self.checkpoint['pid']]):
            raise AssertionError('Live GUI log segment missing from cursor')
        self.sample()
        if not self.samples[-1]['passed']:
            raise AssertionError('Read-only GUI/service preflight failed')
        self.worker = threading.Thread(target=self.work, daemon=True)
        self.worker.start()
        return self

    def sample(self):
        started = time.monotonic()
        item = dict(started_elapsed=round(started-self.started, 6),
                    started_epoch=time.time(), passed=False)
        try:
            self.read_state()
            item['rpc_duration_seconds'] = round(time.monotonic()-started, 6)
            pids = [str(pid) for pid in self.process_ids()]
            item['process_ids'] = pids
            item['passed'] = pids == [self.checkpoint['pid']]
            if item['rpc_duration_seconds'] >= 3:
                item['passed'] = False
            self.track_cursor()
        except Exception as error:
            item['passed'] = False
            item['error_class'] = type(error).__name__
        item['duration_seconds'] = round(time.monotonic()-started, 6)
        self.samples.append(item)

    def work(self):
        while not self.done.wait(self.interval):
            self.sample()

    def finish(self, evidence_id):
        if self.result is not None:
            return self.result
        self.done.set()
        if self.worker:
            self.worker.join(6)  # Three-second RPC plus two-second PID query.
        self.track_cursor()
        rows = self.events(self.offsets or {})
        self.track_cursor()
        covered = bool(self.required_segments) and not self.segment_loss
        live = bool(self.checkpoint and self.samples and all(s['passed'] for s in self.samples))
        audit = audit_gui_events(rows, expected_pid=self.checkpoint['pid'] if self.checkpoint else None,
                                 allow_quiet=covered and live)
        failures = []
        if not self.checkpoint:
            failures.append('missing_connected_GUI_checkpoint')
        if not self.samples or any(s['passed'] is not True for s in self.samples):
            failures.append('read_only_state_or_GUI_identity_sample_failed')
        if self.worker and self.worker.is_alive():
            failures.append('read_only_sampler_did_not_finish')
        if not audit['passed']:
            failures.append('GUI_communication_or_lifecycle_failure')
        if not covered:
            failures.append('log_cursor_coverage_unavailable')
        if any(b['started_elapsed']-a['started_elapsed'] > self.interval+5.5
               for a,b in zip(self.samples, self.samples[1:])):
            failures.append('read_only_sampling_gap')
        self.result = dict(passed=not failures, checkpoint=self.checkpoint,
            event_audit=audit, state_samples=list(self.samples), failures=failures,
            log_cursor_coverage=covered, quiet_GUI_covered=not audit['event_count'] and covered and live,
            required_segment_count=len(self.required_segments),
            historical_segments_outside_coverage=len(set(self.offsets or {})-set(self.required_segments)),
            method='retained GUI connection/events and bounded read-only core state RPC',
            sampling_interval_seconds=self.interval, rpc_deadline_seconds=3)
        import json
        (self.root/(evidence_id+'-all-raw-events.json')).write_text(json.dumps(rows, indent=2)+'\n')
        (self.root/(evidence_id+'-communication.json')).write_text(json.dumps(self.result, indent=2)+'\n')
        return self.result


def audit_gui_events(rows, expected_pid=None, allow_quiet=False):
    """Rapid operations must retain the already-running GUI's service channel."""
    gui=sorted((row for row in rows if row.get('fields',{}).get('processRole')=='gui'),
               key=event_order)
    pids=sorted({row['fields'].get('pid') for row in gui if row['fields'].get('pid')})
    disconnects=[];lifecycle=[]
    for row in gui:
        fields=row['fields']
        metadata={'event':row['event'],'timestamp':row.get('timestamp'),
                  'pid':fields.get('pid'),'generation':fields.get('generation'),
                  'source':fields.get('source')}
        if row['event']=='daemon_client_disconnected':
            metadata.update(reconnected_at=None,recovery_seconds=None)
            disconnects.append(metadata)
        if row['event']=='daemon_client_connected':
            for disconnected in disconnects:
                if disconnected['pid']==fields.get('pid') and disconnected['reconnected_at'] is None:
                    disconnected['reconnected_at']=row.get('timestamp')
                    try:
                        start=datetime.datetime.fromisoformat(disconnected['timestamp'].replace('Z','+00:00'))
                        end=datetime.datetime.fromisoformat(row['timestamp'].replace('Z','+00:00'))
                        disconnected['recovery_seconds']=round((end-start).total_seconds(),3)
                    except (TypeError,ValueError):pass
        if row['event'] in ('daemon_client_stopped','app_terminating','process_entered'):
            lifecycle.append(metadata)
    identity_ok = (bool(gui) and len(pids)==1 and (expected_pid is None or pids == [str(expected_pid)])) or (
        not gui and allow_quiet and expected_pid is not None)
    return {'passed':identity_ok and not disconnects and not lifecycle,
            'event_count':len(gui),'process_ids':pids,'disconnects':disconnects,'lifecycle':lifecycle}
