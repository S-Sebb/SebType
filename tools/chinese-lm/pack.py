"""Turns the corpus into training tokens, with pinyin examples in the text and word boundaries beside it.

  pack.py RUN_DIR SPLIT SEED [-SOURCE...]       SPLIT: train or dev; -SOURCE leaves a chat source out (a pilot)

Writes RUN_DIR/data/SPLIT.SEED.bin (uint16 token ids, each segment as <s> text </s>) and SPLIT.SEED.wb (one
byte per token: 1 when a word ends at that token, 0 when it doesn't, 2 when it doesn't count); a pilot's names
end in -without-SOURCE. The corpus files are mixed by passes over each: Wikipedia's BASE samples it, Wikinews
takes BASE's passes, and each chat source SHARE of the training characters (#557's mix). Each pass draws its
own examples.

A pinyin example sits in the text in front of a span of words: <T>, the letters typed for the span, <S>, the
span's characters, <E>, then the text goes on. About one span per EVERY characters starts one, at a word
boundary inside a run of Han characters. The span is 1-2 words (half), 3-5 words, or the rest of the clause,
at most MAX_SPAN characters and MAX_LETTERS letters, the loader's: core gives the model a whole long input
(#563). The letters typed are, for the span's syllables, read for its whole clause (common.syllables):
- 45 %: full pinyin;
- 25 %: full pinyin with a phone typo or a pinyin confusion (common.typo, with the app's other fuzzy pairs;
  10 % of them two);
- 10 %: each syllable's first letter (spans of 2-6 characters), zh, ch and sh whole in a third of them (chsh);
- 15 %: full pinyin with the last syllable cut to its first letters (ranh → 然后);
- 5 %: some syllables, at random, cut to their first letter (nihaom → 你好吗).
Half of the examples type lve and nve as lue and nue (common.ue).
A fifth of the spans whose last word has two characters or more end inside it (CUT): the letters and the span
stop at the same character, and the rest of the word follows <E> as text. The span's last character then
teaches the <B> logit whether the text there ends a word (#502).
LOADER of the examples also come as a segment of their own, as the loader writes one (zh_lm.cpp
contextTokens()): <s>, the field's text before the span, its last CONTEXT characters, and the example, with no
earlier example in it.
train.py doesn't train the model to predict the typed letters, only the span after <S> and the <E> closing it.
Word boundaries are jieba's; they teach the <B> logit (tokenizer.py) for the next words after a commit.
"""

import multiprocessing as mp
import random
import sys
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parent)
)  # python -I leaves the script's folder out
import common
import jieba
import numpy as np
import sentencepiece as spm

jieba.setLogLevel(60)
BASE = {"wikipedia": 0.6, "wikinews": 3.0}
SHARE = {
    "meetings": 0.08,
    "hundredcv": 0.04,
    "tatoeba": 0.015,
    "kdconv": 0.01,
    "oasst2": 0.005,
}
EVERY = 30
MAX_SPAN = 25
MAX_LETTERS = 64  # zh_lm.h's
CONTEXT = 64  # zh_lm.cpp's CONTEXT_CHARS
CUT = 0.2
LOADER = 0.15
WORKERS = 12

sp = piece = None
BOS = EOS = T = S = E = None


def init(run):
    global sp, piece, BOS, EOS, T, S, E
    sp = spm.SentencePieceProcessor(model_file=str(Path(run) / "data/tokenizer.model"))
    BOS, EOS = sp.bos_id(), sp.eos_id()
    T, S, E = (sp.piece_to_id(p) for p in ("<T>", "<S>", "<E>"))
    piece = {}
    common.use_readings(Path(run) / "data/readings.tsv")


def ids(ch):
    if ch not in piece:
        piece[ch] = sp.encode(ch)
    return piece[ch]


def typed_for(rng, sy):
    r = rng.random()
    if r < 0.45:
        keys = "".join(sy)
    elif r < 0.70:
        keys, _ = common.typo(rng, sy, fuzzy_pairs=True)
        if rng.random() < 0.1:
            keys, _ = common.typo(
                rng, [keys], rng.choice(["slip", "omit", "double", "swap"])
            )
    elif r < 0.80 and 2 <= len(sy) <= 6:
        keys = common.abbreviated(sy, rng.random() < 1 / 3)
    elif r < 0.95:
        last = sy[-1][: rng.randint(1, max(1, len(sy[-1]) - 1))]
        keys = "".join(sy[:-1]) + last
    else:
        keys = "".join(x[0] if rng.random() < 0.3 else x for x in sy)
    return common.ue(keys) if rng.random() < 0.5 else keys


def text_tokens(toks, wb, text, ends=True):
    """TEXT's tokens and their word-end labels (ENDS: at its last character; else none count)."""
    for i, c in enumerate(text):
        p = ids(c)
        toks.extend(p)
        wb.extend([2] * (len(p) - 1) + [int(i == len(text) - 1) if ends else 2])


def example(toks, wb, keys, words, cut):
    """<T> KEYS <S> the WORDS <E>, the last word's last CUT characters after <E> as text."""
    toks.append(T)
    wb.append(2)
    for c in keys:
        toks.extend(ids(c))
        wb.extend([2] * len(ids(c)))
    toks.append(S)
    wb.append(2)
    for j, word in enumerate(words):
        for i, c in enumerate(word):
            if cut and j == len(words) - 1 and i == len(word) - cut:
                toks.append(E)
                wb.append(2)
            p = ids(c)
            toks.extend(p)
            wb.extend([2] * (len(p) - 1) + [int(i == len(word) - 1)])
    if not cut:
        toks.append(E)
        wb.append(2)


