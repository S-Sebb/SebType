"""Builds the English harness's test sets (#231) from openly licensed text; run.sh reads the committed result.

  make_sets.py OASST1_PROMPTS_JSONL_GZ MISSPELLINGS_TXT WIKINEWS_JSON OUT_DIR

WIKINEWS_JSON is a cache: fetched from Wikinews's API when it doesn't exist.

Sentences come from OpenAssistant oasst1's prompts (chat, Apache-2.0) and the last English Wikinews articles
(news, CC BY 2.5); misspellings from Wikipedia's machine-readable list (CC BY-SA 4.0). Each set is a TSV:
context, typed letters, intended word, then the touch points' x and y (comma-separated, layout.tsv's pixels).

- next-chat, next-news: every lowercase word after the first in 250 chat and 150 news sentences, with nothing
  typed: the next word to predict.
- clean: 1,000 such words typed with touch noise that stays on the intended keys.
- phone-typos: 1,000 such words with one typo, or two in 10 % of them, in #46's phone mix (Palin et al.
  MobileHCI 2019): substitution 55.6 %, omission 33.3 %, insertion 11.1 % of the other errors; 6 % swaps.
  A substitution or a neighbour insertion is a tap that lands on another key.
- misspellings: 1,500 of Wikipedia's common misspellings, typed on their own keys with no context.

Taps are a Gaussian around the key centre with sigma 30 px (1.9 mm on #46's 108 px, 6.8 mm keys). Each set
uses its own sentences; the seed is fixed, so the same inputs give the same files.
"""

import gzip
import json
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIGMA = 30.0
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
ASCII = str.maketrans(
    {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", " ": " "}
)


def load_layout():
    keys = []
    for line in (HERE / "layout.tsv").read_text().splitlines():
        if line and not line.startswith("#"):
            k, x, y, w, h = line.split("\t")
            keys.append((k, int(x), int(y), int(w), int(h)))
    return keys


KEYS = load_layout()
LETTERS = {k: (x, y, w, h) for k, x, y, w, h in KEYS if len(k) == 1 and k.isalpha()}


def key_at(x, y):
    for k, kx, ky, w, h in KEYS:
        if kx <= x < kx + w and ky <= y < ky + h:
            return k
    return None


def tap(rng, letter, on_key):
    """A tap aimed at LETTER: on its key if ON_KEY, else on another letter's key. Returns (key, x, y)."""
    x, y, w, h = LETTERS[letter]
    while True:
        px, py = round(rng.gauss(x + w / 2, SIGMA)), round(rng.gauss(y + h / 2, SIGMA))
        k = key_at(px, py)
        if k in LETTERS and (k == letter) == on_key:
            return k, px, py


def sentences(texts):
    for text in texts:
        for s in re.split(r"(?<=[.!?])\s+|\n+", text.translate(ASCII)):
            s = s.strip()
            if (
                s.isascii()
                and 5 <= len(s.split()) <= 30
                and s[0].isupper()
                and s[-1] in ".!?"
                and not re.search(r"https?:|www\.|[`{}<>|@#*_\[\]\\]", s)
            ):
                yield s


def targets(s):
    """(context, word) for each lowercase word after the first that stands alone between spaces/punctuation."""
    for m in WORD.finditer(s):
        w, i, j = m.group(), m.start(), m.end()
        if (
            i > 0
            and s[i - 1] == " "
            and w.isalpha()
            and w.islower()
            and len(w) >= 2
            and (j == len(s) or s[j] in " .,!?;:")
        ):
            yield s[:i].rstrip(), w


def row(context, typed, target, taps=()):
    return "\t".join(
        (
            context,
            typed,
            target,
            ",".join(str(x) for _, x, _ in taps),
            ",".join(str(y) for _, _, y in taps),
        )
    )


def typo(rng, word):
    """WORD typed with one error, or two in 10 % of words; returns the taps, never WORD itself."""
    while True:
        taps = [tap(rng, c, True) for c in word]
        for _ in range(2 if rng.random() < 0.10 else 1):
            i = rng.randrange(len(taps))
            r = rng.random()
            if r < 0.06 and len(taps) > 1:  # swap with the next letter
                i = min(i, len(taps) - 2)
                taps[i], taps[i + 1] = taps[i + 1], taps[i]
            elif (
                r < 0.06 + 0.94 * 0.556
            ):  # substitution: the tap slips onto another key
                taps[i] = tap(rng, taps[i][0], False)
            elif r < 0.06 + 0.94 * (0.556 + 0.333) and len(taps) > 1:  # omission
                del taps[i]
            elif rng.random() < 0.5:  # insertion: the same key twice
                taps.insert(i, tap(rng, taps[i][0], True))
            else:  # insertion: a neighbour hit with the intended key
                taps.insert(i + rng.randrange(2), tap(rng, taps[i][0], False))
        typed = "".join(k for k, _, _ in taps)
        if typed != word:
            return typed, taps


def fetch_wikinews(path, n=200):
    """The last N articles published on English Wikinews (closed in 2026, so the list no longer changes)."""

    def get(**params):
        url = "https://en.wikinews.org/w/api.php?" + urllib.parse.urlencode(
            {"format": "json", **params}
        )
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "SebType-english-harness/1.0 (S-Sebb/SebType#231)"},
        )
        for wait in (2, 10, 30, 60, 120):
            time.sleep(wait)
            try:
                return json.load(urllib.request.urlopen(req, timeout=60))
            except urllib.error.HTTPError as e:
                if e.code != 429:
                    raise
        raise RuntimeError(f"Wikinews keeps answering 429 to {url}")

    titles, cont = [], {}
    while len(titles) < n:
        r = get(
            action="query",
            list="categorymembers",
            cmtitle="Category:Published",
            cmtype="page",
            cmsort="timestamp",
            cmdir="desc",
            cmlimit=50,
            **cont,
        )
        titles += [m["title"] for m in r["query"]["categorymembers"]]
        cont = r["continue"]
    articles = []
    for t in titles[:n]:
        page = next(
            iter(
                get(
                    action="query",
                    prop="extracts|revisions",
                    explaintext=1,
                    rvprop="ids",
                    titles=t,
                )["query"]["pages"].values()
            )
        )
        articles.append(
            {
                "title": t,
                "revid": page["revisions"][0]["revid"],
                "text": page["extract"],
            }
        )
    Path(path).write_text(json.dumps(articles))


