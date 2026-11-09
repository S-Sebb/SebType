#!/usr/bin/env python3
"""Chinese (rime-ice) checks on the emulator, run by sebtype/test-emulator.sh under the emulator lock.

    test-chinese.py SERIAL APK BUMPED_APK RESULTS LOGDIR

APK is the release build; BUMPED_APK is the same APK with a different bundled rime-ice version marker,
installed over it as an update. Types through SebType's own keys (taps found in the accessibility tree,
`uiautomator dump --windows`) into FUTO's "try typing" popup and reads the candidate bar. One line per
check appended to RESULTS; later checks that depend on an earlier one SKIP when it failed.
"""

import datetime
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

serial, apk, bumped_apk, results_path, logdir = sys.argv[1:6]
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
FIELD = f"{PKG}/org.futo.inputmethod.latin.uix.TextEditPopupActivity"
RIME = f"/storage/emulated/0/Android/data/{PKG}/files/rime"
FAILURE_NOTICES = (
    "中文输入启动失败，点此重试",
    "Chinese input failed to start. Tap to retry",
)
log_path = os.path.join(logdir, "test-chinese.log")


def adb(*args, timeout=120, check=True):
    p = subprocess.run(
        ["adb", "-s", serial, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"$ adb {' '.join(args)}\n{p.stdout[-2000:]}{p.stderr[-2000:]}")
    if check and p.returncode != 0:
        raise RuntimeError(
            f"adb {' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}"
        )
    return p.stdout


def result(status, name, detail=""):
    line = f"{status} {name}" + (f": {detail}" if detail else "")
    print(line, flush=True)
    with open(results_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


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
    """(label, x, y, top, class) of every node in all windows, keyboard included."""
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out = []
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append((label, (x1 + x2) // 2, (y1 + y2) // 2, y1, n.get("class")))
    return out


def keys(ns):
    # The letter keys are the single lowercase letters; on SebType's QWERTY each appears once.
    return {
        label: (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-z]", label)
    }


def bar_row(ns):
    k = keys(ns)
    return (k["q"][2] - 130, k["q"][2]) if "q" in k else None


def candidates(ns):
    """Candidate texts in the suggestion bar (the row just above the letter keys), left to right."""
    row = bar_row(ns)
    if not row:
        return []
    bar = [
        (x, label)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1]
        and cls == "android.widget.TextView"
        and label
        and label not in FAILURE_NOTICES
    ]
    return [label for x, label in sorted(bar)]


def expanded_candidates():
    """Opens the bar's expanded view (the button at its right end); its candidates, in reading order."""
    ns = nodes()
    row = bar_row(ns)
    button = max(
        (x, y)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1] and cls == "android.widget.Button"
    )
    adb("shell", "input", "tap", str(button[0]), str(button[1]))
    time.sleep(1.5)
    grid = [
        (top, x, label)
        for label, x, y, top, cls in nodes()
        if y > row[1] and cls == "android.widget.TextView" and label
    ]
    return [label for top, x, label in sorted(grid)]


def type_keys(text):
    k = wait_for("the keyboard", lambda: keys(nodes()), 30)
    for ch in text:
        adb("shell", "input", "tap", str(k[ch][0]), str(k[ch][1]))
    time.sleep(1.5)


def open_field():
    """A fresh, empty text field with SebType up (any composition from before is dropped)."""
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "ime", "set", IME)
    adb("shell", "am", "start", "-W", "-n", FIELD)
    wait_for("the keyboard", lambda: keys(nodes()), 30)


def candidates_for(text, expand=False):
    """The bar's candidates for typing text; with expand, followed by those of the expanded view."""
    open_field()
    type_keys(text)
    got = wait_for(f"candidates for {text}", lambda: candidates(nodes()), 10)
    if expand:
        got += [c for c in expanded_candidates() if c not in got]
    return got


def tap_candidate(word):
    for label, x, y, top, cls in nodes():
        if label == word:
            adb("shell", "input", "tap", str(x), str(y))
            time.sleep(1.5)
            return
    raise Fail(f"{word} not in the candidate bar")


def logcat():
    return adb("logcat", "-d", "-s", "ChineseIME (rime):I")


def wait_deployed(timeout=240):
    """Waits for the app's deploy log line; returns (deploy ms, install ms or None). Clears logcat."""
    line = wait_for(
        "the deploy to finish",
        lambda: re.search(r"Deployed rime_ice in (\d+) ms, self-test (\w+)", logcat()),
        timeout,
        2,
    )
    text = logcat()
    install = re.search(r"Installed the bundled rime-ice in (\d+) ms", text)
    adb("logcat", "-c")
    if line.group(2) != "passed":
        raise Fail(f"self-test {line.group(2)} after deploy")
    return int(line.group(1)), int(install.group(1)) if install else None


def restart_app():
    adb("shell", "am", "force-stop", PKG)
    adb("logcat", "-c")
    open_field()


passed = {}


def check(name, fn, needs=()):
    missing = [n for n in needs if not passed.get(n)]
    if missing:
        result("SKIP", name, f"needs {', '.join(missing)}")
        return
    try:
        detail = fn()
        passed[name] = True
        result("PASS", name, detail or "")
    # Each check reports on its own; the next ones still run.
    except (
        Fail,
        RuntimeError,
        subprocess.SubprocessError,
        ET.ParseError,
        LookupError,
        ValueError,
        StopIteration,
    ) as e:
        result("FAIL", name, str(e))


def fresh_install():
    adb("uninstall", PKG, check=False)
    adb("install", apk, timeout=300)
    wait_for(
        "SebType to be listed as a keyboard",
        lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
        30,
    )
    adb("shell", "ime", "enable", IME)
    adb("logcat", "-c")
    open_field()
    deploy, install = wait_deployed()
    built = adb("shell", "ls", f"{RIME}/user/build")
    # rime-ice's prebuilt tables and the English prism (the slow part) must be used, not rebuilt.
    rebuilt = [f for f in ("rime_ice.table.bin", "melt_eng.prism.bin") if f in built]
    if rebuilt:
        raise Fail(f"rebuilt on the phone: {', '.join(rebuilt)} (deploy {deploy} ms)")
    return f"first run: install {install} ms + deploy and self-test {deploy} ms, prebuilt tables used"


def expect_first(text, word):
    def run():
        got = candidates_for(text)
        if not got or got[0] != word:
            raise Fail(f"{text} -> {got[:6]}")
        return f"{text} -> {got[:6]}"

    return run


def lh_in_top():
    # rime-ice ranks 厉害 about 8th on a fresh install, past the bar's first screen (#4); it must be
    # among the first ten candidates, and comes first once picked (learn-picked-word).
    got = candidates_for("lh", expand=True)
    if "厉害" not in got[:10]:
        raise Fail(f"lh -> {got[:12]} (厉害 not in the first ten)")
    return f"lh -> {got[:10]}, 厉害 at {got.index('厉害') + 1}"


def rq_date():
    got = candidates_for("rq")
    today = datetime.date.today().isoformat()
    if today not in got:
        raise Fail(f"rq -> {got[:6]}, no {today}")
    return f"rq -> {got[:6]}"


def learn_lower_candidate():
    got = candidates_for("lh", expand=True)
    if got.index("厉害") == 0:
        raise Fail(f"lh -> {got}: 厉害 is already first, nothing to learn")
    tap_candidate("厉害")
    after = candidates_for("lh")
    if after[0] != "厉害":
        raise Fail(
            f"picked 厉害 from place {got.index('厉害') + 1}; next lh -> {after[:6]}"
        )
    return f"picked 厉害 from place {got.index('厉害') + 1}; next lh -> {after[:6]}"


def learned_survives_restart():
    restart_app()
    wait_deployed()
    return expect_first("lh", "厉害")()


def update_over_itself():
    adb("logcat", "-c")
    adb("install", "-r", bumped_apk, timeout=300)
    open_field()
    deploy, install = wait_deployed()
    if install is None:
        raise Fail("the update didn't reinstall the bundled rime-ice")
    return f"reinstalled rime-ice in {install} ms, deploy and self-test {deploy} ms"


def failure_is_visible():
    # Break the installed rime-ice behind the app's back: its dictionary source and prebuilt table go.
    adb("shell", "am", "force-stop", PKG)
    adb(
        "shell",
        "rm",
        "-rf",
        f"{RIME}/shared/rime_ice.dict.yaml",
        f"{RIME}/shared/build/rime_ice.table.bin",
        f"{RIME}/user/build",
    )
    adb("logcat", "-c")
    open_field()
    wait_for("the deploy to finish", lambda: "Deployed rime_ice" in logcat(), 240, 2)
    notice = wait_for(
        "the failure notice",
        lambda: [n[0] for n in nodes() if n[0] in FAILURE_NOTICES],
        15,
    )
    return f"bar shows {notice[0]!r}"


def failure_recovers():
    adb("logcat", "-c")
    tap_candidate(next(n[0] for n in nodes() if n[0] in FAILURE_NOTICES))
    deploy, install = wait_deployed()
    got = candidates_for("ranh")
    if not got or got[0] != "然后":
        raise Fail(f"after the retry ranh -> {got[:6]}")
    return (
        f"tap reinstalled ({install} ms) and deployed ({deploy} ms); ranh -> {got[:3]}"
    )


check("first-install", fresh_install)
check("ranh", expect_first("ranh", "然后"), needs=["first-install"])
check("lh-in-bar", lh_in_top, needs=["first-install"])
check("rq-date", rq_date, needs=["first-install"])
check("hm-pinned", expect_first("hm", "后面"), needs=["first-install"])
check("learn-picked-word", learn_lower_candidate, needs=["lh-in-bar"])
check("learned-after-restart", learned_survives_restart, needs=["learn-picked-word"])
check("update-redeploys", update_over_itself, needs=["first-install"])
check("update-keeps-chinese", expect_first("ranh", "然后"), needs=["update-redeploys"])
check(
    "update-keeps-learned",
    expect_first("lh", "厉害"),
    needs=["update-redeploys", "learn-picked-word"],
)
check("failure-visible", failure_is_visible, needs=["first-install"])
check("failure-recovers", failure_recovers, needs=["failure-visible"])
check(
    "recovery-keeps-learned",
    expect_first("lh", "厉害"),
    needs=["failure-recovers", "learn-picked-word"],
)
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
