#!/usr/bin/env python3
"""Settings checks on the emulator (#41), run by android/test/emulator.sh under the emulator lock after
chinese.py, which leaves SebType installed, chosen as the keyboard and Chinese set up.

    settings.py SERIAL RESULTS LOGDIR

Opens every settings screen from the home screen (one screenshot each, settings-<screen>.png in
LOGDIR), then checks that SebType's own options take effect while typing: the globe order, Chinese
full-width punctuation, emoji among Chinese candidates, Chinese "My words", and forgetting learned
words in Chinese, Japanese and English (which no save or restart brings back, #282); that Picnic is the only look, with no theme choice anywhere and the
same look in the system's dark mode (#111), its pink chip behind the first candidate and its pixel font
in key popups (#28, settings-picnic-*.png in LOGDIR), English's rows as far apart as Gboard's (#161). Last, that long lists (300 of My words, the credits) scroll smoothly
in their pixel-framed cards on the cloth (#87). Then, with the system switched to 日本語 and back to en-US after,
that every screen shows no English SebType string (#120, settings-ja-*.png in LOGDIR). Then incognito (#31):
password and private fields and the sticky toggle learn nothing in English, 中文 and 日本語 and keep no
clipboard copy, but still offer what was learned before; the toggle survives a restart, and turned off,
learning resumes. Then sync with a local sync-server (#12, made-up login and words): the connection check's
connected and wrong-password states on Sync & backup and in its login dialog (#452), offline a learned
word stays on the phone, back online a keyboard hide uploads it, a word in another device's folder on
the server is offered after a sync, so are made-up Japanese and English personal words (#14), whose
phone-side counterparts reach the phone's folder, a conversion picked in 日本語 reaches the server and another
device's picked one comes first on the phone (#409), a crash's report reaches the server's crash folder
without typed words or the login (#33), the login is in no log or plain file, and the delete button
empties the server. Then that made-up personal data of each kind imports through the backup
screen's Import and is offered as candidates (#11): a Rime word list and Rime learned words in 中文,
Mozc and MS-IME dictionaries in 日本語, the phone's personal dictionary (userdictionary.json) in English. Last, that a settings
backup leaves clipboard history out unless its box is ticked, and that importing restores it (#34), and that a backup whose 中文 fails to start leaves the phone's Rime files (#282),
with the backup screen's screenshot in English and Japanese (settings-backup-<locale>.png). Labels
match the emulator's Chinese, English or Japanese UI. One line per check appended to RESULTS; each
check finds its own way from the home screen, so one failing doesn't stop the next.
"""

import ast
import functools
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

serial, results_path, logdir = sys.argv[1:4]
# Only the checks whose names start with one of SEBTYPE_CHECKS (comma-separated, as emulator.sh takes it).
CHECKS = [c for c in os.environ.get("SEBTYPE_CHECKS", "").split(",") if c]
# Timing checks run only in the final performance run (#54, Decisions #2 2026-11-11): PERF_RUN=1.
# SEBTYPE_REPEAT=N runs each check SEBTYPE_CHECKS names (not those it needs) N times, a line per run:
# for a check that fails only now and then (#258).
REPEAT = int(os.environ.get("SEBTYPE_REPEAT") or 1)
TIMING = {"settings-smooth-scrolling"}
PKG = "dev.sebb.sebtype"
# The keyboard keeps the FUTO-based app's service name, so an update from it stays selected (#262).
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
FRAME_ID = f"{PKG}:id/keyboard"
SETTINGS = f"{PKG}/.settings.SettingsActivity"
IMPORT_ACTIVITY = "settings.ImportActivity"
BACKUP_FILES = "SebTypeSettings_*.backup"
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
PREPARING = ("正在准备中文", "Preparing Chinese")
NOT_CANDIDATES = (*PREPARING, "中文输入启动失败", "Chinese input failed")
log_path = os.path.join(logdir, "test-settings.log")
# Seconds for the keyboard to come up. It restarts often here, and while the other emulator runs a
# suite (#103) a restart has taken over 30 s; how fast it comes up is perf.sh's to measure.
KEYBOARD_WAIT = 60


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


def result(status, name, detail=""):
    line = f"{status} {name}" + (f": {detail}" if detail else "")
    print(line, flush=True)
    with open(results_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


class Fail(Exception):
    pass


class Skip(Exception):
    pass


class SebTypeFault(Exception):
    """SebType started, crashed or hung where it should have come up: not a Fail, so no retry hides it."""


def wait_for(what, fn, timeout, interval=1.0):
    end = time.time() + timeout
    while True:
        value = fn()
        if value:
            return value
        if time.time() > end:
            raise Fail(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


# --- The keyboard (as in chinese.py) ---

keyboard_frame = None
BAR_CONTROLS = (
    set()
)  # the suggestion bar's own buttons, filled in with their labels below


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


def letter_keys(left, top, right, bottom):
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
    # The keyboard labels its letters as shown, in capitals while Shift is on.
    return {
        label.lower(): (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-zA-Z]", label)
    }


def bottom_key(column):
    """A bottom-row key by its centre, in tenths of the keyboard's width: the globe sits at 3, the
    Chinese layout's 。 key at 8 (symbols 1.5, ， 1, globe 1, space 4, 。 1, enter 1.5)."""
    left, top, right, bottom = keyboard_frame
    tap(int(left + column * (right - left) / 10), int(top + 3.5 * (bottom - top) / 4))


def candidate_spots(ns):
    """(x, y, label) of the Chinese or Japanese candidates, left to right."""
    k = keys(ns)
    if "q" not in k:
        return []
    row = (k["q"][2] - 130, k["q"][2])
    return sorted(
        (x, y, label)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1]
        and cls == "android.widget.TextView"
        and label
        and not label.startswith(NOT_CANDIDATES)
        and label not in ("あ", "ア")
    )


def candidates(ns):
    return [label for x, y, label in candidate_spots(ns)]


def en_spots(ns):
    """(x, y, label) of English's suggestions, left to right: the bar's labelled nodes of any class, but its buttons."""
    k = keys(ns)
    if "q" not in k:
        return []
    row = (k["q"][2] - 130, k["q"][2])
    controls = {"あ", "ア", *BAR_CONTROLS}
    return sorted(
        {
            (x, y, label)
            for label, x, y, top, cls in ns
            if row[0] < y < row[1] and label and label not in controls
        }
    )


def en_candidates(ns):
    return [label for x, y, label in en_spots(ns)]


def expanded_candidates():
    ns = nodes()
    k = keys(ns)
    row = (k["q"][2] - 130, k["q"][2])
    button = max(
        (x, y)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1]
        and cls == "android.widget.Button"
        and label in MORE_CANDIDATES
    )
    tap(*button)
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
        tap(k[ch][0], k[ch][1])
    time.sleep(1.5)
    settle()


def settle(seconds=30):
    """The keyboard's keys show when its engine thread answers (#241), which on the emulator can
    take a second a key in English: waits until the field stops changing."""
    last, end = None, time.time() + seconds
    while time.time() < end:
        if (text := field_text()) == last:
            return
        last = text
        time.sleep(1)


# In the system log: SebType's process starting, crashing (Java or native) or not responding.
SEBTYPE_LIFE = re.compile(
    r"Start proc \d+:dev\.sebb\.sebtype/|Process: dev\.sebb\.sebtype, PID"
    r"|>>> dev\.sebb\.sebtype <<<|ANR in dev\.sebb\.sebtype(?![.\w])"
)
LOGCAT_TIME = re.compile(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}")


def logcat_time(date_out):
    """`date '+%Y-%m-%d %H:%M:%S.%N'` on the device -> what `logcat -T` reads as a time (a bare number
    it reads as a line count). With the year: without one logcat takes this year's, so a field opened
    on 31 December would be a time in the future after midnight."""
    t = date_out.strip()[:23]
    if not LOGCAT_TIME.fullmatch(t):
        raise ValueError(
            f"device time {date_out.strip()!r} isn't YYYY-MM-DD hh:mm:ss.nnn"
        )
    return t


recoveries = []  # the logcat file of each restart_unstarted recovery, for check()'s WARN
current_check = ""


def choose_sebtype():
    """SebType the keyboard again, with one retry."""
    for _ in range(2):
        try:
            adb("shell", "ime", "set", IME, check=False)
            got = adb("shell", "settings", "get", "secure", "default_input_method")
            if got.strip() == IME:
                return
        except (RuntimeError, subprocess.SubprocessError):
            pass
    raise Fail(
        "SebType isn't the keyboard again after switching through another one (#352)"
    )


def restart_unstarted(since):
    """SebType is chosen but has no process, the field open 10 s. After a force-stop Android can
    leave it so, and `ime set` to the same keyboard changes nothing (#352): another keyboard and back
    starts it. If SebType started, crashed or hung since the field opened (device time `since`) the
    fault is SebType's: fail with that instead. Each recovery is a WARN on the check's line."""
    log = adb("logcat", "-d", "-T", since, check=False)
    seen = [line for line in log.splitlines() if SEBTYPE_LIFE.search(line)]
    if seen:
        raise SebTypeFault(
            f"SebType isn't up or running, and since the field opened: {' | '.join(seen[-3:])}"
        )
    path = os.path.join(
        logdir, f"{current_check}-recovery-{len(recoveries) + 1}.logcat"
    )
    with open(path, "w") as f:
        f.write(log)
    other = [i for i in adb("shell", "ime", "list", "-s").split() if i != IME]
    if not other:
        raise Fail(
            "SebType chosen but never started since the field opened, and no other keyboard to"
            f" switch through (logcat in {path})"
        )
    recoveries.append(path)
    try:
        adb("shell", "ime", "set", other[0])
    except (RuntimeError, subprocess.SubprocessError) as e:
        try:
            choose_sebtype()
        except Fail as restore:
            raise Fail(f"switching to {other[0]}: {e}; then {restore}") from e
        raise
    choose_sebtype()


def open_field(kind=None, clip=None):
    """A new text field with SebType up; kind makes it a password or private field, clip a text the
    field app copies to the clipboard a moment after it opens (android/perf/PerfField.java)."""
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    extra = (["--es", "kind", kind] if kind else []) + (
        ["--es", "clip", clip] if clip else []
    )

    since = logcat_time(adb("shell", "date '+%Y-%m-%d %H:%M:%S.%N'"))
    shown = 0.0

    def show():
        nonlocal shown
        shown = time.time()
        adb("shell", "ime", "set", IME)
        # A slow emulator can show "System UI isn't responding" over everything; this closes it.
        adb(
            "shell",
            "am",
            "broadcast",
            "-a",
            "android.intent.action.CLOSE_SYSTEM_DIALOGS",
        )
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
        ks = keys(nodes())
        if (
            not ks
            and time.time() - shown > 10
            and not adb("shell", "pidof", PKG, check=False).strip()
        ):
            restart_unstarted(since)
            show()
        return ks

    show()
    wait_for("the keyboard", up, KEYBOARD_WAIT)


def candidates_for(text, expand=False, kind=None):
    open_field(kind)
    type_keys(text)
    got = wait_for(f"candidates for {text}", lambda: candidates(nodes()), 60)
    if expand:
        got += [c for c in expanded_candidates() if c not in got]
    return got


def field_text():
    return next((n[0] for n in nodes() if n[4] == "android.widget.EditText"), "")


def tap_candidate(word):
    for label, x, y, top, cls in nodes():
        if label == word:
            tap(x, y)
            time.sleep(1.5)
            return
    raise Fail(f"{word} not in the candidate bar")


def to_language(probe, word):
    """Cycles the globe until typing probe offers word (中: ni -> 你, 日: nihongo -> 日本語, English:
    hello -> Hello, capitalised at the field's start, with no Chinese or Japanese among the candidates,
    as 中 and 日 offer hello among their own words)."""
    for _ in range(8):
        try:
            open_field()
            type_keys(probe)
            # Chinese sets itself up the first time it comes up, showing its notice meanwhile.
            end = time.time() + 300
            # A language that has just come up can take a moment before its first candidates.
            first = time.time() + 15
            while True:
                ns = nodes()
                if (
                    probe == "hello"
                ):  # today's English words aren't TextViews: en_candidates
                    got = en_candidates(ns)
                    english = not any(
                        re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", c) for c in got
                    )
                else:
                    got, english = candidates(ns), True
                if english and word in [c.lower() for c in got]:
                    return
                preparing = any(n[0].startswith(PREPARING) for n in ns)
                waiting = preparing or (not got and time.time() < first)
                if not waiting or time.time() > end:
                    break
                time.sleep(3)
            open_field()
            bottom_key(3)
            time.sleep(2)
        except Fail:
            # Mozc can crash when Japanese starts on the emulator (#35); a restart brings it back.
            adb("shell", "am", "force-stop", PKG)
    raise Fail(f"no language offers {word} for {probe}")


# --- The settings app ---


def labels(*texts):
    return texts


HOME = {
    "languages": labels("语言", "Languages", "言語"),
    "keyboard": labels("键盘", "Keyboard", "キーボード"),
    "privacy": labels("隐私", "Privacy", "プライバシー"),
    "backup": labels("同步与备份", "Sync & backup", "同期とバックアップ"),
    "about": labels("关于", "About", "情報"),
}
MY_WORDS = labels("我的词语", "My words", "自分の単語")
FULL_WIDTH = labels("全角标点", "Full-width punctuation")
EMOJI = labels("候选词中显示表情", "Emoji in candidates")
TIPS = labels("提示", "Tips", "ヒント")
TIPS_SPACE = labels(
    "在空格键上左右滑动可移动光标。",
    "Slide the space bar to move the cursor.",
    "スペースキーを左右にスライドすると、カーソルが動きます。",
)


def screen_contains(texts):
    return any(t in label for label, *_ in nodes() for t in texts)


def find_all(ns, texts):
    return sorted(
        (
            (y, x)
            for label, x, y, top, cls in ns
            if any(
                label == t or label.startswith((t + ".", t + ",", t + "\n"))
                for t in texts
            )
        )
    )


def screen_has(texts):
    return bool(find_all(nodes(), texts))


def tap_text(texts, nth=0):
    """Taps the nth node (top to bottom) showing one of texts, scrolling down until it shows."""
    for _ in range(6):
        found = find_all(nodes(), texts)
        if len(found) > nth:
            y, x = found[nth]
            tap(x, y)
            time.sleep(1.5)
            return
        adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
        time.sleep(1)
    raise Fail(f"no {texts[0]} on the screen")


def open_settings():
    # A new task each time, so it opens on the home screen. Without SebType chosen as the keyboard
    # the app opens on its setup screen instead.
    adb("shell", "ime", "set", IME)
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", SETTINGS)
    wait_for("the settings home screen", home_shown, 30)


def home_shown():
    if screen_has(HOME["about"]):
        return True
    # A fresh install opens on setup until its last step's Done (#285, #435, #444), which a user presses once
    step = setup_step_shown()
    if step == 3:
        tap_text(CONTINUE)
        return False
    if step == 4:
        tap_text(SKIP_SYNC if screen_has(SKIP_SYNC) else CONTINUE)
        return False
    if step == 5:
        tap_text(DONE)
        return False
    # Just after SebType restarts the system can fall back to another keyboard; choosing SebType again
    # takes the setup screen on to the home screen.
    adb("shell", "ime", "set", IME)
    return False


