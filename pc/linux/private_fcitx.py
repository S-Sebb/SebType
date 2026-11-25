"""A private Fcitx5 with SebType's input method, for the tests that type into it (test-forget.py,
test-learned-sync.py): run inside a private D-Bus session, never the desktop's."""

import signal
import subprocess
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

bus = dbus.SessionBus(mainloop=DBusGMainLoop())
SYMS = {" ": 0x20, "\n": 0xFF0D, "\x1b": 0xFF1B, "\t": 0xFF09}


class Fcitx:
    def __init__(self, log_path):
        with open(log_path, "w") as log:
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
            taken = self.key("n" if lang == "zh" else "a")
            # Escape cancels a taken key's composition. After one the engine didn't take, which an app would
            # type, it isn't taken either and clears 中文's model context of it (#515): letters there for the
            # whole first start's deploy put 试试 before 事实 for shishi, for the rest of the process.
            self.key("\x1b")
            if taken:
                return True
            time.sleep(0.5)
        return False

    def stop(self):
        self.p.send_signal(
            signal.SIGTERM
        )  # Fcitx5 stops its add-ons: Rime and Mozc save and close
        self.p.wait(60)
