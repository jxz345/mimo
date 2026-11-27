#!/usr/bin/env python3
"""Clock attribution is required for exceptions, never inferred from absent data."""
import unittest
from v3_observation_transport_tests import baseline
from v3_observation_transport import audit_provider_transport

def data(rejected=False,drift=True):
 f,c,k=baseline()
 if not rejected:f=[{'event':'provider_ingress'},{'event':'provider_http'},{'event':'provider_response_sent'}]
 if drift:
  for r in k['after']:r['host_epoch']+=.05
 return f,c,k

def audit(d,provider='ipapiCo'):return audit_provider_transport(d[0],d[1],provider,'ipapi.co',d[2])
class ClockRequirement(unittest.TestCase):
 def testNoRejectedIngressDoesNotNeedConstantOffset(self):
  r=audit(data());self.assertTrue(r['passed']);self.assertEqual(r['clock_proof']['status'],'not_required');self.assertFalse(r['clock_proof']['passed']);self.assertEqual(r['clock_proof']['calibration_error'],'clock_offset_changed')
 def testValidClockStillNotRequiredWithoutRejection(self):
  r=audit(data(drift=False));self.assertTrue(r['passed']);self.assertEqual(r['clock_proof']['status'],'not_required');self.assertFalse(r['clock_proof']['passed']);self.assertTrue(r['clock_proof']['calibration']['passed'])
 def testActualRejectionWithDriftStillFails(self):
  r=audit(data(rejected=True));self.assertFalse(r['passed']);self.assertEqual(r['rejected'][0]['reason'],'clock_not_qualified')
 def testMalformedProviderFailsEvenWithoutRejection(self):self.assertFalse(audit(data(),provider='invalid')['passed'])
 def testMalformedCoreTimestampFailsEvenWithoutRejection(self):
  f,c,k=data();c[0]['timestamp']='invalid';self.assertFalse(audit((f,c,k))['passed'])
 def testMalformedCoreFieldsFailsEvenWithoutRejection(self):
  f,c,k=data();c[0]['fields']=None;self.assertFalse(audit((f,c,k))['passed'])
 def testMissingFixtureEvidenceFails(self):
  f,c,k=data();self.assertFalse(audit((None,c,k))['passed'])
 def testMalformedFixtureRowFails(self):
  f,c,k=data();self.assertFalse(audit(([None],c,k))['passed'])
 def testMissingFixtureEventTypeFails(self):
  f,c,k=data();self.assertFalse(audit(([{}],c,k))['passed'])
 def testExplicitEmptyEventListNeedsNoExceptionAttribution(self):
  f,c,k=data();r=audit(([],c,k));self.assertTrue(r['passed']);self.assertEqual(r['expected_aborts'],[])
 def testMissingClockSamplesRetainsDiagnosticWhenNoRejection(self):
  f,c,k=data();r=audit((f,c,{}));self.assertTrue(r['passed']);self.assertEqual(r['clock_proof']['status'],'not_required');self.assertEqual(r['clock_proof']['calibration_error'],'clock_samples_unavailable')
if __name__=='__main__':unittest.main()
