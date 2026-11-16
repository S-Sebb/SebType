"""What the corpus, the training data and the harness's sets share: the sources' text cleaned the same way,
clauses, the pinyin typed for a text, and the typos made in it.

Pinyin is pypinyin's (full pinyin as rime-ice spells it: ü as v, so 绿 is lv), one syllable per Han character.
A typo follows the phone error mix of #46 (data/rime/bench/make-typos.py: touch slips on SebType's key grid,
missing, extra and swapped letters) with the pinyin confusions added: zh/z, ch/c, sh/s and ng/n, either way.
"""

import bz2
import gzip
import json
import re
import xml.etree.ElementTree as ET

import opencc

HAN = re.compile(r"[㐀-䶿一-鿿]")
HAN_RUN = re.compile(r"[㐀-䶿一-鿿]+")
# Spaces LCCC puts between characters, and any between two Han characters elsewhere.
CJK_SPACE = re.compile(r"(?<=[^\x00-\x7f]) +| +(?=[^\x00-\x7f])")
BAD = re.compile(r"https?:|www\.|[`{}<>|@#\\^~_\[\]=*]|\.\w{2,4}/")
_t2s = opencc.OpenCC("t2s")


def clean(s):
    """The text in simplified characters with Chinese spacing, or None when it isn't a line of Chinese."""
    s = CJK_SPACE.sub("", " ".join(s.split()))
    if not s or BAD.search(s) or not s.isprintable():
        return None
    if len(HAN.findall(s)) < 0.5 * len(s):
        return None
    return _t2s.convert(s)


def lccc(path):
    """Each dialogue of an LCCC file as its turns."""
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            yield json.loads(line)


def wikinews(path):
    """Each article of a Wikinews dump as (page id, title, paragraphs), the wikitext made plain."""
    import mwparserfromhell

    ns = "{http://www.mediawiki.org/xml/export-0.11/}"
    with bz2.open(path, "rb") as f:
        for _, el in ET.iterparse(f):
            if el.tag != ns + "page":
                continue
            text = el.findtext(f"{ns}revision/{ns}text") or ""
            if (
                el.findtext(ns + "ns") == "0"
                and el.find(ns + "redirect") is None
                and "{{Publish" in text
            ):
                title = el.findtext(ns + "title")
                yield (
                    int(el.findtext(ns + "id")),
                    title,
                    paragraphs(mwparserfromhell, text),
                )
            el.clear()


def paragraphs(mw, text):
    # The article's body ends at its first section (sources, links).
    body = re.split(r"\n==", text, maxsplit=1)[0]
    out = []
    for p in body.split("\n"):
        p = p.strip()
        if (
            not p
            or p[0] in "*#:;{|!="
            or p.startswith("[[Category")
            or p.startswith("[[File")
        ):
            continue
        plain = mw.parse(p).strip_code().strip()
        if plain:
            out.append(plain)
    return out


def clauses(s):
    """(start, clause) for each run of Han characters in S."""
    return [(m.start(), m.group()) for m in HAN_RUN.finditer(s)]


# --- pinyin ---------------------------------------------------------------------------------------------


def syllables(text):
    """One pinyin syllable per character of TEXT, all Han."""
    from pypinyin import Style, lazy_pinyin

    p = lazy_pinyin(text, style=Style.NORMAL, errors=lambda x: ["?"] * len(x))
    return (
        p
        if len(p) == len(text) and all(x.isalpha() and x.isascii() for x in p)
        else None
    )


def initial(syllable):
    return syllable[0]


def abbreviated(sy):
    """Each syllable's first letter: 知道 → zd, as rime-ice's abbreviations take it."""
    return "".join(initial(x) for x in sy)


def partial(sy):
    """Full pinyin but the last syllable's first letter: 然后 → ranh."""
    return "".join(sy[:-1]) + initial(sy[-1])


# --- typos ----------------------------------------------------------------------------------------------

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
PHONE = {
    k: ((i + (0, 0.5, 1.5)[r]) * 108 + 54, r * 160 + 80)
    for r, row in enumerate(ROWS)
    for i, k in enumerate(row)
}
SIGMA_PX = 1.9 / (6.8 / 108)
CONFUSIONS = [("zh", "z"), ("ch", "c"), ("sh", "s"), ("ng", "n")]
# Of the typos: the phone mix of #46 (slips, missing, extra, swapped as 55.6 : 33.3 : 11.1 of 94 %, swaps 6 %),
# with a fifth of them a pinyin confusion instead. An extra letter is the key doubled or a slip next to it.
KINDS = ["slip", "omit", "double", "swap", "confuse"]
WEIGHTS = [55.6 * 0.94 * 0.8, 33.3 * 0.94 * 0.8, 11.1 * 0.94 * 0.8, 6 * 0.8, 20]


def slip(rng, k):
    if k not in PHONE:
        return k
    while True:
        x, y = PHONE[k]
        tx, ty = rng.gauss(x, SIGMA_PX), rng.gauss(y, SIGMA_PX)
        j = min(PHONE, key=lambda c: (PHONE[c][0] - tx) ** 2 + (PHONE[c][1] - ty) ** 2)
        if j != k:
            return j


def confuse(rng, sy):
    """One syllable's zh/z, ch/c, sh/s or ng/n turned into the other, or None when it has none."""
    options = []
    for i, x in enumerate(sy):
        for full, short in CONFUSIONS:
            if full in ("zh", "ch", "sh"):
                if x.startswith(full):
                    options.append((i, short + x[2:]))
                elif x.startswith(short) and not x.startswith(short + "h"):
                    options.append((i, full + x[1:]))
            elif x.endswith("ng"):
                options.append((i, x[:-1]))
            elif x.endswith("n") and x[-2:] in ("an", "en", "in"):
                options.append((i, x + "g"))
    if not options:
        return None
    i, y = rng.choice(options)
    return sy[:i] + [y] + sy[i + 1 :]


def typo(rng, sy, kind=None):
    """KEYS for the syllables SY with one typo of KIND (drawn from the mix when None), and the kind."""
    kind = kind or rng.choices(KINDS, WEIGHTS)[0]
    if kind == "confuse":
        c = confuse(rng, sy)
        if c:
            return "".join(c), kind
        kind = "slip"
    s = "".join(sy)
    i = rng.randrange(len(s))
    if kind == "slip":
        return s[:i] + slip(rng, s[i]) + s[i + 1 :], kind
    if kind == "omit":
        return (s[:i] + s[i + 1 :] if len(s) > 1 else s), kind
    if kind == "double":
        extra = s[i] if rng.random() < 0.5 else slip(rng, s[i])
        return s[:i] + extra + s[i:], kind
    js = [p for p in range(len(s) - 1) if s[p] != s[p + 1]]
    if not js:
        return s[:i] + slip(rng, s[i]) + s[i + 1 :], "slip"
    i = rng.choice(js)
    return s[:i] + s[i + 1] + s[i] + s[i + 2 :], kind