def go(*path):
    """From a fresh home screen, follows path: label tuples, or (labels, nth) for a repeated one."""
    open_settings()
    for step in path:
        texts, nth = step if isinstance(step[1], int) else (step, 0)
        tap_text(texts, nth)


def screenshot(name):
    adb("shell", "screencap -p /sdcard/sebtype-shot.png")
    adb(
        "pull", "/sdcard/sebtype-shot.png", os.path.join(logdir, f"settings-{name}.png")
    )


def toggle(path, texts):
    go(*path)
    tap_text(texts)


def dependency_checks():
    """The checks the ones SEBTYPE_CHECKS names need besides themselves, from their `needs=`."""
    needs = {}
    with open(__file__, encoding="utf-8") as f:
        for node in ast.walk(ast.parse(f.read())):
            if (
                isinstance(node, ast.Call)
                and getattr(node.func, "id", "") == "check"
                and isinstance(node.args[0], ast.Constant)
            ):
                kw = {k.arg: k.value for k in node.keywords}
                needs[node.args[0].value] = (
                    [e.value for e in kw["needs"].elts] if "needs" in kw else []
                )
    named = {n for n in needs if any(n.startswith(c) for c in CHECKS)}
    todo = list(named)
    run = set()
    while todo:
        n = todo.pop()
        if n not in run:
            run.add(n)
            todo += needs[n]
    return run - named


NEEDED = dependency_checks() if CHECKS else set()
passed = set()


def check(name, fn, needs=()):
    # A named run of settings-japanese leaves the system in 日本語, and the file picker's labels the
    # checks after it read (Downloads, Show roots) are English: settings-locale-back always runs.
    if (
        CHECKS
        and not any(name.startswith(c) for c in CHECKS)
        and name not in NEEDED
        and name != "settings-locale-back"
    ):
        return
    missing = [n for n in needs if n not in passed]
    if missing:
        result("SKIP", name, f"needs {', '.join(missing)}")
        return
    if name in TIMING and not os.environ.get("PERF_RUN"):
        if CHECKS:  # named, so say why it didn't run
            result("SKIP", name, "timing check, runs only with PERF_RUN=1 (#54)")
        return
    global current_check
    current_check = name
    runs = REPEAT if any(name.startswith(c) for c in CHECKS) else 1
    for run in range(1, runs + 1):
        first = len(recoveries)

        def warned(detail):
            new = recoveries[first:]
            return detail + (
                f" WARN: Android started SebType only after another keyboard and back, {len(new)}x"
                f" (#352; {', '.join(os.path.basename(p) for p in new)})"
                if new
                else ""
            )

        of = f" (run {run}/{runs})" if runs > 1 else ""
        try:
            detail = fn()
            passed.add(name)
            result("PASS", name, warned((detail or "") + of))
        except Skip as e:
            result("SKIP", name, warned(str(e) + of))
        except (
            Fail,
            SebTypeFault,
            RuntimeError,
            subprocess.SubprocessError,
            ET.ParseError,
            LookupError,
            ValueError,
        ) as e:
            result("FAIL", name, warned(str(e) + of))
            # The system log, for what the keyboard was doing (a keyboard that never came up shows why here).
            suffix = f"-{run}" if runs > 1 else ""
            with open(os.path.join(logdir, f"{name}{suffix}.logcat"), "w") as f:
                f.write(adb("logcat", "-d", check=False))


# Every screen: how to get there from home, and a text only it shows.
LANG = HOME["languages"]
SCREENS = [
    ("home", (), labels("同步与备份", "Sync & backup", "同期とバックアップ")),
    ("languages", (LANG,), labels("地球键顺序", "Globe order", "地球キーの順番")),
    (
        "en-words",
        (LANG, (MY_WORDS, 0)),
        labels("添加", '"添加"', "Add", "Words", "词语", '"追加"', "追加", "単語"),
    ),
    (
        "zh-fuzzy",
        (LANG, labels("Fuzzy Pinyin", "模糊拼音", "あいまいピンイン")),
        labels("zh=z", "zh = z", "z=zh", "z = zh", "zh, ch, sh"),
    ),
    (
        "zh-words",
        (LANG, (MY_WORDS, 1)),
        labels("还没有词语", "No words yet", "単語はまだありません"),
    ),
    (
        "ja-words",
        (LANG, (MY_WORDS, 2)),
        labels("添加", '"添加"', "Add", "Words", "词语", '"追加"', "追加", "単語"),
    ),
    (
        "keyboard",
        (HOME["keyboard"],),
        labels("显示数字行", "Show number row", "数字行を表示"),
    ),
    (
        "resize",
        (HOME["keyboard"], labels("尺寸和位置", "Size and position", "サイズと位置")),
        labels(
            "调整键盘大小",
            "Resize Keyboard",
            "キーボードサイズ調整",
            "キーボードのサイズ変更",
        ),
    ),
    (
        "privacy",
        (HOME["privacy"],),
        labels("从我的输入中学习", "Learn from my typing", "入力から学習"),
    ),
    (
        "forget",
        (
            HOME["privacy"],
            labels("忘记学到的词", "Forget learned words", "学習した単語を消去"),
        ),
        labels("忘记", "Forget", "消去"),
    ),
    (
        "backup",
        (HOME["backup"],),
        labels("导出设置", "Export settings", "設定をエクスポート"),
    ),
    ("about", (HOME["about"],), labels("版本", "Version", "バージョン")),
    ("tips", (HOME["about"], TIPS), TIPS_SPACE),
    (
        "credits",
        (
            HOME["about"],
            labels("许可与致谢", "Licence and credits", "ライセンスとクレジット"),
        ),
        labels("Credits", "致谢", "クレジット"),
    ),
    (
        "licence",
        (
            HOME["about"],
            labels("许可与致谢", "Licence and credits", "ライセンスとクレジット"),
            (("Mozc",), 0),
        ),
        ("Mozc-LICENSE.txt",),
    ),
]


def every_screen():
    opened = []
    failed = []
    for name, path, marker in SCREENS:
        try:
            go(*path)
            wait_for(
                f"{name} ({marker[0]})", lambda marker=marker: screen_has(marker), 10
            )
            screenshot(name)
            opened.append(name)
        except Fail as e:
            screenshot(name)
            failed.append(f"{name}: {e}")
    if failed:
        raise Fail("; ".join(failed))
    return f"{len(opened)} screens: {', '.join(opened)}"


def home_order():
    open_settings()
    return next(
        (
            label
            for label, *_ in nodes()
            if re.search(r"EN|中|日", label) and "→" in label
        ),
        "",
    )


def drag_globe_row(src, dst):
    """Drags language row src's handle onto row dst's place (rows 0..2 in the globe order list)."""
    go(LANG)
    rows = find_all(nodes(), labels("拖动以排序", "Drag to reorder"))
    if len(rows) < 3:
        raise Fail(f"{len(rows)} drag handles on the languages screen")
    (y1, _), (y2, _) = rows[src], rows[dst]
    # The handle's label merges into its row's, so this node is the row; the handle is its icon, in
    # the first tenth of the screen's width.
    width = int(re.search(r"(\d+)x\d+", adb("shell", "wm", "size")).group(1))
    x = width // 10
    adb(
        "shell",
        "input",
        "swipe",
        str(x),
        str(y1),
        str(x),
        str(y2 + (8 if y2 > y1 else -8)),
        "1500",
    )
    time.sleep(1.5)


def globe_order():
    before = home_order()
    drag_globe_row(2, 1)
    after = home_order()
    drag_globe_row(2, 1)
    restored = home_order()
    if not before or after == before or restored != before:
        raise Fail(
            f"home summary {before!r}, after dragging 日 up {after!r}, after dragging back {restored!r}"
        )
    return f"{before} -> {after} -> {restored}"


def punctuation_typed():
    open_field()
    bottom_key(8)
    time.sleep(1.5)
    return field_text()


def full_width_punctuation():
    to_language("ni", "你")
    on = punctuation_typed()
    toggle((LANG,), FULL_WIDTH)
    to_language("ni", "你")
    off = punctuation_typed()
    toggle((LANG,), FULL_WIDTH)
    to_language("ni", "你")
    again = punctuation_typed()
    if (on, off, again) != ("。", ".", "。"):
        raise Fail(f"the 。 key typed {on!r} on, {off!r} off, {again!r} on again")
    return "the 。 key types 。 with it on, . with it off"


def is_emoji(text):
    return any(0x1F300 <= ord(c) <= 0x1FAFF or 0x2600 <= ord(c) <= 0x27BF for c in text)


def emoji_candidates():
    to_language("ni", "你")
    on = [c for c in candidates_for("xiao", expand=True) if is_emoji(c)]
    toggle((LANG,), EMOJI)
    to_language("ni", "你")
    off = [c for c in candidates_for("xiao", expand=True) if is_emoji(c)]
    toggle((LANG,), EMOJI)
    if not on or off:
        raise Fail(f"emoji for xiao: {on} on, {off} off")
    return f"xiao offers {on[:3]} with it on, none off"


@functools.cache
def install_set_text():
    """Builds and installs android/test/set-text, once per run (run from the repo root)."""
    apk = os.path.join(logdir, "set-text.apk")
    subprocess.run(
        ["android/test/set-text/build.sh", apk], check=True, capture_output=True
    )
    adb("install", "-r", apk)


def set_text(index, text):
    """Sets the active window's index-th text field through accessibility, with no keyboard."""
    install_set_text()
    out = adb(
        "shell",
        "am",
        "instrument",
        "-w",
        "-e",
        "index",
        str(index),
        "-e",
        "text",
        text,
        "dev.sebb.sebtype.settext/.SetText",
    )
    if "result=set" not in out:
        raise Fail(f"couldn't set field {index} to {text}: {out.strip()[-300:]}")


def add_my_word(word, pinyin):
    go(LANG, (MY_WORDS, 1))
    tap_text(labels("添加", '"添加"', "Add"))
    set_text(0, word)
    set_text(1, pinyin)
    tap_text(labels("保存", "Save"))


def my_words():
    to_language("ni", "你")
    add_my_word("sebword", "qqzz")
    first = candidates_for("qqzz")[:3]
    go(LANG, (MY_WORDS, 1))
    tap_text(labels("sebword"))
    tap_text(labels("删除", "Delete"))
    time.sleep(2)
    gone = candidates_for("qqzz")[:3]
    if not first or first[0] != "sebword" or "sebword" in gone:
        raise Fail(f"qqzz -> {first} with the word added, {gone} after deleting it")
    return f"qqzz -> {first} with sebword added, {gone} after deleting it"


def forget(language):
    go(
        HOME["privacy"],
        labels("忘记学到的词", "Forget learned words", "学習した単語を消去"),
    )
    tap_text(language)
    found = find_all(nodes(), labels("忘记", "Forget", "消去"))
    y, x = found[-1]  # the dialog's button, below the dialog title
    tap(x, y)
    time.sleep(3)


def forget_chinese():
    to_language("ni", "你")
    # 灵魂, not 厉害: the Chinese model puts 厉害 first unlearned (#369).
    got = candidates_for("lh", expand=True)
    if got[0] != "灵魂":
        tap_candidate("灵魂")
    learned = candidates_for("lh")[:3]
    forget(labels("中文"))
    after = candidates_for("lh")[:3]
    if learned[0] != "灵魂" or after[0] == "灵魂":
        raise Fail(f"lh -> {learned} learned, {after} after forgetting")
    return f"lh -> {learned} learned, {after} after forgetting 中文"


def forget_japanese():
    to_language("nihongo", "日本語")
    fresh = candidates_for("kaku")
    pick = fresh[1]
    tap_candidate(pick)
    learned = candidates_for("kaku")[:3]
    forget(labels("日本語"))
    to_language("nihongo", "日本語")
    after = candidates_for("kaku")[:3]
    if learned[0] != pick or after[0] != fresh[0]:
        raise Fail(
            f"kaku -> {fresh[:3]}, {learned} after picking {pick}, {after} after forgetting"
        )
    return f"kaku -> {fresh[:3]}, {learned} after picking {pick}, {after} after forgetting 日本語"


def forget_english():
    """The keyboard forgets through English's running engine (#282): the word is gone at once, and
    neither the engine's save as the field closes nor a restart that reads its files brings it back."""
    word = "zorbleq"  # made up, so only learning can offer it
    to_language("hello", "hello")
    open_field()
    commit_twice(word)
    learned = suggested_after(word)
    forget(labels("English"))
    after = suggested_after(word)
    open_field()  # the field before closes: English saves
    adb("shell", "am", "force-stop", PKG)
    restarted = suggested_after(word)
    detail = f"zorbl -> {learned[:4]} learned, {after[:4]} after forgetting English, {restarted[:4]} after a restart"
    if word not in learned or word in after or word in restarted:
        raise Fail(detail)
    return detail


WORDS_FILE = f"/data/data/{PKG}/files/rime/user/custom_phrase.txt"
# Most janky %, slowest p90 (ms) per list, from the plain one-colour look on guide35, which renders
# in software (2026-11-10): My words 1.6 %, 16 ms; credits, laid out whole, 30-39 %, 48-57 ms. The
# limits leave room for the cloth and frames, not for a drawing cost per row: a rect per dash in
# the dividers made My words 27.5 %, 53 ms. System Settings is 53-70 % janky on this emulator.
SMOOTH_LIMITS = {"zh-words-300": (10, 45), "credits": (45, 70)}


def root(cmd):
    return adb("shell", f"su 0 sh -c '{cmd}'")


