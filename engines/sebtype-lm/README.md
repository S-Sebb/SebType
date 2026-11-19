# SebType's models and their loaders

- `sebtype_lm.h`, `sebtype_lm.cpp`: the loader on llama.cpp (MIT, fetched at a pinned commit by
  `fetch-llama.sh`), SebType's own code under the MIT licence.
- `bench/bench.sh`: how long the next words take after an empty field and after 20,000 characters, and how
  often the next word is predicted with each context window (#359).
- `bench/zh-keys.sh`: the Chinese model's jobs per key on a phone, timed on its big and little cores, with the
  app's llama.cpp build (#264, [results](../../docs/perf/2026-11-19-chinese-model.md)).
- `english.gguf`: the model, trained by [tools/english-lm](../../tools/english-lm/README.md) (release r2, #236),
  quantised to Q8_0 (#406), 38,305,184 bytes, sha256 `58b90c6c60a96cdb69ba5d4a38d0a6a6c20bd22018fc02565d9c284ceb67beec`. It is
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
