"""Types into a private Fcitx5 through its D-Bus frontend and times it, the same way for any engine (#54).

    python3 -I compare-keys.py keys IM RUNS LOG < words.txt     # per-key times and memory
    python3 -I compare-keys.py soak MINUTES LOG < words.txt     # mixed rime/mozc typing, memory over time

Run it inside a private D-Bus session (compare.sh), with HOME set to a throwaway profile. Each key is a
press and a release, as from a keyboard. Per key: "reply" is the press's ProcessKeyEvent round trip (the
engine's work for the key, as an app waits for it), "ui" is until the last candidate-panel update the
client receives for it (what a candidate window would draw). Words end with Escape, so nothing is
learned; Mozc's words are converted with Space first ("convert"). Prints key=value lines.
"""

import os
import statistics
import subprocess
import sys
import time

from gi.repository import Gio, GLib

mode = sys.argv[1]
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
ctx = GLib.MainContext.default()
IC = "org.fcitx.Fcitx.InputContext1"
CONTROLLER = ("/controller", "org.fcitx.Fcitx.Controller1")
KEYS = {
    "space": (0x20, 65),
    "Escape": (0xFF1B, 9),
    "Return": (0xFF0D, 36),
    **{
        c: (ord(c), code)
        for row, first in (("qwertyuiop", 24), ("asdfghjkl", 38), ("zxcvbnm", 52))
        for code, c in enumerate(row, first)
    },
}


def call(
    path, iface, method, sig=None, *args
):  # never D-Bus-activates a default Fcitx5
    return bus.call_sync(
        "org.fcitx.Fcitx5",
        path,
        iface,
        method,
        GLib.Variant(sig, args) if sig else None,
        None,
        Gio.DBusCallFlags.NO_AUTO_START,
        30000,
        None,
    ).unpack()


def pump(
    quiet,
):  # dispatch signals until none came for `quiet` seconds (busy: exact timestamps)
    end = time.perf_counter() + quiet
    while time.perf_counter() < end:
        if ctx.iteration(False):
            end = time.perf_counter() + quiet


def start(log):
    t0 = time.perf_counter()
    with open(log, "a") as err:  # fcitx5 keeps its own copy of the descriptor
        proc = subprocess.Popen(
            [
                "fcitx5",
                "-k",
                "--disable=all",
                "--enable=dbus,dbusfrontend,keyboard,rime,mozc",
            ],
            stdout=subprocess.DEVNULL,
            stderr=err,
        )
    while True:
        try:
            call(*CONTROLLER, "CurrentInputMethod")
            break
        except GLib.Error:
            if time.perf_counter() - t0 > 20:
                sys.exit("fcitx5 didn't come up")
            time.sleep(0.01)
    up_ms = (time.perf_counter() - t0) * 1000
    ic, _ = call(
        "/org/freedesktop/portal/inputmethod",
        "org.fcitx.Fcitx.InputMethod1",
        "CreateInputContext",
        "(a(ss))",
        [("program", "sebtype-compare")],
    )
    bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
    call(
        ic, IC, "SetCapability", "(t)", 1 << 1 | 1 << 4 | 1 << 39
    )  # preedit, client-side panel
    call(ic, IC, "FocusIn")
    return proc, ic, t0, up_ms


ui = {"t": None, "cands": 0}


def on_signal(_c, _s, _p, _i, name, params):
    if name == "UpdateClientSideUI":
        ui["t"] = time.perf_counter()
        ui["cands"] = len(params.unpack()[4])


def key(ic, name):  # -> (reply_ms, ui_ms or None)
    sym, code = KEYS[name]
    ui["t"] = None
    t0 = time.perf_counter()
    call(ic, IC, "ProcessKeyEvent", "(uuubu)", sym, code, 0, False, 0)
    reply = (time.perf_counter() - t0) * 1000
    pump(0.03)
    shown = (ui["t"] - t0) * 1000 if ui["t"] else None
    call(ic, IC, "ProcessKeyEvent", "(uuubu)", sym, code, 0, True, 0)
    pump(0.01)
    return reply, shown


def use(im):
    call(*CONTROLLER, "SetCurrentIM", "(s)", im)
    pump(0.05)


def ready(ic, t0):
    # Until the engine shows candidates (Rime: its deploy or check done; Mozc: server up).
    while True:
        key(ic, "n")
        key(ic, "i")
        got = ui["cands"]
        key(ic, "Escape")
        if got:
            return (time.perf_counter() - t0) * 1000
        if time.perf_counter() - t0 > 300:
            sys.exit("no candidates after 300 s")
        time.sleep(0.2)


