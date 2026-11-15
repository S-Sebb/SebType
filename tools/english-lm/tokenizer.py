"""Trains SebType's own tokenizer on the corpus: SentencePiece BPE, 16,384 pieces.

  tokenizer.py RUN_DIR

Writes RUN_DIR/data/tokenizer.model. Pieces never cross a space (a word starts with "▁"), so the decoder's
candidates map to whole pieces. Byte fallback covers any character the corpus didn't have. Normalisation is
off: corpus.py folds the text, and llama.cpp's tokenizer, which runs it on the phone, doesn't normalise.
<T> and <S> are control pieces for correction examples: "<T>typed letters<S>intended word" (pack.py).
"""

import random
import sys
from pathlib import Path

import sentencepiece as spm

VOCAB = 16384
SAMPLE = 8_000_000  # lines, in the training mix's proportions


def sample(corpus, weights, n):
    """About N lines from the corpus files, each file's share in proportion to its weight times its size."""
    sizes = {f: (corpus / f"{f}.txt").stat().st_size * w for f, w in weights.items()}
    total = sum(sizes.values())
    rng = random.Random(236)
    for f, size in sizes.items():
        path = corpus / f"{f}.txt"
        with open(path) as lines:
            head = [len(l) for _, l in zip(range(10000), lines)]
        keep = n * size / total / (path.stat().st_size / (sum(head) / len(head)))
        with open(path) as lines:
            for line in lines:
                if rng.random() < keep:
                    yield line.rstrip("\n")


def main(run):
    from pack import MIX

    data = Path(run) / "data"
    spm.SentencePieceTrainer.train(
        sentence_iterator=sample(data / "corpus", MIX, SAMPLE),
        model_prefix=str(data / "tokenizer"),
        model_type="bpe",
        vocab_size=VOCAB,
        character_coverage=1.0,
        byte_fallback=True,
        split_digits=True,
        normalization_rule_name="identity",
        remove_extra_whitespaces=False,
        unk_id=0,
        bos_id=1,
        eos_id=2,
        pad_id=-1,
        control_symbols=["<T>", "<S>"],
        max_sentence_length=8192,
        num_threads=24,
        train_extremely_large_corpus=True,
    )


if __name__ == "__main__":
    main(sys.argv[1])
