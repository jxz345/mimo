#!/usr/bin/env python3
"""New targeted-oracle and bounded fixture controls. Never contacts a VM."""
import copy
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

from v3_bounded_pf_hold import hold, validated_descriptor
from v3_health_trace import HealthTrace, guard_health, state_health, wait_for_phase
from v3_rapid_policy_oracle import audit_queue, audit_native_boundaries, audit_traffic_precondition, current_component_evidence
import v3_rapid_policy_oracle as rapid_oracle


def event(name, moment, **fields):
    return {'event': name, 'timestamp': datetime.fromtimestamp(moment, timezone.utc).isoformat(), 'fields': fields}


def healthy_state():
    return {'revision': 9, 'status': {'ready': {}}, 'routing': {
        'configuration': {'mode': 'rule', 'networkFamily': 'dual'}, 'phase': 'active', 'effectiveMode': 'rule',
        'heartbeatHealth': 'healthy', 'heartbeatCheckedAt': time.time()-978307200,
        'infrastructure': {'pf': 'healthy', 'launchd': 'healthy', 'checkedAt': time.time()-978307200,
            'pfCheckedAt': time.time()-978307200, 'launchdCheckedAt': time.time()-978307200,
            'inspection': {'outcome': 'completed', 'isCurrent': True}}, 'services': []}}


class QueueOracle(unittest.TestCase):
    def setUp(self):
        self.ids = {key: key+'-id' for key in ('first_old','first_kept','barrier','last_old','last_kept')}
        self.rows = [event('mimo_control_queued', index+1, request=value, command='configure')
                     for index,value in enumerate(self.ids.values())]
        for old,new in (('first_old','first_kept'),('last_old','last_kept')):
            self.rows.append(event('mimo_control_superseded',6,request=self.ids[old],replacement=self.ids[new]))
        for index,key in enumerate(('first_kept','barrier','last_kept')):
            self.rows.append(event('mimo_control_resumed',10+index,request=self.ids[key]))
        self.rows += [event('mimo_routing_configuration_committed',10.2,request=self.ids['first_kept'],mode='global',revision=11),
            event('shared_settings_changed',11.2,revision=12),
            event('mimo_routing_configuration_committed',12.2,request=self.ids['last_kept'],mode='rule',revision=13)]
        self.replies = {key:{'controlOutcome':'superseded'} for key in ('first_old','last_old')}
        self.replies.update(first_kept={'controlOutcome':'applied'},
            barrier={'state':{'revision':12,'settings':{'allowlist':{'addresses':['203.0.113.99']}}}},
            last_kept={'controlOutcome':'applied','state':{'revision':13,'routing':{'configuration':{'mode':'rule'}}}})

    def audit(self): return audit_queue(self.rows,self.replies,self.ids,10,'rule')
    def testExactQueuedSupersessionAndRevisionBarrierPass(self): self.assertTrue(self.audit()['passed'])
    def testMissingQueuedRequestFails(self):
        self.rows.pop(0); self.assertFalse(self.audit()['passed'])
    def testSupersededRequestAdmissionFails(self):
        self.rows.append(event('mimo_control_resumed',7,request=self.ids['first_old'])); self.assertFalse(self.audit()['passed'])
    def testSupersededRequestCommitFails(self):
        self.rows.append(event('mimo_routing_configuration_committed',8,request=self.ids['last_old'])); self.assertFalse(self.audit()['passed'])
    def testWrongReplacementFails(self):
        next(row for row in self.rows if row['event']=='mimo_control_superseded')['fields']['replacement']='unrelated'
        self.assertFalse(self.audit()['passed'])
    def testOrderingBarrierCannotBeSuperseded(self):
        self.rows.append(event('mimo_control_superseded',9,request=self.ids['barrier'],replacement=self.ids['last_kept']))
        self.assertFalse(self.audit()['passed'])
    def testConflictedAllowlistEditCannotPass(self):
        self.replies['barrier']={'failure':'conflict'}; self.assertFalse(self.audit()['passed'])
    def testChangedAllowlistCannotPass(self):
        self.replies['barrier']['state']['settings']['allowlist']['addresses']=[]; self.assertFalse(self.audit()['passed'])
    def testWrongRevisionCannotPass(self):
        self.replies['barrier']['state']['revision']=13; self.assertFalse(self.audit()['passed'])
    def testSameTimestampOrderingStillChecked(self):
        rows=[row for row in self.rows if row['event']=='mimo_control_resumed']
        for row in rows: row['timestamp']=event('x',10)['timestamp']
        first,last=self.rows.index(rows[0]),self.rows.index(rows[-1])
        self.rows[first],self.rows[last]=self.rows[last],self.rows[first]
        self.assertFalse(self.audit()['passed'])
    def testLateApprovalAfterDeniedEditFails(self):
        self.rows.append(event('mimo_traffic_opened',12,attempt='old')); self.assertFalse(self.audit()['passed'])