def mem(pid):  # -> (rss_kb, pss_kb)
    with open(f"/proc/{pid}/smaps_rollup") as f:
        v = {
            l.split(":")[0]: int(l.split()[1])
            for l in f
            if l.split(":")[0] in ("Rss", "Pss")
        }
    return v["Rss"], v["Pss"]


def read(path):
    with open(path, "rb") as f:
        return f.read()


def mozc_pid():  # this profile's mozc_server, found by its HOME
    home = f"HOME={os.environ['HOME']}".encode()
    for p in os.listdir("/proc"):
        try:
            if read(f"/proc/{p}/comm").strip() == b"mozc_server" and home in read(
                f"/proc/{p}/environ"
            ).split(b"\0"):
                return int(p)
        except OSError:
            pass
    return None


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, round(q * (len(v) - 1)))]


def stats(name, v):
    if v:
        print(
            f"{name}_p50_ms={statistics.median(v):.2f}\n{name}_p95_ms={pct(v, 0.95):.2f}\n{name}_max_ms={max(v):.2f}"
        )


words = [w.strip() for w in sys.stdin if w.strip()]

if mode == "keys":
    im, runs, log = sys.argv[2], int(sys.argv[3]), sys.argv[4]
    # First start: a fresh profile (Rime deploys or checks its data here), then a second start on it.
    for n, label in ((1, "first"), (2, "second")):
        proc, ic, t0, up = start(log)
        use(im)
        print(f"{label}_up_ms={up:.0f}\n{label}_ready_ms={ready(ic, t0):.0f}")
        if n == 1:
            proc.terminate()
            proc.wait(10)
            if m := mozc_pid():
                os.kill(m, 15)
            time.sleep(1)
    time.sleep(3)
    rss, pss = mem(proc.pid)
    print(f"fcitx5_idle_rss_kb={rss}\nfcitx5_idle_pss_kb={pss}")
    reply, shown, convert, nkeys = [], [], [], 0
    for _ in range(runs):
        for w in words:
            for c in w:
                r, s = key(ic, c)
                reply.append(r)
                nkeys += 1
                if s is not None:
                    shown.append(s)
            if im == "mozc":
                r, s = key(ic, "space")
                convert.append(s if s is not None else r)
                key(ic, "Escape")
            key(ic, "Escape")
    print(f"keys={nkeys}\nui_updates={len(shown)}")
    stats("reply", reply)
    stats("ui", shown)
    stats("convert", convert)
    rss, pss = mem(proc.pid)
    print(f"fcitx5_rss_kb={rss}\nfcitx5_pss_kb={pss}")
    if m := mozc_pid():
        rss, pss = mem(m)
        print(f"mozc_server_rss_kb={rss}\nmozc_server_pss_kb={pss}")
    proc.terminate()
    proc.wait(10)
    if m := mozc_pid():
        os.kill(m, 15)

elif mode == "soak":
    minutes, log = float(sys.argv[2]), sys.argv[3]
    proc, ic, t0, _ = start(log)
    zh = [w for w in words if not w.startswith("ja:")]
    ja = [w[3:] for w in words if w.startswith("ja:")]
    for im in ("mozc", "rime"):
        use(im)
        ready(ic, time.perf_counter())
    mozc0, nkeys, samples, crashes = mozc_pid(), 0, [], []
    end, next_sample, i = time.time() + minutes * 60, 0, 0
    while time.time() < end:
        im, w = ("rime", zh[i % len(zh)]) if i % 2 == 0 else ("mozc", ja[i % len(ja)])
        use(im)
        for c in w:
            key(ic, c)
            nkeys += 1
        key(ic, "space")  # Rime commits the first candidate, Mozc converts
        if im == "mozc":
            key(ic, "Return")
        i += 1
        if proc.poll() is not None:
            crashes.append("fcitx5 exited")
            break
        if (m := mozc_pid()) != mozc0:
            crashes.append(f"mozc_server changed {mozc0} -> {m}")
            mozc0 = m
        if time.time() >= next_sample:
            f, z = mem(proc.pid), mem(mozc0) if mozc0 else (0, 0)
            samples.append(
                (round(time.time() - (end - minutes * 60)), f[1], z[1], f[0], z[0])
            )
            next_sample = time.time() + 30
    print(
        f"keys={nkeys}\nwords={i}\ncrashes={len(crashes)}"
        + "".join(f"\ncrash={c}" for c in crashes)
    )
    for t, fp, zp, fr, zr in samples:
        print(
            f"sample=t{t}s fcitx5_pss_kb={fp} mozc_pss_kb={zp} fcitx5_rss_kb={fr} mozc_rss_kb={zr}"
        )
    proc.terminate()
    proc.wait(10)
    if m := mozc_pid():
        os.kill(m, 15)
