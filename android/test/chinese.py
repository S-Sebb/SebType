#!/usr/bin/env python3
"""Chinese checks on the emulator, run by android/test/emulator.sh under the emulator lock: password,
private and URL fields (#30), the 简/繁 menu switch (#36), then Japanese's あ ⇄ ア mode chip (#38), its
cold starts (#97) and its idle unload (#56), and that English's model waits for the first letter (#56).

    chinese.py SERIAL APK BUMPED_APK FIELD_APK RESULTS LOGDIR [MAIN_APK]

APK is the release build; BUMPED_APK is the same APK with a different bundled data version marker,
installed over it as an update; MAIN_APK (optional) is the last release of the FUTO-based app, which learns
words in all three languages before APK is installed over it (update-from-futo-app); FIELD_APK is android/perf/build-field.sh's text field app, which only
supplies the box that gets typed into (the app's own "try typing" popup isn't exported). Types by
tapping SebType's own keys (found with `uiautomator dump --windows`) and reads the candidate bar. One
line per check appended to RESULTS; later checks that depend on an earlier one SKIP when it failed.
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
PKG = "dev.sebb.sebtype"
# The keyboard keeps the FUTO-based app's service name, so an update from it stays selected (#262).
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
# OLD: the helpers drive the FUTO-based app (MAIN_APK), only within update-from-futo-app: its keyboard
# view and log tags are its own.
OLD = False
FRAME_ID = f"{PKG}:id/keyboard"
# The new keyboard's space bar, as its accessibility label reads in each system language.
SPACE_LABELS = ("Space", "空格", "スペース")
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
SETTINGS = f"{PKG}/.settings.SettingsActivity"
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


# Whether the device has a root shell: a phone may not (android/test/emulator.sh)
ROOT = os.environ.get("SEBTYPE_ROOT", "1") == "1"


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
        if re.fullmatch(r"[a-zA-Z]", label)
    }


def globe_spot():
    """The globe key beside the space bar: the bottom row's third column, over the last nodes()."""
    left, top, right, bottom = keyboard_frame
    return int(left + 3 * (right - left) / 10), row_y(top, bottom, 3)


def tap_globe():
    """A tap on the globe: English ⇄ the last other language (#526), 中 on a fresh install (EN, 中, 日, #35)."""
    adb("shell", "input", "tap", *map(str, globe_spot()))


