"""Turns the corpus into training tokens, with correction examples in the text.

  pack.py RUN_DIR SPLIT SEED       SPLIT: train or dev

Writes RUN_DIR/data/SPLIT.SEED.bin: uint16 token ids, the corpus files mixed by MIX (passes over each file; a
fraction samples its lines). Each pass draws its own correction examples. The same inputs give the same file.

A line of the corpus is cut, between words, into segments of at most CONTEXT_CHARS, the most the phone's model
reads before the cursor (engines/sebtype-lm/sebtype_lm.cpp); each segment starts with <s>, and the line ends
with </s>. So a word's context in training is what it is on the phone: <s>, then at most CONTEXT_CHARS of its
line.

A correction example sits in the text in front of a word: <T>, the letters typed for it, <S>, then the word as
it is written, as the phone scores a candidate: its own pieces, with a space in front. HINT (5 %) of the words
get one, wherever they stand (after a quote or a bracket too). The typed letters are lowercase:
- 40 %: the word itself, so a correctly typed word is kept;
- 35 %: a phone typo from the bank (noise.py), 15 %: a spelling mistake from it (a phone typo for a word too
  short for one), made on the spot for a word the bank lacks;
- 10 %: the first letters only, correct or not, so the model also completes words.
A contraction is typed without its apostrophe (APOSTROPHE_TYPED of the time with it): it isn't on the phone's
letter layer. TWO_WORDS of the examples span two words typed as one, the space missed or slipped onto a letter
above it ("couldbe", "ofvthe"), so the typed letters count against a two-word candidate as against one word.
The word after <S> is always the standard one (standard()): "I" for "i", "don't" for "dont" (the harness's
intended()), a capital at a sentence start, whatever the text around it does: the model learns to correct
them, not to keep them. Short forms people mean ("u", "pls") stay.
train.py doesn't train the model to predict the example's own tokens, only the words after <S>. On the phone,
SebType's loader writes the same example for each candidate and reads its probability.

Texting style (#266): TEXTING of the chat sources' lines are written as people text: sentences start in
lowercase, "I" and apostrophes are often dropped ("im", "dont"), a final full stop goes, and common words take
their short forms ("u", "ur", "pls", "gonna"). The real messages in nus-sms show the model the true mix; this
gives it texting contexts from the much larger chat it already has. TEXTING was chosen on the dev sets
(dev_sets.py's next-texts and text-typos); the optional arguments set it and scale the mix down for short
trials:

  pack.py RUN_DIR train NAME TEXTING SCALE
"""

import multiprocessing as mp
import random
import re
import sys
from pathlib import Path

import numpy as np
import sentencepiece as spm

sys.path[:0] = [
    str(Path(__file__).resolve().parent),
    str(Path(__file__).resolve().parents[2] / "android/test/english"),
]
import make_sets
import noise

