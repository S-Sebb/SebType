"""Makes the Chinese harness's sets (#259) from held-out, openly licensed text: the test documents of the chat
sources (tools/chinese-lm/common.py's split(): meetings, HundredCV-Chat, Tatoeba, KdConv and oasst2, #557) and
the 200 newest published articles of Chinese Wikinews (news). The dev sets, for tuning, come the same way from
the dev documents and the 400 Wikinews articles before those. Training sees none of them
(tools/chinese-lm/corpus.py leaves them out; overlap.py checks).

  make_sets.py SRC_DIR READINGS OUT_DIR [--dev]

SRC_DIR is a training run's data/src (tools/chinese-lm/fetch.sh), READINGS its data/readings.tsv
(common.py readings). Each set is a TSV of `context<TAB>keys<TAB>target<TAB>note`: the field's text before the
item, the letters typed, the text meant, and the note: for typos and variants their kind, for clauses their
words. A chat set takes its items from the sources by QUOTA, the others filling in for one that runs out.
Seed 259; the same sources give the same sets. The pinyin is read for the item's whole clause (common.reading).

| Set | Items | What is typed |
|---|---|---|
| sent-chat, sent-news | 800 each | a clause of 2-12 Han characters in full pinyin |
| long-chat, long-news | 200 each | a clause of 13-25 Han characters in full pinyin, about as many of each length (#563) |
| long-typo-chat, long-typo-news | 199-200 | long-chat's and long-news's clauses with typos as typo's (an item a typo leaves as it was is left out) |
| fuzzy-chat, fuzzy-news | 300 each at most | sent's and long's clauses with 2 or more of zh, ch, sh, each typed as z, c, s, as fuzzy pinyin's users type them |
| abbr-chat, abbr-news | 400 each | a 2-4-character word as its syllables' first letters (zd → 知道) |
| partial-chat, partial-news | 400 each | a 2-4-character word in full pinyin but its last syllable's first letter (ranh → 然后) |
| typo | 800 (500 chat, 300 news) | a clause of 2-8 characters with one phone typo or pinyin confusion (10 % two) |
| next-chat, next-news | 1,500 and 1,000 | nothing: the next word (jieba's) after the text before it |
| variants | up to 300 (100 each) | spellings that training's pinyin didn't have before #557: lue/nue for lve/nve and zh/ch/sh whole in abbreviations (chsh → 城市), which Rime takes, and one of the app's other fuzzy pairs (l/n, f/h, r/l, k/g), which it takes only when the user turns that pair on (off by default, as here: a typo to fix) |
"""

import itertools
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools/chinese-lm"))
import common
import jieba

jieba.setLogLevel(60)
CONTEXT = 64  # characters of the field's text kept before an item
QUOTA = {
    "meetings": 0.4,
    "hundredcv": 0.2,
    "tatoeba": 0.2,
    "kdconv": 0.1,
    "oasst2": 0.1,
}


def texts(src, dev):
    """The held-out texts of each pool (chat by source), and the Wikinews articles they come from."""
    split = "dev" if dev else "test"
    chat = {s: [] for s in QUOTA}
    for source, s, _, turns in common.chat(src):
        if s == split:
            chat[source] += [t for t in map(common.clean, turns) if t]
    arts = common.news_split(src)[split]
    news = [t for _, _, ps in arts for t in map(common.clean, ps) if t]
    return {"chat": chat, "news": news}, [(i, title) for i, title, _ in arts]


def pooled(rng, pool, make, *args):
    """MAKE's items from POOL; a chat pool's from each source, mixed by QUOTA (mix())."""
    if isinstance(pool, dict):
        return mix({s: make(rng, p, *args) for s, p in pool.items()})
    return make(rng, pool, *args)


def mix(lists):
    """LISTS' items in turn, each source's share of any first items its QUOTA while it has items left."""
    at = {s: 0 for s in lists}
    out = []
    while True:
        left = [s for s in lists if at[s] < len(lists[s])]
        if not left:
            return out
        s = min(left, key=lambda s: (at[s] / QUOTA[s], s))
        out.append(lists[s][at[s]])
        at[s] += 1


def clause_items(rng, pool, lo, hi):
    out = []
    for text in pool:
        for start, c in common.clauses(text):
            if lo <= len(c) <= hi:
                sy = common.syllables(c)
                if sy:
                    out.append((text[max(0, start - CONTEXT) : start], c, sy))
    rng.shuffle(out)
    return out


def spread(items, lo, hi):
    """ITEMS (shuffled), a clause of each length from LO to HI in turn, so long ones aren't drowned out."""
    by = [[it for it in items if len(it[1]) == n] for n in range(lo, hi + 1)]
    return [it for row in itertools.zip_longest(*by) for it in row if it]


def word_items(rng, pool):
    out = []
    for text in pool:
        at, reading = 0, common.reading(text)
        for w in jieba.cut(text):
            if 2 <= len(w) <= 4 and common.HAN_RUN.fullmatch(w):
                sy = reading[at : at + len(w)]
                if None not in sy:
                    out.append((text[max(0, at - CONTEXT) : at], w, sy))
            at += len(w)
    rng.shuffle(out)
    return out


def next_items(rng, pool, per_text):
    out = []
    for text in pool:
        words, at, here = list(jieba.cut(text)), 0, []
        for w in words:
            if at >= 2 and len(w) <= 4 and common.HAN_RUN.fullmatch(w):
                here.append((text[max(0, at - CONTEXT) : at], w))
            at += len(w)
        out += rng.sample(
            here, min(per_text, len(here))
        )  # a few from each text, for variety
    rng.shuffle(out)
    return out


