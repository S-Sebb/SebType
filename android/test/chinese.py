#!/usr/bin/env python3
"""Chinese checks on the emulator, run by android/test/emulator.sh under the emulator lock: password,
private and URL fields (#30), the 简/繁 menu switch (#36), then Japanese's あ ⇄ ア mode chip (#38), its
cold starts (#97) and its idle unload (#56), and that English's model waits for the first letter (#56).

    chinese.py SERIAL APK BUMPED_APK FIELD_APK RESULTS LOGDIR [MAIN_APK]

APK is the release build; BUMPED_APK is the same APK with a different bundled data version marker,
installed over it as an update; MAIN_APK (optional) is main's release build, which learns a word before
APK is installed over it; FIELD_APK is android/perf/build-field.sh's text field app, which only
supplies the box that gets typed into (the app's own "try typing" popup isn't exported). Types by
tapping SebType's own keys (found with `uiautomator dump --windows`) and reads the candidate bar. One
line per check appended to RESULTS; later checks that depend on an earlier one SKIP when it failed.

SEBTYPE_PACKAGE=dev.sebb.sebtype.next runs them against the new keyboard (#191 stage 3, android/next):
the checks for what it doesn't have yet SKIP, and it gets its own: pinyin dropped on the globe, and
English's spacing around a period (#39).
"""

import ast
import datetime
import json
import os
import re
import shlex
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zlib

serial, apk, bumped_apk, field_apk, results_path, logdir = sys.argv[1:7]
main_apk = sys.argv[7] if len(sys.argv) > 7 else ""
PKG = os.environ.get("SEBTYPE_PACKAGE") or "dev.sebb.sebtype"
# The new keyboard (android/next): its own service, keyboard view and log tag.
NEXT = PKG == "dev.sebb.sebtype.next"
IME = f"{PKG}/.SebTypeIme" if NEXT else f"{PKG}/org.futo.inputmethod.latin.LatinIME"
FRAME_ID = f"{PKG}:id/keyboard" if NEXT else f"{PKG}:id/main_keyboard_frame"
# Checks the new keyboard can't pass yet, and why.
NEXT_SKIPS = {}
# The new keyboard's space bar, as its accessibility label reads in each system language.
SPACE_LABELS = ("Space", "空格", "スペース")
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
    # Through sh -c: the whole of cmd runs as root, not only its first command.
    return adb("shell", f"su 0 sh -c {shlex.quote(cmd)}")


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
# Seconds for the keyboard to come up. It restarts often here, and while the other emulator runs a
# suite (#103) a restart has taken over 30 s; how fast it comes up is perf.sh's to measure.
KEYBOARD_WAIT = 60
# Password and email fields get a number row on top (SettingsValues), 0.9 of a row high (LayoutEngine);
# the keyboard grows by that much, so the other rows stay where they are.
number_row = False


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
            if n.get("resource-id") == FRAME_ID:
                frame = keyboard_frame = (x1, y1, x2, y2)
    if frame and not keys(out):
        out += letter_keys(*frame)
    return out


def row_y(top, bottom, row):
    """The middle of a row of SebType's QWERTY: 0 to 2 are the letter rows, 3 the bottom row."""
    h = (bottom - top) / (4 + 0.9 * number_row)
    return int(top + (0.9 * number_row + row + 0.5) * h)


def letter_keys(left, top, right, bottom):
    """SebType's letter keys aren't in the tree unless an accessibility service is on; their places
    on its QWERTY: three letter rows over a bottom row, ten keys across, rows 2 and 3 indented."""
    w = (right - left) / 10
    layout = (("qwertyuiop", 0.5), ("asdfghjkl", 1), ("zxcvbnm", 2))
    return [
        (
            ch,
            int(left + (i + indent) * w),
            row_y(top, bottom, r),
            row_y(top, bottom, r - 0.5),
            "key",
        )
        for r, (letters, indent) in enumerate(layout)
        for i, ch in enumerate(letters)
    ]


def keys(ns):
    # The letter keys are the single lowercase letters; on SebType's QWERTY each appears once. The new
    # keyboard labels them as shown, in capitals while Shift is on.
    return {
        label.lower(): (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-zA-Z]" if NEXT else r"[a-z]", label)
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
        str(row_y(top, bottom, 3)),
    )


def bar_row(ns):
    # Right above the keyboard, whose top is the number row's where it has one.
    return (keyboard_frame[1] - 130, keyboard_frame[1]) if keys(ns) else None


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
    k = wait_for("the keyboard", lambda: keys(nodes()), KEYBOARD_WAIT)
    for ch in text:
        adb("shell", "input", "tap", str(k[ch][0]), str(k[ch][1]))
    time.sleep(1.5)
    settle()


def settle(seconds=30):
    """The new keyboard's keys show when its engine thread answers (#241), which on the emulator can
    take a second a key in English: waits until the field stops changing."""
    if not NEXT:
        return
    last, end = None, time.time() + seconds
    while time.time() < end:
        if (text := field_text()) == last:
            return
        last = text
        time.sleep(1)


def field_text():
    return next((n[0] for n in nodes() if n[4] == "android.widget.EditText"), "")


def type_fast(text, gap_ms=10):
    """Types text (letters, spaces and periods) with monkey taps gap_ms apart, faster than the engines answer
    (10-60 ms a key, #241); then waits for them to catch up."""
    k = wait_for("the keyboard", lambda: keys(nodes()), KEYBOARD_WAIT)
    left, top, right, bottom = keyboard_frame
    # The new keyboard labels its space bar; today's has its place in the bottom row.
    space = next(
        (
            (x, y)
            for label, x, y, top_, cls in nodes()
            if NEXT and label in SPACE_LABELS
        ),
        (int(left + 5.5 * (right - left) / 10), row_y(top, bottom, 3)),
    )
    # The bottom row's period, by its label
    period = next(
        ((x, y) for label, x, y, top_, cls in nodes() if label == "." and top_ >= top),
        None,
    )
    monkey_taps(
        [space if ch == " " else period if ch == "." else k[ch][:2] for ch in text],
        gap_ms,
    )
    time.sleep(3)


def monkey_taps(points, gap_ms):
    """Taps the points gap_ms apart in one monkey run: closer together than `input tap` can (a double tap)."""
    script = "type= raw events\ncount= 1\nspeed= 1.0\nstart data >>\n" + "".join(
        f"Tap({x},{y})\nUserWait({gap_ms})\n" for x, y in points
    )
    path = os.path.join(logdir, "fast-taps.txt")
    with open(path, "w") as f:
        f.write(script)
    adb("push", path, "/data/local/tmp/sebtype-fast-taps.txt")
    adb("shell", "monkey", "-f", "/data/local/tmp/sebtype-fast-taps.txt", "1")
    adb("shell", "rm", "/data/local/tmp/sebtype-fast-taps.txt")


def open_field(kind=None, clip=None, image=False):
    """A fresh, empty text field with SebType up (any composition from before is dropped); kind makes it
    a password, pin, private, url, email or image field (#30, #281); clip has the field app copy that
    text, image a small PNG."""
    global number_row
    number_row = kind in ("password", "visible-password", "email")
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    # A new popup each time (new task, clear task): one left open would get the intent without showing
    # the keyboard again.
    extra = (
        (["--es", "kind", kind] if kind else [])
        + (["--es", "clip", clip] if clip else [])
        + (["--ez", "clipimage", "true"] if image else [])
    )

    def show():
        adb("shell", "ime", "set", IME)
        adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD, *extra)

    def up():
        # A force-stop of the keyboard makes Android choose its default keyboard, and that can land
        # just after `ime set`: SebType is then never started again (#258). Choose it again.
        if (
            adb("shell", "settings", "get", "secure", "default_input_method").strip()
            != IME
        ):
            show()
            return None
        return keys(nodes())

    show()
    wait_for("the keyboard", up, KEYBOARD_WAIT)


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
    if NEXT:
        return adb("shell", "logcat -d -s SebType || true")
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


def wanted():
    """With SEBTYPE_CHECKS (comma-separated name prefixes, as android/test/emulator.sh takes it), the
    checks named there and those they need; None runs all."""
    if not PREFIXES:
        return None
    needs = {}
    with open(__file__, encoding="utf-8") as f:
        for node in ast.walk(ast.parse(f.read())):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "check":
                kw = {k.arg: k.value for k in node.keywords}
                needs[node.args[0].value] = (
                    [e.value for e in kw["needs"].elts] if "needs" in kw else []
                )
    todo = [n for n in needs if any(n.startswith(c) for c in PREFIXES)]
    run = set()
    while todo:
        n = todo.pop()
        if n not in run:
            run.add(n)
            todo += needs[n]
    return run


