#!/usr/bin/env python3
"""Explicit guest-administrator test of the real installer and launchd lifecycle.

Only runs in a fresh VirtualMac guest. Installs the staged app services, checks
Direct and stopped-job persistence, and leaves a successful installation running.
On failure it invokes the installed uninstaller. Never writes qualification evidence
or loads an active Rule/Global profile. Reboot/TUN/IPv6 acceptance is separate.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

CORE = "com.example.exitipmonitor.daemon"
SUPERVISOR = "com.example.exitipmonitor.supervisor"
ENGINE = "com.example.exitipmonitor.mihomo"
SUPPORT = Path("/Library/Application Support/ExitIPMonitor")
RUNTIME = SUPPORT / "Mihomo"
APP = Path("/Users/jay/Applications/ExitIPMonitor.app")


def run():
    if os.geteuid() != 0:
        sys.exit("Run with guest sudo: sudo /usr/bin/python3 ~/mimo-tests/runtime/installation_test.py")
    model = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
    if not model.startswith("VirtualMac"):
        sys.exit("This test only runs inside an Apple VirtualMac guest.")
    for label in (CORE, SUPERVISOR, ENGINE):
        result = subprocess.run(["/bin/launchctl", "print", "system/" + label], capture_output=True)
        if result.returncode != 113:
            sys.exit("A Mimo service already exists or cannot be inspected; fresh-install test stopped.")
    if (SUPPORT / "Service/state.plist").exists():
        sys.exit("Saved Mimo machine configuration exists; fresh-install test stopped.")
    base = Path(__file__).resolve().parent
    evidence = Path(tempfile.mkdtemp(prefix="mimo-installation-test-", dir="/var/tmp"))
    completed = []
    success = False

    def command(name, arguments, timeout=30):
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate(timeout=5)
            (evidence / (name + ".log")).write_text(output)
            raise
        (evidence / (name + ".log")).write_text(output)
        if process.returncode:
            raise RuntimeError(name + " failed; see " + str(evidence / (name + ".log")))
        return output

    def state(*arguments):
        text = command("last-state", [str(base / "installation-check")] + list(arguments))
        return json.loads(text)

    def wait_for(predicate, name):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                value = state()
                if predicate(value):
                    network = command('last-ipv6-state', ['/usr/sbin/networksetup', '-getinfo', 'Ethernet'])
                    assert 'IPv6: Off' in network, 'Installed Mimo must keep IPv6 disabled'
                    (evidence / (name + ".json")).write_text(json.dumps(value, indent=2))
                    completed.append(name)
                    print("PASS:", name, flush=True)
                    return value
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.5)
        raise RuntimeError(name + " timed out")

    def health(value, service):
        return next(s["health"] for s in value["services"] if s["id"] == service)

    def direct(value):
        return (value["phase"] == "active" and value.get("effectiveMode") == "direct"
                and (RUNTIME / "gate.state").read_text() == "direct")

    def engine_pid():
        result = subprocess.run(["/bin/launchctl", "print", "system/" + ENGINE], capture_output=True, text=True, timeout=5)
        match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
        return match[1] if match else None

    try:
        command("install", ["/usr/bin/env", "SUDO_USER=jay", "/bin/bash",
                            str(APP / "Contents/Resources/daemon.sh"), "install"], timeout=150)
        wait_for(lambda s: direct(s) and health(s, "core") == "running" and health(s, "mihomo") == "running",
                 "fresh-install-restores-Direct")
        with socket.create_connection(("1.1.1.1", 443), timeout=5):
            pass
        for label, group in ((CORE, None), (ENGINE, "_mimo")):
            plist = plistlib.loads((SUPPORT / "LaunchDaemons" / (label + ".plist")).read_bytes())
            assert plist.get("GroupName") == group
            assert not Path("/Library/LaunchDaemons", label + ".plist").exists()
        assert not (RUNTIME / "qualification.json").exists()
        state("core", "stop")
        wait_for(lambda s: direct(s) and health(s, "core") == "stopped", "core-stop-preserves-Direct")
        command('attempt-enable-ipv6', ['/usr/sbin/networksetup', '-setv6automatic', 'Ethernet'])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if 'IPv6: Off' in command('ipv6-reenforcement', ['/usr/sbin/networksetup', '-getinfo', 'Ethernet']):
                break
            time.sleep(0.25)
        else:
            raise AssertionError('Supervisor did not restore IPv4-only policy while core was stopped')
        completed.append('network-change-reenforces-IPv4-with-core-stopped')
        print('PASS: network-change-reenforces-IPv4-with-core-stopped', flush=True)
        command("restart-supervisor", ["/bin/launchctl", "kickstart", "-k", "system/" + SUPERVISOR])
        wait_for(lambda s: direct(s) and health(s, "core") == "stopped", "core-stop-survives-supervisor-restart")
        state("mihomo", "stop")
        wait_for(lambda s: direct(s) and health(s, "mihomo") == "stopped", "engine-stop-preserves-Direct")
        command("restart-supervisor-stopped", ["/bin/launchctl", "kickstart", "-k", "system/" + SUPERVISOR])
        wait_for(lambda s: direct(s) and health(s, "core") == "stopped" and health(s, "mihomo") == "stopped",
                 "stopped-jobs-remain-stopped")
        state("mihomo", "start")
        wait_for(lambda s: direct(s) and health(s, "mihomo") == "running", "engine-start-restores-Direct")
        denied = state("unqualified-rule")
        assert denied["phase"] == "blocked" and denied.get("effectiveMode") is None
        assert not (RUNTIME / "qualification.json").exists()
        (evidence / "unqualified-rule.json").write_text(json.dumps(denied, indent=2))
        completed.append("unqualified-Rule-remains-blocked")
        print("PASS: unqualified-Rule-remains-blocked", flush=True)
        state("direct")
        wait_for(direct, "explicit-Direct-recovers")
        state("core", "start")
        wait_for(lambda s: direct(s) and health(s, "core") == "running", "core-start-recovers")
        old_pid = engine_pid()
        assert old_pid is not None
        command("kill-engine", ["/bin/launchctl", "kill", "SIGKILL", "system/" + ENGINE])
        # Wait until launchd has actually replaced the engine, not just returned a
        # stale running status immediately after delivering the signal.
        time.sleep(12)
        wait_for(lambda s: direct(s) and health(s, "mihomo") == "running" and engine_pid() not in (None, old_pid),
                 "engine-crash-restarts-with-Direct-recovery")
        with socket.create_connection(("1.1.1.1", 443), timeout=5):
            pass
        command("check-installation", ["/Library/PrivilegedHelperTools/mimo-core", "--check-installation"])
        success = True
    finally:
        if not success:
            manager = Path("/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage")
            if manager.exists():
                result = subprocess.run([str(manager), "uninstall"], capture_output=True, text=True, timeout=150)
                (evidence / "failure-cleanup.log").write_text(result.stdout + result.stderr)
            # Fresh VM test only: retain an offline recovery path even when the
            # install failed before copying its privileged manager into place.
            for label in (CORE, ENGINE, SUPERVISOR):
                subprocess.run(["/bin/launchctl", "bootout", "system/" + label], capture_output=True, timeout=15)
            recovery = subprocess.run([str(APP / "Contents/MacOS/mimo-core"), "--restore-direct-offline"],
                                      capture_output=True, text=True, timeout=30)
            (evidence / "offline-recovery.log").write_text(recovery.stdout + recovery.stderr)
        (evidence / "report.json").write_text(json.dumps({"success": success, "passed": completed,
            "scope": "Installer/Direct/lifecycle only; no protected routing qualification"}, indent=2) + "\n")
        for path in evidence.iterdir():
            path.chmod(0o644)
        evidence.chmod(0o755)
        print("Evidence:", evidence, flush=True)


if __name__ == "__main__":
    run()
