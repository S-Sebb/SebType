# Forget learned words while SebType's input method runs (#375), in a private Fcitx5 that this script starts
# and restarts (pc/configurator/test.sh's private-forget, inside its private D-Bus session and sandbox):
#   python3 test-forget.py <out> <configurator tests executable> <configurator>
# In 中文 (shishi) and 日本語 (kisha) the 4th candidate is picked, and is then first: learned. The
# Configurator's forget (its ignored test linux::tests::private_fcitx5_forgets, the app's own code) runs while
# both engines are open and another app keeps typing (k a Escape, which learns nothing); then the first candidate
# is the original one again, and still after Fcitx5 restarts. The same for 日本語's prediction (Tab after きし
# no longer suggests the word picked) and a character form it learns (a digit's width, which Mozc keeps for
# the whole process); the record of Mozc's picks that the sync uploads (#409) is emptied. At the end the
# Configurator says forgetting failed when the input method couldn't delete what was learned (read-only
# folders). Rime's sync folder is
# outside its folder (installation.yaml's sync_dir, #396): a sync before forgetting puts 中文's snapshot there,
# forgetting deletes it and another device's (through a link) but no other file there, and a sync after it
# brings nothing back; the input method's forget fails when a snapshot there can't be read or sync_dir isn't a
# path. Before forgetting, a
# Forget for another language (D-Bus, or the Configurator's --forget) forgets nothing and Fcitx5 lives on.
# Results: one line per check, also in <out>/forget-results.txt; exit 1 if a check fails.
import os
import subprocess
import sys
import time

import dbus
from private_fcitx import Fcitx, bus

out, tests = sys.argv[1:3]
app = sys.argv[3] if len(sys.argv) > 3 else ""
failed = 0


def result(name, ok, why):
    global failed
    failed += not ok
    line = f"{'PASS' if ok else 'FAIL'} {name}: {why}"
    print(line, flush=True)
    with open(f"{out}/forget-results.txt", "a") as f:
        f.write(line + "\n")


def other_app():
    """Another app typing in its own input context until stopped: a key may come between any two steps of a
    forget that isn't one operation."""
    fcitx = bus.get_object("org.fcitx.Fcitx5", "/org/freedesktop/portal/inputmethod")
    path, _ = dbus.Interface(fcitx, "org.fcitx.Fcitx.InputMethod1").CreateInputContext(
        [("program", "other-app")]
    )
    ic = dbus.Interface(
        bus.get_object("org.fcitx.Fcitx5", path), "org.fcitx.Fcitx.InputContext1"
    )
    ic.FocusIn()
    while True:
        for sym in (ord("k"), ord("a"), 0xFF1B):
            for release in (False, True):
                ic.ProcessKeyEvent(
                    dbus.UInt32(sym),
                    dbus.UInt32(0),
                    dbus.UInt32(0),
                    release,
                    dbus.UInt32(0),
                )


if tests == "--other-app":
    other_app()


# The first candidate, and the 4th picked (Mozc: Space converts, each Space after it the next).
WORDS = {"zh": ("shishi ", "shishi4"), "ja": ("kisha \n", "kisha    \n")}
# Mozc's first prediction (Tab) for きし: its prediction history, which suggests the word picked above.
PREDICT = "kisi\t\n"


def width(digit, text):
    """Whether Mozc's first candidate for the digit is half or full width (its learned form for all digits)."""
    return {digit: "half", chr(0xFF10 + int(digit)): "full"}.get(text, f"'{text}'")


def digit_form(f, digit):
    return width(digit, f.type(digit + " \n"))


def learn_digit_form(f, form):
    """Commits 2 in the other width: Mozc's next digits come in that form, never typed before."""
    for spaces in range(1, 9):
        if width("2", f.type("2" + " " * spaces + "\n")) == form:
            return True
    return False


# Rime's sync folder outside its folder (#396), as a home folder may be, with a # in its path (unquoted YAML),
# files that aren't Rime's snapshots or that its sync doesn't merge, and a device's folder through a link.
rime_dir = f"{os.environ['XDG_DATA_HOME']}/fcitx5/rime"
sync_dir = f"{os.environ['HOME']}/outside#sync"
SNAPSHOT = "# Rime user dictionary\n#@/db_name\trime_ice\n"
KEPT = {
    "notes.txt": "not Rime's\n",
    "archive/deep/rime_ice.userdb.txt": SNAPSHOT,
    "other/app.userdb.txt": "an app's own\n",
    "other/dir.userdb.txt/inside": "x\n",
}
for name, text in {**KEPT, "../linked-device/rime_ice.userdb.txt": SNAPSHOT}.items():
    os.makedirs(os.path.dirname(f"{sync_dir}/{name}"), exist_ok=True)
    with open(f"{sync_dir}/{name}", "w") as made_up:
        made_up.write(text)
