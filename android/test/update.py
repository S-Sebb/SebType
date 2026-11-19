#!/usr/bin/env python3
"""The update check and install on the emulator (#422), run by android/test/update.sh under the emulator lock.

    update.py DEBUG_APK RESULTS LOGDIR

Installs DEBUG_APK fresh, points its test hook at a made-up release (v9.9.9, whose APK is DEBUG_APK itself)
served from this PC, and walks the shortest path through each step. One line per check in RESULTS; a check
after one that failed is skipped. Labels match the emulator's English, Chinese or Japanese UI.
"""

import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET

apk, results_path, logdir = sys.argv[1:4]
serial = os.environ["ANDROID_SERIAL"]
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
SETTINGS = f"{PKG}/.settings.SettingsActivity"
VERSION = "9.9.9"
DEVICE_PORT = (
    8422  # the emulator's 127.0.0.1:8422, which adb reverse sends to the server here
)
log_path = os.path.join(logdir, "update-adb.log")

ABOUT = ("About", "关于", "情報")
DONE = ("Done", "完成", "完了")
CHECK = ("Check for updates", "检查更新", "アップデートを確認")
AUTO = ("Check for updates automatically", "自动检查更新", "アップデートを自動で確認")
AVAILABLE = tuple(
    f.format(VERSION)
    for f in (
        "SebType {} is available",
        "SebType {} 已发布",
        "SebType {} が利用できます",
    )
)
ALLOW_NOTIFY = "com.android.permissioncontroller:id/permission_allow_button"


