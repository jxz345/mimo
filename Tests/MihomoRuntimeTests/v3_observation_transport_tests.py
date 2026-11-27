#!/usr/bin/env python3
"""Pure ownership/clock negative controls; no sockets, settings or VM use."""
import copy
from datetime import datetime,timezone
import unittest
from v3_observation_transport import audit_provider_transport, calibrated_clock

OLD='11111111-1111-1111-1111-111111111111'
NEW='22222222-2222-2222-2222-222222222222'
OTHER='33333333-3333-3333-3333-333333333333'
ATTEMPT='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
CONTROLLER='cccccccc-cccc-cccc-cccc-cccccccccccc'

def core(name,at,**fields):
    return {'event':name,'timestamp':datetime.fromtimestamp(at,timezone.utc).isoformat(),
            'level':'info','fields':fields}

def baseline():
    fixture=[{'event':'provider_ingress_rejected','connection_id':'a'*32,'ingress':'proxy_configured_dns',
        'reason':'tls_or_transport','phase':'handshake','exception_class':'SSLEOFError','errno':8,
        'ssl_reason':None,'sni_accepted':True,'host_accepted':False,'approved_sni':'ipapi.co','wall_time_epoch':1007.0}]
    rows=[core('mimo_private_probe_ready',999.9,lookup=OLD,attempt=ATTEMPT,controller=CONTROLLER,generation='10'),
        core('mimo_probe_http_started',1000,lookup=OLD,provider='ipapiCo',path='private_proxy_probe'),
        core('mimo_supervisor_command_received',1001,command='direct',controller=CONTROLLER,generation='11'),
        core('mimo_probe_result_cancelled',1004,lookup=OLD,attempt=ATTEMPT,reason='task_cancelled'),
        core('mimo_probe_http_started',1005,lookup=NEW,provider='ipapiCo',path='native_direct'),
        core('lookup_succeeded',1006,lookup=NEW,provider='ipapiCo')]
    samples={side:[{'guest_start_epoch':t,'guest_end_epoch':t+.02,'host_epoch':t+5.01} for _ in range(3)]
             for side,t in [('before',990),('after',1010)]}
    return fixture,rows,samples

class TransportAuditTests(unittest.TestCase):
    def run_audit(self,data):
        return audit_provider_transport(data[0],data[1],'ipapiCo','ipapi.co',data[2])

    def testOwnedHandshakeCancellationQualifiesWithMeasuredClock(self):
        result=self.run_audit(baseline())
        self.assertTrue(result['passed']);self.assertEqual(len(result['expected_aborts']),1)
        self.assertEqual(result['expected_aborts'][0]['lookup'],OLD)
        self.assertEqual(result['expected_aborts'][0]['fresh_lookup'],NEW)
        self.assertLess(result['clock_proof']['uncertainty_seconds'],.021)

    def testNoRejectedEventsDoesNotInventCancellation(self):
        f,c,k=baseline();result=self.run_audit(([],c,k))
        self.assertTrue(result['passed']);self.assertEqual(result['expected_aborts'],[])

    def testClockChoosesNarrowestOfMeasuredRoundTrips(self):
        f,c,k=baseline();k['before'].append({'guest_start_epoch':989.9,'guest_end_epoch':990.1,'host_epoch':995})
        self.assertLess(calibrated_clock(k)['before_roundtrip_seconds'],.021)

    def testUnknownFieldsAndCredentialTextNeverEnterResult(self):
        f,c,k=baseline();f[0]['raw_error']='SECRET_SENTINEL';c[0]['fields']['token']='SECRET_SENTINEL'
        self.assertNotIn('SECRET_SENTINEL',str(self.run_audit((f,c,k))))

def fixture_field(field,value):return lambda d:d[0][0].update({field:value})
def remove_event(name):return lambda d:d[1].__setitem__(slice(None),[r for r in d[1] if r['event']!=name])
def add_event(name,**fields):return lambda d:d[1].append(core(name,1003,**fields))
def intent_field(field,value):return lambda d:d[1][2]['fields'].update({field:value})

