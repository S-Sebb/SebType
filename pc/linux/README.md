# SebType on Linux (KDE Plasma, Wayland)

On Linux, SebType typing is Fcitx5 with SebType's input method (`linux/`, #190): one Fcitx5 add-on over
SebType's core (`core/`), which hosts Rime (Chinese, rime-ice), Mozc (Japanese, the same engine as on the
phone) and plain English, and switches between them itself. `setup-ime.sh` sets it up so that it works in every app on a KDE
Plasma Wayland session, XWayland apps included, with nothing set by hand. It targets Fedora-family
systems (Nobara, Fedora).

```sh
pc/linux/setup-ime.sh --dry-run   # print what would change, change nothing
pc/linux/setup-ime.sh             # apply; safe to rerun
```

It changes only this account's config. It uses sudo only to install missing packages, and only after
asking. Files it replaces are backed up to `~/.local/share/sebtype/backup/<time>/` first.

A release carries what the packages steps install, built by CI (`.github/workflows/linux-rpm.yml`, #421):
the `sebtype` RPM and SebType's librime RPMs. Besides the input method and Mozc, `sebtype` holds what the
per-account steps copy from: the Configurator, the Chinese data, the Mozc keymap and setup itself, as
`sebtype-setup` (in `/usr/libexec/sebtype`). Run that way, setup builds nothing and installs no packages;
it does this account's steps with the release's files. An update installs the release's RPMs, then runs
`sebtype-setup` as the user:

```sh
pkexec dnf install -y sebtype-<version>-<release>.x86_64.rpm librime{,-lua,-octagram}-<librime version>.x86_64.rpm \
  [librime-predict, -tools and -devel, each one the PC has]
sebtype-setup < /dev/null
```

`linux/test-rpms.sh <folder>` installs a release's RPMs that way in a fresh Fedora and checks them.

## What it does, and why

| Step | Change | Fixes |
|---|---|---|
| Packages | `fcitx5`, its GTK 2/3/4 and Qt 5/6 modules, `librime-lua`, `librime-octagram`; `librime-octagram` from SebType's librime build once librime is SebType's | Rime's plugins, and the modules XWayland and older apps load. `librime-octagram` reads the Chinese data's grammar file, so Chinese candidates come in the phone's and Windows' order: `beirendingwei` gives 被认定为, not 被人定位 (#127) |
| Fcitx5's own settings | Removes `kcm-fcitx5` (Fcitx5's page in System Settings) and `fcitx5-configtool` (the Fcitx 5 Configuration app), after asking, with sudo. `--undo-fcitx5` puts them back | SebType's settings are in the Configurator; Fcitx5's own were a second place to change Rime and Mozc behind SebType's back (Decisions #2, #182) |
| SebType's input method | Installs the `sebtype` RPM (`linux/build.sh`: the Fcitx5 add-on and Mozc), after asking, with sudo. Fcitx5 loads it once it restarts; then rerun setup | English, 中文 and 日本語 in one input method with SebType's own switching, popups, candidate pages and tray menu, in place of fcitx5-rime's and fcitx5-mozc's frontends (#190). See [SebType's input method](#sebtypes-input-method) |
| SebType's librime | Replaces Fedora's `librime` and its installed plugins (`librime-lua`, …) with SebType's build of the same version (`linux/build-librime.sh`), after asking, with sudo | Chinese typo correction also fixes a slip onto the key above or below, which librime's own neighbour map lacks: `xkaoshi` gives 小时 (#101) |
| KWin input method | `kwinrc` `[Wayland] InputMethod` = Fcitx 5 (System Settings → Keyboard → Virtual Keyboard) | Every native Wayland app (GTK, Qt, Electron) through text-input, with no environment variables. Takes effect at the next login if Fcitx5 isn't already running under KWin |
| XWayland | `XMODIFIERS=@im=fcitx` in `~/.config/environment.d/90-sebtype-im.conf`, only if the session doesn't already have it | XIM apps on XWayland: Steam, WINE/Proton, Java, Xlib/SDL games |
| Global IM modules | Warns about any global `*_IM_MODULE` (`/etc/environment`, `environment.d`, Plasma env scripts, shell profiles) and doesn't edit it | A global `GTK_IM_MODULE`/`QT_IM_MODULE` overrides Wayland text-input and makes candidate windows flicker |
| Dead Flatpak overrides | Removes `~/.local/share/flatpak/overrides/com.qq.QQ` and `com.tencent.WeChat` when those Flatpaks aren't installed | Leftovers of older QQ/WeChat input fixes |
| WeChat | `env QT_IM_MODULE=fcitx` in the user's WeChat launcher | WeChat bundles its own Qt on X11 and only finds Fcitx when named |
| Chromium/Electron | `--enable-wayland-ime` in the user's launcher, only for apps the checklist below shows need it. None do today | Apps on native Wayland that don't turn on text-input by themselves |
| Input methods | Makes `sebtype` the first Fcitx5 group's input method in place of `keyboard-us`, `rime` and `mozc`, keeping any others, once the running Fcitx5 knows it | English, Chinese and Japanese in one input method; their order (EN → 中 → 日) is SebType's setting, which the Configurator writes to `~/.config/sebtype/sebtype.conf` |
| Language switch | In `~/.config/fcitx5/config`: `ShareInputState=All`, so every window shares one language, as on Windows. Fcitx5's trigger key (Super+Space after an older setup), Shift_L (`AltTriggerKeys`), Ctrl+Shift+Shift_L (enumerate) and the group-switch keys are cleared. Fcitx5 reloads its config | Super+Space reaches SebType's input method, the only language switch: it toggles English ⇄ the last other language (中文 or 日本語), also while Super stays held; the other one is picked from the tray menu, and then it is the one Super+Space returns to (#93). A Shift tap switches English letters inside Chinese and Japanese |
| Japanese keymap | `~/.config/mozc/config1.db` gets a custom keymap, `mozc-keymap.tsv`: Mozc's MS-IME keymap plus a Shift tap (あ ⇄ direct English) and Alt+\` (あ ⇄ ア, before typing). Other Mozc settings are kept. A running `mozc_server` is stopped; SebType's input method starts it again on the next key | Mozc's MS-IME keys: Shift+letter, F6–F10 and Space work as in Mozc's default keymap. SebType's input method now takes the Shift tap and Alt+\` itself (#190), so the keymap's Shift and Alt+\` lines are no longer used |
| Fcitx5's add-on hotkeys | Empties the keys of Fcitx5's clipboard history (Ctrl+;), Unicode input (Ctrl+Alt+Shift+U, Ctrl+Shift+U) and quick phrase (Super+\`, Super+;) in `~/.config/fcitx5/conf/clipboard.conf`, `unicode.conf` and `quickphrase.conf`, keeping their other settings, and Fcitx5 reloads them. The add-ons stay loaded | These keys reach the app instead of opening Fcitx5 popups SebType doesn't offer (Decisions #2, #182) |
| Alt+\` in Plasma | Removes Alt+\` from KWin's "Walk Through Windows of Current Application", which keeps Meta+` | Plasma would otherwise take Alt+\` before Mozc sees it |
| Tray icons | Nothing of its own: SebType's input method package installs its tray icons (`pc/icons`) as `sebtype-<state>` in `/usr/share/icons/hicolor`, the theme every icon theme falls back to, so the active icon theme stays as it is. After an older setup that installed `~/.local/share/icons/SebType` and made it the active icon theme, setup removes it and makes the theme it inherits active again (one picked since stays); Plasma reloads icons at once | The tray shows SebType's keycaps in every state, whatever icon theme is active, and other apps keep their theme's keyboard icon (#278) |
| SebType's tray | `~/.local/share/fcitx5/addon/notificationitem.conf`: this account's entry for Fcitx5's tray add-on, which loads SebType's tray from SebType's input method instead. Shows once Fcitx5 restarts | SebType's tray menu (below) in place of Fcitx5's, without Input Method Settings (Decisions #2, #182). Fcitx5's classic UI leaves out its own X11 tray icon while a tray item is up, as it does for Fcitx5's, so Fcitx5's menu never shows (#190) |
| Chinese name | `~/.local/share/fcitx5/inputmethod/rime.conf`, this account's copy of Rime's input method entry, named and labelled 中文, and `schema/name: ".中文"` in `~/.local/share/fcitx5/rime/rime_ice.custom.yaml`, keeping the file's other patches. Shows once Fcitx5 restarts (log in again, or turn Virtual Keyboard off and back on), when Rime also redeploys | The Super+Space popup and the tray text read 中文 for Chinese instead of 雾. fcitx5-rime shows the schema name's first character (雾 of 雾凇拼音) unless the name starts with `.`; then Fcitx5 shows the entry's label. The schema id stays `rime_ice`, so learned words stay. |
| Japanese and English names | `mozc.conf` named 日本語 and `keyboard-us.conf` named English in the same `inputmethod` folder. Show once Fcitx5 restarts | The tray menu and the Super+Space popup read English · 中文 · 日本語 instead of Keyboard - English (US) · Rime · Mozc (#92). An entry there also renames the keyboard addon's built-in `keyboard-us`; its layout still comes from the id |
| Typo correction | `sebtype_typo/keyboard: pc` in the same `rime_ice.custom.yaml` | Chinese typo correction (#46) weighs a PC keyboard's neighbour keys instead of the phone's touch grid |
| Chinese data | Builds SebType's Chinese data with `data/rime/build.sh` (cached in `~/scratch/SebType/cache`; the first build needs gcc, g++ and OpenCC and takes about a minute) and unzips it into `~/.local/share/fcitx5/rime` over the files of the same name, then removes the dictionary sources (`*.dict.yaml`) it has prebuilt tables for. Learned words, `*.custom.yaml` and an existing `custom_phrase.txt` stay. Every file it replaces or removes is kept first in `~/.local/share/sebtype/rime-before`, and `sebtype-data.txt` in Rime's folder names the data installed. Rime then deploys it (Rime deploy, below) | Chinese on Linux types with the same data as the phone and Windows: rime-ice's schemas and Lua with 白霜's dictionary, and SebType's typo correction (#46, #102), so `xoaoshi` gives 小时 first. Full pinyin is its only scheme, and 简 → 繁 its only menu switch: punctuation, emoji, half-width and the other switches stay at their defaults (#117) |
| 简/繁 key | Ctrl+Shift+F toggles rime-ice's `traditionalization` option at any time, added to `key_binder/bindings` in `~/.local/share/fcitx5/rime/default.custom.yaml`, keeping the file's other patches | Chinese switches between simplified and traditional output, as with Weasel on Windows. Only the output changes, so learned words stay shared; Ctrl+F alone stays Find in apps |
| Candidates per page | `menu/page_size: 6` in the same `default.custom.yaml`, only when it has no page size yet | 6 Chinese candidates per page instead of rime-ice's 5 (Decisions #2, #163). A page size of the user's own, which the Configurator writes there too, stays |
| Rime deploy | When any of the Chinese steps changed something and Fcitx5 runs, asks it over D-Bus to redeploy Rime, which it does in the background | The changes apply without a Deploy menu entry, which SebType's tray menu doesn't have |
| SebType Configurator | Builds `pc/configurator` with Rust's `cargo` when its sources changed, and installs it in `~/.local/share/sebtype/configurator` with the app-menu entry **SebType Configurator** (`sebtype-configurator.desktop`) and the phone's pig as its icon. Without Rust it only warns | SebType's settings without editing YAML: see [SebType Configurator](#sebtype-configurator) |

`mozc-keymap.tsv` is Mozc's `src/data/keymap/ms-ime.tsv` (BSD-3-Clause, Google) with Alt+\` (あ ⇄ ア) and Shift
lines added at the end. Windows passes Alt+\` on as the Kanji key with Alt held, so the same switch is also
there as `Alt Hankaku/Zenkaku`.

The keymap binds a bare `Shift` (a Shift press and release with no other key in between, as fcitx5-mozc
sent it) to IMEOff (commit what is being typed, then direct English) in every typing state, and to IMEOn
in direct English. SebType's input method (#190) now takes the Shift tap and Alt+\` itself, so those lines
are no longer used on Linux; Windows' Mozc still reads them. The keymap lives in this account's Mozc config. If Mozc's settings are ever reset, rerun `setup-ime.sh`. To undo: copy `config` and `config1.db` back from the backup folder, then run
`fcitx5-remote -r`. To bring back Alt+\` for the KWin action, use System Settings → Shortcuts.

### Tray icons

| State | Icon | SebType's input method asks for |
|---|---|---|
| English (US layout) | EN | `sebtype-en` |
| Chinese | 中 | `sebtype-zh` |
| Chinese, English mode | a | `sebtype-zh-a` |
| Chinese, English mode with Caps Lock | A | `sebtype-zh-caps` |
| Japanese hiragana, and Japanese in the tray menu | あ | `sebtype-hira` |
| Japanese katakana | ア | `sebtype-kata` |
| Japanese, English mode | a | `sebtype-ja-a` |
| Japanese, English mode with Caps Lock | A | `sebtype-ja-caps` |

SebType's names are its own, so any icon theme leaves them to hicolor, and the tray shows SebType's
keycaps whatever theme is active; the other names stay the active theme's. hicolor has no 20 px size,
so Linux uses the 16, 22, 24 and 32 px drawings and the scalable one; the 20 px drawings are for Windows.

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
virtual KWin (screenshots in `~/scratch/SebType/<issue>/configurator-shots`), a private Fcitx5 and Rime on
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

Fcitx5's own Restart and Exit stay at the end: they are Fcitx5's, not an engine's. SebType's tray
leaves out Input Method Settings, and no key opens Rime's switcher: F4 and Ctrl+\` reach the app (#182).

### SebType's input method

`linux/` is one Fcitx5 add-on, `sebtype`, over SebType's core (`core/`, the same on every platform,
#190): the core hosts librime for 中文 and Mozc for 日本語, both in Fcitx5's process (#233), passes English through, and owns the
switching (Win+Space, the Shift tap, Ctrl+Shift+F, Alt+\`), the popups, the candidate pages and the tray
menu. The add-on draws what the core says with Fcitx5's own candidate window (classicui, so the Picnic
theme and the Configurator's settings apply to both languages) and shows its popups as Fcitx5 did. Its
tray, `linux/src/tray.cpp`, is Fcitx5's notificationitem trimmed to SebType's menu, loaded under that
add-on's name (step "SebType's tray"), so Fedora's Fcitx5 needs no change. Rime keeps fcitx5-rime's user
folder (`~/.local/share/fcitx5/rime`) and names, and Mozc its profile, so learned words stay.

`linux/build.sh` builds the `sebtype` RPM in a pinned Fedora container (`linux/versions.sh`), with Mozc
(`/usr/lib64/sebtype/libsebtype-mozc.so`, which the add-on links) built by Bazel with the libraries
`engines/mozc/src/MODULE.bazel` pins. Bazel downloads nothing itself: as for the phone's Mozc builds, Bazel
and those libraries come from `tools/mozc-downloads.tsv`, fetched capped and checked first
([development.md](../../docs/development.md#android)) (#361). Bazel's caches stay in `~/scratch/SebType/cache/mozc/work`,
so a rebuild compiles only what changed. It runs the core's unit tests too. The RPM's name in
`~/scratch/SebType/cache/sebtype` has a hash of the sources it packs (`sebtype_key`), so setup and the tests
use the one built from their own checkout's code and build it when it's missing (#326).

Before #190, setup installed SebType's own builds of fcitx5-mozc (#66), fcitx5-rime (#117) and Fcitx5
(#182), from sources in this repo. The input method replaced them, and their sources and packaging are
gone. A PC that still has one of them (a release with `.sebtype` in `rpm -qa 'fcitx5*'`) gets Fedora's
packages back with `sudo dnf distro-sync` on those packages.

### SebType's librime

SebType's typo correction (#46) asks a second translator, `corr`, with librime's correction on, and
`lua/sebtype_typo.lua` ranks what it finds by a keyboard model. librime only proposes slips onto the key
left or right, so on a PC a slip onto the key above or below (`xkaoshi` for xiaoshi) was never found.
SebType's librime, `engines/librime` (1.16.1), gives librime's correction a PC layout model when the schema says
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
sentences. `linux/build-librime.sh` builds it with `linux/librime.spec` (Fedora's spec) and Fedora's
copies of its plugins, which must match it. Its release `2.sebtype4.fc44` sorts above Fedora's `2.fc44`. To undo:
`pc/linux/setup-ime.sh --undo-librime`.

It never restarts Fcitx5 or KWin: KWin's input-method connection can't be reused after Fcitx5
restarts. At the end it checks that Fcitx5 runs under KWin and that the session has `XMODIFIERS`, and
says to log in again if not.

`test-setup-ime.sh` checks the script (ShellCheck, a read-only dry run on this PC, and a full,
rerun run on a fake fresh account including the install of SebType's input method, the removal of an older setup's icon theme, SebType's librime and the Configurator,
the Japanese keys and tray icons in a private Fcitx5 with its own D-Bus session, that a sensitive field, and learning off in the Configurator, learn no 中文 or 日本語 picks and keep what was learned (`private-field`), the Chinese popup
text, the 简/繁 key and typo correction (`xoaoshi` → 小时, and `xkaoshi` → 小时 and `nihap` → 你好 with SebType's librime), the grammar plugin (`beirendingwei` → 被认定为) and 6 candidates per page (a page size of the user's own kept) in a private Fcitx5 running SebType's input method on SebType's
Chinese data, the install and undo of that data over an account's own rime-ice, and Super+Space, Rime's Shift tap and the tray menu's names,
icons, switches and picks in a private Fcitx5 with a stand-in for Plasma's tray). The private Fcitx5s run SebType's input method and librime without installing them:
Fcitx5 finds the add-on through `FCITX_ADDON_DIRS`, and `bwrap` mounts librime over Fedora's for that Fcitx5 alone. It doesn't touch the session. Check names as arguments run only those checks, after `fresh-apply` (`./test-setup-ime.sh page-size-kept`).

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
| Private window | Chrome incognito | nothing new learned |

A field the app marks sensitive or a password field learns nothing (#270): Fcitx5 passes Qt's
`ImhSensitiveData` and text-input-v3's sensitive hint on as its `Sensitive` flag, which Chrome sets in
its incognito windows. Firefox (and Zen) set no hint in private windows on Linux, so they learn there.

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
