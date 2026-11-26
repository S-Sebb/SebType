# SebType's English model

Stage 7 of [the plan for SebType's own Android keyboard](../../docs/plans/android-own-keyboard.md) (#236):
SebType's own English language model, trained from scratch on openly licensed text ([SOURCES.md](SOURCES.md)),
to replace FUTO's `ml4_q6_k.gguf`. The phone runs it through `engines/sebtype-lm/` on llama.cpp. The English
harness (`android/test/english/run.sh` with `SEBTYPE_MODEL`) measures it against the plan's quality bar, and
[docs/perf/2026-11-15-english.md](../../docs/perf/2026-11-15-english.md) has the results.

The committed model is r5e (#556): r4 fine-tuned on this folder's data as of commit `2d4666bc`, with
`config-r5e.json` (1,506 steps on 0.88B fresh tokens from `pack.py RUN_DIR train 5 0.2 0.4`, starting at r4's
last learning rate). Its checkpoint at step 1,250 is `select.sh`'s pick (dev gain 107.77 at the shipped
weights, r4's 107.45; GGUF sha256 `a27343797c2847951cf4d6089f48dd5db098896a14d737a19316c9bf4d55a1c3`). Its data
differs from r4's in texting style: apostrophes are left out only in the letters typed, not in the text the
model learns to predict (#561), and text is written txt; and a word's short form is never one of its typos, as
the bank had txt for text (#556). A new model ships if it misses none of the harness's bar rows and gets more
of its rows right than it loses against the committed one (#556).

r4, trained as of `36be6045` (step 15,000; sha256 `ca19bde0037b5d1eb03cd10f70316de53a653bd25353e6d8649fa51e99f29cf1`),
fixed what made r2 and r3 write contractions, capitals and texted words wrong. r2, trained as of `15671d98`, came
before it; r3 added everyday sources and texting style but fixed fewer misspellings than r2 and wasn't committed
([the report](../../docs/experiments/2026-11-16-english-everyday-text.md#results-the-retrained-model-r3-2026-11-16)).
`engines/sebtype-lm/sebtype_lm.cpp`'s scoring was tuned on r4 (#561, #568).

## The model

- A Llama-style transformer: 8 layers, width 512, 8 heads, feed-forward 1,536, input and output embeddings
  shared, 256 tokens of context. 35.7M parameters, about FUTO's size. `config.json` has the training settings.
- SebType's own tokenizer: SentencePiece BPE with 16,384 pieces, trained on the corpus (`tokenizer.py`). r3
  kept r2's (`tokenizer.model` in r2's checkpoint, copied into the run's `data/` before `prepare.sh`).
- **Correction examples in the text.** In front of 5 % of the words, the training text holds the letters
  someone typed for it: `<T>`, the typed letters, `<S>`, then the word as it should be written. The typed
  letters are the word itself (40 %), a phone typo (35 %), a spelling mistake (15 %) or only its first letters
  (10 %) (`noise.py`, `pack.py`). The model learns to predict the meant word from the letters and the
  sentence before them, so on the phone it both predicts and corrects.
  - The phone typos come from taps scattered around the keys, as #46's error mix, by a generator of their own
    (`noise.py`); the harness's phone-typos set uses another (`make_sets.py`).
  - A contraction is typed without its apostrophe 85 % of the time, as people do on a phone, and a word the
    typo bank lacks gets typos made for it.
  - The word after `<S>` is the standard one even when the line is texted: "I'm" for typed "im", a capital
    at a sentence start (`standard()` in `pack.py`); in chat and text messages "can't", "what's" and
    "won't" for typed "cant", "whats" and "wont". One in 20 examples covers two words typed as one.
  - Training learns only the word after `<S>`, never the typed letters, also where a window starts inside
    an example (`labels()` in `train.py`).
- **The phone's context.** Each line is cut into pieces of at most 300 characters, each after its own `<s>`,
  as `window()` in `engines/sebtype-lm/sebtype_lm.cpp` gives the model, and training windows start at `<s>`:
  a window's first piece has the phone's context. The pieces after it in the window see the ones before
  (ordinary packing). A window starts at the `<s>` before a uniformly drawn token, so the sources mix by
  their tokens, as `MIX` says. Pilot r4 (#556) drew windows by `<s>`, which favoured sources of short
  segments; `MIX` is its passes scaled by each source's segments per token, so the retrain keeps the mix the
  pilot was measured on (Wikipedia 60 %, SODA 31 %; `pack.py`, checked by `test.py`).
- **Texting style** (#266). A fifth of the chat sources' lines (SODA, Blended Skill Talk, Topical-Chat) are
  written as people text: lowercase sentence starts, "i", dropped apostrophes and full stops, "u", "pls",
  "gonna" only before a verb (`pack.py`). The real text messages of the NUS SMS Corpus (2 passes in the pilot's sampling, 5.9 now) show the
  model the true mix. The share was
  chosen on the dev sets with short trials ([the report](../../docs/experiments/2026-11-16-english-everyday-text.md)).
- Exported to GGUF and quantised to Q8_0 (`export.sh`): Q6_K, FUTO's, ran 1.4 times as slow on a phone's little
  cores (#406).

On the phone, AOSP's decoder finds the candidates for the typed letters. The model scores each of the first 6
and the typed word as `context <T>typed<S>candidate`, and `decide()` in `engines/sebtype-lm/sebtype_lm.cpp`
adds the decoder's own score to rank them and to decide whether a space corrects the word. Its weights are
tuned on dev sets made from held-out corpus lines (`dev_sets.py`, `tune.py`), never on the harness's sets.
With nothing typed, the model alone gives the next words.

## Running it

On yanglab16, with the corpus, checkpoints and logs in `~/scratch/SebType/<issue>/`:

```sh
tools/english-lm/fetch.sh RUN_DIR                 # venv, llama.cpp, the sources (~12 GB)
tools/english-lm/prepare.sh RUN_DIR [SEEDS...]    # corpus, tokenizer, test.py, typo bank, dev sets, tokens
python tools/english-lm/train.py RUN_DIR tools/english-lm/config.json   # one GPU
tools/english-lm/select.sh RUN_DIR NAME           # each checkpoint's dev gain and next-word top 3, the best last
tools/english-lm/export.sh RUN_DIR/ckpt/NAME/step-N RUN_DIR/sebtype-en.gguf   # the best one
tools/english-lm/dev.sh RUN_DIR RUN_DIR/sebtype-en.gguf [CKPT_DIR]      # dev numbers, tuned weights, parity
python tools/english-lm/overlap.py RUN_DIR        # the corpus doesn't hold the harness's sentences
SEBTYPE_MODEL=RUN_DIR/sebtype-en.gguf android/test/english/run.sh       # the harness, from nobara-pc
```

`python` is the venv's (`~/scratch/SebType/cache/english-lm-venv/bin/python`). The data steps use 8 to 16
processes and the build 24 (yanglab16's build lock), leaving most of the shared machine free. Training needs one
idle GPU (`nvidia-smi`), about 4 GB of its memory.

`prepare.sh` keeps each step's output while its code and inputs are the same, and runs `test.py`, checks of
the pipeline's own code, before the typo bank. `dev.sh` with a checkpoint also checks the GGUF's scores against
the checkpoint's (`parity.py`, on `dev_sets.py`'s `parity.tsv`). The dev sets leave out a query whose last 8
words are in a training file. `select.sh` leaves out a checkpoint whose next-word top 3 falls more than a point
below the best checkpoint's on a set. The harness's bar (`score.py --bar`) needs each new set (contractions,
apostrophes, capitals, and homographs' kept and restored rows apart) fixed at least as often as AOSP and the
text-message sets near FUTO's.

The full retrain (#556), with `RUN_DIR` holding the sources from `fetch.sh`. First copy r2's tokenizer (on
yanglab16 `~/scratch/SebType/cache/english-lm/r2-ckpt/tokenizer.model`, sha256 `7f0149eef056fadee614f17c63c3af5b013661ea2888972b99b4cbcfd1617d27`);
without it `prepare.sh` stops rather than train a new one:

```sh
cp ~/scratch/SebType/cache/english-lm/r2-ckpt/tokenizer.model RUN_DIR/data/ &&
tools/english-lm/prepare.sh RUN_DIR 0 1 2 &&
python tools/english-lm/train.py RUN_DIR tools/english-lm/config.json &&
tools/english-lm/select.sh RUN_DIR r4
```

r5e, then, from that run's step 15,000 (`ckpt/r4/step-15000` in `RUN_DIR`), on a fresh pack:

```sh
python tools/english-lm/pack.py RUN_DIR train 5 0.2 0.4 &&
python tools/english-lm/train.py RUN_DIR tools/english-lm/config-r5e.json &&
tools/english-lm/select.sh RUN_DIR r5e
```

Training on a GPU isn't bit-exact: a rebuild's checkpoints differ a little. Two builds of r5c, the same recipe
before the txt changes, picked step 1,000 and step 500 (dev gain 107.65 and 107.58).

A model trained on the sources r2 didn't have (NUS SMS, Blended Skill Talk, Topical-Chat, Tatoeba) adds them to
NOTICE's credits in the PR that ships it.