PREFIXES = [c for c in os.environ.get("SEBTYPE_CHECKS", "").split(",") if c]
# SEBTYPE_REPEAT=N runs each check SEBTYPE_CHECKS names (not those it needs) N times, a line per run:
# for a check that fails only now and then (#258).
REPEAT = int(os.environ.get("SEBTYPE_REPEAT") or 1)
WANTED = wanted()
if WANTED == set():  # none of the named checks is here
    sys.exit()


def check(name, fn, needs=()):
    if WANTED is not None and name not in WANTED:
        return
    if NEXT and name in NEXT_SKIPS:
        result("SKIP", name, f"new keyboard: {NEXT_SKIPS[name]}")
        return
    missing = [n for n in needs if not passed.get(n)]
    if missing:
        result("SKIP", name, f"needs {', '.join(missing)}")
        return
    runs = REPEAT if any(name.startswith(c) for c in PREFIXES) else 1
    for run in range(1, runs + 1):
        of = f" (run {run}/{runs})" if runs > 1 else ""
        try:
            detail = fn()
            passed[name] = True
            result("PASS", name, (detail or "") + of)
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
            result("FAIL", name, str(e) + of)
            # The system log since the last restart, for what the app was doing (a hang shows its threads here).
            suffix = f"-{run}" if runs > 1 else ""
            with open(os.path.join(logdir, f"{name}{suffix}.logcat"), "w") as f:
                f.write(adb("logcat", "-d", check=False))


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
    # What a new user does: the setup screen (which starts setting up Chinese in the background), then
    # the keyboard right away. The keyboard comes up once first, in English, so the test knows where
    # its keys are (the same in 中) and can type at 中 at once: setup takes only a few seconds now.
    open_field()
    q = keys(nodes())["q"]
    adb("shell", "input", "text", "hi")  # English works meanwhile
    # The new keyboard has no setup screen: it sets Chinese up as it first starts.
    if not NEXT:
        adb(
            "shell",
            "am",
            "start",
            "-W",
            "-n",
            f"{PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity",
        )
        adb("shell", "am", "start", "-W", "-n", FIELD)  # back to the same field
    # Under load (the other emulator's suite) the keyboard can take seconds to come back.
    wait_for("the keyboard back in the field", lambda: keys(nodes()), KEYBOARD_WAIT)
    time.sleep(1)  # taps while the keyboard slides back in are dropped
    tap_globe()  # a fresh install starts in EN; the globe turns it into 中
    time.sleep(0.3)
    ready_first = bool(re.search(SET_UP, logcat()))
    # Keys while Chinese isn't ready type plain letters.
    adb("shell", "input", "tap", str(q[0]), str(q[1]))

    def keyboard_nodes():
        global keyboard_frame
        keyboard_frame = None
        ns = nodes()
        return ns if keyboard_frame else None

    ns = wait_for("the keyboard on screen during setup", keyboard_nodes, 10)
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
        # rime-ice's spelling hints (［ran hou］) show only when its Lua filters aren't running.
        if not got or got[0] != word or any(c.startswith("［") for c in got):
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


def password_plain(kind):
    """#30: Rime never sees keys typed into a password field: no candidates, and (where the field shows
    its text) the letters themselves, not a composition."""

    def run():
        open_field(kind)
        type_keys("lh")
        ns = nodes()
        got = candidates(ns)
        field = [n[0] for n in ns if n[4] == "android.widget.EditText"]
        if got or (kind == "visible-password" and field != ["lh"]):
            raise Fail(f"typed lh into a {kind} field: bar {got[:6]}, field {field}")
        return f"typed lh into a {kind} field: no candidates, field {field}"

    return run


def password_after_restart():
    """#100: a keyboard that starts while a UI dump runs puts its keys in the tree, and these checks tap
    by that tree. In a password keyboard, whose number row moves the letters down, it must show where
    they are now, not where the keyboard before had them. Three restarts: the tree shows up in about
    half of them."""
    for _ in range(3):
        restart_app()
        wait_set_up()
        for _ in range(3):
            nodes()
        password_plain("visible-password")()
    return "typed lh into a visible-password field after each of 3 restarts"


def pin_plain():
    """#30: a PIN field's keypad types digits in 中, with no candidates: its left column's top three keys."""
    open_field("pin")
    left, top, right, bottom = keyboard_frame
    for row in range(3):
        y = top + (row + 0.5) * (bottom - top) / 4
        adb("shell", "input", "tap", str(int(left + (right - left) / 8)), str(int(y)))
    time.sleep(1.5)
    ns = nodes()
    got = candidates(ns)
    field = [n[0] for n in ns if n[4] == "android.widget.EditText"]
    if got or len(field) != 1 or len(field[0]) != 3:
        raise Fail(f"tapped 3 keypad keys in a PIN field: bar {got[:6]}, field {field}")
    return f"tapped 3 keypad keys in a PIN field: no candidates, field {field}"


def no_learning_in(kind, code):
    """#30: a lower candidate picked in a kind field isn't learned: it stays where it was in a normal one."""

    def run():
        before = candidates_for(code)
        word = before[2]
        got = candidates_for(code, kind=kind)
        if word not in got:
            raise Fail(f"{code} -> {before[:6]}, but in a {kind} field -> {got[:6]}")
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


def fast_typing_zh():
    # Each space commits ranh's first candidate (然后, the ranh check); a key lost or out of order
    # would commit something else.
    open_field()
    type_fast("ranh ranh ranh ranh ")
    if (text := field_text()) != "然后" * 4:
        raise Fail(f"typed 'ranh ' four times, 10 ms apart; the field shows {text!r}")
    return f"'ranh ' × 4, 10 ms apart -> {text!r}"


check("fast-typing-zh", fast_typing_zh, needs=["ranh"])
check("rq-date", rq_date, needs=["first-install"])
check("hm-pinned", expect_first("hm", "后面"), needs=["first-install"])
# Typo correction (#46): o for i, its neighbour on the phone grid, still gives 小时 first.
check("typo-corrected", expect_first("xoaoshi", "小时"), needs=["first-install"])
check("learn-picked-word", learn_lower_candidate, needs=["lh-in-bar"])
check("learned-after-restart", learned_survives_restart, needs=["learn-picked-word"])
# Restarts 中 and waits for its setup, so it needs 中 working.
check("password-after-restart", password_after_restart, needs=["ranh"])
check("password-plain", password_plain("password"), needs=["first-install"])
check("pin-plain", pin_plain, needs=["first-install"])
check(
    "visible-password-plain",
    password_plain("visible-password"),
    needs=["first-install"],
)
check("private-no-learning", no_learning_in("private", "wm"), needs=["first-install"])
check("url-no-learning", no_learning_in("url", "wm"), needs=["first-install"])
check("normal-still-learns", normal_still_learns("wm"), needs=["first-install"])
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


# The 简/繁 switch at the top of the keyboard menu (#36): Open Action Bar, then All Actions (the new
# keyboard: its menu shows the switch at once, and Close Action Bar closes it). Their labels follow the
# system language (English, Chinese or Japanese).
OPEN_BAR = ("Open Action Bar", "打开操作栏", "アクションバーを開く")
CLOSE_BAR = ("Close Action Bar", "关闭操作栏", "アクションバーを閉じる")
ALL_ACTIONS = ("All Actions", "所有操作项", "アクションリスト", "すべての操作")
BACK = ("Back", "返回", "戻る")


def tap_label(labels, timeout=10):
    n = wait_for(
        labels[0], lambda: next((n for n in nodes() if n[0] in labels), None), timeout
    )
    adb("shell", "input", "tap", str(n[1]), str(n[2]))
    time.sleep(1)


def open_menu():
    open_field()
    # The expanded bar is a saved setting (today's ActionBarExpanded, the new keyboard's too), so after it
    # has been opened once, a new keyboard comes up expanded: its toggle reads "Close Action Bar" and All
    # Actions is already showing.
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


def fast_typing_ja():
    # The romaji stays in the field as Mozc's composition: every key, in order, or other kana.
    open_field()
    type_fast("watashihanihongowohanasu")
    if (text := field_text()) != "わたしはにほんごをはなす":
        raise Fail(
            f"typed watashihanihongowohanasu 10 ms apart in 日; the field shows {text!r}"
        )
    return f"watashihanihongowohanasu, 10 ms apart -> {text!r}"


check("fast-typing-ja", fast_typing_ja, needs=["ja-chip"])


def no_switch_in_japanese():
    open_menu()
    sw = menu_switch()
    close_menu()
    if sw:
        raise Fail("the menu shows the 简/繁 switch in 日")
    return "日's menu has no 简/繁 switch"


check("ja-menu-has-no-zh-switch", no_switch_in_japanese, needs=["ja-chip"])


def sebtype_crashes():
    log = adb("logcat", "-b", "crash", "-d")
    # A native crash names the process by its last 15 characters.
    return len(
        re.findall(
            rf"Fatal signal .*\({re.escape(PKG[-15:])}\)|Process: {re.escape(PKG)},",
            log,
        )
    )


