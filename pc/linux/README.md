# SebType on Linux (KDE Plasma, Wayland)

On Linux, SebType typing is Fcitx5 with Rime (Chinese, rime-ice), Mozc (Japanese, the same engine as
on the phone) and plain English. `setup-ime.sh` sets it up so that it works in every app on a KDE
Plasma Wayland session, XWayland apps included, with nothing set by hand. It targets Fedora-family
systems (Nobara, Fedora).

```sh
pc/linux/setup-ime.sh --dry-run   # print what would change, change nothing
pc/linux/setup-ime.sh             # apply; safe to rerun
```

It changes only this account's config. It uses sudo only to install missing packages, and only after
asking. Files it replaces are backed up to `~/.local/share/sebtype/backup/<time>/` first.

## What it does, and why

| Step | Change | Fixes |
|---|---|---|
| Packages | `fcitx5`, its GTK 2/3/4 and Qt 5/6 modules, `fcitx5-rime`, `librime-octagram`, `fcitx5-mozc`, `kcm-fcitx5`; `librime-octagram` from SebType's librime build once librime is SebType's | The engines, and the modules XWayland and older apps load. `librime-octagram` reads the Chinese data's grammar file, so Chinese candidates come in the phone's and Windows' order: `beirendingwei` gives 被认定为, not 被人定位 (#127) |
| SebType's fcitx5-mozc | Replaces Fedora's `fcitx5-mozc` with SebType's build of the same version (`mozc/`), after asking, with sudo | Japanese's English mode shows **A** while Caps Lock is on, like Chinese's, and its tray menu has one switch, あ → ア (#117) |
| SebType's fcitx5-rime | Replaces Fedora's `fcitx5-rime` with SebType's build of the same version (`rime/`), after asking, with sudo | Chinese's tray menu has one switch, 简 → 繁, with no schema list, Deploy or Synchronize (#117) |
| SebType's librime | Replaces Fedora's `librime` and its installed plugins (`librime-lua`, …) with SebType's build of the same version (`rime/`), after asking, with sudo | Chinese typo correction also fixes a slip onto the key above or below, which librime's own neighbour map lacks: `xkaoshi` gives 小时 (#101) |
| KWin input method | `kwinrc` `[Wayland] InputMethod` = Fcitx 5 (System Settings → Keyboard → Virtual Keyboard) | Every native Wayland app (GTK, Qt, Electron) through text-input, with no environment variables. Takes effect at the next login if Fcitx5 isn't already running under KWin |
| XWayland | `XMODIFIERS=@im=fcitx` in `~/.config/environment.d/90-sebtype-im.conf`, only if the session doesn't already have it | XIM apps on XWayland: Steam, WINE/Proton, Java, Xlib/SDL games |
| Global IM modules | Warns about any global `*_IM_MODULE` (`/etc/environment`, `environment.d`, Plasma env scripts, shell profiles) and doesn't edit it | A global `GTK_IM_MODULE`/`QT_IM_MODULE` overrides Wayland text-input and makes candidate windows flicker |
| Dead Flatpak overrides | Removes `~/.local/share/flatpak/overrides/com.qq.QQ` and `com.tencent.WeChat` when those Flatpaks aren't installed | Leftovers of older QQ/WeChat input fixes |
| WeChat | `env QT_IM_MODULE=fcitx` in the user's WeChat launcher | WeChat bundles its own Qt on X11 and only finds Fcitx when named |
| Chromium/Electron | `--enable-wayland-ime` in the user's launcher, only for apps the checklist below shows need it. None do today | Apps on native Wayland that don't turn on text-input by themselves |
| Input methods | Adds `keyboard-us`, `rime`, `mozc` (EN → 中 → 日) to the first Fcitx5 group, keeping any others | Chinese and Japanese ready to switch to |
| Language switch | In `~/.config/fcitx5/config`: `ShareInputState=All`, so every window shares one language, as on Windows. Super+Space is the trigger key with `EnumerateWithTriggerKeys=False`, and Shift_L (`AltTriggerKeys`), Ctrl+Shift+Shift_L (enumerate) and the group-switch keys are cleared. Fcitx5 reloads its config | Super+Space is the only language switch and toggles English ⇄ the last other language (中文 or 日本語), also while Super stays held; the other one is picked from the tray menu, and then it is the one Super+Space returns to (#93). Rime's own Shift tap still switches English inside Chinese |
| Japanese あ ⇄ English | `~/.config/mozc/config1.db` gets a custom keymap, `mozc-keymap.tsv`: Mozc's MS-IME keymap plus a Shift tap (あ ⇄ direct English) and Alt+\` (あ ⇄ ア, before typing). Other Mozc settings are kept. A running `mozc_server` is stopped; fcitx5-mozc starts it again on the next key. The Shift tap from English back to あ works once Fcitx5 restarts (fcitx5-mozc reads the keys that work in direct mode only then): log in again, or turn System Settings → Keyboard → Virtual Keyboard off and back on, which makes KWin restart Fcitx5 | A Shift tap switches Japanese like Rime's Shift tap in Chinese, the only switch to English letters, and Alt+\` switches hiragana and katakana as on Windows (#117). Shift+letter, F6–F10 and Space work as in Mozc's default keymap |
| Alt+\` in Plasma | Removes Alt+\` from KWin's "Walk Through Windows of Current Application", which keeps Meta+` | Plasma would otherwise take Alt+\` before Mozc sees it |
| Tray icons | Installs `~/.local/share/icons/SebType`, an icon theme that holds only SebType's tray icons (`pc/icons`) and inherits the theme that was active, then makes it the active icon theme. Plasma reloads icons at once | The tray shows SebType's keycaps instead of the icon theme's keyboard, Rime logo and Mozc squares |
| Chinese name | `~/.local/share/fcitx5/inputmethod/rime.conf`, this account's copy of Rime's input method entry, named and labelled 中文, and `schema/name: ".中文"` in `~/.local/share/fcitx5/rime/rime_ice.custom.yaml`, keeping the file's other patches. Shows once Fcitx5 restarts (log in again, or turn Virtual Keyboard off and back on), when Rime also redeploys | The Super+Space popup and the tray text read 中文 for Chinese instead of 雾. fcitx5-rime shows the schema name's first character (雾 of 雾凇拼音) unless the name starts with `.`; then Fcitx5 shows the entry's label. The schema id stays `rime_ice`, so learned words stay. Rime's own switcher (Ctrl+\` or F4) lists `.中文` and the one switch, 简 → 繁 |
| Japanese and English names | `mozc.conf` named 日本語 and `keyboard-us.conf` named English in the same `inputmethod` folder. Show once Fcitx5 restarts | The tray menu and the Super+Space popup read English · 中文 · 日本語 instead of Keyboard - English (US) · Rime · Mozc (#92). An entry there also renames the keyboard addon's built-in `keyboard-us`; its layout still comes from the id |
| Typo correction | `sebtype_typo/keyboard: pc` in the same `rime_ice.custom.yaml` | Chinese typo correction (#46) weighs a PC keyboard's neighbour keys instead of the phone's touch grid |
| Chinese data | Builds SebType's Chinese data with `tools/rime-data/build.sh` (cached in `~/.cache/sebtype`; the first build needs gcc, g++ and OpenCC and takes about a minute) and unzips it into `~/.local/share/fcitx5/rime` over the files of the same name, then removes the dictionary sources (`*.dict.yaml`) it has prebuilt tables for. Learned words, `*.custom.yaml` and an existing `custom_phrase.txt` stay. Every file it replaces or removes is kept first in `~/.local/share/sebtype/rime-before`, and `sebtype-data.txt` in Rime's folder names the data installed. Rime then deploys it (Rime deploy, below) | Chinese on Linux types with the same data as the phone and Windows: rime-ice's schemas and Lua with 白霜's dictionary, and SebType's typo correction (#46, #102), so `xoaoshi` gives 小时 first. Full pinyin is its only scheme, and 简 → 繁 its only menu switch: punctuation, emoji, half-width and the other switches stay at their defaults (#117) |
| 简/繁 key | Ctrl+Shift+F toggles rime-ice's `traditionalization` option at any time, added to `key_binder/bindings` in `~/.local/share/fcitx5/rime/default.custom.yaml`, keeping the file's other patches | Chinese switches between simplified and traditional output, as with Weasel on Windows. Only the output changes, so learned words stay shared; Ctrl+F alone stays Find in apps |
| Candidates per page | `menu/page_size: 6` in the same `default.custom.yaml`, only when it has no page size yet | 6 Chinese candidates per page instead of rime-ice's 5 (Decisions #2, #163). A page size of the user's own, which the Configurator writes there too, stays |
| Rime deploy | When any of the Chinese steps changed something and Fcitx5 runs, asks it over D-Bus to redeploy Rime, which it does in the background | The changes apply without Rime's Deploy menu entry, which SebType's fcitx5-rime doesn't have |
| SebType Configurator | Builds `pc/configurator` with Rust's `cargo` when its sources changed, and installs it in `~/.local/share/sebtype/configurator` with the app-menu entry **SebType Configurator** (`sebtype-configurator.desktop`) and the phone's pig as its icon. Without Rust it only warns | SebType's settings without editing YAML: see [SebType Configurator](#sebtype-configurator) |

`mozc-keymap.tsv` is Mozc's `src/data/keymap/ms-ime.tsv` (BSD-3-Clause, Google) with Alt+\` (あ ⇄ ア) and Shift
lines added at the end. Windows passes Alt+\` on as the Kanji key with Alt held, so the same switch is also
there as `Alt Hankaku/Zenkaku`.

The Shift tap needs no addon or Mozc patch. fcitx5-mozc already turns a Shift press and release with no
other key in between into a bare `Shift` key for Mozc, and drops it when any key came between (Shift+K,
Ctrl+Shift+…). The keymap binds that bare `Shift` to IMEOff (commit what is being typed, then direct
English) in every typing state, and to IMEOn in direct English. It costs one keymap lookup, which Mozc
does for every key anyway. The keymap lives in this account's Mozc config, so Fedora updates of
fcitx5-mozc keep it. If Mozc's settings are ever reset, rerun `setup-ime.sh`. To undo: copy `config` and `config1.db` back from the backup folder, then run
`fcitx5-remote -r` and stop `mozc_server`. To bring back Alt+\` for the KWin action, use System Settings → Shortcuts.

### Tray icons

| State | Icon | Fcitx5 asks for |
|---|---|---|
| English (US layout) | EN | `input-keyboard` |
| Chinese | 中 | `fcitx-rime` |
| Chinese, English mode | a | `fcitx_rime_latin` |
| Chinese, English mode with Caps Lock | A | `fcitx_rime_latin_upper` |
| Japanese hiragana, and Japanese in the tray menu | あ | `fcitx_mozc_hiragana`, `fcitx_mozc` |
| Japanese katakana (full and half width) | ア | `fcitx_mozc_katakana_full`, `fcitx_mozc_katakana_half` |
| Japanese, English mode (direct, half and full ASCII) | a | `fcitx_mozc_direct`, `fcitx_mozc_alpha_half`, `fcitx_mozc_alpha_full` |
| Japanese, English mode with Caps Lock | A | the same names with `_upper` (SebType's fcitx5-mozc) |

`input-keyboard` and `fcitx-rime` come from the active icon theme, so only a theme of SebType's own
replaces them, and other apps that show `input-keyboard` get the EN key too. Every other icon still
comes from the theme SebType's inherits. If you pick another icon theme in System Settings, rerun
`setup-ime.sh` to put SebType's on top of it.

To undo: `pc/linux/setup-ime.sh --undo-icons`. It makes the inherited theme active again and removes
`~/.local/share/icons/SebType`.

### Names

To undo the names English · 中文 · 日本語: `pc/linux/setup-ime.sh --undo-names`. It removes the three
input method entries from `~/.local/share/fcitx5/inputmethod` and the `.中文` schema name from
`rime_ice.custom.yaml`, so Fcitx5 shows Keyboard - English (US), Rime (雾 in the popup) and Mozc again once
it restarts.

### Chinese data

To undo: `pc/linux/setup-ime.sh --undo-chinese-data`. It removes the files SebType's Chinese data placed
in `~/.local/share/fcitx5/rime` and puts back the ones it replaced or removed, so Rime's folder is as it
was; learned words stay. Rime uses the old data once it redeploys.

### SebType Configurator

SebType's settings app (`pc/configurator`, Rust with Slint), the PC counterpart of the phone's settings
with the same groups and wording: Languages (which languages are on and their order in the tray menu; Super+Space toggles the first one and the
last other one; Chinese's
简/繁 start, punctuation, emoji, fuzzy pinyin and own words; Japanese's half-width space and own words),
Keyboard (candidates per page, row or column, text size; the shortcuts), Theme (the candidate window in
SebType's Picnic look, with its pig at the start, rising above the window on a tab, or the system's), Privacy (learning, and forgetting what Rime or Mozc learned), Sync & backup
(sync with your own server, [sync-server/README.md](../../sync-server/README.md); export and import of the
settings and own words) and About. It shows them in English, 中文
or 日本語, following the system language (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`; Windows' display
language), English for any other (#118): the English is in `ui/*.slint` inside `@tr`, and
`lang/{zh,ja}/LC_MESSAGES/sebtype-configurator.po` are built into the program. It writes the same files the
engines read (`rime_ice.custom.yaml`, `default.custom.yaml`, `custom_phrase.txt`, Mozc's `config1.db` and
`user_dictionary.db`, Fcitx5's `classicui.conf` and group) and tells a running Fcitx5 over D-Bus, so a
change shows at the next key; Chinese changes redeploy Rime.

To undo: `pc/linux/setup-ime.sh --undo-configurator`. It removes the app and its entry, and puts back the
candidate window look that Picnic replaced. Settings made with it stay.

`pc/configurator/test.sh` checks it without touching the session: unit tests, that every string the
window shows has its 中文 and 日本語, every screen opened in each of the three languages in a nested
virtual KWin (screenshots in `/tmp/sebtype/configurator-shots`), a private Fcitx5 and Rime on
a copy of this account's rime-ice taking the languages and Chinese settings the app writes, and
`test-setup-ime.sh`. The Windows build is the `sebtype-configurator` artifact of the Configurator
workflow.

### The tray menu

Every language's tray menu has the same pattern (#117): English · 中文 · 日本語, then at most one switch
for the active language with its key, and nothing else from the engines.

| Language | Switch | Key |
|---|---|---|
| English | none | |
| 中文 | 简 → 繁 (繁 → 简 while traditional) | Ctrl+Shift+F |
| 日本語 | あ → ア (ア → あ while katakana) | Alt+\` |

Fcitx5's own Restart, Input Method Settings and Exit stay at the end: they are Fcitx5's, not an
engine's. Rime's switcher (Ctrl+\` or F4) has the same one switch.

### SebType's fcitx5-mozc

Fedora's fcitx5-mozc picks the tray icon from the input mode alone, so Japanese's English mode can't show
**A** for Caps Lock. SebType's fcitx5-mozc, built from `pc/mozc` (Mozc 3.35.6354, the same
tree as Windows, with fcitx/mozc's Fcitx 5 frontend in `src/unix/fcitx5`), asks for `<icon>_upper` in the English modes while Caps Lock is on, and redraws the
tray when Caps Lock changes, the way fcitx5-rime does (`src/unix/fcitx5/mozc_engine.cc`). It also
replaces Mozc's tray menu (its five input modes and its
tools) with the one switch, あ → ア, and makes Mozc's kana switch (Alt+\`) a two-way toggle of hiragana
and full-width katakana instead of a cycle through half-width katakana. Nothing else changes: the same
Mozc, dictionary and learned words.

`mozc/build.sh` packages it in place of Fedora's: `mozc/fcitx5-mozc.spec` follows Fedora's spec and
builds with Bazel (Bazelisk, pinned by checksum in `mozc/versions.sh` with the Fedora container image),
which fetches the libraries `pc/mozc/src/MODULE.bazel` pins. The tools (`mozc_tool`) use Qt 6, as
Mozc's Bazel build does. It runs under the shared build lock with 4 compile jobs in a container capped
at 6 GB. Bazel's caches stay in `~/.cache/sebtype/mozc/work`, so a rebuild compiles only what changed.
`setup-ime.sh` runs it when the RPM isn't built yet, replaces Fedora's fcitx5-mozc
(`2.30.5618.102^20250124gitc0ed34e-6.fc44`) with it through `sudo dnf install` and asks first. Its
version, 3.35.6354, is above Fedora's, so `dnf upgrade` keeps it; `--undo-mozc` brings Fedora's back.

Fcitx5 loads the new fcitx5-mozc when it restarts: turn System Settings → Keyboard → Virtual Keyboard
off and back on, or log in again.

To undo: `pc/linux/setup-ime.sh --undo-mozc` (`sudo dnf distro-sync fcitx5-mozc`, back to Fedora's
package), then restart Fcitx5 the same way.

### SebType's fcitx5-rime

Fedora's fcitx5-rime puts Rime's schema list, Latin Mode, Deploy and Synchronize into the tray menu, and
every switch the schema has. SebType's fcitx5-rime, `pc/fcitx5-rime` (5.1.15), leaves out the schema list, Deploy and Synchronize, and
adds each switch's key to its menu entry (read from Rime's `default.yaml` key bindings, so the entry
reads `简 → 繁 Ctrl+Shift+F`). Which switches show comes from the data: SebType's Chinese data keeps
`states` only on `traditionalization`, and fcitx5-rime, Weasel and Rime's switcher hide a switch
without them.

`rime/build.sh` builds it the same way as fcitx5-mozc, with `rime/fcitx5-rime.spec` (Fedora's spec)
and the image pinned in `rime/versions.sh`, in about a minute. Its release `1.sebtype1.fc44` sorts above Fedora's `1.fc44`.
To undo: `pc/linux/setup-ime.sh --undo-rime`.

### SebType's librime

SebType's typo correction (#46) asks a second translator, `corr`, with librime's correction on, and
`lua/sebtype_typo.lua` ranks what it finds by a keyboard model. librime only proposes slips onto the key
left or right, so on a PC a slip onto the key above or below (`xkaoshi` for xiaoshi) was never found.
SebType's librime, `pc/librime` (1.16.1), gives librime's correction a PC layout model when the schema says
`sebtype_typo/keyboard: pc` (setup sets it; the phone keeps librime's own map): the neighbours within
1.25 key widths on the staggered rows, each slip priced −log P(typed | meant) as the Lua filter prices
it, one slip per syllable. It also stops a sentence of several words, such as 你|好 for the corrected
`nihap`, from hiding the phrase that reads the same (你好), which librime's duplicate filter did (#135).
Measured on this PC (#101, SebType's data, per-key CPU time, median of 5):

| | typo-pc top-1 / top-3 | typo-phone top-1 / top-3 | clean sets | typo key p95 |
|---|---|---|---|---|
| Lua filter on Fedora's librime | 7.0 / 9.8 % | 14.6 / 17.6 % | 51.2 / 62.0 % | 6.3–6.8 ms |
| Lua filter on SebType's librime | 16.2 / 22.2 % | 16.2 / 19.6 % | 51.2 / 62.0 % | 7.6 ms |

The Lua filter stays: the model alone in the main translator (no filter) loses 2–3 points of clean
sentences. `rime/build.sh librime` builds it with `rime/librime.spec` (Fedora's spec) and Fedora's
copies of its plugins, which must match it. Its release `2.sebtype2.fc44` sorts above Fedora's `2.fc44`. To undo:
`pc/linux/setup-ime.sh --undo-librime`.

It never restarts Fcitx5 or KWin: KWin's input-method connection can't be reused after Fcitx5
restarts. At the end it checks that Fcitx5 runs under KWin and that the session has `XMODIFIERS`, and
says to log in again if not.

`test-setup-ime.sh` checks the script (ShellCheck, a read-only dry run on this PC, and a full,
rerun run on a fake fresh account including the install and undo of the icon theme, SebType's fcitx5-mozc, fcitx5-rime and librime and the Configurator,
the Japanese keys and tray icons in a private Fcitx5 with its own D-Bus session, the Chinese popup
text, the 简/繁 key and typo correction (`xoaoshi` → 小时, and `xkaoshi` → 小时 and `nihap` → 你好 with SebType's librime), the grammar plugin (`beirendingwei` → 被认定为) and 6 candidates per page (a page size of the user's own kept) in a private Fcitx5 running Rime on SebType's
Chinese data, the install and undo of that data over an account's own rime-ice, and Super+Space, Rime's Shift tap and the tray menu's names,
icons, switches and picks in a private Fcitx5 with a stand-in for Plasma's tray). The private Fcitx5s run SebType's builds without installing them: `bwrap`
mounts their files over Fedora's for that Fcitx5 alone. It doesn't touch the session. Check names as arguments run only those checks, after `fresh-apply` (`./test-setup-ime.sh page-size-kept`).

## App checklist

In each app: type `ranh` → 然后 (Rime), switch to Mozc and type `nihongo` → 日本語, type plain
English, and check that the candidate window sits next to the text cursor. `fcitx5-diagnose` lists
each app's input context and the frontend it uses.

| Path | App | Expected frontend |
|---|---|---|
| Qt6 native Wayland | Konsole, Dolphin rename, KRunner | wayland |
| GTK3 Flatpak | Betterbird compose | wayland |
| GTK4 / libadwaita Flatpak | Bazaar search box | wayland |
| Qt Flatpak | Haruna or KolourPaint text tool; OnlyOffice document | wayland, or xim/ibus on X11 |
| Electron native Wayland | Discord message box, T3 Code composer | wayland |
| Chromium | Google Chrome address bar and a textarea | wayland |
| Electron on XWayland | QQ, Exiled Exchange 2 | ibus / xim |
| Proprietary Qt (XCB) | WeChat | fcitx4 |
| XWayland Xlib/CEF | Steam client search and chat | xim |
| WINE | `wine notepad`, chat in a Proton game | xim |
| Java | a Swing text field | xim |
| Password field | any login box | IME stays off |

### Results on the reference PC (Nobara 44, Plasma 6.7.5, Fcitx5 5.1.23)

Tested on 2026-11-09 after running `setup-ime.sh`, with no app flags or global IM variables.
Typed through `ydotool` while the desk was unattended. Each test used a field the test opened and
had checked was empty, and everything typed was cleared afterwards. In every row but the password one, Rime showed its
candidate window next to the text, committed 然后, plain English went in as typed, and Mozc converted
`nihongo` to 日本語.

| App | Field | Frontend | Result |
|---|---|---|---|
| KRunner | search | wayland | PASS |
| Dolphin | rename | wayland | PASS |
| Konsole | terminal (running `cat`, not a shell) | wayland | PASS |
| Betterbird (GTK3 Flatpak) | compose To | wayland | PASS |
| Bazaar (GTK4 Flatpak) | search | wayland | PASS |
| Haruna (Qt Flatpak) | Open URL | wayland | PASS |
| OnlyOffice (Flatpak, X11) | new document | ibus | PASS |
| Discord (Electron, Chromium 152, Wayland) | Ctrl+K switcher | wayland | PASS, no flag needed |
| Google Chrome 157 (Wayland) | textarea, address bar | wayland | PASS, no flag needed |
| QQ (Electron on XWayland) | search | ibus | PASS |
| WeChat (bundled Qt, X11) | search | fcitx4 | PASS (launcher keeps `QT_IM_MODULE=fcitx`) |
| Wine Notepad (fresh prefix) | text | xim | PASS. The candidate window sits at the window's top-left. The fresh prefix has no CJK font, so committed Chinese shows as boxes |
| Java Swing | text field | xim | PASS |
| Chrome password field | password | (IME off) | PASS: Fcitx5 stayed on English, no candidates |

Not typed: Steam (its window needs mouse clicks; its 11 `steamwebhelper` input contexts run on
xim, like Wine and Java above), T3 Code (Escape in its composer can stop a running thread; its
input context runs on wayland), Exiled Exchange 2 and Proton game chat (need a running game), and
WeChat without its launcher variable (would mean restarting WeChat). Discord had no input context
in the earlier study only because its window was hidden in the tray.
