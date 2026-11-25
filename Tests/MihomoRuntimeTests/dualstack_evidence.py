#!/usr/bin/env python3
"""Export sanitized campaign results; never copy private inputs or packet files."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys


def main():
    campaign, out = map(Path, sys.argv[1:3])
    out.mkdir(parents=True, exist_ok=True)
    runs = []
    replacements = {}
    for path in campaign.glob('*/report.json'):
        report = json.loads(path.read_text())
        fixture_path = path.parent / 'fixture.json'
        if fixture_path.exists():
            f = json.loads(fixture_path.read_text())
            for key in ('bridge4', 'data4', 'data6', 'client4', 'token'):
                replacements[f[key]] = '<' + key.upper() + '>'
            peer = f.get('native_peer', {})
            if peer.get('name'):
                replacements[peer['name']] = '<NATIVE_PEER_NAME>'
                replacements[peer['name'].rstrip('.')] = '<NATIVE_PEER_NAME>'
            for address in peer.get('addresses', []):
                replacements[address] = '<NATIVE_PEER_IPV6>' if ':' in address else '<NATIVE_PEER_IPV4>'
        runs.append((path.parent.name, report))
    replacements = dict(sorted(replacements.items(), key=lambda x: -len(x[0])))

    def sanitize(value):
        if isinstance(value, dict):
            return {k: sanitize(v) for k, v in value.items()}
        if isinstance(value, list):
            return [sanitize(v) for v in value]
        if isinstance(value, str):
            for a, b in replacements.items():
                value = value.replace(a, b)
        return value

    matrix = sorted([(n, r) for n, r in runs if r['scope'] == 'matrix'], key=lambda x: (x[1]['profile'], x[1]['proxy_mode']))
    assert len(matrix) == 48 and len({(r['profile'], r['proxy_mode']) for _, r in matrix}) == 48
    assert all(r['passed'] and len(r['cases']) == 130 for _, r in matrix)
    counts = Counter()
    with (out / 'matrix-cases.jsonl').open('w') as stream:
        for name, report in matrix:
            counts.update(report['counts'])
            for case in report['cases']:
                row = {'profile': report['profile'], 'proxy_mode': report['proxy_mode'], **case}
                stream.write(json.dumps(sanitize(row), separators=(',', ':')) + '\n')
    assert sum(counts.values()) == 6240
    focused = {}
    for name, report in sorted(runs, key=lambda x: x[1]['tested_at_utc']):
        if report['scope'] not in ('matrix', 'smoke') and report['status'] == 'complete':
            focused[(report['profile'], report['scope'])] = (name, report)
    assert len(focused) == 8
    focused_counts = Counter()
    for _, report in focused.values():
        focused_counts.update(report['counts'])
    full_focused = [{'run': name, **r} for name, r in focused.values()]
    (out / 'focused.json').write_text(json.dumps(sanitize(full_focused), indent=2) + '\n')
    failures = [{'run': name, 'profile': report['profile'], **case}
                for name, report in focused.values() for case in report['cases'] if case['result'].startswith('FAIL')]
    assert len(failures) == 1 and failures[0]['profile'] == 'P09'
    selected = {name for name, _ in matrix} | {name for name, _ in focused.values()}
    earlier = [{'run': name, 'profile': r['profile'], 'scope': r['scope'], 'passed': r['passed'],
                'status': r['status'], 'counts': r['counts'], 'error': r.get('error'),
                'failed_checks': [k for k, v in r['checks'].items() if not v]}
               for name, r in runs if name not in selected]
    (out / 'preliminary-runs.json').write_text(json.dumps(sanitize(earlier), indent=2) + '\n')
    summary = {
        'status': 'candidate_qualified_with_documented_limits',
        'tested_date': '2026-11-24',
        'scope': 'Controlled Delta IPv4/IPv6 services and SOCKS5; isolated mimo-vm engine. No installed app change.',
        'engine_sha256': matrix[0][1]['engine_sha256'],
        'candidate_profile': 'P07',
        'working_profile_unchanged': True,
        'matrix': {'cells': 48, 'cases': 6240, 'counts': dict(counts), 'all_expectations_met': True,
                   'cells_detail': [{'run': n, 'profile': r['profile'], 'proxy_mode': r['proxy_mode'],
                                     'runner_sha256': r['runner_sha256'], 'profile_sha256': r['profile_sha256'],
                                     'counts': r['counts'], 'checks': r['checks'], 'packets': r['packets']} for n, r in matrix]},
        'focused': {'counts': dict(focused_counts), 'differences': failures},
        'limits': [
            'The supplied remote proxy was not tested for IPv6 egress; all destination services were on Delta.',
            'No standalone kill switch after engine exit or for intentionally native/interface-bound traffic.',
            'Automatic IPv4 retry did not occur in the tested IPv6-refusal/stall cases; explicit proxied IPv4 retry succeeded.',
            'Core profile keeps macOS DNS registration disabled; P10 separately qualified system DNS and Safari then restored it.',
            'NAT64 fixture mapping qualifies capture and SOCKS transport, not public NAT64 translation.',
            'Host BPF capture requires unavailable root access; VM captures plus actual host socket/service records were used.',
            'No crafted ICMPv6 Packet Too Big injection; existing no-ping packet-handler unit tests cover retaining control/error handling.',
            'Unrelated existing QUIC and native Tailscale transport packets are reported separately from exact fixture flows.'
        ],
    }
    final_checks_path = out / 'final-checks.json'
    if final_checks_path.exists():
        final_checks = json.loads(final_checks_path.read_text())
        assert final_checks['all_passed'] and all(final_checks['checks'].values())
        summary['final_verification'] = final_checks
    summary['artifacts'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.name != 'summary.json'}
    (out / 'summary.json').write_text(json.dumps(sanitize(summary), indent=2) + '\n')
    for path in out.iterdir():
        data = path.read_text()
        assert all(raw not in data for raw in replacements), 'Private fixture identity remained in evidence'
    print(json.dumps({'matrix': dict(counts), 'focused': dict(focused_counts), 'diagnostic_differences': len(failures)}))


if __name__ == '__main__':
    main()
