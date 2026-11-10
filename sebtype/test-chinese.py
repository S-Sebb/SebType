#!/usr/bin/env python3
"""Chinese checks on the emulator, run by sebtype/test-emulator.sh under the emulator lock: password,
private, URL and email fields (#30), the 简/繁 menu switch (#36), then Japanese's あ ⇄ ア mode chip (#38).

    test-chinese.py SERIAL APK BUMPED_APK FIELD_APK RESULTS LOGDIR [MAIN_APK]

APK is the release build; BUMPED_APK is the same APK with a different bundled data version marker,
installed over it as an update; MAIN_APK (optional) is main's release build, which learns a word before
APK is installed over it; FIELD_APK is sebtype/perf/build-field.sh's text field app, which only
supplies the box that gets typed into (the app's own "try typing" popup isn't exported). Types by
tapping SebType's own keys (found with `uiautomator dump --windows`) and reads the candidate bar. One
line per check appended to RESULTS; later checks that depend on an earlier one SKIP when it failed.
"""

import datetime
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

serial, apk, bumped_apk, field_apk, results_path, logdir = sys.argv[1:7]
main_apk = sys.argv[7] if len(sys.argv) > 7 else ""
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
# Rime's data is private (#32): read through the emulator's root shell (su), as a release APK has no run-as.
RIME_USER = f"/data/user/0/{PKG}/files/rime/user"
RIME_SHARED = f"/data/user/0/{PKG}/no_backup/rime/shared"
# Where builds before #32 kept it; nothing may be left there.
EXTERNAL = f"/storage/emulated/0/Android/data/{PKG}/files"
FAILURE_NOTICES = (
    "中文输入启动失败，点此重试",
    "Chinese input failed to start. Tap to retry",
)
PREPARING = ("正在准备中文", "Preparing Chinese")
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
        log.write(f"$ adb {' '.join(args)}\n{p.stdout[-2000:]}{p.stderr[-2000:]}\n")
    if check and p.returncode != 0:
        raise RuntimeError(
            f"adb {' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}"
        )
    return p.stdout


def root(cmd):
    return adb("shell", f"su 0 {cmd}")


def external_files():
    return adb("shell", f"ls -A {EXTERNAL} 2>/dev/null || true").split()


# The field app just supplies an exported text box; it stays installed, like the keyboards.
adb("install", "-r", field_apk, timeout=300)


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


keyboard_frame = None  # the keyboard's bounds, from the last nodes()


def nodes():
    """(label, x, y, top, class) of every node in all windows, keyboard included."""
    global keyboard_frame
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out, frame = [], None
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append((label, (x1 + x2) // 2, (y1 + y2) // 2, y1, n.get("class")))
            if n.get("resource-id") == f"{PKG}:id/main_keyboard_frame":
                frame = keyboard_frame = (x1, y1, x2, y2)
    if frame and not keys(out):
        out += letter_keys(*frame)
    return out


def letter_keys(left, top, right, bottom):
    """SebType's letter keys aren't in the tree unless an accessibility service is on; their places
    on its QWERTY: three letter rows over a bottom row, ten keys across, rows 2 and 3 indented."""
    w, h = (right - left) / 10, (bottom - top) / 4
    rows = (("qwertyuiop", 0.5), ("asdfghjkl", 1), ("zxcvbnm", 2))
    return [
        (
            ch,
            int(left + (i + indent) * w),
            int(top + (r + 0.5) * h),
            int(top + r * h),
            "key",
        )
        for r, (letters, indent) in enumerate(rows)
        for i, ch in enumerate(letters)
    ]


def keys(ns):
    # The letter keys are the single lowercase letters; on SebType's QWERTY each appears once.
    return {
        label: (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-z]", label)
    }


def tap_globe():
    """The globe key beside the space bar: the bottom row's third column, over the last nodes().

    A fresh install sets up EN, 中, 日 in that order (#35), so one tap turns the English from the
    install into 中; the globe then cycles back to EN after 日.
    """
    left, top, right, bottom = keyboard_frame
    adb(
        "shell",
        "input",
        "tap",
        str(int(left + 3 * (right - left) / 10)),
        str(int(top + 3.5 * (bottom - top) / 4)),
    )


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
        and not label.startswith(PREPARING)
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


def open_field(kind=None):
    """A fresh, empty text field with SebType up (any composition from before is dropped); kind makes it
    a password, private, url or email field (#30)."""
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "ime", "set", IME)
    # A new popup each time (new task, clear task): one left open would get the intent without showing
    # the keyboard again.
    extra = ["--es", "kind", kind] if kind else []
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD, *extra)
    wait_for("the keyboard", lambda: keys(nodes()), 30)


