# SebType on Linux (KDE Plasma, Wayland)

On Linux, SebType typing is Fcitx5 with SebType's input method (`linux/`, #190): one Fcitx5 add-on over
SebType's core (`core/`), which hosts Rime (Chinese, rime-ice), Mozc (Japanese, the same engine as on the
phone) and plain English, and switches between them itself. `setup-ime.sh` sets it up so that it works in every app on a KDE
Plasma Wayland session, XWayland apps included, with nothing set by hand. It targets Fedora-family
systems (Nobara, Fedora).

Download `SebType-setup-<version>-linux-x86_64.sh` from the
[latest release](https://github.com/S-Sebb/SebType/releases/latest) and run:

```sh
sh SebType-setup-<version>-linux-x86_64.sh
```

From a checkout of this repository, you can also build and set it up directly:

```sh
pc/linux/setup-ime.sh --dry-run   # print what would change, change nothing
pc/linux/setup-ime.sh             # apply; safe to rerun
```

It changes only this account's config. It uses sudo only to install missing packages, and only after
asking. Files it replaces are backed up to `~/.local/share/sebtype/backup/<time>/` first.

A release carries one self-extracting installer (`SebType-setup-<version>-linux-x86_64.sh`), built by CI
(`.github/workflows/linux-rpm.yml`, #421, #427, #435) with `linux/build-installer.sh`: it packs the `sebtype`
RPM (with SebType's librime inside) and `sebtype-configurator` with their SHA-256 manifest. In a graphical session
(unless `--no-gui` is passed) it launches the Picnic-themed GUI setup wizard (`sebtype-configurator --setup`),
falling back to terminal mode when headless or if the GUI cannot start. Besides the input method and Mozc,
`sebtype` holds what the per-account steps copy from: the Configurator, the Chinese data, the Mozc keymap and
setup itself, as `sebtype-setup` (in `/usr/libexec/sebtype`). Run that way, setup builds nothing and installs
no packages; it does this account's steps with the release's files. Running the installer elevates once
(`sudo` or `pkexec`) to run `--install-rpms-only` (which verifies the embedded RPM and installs `sebtype`, and
puts Fedora's librime packages back where SebType 0.2.0 or older had replaced them with its build, #527), then
runs `sebtype-setup` as your user.

Nothing is left to do by hand in the usual case: setup restarts Fcitx5 under KWin itself whenever the running
one has to load something new (SebType's input method, its tray, the input method names, a package), so
typing works at once, with no login (#442, #445). The wizard's last page then checks the real state, again
every two seconds while it shows, and is "SebType is ready!" only when every check passes. Each check that
fails is a step with a button that does it:

| Check | Fails when | Button |
|---|---|---|
| SebType's input method is on in every app | Fcitx5's current input method isn't `sebtype`, or an Fcitx5 KWin didn't start runs (Wayland apps reach only KWin's) | Turn on: stops an Fcitx5 KWin didn't start and runs `sebtype-setup` again |
| A global IM module (shown only when one is found) | A `*_IM_MODULE` line in the files setup warns about (below) | Turn off: comments the line out (`# Turned off by SebType Setup (#445): …`) in a file of the person's own; Open file for a system file, in the person's editor |
| A new login (shown only when needed) | Plasma's session (`plasmashell`'s environment, which the apps it starts get) lacks `XMODIFIERS=@im=fcitx` or has a global IM module: XWayland apps such as Steam and WINE don't get SebType until a login | Log out: Plasma's own Log out dialog |

A step done stays on the page, ticked.

`linux/test-rpms.sh <installer>` installs a release's installer that way in a fresh Fedora and checks it.

## Removing SebType

Undo setup's changes first, while SebType is still installed, then remove it:

```sh
sebtype-setup --undo-all
sudo dnf remove sebtype
```

`--undo-all` runs every undo below (`sudo dnf install` of Fcitx5's settings apps asks for your password). Then,
with Fcitx5 stopped, it takes SebType's input method out of the groups in `~/.config/fcitx5/profile` and puts
back what setup or the Configurator's Use SebType took out of each (English, Rime, Mozc, and its default input
method) from the newest copy of `profile` in `~/.local/share/sebtype/backup/` that has the group without SebType
in it: the group as it was just before SebType came into it. Groups and input methods added since setup stay
(#611). The `Default` group setup made when there was no `profile` goes if nothing else is in it; any other
group left empty keeps its place with the keyboard of its layout. It puts back `config` and the add-ons' keys in
`conf/`, and Mozc's `config1.db`, each from its oldest copy (#582), and Fcitx5's own tray; a file with no copy
stays. A group no copy has from before SebType (setups up to 0.2.0 kept no copy of `profile`, or the group was
renamed since) gets nothing back: `--undo-all` names it, and if it had Rime, you add Rime back in Fcitx 5
Configuration after the removal. The backups move
to `backup-until-<time>`, so a later install's are its own. If you removed and installed SebType again before
0.3.0, the oldest copies may be from before the earlier install, not from just before this one.

Already ran `dnf remove`? Install SebType again, then run the two commands: installing it again only adds newer
copies, so the oldest are still the ones from before SebType.

These stay: KWin's virtual keyboard (Fcitx 5), XMODIFIERS, the WeChat launcher fix, Alt+\` taken from Plasma's
"Walk Through Windows of Current Application" (System Settings → Shortcuts → KWin), and Rime's Ctrl+Shift+F and 6
candidates per page in `~/.local/share/fcitx5/rime/default.custom.yaml` and `sebtype_typo/keyboard: pc` in
`rime_ice.custom.yaml`, which only SebType reads.

## What it does, and why

| Step | Change | Fixes |
|---|---|---|
| Packages | `fcitx5`, its GTK 2/3/4 and Qt 5/6 modules | The modules XWayland and older apps load |
| Fcitx5's own settings | Removes `kcm-fcitx5` (Fcitx5's page in System Settings) and `fcitx5-configtool` (the Fcitx 5 Configuration app), after asking, with sudo. `--undo-fcitx5` puts them back | SebType's settings are in the Configurator; Fcitx5's own were a second place to change Rime and Mozc behind SebType's back (Decisions #2, #182) |
| SebType's input method | Installs the `sebtype` RPM (`linux/build.sh`: the Fcitx5 add-on and Mozc), after asking, with sudo. Setup restarts a running Fcitx5 under KWin to load it (#442) | English, 中文 and 日本語 in one input method with SebType's own switching, popups, candidate pages and tray menu, in place of fcitx5-rime's and fcitx5-mozc's frontends (#190). See [SebType's input method](#sebtypes-input-method) |
| SebType 0.2.0's librime | Where SebType 0.2.0 or older replaced Fedora's `librime` packages with its build, puts Fedora's back with `dnf distro-sync`, after asking, with sudo (run from the RPM it warns instead; the installer has done it). `--undo-librime` does the same | The add-on has SebType's librime inside now (#527): the old build only kept Fedora's from other apps |
| KWin input method | `kwinrc` `[Wayland] InputMethod` = Fcitx 5 (System Settings → Keyboard → Virtual Keyboard) | Every native Wayland app (GTK, Qt, Electron) through text-input, with no environment variables. When an Fcitx5 is already running, setup restarts it under KWin by turning the setting off and back on |
| XWayland | `XMODIFIERS=@im=fcitx` in `~/.config/environment.d/90-sebtype-im.conf`, only if the session doesn't already have it | XIM apps on XWayland: Steam, WINE/Proton, Java, Xlib/SDL games |
| Global IM modules | Warns about any global `*_IM_MODULE` (`/etc/environment`, `environment.d`, Plasma env scripts, shell profiles) and doesn't edit it | A global `GTK_IM_MODULE`/`QT_IM_MODULE` overrides Wayland text-input and makes candidate windows flicker |
| Dead Flatpak overrides | Removes `~/.local/share/flatpak/overrides/com.qq.QQ` and `com.tencent.WeChat` when those Flatpaks aren't installed | Leftovers of older QQ/WeChat input fixes |
| WeChat | `env QT_IM_MODULE=fcitx` in the user's WeChat launcher | WeChat bundles its own Qt on X11 and only finds Fcitx when named |
| Chromium/Electron | `--enable-wayland-ime` in the user's launcher, only for apps the checklist below shows need it. None do today | Apps on native Wayland that don't turn on text-input by themselves |
| Input methods | Makes `sebtype` the first Fcitx5 group's input method in place of `keyboard-us`, `rime` and `mozc`, keeping any others, once the running Fcitx5 knows it | English, Chinese and Japanese in one input method; their order (EN → 中 → 日) is SebType's setting, which the Configurator writes to `~/.config/sebtype/sebtype.conf` |
| fcitx5-rime | Nothing on disk: SebType's input method keeps fcitx5-rime's add-on off in the Fcitx5 that loads it, for that run only, as Fcitx5's `--disable=rime` does, also when fcitx5-rime is installed while Fcitx5 runs (at Fcitx5's Refresh). The Input methods step above already took Rime (`rime`) out of the first group; setup warns when another group still has it, since it won't type Chinese there, with the command that removes such a group, and the Configurator says the same on the setup wizard's Ready page and on About, once the running Fcitx5 knows SebType's input method, with a Use SebType button that lays out those groups as this step does the first (a group that starts on another input method, such as pinyin, keeps it first, and SebType's takes Rime's place), after a copy of the profile in `~/.local/share/sebtype/backup`. Once `sebtype` is removed, fcitx5-rime loads again: [Removing SebType](#removing-sebtype) says how to get Rime back in the groups | SebType's input method has its own librime (#527): beside fcitx5-rime's, two librimes would share `~/.local/share/fcitx5/rime`, deploy into one `build/` and write one `rime_ice.userdb`, which LevelDB allows only one of them to do (#542). SebType's 中文 is Rime on that folder, with its settings and My words, and rime-ice's learned words |
| Language switch | In `~/.config/fcitx5/config`: `ShareInputState=All`, so every window shares one language, as on Windows. Fcitx5's trigger key (Super+Space after an older setup), Shift_L (`AltTriggerKeys`), Ctrl+Shift+Shift_L (enumerate) and the group-switch keys are cleared. Fcitx5 reloads its config | Super+Space reaches SebType's input method, the only language switch: it toggles English ⇄ the last other language (中文 or 日本語), also while Super stays held; the other one is picked from the tray menu, and then it is the one Super+Space returns to (#93). A Shift tap switches English letters inside Chinese and Japanese |
| Japanese keymap | `~/.config/mozc/config1.db` gets a custom keymap, `mozc-keymap.tsv`: Mozc's MS-IME keymap plus a Shift tap (あ ⇄ direct English) and Alt+\` (あ ⇄ ア, before typing). Other Mozc settings are kept. A running `mozc_server` is stopped; SebType's input method starts it again on the next key | Mozc's MS-IME keys: Shift+letter, F6–F10 and Space work as in Mozc's default keymap. SebType's input method now takes the Shift tap and Alt+\` itself (#190), so the keymap's Shift and Alt+\` lines are no longer used |
| Fcitx5's add-on hotkeys | Empties the keys of Fcitx5's clipboard history (Ctrl+;), Unicode input (Ctrl+Alt+Shift+U, Ctrl+Shift+U) and quick phrase (Super+\`, Super+;) in `~/.config/fcitx5/conf/clipboard.conf`, `unicode.conf` and `quickphrase.conf`, keeping their other settings, and Fcitx5 reloads them. The add-ons stay loaded | These keys reach the app instead of opening Fcitx5 popups SebType doesn't offer (Decisions #2, #182) |
| Alt+\` in Plasma | Removes Alt+\` from KWin's "Walk Through Windows of Current Application", which keeps Meta+` | Plasma would otherwise take Alt+\` before Mozc sees it |
| Tray icons | Nothing of its own: SebType's input method package installs its tray icons (`pc/icons`), every size in `/usr/share/sebtype/tray` for the tray item's pixmaps (the tray takes the one for its size and display scaling, #441) and as `sebtype-<state>` in `/usr/share/icons/hicolor`, the theme every icon theme falls back to, for the menu, so the active icon theme stays as it is. After an older setup that installed `~/.local/share/icons/SebType` and made it the active icon theme, setup removes it and makes the theme it inherits active again (one picked since stays); Plasma reloads icons at once | The tray shows SebType's keycaps in every state, whatever icon theme is active, and other apps keep their theme's keyboard icon (#278) |
| SebType's tray | `~/.local/share/fcitx5/addon/notificationitem.conf`: this account's entry for Fcitx5's tray add-on, which loads SebType's tray from SebType's input method instead. Setup restarts a running Fcitx5 under KWin to load it (#445) | SebType's tray menu (below) in place of Fcitx5's, without Input Method Settings (Decisions #2, #182). Fcitx5's classic UI leaves out its own X11 tray icon while a tray item is up, as it does for Fcitx5's, so Fcitx5's menu never shows (#190) |
| Chinese name | `schema/name: ".中文"` in `~/.local/share/fcitx5/rime/rime_ice.custom.yaml`, keeping the file's other patches. Older setups also wrote `~/.local/share/fcitx5/inputmethod/rime.conf`, which named fcitx5-rime's entry 中文; setup removes it when it is still as written (kept in the backup), and restarts a running Fcitx5 under KWin (#445) | fcitx5-rime shows the schema name's first character (雾 of 雾凇拼音) unless the name starts with `.`; then Fcitx5 shows the entry's label. fcitx5-rime's entry reads Rime again, as setup's warning and Fcitx5's settings name it, since SebType's 中文 types Chinese (#542). The schema id stays `rime_ice`, so learned words stay. |
| Japanese and English names | `mozc.conf` named 日本語 and `keyboard-us.conf` named English in the same `inputmethod` folder. Setup restarts a running Fcitx5 under KWin to show them (#445) | The tray menu and the Super+Space popup read English · 中文 · 日本語 instead of Keyboard - English (US) · Rime · Mozc (#92). An entry there also renames the keyboard addon's built-in `keyboard-us`; its layout still comes from the id |
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

To undo the names English · 中文 · 日本語: `pc/linux/setup-ime.sh --undo-names`. It removes the renamed
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
Keyboard (candidates per page, row or column, text size, 中文's pinyin in a row over the candidates or in
the text, #447; the shortcuts), Theme (the candidate window in SebType's Picnic look, one flat rectangle with
its pig at the start as on Windows, #461, or the system's), Privacy (learning, and forgetting what Rime or Mozc learned), Sync & backup
(sync with your own server, [sync-server/README.md](../../sync-server/README.md); export and import of the
settings and own words) and About. It shows them in English, 中文
or 日本語, following the system language (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`; Windows' display
language), English for any other (#118): the English is in `ui/*.slint` inside `@tr`, and
`lang/{zh,ja}/LC_MESSAGES/sebtype-configurator.po` are built into the program. It writes the same files the
engines read (`rime_ice.custom.yaml`, `default.custom.yaml`, `custom_phrase.txt`, Mozc's `config1.db` and
`user_dictionary.db`, Fcitx5's `classicui.conf` and group) and tells a running Fcitx5 over D-Bus, so a
change shows at the next key; Chinese changes redeploy Rime.

**Updates (#422).** Setup schedules `sebtype-configurator --check-updates` once a day with a systemd user
timer (`sebtype-update.timer`, at the next login after a missed day). It asks GitHub for SebType's latest
release (`releases/latest`; tags `v<MAJOR.MINOR.PATCH>` only, so the `v0.1.30-sebtype.N` tags from before
0.1.0 are never newer) and compares it with the newer of the Configurator's version (`VERSION`) and the
installed `sebtype` package's. A newer release shows a notification once; clicking it opens the
Configurator's About page. There, Update… downloads `SebType-setup-<version>-linux-x86_64.sh` (#427) from
the release's download address into a new folder only this account can use (`$XDG_RUNTIME_DIR/sebtype-updates`),
checking GitHub's size and SHA-256 (the asset's `digest`; a release without one installs nothing). One admin
prompt (`pkexec`) then runs, as root, a script that copies the installer into a new folder only root can write,
checks its SHA-256 there again and runs `/bin/sh "$copy" --install-rpms-only`, so a file changed after the
check isn't run. Then `sebtype-setup </dev/null` does this account's part, without a prompt. The new input
method runs once Fcitx5 restarts: log out and in again, or turn Virtual Keyboard off and on; the Configurator
never restarts it, and its own window is the old one until it is reopened. About's "Check for updates
automatically" turns the daily check off, Check now checks at once.

To undo: `pc/linux/setup-ime.sh --undo-configurator`. It removes the app, its entry and its daily update
check, and puts back the candidate window look that Picnic replaced. Settings made with it stay.

`pc/configurator/test.sh` checks it without touching the session: unit tests, that every string the
window shows has its 中文 and 日本語, every screen opened in each of the three languages in a nested
virtual KWin (screenshots in `~/scratch/SebType/<issue>/configurator-shots`), a private Fcitx5 and Rime on
a copy of this account's rime-ice taking the languages and Chinese settings the app writes, the daily
update check against a release served on this PC with a fake notification server (`test-update.py`, run
with the test build `sebtype-configurator-update-test`, the only one that takes `SEBTYPE_UPDATE_URL`), and
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
sentences. The add-on has it inside (#527): `linux/CMakeLists.txt` builds `engines/librime` as a static
library with Fedora's copy of librime-lua and librime-octagram at the phone's pin (the grammar file's plugin, #127: `beirendingwei`
gives 被认定为, not 被人定位) merged in, and keeps its symbols in the add-on. Fedora's `librime` stays
installed and untouched for other apps (fcitx5-rime, ibus-rime), so system updates, which sync Fedora's
packages to the repositories' versions (Nobara's updater runs `dnf distro-sync`), Fedora's own librime
updates and removing `sebtype` all leave both working. What librime and core/ link (glog, yaml-cpp, Snappy, LevelDB,
marisa-trie, OpenCC, Lua and protobuf, `linux/versions.sh`'s `SEBTYPE_DEPS`) is static in the add-on too
(#540). LevelDB compresses with Snappy as Fedora's does, so the user dictionaries an older SebType wrote
with Fedora's LevelDB still read (`test-rpms.sh`'s `learned-words-kept`); as shared libraries they made `sebtype` need sonames a Fedora release drops (Fedora 45 has
`libopencc.so.1.2` and Lua 5.5), and the upgrade (`dnf --releasever=45 distro-sync`) stopped on them.
The package now needs only glibc's, GCC's, Fcitx5's, libpng's and fontconfig's, and `linux/test-rpms.sh`
checks that and upgrades its container to the next release with SebType installed. The phone builds the
same OpenCC and Lua; its LevelDB has no Snappy, which is fine there: devices share only the text snapshots
(`*.userdb.txt`), never the databases. Up to 0.2.0, SebType's librime RPMs replaced Fedora's
and a distro-sync swapped them back (#527). `linux/build-librime.sh` still builds those RPMs
(`linux/librime.spec`, Fedora's spec) for the benches and the dev tools' private Fcitx5s.

It never restarts Fcitx5 or KWin: KWin's input-method connection can't be reused after Fcitx5
restarts. At the end it checks that Fcitx5 runs under KWin and that the session has `XMODIFIERS`, and
says to log in again if not.

`test-setup-ime.sh` checks the script (ShellCheck, a read-only dry run on this PC, and a full,
rerun run on a fake fresh account including the install of SebType's input method, the removal of an older setup's icon theme, Fedora's librime back in place of 0.2.0's (`old-librime-replaced`) and the Configurator,
the Japanese keys and tray icons in a private Fcitx5 with its own D-Bus session, that a sensitive field, and learning off in the Configurator, learn no 中文 or 日本語 picks and keep what was learned (`private-field`), that a private Fcitx5 asked for fcitx5-rime beside SebType loads none, also when fcitx5-rime is installed while it runs, so SebType's 中文 still learns, and fcitx5-rime types once SebType is gone, and that setup's warning names Rime's other groups (`fcitx5-rime-beside-sebtype`), the Chinese popup
text, the 简/繁 key and typo correction (`xoaoshi` → 小时, and `xkaoshi` → 小时 and `nihap` → 你好 with SebType's librime), the grammar plugin (`beirendingwei` → 被认定为), 6 candidates per page (a page size of the user's own kept) and the wheel's paging of 中文 and 日本語 candidates (#443) in a private Fcitx5 running SebType's input method on SebType's
Chinese data, the install and undo of that data over an account's own rime-ice, and Super+Space, Rime's Shift tap and the tray menu's names,
icons, switches and picks in a private Fcitx5 with a stand-in for Plasma's tray). The private Fcitx5s run SebType's input method, with its own librime, without installing it:
Fcitx5 finds the add-on through `FCITX_ADDON_DIRS`. It doesn't touch the session. Check names as arguments run only those checks, after `fresh-apply` (`./test-setup-ime.sh page-size-kept`).

`test-removal.sh`, on yanglab16, removes SebType end to end in a kde-emu session of its own: an account with
Fcitx5 groups of its own, this tree's RPM installed and set up, a group and an input method added, then
`sebtype-setup --undo-all` and `dnf remove sebtype`; Fcitx5's groups and keys must be the account's own again, with
those added since, running and on disk.

## App checklist

In each app: type `ranh` → 然后 (Rime), switch to Mozc and type `nihongo` → 日本語, type plain
English, and check that the candidate window sits next to the text cursor and that the mouse wheel over it
pages the candidates (#443; the tests reach the same paging through D-Bus, not the compositor's pointer). `fcitx5-diagnose` lists
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
