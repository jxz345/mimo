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
    assert end('rule_generation')<=begin('rule_validation'), 'Validation preceded generation'
    assert end('rule_validation')<=begin('install_probe_policy'), 'Installation preceded syntax validation'
    assert end('confirmed_close')<=begin('install_probe_policy'), 'Installation preceded confirmed blocking'
    for job in ('connection_cleanup','profile_preflight','install_probe_policy'):
        assert end(job)<=begin('permit_private_probe'), job+' was unfinished when private probing was permitted'
    assert end('permit_private_probe')<=begin('exit_ip'), 'IP lookup preceded private permission'
    assert begin('rule_generation')<begin('install_probe_policy'), 'Rule generation stayed inside installation'
    assert begin('critical_checks')<first, 'Inspection waited until after the first join'
    return {'ruleValidationBlockingOverlapMS':max(0,min(end('rule_validation'),end('barrier_and_confirmation'))-max(begin('rule_validation'),begin('barrier_and_confirmation'))),
            'installationAfterBlockMS':begin('install_probe_policy')-end('confirmed_close'),
            'permissionToIPMS':begin('exit_ip')-end('permit_private_probe'),
            'openingJoinMS':int(spans['opening_join']['duration_ms']),
            'cleanupBlockOverlapMS':max(0,min(end('connection_cleanup'),end('barrier_and_confirmation'))-max(begin('connection_cleanup'),begin('barrier_and_confirmation')))}

if __name__=='__main__':
    results=[]
    for path in sys.argv[1:]:
        report=json.load(open(path))
        for trial in report['trials']:results.append(verify_trial(trial))
    assert results and any(r['ruleValidationBlockingOverlapMS']>0 for r in results), 'No measured rule-validation/blocking overlap'
    print(json.dumps({'success':True,'trials':len(results),'firstJoinPrerequisitesBeforeIP':True,'secondJoinPrerequisitesBeforeOpen':True,'measuredRuleValidationBlockingOverlap':True,'installationAfterBlockMS':[r['installationAfterBlockMS'] for r in results],'permissionToIPMS':[r['permissionToIPMS'] for r in results],'openingJoinMS':[r['openingJoinMS'] for r in results]},indent=2))
