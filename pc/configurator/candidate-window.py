#!/usr/bin/env python3
"""Types into a private Fcitx5 on this D-Bus session and saves its candidate window (#94), for test.sh.

    candidate-window.py OUT.png [KEYS]        # needs python3-dbus, python3-xlib, Pillow, NumPy; KEYS: nihao

Runs inside a nested KWin with Xwayland, where Fcitx5 draws with X11 (classicui on xcb). It talks to
Fcitx5 as an app would (an input context with inline preedit, on Rime), waits for the window's size to
settle, saves its pixels over a light desktop and prints `WIDTHxHEIGHT LOGO_PIXELS TAB`: the pink pixels
where the Picnic theme draws SebType's pig, left of the candidates, and 1 if the window's top is a tab
(#162): drawn at the left, clear at the right.
"""

import sys
import time

import dbus
import numpy as np
from PIL import Image
from Xlib import X, display

out, keys = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "nihao")
bus = dbus.SessionBus()
fcitx = bus.get_object("org.fcitx.Fcitx5", "/org/freedesktop/portal/inputmethod")
path, _ = dbus.Interface(fcitx, "org.fcitx.Fcitx.InputMethod1").CreateInputContext(
    [("program", "kate")]
)
ic = dbus.Interface(
    bus.get_object("org.fcitx.Fcitx5", path), "org.fcitx.Fcitx.InputContext1"
)
ic.SetCapability(
    dbus.UInt64((1 << 1) | (1 << 4))
)  # Preedit | FormattedPreedit: the app shows the preedit
ic.FocusIn()
ic.SetCursorRect(60, 60, 1, 20)
controller = dbus.Interface(
    bus.get_object("org.fcitx.Fcitx5", "/controller"), "org.fcitx.Fcitx.Controller1"
)
controller.SetCurrentIM("rime")


def type_keys(keysyms):
    for k in keysyms:
        for release in (False, True):
            ic.ProcessKeyEvent(
                dbus.UInt32(k), dbus.UInt32(0), dbus.UInt32(0), release, dbus.UInt32(0)
            )


def window():
    """Fcitx5's mapped input window and its size."""
    for w in display_.screen().root.query_tree().children:
        if (
            w.get_attributes().map_state == X.IsViewable
            and (w.get_wm_class() or ("",))[0] == "fcitx"
        ):
            g = w.get_geometry()
            return w, (g.width, g.height)
    return None, None


def settled():
    """The window once its size holds for a quarter second, within 5 s."""
    last = None
    for _ in range(20):
        time.sleep(0.25)
        w, size = window()
        if size and size == last:
            return w, size
        last = size
    return None, None


display_ = display.Display()
# Keys typed while Rime still loads its schema show nothing: then clear (Esc) and type them again.
for _ in range(3):
    type_keys(map(ord, keys))
    w, size = settled()
    if w:
        break
    type_keys([0xFF1B])
else:
    sys.exit("no candidate window, or its size never settled")

raw = w.get_image(0, 0, *size, X.ZPixmap, 0xFFFFFFFF).data
px = (
    np.frombuffer(raw, np.uint8).reshape(size[1], size[0], 4).astype(np.int32)
)  # BGRA, premultiplied
b, g, r, a = (px[..., i] for i in range(4))
rgb = np.dstack(
    [c + (255 - a) * d // 255 for c, d in ((r, 0xE9), (g, 0xE6), (b, 0xE1))]
)  # over a light desk
Image.fromarray(rgb.astype(np.uint8)).save(out)
# The pig's pink (about #f5a0b4) in the first 40 px; the theme's own pinks are darker (#c2506a).
r, g, b = (rgb[:, :40, i] for i in range(3))
pink = int(((r > 220) & (g > 120) & (g < 200) & (b > 140) & (r - g > 40)).sum())
tab = int(a[3, 10] > 0 and a[3, size[0] - 15] == 0)
print(f"{size[0]}x{size[1]} {pink} {tab}")