class PacketOracle(unittest.TestCase):
    def testAdmittedDirectWindowIsReported(self):
        rows=[event('mimo_supervisor_command_received',2,command='direct'),event('mimo_gate_closed',4,confirmed='true')]
        result=audit_native_boundaries(rows,[{'t':3,'family':4}],1,'rule')
        self.assertTrue(result['passed']);self.assertEqual(result['authorized_direct_native_attempts'],1)
    def testQueuedDirectDoesNotAuthorizeNativePackets(self):
        result=audit_native_boundaries([event('mimo_control_queued',2,command='configureRouting')],[{'t':3,'family':4}],1,'rule')
        self.assertFalse(result['passed'])
    def testNativeAttemptAfterConfirmedClosureFails(self):
        rows=[event('mimo_supervisor_command_received',2,command='direct'),event('mimo_gate_closed',4,confirmed='true')]
        self.assertFalse(audit_native_boundaries(rows,[{'t':4.1,'family':6}],1,'rule')['passed'])
    def testMissingFinalClosureCannotPassProtectedCase(self):
        self.assertFalse(audit_native_boundaries([event('mimo_supervisor_command_received',2,command='direct')],[],1,'rule')['passed'])
    def testDualStackPositiveTrafficAndBlockedEchoPass(self):
        rows=[{'t':2,'family':family,'kind':kind,'success':kind!='echo','send_attempted':kind=='echo'}
            for family in (4,6) for kind in ('tcp','udp','echo')]
        self.assertTrue(audit_traffic_precondition(rows,1,3,'dual')['passed'])
    def testDeadTrafficCannotPass(self): self.assertFalse(audit_traffic_precondition([],1,3,'dual')['passed'])
    def testPublicPingSuccessCannotPass(self):
        rows=[{'t':2,'family':family,'kind':kind,'success':True,'send_attempted':True}
            for family in (4,6) for kind in ('tcp','udp','echo')]
        self.assertFalse(audit_traffic_precondition(rows,1,3,'dual')['passed'])


class DelayedIntentOracle(unittest.TestCase):
    def setUp(self):
        self.base=QueueOracle();self.base.setUp()
        self.base.ids['late_older']='late-id'
        self.base.replies['late_older']={'controlOutcome':'superseded'}
        self.base.rows.append(event('mimo_mode_intent_superseded',7,request='late-id',reason='older_or_duplicate_sequence'))
    def audit(self):return audit_queue(self.base.rows,self.base.replies,self.base.ids,10,'rule',True)
    def testExactIgnoredOldSequenceDoesNotReplacePendingLatest(self):self.assertTrue(self.audit()['passed'])
    def testDelayedOlderRequestCannotEnterQueue(self):
        self.base.rows.append(event('mimo_control_queued',8,request='late-id'))
        self.assertFalse(self.audit()['passed'])
    def testDelayedOlderRequestCannotReplacePendingLatest(self):
        self.base.rows.append(event('mimo_control_superseded',8,request=self.base.ids['last_kept'],replacement='late-id'))
        self.assertFalse(self.audit()['passed'])