os.symlink(f"{os.environ['HOME']}/linked-device", f"{sync_dir}/linked")
with open(f"{rime_dir}/installation.yaml") as y:
    lines = [line for line in y.read().splitlines() if not line.startswith("sync_dir:")]
with open(f"{rime_dir}/installation.yaml", "w") as y:
    y.write("\n".join(lines + [f"sync_dir: {sync_dir}"]) + "\n")
snapshot = next(
    f"{sync_dir}/{line.split(':', 1)[1].strip().strip(chr(34))}/rime_ice.userdb.txt"
    for line in lines
    if line.startswith("installation_id:")
)
linked = f"{sync_dir}/linked/rime_ice.userdb.txt"


def mtime():
    return os.stat(snapshot).st_mtime_ns if os.path.exists(snapshot) else 0


def sync(f):
    """Fcitx5's save (the sync's), which syncs Rime once typing is idle: whether it wrote 中文's snapshot.
    It isn't deleted first: a snapshot that Forget left would come back in this sync's merge."""
    before = mtime()
    f.obj("/controller").Save(dbus_interface="org.fcitx.Fcitx.Controller1")
    for _ in range(120):
        if mtime() > before:
            return True
        time.sleep(0.5)
    return False


f = Fcitx(f"{out}/forget-fcitx5-first.log")
first, picked = {}, {}
for lang, (top, fourth) in WORDS.items():
    ready = f.language(lang)
    predicted = f.type(PREDICT) if lang == "ja" else ""
    first[lang] = f.type(top)
    picked[lang] = f.type(fourth)
    again = f.type(top)
    result(
        f"{lang}-learns",
        ready
        and first[lang]
        and picked[lang] not in ("", first[lang])
        and again == picked[lang],
        f"{'ready' if ready else 'never ready'}, first '{first[lang]}', 4th '{picked[lang]}', then first '{again}'",
    )
now = f.type(PREDICT)
result(
    "ja-learns-prediction",
    predicted != picked["ja"] and now == picked["ja"],
    f"きし predicted '{predicted}', after '{picked['ja']}' '{now}'",
)
# Still in 日本語: digits each in a width of their own, none typed twice (or the history would choose).
base = digit_form(f, "3")
other = {"half": "full", "full": "half"}.get(base, "?")
learned = learn_digit_form(f, other) and digit_form(f, "5")
result(
    "ja-learns-character-form",
    learned == other,
    f"3 is {base}, then 5 is {learned} after 2 in {other} width",
)

synced = sync(f)
result(
    "zh-syncs-outside-rime-folder",
    synced,
    f"snapshot {'in' if synced else 'not in'} {sync_dir}",
)

# No language, or one that learns nothing: refused and nothing forgotten, by the Configurator's --forget and
# over D-Bus, where Fcitx5 still runs after.
exits = {
    " ".join(args): subprocess.run(
        [app, "--forget", *args], check=False, capture_output=True, timeout=60
    ).returncode
    for args in ([], ["en"], ["JA"])
}
kept = {lang: f.language(lang) and f.type(WORDS[lang][0]) for lang in WORDS}
result(
    "configurator-forget-refuses-other-languages",
    all(exits.values()) and kept == picked,
    f"--forget exits {exits}, then first {kept}, want {picked}",
)
answers = {}
for lang in ("en", "xx", ""):
    try:
        answers[lang] = str(f.core.Forget(lang))
    except dbus.DBusException as e:
        answers[lang] = f"no answer ({e.get_dbus_name()})"
alive = f.p.poll() is None
result(
    "dbus-forget-refuses-other-languages",
    alive and all(a and not a.startswith("no answer") for a in answers.values()),
    f"{'Fcitx5 runs' if alive else f'Fcitx5 exited with {f.p.returncode}'}, answers {answers}",
)

# Both engines are open, with what they learned in memory and on disk, and another app types meanwhile.
# This PC's record of its Mozc picks, which the sync uploads (#409): Forget empties it.
own = f"{os.environ['XDG_CONFIG_HOME']}/mozc/mozc_learned.txt"
LEARNED_HEADER = "# SebType mozc_learned 1\n"


def record():
    try:
        with open(own, encoding="utf-8") as r:
            return r.read()
    except FileNotFoundError:
        return ""


recorded = f"\t{picked['ja']}\t" in record()
typer = subprocess.Popen([sys.executable, __file__, out, "--other-app"])
time.sleep(1)
forgot = subprocess.run(
    [tests, "--ignored", "--exact", "linux::tests::private_fcitx5_forgets"],
    check=False,
    capture_output=True,
    text=True,
    timeout=300,
)
typer.kill()
typer.wait()
f.focus()
with open(f"{out}/forget-configurator.log", "w") as log:
    log.write(forgot.stdout + forgot.stderr)
