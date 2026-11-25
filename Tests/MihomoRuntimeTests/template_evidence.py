#!/usr/bin/env python3
"""Export current template campaign evidence without private fixture identities."""
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import sys


def export(campaign, output):
    runs, replacements = [], {}
    for path in campaign.glob('*/report.json'):
        report = json.loads(path.read_text())
        # Older runner copies used the same label before and after restoring
        # proxy capability. These are distinct ordered assertions, not reruns.
        warm = [c for c in report.get('cases', []) if c['id'] == 'F06-warm-S00']
        if len(warm) == 2:
            for row, phase in zip(warm, ('initial', 'recovered')):
                row['original_id'] = row['id']
                row['id'] += '-' + phase
            report['case_id_normalization'] = 'F06 initial/recovered labels disambiguated; original IDs and raw reports retained.'
        fixture = json.loads((path.parent / 'fixture.json').read_text())
        for key in ('bridge4', 'data4', 'data6', 'client4', 'token'):
            replacements[fixture[key]] = '<' + key.upper() + '>'
        peer = fixture.get('native_peer', {})
        if peer.get('name'):
            name = peer['name'].rstrip('.')
            replacements[name] = '<NATIVE_PEER_NAME>'
            replacements[name.partition('.')[2]] = '<TAILNET_DOMAIN>'
        for address in peer.get('addresses', []):
            replacements[address] = '<NATIVE_PEER_IPV6>' if ':' in address else '<NATIVE_PEER_IPV4>'
        runs.append((path.parent.name, report))
    replacements = dict(sorted(((a, b) for a, b in replacements.items() if a), key=lambda x: -len(x[0])))

    def sanitize(value):
        if isinstance(value, dict):
            return {k: sanitize(v) for k, v in value.items()}
        if isinstance(value, list):
            return [sanitize(v) for v in value]
        if isinstance(value, str):
            for original, replacement in replacements.items():
                value = value.replace(original, replacement)
        return value

    selected = {}
    for name, report in sorted(runs, key=lambda r: r[1]['tested_at_utc']):
        scope = 'matrix' if report['scope'] == 'smoke' else report['scope']
        selected[(report['profile'], report['proxy_mode'], scope)] = (name, report)
    counts, matrix_counts, focused_counts = Counter(), Counter(), Counter()
    matrix, focused = [], []
    for key, (name, report) in sorted(selected.items()):
        rows = report.get('cases', [])
        counts.update(row['result'] for row in rows)
        target = matrix if key[2] == 'matrix' else focused
        (matrix_counts if key[2] == 'matrix' else focused_counts).update(row['result'] for row in rows)
        target.append({'run': name, **report})
    earlier = [{'run': name, **report} for name, report in runs if name not in {n for n, _ in selected.values()}]
    expected = {'matrix': 3120, 'focused': 500, 'total': 3620}
    summary = {
        'updated_at_utc': datetime.now(timezone.utc).isoformat(),
        'status': 'testing_in_progress', 'planned': expected,
        'unique_cases_executed': sum(counts.values()), 'counts': dict(counts),
        'not_run': expected['total'] - sum(counts.values()),
        'matrix': {'cells_reported': len(matrix), 'cells_passed': sum(r['passed'] for r in matrix), 'counts': dict(matrix_counts)},
        'focused': {'runs_reported': len(focused), 'counts': dict(focused_counts)},
        'failed_checks': [{'profile': r['profile'], 'scope': r['scope'], 'proxy_mode': r['proxy_mode'],
                           'checks': [k for k, v in r['checks'].items() if not v],
                           'failed_case_ids': [c['id'] for c in r.get('cases', []) if c['result'].startswith('FAIL')],
                           'error': r.get('error')}
                          for r in matrix + focused if not r['passed']],
        'preliminary_runs_retained': len(earlier),
        'scope': 'Exact public templates with declared fixture overlay; isolated mimo-vm engine; no installed app or host network changes.',
        'per_configuration': {profile: dict(Counter(c['result'] for r in matrix + focused if r['profile'] == profile for c in r.get('cases', [])))
                              for profile in ('T4R', 'T4G', 'T6R', 'T6G')},
        'shutdown_observations': [{'profile': r['profile'], **r['shutdown_boundary']} for r in focused if 'shutdown_boundary' in r],
        'qualification_limits': [
            'D03/D04/D07 use this VM\'s own native Tailscale DNS name when no same-tailnet peer exists; the shared-device FQDN is covered separately by F11.',
            'D10 changes temporary default/supplemental DNS and search entries; no physical primary-network switch or saved preference mutation was tested.',
            'D11 injects process death immediately after DNS registration, not an internal engine initialization error.',
            'Shutdown ends standalone route enforcement; queued OS DNS at the former TUN endpoint is recorded separately from active traffic.',
            'No installed-app integration, supplied remote proxy IPv6 qualification, host packet capture, crafted PMTU packet or public NAT64 translator test.'
        ],
    }
    if not summary['not_run']:
        summary['status'] = 'completed_with_failures' if summary['failed_checks'] or any(k.startswith('FAIL') for k in counts) else 'completed_expectations_met'
    if any(r.get('template', {}).get('file', '').startswith('mimo-v3-') for r in matrix + focused):
        summary['scope'] = 'Canonical v3 templates with declared fixture overlay and production core DNS owner; isolated mimo-vm engine campaign, separate from installed-app qualification.'
        summary['qualification_limits'] = [v for v in summary['qualification_limits'] if not v.startswith('Shutdown ends standalone')]
        summary['qualification_limits'].append('The engine does not own system DNS in v3. Core DNS removal/drain is exercised; full PF/launchd teardown is qualified separately by installed tests.')
    output.mkdir(parents=True, exist_ok=True)
    for file, data in [('runtime-summary.json', summary), ('matrix.json', matrix), ('focused.json', focused), ('preliminary-runs.json', earlier)]:
        content = json.dumps(sanitize(data), indent=2) + '\n'
        assert not any(raw in content for raw in replacements), 'Private identity remains in evidence'
        (output / file).write_text(content)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    export(*map(Path, sys.argv[1:3]))