class CapturedDNSPrecondition(unittest.TestCase):
    def rows(self):
        return [{'t':2,'family':version,'kind':kind,'success':version==4 and kind!='echo',
                 'send_attempted':kind=='echo'}
                for version in (4,6) for kind in ('tcp','udp','echo')]
    def testCapturedIPv6DnsRepliesAreNotApplicationEgress(self):
        rows=self.rows()+[{'t':2,'family':6,'kind':kind,'success':True}
                         for kind in ('dns-udp','dns-tcp')]
        result=audit_traffic_precondition(rows,1,3,'ipv4')
        self.assertTrue(result['passed'])
        self.assertEqual(result['captured_dns_successes'],{'6:dns-udp':1,'6:dns-tcp':1})
    def testUnknownSuccessfulIPv6KindStillFails(self):
        rows=self.rows()+[{'t':2,'family':6,'kind':'unknown-protocol','success':True}]
        self.assertFalse(audit_traffic_precondition(rows,1,3,'ipv4')['passed'])
    def testSuccessfulIPv6ApplicationKindsStillFail(self):
        for kind in ('tcp','udp','stream','fake-tcp','fake-udp'):
            with self.subTest(kind=kind):
                rows=self.rows()+[{'t':2,'family':6,'kind':kind,'success':True}]
                self.assertFalse(audit_traffic_precondition(rows,1,3,'ipv4')['passed'])
    def testNativeDnsEscapeFailsProtectedPrecondition(self):
        result=rapid_oracle.audit_protected_precondition_native(
            [{'t':2,'family':6,'protocol':'dns'}],1,3)
        self.assertFalse(result['passed']);self.assertEqual(result['native_attempts'],1)
    def testNativeZeroProofUsesOnlyApprovedWindow(self):
        result=rapid_oracle.audit_protected_precondition_native(
            [{'t':.9,'family':4,'protocol':'dns'},{'t':3.1,'family':6,'protocol':'tcp'}],1,3)
        self.assertTrue(result['passed']);self.assertEqual(result['native_attempts'],0)


class CurrentPolicyEvidence(unittest.TestCase):
    def testHealthyPfCannotHaveNonCurrentEvidence(self):
        self.assertFalse(current_component_evidence({'infrastructure':{'pf':'healthy','pfEvidenceCurrent':False}}))
    def testReleasedPfCannotHaveNonCurrentEvidence(self):
        self.assertFalse(current_component_evidence({'infrastructure':{'pf':'released','pfEvidenceCurrent':False}}))
    def testHistoricalInspectionDoesNotInvalidateIndependentPolicyProof(self):
        self.assertTrue(current_component_evidence({'infrastructure':{'pf':'healthy','pfEvidenceCurrent':True,
            'inspection':{'isCurrent':False,'outcome':'completed'}}}))


class ManualRefreshCompletion(unittest.TestCase):
    def setUp(self):
        self.start=978307300.0
        self.manual={'id':'current','requestedAt':100.1,'startedAt':100.2,'finishedAt':101.5,'phase':'succeeded','message':'Exit IP refreshed.'}
        self.state={'revision':13,'manualRefresh':self.manual,'status':{'ready':{}},
            'snapshot':{'ipAddress':'203.0.113.10','checkedAt':101.4},
            'routing':{'configuration':{'mode':'direct'},'phase':'active'}}
        self.response={'state':{'revision':13,'manualRefresh':{'id':'current','requestedAt':100.1}}}
        self.rows=[event('lookup_started',self.start+.2,lookup='lookup-current',trigger='manual',lifecycle_generation='9'),
            event('lookup_http_request',self.start+.3,lookup='lookup-current'),
            event('lookup_succeeded',self.start+1.4,lookup='lookup-current'),
            event('manual_refresh_finished',self.start+1.5,outcome='succeeded')]
        self.mode='direct';self.pf='empty'
    def audit(self):return rapid_oracle.audit_current_refresh(self.response,self.state,self.rows,self.start,self.mode,self.pf)
    def blocked(self):
        self.mode='rule';self.pf='closed';self.manual.update(phase='failed',message='Exit IP checked. Outbound access remains blocked. Exit not approved.')
        self.state['routing'].update(phase='blocked',configuration={'mode':'rule'},blockingIP={'address':'203.0.113.10','checkedAt':101.4})
        self.rows[-1]['fields']['outcome']='blocked'
    def testValidBlockedCompletionIsTerminalSuccessfulLookup(self):
        self.blocked();self.assertTrue(self.audit()['passed'])
    def testValidDirectCompletionPasses(self):self.assertTrue(self.audit()['passed'])
    def testWrongManualIdentityFails(self):
        self.manual['id']='old';self.assertFalse(self.audit()['passed'])
    def testOldManualRequestedTimeFails(self):
        self.manual['requestedAt']=self.response['state']['manualRefresh']['requestedAt']=99
        self.assertFalse(self.audit()['passed'])
    def testUnfinishedManualResponseFails(self):
        self.manual.update(phase='checking',finishedAt=None);self.assertFalse(self.audit()['passed'])
    def testProviderFailureCannotPass(self):
        self.rows[2]['event']='lookup_failed';self.assertFalse(self.audit()['passed'])
    def testProviderPauseCannotPass(self):
        self.rows.append(event('provider_failure_paused',self.start+1.6,lookup='lookup-current'))
        self.assertFalse(self.audit()['passed'])
    def testCancelledCompletionCannotPass(self):
        self.rows[-1]['fields']['outcome']='cancelled';self.assertFalse(self.audit()['passed'])
    def testMissingSuccessfulLookupFails(self):
        self.rows.pop(2);self.assertFalse(self.audit()['passed'])
    def testBlockedPhaseAloneCannotPass(self):
        self.blocked();self.manual['message']='Refresh failed.';self.rows[-1]['fields']['outcome']='failed'
        self.assertFalse(self.audit()['passed'])
    def testFreshBlockedIpTimestampMatchesFinalHttp(self):
        self.blocked();self.assertTrue(self.audit()['passed'])
    def testOldBlockingIpTimestampCannotPass(self):
        self.blocked();self.state['routing']['blockingIP']['checkedAt']=99
        self.assertFalse(self.audit()['passed'])
    def testSnapshotBeforeFinalHttpCannotPass(self):
        self.blocked();self.state['snapshot']['checkedAt']=100.15
        self.state['routing']['blockingIP']['checkedAt']=100.15
        self.assertFalse(self.audit()['passed'])