result(
    "configurator-forgets",
    forgot.returncode == 0,
    f"exit {forgot.returncode}, see {out}/forget-configurator.log",
)

result(
    "ja-record-forgotten",
    recorded and record() == LEARNED_HEADER,
    f"'{picked['ja']}' {'in' if recorded else 'not in'} the record before, after {record()!r}",
)
left = [p for p in (snapshot, linked) if os.path.exists(p)]
gone = [name for name in KEPT if not os.path.exists(f"{sync_dir}/{name}")]
result(
    "zh-snapshots-forgotten-outside-rime-folder",
    not left and not gone,
    f"snapshots left {left}, other files deleted {gone}",
)
for lang, (top, _) in WORDS.items():
    ready = f.language(lang)
    now = f.type(top)
    result(
        f"{lang}-forgotten-while-typing",
        ready and now == first[lang],
        f"first '{now}', want '{first[lang]}'",
    )
now = f.type(PREDICT)
result(
    "ja-prediction-forgotten-while-typing",
    now not in ("", picked["ja"]),
    f"きし predicted '{now}', not '{picked['ja']}'",
)
now = digit_form(f, "6")
result(
    "ja-character-form-forgotten-while-typing", now == base, f"6 is {now}, want {base}"
)
synced = sync(f)
now = f.language("zh") and f.type(WORDS["zh"][0])
result(
    "zh-forgotten-after-sync",
    synced and now == first["zh"],
    f"{'synced' if synced else 'no sync'}, first '{now}', want '{first['zh']}'",
)
f.stop()

f = Fcitx(f"{out}/forget-fcitx5-restarted.log")
for lang, (top, _) in WORDS.items():
    ready = f.language(lang)
    now = f.type(top)
    result(
        f"{lang}-forgotten-after-restart",
        ready and now == first[lang],
        f"first '{now}', want '{first[lang]}'",
    )
now = f.type(PREDICT)
result(
    "ja-prediction-forgotten-after-restart",
    now not in ("", picked["ja"]),
    f"きし predicted '{now}', not '{picked['ja']}'",
)
now = digit_form(f, "7")
result(
    "ja-character-form-forgotten-after-restart", now == base, f"7 is {now}, want {base}"
)


def engine_forget():
    """中文's forget in the input method itself (the Configurator refuses before asking it): what it said."""
    return str(f.core.Forget("zh"))


# A snapshot it can't read may merge back once it can, and a sync_dir that isn't a path may be any folder
# to Rime: forgetting fails and says so.
locked = f"{sync_dir}/locked-device/rime_ice.userdb.txt"
os.makedirs(os.path.dirname(locked), exist_ok=True)
with open(locked, "w") as made_up:
    made_up.write(SNAPSHOT)
os.chmod(locked, 0o000)
said = engine_forget()
os.chmod(locked, 0o644)
result(
    "zh-forget-fails-on-unreadable-snapshot",
    said.endswith("rime_ice.userdb.txt: can't be read") and os.path.exists(locked),
    f"said '{said}'",
)
os.remove(locked)
with open(f"{rime_dir}/installation.yaml") as y:
    kept_yaml = y.read()
with open(f"{rime_dir}/installation.yaml", "w") as y:
    y.write("\n".join(lines + [f"sync_dir: [{sync_dir}]"]) + "\n")
said = engine_forget()
with open(f"{rime_dir}/installation.yaml", "w") as y:
    y.write(kept_yaml)
result(
    "zh-forget-refuses-sync-dir-not-a-path",
    "isn't a path" in said,
    f"said '{said}'",
)

# What the engines learned (made up here) in folders they can't delete from: the Configurator says it failed.
dirs = [
    f"{os.environ['XDG_DATA_HOME']}/fcitx5/rime",
    f"{os.environ['XDG_CONFIG_HOME']}/mozc",
]
for d, name in zip(dirs, ("test.userdb.txt", "segment.db")):
    with open(f"{d}/{name}", "w") as made_up:
        made_up.write("made up\n")
    os.chmod(d, 0o555)
try:
    forgot = subprocess.run(
        [tests, "--ignored", "--exact", "linux::tests::private_fcitx5_forgets"],
        check=False,
        capture_output=True,
        text=True,
        timeout=300,
    )
finally:
    for d in dirs:
        os.chmod(d, 0o755)
said = next(
    (line for line in forgot.stdout.splitlines() if line.startswith("Rime: ")), ""
)
result(
    "configurator-says-forgetting-failed",
    forgot.returncode != 0 and said.count("Permission denied") == 2,
    f"exit {forgot.returncode}, {said or 'no answer'}",
)
f.stop()
sys.exit(1 if failed else 0)
