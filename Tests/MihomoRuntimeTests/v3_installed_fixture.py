#!/usr/bin/env python3
"""Closed Delta fixture for the production installed-app verification path.

Only fixture destinations are reachable. Provider HTTPS and pinned Cloudflare
DoH are served locally over SOCKS; the temporary CA is trusted only in the VM.
No provider token, public DNS query, or application traffic leaves the lab.
"""
import json
import signal
import sys
import time
from pathlib import Path
from dualstack_fixture import Fixture

PROVIDERS = {'api.ipinfo.io', 'v4.api.ipinfo.io', 'v6.api.ipinfo.io', 'ipwho.is',
             'ipapi.co', 'api.ipapi.is', 'api4.ipify.org', 'api6.ipify.org'}


class InstalledFixture(Fixture):
    def __init__(self, *args, loopback_provider_alias=False):
        self.provider_alias = None
        super().__init__(*args)
        if loopback_provider_alias:
            from v3_provider_alias import ProviderAliasEndpoints
            self.provider_alias = ProviderAliasEndpoints(self, PROVIDERS)

    def destinations(self, name):
        if name.rstrip('.').lower() in PROVIDERS:
            return [self.data4, self.data6]
        return super().destinations(name)

    def target(self, host, port, protocol):
        if (self.provider_alias is not None and protocol == 'tcp' and port == 443
                and (host == '127.0.0.1' or host in self.provider_alias.names)):
            return self.data4
        if host == '2001:db8:33::10' and port in (self.http_port, self.https_port, self.udp_port): return self.data6
        if protocol == 'tcp' and port == 443:
            if host in ('1.1.1.1', '1.0.0.1'):
                return self.data4
            if host in (self.data4, self.data6):
                return host
        return super().target(host, port, protocol)

    def connect_port(self, host, port):
        if (self.provider_alias is not None and port == 443
                and (host == '127.0.0.1' or host in self.provider_alias.names)):
            return self.provider_alias.proxy.server_address[1]
        if self.provider_alias is not None and host == self.data4 and port == 443:
            return self.provider_alias.configured_dns.server_address[1]
        return self.https_port if port == 443 else port

    def manifest(self):
        return dict(super().manifest(), **(self.provider_alias.manifest() if self.provider_alias else {}))

    def provider_reply(self, host, path, family):
        if host not in PROVIDERS:
            return None
        self.record('provider_http', host=host, family=family)
        ip = getattr(self, 'provider_ip', '203.0.113.10') if family == 4 else '2001:db8::10'
        time.sleep(getattr(self, 'provider_delay', 0))
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