class TypedManualOwnership(unittest.TestCase):
    def setUp(self):
        self.base=ManualRefreshCompletion();self.base.setUp();self.base.blocked()
        self.base.manual.update(result='checkedBlocked',lifecycleGeneration=9,lookupID='lookup-current')
        self.base.response['state']['manualRefresh'].update(lifecycleGeneration=9)
        self.base.rows[-1]['fields'].update(result='checkedBlocked',request='current',generation='9',lookup='lookup-current',revision='13')
        self.base.rows.insert(1,event('manual_refresh_started',self.base.start+.21,request='current',generation='9',lookup='lookup-current',revision='13'))
        self.prior={'manualRefresh':{'id':'prior','requestedAt':100,'finishedAt':101,'phase':'failed','result':'superseded','lifecycleGeneration':8}}
        self.prior_rows=[event('manual_refresh_queued',self.base.start,request='prior',generation='8'),
            event('manual_refresh_finished',self.base.start+1,request='prior',generation='8',result='superseded',outcome='superseded')]
    def testValidTypedFinalOwnerPasses(self):self.assertTrue(self.base.audit()['passed'])
    def testWrongTypedFinalResultFails(self):
        self.base.manual['result']='providerFailed';self.assertFalse(self.base.audit()['passed'])
    def testWrongFinalLookupOwnerFails(self):
        self.base.manual['lookupID']='old-lookup';self.assertFalse(self.base.audit()['passed'])
    def testWrongFinalLifecycleOwnerFails(self):
        self.base.manual['lifecycleGeneration']=8;self.assertFalse(self.base.audit()['passed'])
    def testExplicitSameOwnerSupersededPriorPasses(self):
        self.assertTrue(rapid_oracle.audit_prior_manual_terminal(self.prior,self.prior_rows)['passed'])
    def testArbitraryFailedPriorCannotPass(self):
        self.prior['manualRefresh']['result']='providerFailed';self.assertFalse(rapid_oracle.audit_prior_manual_terminal(self.prior,self.prior_rows)['passed'])
    def testWrongPriorTerminalIdentityFails(self):
        self.prior_rows[-1]['fields']['request']='other';self.assertFalse(rapid_oracle.audit_prior_manual_terminal(self.prior,self.prior_rows)['passed'])


