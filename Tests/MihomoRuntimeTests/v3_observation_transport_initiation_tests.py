#!/usr/bin/env python3
"""Future cancellation-initiation evidence only; no retrospective waiver."""
import copy,unittest
from v3_observation_transport_tests import baseline,core,OLD,NEW,CONTROLLER,ATTEMPT
from v3_observation_transport import audit_provider_transport
REQUEST='44444444-4444-4444-4444-444444444444'

def initiated():
    f,c,k=baseline()
    # EOF guest interval is1001.99–1002.01; actual cancellation starts1001,
    # routing persistence/command delivery follow after EOF.
    c=[r for r in c if r['event']!='mimo_supervisor_command_received']
    c += [core('lookup_started',999.8,lookup=OLD,provider='ipapiCo',lifecycle_generation='71'),
      core('lookup_cancellation_requested',1001,lookup=OLD,provider='ipapiCo',lookup_generation='71',lifecycle_before='71',lifecycle_after='72',already_cancelled='false',cause='routing_configuration',request=REQUEST,command='configureRouting',intended_mode='direct',intended_revision='52'),
      core('mimo_routing_configuration_committed',1002.3,request=REQUEST,command='configureRouting',mode='direct',revision='52'),
      core('mimo_supervisor_command_received',1002.4,command='direct',controller=CONTROLLER,generation='11',revision='52')]
    return f,c,k

def row(data,name):return next(r for r in data[1] if r['event']==name)
def field(name,key,value):return lambda d:row(d,name)['fields'].update({key:value})
def remove(name):return lambda d:d[1].__setitem__(slice(None),[r for r in d[1] if r['event']!=name])

class InitiationTests(unittest.TestCase):
 def audit(self,d):return audit_provider_transport(d[0],d[1],'ipapiCo','ipapi.co',d[2])
 def testInitiationBeforeEOFWithLaterCommittedDirectQualifies(self):
  result=self.audit(initiated());self.assertTrue(result['passed'])
  self.assertEqual(result['expected_aborts'][0]['ownership_fence'],'routing_cancellation_requested')
 def testDirectCommitAndDeliveryMayFollowHTTPUnwind(self):
  d=initiated();row(d,'mimo_routing_configuration_committed')['timestamp']=core('',1004.1)['timestamp'];row(d,'mimo_supervisor_command_received')['timestamp']=core('',1004.2)['timestamp']
  self.assertTrue(self.audit(d)['passed'])
 def testMonitorEpochIsNotSupervisorGeneration(self):
  d=initiated();field('lookup_started','lifecycle_generation','800')(d)
  field('lookup_cancellation_requested','lookup_generation','800')(d);field('lookup_cancellation_requested','lifecycle_before','800')(d);field('lookup_cancellation_requested','lifecycle_after','801')(d)
  self.assertTrue(self.audit(d)['passed'])
 def testHistoricalMissingInitiationRemainsRejected(self):
  d=initiated();remove('lookup_cancellation_requested')(d);self.assertFalse(self.audit(d)['passed'])

NEGATIVE={
 'MissingCommit':remove('mimo_routing_configuration_committed'),
 'MissingLookupEpoch':remove('lookup_started'),
 'MissingSupervisorReceipt':remove('mimo_supervisor_command_received'),
 'GenericCancellation':field('lookup_cancellation_requested','cause','invalidated'),
 'AlreadyCancelled':field('lookup_cancellation_requested','already_cancelled','true'),
 'DifferentProvider':field('lookup_cancellation_requested','provider','ipWhois'),
 'DifferentLookup':field('lookup_cancellation_requested','lookup',NEW),
 'WrongLookupEpoch':field('lookup_cancellation_requested','lookup_generation','70'),
 'PriorInvalidation':field('lookup_cancellation_requested','lifecycle_before','72'),
 'SkippedLifecycle':field('lookup_cancellation_requested','lifecycle_after','73'),
 'MalformedRequest':field('lookup_cancellation_requested','request','not-uuid'),
 'WrongCommitRequest':field('mimo_routing_configuration_committed','request',NEW),
 'WrongCommitCommand':field('mimo_routing_configuration_committed','command','selectProxy'),
 'WrongCommitMode':field('mimo_routing_configuration_committed','mode','global'),
 'WrongCommitRevision':field('mimo_routing_configuration_committed','revision','53'),
 'UnvalidatedCommand':field('lookup_cancellation_requested','command','refresh'),
 'WrongDeliveredRevision':field('mimo_supervisor_command_received','revision','51'),
 'WrongDeliveredController':field('mimo_supervisor_command_received','controller',NEW),
 'OldDeliveredGeneration':field('mimo_supervisor_command_received','generation','10'),
 'WrongDeliveredCommand':field('mimo_supervisor_command_received','command','close'),
 'DuplicateInitiation':lambda d:d[1].append(copy.deepcopy(row(d,'lookup_cancellation_requested'))),
 'DuplicateCommit':lambda d:d[1].append(copy.deepcopy(row(d,'mimo_routing_configuration_committed'))),
 'DuplicateReceipt':lambda d:d[1].append(copy.deepcopy(row(d,'mimo_supervisor_command_received'))),
 'InitiationAfterEOF':lambda d:row(d,'lookup_cancellation_requested').update(timestamp=core('',1002.1)['timestamp']),
 'CommitBeforeInitiation':lambda d:row(d,'mimo_routing_configuration_committed').update(timestamp=core('',1000.9)['timestamp']),
 'DeliveredBeforeCommit':lambda d:row(d,'mimo_supervisor_command_received').update(timestamp=core('',1002.2)['timestamp']),
 'DeliveryAfterFreshHTTP':lambda d:row(d,'mimo_supervisor_command_received').update(timestamp=core('',1005.1)['timestamp']),
 'PauseOldOwner':lambda d:d[1].append(core('provider_failure_paused',1004.5,lookup=OLD,provider='ipapiCo')),
 'LateOldApproval':lambda d:d[1].append(core('mimo_exit_ip_approved',1004.5,attempt=ATTEMPT)),
}
for name,mutation in NEGATIVE.items():
 def test(self,mutation=mutation):
  data=initiated();mutation(data);self.assertFalse(self.audit(data)['passed'])
 setattr(InitiationTests,'testReject'+name,test)
if __name__=='__main__':unittest.main()
