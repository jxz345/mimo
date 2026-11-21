#!/usr/bin/env python3
"""One-reboot, guest-admin acceptance of protected startup and saved Stop intent.

Installs the staged candidate, then installs a fixed, temporary root boot worker.
The worker runs without login, verifies the closed gate and current-boot PF token,
restores the original unconfigured Direct settings, and removes its launch job.
No qualification record, active TUN profile, or general-purpose root grant is made.
"""
import fcntl
import grp
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CORE = "com.mimo.core"
SUPERVISOR = "com.mimo.supervisor"
ENGINE = "com.mimo.mihomo"
JOB = "com.mimo.boot-acceptance"
JOB_PLIST = Path("/Library/LaunchDaemons") / (JOB + ".plist")
SUPPORT = Path("/Library/Application Support/Mimo")
RUNTIME = SUPPORT / "Runtime"
STORAGE = SUPPORT / "Service/state.plist"
FLAGS = RUNTIME / "services.json"
WORK = SUPPORT / "BootAcceptance"
HELPER = Path("/Library/PrivilegedHelperTools/mimo-core")
APP = Path("/Users/jay/Applications/Mimo.app")
EVIDENCE = None
PASSED = []


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
        (EVIDENCE / (name + ".log")).write_text(output)
        raise
    (EVIDENCE / (name + ".log")).write_text(output)
    if process.returncode:
        raise RuntimeError(name + " failed; see " + str(EVIDENCE / (name + ".log")))
    return output


def boot_id():
    return subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], text=True).strip()


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".boot-test-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_settings(data):
    with open(STORAGE.parent / "instance.lock", "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        atomic_write(STORAGE, data)


def state(*arguments):
    return json.loads(command("last-state", [WORK / "installation-check", *arguments]))


def health(value, service):
    return next(s["health"] for s in value["services"] if s["id"] == service)


def blocked(value):
    return (value["phase"] == "blocked" and value.get("effectiveMode") is None
            and (RUNTIME / "gate.state").read_text() == "blocked")


def direct(value):
    return (value["phase"] == "active" and value.get("effectiveMode") == "direct"
            and (RUNTIME / "gate.state").read_text() == "direct")


def passed(name):
    PASSED.append(name)
    print("PASS:", name, flush=True)


def wait_for(predicate, name):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            value = state()
            if predicate(value):
                assert 'IPv6: Off' in command('ipv6-policy', ['/usr/sbin/networksetup', '-getinfo', 'Ethernet'])
                (EVIDENCE / (name + ".json")).write_text(json.dumps(value, indent=2))
                passed(name)
                return value
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.5)
    raise RuntimeError(name + " timed out")


def public_probe(expect_connected):
    account = pwd.getpwnam("jay")
    assert account.pw_uid != 0 and account.pw_gid != grp.getgrnam("_mimo").gr_gid
    def ordinary_user():
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
    code = """import socket, sys
try:
    s=socket.create_connection(('1.1.1.1',443),timeout=3)
    s.close()
except OSError as error:
    print(type(error).__name__)
    sys.exit(2)
"""
    result = subprocess.run(["/usr/bin/python3", "-I", "-c", code], capture_output=True,
                            text=True, preexec_fn=ordinary_user, timeout=6)
    (EVIDENCE / ("public-connected.log" if expect_connected else "public-blocked.log")).write_text(
        result.stdout + result.stderr)
    if result.returncode != (0 if expect_connected else 2):
        raise RuntimeError("Ordinary public TCP did not match the expected gate state")


def restore_original():
    # Stop every actor before replacing the test settings; offline Direct recovery
    # does not depend on a working XPC endpoint or a login session.
    for label in (CORE, ENGINE, SUPERVISOR):
        subprocess.run(["/bin/launchctl", "bootout", "system/" + label], capture_output=True, timeout=20)
    write_settings((WORK / "original.plist").read_bytes())
    atomic_write(FLAGS, (WORK / "original-services.json").read_bytes())
    command("offline-Direct-recovery", [HELPER, "--restore-direct-offline"])
    command("restore-supervisor", ["/bin/launchctl", "bootstrap", "system",
                                   "/Library/LaunchDaemons/" + SUPERVISOR + ".plist"])
    wait_for(lambda s: direct(s) and health(s, "core") == "running" and health(s, "mihomo") == "running",
             "original-Direct-services-restored")


