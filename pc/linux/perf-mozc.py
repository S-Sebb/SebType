"""Times Mozc candidate generation through its own server, as Fcitx5's Mozc uses it.

    python3 -I perf-mozc.py MOZC_SERVER PROFILE_HOME RUNS < inputs.txt   (one romaji word per line)

Starts a private mozc_server with HOME=PROFILE_HOME, so it gets its own profile and IPC socket and never
touches the desktop's server. Each word is typed one key at a time (each reply carries the suggestions),
converted with Space, then reverted, so nothing is learned. Prints key=value lines.
"""

import os
import socket
import statistics
import subprocess
import sys
import time

CREATE_SESSION, DELETE_SESSION, SEND_KEY, SEND_COMMAND = 1, 2, 3, 5
ON, SPACE, HIRAGANA, REVERT = 2, 4, 1, 1


def varint(n):
    out = bytearray()
    while True:
        b, n = n & 0x7F, n >> 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(num, value):  # int -> varint field, bytes -> length-delimited field
    if isinstance(value, int):
        return varint(num << 3) + varint(value)
    return varint(num << 3 | 2) + varint(len(value)) + value


def fields(buf):
    i = 0
    while i < len(buf):
        tag, i = read_varint(buf, i)
        num, wire = tag >> 3, tag & 7
        if wire == 0:
            value, i = read_varint(buf, i)
        elif wire == 2:
            size, i = read_varint(buf, i)
            value, i = buf[i : i + size], i + size
        elif wire in (1, 5):
            value, i = buf[i : i + (8 if wire == 1 else 4)], i + (8 if wire == 1 else 4)
        else:
            raise ValueError(f"wire type {wire}")
        yield num, value


def read_varint(buf, i):
    n = shift = 0
    while True:
        b = buf[i]
        i += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return n, i


def ipc_key(profile):  # IPCPathInfo.key (field 1) from the server's .session.ipc
    with open(os.path.join(profile, ".session.ipc"), "rb") as f:
        return dict(fields(f.read()))[1].decode()


def call(
    key, request
):  # Mozc's Unix IPC: one connection per call, EOF ends each message
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(f"\0tmp/.mozc.{key}.session")
        s.sendall(request)
        s.shutdown(socket.SHUT_WR)
        reply = b""
        while chunk := s.recv(65536):
            reply += chunk
    return dict(fields(reply))


def send_key(key, session, **k):
    event = field(7, HIRAGANA) + (
        field(1, ord(k["char"])) if "char" in k else field(3, k["special"])
    )
    return call(key, field(1, SEND_KEY) + field(2, session) + field(3, event))


def stats(name, ms):
    ms = sorted(ms)
    print(
        f"{name}_p50_ms={statistics.median(ms):.2f}\n{name}_p95_ms={ms[int(len(ms) * 0.95)]:.2f}\n"
        f"{name}_max_ms={ms[-1]:.2f}"
    )


def status_kb(pid, name):
    with open(f"/proc/{pid}/status") as f:
        return next(int(l.split()[1]) for l in f if l.startswith(name))


def main():
    server, home, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
    words = sys.stdin.read().split()
    profile = os.path.join(home, ".config", "mozc")
    os.makedirs(profile, exist_ok=True)  # the server won't start without it
    env = {k: v for k, v in os.environ.items() if k != "XDG_CONFIG_HOME"} | {
        "HOME": home
    }
    start = time.monotonic()
    proc = subprocess.Popen(
        [server], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    try:
        while True:  # the server writes .session.ipc once it listens
            try:
                key = ipc_key(profile)
                session = call(key, field(1, CREATE_SESSION))[1]
                break
            except (OSError, KeyError):
                if proc.poll() is not None or time.monotonic() - start > 30:
                    raise SystemExit("mozc_server did not start")
                time.sleep(0.01)
        send_key(
            key, session, special=ON
        )  # a new session starts in direct (ASCII) mode
        print(f"start_ms={(time.monotonic() - start) * 1e3:.0f}")
        keys, converts, shown, suggested = [], [], 0, 0
        for run in range(runs):
            for word in words:
                for c in word:
                    t = time.monotonic()
                    out = send_key(key, session, char=c)
                    keys.append((time.monotonic() - t) * 1e3)
                    suggested += (
                        6 in out
                    )  # candidate_window: suggestions under the preedit
                t = time.monotonic()
                out = send_key(key, session, special=SPACE)
                converts.append((time.monotonic() - t) * 1e3)
                shown += 14 in out  # all_candidate_words: the conversion's candidates
                call(
                    key,
                    field(1, SEND_COMMAND)
                    + field(2, session)
                    + field(4, field(1, REVERT)),
                )
        print(f"first_key_ms={keys[0]:.2f}")
        stats("key", keys)
        stats("convert", converts)
        print(
            f"keys_with_suggestions={suggested}/{len(keys)}\nconverts_with_candidates={shown}/{len(converts)}"
        )
        call(key, field(1, DELETE_SESSION) + field(2, session))
        print(
            f"rss_kb={status_kb(proc.pid, 'VmRSS:')}\npeak_rss_kb={status_kb(proc.pid, 'VmHWM:')}"
        )
    finally:
        proc.terminate()
        proc.wait(10)


main()