def candidates_for(text, expand=False, kind=None):
    """The bar's candidates for typing text; with expand, followed by those of the expanded view."""
    open_field(kind)
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
    """The app's rime log lines; logcat's -s splits the filter on spaces, so it can't match the tag."""
    return adb("shell", "logcat -d | grep -F 'ChineseIME (rime)' || true")


def screenshot(name):
    adb("shell", "screencap -p /sdcard/sebtype-shot.png")
    adb("pull", "/sdcard/sebtype-shot.png", os.path.join(logdir, name))


SET_UP = r"Set up rime_ice in (\d+) ms \(deployed: (yes|no)\), self-test (\w+)"


def wait_set_up(timeout=240):
    """Waits for the app's setup log line; returns (setup ms, install ms or None, deployed, setup
    lines logged). Clears logcat."""
    line = wait_for(
        "Chinese to be set up", lambda: re.search(SET_UP, logcat()), timeout, 2
    )
    text = logcat()
    # "rime-ice" in builds from before #40
    install = re.search(
        r"Installed the bundled (?:rime-ice|Chinese data) in (\d+) ms", text
    )
    adb("logcat", "-c")
    if line.group(3) != "passed":
        raise Fail(f"self-test {line.group(3)} after setup")
    return (
        int(line.group(1)),
        int(install.group(1)) if install else None,
        line.group(2) == "yes",
        len(re.findall(SET_UP, text)),
    )


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
    global keyboard_frame
    adb("uninstall", PKG, check=False)
    adb("install", apk, timeout=300)
    wait_for(
        "SebType to be listed as a keyboard",
        lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
        30,
    )
    adb("shell", "ime", "enable", IME)
    adb("logcat", "-c")
    # What a new user does: the setup screen (which starts setting up Chinese in the background), then
    # the keyboard right away. The keyboard comes up once first, in English, so the test knows where
    # its keys are (the same in 中) and can type at 中 at once: setup takes only a few seconds now.
    open_field()
    q = keys(nodes())["q"]
    adb("shell", "input", "text", "hi")  # English works meanwhile
    adb(
        "shell",
        "am",
        "start",
        "-W",
        "-n",
        f"{PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity",
    )
    adb("shell", "am", "start", "-W", "-n", FIELD)  # back to the same field
    time.sleep(1)  # taps while the keyboard slides back in are dropped
    tap_globe()  # a fresh install starts in EN; the globe turns it into 中
    time.sleep(0.3)
    ready_first = bool(re.search(SET_UP, logcat()))
    # Keys while Chinese isn't ready type plain letters.
    adb("shell", "input", "tap", str(q[0]), str(q[1]))
    keyboard_frame = None
    ns = nodes()
    if not keyboard_frame:
        raise Fail("no keyboard on screen during setup")
    notice = [n[0] for n in ns if n[0].startswith(PREPARING)]
    if notice:
        adb("shell", "screencap -p /sdcard/sebtype-indicator.png")
        adb(
            "pull",
            "/sdcard/sebtype-indicator.png",
            os.path.join(logdir, "chinese-indicator.png"),
        )
    field = [n[0] for n in ns if n[4] == "android.widget.EditText"]
    setup, install, deployed, runs = wait_set_up()
    if ready_first:
        meanwhile = "Chinese was ready before 中 came up"
    elif field != ["hiq"]:
        raise Fail(f"typed hi in English and q during setup; the field shows {field}")
    else:
        # A dump takes a couple of seconds, so a quick setup can end before it reads the notice.
        seen = (
            f"中 showed {notice[0]!r} meanwhile"
            if notice
            else "setup ended before the bar was read"
        )
        meanwhile = f"{seen}, keys typed plain letters"
    if runs != 1 or not deployed:
        raise Fail(
            f"{runs} setups logged, deployed: {deployed}; expected one, deploying"
        )
    built = root(f"ls {RIME_USER}/build").split()
    # The bundle comes compiled: no table, prism or reverse db may be built on the phone.
    rebuilt = [f for f in built if f.endswith(".bin")]
    if rebuilt:
        raise Fail(f"rebuilt on the phone: {', '.join(rebuilt)} (setup {setup} ms)")
    return (
        f"first run from the setup screen: install {install} ms, set up in {setup} ms all told; "
        f"{meanwhile}; prebuilt tables used"
    )