def segment(rng, text, toks, wb, records):
    words = list(jieba.cut(text))
    toks.append(BOS)
    wb.append(2)
    reading = common.reading(text)
    # Where each Han run (clause) ends, to bound the spans.
    clause_end, end = [0] * len(text), len(text)
    for i in range(len(text) - 1, -1, -1):
        if not common.HAN.match(text[i]):
            end = i
        clause_end[i] = end
    at, w = 0, 0
    while w < len(words):
        word = words[w]
        if common.HAN.match(word[0]) and rng.random() < len(word) / EVERY:
            r = rng.random()
            n = (
                rng.randint(1, 2)
                if r < 0.5
                else rng.randint(3, 5)
                if r < 0.8
                else len(words)
            )
            span, k = "", w
            while (
                k < len(words)
                and k < w + n
                and at + len(span) + len(words[k]) <= min(clause_end[at], at + MAX_SPAN)
                and None not in reading[at : at + len(span) + len(words[k])]
                and len("".join(reading[at : at + len(span) + len(words[k])]))
                <= MAX_LETTERS
            ):
                span += words[k]
                k += 1
            # Some spans end inside their last word, so that the <B> logit at a span's end learns from the
            # text whether a word ends there: were every span whole words, the letters running out would say.
            cut = 0
            if k > w and len(words[k - 1]) > 1 and rng.random() < CUT:
                cut = rng.randint(1, len(words[k - 1]) - 1)
            if span:
                # The cut word's reading is the whole word's (重 of 重庆 is chong, #557).
                keys = typed_for(rng, reading[at : at + len(span) - cut])
                example(toks, wb, keys, words[w:k], cut)
                if rng.random() < LOADER:
                    rec, rb = [BOS], [2]
                    # The context's word ends count once, in the text.
                    text_tokens(rec, rb, text[max(0, at - CONTEXT) : at], ends=False)
                    example(rec, rb, keys, words[w:k], cut)
                    records.append((rec, rb))
                at += len(span)
                w = k
                continue
        text_tokens(toks, wb, word)
        at += len(word)
        w += 1
    toks.append(EOS)
    wb.append(2)


def work(job):
    lines, seed = job
    rng = random.Random(seed)
    toks, wb, records = [], [], []
    for line in lines:
        segment(rng, line.rstrip("\n"), toks, wb, records)
    for rec, rb in records:
        toks += rec
        wb += rb
    return np.array(toks, dtype=np.uint16), np.array(wb, dtype=np.uint8)


def passes(corpus, split, without):
    """Passes over each corpus file: BASE's, and for each chat source its SHARE of all the characters."""
    if split == "dev":
        return {n: 1 for n in [*BASE, *SHARE]}
    chars = {
        n: sum(len(l) - 1 for l in open(corpus / f"{n}.txt", encoding="utf-8"))
        for n in [*BASE, *SHARE]
    }
    share = {n: s for n, s in SHARE.items() if n not in without}
    total = sum(BASE[n] * chars[n] for n in BASE) / (1 - sum(share.values()))
    out = dict(BASE) | {n: s * total / chars[n] for n, s in share.items()}
    for n, p in out.items():
        print(
            f"{n}: {chars[n] / 1e6:.1f}M characters, {p:.2f} passes, {100 * p * chars[n] / total:.1f} %"
        )
    return out


def jobs(corpus, split, seed, without):
    rng = random.Random(seed)
    n = 0
    for name, p in passes(corpus, split, without).items():
        lines = open(
            corpus / (f"{name}.txt" if split == "train" else f"{name}.dev.txt"),
            encoding="utf-8",
        ).readlines()
        # Whole passes, then a sample of the lines for the fraction left.
        for k in range(int(p) + (p % 1 > 0)):
            part = (
                lines if k < int(p) else rng.sample(lines, round(len(lines) * (p % 1)))
            )
            part = part[:]
            rng.shuffle(part)
            for i in range(0, len(part), 20000):
                n += 1
                yield part[i : i + 20000], seed * 1_000_003 + n


def main(run, split, seed, *without):
    run, seed = Path(run), int(seed)
    without = [w.lstrip("-") for w in without]
    out = run / "data"
    name = f"{split}.{seed}" + "".join(f"-without-{w}" for w in without)
    jl = list(jobs(out / "corpus", split, seed, without))
    random.Random(seed).shuffle(jl)  # the sources mixed through the file
    with (
        open(out / f"{name}.bin", "wb") as ft,
        open(out / f"{name}.wb", "wb") as fw,
        mp.Pool(WORKERS, init, (run,)) as pool,
    ):
        total = 0
        for k, (t, w) in enumerate(pool.imap(work, jl, chunksize=1)):
            assert len(t) == len(w)
            ft.write(t.tobytes())
            fw.write(w.tobytes())
            total += len(t)
            if k % 50 == 0:
                print(f"PROGRESS {k}/{len(jl)} tokens {total / 1e9:.3f}B", flush=True)
    print(f"{name}: {total / 1e9:.3f}B tokens", flush=True)


if __name__ == "__main__":
    main(*sys.argv[1:])
