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
| Packages | `fcitx5`, its GTK 2/3/4 and Qt 5/6 modules, `fcitx5-rime`, `fcitx5-mozc`, `kcm-fcitx5` | The engines, and the modules XWayland and older apps load |
| KWin input method | `kwinrc` `[Wayland] InputMethod` = Fcitx 5 (System Settings → Keyboard → Virtual Keyboard) | Every native Wayland app (GTK, Qt, Electron) through text-input, with no environment variables. Takes effect at the next login if Fcitx5 isn't already running under KWin |
| XWayland | `XMODIFIERS=@im=fcitx` in `~/.config/environment.d/90-sebtype-im.conf`, only if the session doesn't already have it | XIM apps on XWayland: Steam, WINE/Proton, Java, Xlib/SDL games |
| Global IM modules | Warns about any global `*_IM_MODULE` (`/etc/environment`, `environment.d`, Plasma env scripts, shell profiles) and doesn't edit it | A global `GTK_IM_MODULE`/`QT_IM_MODULE` overrides Wayland text-input and makes candidate windows flicker |
| Dead Flatpak overrides | Removes `~/.local/share/flatpak/overrides/com.qq.QQ` and `com.tencent.WeChat` when those Flatpaks aren't installed | Leftovers of older QQ/WeChat input fixes |
| WeChat | `env QT_IM_MODULE=fcitx` in the user's WeChat launcher | WeChat bundles its own Qt on X11 and only finds Fcitx when named |
| Chromium/Electron | `--enable-wayland-ime` in the user's launcher, only for apps the checklist below shows need it. None do today | Apps on native Wayland that don't turn on text-input by themselves |
| Input methods | Adds `keyboard-us`, `rime`, `mozc` (EN → 中 → 日) to the first Fcitx5 group, keeping any others | Chinese and Japanese ready to switch to |
| Language switch | In `~/.config/fcitx5/config`: Super+Space is the "enumerate forward" key, and the trigger, Shift_L (`AltTriggerKeys`), Ctrl+Shift+Shift_L and group-switch keys are cleared. Fcitx5 reloads its config | Super+Space is the only language switch and cycles EN → 中 → 日 (a trigger key would only toggle English and the last language). Rime's own Shift tap still switches English inside Chinese |
| Japanese あ ⇄ English | `~/.config/mozc/config1.db` gets a custom keymap, `mozc-keymap.tsv`: Mozc's MS-IME keymap plus Alt+` (あ ⇄ direct English). Other Mozc settings are kept. A running `mozc_server` is stopped; fcitx5-mozc starts it again on the next key | Alt+` switches Japanese like on Windows. Shift+letter, F6–F10 and Space work as in Mozc's default keymap |
| Alt+` in Plasma | Removes Alt+` from KWin's "Walk Through Windows of Current Application", which keeps Meta+` | Plasma would otherwise take Alt+` before Mozc sees it |

`mozc-keymap.tsv` is Mozc's `src/data/keymap/ms-ime.tsv` (BSD-3-Clause, Google) with four Alt+` lines
added at the end. To undo: copy `config` and `config1.db` back from the backup folder, then run
`fcitx5-remote -r` and stop `mozc_server`. To bring back Alt+` for the KWin action, use System Settings → Shortcuts.

It never restarts Fcitx5 or KWin: KWin's input-method connection can't be reused after Fcitx5
restarts. At the end it checks that Fcitx5 runs under KWin and that the session has `XMODIFIERS`, and
says to log in again if not.

`test-setup-ime.sh` checks the script (ShellCheck, a read-only dry run on this PC, and a full,
rerun run on a fake fresh account). It doesn't touch the session.

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
