#!/usr/bin/env python3
"""Settings checks on the emulator (#41), run by sebtype/test-emulator.sh under the emulator lock after
test-chinese.py, which leaves SebType installed, chosen as the keyboard and Chinese set up.

    test-settings.py SERIAL RESULTS LOGDIR

Opens every settings screen from the home screen (one screenshot each, settings-<screen>.png in
LOGDIR), then checks that SebType's own options take effect while typing: the globe order, Chinese
full-width punctuation, emoji among Chinese candidates, Chinese "My words", and forgetting learned
words in Chinese and Japanese. Labels match the emulator's Chinese UI or English. One line per check
appended to RESULTS; each check finds its own way from the home screen, so one failing doesn't
stop the next.
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

serial, results_path, logdir = sys.argv[1:4]
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
# The emulator's Gboard, for typing into SebType's own settings: with SebType in Chinese, Rime would
# compose the letters instead.
GBOARD = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"
SETTINGS = f"{PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity"
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
PREPARING = ("正在准备中文", "Preparing Chinese")
NOT_CANDIDATES = (*PREPARING, "中文输入启动失败", "Chinese input failed")
log_path = os.path.join(logdir, "test-settings.log")


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


# --- The keyboard (as in test-chinese.py) ---

keyboard_frame = None


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
    return {
        label: (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-z]", label)
    }


def bottom_key(column):
    """A bottom-row key by its centre, in tenths of the keyboard's width: the globe sits at 3, the
    Chinese layout's 。 key at 8 (symbols 1.5, ， 1, globe 1, space 4, 。 1, enter 1.5)."""
    left, top, right, bottom = keyboard_frame
    tap(int(left + column * (right - left) / 10), int(top + 3.5 * (bottom - top) / 4))


def candidates(ns):
    k = keys(ns)
    if "q" not in k:
        return []
    row = (k["q"][2] - 130, k["q"][2])
    bar = [
        (x, label)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1]
        and cls == "android.widget.TextView"
        and label
        and not label.startswith(NOT_CANDIDATES)
        and label not in ("あ", "ア")
    ]
    return [label for x, label in sorted(bar)]


def expanded_candidates():
    ns = nodes()
    k = keys(ns)
    row = (k["q"][2] - 130, k["q"][2])
    button = max(
        (x, y)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1] and cls == "android.widget.Button"
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
    k = wait_for("the keyboard", lambda: keys(nodes()), 30)
    for ch in text:
        tap(k[ch][0], k[ch][1])
    time.sleep(1.5)


def open_field():
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "ime", "set", IME)
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD)
    wait_for("the keyboard", lambda: keys(nodes()), 30)


def candidates_for(text, expand=False):
    open_field()
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
    """Cycles the globe until typing probe offers word (中: ni -> 你, 日: nihongo -> 日本語)."""
    for _ in range(8):
        try:
            open_field()
            type_keys(probe)
            # Chinese sets itself up the first time it comes up, showing its notice meanwhile.
            end = time.time() + 300
            while True:
                ns = nodes()
                if word in candidates(ns):
                    return
                preparing = any(n[0].startswith(PREPARING) for n in ns)
                if not preparing or time.time() > end:
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
    "languages": labels("语言", "Languages"),
    "keyboard": labels("键盘", "Keyboard"),
    "theme": labels("主题", "Theme"),
    "privacy": labels("隐私", "Privacy"),
    "backup": labels("同步与备份", "Sync & backup"),
    "about": labels("关于", "About"),
}
MY_WORDS = labels("我的词语", "My words")
FULL_WIDTH = labels("全角标点", "Full-width punctuation")
EMOJI = labels("候选词中显示表情", "Emoji in candidates")


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
    wait_for("the settings home screen", lambda: screen_has(HOME["about"]), 30)


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