def fling_stats(name, path):
    """Opens path, flings down through it, and returns the app's frame stats for the flings."""
    go(*path)
    size = re.search(r"(\d+)x(\d+)", adb("shell", "wm", "size"))
    w, h = int(size[1]), int(size[2])
    adb("shell", "dumpsys", "gfxinfo", PKG, "reset")
    for _ in range(8):
        adb(
            "shell",
            "input",
            "swipe",
            str(w // 2),
            str(h * 4 // 5),
            str(w // 2),
            str(h // 5),
            "150",
        )
        time.sleep(1)
    info = adb("shell", "dumpsys", "gfxinfo", PKG)
    frames = int(re.search(r"Total frames rendered: (\d+)", info)[1])
    janky = float(re.search(r"Janky frames: \d+ \(([\d.]+)%\)", info)[1])
    p90 = int(re.search(r"90th percentile: (\d+)ms", info)[1])
    screenshot(f"{name}-scrolled")
    return name, frames, janky, p90


def smooth(name, frames, janky, p90):
    return (
        frames >= 30
        and janky <= SMOOTH_LIMITS[name][0]
        and p90 <= SMOOTH_LIMITS[name][1]
    )


def best_flings(name, path):
    """Up to three tries, the least janky kept: frame times follow the PC's load, which the other
    emulator's suite raises (#103). A drawing cost per row fails every try."""
    tries = []
    while len(tries) < 3 and not (tries and smooth(*tries[-1])):
        tries.append(fling_stats(name, path))
    return min(tries, key=lambda t: t[2]) + (len(tries),)


def other_emulator_busy():
    """Whether another emulator's lock is held (#103): a suite running there slows this one's frames."""
    me = adb("emu", "avd", "name").splitlines()[0].strip()
    return any(
        subprocess.run(["flock", "-n", lock, "true"], check=False).returncode != 0
        for lock in glob.glob("/tmp/agent-locks/devices/emulator-*.lock")
        if os.path.basename(lock) != f"emulator-{me}.lock"
    )


def smooth_scrolling():
    # 300 of My words, which it reads after its marker; the file goes back as it was afterwards.
    local = os.path.join(logdir, "my-words-300.txt")
    with open(local, "w", encoding="utf-8") as f:
        f.write(
            "# SebType: My words\n"
            + "".join(f"测试词{i}\tceshici{i}\n" for i in range(300))
        )
    adb("push", local, "/data/local/tmp/sebtype-words.txt")
    had = root(f"test -f {WORDS_FILE} && echo yes || true").strip() == "yes"
    if had:
        root(f"cp -p {WORDS_FILE} {WORDS_FILE}.bak")
    owner = root(f"stat -c %u:%g /data/data/{PKG}/files").strip()
    try:
        root(
            f"mkdir -p $(dirname {WORDS_FILE}) && cp /data/local/tmp/sebtype-words.txt {WORDS_FILE} && chown -R {owner} $(dirname {WORDS_FILE}) && restorecon -R $(dirname {WORDS_FILE})"
        )
        stats = [
            best_flings("zh-words-300", (LANG, (MY_WORDS, 1))),
            best_flings(
                "credits",
                (
                    HOME["about"],
                    labels(
                        "许可与致谢", "Licence and credits", "ライセンスとクレジット"
                    ),
                ),
            ),
        ]
    finally:
        root(f"mv {WORDS_FILE}.bak {WORDS_FILE}" if had else f"rm -f {WORDS_FILE}")
    summary = ", ".join(
        f"{n}: {f} frames, {j}% janky, p90 {p} ms"
        + (f" (best of {t})" if t > 1 else "")
        for n, f, j, p, t in stats
    )
    if not all(smooth(*s[:4]) for s in stats):
        # The limits hold on a quiet PC; a drawing regression shows in the next run without company.
        if other_emulator_busy():
            raise Skip(f"too slow while another emulator ran a test: {summary}")
        raise Fail(summary)
    return summary


THEME = labels("主题", "Theme")


def nothing_shows(texts, swipes):
    """Fails if any of texts shows on the screen, scrolling down swipes times."""
    for _ in range(swipes + 1):
        found = [label for label, *_ in nodes() if label in texts]
        if found:
            raise Fail(f"{found[0]!r} on the screen")
        adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
        time.sleep(1)


def no_theme_choice():
    open_settings()
    nothing_shows(THEME, 2)
    return "no Theme group on the home screen"


# Picnic's own colours (theme/Picnic.kt): the cloth's two, the cream keys and cards, their lines, pink.
PICNIC = [
    (0xFB, 0xE9, 0xD6),
    (0xF8, 0xE2, 0xCC),
    (0xFF, 0xF7, 0xE8),
    (0xEC, 0xD0, 0xAE),
    (0xFD, 0xE0, 0xE6),
]


def picnic_share(box=None, colours=PICNIC):
    """The share of the screen (or of box, x1 y1 x2 y2) in Picnic's colours (or colours), from a raw screencap."""
    raw = subprocess.run(
        ["adb", "-s", serial, "exec-out", "screencap"],
        capture_output=True,
        timeout=60,
        check=True,
    ).stdout
    w, h = int.from_bytes(raw[0:4], "little"), int.from_bytes(raw[4:8], "little")
    pixels = raw[len(raw) - w * h * 4 :]
    x1, y1, x2, y2 = box or (0, 0, w, h)
    near = total = 0
    for y in range(y1, y2, 12):
        for x in range(x1, x2, 12):
            i = (y * w + x) * 4
            r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
            total += 1
            # 12 covers the cloth's RGB_565 rounding.
            near += any(
                abs(r - pr) + abs(g - pg) + abs(b - pb) <= 12 for pr, pg, pb in colours
            )
    return near / total


def dark_mode_picnic():
    adb("shell", "cmd", "uimode", "night", "yes")
    try:
        time.sleep(2)
        adb("shell", "am", "force-stop", PKG)
        open_settings()
        time.sleep(1)
        screenshot("dark-home")
        home = picnic_share()
        # Chinese, not Japanese: Mozc can crash when it starts on the emulator (#35).
        to_language("ni", "你")
        open_field()
        time.sleep(1)
        screenshot("dark-keyboard")
        keyboard = picnic_share(keyboard_frame)
    finally:
        adb("shell", "cmd", "uimode", "night", "no")
    summary = f"in dark mode {home:.0%} of the settings home and {keyboard:.0%} of the keyboard in Picnic's colours"
    # Picnic measured 92 % on the home screen and 73 % on the keyboard (guide35, 2026-11-11); a dark
    # theme is near 0.
    if home < 0.4 or keyboard < 0.4:
        raise Fail(summary)
    return summary


def chip_share(x, y):
    """Picnic pink's share round a candidate's centre: high when its chip is behind it (#28)."""
    return picnic_share((x - 40, y - 24, x + 40, y + 24), [PICNIC[4]])


def hold_shot(key, name, wait):
    """Holds key down for wait seconds, saves a screenshot (settings-<name>.png), lets go. In one shell
    command, so a wait of 0 catches the press preview before the long-press menu opens."""
    x, y, _ = keys(nodes())[key]
    adb(
        "shell",
        f"input motionevent DOWN {x} {y}; sleep {wait}; screencap -p /sdcard/sebtype-shot.png;"
        f" input motionevent UP {x} {y}",
    )
    adb(
        "pull", "/sdcard/sebtype-shot.png", os.path.join(logdir, f"settings-{name}.png")
    )


def picnic_look():
    """Picnic's pink chip behind the first candidate, and the pixel font in key popups (#28): the
    chip is measured in Chinese; English's chip and the popups' font are for the eye, in the screenshots."""
    to_language("ni", "你")
    spots = candidate_spots(nodes())
    shares = [chip_share(x, y) for x, y, _ in spots[:2]]
    screenshot("picnic-candidates-zh")
    hold_shot("h", "picnic-press-preview", 0)
    hold_shot("e", "picnic-long-press", 1.5)
    summary = f"Chinese first candidate {shares[0]:.0%} pink, second {shares[1]:.0%}"
    # The chip's fill covers most of the box round the word; the cloth has no pink.
    if shares[0] < 0.3 or shares[1] > 0.05:
        raise Fail(summary)
    try:  # only for the screenshot: the switch to English can be slow on a busy PC
        to_language("hello", "hello")
        shares = [chip_share(x, y) for x, y, _ in en_spots(nodes())]
        screenshot("picnic-candidates-en")
        english = "English " + ", ".join(f"{s:.0%}" for s in shares) + " pink"
    except Fail as e:
        english = f"no English screenshot: {e}"
    return f"{summary}; {english}; screenshots settings-picnic-*.png"


def gboard_size():
    """English's rows as far apart as Gboard's (#161): 155 px on guide35's 420 dpi screen, so 59 dp;
    the rest of the match (key frames, letter size) is for the eye, in settings-picnic-size-en.png."""
    to_language("hello", "hello")
    k = keys(nodes())
    density = int(re.search(r"(\d+)\s*$", adb("shell", "wm", "density")).group(1)) / 160
    pitches = [(k[b][2] - k[a][2]) / density for a, b in (("q", "a"), ("a", "z"))]
    screenshot("picnic-size-en")
    summary = "rows " + ", ".join(f"{p:.1f}" for p in pitches) + " dp apart (Gboard 59)"
    if any(abs(p - 59) > 1 for p in pitches):
        raise Fail(summary)
    return summary


NAV_OVERLAYS = {
    "3-button": "com.android.internal.systemui.navbar.threebutton",
    "gesture": "com.android.internal.systemui.navbar.gestural",
}


def nav_bar():
    """The navigation bar's frame (left, top, right, bottom) as the system lays it out now, or None."""
    frames = [
        tuple(map(int, m.groups()))
        for m in re.finditer(
            r"type=navigationBars frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\] visible=true",
            adb("shell", "dumpsys", "window"),
        )
    ]
    return max(frames, key=lambda f: (f[2] - f[0]) * (f[3] - f[1]), default=None)


def keys_clear_of_nav_bar(step):
    """The keys, their bottom row included, don't reach into the navigation bar; '' or what overlaps."""
    wait_for("the keyboard", lambda: keys(nodes()), KEYBOARD_WAIT)
    time.sleep(1)  # the window's show animation and any later inset change settle
    nodes()
    l, t, r, b = keyboard_frame
    bar = nav_bar()
    if bar and l < bar[2] and bar[0] < r and t < bar[3] and bar[1] < b:
        screenshot(f"nav-bar-{step.replace(' ', '-')}")
        return f"{step}: keys {keyboard_frame} reach into the navigation bar {bar}"
    return ""


def nav_bar_clear():
    """The keyboard sits above the navigation bar (#472) with 3-button and gesture navigation: when it
    first shows, after a turn to landscape and back, after switching apps and back, when it is hidden
    and shown again and in a full-screen app, five times over (it went under the bar only now and then)."""
    overlays = adb("shell", "cmd", "overlay", "list")
    before = next(
        (
            o
            for o in NAV_OVERLAYS.values()
            if re.search(rf"\[x\] {re.escape(o)}$", overlays, re.MULTILINE)
        ),
        None,
    )
    if not before:
        raise Skip(
            "neither 3-button nor gesture navigation is on, which this can't put back"
        )
    rotation = {
        k: adb("shell", "settings", "get", "system", k).strip()
        for k in ("user_rotation", "accelerometer_rotation")
    }

    def turn(quarter):
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        adb("shell", "settings", "put", "system", "user_rotation", str(quarter))
        time.sleep(3)

    def field_again():
        adb("shell", "am", "start", "-n", FIELD)
        time.sleep(1)
        if not keys(nodes()):
            tap(
                *next(
                    (x, y)
                    for _, x, y, _, cls in nodes()
                    if cls == "android.widget.EditText"
                )
            )

    steps = (
        ("first show", lambda: None),
        ("landscape", lambda: turn(1)),
        ("portrait again", lambda: turn(0)),
        (
            "other app and back",
            lambda: (
                adb("shell", "input", "keyevent", "KEYCODE_HOME"),
                time.sleep(2),
                field_again(),
            ),
        ),
        (
            "hidden and shown",
            lambda: (
                adb("shell", "input", "keyevent", "KEYCODE_BACK"),
                time.sleep(1),
                field_again(),
            ),
        ),
    )
    problems = []

    def look(step):
        problem = keys_clear_of_nav_bar(step)
        if problem:
            problems.append(problem)

    looked = 0
    try:
        for mode, overlay in NAV_OVERLAYS.items():
            adb("shell", "cmd", "overlay", "enable-exclusive", "--category", overlay)
            time.sleep(3)
            open_field()
            for round_ in range(5):
                for step, act in steps[bool(round_) :]:  # the first show once
                    act()
                    looked += 1
                    look(f"{mode} {step} {round_ + 1}")
            # Last, an app in full screen: its navigation bar hidden until the keyboard comes up
            adb(
                "shell",
                "am",
                "start",
                "-W",
                "-f",
                "0x10008000",
                "-n",
                FIELD,
                "--ez",
                "nobars",
                "true",
            )
            looked += 1
            look(f"{mode} full-screen app")
    finally:
        adb("shell", "cmd", "overlay", "enable-exclusive", "--category", before)
        for k, v in rotation.items():
            if v == "null":
                adb("shell", "settings", "delete", "system", k)
            else:
                adb("shell", "settings", "put", "system", k, v)
    if problems:
        raise Fail(f"{len(problems)} of {looked}: " + "; ".join(problems[:4]))
    return f"the keys clear of the navigation bar in all {looked} looks, 3-button and gesture"


# --- Incognito (#31): the action bar button, its badge, and what is learned and copied meanwhile ---

INCOGNITO = labels("无痕模式", "Incognito", "シークレットモード")
INCOGNITO_ON = labels(
    "无痕模式已开，点按关闭",
    "Incognito on. Tap to turn off",
    "シークレットモード オン。タップでオフ",
)
INCOGNITO_FIELD = labels(
    "此输入框为无痕模式", "Incognito in this field", "この入力欄はシークレットモード"
)
OPEN_BAR = labels("打开操作栏", "Open Action Bar", "アクションバーを開く")
CLOSE_BAR = labels("关闭操作栏", "Close Action Bar", "アクションバーを閉じる")
CLIPBOARD_FILE = f"/data/data/{PKG}/files/clipboard.json"
CLIPBOARD_ACTION = labels("剪贴板管理器", "Clipboard Manager", "クリップボード")
KEEP_CLIPBOARD = labels(
    "保留剪贴板历史", "Keep clipboard history", "クリップボード履歴を残す"
)
BAR_CONTROLS.update((*INCOGNITO_ON, *INCOGNITO_FIELD, *OPEN_BAR, *CLOSE_BAR))
# The new keyboard's bar: its expand button
MORE_CANDIDATES = labels("更多候选词", "More candidates", "候補をもっと見る")
BAR_CONTROLS.update(MORE_CANDIDATES)
BAR_CONTROLS.update(labels("收起候选词", "Fewer candidates", "候補を閉じる"))


def badge():
    """The incognito badge in the suggestion bar: "toggle", "field" or None."""
    ns = nodes()
    if find_all(ns, INCOGNITO_ON):
        return "toggle"
    return "field" if find_all(ns, INCOGNITO_FIELD) else None


def set_incognito(on, shot=None):
    """On through the action bar's Incognito button, off through a tap on the badge."""
    open_field()
    if (badge() == "toggle") == on:
        return
    if on:
        if not screen_has(CLOSE_BAR):  # the bar stays open from before
            tap_text(OPEN_BAR)
        if shot:
            screenshot(shot)
        tap_text(INCOGNITO)
        tap_text(CLOSE_BAR)
    else:
        tap_text(INCOGNITO_ON)
    want = "toggle" if on else None
    wait_for(f"the badge to show {want}", lambda: badge() == want, 10)


def commit_twice(word):
    """Types a made-up word and picks it from the bar as typed (the field capitalises the first one),
    or presses space if the bar doesn't offer it, twice: English suggests a word it doesn't know only
    after it is typed more than once."""
    for _ in range(2):
        type_keys(word)
        typed = [c for c in en_candidates(nodes()) if c.lower() == word]
        if typed:
            tap_candidate(typed[0])
        else:
            bottom_key(5)
            time.sleep(1.5)


def suggested_after(word, kind=None):
    """English's suggestions, in lower case, for word's first five letters in a new field."""
    open_field(kind)
    type_keys(word[:5])
    return [c.lower() for c in en_candidates(nodes())]


def incognito_toggle():
    to_language("hello", "hello")
    set_incognito(True, shot="31-action-bar.png")
    screenshot("31-badge-toggle.png")
    open_field()
    if badge() != "toggle":
        raise Fail(f"a new field after turning incognito on shows the badge {badge()}")
    return "the action bar's Incognito button turns it on; a new field still shows the badge"


def incognito_en():
    open_field()
    commit_twice("zorbleq")
    got = suggested_after("zorbleq")
    if "zorbleq" in got:
        raise Fail(f"typed zorbleq twice while incognito; zorbl -> {got[:6]}")
    return f"typed zorbleq twice while incognito; zorbl -> {got[:6]}"


def incognito_zh():
    to_language("ni", "你")
    before = candidates_for("sx")
    word = before[2]
    tap_candidate(word)
    after = candidates_for("sx")
    if word in after[:2]:
        raise Fail(
            f"sx -> {before[:4]}; picked {word} while incognito; next sx -> {after[:4]}"
        )
    return f"sx -> {before[:4]}; picked {word} while incognito; next sx -> {after[:4]}"


def incognito_ja():
    to_language("nihongo", "日本語")
    before = candidates_for("hashi")
    word = before[2]
    tap_candidate(word)
    after = candidates_for("hashi")
    if word in after[:2]:
        raise Fail(
            f"hashi -> {before[:4]}; picked {word} while incognito; next hashi -> {after[:4]}"
        )
    return f"hashi -> {before[:4]}; picked {word} while incognito; next hashi -> {after[:4]}"


def clipboard_has(text):
    return text in root(f"cat {CLIPBOARD_FILE} 2>/dev/null || true")


def clipboard_capture(text, kind=None):
    """Copies text in the field app; whether SebType's clipboard history kept it."""
    open_field(kind, clip=text)
    time.sleep(
        4
    )  # the copy comes 1.5 s after the field opens; the history saves it in the background
    return clipboard_has(text)


def incognito_clipboard():
    if adb("shell", "su 0 id -u", check=False).strip() != "0":
        raise Skip("no root shell to read the clipboard history (a phone)")
    # Clipboard history is off after a fresh install: on, then a control copy from a normal field
    # (taken before incognito is turned on) shows it is on.
    set_incognito(False)
    for _ in range(2):
        if clipboard_capture(f"sebclip-ctl-{time.time_ns()}"):
            break
        # The switch is the keyboard's clipboard panel's
        open_field()
        if not screen_has(CLOSE_BAR):
            tap_text(OPEN_BAR)
        tap_text(CLIPBOARD_ACTION)
        tap_text(KEEP_CLIPBOARD)
    else:
        raise Fail("clipboard history keeps no copy even from a normal field")
    private = f"sebclip-private-{time.time_ns()}"
    if clipboard_capture(private, kind="private"):
        raise Fail("a copy made in a private field was kept")
    # #139: the keyboard was last up in a normal field; a private field then gets focus with the
    # keyboard down, as in a private browser tab, and a copy made there is still not kept.
    open_field()
    hidden = f"sebclip-hidden-{time.time_ns()}"
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb(
        "shell",
        "am",
        "start",
        "-W",
        "-f",
        "0x10008000",
        "-n",
        FIELD,
        "--es",
        "kind",
        "private",
        "--es",
        "clip",
        hidden,
        "--ez",
        "hidden",
        "true",
    )
    time.sleep(4)
    if keys(nodes()):
        raise Fail("the keyboard showed in the field meant to keep it down")
    if clipboard_has(hidden):
        raise Fail(
            "a copy made in a private field the keyboard never showed in was kept"
        )
    set_incognito(True)
    copied = f"sebclip-incog-{time.time_ns()}"
    if clipboard_capture(copied):
        raise Fail("a copy made while incognito was kept")
    return "copies from a private field (keyboard up or never shown there) and while incognito not kept; a normal one is"


def incognito_after_restart():
    adb("shell", "am", "force-stop", PKG)
    open_field()
    wait_for("the badge after a restart", lambda: badge() == "toggle", 15)
    return "incognito still on after the keyboard restarted"


def incognito_privacy_switch():
    go(HOME["privacy"])
    if not screen_has(INCOGNITO):
        raise Fail("no Incognito switch in Privacy")
    screenshot("31-privacy.png")
    return "Privacy shows the Incognito switch"


def incognito_auto_fields():
    shown = {}
    for kind in ("password", "private"):
        open_field(kind)
        shown[kind] = badge()
        screenshot(f"31-badge-{kind}.png")
    open_field()
    shown["normal"] = badge()
    if shown != {"password": "field", "private": "field", "normal": None}:
        raise Fail(f"badge per field: {shown}")
    return f"badge per field: {shown}"


def incognito_private_en():
    to_language("hello", "hello")
    open_field("private")
    commit_twice("vemquat")
    got = suggested_after("vemquat")
    if "vemquat" in got:
        raise Fail(f"typed vemquat twice in a private field; vemqu -> {got[:6]}")
    return f"typed vemquat twice in a private field; vemqu -> {got[:6]}"


def incognito_private_ja():
    to_language("nihongo", "日本語")
    before = candidates_for("kami")
    word = before[2]
    private = candidates_for("kami", kind="private")
    if word not in private:
        raise Fail(f"kami -> {before[:4]}, but in a private field -> {private[:4]}")
    tap_candidate(word)
    after = candidates_for("kami")
    if word in after[:2]:
        raise Fail(
            f"kami -> {before[:4]}; picked {word} in a private field; next kami -> {after[:4]}"
        )
    return f"kami -> {before[:4]}; picked {word} in a private field; next kami -> {after[:4]}"


def learns_again_en():
    """After incognito: English learns again, and still offers what it learned once incognito is back
    on (Decisions #2, #158: incognito stops learning, not the use of what was learned)."""
    to_language("hello", "hello")
    open_field()
    commit_twice("zorbleq")
    got = suggested_after("zorbleq")
    if "zorbleq" not in got:
        raise Fail(f"typed zorbleq twice after incognito; zorbl -> {got[:6]}")
    set_incognito(True)
    kept = suggested_after("zorbleq")
    set_incognito(False)
    detail = f"zorbl -> {got[:6]} after incognito; {kept[:6]} while incognito again"
    if "zorbleq" not in kept:
        raise Fail(detail)
    return detail


def learns_again(probe, probe_word, code):
    """After incognito the language learns again: a lower candidate picked goes first. Once incognito
    is back on, it stays first (#158)."""

    def run():
        to_language(probe, probe_word)
        word = candidates_for(code)[1]
        tap_candidate(word)
        after = candidates_for(code)
        detail = f"picked {word} for {code} after incognito; next {code} -> {after[:4]}"
        if after[0] != word:
            raise Fail(detail)
        set_incognito(True)
        kept = candidates_for(code)
        set_incognito(False)
        detail += f"; while incognito again -> {kept[:4]}"
        if kept[0] != word:
            raise Fail(detail)
        return detail

    return run


# --- Clipboard history in a settings backup (#34) ---

CLIP_BOX = labels(
    "包含剪贴板历史", "Include clipboard history", "クリップボード履歴を含める"
)
EXPORT = labels("导出设置", "Export settings", "設定をエクスポート")
IMPORT = labels("导入设置", "Import settings", "設定をインポート")
SAVE = labels("保存", "SAVE", "Save")
IMPORT_BUTTON = labels("导入", "Import", "インポート")
KEEP_HISTORY = labels(
    "保留剪贴板历史", "Keep clipboard history", "クリップボード履歴を残す"
)
FILES = f"/data/data/{PKG}/files"
# Made-up entries only, never anyone's real clipboard.
CLIP_TEXT = "SebType test clip 34"
CLIP_FILE = "sebtype-test-34.txt"
# Pinned, so the app's pruning keeps both; the second points to a file in clipboardfiles/.
CLIP_JSON = (
    '[{"timestamp":1,"pinned":true,"text":"' + CLIP_TEXT + '","uri":null,'
    '"mimeTypes":["text/plain"]},'
    '{"timestamp":2,"pinned":true,"text":null,"uri":null,"mimeTypes":["text/plain"],'
    '"backingFile":"' + CLIP_FILE + '","sizeMb":0.0}]'
)


def is_checked(texts):
    """The state of the checkbox or switch row showing one of texts (the new app's row carries its label
    in a child node, not on the switch)."""
    adb("shell", "uiautomator", "dump", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        if n.get("checkable") != "true":
            continue
        labels = [n.get("text") or n.get("content-desc") or ""] + [
            c.get("text") or c.get("content-desc") or ""
            for c in n.iter("node")
            if c is not n
        ]
        if any(label.startswith(t) for label in labels for t in texts):
            return n.get("checked") == "true"
    raise Fail(f"no {texts[1]} checkbox or switch")


def keep_clipboard_history(on):
    go(HOME["privacy"])
    if is_checked(KEEP_HISTORY) != on:
        tap_text(KEEP_HISTORY)


def seed_clipboard():
    """Made-up clipboard history in the app's files, written while the app is stopped. With
    history off, the app deletes it when it starts."""
    keep_clipboard_history(True)
    adb("shell", "am", "force-stop", PKG)
    tmp = "/data/local/tmp/sebtype-clipboard.json"
    adb("shell", f"echo '{CLIP_JSON}' > {tmp}")
    uid = root(f"stat -c %u {FILES}").strip()
    root(
        f"cp {tmp} {FILES}/clipboard.json && mkdir -p {FILES}/clipboardfiles && "
        f"echo made-up > {FILES}/clipboardfiles/{CLIP_FILE} && "
        f"chown -R {uid}:{uid} {FILES}/clipboard.json {FILES}/clipboardfiles && "
        f"restorecon -R {FILES}/clipboard.json {FILES}/clipboardfiles"
    )


def clear_clipboard():
    adb("shell", "am", "force-stop", PKG)
    root(f"rm -rf {FILES}/clipboard.json* {FILES}/clipboardfiles")


def clipboard_on_device():
    return CLIP_TEXT in root(f"cat {FILES}/clipboard.json 2>/dev/null; true") and (
        CLIP_FILE in root(f"ls {FILES}/clipboardfiles 2>/dev/null; true")
    )


def export_backup(include_clipboard, name):
    """Exports from the backup screen into Downloads; returns the backup's entry names."""
    go(HOME["backup"])
    if is_checked(CLIP_BOX):
        raise Fail("the clipboard checkbox starts ticked")
    if include_clipboard:
        tap_text(CLIP_BOX)
        if not is_checked(CLIP_BOX):
            raise Fail("tapping the clipboard checkbox doesn't tick it")
    adb("shell", f"rm -f /sdcard/Download/{BACKUP_FILES}")
    tap_text(EXPORT)
    wait_for("the save dialog", lambda: screen_has(SAVE), 20)
    if not screen_has(labels("下载", "Downloads", "Download")):
        tap_text(labels("显示根目录", "Show roots"))
        tap_text(labels("下载", "Downloads"))
    tap_text(SAVE)
    path = wait_for(
        "the exported backup",
        lambda: adb(
            "shell", f"ls /sdcard/Download/{BACKUP_FILES}", check=False
        ).strip(),
        60,
    )
    wait_for("the export to finish", lambda: screen_has(EXPORT), 60)
    adb("shell", f"mv {path} /sdcard/Download/{name}")
    local = os.path.join(logdir, name)
    adb("pull", f"/sdcard/Download/{name}", local)
    with zipfile.ZipFile(local) as z:
        return z.namelist()


def pick_import(name):
    """Opens the backup screen's Import and picks name in Downloads."""
    go(HOME["backup"])
    tap_text(IMPORT)
    try:
        wait_for(f"{name} in the file picker", lambda: screen_has((name,)), 10)
    except Fail:  # the picker opened elsewhere
        tap_text(labels("显示根目录", "Show roots"))
        tap_text(labels("下载", "Downloads"))
        wait_for(f"{name} in Downloads", lambda: screen_has((name,)), 20)
    tap_text((name,))


def import_backup(name):
    pick_import(name)
    tap_text(IMPORT_BUTTON)
    wait_for("the import to finish", lambda: not screen_has(IMPORT_BUTTON), 120)


def has_clipboard(entries):
    return "clipboard.json" in entries or any(
        e.startswith("clipboard/") for e in entries
    )


def backup_clipboard():
    seed_clipboard()
    off = export_backup(False, "sebtype-34-off.backup")
    if has_clipboard(off):
        raise Fail(f"clipboard history in a backup with the box off: {off}")
    on = export_backup(True, "sebtype-34-on.backup")
    if "clipboard.json" not in on or f"clipboard/{CLIP_FILE}" not in on:
        raise Fail(f"no clipboard history in a backup with the box ticked: {on}")
    clear_clipboard()
    import_backup("sebtype-34-on.backup")
    wait_for("the imported clipboard history", clipboard_on_device, 30)
    # A backup without clipboard history leaves the one on the phone alone.
    import_backup("sebtype-34-off.backup")
    if not clipboard_on_device():
        raise Fail("importing a backup without clipboard history removed the phone's")
    adb("shell", "rm -f /sdcard/Download/sebtype-34-*.backup")
    clear_clipboard()
    keep_clipboard_history(False)
    return "box off by default leaves it out; ticked includes it and import restores it"


INSTALLATION = f"{FILES}/rime/user/installation.yaml"


def installation_id():
    m = re.search(
        r'installation_id:\s*"?([^"\s]+)', root(f"cat {INSTALLATION} 2>/dev/null; true")
    )
    return m and m.group(1)


def backup_installation_id():
    """A backup carries no Rime installation_id, and an older backup's leaves the phone's alone: the id
    names the phone's folder on the sync server, so two phones must never share one (#169)."""
    to_language("ni", "你")  # Chinese set up: Rime has written its installation.yaml
    own = wait_for("Rime's installation_id", installation_id, 60)
    entries = export_backup(False, "sebtype-169.backup")
    if "rime/user/installation.yaml" in entries:
        raise Fail("the backup carries rime/user/installation.yaml")
    # What an older backup from another phone looks like: made-up id.
    old = os.path.join(logdir, "sebtype-169-old.backup")
    with (
        zipfile.ZipFile(os.path.join(logdir, "sebtype-169.backup")) as src,
        zipfile.ZipFile(old, "w") as dst,
    ):
        for item in src.infolist():
            dst.writestr(item, src.read(item))
        dst.writestr(
            "rime/user/installation.yaml",
            'installation_id: "sebtype-test-other-phone"\n',
        )
    adb("push", old, "/sdcard/Download/sebtype-169-old.backup")
    try:
        import_backup("sebtype-169-old.backup")
    finally:
        adb("shell", "rm -f /sdcard/Download/sebtype-169*.backup", check=False)
    after = installation_id()
    if after != own:
        raise Fail(
            f"installation_id {own} became {after} after importing another phone's backup"
        )
    return f"no installation.yaml in the backup; {own} kept after importing one with another id"


def backup_rime_fails():
    """A backup whose Chinese data doesn't start (#282): the import puts the phone's Rime files back and
    中文 types as before. The backup's patch leaves Rime without translators, so ranh offers no 然后."""
    to_language("ni", "你")
    user = f"{FILES}/rime/user"
    marker, patch = "sebtype-282-test.txt", "rime_ice.custom.yaml"
    before = root(f"cat {user}/{patch} 2>/dev/null; true")
    # The options too (#285): the phone's languages and setup's record must come back, not the backup's languages
    options = has_root()
    if options:
        saved = read_prefs()
        write_prefs(
            without_setup(saved).replace(TODAYS_SUBTYPES, b"")
            + TODAYS_SUBTYPES
            + setup_record(2)
        )
        options = prefs_entries(read_prefs())
    export_backup(False, "sebtype-282.backup")
    broken = os.path.join(logdir, "sebtype-282-broken.backup")
    with (
        zipfile.ZipFile(os.path.join(logdir, "sebtype-282.backup")) as src,
        zipfile.ZipFile(broken, "w") as dst,
    ):
        for item in src.infolist():
            if options and item.filename == "datastore.preferences_pb":
                dst.writestr(
                    item,
                    without_setup(src.read(item)).replace(TODAYS_SUBTYPES, b"")
                    + LANGUAGES,
                )
            elif item.filename != f"rime/user/{patch}":
                dst.writestr(item, src.read(item))
        dst.writestr(f"rime/user/{patch}", 'patch:\n  "engine/translators": []\n')
        dst.writestr(f"rime/user/{marker}", "made up\n")
    adb("push", broken, "/sdcard/Download/sebtype-282-broken.backup")
    adb("logcat", "-c")
    try:
        import_backup("sebtype-282-broken.backup")
        # It ends once 中文 has started, on the backup's files or, failing that, on the phone's again.
        log = wait_for(
            "the import to end",
            lambda: (lambda out: out if "settings backup" in out else None)(
                adb("logcat", "-d", "-s", "SebType:W", check=False)
            ),
            300,
        )
    finally:
        adb("shell", "rm -f /sdcard/Download/sebtype-282*.backup", check=False)
    if "failed to import" not in log:
        raise Fail("a backup whose Chinese doesn't start imported as if it had")
    if "No such file" not in root(f"ls {user}/{marker} 2>&1; true"):
        raise Fail(f"the backup's {marker} stayed after the failed import")
    after = root(f"cat {user}/{patch} 2>/dev/null; true")
    if after != before:
        raise Fail(f"{patch} was {before!r}, after the failed import {after!r}")
    if options:
        restored = prefs_entries(read_prefs())
        write_prefs(saved)
        if restored != options:
            raise Fail(
                f"the options were {options}, after the failed import {restored}"
            )
    to_language("ni", "你")
    got = candidates_for("ranh")
    if not any(c in ("然后", "然後") for c in got[:3]):
        raise Fail(f"after the failed import ranh -> {got[:5]}")
    return f"Rime's files{' and the options' if options else ''} back after a backup whose Chinese failed; ranh -> {got[:3]}"


def open_with_sebtype(name):
    """Opens Downloads' name in SebType's import screen, as a file manager's Open with does."""
    adb(
        "shell",
        "am",
        "broadcast",
        "-a",
        "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
        "-d",
        f"file:///sdcard/Download/{name}",
    )
    ids = wait_for(
        f"{name} in the media store",
        lambda: re.findall(
            r"_id=(\d+)",
            adb(
                "shell",
                "content",
                "query",
                "--uri",
                "content://media/external/downloads",
                "--projection",
                "_id:_display_name",
                "--where",
                f"\"_display_name='{name}'\"",
                check=False,
            ),
        ),
        20,
    )
    uri = f"content://media/external/downloads/{max(map(int, ids))}"
    # The type the export saves as: a file manager's Open with offers SebType for it
    view = [
        "-a",
        "android.intent.action.VIEW",
        "-t",
        "application/octet-stream",
        "-d",
        uri,
    ]
    handlers = adb("shell", "cmd", "package", "query-activities", "--brief", *view)
    if not {
        f"{PKG}/.settings.ImportActivity",
        f"{PKG}/{PKG}.settings.ImportActivity",
    } & set(handlers.split()):
        raise Fail(
            f"Open with doesn't offer SebType for its own backup: {handlers.strip()!r}"
        )
    adb(
        "shell",
        "am",
        "start",
        "-W",
        *view,
        "--grant-read-uri-permission",
        "-n",
        f"{PKG}/.settings.ImportActivity",
    )


def backup_setup():
    """#285: through the app's own export and import, today's app's languages (globe order, layouts) go with
    a backup and setup's record never does. A set-up phone's backup opened on a new phone keeps them, and
    setup still runs there; the new phone's export has them again."""
    if not has_root():
        raise Skip("needs root to read and plant the app's options")
    name = "sebtype-285.backup"
    saved = read_prefs()
    adb("shell", "ime", "enable", IME)
    adb("shell", "ime", "set", IME)
    try:
        write_prefs(
            without_setup(saved).replace(TODAYS_SUBTYPES, b"")
            + LANGUAGES
            + setup_record(2)
        )
        export_backup(False, name)
        with zipfile.ZipFile(os.path.join(logdir, name)) as z:
            exported = prefs_entries(z.read("datastore.preferences_pb"))
        if exported.get(b"subtypes") != LANGUAGES or b"sebtype_setup" in exported:
            raise Fail(
                f"the backup's options: {sorted(exported)}, its languages {exported.get(b'subtypes')!r}"
            )
        # A new phone: no options yet, SebType on and chosen
        write_prefs(b"")
        open_with_sebtype(name)
        tap_text(IMPORT_BUTTON)
        wait_for("the import to finish", lambda: not screen_has(IMPORT_BUTTON), 120)
        got = prefs_entries(read_prefs())
        if got.get(b"subtypes") != LANGUAGES:
            raise Fail(f"the languages after the import: {got.get(b'subtypes')!r}")
        if got.get(b"sebtype_setup") != setup_record(0):
            raise Fail(
                f"setup's record after the import: {got.get(b'sebtype_setup')!r}, not unseen"
            )
        start_settings()
        wait_for("setup's step 3 on the new phone", step3_again, 30)
        past_common()
        tap_text(SKIP_SYNC if screen_has(SKIP_SYNC) else CONTINUE)
        wait_step(5)
        tap_text(DONE)
        wait_for("home after Done", lambda: not setup_step_shown(), 15)
        export_backup(False, name)
        with zipfile.ZipFile(os.path.join(logdir, name)) as z:
            again = prefs_entries(z.read("datastore.preferences_pb"))
        if again.get(b"subtypes") != LANGUAGES or b"sebtype_setup" in again:
            raise Fail(
                f"the new phone's backup: {sorted(again)}, its languages {again.get(b'subtypes')!r}"
            )
    finally:
        adb("shell", f"rm -f /sdcard/Download/{name}", check=False)
        write_prefs(saved)
    return "the languages in the backup, not setup's record; on a new phone setup ran and its backup had them"


def backup_screenshots():
    """The backup screen in English and Japanese, whatever the system language."""
    try:
        for lang in ("en-US", "ja-JP"):
            adb("shell", "cmd", "locale", "set-app-locales", PKG, "--locales", lang)
            adb("shell", "am", "force-stop", PKG)
            go(HOME["backup"])
            wait_for(f"the {lang} checkbox", lambda: screen_has(CLIP_BOX), 10)
            screenshot(f"backup-{lang}")
    finally:
        adb(
            "shell",
            "cmd",
            "locale",
            "set-app-locales",
            PKG,
            "--locales",
            "",
            check=False,
        )
    return "settings-backup-en-US.png, settings-backup-ja-JP.png"


adb("logcat", "-c")
# --- Setup's last step, the tips (#285; the new app only) ---

SETUP_FILE = f"/data/data/{PKG}/files/datastore/settings.preferences_pb"


def setup_step_shown():
    m = re.search(
        r"(?:step|第|ステップ) ?(\d)",
        " ".join(label for label, *_ in nodes() if "5" in label),
    )
    return int(m.group(1)) if m else None


def pressed_step(step):
    """Whether setup shows step once its button was pressed, scrolling the page back up when the header
    (the number) is out of view: at large text the next step keeps the scroll position the button was
    pressed at."""

    def reached(before):
        for _ in range(3):
            if setup_step_shown() == step:
                return True
            adb("shell", "input", "swipe", "540", "300", "540", "800", "300")
            time.sleep(0.5)
        return setup_step_shown() == step

    return reached


@functools.cache
def has_root():
    return adb("shell", "su 0 id -u", check=False).strip() == "0"


def night_mode():
    """The system's night mode as `cmd uimode night` takes it back: yes, no or auto"""
    m = re.search(r"Night mode: (yes|no|auto)", adb("shell", "cmd", "uimode", "night"))
    if not m:
        raise Skip("night mode is custom, which this can't put back")
    return m.group(1)


def system_locale(tag):
    """Sets the system's language list to tag alone with emulator.sh's set-locale helper (the way
    Settings does it, without a restart, which can crash the emulator; docs/development.md)."""
    dex = "/data/local/tmp/sebtype-set-locale.dex"
    adb("push", os.path.join(logdir, "set-locale.dex"), dex)
    try:
        adb(
            "shell",
            "app_process",
            "-cp",
            dex,
            "/",
            "dev.sebb.sebtype.setlocale.SetLocale",
            tag,
        )
    finally:
        adb("shell", "rm", "-f", dex, check=False)
    config = tag.replace("-", "-r")  # am get-config writes ja-JP as ja-rJP
    wait_for(
        f"the system in {tag}",
        lambda: re.search(rf"[ -]{config}-", adb("shell", "am", "get-config")),
        30,
    )
    time.sleep(3)  # open apps redraw in the new language


def read_prefs():
    """DataStore's file as it is (a protobuf map of key to value); b"" when the app has none yet."""
    adb("shell", "am", "force-stop", PKG)
    if root(f"[ -f {SETUP_FILE} ] && echo yes || true").strip() != "yes":
        return b""
    local = os.path.join(logdir, "settings.preferences_pb")
    root(
        f"cp {SETUP_FILE} /data/local/tmp/sebtype-prefs.pb; chmod 644 /data/local/tmp/sebtype-prefs.pb"
    )
    adb("pull", "/data/local/tmp/sebtype-prefs.pb", local)
    with open(local, "rb") as f:
        data = f.read()
    os.remove(local)
    return data


def write_prefs(data):
    """Puts data in DataStore's file with the app stopped. The file must exist already: one made by root
    here would be root's, and the app couldn't write it."""
    adb("shell", "am", "force-stop", PKG)
    if root(f"[ -f {SETUP_FILE} ] && echo yes || true").strip() != "yes":
        raise Fail("no DataStore file to write over yet")
    local = os.path.join(logdir, "settings.preferences_pb")
    with open(local, "wb") as f:
        f.write(data)
    adb("push", local, "/data/local/tmp/sebtype-prefs.pb")
    root(
        f"cat /data/local/tmp/sebtype-prefs.pb > {SETUP_FILE}; rm /data/local/tmp/sebtype-prefs.pb"
    )
    os.remove(local)


def prefs_entries(data):
    """DataStore's file as {key: its whole map entry}"""

    def varint(b, i):
        n = shift = 0
        while True:
            n |= (b[i] & 0x7F) << shift
            i += 1
            if b[i - 1] < 0x80:
                return n, i
            shift += 7

    entries, i = {}, 0
    while i < len(data):
        start = i
        _, i = varint(data, i)  # field 1, a map entry
        size, i = varint(data, i)
        body, i = data[i : i + size], i + size
        size, k = varint(body, 1)  # its field 1, the key
        entries[body[k : k + size]] = data[start:i]
    return entries


def without_setup(data):
    """data without the setup record (#285)"""
    return b"".join(e for k, e in prefs_entries(data).items() if k != b"sebtype_setup")


def entry(key, value):
    """One map entry: the key, then a Value message; all short enough for one-byte lengths."""
    e = b"\x0a" + bytes([len(key)]) + key + b"\x12" + bytes([len(value)]) + value
    return b"\x0a" + bytes([len(e)]) + e


# What today's app saves as it first starts: its languages, a string set (Value field 6). The new app never
# writes them, so they mark an update over today's app.
TODAYS_SUBTYPES = entry(b"subtypes", b"\x32\x08\x0a\x06en_US:")


def subtypes(*names):
    """Today's app's languages, globe order and layouts: a string set (Value field 6)"""
    names = b"".join(b"\x0a" + bytes([len(n)]) + n for n in names)
    return entry(b"subtypes", b"\x32" + bytes([len(names)]) + names)


def setup_record(n):
    """Setup's record (#285): an int (Value field 3)"""
    return entry(b"sebtype_setup", b"\x18" + bytes([n]))


# Other than today's app's defaults
LANGUAGES = subtypes(
    b"ja_JP:KeyboardLayoutSet=jis", b"zh_CN:", b"en_US:KeyboardLayoutSet=dvorak"
)


def forget_setup():
    """Takes the app back to before its settings first opened: the setup record out, the rest kept. A phone
    without root clears the app's data instead: the run installed it fresh."""
    if not has_root():
        adb("shell", "pm", "clear", PKG)
        return
    data = read_prefs()
    if data:
        write_prefs(without_setup(data))


def start_settings():
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", SETTINGS)


def wait_step(step):
    wait_for(f"setup's step {step} of 5", lambda: setup_step_shown() == step, 20)


def other_keyboard():
    """Stock FUTO Keyboard, which emulator.sh installs beside SebType"""
    imes = adb("shell", "ime", "list", "-a", "-s").split()
    futo = next(i for i in imes if i.startswith("org.futo.inputmethod.latin/"))
    adb("shell", "ime", "enable", futo)
    return futo


def home_not_setup(what):
    """The settings open on home, with whichever keyboard is in use: never setup."""
    wait_for(what, lambda: screen_has(HOME["about"]) or setup_step_shown(), 30)
    step = setup_step_shown()
    if step:
        raise Fail(f"{what}: setup's step {step} instead")


def bounds(texts):
    """The bounds of the button showing one of texts: its label's nearest clickable node (Compose gives the
    label a node of its own, inside the button's)."""
    adb("shell", "uiautomator", "dump", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    root_node = ET.fromstring(xml[xml.index("<") :])
    parent = {child: node for node in root_node.iter() for child in node}
    for n in root_node.iter("node"):
        if (n.get("text") or n.get("content-desc")) in texts:
            while n.get("clickable") != "true" and n in parent:
                n = parent[n]
            return tuple(map(int, re.findall(r"\d+", n.get("bounds")))), xml
    return None, xml


def focus():
    return (
        adb("shell", "dumpsys", "window")
        .split("mCurrentFocus=", 1)[-1]
        .split("\n", 1)[0]
    )


def large_text(name, button, pressed):
    """At font scale 2 and the largest display size, in portrait and then landscape, setup's page scrolls to
    its real end, where the whole button is on the screen and clear of the system bars; in landscape it is
    pressed and pressed() says what that did (settings-<name>-large-*.png)."""
    if not has_root():
        # A phone (someone's own): its auto-rotate turned itself on during a run, so its display can't be
        # promised back exactly as it was; the button is only pressed, at the phone's own settings.
        print(f"{name}: no large text on a phone")
        before = focus()
        tap_text(button)
        wait_for(f"{button[0]} to do its part", lambda: pressed(before), 15)
        return
    w, h = map(
        int, re.findall(r"(\d+)x(\d+)", adb("shell", "wm", "size"))[0]
    )  # physical, portrait
    # What the device had, put back exactly after; settings it never set stay unset
    saved = {
        k: adb("shell", "settings", "get", "system", k).strip()
        for k in ("font_scale", "user_rotation", "accelerometer_rotation")
    }
    override = re.search(r"Override density: (\d+)", adb("shell", "wm", "density"))
    density = (
        w * 160 // 320
    )  # the largest display size: 320 dp across (540 on a 1080 px screen)
    dp = density / 160
    adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    adb("shell", "settings", "put", "system", "font_scale", "2.0")
    adb("shell", "wm", "density", str(density))
    try:
        for rotation, side in (("0", "portrait"), ("1", "landscape")):
            adb("shell", "settings", "put", "system", "user_rotation", rotation)
            time.sleep(4)
            width, height = (w, h) if rotation == "0" else (h, w)
            screenshot(f"{name}-large-{side}")
            last = None
            for _ in range(12):  # to the end: a swipe that changes nothing
                box, xml = bounds(button)
                if xml == last:
                    break
                last = xml
                adb(
                    "shell",
                    "input",
                    "swipe",
                    str(width // 2),
                    str(height * 3 // 4),
                    str(width // 2),
                    str(height // 4),
                    "300",
                )
                time.sleep(1)
            else:
                raise Fail(f"{side}: the page didn't come to an end")
            screenshot(f"{name}-large-{side}-end")
            # At the end the page's 48 dp under the button show too, which no system bar is as tall as: a
            # button the screen's edge or a bar clipped would end lower. A Material button is 40 dp at least.
            if (
                not box
                or box[1] <= 0
                or box[3] + 48 * dp > height
                or box[3] - box[1] < 40 * dp
            ):
                raise Fail(
                    f"{side}: {button[0]} not whole on the screen at the end: {box}, screen height {height}"
                )
        before = focus()
        tap((box[0] + box[2]) // 2, (box[1] + box[3]) // 2)
        wait_for(f"{button[0]} to do its part", lambda: pressed(before), 15)
    finally:
        for k, v in saved.items():
            if v == "null":
                adb("shell", "settings", "delete", "system", k)
            else:
                adb("shell", "settings", "put", "system", k, v)
        adb("shell", "wm", "density", *([override.group(1)] if override else ["reset"]))
        time.sleep(3)


def left_and_back(before):
    """A step's button opened Android's own screen or its keyboard picker; Back returns to setup."""
    if focus() == before and not screen_has(
        ("Choose input method", "Select input method")
    ):
        return False
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    wait_for("setup again after Back", lambda: "SettingsActivity" in focus(), 10)
    return True


SKIP_SYNC = labels("暂不设置", "Not now", "あとで")
CONTINUE = labels("继续", "Continue", "次へ")
DONE = labels("完成", "Done", "完了")


def past_common():
    """Setup's common settings (#444), step 3: Continue keeps them as they are, on to account sync."""
    tap_text(CONTINUE)
    wait_step(4)


def step3_again():
    """Just after SebType stops, the system can fall back to another keyboard (setup's step 2): SebType is
    chosen again until step 3 shows."""
    step = setup_step_shown()
    if step == 2:
        adb("shell", "ime", "set", IME)
    return step == 3


def setup_tips():
    """A new user: steps 1 and 2 of 5, then the common settings as step 3 (#444: number row off, in English and
    中文), account sync as step 4, then the tips as step 5, which an interruption keeps; Done ends setup for good. At large text each step's button can be reached and pressed."""
    forget_setup()
    adb("shell", "ime", "disable", IME)
    try:
        start_settings()
        wait_step(1)
        screenshot("setup-step1")
        large_text("setup-step1", labels("Turn on SebType"), left_and_back)
        adb("shell", "ime", "enable", IME)
        wait_step(2)
        screenshot("setup-step2")
        large_text("setup-step2", labels("Choose SebType"), left_and_back)
        adb("shell", "ime", "set", IME)
        wait_step(3)
        screenshot("setup-common")
        if is_checked(labels("显示数字行", "Show number row")):
            raise Fail("the common settings step's number row isn't shown off")
        system_locale("zh-CN")
        try:
            wait_for(
                "the common settings in 中文", lambda: screen_has(("显示数字行",)), 10
            )
            screenshot("setup-common-zh")
        finally:
            system_locale("en-US")
        large_text("setup-common", CONTINUE, pressed_step(4))
        wait_step(4)
        screenshot("setup-sync")
        large_text(
            "setup-sync",
            SKIP_SYNC if screen_has(SKIP_SYNC) else CONTINUE,
            pressed_step(5),
        )
        wait_step(5)
        wait_for("the tips", lambda: screen_has(TIPS_SPACE), 10)
        screenshot("setup-tips")
        night = night_mode()
        adb("shell", "cmd", "uimode", "night", "yes")
        try:
            time.sleep(2)
            screenshot("setup-tips-dark")
        finally:
            adb("shell", "cmd", "uimode", "night", night)
        # Interrupted: the app stopped before Done comes back to setup (step 3)
        adb("shell", "am", "force-stop", PKG)
        start_settings()
        wait_for("setup's step 3 of 5 after a restart", step3_again, 30)
        past_common()
        tap_text(SKIP_SYNC if screen_has(SKIP_SYNC) else CONTINUE)
        wait_step(5)
        # Done, pressed at large text in landscape, opens home (its title, at the top)
        large_text(
            "setup-tips",
            DONE,
            lambda before: screen_has(("SebType",)) and not setup_step_shown(),
        )
        adb("shell", "am", "force-stop", PKG)
        adb("shell", "ime", "set", IME)
        start_settings()
        home_not_setup("reopened after Done")
        # Another keyboard chosen after Done: still home
        adb("shell", "ime", "set", other_keyboard())
        adb("shell", "am", "force-stop", PKG)
        start_settings()
        home_not_setup("the settings with another keyboard after Done")
    finally:
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)
    return (
        "steps 1 to 5 of 5, each button "
        + (
            "scrolled to and pressed at large text (portrait and landscape)"
            if has_root()
            else "pressed (no large text on a phone)"
        )
        + ", "
        "setup again after a restart, home after Done, after a restart and with another keyboard (settings-setup-*.png)"
    )


def setup_fresh_enabled():
    """Fresh data with SebType already on and chosen (turned on before the app first opened, or its data
    cleared): setup, its step 3, not home."""
    if not has_root():  # a phone: its data cleared, which the run installed fresh
        adb("shell", "pm", "clear", PKG)
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)
        start_settings()
        wait_for("setup's step 3 of 5 with fresh data", step3_again, 30)
        # Common settings, skip sync and Done, as the user would: the next checks expect home, and without root
        # none can put it back
        past_common()
        tap_text(SKIP_SYNC if screen_has(SKIP_SYNC) else CONTINUE)
        wait_step(5)
        tap_text(DONE)
        wait_for("home after Done", lambda: not setup_step_shown(), 15)
        return "data cleared, SebType on and chosen: setup's step 3"
    saved = read_prefs()
    try:
        write_prefs(b"")
        adb("shell", "ime", "enable", IME)
        adb("shell", "ime", "set", IME)
        start_settings()
        wait_for("setup's step 3 of 5 with fresh data", step3_again, 30)
    finally:
        write_prefs(saved)
    return "fresh data, SebType on and chosen: setup's step 3"


def setup_existing_user():
    """An update over today's app (its languages in DataStore's file, no setup record): home, never setup,
    with SebType off (so the evidence, not Android's keyboard settings, decides), with another keyboard in
    use, and once SebType is chosen again."""
    if not has_root():
        raise Skip("needs root to put today's app's data in place")
    saved = read_prefs()
    try:
        write_prefs(without_setup(saved) + TODAYS_SUBTYPES)
        adb("shell", "ime", "disable", IME)
        try:
            start_settings()
            home_not_setup("opening with SebType off")
            adb("shell", "am", "force-stop", PKG)
        finally:
            adb("shell", "ime", "enable", IME)
        write_prefs(without_setup(saved) + TODAYS_SUBTYPES)
        adb("shell", "ime", "set", other_keyboard())
        try:
            for run in (1, 2):
                start_settings()
                home_not_setup(f"opening {run} with another keyboard")
                adb("shell", "am", "force-stop", PKG)
        finally:
            adb("shell", "ime", "set", IME)
        start_settings()
        home_not_setup("opening with SebType chosen again")
    finally:
        write_prefs(saved)
    return "today's app's data: home with SebType off, with another keyboard in use, twice, and with SebType chosen again"


def tips_screenshots():
    shots = []
    before = night_mode()
    for night in ("no", "yes"):
        adb("shell", "cmd", "uimode", "night", night)
        try:
            time.sleep(2)
            suffix = "-dark" if night == "yes" else ""
            go(HOME["about"])
            screenshot(f"about{suffix}")
            tap_text(TIPS)
            wait_for("the tips", lambda: screen_has(TIPS_SPACE), 10)
            screenshot(f"tips{suffix}")
            shots += [f"settings-about{suffix}.png", f"settings-tips{suffix}.png"]
        finally:
            adb("shell", "cmd", "uimode", "night", before)
    return ", ".join(shots)


check("settings-setup-tips", setup_tips)
check(
    "settings-setup-fresh-enabled",
    setup_fresh_enabled,
    needs=["settings-setup-tips"],
)
check(
    "settings-setup-existing-user",
    setup_existing_user,
    needs=["settings-setup-tips"],
)
check("settings-tips-screenshots", tips_screenshots)


check("settings-screens", every_screen)
check("settings-globe-order", globe_order)
check("settings-zh-punctuation", full_width_punctuation)
check("settings-zh-emoji", emoji_candidates)
check("settings-zh-my-words", my_words)
check("settings-zh-forget", forget_chinese)
check("settings-ja-forget", forget_japanese)
check("settings-en-forget", forget_english)
check("settings-no-theme-choice", no_theme_choice)
check("settings-dark-mode-picnic", dark_mode_picnic)
check("settings-picnic-look", picnic_look)
check("settings-picnic-size", gboard_size)
check("settings-nav-bar", nav_bar_clear)
check("settings-smooth-scrolling", smooth_scrolling)


# --- The settings in 日本語 (#120) ---

HERE = os.path.dirname(os.path.abspath(__file__))


# --- Sync with the user's own server (#12) ---
# A local sync-server on this PC (127.0.0.1, which the emulator reaches as 10.0.2.2) over HTTPS with a
# made-up certificate authority the emulator trusts until the end of the run, a made-up login and
# made-up words. Nothing of the maintainer's own server.
SYNC_USER, SYNC_PASSWORD = "sebtype-test", "made-up-pass-4821"
OTHER_DEVICE = "5e5e5e5e-0000-4000-8000-000000000012"  # a made-up second device
OTHER_CODE, OTHER_WORD = "lu lu", "鹿芦"
# The words the offline check learns for the code it types: the model's own guess 猫狗就要, which reads jiya
# otherwise, so Rime has no pieces for it and the model stores it under the syllables typed (#518), and
# Rime's 猫狗挤压. 繁 on shows each converted where the file keeps the first spelling (zh-hant-on in another
# run of the suite may leave it on, #36).
SYNC_CODE = "maogoujiya"
SYNC_PICKS = {"model": ("猫狗就要", "貓狗就要"), "rime": ("猫狗挤压", "貓狗擠壓")}
SYNC = {}  # the server process, its port and data dir, the CA's file name on the emulator, airplane mode before
NO_BACKUP = f"/data/data/{PKG}/no_backup"
RIME_USER = f"/data/data/{PKG}/files/rime/user"
SYNC_LOGIN = labels("服务器和登录", "Server and login", "サーバーとログイン")
SYNC_DELETE = labels(
    "删除服务器上学到的词和词典",
    "Delete learned words and dictionaries on the server",
    "サーバー上の学習した単語と辞書を削除",
)
SYNC_OFFLINE = ("无法连接服务器", "Can't reach the server", "サーバーに接続できません")
SYNC_SYNCED = ("上次同步", "Last synced", "前回の同期")
SYNC_OFF = ("通过你自己的服务器", "with your own server", "自分のサーバーと")
CA_SCRIPT = r"""set -u
d=/data/local/tmp/sebtype-cacerts apex=/apex/com.android.conscrypt/cacerts
zygotes=$(pidof zygote64 zygote)
if [ "$1" = add ]; then
  rm -rf $d; mkdir -p $d; cp $apex/* $d/; cp /data/local/tmp/$2 $d/
  label=$(ls -Z $apex/$(ls $apex | head -1) | cut -d" " -f1)
  for z in $zygotes; do
    nsenter --mount=/proc/$z/ns/mnt -- sh -c "mount -t tmpfs tmpfs $apex && cp $d/* $apex/ && chmod 755 $apex && chmod 644 $apex/* && chcon $label $apex $apex/*" || exit 1
  done
else
  for z in $zygotes; do nsenter --mount=/proc/$z/ns/mnt -- umount $apex; done
  rm -rf $d /data/local/tmp/$2 /data/local/tmp/sebtype-ca.sh
fi
"""


def sync_server_dir(*parts):
    return os.path.join(SYNC["data"], "files", SYNC_USER, *parts)


def openssl(*args, cwd):
    subprocess.run(
        ["openssl", *args], cwd=cwd, check=True, capture_output=True, timeout=60
    )


def start_sync_server():
    """The server with TLS from a made-up CA, whose certificate the emulator's apps trust meanwhile."""
    d = os.path.join(logdir, "sync-server")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        "ca.key",
        "-out",
        "ca.pem",
        "-days",
        "2",
        "-subj",
        "/CN=SebType test CA (made up)",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign",
        cwd=d,
    )
    openssl(
        "req",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        "server.key",
        "-out",
        "server.csr",
        "-subj",
        "/CN=10.0.2.2",
        cwd=d,
    )
    with open(os.path.join(d, "ext.cnf"), "w") as f:
        f.write("subjectAltName=IP:10.0.2.2\nextendedKeyUsage=serverAuth\n")
    openssl(
        "x509",
        "-req",
        "-in",
        "server.csr",
        "-CA",
        "ca.pem",
        "-CAkey",
        "ca.key",
        "-CAcreateserial",
        "-out",
        "server.pem",
        "-days",
        "2",
        "-extfile",
        "ext.cnf",
        cwd=d,
    )
    SYNC["data"] = os.path.join(d, "data")
    server = os.path.join(HERE, "..", "..", "sync-server", "sebtype_sync.py")
    subprocess.run(
        [
            sys.executable,
            "-I",
            server,
            "adduser",
            "--data",
            SYNC["data"],
            SYNC_USER,
            "--password-stdin",
        ],
        input=SYNC_PASSWORD + "\n",
        text=True,
        check=True,
        timeout=60,
    )
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        SYNC["port"] = sock.getsockname()[1]
    SYNC["log"] = open(os.path.join(d, "server.log"), "w")  # noqa: SIM115 (open while the server runs)
    SYNC["server"] = subprocess.Popen(
        [
            sys.executable,
            "-I",
            server,
            "serve",
            "--data",
            SYNC["data"],
            "--port",
            str(SYNC["port"]),
            "--tls-cert",
            os.path.join(d, "server.pem"),
            "--tls-key",
            os.path.join(d, "server.key"),
        ],
        stdout=SYNC["log"],
        stderr=subprocess.STDOUT,
    )
    wait_for(
        "the sync server",
        lambda: socket.socket().connect_ex(("127.0.0.1", SYNC["port"])) == 0,
        30,
    )

    name = (
        subprocess.run(
            [
                "openssl",
                "x509",
                "-subject_hash_old",
                "-noout",
                "-in",
                os.path.join(d, "ca.pem"),
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        + ".0"
    )
    with open(os.path.join(d, "ca.sh"), "w") as f:
        f.write(CA_SCRIPT)
    adb("push", os.path.join(d, "ca.pem"), f"/data/local/tmp/{name}")
    adb("push", os.path.join(d, "ca.sh"), "/data/local/tmp/sebtype-ca.sh")
    SYNC["ca"] = name
    root(f"sh /data/local/tmp/sebtype-ca.sh add {name}")
    # SebType's process forks from zygote again, now with the CA.
    adb("shell", "am", "force-stop", PKG)


def stop_sync_server():
    if "airplane" in SYNC:
        airplane(SYNC.pop("airplane") == "1")
    if "ca" in SYNC:
        root(f"sh /data/local/tmp/sebtype-ca.sh remove {SYNC.pop('ca')}")
        adb("shell", "am", "force-stop", PKG)
    if "server" in SYNC:
        SYNC.pop("server").terminate()
        SYNC.pop("log").close()


def airplane(on):
    adb("shell", "cmd", "connectivity", "airplane-mode", "enable" if on else "disable")
    # Some images keep Wi-Fi on in airplane mode; the emulator's Wi-Fi and data are on by default.
    adb("shell", "svc", "wifi", "disable" if on else "enable")
    adb("shell", "svc", "data", "disable" if on else "enable")
    reachable = lambda: adb(
        "shell", "ping", "-c", "1", "-W", "2", "10.0.2.2", check=False, timeout=30
    )
    wait_for(
        "the network " + ("off" if on else "back"),
        lambda: (" 0% packet loss" in reachable()) != on,
        60,
        interval=3,
    )


def sync_by_hiding():
    """Hides the keyboard over a minute after it was last up: a hide syncs at most once a minute."""
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(62)
    open_field()
    adb("shell", "input", "keyevent", "KEYCODE_BACK")


def server_snapshot(device):
    path = sync_server_dir(device, "rime_ice.userdb.txt")
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as f:
        return f.read()


def entry_line(snapshot, text=None):
    """A word the offline check learned in a sync snapshot (TEXT: that one), or "", by its code."""
    return next(
        (
            line
            for line in snapshot.splitlines()
            if line.split("\t")[0].replace(" ", "") == SYNC_CODE
            and text in (None, line.split("\t")[1])
        ),
        "",
    )


def entry_lines(snapshot):
    """Both words the offline check learned in a sync snapshot, or None while one isn't there."""
    lines = [entry_line(snapshot, words[0]) for words in SYNC_PICKS.values()]
    return lines if all(lines) else None


def sync_setup():
    # Incognito (#31) is sticky and a run of just some checks may start with it on: nothing is learned
    # while it is, so nothing would ever reach the server.
    set_incognito(False)
    to_language("ni", "你")
    start_sync_server()
    go(HOME["backup"], SYNC_LOGIN)
    set_text(0, f"10.0.2.2:{SYNC['port']}")
    set_text(1, SYNC_USER)
    set_text(2, SYNC_PASSWORD)
    screenshot("12-sync-login")
    tap_text(labels("保存", "Save"))
    # A first login turns sync on and syncs: this phone's learned words arrive in its own folder.
    devices = wait_for(
        "this phone's folder on the server",
        lambda: os.path.isdir(sync_server_dir()) and os.listdir(sync_server_dir()),
        90,
    )
    SYNC["device"] = devices[0]
    try:
        wait_for("its snapshot", lambda: server_snapshot(SYNC["device"]), 30)
    except Fail as e:
        user = f"/data/user/0/{PKG}/files/rime/user"
        raise Fail(
            f"{e}; the phone has {root(f'ls -R {user}/sync; ls {user}').split()}, logged"
            f" {[line for line in adb('logcat', '-d', '-s', 'SebType').splitlines() if 'ync' in line][-5:]}"
        )
    wait_for("the status 'Last synced'", lambda: screen_contains(SYNC_SYNCED), 20)
    screenshot("12-sync-section")
    return f"login saved, sync on; the phone's folder {SYNC['device'][:8]}… arrived; status Last synced"


SYNC_CONNECTED = ("已连接", "Connected. The server", "接続しました")
SYNC_WRONG = (
    "用户名或密码错误",
    "Wrong username or password",
    "ユーザー名またはパスワードが違います",
)


def sync_status():
    """The connection check (#452, #465): Sync & backup's tick for the login sync-setup saved, a wrong
    password's X in the login dialog and, saved anyway, on the page; then the right one again. Without
    sync-setup's server (only this check named, or 中文 not up) it starts one and saves the login itself."""
    if "server" not in SYNC:
        start_sync_server()
        go(HOME["backup"], SYNC_LOGIN)
        set_text(0, f"10.0.2.2:{SYNC['port']}")
        set_text(1, SYNC_USER)
        set_text(2, SYNC_PASSWORD)
        tap_text(labels("保存", "Save"))
    go(HOME["backup"])
    wait_for("Connected on Sync & backup", lambda: screen_contains(SYNC_CONNECTED), 30)
    screenshot("12-sync-status-connected")
    go(HOME["backup"], SYNC_LOGIN)
    set_text(2, "not-the-password")
    tap_text(labels("保存", "Save"))
    wait_for(
        "Wrong username or password in the dialog",
        lambda: screen_contains(SYNC_WRONG),
        30,
    )
    screenshot("12-sync-login-wrong-password")
    tap_text(labels("仍然保存", "Save anyway", "このまま保存"))
    wait_for(
        "Wrong username or password on Sync & backup",
        lambda: screen_contains(SYNC_WRONG),
        30,
    )
    screenshot("12-sync-status-wrong-password")
    go(HOME["backup"], SYNC_LOGIN)
    set_text(2, SYNC_PASSWORD)
    tap_text(labels("保存", "Save"))
    wait_for("Connected again", lambda: screen_contains(SYNC_CONNECTED), 30)
    return "Connected for the saved login; a wrong password: Wrong username or password in the dialog and, saved anyway, on the page; Connected again"


def sync_offline_learns():
    SYNC["airplane"] = adb(
        "shell", "settings", "get", "global", "airplane_mode_on"
    ).strip()
    airplane(True)
    # Rime's word first (it leaves the bar once the model's is learned), then the model's once its list shows.
    for kind in ("rime", "model"):
        open_field()
        type_keys(SYNC_CODE)
        words = SYNC_PICKS[kind]
        SYNC[kind] = wait_for(
            f"one of {words} for {SYNC_CODE}",
            lambda: next((w for w in candidates(nodes()) if w in words), None),
            60,
        )
        tap_candidate(SYNC[kind])
    after = candidates_for(SYNC_CODE)
    if after[0] != SYNC["model"]:
        raise Fail(
            f"picked {SYNC['rime']}, then {SYNC['model']}; then {SYNC_CODE} -> {after[:8]}"
        )
    sync_by_hiding()
    go(HOME["backup"])
    wait_for(
        "the status 'Can't reach the server'", lambda: screen_contains(SYNC_OFFLINE), 30
    )
    screenshot("12-sync-offline")
    if entry_line(server_snapshot(SYNC["device"])):
        raise Fail(f"{SYNC_CODE}'s words reached the server in airplane mode")
    return (
        f"offline: picked Rime's {SYNC['rime']} for {SYNC_CODE}, then the model's {SYNC['model']}, first the "
        f"next time; status Can't reach the server; not on the server"
    )


def sync_online_uploads():
    airplane(False)
    sync_by_hiding()
    lines = wait_for(
        f"{SYNC['model']} and {SYNC['rime']} on the server",
        lambda: entry_lines(server_snapshot(SYNC["device"])),
        90,
    )
    folders = os.listdir(sync_server_dir())
    if folders != [SYNC["device"]]:
        raise Fail(f"folders on the server: {folders}")
    return f"back online, a keyboard hide uploaded both: {lines!r}; only the phone's own folder"


def sync_other_device():
    before = candidates_for(OTHER_CODE.replace(" ", ""), expand=True)
    if OTHER_WORD in before:
        raise Fail(f"{OTHER_WORD} offered before it was synced: {before[:8]}")
    # The other device's snapshot, in the phone's format with its own id and one made-up word.
    snapshot = server_snapshot(SYNC["device"])
    line = entry_line(snapshot)
    key = OTHER_CODE + (" " if line.split("\t")[0].endswith(" ") else "")
    tick = re.search(r"^#@/tick\t(\d+)", snapshot, re.MULTILINE)[1]
    header = [
        re.sub(r"^#@/user_id\t.*", f"#@/user_id\t{OTHER_DEVICE}", l)
        for l in snapshot.splitlines()
        if l.startswith("#")
    ]
    os.makedirs(sync_server_dir(OTHER_DEVICE))
    with open(
        sync_server_dir(OTHER_DEVICE, "rime_ice.userdb.txt"), "w", encoding="utf-8"
    ) as f:
        f.write("\n".join(header + [f"{key}\t{OTHER_WORD}\tc=50 d=50 t={tick}"]) + "\n")
    sync_by_hiding()
    wait_for(
        "the other device's snapshot on the phone",
        lambda: (
            "rime_ice.userdb.txt"
            in root(f"ls {RIME_USER}/sync/{OTHER_DEVICE} 2>/dev/null; true")
        ),
        60,
    )
    time.sleep(10)  # Rime merges it right after the download
    got = candidates_for(OTHER_CODE.replace(" ", ""), expand=True)
    if OTHER_WORD not in got:
        raise Fail(f"after the sync, lulu -> {got[:8]}")
    return f"a made-up word in another device's folder: lulu -> {got[: got.index(OTHER_WORD) + 1]} after a sync"


def sync_crash_report():
    """A crash while sync is on goes to the server's crash folder with the next sync (#33), without the
    words typed before it or the login."""
    queue = f"{NO_BACKUP}/crash-reports"
    crashes = os.path.join(SYNC["data"], "crashes", SYNC_USER)
    open_field()
    adb("shell", "am", "crash", PKG)  # an uncaught exception on SebType's main thread
    wait_for(
        "the report queued on the phone",
        lambda: "crash-" in root(f"ls {queue} 2>/dev/null; true"),
        60,
    )
    sync_by_hiding()
    names = wait_for(
        "the report in the server's crash folder",
        lambda: os.path.isdir(crashes) and os.listdir(crashes),
        90,
    )
    with open(os.path.join(crashes, names[0]), encoding="utf-8") as f:
        report = f.read()
    shutil.copy(
        os.path.join(crashes, names[0]), os.path.join(logdir, "33-crash-report.txt")
    )
    missing = [
        t
        for t in ("Device: ", "Thread: main", "\tat android.", "Last warnings")
        if t not in report
    ]
    leaked = [
        t
        for t in (SYNC["model"], SYNC["rime"], OTHER_WORD, SYNC_USER, SYNC_PASSWORD)
        if t in report
    ]
    if missing or leaked:
        raise Fail(f"missing {missing}, leaked {leaked} (33-crash-report.txt)")
    wait_for(
        "the queue emptied on the phone",
        lambda: "crash-" not in root(f"ls {queue} 2>/dev/null; true"),
        30,
    )
    return f"{names[0]} on the server, {len(report.splitlines())} lines, no typed word or login; the phone's queue is empty"


WORDS = "content://user_dictionary/words"
# Made-up personal words (#14): the other device's, then the phone's own (reading, word for Japanese).
OTHER_JA, OTHER_EN = ("ぷるもに", "プルモニ語"), "Plonkravit"
OTHER_ZH = ("pumolici", "噗莫哩词")  # pinyin, word: 中文's My words (#272)
ZH_FILE = "zh_my_words.userdb.txt"
PHONE_JA, PHONE_EN = ("ぴよぽん", "ピヨポン丸"), "Quindlewump"


def sync_personal_dictionaries():
    """Made-up Japanese, English and Chinese words in another device's folder are offered on the phone
    after a sync, and words added on the phone reach its own folder (#14, #272)."""

    # As root, but not through root()'s quotes: Android's user dictionary takes words only from
    # keyboards, spell checkers and root (#143). It outlives the app, so a run starts by deleting the
    # words an earlier one may have left.
    def content(args):
        adb("shell", f"su 0 content {args} --uri {WORDS}")

    def delete_words():
        for w in (PHONE_JA[1], PHONE_EN, OTHER_JA[1], OTHER_EN):
            content(f"delete --where \"word='{w}'\"")

    delete_words()
    content(
        f"insert --bind word:s:{PHONE_JA[1]} --bind 'shortcut:s:{PHONE_JA[0]}\t1'"
        " --bind locale:s:ja --bind frequency:i:0 --bind appid:i:0"
    )
    content(
        f"insert --bind word:s:{PHONE_EN} --bind locale:s:en --bind frequency:i:250 --bind appid:i:0"
    )
    try:
        os.makedirs(sync_server_dir(OTHER_DEVICE), exist_ok=True)
        with open(
            sync_server_dir(OTHER_DEVICE, "mozc_dictionary.txt"), "w", encoding="utf-8"
        ) as f:
            f.write(f"{OTHER_JA[0]}\t{OTHER_JA[1]}\t名詞\tmade up\n")
        with open(sync_server_dir(OTHER_DEVICE, ZH_FILE), "w", encoding="utf-8") as f:
            f.write(f"{OTHER_ZH[0]}\t{OTHER_ZH[1]}\t名詞\t\t1000\n")
        with open(
            sync_server_dir(OTHER_DEVICE, "userdictionary.json"), "w", encoding="utf-8"
        ) as f:
            json.dump(
                [
                    {
                        "word": OTHER_EN,
                        "frequency": 250,
                        "locale": "en",
                        "appId": 0,
                        "shortcut": None,
                    }
                ],
                f,
            )
        sync_by_hiding()

        def uploaded(name):
            path = sync_server_dir(SYNC["device"], name)
            if not os.path.isfile(path):
                return ""
            with open(path, encoding="utf-8") as f:
                return f.read()

        mozc = wait_for(
            "the phone's words in its own folder",
            lambda: (
                PHONE_JA[1] in (m := uploaded("mozc_dictionary.txt"))
                and PHONE_EN in uploaded("userdictionary.json")
                and m
            ),
            90,
        )
        # The phone's own record of its Chinese words holds the one it took in, with its time.
        zh = wait_for(
            "the Chinese word in the phone's own file",
            lambda: (
                f"{OTHER_ZH[0]}\t{OTHER_ZH[1]}\t名詞\t\t1000"
                in (z := uploaded(ZH_FILE))
                and z
            ),
            60,
        )
        if OTHER_ZH[1] not in root(f"cat {WORDS_FILE}"):
            raise Fail(f"{OTHER_ZH[1]} not in My words ({WORDS_FILE})")
        to_language("ni", "你")
        zh_got = candidates_for(OTHER_ZH[0])
        wait_for(
            "the other device's words in the phone's dictionary",
            lambda: all(
                w in root(f"content query --uri {WORDS} --projection word")
                for w in (OTHER_JA[1], OTHER_EN)
            ),
            30,
        )
        to_language("nihongo", "日本語")
        ja = candidates_for("purumoni")
        # English: the word reaching the dictionary is all this checks (#246).
        en = None
    finally:
        delete_words()
    offered = "no English suggestions yet" if en is None else en[:4]
    detail = (
        f"purumoni -> {ja[:4]}, plonk -> {offered}, {OTHER_ZH[0]} -> {zh_got[:4]}; the phone's files: "
        f"{mozc.strip()!r}, {zh.strip()!r}"
    )
    if (
        OTHER_JA[1] not in ja
        or (en is not None and OTHER_EN.lower() not in en)
        or OTHER_ZH[1] not in zh_got
    ):
        raise Fail(detail)
    return detail


LEARNED_HEADER = "# SebType mozc_learned 1\n"


def sync_learned_conversions():
    """A conversion picked in 日本語 reaches the phone's record on the server, and one another device picked comes
    first on the phone after a sync, its Mozc having learned it as it starts again (#409)."""
    to_language("nihongo", "日本語")
    kanji = candidates_for("kanji", expand=True)
    other = "幹事"  # what the other device picked for かんじ
    if not kanji or kanji[0] == other or other not in kanji:
        raise Fail(f"kanji -> {kanji[:6]}, want {other} below the first")
    picked = candidates_for("kisha")[1]
    tap_candidate(picked)
    os.makedirs(sync_server_dir(OTHER_DEVICE), exist_ok=True)
    with open(
        sync_server_dir(OTHER_DEVICE, "mozc_learned.txt"), "w", encoding="utf-8"
    ) as f:
        f.write(f"{LEARNED_HEADER}かんじ\t{other}\t{int(time.time())}\n")
    sync_by_hiding()

    def uploaded():
        path = sync_server_dir(SYNC["device"], "mozc_learned.txt")
        if not os.path.isfile(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    record = wait_for(
        "the phone's pick in its record on the server",
        lambda: f"きしゃ\t{picked}\t" in (r := uploaded()) and r,
        90,
    )
    wait_for(
        "the other device's record on the phone",
        lambda: (
            other
            in root(
                f"cat /data/data/{PKG}/.mozc/mozc_learned/{OTHER_DEVICE}.txt 2>/dev/null; true"
            )
        ),
        30,
    )
    now = candidates_for("kanji")
    detail = f"picked {picked} for kisha, the phone's record {record.strip()!r}; kanji -> {now[:4]} after a sync"
    if now[0] != other:
        raise Fail(detail)

    # Forget on the phone, with another pick of the other device's just downloaded: nothing picked before it comes
    # back, even when that device later picks something else for the same reading, and the phone's record on the
    # server is emptied (#416 review).
    def other_record(*picks):
        with open(
            sync_server_dir(OTHER_DEVICE, "mozc_learned.txt"), "w", encoding="utf-8"
        ) as f:
            f.write(LEARNED_HEADER + "".join(f"{r}\t{w}\t{t}\n" for r, w, t in picks))

    def on_phone(written):
        return written in root(
            f"cat /data/data/{PKG}/.mozc/mozc_learned/{OTHER_DEVICE}.txt 2>/dev/null; true"
        )

    before = [
        ("かんじ", other, int(time.time()) - 60),
        ("せいか", "聖火", int(time.time())),
    ]
    other_record(*before)
    sync_by_hiding()
    wait_for(
        "the other device's second pick on the phone", lambda: on_phone("聖火"), 90
    )
    forget(labels("日本語"))
    to_language("nihongo", "日本語")
    base = candidates_for("kanji")
    after = "漢字"  # what the other device picks for かんじ after the Forget
    if base[0] == other or after not in base[1:]:
        raise Fail(
            f"kanji -> {base[:4]} after forgetting 日本語, want {other} gone and {after} below the first"
        )
    other_record(*before, ("かんじ", after, int(time.time())))
    sync_by_hiding()
    wait_for(
        "the phone's record emptied on the server",
        lambda: uploaded() == LEARNED_HEADER,
        90,
    )
    wait_for(
        "the other device's pick after the Forget on the phone",
        lambda: on_phone(after),
        30,
    )
    kanji, seika = candidates_for("kanji"), candidates_for("seika")
    want = [after] + [c for c in base if c != after]
    detail += f"; after forgetting 日本語 kanji -> {base[:3]}, then {kanji[:3]} after another sync, seika -> {seika[:2]}"
    if kanji[:3] != want[:3] or seika[0] == "聖火":
        raise Fail(f"{detail}, want kanji -> {want[:3]}")
    return detail


def sync_delete_on_server():
    # The dictionaries go too (#14): the phone's and the other device's, left by sync-personal-dictionaries.
    dictionaries = [
        os.path.join(device, name)
        for device in (SYNC["device"], OTHER_DEVICE)
        for name in ("mozc_dictionary.txt", "userdictionary.json", ZH_FILE)
        if os.path.isfile(sync_server_dir(device, name))
    ]
    if len(dictionaries) != 6:
        raise Fail(f"before the delete, dictionary files on the server: {dictionaries}")
    go(HOME["backup"], SYNC_DELETE)
    screenshot("12-sync-delete")
    found = find_all(nodes(), labels("删除", "Delete", "削除"))
    y, x = found[-1]  # the dialog's button, below its title
    tap(x, y)
    wait_for("the server emptied", lambda: not os.path.isdir(sync_server_dir()), 30)
    go(HOME["backup"])
    wait_for("sync shown as off", lambda: screen_contains(SYNC_OFF), 20)
    screenshot("14-sync-settings")
    return "the button deleted every device's learned words and the 6 dictionary files on the server and turned sync off"


def sync_credentials_private():
    found = []
    if SYNC_PASSWORD in adb("logcat", "-d", timeout=120):
        found.append("logcat")
    if "account" not in root(f"ls {NO_BACKUP}/sync 2>/dev/null; true").split():
        raise Fail(f"no account file in {NO_BACKUP}/sync")
    # grep prints only the names of files with the password or username in plain text.
    plain = root(
        f"grep -rl -e {SYNC_PASSWORD} -e {SYNC_USER} /data/data/{PKG} 2>/dev/null | head -5; true"
    ).split()
    if plain:
        found.append(f"files of the app: {plain}")
    if found:
        raise Fail(f"the login in plain text in {found}")
    return "the login is in no log and no file of the app in plain text (no_backup/sync/account is encrypted)"


def english_strings():
    """SebType's English strings as patterns (%d is any number), and one that isn't SebType's;
    not those that read the same in 日本語 (the name SebType)."""

    def strings(path):
        return {e.get("name"): e for e in ET.parse(os.path.join(HERE, path)).getroot()}

    texts = {"Fuzzy Pinyin"}
    sources = (("../app/src/main/res", "strings-settings.xml", None),)
    for d, f, names in sources:
        ja = strings(f"{d}/values-ja/{f}")
        for name, e in strings(f"{d}/values/{f}").items():
            if (
                (names is None or name in names)
                and e.get("translatable") != "false"
                and (name not in ja or ja[name].text.strip('"') != e.text)
            ):
                texts.add(e.text)
    return [
        re.compile(
            re.escape(t.replace("\\'", "'").replace("\\n", "\n"))
            .replace("%d", r"\d+")
            .replace("%%", "%")
        )
        for t in texts
    ]


def english_on_screen(patterns):
    """The visible labels, or parts of one joined with " · ", ", " or a line break, that are SebType English."""
    found = set()
    for label, *_ in nodes():
        for part in {label, *re.split(r"\n| · |, ", label)}:
            if any(p.fullmatch(part) for p in patterns):
                found.add(part)
    return found


def japanese_ui():
    for f in glob.glob(os.path.join(logdir, "settings-ja-*.png")):
        os.remove(f)  # a last run's extra pages would pass for this run's
    system_locale("ja-JP")
    patterns = english_strings()
    english = {}
    failed = []
    for name, path, marker in SCREENS:
        try:
            go(*path)
            wait_for(f"{name} ({marker[-1]})", lambda m=marker: screen_has(m), 10)
        except Fail as e:
            failed.append(f"{name}: {e}")
        screenshot(f"ja-{name}")
        seen = english_on_screen(patterns)
        # Down the screen too, a page at a time; resizing's page is the keyboard's handles.
        for page in range(2, 6 if name != "resize" else 2):
            before = {label for label, *_ in nodes()}
            adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
            time.sleep(1)
            if {label for label, *_ in nodes()} == before:
                break
            screenshot(f"ja-{name}-{page}")
            seen |= english_on_screen(patterns)
        if seen:
            english[name] = sorted(seen)
    if english:
        failed.append(f"English on {english}")
    if failed:
        raise Fail("; ".join(failed))
    return f"{len(SCREENS)} screens in 日本語, no English SebType string (settings-ja-*.png)"


check("settings-japanese", japanese_ui)
# emulator.sh runs everything else in en-US.
check(
    "settings-locale-back",
    lambda: system_locale("en-US") or "the system is back in en-US",
)

check("incognito-auto-fields", incognito_auto_fields)
check("incognito-private-en", incognito_private_en)
check("incognito-private-ja", incognito_private_ja)
check("incognito-toggle-on", incognito_toggle)
check("incognito-en", incognito_en)
check("incognito-after-restart", incognito_after_restart)
check("incognito-privacy-switch", incognito_privacy_switch)
check("incognito-zh", incognito_zh)
check("incognito-ja", incognito_ja)
check("incognito-clipboard", incognito_clipboard)
check(
    "incognito-badge-tap-off",
    lambda: set_incognito(False) or "a tap on the badge turns incognito off",
)
check("incognito-off-learns-en", learns_again_en)
check("incognito-off-learns-zh", learns_again("ni", "你", "sx"))
check("incognito-off-learns-ja", learns_again("nihongo", "日本語", "hashi"))
try:
    check("sync-setup", sync_setup)
    check("sync-status", sync_status)
    check("sync-offline-learns", sync_offline_learns, needs=["sync-setup"])
    check("sync-online-uploads", sync_online_uploads, needs=["sync-offline-learns"])
    check("sync-other-device", sync_other_device, needs=["sync-online-uploads"])
    check("sync-crash-report", sync_crash_report, needs=["sync-online-uploads"])
    check(
        "sync-personal-dictionaries",
        sync_personal_dictionaries,
        needs=["sync-setup"],
    )
    check("sync-learned-conversions", sync_learned_conversions, needs=["sync-setup"])
    check("sync-credentials-private", sync_credentials_private, needs=["sync-setup"])
    check(
        "sync-delete-on-server",
        sync_delete_on_server,
        needs=["sync-personal-dictionaries"],
    )
finally:
    stop_sync_server()


# --- Personal data import (#11): made-up words only, never anyone's real ones ---

# check: (the file's language, what to type, the word it adds, file name, contents)
PERSONAL_DATA = {
    "import-zh-word-list": (
        "zh",
        "chongyanyan",
        "翀嬿琰",
        "sebtype-11-words.dict.yaml",
        '# made-up test words (#11)\n---\nname: sebtype_test_words\nversion: "1"\n...\n翀嬿琰\tchong yan yan\t1000\n',
    ),
    "import-zh-learned-words": (
        "zh",
        "yanchongyan",
        "琰翀嬿",
        "sebtype-11.userdb.txt",
        (
            "# Rime user dictionary\n#@/db_name\trime_ice\n#@/db_type\tuserdb\n#@/rime_version\t1.16.1\n"
            "#@/tick\t5\n#@/user_id\tsebtype-test-11\nyan chong yan \t琰翀嬿\tc=20 d=20 t=5\n"
        ),
    ),
    "import-ja-mozc": (
        "ja",
        "sebutaipu",
        "瀬武太威符",
        "sebtype-11-mozc.txt",
        "せぶたいぷ\t瀬武太威符\t名詞\t\n",
    ),
    "import-ja-ms-ime": (
        "ja",
        "pigukii",
        "皮具木居",
        "sebtype-11-msime.txt",
        "!Microsoft IME Dictionary Tool\nぴぐきい\t皮具木居\t名詞\n",
    ),
    "import-en-personal-dictionary": (
        "en",
        "zorblefl",
        "zorbleflux",
        "sebtype-11-en.json",
        '[{"word":"zorbleflux","frequency":250,"locale":"en_US","appId":0,"shortcut":null}]',
    ),
}
PROBES = {"zh": ("ni", "你"), "ja": ("nihongo", "日本語"), "en": ("hello", "hello")}


def offered(language, code):
    """The candidates typing code offers, the expanded list's too where there is one."""
    if language == "en":
        open_field()
        type_keys(code)
        return [
            c.lower()
            for c in wait_for(
                f"suggestions for {code}", lambda: en_candidates(nodes()), 30
            )
        ]
    got = candidates_for(code)
    try:
        got += [c for c in expanded_candidates() if c not in got]
    except (Fail, ValueError):  # no expand button
        pass
    return got


def import_done():
    """The import screen closed: it closes itself once the import is done. Only the resumed activity
    counts; the dump keeps finished ones in other lists for a while."""
    dump = adb("shell", "dumpsys", "activity", "activities")
    resumed = [line for line in dump.splitlines() if "ResumedActivity" in line]
    return resumed and not any(IMPORT_ACTIVITY in line for line in resumed)


def drop_personal_word(word):
    """English's personal words go into Android's user dictionary, which outlives the app's uninstall:
    an earlier run's import would already offer the word."""
    adb(
        "shell",
        f"su 0 content delete --uri content://user_dictionary/words --where \"word='{word}'\"",
    )


def import_personal_data(name):
    def run():
        language, code, word, file, text = PERSONAL_DATA[name]
        to_language(*PROBES[language])
        if language == "en":
            drop_personal_word(word)
        before = offered(language, code)
        if word in before:
            raise Fail(f"{code} offers {word} before the import: {before[:5]}")
        local = os.path.join(logdir, file)
        with open(local, "w", encoding="utf-8") as f:
            f.write(text)
        adb("push", local, f"/sdcard/Download/{file}")
        try:
            pick_import(file)
            # The import screen offers the file's language: "<name> (<tag>)".
            row = wait_for(
                f"the import screen's {language} row",
                lambda: next((n for n in nodes() if f"({language}" in n[0]), None),
                30,
            )
            tap(row[1], row[2])
            wait_for("the import to finish", import_done, 300, interval=2)
        finally:
            adb("shell", f"rm -f /sdcard/Download/{file}", check=False)
        to_language(*PROBES[language])

        # Chinese deploys with a new word list in the background, so its words can take a moment.
        def with_word():
            got = offered(language, code)
            return got if word in got else None

        after = wait_for(f"{word} for {code}", with_word, 120, interval=5)
        return f"{code} -> {before[:3]} before, {after[:3]} after importing {file}"

    return run


for name in PERSONAL_DATA:
    check(name, import_personal_data(name))

# Last, in en-US: importing a backup reinstalls the Chinese data in the background.
check("settings-backup-clipboard", backup_clipboard)
check("settings-backup-installation-id", backup_installation_id)
check("settings-backup-rime-fails", backup_rime_fails)
check("settings-backup-setup", backup_setup)
check("settings-backup-screenshots", backup_screenshots)
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