def stop_keyboard():
    other = next(
        i for i in adb("shell", "ime", "list", "-s").split() if not i.startswith(PKG)
    )
    adb("shell", "ime", "set", other)
    adb("shell", "am", "force-stop", PKG)


def cold_starts_in_japanese(n=10):
    """Each new keyboard process starts Mozc again in 日 without crashing. Re-sending Mozc's user
    dictionaries at every start crashed it in most starts on the emulator (#97)."""
    adb("logcat", "-b", "crash", "-c")
    for i in range(n):
        stop_keyboard()
        try:
            open_field()
            type_keys("ka")
        except Fail as e:
            raise Fail(f"start {i + 1}: {e}; {sebtype_crashes()} crashes so far") from e
        if (text := field_text()) != "か":
            raise Fail(f"start {i + 1}: typed ka, the field shows {text!r}")
    if crashes := sebtype_crashes():
        raise Fail(f"{crashes} crashes in {n} starts")
    return f"{n} starts in 日, no crash; ka -> か each time"


check("ja-cold-starts", cold_starts_in_japanese, needs=["ja-chip"])

WORDS = "content://user_dictionary/words"


def personal_word_after_restart():
    """A Japanese personal word added while the keyboard is stopped reaches Mozc at its next start (#97:
    the start re-sends the user dictionaries only when they changed)."""
    adb("logcat", "-b", "crash", "-c")
    stop_keyboard()
    # As root: Android's user dictionary takes words only from enabled keyboards, spell checkers and
    # root, and ignores the shell user without an error (#143).
    root(
        f"content insert --uri {WORDS} --bind word:s:SebType語 --bind 'shortcut:s:てすとご\t1'"
        " --bind locale:s:ja --bind frequency:i:250 --bind appid:i:0"
    )
    try:
        if "SebType語" not in root(f"content query --uri {WORDS} --projection word"):
            raise Fail("SebType語 didn't reach Android's user dictionary")
        # This start re-sends the user dictionaries to Mozc, the step that crashed in #97.
        got = candidates_for("tesutogo")
    except Fail as e:
        raise Fail(f"{e}; {sebtype_crashes()} crashes") from e
    finally:
        root(f"content delete --uri {WORDS} --where \"word='SebType語'\"")
    if "SebType語" not in got:
        raise Fail(f"tesutogo -> {got[:6]}, without the personal word SebType語")
    return f"tesutogo -> {got[:6]}"


check("ja-personal-word-after-restart", personal_word_after_restart, needs=["ja-chip"])


def mozc_log():
    return adb("shell", f"logcat -d -s {'SebType' if NEXT else 'JapaneseIME'} || true")


def ja_unloads_when_idle():
    """Mozc unloads 3 minutes after 日 was left, and the next 日 field loads it again (#56)."""
    to_japanese()
    type_keys("ka")
    adb("logcat", "-c")
    tap_globe()  # 日 -> EN
    time.sleep(2)
    if chip(nodes()):
        raise Fail("the globe didn't leave 日")
    wait_for("Mozc to unload", lambda: "Mozc unloaded" in mozc_log(), 240, interval=5)
    to_japanese()
    type_keys("ka")
    if (text := field_text()) != "か":
        raise Fail(f"after the unload, typed ka in 日; the field shows {text!r}")
    loaded = re.search(r"Mozc loaded again in (\d+) ms", mozc_log())
    if not loaded:
        raise Fail("日 worked, but no log of Mozc loading again")
    return f"unloaded in EN; back in 日 Mozc loaded again in {loaded.group(1)} ms, ka -> か"


check("ja-unloads-when-idle", ja_unloads_when_idle, needs=["ja-chip"])


def model_mapped():
    pid = adb("shell", "pidof", PKG).strip()
    # The new keyboard's model is english.gguf, copied out of the APK into no_backup/english/.
    model = "english/english.gguf" if NEXT else "transformer-models/"
    return pid and model in root(f"cat /proc/{pid}/maps")


def en_model_waits_for_letter():
    """English's prediction model loads only once a letter is typed (#56, Decisions #2)."""
    open_field()
    if chip(nodes()):
        tap_globe()  # 日 -> EN
    stop_keyboard()
    open_field()
    time.sleep(10)
    if model_mapped():
        raise Fail("the model loaded in an empty field before any letter")
    type_keys("th")
    # No chip is EN or 中: in 中, th has Chinese candidates and no English model to load.
    got = candidates(nodes())
    if not all(c.isascii() for c in got):
        raise Fail(f"th -> {got[:6]}: the keyboard is in 中, not EN")
    wait_for("the model to load after a letter", model_mapped, 60, interval=2)
    return "empty field: no model; after typing th: loaded"


check("en-model-waits-for-letter", en_model_waits_for_letter, needs=["ja-chip"])


def fast_typing_en():
    """English keys typed faster than the engine answers (#241) land in order, with each sentence's
    capital: a key lost, out of order or cased by a Shift the field hadn't caught up with shows here."""
    open_field()
    type_fast("the cat sat. on the mat ")
    want = "The cat sat. On the mat "
    if (text := field_text()) != want:
        raise Fail(
            f"typed {want.lower()!r} 10 ms apart in EN; the field shows {text!r}"
        )
    # 100 ms apart, a word's commit is reported while the next word composes: not a cursor move (#257)
    open_field()
    type_fast("the quick brown fox jumps over the lazy dog ", gap_ms=100)
    slow = "The quick brown fox jumps over the lazy dog "
    if (text100 := field_text()) != slow:
        raise Fail(
            f"typed {slow.lower()!r} 100 ms apart in EN; the field shows {text100!r}"
        )
    return f"{want.lower()!r}, 10 ms apart -> {text!r}; 100 ms apart -> {text100!r}"


check("fast-typing-en", fast_typing_en, needs=["en-model-waits-for-letter"])


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


# --- The new keyboard's own checks (SEBTYPE_PACKAGE=dev.sebb.sebtype.next) ---


def key_spots():
    """The new keyboard's keys by label, letters in lower case (its keys are all in the tree)."""
    ns = nodes()
    if not keyboard_frame:
        return {}
    left, top, right, bottom = keyboard_frame
    return {
        (label.lower() if re.fullmatch("[a-zA-Z]", label) else label): (x, y)
        for label, x, y, t, cls in ns
        if label and left <= x <= right and top <= y <= bottom
    }


def type_text(text):
    """Taps text's keys: letters, Space and the bottom row's period. The keys keep their places."""
    k = wait_for(
        "the keyboard", lambda: "q" in (spots := key_spots()) and spots, KEYBOARD_WAIT
    )
    for ch in text:
        adb("shell", "input", "tap", *map(str, k[{" ": "Space"}.get(ch, ch)]))
    time.sleep(1.5)
    settle()


def to_english():
    """Cycles the globe until x types a plain x: no chip, no Chinese notice and no Chinese candidates
    (English may suggest words for it)."""
    for _ in range(4):
        open_field()
        type_keys("x")
        ns = nodes()
        notice = any(n[0].startswith(PREPARING) for n in ns)
        if (
            not chip(ns)
            and all(c.isascii() for c in candidates(ns))
            and not notice
            and field_text().lower() == "x"
        ):
            return
        tap_globe()
        time.sleep(2)
    raise Fail("no English after cycling the globe")


def to_chinese():
    """Cycles the globe until ni offers Chinese candidates (waiting while Chinese sets itself up)."""
    for _ in range(6):
        open_field()
        type_keys("ni")
        ns = nodes()
        if candidates(ns) and not chip(ns):
            return
        if any(n[0].startswith(PREPARING) for n in ns):
            time.sleep(5)
            continue
        tap_globe()
        time.sleep(2)
    raise Fail("no 中 after cycling the globe")


def globe_drops_pinyin():
    """The globe in the middle of a pinyin drops it: nothing reaches the field, and no candidates or
    pinyin are left above the keys (core/ doesn't commit on a switch, Decisions #2)."""
    to_chinese()
    open_field()
    type_keys("nihao")
    before = candidates(nodes())
    if not before:
        raise Fail("typed nihao in 中; no candidates")
    tap_globe()
    time.sleep(2)
    ns = nodes()
    left = [n[0] for n in ns if n[0] in ("nihao", "ni hao")]
    text = field_text()
    if text or candidates(ns) or left:
        raise Fail(
            f"after the globe: field {text!r}, bar {candidates(ns)[:4]}, pinyin {left}"
        )
    return f"nihao -> {before[:3]}; after the globe the field is empty and the bar and pinyin are gone"


def typed_as(text, want):
    """#39's spacing: English types text as it is, with Shift only at the start of a sentence."""

    def run():
        to_english()
        open_field()
        type_text(text)
        got = field_text()
        if got != want:
            raise Fail(f"typed {text!r}; the field shows {got!r}, not {want!r}")
        return f"typed {text!r} -> {got!r}"

    return run


# --- Stage 4 (#257): the action bar's panels, the quick clip, keyboard modes and swipes ---

