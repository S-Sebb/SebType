# Everyday spoken phrases with context (#484)

`dev-spoken.tsv`: 50 phrases written by hand, each with the text before it (context, keys, target, kind):
24 verb–object words split by 个 (我再去 + `jiangeshen` → 健个身), 8 whose reading depends on the context
(好困，我想 + `shuijiao` → 睡觉; 好饿，我想吃 → 水饺) and 18 other everyday phrases. `dev-nocontext.tsv` is
the same without the context. Librime alone checks `data/rime/bench/sets/spoken.tsv`, the same phrases, in
`slips.sh`. With the model, as the keyboard ranks (Rime's first 4, a beam of 2):

    android/test/chinese-lm/bench.sh --dev android/test/chinese-lm/spoken OUT_DIR engines/sebtype-lm/chinese.gguf \
      rerank=4 generate=2 rankWeight=0.5 generatedRank=4 dump=1

OUT_DIR is on the build host when run through `build_remotely` (tools/lib.sh): put it under the host's
~/scratch/SebType, not in the checkout, whose copy each run's rsync replaces.

| Top-1 with the model (yanglab16, 2026-11-22) | with context | without |
|---|---|---|
| before #484 | 40 / 50 (split 17 / 24) | 32 / 50 (split 12 / 24) |
| with sebtype_ge.lua | 41 / 50 (split 18 / 24) | 33 / 50 (split 13 / 24) |

Librime alone has all 24 split words first since #484; the model's own candidates (剪个深 for `jiangeshen`,
log probability −1.8 against 健个身's −5.3) still outrank 6 of them.