def check(name, fn):
    try:
        detail = fn()
        result("PASS", name, detail or "")
    except (
        Fail,
        RuntimeError,
        subprocess.SubprocessError,
        ET.ParseError,
        LookupError,
        ValueError,
    ) as e:
        result("FAIL", name, str(e))


# Every screen: how to get there from home, and a text only it shows.
LANG = HOME["languages"]
SCREENS = [
    ("home", (), labels("同步与备份", "Sync & backup")),
    ("languages", (LANG,), labels("地球键顺序", "Globe order")),
    (
        "en-words",
        (LANG, (MY_WORDS, 0)),
        labels("添加", '"添加"', "Add", "Words", "词语"),
    ),
    (
        "zh-fuzzy",
        (LANG, labels("Fuzzy Pinyin", "模糊拼音")),
        labels("zh=z", "zh = z", "z=zh", "z = zh", "zh, ch, sh"),
    ),
    ("zh-words", (LANG, (MY_WORDS, 1)), labels("还没有词语", "No words yet")),
    (
        "ja-words",
        (LANG, (MY_WORDS, 2)),
        labels("添加", '"添加"', "Add", "Words", "词语"),
    ),
    ("keyboard", (HOME["keyboard"],), labels("尺寸和位置", "Size and position")),
    (
        "resize",
        (HOME["keyboard"], labels("尺寸和位置", "Size and position")),
        labels("调整键盘大小", "Resize Keyboard"),
    ),
    (
        "action-bar",
        (HOME["keyboard"], labels("操作栏按钮", "Action bar buttons")),
        labels("编辑快捷方式", "Edit Actions"),
    ),
    ("theme", (HOME["theme"],), labels("主题", "Theme")),
    ("privacy", (HOME["privacy"],), labels("从我的输入中学习", "Learn from my typing")),
    (
        "forget",
        (HOME["privacy"], labels("忘记学到的词", "Forget learned words")),
        labels("忘记", "Forget"),
    ),
    ("backup", (HOME["backup"],), labels("导出设置", "Export settings")),
    ("about", (HOME["about"],), labels("版本", "Version")),
    (
        "credits",
        (HOME["about"], labels("许可与致谢", "Licence and credits")),
        labels("Credits", "致谢"),
    ),
    (
        "payment",
        (HOME["about"], labels("支持 FUTO", "Support FUTO")),
        labels("为FUTO Keyboard支付", "Pay for FUTO Keyboard"),
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


def add_my_word(word, pinyin):
    go(LANG, (MY_WORDS, 1))
    tap_text(labels("添加", '"添加"', "Add"))
    adb("shell", "ime", "set", GBOARD)
    fields = [
        (y, x) for label, x, y, top, cls in nodes() if cls == "android.widget.EditText"
    ]
    for (y, x), text in zip(sorted(fields), (word, pinyin)):
        tap(x, y)
        adb("shell", "input", "text", text)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)  # hides the keyboard
    time.sleep(1)
    tap_text(labels("保存", "Save"))
    adb("shell", "ime", "set", IME)


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
    go(HOME["privacy"], labels("忘记学到的词", "Forget learned words"))
    tap_text(language)
    found = find_all(nodes(), labels("忘记", "Forget"))
    y, x = found[-1]  # the dialog's button, below the dialog title
    tap(x, y)
    time.sleep(3)


def forget_chinese():
    to_language("ni", "你")
    got = candidates_for("lh", expand=True)
    if got[0] != "厉害":
        tap_candidate("厉害")
    learned = candidates_for("lh")[:3]
    forget(labels("中文"))
    after = candidates_for("lh")[:3]
    if learned[0] != "厉害" or after[0] == "厉害":
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


adb("logcat", "-c")
check("settings-screens", every_screen)
check("settings-globe-order", globe_order)
check("settings-zh-punctuation", full_width_punctuation)
check("settings-zh-emoji", emoji_candidates)
check("settings-zh-my-words", my_words)
check("settings-zh-forget", forget_chinese)
check("settings-ja-forget", forget_japanese)
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
