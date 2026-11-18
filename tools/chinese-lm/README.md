# SebType's Chinese model (experiment)

The experiment of #259: can a small Chinese transformer, trained from scratch on openly licensed text
([SOURCES.md](SOURCES.md)), beat today's 中文 (Rime: rime-ice, 白霜's dictionary and octagram grammar) at the
first candidate, typo fixes and next words, at about the English model's size and speed? The harness is
`android/test/chinese-lm/`, and [docs/experiments/2026-11-16-chinese-lm.md](../../docs/experiments/2026-11-16-chinese-lm.md)
has the results. Nothing here ships.

## The model

- A Llama-style transformer like the English one (`tools/english-lm`), so llama.cpp runs it unchanged:
  `config.json` has its size and training settings.
- A character vocabulary: SentencePiece `char` over the corpus's ~6,100 commonest characters, the letters a–z,
  and byte fallback for the rest (`tokenizer.py`). The context needs no word segmentation.
- **Pinyin examples in the text.** In front of a span of jieba words (once per ~30 characters, at most 14
  characters), the training text holds the letters typed for it: `<T>`, the letters, `<S>`, the span, `<E>`. The
  letters are its full pinyin (45 %), full pinyin with a phone typo or a zh/z, ch/c, sh/s, ng/n confusion
  (25 %), initials only (10 %), its last syllable cut short (15 %) or some syllables abbreviated (5 %)
  (`common.py`, `pack.py`). The loss skips the letters: the model learns the span from them and the text before.
- **Word ends.** A fifth special token, `<B>`, is never an input: its logit is trained, by binary cross-entropy,
  to say whether a word (by jieba) ends at each character. Next-word prediction uses it to know where to stop.

In the loader (`engines/sebtype-lm/zh_lm.cpp`, which the harness and core/ share), the model scores Rime's first candidates as
`context <T>letters<S>candidate<E>` and re-ranks them with Rime's order (`rerank`, `rankWeight`); it can add
its own candidates by beam search (`generate`), and with nothing typed it proposes next words. `tune.py`
tunes those settings on dev sets (`make_sets.py --dev`), never on the test sets.

## Running it

On yanglab16, with the corpus, checkpoints and logs in `~/scratch/SebType/<issue>/`:

```sh
tools/chinese-lm/fetch.sh RUN_DIR                       # venv, llama.cpp's gguf, the sources (~2 GB)
python android/test/chinese-lm/make_sets.py RUN_DIR/data/src/lccc RUN_DIR/data/src/zhwikinews-20261101.xml.bz2 RUN_DIR/dev --dev
                                                        # dev sets (the test sets are committed)
tools/chinese-lm/prepare.sh RUN_DIR                     # corpus, tokenizer, packed tokens (~30 min)
python tools/chinese-lm/overlap.py RUN_DIR              # the corpus doesn't hold the test items
python tools/chinese-lm/train.py RUN_DIR tools/chinese-lm/config.json   # one GPU
tools/chinese-lm/export.sh RUN_DIR/ckpt/NAME RUN_DIR/NAME.gguf
for w in 1 2 3 4; do                                    # a dump per beam width
  android/test/chinese-lm/bench.sh --dev RUN_DIR/dev OUT-w$w RUN_DIR/NAME.gguf dump=1 rerank=10 generate=$w
done
python tools/chinese-lm/tune.py RUN_DIR/dev OUT-w1 OUT-w2 OUT-w3 OUT-w4   # the settings for the harness
SEBTYPE_ZH_MODEL=RUN_DIR/NAME.gguf SEBTYPE_ZH_OPTIONS="..." android/test/chinese-lm/run.sh   # from nobara-pc
```

`python` is the venv's (`~/scratch/SebType/cache/chinese-lm-venv/bin/python`). The data steps use 12 to 16
processes, leaving most of the shared machine free. Training needs one idle GPU (`nvidia-smi`).
