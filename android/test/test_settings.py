#!/usr/bin/env python3
"""Offline tests of settings.py's keyboard-restart recovery (#352), against a made-up adb:
python3 -I android/test/test_settings.py (android/test/emulator.sh runs it as settings-helpers).
settings.py drives a device as it loads, so these take its functions out of its source."""

import ast
import os
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = {
    "Fail", "Skip", "SebTypeFault", "SEBTYPE_LIFE", "LOGCAT_TIME", "logcat_time",
    "choose_sebtype", "restart_unstarted", "to_language", "check", "result",
}  # fmt: skip
IME = "dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME"
OTHER = "com.android.inputmethod.latin/.LatinIME"
with open(os.path.join(HERE, "settings.py"), encoding="utf-8") as f:
    TREE = ast.parse(f.read())
CODE = compile(
    ast.Module(
        [
            n
            for n in TREE.body
            if getattr(n, "name", None) in NAMES
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in NAMES)
        ],
        [],
    ),
    "settings.py",
    "exec",
)


class Device:
    """adb on a phone with SebType chosen: its log, keyboards, and how `ime set` behaves."""

    def __init__(self, log="", others=(OTHER,), away=None, back=(), restores=True):
        self.log, self.others, self.away = log, others, away
        self.back = list(back)  # an exception per `ime set` back to SebType, in turn
        self.restores, self.ime, self.calls = restores, IME, []

    def __call__(self, *a, check=True, timeout=120):
        self.calls.append(a)
        if a[0] == "logcat":
            return self.log
        if a[:3] == ("shell", "ime", "list"):
            return "\n".join((IME, *self.others))
        if a[:3] == ("shell", "ime", "set"):
            if a[3] != IME:
                self.ime = a[3]
                if self.away:
                    raise self.away
            elif self.back and self.back.pop(0):
                raise RuntimeError("adb shell ime set failed")
            elif self.restores:
                self.ime = IME
            return ""
        if a[:3] == ("shell", "settings", "get"):
            return self.ime + "\n"
        if a[:3] == ("shell", "am", "force-stop"):
            return ""
        raise AssertionError(f"unexpected adb {a}")


def settings(device):
    tmp = tempfile.TemporaryDirectory()
    ns = dict(
        re=re, os=os, subprocess=subprocess, ET=ET, IME=IME, PKG="dev.sebb.sebtype",
        adb=device, logdir=tmp.name, results_path=os.path.join(tmp.name, "results.txt"),
        recoveries=[], current_check="chk", CHECKS=[], NEEDED=set(), passed=set(),
        TIMING=set(), REPEAT=1, _tmp=tmp,
    )  # fmt: skip
    exec(CODE, ns)
    return ns


class LogcatTime(unittest.TestCase):
    def test_device_date_to_a_time_logcat_reads(self):
        ns = settings(Device())
        self.assertEqual(
            ns["logcat_time"]("2026-11-18 14:46:50.059123456\r\n"),
            "2026-11-18 14:46:50.059",
        )

    def test_anything_else_fails_loudly(self):
        ns = settings(Device())
        # A bare epoch: logcat -T reads it as a line count. A date without %N: no fraction. One
        # without the year: logcat takes this year's, so 12-31 23:59:55 is in the future on 1 January.
        for out in (
            "1795013228",
            "2026-11-18 14:46:50.N",
            "12-31 23:59:55.123456789",
            "",
        ):
            with self.assertRaises(ValueError, msg=out):
                ns["logcat_time"](out)


