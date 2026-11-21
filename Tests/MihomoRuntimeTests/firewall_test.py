#!/usr/bin/env python3
"""Bounded, VM-only test of the closed PF gate. Run explicitly with guest sudo.

Uses only com.apple/000.mimo, refuses existing rules there, and acquires/releases
its own PF enable token. No launch jobs, TUN, system proxy, or main rules are changed.
An independent watchdog retries cleanup if this process dies or exceeds 60 seconds.
This is a smoke test, not complete Mimo routing/release qualification.
"""
import json
import os
from pathlib import Path
import pwd
import re
import signal
import subprocess
import sys
import tempfile
import time

ANCHOR = "com.apple/000.mimo"
TARGET = "1.1.1.1"

PROBE = """
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if sys.argv[1] == 'udp' else socket.SOCK_STREAM)
sock.settimeout(3)
try:
    if sys.argv[1] == 'udp':
        sock.sendto(b'mimo-firewall-fixture', ('1.1.1.1', 53))
    else:
        sock.connect(('1.1.1.1', 443))
except OSError as error:
    print(type(error).__name__)
    sys.exit(2)
finally:
    sock.close()
"""

WATCHDOG = """
import os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
parent = int(sys.argv[2])
deadline = time.monotonic() + 60
while not (root / 'cleanup-complete').exists():
    try:
        os.kill(parent, 0)
    except ProcessLookupError:
        break
    if time.monotonic() >= deadline:
        break
    time.sleep(0.2)
else:
    sys.exit(0)
subprocess.run(['/sbin/pfctl', '-a', 'com.apple/000.mimo', '-F', 'rules'], timeout=5)
token = (root / 'pf.token').read_text().strip() if (root / 'pf.token').exists() else ''
if token.isdigit():
    subprocess.run(['/sbin/pfctl', '-X', token], timeout=5)
"""


def command(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=6, **kwargs)


def require(result):
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "command failed")
    return result.stdout + result.stderr


