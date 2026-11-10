"""Times Mozc candidate generation through its own server, as the PC input methods use it (#45, #65).

    python3 -I perf-mozc.py MOZC_SERVER PROFILE_HOME RUNS < inputs.txt

Each input line is a romaji word, optionally followed by a tab and the conversion it should give.
Linux: starts a private mozc_server with HOME=PROFILE_HOME, so it gets its own profile and IPC socket and
never touches the desktop's server. Windows: Mozc's profile is always %USERPROFILE%\\AppData\\LocalLow\\Mozc,
so PROFILE_HOME must be "-", the profile must not exist yet or be empty (no Mozc in use), and it is put back
afterwards.
Each word is typed one key at a time (each reply carries the suggestions), converted with Space, then
reverted, so nothing is learned. Then, for lines with an expected conversion, one more pass converts and
commits each word and counts how often the first candidate is the expected one. Prints key=value lines.
"""

import os
import shutil
import statistics
import subprocess
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


def read_shared(path):
    if not WINDOWS:
        with open(path, "rb") as f:
            return f.read()
    # The server keeps session.ipc open with DELETE_ON_CLOSE, which a plain open doesn't share;
    # read it as Mozc's own client does (ipc/ipc_path_manager.cc).
    import ctypes
    from ctypes import wintypes as w

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.restype = w.HANDLE
    k32.CreateFileW.argtypes = [
        w.LPCWSTR,
        w.DWORD,
        w.DWORD,
        w.LPVOID,
        w.DWORD,
        w.DWORD,
        w.HANDLE,
    ]
    # GENERIC_READ, FILE_SHARE_READ | WRITE | DELETE, OPEN_EXISTING
    handle = w.HANDLE(k32.CreateFileW(path, 0x80000000, 0x7, None, 3, 0, None))
    if handle.value in (None, 0xFFFFFFFFFFFFFFFF):
        raise OSError(ctypes.get_last_error(), f"can't open {path}")
    try:
        buf, read = ctypes.create_string_buffer(4096), w.DWORD()
        if not k32.ReadFile(handle, buf, len(buf), ctypes.byref(read), None):
            raise OSError(ctypes.get_last_error(), f"can't read {path}")
        return buf.raw[: read.value]
    finally:
        k32.CloseHandle(handle)


def ipc_key(profile):  # IPCPathInfo.key (field 1) from the server's session.ipc
    path = os.path.join(profile, "session.ipc" if WINDOWS else ".session.ipc")
    return dict(fields(read_shared(path)))[1].decode()


def call(key, request):
    if WINDOWS:  # a message-mode named pipe: one request, one reply, then disconnect
        # The server listens on one pipe instance at a time: retry while it's busy.
        deadline = time.monotonic() + 10
        while True:
            try:
                with open(rf"\\.\pipe\mozc.{key}.session", "r+b", buffering=0) as pipe:
                    pipe.write(request)
                    reply = pipe.read(1 << 20)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.001)
    else:  # Mozc's Unix IPC: one connection per call, EOF ends each message
        import socket

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


