#!/usr/bin/env python3
"""Check the two joins using actual installed-process system-uptime spans."""
import json,sys

def verify_trial(trial):
    spans={s['stage']:s for s in trial['stages']}
    begin=lambda name:int(spans[name]['start_uptime_ms'])
    end=lambda name:int(spans[name]['end_uptime_ms'])
    first=end('private_probe_join')
    for job in ('confirmed_close','connection_cleanup','profile_preflight','probe_policy'):
        assert end(job)<=first, job+' was unfinished at the private-probe join'
    assert first<=begin('exit_ip'), 'IP lookup preceded its prerequisites'
    assert end('exit_ip')<=end('opening_join'), 'Opening join preceded the new IP result'
    for job in ('critical_checks','installation_inspection'):
        assert end(job)<=end('opening_join'), job+' was unfinished at the opening join'
    assert end('opening_join')<=begin('open_gate'), 'PF opening preceded the second join'
    assert begin('connection_cleanup')<end('confirmed_close'), 'Cleanup was serialized behind PF confirmation'
    assert end('profile_preflight')<end('probe_policy'), 'Profile reuse was serialized behind probe setup'
    assert begin('critical_checks')<first, 'Inspection waited until after the first join'
    return {'openingJoinMS':int(spans['opening_join']['duration_ms']),
            'cleanupBlockOverlapMS':max(0,min(end('connection_cleanup'),end('barrier_and_confirmation'))-max(begin('connection_cleanup'),begin('barrier_and_confirmation')))}

if __name__=='__main__':
    results=[]
    for path in sys.argv[1:]:
        report=json.load(open(path))
        for trial in report['trials']:results.append(verify_trial(trial))
    assert results and any(r['cleanupBlockOverlapMS']>0 for r in results), 'No measured cleanup/blocking overlap'
    print(json.dumps({'success':True,'trials':len(results),'firstJoinPrerequisitesBeforeIP':True,'secondJoinPrerequisitesBeforeOpen':True,'measuredCleanupBlockingOverlap':True,'openingJoinMS':[r['openingJoinMS'] for r in results]},indent=2))