EMOJI_ACTION = ("Emojis", "表情符号", "絵文字")
CLIPBOARD_ACTION = ("Clipboard Manager", "剪贴板管理器", "クリップボード")
MODES_ACTION = ("Keyboard Modes", "键盘模式", "キーボードモード")
KEEP_CLIPBOARD = (
    "Keep clipboard history",
    "保留剪贴板历史",
    "クリップボード履歴を残す",
)
QUICK_CLIP = ("Paste copied text", "粘贴复制的文字", "コピーしたテキストを貼り付け")
RESIZE = ("Resize Keyboard", "调整键盘大小", "キーボードのサイズ変更")
TALLER = ("Taller", "调高", "高く")
SHORTER = ("Shorter", "调低", "低く")
MOVE_KEYBOARD = "Move keyboard"
RESIZE_CORNER = "Drag to resize"


def action(labels):
    """Opens the action bar if it is closed, then taps one of its actions."""
    if not any(n[0] in CLOSE_BAR for n in nodes()):
        tap_label(OPEN_BAR)
    tap_label(labels)


def node(label):
    return next((n for n in nodes() if n[0] == label), None)


def emoji_picks():
    """The emoji panel types an emoji by its CLDR name, and keeps it among the recent ones."""
    to_english()
    open_field()
    action(EMOJI_ACTION)
    tap_label(("grinning face",))
    if field_text() != "😀":
        raise Fail(f"grinning face typed {field_text()!r}")
    open_field()
    action(EMOJI_ACTION)
    ns = nodes()
    recent = next((n for n in ns if n[0] == "Recently used"), None)
    first = next((n for n in ns if n[0] == "grinning face"), None)
    if not recent or not first or first[2] > recent[2] + 200:
        raise Fail("grinning face isn't first under Recently used")
    # A long press shows its skin tones; one is typed and kept for next time.
    # Its group's tab scrolls to it.
    tab = next(
        n
        for n in nodes()
        if n[0] == "People & Body" and n[4] == "android.widget.Button"
    )
    adb("shell", "input", "tap", str(tab[1]), str(tab[2]))
    time.sleep(1)
    hand = wait_for("waving hand", lambda: node("waving hand"), 10)
    adb(
        "shell",
        "input",
        "swipe",
        str(hand[1]),
        str(hand[2]),
        str(hand[1]),
        str(hand[2]),
        "800",
    )
    time.sleep(1)
    tap_label(("👋🏽",))
    if field_text() != "👋🏽":
        raise Fail(f"the medium skin tone typed {field_text()!r}")
    return "grinning face -> 😀, first among the recent ones; waving hand's medium tone -> 👋🏽"


def clipboard_paste():
    """Clipboard history on, a copy is kept, and a tap on it in the clipboard panel pastes it."""
    to_english()
    open_field()
    action(CLIPBOARD_ACTION)
    if node("Clipboard history is off"):
        tap_label(KEEP_CLIPBOARD)
    text = f"sebclip-paste-{time.time_ns()}"
    open_field(clip=text)
    time.sleep(4)
    open_field()
    action(CLIPBOARD_ACTION)
    tap_label((text,))
    got = field_text()
    if got != text:
        raise Fail(f"the clip pasted {got!r}")
    return f"kept and pasted {text}"


def quick_clip():
    """Text just copied is offered in the bar; a tap pastes it, and it is gone."""
    to_english()
    text = f"sebclip-quick-{time.time_ns()}"
    open_field(clip=text)
    wait_for("the quick clip", lambda: any(n[0] in QUICK_CLIP for n in nodes()), 10)
    tap_label(QUICK_CLIP)
    got = field_text()
    if got != text:
        raise Fail(f"the quick clip pasted {got!r}")
    if any(n[0] in QUICK_CLIP for n in nodes()):
        raise Fail("the quick clip is still offered after it was pasted")
    return f"offered and pasted {text}"


# --- #281: emoji and clipboard search, ASCII faces, images, today's saved history ---

SEARCH = ("Search", "搜索", "検索")
CLIPBOARD_SEARCH = ("Search clipboard", "搜索剪贴板", "クリップボードを検索")
CLOSE_SEARCH = ("Close search", "关闭搜索", "検索を閉じる")
FACES = ("ASCII", "颜文字", "顔文字")
IMAGE_CLIP = ("Image", "图片", "画像")
QUICK_IMAGE = ("Paste copied image", "粘贴复制的图片", "コピーした画像を貼り付け")


def keep_clipboard():
    open_field()
    action(CLIPBOARD_ACTION)
    if node("Clipboard history is off"):
        tap_label(KEEP_CLIPBOARD)


def emoji_search():
    """The emoji panel's search: the keys type into it, a result is typed into the field."""
    to_english()
    open_field()
    action(EMOJI_ACTION)
    tap_label(SEARCH)
    type_text("grinning")
    tap_label(("grinning face",))
    tap_label(CLOSE_SEARCH)
    if field_text() != "😀":
        raise Fail(f"grinning face from the search typed {field_text()!r}")
    return "searched grinning -> 😀"


def emoji_ascii():
    """The ASCII group types its face with a space after it, as today's."""
    to_english()
    open_field()
    action(EMOJI_ACTION)
    tap_label(FACES)
    tap_label(("smiley face",))
    if field_text() != ":) ":
        raise Fail(f"smiley face typed {field_text()!r}")
    return "smiley face -> ':) '"


def clipboard_search():
    """The clipboard's search shows only the clips with what was typed; a tap pastes one."""
    to_english()
    keep_clipboard()
    n = time.time_ns()
    found, other = f"sebclip-found-{n}", f"sebclip-other-{n}"
    for text in (found, other):
        open_field(clip=text)
        time.sleep(4)
    open_field()
    action(CLIPBOARD_ACTION)
    tap_label(CLIPBOARD_SEARCH)
    type_text("found")
    wait_for(found, lambda: node(found), 10)
    if node(other):
        raise Fail(f"searching found still shows {other}")
    tap_label((found,))
    if field_text() != found:
        raise Fail(f"the found clip pasted {field_text()!r}")
    return f"found and pasted {found}, {other} left out"


def clipboard_image_paste():
    """A copied image is offered in the bar and kept in the history; both paste it into a field that
    takes images."""
    to_english()
    keep_clipboard()
    open_field(image=True)
    time.sleep(4)
    open_field(kind="image")
    tap_label(QUICK_IMAGE)
    got = wait_for(
        "the pasted image",
        lambda: field_text().startswith("image ") and field_text(),
        10,
    )
    if not got.startswith("image image/png "):
        raise Fail(f"the quick clip pasted {got!r}")
    open_field(kind="image")
    action(CLIPBOARD_ACTION)
    tap_label(IMAGE_CLIP)
    got2 = wait_for(
        "the pasted image",
        lambda: field_text().startswith("image ") and field_text(),
        10,
    )
    if got2 != got:
        raise Fail(f"the history's image pasted {got2!r}, the quick clip {got!r}")
    return f"quick clip and history both pasted: {got}"


