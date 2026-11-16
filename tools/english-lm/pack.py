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

Texting style (#266): TEXTING of the chat sources' lines are written as people text, before the correction
examples are drawn: sentences start in lowercase, "I" and apostrophes are often dropped ("im", "dont"), a final
full stop goes, and common words take their short forms ("u", "ur", "pls", "gonna"). The real messages in
nus-sms show the model the true mix; this gives it texting contexts from the much larger chat it already has.
TEXTING was chosen on the dev sets (dev_sets.py's next-texts and text-typos); the optional arguments set it
and scale the mix down for those short trials:

  pack.py RUN_DIR train NAME TEXTING SCALE
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
    "nus-sms": 4.0,
    "bst": 3.0,
    "topical-chat": 1.5,
    "tatoeba": 0.5,
}
HINT = 0.05
CHAT = {"soda", "bst", "topical-chat"}
TEXTING = 0.2
# Short forms. In a texting line, each replaces its words with a chance drawn for the line, up to 80 %.
SHORT = {
    "you": "u",
    "your": "ur",
    "you're": "ur",
    "are": "r",
    "please": "pls",
    "okay": "ok",
    "thanks": "thx",
    "tomorrow": "tmrw",
    "because": "cuz",
    "though": "tho",
    "going to": "gonna",
    "want to": "wanna",
    "got to": "gotta",
    "don't know": "dunno",
    "i don't know": "idk",
    "oh my god": "omg",
    "by the way": "btw",
    "to be honest": "tbh",
    "right now": "rn",
    "people": "ppl",
    "really": "rly",
    "about": "abt",
}
# "going to the shop" isn't "gonna the shop": the "to" short forms need a verb after them, not a determiner.
NOT_VERB = r"(?! (?:the|a|an|my|your|his|her|its|our|their|this|that|these|those|school|work|bed|church|class)\b)"
SHORT_RE = re.compile(
    "|".join(
        rf"\b{re.escape(k)}\b" + (NOT_VERB if k.endswith(" to") else "")
        for k in sorted(SHORT, key=len, reverse=True)
    ),
    re.IGNORECASE,
)
SENTENCE_START = re.compile(r"(^|[.!?] +)([A-Z])(?=[a-z' ])")
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


def texting(rng, s):
    """S as someone might text it; each habit is a person's, so it holds for the whole line."""
    if rng.random() < 0.8:
        s = SENTENCE_START.sub(lambda m: m.group(1) + m.group(2).lower(), s)
    if rng.random() < 0.5:
        s = re.sub(r"\bI\b", "i", s)
    if rng.random() < 0.5:
        s = re.sub(r"(?<=[A-Za-z])'(?=(?:t|m|re|ve|ll|d|s)\b)", "", s)
    if rng.random() < 0.6:
        s = re.sub(r"(?<=[A-Za-z])\.$", "", s)
    short = rng.random() * 0.8
    s = SHORT_RE.sub(
        lambda m: SHORT[m.group().lower()] if rng.random() < short else m.group(), s
    )
    if rng.random() < 0.05:
        s += rng.choice((" lol", " haha", " :)"))
    return s


def encode(part):
    """Token ids of the lines in the byte range PART = (path, start, end, seed, texting)."""
    path, start, end, seed, text_share = part
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
            line = line.decode().rstrip("\n")
            lines.append(texting(rng, line) if rng.random() < text_share else line)
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


def main(run, split, seed, text_share=TEXTING, scale=1.0):
    text_share, scale = float(text_share), float(scale)
    corpus = Path(run) / "data/corpus"
    rng = random.Random(f"{split}:{seed}")
    parts = []
    size = 64 << 20
    for name, passes in MIX.items():
        path = corpus / (f"{name}.txt" if split == "train" else f"{name}.dev.txt")
        passes = passes * scale if split == "train" else 1
        share = text_share if split == "train" and name in CHAT else 0.0
        chunks = [
            (str(path), s, min(s + size, path.stat().st_size))
            for s in range(0, path.stat().st_size, size)
        ]
        whole, frac = int(passes), passes - int(passes)
        for p in range(whole):
            parts += [c + (f"{seed}.{p}", share) for c in chunks]
        parts += [c + (f"{seed}.{whole}", share) for c in chunks if rng.random() < frac]
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
    main(*sys.argv[1:])