def finish(success, error=None):
    report = {"success": success, "passed": PASSED, "error": error,
              "boot": boot_id(), "consoleUser": pwd.getpwuid(os.stat("/dev/console").st_uid).pw_name,
              "scope": "Post-startup protected gate, saved Stop intent and PF boot reference only; no active TUN/IPv6/tailnet or packet qualification"}
    (EVIDENCE / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    for path in EVIDENCE.iterdir():
        if path.is_file():
            path.chmod(0o644)
    EVIDENCE.chmod(0o755)
    if JOB_PLIST.exists():
        JOB_PLIST.unlink()
    print("Evidence:", EVIDENCE, flush=True)


def prepare():
    global EVIDENCE
    if WORK.exists() or JOB_PLIST.exists():
        sys.exit("A boot test already exists; inspect its report/backup before preparing another.")
    original = plistlib.loads(STORAGE.read_bytes()) if STORAGE.exists() else {}
    routing = json.loads(original.get("service.routing", b"{}"))
    flags = json.loads(FLAGS.read_bytes())
    if ("service.settings" in original or routing.get("proxy") or routing.get("mode", "direct") != "direct"
            or not all(flags.get(k) for k in ("core", "engine", "profile"))):
        sys.exit("This test requires the unconfigured, running Direct installation.")
    if not APP.exists() or (RUNTIME / "qualification.json").exists():
        sys.exit("Stage the signed candidate first; qualified installations are refused.")
    EVIDENCE = Path(tempfile.mkdtemp(prefix="mimo-boot-test-", dir="/var/tmp"))
    WORK.mkdir(mode=0o700)
    (WORK / "original.plist").write_bytes(plistlib.dumps(original, fmt=plistlib.FMT_BINARY))
    (WORK / "original-services.json").write_bytes(FLAGS.read_bytes())
    shutil.copyfile(__file__, WORK / "boot_test.py")
    shutil.copyfile(Path(__file__).with_name("installation-check"), WORK / "installation-check")
    (WORK / "installation-check").chmod(0o700)
    metadata = {"oldBoot": boot_id(), "evidence": str(EVIDENCE), "attempts": 0}
    (WORK / "test.json").write_text(json.dumps(metadata))
    try:
        command("candidate-install", ["/usr/bin/env", "SUDO_USER=jay", "/bin/bash",
                APP / "Contents/Resources/daemon.sh", "install"], timeout=180)
        wait_for(direct, "candidate-installed-in-Direct")
        public_probe(True)
        state("core", "stop")
        state("mihomo", "stop")
        protected = {"mode": "global", "profileHostingEnabled": True, "mihomoEnabled": True}
        fixture = dict(original)
        fixture.update({"service.routing": json.dumps(protected).encode(),
                        "service.revision": original.get("service.revision", 0) + 1})
        write_settings(plistlib.dumps(fixture, fmt=plistlib.FMT_BINARY))
        command("prepare-protected-supervisor", ["/bin/launchctl", "kickstart", "-k", "system/" + SUPERVISOR])
        wait_for(lambda s: blocked(s) and health(s, "core") == "stopped" and health(s, "mihomo") == "stopped",
                 "protected-fixture-armed")
        reference = json.loads((RUNTIME / "pf-reference.json").read_bytes())
        assert reference["boot"] == metadata["oldBoot"]
        metadata["passedBeforeBoot"] = PASSED
        (WORK / "test.json").write_text(json.dumps(metadata))
        job = {"Label": JOB, "ProgramArguments": ["/usr/bin/python3", "-I", str(WORK / "boot_test.py"), "--after-boot"],
               "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 10,
               "StandardOutPath": str(EVIDENCE / "worker.log"), "StandardErrorPath": str(EVIDENCE / "worker.log")}
        atomic_write(JOB_PLIST, plistlib.dumps(job))
        JOB_PLIST.chmod(0o644)
        print("The VM will reboot once. The fixed boot worker will test protection, restore original Direct settings, and remove its job.", flush=True)
        print("Evidence:", EVIDENCE, flush=True)
        command("request-reboot", ["/sbin/shutdown", "-r", "now"], timeout=10)
    except BaseException as error:
        try:
            restore_original()
        finally:
            finish(False, str(error))
        raise


def after_boot():
    global EVIDENCE, PASSED
    metadata = json.loads((WORK / "test.json").read_bytes())
    EVIDENCE = Path(metadata["evidence"])
    PASSED = metadata.get("passedBeforeBoot", [])
    metadata["attempts"] += 1
    atomic_write(WORK / "test.json", json.dumps(metadata).encode())
    success = False
    error = None
    try:
        if metadata["attempts"] != 1 or boot_id() == metadata["oldBoot"]:
            raise RuntimeError("The worker restarted unexpectedly or no new kernel boot occurred")
        value = wait_for(lambda s: blocked(s) and health(s, "core") == "stopped" and health(s, "mihomo") == "stopped",
                         "protected-boot-retains-stopped-services")
        assert value["configuration"]["mode"] == "global"
        reference = json.loads((RUNTIME / "pf-reference.json").read_bytes())
        assert reference["boot"] == boot_id() and reference["token"].isascii() and reference["token"].isdigit()
        assert "Status: Enabled" in command("pf-status", ["/sbin/pfctl", "-s", "info"])
        passed("PF-reference-belongs-to-new-kernel-boot")
        processes = command("boot-processes", ["/bin/ps", "-axo", "comm="])
        assert not any(p.endswith(("/Contents/MacOS/Mimo", "/Contents/MacOS/mimo-gui")) for p in processes.splitlines())
        passed("protection-runs-without-Mimo-GUI")
        public_probe(False)
        passed("ordinary-public-TCP-blocked-after-protected-startup")
        state("mihomo", "start")
        wait_for(lambda s: blocked(s) and health(s, "core") == "stopped" and health(s, "mihomo") == "running",
                 "engine-start-remains-protected-with-core-stopped")
        command("recover-Direct", [HELPER, "--recover-direct"])
        wait_for(lambda s: direct(s) and health(s, "core") == "stopped", "boot-recovery-preserves-core-Stop")
        assert json.loads(plistlib.loads(STORAGE.read_bytes())["service.routing"])["mode"] == "direct"
        restore_original()
        public_probe(True)
        passed("ordinary-public-TCP-restored")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            core = state("core-state")
            if core["protocolVersion"] == 5 and (core.get("routing") or {}).get("effectiveMode") == "direct":
                passed("core-ordered-protocol-confirms-Direct")
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("Core did not confirm Direct after recovery")
        success = True
    except BaseException as exception:
        error = str(exception)
        try:
            restore_original()
        except BaseException as recovery:
            error += "; recovery: " + str(recovery)
    finally:
        finish(success, error)
    # No persistent test executor is left registered. Evidence and the root-only
    # original-settings backup remain for review; this process has finished work.
    subprocess.Popen(["/bin/launchctl", "bootout", "system/" + JOB], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Run with guest sudo: sudo /usr/bin/python3 ~/mimo-tests/runtime/boot_test.py")
    os.umask(0o077)
    if not subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).startswith("VirtualMac"):
        sys.exit("This test only runs inside an Apple VirtualMac guest.")
    if sys.argv[1:] == ["--after-boot"]:
        after_boot()
    elif not sys.argv[1:]:
        prepare()
    else:
        sys.exit("Usage: boot_test.py")