# Passes over each corpus file per training set. The chat sources count most, as the keyboard's text is
# closest to them; Wikipedia gives breadth. The recipe pilot r4 validated (#556) was PILOT_MIX with train.py's
# windows drawn by <s>, which gave a source of short segments more than its tokens' share. train.py now draws
# windows by token, so MIX is PILOT_MIX times each source's segments per token, measured on the pilot's corpus
# (wikipedia 51.0 tokens per segment, NUS 14.4), scaled to keep a pack's size: each source keeps the share of
# training pilot r4 had (wikipedia 60.3 %, SODA 30.9 %, NUS 0.10 %). test.py checks it on the run's corpus.
# NUS's 5.9 passes are as many reads of each message as the pilot's 2 passes drawn by <s>.
PILOT_MIX = {
    "wikipedia": 0.35,
    "simplewiki": 1.0,
    "wikinews": 3.0,
    "soda": 1.5,
    "oasst2": 4.0,
    "dolly": 3.0,
    "nus-sms": 2.0,
    "bst": 3.0,
    "topical-chat": 1.5,
    "tatoeba": 0.5,
}
MIX = {
    "wikipedia": 0.289,
    "simplewiki": 0.946,
    "wikinews": 2.674,
    "soda": 2.342,
    "oasst2": 4.936,
    "dolly": 4.212,
    "nus-sms": 5.871,
    "bst": 6.448,
    "topical-chat": 2.221,
    "tatoeba": 1.752,
}
HINT = 0.05
TWO_WORDS = 0.05
APOSTROPHE_TYPED = 0.15
CONTEXT_CHARS = 300
CHAT = {"soda", "bst", "topical-chat"}
# Bare forms that are words too but in chat and text messages almost always a contraction missing its
# apostrophe (topical-chat: cant 641, can't 3,605): there an example writes the contraction (#556).
CHAT_CONTRACTIONS = {"cant", "whats", "wont"}
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
# "going to London" isn't "gonna London": the "to" short forms need a common verb after them.
VERB = r"(?= (?:be|go|get|have|do|see|make|take|know|say|come|try|eat|buy|call|tell|keep|give|find|think|look|help|leave|play|start|stop|talk|work|sleep|watch|wait|pay|use|meet|ask|send|put|need|let|cry|miss|lose|win|move|change|read|write|run|drive|stay|show|hang|check|kill|die|be)\b)"
SHORT_RE = re.compile(
    "|".join(
        rf"\b{re.escape(k)}\b" + (VERB if k.endswith(" to") else "")
        for k in sorted(SHORT, key=len, reverse=True)
    ),
    re.IGNORECASE,
)
OPENING = "[\"'(\\[\u201c\u2018]"  # opening quotes and brackets
SENTENCE_START = re.compile(r"(^|[.!?] +)([A-Z])(?=[a-z' ])")
SENTENCE_START_INSIDE = re.compile(r"([.!?] +)([A-Z])(?=[a-z' ])")
# A word an example can go in front of: after the line's start, a space, a quote or a bracket.
EXAMPLE_WORD = re.compile(
    r"(?:(?<=^)|(?<=[ \"'(\[]))[A-Za-z]+(?:'[A-Za-z]+)?(?![A-Za-z0-9])"
)
I_FORMS = {"i": "I", "i'm": "I'm", "i've": "I've", "i'll": "I'll", "i'd": "I'd"}
# Letters above the space bar: a space aimed at between two words that lands on one.
ABOVE_SPACE = "xcvbnm"

sp = bank = letter = None
T = S = NEWLINE = None
intended = real_word = None
commonest = {}


def init(run, typos=True):
    """Each worker's tokenizer, typo bank (TYPOS: RUN_DIR's, else an empty one) and dictionary."""
    global sp, bank, letter, T, S, NEWLINE, intended, real_word
    sp = spm.SentencePieceProcessor(model_file=str(Path(run) / "data/tokenizer.model"))
    T, S = sp.piece_to_id("<T>"), sp.piece_to_id("<S>")
    NEWLINE = sp.encode("\n")
    letter = {c: sp.piece_to_id(c) for c in "abcdefghijklmnopqrstuvwxyz'"}
    assert all(i != sp.unk_id() for i in letter.values())
    bank = {}
    for line in open(Path(run) / "data/typos.tsv") if typos else ():
        w, phone, spell = line.rstrip("\n").split("\t")
        bank[w] = (phone.split(",") if phone else [], spell.split(",") if spell else [])
    words = make_sets.dictionary()
    intended = make_sets.intended_of(words)
    real_word = lambda w: w in words and not words[w][1]
    # Each apostrophe word's commonest case in the dictionary: "o'clock" for "O'Clock" (a title's case).
    for w, (f, bad, *_) in sorted(words.items(), key=lambda x: x[1][0]):
        if "'" in w and not bad:
            commonest[w.lower()] = w