def run():
    if os.geteuid() != 0:
        sys.exit("Administrator access is required: sudo /usr/bin/python3 ~/mimo-tests/runtime/firewall_test.py")
    model = require(command(["/usr/sbin/sysctl", "-n", "hw.model"])).strip()
    if not model.startswith("VirtualMac"):
        sys.exit("This test runs only inside an Apple VirtualMac guest.")
    account = pwd.getpwnam("jay")
    if account.pw_uid == 0 or account.pw_gid == 1:
        sys.exit("The application test user must be unprivileged and outside the bootstrap group.")
    rules = require(command(["/sbin/pfctl", "-sr"]))
    if 'anchor "com.apple/*"' not in rules or re.search(r"\bpass\b[^\n]*\bquick\b", rules):
        sys.exit("PF preflight failed: the main ruleset needs the supported com.apple/* anchor and no earlier quick pass.")
    existing = command(["/sbin/pfctl", "-a", ANCHOR, "-sr"])
    require(existing)
    # macOS can print ALTQ notices on stderr even for an empty ruleset.
    if existing.stdout.strip():
        sys.exit("Refusing to replace existing Mimo firewall rules.")
    route = require(command(["/sbin/route", "-n", "get", TARGET]))
    match = re.search(r"interface:\s*(\w+)", route)
    if not match or not match[1].startswith("en"):
        sys.exit("A direct Ethernet route is required for the packet-capture smoke test.")
    interface = match[1]
    root = Path(tempfile.mkdtemp(prefix="mimo-firewall-test-", dir="/var/tmp"))
    (root / "closed.pf").write_bytes(Path(__file__).with_name("closed.pf").read_bytes())
    require(command(["/sbin/pfctl", "-n", "-a", ANCHOR, "-f", str(root / "closed.pf")]))
    results = []
    capture = None
    watcher = None
    token = None
    changed = False
    success = False

    def passed(message):
        results.append(message)
        print("PASS:", message, flush=True)

    def probe(protocol="tcp", bootstrap=False):
        def identity():
            os.setgroups([])
            os.setgid(1 if bootstrap else account.pw_gid)
            if not bootstrap:
                os.setuid(account.pw_uid)
        return command([sys.executable, "-c", PROBE, protocol], preexec_fn=identity)

    def cleanup():
        nonlocal changed, token
        if changed:
            require(command(["/sbin/pfctl", "-a", ANCHOR, "-F", "rules"]))
            changed = False
        if token:
            require(command(["/sbin/pfctl", "-X", token]))
            token = None
        (root / "cleanup-complete").touch()

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        require(probe())
        passed("application TCP reaches the public test endpoint before blocking")
        with (root / "watchdog.log").open("w") as log:
            watcher = subprocess.Popen([sys.executable, "-c", WATCHDOG, str(root), str(os.getpid())],
                                       stdout=log, stderr=log, start_new_session=True)
        # Record intent before mutation so cleanup also covers a partial pfctl failure.
        changed = True
        require(command(["/sbin/pfctl", "-a", ANCHOR, "-f", str(root / "closed.pf")]))
        enabled = require(command(["/sbin/pfctl", "-E"]))
        match = re.search(r"Token\s*:\s*(\d+)", enabled)
        if not match:
            raise RuntimeError("PF did not return an enable reference token")
        token = match[1]
        (root / "pf.token").write_text(token)
        require(command(["/sbin/pfctl", "-k", "0.0.0.0/0"]))
        require(command(["/sbin/pfctl", "-k", "::/0"]))
        with (root / "capture.log").open("w") as log:
            capture = subprocess.Popen(["/usr/sbin/tcpdump", "-n", "-U", "-i", interface,
                                        "-w", str(root / "blocked.pcap"),
                                        "dst host 1.1.1.1 and (tcp dst port 443 or udp dst port 53)"],
                                       stdout=log, stderr=log)
        deadline = time.monotonic() + 3
        while "listening on" not in (root / "capture.log").read_text():
            if capture.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("packet capture did not start")
            time.sleep(0.05)
        blocked = probe()
        if blocked.returncode != 2:
            raise RuntimeError("application TCP was not blocked: " + blocked.stdout + blocked.stderr)
        udp = probe("udp")  # UDP send can report success even when PF drops the packet.
        if udp.returncode not in (0, 2):
            raise RuntimeError("UDP probe did not run: " + udp.stderr)
        (root / "application-probes.txt").write_text(
            f"TCP exit={blocked.returncode}: {blocked.stdout}{blocked.stderr}\n"
            f"UDP exit={udp.returncode}: {udp.stdout}{udp.stderr}\n")
        time.sleep(0.5)
        capture.send_signal(signal.SIGINT)
        capture.wait(timeout=3)
        capture = None
        packets = command(["/usr/sbin/tcpdump", "-nn", "-r", str(root / "blocked.pcap")])
        require(packets)
        # Packet lines are stdout; capture metadata is stderr.
        if packets.stdout.strip():
            raise RuntimeError("application packets escaped the closed gate")
        passed("application TCP/443 and UDP/53 emit no packets on the guest uplink while closed")
        require(probe(bootstrap=True))
        passed("the isolated bootstrap group can still reach the pinned HTTPS endpoint")
        cleanup()
        require(probe())
        passed("application TCP works again after removal of the test gate")
        success = True
    finally:
        try:
            if capture is not None:
                capture.terminate()
                capture.wait(timeout=3)
        finally:
            try:
                cleanup()
            finally:
                report = {"passed": results, "success": success, "interface": interface,
                          "scope": "Closed PF gate IPv4 smoke test only; no active TUN, IPv6, Tailscale or release qualification"}
                (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                for path in root.iterdir():
                    path.chmod(0o644)
                root.chmod(0o755)
                print("Evidence:", root, flush=True)
        if watcher is not None:
            watcher.wait(timeout=3)


if __name__ == "__main__":
    run()