def adb(*args, timeout=120, check=True):
    p = subprocess.run(
        ["adb", "-s", serial, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"$ adb {' '.join(args)}\n{p.stdout[-2000:]}{p.stderr[-2000:]}\n")
    if check and p.returncode != 0:
        raise Fail(
            f"adb {' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}"
        )
    return p.stdout


class Fail(Exception):
    pass


def wait_for(what, fn, timeout, interval=1.0):
    end = time.time() + timeout
    while True:
        value = fn()
        if value:
            return value
        if time.time() > end:
            raise Fail(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


def nodes():
    """(label, resource-id, x, y) of every node on the screen"""
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out = []
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append(
                (
                    n.get("text") or n.get("content-desc") or "",
                    n.get("resource-id") or "",
                    (x1 + x2) // 2,
                    (y1 + y2) // 2,
                )
            )
    return out


def find(texts, ns=None):
    return [
        (x, y) for label, rid, x, y in (ns or nodes()) if label in texts or rid in texts
    ]


def tap_text(texts, scroll=True):
    for _ in range(5):
        found = find(texts)
        if found:
            adb("shell", "input", "tap", *map(str, found[0]))
            time.sleep(1.5)
            return
        if not scroll:
            break
        adb("shell", "input", "swipe", "540", "1800", "540", "900", "400")
        time.sleep(1)
    raise Fail(f"no {texts[0]} on the screen")


def shown(texts):
    return bool(find(texts))


def screenshot(name):
    with open(os.path.join(logdir, f"update-{name}.png"), "wb") as f:
        f.write(
            subprocess.run(
                ["adb", "-s", serial, "exec-out", "screencap", "-p"],
                capture_output=True,
                timeout=60,
            ).stdout
        )


def resumed():
    """The activity on top, as dumpsys names it"""
    m = re.search(
        r"(?:topResumedActivity|mResumedActivity)[=:].*? (\S+/\S+)",
        adb("shell", "dumpsys", "activity", "activities"),
    )
    return m.group(1) if m else ""


# --- The made-up release, served here ---

requests = []  # (path, headers) of every request the app made
# The release is out only from "Check for updates" on: the daily job's first run, which Android may start as
# soon as SebType schedules it, finds nothing before.
released = threading.Event()


class Release(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        if self.path == "/latest.json" and not released.is_set():
            return self.send_error(503)
        super().do_GET()

    def log_message(self, *args):
        pass


def serve():
    d = os.path.join(logdir, "release")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    name = f"SebType-{VERSION}-arm64-v8a.apk"
    shutil.copyfile(apk, os.path.join(d, name))
    with open(os.path.join(d, "latest.json"), "w") as f:
        json.dump(
            {
                "tag_name": f"v{VERSION}",
                "assets": [
                    {
                        "name": f"SebType-setup-{VERSION}.exe",
                        "browser_download_url": f"http://127.0.0.1:{DEVICE_PORT}/missing.exe",
                    },
                    {
                        "name": name,
                        "browser_download_url": f"http://127.0.0.1:{DEVICE_PORT}/{name}",
                    },
                ],
            },
            f,
        )
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), lambda *a: Release(*a, directory=d)
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# --- The checks ---

failed = []


def check(name, fn):
    if failed:
        return result("SKIP", name, f"after {failed[0]} failed")
    try:
        result("PASS", name, fn() or "")
    except (Fail, subprocess.SubprocessError, ET.ParseError, ValueError) as e:
        failed.append(name)
        result("FAIL", name, str(e))
        with open(os.path.join(logdir, f"{name}.logcat"), "w") as f:
            f.write(adb("logcat", "-d", check=False))


def result(status, name, detail=""):
    line = f"{status} update-{name}" + (f": {detail}" if detail else "")
    print(line, flush=True)
    with open(results_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def install():
    adb("uninstall", PKG, check=False)
    adb("install", apk, timeout=300)
    # The hook before SebType's process first starts, which reads it once
    adb(
        "shell",
        "run-as",
        PKG,
        "sh",
        "-c",
        f"'mkdir -p files && echo http://127.0.0.1:{DEVICE_PORT}/latest.json > files/update-test-url'",
    )
    adb("reverse", f"tcp:{DEVICE_PORT}", f"tcp:{server.server_address[1]}")
    # The system lists a newly installed keyboard a few seconds after the install returns.
    wait_for(
        "SebType among the keyboards",
        lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
        30,
    )
    adb("shell", "ime", "enable", IME)
    adb("shell", "ime", "set", IME)


def open_home():
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", SETTINGS)

    def home():
        ns = nodes()
        if find(ABOUT, ns):
            return True
        if find(DONE, ns):  # a fresh install opens on setup until its last step's Done
            tap_text(DONE)
        return False

    wait_for("the settings' home screen", home, 60)


def about_asks_to_notify():
    open_home()
    tap_text(ABOUT)
    wait_for(
        "Android's notification permission dialog", lambda: shown((ALLOW_NOTIFY,)), 15
    )
    tap_text((ALLOW_NOTIFY,), scroll=False)
    granted = "POST_NOTIFICATIONS: granted=true" in adb(
        "shell", "dumpsys", "package", PKG
    )
    if not granted:
        raise Fail("POST_NOTIFICATIONS not granted after Allow")


def about_entries():
    wait_for("the update entries", lambda: shown(CHECK) and shown(AUTO), 10)
    screenshot("about")


def check_now_finds():
    released.set()
    tap_text(CHECK)
    wait_for(f"{AVAILABLE[0]} on About", lambda: shown(AVAILABLE), 30)
    screenshot("about-found")


def home_card():
    adb("shell", "input", "keyevent", "4")
    wait_for(
        f"{AVAILABLE[0]} on the home screen",
        lambda: shown(AVAILABLE) and shown(ABOUT),
        10,
    )
    screenshot("home")


def request_sends_nothing_else():
    asks = [h for path, h in requests if path == "/latest.json"]
    if not asks:
        raise Fail("the server got no check")
    sent = {k.lower(): v for k, v in asks[-1].items()}
    extra = set(sent) - {
        "host",
        "user-agent",
        "accept",
        "accept-encoding",
        "connection",
    }
    if sent.get("user-agent") != "SebType" or extra:
        raise Fail(f"headers {sent}")
    return f"headers: {', '.join(sorted(sent))}"


def daily_notification():
    adb(
        "shell", "input", "keyevent", "3"
    )  # home: the job runs with the settings closed (a force-stop would cancel it)
    adb("shell", "cmd", "jobscheduler", "run", "-f", PKG, "422")
    wait_for(
        "the update notification",
        lambda: any(
            t in adb("shell", "dumpsys", "notification", "--noredact")
            for t in AVAILABLE
        ),
        60,
    )
    adb("shell", "cmd", "statusbar", "expand-notifications")
    wait_for("the notification in the shade", lambda: shown(AVAILABLE), 10)
    screenshot("notification")


def process_dies():
    """The notification outlives SebType's process: another keyboard, so Android doesn't restart it, then a kill.
    The tap that follows starts a new process, which reads the release back before it installs."""
    other = [i for i in adb("shell", "ime", "list", "-s").split() if i != IME]
    if not other:
        raise Fail("no other keyboard to switch to")
    adb("shell", "ime", "set", other[0])
    adb("shell", "run-as", PKG, "sh", "-c", f"'kill -9 $(pidof {PKG})'", check=False)
    wait_for(
        "SebType's process gone",
        lambda: not adb("shell", "pidof", PKG, check=False).strip(),
        15,
    )
    if not shown(AVAILABLE):
        raise Fail("the notification went with the process")
    return f"keyboard {other[0]}"


def notification_asks_to_allow():
    tap_text(AVAILABLE, scroll=False)
    # Settings' "Install unknown apps" for SebType (Android 15 hands it on to its SpaActivity)
    wait_for(
        "Install unknown apps",
        lambda: resumed().startswith("com.android.settings/"),
        20,
    )
    screenshot("allow")


def allowed_opens_installer():
    adb("shell", "appops", "set", PKG, "REQUEST_INSTALL_PACKAGES", "allow")
    adb("shell", "input", "keyevent", "4")  # back to SebType, which goes on
    top = wait_for(
        "Android's install prompt",
        lambda: "packageinstaller" in resumed() and resumed(),
        120,
    )
    if not any(path.endswith(".apk") for path, _ in requests):
        raise Fail("the APK was never downloaded")

    def drawn():  # the prompt's window, not just its activity
        adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
        return 'packageinstaller" ' in adb("shell", "cat", "/sdcard/sebtype-ui.xml")

    wait_for("the install prompt's window", drawn, 20)
    screenshot("install-prompt")
    return top


server = serve()
try:
    adb("wait-for-device")
    check("install", install)
    check("about-asks-to-notify", about_asks_to_notify)
    check("about-entries", about_entries)
    check("check-now-finds", check_now_finds)
    check("home-card", home_card)
    check("request-sends-nothing-else", request_sends_nothing_else)
    check("daily-notification", daily_notification)
    check("process-dies", process_dies)
    check("notification-asks-to-allow", notification_asks_to_allow)
    check("allowed-opens-installer", allowed_opens_installer)
finally:
    adb("shell", "input", "keyevent", "4", check=False)  # dismisses the install prompt
    adb("shell", "cmd", "statusbar", "collapse", check=False)
    adb("reverse", "--remove", f"tcp:{DEVICE_PORT}", check=False)
    adb("uninstall", PKG, check=False)
    server.shutdown()