def typed_for(rng, word, prefix=True, bare=False):
    """The letters someone typed for WORD (BARE: never its apostrophe)."""
    w = word.lower()
    if (
        w not in bank
    ):  # a word too rare for the bank: its typos made now, kept for the next time
        bank[w] = noise.variants(w)[1:]
    phone, spell = bank[w]
    if "'" in w and (bare or rng.random() >= APOSTROPHE_TYPED):
        w = w.replace("'", "")
    r = rng.random()
    if r < 0.40 or not phone:
        return w
    if r < 0.75 or (r < 0.90 and not spell) or (r >= 0.90 and not prefix):
        return rng.choice(phone)
    if r < 0.90:
        return rng.choice(spell)
    full = rng.choice(phone) if rng.random() < 0.5 else w
    return full[: rng.randrange(1, len(full))] if len(full) >= 2 else full


def standard(word, sentence_start, chat=False):
    """WORD as the example's output: I and its forms capitalised, an apostrophe word with a capital after its
    apostrophe in the dictionary's commonest case, a bare contraction that is no word itself
    (or, in CHAT text, one of CHAT_CONTRACTIONS) with its apostrophe, and a lowercase word at a sentence start
    capitalised."""
    low = word.lower()
    if low in I_FORMS:
        return I_FORMS[low]
    if "'" in word and any(c.isupper() for c in word.split("'", 1)[1]):
        word = commonest.get(low, word)  # "O'Clock", "YOU'RE": the dictionary's case
    bare = not real_word(low) or (chat and low in CHAT_CONTRACTIONS)
    if "'" not in low and bare and intended(low) != low:
        w = intended(low)
        word = w[0].upper() + w[1:] if word[0].isupper() else w
    if sentence_start and word.islower():
        word = word[0].upper() + word[1:]
    return word


class Texting:
    """How one person texts: each habit holds for a whole line."""

    def __init__(self, rng):
        self.rng = rng
        self.lower_starts = rng.random() < 0.8
        self.lower_i = rng.random() < 0.5
        self.drop_apostrophes = rng.random() < 0.5
        self.drop_stop = rng.random() < 0.6
        self.short = rng.random() * 0.8
        self.tail = rng.choice((" lol", " haha", " :)")) if rng.random() < 0.05 else ""

    def text(self, s, line_start, line_end):
        """S, a piece of the line, as this person texts it."""
        if self.lower_starts:
            s = (SENTENCE_START if line_start else SENTENCE_START_INSIDE).sub(
                lambda m: m.group(1) + m.group(2).lower(), s
            )
        if self.lower_i:
            s = re.sub(r"\bI\b", "i", s)
        if self.drop_apostrophes:
            s = re.sub(r"(?<=[A-Za-z])'(?=(?:t|m|re|ve|ll|d|s)\b)", "", s)
        if line_end and self.drop_stop:
            s = re.sub(r"(?<=[A-Za-z])\.$", "", s)
        s = SHORT_RE.sub(
            lambda m: (
                SHORT[m.group().lower()]
                if self.rng.random() < self.short
                else m.group()
            ),
            s,
        )
        return s + self.tail if line_end else s

    def short_form(self, word):
        """WORD's short form if this person writes it so here, else None."""
        s = SHORT.get(word.lower())
        return s if s and " " not in word and self.rng.random() < self.short else None


def segments(line):
    """LINE cut between words into pieces of at most CONTEXT_CHARS."""
    out = []
    while len(line) > CONTEXT_CHARS:
        cut = line.rfind(" ", 0, CONTEXT_CHARS + 1)
        cut = cut if cut > 0 else CONTEXT_CHARS
        out.append(line[:cut])
        line = line[cut:].lstrip(" ")
    return out + [line] if line else out


def tokens(text, first):
    """TEXT's token ids; with a space marker in front only if FIRST (the start of a segment), as there."""
    if first:
        return sp.encode(text)
    ids = sp.encode("\n" + text)
    assert ids[: len(NEWLINE)] == NEWLINE
    return ids[len(NEWLINE) :]


def examples(rng, seg):
    """The examples' spans in SEG: (start, end), the second word's start for two words else None."""
    words = list(EXAMPLE_WORD.finditer(seg))
    out, k = [], 0
    while k < len(words):
        m = words[k]
        if rng.random() < HINT:
            n = words[k + 1] if k + 1 < len(words) else None
            if (
                n
                and rng.random() < TWO_WORDS
                and seg[m.end() : n.start()] == " "
                and m.group().isalpha()
                and n.group().isalpha()
            ):
                out.append((m.start(), n.end(), n.start()))
                k += 2
                continue
            out.append((m.start(), m.end(), None))
        k += 1
    return out


