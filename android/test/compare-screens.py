#!/usr/bin/env python3
"""Screenshots of today's keyboard (app/) next to the new one (next/, #191) on the emulator, for the
user to judge the look by eye: English, symbols, a long press, 中文 with pinyin and candidates, its
简/繁 menu, and 日本語, in the system's light and dark mode. Run under the emulator's lock:

    android/emulator.sh -- android/test/compare-screens.py TODAY_APK NEW_APK FIELD_APK OUTDIR

Installs both afresh (their data is lost), types into the perf field app (android/perf/build-field.sh)
and writes OUTDIR/<mode>-<state>-<today|new>.png, the keyboard's part of the screen at most 1000 px
across, and OUTDIR/index.html, the two side by side.
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

from PIL import Image

today_apk, new_apk, field_apk, outdir = sys.argv[1:5]
serial = os.environ["ANDROID_SERIAL"]
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
APPS = {
    "today": (
        "dev.sebb.sebtype",
        "org.futo.inputmethod.latin.LatinIME",
        "main_keyboard_frame",
        today_apk,
    ),
    "new": ("dev.sebb.sebtype.next", ".SebTypeIme", "keyboard", new_apk),
}
STATES = [
    ("en", "English"),
    ("symbols", "Symbols"),
    ("long-press", "Long press on e"),
    ("zh", "中文: nihao"),
    ("zh-menu", "中文's menu with 简/繁"),
    ("ja", "日本語: nihongo"),
]


def adb(*args, timeout=120):
    return subprocess.run(
        ["adb", "-s", serial, *args], capture_output=True, text=True, timeout=timeout
    ).stdout


def nodes():
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out = []
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            out.append(
                (
                    n.get("text") or n.get("content-desc") or "",
                    tuple(map(int, m.groups())),
                    n.get("resource-id"),
                )
            )
    return out


def frame(app):
    pkg, _, rid, _ = APPS[app]
    for _ in range(30):
        f = next((b for _, b, r in nodes() if r == f"{pkg}:id/{rid}"), None)
        if f:
            return f
        time.sleep(1)
    raise SystemExit(f"{app}: no keyboard")


def tap(x, y):
    adb("shell", "input", "tap", str(int(x)), str(int(y)))


def tap_label(*labels):
    for _ in range(10):
        b = next((b for t, b, _ in nodes() if t in labels), None)
        if b:
            tap((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
            time.sleep(1.5)
            return
        time.sleep(1)
    raise SystemExit(
        f"no {labels[0]} among {sorted({t for t, _, _ in nodes() if t})[:40]}"
    )


class Keys:
    """Places on the uniform QWERTY both keyboards share: four rows, ten keys across."""

    def __init__(self, f):
        self.l, self.t, self.r, self.b = f
        self.w = (self.r - self.l) / 10

    def row(self, r):
        return self.t + (r + 0.5) * (self.b - self.t) / 4

    def letter(self, ch):
        for r, (letters, indent) in enumerate(
            (("qwertyuiop", 0.5), ("asdfghjkl", 1), ("zxcvbnm", 2))
        ):
            if ch in letters:
                return self.l + (letters.index(ch) + indent) * self.w, self.row(r)

    def type(self, text):
        for ch in text:
            tap(*self.letter(ch))
        time.sleep(1.5)

    def bottom(self, column):
        tap(self.l + column * self.w, self.row(3))
        time.sleep(1.5)


def open_field(app):
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    pkg, ime, _, _ = APPS[app]
    adb("shell", "ime", "set", f"{pkg}/{ime}")
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD)
    time.sleep(1)
    return Keys(frame(app))


def shot(name, top):
    path = os.path.join(outdir, name + ".png")
    with open(path, "wb") as f:
        f.write(
            subprocess.run(
                ["adb", "-s", serial, "exec-out", "screencap", "-p"],
                capture_output=True,
            ).stdout
        )
    img = Image.open(path)
    img = img.crop((0, max(0, top), img.width, img.height))
    scale = min(1, 1000 / img.width, 1000 / img.height) * 0.5
    img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS).save(
        path
    )


def chinese_ready(app, k):
    """Waits (Chinese sets itself up on its first start) until nihao has candidates."""
    for _ in range(40):
        k = open_field(app)
        k.type("nihao")
        if any(t in ("你好",) for t, _, _ in nodes()):
            return k
        time.sleep(5)
    raise SystemExit(f"{app}: no 你好 for nihao")


def menu(app):
    if app == "new":
        tap_label("Open Action Bar")
        return
    # Today's bar is labelled in the keyboard's language. The expanded bar is a saved setting: it may be
    # open, with All Actions showing, already.
    labels = {t for t, _, _ in nodes()}
    if not labels & {"All Actions", "所有操作项"}:
        tap_label("Open Action Bar", "打开操作栏")
    tap_label("All Actions", "所有操作项")


def run(app, mode):
    k = open_field(app)
    top = k.t - 520  # the bar, the floating pinyin and some of the field above the keys

    def step(state, do):
        """One screenshot; a state that fails is noted in the page instead of stopping the run."""
        try:
            do()
            shot(f"{mode}-{state}-{app}", top)
        except (SystemExit, KeyError, ValueError, subprocess.SubprocessError) as e:
            failed[f"{mode}-{state}-{app}"] = str(e)
            print(f"{mode}-{state}-{app}: {e}", flush=True)

    step("en", lambda: None)
    step("symbols", lambda: k.bottom(0.75))  # ?123
    k.bottom(0.75)  # ABC
    x, y = k.letter("e")
    hold = subprocess.Popen(
        [
            "adb",
            "-s",
            serial,
            "shell",
            "input",
            "swipe",
            *map(str, (int(x), int(y), int(x), int(y))),
            "2500",
        ]
    )
    step("long-press", lambda: time.sleep(1.4))
    hold.wait()
    open_field(app)
    k.bottom(3)  # 🌐: EN -> 中
    step("zh", lambda: chinese_ready(app, k))
    step("zh-menu", lambda: (open_field(app), menu(app)))
    open_field(app)  # a new field closes the menu
    k.bottom(3)  # 中 -> 日
    step("ja", lambda: (open_field(app).type("nihongo"), time.sleep(2)))
    open_field(app).bottom(3)  # 日 -> EN for the next run


failed = {}
os.makedirs(outdir, exist_ok=True)
adb("install", "-r", field_apk, timeout=300)
for app, (pkg, ime, _, apk) in APPS.items():
    adb("uninstall", pkg)
    adb("install", apk, timeout=300)
    for _ in range(15):
        if f"{pkg}/{ime}" in adb("shell", "ime", "list", "-a", "-s"):
            break
        time.sleep(2)
    adb("shell", "ime", "enable", f"{pkg}/{ime}")
try:
    for mode in ("light", "dark"):
        adb("shell", "cmd", "uimode", "night", "yes" if mode == "dark" else "no")
        time.sleep(2)
        for app in APPS:
            run(app, mode)
finally:
    adb("shell", "cmd", "uimode", "night", "no")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")

rows = "\n".join(
    f"<tr><th>{label}<br><small>{mode}</small></th>"
    + "".join(
        f"<td>not taken: {failed[n]}</td>"
        if (n := f"{mode}-{state}-{app}") in failed
        else f'<td><img src="{n}.png"></td>'
        for app in APPS
    )
    + "</tr>"
    for mode in ("light", "dark")
    for state, label in STATES
)
with open(os.path.join(outdir, "index.html"), "w", encoding="utf-8") as f:
    f.write(f"""<!doctype html><meta charset="utf-8"><title>SebType: today's keyboard and the new one</title>
<style>body{{font-family:sans-serif;background:#eee}} td,th{{padding:6px;vertical-align:top}} img{{width:100%;max-width:480px;border:1px solid #ccc}}</style>
<h1>Today's keyboard (left) and the new one (right), #242</h1>
<table><tr><th></th><th>Today (app/)</th><th>New (next/)</th></tr>
{rows}
</table>
""")
print(os.path.join(outdir, "index.html"))
