#!/usr/bin/env python3
"""console.py -- drive a QEMU guest over its serial socket.

The guest runs headless and detached; everything it prints is appended to a log
file, and a small expect script types the few commands the test needs. This is
the whole automation layer -- no ssh into the guest, no agent inside it.

Usage:  console.py SOCKET LOGFILE SCRIPT

SCRIPT is one directive per line:
    expect <seconds> <regex>   wait for regex in the output stream
    send <text>                type text, then Enter
    sendraw <text>             type text with no Enter
    sleep <seconds>
    done                       stop and exit 0

Exit: 0 on 'done' or end of script, 2 on an expect timeout, 4 if the guest
closed the console. The log always says which.
"""
import os
import re
import socket
import sys
import time

BUF_KEEP = 262144


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sock_path, log_path, script_path = sys.argv[1:4]

    directives = []
    with open(script_path) as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.strip() and not line.lstrip().startswith("#"):
                directives.append(line)

    for _ in range(240):
        if os.path.exists(sock_path):
            break
        time.sleep(0.5)
    else:
        sys.exit("console.py: %s never appeared" % sock_path)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(120):
        try:
            s.connect(sock_path)
            break
        except OSError:
            time.sleep(0.5)
    else:
        sys.exit("console.py: could not connect to %s" % sock_path)
    s.setblocking(False)

    log = open(log_path, "ab", buffering=0)
    buf = bytearray()
    alive = [True]

    def note(msg):
        log.write(("\n[console] %s\n" % msg).encode())

    def pump(timeout):
        """Read what is available, up to `timeout` seconds."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                data = s.recv(65536)
            except BlockingIOError:
                time.sleep(0.1)
                continue
            except OSError as exc:
                note("socket error: %s" % exc)
                alive[0] = False
                return
            if not data:
                note("guest closed the console")
                alive[0] = False
                return
            log.write(data)
            buf.extend(data)
            if len(buf) > BUF_KEEP:
                del buf[:-BUF_KEEP]
            return

    for line in directives:
        verb, _, rest = line.partition(" ")
        if verb == "done":
            note("done")
            return 0
        if verb == "sleep":
            end = time.time() + float(rest)
            while time.time() < end and alive[0]:
                pump(1)
            continue
        if verb in ("send", "sendraw"):
            payload = rest + ("\n" if verb == "send" else "")
            note("send %r" % rest)
            try:
                s.sendall(payload.encode())
            except OSError as exc:
                note("send failed: %s" % exc)
                return 4
            del buf[:]
            continue
        if verb == "expect":
            secs, _, pattern = rest.partition(" ")
            rx = re.compile(pattern.encode())
            deadline = time.time() + float(secs)
            note("expect %r (%ss)" % (pattern, secs))
            while True:
                if rx.search(buf):
                    note("matched %r" % pattern)
                    break
                if not alive[0]:
                    note("console closed while waiting for %r" % pattern)
                    return 4
                if time.time() > deadline:
                    note("TIMEOUT waiting for %r" % pattern)
                    return 2
                pump(2)
            continue
        note("unknown directive: %r" % line)
        return 3

    note("script ended")
    return 0


if __name__ == "__main__":
    sys.exit(main())
