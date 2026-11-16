"""Trains SebType's Chinese tokenizer: one piece per character (SentencePiece's char model), the corpus's most
frequent characters, bytes for the rest, and the format's own symbols.

  tokenizer.py RUN_DIR       writes RUN_DIR/data/tokenizer.model

One piece per character keeps every candidate's score exact (no segmentation to choose) and lets the word
boundaries fall between any two characters. <T> starts the letters typed for the text after <S>, which ends
at <E> (pack.py). <B> is never in the text: its logit is the model's guess that a word ends at the character
just read. No normalisation, so the text the phone gives the model is tokenised as the corpus was.
"""

import random
import sys
from pathlib import Path

import sentencepiece as spm

SPECIAL = ["<T>", "<S>", "<E>", "<B>"]


def main(run):
    data = Path(run) / "data"
    rng = random.Random(259)
    sample = data / "tokenizer-sample.txt"
    with open(sample, "w", encoding="utf-8") as out:
        for f in sorted((data / "corpus").glob("*.txt")):
            if f.name.endswith(".dev.txt"):
                continue
            for line in open(f, encoding="utf-8"):
                if rng.random() < 0.02:
                    out.write(line)
        out.write(
            "abcdefghijklmnopqrstuvwxyz\n" * 1000
        )  # every typed letter has its piece
    spm.SentencePieceTrainer.train(
        input=str(sample),
        model_prefix=str(data / "tokenizer"),
        model_type="char",
        vocab_size=8000,
        hard_vocab_limit=False,
        character_coverage=0.9995,
        byte_fallback=True,
        normalization_rule_name="identity",
        add_dummy_prefix=False,
        remove_extra_whitespaces=False,
        user_defined_symbols=SPECIAL,
        input_sentence_size=4_000_000,
        shuffle_input_sentence=True,
        num_threads=12,
    )
    sample.unlink()


if __name__ == "__main__":
    main(sys.argv[1])
