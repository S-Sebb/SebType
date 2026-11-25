# SebType's Chinese model

Born of the experiment of #259: can a small Chinese transformer, trained from scratch on openly licensed text
([SOURCES.md](SOURCES.md)), beat today's 中文 (Rime: rime-ice, 白霜's dictionary and octagram grammar) at the
first candidate, typo fixes and next words, at about the English model's size and speed? The harness is
`android/test/chinese-lm/`, and [docs/experiments/2026-11-16-chinese-lm.md](../../docs/experiments/2026-11-16-chinese-lm.md)
has its results. The keyboard's 中文 ships the model as `engines/sebtype-lm/chinese.gguf`; only the model, not
these scripts or their data, goes into the apps.

## The model

- A Llama-style transformer like the English one (`tools/english-lm`), so llama.cpp runs it unchanged:
  `config.json` has its size and training settings.
- A character vocabulary: SentencePiece `char` over the corpus's ~6,100 commonest characters, the letters a–z,
  and byte fallback for the rest (`tokenizer.py`). The context needs no word segmentation.
- **Pinyin examples in the text.** In front of a span of jieba words (once per ~30 characters, within a
  clause, at most 25 characters and 64 letters: core gives the model a whole long input, #563), the training
  text holds the letters typed for it: `<T>`, the letters, `<S>`, the span, `<E>`. The letters are its full
  pinyin (45 %), full pinyin with a phone typo or a pinyin confusion, the app's fuzzy pairs among them (25 %),
  initials only, zh/ch/sh whole in a third (10 %), its last syllable cut short (15 %) or some syllables
  abbreviated (5 %); half type lve and nve as lue and nue, as rime-ice takes them (`common.py`, `pack.py`).
  The pinyin is read for the whole clause, by pypinyin corrected by 白霜's dictionary (`common.py readings`).
  The loss skips the letters, wherever a training window starts (`test_train.py`): the model learns the span
  from them and the text before. A fifth of the spans end inside their last word, the rest of it following
  `<E>` as text, typed as the whole word reads (重 of 重庆 is chong). Some examples also come as the loader
  writes them, `<s>`, the text before the span and the example, so the model learns to read that too (#557).
- **Word ends.** A fifth special token, `<B>`, is never an input: its logit is trained, by binary cross-entropy,
  to say whether a word (by jieba) ends at each character. Next-word prediction uses it to know where to stop,
  and a candidate's score includes it at the candidate's last character: as spans may stop inside a word, it
  learns there from the text, not from the letters running out, so 剪个深 for `jiangeshen` scores low (#502).

In the loader (`engines/sebtype-lm/zh_lm.cpp`, which the harness and core/ share), the model scores Rime's first candidates as
`context <T>letters<S>candidate<E>` and re-ranks them with Rime's order (`rerank`, `rankWeight`); it can add
its own candidates by beam search (`generate`), and with nothing typed it proposes next words. The first 3 are
then re-ordered with part of their probability as plain text after the context added (`plain()`; `plain`,
`ownPlain`, `plainTop`): given the letters, the model must spell them out once it has picked a first character,
so the example's score alone can't tell a text whose first character fits but whose rest doesn't (剪个深 for
`jiangeshen`, #502). `tune.py`
tunes those settings on dev sets (`make_sets.py --dev`), never on the test sets.

## Running it

On yanglab16, with the corpus, checkpoints and logs in `~/scratch/SebType/<issue>/`:

```sh
tools/chinese-lm/fetch.sh RUN_DIR                       # venv, llama.cpp's gguf, the sources (~3 GB kept; the
                                                        # meetings' archives stream by, ~100 GB, once)
python tools/chinese-lm/common.py readings RUN_DIR/data/src/rime-frost-schemas.zip RUN_DIR/data/readings.tsv
python android/test/chinese-lm/make_sets.py RUN_DIR/data/src RUN_DIR/data/readings.tsv android/test/chinese-lm/sets
                                                        # only when the test sets change (they are committed)
tools/chinese-lm/prepare.sh RUN_DIR                     # readings, dev sets, corpus (overlap.py checks it),
                                                        # tokenizer, packed tokens; a step reruns when its inputs change
python tools/chinese-lm/train.py RUN_DIR tools/chinese-lm/config.json   # one GPU; a checkpoint every save_every steps
tools/chinese-lm/select.sh RUN_DIR NAME                 # the best checkpoint on the dev sets, and its export's parity
cp RUN_DIR/select/NAME/BEST.gguf engines/sebtype-lm/chinese.gguf
android/test/chinese-lm/run.sh                          # from nobara-pc: the harness, and the bar against baseline.json
```

A pilot leaves one chat source out (`pack.py RUN_DIR train 0 -SOURCE`, then a short training run on the
packed file) to see what the source does on the dev sets.

`python` is the venv's (`~/scratch/SebType/cache/chinese-lm-venv/bin/python -I`). The data steps use 12 to 16
processes, leaving most of the shared machine free. Training needs one idle GPU (`nvidia-smi`).

`tune.py` tunes the model stack's settings (`bench.sh --dev ... dump=1 rerank=10 generate=W`), not core's own
ranking (core/src/chinese.cpp's weights, the plain re-rank and the misread partition), which the harness's
core stack measures as it is.
