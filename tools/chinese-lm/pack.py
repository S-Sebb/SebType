"""Turns the corpus into training tokens, with pinyin examples in the text and word boundaries beside it.

  pack.py RUN_DIR SPLIT SEED       SPLIT: train or dev

Writes RUN_DIR/data/SPLIT.SEED.bin (uint16 token ids, each segment as <s> text </s>) and SPLIT.SEED.wb (one
byte per token: 1 when a word ends at that token, 0 when it doesn't, 2 when it doesn't count). The corpus
files are mixed by MIX (passes over each file; a fraction samples it). Each pass draws its own examples.

A pinyin example sits in the text in front of a span of words: <T>, the letters typed for the span, <S>, the
span's characters, <E>, then the text goes on. About one span per EVERY characters starts one, at a word
boundary inside a run of Han characters. The span is 1-2 words (half), 3-5 words, or the rest of the clause,
at most 14 characters. The letters typed are, for the span's syllables:
- 45 %: full pinyin;
- 25 %: full pinyin with a phone typo or a pinyin confusion (common.typo; 10 % of them two);
- 10 %: each syllable's first letter (spans of 2-4 characters);
- 15 %: full pinyin with the last syllable cut to its first letters (ranh → 然后);
- 5 %: some syllables, at random, cut to their first letter (nihaom → 你好吗).
A fifth of the spans whose last word has two characters or more end inside it (CUT): the letters and the span
stop at the same character, and the rest of the word follows <E> as text. The span's last character then
teaches the <B> logit whether the text there ends a word (#502).
train.py doesn't train the model to predict the typed letters, only the span after <S> and the <E> closing it.
Word boundaries are jieba's; they teach the <B> logit (tokenizer.py) for the next words after a commit.
"""

import multiprocessing as mp
import random
import sys
from pathlib import Path

import common
import jieba
import numpy as np
import sentencepiece as spm

jieba.setLogLevel(60)
MIX = {"wikipedia": 0.6, "lccc": 2.0, "wikinews": 3.0, "oasst2": 3.0}
EVERY = 30
MAX_SPAN = 14
CUT = 0.2
WORKERS = 12

sp = piece = None
BOS = EOS = T = S = E = None


def init(run):
    global sp, piece, BOS, EOS, T, S, E
    sp = spm.SentencePieceProcessor(model_file=str(Path(run) / "data/tokenizer.model"))
    BOS, EOS = sp.bos_id(), sp.eos_id()
    T, S, E = (sp.piece_to_id(p) for p in ("<T>", "<S>", "<E>"))
    piece = {}


def ids(ch):
    if ch not in piece:
        piece[ch] = sp.encode(ch)
    return piece[ch]


def typed_for(rng, sy):
    r = rng.random()
    if r < 0.45:
        return "".join(sy)
    if r < 0.70:
        keys, _ = common.typo(rng, sy)
        if rng.random() < 0.1:
            keys, _ = common.typo(
                rng, [keys], rng.choice(["slip", "omit", "double", "swap"])
            )
        return keys
    if r < 0.80 and 2 <= len(sy) <= 4:
        return common.abbreviated(sy)
    if r < 0.95:
        last = sy[-1][: rng.randint(1, max(1, len(sy[-1]) - 1))]
        return "".join(sy[:-1]) + last
    return "".join(x[0] if rng.random() < 0.3 else x for x in sy)


def segment(rng, text, toks, wb):
    words = list(jieba.cut(text))
    toks.append(BOS)
    wb.append(2)
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
            ):
                span += words[k]
                k += 1
            # Some spans end inside their last word, so that the <B> logit at a span's end learns from the
            # text whether a word ends there: were every span whole words, the letters running out would say.
            cut = 0
            if k > w and len(words[k - 1]) > 1 and rng.random() < CUT:
                cut = rng.randint(1, len(words[k - 1]) - 1)
            sy = common.syllables(span[: len(span) - cut]) if span else None
            if sy:
                toks.append(T)
                wb.append(2)
                for c in typed_for(rng, sy):
                    toks.extend(ids(c))
                    wb.extend([2] * len(ids(c)))
                toks.append(S)
                wb.append(2)
                for j in range(w, k):
                    word = words[j]
                    for i, c in enumerate(word):
                        if j == k - 1 and i == len(word) - cut:
                            toks.append(E)
                            wb.append(2)
                        p = ids(c)
                        toks.extend(p)
                        wb.extend([2] * (len(p) - 1) + [int(i == len(word) - 1)])
                if not cut:
                    toks.append(E)
                    wb.append(2)
                at += len(span)
                w = k
                continue
        for i, c in enumerate(word):
            p = ids(c)
            toks.extend(p)
            wb.extend([2] * (len(p) - 1) + [int(i == len(word) - 1)])
        at += len(word)
        w += 1
    toks.append(EOS)
    wb.append(2)


def work(job):
    lines, seed = job
    rng = random.Random(seed)
    toks, wb = [], []
    for line in lines:
        segment(rng, line.rstrip("\n"), toks, wb)
    return np.array(toks, dtype=np.uint16), np.array(wb, dtype=np.uint8)


def jobs(corpus, split, seed):
    rng = random.Random(seed)
    n = 0
    for name, passes in MIX.items():
        lines = open(
            corpus / (f"{name}.txt" if split == "train" else f"{name}.dev.txt"),
            encoding="utf-8",
        ).readlines()
        if split == "dev":
            passes = 1
        elif passes < 1:
            lines, passes = rng.sample(lines, int(len(lines) * passes)), 1
        for _ in range(int(passes)):
            rng.shuffle(lines)
            for i in range(0, len(lines), 20000):
                n += 1
                yield lines[i : i + 20000], seed * 1_000_003 + n


def main(run, split, seed):
    run, seed = Path(run), int(seed)
    out = run / "data"
    jl = list(jobs(out / "corpus", split, seed))
    random.Random(seed).shuffle(jl)  # the sources mixed through the file
    with (
        open(out / f"{split}.{seed}.bin", "wb") as ft,
        open(out / f"{split}.{seed}.wb", "wb") as fw,
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
    print(f"{split}.{seed}: {total / 1e9:.3f}B tokens", flush=True)


if __name__ == "__main__":
    main(*sys.argv[1:4])
