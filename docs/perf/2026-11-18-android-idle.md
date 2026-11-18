# Android idle memory and key → idle after stage 6 (2026-11-18, #351)

Stage 6 (#262, PR #334) measured two regressions against today's release (157, the FUTO-based app):
idle memory in a fresh process and the time from a key to the keyboard's last frame. This run finds
what causes each. It fixes the memory regression and records why the key → idle gap stays.

## Device and method

The guide35 emulator, `android/perf/compare-apks.sh` with RUNS=2: release 157 against a release build
of this branch, run alternately in one emulator lock. Stage 6's own runs are in
`~/scratch/SebType/262/perf-compare/`, this run's in `~/scratch/SebType/351/perf-compare/`. Medians and
95th percentiles are written "p50 / p95". The emulator's English model is slower than a phone's
(arm64 code on an x86_64 host).

## Results

| Metric | Today's release (157) | Stage 6 (#262) | This PR | Plan target (stage 6) |
|---|---|---|---|---|
| PSS idle, fresh process, EN | 68 / 71 MB | 108 / 108 MB | 66 / 70 MB | ≤ 60 MB |
| PSS after typing EN | 187 / 191 MB | 172 / 176 MB | 136 / 140 MB | ≤ 180 MB |
| EN key → keyboard idle, p50 / p95 | 131 / 429 ms | 324 / 662 ms | 331 / 668 ms | – |
| EN key → text on screen, p50 / p95 | 16–17 / 31–33 ms | 17 / 31 ms | 17 / 34 ms | – |
| Keyboard open, warm, p50 | 63–67 ms | 28 ms | 29–30 ms | – |
| Keyboard open, cold, p50 | 925–964 ms | 918 ms | 1016 ms | – |
| Fast typing: frames late because of the app | 63–70 of 438 | 15 of 203 | 4–8 of 200 | – |

Each cell gives both runs. The cold open is within run-to-run noise on the emulator: this PR doesn't
touch what the first frame waits for, and stage 6 measured 918–1015 ms over its runs.

## Idle memory: Rime started in every keyboard process

`Engines.configure` and then `prepareChinese` ran in the keyboard service's `onCreate`, so every
keyboard process started Rime and loaded rime_ice's tables and prism, even in English. Today's app
sets Chinese up in the background too, but only after an install or update, and stops Rime again 3
minutes later (#56). Stage 6's `meminfo-fresh.txt` shows the difference: "Other mmap" 47 MB (Rime's
mapped tables, 36 MB private dirty) against 22 MB with Rime stopped, and the native heap 26 against
20 MB.

Fix: the service's start (and `UpdateReceiver`) call `Engines.setUpChineseAhead`. It runs the
install and deploy only when this version hasn't done them yet, and then lets Rime stop after the
usual 3 minutes unless 中文 is in use. Otherwise Rime starts when 中文 is picked, as after an idle
stop (`prepareChinese` in `onStartInput`). Until Rime is up, the bar shows "preparing", as in today's
app after its idle stop. The `zh-waits-for-zh` check in
`android/test/chinese.py` covers it: a process that starts in English logs no Rime setup, and 中文
then types ranh → 然后.

The same change lowers PSS after typing English by about 36 MB, because Rime no longer sits under
the English model.

Not reached: the plan's ≤ 60 MB. What is left is about level with today's app: the native heap
(20 MB), the native libraries (13 MB) and other mapped files (22 MB). `dumpsys meminfo` doesn't name
the files behind them. That breakdown needs `showmap` from a root shell, and `perf.sh --compare-device`
doesn't have one.

## Key → keyboard idle: the English model's strip arrives later

Each of the stage 6 trace's late keyboard frames (200–680 ms after a key) follows 100–200 ms of CPU
on English's model thread and then the engine's `state()` call (`NativeCore.onEnglishReady`). That
frame is the candidate bar showing the model's ranking for the word being typed (#310). Today's app
has a late frame after about as many keys (73 of 88, against 75 of 88), but its FUTO transformer
ran on only 20 of 88 keys and turned itself off after 6 misses. Its late frame is mostly the key
preview closing, at about 130 ms. No animation and no repeated redraw keeps the new keyboard
drawing: it's one frame per key, when the model is done.

Not fixed. The frame can only come sooner if the model does less work or stops running, and either
change costs suggestion quality, which the English harness's bars guard. Text on screen, typing
latency and late frames are equal or better than today's. The emulator runs the model slower than a phone, so
the gap there is likely smaller; a phone run would show it.

Tried and dropped: setting the space bar's label only when it changes, which saved a redraw of the
key area on each candidate update. It didn't move key → idle in this run.
