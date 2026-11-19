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
after instead, and the English word only after the update. Fuzzy pinyin is also checked the way Rime
types it: `zengzi` must offer 政治 among its first three candidates, which only z = zh does (guide35:
third with it; 曾子, 曾祖, 增资, 增子, 甑子 without). The phone's run predates that check.

## Speed: the keyboard ran on the little cores

`perf.sh --english` and `perf.sh --chinese`, `RUNS=3`, with the owner's apps running (the busy run):

| Set (busy run) | Ranking, p50 / p95 (n) | Next words, p50 / p95 (n) | Spaces decided by the model | Space's wait, p50 / p95 |
|---|---|---|---|---|
| EN, 700 ms per key | 105 / 207 ms (104) | 192 / 232 ms (29) | 27 of 27: ready 27 | none waited |
| Fast, 100 ms per key | 132 / 235 ms (38) | 196 / 230 ms (17) | 18 of 18: waited 18 | 158 / 327 ms |
| Long field, 100 ms per key | 168 / 923 ms (17) | 264 / 1049 ms (8) | 5 of 18: ready 1, waited 4; ranking late 1, not waited for 12 | 214 / 400 ms |
| 中, 700 ms per key | 71 / 113 ms (129) | 77 / 183 ms (21) | – | – |

The `--chinese` run's EN set gave the same: 104 / 206 ms and 191 / 232 ms. Both targets are missed:
the long field's next words aren't near the short field's (and the short field's are 192 ms, not the
42 ms of the run on 2026-11-18), and 中's are far over the 20 ms budget (#264).

In every trace of both runs the whole keyboard process ran on CPUs 0–3, the phone's 2.0 GHz little
cores, and almost never on 4–7 (2.5 GHz). In the EN set the model's thread ran 17.9 s on the little
cores and 0.04 s on the big ones. The process was in `top-app` with all eight CPUs allowed. Nothing
between the 2026-11-18 run (#357's head) and this build changes threads, priorities or affinity.

This is the A001's known placement quirk (#62): the same APK runs on the little cores in one run and
on the big cores in the next, at 99 / 141 ms against 21 / 32 ms of English prediction per key. That
is the same ~5× gap as between this run and 2026-11-18's. Two of the owner's apps were also busy
during the EN set (YouTube Music 14.6 s and Discord 11.7 s of CPU), and the phone was short of memory
(0.5 GB free, 3.2 GB in swap), so this run can't say which of the two set the placement.

**Still to do, with the owner present:** the idle re-run. `PERF_STOP="com.google.android.apps.youtube.music
com.discord"` stops those apps under the device lock first. Repeat it several times, because the
placement varies between runs (#62), and record each run's cores. A first try on 2026-11-19 stopped
both apps (no media playing afterwards) but the phone was locked during the try. Only its Chinese
setup was measured (table below); every other step failed at the lock screen.

Typing itself stayed fast: key → text on screen 16 / 20 ms (EN), 18 / 99 ms (fast), 35 / 49 ms (long);
key handling 2 / 4 ms (EN) and 2 / 3 ms (中). No keyboard crashed.

## First run and memory

| Metric | `--english` (busy) | `--chinese` (busy) | `--chinese`, partial idle try |
|---|---|---|---|
| Keyboard open, first after install | 568 ms | 597 ms | – |
| Chinese first-run setup (install + Rime's check) | 977 ms (install 453 ms) | 997 ms (install 498 ms) | 1089 ms (install 634 ms) |
| RSS peak, first open with the Chinese setup (#358) | 212 MB | 209 MB | 136 MB |
| PSS idle, first open, EN | 169 MB | 171 MB | – |
| PSS after typing EN | 146 MB | 149 MB | – |
| PSS after typing 中 | – | 226 MB | – |
| EN key → keyboard idle | 159 / 240 ms | 159 / 238 ms | – |
| 中 key → keyboard idle | – | 101 / 152 ms | – |

The partial idle try had 2.96 GB available and 5.47 GB of 8.39 GB swap free before it. Its first
open failed at the lock screen, so its RSS peak may not cover a whole first open. The first open's
PSS includes the Chinese setup the first process runs (#358), so it isn't the fresh-process idle of [2026-11-18-android-idle.md](2026-11-18-android-idle.md), which these modes
don't measure. Files compiled on the device and installed size need a root shell.