def with_typo(rng, sy):
    """The keys for the syllables SY with one phone typo or pinyin confusion (10 % two), and their kinds."""
    keys, kind = common.typo(rng, sy)
    if rng.random() < 0.1:
        keys, kind2 = common.typo(
            rng, [keys], rng.choice(["slip", "omit", "double", "swap"])
        )
        kind += "+" + kind2
    return keys, kind


def fuzzy(sy):
    """The keys for the syllables SY with each zh, ch and sh typed as z, c and s, and how many were."""
    out = [x[0] + x[2:] if x[:2] in ("zh", "ch", "sh") else x for x in sy]
    return "".join(out), sum(x != y for x, y in zip(sy, out))


def unique(items, n, key, partial=False):
    """The first N items with distinct KEYs (with PARTIAL, as many as there are, up to N)."""
    seen, out = set(), []
    for it in items:
        k = key(it)
        if k not in seen:
            seen.add(k)
            out.append(it)
        if len(out) == n:
            return out
    if partial:
        return out
    raise SystemExit(f"only {len(out)} items for a set of {n}")


def write(path, rows):
    path.write_text("".join("\t".join(r) + "\n" for r in rows), encoding="utf-8")


def main():
    src, readings, out = sys.argv[1:4]
    dev = "--dev" in sys.argv
    common.use_readings(readings)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(2590 if dev else 259)
    pools, arts = texts(src, dev)
    prefix = "dev-" if dev else ""
    scale = 0.5 if dev else 1
    write(out / f"{prefix}wikinews-articles.tsv", [(str(i), t) for i, t in arts])
    typos, sents, words_all, short_all = [], {}, [], []
    # News has fewer, longer texts: more next words come from each paragraph.
    for src, n_typo, n_next, per_text in (
        ("chat", 500, 1500, 2),
        ("news", 300, 1000, 8),
    ):
        clauses = pooled(rng, pools[src], clause_items, 2, 12)
        sent = unique(clauses, int(800 * scale), lambda x: x[1])
        sents[src] = sent
        # The note: the clause's words (jieba), for the word accuracy.
        write(
            out / f"{prefix}sent-{src}.tsv",
            [(c, "".join(sy), t, " ".join(jieba.cut(t))) for c, t, sy in sent],
        )
        words = pooled(rng, pools[src], word_items)
        abbr = unique(words, int(400 * scale), lambda x: x[1])
        write(
            out / f"{prefix}abbr-{src}.tsv",
            [(c, common.abbreviated(sy), t, "") for c, t, sy in abbr],
        )
        part = unique(words[len(words) // 2 :], int(400 * scale), lambda x: x[1])
        write(
            out / f"{prefix}partial-{src}.tsv",
            [(c, common.partial(sy), t, "") for c, t, sy in part],
        )
        short = [x for x in clauses if len(x[1]) <= 8]
        for c, t, sy in unique(short[::-1], int(n_typo * scale), lambda x: x[1]):
            keys, kind = with_typo(rng, sy)
            if keys != "".join(sy):
                typos.append((c, keys, t, kind))
        nxt = unique(
            pooled(rng, pools[src], next_items, per_text),
            int(n_next * scale),
            lambda x: x,
        )
        write(out / f"{prefix}next-{src}.tsv", [(c, "", w, "") for c, w in nxt])
        words_all += words
        short_all += short
    write(out / f"{prefix}typo.tsv", typos)
    # Clauses longer than the sentence sets' (#563), with a generator of their own.
    rng = random.Random(5630 if dev else 563)
    # Their typos too (Rime splits a misspelled syllable: xiagn as xia g n), with another.
    slips = random.Random(5631 if dev else 5632)
    for src in ("chat", "news"):
        long = unique(
            spread(pooled(rng, pools[src], clause_items, 13, 25), 13, 25),
            int(200 * scale),
            lambda x: x[1],
        )
        write(
            out / f"{prefix}long-{src}.tsv",
            [(c, "".join(sy), t, " ".join(jieba.cut(t))) for c, t, sy in long],
        )
        typed = [(c, *with_typo(slips, sy), t, "".join(sy)) for c, t, sy in long]
        write(
            out / f"{prefix}long-typo-{src}.tsv",
            [(c, keys, t, kind) for c, keys, kind, t, full in typed if keys != full],
        )
        # Fuzzy pinyin typed throughout (#563): the clauses above with two zh/ch/sh or more, long ones first.
        typed = [(c, *fuzzy(sy), t) for c, t, sy in long + sents[src]]
        write(
            out / f"{prefix}fuzzy-{src}.tsv",
            [(c, keys, t, f"{n} z/c/s") for c, keys, n, t in typed if n >= 2][
                : int(300 * scale)
            ],
        )
    # Spellings Rime takes that the training letters lacked before #557, chat and news together.
    rng = random.Random(5570 if dev else 557)
    rng.shuffle(words_all)
    rng.shuffle(short_all)
    n = int(100 * scale)
    ue = [x for x in words_all if any(y in ("lve", "nve") for y in x[2])]
    chsh = [x for x in words_all if any(y[:2] in ("zh", "ch", "sh") for y in x[2])]
    rows = [
        (c, common.ue("".join(sy)), t, "ue")
        for c, t, sy in unique(ue, n, lambda x: x[1], partial=True)
    ]
    rows += [
        (c, common.abbreviated(sy, True), t, "zh/ch/sh abbreviated")
        for c, t, sy in unique(chsh, n, lambda x: x[1], partial=True)
    ]
    fz = [(c, t, f) for c, t, sy in short_all if (f := common.fuzzy(rng, sy))]
    rows += [
        (c, "".join(f), t, "fuzzy")
        for c, t, f in unique(fz, n, lambda x: x[1], partial=True)
    ]
    write(out / f"{prefix}variants.tsv", rows)


if __name__ == "__main__":
    main()
