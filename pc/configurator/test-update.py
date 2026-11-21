#!/usr/bin/env python3
"""The daily update check (#422) on Linux, in a private D-Bus session (test.sh's update-check): a release
served on 127.0.0.1 (SEBTYPE_UPDATE_URL, which only the Configurator's test build takes) and a fake freedesktop notification server stand in for GitHub
and the desktop, so nothing is downloaded or installed. Checked: a newer release is notified once and a
click opens the About page; the same release isn't notified again; the switch off checks nothing; the
tags from before 0.1.0 (v0.1.30-sebtype.N) are never newer; a notification closed opens nothing; the shipping
build doesn't take the test's release.

    test-update.py <sebtype-configurator-update-test> <sebtype-configurator>   # HOME, XDG_DATA_HOME: a sandbox
"""

import http.server
import json
import os
import subprocess
import sys
import threading

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

app, shipping = sys.argv[1:3]
state = os.path.join(os.environ["XDG_DATA_HOME"], "sebtype", "update.json")
release = {}
requests = []


class Release(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        body = json.dumps(release).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Release)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
NAME = "org.freedesktop.Notifications"


class Notifications(dbus.service.Object):
    def __init__(self):
        super().__init__(
            dbus.service.BusName(NAME, bus), "/org/freedesktop/Notifications"
        )
        self.shown, self.answer = [], "default"

    @dbus.service.method(NAME, in_signature="susssasa{sv}i", out_signature="u")
    def Notify(self, app_name, replaces, icon, summary, body, actions, hints, timeout):
        self.shown.append(
            dict(
                app=str(app_name),
                summary=str(summary),
                body=str(body),
                actions=[str(a) for a in actions],
                entry=str(hints.get("desktop-entry", "")),
                timeout=int(timeout),
            )
        )
        n = len(self.shown)
        if self.answer == "close":
            GLib.timeout_add(500, lambda: self.NotificationClosed(n, 2) and False)
        else:
            GLib.timeout_add(500, lambda: self.ActionInvoked(n, self.answer) and False)
        return n

    @dbus.service.method(NAME, in_signature="u")
    def CloseNotification(self, n):
        pass

    @dbus.service.signal(NAME, signature="us")
    def ActionInvoked(self, n, key):
        pass

    @dbus.service.signal(NAME, signature="uu")
    def NotificationClosed(self, n, reason):
        pass


notifications = Notifications()
loop = GLib.MainLoop()


def check_updates(exe=None, **env):
    """Runs --check-updates while the fake server answers: (exit code, stderr)."""
    out = {}

    def run():
        p = subprocess.run(
            [exe or app, "--check-updates"],
            env=dict(os.environ, SEBTYPE_UPDATE_URL=f"{url}/latest.json", **env),
            capture_output=True,
            text=True,
            timeout=60,
        )
        out.update(rc=p.returncode, err=p.stderr)
        GLib.idle_add(loop.quit)

    threading.Thread(target=run).start()
    loop.run()
    return out["rc"], out["err"]


def make(tag, version):
    assets = [
        f"SebType-setup-{version}.exe",
        f"SebType-setup-{version}-linux-x86_64.sh",
        f"SebType-{version}-arm64-v8a.apk",
    ]
    release.clear()
    release.update(
        tag_name=tag,
        assets=[
            dict(name=n, size=1, browser_download_url=f"{url}/{n}") for n in assets
        ],
    )


def saved():
    with open(state) as f:
        return json.load(f)


failed = 0


def result(name, ok, why):
    global failed
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: {why}", flush=True)


make("v99.0.0", "99.0.0")
rc, err = check_updates()
n = notifications.shown
ok = (
    rc == 0
    and len(n) == 1
    and "99.0.0" in n[0]["summary"]
    and "default" in n[0]["actions"]
    and n[0]["entry"] == "sebtype-configurator"
    and n[0]["timeout"] == 0
    and "opening the About page" in err
)
result(
    "update-notified-and-click-opens-about",
    ok,
    f"rc {rc}, notifications {n}, stderr {err.strip()!r}",
)
s = saved()
result(
    "update-state-saved",
    s.get("latest") == "99.0.0"
    and s.get("notified") == "99.0.0"
    and s.get("checked", 0) > 0,
    f"{s}",
)

rc, err = check_updates()
result(
    "update-notified-once",
    rc == 0 and len(n) == 1 and len(requests) == 2,
    f"rc {rc}, {len(n)} notification(s), {len(requests)} check(s)",
)

s["auto"] = False
with open(state, "w") as f:
    json.dump(s, f)
rc, err = check_updates()
result(
    "update-switch-off-checks-nothing",
    rc == 0 and len(requests) == 2 and len(n) == 1,
    f"rc {rc}, {len(requests)} check(s)",
)

s.update(auto=True, notified="", latest="")
with open(state, "w") as f:
    json.dump(s, f)
make("v0.1.30-sebtype.208", "0.1.30-sebtype.208")
rc, err = check_updates()
result(
    "update-old-sebtype-tag-not-newer",
    rc == 0 and len(n) == 1 and saved().get("latest") == "",
    f"rc {rc}, {saved()}",
)

notifications.answer = "close"
make("v99.0.1", "99.0.1")
rc, err = check_updates()
result(
    "update-closed-opens-nothing",
    rc == 0 and len(n) == 2 and "opening" not in err,
    f"rc {rc}, stderr {err.strip()!r}",
)

# The shipping build goes to GitHub whatever SEBTYPE_UPDATE_URL says: here through a proxy that isn't
# there, so it fails without the network.
before = len(requests)
rc, err = check_updates(
    shipping, HTTPS_PROXY="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9"
)
result(
    "update-shipping-build-ignores-test-release",
    rc == 1 and len(requests) == before and len(n) == 2,
    f"rc {rc}, {len(requests) - before} request(s) here, stderr {err.strip()!r}",
)

server.shutdown()
sys.exit(1 if failed else 0)