def expect_first(text, word):
    def run():
        got = candidates_for(text)
        if not got or got[0] != word:
            raise Fail(f"{text} -> {got[:6]}")
        return f"{text} -> {got[:6]}"

    return run


def lh_in_top():
    # 白霜 ranks 厉害 4th on a fresh install (rime-ice: 8th, #4); it must be among the first ten
    # candidates, and comes first once picked (learn-picked-word).
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
    setup, _, deployed, _ = wait_set_up()
    if deployed:
        raise Fail(f"a restart deployed again ({setup} ms)")
    return expect_first("lh", "厉害")()


def password_plain():
    # #30: Rime never sees keys typed into a password field: they go in as letters, with no candidates.
    open_field("password")
    type_keys("lh")
    ns = nodes()
    got, field = candidates(ns), [n[0] for n in ns if n[4] == "android.widget.EditText"]
    if got or field not in (["lh"], ["••"]):
        raise Fail(
            f"typed lh into a password field: bar {got[:6]}, field shows {field}"
        )
    return f"typed lh into a password field: no candidates, field shows {field}"


def no_learning_in(kind, code):
    """#30: a lower candidate picked in a kind field isn't learned: it stays where it was in a normal one."""

    def run():
        before = candidates_for(code)
        word = before[2]
        candidates_for(code, kind=kind)
        tap_candidate(word)
        after = candidates_for(code)
        if word in after[:2]:
            raise Fail(
                f"picked {word} for {code} in a {kind} field; next {code} -> {after[:6]}"
            )
        return f"picked {word} (3rd) for {code} in a {kind} field; next {code} -> {after[:6]}"

    return run


def normal_still_learns(code):
    """The same pick in a normal field is learned: the control for no_learning_in."""

    def run():
        word = candidates_for(code)[2]
        tap_candidate(word)
        after = candidates_for(code)
        if after[0] != word:
            raise Fail(f"picked {word} for {code}; next {code} -> {after[:6]}")
        return f"picked {word} (3rd) for {code}; next {code} -> {after[:6]}"

    return run


def update_over_itself():
    adb("logcat", "-c")
    adb("install", "-r", bumped_apk, timeout=300)
    # The update itself starts setting up Chinese, before any keyboard shows.
    setup, install, _, _ = wait_set_up()
    if install is None:
        raise Fail("the update didn't reinstall the bundled data")
    # Android drops the keyboard's binding on an update and, on the emulator, may not rebind it on the
    # first selection; a second one brings it up.
    wait_for(
        "SebType to be listed again",
        lambda: IME in adb("shell", "ime", "list", "-s"),
        30,
    )
    try:
        open_field()
    except Fail:
        open_field()
    return f"the update alone reinstalled the data in {install} ms and set it up in {setup} ms"


