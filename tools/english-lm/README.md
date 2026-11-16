# SebType's English model

Stage 7 of [the plan for SebType's own Android keyboard](../../docs/plans/android-own-keyboard.md) (#236):
SebType's own English language model, trained from scratch on openly licensed text ([SOURCES.md](SOURCES.md)),
to replace FUTO's `ml4_q6_k.gguf`. The phone runs it through `engines/sebtype-lm/` on llama.cpp. The English
harness (`android/test/english/run.sh` with `SEBTYPE_MODEL`) measures it against the plan's quality bar, and
[docs/perf/2026-11-15-english.md](../../docs/perf/2026-11-15-english.md) has the results.

The committed model is r2, trained by this folder as of commit `15671d98` (before #266's sources). The folder now
holds r3's recipe, which adds everyday sources and texting style; r3 fixed fewer misspellings than r2 and wasn't
committed ([the report](../../docs/experiments/2026-11-16-english-everyday-text.md#results-the-retrained-model-r3-2026-11-16)).

## The model

- A Llama-style transformer: 8 layers, width 512, 8 heads, feed-forward 1,536, input and output embeddings
  shared, 256 tokens of context. 35.7M parameters, about FUTO's size. `config.json` has the training settings.
- SebType's own tokenizer: SentencePiece BPE with 16,384 pieces, trained on the corpus (`tokenizer.py`). r3
  kept r2's (`tokenizer.model` in r2's checkpoint, copied into the run's `data/` before `prepare.sh`).
- **Correction examples in the text.** In front of 5 % of the words, the training text holds the letters
  someone typed for it: `<T>`, the typed letters, `<S>`, then the word as written. The typed letters are the
  word itself (40 %), a phone typo in #46's error mix (35 %), a spelling mistake (15 %) or only its first
  letters (10 %) (`noise.py`, `pack.py`). The model learns to predict the meant word from the letters and the
  sentence before them, so on the phone it both predicts and corrects.
- **Texting style** (#266). A fifth of the chat sources' lines (SODA, Blended Skill Talk, Topical-Chat) are
  written as people text: lowercase sentence starts, "i", dropped apostrophes and full stops, "u", "pls",
  "gonna" (`pack.py`). The real text messages of the NUS SMS Corpus show the model the true mix. The share was
  chosen on the dev sets with short trials ([the report](../../docs/experiments/2026-11-16-english-everyday-text.md)).
- Exported to GGUF and quantised to Q6_K like FUTO's (`export.sh`).

On the phone, AOSP's decoder finds the candidates for the typed letters. The model scores each of the first 6
and the typed word as `context <T>typed<S>candidate`, and `decide()` in `engines/sebtype-lm/sebtype_lm.cpp`
adds the decoder's own score to rank them and to decide whether a space corrects the word. Its weights are
tuned on dev sets made from held-out corpus lines (`dev_sets.py`, `tune.py`), never on the harness's sets.
With nothing typed, the model alone gives the next words.

## Running it

On yanglab16, with the corpus, checkpoints and logs in `~/scratch/SebType/<issue>/`:

```sh
tools/english-lm/fetch.sh RUN_DIR                 # venv, llama.cpp, the sources (~12 GB)
tools/english-lm/prepare.sh RUN_DIR [SEEDS...]    # corpus, tokenizer, typo bank, dev sets, packed tokens
python tools/english-lm/train.py RUN_DIR tools/english-lm/config.json   # one GPU
tools/english-lm/export.sh RUN_DIR/ckpt/NAME RUN_DIR/sebtype-en.gguf
tools/english-lm/dev.sh RUN_DIR RUN_DIR/sebtype-en.gguf                 # dev numbers and tuned weights
python tools/english-lm/overlap.py RUN_DIR        # the corpus doesn't hold the harness's sentences
SEBTYPE_MODEL=RUN_DIR/sebtype-en.gguf android/test/english/run.sh       # the harness, from nobara-pc
```

`python` is the venv's (`~/scratch/SebType/cache/english-lm-venv/bin/python`). The data steps use 8 to 16
processes and the build 24 (yanglab16's build lock), leaving most of the shared machine free. Training needs one
idle GPU (`nvidia-smi`), about 4 GB of its memory.
