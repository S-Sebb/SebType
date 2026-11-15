# Plan: SebType's own Android keyboard on core/ (#191, #190 step 3)

Status: a plan for the user to approve. Nothing here is built yet.

The user's goal (2026-11-15): "I want to make sure as much of these components are our own code in consistent
form, so everything is easier to maintain and we can clean up things as much as possible while reducing final
app size and improving performance while not being limited."

Sources: Requirements #1, Decisions #2 (up to "2026-11-15, identity"), #53's kept and removed lists, #108's
inventory (how much of the app is FUTO's, 2026-11-10), #46's offline English measurements, #190's step 3
comparison, [docs/perf/2026-11-12.md](../perf/2026-11-12.md) and [2026-11-15.md](../perf/2026-11-15.md), and the
code at `bb822b88`. Sizes are from the release APK built from main on 2026-11-15 (108.8 MB, or 103.8 MiB; the
perf runs call it 103–105 MB).

## Summary

- **Build a new app and don't touch FUTO's.** It is written from scratch in Kotlin on top of `core/`, inside
  `dev.sebb.sebtype`. English uses the pristine AOSP LatinIME decoder (Apache-2.0), taken from AOSP's own repo,
  not FUTO's copy. The phone runs librime and Mozc in-process, behind the same `core/` engines the PCs use.
- **The size comes from data, not UI code.** The APK is 42 % Mozc's dictionary, 28 % FUTO's English model and
  19 % Rime's data. All the UI and engine code together is under 9 %. A new UI saves about 2 MB. Dropping FUTO's
  model saves 31 MB and about 70 MB of PSS while typing English.
- **The main risk is English next-word prediction.** FUTO's model is FUTO-licensed and has to go (#108). The plan
  first measures today's English offline. It then replaces the model with the AOSP decoder and SebType's own
  n-gram dictionary, and only trains a small model of SebType's own if the measured quality falls short.
- **No FUTO code ships after stage 6.** The payment screen, the unpaid notice and FUTO's licence notice go in the
  same release.
- **About 33–48 delegate-days in 7 stages**, plus 6–10 if a model of SebType's own is needed. Every stage keeps the released app shippable. Until stage 6 the
  release is still the FUTO-based app.

## 1. Inventory

"Lines" counts code in the tree today. Shares are of the 108.8 MB APK. The 2.8 MB `classes.dex` (2.6 %) and the
1.0 MB `resources.arsc` (0.9 %) hold every Kotlin and Java feature together. A feature's own share of them is far
below 1 %, so those rows show "code". Decisions:

- **Rewrite**: new code of SebType's own, MIT.
- **Reuse**: kept as it is, under the licence given.
- **Drop**: not carried over.

Correction to #191's "about 390k lines of Kotlin": the app has 37k lines of Kotlin, 41k of Java and 296k of C/C++.
Of the C/C++, 258k is vendored sentencepiece, ggml, absl and protobuf. By #108's blame, 58 % of the Kotlin and
Java is FUTO's, 39 % AOSP's and 3 % SebType's.

### Typing and engines

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Keyboard view, keys, long-press popups, key preview, touch handling | `keyboard/` (AOSP-origin, FUTO-edited) | 13,445 | code | **Rewrite**: one custom `View` drawn on a Canvas (§3) |
| Layout engine (YAML layouts, subtypes, globe list) | `v2keyboard/`, `latin/Subtypes.kt` | 4,591 | code | **Rewrite**: a small JSON layout format for the 3 layouts, symbols, the number row and later Russian |
| SebType's EN/中/日 layouts | `assets/layouts/SebType/` (Apache-2.0, adapted from FUTO's) | 212 KB of files | < 0.1 % | **Rewrite** in the new format. Same keys in the same places (#1, #10) |
| Text field handling (InputConnection, composing text, cursor tracking) | `latin/RichInputConnection.java`, `latin/inputlogic/`, wrappers | ~5,300 | code | **Rewrite**, guided by pristine AOSP's `RichInputConnection` (Apache-2.0) |
| Field kinds: password, PIN, URL, private tabs → incognito (#26, #31) | `latin/InputAttributes.java`, `IncognitoAction.kt` | 455 | code | **Rewrite**. Same rules, including "private: learned words used, nothing new learned" (2026-11-12) |
| 中文 engine glue (Rime, candidates, 简/繁, punctuation, emoji, typo re-ranker) | `engine/general/ChineseIME.kt`, `android/rime/` (RimeJni, MIT) | 871 + 1,183 | librime-jni 1.6 % | **Rewrite** onto `core/` (Rime in `core/src/rime.cpp`) |
| 日本語 engine glue (romaji, あ/ア chip, katakana candidates) | `engine/general/JapaneseIME.kt`, `android/mozc/src` (FUTO's mozc-lib: Google's BSD client with FUTO's edits) | 1,187 + ~12,200 | libmozc 1.1 % | **Rewrite** onto `core/` (Mozc in-process, §3). The 12k-line Java client goes |
| Multi-engine layer and globe switching | `engine/IMEManager.kt`, `GeneralIME.kt`, `IMEInterface.kt` | ~1,350 | code | **Rewrite**: `core/` owns languages and switching |
| Floating pre-edit (pinyin above the keys) | `latin/uix/FloatingPreEdit.kt` | 176 | code | **Rewrite** as part of the candidate bar |
| English decoder: completion and autocorrect (about 70 % of phone typos fixed, #46) | `cpp/src/dictionary`, `cpp/src/suggest` (AOSP plus 1,395 lines of FUTO's), `latin/Suggest.java` and dictionaries | 28,500 C++ + 3,900 Java | part of latinime 1.0 % | **Reuse pristine AOSP** native decoder (Apache-2.0, 29,950 lines at AOSP `127336e`) in `engines/latinime/`. **Rewrite** the glue in `core/` |
| English transformer (next-word, completion re-ranking) | `latin/xlm/`, the LanguageModel JNI, ggml, sentencepiece | 1,265 Kotlin + 1,315 + 218k vendored | model 28.2 % + part of latinime 1.0 % | **Drop** FUTO's model and its code. Replace per §2 |
| English dictionary (FUTO's words, wordfreq frequencies, SCOWL-checked modern words; #40) | `res/raw/main_en.dict` (FUTO's licence + CC BY-SA 4.0) | data | 1.0 % | **Rewrite** the build: AOSP `en_US` wordlist (Apache-2.0) + wordfreq (CC BY-SA 4.0) + SCOWL words + n-grams (§2) |
| Learned English words and personal dictionary | `UserBinaryDictionary`, `personalization/` | 511 | code | **Reuse** AOSP's user-history format through its native code. **Rewrite** the glue |
| Blocked-words filter (fixed on, #41) | `BadWords.kt`, `SuggestionBlacklist.kt` | ~150 | code | **Rewrite**: a word list applied in the English engine |
| Email domain suggestions (kept, #53 B10) | `latin/EmailDictionary.kt` | 28 | code | **Rewrite** |
| Period after a suggestion, ".py" rule (#39) | `inputlogic/` | small | code | **Rewrite**. Its four `LiveSpacingTests` become emulator checks |
| Spacebar and backspace swipes (kept, #53 B11) | `keyboard/`, `inputlogic/` | small | code | **Rewrite** in the keyboard view |
| Gesture (glide) typing | dropped 2026-11-09 (Decisions #2), library removed in #59 | dead code in `keyboard/internal/` | 0 | **Drop**. AOSP has no open gesture decoder, so bringing it back later would be SebType's own work |
| Accessibility (TalkBack) | `accessibility/` (AOSP) | 1,338 | code | **Rewrite** with `ExploreByTouchHelper`: every key and candidate gets a text label. The emulator checks find keys that way (`uiautomator dump`) |

### Bars, panels and actions

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Suggestion bar, mode chip (あ/ア, #38), up to 128 candidates scrolling | `UixManager.kt`, `ActionBar.kt` | 3,451 | code | **Rewrite** |
| Action bar and its buttons editor (#41) | `ActionBar.kt`, `actions/Registry.kt`, `MoreActions.kt` | ~800 | code | **Rewrite** |
| All Actions with the 简/繁 switch (#36, #53 A1) | `actions/MoreActions.kt` | 342 | code | **Rewrite** |
| Undo/Redo, Cut/Copy/Paste/Select All, Settings buttons (kept, #53) | `actions/*` | ~80 | code | **Rewrite** |
| Emoji picker, skin tones, recents (kept, #53 B1) | `actions/emoji/`, `EmojiTracker.kt`, Noto Color Emoji font, `gemoji.json` (MIT), `emoji_i18n` names (FUTO's) | 1,608 | font 1.0 %, names 0.1 % | **Rewrite** the picker. **Reuse** gemoji (MIT). Names come from Unicode CLDR annotations (Unicode licence). **Drop** the bundled font: the system's emoji font covers Android 16 |
| Clipboard history (FUTO's defaults, #26) and quick clips (#53 B8) | `actions/clipboard/`, `QuickClip.kt` | 2,109 | code | **Rewrite** |
| Inline autofill chips (kept, #53 B9) | `InlineSuggestionView.kt` | 245 | code | **Rewrite** (Android's inline suggestions API) |
| Keyboard modes: one-handed, floating, split; height (#41, #53 A2) | `resizing/`, `KeyboardSizingActions.kt` | 781 | code | **Rewrite** |
| Number row, hidden by default, Gboard's layout (#161) | layouts | small | code | **Rewrite** |
| Input-method picker (long-press 🌐, #53 A4) | Android API | small | code | **Rewrite** (one call) |
| Picnic theme, light and dark alike (#17, #87, #111) | `uix/theme/`, `ColorScheme.kt`, theme providers | ~1,600 | about 0.4 % of drawables | **Rewrite**: one fixed theme, no theme engine. **Reuse** SebType's own art and fonts (OFL) |

### Settings, data and app

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Settings in 6 groups, pixel frames (#41, #87); 中文 My words, emoji, punctuation; Forget learned words | `uix/settings/` (FUTO's) + `dev/sebb/sebtype/settings/` (SebType's) | 6,442 + 1,043 | code | **Rewrite** FUTO's part. **Reuse** SebType's pages where they don't depend on FUTO's settings framework |
| Setup wizard (#53 A3) | `settings/Setup.kt` | 170 | code | **Rewrite** |
| Settings export and import, PC words import (#11, #34, #44) | `SettingsExporter.kt`, `ImportResourceActivity.kt` | 1,369 | code | **Rewrite**. **Reuse** `sync/PersonalDataImport.kt` (SebType's) |
| Sync with the user's own server (#12, #14) | `dev/sebb/sebtype/sync/` | 530 | code | **Reuse** (MIT, SebType's) |
| Crash reports to the sync server (#26) | `dev/sebb/sebtype/CrashReports.kt` and app class | 176 | code | **Reuse** |
| Chinese data setup (bundled compiled data, no deploy) | `dev/sebb/sebtype/chinese/` | 524 | Rime data 19.2 % | **Reuse**. The data is unchanged, GPL-3.0, shipped as now |
| Mozc dictionary | `libmozc` data (`res/gj.dict`, stored uncompressed for mmap) | data | 41.7 % | **Reuse** unchanged (BSD-3 and its data licences). Shrinking it is out of scope (see §5) |
| Licences and credits screen | `settings/pages/credits/` | 2,176 | code | **Rewrite**: one generated list of components |
| Payment screen, thank-you screen, unpaid notice (#112) | `settings/pages/Payment.kt`, `latin/payment/`, `UixManager` notices | 814 | code | **Stays until stage 6, then Drop** (§4) |
| FUTO's translations (ja, zh-CN strings) | `res/values-ja/`, `values-zh-rCN/` | ~2,000 strings | part of arsc | **Rewrite** SebType's own strings in 3 languages, fewer of them |
| `libc++_shared.so` workaround (#62) | build | – | 0.4 % | **Reuse** until #62 finds the real cause. The new app has its own native library to load anyway, so the workaround may not be needed (stage 6 measures it) |
| Developer mode, WordStyles, text editor pad, spell checker, memory overlay (removed, #53) | gone | 0 | 0 | **Drop** (already gone) |
| Voice input, other languages, update checks (removed, #59) | gone | 0 | 0 | **Drop**. Russian stays possible: the layout format and English engine take any alphabet and AOSP ships a Russian wordlist (Apache-2.0) |

## 2. English without FUTO's code

**What to beat.** Requirements #1 asks for "Good recommended (next-word and completion) suggestions" and a space
after a picked word. #46 found that English autocorrect fixes about 70 % of phone typos. Today all three come
from AOSP's decoder plus FUTO's tweaks plus FUTO's transformer.

**Options weighed:**

| Option | Next-word | Completion and autocorrect | Size, PSS, latency | Licence | Verdict |
|---|---|---|---|---|---|
| **A. Pristine AOSP decoder + SebType's own dictionary with n-grams** | Up to 3-gram contexts from a built corpus, plus learned words. Weaker than a transformer on long context | AOSP's proximity decoder: the same core as today's 70 % | dict ~5–15 MB; no model in RAM; a few ms per key | Apache-2.0 code; dictionary from Apache, CC BY-SA and openly licensed text | **First** |
| B. SebType-trained small transformer (~20–36M parameters) on llama.cpp/ggml (MIT), re-ranking A's candidates | Close to today if trained well. Community models trained from scratch exist (Greek, Albanian, Danish) | Adds context-aware re-ranking on top of A | +15–30 MB APK, +40–70 MB PSS, tens of ms per key | Own weights, MIT. Training data must be openly licensed | **Only if A misses the bar** |
| C. Keep FUTO's `ml4_q6_k.gguf` | Today's | Today's | Today's | FUTO's licence. No published licence lets it leave FUTO's app (#108) | **No**: FUTO code would still ship |
| D. Rime-based English (rime-ice's English words) | None (no context) | Prefix completion only, no proximity correction | small | GPL-3.0 data | **No** |
| E. A general open model (SmolLM2-135M, Apache-2.0) | Good | – | 3× FUTO's model, too slow per key | Apache-2.0 | **No** |

**Measurable bar.** A host harness lives in the repo (`android/test/english/`). It builds the English engine
for the PC and drives it through a stub, as #46 did, with no emulator. It runs the same sets against today's
stack (FUTO's decoder with its transformer) and the new one:

| Metric | Set | Bar (recommended) |
|---|---|---|
| Autocorrect, typo fixed at rank 1 / in the top 3 | #46's 1,000 phone typos (Palin et al. error mix) and 1,500 Wikipedia misspellings | ≥ today − 2 points |
| Correct words wrongly changed | #46's 1,000 clean words | ≤ today (1–2 %) |
| Next word in the 3 suggestions, empty prefix | held-out chat and news sentences (oasst1 prompts, Apache-2.0, plus a news set) | ≥ 90 % of today's rate |
| Keystroke savings with 3 suggestions (simulated taps on a suggestion once it appears) | same sentences | ≥ today − 3 points |
| Per-key time p95, engine alone | same | ≤ 10 ms |

The harness reports the numbers in a table checked into `docs/perf/`. The new English replaces today's only when
every row passes. If next-word or keystroke savings miss and the rest pass, option B starts.

## 3. Architecture

```
dev.sebb.sebtype (Kotlin, MIT)                         libsebtype.so (C++, NDK)
┌──────────────────────────────────┐   JNI, one call   ┌────────────────────────────────────────┐
│ SebTypeIme : InputMethodService  │   per key, one    │ core/  Core: languages, switching,      │
│  Editor (InputConnection)        │ ─ state record ─▶ │        candidates, settings (sebtype.conf)│
│  KeyboardView (Canvas, one View) │                   │  ├ rime.cpp ─ librime (engines/librime) │
│  CandidateBar, ActionBar, chip   │ ◀──────────────── │  ├ mozc.cpp ─ in-process transport ──┐   │
│  Emoji / Clipboard / More panels │                   │  └ english.cpp ─ engines/latinime    │   │
│  Settings (Compose activity)     │                   │     (AOSP decoder, Apache-2.0)       │   │
│  sync/, crash/, chinese/ (reused)│                   └──────────────────────────────────────┼───┘
└──────────────────────────────────┘                      libmozc.so (Bazel, engines/mozc) ◀──┘
```

- **One library, one JNI call per key.** `libsebtype.so` links `core/`, librime and the AOSP decoder. A key
  returns one compact record: text to commit, the preedit, the first N candidates and flags. A key never crosses
  JNI more than once. Mozc stays a Bazel-built `libmozc.so` exposing `EvalCommand(bytes)`, which `core/` calls
  in-process.
- **Mozc in-process.** `core/src/mozc.cpp` today talks to `mozc_server` over IPC. Split it into the protocol
  code, which is shared, and a transport: IPC on the PCs, a direct call into Mozc's `SessionHandler` on Android.
  The protobuf commands are identical, so the key translation, あ/ア and the candidate handling become one
  code path on all three platforms.
- **Rime on Android.** `core/src/rime.cpp` gets a "prebuilt data" mode. It never deploys and uses the compiled
  data that `chinese/RimeIceSetup.kt` unpacks (Decisions #2, #45: no deploy on the phone).
- **English in `core/`.** A new `Engine` for `Lang::English` on Android only. The PCs keep plain English
  (Decisions #2).
- **What `core/` gains for touch:**
  - `cycleLanguage()` for 🌐, which goes through every language in order (#1). Win+Space stays the PC toggle.
  - A candidate list that is not paged (the phone scrolls up to 128). This reuses `Engine::candidateAt`.
  - Keys sent as characters: a tap of "a" is keysym `a`.
  - The phone's field kinds: password and private disable learning.

  `core/test/core_test.cpp` covers each of these.
- **Threads.** Typing runs on the main thread, as today: each engine takes about 2 ms per key. Next-word
  suggestions are computed on one worker thread and posted back, so a key never waits for them.
- **Settings shared with the PCs.** `core::Settings` grows from `[Languages] Order=` to everything both
  sides set:
  - which languages are on and their order (the PCs' order is Win+Space's home; the phone's is the 🌐 cycle);
  - 简/繁;
  - 中文 full-width punctuation;
  - emoji in 中文 candidates;
  - learning on or off.

  The phone keeps them in `sebtype.conf` in its files dir and its settings screens read and write them through
  JNI. The PC Configurator goes through the same keys instead of editing Rime's `*.custom.yaml` itself.
  Phone-only options stay in Kotlin DataStore: the number row, height and modes, clipboard, sync login.
- **UI toolkit.** The keyboard window uses plain Views, not Compose: cold open and PSS matter there (cold open is
  456 ms p50 today). The settings activity keeps Compose for the pixel-frame look (#87), so Compose loads only
  when settings open.
- **Package.** The new code goes under `android/app/src/main/java/dev/sebb/sebtype/`, the only package left
  after stage 6. Gradle modules: `:app` and `:native` (CMake for `core/`, librime, latinime; the Bazel task for
  Mozc). `:rime` and `:mozc` go.

## 4. Licence

FUTO's licence (LICENSE.md) applies to any copy that contains FUTO's code. It requires the payment functionality
to stay and FUTO's notices to be kept. Once a release contains no FUTO code, neither applies to that release.
Rules for the rewrite (#108):

- Write each part from a behaviour description: the requirements, the decisions and the emulator checks. Don't
  read or translate FUTO's file while writing its replacement. Ideas and behaviour are free; copied expression
  is not.
- Reuse AOSP code only from AOSP's own repo (`~/src/sebtype-upstream/aosp-latinime`, `127336e`), never from
  FUTO's tree. FUTO's edits to AOSP files are FUTO's.
- SebType's 2,847 lines inside FUTO's files count as FUTO-derived, so they are rewritten too. Their behaviour is
  SebType's spec.

**What has to be gone for a FUTO-free release:**

- `android/app/src/main/java/org/futo/**`
- `android/app/src/main/cpp` (FUTO's native code and its vendored copies)
- `android/mozc/src` (FUTO's mozc-lib)
- FUTO's Gradle files and `android/tools/` scripts
- `.github/ISSUE_TEMPLATE/`
- `ml4_q6_k.gguf`, `main_en.dict`, `emoji_i18n.jsondlgz`, FUTO's translations
- FUTO's layouts. They are Apache-2.0 and could stay, but the new format replaces them.

That happens at **stage 6**. In the same release:

- the payment screen, thank-you screen and unpaid notice go;
- `LICENSE.md` and FUTO's NOTICE section leave the shipped app and the repo's current tree (git history keeps
  them);
- the README drops FUTO Keyboard from its components;
- `android/LICENSE` and NOTICE list Apache-2.0 for `engines/latinime/`, BSD-3 for Mozc and librime, LGPL-2.1 for
  `core/src/rime.cpp`, and GPL-3.0 for the Chinese data.

**Until then everything stays as today:** the payment screen with #112's note, the unpaid notice, LICENSE.md and
the one-sentence modification notice (Decisions #2, 2026-11-15). The new app is built beside FUTO's (stages 3–5),
but it ships only at stage 6, so no release mixes the two.

## 5. Size and performance targets

Today's numbers are from the phone run (Nothing A001, 2026-11-12). The budgets are provisional (Decisions #2,
2026-11-11), so these are targets to measure against, not gates.

| Metric | Today | Target with option A | With option B |
|---|---|---|---|
| APK | 108.8 MB (103.8 MiB) | ≤ 85 MB (model −30.7, emoji font −1.1, native −0.6, dex −1.3; English dictionary with n-grams +5–10) | ≤ 110 MB |
| `classes.dex` | 2.8 MB | ≤ 1.5 MB | same |
| Native code | 4.6 MB | ≤ 4.0 MB | ≤ 4.5 MB |
| PSS idle, fresh / after use | 74 / 109 MB | ≤ 60 / 80 MB | same |
| PSS after typing EN | 204 MB | ≤ 110 MB | ≤ 170 MB |
| PSS after 中 / 日 alone | 133 / 146 MB | ≤ 120 / 135 MB | same |
| PSS with all three | 267 MB | ≤ 200 MB | ≤ 250 MB |
| Key handling p95, EN / 中 / 日 | 7 / 6 / 4 ms | ≤ 5 ms each | same |
| Key → text p95, EN / 日 | 22 / 41 ms | ≤ 20 / 35 ms | same |
| Key → candidates p95, EN / 中 / 日 | 78 / 65 / 52 ms | ≤ 30 / 50 / 45 ms | EN ≤ 70 ms |
| Warm / cold open p50 | 68 / 456 ms | ≤ 60 / 300 ms | same |
| Late frames at 10 keys/s, empty field | 1 in 701 | ≤ 1 in 700 | same |
| Gradle release build, clean (#58) | sentencepiece and ggml compile every clean build | −218k lines of C++ to compile | same |

Not in this plan: Mozc's 45 MB dictionary is the biggest file left after the model goes. A smaller Mozc data
set (for example without the zip-code dictionary) would be its own issue. Decisions #2 (2026-11-10) says nothing
is compressed for size, and that rule stays.

## 6. Stages

Each stage is one or more PRs and keeps the released app shippable. Tests are `android/test/emulator.sh` checks
(`SEBTYPE_CHECKS=` for the stage's own), `core_test`, and the English harness. A delegate-day is one delegate's
day of tested work, about 1,000–1,500 lines (#108's measure).

| # | Stage | What ships to the user | Tests | Effort |
|---|---|---|---|---|
| 0 | **English harness and baseline.** Host build of today's decoder plus transformer and of the pristine AOSP decoder; the sets from #46 plus next-word sentences; a baseline table in `docs/perf/` | nothing | the harness itself; numbers reproducible across two runs | 2–3 days |
| 1 | **`core/` on Android (#190 step 3).** `:native` module, Mozc in-process transport, Rime prebuilt mode, `cycleLanguage`, the unpaged list, settings in `sebtype.conf`. FUTO's `ChineseIME` and `JapaneseIME` call `core/` through JNI; `android/mozc/src` and `android/rime` go | the same app; 中 and 日 now run through `core/` | `core_test` (new touch paths); `emulator.sh` `chinese-run` (ranh, lh-in-bar, learn-*, zh-hant-*, ja-*), `settings-zh-*`, `incognito-zh`, `incognito-ja`; Linux and Windows `core_test` still pass | 5–7 days |
| 2 | **English engine.** `engines/latinime/` (pristine AOSP), `core/src/english.cpp`, the dictionary build (AOSP en_US + wordfreq + SCOWL + n-grams), learned words, blocked words, email domains | nothing (the app still uses FUTO's English) | the harness against §2's bar; `core_test` for the English engine | 5–7 days |
| 2b | *Only if stage 2 misses next-word or keystroke savings:* train a SebType model on openly licensed text, run it on llama.cpp (MIT) as a re-ranker inside `english.cpp` | nothing | the harness again; per-key time | 6–10 days + GPU time |
| 3 | **New keyboard, typing core.** `SebTypeIme`, `Editor`, `KeyboardView` with the 3 layouts, symbols and number row, 🌐 cycle and long-press picker, candidate bar with chip and 简/繁 menu, field kinds and incognito, Picnic look, accessibility labels. Built as a test-only `dev.sebb.sebtype.next` package beside the release | nothing (test package only) | `chinese.py` and `settings.py` gain a `SEBTYPE_PACKAGE` switch; run `chinese-run`, `incognito-*`, the four #39 period checks, `uniform-layouts`; screenshots next to today's for the user | 8–12 days |
| 4 | **New keyboard, the rest.** Action bar and editor, All Actions, emoji picker (CLDR names), clipboard and quick clips, inline autofill, keyboard modes and height, spacebar and backspace swipes, haptics and key sounds | nothing (test package) | new checks: `emoji-picks`, `clipboard-paste`, `quick-clip`, `modes-*`, `swipe-*`; screenshots for the user | 6–9 days |
| 5 | **Settings and data.** Compose settings in 6 groups with pixel frames, setup wizard, export and import, PC words, sync and crash reports wired to the new app, credits; **migration** of an installed FUTO-based SebType's data on update (DataStore keys, learned English words, Rime userdb and Mozc profile kept in place) | nothing (test package) | `settings-run` in full, `sync-*`, `settings-backup-*`, a new `update-from-futo-app` check (learned words in all 3 languages survive) | 5–7 days |
| 6 | **Switch.** The new app becomes `dev.sebb.sebtype`; FUTO's code, model, payment screens and notices are deleted; licence files and README updated; perf run on the phone (#54 style) | **the new app** | full `emulator.sh`, `typing.sh`, `android/perf/perf.sh`, the harness; `trimmed` gains a check that no `org.futo` class or FUTO file is in the APK | 2–3 days |

Total about 33–48 delegate-days, or 39–58 with stage 2b. Stages 2 and 3 can run in parallel after stage 1.
Stage 1 can merge and release on its own, since it is #190 step 3.

## 7. Risks

| Risk | Effect | How the plan handles it |
|---|---|---|
| English next-word quality drops without the transformer | Requirements #1's "good suggestions" get worse | Stage 0 measures first, the bar in §2 gates the switch, and stage 2b is ready |
| Text-field quirks FUTO fixed (Chrome, WebView, Termux, apps that reset composing text) come back | Lost or doubled characters in some apps | `Editor` is guided by pristine AOSP's `RichInputConnection`; stage 3 adds checks typing into Chrome and a WebView on the emulator |
| Mozc's in-process session behaves differently from FUTO's client (focus, timeouts, prediction) | 日本語 regressions | Stage 1 lands it inside today's app, so the existing `ja-*` checks catch it before any UI change |
| Data loss on the update at stage 6 | Learned words gone | Stage 5's `update-from-futo-app` check; Rime and Mozc keep their files where they are |
| Clean-room discipline slips: a delegate translates a FUTO file | The release is still FUTO-derived | Briefs forbid opening FUTO's file for the part being written; the reviewer checks new files against FUTO's with a similarity scan before stage 6 |
| Weeks of work while the release is held (#191, 2026-11-15) | Nothing reaches the phone for weeks | Each stage keeps the app shippable, and stage 1 can release on its own (question 3 below) |
| Accessibility and long-tail behaviours nobody listed (key repeat, cursor-control edge cases, landscape) | Small regressions | Stage 3–4 checklist from today's app; the user tries the test package before stage 6 |
| Training option B needs a GPU and clean data | Extra time and a data-licence check | Only started if stage 2 misses the bar, after its own question |

## Decisions the plan needs

1. **English prediction.** Recommended: option A first (AOSP decoder + own n-gram dictionary), training an own
   model (B) only if the bar is missed. Alternatives: commit to B now, or accept A's quality whatever it measures.
2. **The quality bar** in §2. Recommended: autocorrect within 2 points of today, no more wrong changes, next-word
   at least 90 % of today's. Alternative: match or beat today on every row (makes B much more likely).
3. **The release hold.** Recommended: release after stage 1 and keep releasing the FUTO-based app until stage 6.
   Alternative: hold every release until stage 6.
4. **Leaving 中文 with typed pinyin on the phone.** Recommended: commit what is typed, as the PCs do (one rule in
   `core/`). Alternative: keep the phone's drop.
