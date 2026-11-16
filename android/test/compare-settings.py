#!/usr/bin/env python3
"""Screenshots of the settings in today's app (app/) next to the new one's (next/, #254, #267) on the emulator,
for judging the look by eye: the setup wizard, the home screen and its five groups, in the system's light and
dark mode, with the emulator in English. Run under the emulator's lock:

    android/emulator.sh -- android/test/compare-settings.py OUTDIR new=NEW_APK [today=TODAY_APK]

Installs each APK afresh (its data is lost) and writes OUTDIR/<screen>-<app>-<mode>.png, at most 1000 px
high, and OUTDIR/index.html with the apps side by side. An app left out keeps the shots already in OUTDIR
(today's app's settings rarely change). A screen that fails is noted in the page instead of stopping the run.
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

from PIL import Image

outdir = sys.argv[1]
apks = dict(a.split("=", 1) for a in sys.argv[2:])
serial = os.environ["ANDROID_SERIAL"]
APPS = {
    "today": (
        "dev.sebb.sebtype",
        "org.futo.inputmethod.latin.LatinIME",
        "org.futo.inputmethod.latin.uix.settings.SettingsActivity",
    ),
    "new": (
        "dev.sebb.sebtype.next",
        ".SebTypeIme",
        "dev.sebb.sebtype.next.settings.SettingsActivity",
    ),
}
# Each group's row on the home screen, and a label its screen shows
SCREENS = [
    ("home", None, "About"),
    ("languages", "Languages", "Globe order"),
    ("keyboard", "Keyboard", "Popup on keypress"),
    ("privacy", "Privacy", "Learn from my typing"),
    ("backup", "Sync & backup", "Import settings"),
    ("about", "About", "Version"),
]
MODES = ("light", "dark")


def adb(*args, timeout=120):
    return subprocess.run(
        ["adb", "-s", serial, *args], capture_output=True, text=True, timeout=timeout
    ).stdout


def labels():
    adb("shell", "uiautomator", "dump", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    if "<" not in xml:
        return {}
    out = {}
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        text = n.get("text") or n.get("content-desc")
        if m and text:
            out.setdefault(text, tuple(map(int, m.groups())))
    return out


def wait_for(text):
    for _ in range(20):
        if b := labels().get(text):
            return b
        time.sleep(1)
    raise RuntimeError(f"no {text!r} on the screen")


def shot(name):
    path = os.path.join(outdir, name + ".png")
    with open(path, "wb") as f:
        f.write(
            subprocess.run(
                ["adb", "-s", serial, "exec-out", "screencap", "-p"],
                capture_output=True,
            ).stdout
        )
    img = Image.open(path)
    scale = min(1, 1000 / img.width, 1000 / img.height)
    img.resize(
        (round(img.width * scale), round(img.height * scale)), Image.LANCZOS
    ).save(path)


def open_settings(app):
    pkg, _, activity = APPS[app]
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", f"{pkg}/{activity}")
    time.sleep(1.5)


failed = {}


def step(name, do):
    try:
        do()
        time.sleep(1)  # the switches' and ripples' animations
        shot(name)
    except (RuntimeError, subprocess.SubprocessError) as e:
        failed[name] = str(e)
        print(f"{name}: {e}", flush=True)


os.makedirs(outdir, exist_ok=True)
try:
    for app in apks:
        pkg, ime, _ = APPS[app]
        adb("uninstall", pkg)
        adb("install", apks[app], timeout=300)
        # Step 1 of the wizard: SebType installed but not on yet.
        for mode in MODES:
            adb("shell", "cmd", "uimode", "night", "yes" if mode == "dark" else "no")
            step(f"wizard-{app}-{mode}", lambda: (open_settings(app), time.sleep(2)))
        for _ in range(15):
            if f"{pkg}/{ime}" in adb("shell", "ime", "list", "-a", "-s"):
                break
            time.sleep(2)
        adb("shell", "ime", "enable", f"{pkg}/{ime}")
        adb("shell", "ime", "set", f"{pkg}/{ime}")
        for mode in MODES:
            adb("shell", "cmd", "uimode", "night", "yes" if mode == "dark" else "no")
            time.sleep(2)
            for screen, row, marker in SCREENS:

                def go(row=row, marker=marker):
                    open_settings(app)
                    if row:
                        l, t, r, b = wait_for(row)
                        adb(
                            "shell",
                            "input",
                            "tap",
                            str((l + r) // 2),
                            str((t + b) // 2),
                        )
                    wait_for(marker)

                step(f"{screen}-{app}-{mode}", go)
finally:
    adb("shell", "cmd", "uimode", "night", "no")
    adb("shell", "input", "keyevent", "KEYCODE_HOME")

sections = "".join(
    f"<section><h2>{screen} · {mode}</h2><div>"
    + "".join(
        f"<figure><figcaption>{app}: not taken: {failed[n]}</figcaption></figure>"
        if n in failed
        else f'<figure><img src="{n}.png"><figcaption>{"today's app" if app == "today" else "new app"}</figcaption></figure>'
        for app in APPS
        if (n := f"{screen}-{app}-{mode}") in failed
        or os.path.exists(os.path.join(outdir, n + ".png"))
    )
    + "</div></section>"
    for screen in [s for s, _, _ in SCREENS] + ["wizard"]
    for mode in MODES
)
with open(os.path.join(outdir, "index.html"), "w", encoding="utf-8") as f:
    f.write(f"""<!doctype html><meta charset="utf-8"><title>SebType settings: today's and new</title>
<style>body{{font-family:sans-serif;background:#f6efe6;margin:24px}}section{{margin-bottom:28px}}
div{{display:flex;gap:16px}}img{{width:360px;border:1px solid #c9b8a6}}h2{{font-size:16px}}
figcaption{{text-align:center;font-size:13px}}</style>
<h1>SebType settings: today's app (left) and the new app (right), light and dark</h1>
{sections}
""")
print(os.path.join(outdir, "index.html"))
sys.exit(1 if failed else 0)