class RestartUnstarted(unittest.TestCase):
    def recover(self, device):
        ns = settings(device)
        ns["restart_unstarted"]("2026-11-18 14:46:50.059")
        return ns

    def test_android_never_started_it(self):
        device = Device(log="11-18 I ActivityManager: Force stopping dev.sebb.sebtype")
        ns = self.recover(device)
        self.assertEqual(
            [os.path.basename(p) for p in ns["recoveries"]], ["chk-recovery-1.logcat"]
        )
        with open(ns["recoveries"][0]) as f:
            self.assertEqual(f.read(), device.log)
        self.assertIn(("shell", "ime", "set", OTHER), device.calls)
        self.assertEqual(device.ime, IME)

    def test_sebtype_started_crashed_or_hung(self):
        for line in (
            "E AndroidRuntime: Process: dev.sebb.sebtype, PID: 123",
            "F DEBUG: pid: 1, tid: 1, name: x  >>> dev.sebb.sebtype <<<",
            "E ActivityManager: ANR in dev.sebb.sebtype",
            "I ActivityManager: Start proc 9:dev.sebb.sebtype/u0a228 for service {x}",
        ):
            device = Device(log=f"11-18 14:46:51.000 {line}")
            ns = settings(device)
            with self.assertRaisesRegex(ns["SebTypeFault"], re.escape(line)):
                ns["restart_unstarted"]("2026-11-18 14:46:50.059")
            self.assertEqual(ns["recoveries"], [])
            self.assertNotIn(("shell", "ime", "set", OTHER), device.calls)

    def test_the_field_apps_anr_isnt_sebtypes(self):
        self.recover(Device(log="E ActivityManager: ANR in dev.sebb.sebtype.perffield"))

    def test_no_other_keyboard(self):
        ns = settings(Device(others=()))
        with self.assertRaisesRegex(
            ns["Fail"], "no other keyboard.*chk-recovery-1.logcat"
        ):
            ns["restart_unstarted"]("2026-11-18 14:46:50.059")

    def test_switch_away_times_out(self):
        device = Device(away=subprocess.TimeoutExpired("adb", 120))
        ns = settings(device)
        with self.assertRaises(subprocess.TimeoutExpired):
            ns["restart_unstarted"]("2026-11-18 14:46:50.059")
        self.assertEqual(device.ime, IME)

    def test_switch_back_fails_once(self):
        device = Device(back=[True])
        self.recover(device)
        self.assertEqual(device.ime, IME)

    def test_switch_back_never_applies(self):
        ns = settings(Device(restores=False))
        with self.assertRaisesRegex(ns["Fail"], "isn't the keyboard again"):
            ns["restart_unstarted"]("2026-11-18 14:46:50.059")

    def test_failed_restore_keeps_the_first_error(self):
        device = Device(away=subprocess.TimeoutExpired("adb", 120), back=[True, True])
        ns = settings(device)
        with self.assertRaisesRegex(
            ns["Fail"],
            f"switching to {re.escape(OTHER)}: .*timed out.*; then SebType isn't the keyboard",
        ):
            ns["restart_unstarted"]("2026-11-18 14:46:50.059")
        self.assertEqual(device.calls.count(("shell", "ime", "set", IME)), 2)


class Check(unittest.TestCase):
    def lines(self, ns):
        with open(ns["results_path"]) as f:
            return f.read().splitlines()

    def test_a_recovery_is_a_warn_on_any_check(self):
        ns = settings(Device())

        def recovering(fail):
            def fn():
                ns["restart_unstarted"]("2026-11-18 14:46:50.059")
                if fail:
                    raise ns["Fail"]("badge never came")
                return "fine"

            return fn

        ns["check"]("plain", lambda: "fine")
        ns["check"]("passing", recovering(False))
        ns["check"]("failing", recovering(True))
        self.assertEqual(
            self.lines(ns),
            [
                "PASS plain: fine",
                "PASS passing: fine WARN: Android started SebType only after another keyboard and"
                " back, 1x (#352; passing-recovery-1.logcat)",
                "FAIL failing: badge never came WARN: Android started SebType only after another"
                " keyboard and back, 1x (#352; failing-recovery-2.logcat)",
            ],
        )

    def test_a_crash_isnt_retried_away_by_to_language(self):
        device = Device(
            log="11-18 14:46:51.000 E AndroidRuntime: Process: dev.sebb.sebtype, PID: 7"
        )
        ns = settings(device)
        ns["open_field"] = lambda: ns["restart_unstarted"]("2026-11-18 14:46:50.059")
        ns["check"]("settings-en-forget", lambda: ns["to_language"]("hello", "hello"))
        self.assertEqual(len(self.lines(ns)), 1)
        self.assertRegex(
            self.lines(ns)[0],
            r"^FAIL settings-en-forget: SebType .*Process: dev\.sebb\.sebtype",
        )
        self.assertNotIn(
            ("shell", "am", "force-stop", "dev.sebb.sebtype"), device.calls
        )


if __name__ == "__main__":
    unittest.main()
