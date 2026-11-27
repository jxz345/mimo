#!/usr/bin/env python3
"""Conservative, pure classification of intentionally cancelled fixture TLS.

This does not alter fixture ACLs or preflight requirements. Only a provider TLS
handshake EOF with complete, clock-bounded cancellation ownership can qualify.
"""
from datetime import datetime
import math
import re

MAX_CLOCK_RTT = .25
PROVIDERS = {'ipWhois':'ipwho.is', 'ipapiCo':'ipapi.co', 'ipapiIs':'api.ipapi.is',
             'ipinfoLite':'v4.api.ipinfo.io'}
CANCELLATIONS = {'task_cancelled', 'generation_changed', 'operation_cancelled',
                 'verification_no_longer_current', 'observation_no_longer_current'}

def number(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError('invalid_number')
    return float(value)

def epoch(row):
    return datetime.fromisoformat(row['timestamp'].replace('Z','+00:00')).timestamp()

def calibrated_clock(samples):
    """Offset is fixture(host) minus guest UTC; no assumed clock tolerance."""
    selected=[]
    for side in ('before','after'):
        candidates=[]
        rows=samples[side]
        if not isinstance(rows,list) or not 1<=len(rows)<=16:
            raise ValueError('invalid_clock_samples')
        for row in rows:
            start,host,end=(number(row[k]) for k in ('guest_start_epoch','host_epoch','guest_end_epoch'))
            if 0<=end-start<=MAX_CLOCK_RTT:
                candidates.append((end-start,host-end,host-start,start,end))
        if not candidates:raise ValueError('clock_roundtrip_too_large')
        selected.append(min(candidates))
    before,after=selected
    if before[4]>after[3]:raise ValueError('clock_samples_out_of_order')
    low,high=max(before[1],after[1]),min(before[2],after[2])
    if low>high:raise ValueError('clock_offset_changed')
    return {'passed':True,'offset_lower_seconds':low,'offset_upper_seconds':high,
            'uncertainty_seconds':high-low,'before_roundtrip_seconds':before[0],
            'after_roundtrip_seconds':after[0],'guest_window_start_epoch':before[4],
            'guest_window_end_epoch':after[3]}

def cancellation_fences(rows, lookup, provider, started, cancelled, controller, generation):
    """A recorded command or a proven pre-cancel intent followed by its commit.

    Monitor lifecycle generations and supervisor generations are separate epochs.
    An initiating record alone never qualifies: persistence and the delivered
    routing revision must independently agree before a fresh lookup starts.
    """
    fences=[]
    receipts=[]
    for row in rows:
        if row[1]!='mimo_supervisor_command_received' or row[2].get('command') not in ('direct','close'):continue
        try:new_generation=int(row[2]['generation'])
        except (KeyError,TypeError,ValueError):continue
        if row[2].get('controller')==controller and new_generation>generation and row[0]>=started:
            receipts.append(row)
            if row[0]<=cancelled:
                fences.append({'at':row[0],'delivered':row[0],'generation':new_generation,
                               'kind':'supervisor_command_received'})
    beginnings=[r for r in rows if r[1]=='lookup_started' and r[2].get('lookup')==lookup and
                r[2].get('provider')==provider and r[0]<=started]
    initiations=[r for r in rows if r[1]=='lookup_cancellation_requested' and r[2].get('lookup')==lookup]
    if len(beginnings)!=1 or len(initiations)!=1:return fences
    initiation=initiations[0];f=initiation[2]
    if not (started<=initiation[0]<=cancelled and f.get('provider')==provider and
            f.get('already_cancelled')=='false' and f.get('cause')=='routing_configuration' and
            f.get('command') in ('configureRouting','saveProxy','removeProxy','selectProxy') and
            f.get('intended_mode') in ('direct','rule','global')):return fences
    request=f.get('request')
    if not isinstance(request,str) or not re.fullmatch(r'[A-Fa-f0-9-]{36}',request):return fences
    try:
        lookup_epoch=int(beginnings[0][2]['lifecycle_generation'])
        before=int(f['lifecycle_before']);after=int(f['lifecycle_after'])
        revision=int(f['intended_revision'])
        if int(f['lookup_generation'])!=lookup_epoch or before!=lookup_epoch or after!=before+1 or revision<0:return fences
    except (KeyError,TypeError,ValueError):return fences
    # Duplicate/mixed ownership records are ambiguity, never additional proof.
    owners=[r for r in rows if r[1]=='lookup_cancellation_requested' and r[2].get('request')==request]
    commits=[r for r in rows if r[1]=='mimo_routing_configuration_committed' and r[2].get('request')==request]
    if len(owners)!=1 or len(commits)!=1:return fences
    commit=commits[0]
    if commit[0]<initiation[0] or commit[2].get('command')!=f['command'] or commit[2].get('mode')!=f['intended_mode']:return fences
    try:
        if int(commit[2]['revision'])!=revision:return fences
    except (KeyError,TypeError,ValueError):return fences
    delivered=[]
    for row in receipts:
        try:same_revision=int(row[2]['revision'])==revision
        except (KeyError,TypeError,ValueError):continue
        expected='direct' if f['intended_mode']=='direct' else 'close'
        if same_revision and row[2].get('command')==expected and row[0]>=commit[0]:delivered.append(row)
    if len(delivered)!=1:return fences
    fences.append({'at':initiation[0],'delivered':delivered[0][0],
                   'generation':int(delivered[0][2]['generation']),
                   'kind':'routing_cancellation_requested','revision':revision})
    return fences

def audit_provider_transport(fixture_events, core_events, provider, provider_host, clock_samples):
    result={'passed':False,'expected_aborts':[],'rejected':[],'clock_proof':{'passed':False}}
    if PROVIDERS.get(provider)!=provider_host:
        result['rejected'].append({'connection_id':None,'reason':'provider_identity_invalid'});return result
    if (not isinstance(fixture_events,list) or any(not isinstance(r,dict) or
            not isinstance(r.get('event'),str) or not r['event'] for r in fixture_events)):
        result['rejected'].append({'connection_id':None,'reason':'fixture_events_invalid'});return result
    try:
        if not isinstance(core_events,list) or any(not isinstance(r,dict) or
                not isinstance(r.get('fields',{}),dict) or not isinstance(r.get('event'),str) for r in core_events):
            raise ValueError('core_events_invalid')
        rows=[(epoch(r),r.get('event'),r.get('fields',{}),r.get('level')) for r in core_events]
    except (ValueError,TypeError,KeyError,OverflowError):
        result['rejected'].append({'connection_id':None,'reason':'core_events_invalid'});return result
    needs_clock=any(r['event']=='provider_ingress_rejected' for r in fixture_events)
    clock=None;calibration_error=None
    try:clock=calibrated_clock(clock_samples)
    except ValueError as error:
        # Only fixed internal error categories enter the exported diagnostic.
        known={'invalid_number','invalid_clock_samples','clock_roundtrip_too_large',
               'clock_samples_out_of_order','clock_offset_changed'}
        calibration_error=str(error) if str(error) in known else 'clock_samples_unavailable'
    except (TypeError,KeyError,OverflowError):calibration_error='clock_samples_unavailable'
    if not needs_clock:
        result['clock_proof']={'passed':False,'required':False,'status':'not_required',
            'reason':'no_rejected_ingress','calibration_error':calibration_error,'calibration':clock}
        result['passed']=True
        return result
    if clock is None:
        result['clock_proof']={'passed':False,'required':True,'status':'unqualified',
                               'calibration_error':calibration_error}
        result['rejected'].append({'connection_id':None,'reason':'clock_not_qualified'});return result
    result['clock_proof']=dict(clock,required=True,status='qualified')
    cohorts=[]
    starts=[r for r in rows if r[1]=='mimo_probe_http_started' and r[2].get('provider')==provider and r[2].get('path')=='private_proxy_probe']
    for started,_,fields,_ in starts:
        lookup=fields.get('lookup')
        if not isinstance(lookup,str) or not re.fullmatch(r'[A-Fa-f0-9-]{36}',lookup):continue
        if sum(r[2].get('lookup')==lookup for r in starts)!=1:continue
        ready=[r for r in rows if r[1]=='mimo_private_probe_ready' and r[2].get('lookup')==lookup and r[0]<=started]
        cancels=[r for r in rows if r[1]=='mimo_probe_result_cancelled' and r[2].get('lookup')==lookup and r[2].get('reason') in CANCELLATIONS and r[0]>=started]
        if len(ready)!=1 or len(cancels)!=1:continue
        proof=ready[0][2];cancelled=cancels[0][0]
        try:generation=int(proof['generation']);controller=proof['controller'];attempt=proof['attempt']
        except (KeyError,TypeError,ValueError):continue
        if not controller or not attempt:continue
        fences=cancellation_fences(rows,lookup,provider,started,cancelled,controller,generation)
        if not fences:continue
        bad=False
        for when,event,f,level in rows:
            same=f.get('lookup')==lookup or f.get('attempt')==attempt
            if same and (level=='error' or event in ('lookup_failed','provider_failure_paused','lookup_succeeded',
                    'mimo_exit_ip_approved','mimo_traffic_opened','mimo_observation_completed') or
                    (event=='mimo_core_command_started' and f.get('command') in ('approve','completeObservation'))):bad=True
            if started<=when<=cancelled and event in ('provider_failure_paused','lookup_failed') and f.get('provider')==provider:bad=True
        if bad:continue
        fresh=[]
        for row in rows:
            if row[1]!='lookup_succeeded' or row[2].get('provider')!=provider or row[2].get('lookup') in (None,lookup):continue
            fresh_id=row[2]['lookup']
            fresh_http=[r for r in rows if r[1]=='mimo_probe_http_started' and r[2].get('provider')==provider and r[2].get('lookup')==fresh_id and cancelled<r[0]<=row[0]]
            if len(fresh_http)==1:fresh.append((fresh_id,fresh_http[0][0]))
        if not fresh:continue
        eligible=[(f,owned) for f in fences for owned in fresh if owned[1]>=f['delivered']]
        if not eligible:continue
        fence,owned=min(eligible,key=lambda item:item[0]['at'])
        cohorts.append({'lookup':lookup,'attempt':attempt,'generation':generation,'intent_generation':fence['generation'],
            'started':started,'cancelled':cancelled,'intent':fence['at'],'fresh_lookup':owned[0],
            'ownership_fence':fence['kind']})
    consumed=set()
    for event in fixture_events:
        if event.get('event')!='provider_ingress_rejected':continue
        connection=event.get('connection_id')
        if not isinstance(connection,str) or not re.fullmatch(r'[a-f0-9]{32}',connection):connection=None
        reason='not_qualified_handshake_eof'
        exact=(connection is not None and event.get('ingress')=='proxy_configured_dns' and
            event.get('phase')=='handshake' and event.get('reason')=='tls_or_transport' and
            event.get('exception_class')=='SSLEOFError' and event.get('errno')==8 and
            event.get('ssl_reason') in (None,'UNEXPECTED_EOF_WHILE_READING') and
            event.get('sni_accepted') is True and event.get('host_accepted') is False and
            event.get('approved_sni')==provider_host)
        if exact:
            same_http=any(r.get('connection_id')==connection and r.get('event') in
                          ('provider_ingress','provider_http','provider_response_sent') for r in fixture_events)
            if same_http:reason='connection_already_reached_http'
            else:
                try:
                    observed=number(event['wall_time_epoch'])
                    lower=observed-clock['offset_upper_seconds'];upper=observed-clock['offset_lower_seconds']
                    matches=[c for c in cohorts if c['started']<=lower and c['intent']<=lower and upper<=c['cancelled'] and
                             clock['guest_window_start_epoch']<=lower<=upper<=clock['guest_window_end_epoch']]
                    if len(matches)==1:
                        owner=matches[0]['lookup']
                        for started,_,fields,_ in starts:
                            other=fields.get('lookup')
                            finished=[r[0] for r in rows if r[2].get('lookup')==other and
                                      r[1] in ('mimo_probe_http_finished','lookup_finished')]
                            if other!=owner and started<=upper and not any(end<lower for end in finished):
                                matches=[];break
                except (ValueError,KeyError,TypeError):matches=[]
                if len(matches)!=1:reason='unique_cancelled_owner_not_proven'
                elif matches[0]['lookup'] in consumed:reason='abort_count_exceeds_cancelled_lookups'
                else:
                    cohort=matches[0];consumed.add(cohort['lookup'])
                    result['expected_aborts'].append({'connection_id':connection,'lookup':cohort['lookup'],
                        'generation':cohort['generation'],'superseding_generation':cohort['intent_generation'],
                        'fresh_lookup':cohort['fresh_lookup'],'ownership_fence':cohort['ownership_fence'],'event_guest_lower_epoch':lower,'event_guest_upper_epoch':upper})
                    continue
        result['rejected'].append({'connection_id':connection,'reason':reason})
    result['passed']=not result['rejected']
    return result
