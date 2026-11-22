#!/usr/bin/env python3
"""Types into a private Fcitx5 on this D-Bus session and saves its candidate window (#94), for test.sh.

    candidate-window.py OUT.png [KEYS [LANG]]   # needs python3-dbus, python3-xlib, Pillow, NumPy; nihao zh

Runs inside a nested KWin with Xwayland, where Fcitx5 draws with X11 (classicui on xcb). It talks to Fcitx5
as an app would (an input context with inline preedit, in SebType's LANG; with KEYS "", the popup of a switch
to LANG; with SWITCH=1, KEYS typed at once after that switch), waits for the window's size to settle, saves
its pixels over a light desktop and prints `WIDTHxHEIGHT LOGO_PIXELS FLAT GAP BORDER FILL ICON`: the pink pixels where the
Picnic theme draws SebType's pig, left of the candidates, 1 if the window is one flat rectangle (#461): its
top border drawn at the left and the right, as no tab rising above it is, and how many px more room the
text has at its left than at its right (about 0 for the switch popup's pill, #476), the left border's colour
and the fill's inside it, and the tray's icon (sebtype-zh) then.
"""

import os
import sys
import time

import dbus
import numpy as np
from PIL import Image
from Xlib import X, display

out, keys, lang = (sys.argv[1:] + ["nihao", "zh"][len(sys.argv) - 2 :])[:3]
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
core = dbus.Interface(
    bus.get_object("org.fcitx.Fcitx5", "/sebtype"), "org.sebtype.Core1"
)
if not keys or os.environ.get(
    "SWITCH"
):  # the switch's popup (no KEYS: ""), or KEYS typed over it
    core.SetLanguage("zh" if lang == "en" else "en")
    time.sleep(1.5)
core.SetLanguage(lang)


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
flat = int(a[1, 14] > 0 and a[1, size[0] - 14] > 0)
# The text's dark pixels inside the 3 px border: how much wider the room left of it is than the room right.
dark = np.flatnonzero((rgb[4:-4, 4:-4].max(axis=2) < 150).any(axis=0))
gap = int(dark[0] - (size[0] - 9 - dark[-1])) if dark.size else 0
# The left border and the fill inside it: the pill's border is the tray key's colour (#476).
border, fill = ("%02x%02x%02x" % tuple(rgb[size[1] // 2, x]) for x in (1, 5))
print(f"{size[0]}x{size[1]} {pink} {flat} {gap} {border} {fill} {core.State()[3]}")