def pick_language(name):
    """#526: holds the globe until its list shows, slides to name's row and lets go there, which picks it."""
    at = to = globe_spot()
    adb("shell", "input", "motionevent", "DOWN", *map(str, at))
    try:
        time.sleep(1)
        to = next(
            (
                (x, y)
                for label, x, y, top, cls in nodes()
                if label == name and cls == "android.widget.Button"
            ),
            None,
        )
        if not to:
            to = at  # let go on the globe: nothing changes
            raise Fail(f"no {name} in the globe's list")
    finally:
        adb("shell", "input", "motionevent", "MOVE", *map(str, to), check=False)
        adb("shell", "input", "motionevent", "UP", *map(str, to), check=False)
    time.sleep(2)


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
    """The keyboard's keys show when its engine thread answers (#241), which on the emulator can
    take a second a key in English: waits until the field stops changing."""
    if OLD:
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
            if not OLD and label in SPACE_LABELS
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
    if not OLD:
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
    # The keyboard sets Chinese up as it first starts, without the settings.
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
    tables = "prebuilt tables not checked (no root shell)"
    if ROOT:
        built = root(f"ls {RIME_USER}/build").split()
        # The bundle comes compiled: no table, prism or reverse db may be built on the phone.
        rebuilt = [f for f in built if f.endswith(".bin")]
        if rebuilt:
            raise Fail(f"rebuilt on the phone: {', '.join(rebuilt)} (setup {setup} ms)")
        tables = "prebuilt tables used"
    return (
        f"first run from the setup screen: install {install} ms, set up in {setup} ms all told; "
        f"{meanwhile}; {tables}"
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
    # candidates.
    got = candidates_for("lh", expand=True)
    if "厉害" not in got[:10]:
        raise Fail(f"lh -> {got[:12]} (厉害 not in the first ten)")
    return f"lh -> {got[:10]}, 厉害 at {got.index('厉害') + 1}"


def bar_widths():
    """Each bar candidate's width on screen: a cell the expand button cuts off is narrower than the rest."""
    row = bar_row(nodes())
    # The dump nodes() just made
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    widths = {}
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        label = n.get("text") or n.get("content-desc") or ""
        if m and label and n.get("class") == "android.widget.TextView":
            x1, y1, x2, y2 = map(int, m.groups())
            if row[0] < (y1 + y2) // 2 < row[1]:
                widths[label] = x2 - x1
    return widths


def dan_cut_cell():
    # #491: the bar cut 淡 to a sliver before its expand button, and the expanded view began after it.
    got = candidates_for("dan")
    widths = bar_widths()
    # A single character's cell is the bar's narrowest whole one.
    whole = min(w for c, w in widths.items() if len(c) == 1 and c != "淡")
    in_bar = widths.get("淡", 0) >= whole - 2
    grid = expanded_candidates()
    if not in_bar and "淡" not in grid:
        raise Fail(
            f"dan -> bar {got} (淡 {widths.get('淡', 0)} px wide, a whole cell {whole}), expanded {grid[:6]}"
        )
    return (
        f"dan -> bar {got} (淡 {widths.get('淡', 0)} px wide, a whole cell {whole}), expanded {grid[:6]}: "
        f"淡 whole in the {'bar' if in_bar else 'expanded view'}"
    )


def dan_before_dang():
    # #503: with fuzzy pinyin off (a fresh install's default), the model's 当 (dang) comes after dan's own.
    got = candidates_for("dan", expand=True)[:20]
    dan = [c for c in ("但", "单", "弹", "蛋", "淡") if c in got]
    late = [c for c in dan if "当" in got and got.index(c) > got.index("当")]
    if len(dan) < 5 or late:
        raise Fail(f"dan -> {got}: {late or 'dan characters missing'} after 当")
    return f"dan -> {got}"


def rq_date():
    got = candidates_for("rq")
    today = datetime.date.today().isoformat()
    if today not in got:
        raise Fail(f"rq -> {got[:6]}, no {today}")
    return f"rq -> {got[:6]}"


# The word learn-picked-word teaches for lh: 2nd with the model, which puts 厉害 first by itself (#369), so
# the checks after it see the learned word first only if Rime learned it and the model kept it there.
LEARNED = "灵魂"


def learn_lower_candidate(word=LEARNED):
    got = candidates_for("lh", expand=True)
    if got.index(word) == 0:
        raise Fail(f"lh -> {got}: {word} is already first, nothing to learn")
    tap_candidate(word)
    after = candidates_for("lh")
    if after[0] != word:
        raise Fail(
            f"picked {word} from place {got.index(word) + 1}; next lh -> {after[:6]}"
        )
    return f"picked {word} from place {got.index(word) + 1}; next lh -> {after[:6]}"


def learned_survives_restart():
    restart_app()
    setup, _, deployed, _ = wait_set_up()
    if deployed:
        raise Fail(f"a restart deployed again ({setup} ms)")
    return expect_first("lh", LEARNED)()


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


LAYOUTS = os.path.join(os.path.dirname(__file__), "../app/src/main/assets/layouts")
# Each field kind's pad and what its text and space keys type, left to right and top down (#411).
PADS = {
    "number": ("numpad", "123456-789 ,0."),
    "pin": ("pin", "1234567890"),
    "phone": ("phone", "123456-789 *0#"),
    "date": ("date", "123456-789/0."),
    "time": ("time", "123456:789 0."),
    "datetime": ("datetime", "123456-789/:0 "),
}


def pad_keys(pad):
    """Where each key of the pad's layout file is on the keyboard: (key, x, y), over the last nodes()."""
    with open(os.path.join(LAYOUTS, pad + ".json"), encoding="utf-8") as f:
        rows = json.load(f)["rows"]
    left, top, right, bottom = keyboard_frame
    out = []
    for r, row in enumerate(rows):
        at = 0
        for key in row:
            w = key.get("width", key.get("gap", 1))
            x = left + (at + w / 2) * (right - left) / 10
            out.append((key, int(x), int(top + (r + 0.5) * (bottom - top) / len(rows))))
            at += w
    return out


def pad_types(kind):
    """#411: a field of this kind shows its pad: each text and space key, tapped in turn, types its own text."""

    def run():
        pad, want = PADS[kind]
        open_field(kind)
        for key, x, y in pad_keys(pad):
            if "text" in key or key.get("code") == "space":
                adb("shell", "input", "tap", str(x), str(y))

        def typed():
            return next(n[0] for n in nodes() if n[4] == "android.widget.EditText")

        try:
            field = wait_for(
                f"{want!r} in the {kind} field", lambda: typed() == want and want, 15
            )
        except Fail:
            field = typed()
        if field != want:
            screenshot(f"pad-{kind}.png")
            raise Fail(f"tapped the {pad} pad's keys: field {field!r}, want {want!r}")
        return f"{pad} pad typed {field!r}"

    return run


def pad_globe():
    """#411: a tap on the pads' globe opens Android's keyboard chooser, which lists SebType."""
    open_field("number")
    key = next(k for k in pad_keys("numpad") if k[0].get("code") == "keyboards")
    adb("shell", "input", "tap", str(key[1]), str(key[2]))
    try:
        wait_for(
            "the keyboard chooser", lambda: any(n[0] == "SebType" for n in nodes()), 10
        )
    except Fail:
        screenshot("pad-globe.png")
        raise
    finally:
        adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    return "the number pad's globe opened the keyboard chooser"


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
check("dan-cut-cell", dan_cut_cell, needs=["first-install"])
check("dan-before-dang", dan_before_dang, needs=["first-install"])


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


def expect_model_first(text, word):
    """Rime's own first candidate for text is wrong (the harness, #264); the model's list follows
    Rime's page, slowly under Berberis, so this waits for the model to put word first."""

    def run():
        open_field()
        type_keys(text)
        got = []

        def first():
            got[:] = candidates(nodes())
            return got[:1] == [word]

        try:
            wait_for(f"{word} first", first, 30)
        except Fail:
            raise Fail(f"{text} -> {got[:6]}")
        tap_candidate(word)
        if (field := field_text()) != word:
            raise Fail(f"picking {word} wrote {field!r}")
        return f"{text} -> {got[:6]}"

    return run


# 中文's model (#264): a typo Rime alone gets wrong, and a sentence it splits wrong.
check(
    "zh-model-typo",
    expect_model_first("zheshioxiede", "这是我写的"),
    needs=["first-install"],
)
check(
    "zh-model-sentence",
    expect_model_first("buyaoxiawoa", "不要吓我啊"),
    needs=["first-install"],
)


def split_word_after_context():
    """#502: after 我再去, jiangeshen gives Rime's 健个身 first, not the model's own 剪个深, whose first character
    suits the text before but whose rest doesn't."""
    open_field()
    type_keys("wozaiqu")
    tap_candidate("我再去")
    if (text := field_text()) != "我再去":
        raise Fail(f"picked 我再去; the field shows {text!r}")
    type_keys("jiangeshen")
    got = []

    def first():
        got[:] = candidates(nodes())
        return got[:1] == ["健个身"]

    try:
        wait_for("健个身 first", first, 30)
    except Fail:
        raise Fail(f"我再去 + jiangeshen -> {got[:6]}")
    return f"我再去 + jiangeshen -> {got[:6]}"


check("zh-model-split-word", split_word_after_context, needs=["first-install"])


def correction_on_first_page():
    """A slip that reads as pinyin (#478): youkuaiyoouhao, 又快又好 meant, which Rime doesn't read. Rime's
    correction, which the model weighs once typing pauses (since #502 the model's own beam reads it too),
    comes on the first page (5) within the seconds type_keys waits, and picking it writes it."""
    open_field()
    got = candidates_for("youkuaiyoouhao", expand=True)
    if "又快又好" not in got[:5]:
        raise Fail(f"youkuaiyoouhao -> {got[:8]}")
    tap_candidate("又快又好")
    if (field := field_text()) != "又快又好":
        raise Fail(f"picking 又快又好 wrote {field!r}")
    return f"youkuaiyoouhao -> {got[:5]}"


check("zh-model-correction", correction_on_first_page, needs=["first-install"])


def model_context_after_idle_stop():
    """Rime stops 3 minutes after 中 was left, and starts again when 中 comes back. Its model then reads the
    field's text, which was entered while it was stopped: 国 is among the next words after 中华人民共和."""
    open_field()
    type_keys("zhonghuarenmingonghe")
    tap_candidate("中华人民共和")
    if (text := field_text()) != "中华人民共和":
        raise Fail(f"picked 中华人民共和; the field shows {text!r}")
    adb("logcat", "-c")
    nodes()
    tap_globe()  # 中 -> EN
    wait_for("Rime to unload", lambda: "Rime unloaded" in logcat(), 240, interval=5)
    nodes()
    tap_globe()  # EN -> 中, in the same field
    got = []

    def next_words():
        got[:] = candidates(nodes())
        return "国" in got[:5]

    try:
        wait_for("国 among the next words", next_words, 120, interval=2)
    except Fail:
        raise Fail(
            f"after the idle stop, the next words for 中华人民共和 are {got[:6]}"
        )
    return f"Rime unloaded and set up again; next words {got[:6]}"


check(
    "zh-model-context-after-idle-stop",
    model_context_after_idle_stop,
    needs=["zh-model-typo"],
)
check("learned-after-restart", learned_survives_restart, needs=["learn-picked-word"])
# Restarts 中 and waits for its setup, so it needs 中 working.
check("password-after-restart", password_after_restart, needs=["ranh"])
check("password-plain", password_plain("password"), needs=["first-install"])
check("pin-plain", pin_plain, needs=["first-install"])
check("pad-number", pad_types("number"), needs=["first-install"])
check("pad-pin", pad_types("pin"), needs=["first-install"])
check("pad-phone", pad_types("phone"), needs=["first-install"])
check("pad-date", pad_types("date"), needs=["first-install"])
check("pad-time", pad_types("time"), needs=["first-install"])
check("pad-datetime", pad_types("datetime"), needs=["first-install"])
check("pad-globe", pad_globe, needs=["first-install"])
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
    expect_first("lh", LEARNED),
    needs=["failure-recovers", "learn-picked-word"],
)
check("update-redeploys", update_over_itself, needs=["first-install"])
check("update-keeps-chinese", expect_first("ranh", "然后"), needs=["update-redeploys"])
check(
    "update-keeps-learned",
    expect_first("lh", LEARNED),
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
    return f"繁 off: houlai -> {got[:6]}; learned {LEARNED} still first: {expect_first('lh', LEARNED)()}"


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
        pick_language("日本語")
        if c := chip(nodes()):
            break
    else:
        raise Fail("no あ|ア chip after picking 日本語 from the globe's list")
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


UNDO_ACTION = ("Undo", "撤销", "元に戻す")


def action(labels):
    """Opens the action bar if it is closed, then taps one of its actions. While something is typed the bar's
    toggle is hidden, but an open bar's actions stay."""
    ns = nodes()
    if not any(n[0] in CLOSE_BAR or n[0] in labels for n in ns):
        tap_label(OPEN_BAR)
    tap_label(labels)


def undo(expect):
    """The action bar's Undo in 日本語; which undo went (SebTypeIme's log), expected to be expect's (#379)."""
    adb("logcat", "-c")
    action(UNDO_ACTION)
    settle()
    went = re.findall(r"Undo: (Mozc's|the app's)", logcat())
    if went != [expect]:
        raise Fail(f"Undo went to {went}, not [{expect!r}]")


def undo_conversion():
    """#379: Undo after a conversion goes to Mozc, as today's app: the reading comes back, to convert again."""
    open_field()
    type_keys("nihongo")
    tap_candidate("日本語")
    settle()
    if (text := field_text()) != "日本語":
        raise Fail(f"nihongo, 日本語 picked: the field shows {text!r}")
    undo("Mozc's")
    text = field_text()
    got = candidates(nodes())
    screenshot("japanese-undo.png")
    if text != "にほんご" or "日本語" not in got:
        raise Fail(f"Undo after 日本語: the field shows {text!r}, the bar {got[:6]}")
    return f"日本語 committed, Undo -> {text!r}, the bar {got[:3]}"


check("ja-undo-conversion", undo_conversion, needs=["ja-chip"])


PASTE_ACTION = ("Paste from Clipboard", "从剪贴板粘贴", "クリップボードから貼り付け")


def converted(word, reading):
    """reading typed in 日本語 after what the field has, word picked."""
    before = field_text()
    type_keys(reading)
    tap_candidate(word)
    settle()
    if (text := field_text()) != before + word:
        raise Fail(
            f"{reading}, {word} picked after {before!r}: the field shows {text!r}"
        )
    return text


def undo_keeps(was, wrong, what):
    """Undo after an edit that wasn't Mozc's: the app's undo (Ctrl+Z) goes, whatever it takes back, and not
    Mozc's, which would have put its reading over other text (wrong)."""
    undo("the app's")
    if (text := field_text()) == wrong:
        raise Fail(f"{what}, then Undo: {was!r} became {text!r}")
    return text


def undo_after_cursor_move():
    """#379: 日本語 and 寿司 committed, the cursor moved back two: Undo leaves the text before it alone."""
    open_field()
    converted("日本語", "nihongo")
    was = converted("寿司", "sushi")
    for _ in range(2):
        adb("shell", "input", "keyevent", "KEYCODE_DPAD_LEFT")
    time.sleep(1.5)
    return f"{was!r}, the cursor moved, Undo -> {undo_keeps(was, '日すし寿司', 'the cursor moved')!r}"


def undo_after_paste():
    """#379: 日本語 committed, then xyz pasted: Undo doesn't take the paste for Mozc's commit."""
    open_field(clip="xyz")
    converted("日本語", "nihongo")
    action(ALL_ACTIONS)
    tap_label(PASTE_ACTION)
    settle()
    if (was := field_text()) != "日本語xyz":
        raise Fail(f"日本語, then Paste: the field shows {was!r}")
    return f"{was!r}, Undo -> {undo_keeps(was, '日本語にほんご', 'pasted')!r}"


def undo_while_composing():
    """#379: Undo while nihongo is typed and nothing converted: as before, the reading goes in as it is (and the
    app may undo it); it isn't left composing."""
    open_field()
    if not any(n[0] in CLOSE_BAR for n in nodes()):
        tap_label(OPEN_BAR)
    type_keys("nihongo")
    undo("the app's")
    text = field_text()
    got = candidates(nodes())
    if text not in ("にほんご", "") or "日本語" in got:
        raise Fail(f"nihongo typed, Undo: the field shows {text!r}, the bar {got[:6]}")
    return f"nihongo typed, Undo -> {text!r}, the bar {got[:3]}"


check("ja-undo-after-cursor-move", undo_after_cursor_move, needs=["ja-chip"])
check("ja-undo-after-paste", undo_after_paste, needs=["ja-chip"])
check("ja-undo-while-composing", undo_while_composing, needs=["ja-chip"])


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
# A made-up English personal word with a shortcut, as the words screen of the FUTO-based app saved it:
# typing the shortcut offers the phrase (#380).
SHORTCUT, SHORTCUT_PHRASE = "qvz", "plimbo vexter"


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
    return adb("shell", f"logcat -d -s {'JapaneseIME' if OLD else 'SebType'} || true")


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


def en_loads():
    """How many times English began loading its model in the keyboard's process since trace_loads()
    started: core/ marks each attempt with the trace section "SebType load" (english.cpp)."""
    trace = root("atrace --async_dump")
    return len(re.findall(r"B\|\d+\|SebType load\b", trace))


def en_model_waits_for_letter():
    """English's prediction model loads only once a letter is typed (#56, Decisions #2)."""
    open_field()
    if chip(nodes()):
        tap_globe()  # 日 -> EN
    stop_keyboard()
    adb("logcat", "-c")
    # App-level tracing of the keyboard's process alone; atrace wants a category, and view is a light one.
    root(f"atrace --async_start -b 4096 -a {PKG} view")
    try:
        open_field()
        time.sleep(10)
        if loads := en_loads():
            raise Fail(
                f"the model began loading {loads} time(s) in an empty field before any letter"
            )
        type_keys("th")
        # No chip is EN or 中: in 中, th has Chinese candidates and no English model to load.
        got = candidates(nodes())
        if not all(c.isascii() for c in got):
            raise Fail(f"th -> {got[:6]}: the keyboard is in 中, not EN")
        loads = wait_for("the model to load after a letter", en_loads, 60, interval=2)
    finally:
        root("atrace --async_stop > /dev/null")
    # The section also covers a load that failed, which core/ reports on stderr, in the system log.
    if failed := [l for l in logcat().splitlines() if "sebtype-lm:" in l]:
        raise Fail(f"the model failed to load after a letter: {failed[0]}")
    return f"empty field: no load began; after typing th: {loads} load(s), none failed"


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


# --- The keyboard's own checks, from #191's stages 3 and 4 ---


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
    """Taps the globe until x types a plain x: no chip, no Chinese notice and no Chinese candidates
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
    raise Fail("no English after tapping the globe")


def to_chinese():
    """Cycles the globe until ni offers Chinese candidates (waiting while Chinese sets itself up). English
    offers suggestions for ni too, so a candidate must be Chinese."""
    for _ in range(6):
        open_field()
        type_keys("ni")
        ns = nodes()
        if any(re.search("[\u4e00-\u9fff]", c) for c in candidates(ns)) and not chip(
            ns
        ):
            return
        if any(n[0].startswith(PREPARING) for n in ns):
            time.sleep(5)
            continue
        pick_language("中文")
    raise Fail("no 中 after picking it from the globe's list")


def fresh_in_english():
    """A new keyboard process in EN, which must leave Rime stopped (it holds about 40 MB, #351). 中 was the last
    other language, so the globe's tap goes to it (#526)."""
    open_field()
    nodes()
    pick_language("中文")
    to_english()
    stop_keyboard()
    adb("logcat", "-c")
    open_field()
    time.sleep(10)
    if re.search(SET_UP, logcat()):
        raise Fail("a keyboard that started in EN started Rime")


def burst_into_chinese(points):
    """The globe (EN -> 中), then points, in one burst while Rime starts: its files are dropped from the page
    cache first, as on a phone short of memory, so its start reads them from storage. Over the last nodes()."""
    left, top, right, bottom = keyboard_frame
    globe = (int(left + 3 * (right - left) / 10), row_y(top, bottom, 3))
    root("sync; echo 3 > /proc/sys/vm/drop_caches")
    monkey_taps([globe] + points, 10)


def setup_took():
    setup = re.search(SET_UP, logcat())
    return f"Rime set up in {setup.group(1)} ms" if setup else "no setup logged"


def keys_waited():
    """How many keys of the burst waited for Rime, from the app's log (None if none did): proof the burst
    overlapped its start."""
    fed = re.search(
        r"Fed (\d+) keys that waited for Rime",
        adb("shell", "logcat -d -s SebType || true"),
    )
    return int(fed.group(1)) if fed else None


def no_overlap(took):
    return Fail(f"no key waited for Rime ({took}): the burst didn't overlap its start")


def zh_waits_for_zh():
    """#351: keys typed while Rime starts reach it in order, as they would a running Rime: ranh, Space
    (然后 committed), Delete (后 deleted) leave 然. The letters are where EN has them."""
    fresh_in_english()
    ns = wait_for(
        "the keyboard",
        lambda: (lambda n: n if keys(n) else None)(nodes()),
        KEYBOARD_WAIT,
    )
    k = keys(ns)
    space = next((x, y) for label, x, y, top, cls in ns if label in SPACE_LABELS)
    delete = next((x, y) for label, x, y, top, cls in ns if label == "Delete")
    burst_into_chinese([k[ch][:2] for ch in "ranh"] + [space, delete])
    try:
        text = wait_for("the field to show what was typed", field_text, 30)
    except Fail:
        text = ""
    took = setup_took()
    waited = keys_waited()
    bar = candidates(nodes())
    to_english()  # the checks after type in EN
    if text != "然":
        raise Fail(
            f"ranh, Space, Delete typed while Rime started ({took}): field {text!r}, bar {bar[:6]}"
        )
    if waited is None:
        raise no_overlap(took)
    return f"ranh, Space, Delete typed while Rime started ({took}, {waited} keys waited) -> field 然"


check("zh-waits-for-zh", zh_waits_for_zh, needs=["ja-chip"])


def globe_types_letters(to_language, name):
    """The globe in the middle of a word to convert types its letters as they were tapped, phizz, not its
    pinyin or kana, then switches (#492). The bar isn't checked: English, after 日, offers words for phizz."""

    def run():
        to_language()
        open_field()
        type_keys("phizz")
        before, shown = candidates(nodes()), field_text()
        if not before:
            raise Fail(f"typed phizz in {name}; no candidates")
        tap_globe()
        try:
            text = wait_for(
                "the field to show phizz",
                lambda: field_text() == "phizz" and "phizz",
                10,
            )
        except Fail:
            text = field_text()
        if text != "phizz":
            raise Fail(
                f"phizz in {name} (field {shown!r}), then the globe: field {text!r}"
            )
        return f"phizz in {name} (field {shown!r}, {before[:3]}); after the globe the field reads phizz"

    return run


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
        screenshot("one-handed.png")
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


def shift_cancels_capital():
    """#479: a tap on Shift at the start of a sentence cancels the field's capital: the keys show lower case and
    the letter types in lower case. The next sentence has its capital again, and Shift turned on types one."""
    to_english()
    open_field()
    wait_for(
        "Shift on (the field's capital)",
        lambda: "Shift on" in {label for label, *_ in nodes()},
        KEYBOARD_WAIT,
    )
    tap_key("Shift on")
    labels = {label for label, *_ in nodes()}
    if "Shift" not in labels or "Q" in labels:
        raise Fail(
            f"Shift tapped at the start: the keys still show capitals ({sorted(labels)[:12]})"
        )
    type_text("hi. there ")
    tap_key("Shift")
    type_text("now")
    if (text := field_text()) != "hi. There Now":
        raise Fail(
            f"Shift (cancel), hi. there, Shift, now -> {text!r}, not 'hi. There Now'"
        )
    return f"-> {text!r}"


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
        screenshot("split.png")
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


def slide_to_letter():
    """A finger put down on one letter and slid onto its neighbour types the neighbour (#382); held there,
    the long press opens the neighbour's choices (e's first is 3, w's is 2). The lift-off point counts: a last
    MOVE 7 dp past q's edge (under the 8 dp threshold) and the UP 12 dp past it type w."""
    to_english()
    k = key_spots()
    (qx, y), (wx, _), (ex, _) = k["q"], k["w"], k["e"]
    edge = (qx + wx) // 2  # q's right edge: keys are a key width apart, edge to edge
    dp = screen_density()
    cases = (  # name, down, moves, hold, up, what it types
        ("q -> w", qx, [qx + (wx - qx) * i // 4 for i in range(1, 5)], 0, wx, "w"),
        (
            "w -> e, held",
            wx,
            [wx + (ex - wx) * i // 4 for i in range(1, 5)],
            1.5,
            ex,
            "3",
        ),
        (
            "q, lifted 12 dp past its edge",
            qx,
            [edge + round(7 * dp)],
            0,
            edge + round(12 * dp),
            "w",
        ),
    )
    got = []
    for name, down, moves, hold, up, want in cases:
        open_field()
        path = "; ".join(f"input motionevent MOVE {x} {y}" for x in moves)
        adb(
            "shell",
            f"input motionevent DOWN {down} {y}; {path}; sleep {hold}; input motionevent UP {up} {y}",
        )
        time.sleep(1.5)
        settle()
        text = field_text()
        got.append(f"{name} typed {text!r}")
        if text.lower() != want:
            raise Fail(f"{got[-1]}, not {want!r}; " + "; ".join(got[:-1]))
    return "; ".join(got)


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
    talkback_reaches(framed=True)
    for start, (dx, dy) in swipes:
        corner = wait_for("the resize corner", lambda: node(RESIZE_CORNER), 10)
        l, t, r, b = keyboard_frame
        x, y = (
            corner[1:3] if start == "corner" else (l + (r - l) // 6, t + (b - t) // 5)
        )
        to = (min(max(x + dx, 0), w - 1), min(max(y + dy, 0), h - 1))
        adb("shell", "input", "swipe", str(x), str(y), *map(str, to), "1500")
        time.sleep(1)
    try:
        tap_label(("Apply", "应用", "適用"))
    except Fail:
        screenshot("resize-without-apply.png")
        raise
    return frame_now()


def talkback_reaches(framed):
    """TalkBack reaches the resize frame alone while it is up (the keys under it are out of the
    accessibility tree), and the keys again once it is gone (#283)."""
    shown = important_labels()
    if (RESIZE_CORNER in shown) != framed or bool(shown & set(SPACE_LABELS)) == framed:
        raise Fail(
            f"with the resize frame {'up' if framed else 'gone'}, TalkBack's tree has "
            f"{sorted(shown & set(SPACE_LABELS + (RESIZE_CORNER,)))}"
        )


def node_bounds():
    """{label: (left, top, right, bottom)} of the nodes in all windows, the first of each label. Bounds are
    cut to what shows: a key half off the window is half as tall."""
    nodes()  # the keyboard's frame too
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out = {}
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        out.setdefault(
            n.get("text") or n.get("content-desc") or "",
            m and tuple(map(int, m.groups())),
        )
    return out


def bottom_row_whole(window):
    """The keyboard's bottom row, whole within a window [window] px tall: Symbols and Space as tall as
    Delete in the row above. Returns Space's bounds."""
    b = node_bounds()
    space = next((b[l] for l in SPACE_LABELS if b.get(l)), None)
    above, symbols = b.get("Delete"), b.get("Symbols")
    tall = above and above[3] - above[1]
    if not (above and symbols and space) or any(
        k[3] > window or abs((k[3] - k[1]) - tall) > 2 for k in (symbols, space)
    ):
        raise Fail(
            f"in a {window} px window the bottom row isn't whole: Delete {above}, Symbols {symbols}, Space {space}"
        )
    return space


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
    uimode = (
        adb("shell", "cmd", "uimode", "night").split(":")[-1].strip()
    )  # yes, no, auto or custom
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
        # The keyboard's view made again with the frame up, by dark mode and by a turn (floating in both
        # orientations): TalkBack reaches the frame alone while it shows, and the keys once it is gone (after
        # Apply, or when the change started the keyboard over and so ended the resize).
        rotate(1)
        set_mode("Floating")
        rotate(0)
        night = "no" if uimode == "yes" else "yes"
        made_again = []
        for name, change in (
            ("dark mode", lambda: adb("shell", "cmd", "uimode", "night", night)),
            ("a turn", lambda: rotate(1)),
        ):
            open_field()
            action(MODES_ACTION)
            tap_label(RESIZE)
            wait_for("the resize corner", lambda: node(RESIZE_CORNER), 10)
            change()
            time.sleep(3)
            framed = node(RESIZE_CORNER) is not None
            talkback_reaches(framed)
            if framed:
                tap_label(("Apply", "应用", "適用"))
                talkback_reaches(framed=False)
            made_again.append((name, framed))
        set_mode("Standard")
        rotate(0)
        types_letters()
        return (
            f"keys {r - l}x{b - t} -> {r2 - l2}x{b2 - t2} px, kept after a restart and landscape "
            f"(there {land[2] - land[0]}x{land[3] - land[1]}); the frame "
            + ", ".join(
                f"{'kept' if kept else 'closed'} by {name}" for name, kept in made_again
            )
            + ", TalkBack reaching the frame alone while it shows and the keys after; typing works"
        )
    finally:
        adb("shell", "cmd", "uimode", "night", uimode)
        rotate(1)
        set_mode("Standard")
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
    """Floating, moved to the top left and resized wide and tall: a window two thirds as wide and half as
    tall shows its keys narrower and shorter, all of them whole on the screen (the handle too) and typing.
    Wider and Taller there, held at the window's edges, change nothing saved: the full window brings the
    whole size back. Made narrower there, the full window brings the saved height back with the new width. In
    a window 280 dp tall the keys step aside under Keyboard Modes and show whole once it closes (#283)."""
    to_english()
    w, h = screen_size()

    def full_window():
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        open_field()
        return frame_now()

    try:
        set_mode("Floating")
        tap_reset()
        l, t, r, b = resize_floating(("keys", (-w, -h)), ("corner", (w, h)))
        wide, tall = r - l, b - t
        small, short = w * 2 // 3, h // 2
        adb("shell", "wm", "size", f"{small}x{short}")
        time.sleep(3)
        open_field()
        space = bottom_row_whole(short)
        l2, t2, r2, b2 = keyboard_frame
        handle = node(MOVE_KEYBOARD)
        if not handle or handle[3] < 0 or b2 - t2 >= tall or r2 - l2 > small:
            raise Fail(
                f"keys {wide}x{tall} px; in a {small}x{short} px window {r2 - l2}x{b2 - t2} px, the handle at "
                f"{handle and handle[3]}"
            )
        screenshot("floating-short-window.png")
        types_letters()
        # Wider and Taller at the window's edges: the saved size stays the user's, not the one shown here.
        resize_floating(("corner", (w, 0)), ("corner", (0, h)))
        l3, t3, r3, b3 = full_window()
        if abs((b3 - t3) - tall) > 4 or abs((r3 - l3) - wide) > 4:
            raise Fail(
                f"after Wider and Taller at a {small}x{short} px window's edges, the full window shows "
                f"{r3 - l3}x{b3 - t3} px, not the saved {wide}x{tall}"
            )
        # Only the width changed: the saved height stays the tall one, not the one cut to this window.
        adb("shell", "wm", "size", f"{small}x{short}")
        time.sleep(3)
        open_field()  # the keyboard settled in the new window before the frame opens, as above
        l4, t4, r4, b4 = resize_floating(("corner", (-150, 0)))
        if (r4 - l4) > (r2 - l2) - 100:
            raise Fail(
                f"the corner dragged 150 px left: keys {r2 - l2} -> {r4 - l4} px wide"
            )
        l5, t5, r5, b5 = full_window()
        if abs((b5 - t5) - tall) > 4 or abs((r5 - l5) - (r4 - l4)) > 4:
            raise Fail(
                f"back in the full window the keys are {r5 - l5}x{b5 - t5} px, not {r4 - l4}x{tall}"
            )
        # A window wider than tall is landscape: floating there too. 280 dp less the status bar, the
        # navigation bar and Keyboard Modes leaves no room for keys at today's 96 dp minimum: they step
        # aside while Keyboard Modes is open. Once it closes they come back whole, shorter than the minimum
        # (the bars above them leave about 60 dp), and no shorter than 48 dp, half of it.
        tiny = round(280 * screen_density())
        least = round(48 * screen_density()) - 2
        adb("shell", "wm", "size", f"{w}x{tiny}")
        time.sleep(3)
        try:
            set_mode("Floating")
            open_field()
            action(MODES_ACTION)
            b = node_bounds()
            handle, floating = b.get(MOVE_KEYBOARD), b.get("Floating")
            if (
                any(b.get(l) for l in SPACE_LABELS)
                or not handle
                or handle[1] < 0
                or not floating
                or floating[3] > tiny
            ):
                raise Fail(
                    f"in a {tiny} px window with Keyboard Modes open: the handle {handle}, Floating {floating}, "
                    f"Space {[b.get(l) for l in SPACE_LABELS if b.get(l)]} (the keys should step aside)"
                )
            screenshot("floating-tiny-window.png")
            open_field()
            tiny_space = bottom_row_whole(tiny)
            tiny_keys = keyboard_frame[3] - keyboard_frame[1]
            screenshot("floating-tiny-window-keys.png")
            if tiny_keys < least:
                raise Fail(
                    f"in a {tiny} px window the keys are {tiny_keys} px tall, under the {least} px "
                    f"the window leaves them"
                )
            types_letters()
        finally:
            set_mode("Standard")
        return (
            f"keys {wide}x{tall} px; {r2 - l2}x{b2 - t2} px within a {small}x{short} px window (Space {space}), "
            f"typing works; after Wider and Taller at its edges {r3 - l3}x{b3 - t3} px in the full window; "
            f"narrowed there to {r4 - l4} px, then {r5 - l5}x{b5 - t5} px in the full window; in {tiny} px "
            f"the keys aside under Keyboard Modes, then {tiny_keys} px with Space {tiny_space}, typing works"
        )
    finally:
        adb("shell", "wm", "size", "reset")
        time.sleep(3)
        tap_reset()
        set_mode("Standard")


def globe_list_narrow():
    """#526: the held globe's list stays within the keys' width and on the screen, on the narrowest floating
    keyboard moved to the screen's top and on one-handed's (modes-globe-list-*.png)."""
    to_english()
    w, h = screen_size()
    labels = ("English", "中文", "日本語", "Other keyboards")
    got = []
    try:
        set_mode("Floating")
        tap_reset()
        resize_floating(("corner", (-w, 0)))
        # Its handle to the screen's top, as in modes-floating-resized: the list has no room above the keys
        open_field()
        x, y = next(n[1:3] for n in nodes() if n[0] == MOVE_KEYBOARD)
        adb("shell", "input", "swipe", str(x), str(y), str(x), "0", "800")
        time.sleep(1)
        for mode in ("floating", "one-handed"):
            if mode == "one-handed":
                set_mode("One-handed")
            open_field()
            nodes()
            l, t, r, b = keyboard_frame
            at = globe_spot()
            adb("shell", "input", "motionevent", "DOWN", *map(str, at))
            try:
                time.sleep(1)
                bounds = node_bounds()
                screenshot(f"modes-globe-list-{mode}.png")
            finally:
                adb("shell", "input", "motionevent", "UP", *map(str, at), check=False)
            rows = [bounds.get(k) for k in labels]
            heights = [row[3] - row[1] for row in rows if row]
            if (
                None in rows
                or min(heights) < 0.9 * max(heights)
                or any(row[0] < l - 2 or row[2] > r + 2 or row[1] < 0 for row in rows)
            ):
                raise Fail(
                    f"{mode}: keys {l}..{r} px wide; the list's rows {dict(zip(labels, rows))}"
                )
            got.append(
                f"{mode}: keys {l}..{r}, rows {rows[0][0]}..{rows[0][2]} from y {rows[0][1]}"
            )
            time.sleep(1)
        return "; ".join(got)
    finally:
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
        bounds = node_bounds()
        corner, reset, apply = (
            bounds.get(k) for k in (RESIZE_CORNER, "Reset", "Apply")
        )
        # The frame is the keyboard's width, its right edge the corner's; each button whole within it, apart
        # from the other and as big as drawn, 40 dp at least (bounds are cut to what shows).
        right = corner and corner[2]
        left = right and right - narrowest
        least = 40 * screen_density() - 2
        if (
            not (corner and reset and apply)
            or any(
                b[0] < left
                or b[2] > right
                or b[3] > corner[3]
                or min(b[2] - b[0], b[3] - b[1]) < least
                for b in (reset, apply)
            )
            or not (reset[3] <= apply[1] or reset[2] <= apply[0])
        ):
            raise Fail(
                f"in a frame from x {left} to {right}, Reset is {reset} and Apply {apply}"
            )
        screenshot("floating-narrowest.png")
        tap_label(("Apply",))
        if node(RESIZE_CORNER):
            raise Fail("Apply didn't end the resize")
        screenshot("floating-narrowest-keys.png")
        l, t, r, b = frame_now()
        if abs((r - l) - narrowest) > 0.1 * narrowest:
            raise Fail(f"the narrowest keys are {r - l} px, not about {narrowest}")
        types_letters()
        # Reset at this width brings back the keyboard's first width, 85 % of the screen.
        open_field()
        action(MODES_ACTION)
        tap_label(RESIZE)
        tap_label(("Reset",))
        tap_label(("Apply",))
        l2, t2, r2, b2 = frame_now()
        if abs((r2 - l2) - 0.85 * w) > 0.05 * w:
            raise Fail(
                f"Reset at the narrowest width left the keys {r2 - l2} px wide, not about {0.85 * w:.0f}"
            )
        return (
            f"keys {r - l} px wide (144 dp is {narrowest}), Reset {reset} and Apply {apply} inside, typing "
            f"works; Reset there: {r2 - l2} px"
        )
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
    """English suggests a word of the personal dictionary (Android's user dictionary), as 日本語 does, and a
    word's shortcut offers it first, left of the shortcut typed in the middle (#380)."""
    root(
        f"content insert --uri {WORDS} --bind word:s:zorblax --bind locale:s:en_US"
        " --bind frequency:i:250 --bind appid:i:0"
    )
    root(
        f"content insert --uri {WORDS} --bind word:s:'{SHORTCUT_PHRASE}' --bind shortcut:s:{SHORTCUT}"
        " --bind locale:s:en_US --bind frequency:i:250 --bind appid:i:0"
    )
    try:
        to_english()
        got = candidates_for(
            "zorbl"
        )  # the field shows the keyboard again: it reads the words
        shortcut = candidates_for(SHORTCUT)
    finally:
        root(
            f"content delete --uri {WORDS} --where \"word='zorblax' OR word='{SHORTCUT_PHRASE}'\""
        )
    if "zorblax" not in [
        c.lower() for c in got
    ]:  # a sentence's first word has its capital
        raise Fail(f"zorbl -> {got[:6]}, without the personal word zorblax")
    if shortcut_offered(shortcut):
        raise Fail(shortcut_offered(shortcut))
    return f"zorbl -> {got[:6]}; {SHORTCUT} -> {shortcut[:3]}"


def shortcut_offered(bar):
    """Why BAR (the slots left to right) doesn't offer the shortcut's phrase first, or None."""
    # The middle slot holds the shortcut as typed, the left one the first candidate.
    if len(bar) < 2 or bar[0].lower() != SHORTCUT_PHRASE or bar[1].lower() != SHORTCUT:
        return f"{SHORTCUT} -> {bar[:3]}, not {SHORTCUT_PHRASE!r} first"
    return None


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


def custom_enter_action():
    """#381: in a field with an app's own action (label "Pay", id 42), Enter after a word sends that action,
    as the old app did, not a newline; the key keeps the Enter icon, as the old app's did."""
    to_english()
    open_field("action")
    type_text("hi")
    spots = key_spots()
    if "Enter" not in spots:
        raise Fail(f"no Enter key among {sorted(spots)}")
    adb("shell", "input", "tap", *map(str, spots["Enter"]))
    wait_for("the field's action", lambda: field_text() == "action 42", 10)
    return "Enter -> performEditorAction(42)"


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
check("en-failure-visible", en_failure_visible, needs=["first-install"])
check("zh-globe-types-letters", globe_types_letters(to_chinese, "中"), needs=["ranh"])
check(
    "ja-globe-types-letters", globe_types_letters(to_japanese, "日"), needs=["ja-chip"]
)
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
check("en-picked-suggestion-period", picked_suggestion_period, needs=["first-install"])
check("emoji-picks", emoji_picks, needs=["first-install"])
check("caps-lock", caps_lock, needs=["en-model-waits-for-letter"])
check("en-shift-cancels-capital", shift_cancels_capital, needs=["first-install"])
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
check("custom-enter-action", custom_enter_action, needs=["first-install"])
check("clipboard-paste", clipboard_paste, needs=["first-install"])
check("quick-clip", quick_clip, needs=["first-install"])
check("quick-clip-secret", quick_clip_secret, needs=["first-install"])
check("emoji-search", emoji_search, needs=["first-install"])
check("emoji-ascii", emoji_ascii, needs=["first-install"])
check("clipboard-search", clipboard_search, needs=["first-install"])


def zh_search_waits():
    """#351: letters typed into the clipboard's search while Rime starts stay in the search, and letters typed
    right after it closes reach Rime after the field's reset, not before it: ni in the search, close, ni, then
    Space once Rime is ready leave 你."""
    keep_clipboard()
    fresh_in_english()
    ns = wait_for(
        "the keyboard",
        lambda: (lambda n: n if keys(n) else None)(nodes()),
        KEYBOARD_WAIT,
    )
    field_keys = keys(ns)
    space = next((x, y) for label, x, y, top, cls in ns if label in SPACE_LABELS)
    action(CLIPBOARD_ACTION)
    tap_label(CLIPBOARD_SEARCH)
    ns = wait_for(
        "the keyboard",
        lambda: (lambda n: n if keys(n) else None)(nodes()),
        KEYBOARD_WAIT,
    )
    k = keys(ns)
    close = next((x, y) for label, x, y, top, cls in ns if label in CLOSE_SEARCH)
    burst_into_chinese(
        [k["n"][:2], k["i"][:2], close, field_keys["n"][:2], field_keys["i"][:2]]
    )
    # Space only now: a Space in the burst would commit 你 before the field's reset could drop the reading
    wait_for("Chinese to be set up", lambda: re.search(SET_UP, logcat()), 30, 1)
    time.sleep(1)
    adb("shell", "input", "tap", str(space[0]), str(space[1]))
    try:
        text = wait_for("the field to show what was typed", field_text, 10)
    except Fail:
        text = ""
    took = setup_took()
    waited = keys_waited()
    bar = candidates(nodes())
    to_english()
    if text != "你":
        raise Fail(
            f"ni in the search, close, ni while Rime started ({took}), then Space: field {text!r}, bar {bar[:6]}"
        )
    if waited is None:
        raise no_overlap(took)
    return f"ni in the search, close, ni while Rime started ({took}, {waited} keys waited), then Space -> field 你"


check("zh-search-waits", zh_search_waits, needs=["ja-chip"])
check("clipboard-image-paste", clipboard_image_paste, needs=["first-install"])
check("clipboard-today-image", clipboard_today_image, needs=["first-install"])
check("modes-one-handed", modes_one_handed, needs=["first-install"])
check("modes-split", modes_split, needs=["first-install"])
check("modes-floating", modes_floating, needs=["first-install"])
check("modes-height", modes_height, needs=["first-install"])
check("swipe-space-cursor", swipe_space_cursor, needs=["first-install"])
check("swipe-delete-words", swipe_delete_words, needs=["first-install"])
check("swipe-delete-cjk", swipe_delete_cjk, needs=["first-install"])
check("slide-to-letter", slide_to_letter, needs=["first-install"])
check("modes-floating-resized", floating_after_resize, needs=["first-install"])
check("modes-floating-resize", floating_resize, needs=["first-install"])
check("modes-floating-resize-edge", floating_resize_edge, needs=["first-install"])
check("modes-floating-short-window", floating_short_window, needs=["first-install"])
check("modes-floating-narrowest", floating_narrowest, needs=["first-install"])
check("modes-globe-list", globe_list_narrow, needs=["first-install"])

# --- An update from the FUTO-based app (its last release, MAIN_APK) to this one (#254, #262) ---
# The old app, chosen as the keyboard, learns a made-up English word, picks lower candidates in 中文 and
# 日本語 and changes options in its settings (autocorrect, fuzzy pinyin, learning). APK installs over it: SebType
# stays enabled and chosen (the service keeps its name), offers both picks first, English's learned words
# wait in the English engine's folder (core_test checks that engine takes them in), and the options are kept.
OLD_PKG = PKG
EN_WORD = "zorbleq"  # made up, so only learning can put it in the history
JA_CODE = "hashi"
# z for zh: zhengzhi's 政治 is among zengzi's first three only with fuzzy pinyin's z = zh, which Rime reads
# from SebType's schema patch (guide35: third with it, not in the first four without). Typo fixes already
# turn commoner ones, like zege, into zh words.
FUZZY_CODE, FUZZY_WORD = "zengzi", "政治"


def as_old(old):
    """Points the helpers at the FUTO-based app (old) or this one: their keyboard views differ."""
    global OLD, FRAME_ID
    OLD = old
    FRAME_ID = f"{PKG}:id/main_keyboard_frame" if old else f"{PKG}:id/keyboard"


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


def scroll_to(label):
    for _ in range(4):
        if row(label, nodes()):
            return
        adb("shell", "input", "swipe", "540", "1700", "540", "900", "400")
        time.sleep(1)


def shown_on(label):
    """Whether the screen shows the switch or box of the row titled label on (None: no such row)."""
    adb("shell", "uiautomator", "dump", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    ns = [
        (n, *map(int, re.findall(r"\d+", n.get("bounds", ""))))
        for n in ET.fromstring(xml[xml.index("<") :]).iter("node")
    ]
    for n, x1, y1, x2, y2 in ns:
        if row(label, [(n.get("text") or n.get("content-desc") or "",)]):
            y = (y1 + y2) // 2
            for m, _, top, _, bottom in ns:
                if m.get("checkable") == "true" and top <= y <= bottom:
                    return m.get("checked") == "true"
    return None


def options_shown(settings, paths, tap):
    """Opens settings for each path of rows, tapping the last row too if tap; returns each path's last
    row as the screen then shows it (shown_on), which a phone without a root shell checks instead of files."""
    shown = {}
    for path in paths:
        adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", settings)
        for label in path[:-1]:
            scroll_to(label)
            tap_row(label)
        scroll_to(path[-1])
        if tap:
            tap_row(path[-1])
        shown[path] = shown_on(path[-1])
    return shown


def set_old_options(*paths):
    """Taps each path of rows in today's settings, as a user would; returns what it stored, for the log
    (only with a root shell), and the rows as the screen showed them."""
    settings = f"{OLD_PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity"
    shown = options_shown(settings, paths, tap=True)
    adb("shell", "am", "force-stop", OLD_PKG)
    data = f"/data/user/0/{OLD_PKG}"
    stored = (
        root(
            f"cat {data}/shared_prefs/*.xml; strings {data}/files/datastore/settings.preferences_pb; cat {data}/files/sebtype.conf"
        )
        if ROOT
        else f"(files not read: no root shell) on the screen: {shown}"
    )
    return stored, shown


def old_files(path):
    return root(f"ls /data/user/0/{OLD_PKG}/{path} 2>/dev/null; true").split()


def update_from_futo_app():
    adb("shell", "ime", "reset", check=False)
    as_old(True)
    try:
        adb("uninstall", OLD_PKG, check=False)
        adb("install", main_apk, timeout=300)
        wait_for(
            "the old app to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)
        adb("logcat", "-c")
        open_field()
        tap_globe()  # a fresh install starts in EN
        wait_set_up()
        # The old app has no model and puts 灵魂 first already, and the new one's model puts 厉害 first by
        # itself (#369): it learns another of its lh candidates, which only the carried-over learning puts first.
        zh_word = next(
            w
            for w in candidates_for("lh", expand=True)[2:]
            if w != "厉害" and "\u4e00" <= w[0] <= "\u9fff"
        )
        learn_lower_candidate(zh_word)
        ja = learn_japanese()
        # English: a made-up word typed twice and the field closed, so the history saves it.
        for _ in range(2):
            open_field()
            if chip(nodes()):
                tap_globe()  # 日 -> EN
            type_keys(EN_WORD)
            tap_space()
        typed = field_text()
        if ROOT:
            # As root, as in en-personal-word: Android's user dictionary ignores the shell user. Without
            # root the shortcut isn't checked (#380).
            root(
                f"content insert --uri {WORDS} --bind word:s:'{SHORTCUT_PHRASE}' --bind shortcut:s:{SHORTCUT}"
                " --bind locale:s:en_US --bind frequency:i:250 --bind appid:i:0"
            )
            # Its strip has no accessibility nodes: the screenshot shows it, and a space what it commits.
            open_field()
            type_keys(SHORTCUT)
            screenshot("380-old-shortcut.png")
            tap_space()
            old_space = field_text()
            print(f"the old app: a space after {SHORTCUT} typed {old_space!r}")
            if old_space.lower() != SHORTCUT + " ":
                raise Fail(f"the old app's space after {SHORTCUT} typed {old_space!r}")
        adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
        old, history = (
            f"/data/user/0/{OLD_PKG}",
            "files/UserHistoryDictionary.en_US.dict",
        )
        if ROOT:
            try:
                wait_for(
                    f"the old app to save {EN_WORD}",
                    lambda: root(f"grep -rlaF {EN_WORD} {old}/{history}; true").strip(),
                    30,
                )
            except Fail:
                raise Fail(
                    f"the old app saved no {EN_WORD} in its history; the field had {typed!r}"
                )
        else:
            # Its history file can't be read: the old app gets the 30 s the check above allows to save it.
            # The update's check below finds the word only if it was saved.
            time.sleep(30)
        # Learning stays on: once it is off, today's app (AOSP's LatinIME underneath) deletes what it
        # learned when its keyboard next starts. Learning off gets its own update below.
        paths = (
            ("Languages", "Autocorrect"),
            ("Languages", "Emoji suggestions"),
            ("Languages", "Fuzzy Pinyin", "z = zh"),
        )
        options, old_shown = set_old_options(*paths)
        print("the old app stored:\n" + options)
        # Each tap turned the option from its default: autocorrect and emoji suggestions off, z = zh on.
        if list(old_shown.values()) != [False, False, True]:
            raise Fail(f"the old app's settings show {old_shown} after the taps")
        # Setting the options force-stopped the old app, and Android unpicks a keyboard whose app is
        # force-stopped: pick it again, as the user had it.
        adb("shell", "ime", "set", IME)
        chosen = adb(
            "shell", "settings", "get", "secure", "default_input_method"
        ).strip()
        if chosen != IME:
            raise Fail(
                f"the old app isn't the chosen keyboard before the update: {chosen}"
            )
        datastore = f"{old}/files/datastore/settings.preferences_pb"
        before = set(root(f"strings {datastore}").split()) if ROOT else set()

        adb("logcat", "-c")
        adb("install", "-r", apk, timeout=300)
        as_old(False)
        wait_for(
            "the update's keyboard to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        # Nothing is enabled or chosen again: the update itself must keep SebType the keyboard in use.
        enabled = IME in adb("shell", "ime", "list", "-s").split()
        chosen = adb(
            "shell", "settings", "get", "secure", "default_input_method"
        ).strip()
        if not enabled or chosen != IME:
            raise Fail(
                f"after the update SebType is {'enabled' if enabled else 'not enabled'}, the keyboard in use {chosen}"
            )
        # As in update_over_itself: the emulator may not rebind an updated keyboard on the first try.
        try:
            open_field()
        except Fail:
            open_field()
        wait_set_up()
        # z = zh as Rime types it, which the settings screen alone doesn't show: the patch must have come through.
        to_chinese()
        fuzzy = candidates_for(FUZZY_CODE)
        if FUZZY_WORD not in fuzzy[:3]:
            raise Fail(f"z = zh doesn't reach Rime: {FUZZY_CODE} -> {fuzzy[:5]}")
        if not ROOT:
            # No root shell: the files below can't be read, so the options are compared as both apps' settings show them.
            new_shown = options_shown(SETTINGS, paths, tap=False)
            if new_shown != old_shown:
                raise Fail(
                    f"options changed in the update: before {old_shown}, after {new_shown}"
                )
        else:
            # Migration moves the old history into files/english/, and English's engine learns its words into
            # en_history once and removes it: what counts is the old app's word offered now.
            if old_files(history):
                raise Fail(f"English's old history left in place: {old_files(history)}")
            # Not an option: the FUTO-based app's own record of which of its input modes learned words, which
            # nothing in SebType reads, comes through the update emptied.
            futo_record = {"General", "Chinese", "Japanese"}
            lost = before - futo_record - set(root(f"strings {datastore}").split())
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
                    ("z = zh", "derive/^zh/z/" in stored),
                    ("autocorrect off", "pref_key_auto_correction" in stored),
                )
                if not found
            ]
            if missing:
                raise Fail(f"options lost in the update: {', '.join(missing)}")
        to_english()
        en = candidates_for(EN_WORD[:5])
        if EN_WORD not in [c.lower() for c in en]:
            raise Fail(
                f"after the update {EN_WORD[:5]} -> {en[:5]}, without the old app's {EN_WORD}"
            )
        # The old app offered the phrase first, and its space kept the shortcut typed (old_space).
        shortcut = candidates_for(SHORTCUT) if ROOT else ["not checked (no root shell)"]
        if ROOT and shortcut_offered(shortcut):
            raise Fail(f"after the update: {shortcut_offered(shortcut)}")
        to_chinese()
        zh = expect_first("lh", zh_word)()
        to_japanese()
        got = candidates_for(JA_CODE)
        if got[0] != ja:
            raise Fail(f"after the update {JA_CODE} -> {got[:5]}, not {ja} first")

        # Learning off, from a fresh install of today's app
        as_old(True)
        adb("uninstall", OLD_PKG, check=False)
        adb("install", main_apk, timeout=300)
        wait_for(
            "the old app to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)  # else its settings open on the setup screen
        learning = (("Privacy", "Learn from my typing"),)
        options, old_shown = set_old_options(*learning)
        print("the old app stored:\n" + options)
        adb(
            "shell", "ime", "set", IME
        )  # as above; a stopped app also gets no update broadcast
        adb("install", "-r", apk, timeout=300)
        as_old(False)
        if not ROOT:
            # The app's settings start it, as the update's broadcast does: the option moved shows off.
            new_shown = options_shown(SETTINGS, learning, tap=False)
            if old_shown != {learning[0]: False} or new_shown != old_shown:
                raise Fail(
                    f"learning off: the old app showed {old_shown}, the update {new_shown}"
                )
        else:
            # The update's broadcast or the keyboard's service starts the app, which moves the option as it
            # starts, before the keyboard can take a key. Android may deliver the broadcast many seconds after
            # the install on a busy emulator (#395): the wait is for the app, not for the file.
            wait_for(
                "the app to start after the update",
                lambda: adb("shell", "pidof", PKG, check=False).strip(),
                120,
            )
            try:
                wait_for(
                    "learning off in sebtype.conf",
                    lambda: re.search(
                        r"\[Learning\]\s*On=false",
                        root(f"cat {old}/files/sebtype.conf; true"),
                    ),
                    15,
                )
            except Fail:
                raise Fail(
                    f"learning off lost in the update: sebtype.conf has {root(f'cat {old}/files/sebtype.conf; true')!r}"
                )
        return (
            f"SebType still enabled and in use after the update; {zh}; {FUZZY_CODE} -> {fuzzy[:3]}; {JA_CODE} -> {got[:3]};"
            f" {EN_WORD[:5]} -> {en[:3]}; {SHORTCUT} -> {shortcut[:3]}; options kept; learning off kept"
        )
    finally:
        if ROOT:
            root(f"content delete --uri {WORDS} --where \"word='{SHORTCUT_PHRASE}'\"")
        as_old(False)
        adb("uninstall", OLD_PKG, check=False)
        # A fresh install for the checks after this one.
        adb("install", apk, timeout=300)
        wait_for(
            "the new keyboard to be listed",
            lambda: IME in adb("shell", "ime", "list", "-a", "-s"),
            30,
        )
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)


if main_apk:
    check("update-from-futo-app", update_from_futo_app)
elif WANTED is None or "update-from-futo-app" in WANTED:
    result(
        "SKIP",
        "update-from-futo-app",
        "needs MAIN_APK, the FUTO-based app's last release",
    )

adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