def start_server(server, env):
    if not WINDOWS:
        return subprocess.Popen(
            [server], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    # mozc_server exits unless its main thread starts with a thread token (base/run_level.cc), which
    # Mozc's client sets on the suspended process (base/win32/win_sandbox.cc); give it a copy of ours.
    import ctypes
    from ctypes import wintypes as w

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    adv = ctypes.WinDLL("advapi32", use_last_error=True)
    for f in k32.GetCurrentProcess, k32.OpenThread, k32.CreateToolhelp32Snapshot:
        f.restype = w.HANDLE  # handles stay wrapped: bare ints go as 32-bit

    class Thread(ctypes.Structure):  # THREADENTRY32
        _fields_ = [
            (n, w.DWORD)
            for n in ["size", "usage", "tid", "pid", "base", "delta", "flags"]
        ]

    proc = subprocess.Popen(  # CREATE_SUSPENDED
        [server],
        creationflags=0x4,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    snap, t = (
        w.HANDLE(k32.CreateToolhelp32Snapshot(4, 0)),
        Thread(),
    )  # TH32CS_SNAPTHREAD
    t.size = ctypes.sizeof(t)
    ok = k32.Thread32First(snap, ctypes.byref(t))
    while ok and t.pid != proc.pid:
        ok = k32.Thread32Next(snap, ctypes.byref(t))
    k32.CloseHandle(snap)
    thread = w.HANDLE(
        k32.OpenThread(0x82, False, t.tid)
    )  # SET_THREAD_TOKEN | SUSPEND_RESUME
    token, dup = w.HANDLE(), w.HANDLE()
    if not (
        ok
        and thread.value
        and adv.OpenProcessToken(
            w.HANDLE(k32.GetCurrentProcess()), 0xA, ctypes.byref(token)
        )
        # TOKEN_IMPERSONATE | TOKEN_QUERY, SecurityImpersonation, TokenImpersonation
        and adv.DuplicateTokenEx(token, 0xC, None, 2, 2, ctypes.byref(dup))
        and adv.SetThreadToken(ctypes.byref(thread), dup)
    ):
        proc.kill()
        raise SystemExit(
            f"can't give mozc_server a thread token: {ctypes.get_last_error()}"
        )
    k32.ResumeThread(thread)
    for h in thread, token, dup:
        k32.CloseHandle(h)
    return proc


def memory_kb(pid):  # (RSS, peak RSS)
    if WINDOWS:
        import ctypes
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
                (n, ctypes.c_size_t)
                for n in ("peak", "rss", "a", "b", "c", "d", "e", "f")
            ]

        c = Counters(cb=ctypes.sizeof(Counters))
        h = ctypes.windll.kernel32.OpenProcess(
            0x1000, False, pid
        )  # QUERY_LIMITED_INFORMATION
        ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb)
        ctypes.windll.kernel32.CloseHandle(h)
        return c.rss // 1024, c.peak // 1024
    with open(f"/proc/{pid}/status") as f:
        s = dict(l.split(":", 1) for l in f)
    return int(s["VmRSS"].split()[0]), int(s["VmHWM"].split()[0])


def main():
    server, home, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
    # -I ignores PYTHONIOENCODING, and Windows would use its ANSI code page.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    lines = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
    words = [l[0] for l in lines]
    expected = [(l[0], l[1]) for l in lines if len(l) > 1]
    if WINDOWS:
        profile, env = (
            os.path.join(os.environ["USERPROFILE"], "AppData", "LocalLow", "Mozc"),
            None,
        )
        if os.path.exists(profile) and os.listdir(profile):
            raise SystemExit(
                f"{profile} has files: Mozc is in use, so its profile can't be borrowed"
            )
        found = os.path.exists(profile)
    else:
        profile = os.path.join(home, ".config", "mozc")
        env = {k: v for k, v in os.environ.items() if k != "XDG_CONFIG_HOME"} | {
            "HOME": home
        }
    os.makedirs(profile, exist_ok=True)  # the server won't start without it
    start = time.monotonic()
    proc = start_server(server, env)
    try:
        while True:  # the server writes session.ipc once it listens
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
        rss, peak = memory_kb(proc.pid)
        print(f"rss_kb={rss}\npeak_rss_kb={peak}")
        if expected:  # last, since committing teaches Mozc the words
            hits = 0
            for word, want in expected:
                for c in word:
                    send_key(key, session, char=c)
                send_key(key, session, special=SPACE)
                result = dict(fields(send_key(key, session, special=ENTER).get(4, b"")))
                got = result.get(2, b"").decode()
                hits += got == want
                if got != want:
                    print(f"miss={word}\t{got}\t{want}")
            print(f"top1={hits}/{len(expected)}")
        call(key, field(1, DELETE_SESSION) + field(2, session))
    finally:
        proc.terminate()
        proc.wait(10)
        if WINDOWS:
            shutil.rmtree(profile, ignore_errors=True)
            if found:
                os.makedirs(profile)


main()