def failure_is_visible():
    # Break the installed data behind the app's back: its compiled dictionary goes.
    adb("shell", "am", "force-stop", PKG)
    root(
        f"rm -rf {RIME_SHARED}/rime_ice.dict.yaml {RIME_SHARED}/build/rime_ice.table.bin "
        f"{RIME_USER}/build"
    )
    adb("logcat", "-c")
    open_field()
    wait_for("the setup to finish", lambda: re.search(SET_UP, logcat()), 240, 2)
    notice = wait_for(
        "the failure notice",
        lambda: [n[0] for n in nodes() if n[0] in FAILURE_NOTICES],
        15,
    )
    return f"bar shows {notice[0]!r}"


def failure_recovers():
    adb("logcat", "-c")
    tap_candidate(next(n[0] for n in nodes() if n[0] in FAILURE_NOTICES))
    setup, install, _, _ = wait_set_up()
    got = candidates_for("ranh")
    if not got or got[0] != "然后":
        raise Fail(f"after the retry ranh -> {got[:6]}")
    return f"tap reinstalled ({install} ms) and set up ({setup} ms); ranh -> {got[:3]}"


check("first-install", fresh_install)


def nothing_external():
    left = external_files()
    if left:
        raise Fail(f"external files: {left}")
    return "nothing under the app's external files"


check("fresh-nothing-external", nothing_external, needs=["first-install"])
check("ranh", expect_first("ranh", "然后"), needs=["first-install"])
check("lh-in-bar", lh_in_top, needs=["first-install"])
check("rq-date", rq_date, needs=["first-install"])
check("hm-pinned", expect_first("hm", "后面"), needs=["first-install"])
check("learn-picked-word", learn_lower_candidate, needs=["lh-in-bar"])
check("learned-after-restart", learned_survives_restart, needs=["learn-picked-word"])
check("password-plain", password_plain, needs=["first-install"])
check("private-no-learning", no_learning_in("private", "sj"), needs=["first-install"])
check("url-no-learning", no_learning_in("url", "sj"), needs=["first-install"])
check("email-no-learning", no_learning_in("email", "sj"), needs=["first-install"])
check("normal-still-learns", normal_still_learns("sj"), needs=["first-install"])
# Before the update: a restart after it has once switched the keyboard to English (not rime-ice's doing).
check("failure-visible", failure_is_visible, needs=["first-install"])
check("failure-recovers", failure_recovers, needs=["failure-visible"])
check(
    "recovery-keeps-learned",
    expect_first("lh", "厉害"),
    needs=["failure-recovers", "learn-picked-word"],
)
check("update-redeploys", update_over_itself, needs=["first-install"])
check("update-keeps-chinese", expect_first("ranh", "然后"), needs=["update-redeploys"])
check(
    "update-keeps-learned",
    expect_first("lh", "厉害"),
    needs=["update-redeploys", "learn-picked-word"],
)


# The 简/繁 switch at the top of the keyboard menu (#36): Open Action Bar, then All Actions. Their
# labels follow the system language (English, Chinese or Japanese).
OPEN_BAR = ("Open Action Bar", "打开操作栏", "アクションバーを開く")
ALL_ACTIONS = ("All Actions", "所有操作项", "アクションリスト")
BACK = ("Back", "返回", "戻る")


def tap_label(labels, timeout=10):
    n = wait_for(
        labels[0], lambda: next((n for n in nodes() if n[0] in labels), None), timeout
    )
    adb("shell", "input", "tap", str(n[1]), str(n[2]))
    time.sleep(1)


def open_menu():
    open_field()
    # The expanded bar is a saved setting (ActionBarExpanded), so after it has been opened once, a new
    # keyboard comes up expanded: its toggle reads "Close Action Bar" and its tiles are already showing.
    if not any(n[0] in ALL_ACTIONS for n in nodes()):
        tap_label(OPEN_BAR)
    tap_label(ALL_ACTIONS)


