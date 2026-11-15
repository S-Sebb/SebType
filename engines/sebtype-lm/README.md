# SebType's English model and its loader

- `sebtype_lm.h`, `sebtype_lm.cpp`: the loader on llama.cpp (MIT, fetched at a pinned commit by
  `fetch-llama.sh`), SebType's own code under the MIT licence.
- `english.gguf`: the model, trained by [tools/english-lm](../../tools/english-lm/README.md) (release r2, #236),
  29,670,816 bytes, sha256 `34dd561818a45c4afb3dd68a73b53ad83668d9ef50cc19a1332c76cb21e42f62`. It is
  licensed under CC BY-SA 4.0 (Decisions 6 of [the plan](../../docs/plans/android-own-keyboard.md)), with its
  training sources credited in [NOTICE](../../NOTICE) and listed in
  [SOURCES.md](../../tools/english-lm/SOURCES.md).

The model is committed, not fetched, so that builds work offline and with no release to host it (releases are
held until stage 6). A new model replaces the file, and this README's size and hash, in the PR that shows it
passes the English harness (`android/test/english/run.sh`).

`core/src/english.cpp` runs it behind `core/`: AOSP's decoder (`engines/latinime`) finds the candidates, and
the model ranks them, decides what a space corrects and predicts the next words.
