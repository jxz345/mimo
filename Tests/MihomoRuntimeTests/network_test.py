#!/usr/bin/env python3
"""Bounded supervisor network-event acceptance in the unconfigured test VM.

Temporarily initializes anonymous Direct monitoring, changes one documentation-only
route and DNS setting, verifies immediate check requests, then tests observation with
core stopped in saved Global. Restores DNS, routes, settings and service preferences.
Does not qualify active protected routing or create a qualification manifest.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

from upgrade_test import (CORE, SUPERVISOR, ENGINE, SUPPORT, RUNTIME, STORAGE, FLAGS,
                          HELPER, read_settings, write_settings, atomic_write)


def run():
    assert os.geteuid() == 0, "Run through the guest administrator"
    assert subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).startswith("VirtualMac")
    original = read_settings()
    routing = json.loads(original.get("service.routing", b"{}"))
    assert "service.settings" not in original and not routing.get("proxy") and routing.get("mode", "direct") == "direct"
    assert not (RUNTIME / "qualification.json").exists()
    original_flags = FLAGS.read_bytes()
    assert all(json.loads(original_flags).values())
    evidence = Path(tempfile.mkdtemp(prefix="mimo-network-test-", dir="/var/tmp"))
    backup = evidence / "private-backup"
    backup.mkdir(mode=0o700)
    (backup / "settings.plist").write_bytes(plistlib.dumps(original))
    (backup / "services.json").write_bytes(original_flags)
    base = Path(__file__).resolve().parent
    passed = []
    added = False
    dns_changed = False
    success = False
    dns = subprocess.check_output(["/usr/sbin/networksetup", "-getdnsservers", "Ethernet"], text=True).splitlines()
    original_dns = ["Empty"] if len(dns) == 1 and "There aren't any DNS Servers" in dns[0] else dns
    assert original_dns and len(original_dns) <= 8

    def command(*args, timeout=30):
        return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT, timeout=timeout)

    def state(*args):
        value = json.loads(command(base / "installation-check", *args))
        assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet')
        return value

    def check(name):
        passed.append(name)
        print("PASS:", name, flush=True)

    def mark():
        return {p: p.stat().st_size for p in Path("/Library/Logs/ExitIPMonitor").glob("runtime-*.jsonl")}

    def events(offsets):
        values = []
        for path in Path("/Library/Logs/ExitIPMonitor").glob("runtime-*.jsonl"):
            with path.open("rb") as stream:
                stream.seek(offsets.get(path, 0))
                for line in stream:
                    try:
                        value = json.loads(line)
                        if value["event"] in ("mimo_network_changed", "refresh_requested", "mimo_gate_closed"):
                            values.append(value)
                    except (ValueError, KeyError):
                        pass
        return values

    def wait_event(offsets, source, require_check, name):
        start = time.monotonic()
        while time.monotonic() - start < 8:
            records = events(offsets)
            observed = any(v["event"] == "mimo_network_changed" and v["fields"].get("source") == source for v in records)
            refreshed = any(v["event"] == "refresh_requested" and v["fields"].get("trigger") == "network_configuration" for v in records)
            if observed and (refreshed or not require_check):
                (evidence / (name + ".json")).write_text(json.dumps({"elapsed": time.monotonic() - start, "events": records}, indent=2))
                check(name)
                return
            time.sleep(0.1)
        raise AssertionError(name + " did not produce the immediate supervisor/core events")

    def wait_state(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                value = state()
                if predicate(value):
                    return value
            except subprocess.SubprocessError:
                pass
            time.sleep(0.2)
        raise AssertionError("service state did not settle")

    def restart():
        command("/bin/launchctl", "kickstart", "-k", "system/" + SUPERVISOR)

    try:
        state("core", "stop")
        settings = dict(original)
        settings["service.settings"] = json.dumps({"provider": "ipWhois", "providerPool": ["ipWhois", "ipapiCo", "ipapiIs"],
            "refreshInterval": 900, "allowlist": {"addresses": []},
            "diagnostics": {"includeFullIPAddresses": False, "retentionDays": 7}, "tailscaleProviderEnabled": False}).encode()
        settings["service.revision"] = original.get("service.revision", 0) + 1
        write_settings(settings)
        state("core", "start")
        wait_state(lambda s: s.get("effectiveMode") == "direct")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            core = state("core-state")
            if core["initialized"] and core["protocolVersion"] == 5:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("initialized protocol-5 core unavailable")
        check("anonymous-Direct-monitoring-initialized")

        before = mark()
        command("/sbin/route", "-n", "add", "-host", "203.0.113.254", "192.168.64.1")
        added = True
        wait_event(before, "route", True, "route-change-requests-immediate-check")
        before = mark()
        command("/sbin/route", "-n", "delete", "-host", "203.0.113.254")
        added = False
        wait_event(before, "route", True, "second-route-change-does-not-wait-for-interval")

        before = mark()
        dns_changed = True
        command("/usr/sbin/networksetup", "-setdnsservers", "Ethernet", "203.0.113.53")
        wait_event(before, "configuration", True, "DNS-change-requests-immediate-check")
        before = mark()
        command("/usr/sbin/networksetup", "-setdnsservers", "Ethernet", *original_dns)
        dns_changed = False
        wait_event(before, "configuration", True, "DNS-restoration-requests-immediate-check")
        assert state().get("effectiveMode") == "direct"
        check("network-events-preserve-Direct-access")

        state("core", "stop")
        settings = read_settings()
        settings["service.routing"] = json.dumps({"mode": "global", "mihomoEnabled": True, "profileHostingEnabled": True}).encode()
        settings["service.revision"] += 1
        write_settings(settings)
        restart()
        wait_state(lambda s: s["phase"] == "blocked")
        before = mark()
        command("/sbin/route", "-n", "add", "-host", "203.0.113.254", "192.168.64.1")
        added = True
        wait_event(before, "route", False, "supervisor-observes-network-with-core-stopped")
        value = state()
        assert value["phase"] == "blocked" and (RUNTIME / "gate.state").read_text() == "blocked"
        assert next(s for s in value["services"] if s["id"] == "core")["health"] == "stopped"
        check("protected-network-change-retains-blocking-and-core-Stop")
        success = True
    finally:
        if dns_changed:
            command("/usr/sbin/networksetup", "-setdnsservers", "Ethernet", *original_dns)
        if added:
            command("/sbin/route", "-n", "delete", "-host", "203.0.113.254")
        for label in (CORE, ENGINE, SUPERVISOR):
            subprocess.run(["/bin/launchctl", "bootout", "system/" + label], capture_output=True, timeout=20)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                inspection = subprocess.run(["/bin/launchctl", "print", "system/" + label], capture_output=True, timeout=3)
                if inspection.returncode == 113:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("launchd did not finish unloading " + label)
        write_settings(original)
        atomic_write(FLAGS, original_flags)
        command(HELPER, "--restore-direct-offline")
        command("/bin/launchctl", "bootstrap", "system", "/Library/LaunchDaemons/" + SUPERVISOR + ".plist")
        wait_state(lambda s: s.get("effectiveMode") == "direct")
        check("original-settings-services-and-Direct-restored")
        (evidence / "report.json").write_text(json.dumps({"success": success, "passed": passed}, indent=2))
        for path in evidence.iterdir():
            if path.is_file(): path.chmod(0o644)
        evidence.chmod(0o755)
        print("Evidence:", evidence, flush=True)


if __name__ == "__main__":
    run()
