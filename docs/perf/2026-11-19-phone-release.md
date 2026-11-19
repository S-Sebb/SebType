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

A first idle try on 2026-11-19 had the phone locked, so only its Chinese setup was measured (table
below). A second one ran with the screen turned sideways: its taps missed the keys (#402, fixed in
#403).

## Speed on an idle phone: the cores still decide

Release 0.1.30-sebtype.196 (main at bd7ebdd566), the owner present, the phone unlocked and upright,
`PERF_STOP="com.google.android.apps.youtube.music com.discord"` (both stopped, no media playing),
2.8–3.4 GB available. Five runs, each a fresh install: `--english` three times, `--chinese` twice (a
third `--chinese` didn't start: another project held the phone). Cores are the keyboard process's CPU
time in the EN set's trace, CPUs 0–3 (little) / 4–7 (big):

| Run | Cores, little / big | EN ranking | EN next words | Fast: spaces that waited, wait | Long field: next words, spaces decided | 中 ranking | 中 next words |
|---|---|---|---|---|---|---|---|
| english-1 | 0.7 / 6.9 s | 22 / 46 ms | 42 / 65 ms | 0 of 18 | 43 / 250 ms, 18 of 18 | – | – |
| english-2 | 24.6 / 0.2 s | 101 / 205 ms | 190 / 230 ms | 18 of 18, 152 / 281 ms | 641 / 1041 ms, 4 of 18 | – | – |
| english-3 | 0.8 / 6.9 s | 21 / 45 ms | 41 / 61 ms | 0 of 18 | 43 / 250 ms, 18 of 18 | – | – |
| chinese-1 | 24.5 / 0.2 s | 105 / 206 ms | 190 / 230 ms | – | – | 70 / 106 ms | 73 / 114 ms |
| chinese-2 | 0.7 / 7.0 s | 21 / 46 ms | 42 / 74 ms | – | – | 21 / 32 ms | 29 / 137 ms |

Each run stayed on one side for its whole process: the fast and long sets and the 中 set ran on the
same cores as that run's EN set. With nothing else busy, two of five runs still got the little cores.
So the busy run's little cores needn't have come from the owner's apps. This is #62's placement.

What sets it ([#62](https://github.com/S-Sebb/SebType/issues/62#issuecomment-7012804195)): a
keyboard process starts either in `top-app` (CPUs 0–7) or in Nothing's own cpuset `nt_foreground`,
and it stays there for the whole life of the process. Google Play services and other Google system
processes also run in `nt_foreground`. Its CPUs change: 0–3 during #62's runs, 0–7 when read again
later that day. Of 10 fresh starts with the keyboard hidden, 6 landed in `nt_foreground`. An ADPF
hint session and pinning the model's thread to CPUs 4–7 both left the thread on 0–3. The app can't
leave the cpuset, so the owner released with this as a known limitation of the A001. Making English
fast enough on the little cores is #406.

Gboard, measured the same way on the same afternoon, alternating with SebType 201: each start was
on the home screen, with the keyboard force-stopped and selected again, then Messages' compose field
opened. Gboard was in `top-app` in all 20 starts, and in 20 more earlier that afternoon. SebType was
in `nt_foreground` in 2 of its 20 starts, against #62's 6 of 10 earlier that day.
`nt_foreground` allowed CPUs 0–7 in 38 of the 40 reads, so neither keyboard was slowed then. Gboard
may be exempt from `nt_foreground`, but 20 SebType starts with 2 in it can't show that.

- On the big cores the long field is fixed (#359): next words at the short field's 42 ms median, and
  17 of 18 spaces didn't wait (the one that did waited 81 ms). Its p95 is still 250 ms.
- 中 misses #264's 20 ms p95 on both: 32 ms ranking and 137 ms next words on the big cores
  (since then 14–16 ms ranking and 12–31 ms next words: [中's model on the phone](2026-11-19-chinese-model.md)).
- On the little cores, fast typing waits at every space (152 / 281 ms), and the long field's ranking
  is late or skipped for 14 of 18 spaces.

What doesn't depend on the cores: every key was typed (44 of 44 three times, 88 of 88, 中 14 of 14
three times), no keyboard crashed, and key → text on screen was 14–18 / 19–23 ms (EN and fast; english-2's fast set: 18 / 89 ms)
and 26–35 / 32–52 ms (long field). Janky keyboard frames: 0–0.3 % (fast), 0–1.5 % (long). The field's
janky frames in the long field were 0–0.6 %, except english-2's 27.9 % (p95 frame 29 ms), on the
little cores.

| Metric, range over the five runs | Big-core runs | Little-core runs |
|---|---|---|
| Keyboard open, first after install | 1019–1179 ms | 988–1245 ms |
| Chinese first-run setup (install + Rime's check) | 964–1138 ms | 1118–1141 ms |
| RSS peak, first open with the Chinese setup | 212–219 MB | 218–219 MB |
| PSS idle, first open, EN | 169–175 MB | 173–174 MB |
| PSS after typing EN | 136–151 MB | 149–156 MB |
| PSS after typing 中 | 205 MB | 234 MB |
| EN key → keyboard idle | 48–49 / 67–68 ms | 156–158 / 240–241 ms |
| 中 key → keyboard idle | 44 / 58 ms | 101 / 151 ms |

The first open took about twice the busy run's 568–597 ms on every run, on both kinds of cores.

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
