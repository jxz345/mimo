#!/usr/bin/env python3
"""Portable deterministic queue-log visibility controls; no VM or network access."""
import copy
from datetime import datetime, timezone
import json
import sys
sys.dont_write_bytecode = True
import v3_rapid_policy_oracle as oracle
import v3_queue_log_visibility as visibility
START = 1000.0; END = 1030.0
IDS = {name: name for name in ('first_old','first_kept','barrier','last_old','last_kept','late_older')}

def row(event, second, **fields):
    return {'event':event,'timestamp':datetime.fromtimestamp(second,timezone.utc).isoformat(),
            'fields':{'pid':'11','recordSequence':str(int(second*10)),**fields}}

def fixture():
    rows = [row('mimo_control_queued',1001+i,request=name,command='configureRouting' if name!='barrier' else 'configure')
            for i,name in enumerate(('first_old','first_kept','barrier','last_old','last_kept'))]
    rows += [row('mimo_control_superseded',1006,request='first_old',replacement='first_kept'),
             row('mimo_control_superseded',1007,request='last_old',replacement='last_kept'),
             row('mimo_mode_intent_superseded',1008,request='late_older',reason='older_or_duplicate_sequence'),
             row('mimo_control_resumed',1010,request='first_kept'),
             row('mimo_routing_configuration_committed',1011,request='first_kept',mode='global',revision='101'),
             row('mimo_control_resumed',1012,request='barrier'),
             row('shared_settings_changed',1013,revision='102'),
             row('mimo_control_resumed',1014,request='last_kept'),
             row('mimo_routing_configuration_committed',1015,request='last_kept',mode='rule',revision='103')]
    replies = {name:{'controlOutcome':'superseded'} for name in ('first_old','last_old','late_older')}
    replies['first_kept']={'controlOutcome':'applied','state':{'revision':101}}
    replies['barrier']={'state':{'revision':102,'settings':{'allowlist':{'addresses':['203.0.113.99']}}}}
    replies['last_kept']={'controlOutcome':'applied','state':{'revision':103,'routing':{'configuration':{'mode':'rule'}}}}
    return rows,replies

class Clock:
    def __init__(self): self.value=0.0
    def now(self): return self.value
    def sleep(self,seconds): self.value+=seconds

class Reader:
    def __init__(self, snapshots): self.snapshots=snapshots; self.calls=0
    def __call__(self):
        value=self.snapshots[min(self.calls,len(self.snapshots)-1)];self.calls+=1
        return copy.deepcopy(value)

def execute(name, function, module=None):
    rows,replies=fixture();clock=Clock()
    snapshots=[rows]; expected=True
    if name=='delayed-terminal-persistence': snapshots=[rows[:-1],rows]
    elif name=='wrong-terminal-is-fatal':
        wrong=copy.deepcopy(rows);wrong[-1]['fields']['mode']='direct';snapshots=[wrong,rows];expected=False
    elif name=='duplicate-terminal-is-fatal': snapshots=[rows+[copy.deepcopy(rows[-1])]];expected=False
    elif name=='correct-plus-wrong-owned-terminal-is-fatal':
        wrong=copy.deepcopy(rows[-1]);wrong['fields']['mode']='direct';wrong['fields']['recordSequence']='160';snapshots=[rows+[wrong]];expected=False
    elif name=='missing-terminal-times-out': snapshots=[rows[:-1]];expected=False
    elif name=='post-window-terminal-cannot-qualify':
        late=copy.deepcopy(rows);late[-1]['timestamp']=datetime.fromtimestamp(END+1,timezone.utc).isoformat();snapshots=[late];expected=False
    elif name=='hard-error-not-hidden-while-terminal-missing':
        wrong=copy.deepcopy(rows[:-1]);wrong[9]['fields']['mode']='direct';snapshots=[wrong,rows];expected=False
    elif name=='late-duplicate-final-audit-is-fatal':
        assert module is not None
        initial=function(Reader([rows]),replies,IDS,100,'rule',window_start=START,window_end=END,clock=clock.now,sleep=clock.sleep,timeout=.1,interval=.02)
        assert initial['proof']['passed']
        late=copy.deepcopy(rows[-1]);late['timestamp']=datetime.fromtimestamp(END+1,timezone.utc).isoformat();late['fields']['recordSequence']='310'
        final=module.audit_queue_window(rows+[late],replies,IDS,100,'rule',START,END)
        assert not final['passed'] and 'owned_queue_record_after_rpc_join' in final['failures']
        return
    elif name=='unrelated-post-window-activity-not-borrowed':
        unrelated=row('mimo_routing_configuration_committed',END+1,request='another-case',mode='direct',revision='200')
        snapshots=[rows+[unrelated]]
    elif name!='complete-input': raise AssertionError('Unknown control')
    reader=Reader(snapshots)
    result=function(reader,replies,IDS,100,'rule',window_start=START,window_end=END,clock=clock.now,sleep=clock.sleep,timeout=.1,interval=.02)
    assert result['proof']['passed']==expected, result['proof']['failures']
    if name=='delayed-terminal-persistence':
        assert len(result['initial_rows'])==len(rows)-1 and len(result['final_rows'])==len(rows) and reader.calls==2
    if name in ('wrong-terminal-is-fatal','duplicate-terminal-is-fatal','hard-error-not-hidden-while-terminal-missing'):
        assert reader.calls==1, 'Hard failure was hidden by waiting for a later snapshot'
    if name=='missing-terminal-times-out': assert result['timed_out'] and clock.now()<=.100001
    if name=='post-window-terminal-cannot-qualify': assert 'owned_queue_record_after_rpc_join' in result['proof']['failures']

names=['delayed-terminal-persistence','complete-input','wrong-terminal-is-fatal','duplicate-terminal-is-fatal',
       'missing-terminal-times-out','post-window-terminal-cannot-qualify','hard-error-not-hidden-while-terminal-missing',
       'late-duplicate-final-audit-is-fatal','unrelated-post-window-activity-not-borrowed','correct-plus-wrong-owned-terminal-is-fatal']
def main():
    selected = sys.argv[1:] or names
    assert set(selected).issubset(names), 'Unknown support control'
    results = []
    for name in selected:
        try:
            execute(name, visibility.collect_queue_records, visibility)
            row = {'name': name, 'passed': True, 'failures': []}
        except Exception as error:
            row = {'name': name, 'passed': False, 'failures': [str(error)]}
        results.append(row)
        print(('PASS' if row['passed'] else 'FAIL') + ': ' + name +
              (' ' + str(row['failures']) if not row['passed'] else ''))
    print(json.dumps(results, indent=2))
    print(f"Support controls: {sum(row['passed'] for row in results)}/{len(results)}")
    return 0 if all(row['passed'] for row in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
