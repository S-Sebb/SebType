"""Times Mozc candidate generation in this process, as the PC input methods run it (#45, #65, #233).

    python3 -I perf-mozc.py MOZC_LIBRARY PROFILE_DIR RUNS < inputs.txt

MOZC_LIBRARY is SebType's Mozc with its C interface (core/src/sebtype_mozc.h): libsebtype-mozc.so on Linux,
sebtype-mozc.dll on Windows. PROFILE_DIR is the Mozc profile it uses (an empty one: nothing learned yet).
Each input line is a romaji word, optionally followed by a tab and the conversion it should give.
Each word is typed one key at a time (each reply carries the suggestions), converted with Space, then
reverted, so nothing is learned. Then, for lines with an expected conversion, one more pass converts and
commits each word and counts how often the first candidate is the expected one. Prints key=value lines.
"""

import ctypes
import os
import statistics
import sys
import time

WINDOWS = os.name == "nt"
CREATE_SESSION, DELETE_SESSION, SEND_KEY, SEND_COMMAND = 1, 2, 3, 5
ON, SPACE, ENTER, HIRAGANA, REVERT = 2, 4, 5, 1, 1


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


class Mozc:
    def __init__(self, library, profile):
        self.lib = ctypes.CDLL(library)
        c = ctypes
        self.lib.sebtype_mozc_open.argtypes = [
            c.c_char_p,
            c.c_char_p,
            c.c_int64,
            c.c_int64,
        ]
        self.lib.sebtype_mozc_eval.argtypes = [
            c.c_char_p,
            c.c_size_t,
            c.POINTER(c.c_void_p),
            c.POINTER(c.c_size_t),
        ]
        self.lib.sebtype_mozc_free.argtypes = [c.c_void_p]
        if not self.lib.sebtype_mozc_open(os.fsencode(profile), b"", 0, 0):
            raise SystemExit("Mozc did not load")

    def call(self, request):
        out, size = ctypes.c_void_p(), ctypes.c_size_t()
        if not self.lib.sebtype_mozc_eval(
            request, len(request), ctypes.byref(out), ctypes.byref(size)
        ):
            raise SystemExit("Mozc did not answer")
        reply = ctypes.string_at(out, size.value)
        self.lib.sebtype_mozc_free(out)
        return dict(fields(reply))

    def close(self):
        self.lib.sebtype_mozc_close()


def send_key(mozc, session, **k):
    event = field(7, HIRAGANA) + (
        field(1, ord(k["char"])) if "char" in k else field(3, k["special"])
    )
    return mozc.call(field(1, SEND_KEY) + field(2, session) + field(3, event))


def stats(name, ms):
    ms = sorted(ms)
    print(
        f"{name}_p50_ms={statistics.median(ms):.2f}\n{name}_p95_ms={ms[int(len(ms) * 0.95)]:.2f}\n"
        f"{name}_max_ms={ms[-1]:.2f}"
    )


def memory_kb():  # this process's (RSS, peak RSS)
    if WINDOWS:
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
                (n, ctypes.c_size_t)
                for n in ("peak", "rss", "a", "b", "c", "d", "e", "f")
            ]

        c = Counters(cb=ctypes.sizeof(Counters))
        process = ctypes.windll.kernel32.GetCurrentProcess
        process.restype = wintypes.HANDLE
        info = ctypes.windll.psapi.GetProcessMemoryInfo
        info.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        info(process(), ctypes.byref(c), c.cb)
        return c.rss // 1024, c.peak // 1024
    with open("/proc/self/status") as f:
        s = dict(l.split(":", 1) for l in f)
    return int(s["VmRSS"].split()[0]), int(s["VmHWM"].split()[0])


def main():
    library, profile, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
    # -I ignores PYTHONIOENCODING, and Windows would use its ANSI code page.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    lines = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
    words = [l[0] for l in lines]
    expected = [(l[0], l[1]) for l in lines if len(l) > 1]
    os.makedirs(profile, exist_ok=True)
    start = time.monotonic()
    mozc = Mozc(os.path.abspath(library), profile)
    session = mozc.call(field(1, CREATE_SESSION))[1]
    send_key(mozc, session, special=ON)  # a new session starts in direct (ASCII) mode
    print(f"start_ms={(time.monotonic() - start) * 1e3:.0f}")
    keys, converts, shown, suggested = [], [], 0, 0
    for run in range(runs):
        for word in words:
            for c in word:
                t = time.monotonic()
                out = send_key(mozc, session, char=c)
                keys.append((time.monotonic() - t) * 1e3)
                suggested += 6 in out  # candidate_window: suggestions under the preedit
            t = time.monotonic()
            out = send_key(mozc, session, special=SPACE)
            converts.append((time.monotonic() - t) * 1e3)
            shown += 14 in out  # all_candidate_words: the conversion's candidates
            mozc.call(
                field(1, SEND_COMMAND) + field(2, session) + field(4, field(1, REVERT))
            )
    print(f"first_key_ms={keys[0]:.2f}")
    stats("key", keys)
    stats("convert", converts)
    print(
        f"keys_with_suggestions={suggested}/{len(keys)}\nconverts_with_candidates={shown}/{len(converts)}"
    )
    rss, peak = memory_kb()
    print(f"rss_kb={rss}\npeak_rss_kb={peak}")
    if expected:  # last, since committing teaches Mozc the words
        hits = 0
        for word, want in expected:
            for c in word:
                send_key(mozc, session, char=c)
            send_key(mozc, session, special=SPACE)
            result = dict(fields(send_key(mozc, session, special=ENTER).get(4, b"")))
            got = result.get(2, b"").decode()
            hits += got == want
            if got != want:
                print(f"miss={word}\t{got}\t{want}")
        print(f"top1={hits}/{len(expected)}")
    mozc.call(field(1, DELETE_SESSION) + field(2, session))
    mozc.close()


main()