def close_menu():
    tap_label(BACK)


def menu_switch():
    """(checked, x, y) of the menu's 简/繁 switch, or None when the menu has none."""
    ns = nodes()
    labels = {n[0] for n in ns}
    if not {"简体", "繁體"} <= labels:
        return None
    sw = next(n for n in ns if n[0] == "繁體")
    dump = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    checked = re.search(r'checkable="true" checked="(true|false)"', dump)
    return (checked and checked.group(1) == "true", sw[1], sw[2])


def set_traditional(on, shot=None):
    open_menu()
    sw = wait_for("the 简/繁 switch", menu_switch, 10)
    if sw[0] != on:
        adb("shell", "input", "tap", str(sw[1]), str(sw[2]))
        wait_for(
            f"the switch to turn {'on' if on else 'off'}",
            lambda: (menu_switch() or (None,))[0] == on,
            10,
        )
    if shot:
        screenshot(shot)
    close_menu()


def traditional_on():
    set_traditional(True, "36-menu-switch.png")
    got = candidates_for("houlai")
    screenshot("36-traditional-candidates.png")
    if not got or got[0] != "後來":
        raise Fail(f"繁 on: houlai -> {got[:6]}")
    return f"繁 on: houlai -> {got[:6]}"


def traditional_after_restart():
    restart_app()
    wait_set_up()
    open_menu()
    sw = wait_for("the 简/繁 switch", menu_switch, 10)
    close_menu()
    got = candidates_for("houlai")
    if not sw[0] or not got or got[0] != "後來":
        raise Fail(
            f"after a restart the switch is {'on' if sw[0] else 'off'}, houlai -> {got[:6]}"
        )
    return f"after a restart the switch stays on, houlai -> {got[:6]}"


def traditional_off():
    set_traditional(False)
    got = candidates_for("houlai")
    if not got or got[0] != "后来":
        raise Fail(f"繁 off: houlai -> {got[:6]}")
    return f"繁 off: houlai -> {got[:6]}; learned 厉害 still first: {expect_first('lh', '厉害')()}"


check("zh-hant-on", traditional_on, needs=["first-install"])
check("zh-hant-after-restart", traditional_after_restart, needs=["zh-hant-on"])
check("zh-hant-off", traditional_off, needs=["zh-hant-on", "learn-picked-word"])


def chip(ns):
    """(label, x, y) of the Japanese mode chip in the suggestion bar, or None (English and 中 have none)."""
    row = bar_row(ns)
    return next(
        (
            (label, x, y)
            for label, x, y, top, cls in ns
            if row
            and row[0] < y < row[1]
            and label in ("あ", "ア")
            and cls == "android.widget.Button"
        ),
        None,
    )


def tap_chip(expect):
    adb("shell", "input", "tap", *map(str, chip(nodes())[1:]))
    wait_for(
        f"the chip to show {expect}", lambda: (chip(nodes()) or "")[:1] == (expect,), 10
    )


def field_text():
    return next((n[0] for n in nodes() if n[4] == "android.widget.EditText"), "")


def to_japanese():
    # Mozc's native code can crash a few times in a row when Japanese starts on the emulator (#35); a
    # field opened while the keyboard is down never gets it back, so the app is restarted and the field
    # reopened.
    restarts = 0
    for _ in range(6):
        try:
            open_field()
        except Fail:
            adb("shell", "am", "force-stop", PKG)
            restarts += 1
            continue
        if c := chip(nodes()):
            break
        tap_globe()
        time.sleep(2)
        if c := chip(nodes()):
            break
    else:
        raise Fail("no あ|ア chip after cycling the globe")
    if c[0] != "あ":
        raise Fail(f"日 opened with the chip on {c[0]}")
    return f"日 shows the chip on あ ({restarts} restarts after the keyboard didn't come up)"