def main(oasst, misspellings, wikinews, out):
    out = Path(out)
    if not Path(wikinews).exists():
        fetch_wikinews(wikinews)
    rng = random.Random(231)
    chat_texts = [
        m["text"]
        for m in map(
            json.loads, gzip.decompress(Path(oasst).read_bytes()).decode().splitlines()
        )
        if m.get("lang") == "en"
    ]
    news = json.loads(Path(wikinews).read_text())
    chat = list(dict.fromkeys(sentences(chat_texts)))
    news_s = list(dict.fromkeys(sentences(a["text"] for a in news)))
    rng.shuffle(chat)
    rng.shuffle(news_s)
    chat = [s for s in chat if any(targets(s))]
    news_s = [s for s in news_s if any(targets(s))]

    sets = {"next-chat": chat[:250], "next-news": news_s[:150]}
    for name, pool in sets.items():
        (out / f"{name}.tsv").write_text(
            "".join(row(c, "", w) + "\n" for s in pool for c, w in targets(s))
        )

    # Word sets: one word from each of their own sentences, 60 % chat and 40 % news, none shared with another set.
    cursor = {"chat": 250, "news": 150}
    pools = {"chat": chat, "news": news_s}

    def words(n, min_len):
        picked = []
        for source, count in (("chat", n * 6 // 10), ("news", n - n * 6 // 10)):
            got = 0
            while got < count:
                s = pools[source][cursor[source]]
                cursor[source] += 1
                ts = [t for t in targets(s) if len(t[1]) >= min_len]
                if ts:
                    picked.append(rng.choice(ts))
                    got += 1
        return picked

    clean = words(1000, 2)
    (out / "clean.tsv").write_text(
        "".join(row(c, w, w, [tap(rng, ch, True) for ch in w]) + "\n" for c, w in clean)
    )
    typos = words(1000, 3)
    (out / "phone-typos.tsv").write_text(
        "".join(
            row(c, t, w, taps) + "\n" for c, w in typos for t, taps in [typo(rng, w)]
        )
    )

    pairs = sorted(
        {
            (a, b)
            for a, b in (
                line.strip().split("->", 1)
                for line in Path(misspellings).read_text().splitlines()
                if "->" in line
            )
            if a.isalpha()
            and b.isalpha()
            and a.islower()
            and b.islower()
            and len(a) >= 3
        }
    )
    picked = rng.sample(pairs, 1500)
    (out / "misspellings.tsv").write_text(
        "".join(
            row("", a, b, [tap(rng, ch, True) for ch in a]) + "\n" for a, b in picked
        )
    )
    (out / "wikinews-articles.tsv").write_text(
        "".join(f"{a['revid']}\t{a['title']}\n" for a in news)
    )
    for f in sorted(out.glob("*.tsv")):
        print(f"{f.name}: {len(f.read_text().splitlines())} rows")


if __name__ == "__main__":
    main(*sys.argv[1:])