def png(width, height):
    """A plain-coloured PNG"""

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data))
        )

    rows = b"".join(b"\0" + b"\xc2\x50\x6a" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def clipboard_today_image():
    """A history today's keyboard saved, with an image among its texts, loads whole and newest first."""
    to_english()
    keep_clipboard()
    now = int(time.time() * 1000)
    old, new = f"sebclip-today-old-{now}", f"sebclip-today-new-{now}"
    # Today's ClipboardEntry fields, oldest first; the image is in clipboardfiles/
    saved = [
        {
            "timestamp": now - 3000,
            "pinned": False,
            "text": old,
            "uri": None,
            "mimeTypes": ["text/plain"],
        },
        {
            "timestamp": now - 2000,
            "pinned": False,
            "text": None,
            "uri": None,
            "mimeTypes": ["image/png"],
            "backingFile": "sebtype281.png",
            "sizeMb": 0.01,
        },
        {
            "timestamp": now - 1000,
            "pinned": False,
            "text": new,
            "uri": None,
            "mimeTypes": ["text/plain"],
        },
    ]
    for name, data in (
        ("clipboard.json", json.dumps(saved).encode()),
        ("sebtype281.png", png(64, 48)),
    ):
        path = os.path.join(logdir, name)
        with open(path, "wb") as f:
            f.write(data)
        adb("push", path, f"/data/local/tmp/{name}")
    files = f"/data/data/{PKG}/files"
    adb("shell", "am", "force-stop", PKG)
    root(
        f"mkdir -p {files}/clipboardfiles && mv /data/local/tmp/clipboard.json {files}/ && "
        f"mv /data/local/tmp/sebtype281.png {files}/clipboardfiles/ && "
        f"chown -R $(stat -c %u:%g {files}) {files}/clipboard.json {files}/clipboardfiles && "
        f"restorecon -R {files}"
    )
    open_field()
    action(CLIPBOARD_ACTION)

    def loaded():
        ns = nodes()
        return ns if any(n[0] == new for n in ns) else None

    def listed(ns):
        return sorted(
            n[0]
            for n in ns
            if "sebclip" in n[0] or n[0] in IMAGE_CLIP or n[0] == "null"
        )

    # Newest first: the new text, then the image, then (scrolled to, below the image) the old text
    ns = wait_for(new, loaded, 10)
    shown = {n[0]: n for n in ns}
    image = next((shown[i] for i in IMAGE_CLIP if i in shown), None)
    if "null" in shown or not image or image[2] < shown[new][2]:
        raise Fail(f"today's history shows {listed(ns)}, top to bottom")
    if old not in shown:
        adb(
            "shell",
            "input",
            "swipe",
            *map(str, (image[1], image[2], image[1], shown[new][2])),
            "600",
        )
        time.sleep(1.5)
        ns = nodes()
        shown = {n[0]: n for n in ns}
    image = next((shown[i] for i in IMAGE_CLIP if i in shown), None)
    if old not in shown or image and image[2] > shown[old][2]:
        raise Fail(f"today's history shows {listed(ns)} after a scroll")
    return "both texts and the image, newest first"


def quick_clip_secret():
    """Text just copied isn't offered in a password or private field."""
    to_english()
    for kind in ("password", "private"):
        open_field(clip=f"sebclip-secret-{time.time_ns()}")
        time.sleep(3)
        open_field(kind=kind)
        time.sleep(2)
        if any(n[0] in QUICK_CLIP for n in nodes()):
            raise Fail(f"the quick clip is offered in a {kind} field")
    return "not offered in password or private fields"


def frame_now():
    nodes()
    return keyboard_frame


def set_mode(label):
    open_field()
    action(MODES_ACTION)
    tap_label((label,))
    open_field()
    return frame_now()


def screen_width():
    m = re.search(r"(\d+)x(\d+)", adb("shell", "wm", "size"))
    return int(m.group(1))


def types_letters():
    open_field()
    type_text("ok")
    if field_text().lower() != "ok":
        raise Fail(f"typing ok gave {field_text()!r}")


def modes_one_handed():
    """One-handed: the keys take 80% of the width, at one side, and still type."""
    to_english()
    try:
        l, t, r, b = set_mode("One-handed")
        w = screen_width()
        if not (0.7 * w < r - l < 0.9 * w):
            raise Fail(f"the keys are {r - l} px wide of {w}")
        types_letters()
        return f"keys {r - l} of {w} px, typing works"
    finally:
        set_mode("Standard")


def caps_lock():
    """A double tap on Shift locks capitals, also while the field's own capital has Shift on (#257): today's
    does, and the locked key is drawn berry. A new field ends it, as today's does."""
    open_field()
    shift = wait_for(
        "Shift",
        lambda: next(
            (
                (x, y)
                for label, x, y, top, cls in nodes()
                if label in ("Shift", "Shift on")
            ),
            None,
        ),
        KEYBOARD_WAIT,
    )
    monkey_taps([shift, shift], 100)
    time.sleep(1)
    if "Caps lock" not in {label for label, *_ in nodes()}:
        raise Fail("a double tap on Shift (auto-capital on) didn't lock it")
    type_fast("ab", gap_ms=300)
    if (text := field_text()) != "AB":
        raise Fail(f"typed ab with caps lock; the field shows {text!r}")
    open_field()
    time.sleep(1)
    if "Caps lock" in {label for label, *_ in nodes()}:
        raise Fail("caps lock stayed on in a new field")
    return f"double tap -> Caps lock, ab -> {text!r}; a new field ends it"


def modes_split():
    """Split: the keys in two halves, t and y far apart (g and v sit on both halves, as in today's app)."""
    to_english()
    try:
        set_mode("Split")
        k = key_spots()
        gap = k["y"][0] - k["t"][0]
        unit = k["w"][0] - k["q"][0]
        if gap < 2 * unit:
            raise Fail(f"t and y are {gap} px apart, a key is {unit}")
        types_letters()
        return f"t to y {gap} px, a key {unit} px"
    finally:
        set_mode("Standard")


def modes_floating():
    """Floating: a narrower keyboard that leaves the app its whole height, and still types."""
    to_english()
    try:
        l, t, r, b = set_mode("Floating")
        w = screen_width()
        if not (r - l < 0.9 * w):
            raise Fail(f"the floating keyboard is {r - l} px wide of {w}")
        types_letters()
        return f"{r - l} of {w} px wide, typing works"
    finally:
        set_mode("Standard")


def modes_height():
    """Taller and shorter: the keys' height follows, and comes back."""
    to_english()
    open_field()
    l, t, r, b = frame_now()
    before = b - t
    open_field()
    action(MODES_ACTION)
    tap_label(RESIZE)
    tap_label(TALLER)
    tap_label(TALLER)
    open_field()
    l, t, r, b = frame_now()
    after = b - t
    open_field()
    action(MODES_ACTION)
    tap_label(RESIZE)
    tap_label(SHORTER)
    tap_label(SHORTER)
    open_field()
    l, t, r, b = frame_now()
    if not after > before * 1.05:
        raise Fail(f"two taps on Taller: {before} -> {after} px")
    if abs((b - t) - before) > 4:
        raise Fail(f"two taps on Shorter didn't bring {before} px back: {b - t}")
    return f"{before} -> {after} -> {b - t} px"


def tap_key(label):
    adb("shell", "input", "tap", *map(str, key_spots()[label]))
    time.sleep(1.5)
    settle()


def swipe_key(label, dx):
    k = key_spots()
    x, y = k[label]
    adb("shell", "input", "swipe", str(x), str(y), str(x + dx), str(y), "600")
    time.sleep(1.5)


def swipe_space_cursor():
    """Space swiped left moves the cursor back: a letter typed then lands inside the text."""
    to_english()
    open_field()
    type_text("good day ")
    unit = key_spots()["w"][0] - key_spots()["q"][0]
    swipe_key("Space", -2 * unit)
    type_text("x")
    got = field_text()
    if got.endswith("x") or "x" not in got:
        raise Fail(f"after the swipe, x went to {got!r}")
    return f"-> {got!r}"


def swipe_delete_words():
    """Delete swiped left a key and a half deletes the last two words."""
    to_english()
    open_field()
    type_text("one two three")
    unit = key_spots()["w"][0] - key_spots()["q"][0]
    swipe_key("Delete", -int(1.6 * unit))
    got = field_text()
    if (
        "three" in got.lower()
        or "two" in got.lower()
        or not got.lower().startswith("one")
    ):
        raise Fail(f"after the swipe the field shows {got!r}")
    return f"-> {got!r}"


def swipe_delete_cjk():
    """Delete swiped left a key in Chinese, then Japanese, deletes the last word, not the whole sentence:
    they have no spaces between words (#283)."""
    to_english()
    got = []
    for text, left in (
        ("我们今天去公园", "我们今天去"),
        ("今日は良い天気です", "今日は良い天気"),
    ):
        open_field(clip=text)
        wait_for("the quick clip", lambda: any(n[0] in QUICK_CLIP for n in nodes()), 10)
        tap_label(QUICK_CLIP)
        unit = key_spots()["w"][0] - key_spots()["q"][0]
        swipe_key("Delete", -int(0.6 * unit))
        got.append(field_text())
        if got[-1] != left:
            raise Fail(f"a word's swipe on {text!r} left {got[-1]!r}, not {left!r}")
    return " and ".join(f"-> {g!r}" for g in got)


def floating_after_resize():
    """A floating keyboard moved to the top stays on the screen when the window gets shorter (a split
    screen, a fold, #283), and still types."""
    to_english()
    size = re.search(r"Physical size: (\d+)x(\d+)", adb("shell", "wm", "size"))
    w, h = int(size.group(1)), int(size.group(2))
    try:
        set_mode("Floating")
        x, y = next(n[1:3] for n in nodes() if n[0] == MOVE_KEYBOARD)
        adb("shell", "input", "swipe", str(x), str(y), str(x), "0", "800")
        time.sleep(1)
        short = h * 2 // 3
        adb("shell", "wm", "size", f"{w}x{short}")
        time.sleep(3)
        open_field()
        # The handle is the keyboard's top: off the screen, it isn't in the tree.
        handle = next((n for n in nodes() if n[0] == MOVE_KEYBOARD), None)
        l, t, r, b = keyboard_frame
        if not handle or handle[3] < 0 or b > short:
            raise Fail(
                f"in a {short} px screen the handle is at {handle and handle[3]}, the keys end at {b} px"
            )
        types_letters()
        return f"handle at {handle[3]} px, keys end at {b} of {short} px, typing works"
    finally:
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        set_mode("Standard")


def resize_floating(*swipes):
    """Floating mode's Resize Keyboard: each swipe (from, by) starts at "corner" (the frame's corner, which
    resizes) or "keys" (a point on the keys, which moves the keyboard) and goes (dx, dy) px, stopping at the
    screen's edge; then Apply."""
    w, h = screen_size()
    open_field()
    action(MODES_ACTION)
    tap_label(RESIZE)
    wait_for("the resize corner", lambda: node(RESIZE_CORNER), 10)
    # TalkBack reaches the frame alone: the keys under it are out of the accessibility tree (#283).
    shown = important_labels()
    if RESIZE_CORNER not in shown or shown & set(SPACE_LABELS):
        raise Fail(
            f"with the resize frame up, TalkBack's tree has {sorted(shown & set(SPACE_LABELS + (RESIZE_CORNER,)))}"
        )
    for start, (dx, dy) in swipes:
        corner = wait_for("the resize corner", lambda: node(RESIZE_CORNER), 10)
        l, t, r, b = keyboard_frame
        x, y = (
            corner[1:3] if start == "corner" else (l + (r - l) // 6, t + (b - t) // 5)
        )
        to = (min(max(x + dx, 0), w - 1), min(max(y + dy, 0), h - 1))
        adb("shell", "input", "swipe", str(x), str(y), *map(str, to), "1500")
        time.sleep(1)
    tap_label(("Apply", "应用", "適用"))
    return frame_now()


def important_labels():
    """The labels in the accessibility tree as TalkBack has it: a compressed dump leaves out the views
    hidden from it."""
    adb(
        "shell",
        "uiautomator",
        "dump",
        "--compressed",
        "--windows",
        "/sdcard/sebtype-ui.xml",
    )
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    return {
        n.get("text") or n.get("content-desc") or ""
        for n in ET.fromstring(xml[xml.index("<") :]).iter("node")
    }


def screen_density():
    return int(re.findall(r"density: (\d+)", adb("shell", "wm", "density"))[-1]) / 160


def screen_size():
    m = re.search(r"(\d+)x(\d+)", adb("shell", "wm", "size").splitlines()[-1])
    return int(m.group(1)), int(m.group(2))


def rotate(quarter):
    adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    adb("shell", "settings", "put", "system", "user_rotation", str(quarter))
    time.sleep(3)


def floating_resize():
    """Floating: the resize frame's corner dragged left and up makes the keyboard narrower and shorter, and
    the size stays after the keyboard restarts and after a turn to landscape and back (#283)."""
    to_english()
    auto = adb("shell", "settings", "get", "system", "accelerometer_rotation").strip()
    try:
        set_mode("Floating")
        tap_reset()  # from its size and place before any change
        open_field()
        l, t, r, b = frame_now()
        l2, t2, r2, b2 = resize_floating(("corner", (-200, -80)))
        if not (r2 - l2 < r - l - 150 and b2 - t2 < b - t - 40):
            raise Fail(
                f"the corner dragged by (-200, -80): keys {r - l}x{b - t} -> {r2 - l2}x{b2 - t2} px"
            )
        restart_app()
        after_restart = frame_now()
        rotate(1)
        open_field()
        land = frame_now()
        rotate(0)
        open_field()
        back = frame_now()
        for name, (l3, t3, r3, b3) in (
            ("the restart", after_restart),
            ("landscape and back", back),
        ):
            if abs((r3 - l3) - (r2 - l2)) > 4 or abs((b3 - t3) - (b2 - t2)) > 4:
                raise Fail(
                    f"after {name} the keys are {r3 - l3}x{b3 - t3} px, not {r2 - l2}x{b2 - t2}"
                )
        types_letters()
        return (
            f"keys {r - l}x{b - t} -> {r2 - l2}x{b2 - t2} px, kept after a restart and landscape "
            f"(there {land[2] - land[0]}x{land[3] - land[1]}), typing works"
        )
    finally:
        rotate(0)
        adb(
            "shell",
            "settings",
            "put",
            "system",
            "accelerometer_rotation",
            auto if auto in ("0", "1") else "0",
        )
        tap_reset()
        set_mode("Standard")


def tap_reset():
    open_field()
    action(MODES_ACTION)
    tap_label(RESIZE)
    tap_label(("Reset", "重置", "初期化"))
    tap_label(("Apply", "应用", "適用"))


def floating_short_window():
    """Floating, moved to the top and resized tall: a window half as tall shows its keys shorter, all of them
    on the screen (the handle too) and typing; the full window brings the saved height back (#283)."""
    to_english()
    w, h = screen_size()
    try:
        set_mode("Floating")
        tap_reset()
        l, t, r, b = resize_floating(("keys", (0, -h)), ("corner", (0, h)))
        tall = b - t
        short = h // 2
        adb("shell", "wm", "size", f"{w}x{short}")
        time.sleep(3)
        open_field()
        l2, t2, r2, b2 = frame_now()
        handle = node(MOVE_KEYBOARD)
        # The bottom row too: a node's bounds are cut to what shows, so a row cut off has none.
        space = next((n for n in nodes() if n[0] in SPACE_LABELS), None)
        if (
            not handle
            or handle[3] < 0
            or not space
            or space[2] > short
            or b2 - t2 >= tall
        ):
            raise Fail(
                f"keys {tall} px tall; in a {short} px window to {b2}, the handle at "
                f"{handle and handle[3]}, space at {space and space[2]}"
            )
        screenshot("floating-short-window.png")
        types_letters()
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        open_field()
        l3, t3, r3, b3 = frame_now()
        if abs((b3 - t3) - tall) > 4:
            raise Fail(
                f"back in the full window the keys are {b3 - t3} px tall, not the saved {tall}"
            )
        return f"keys {tall} px; {b2 - t2} px within a {short} px window, typing works; {b3 - t3} px again after"
    finally:
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        tap_reset()
        set_mode("Standard")


def floating_narrowest():
    """Floating resized as narrow as it goes: today's 144 dp, with Reset and Apply inside it and Apply still
    ending the resize (#283)."""
    to_english()
    w, h = screen_size()
    narrowest = round(144 * screen_density())
    try:
        set_mode("Floating")
        tap_reset()
        open_field()
        action(MODES_ACTION)
        tap_label(RESIZE)
        corner = wait_for("the resize corner", lambda: node(RESIZE_CORNER), 10)
        adb(
            "shell",
            "input",
            "swipe",
            str(corner[1]),
            str(corner[2]),
            "0",
            str(corner[2]),
            "1500",
        )
        time.sleep(1)
        corner = node(RESIZE_CORNER)
        buttons = [node(label) for label in ("Reset", "Apply")]
        left = corner[1] - narrowest
        if any(b is None or not left < b[1] < corner[1] for b in buttons):
            raise Fail(
                f"in a frame from x {left} to {corner[1]}, Reset and Apply are at {buttons}"
            )
        screenshot("floating-narrowest.png")
        tap_label(("Apply",))
        if node(RESIZE_CORNER):
            raise Fail("Apply didn't end the resize")
        l, t, r, b = frame_now()
        if abs((r - l) - narrowest) > 0.1 * narrowest:
            raise Fail(f"the narrowest keys are {r - l} px, not about {narrowest}")
        types_letters()
        return f"keys {r - l} px wide (144 dp is {narrowest}), Reset and Apply inside, typing works"
    finally:
        tap_reset()
        set_mode("Standard")


def floating_resize_edge():
    """Floating, moved to the left edge, its corner dragged to the screen's bottom right: it grows to nearly
    the screen's width and taller, pushed up rather than off the bottom; then a narrower window narrows it to
    fit, and it still types (#283)."""
    to_english()
    w, h = screen_size()
    try:
        set_mode("Floating")
        tap_reset()  # from its size and place before any change
        open_field()
        l, t, r, b = frame_now()
        l2, t2, r2, b2 = resize_floating(("keys", (-w, 0)), ("corner", (w, h)))
        if l2 < 0 or r2 > w or b2 > h or not (r2 - l2 > r - l and b2 - t2 > b - t):
            raise Fail(
                f"keys at ({l}, {t}, {r}, {b}) -> ({l2}, {t2}, {r2}, {b2}) on a {w}x{h} screen"
            )
        narrow = w * 2 // 3
        adb("shell", "wm", "size", f"{narrow}x{h}")
        time.sleep(3)
        open_field()
        l3, t3, r3, b3 = frame_now()
        if l3 < 0 or r3 > narrow or b3 > h:
            raise Fail(
                f"in a {narrow} px wide screen the keys are at ({l3}, {t3}, {r3}, {b3})"
            )
        types_letters()
        return (
            f"keys {r - l}x{b - t} -> {r2 - l2}x{b2 - t2} px within {w}x{h}; {r3 - l3} px wide in a "
            f"{narrow} px screen, typing works"
        )
    finally:
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        tap_reset()
        set_mode("Standard")


def picked_suggestion_period():
    """#39: after a tapped suggestion, a "." still joins the word: "this", This tapped, "." -> "This. "."""
    to_english()
    open_field()
    type_text("this")
    wait_for("This in the bar", lambda: "This" in candidates(nodes()), 15)
    ns = nodes()
    row = bar_row(ns)
    x, y = next(
        (x, y)
        for label, x, y, top, cls in ns
        if label == "This" and row[0] < y < row[1]
    )
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(1.5)
    type_text(".")
    text = field_text()
    if text != "This. ":
        raise Fail(f"this, This tapped, then . -> {text!r}, not 'This. '")
    return f"-> {text!r}"


def personal_word_en():
    """English suggests a word of the personal dictionary (Android's user dictionary), as 日本語 does."""
    root(
        f"content insert --uri {WORDS} --bind word:s:zorblax --bind locale:s:en_US"
        " --bind frequency:i:250 --bind appid:i:0"
    )
    try:
        to_english()
        got = candidates_for(
            "zorbl"
        )  # the field shows the keyboard again: it reads the words
    finally:
        root(f"content delete --uri {WORDS} --where \"word='zorblax'\"")
    if "zorblax" not in [
        c.lower() for c in got
    ]:  # a sentence's first word has its capital
        raise Fail(f"zorbl -> {got[:6]}, without the personal word zorblax")
    return f"zorbl -> {got[:6]}"


def backspace_reverts():
    """#280: Delete right after a space corrected a word puts back what was typed, as today's app; the next
    word gets its space back."""
    to_english()
    open_field()
    type_text("i saw teh ")
    if (got := field_text()) != "I saw the ":
        raise Fail(f"typed 'i saw teh ' -> {got!r}, not corrected")
    tap_key("Delete")
    if (reverted := field_text()) != "I saw teh":
        raise Fail(f"Delete after 'I saw the ' -> {reverted!r}, not 'I saw teh'")
    type_text("cat")
    if (got := field_text()) != "I saw teh cat":
        raise Fail(f"then cat -> {got!r}")
    return f"the -> {reverted!r} -> {got!r}"


def reopen_word():
    """#280: Delete back into a word, or the cursor moved into one, opens it again with its suggestions,
    and a tap replaces the whole word, as today's app."""
    to_english()
    open_field()
    type_text("i like cats ")
    tap_key("Delete")
    got = wait_for("suggestions for cats", lambda: candidates(nodes()), 10)
    pick = next((c for c in got if c.lower() != "cats"), None)
    if not pick:
        raise Fail(f"Delete into cats -> bar {got}")
    tap_candidate(pick)
    settle()
    if (text := field_text()) != f"I like {pick} ":
        raise Fail(f"cats reopened, {pick} tapped -> {text!r}")
    for _ in range(3):  # into the word: "I like ca|t "-style
        adb("shell", "input", "keyevent", "KEYCODE_DPAD_LEFT")
    time.sleep(1.5)
    inside = wait_for(f"suggestions for {pick}", lambda: candidates(nodes()), 10)
    other = next((c for c in inside if c.lower() != pick.lower()), None)
    if not other:
        raise Fail(f"cursor into {pick} -> bar {inside}")
    tap_candidate(other)
    settle()
    if (moved := field_text()) != f"I like {other} ":
        raise Fail(f"cursor into {pick}, {other} tapped -> {moved!r}")
    return f"cats -> {got[:3]} -> {text!r}; inside -> {inside[:3]} -> {moved!r}"


def emoji_suggestion():
    """English's word that names an emoji offers it in the bar; a tap puts it in place of the word."""
    to_english()
    open_field()
    type_text("pizza")
    got = wait_for(
        "🍕 in the bar", lambda: "🍕" in candidates(nodes()) and candidates(nodes()), 15
    )
    tap_candidate("🍕")
    settle()
    if (text := field_text()) != "🍕":
        raise Fail(f"pizza, 🍕 tapped -> {text!r}")
    return f"pizza -> {got[:3]}, tapped -> {text!r}"


SETTINGS_ACTION = ("Settings", "设置", "設定")


def settings_action():
    """All Actions' Settings opens the app's settings (Decisions #2, 2026-11-12)."""
    to_english()
    open_field()
    action(ALL_ACTIONS)
    tap_label(SETTINGS_ACTION)

    def resumed():
        dump = adb("shell", "dumpsys activity activities")
        return any(
            "settings.SettingsActivity" in line
            for line in dump.splitlines()
            if "ResumedActivity" in line
        )

    wait_for("the settings to open", resumed, 10)
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    return "All Actions, Settings -> SettingsActivity"


# --- A hardware (Bluetooth, USB) keyboard's keys, sent as key events (#284) ---


def hw_typing(to_language, text):
    """In today's app a hardware keyboard's letters reach the field as they are, without the engines:
    FUTO's hardware keyboard support is off (ProductionFlags.IS_HARDWARE_KEYBOARD_SUPPORTED) and its Alt
    shortcuts do nothing (KeyboardSwitcher.onToggleKeyboard). The new keyboard does the same."""

    def run():
        to_language()
        open_field()
        adb(
            "shell",
            "input",
            "keyboard",
            "keyevent",
            *(f"KEYCODE_{ch.upper()}" for ch in text),
        )
        time.sleep(1.5)
        settle()
        got, bar = field_text(), candidates(nodes())
        if got != text:
            raise Fail(f"hardware keys {text} -> field {got!r}, bar {bar[:5]}")
        return f"hardware keys {text} -> field {got!r}, bar {bar[:5]}"

    return run


def en_failure_visible():
    """English's learned words can't be opened (their folder is a file): the failure is in the system
    log, as today's app logs its dictionaries' (core/ writes it to stderr, which Android drops); English
    still types, and once the folder is back it opens without the error."""
    english = f"/data/user/0/{PKG}/files/english"
    error = "can't open the English learned words"
    try:
        to_english()
        stop_keyboard()
        root(f"rm -rf {english} && touch {english}")
        adb("logcat", "-c")
        open_field()
        type_keys("th")
        line = wait_for(
            "the error in the system log",
            lambda: next((l for l in logcat().splitlines() if error in l), None),
            30,
        )
        got = candidates(nodes())
        if field_text().lower() != "th":
            raise Fail(f"with the error, th typed {field_text()!r}")
    finally:
        stop_keyboard()
        root(f"rm -f {english}")
    adb("logcat", "-c")
    open_field()
    type_keys("th")
    time.sleep(3)
    if error in logcat() or not root(f"ls -d {english}").strip():
        raise Fail("the folder is still missing after the restart")
    return f"logged {line.split('sebtype: ', 1)[-1]!r}; typing went on ({got[:3]}); fine after the restart"


check("hw-typing-zh", hw_typing(to_chinese, "nihao"), needs=["first-install"])
check("hw-typing-ja", hw_typing(to_japanese, "hashi"), needs=["first-install"])
if NEXT:
    check("en-failure-visible", en_failure_visible, needs=["first-install"])

if NEXT:
    NEXT_SKIPS["en-futo-default-migrates"] = (
        "FUTO's stored settings have nothing to migrate to here"
    )
    check("zh-globe-drops-pinyin", globe_drops_pinyin, needs=["ranh"])
    # #39's four period checks (LiveSpacingTests in app/): the two the new keyboard can run, as typing.
    check(
        "en-period-space-stays",
        typed_as(
            "open main .py see notebook .ipynb ", "Open main .py see notebook .ipynb "
        ),
        needs=["first-install"],
    )
    check(
        "en-sentence-capital",
        typed_as("hello. how", "Hello. How"),
        needs=["first-install"],
    )
    check(
        "en-picked-suggestion-period", picked_suggestion_period, needs=["first-install"]
    )
    check("emoji-picks", emoji_picks, needs=["first-install"])
    check("caps-lock", caps_lock, needs=["en-model-waits-for-letter"])
    check(
        "en-double-space-period",
        typed_as("yes  then", "Yes. Then"),
        needs=["first-install"],
    )
    check("en-personal-word", personal_word_en, needs=["first-install"])
    check("en-backspace-reverts", backspace_reverts, needs=["first-install"])
    check("en-reopen-word", reopen_word, needs=["first-install"])
    check("en-emoji-suggestion", emoji_suggestion, needs=["first-install"])
    check("settings-action", settings_action, needs=["first-install"])
    check("clipboard-paste", clipboard_paste, needs=["first-install"])
    check("quick-clip", quick_clip, needs=["first-install"])
    check("quick-clip-secret", quick_clip_secret, needs=["first-install"])
    check("emoji-search", emoji_search, needs=["first-install"])
    check("emoji-ascii", emoji_ascii, needs=["first-install"])
    check("clipboard-search", clipboard_search, needs=["first-install"])
    check("clipboard-image-paste", clipboard_image_paste, needs=["first-install"])
    check("clipboard-today-image", clipboard_today_image, needs=["first-install"])
    check("modes-one-handed", modes_one_handed, needs=["first-install"])
    check("modes-split", modes_split, needs=["first-install"])
    check("modes-floating", modes_floating, needs=["first-install"])
    check("modes-height", modes_height, needs=["first-install"])
    check("swipe-space-cursor", swipe_space_cursor, needs=["first-install"])
    check("swipe-delete-words", swipe_delete_words, needs=["first-install"])
    check("swipe-delete-cjk", swipe_delete_cjk, needs=["first-install"])
    check("modes-floating-resized", floating_after_resize, needs=["first-install"])
    check("modes-floating-resize", floating_resize, needs=["first-install"])
    check("modes-floating-resize-edge", floating_resize_edge, needs=["first-install"])
    check("modes-floating-short-window", floating_short_window, needs=["first-install"])
    check("modes-floating-narrowest", floating_narrowest, needs=["first-install"])
    check("en-futo-default-migrates", lambda: None)

if (
    main_apk and not NEXT
):  # the new keyboard's update from main is update-from-futo-app's
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
elif not NEXT and (WANTED is None or "update-from-main" in WANTED):
    result("SKIP", "update-from-main", "no MAIN_APK (main's release APK) given")
# --- An update from today's app (FUTO's, MAIN_APK) to the new keyboard built as dev.sebb.sebtype (#254) ---
# UPDATE_APK is android/build.sh next-update's APK. Today's app learns a made-up English word, picks
# lower candidates in 中文 and 日本語 and changes options in its settings (autocorrect, fuzzy pinyin, learning);
# after the update the new keyboard offers both picks first, English's learned words wait in the English
# engine's folder (core_test checks that engine takes them in), and the options are kept.
update_apk = os.environ.get("UPDATE_APK", "")
OLD_PKG = "dev.sebb.sebtype"
EN_WORD = "zorbleq"  # made up, so only learning can put it in the history
JA_CODE = "hashi"


def as_app(pkg, new):
    """Points the helpers at an installed app: today's (FUTO's keyboard) or the new one, in package pkg."""
    global PKG, NEXT, IME, FRAME_ID, RIME_USER, RIME_SHARED
    PKG, NEXT = pkg, new
    # The new keyboard's classes keep their package when it is built as dev.sebb.sebtype, and Android
    # names that service dev.sebb.sebtype/.next.SebTypeIme: the id `ime list` prints and `ime enable` takes.
    IME = (
        (f"{PKG}/.SebTypeIme" if PKG.endswith(".next") else f"{PKG}/.next.SebTypeIme")
        if NEXT
        else f"{PKG}/org.futo.inputmethod.latin.LatinIME"
    )
    FRAME_ID = f"{PKG}:id/keyboard" if NEXT else f"{PKG}:id/main_keyboard_frame"
    RIME_USER = f"/data/user/0/{PKG}/files/rime/user"
    RIME_SHARED = f"/data/user/0/{PKG}/no_backup/rime/shared"


def tap_space():
    left, top, right, bottom = keyboard_frame
    adb("shell", "input", "tap", str((left + right) // 2), str(row_y(top, bottom, 3)))
    time.sleep(1)


def learn_japanese():
    """Picks hashi's third candidate; it comes first the next time."""
    to_japanese()
    got = candidates_for(JA_CODE)
    if len(got) < 3:
        raise Fail(f"{JA_CODE} -> {got}")
    tap_candidate(got[2])
    to_japanese()
    after = candidates_for(JA_CODE)
    if after[0] != got[2]:
        raise Fail(f"picked {got[2]} for {JA_CODE}; next {JA_CODE} -> {after[:5]}")
    return got[2]


def row(label, ns):
    """A settings row's node, or None: a toggle's row reads "Title. " and its subtitle, others the title."""
    return next(
        (
            n
            for n in ns
            if n[0] == label
            or n[0].startswith((label + ".", label + ",", label + "\n"))
        ),
        None,
    )


def tap_row(label, timeout=10):
    n = wait_for(label, lambda: row(label, nodes()), timeout)
    adb("shell", "input", "tap", str(n[1]), str(n[2]))
    time.sleep(1)


def set_old_options():
    """Autocorrect off, "z = zh" on and learning off in today's settings, as a user would; returns what it
    stored, for the log."""
    settings = f"{OLD_PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity"
    for path in (
        ("Languages", "Autocorrect"),
        ("Languages", "Emoji suggestions"),
        ("Languages", "Fuzzy Pinyin", "z = zh"),
        ("Privacy", "Learn from my typing"),
    ):
        adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", settings)
        for label in path:
            for _ in range(4):
                if row(label, nodes()):
                    break
                adb("shell", "input", "swipe", "540", "1700", "540", "900", "400")
                time.sleep(1)
            tap_row(label)
    adb("shell", "am", "force-stop", OLD_PKG)
    data = f"/data/user/0/{OLD_PKG}"
    return root(
        f"cat {data}/shared_prefs/*.xml; strings {data}/files/datastore/settings.preferences_pb; cat {data}/files/sebtype.conf"
    )


def old_files(path):
    return root(f"ls /data/user/0/{OLD_PKG}/{path} 2>/dev/null; true").split()


def update_from_futo_app():
    adb("shell", "ime", "reset", check=False)
    as_app(OLD_PKG, False)
    try:
        for p in (OLD_PKG, "dev.sebb.sebtype.next"):
            adb("uninstall", p, check=False)
        adb("install", main_apk, timeout=300)
        wait_for(
            "today's app to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        adb("shell", "ime", "enable", IME)
        adb("logcat", "-c")
        open_field()
        tap_globe()  # a fresh install starts in EN
        wait_set_up()
        learn_lower_candidate()
        ja = learn_japanese()
        # English: a made-up word typed twice and the field closed, so the history saves it.
        for _ in range(2):
            open_field()
            if chip(nodes()):
                tap_globe()  # 日 -> EN
            type_keys(EN_WORD)
            tap_space()
        adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
        print("today's app stored:\n" + set_old_options())
        history = "files/UserHistoryDictionary.en_US.dict"
        if not old_files(history):
            raise Fail(f"today's app kept no English history in {history}")
        datastore = f"/data/user/0/{OLD_PKG}/files/datastore/settings.preferences_pb"
        before = set(root(f"strings {datastore}").split())

        adb("logcat", "-c")
        adb("install", "-r", update_apk, timeout=300)
        as_app(OLD_PKG, True)
        wait_for(
            "the update's keyboard to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        # The old keyboard's service is gone: Android drops it from the enabled keyboards.
        kept = IME in adb("shell", "ime", "list", "-s")
        adb("shell", "ime", "enable", IME)
        open_field()
        wait_set_up()
        moved = old_files("files/english/UserHistoryDictionary.en_US.dict")
        if old_files(history) or not any(f.endswith(".body") for f in moved):
            raise Fail(
                f"English's history not moved: left {old_files(history)}, moved {moved}"
            )
        lost = before - set(root(f"strings {datastore}").split())
        if not before or lost:
            raise Fail(f"the options' file lost {sorted(lost)[:10]}")
        stored = root(
            f"cat /data/user/0/{OLD_PKG}/files/sebtype.conf /data/user/0/{OLD_PKG}/files/rime/user/rime_ice.custom.yaml; "
            f"strings /data/user/0/{OLD_PKG}/files/datastore/settings.preferences_pb"
        )
        print("the new app has:\n" + stored)
        missing = [
            o
            for o, found in (
                ("learning off", re.search(r"\[Learning\]\s*On=false", stored)),
                ("z = zh", "derive/^zh/z/" in stored),
                ("autocorrect off", "pref_key_auto_correction" in stored),
            )
            if not found
        ]
        if missing:
            raise Fail(f"options lost in the update: {', '.join(missing)}")
        to_chinese()  # the update kept EN in use, as today's app was left
        zh = expect_first("lh", "厉害")()
        to_japanese()
        got = candidates_for(JA_CODE)
        if got[0] != ja:
            raise Fail(f"after the update {JA_CODE} -> {got[:5]}, not {ja} first")
        return (
            f"{zh}; {JA_CODE} -> {got[:3]}; English's history moved ({', '.join(moved)}); options kept;"
            f" keyboard {'still' if kept else 'no longer'} enabled after the update"
        )
    finally:
        adb("uninstall", OLD_PKG, check=False)
        # The new keyboard was uninstalled for the update: the checks after this one need it back.
        adb("install", apk, timeout=300)
        as_app(os.environ.get("SEBTYPE_PACKAGE") or OLD_PKG, NEXT_RUN)
        wait_for(
            "the new keyboard to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        adb("shell", "ime", "enable", IME)


NEXT_RUN = NEXT
if NEXT and main_apk and update_apk:
    check("update-from-futo-app", update_from_futo_app)
elif NEXT and (WANTED is None or "update-from-futo-app" in WANTED):
    result(
        "SKIP",
        "update-from-futo-app",
        "needs MAIN_APK and UPDATE_APK (android/build.sh next-update)",
    )

adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
