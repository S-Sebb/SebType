# Bringing in your own words

SebType takes in four kinds of personal data. On the phone, each one comes in the same way:
**Settings › Sync & backup › Import settings**. Pick the file, then pick the language the import
screen offers. SebType tells the kinds apart by what is in the file, not by its name. Each import adds
to what is there already. The only exception is a Chinese word list, which replaces the previous list.

A settings backup (`.backup`) still goes in through the same button. It replaces all settings and
data, as before.

## Chinese word list (Rime `.dict.yaml`)

A list of your own words with their pinyin, in Rime's dictionary format. The phone and both PCs use
the same file: `sebtype_words.dict.yaml` in Rime's user folder. SebType's Chinese data has a small
dictionary, `sebtype`, that rime-ice reads alongside its own and that imports this file. Rime compiles
only your list, never the whole dictionary.

The file is any Rime word list: a header with a `name` and a `version` (the name inside doesn't
matter), `...`, then one word per line: the word, a tab, its pinyin with spaces between syllables, and
optionally a tab and a weight.

```
---
name: my_words
version: "1"
...
雾凇	wu song	100000000
```

A word without a weight comes after the dictionary's own words for the same pinyin. A large weight,
like the one above, puts it first.

- **Phone:** import the file. It is saved as `sebtype_words.dict.yaml`, replacing the last list, and
  Chinese gets ready again in the background, which takes a few seconds. To empty the list, import a
  list with no words.
- **Linux:** copy the file to `~/.local/share/fcitx5/rime/sebtype_words.dict.yaml`, then tell Rime to
  deploy:
  `busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/rime/deploy s ''`
- **Windows:** copy the file to `%APPDATA%\Rime\sebtype_words.dict.yaml`, then run
  `WeaselDeployer.exe /deploy` from Weasel's folder (`WeaselRoot` in
  `HKLM\SOFTWARE\WOW6432Node\Rime\Weasel`).
- To remove the list on a PC, delete the file and `build/sebtype.table.bin` next to it, then deploy.

A word list that rime-ice used to read through its own `rime_ice.dict.yaml` (an `import_tables`
entry such as `fcitx_import`) carries over as it is: copy that file under the new name.

## Chinese learned words (Rime `rime_ice.userdb.txt`)

What Rime learned on another device, in the text form Rime's sync writes. The phone merges it into
its own learned words with Rime's own sync merge, the same merge Rime runs between synced devices.
Nothing the phone learned is lost.

1. On the PC, have Rime write its sync files. This also merges in anything already in its sync
   folder, as a sync always does.
   - Linux: `busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/rime/sync s ''`
   - Windows: `WeaselDeployer.exe /sync` from Weasel's folder.
2. Take `sync/<installation id>/rime_ice.userdb.txt` from Rime's user folder (the id is in
   `installation.yaml` there) and import it on the phone.

Only rime_ice's learned words are accepted, the ones SebType's Chinese uses. The phone needs **Privacy ›
Learn from my typing** on to have learned words to merge into.

## Japanese dictionary

The Japanese personal dictionary takes another IME's dictionary export. It also comes in through
the **Import** button on 日本語's **My words** page (Languages). Each imported file stays a dictionary of its own on that
page, where it can be removed. These formats work:

| Format | How it starts |
|---|---|
| Mozc (its dictionary tool's Export, e.g. fcitx5-mozc's) | `よみ<TAB>単語<TAB>品詞[<TAB>コメント]` lines, UTF-8 |
| Microsoft IME (text export) | `!Microsoft IME Dictionary Tool`; UTF-16, Shift_JIS or UTF-8 |
| ATOK | `!!ATOK_TANGO_TEXT_HEADER` |
| Gboard (`dictionary.txt` from the exported zip) | `# Gboard Dictionary version:1` |

Mozc's learning history (what it learned from typing) can't be carried over.

## English personal dictionary

FUTO Keyboard's personal dictionary format: `userdictionary.json`, the file inside a SebType or FUTO
Keyboard settings backup (a `.backup` file is a zip). Import that file on its own: its words are added
to the personal dictionary, and the words already there stay. Each word keeps its language, so
Japanese words in it go to the Japanese dictionary too. The PCs keep no English words to export.
