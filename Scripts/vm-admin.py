#!/usr/bin/env python3
"""Run an authorized test command as root in mimo-vm using its dedicated account.

The password stays outside the repository and is sent to sudo through stdin.
No credentials are accepted on the command line or printed.
"""
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys


def main():
    if len(sys.argv) < 2 or not sys.argv[1].startswith("/"):
        sys.exit("Usage: python3 Scripts/vm-admin.py /absolute/guest/executable [arguments...]")
    path = Path.home() / ".config/mimo-vm/test-admin.json"
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        sys.exit("The VM credential file must belong to the current user and have mode 0600.")
    value = json.loads(path.read_text())
    if value.get("host") != "mimo-vm-admin" or value.get("username") != "mimotest":
        sys.exit("Unexpected VM administrator configuration")
    remote = shlex.join(["/usr/bin/sudo", "-k", "-S", "-p", "", "--", *sys.argv[1:]])
    process = subprocess.Popen(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                                "mimo-vm-admin", remote], stdin=subprocess.PIPE)
    try:
        process.communicate(input=(value["password"] + "\n").encode())
    except KeyboardInterrupt:
        process.terminate()
        process.wait()
        raise
    return process.returncode


if __name__ == "__main__":
    sys.exit(main())
