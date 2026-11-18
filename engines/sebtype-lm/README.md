# SebType's models and their loaders

- `sebtype_lm.h`, `sebtype_lm.cpp`: the loader on llama.cpp (MIT, fetched at a pinned commit by
  `fetch-llama.sh`), SebType's own code under the MIT licence.
- `bench/bench.sh`: how long the next words take after an empty field and after 20,000 characters, and how
  often the next word is predicted with each context window (#359).
- `english.gguf`: the model, trained by [tools/english-lm](../../tools/english-lm/README.md) (release r2, #236),
  29,670,816 bytes, sha256 `34dd561818a45c4afb3dd68a73b53ad83668d9ef50cc19a1332c76cb21e42f62`. It is
  licensed under CC BY-SA 4.0 (Decisions 6 of [the plan](../../docs/plans/android-own-keyboard.md)), with its
  training sources credited in [NOTICE](../../NOTICE) and listed in
  [SOURCES.md](../../tools/english-lm/SOURCES.md).

- `zh_lm.h`, `zh_lm.cpp`: the Chinese model's loader (#259, #264), SebType's own code under the MIT licence.
- `chinese.gguf`: the Chinese model, trained by [tools/chinese-lm](../../tools/chinese-lm/README.md) (release
  r1, #259), 17,035,808 bytes, sha256 `d544a19dbe89b4f95fdd629525e87125ed3a9ea08f4c9d632ab75d0f9a4c9192`.
  CC BY-SA 4.0 too, as part of its text is share-alike, with its sources credited in [NOTICE](../../NOTICE)
  and listed in [SOURCES.md](../../tools/chinese-lm/SOURCES.md). `core/src/chinese.cpp` runs it around Rime;
  the Chinese harness (`android/test/chinese-lm/run.sh`) measures it.

The models are committed, not fetched, so that builds work offline and with no release to host it (releases are
held until stage 6). A new model replaces the file, and this README's size and hash, in the PR that shows it
passes its harness (`android/test/english/run.sh`, `android/test/chinese-lm/run.sh`).

`core/src/english.cpp` runs it behind `core/`: AOSP's decoder (`engines/latinime`) finds the candidates, and
the model ranks them, decides what a space corrects and predicts the next words.
