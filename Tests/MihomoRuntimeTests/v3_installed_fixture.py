#!/usr/bin/env python3
"""Closed Delta fixture for the production installed-app verification path.

Only fixture destinations are reachable. Provider HTTPS and pinned Cloudflare
DoH are served locally over SOCKS; the temporary CA is trusted only in the VM.
No provider token, public DNS query, or application traffic leaves the lab.
"""
import json
import signal
import sys
from pathlib import Path
from dualstack_fixture import Fixture

PROVIDERS = {'api.ipinfo.io', 'v4.api.ipinfo.io', 'v6.api.ipinfo.io', 'ipwho.is',
             'ipapi.co', 'api.ipapi.is', 'api4.ipify.org', 'api6.ipify.org'}


class InstalledFixture(Fixture):
    def destinations(self, name):
        if name.rstrip('.').lower() in PROVIDERS:
            return [self.data4, self.data6]
        return super().destinations(name)

    def target(self, host, port, protocol):
        if host == '2001:db8:33::10' and port in (self.http_port, self.https_port, self.udp_port): return self.data6
        if protocol == 'tcp' and port == 443:
            if host in ('1.1.1.1', '1.0.0.1'):
                return self.data4
            if host in (self.data4, self.data6):
                return host
        return super().target(host, port, protocol)

    def connect_port(self, host, port):
        return self.https_port if port == 443 else port

    def provider_reply(self, host, path, family):
        if host not in PROVIDERS:
            return None
        self.record('provider_http', host=host, family=family)
        ip = '203.0.113.10' if family == 4 else '2001:db8::10'
        return {'ip': ip, 'success': True, 'country': 'Singapore', 'country_code': 'SG',
                'country_name': 'Singapore', 'countryCode': 'SG', 'connection': {'asn': 64500, 'org': 'Mimo lab'}}


if __name__ == '__main__':
    root = Path(sys.argv[1])
    fixture = InstalledFixture(root, *sys.argv[2:6], 'S00')
    (root / 'fixture.json').write_text(json.dumps(fixture.manifest()))
    def finish(*_):
        fixture.done.set()
    signal.signal(signal.SIGTERM, finish)
    signal.signal(signal.SIGINT, finish)
    fixture.done.wait()
