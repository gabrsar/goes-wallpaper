#!/usr/bin/env python3
"""Run a command on a pseudo-terminal, type keys into it, print what it drew.

Used by test_picker.sh to exercise the interactive picker exactly as a user
would, including its /dev/tty handling.

    pty_drive.py [--timeout S] CMD [ARGS...] -- KEY [KEY...]

Keys: UP DOWN ENTER ESC HOME END, SLEEPn.n to pause, anything else is typed
literally. Exit status is the command's, or 124 on timeout.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

KEYS = {"UP": "\x1b[A", "DOWN": "\x1b[B", "ENTER": "\r", "ESC": "\x1b",
        "HOME": "\x1b[H", "END": "\x1b[F"}


def drive(cmd, keys, timeout, cols=100, rows=30):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    out, pending = b"", list(keys)
    deadline, next_key_at = time.time() + timeout, time.time() + 0.8
    status = None
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            out += chunk
        if pending and time.time() >= next_key_at:
            key = pending.pop(0)
            if key.startswith("SLEEP"):
                next_key_at = time.time() + float(key[5:])
                continue
            os.write(fd, KEYS.get(key, key).encode())
            next_key_at = time.time() + 0.4
        waited, raw = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = os.waitstatus_to_exitcode(raw)
            break
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        status = 124
    try:
        while select.select([fd], [], [], 0.1)[0]:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            out += chunk
    except OSError:
        pass
    os.close(fd)
    sys.stdout.write(out.decode("utf-8", "replace"))
    return status


def main():
    args = sys.argv[1:]
    timeout = 20.0
    if args[:1] == ["--timeout"]:
        timeout, args = float(args[1]), args[2:]
    split = args.index("--")
    sys.exit(drive(args[:split], args[split + 1:], timeout))


if __name__ == "__main__":
    main()
