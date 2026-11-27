#!/usr/bin/env python3
"""Owned VM-only contention fixture; never writes or unlinks the PF lock."""
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import stat
import sys
import time

LOCK = Path('/Library/Application Support/Mimo/Runtime/pf-mutation.lock')


def validated_descriptor(path, uid=0):
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
        os.close(fd)
        raise AssertionError('Unsafe existing lock')
    return fd, {'device': info.st_dev, 'inode': info.st_ino, 'owner': info.st_uid, 'mode': stat.S_IMODE(info.st_mode)}


def write_new(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)


def hold(root, identity, maximum, lock=LOCK, uid=0):
    assert re.fullmatch('[a-f0-9]{32}', identity)
    assert 0 < maximum <= 8
    root = Path(root)
    info = root.lstat()
    assert stat.S_ISDIR(info.st_mode) and info.st_uid == uid and not info.st_mode & 0o077
    started = time.monotonic()
    parent = os.getppid()
    descriptor, original = validated_descriptor(lock, uid)
    record = {'pid': os.getpid(), 'parent': parent, 'identity': identity, 'lock': original,
              'maximum_seconds': maximum, 'started_epoch': time.time()}
    acquired = False
    try:
        while time.monotonic() - started < 1:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                time.sleep(.01)
        assert acquired, 'PF lock fixture unavailable'
        record['acquired_epoch'] = time.time()
        write_new(root / (identity + '-pf-hold-ready.json'), record)
        deadline = time.monotonic() + maximum
        release = root / (identity + '-pf-hold-release')
        while time.monotonic() < deadline:
            if os.getppid() != parent:
                record['release_reason'] = 'parent_changed'
                break
            if release.exists():
                release_info = release.lstat()
                assert stat.S_ISREG(release_info.st_mode) and release_info.st_uid == uid and not release_info.st_mode & 0o077
                record['release_reason'] = 'requested'
                break
            time.sleep(.01)
        else:
            record['release_reason'] = 'deadline'
    finally:
        if acquired: fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
        record['released_epoch'] = time.time()
        current = lock.lstat()
        record['lock_inode_unchanged'] = current.st_ino == original['inode'] and current.st_dev == original['device']
        write_new(root / (identity + '-pf-hold-finished.json'), record)
    return record


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm-worker')
    root, identity, value = sys.argv[1:4]
    assert Path(root) == Path('/var/tmp/mimo-observation-worker')
    maximum = float(value)
    assert math.isfinite(maximum) and 0 < maximum <= 8
    # Independent upper bound survives a lost controller/harness. Process exit
    # releases flock even if an exception prevents the final evidence write.
    signal.alarm(math.ceil(maximum) + 2)
    hold(root, identity, maximum)


if __name__ == '__main__': main()
