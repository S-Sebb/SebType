"""Makes the Chinese harness's sets (#259) from held-out, openly licensed text: LCCC-base's test dialogues (chat)
and the 200 newest published articles of Chinese Wikinews (news). The dev sets, for tuning, come the same way
from LCCC-base's validation dialogues and the 400 Wikinews articles before those. Training sees none of them
(tools/chinese-lm/corpus.py leaves them out; overlap.py checks).

  make_sets.py LCCC_DIR WIKINEWS_DUMP OUT_DIR [--dev]

Each set is a TSV of `context<TAB>keys<TAB>target<TAB>note`: the field's text before the item, the letters
typed, the text meant, and the note: for typos their kind, for clauses their words. Seed 259; the same sources give the same sets.

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


def texts(lccc_dir, dump, dev):
    """The held-out texts of each pool, and the Wikinews articles they come from."""
    split = "valid" if dev else "test"
    chat = []
    for turns in common.lccc(f"{lccc_dir}/lccc_base_{split}.jsonl.gz"):
        chat += [t for t in map(common.clean, turns) if t]
    arts = sorted(common.wikinews(dump), reverse=True)
    arts = arts[200:600] if dev else arts[:200]
    news = [t for _, _, ps in arts for t in map(common.clean, ps) if t]
    return {"chat": chat, "news": news}, [(i, title) for i, title, _ in arts]


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
        at = 0
        for w in jieba.cut(text):
            if 2 <= len(w) <= 4 and common.HAN_RUN.fullmatch(w):
                sy = common.syllables(w)
                if sy:
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


def unique(items, n, key):
    seen, out = set(), []
    for it in items:
        k = key(it)
        if k not in seen:
            seen.add(k)
            out.append(it)
        if len(out) == n:
            return out
    raise SystemExit(f"only {len(out)} items for a set of {n}")


def write(path, rows):
    path.write_text("".join("\t".join(r) + "\n" for r in rows), encoding="utf-8")


def main():
    lccc_dir, dump, out = sys.argv[1:4]
    dev = "--dev" in sys.argv
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(2590 if dev else 259)
    pools, arts = texts(lccc_dir, dump, dev)
    prefix = "dev-" if dev else ""
    scale = 0.5 if dev else 1
    write(out / f"{prefix}wikinews-articles.tsv", [(str(i), t) for i, t in arts])
    typos, sents = [], {}
    # News has fewer, longer texts: more next words come from each paragraph.
    for src, n_typo, n_next, per_text in (
        ("chat", 500, 1500, 2),
        ("news", 300, 1000, 8),
    ):
        clauses = clause_items(rng, pools[src], 2, 12)
        sent = unique(clauses, int(800 * scale), lambda x: x[1])
        sents[src] = sent
        # The note: the clause's words (jieba), for the word accuracy.
        write(
            out / f"{prefix}sent-{src}.tsv",
            [(c, "".join(sy), t, " ".join(jieba.cut(t))) for c, t, sy in sent],
        )
        words = word_items(rng, pools[src])
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
            next_items(rng, pools[src], per_text), int(n_next * scale), lambda x: x
        )
        write(out / f"{prefix}next-{src}.tsv", [(c, "", w, "") for c, w in nxt])
    write(out / f"{prefix}typo.tsv", typos)
    # Clauses longer than the sentence sets' (#563), with a generator of their own so the sets above stay
    # as they were.
    rng = random.Random(5630 if dev else 563)
    # Their typos too (Rime splits a misspelled syllable: xiagn as xia g n), with another.
    slips = random.Random(5631 if dev else 5632)
    for src in ("chat", "news"):
        long = unique(
            spread(clause_items(rng, pools[src], 13, 25), 13, 25),
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


if __name__ == "__main__":
    main()