NEGATIVES={
    'NonEOFSSLFailure':fixture_field('exception_class','SSLError'),
    'WrongErrno':fixture_field('errno',1),
    'UnapprovedSNI':fixture_field('sni_accepted',False),
    'DifferentProviderSNI':fixture_field('approved_sni','ipwho.is'),
    'MissingProviderSNI':fixture_field('approved_sni',None),
    'ValidatedHTTP':fixture_field('host_accepted',True),
    'WriteCancellationIsNotHandshakeEOF':fixture_field('phase','write'),
    'ClientRejection':fixture_field('reason','client'),
    'NativeIngress':fixture_field('ingress','native_relay'),
    'WrongTLSReason':fixture_field('ssl_reason','SSLV3_ALERT_BAD_CERTIFICATE'),
    'MissingUTC':fixture_field('wall_time_epoch',None),
    'NonFiniteUTC':fixture_field('wall_time_epoch',float('nan')),
    'NoSupersedingIntent':remove_event('mimo_supervisor_command_received'),
    'OldGeneration':intent_field('generation','10'),
    'WrongController':intent_field('controller','unrelated'),
    'UnrelatedCommand':intent_field('command','poll'),
    'NoCancellation':remove_event('mimo_probe_result_cancelled'),
    'NoHTTPStart':remove_event('mimo_probe_http_started'),
    'NoPrivateToken':remove_event('mimo_private_probe_ready'),
    'NoFreshSuccess':remove_event('lookup_succeeded'),
    'ProviderPause':add_event('provider_failure_paused',lookup=OLD,provider='ipapiCo'),
    'ProviderPauseWithoutLookup':add_event('provider_failure_paused',provider='ipapiCo'),
    'ProviderFailure':add_event('lookup_failed',lookup=OLD,provider='ipapiCo'),
    'LateIPApproval':add_event('mimo_exit_ip_approved',attempt=ATTEMPT),
    'LateTrafficOpen':add_event('mimo_traffic_opened',attempt=ATTEMPT),
    'OldLookupSucceeded':add_event('lookup_succeeded',lookup=OLD,provider='ipapiCo'),
    'TwoAbortsOneCancelledLookup':lambda d:d[0].append(dict(d[0][0],connection_id='b'*32)),
    'SameConnectionHTTP':lambda d:d[0].append({'event':'provider_ingress','connection_id':'a'*32}),
    'DuplicateStart':lambda d:d[1].append(copy.deepcopy(d[1][1])),
    'ConcurrentUncancelledPrivateLookup':lambda d:d[1].append(core('mimo_probe_http_started',1001.5,lookup=OTHER,provider='ipapiCo',path='private_proxy_probe')),
    'AbortBeforeSupersedingIntent':fixture_field('wall_time_epoch',1005.5),
    'AbortAfterCancellation':fixture_field('wall_time_epoch',1010),
    'ClockMissing':lambda d:d[2].clear(),
    'ClockSlow':lambda d:d[2].update(before=[{'guest_start_epoch':990,'host_epoch':995,'guest_end_epoch':991}]),
    'ClockOffsetChanged':lambda d:d[2].update(after=[{'guest_start_epoch':1010,'host_epoch':1020,'guest_end_epoch':1010.02}]),
    'UncertaintyOverlapsIntent':fixture_field('wall_time_epoch',1006.0),
}

def negative_test(mutate):
    def test(self):
        data=baseline();mutate(data);result=self.run_audit(data)
        self.assertFalse(result['passed']);self.assertTrue(result['rejected'])
    return test

for name,mutate in NEGATIVES.items():
    setattr(TransportAuditTests,'testReject'+name,negative_test(mutate))

if __name__=='__main__':unittest.main()
