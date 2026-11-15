#!/usr/bin/env python3
"""Types keys into the Remote Desktop client on this X display, as a keyboard would (#65).

    rdp-keys.py <port>

test-tcsbackend.sh runs it in the headless gamescope next to FreeRDP, and test.ps1's typing checks reach it
through an SSH tunnel. Each request is one line of keys separated by spaces, each key an X keysym name or a
chord such as Alt_L+grave; it answers "ok" once they are pressed and released, or "error <why>". The keys go
through XTEST to FreeRDP, which sends their scancodes to Windows like any keyboard, so they take the path a
person's keys take: the session's input queue, the app's message loop and TSF's keystroke manager.
"""

import socket
import sys
import time

import Xlib.error
from Xlib import XK, X, display
from Xlib.ext import xtest

HOLD = 0.08  # how long a person holds a key in a tap
GAP = 0.05  # between keys

x = display.Display()


def keycode(name):
    code = x.keysym_to_keycode(XK.string_to_keysym(name))
    if not code:
        raise ValueError(f"no key {name!r}")
    return code


def chord(names):
    codes = [keycode(n) for n in names]
    if names in (["Shift_L"], ["Shift_R"]):
        # A Shift tap switches only when its release comes within 500 ms of its press (core/). FreeRDP, short
        # of CPU on a busy PC, sent the release of an 80 ms tap up to 444 ms late, and in a release run past
        # 500 ms (#222): the press and release go in one flush, so they leave together.
        xtest.fake_input(x, X.KeyPress, codes[0])
        xtest.fake_input(x, X.KeyRelease, codes[0])
        x.sync()
        time.sleep(GAP)
        return
    for c in codes:
        xtest.fake_input(x, X.KeyPress, c)
        x.sync()
        time.sleep(GAP)
    time.sleep(HOLD)
    for c in reversed(codes):
        xtest.fake_input(x, X.KeyRelease, c)
        x.sync()
        time.sleep(GAP)


server = socket.create_server(("127.0.0.1", int(sys.argv[1])))
while True:
    conn, _ = server.accept()
    with conn, conn.makefile("rw", newline="\n") as f:
        for line in f:
            try:
                for key in line.split():
                    chord(key.split("+"))
                f.write("ok\n")
            except (ValueError, Xlib.error.XError) as e:
                f.write(f"error {e}\n")
            f.flush()
