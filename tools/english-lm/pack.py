"""Turns the corpus into training tokens, with correction examples in the text.

  pack.py RUN_DIR SPLIT SEED       SPLIT: train or dev

Writes RUN_DIR/data/SPLIT.SEED.bin: uint16 token ids, each segment as <s> text </s>, the corpus files mixed
by MIX (passes over each file; a fraction samples it). Each pass draws its own correction examples.

A correction example sits in the text in front of a word: <T>, the letters typed for it, <S>, then the word
as written. HINT (5 %) of the words get one. The typed letters are lowercase:
- 40 %: the word itself, so a correctly typed word is kept;
- 35 %: a phone typo from the bank (noise.py), 15 %: a spelling mistake from it;
- 10 %: the first letters only, correct or not, so the model also completes words.
train.py doesn't train the model to predict the example's own tokens, only the word after <S>. On the phone,
SebType's loader writes the same example for each candidate and reads its probability.
"""

import multiprocessing as mp
import random
import re
import sys
from pathlib import Path

import numpy as np
import sentencepiece as spm

# Passes over each corpus file per training set: the chat sources count most, as the keyboard's text is
# closest to them; Wikipedia gives breadth.
MIX = {
    "wikipedia": 0.35,
    "simplewiki": 1.0,
    "wikinews": 3.0,
    "soda": 1.5,
    "oasst2": 4.0,
    "dolly": 3.0,
}
HINT = 0.05
LEADING_WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")

sp = bank = letter = None
T = S = None
starts_word = None


def init(run):
    global sp, bank, letter, T, S, starts_word
    sp = spm.SentencePieceProcessor(model_file=str(Path(run) / "data/tokenizer.model"))
    T, S = sp.piece_to_id("<T>"), sp.piece_to_id("<S>")
    letter = {c: sp.piece_to_id(c) for c in "abcdefghijklmnopqrstuvwxyz'"}
    assert all(i != sp.unk_id() for i in letter.values())
    starts_word = np.array(
        [sp.id_to_piece(i).startswith("▁") for i in range(sp.get_piece_size())]
    )
    bank = {}
    for line in open(Path(run) / "data/typos.tsv"):
        w, phone, spell = line.rstrip("\n").split("\t")
        bank[w] = (phone.split(",") if phone else [], spell.split(",") if spell else [])


def typed_for(rng, word):
    w = word.lower()
    phone, spell = bank.get(w, ((), ()))
    r = rng.random()
    if r < 0.40:
        return w
    if r < 0.75 and phone:
        return rng.choice(phone)
    if r < 0.90 and spell:
        return rng.choice(spell)
    if r >= 0.90 and len(w) >= 2:
        full = rng.choice(phone) if phone and rng.random() < 0.5 else w
        return full[: rng.randrange(1, len(full))] if len(full) >= 2 else full
    return w


def encode(part):
    """Token ids of the lines in the byte range PART = (path, start, end, seed)."""
    path, start, end, seed = part
    rng = random.Random(f"{path}:{start}:{seed}")
    lines = []
    with open(path, "rb") as f:
        f.seek(start)
        if start:
            f.readline()
        while f.tell() <= end:
            line = f.readline()
            if not line:
                break
            lines.append(line.decode().rstrip("\n"))
    out = []
    for ids in sp.encode(lines):
        out.append(sp.bos_id())
        n = len(ids)
        i = 0
        while i < n:
            if starts_word[ids[i]] and rng.random() < HINT:
                # The word: this piece and the ones up to the next word start; its letters lead it.
                j = i + 1
                while j < n and not starts_word[ids[j]]:
                    j += 1
                m = LEADING_WORD.match(sp.decode(ids[i:j]).lstrip())
                if m:
                    out += [T] + [letter[c] for c in typed_for(rng, m.group())] + [S]
                out += ids[i:j]
                i = j
            else:
                out.append(ids[i])
                i += 1
        out.append(sp.eos_id())
    return np.array(out, dtype=np.uint16)


def main(run, split, seed):
    corpus = Path(run) / "data/corpus"
    rng = random.Random(f"{split}:{seed}")
    parts = []
    size = 64 << 20
    for name, passes in MIX.items():
        path = corpus / (f"{name}.txt" if split == "train" else f"{name}.dev.txt")
        passes = passes if split == "train" else 1
        chunks = [
            (str(path), s, min(s + size, path.stat().st_size))
            for s in range(0, path.stat().st_size, size)
        ]
        whole, frac = int(passes), passes - int(passes)
        for p in range(whole):
            parts += [c + (f"{seed}.{p}",) for c in chunks]
        parts += [c + (f"{seed}.{whole}",) for c in chunks if rng.random() < frac]
    rng.shuffle(parts)
    out = Path(run) / f"data/{split}.{seed}.bin"
    total = 0
    with mp.Pool(16, initializer=init, initargs=(run,)) as pool, open(out, "wb") as f:
        for k, ids in enumerate(pool.imap_unordered(encode, parts)):
            ids.tofile(f)
            total += len(ids)
            print(
                f"PROGRESS {k + 1}/{len(parts)} {total / 1e9:.2f}B tokens", flush=True
            )
    print(f"{out.name}: {total:,} tokens")


if __name__ == "__main__":
    main(*sys.argv[1:4])
