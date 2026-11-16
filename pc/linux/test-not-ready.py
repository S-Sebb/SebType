# test-not-ready.sh's checks, inside its nested KWin: types into the private Fcitx5 over D-Bus, reads the tray
# key from SebType's org.sebtype.Core1 State, saves the screen (spectacle) and the popup by the caret (from X).
# Checks: chinese-preparing (grey 中 with "…" while Rime rebuilds, a key goes in as typed, the popup says
# why), chinese-back (中 again, unasked). 日本語 can't be made unavailable here: Mozc falls back to a
# minimal engine, so japanese-ready only shows あ. Results: <out>/results.txt, exit 1 if a check fails.
import os
import shutil
import subprocess
import sys
import time

import dbus
import numpy as np
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
from PIL import Image
from Xlib import X, display

out = sys.argv[1]
failed = 0


def result(name, ok, why):
    global failed
    failed += not ok
    line = f"{'PASS' if ok else 'FAIL'} {name}: {why}"
    print(line, flush=True)
    with open(f"{out}/results.txt", "a") as f:
        f.write(line + "\n")


bus = dbus.SessionBus(mainloop=DBusGMainLoop())  # for CommitString


def obj(path):
    return bus.get_object("org.fcitx.Fcitx5", path)


for _ in range(100):
    try:
        dbus.Interface(obj("/sebtype"), "org.sebtype.Core1").State()
        break
    except dbus.DBusException:
        time.sleep(0.2)
core = dbus.Interface(obj("/sebtype"), "org.sebtype.Core1")
path, _ = dbus.Interface(
    obj("/org/freedesktop/portal/inputmethod"), "org.fcitx.Fcitx.InputMethod1"
).CreateInputContext([("program", "kate")])
ic = dbus.Interface(obj(path), "org.fcitx.Fcitx.InputContext1")
ic.SetCapability(
    dbus.UInt64((1 << 1) | (1 << 4))
)  # preedit, client-side input panel off
ic.FocusIn()
ic.SetCursorRect(120, 640, 1, 20)
typed = []
ic.connect_to_signal("CommitString", lambda text: typed.append(str(text)))


def pump():  # takes in the signals so far
    while GLib.MainContext.default().iteration(False):
        pass


def key(sym):
    """Presses and releases a key; whether SebType took it (if not, it goes to the app as typed)."""
    taken = ic.ProcessKeyEvent(
        dbus.UInt32(sym), dbus.UInt32(0), dbus.UInt32(0), False, dbus.UInt32(0)
    )
    ic.ProcessKeyEvent(
        dbus.UInt32(sym), dbus.UInt32(0), dbus.UInt32(0), True, dbus.UInt32(0)
    )
    return bool(taken)


def icon():
    return str(core.State()[3])


def wait_icon(want, secs):
    end = time.time() + secs
    while icon() != want and time.time() < end:
        time.sleep(0.1)
    return icon()


def shot(name):
    subprocess.run(
        ["spectacle", "-b", "-n", "-f", "-o", f"{out}/{name}.png"],
        stderr=subprocess.DEVNULL,
        timeout=30,
    )


disp = display.Display()


def popup(name):
    """The popup by the caret (Fcitx's classic UI window), saved while it shows; its size, or None."""
    for _ in range(40):
        for w in disp.screen().root.query_tree().children:
            if (
                w.get_attributes().map_state != X.IsViewable
                or (w.get_wm_class() or ("",))[0] != "fcitx"
            ):
                continue
            g = w.get_geometry()
            if g.width <= 20:
                continue
            time.sleep(0.15)  # drawn
            g = w.get_geometry()
            px = np.frombuffer(
                w.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xFFFFFFFF).data,
                np.uint8,
            )
            b, gr, r, a = (
                c.astype(np.int32)
                for c in px.reshape(g.height, g.width, 4).transpose(2, 0, 1)
            )
            rgb = np.dstack([c + (255 - a) for c in (r, gr, b)]).clip(
                0, 255
            )  # over white
            Image.fromarray(rgb.astype(np.uint8)).save(f"{out}/{name}-popup.png")
            return f"{g.width} x {g.height}"
        time.sleep(0.05)
    return None


time.sleep(2)  # the tray takes in Fcitx's item
core.SetLanguage("zh")
ready = wait_icon("sebtype-zh", 180)  # a new profile's first deploy
key(ord("n"))
key(0xFF1B)
time.sleep(1.5)
shot("zh")
result("chinese-ready", ready == "sebtype-zh", f"key {ready}")

# A deploy with nothing changed is over at once: without its build, Rime builds every table again.
shutil.rmtree(
    os.path.join(os.environ["XDG_DATA_HOME"], "fcitx5/rime/build"), ignore_errors=True
)
dbus.Interface(obj("/controller"), "org.fcitx.Fcitx.Controller1").SetConfig(
    "fcitx://config/addon/sebtype/deploy", dbus.Dictionary({}, signature="sv")
)
waiting = wait_icon("sebtype-zh-wait", 2)
taken = key(ord("n"))
size = popup("zh-wait")
shot("zh-wait")
result(
    "chinese-preparing",
    waiting == "sebtype-zh-wait" and not taken and size is not None,
    f"key {waiting}, 'n' {'taken' if taken else 'to the app as typed'}, popup {size}",
)

t = time.time()
back = wait_icon("sebtype-zh", 180)
took = time.time() - t
time.sleep(1)
shot("zh-back")
pump()
typed.clear()
for k in "ni ":
    key(ord(k))
time.sleep(0.5)
pump()
result(
    "chinese-back",
    back == "sebtype-zh" and typed == ["你"],
    f"key {back} after {took:.1f} s, ni + Space typed {typed}",
)

core.SetLanguage("ja")
time.sleep(1.5)
ja = icon()
shot("hira")
result("japanese-ready", ja == "sebtype-hira", f"key {ja}")
sys.exit(1 if failed else 0)