def katakana_candidate():
    got = candidates_for("nihongo")
    screenshot("japanese-hiragana.png")
    if "ニホンゴ" not in got or got[0] != "日本語":
        raise Fail(f"nihongo in あ -> {got[:6]}")
    if (chip(nodes()) or "?")[0] != "あ":
        raise Fail("the chip isn't on あ beside the candidates")
    return f"nihongo in あ -> {got[:6]}; the chip stays beside them"


def katakana_mode():
    open_field()
    tap_chip("ア")
    type_keys("nihongo")
    text = field_text()
    screenshot("japanese-katakana.png")
    if text != "ニホンゴ":
        raise Fail(f"typed nihongo in ア; the field shows {text!r}")
    tap_chip("あ")
    type_keys("a")
    text = field_text()
    if not text.endswith("あ"):
        raise Fail(f"back in あ, typed a; the field shows {text!r}")
    return f"ア: nihongo -> ニホンゴ; back in あ: a -> {text!r}"


def new_field_resets():
    open_field()
    tap_chip("ア")
    open_field()
    c = wait_for("the chip", lambda: chip(nodes()), 10)
    if c[0] != "あ":
        raise Fail(f"a new field opened with the chip on {c[0]}")
    return "ア in one field, あ in the next"


check("ja-chip", to_japanese, needs=["first-install"])
check("ja-katakana-candidate", katakana_candidate, needs=["ja-chip"])
check("ja-katakana-mode", katakana_mode, needs=["ja-chip"])
check("ja-new-field-resets", new_field_resets, needs=["ja-chip"])


def no_switch_in_japanese():
    open_menu()
    sw = menu_switch()
    close_menu()
    if sw:
        raise Fail("the menu shows the 简/繁 switch in 日")
    return "日's menu has no 简/繁 switch"


check("ja-menu-has-no-zh-switch", no_switch_in_japanese, needs=["ja-chip"])


def main_learns():
    """main's build, fresh, learns 厉害 (rime-ice's dictionary, same schema id rime_ice)."""
    adb("uninstall", PKG, check=False)
    adb("install", main_apk, timeout=300)
    wait_for(
        "SebType to be listed",
        lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
        30,
    )
    adb("shell", "ime", "enable", IME)
    adb("logcat", "-c")
    open_field()
    tap_globe()  # a fresh install starts in EN
    wait_set_up()
    return learn_lower_candidate()


def update_from_main():
    adb("logcat", "-c")
    adb("install", "-r", apk, timeout=300)
    setup, install, _, _ = wait_set_up()
    # main and this build ship the same bundled data version, which RimeIceBundle leaves installed;
    # only a release that changes the data reinstalls it here (as BUMPED_APK does above).
    data = f"data reinstalled in {install} ms" if install else "installed data kept"
    wait_for(
        "SebType to be listed again",
        lambda: IME in adb("shell", "ime", "list", "-s"),
        30,
    )
    try:
        open_field()
    except Fail:
        open_field()
    return f"main -> this build: {data}, set up in {setup} ms"


def moved_from_external():
    """main kept Rime's data in external storage; this build moved it into private storage (#32)."""
    if "rime_ice.userdb" not in root(f"ls {RIME_USER}").split():
        raise Fail(f"no rime_ice.userdb in {RIME_USER}")
    nothing_external()
    return "learned words in private storage, nothing left in external files"


if main_apk:
    check("main-learns", main_learns)
    check("update-from-main", update_from_main, needs=["main-learns"])
    check("update-from-main-moved", moved_from_external, needs=["update-from-main"])
    check(
        "update-from-main-keeps-learned",
        expect_first("lh", "厉害"),
        needs=["update-from-main"],
    )
    check(
        "update-from-main-chinese",
        expect_first("ranh", "然后"),
        needs=["update-from-main"],
    )
else:
    result("SKIP", "update-from-main", "no MAIN_APK (main's release APK) given")
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