def encode_line(rng, line, texting, chat=False):
    """LINE's token ids, its correction examples in it; TEXTING: a Texting or None; CHAT: from a chat source
    or text messages."""
    out = []
    segs = segments(line)
    for si, seg in enumerate(segs):
        out.append(sp.bos_id())
        pos, first = 0, True
        for start, end, second in examples(rng, seg):
            before = seg[pos:start]
            # A sentence starts after a full stop, or at the line's start, an opening quote or bracket
            # between ('He stopped. "Don't'); after one mid-sentence a capital the source wrote stays
            # ('He said, "YOU'RE' is "You're" once standard() puts YOU'RE in the dictionary's case).
            at_start = bool(
                re.search(r"(?:[.!?]\s+|^\s*)" + OPENING + "*$", seg[:start])
            ) and (si == 0 or not re.match(r"\s*" + OPENING + "*$", seg[:start]))
            quoted = bool(re.search(OPENING + "$", seg[:start]))
            at_start |= quoted and seg[start].isupper()
            if before.endswith(
                " "
            ):  # the example's word brings its own space marker, as on the phone
                before = before[:-1]
            if before:
                if texting:
                    before = texting.text(before, si == 0 and pos == 0, False)
                out += tokens(before, first)
            words = (
                [seg[start:end]]
                if second is None
                else [seg[start : second - 1], seg[second:end]]
            )
            typed, written = [], []
            for i, w in enumerate(words):
                short = texting.short_form(w) if texting and second is None else None
                written.append(short or standard(w, at_start and i == 0, chat))
                typed.append(
                    typed_for(
                        rng,
                        short or written[-1],
                        prefix=second is None,
                        bare=bool(texting and texting.drop_apostrophes),
                    )
                )
            sep = "" if rng.random() < 0.7 else rng.choice(ABOVE_SPACE)
            out += [T] + [letter[c] for c in sep.join(typed) if c in letter] + [S]
            out += sp.encode(" ".join(written))
            pos, first = end, False
        rest = seg[pos:]
        if texting:
            rest = texting.text(rest, si == 0 and pos == 0, si == len(segs) - 1)
        if rest:
            out += tokens(rest, first)
    out.append(sp.eos_id())
    return out


def encode(part):
    """Token ids of the lines in the byte range PART = (path, start, end, seed, texting, keep): each line kept
    with chance KEEP (a fraction of a pass)."""
    path, start, end, seed, text_share, keep = part
    rng = random.Random(f"{Path(path).name}:{start}:{seed}")
    chat = Path(path).name.split(".")[0] in CHAT | {"nus-sms"}
    out = []
    with open(path, "rb") as f:
        f.seek(start)
        if start:
            f.readline()
        while f.tell() <= end:
            line = f.readline()
            if not line:
                break
            if keep < 1 and rng.random() >= keep:
                continue
            line = line.decode().rstrip("\n")
            texting = Texting(rng) if rng.random() < text_share else None
            out += encode_line(rng, line, texting, chat)
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
        for p in range(whole + (frac > 0)):
            parts += [
                c + (f"{seed}.{p}", share, 1.0 if p < whole else frac) for c in chunks
            ]
    rng.shuffle(parts)
    out = Path(run) / f"data/{split}.{seed}.bin"
    total = 0
    with mp.Pool(16, initializer=init, initargs=(run,)) as pool, open(out, "wb") as f:
        for k, ids in enumerate(
            pool.imap(encode, parts)
        ):  # in order: the same file every time
            ids.tofile(f)
            total += len(ids)
            print(
                f"PROGRESS {k + 1}/{len(parts)} {total / 1e9:.2f}B tokens", flush=True
            )
    print(f"{out.name}: {total:,} tokens")


if __name__ == "__main__":
    main(*sys.argv[1:])
