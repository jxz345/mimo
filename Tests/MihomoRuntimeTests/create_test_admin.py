#!/usr/bin/env python3
"""One-time, explicitly authorized administrator setup inside the Mimo test VM.

Uses a generated password and dedicated SSH key staged by jay with mode 0600.
No password appears in command arguments, output, logs, or sudoers. This creates
a normal visible administrator account; sudo still authenticates with its password.
"""
import base64
import json
import os
from pathlib import Path
import pty
import pwd
import re
import select
import signal
import stat
import subprocess
import sys
import time

ACCOUNT = "mimotest"
INPUT = Path("/Users/jay/mimo-tests/private/test-admin.json")


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Account setup command failed")
    return result.stdout


def create_account(password):
    # '-' requests a terminal password prompt. Supplying the generated password
    # through that PTY avoids both process-list and shell-history exposure.
    child, terminal = pty.fork()
    if child == 0:
        os.execv("/usr/sbin/sysadminctl", ["sysadminctl", "-addUser", ACCOUNT,
                   "-fullName", "Mimo Test Administrator", "-home", "/Users/" + ACCOUNT,
                   "-shell", "/bin/zsh", "-admin", "-password", "-"])
    transcript = ""
    prompt = ""
    sent = 0
    deadline = time.monotonic() + 90
    status = None
    try:
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.2)[0]:
                try:
                    data = os.read(terminal, 65536)
                except OSError:
                    data = b""
                text = data.decode(errors="replace")
                transcript += text
                prompt += text
                if re.search(r"password[^\r\n]{0,100}:\s*$", prompt, re.IGNORECASE):
                    if sent >= 2:
                        raise RuntimeError("Unexpected extra password prompt; account setup stopped")
                    os.write(terminal, password.encode() + b"\n")
                    sent += 1
                    prompt = ""
            finished, value = os.waitpid(child, os.WNOHANG)
            if finished:
                status = value
                break
        if status is None:
            raise RuntimeError("Account creation timed out")
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0 or sent == 0:
            safe = transcript.replace(password, "<redacted>")
            raise RuntimeError("Account creation did not complete: " + safe[-3000:])
    finally:
        if status is None:
            os.kill(child, signal.SIGKILL)
            os.waitpid(child, 0)
        os.close(terminal)


def main():
    if os.geteuid() != 0:
        sys.exit("Run once with guest sudo: sudo /usr/bin/python3 ~/mimo-tests/runtime/create_test_admin.py")
    os.umask(0o077)
    if not run(["/usr/sbin/sysctl", "-n", "hw.model"]).startswith("VirtualMac"):
        sys.exit("This setup is restricted to an Apple VirtualMac guest.")
    try:
        pwd.getpwnam(ACCOUNT)
    except KeyError:
        pass
    else:
        sys.exit("The mimotest account already exists; no existing account was modified.")
    owner = pwd.getpwnam("jay")
    info = INPUT.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner.pw_uid or info.st_mode & 0o077:
        sys.exit("The staged credential file must belong to jay and have mode 0600.")
    value = json.loads(INPUT.read_text())
    password = value["password"]
    key = value["publicKey"]
    if (value.get("username") != ACCOUNT or not re.fullmatch(r"[A-Za-z0-9_-]{40,128}", password)
            or not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+ mimo-vm-test-admin", key)):
        sys.exit("The staged account data is invalid.")
    base64.b64decode(key.split()[1], validate=True)
    create_account(password)
    account = pwd.getpwnam(ACCOUNT)
    home = Path(account.pw_dir)
    if account.pw_uid < 501 or home != Path("/Users/mimotest") or home.is_symlink():
        raise RuntimeError("The new account has an unexpected identity or home directory")
    if not home.exists():
        run(["/usr/sbin/createhomedir", "-c", "-u", ACCOUNT])
    run(["/usr/sbin/dseditgroup", "-o", "edit", "-a", ACCOUNT, "-t", "user", "admin"])
    # Remote Login is already enabled for the VM. Add only this account to its
    # existing access group; do not broaden Remote Login to all users.
    acl = subprocess.run(["/usr/bin/dscl", ".", "-read", "/Groups/com.apple.access_ssh"], capture_output=True)
    if acl.returncode == 0:
        run(["/usr/sbin/dseditgroup", "-o", "edit", "-a", ACCOUNT, "-t", "user", "com.apple.access_ssh"])
    ssh = home / ".ssh"
    ssh.mkdir(mode=0o700, exist_ok=False)
    os.chown(ssh, account.pw_uid, account.pw_gid)
    authorized = ssh / "authorized_keys"
    restrictions = 'from="192.168.64.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding '
    descriptor = os.open(authorized, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(restrictions + key + "\n")
    os.chown(authorized, account.pw_uid, account.pw_gid)
    run(["/usr/sbin/dseditgroup", "-o", "checkmember", "-m", ACCOUNT, "admin"])
    INPUT.unlink()  # Delta retains the sole automation password file.
    print("Created mimotest (Mimo Test Administrator) inside the VM.")
    print("Dedicated SSH key installed; ordinary password-based sudo retained.")
    print("Ready for SSH and sudo verification from Delta. No password was printed.")


if __name__ == "__main__":
    main()
