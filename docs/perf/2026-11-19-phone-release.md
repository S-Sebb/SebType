# The phone before the first release (#353, 2026-11-18/19)

The owner's phone (nothing-a001, A001, Android 16, no root shell), the owner present, release
0.1.30-sebtype.181 (main at da8ee60e5b, signed with SebType's key). Medians and 95th percentiles are
written "p50 / p95".

## Update from the FUTO-based app

`MAIN_APK=<release 157> SEBTYPE_CHECKS=update-from-futo-app android/test/emulator.sh` passed. No GitHub
release of the FUTO-based app exists, so MAIN_APK was release 157 (0.1.30-sebtype.157, the same signing
key), the build stage 6 compared against.

- SebType stayed enabled and the keyboard in use after the update.
- Learned words, all made up or the test's own: English `zorbl` → Zorbl, Zorbleq (the old app's
  `zorbleq`), 中文 `lh` → 厉害 first, 日本語 `hashi` → 端 first (picked third before the update).
- Options as both apps' settings screens show them: autocorrect off, emoji suggestions off, fuzzy
  pinyin z = zh on, and, in a second update, learning off.

Without a root shell the check can't read the app's files (the old app's English history, the
options' DataStore and `sebtype.conf`), so on the phone it compares the settings screens before and
after instead, and the English word only after the update.

## Speed: the keyboard ran on the little cores

`perf.sh --english` and `perf.sh --chinese`, `RUNS=3`:

| Set | Ranking, p50 / p95 (n) | Next words, p50 / p95 (n) | Spaces decided by the model | Space's wait, p50 / p95 |
|---|---|---|---|---|
| EN, 700 ms per key | 105 / 207 ms (104) | 192 / 232 ms (29) | 27 of 27: ready 27 | none waited |
| Fast, 100 ms per key | 132 / 235 ms (38) | 196 / 230 ms (17) | 18 of 18: waited 18 | 158 / 327 ms |
| Long field, 100 ms per key | 168 / 923 ms (17) | 264 / 1049 ms (8) | 5 of 18: ready 1, waited 4; ranking late 1, not waited for 12 | 214 / 400 ms |
| 中, 700 ms per key | 71 / 113 ms (129) | 77 / 183 ms (21) | – | – |

The `--chinese` run's EN set gave the same: 104 / 206 ms and 191 / 232 ms. Both targets are missed:
the long field's next words aren't near the short field's (and the short field's are 192 ms, not the
42 ms of the run on 2026-11-18), and 中's are far over the 20 ms budget (#264).

The cause is where the keyboard ran, not the code: in every trace of both runs the whole keyboard
process ran on CPUs 0–3, the phone's 2.0 GHz little cores, and almost never on 4–7 (2.5 GHz). In
the EN set the model's thread ran 17.9 s on the little cores and 0.04 s on the big ones. Nothing
between the 2026-11-18 run (#357's head) and this build changes threads, priorities or affinity.
The process was in `top-app` with all eight CPUs allowed, so the placement is the phone's scheduler.
Two of the owner's apps were busy during the EN set (YouTube Music 14.6 s and Discord 11.7 s of CPU),
and the phone was short of memory (0.5 GB free, 3.2 GB in swap). The phone also has its own cpuset
for CPUs 0–3 (`nt_foreground`). The 2026-11-18 numbers show what the model does on the big cores. A
run with the phone idle would show whether the scheduler gives them back.

Typing itself stayed fast: key → text on screen 16 / 20 ms (EN), 18 / 99 ms (fast), 35 / 49 ms (long);
key handling 2 / 4 ms (EN) and 2 / 3 ms (中). No keyboard crashed.

## First run and memory

| Metric | `--english` | `--chinese` |
|---|---|---|
| Keyboard open, first after install | 568 ms | 597 ms |
| Chinese first-run setup (install + Rime's check) | 977 ms (install 453 ms) | 997 ms (install 498 ms) |
| RSS peak, first open with the Chinese setup (#358) | 212 MB | 209 MB |
| PSS idle, first open, EN | 169 MB | 171 MB |
| PSS after typing EN | 146 MB | 149 MB |
| PSS after typing 中 | – | 226 MB |
| EN key → keyboard idle | 159 / 240 ms | 159 / 238 ms |
| 中 key → keyboard idle | – | 101 / 152 ms |

The first open's PSS includes the Chinese setup the first process runs (#358), so it isn't the
fresh-process idle of [2026-11-18-android-idle.md](2026-11-18-android-idle.md), which these modes
don't measure. Files compiled on the device and installed size need a root shell.