class FixtureAndHealth(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.root.chmod(0o700)
        self.lock=self.root/'existing.lock';self.lock.write_bytes(b'untouched');self.lock.chmod(0o600)
    def tearDown(self): self.temp.cleanup()
    def testBoundedHoldReleasesAndPreservesInodeAndBytes(self):
        before=self.lock.stat();identity=uuid.uuid4().hex
        result=hold(self.root,identity,.04,self.lock,os.getuid())
        self.assertEqual(result['release_reason'],'deadline');self.assertTrue(result['lock_inode_unchanged'])
        self.assertEqual(self.lock.stat().st_ino,before.st_ino);self.assertEqual(self.lock.read_bytes(),b'untouched')
        with self.lock.open('rb') as stream: fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
    def testExplicitReleaseExitsBeforeDeadline(self):
        identity=uuid.uuid4().hex;release=self.root/(identity+'-pf-hold-release');release.touch(mode=0o600)
        began=time.monotonic();result=hold(self.root,identity,2,self.lock,os.getuid())
        self.assertEqual(result['release_reason'],'requested');self.assertLess(time.monotonic()-began,.5)
    def testUnsafeExistingLockRejectedWithoutMutation(self):
        self.lock.chmod(0o666)
        with self.assertRaises(AssertionError): validated_descriptor(self.lock,os.getuid())
        self.assertEqual(self.lock.read_bytes(),b'untouched')
    def testSymlinkLockRejected(self):
        link=self.root/'link';link.symlink_to(self.lock)
        with self.assertRaises(OSError): validated_descriptor(link,os.getuid())
    def testHealthRetainsSeparateRealComponentDates(self):
        state=healthy_state();state['routing']['infrastructure']['checkedAt']=100
        state['routing']['infrastructure']['pfCheckedAt']=102;state['routing']['infrastructure']['launchdCheckedAt']=103
        result=state_health(state,978307235+100)
        self.assertEqual(result['infrastructure_age_seconds'],35);self.assertIn('infrastructure_age',result['failed_components'])
        self.assertEqual(result['pf_age_seconds'],33);self.assertEqual(result['launchd_age_seconds'],32)
    def testGuardEvidenceDoesNotContainArbitraryPrivateFields(self):
        self.lock.write_text(json.dumps({'checkedAt':10,'pfMutationEpoch':'e','privateToken':'secret'}))
        value=guard_health(self.lock,os.getuid())
        self.assertNotIn('privateToken',value['record']);self.assertEqual(value['record']['pfMutationEpoch'],'e')
    def testTraceStopsBeforeIdempotentReport(self):
        self.lock.write_text(json.dumps({'checkedAt':10,'status':'healthy'}))
        trace=HealthTrace(self.root,healthy_state,lambda:{},lambda _:[],.01,self.lock,os.getuid()).start()
        time.sleep(.03);first=trace.finish('a'*32);count=len(first['samples'])
        time.sleep(.02);self.assertIs(first,trace.finish('a'*32));self.assertFalse(trace.thread.is_alive())
        self.assertEqual(len(first['samples']),count);self.assertTrue(first['passed'])
    def testTraceRetainsSamplingFailure(self):
        def fail():raise TimeoutError('do not export text')
        trace=HealthTrace(self.root,fail,lambda:{},lambda _:[],.01,self.lock,os.getuid()).start()
        time.sleep(.02);result=trace.finish('b'*32)
        self.assertFalse(result['passed']);self.assertEqual(result['samples'][0]['error_class'],'TimeoutError')
    def testClaimedProtectionOverStableEmptyPfFails(self):
        self.lock.write_text(json.dumps({'checkedAt':10,'status':'healthy'}))
        trace=HealthTrace(self.root,healthy_state,lambda:{},lambda _:[],.01,self.lock,os.getuid(),lambda:'empty').start()
        time.sleep(.02);result=trace.finish('c'*32)
        self.assertFalse(result['passed']);self.assertEqual(result['samples'][0]['pf_readback'],{'before':'empty','after':'empty'})
    def testDirectRestorationDoesNotClaimProtectedStatus(self):
        self.lock.write_text(json.dumps({'checkedAt':10,'status':'healthy'}))
        def read():
            state=healthy_state();state['routing']['phase']='restoringDirect';state['routing']['effectiveMode']=None
            return state
        trace=HealthTrace(self.root,read,lambda:{},lambda _:[],.01,self.lock,os.getuid(),lambda:'empty').start()
        time.sleep(.02);self.assertTrue(trace.finish('d'*32)['passed'])
    def testPhaseGateRequiresNewRealCompletion(self):
        clock=[100.0]
        def sleep(duration):clock[0]+=duration
        def read_guard():return {'record':{'completedAt':100.2 if clock[0]>=100.2 else 99,'status':'healthy'}}
        result=wait_for_phase('early',read_guard,healthy_state,lambda _:True,lambda:clock[0],lambda:clock[0],sleep,2)
        self.assertGreaterEqual(result['guard']['record']['completedAt'],100)
    def testPhaseGateNeverTreatsOldCompletionAsFresh(self):
        clock=[100.0]
        def sleep(duration):clock[0]+=duration
        with self.assertRaises(AssertionError):wait_for_phase('early',lambda:{'record':{'completedAt':99,'status':'healthy'}},
            healthy_state,lambda _:True,lambda:clock[0],lambda:clock[0],sleep,.5)


if __name__=='__main__': unittest.main()
