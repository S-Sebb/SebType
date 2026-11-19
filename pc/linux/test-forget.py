# Forget learned words while SebType's input method runs (#375), in a private Fcitx5 that this script starts
# and restarts (pc/configurator/test.sh's private-forget, inside its private D-Bus session and sandbox):
#   python3 test-forget.py <out> <configurator tests executable>
# In 中文 (shishi) and 日本語 (kisha) the 4th candidate is picked, and is then first: learned. The
# Configurator's forget (its ignored test linux::tests::private_fcitx5_forgets, the app's own code) runs while
# both engines are open and another app keeps typing (k a Escape, which learns nothing); then the first candidate
# is the original one again, and still after Fcitx5 restarts. The same for 日本語's prediction (Tab after きし
# no longer suggests the word picked) and a character form it learns (a digit's width, which Mozc keeps for
# the whole process), and at the end the Configurator says forgetting
# failed when the input method couldn't delete what was learned (read-only folders).
# Results: one line per check, also in <out>/forget-results.txt; exit 1 if a check fails.
import os
import signal
import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

out, tests = sys.argv[1:3]
failed = 0


def result(name, ok, why):
    global failed
    failed += not ok
    line = f"{'PASS' if ok else 'FAIL'} {name}: {why}"
    print(line, flush=True)
    with open(f"{out}/forget-results.txt", "a") as f:
        f.write(line + "\n")


bus = dbus.SessionBus(mainloop=DBusGMainLoop())
SYMS = {" ": 0x20, "\n": 0xFF0D, "\x1b": 0xFF1B, "\t": 0xFF09}


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


class Fcitx:
    def __init__(self, name):
        with open(f"{out}/forget-fcitx5-{name}.log", "w") as log:
            self.p = subprocess.Popen(
                [
                    "fcitx5",
                    "-k",
                    "--disable=all",
                    "--enable=dbus,dbusfrontend,keyboard,sebtype",
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        # Not a call before it has the name: the bus would start the system's Fcitx5 for it.
        for _ in range(150):
            if self.p.poll() is not None:
                raise RuntimeError(f"Fcitx5 exited with {self.p.returncode}")
            if not bus.name_has_owner("org.fcitx.Fcitx5"):
                time.sleep(0.2)
                continue
            try:
                self.core = dbus.Interface(self.obj("/sebtype"), "org.sebtype.Core1")
                self.core.State()
                break
            except dbus.DBusException:
                time.sleep(0.2)
        else:
            raise RuntimeError("SebType's input method didn't come up")
        path, _ = dbus.Interface(
            self.obj("/org/freedesktop/portal/inputmethod"),
            "org.fcitx.Fcitx.InputMethod1",
        ).CreateInputContext([("program", "sebtype-test")])
        self.ic = dbus.Interface(self.obj(path), "org.fcitx.Fcitx.InputContext1")
        self.ic.SetCapability(dbus.UInt64(1 << 1))  # preedit
        self.ic.FocusIn()
        self.typed = []
        self.ic.connect_to_signal(
            "CommitString", lambda text: self.typed.append(str(text))
        )

    def focus(self):  # back from the other app
        self.ic.FocusIn()

    def obj(self, path):
        return bus.get_object("org.fcitx.Fcitx5", path)

    def key(self, ch):
        sym = SYMS.get(ch, ord(ch))
        taken = False
        for release in (False, True):
            taken |= bool(
                self.ic.ProcessKeyEvent(
                    dbus.UInt32(sym),
                    dbus.UInt32(0),
                    dbus.UInt32(0),
                    release,
                    dbus.UInt32(0),
                )
            )
        return taken

    def pump(self):
        while GLib.MainContext.default().iteration(False):
            pass

    def type(self, keys):
        """What typing these keys commits."""
        self.pump()
        self.typed.clear()
        for ch in keys:
            self.key(ch)
            time.sleep(0.05)
        time.sleep(0.3)
        self.pump()
        return "".join(self.typed)

    def language(self, lang):
        """Switches to it and waits until its engine takes keys (Rime deploys at its first start)."""
        self.core.SetLanguage(lang)
        for _ in range(600):
            if self.key("n" if lang == "zh" else "a"):
                self.key("\x1b")
                return True
            time.sleep(0.5)
        return False

    def stop(self):
        self.p.send_signal(
            signal.SIGTERM
        )  # Fcitx5 stops its add-ons: Rime and Mozc save and close
        self.p.wait(60)


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


f = Fcitx("first")
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

# Both engines are open, with what they learned in memory and on disk, and another app types meanwhile.
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
f.stop()

f = Fcitx("restarted")
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
    forgot.returncode != 0
    and said.count("Err(") == 2
    and "test.userdb.txt" in said
    and "segment.db" in said,
    f"exit {forgot.returncode}, {said or 'no answer'}",
)
f.stop()
sys.exit(1 if failed else 0)
