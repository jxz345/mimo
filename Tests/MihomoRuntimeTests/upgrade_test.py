#!/usr/bin/env python3
"""Guest-admin acceptance for an existing, unconfigured development installation.

Exercises replacement, saved-mode recovery, stopped-service intent, and retained
settings across uninstall/reinstall. Uses only blocking profiles and Direct.
Refuses a physical Mac, initialized user settings, or a qualification manifest.
No reboot or active protected-routing qualification is performed.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
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
STORAGE = SUPPORT / "Service/state.plist"
FLAGS = RUNTIME / "services.json"
HELPER = Path("/Library/PrivilegedHelperTools/mimo-core")
MANAGER = Path("/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage")
APP = Path("/Users/jay/Applications/ExitIPMonitor.app")


def read_settings():
    return plistlib.loads(STORAGE.read_bytes()) if STORAGE.exists() else {}


def atomic_write(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".upgrade-test-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_settings(settings):
    # Same kernel-held lock as core and the production recovery command.
    with open(STORAGE.parent / "instance.lock", "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        atomic_write(STORAGE, plistlib.dumps(settings, fmt=plistlib.FMT_BINARY))


def run():
    if os.geteuid() != 0:
        sys.exit("Run with guest sudo: sudo /usr/bin/python3 ~/mimo-tests/runtime/upgrade_test.py")
    model = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
    if not model.startswith("VirtualMac"):
        sys.exit("This test only runs inside an Apple VirtualMac guest.")
    if not HELPER.exists() or not FLAGS.exists() or not APP.exists():
        sys.exit("Install the fresh-test services and stage the signed candidate app first.")
    if (RUNTIME / "qualification.json").exists():
        sys.exit("This test refuses a qualified routing installation.")
    original = read_settings()
    original_routing = json.loads(original.get("service.routing", b"{}"))
    if "service.settings" in original or original_routing.get("proxy") or original_routing.get("mode", "direct") != "direct":
        sys.exit("This test requires the unconfigured Direct installation from installation_test.py.")
    original_flags = FLAGS.read_bytes()
    if not all(json.loads(original_flags).get(key) for key in ("core", "engine", "profile")):
        sys.exit("Start core, mihomo and profile hosting before this test.")
    base = Path(__file__).resolve().parent
    evidence = Path(tempfile.mkdtemp(prefix="mimo-upgrade-test-", dir="/var/tmp"))
    backup = evidence / "private-backup"
    backup.mkdir(mode=0o700)
    (backup / "state.plist").write_bytes(plistlib.dumps(original))
    (backup / "services.json").write_bytes(original_flags)
    completed = []
    success = False

    def command(name, arguments, timeout=30):
        process = subprocess.Popen([str(a) for a in arguments], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
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
        return json.loads(command("last-state", [base / "installation-check", *arguments]))

    def passed(name):
        completed.append(name)
        print("PASS:", name, flush=True)

    def health(value, service):
        return next(s["health"] for s in value["services"] if s["id"] == service)

    def direct(value):
        return (value["phase"] == "active" and value.get("effectiveMode") == "direct"
                and (RUNTIME / "gate.state").read_text() == "direct")

    def blocked(value):
        return (value["phase"] == "blocked" and value.get("effectiveMode") is None
                and (RUNTIME / "gate.state").read_text() == "blocked")

    def wait_for(predicate, name):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                value = state()
                if predicate(value):
                    assert 'IPv6: Off' in command('ipv6-policy', ['/usr/sbin/networksetup', '-getinfo', 'Ethernet'])
                    (evidence / (name + ".json")).write_text(json.dumps(value, indent=2))
                    passed(name)
                    return value
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.5)
        raise RuntimeError(name + " timed out")

    def restart_supervisor(name):
        command(name, ["/bin/launchctl", "kickstart", "-k", "system/" + SUPERVISOR])

    def install(name):
        command(name, ["/usr/bin/env", "SUDO_USER=jay", "/bin/bash",
                       APP / "Contents/Resources/daemon.sh", "install"], timeout=180)

    def failed_upgrade(name, protected):
        # Fault injection lives only in a separately signed test bundle. Production
        # installer code has no environment variable or switch that bypasses readiness.
        fixture = backup / name / "ExitIPMonitor.app"
        command(name + "-copy", ["/usr/bin/ditto", APP, fixture])
        script = fixture / "Contents/Resources/daemon.sh"
        source = script.read_text()
        check = 'bounded_command 30 check-services "$EXECUTABLE" --check-installation || return 1'
        assert source.count(check) == 1
        script.write_text(source.replace(check, 'echo "Injected final readiness failure" >&2; return 1'))
        command(name + "-sign", ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", fixture])
        before_helper = hashlib.sha256(HELPER.read_bytes()).digest()
        before_settings = read_settings()
        before_flags = FLAGS.read_bytes()
        before_app = (SUPPORT / "installed-app").read_bytes()
        result = subprocess.run(["/usr/bin/env", "SUDO_USER=jay", "/bin/bash", str(script), "install"],
                                capture_output=True, text=True, timeout=180)
        (evidence / (name + ".log")).write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and "previous files and loaded services were restored" in result.stderr
        assert hashlib.sha256(HELPER.read_bytes()).digest() == before_helper
        assert read_settings() == before_settings
        assert json.loads(FLAGS.read_bytes()) == json.loads(before_flags)
        assert (SUPPORT / "installed-app").read_bytes() == before_app
        assert not (RUNTIME / "maintenance").exists()
        wait_for(blocked if protected else direct, name)
        if not protected:
            connected()

    def seed_protected(mode):
        state("core", "stop")
        settings = read_settings()
        revision = settings.get("service.revision", 0) + 1
        routing = {"mode": mode, "proxy": {"name": "Recovery fixture", "type": "http",
                   "server": "127.0.0.1", "port": 9, "username": ""},
                   "profileHostingEnabled": True, "mihomoEnabled": True}
        settings.update({"service.routing": json.dumps(routing).encode(), "service.revision": revision,
                         "mimo.upgrade-test.marker": "must-survive-recovery"})
        write_settings(settings)
        restart_supervisor("load-" + mode + "-fixture")
        wait_for(lambda s: blocked(s) and health(s, "core") == "stopped", mode + "-fixture-blocked")
        return routing, revision

    def connected():
        with socket.create_connection(("1.1.1.1", 443), timeout=5):
            pass

    def core_confirms_direct(name):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = state("core-state")
            routing = value.get("routing") or {}
            if (value["protocolVersion"] == 5 and routing.get("phase") == "active"
                    and routing.get("effectiveMode") == "direct"):
                (evidence / (name + ".json")).write_text(json.dumps(value, indent=2))
                passed(name)
                return
            time.sleep(0.5)
        raise RuntimeError("Core did not confirm Direct using the ordered protocol")

    try:
        install("upgrade")
        assert hashlib.sha256(HELPER.read_bytes()).digest() == hashlib.sha256(
            (APP / "Contents/MacOS/mimo-core").read_bytes()).digest()
        wait_for(lambda s: direct(s) and health(s, "core") == "running" and health(s, "mihomo") == "running",
                 "upgrade-preserves-Direct")
        core_confirms_direct("core-ordered-protocol-confirms-Direct")
        failed_upgrade("failed-upgrade-restores-Direct", protected=False)
        for enabled, mode in ((False, "rule"), (True, "global")):
            routing, revision = seed_protected(mode)
            if enabled:
                state("core", "start")
                wait_for(lambda s: blocked(s) and health(s, "core") == "running", "protected-core-started")
            command("recover-" + mode, [HELPER, "--recover-direct"])
            saved = read_settings()
            expected = dict(routing, mode="direct")
            assert json.loads(saved["service.routing"]) == expected
            assert saved["service.revision"] == revision + 1
            assert saved["mimo.upgrade-test.marker"] == "must-survive-recovery"
            assert json.loads(FLAGS.read_bytes())["core"] == enabled
            restart_supervisor("restart-after-" + mode + "-recovery")
            wait_for(lambda s: direct(s) and health(s, "core") == ("running" if enabled else "stopped"),
                     mode + "-recovery-saved-across-restart")
            connected()

        for service in ("core", "mihomo", "profileHosting"):
            state(service, "stop")
        install("upgrade-stopped-services")
        wait_for(lambda s: direct(s) and all(health(s, service) == "stopped" for service in
                 ("core", "mihomo", "profileHosting")), "upgrade-retains-stopped-services")
        command('attempt-enable-ipv6', ['/usr/sbin/networksetup', '-setv6automatic', 'Ethernet'])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if 'IPv6: Off' in command('ipv6-reenforcement', ['/usr/sbin/networksetup', '-getinfo', 'Ethernet']):
                break
            time.sleep(0.25)
        else:
            raise AssertionError('Supervisor did not restore IPv4-only policy while core was stopped')
        passed('network-change-reenforces-IPv4-with-core-and-engine-stopped')
        for service in ("mihomo", "profileHosting", "core"):
            state(service, "start")
        wait_for(direct, "stopped-upgrade-recovers")

        seed_protected("global")
        install("upgrade-protected")
        wait_for(blocked, "protected-upgrade-remains-blocked")
        failed_upgrade("failed-upgrade-retains-protection", protected=True)
        assert not (RUNTIME / "qualification.json").exists()
        before_uninstall = read_settings()
        command("uninstall", [MANAGER, "uninstall"], timeout=180)
        for label in (CORE, SUPERVISOR, ENGINE):
            result = subprocess.run(["/bin/launchctl", "print", "system/" + label], capture_output=True, timeout=5)
            assert result.returncode == 113
        assert not HELPER.exists() and not MANAGER.exists() and not (RUNTIME / "mihomo").exists()
        assert not Path("/etc/sudoers.d/exitipmonitor-service").exists()
        assert read_settings() == before_uninstall
        assert (RUNTIME / "gate.state").read_text() == "direct"
        assert Path("/opt/homebrew/opt/mihomo@1.19.34/bin/mihomo").exists()
        connected()
        passed("uninstall-restores-network-and-retains-settings")

        install("retained-settings-reinstall")
        wait_for(blocked, "reinstall-retains-protected-selection")
        command("recover-reinstalled", [HELPER, "--recover-direct"])
        wait_for(direct, "reinstalled-Direct-recovery")

        # Remove only test fixtures; preserve all original machine settings.
        state("core", "stop")
        write_settings(original)
        atomic_write(FLAGS, original_flags)
        restart_supervisor("restore-original-settings")
        wait_for(lambda s: direct(s) and health(s, "core") == "running" and health(s, "mihomo") == "running",
                 "original-settings-restored")
        core_confirms_direct("core-reconnects-after-supervisor-restart")
        connected()
        success = True
    finally:
        if not success:
            # Keep the private backup for diagnosis. Stop test jobs before offline
            # recovery so no stale protected request can replace the restored gate.
            for label in (CORE, ENGINE, SUPERVISOR):
                subprocess.run(["/bin/launchctl", "bootout", "system/" + label], capture_output=True, timeout=20)
            write_settings(original)
            atomic_write(FLAGS, original_flags)
            result = subprocess.run([str(APP / "Contents/MacOS/mimo-core"), "--restore-direct-offline"],
                                    capture_output=True, text=True, timeout=30)
            (evidence / "failure-offline-recovery.log").write_text(result.stdout + result.stderr)
        (evidence / "report.json").write_text(json.dumps({"success": success, "passed": completed,
            "scope": "Development upgrade/recovery/uninstall only; no reboot or protected routing qualification"}, indent=2) + "\n")
        for path in evidence.iterdir():
            if path.is_file():
                path.chmod(0o644)
        evidence.chmod(0o755)
        print("Evidence:", evidence, flush=True)


if __name__ == "__main__":
    run()
