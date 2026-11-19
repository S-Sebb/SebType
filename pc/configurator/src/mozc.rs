//! Japanese (Mozc's profile folder): config1.db's space field (and an older Configurator's learning off), SebType's own dictionary
//! in user_dictionary.db (My words, with the words the sync brings), and forgetting the input history. Field numbers are Mozc's
//! protocol/config.proto and protocol/user_dictionary_storage.proto.

use crate::proto;
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

const CONFIG: &str = "config1.db";
const DICTIONARIES: &str = "user_dictionary.db";
const SPACE_CHARACTER_FORM: u32 = 47; // FUNDAMENTAL_HALF_WIDTH = 2
const HISTORY_LEARNING_LEVEL: u32 = 50; // NO_HISTORY = 2
const DICTIONARY_NAME: &str = "SebType";
/// Where the sync put other devices' words before #273; My words shows them and moves them into
/// SebType's dictionary when it next saves.
const OLD_SYNC_DICTIONARY: &str = "SebType sync";
/// What the history files are: Mozc's learned conversions, and its predictions and character forms
/// (user_history_storage.cc names that file per OS); cform.db is older Mozcs'.
#[cfg(windows)]
const HISTORY: [&str; 4] = ["segment.db", "boundary.db", "history.db", "cform.db"];
#[cfg(not(windows))]
const HISTORY: [&str; 4] = ["segment.db", "boundary.db", ".history.db", "cform.db"];
/// The parts of speech the window offers (State.ja-pos), as Mozc's PosType values.
pub const POS: [u64; 6] = [1, 4, 5, 9, 8, 15]; // 名詞 固有名詞 人名 地名 組織 顔文字

fn bad(e: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e)
}

fn read(path: &Path) -> io::Result<Vec<u8>> {
    match fs::read(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(vec![]),
        r => r,
    }
}

fn write(path: &Path, data: &[u8]) -> io::Result<bool> {
    if read(path)? == data {
        return Ok(false);
    }
    let tmp = path.with_extension("sebtype-tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)?;
    Ok(true)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Japanese {
    pub half_width_space: bool,
}

pub fn load(dir: &Path) -> io::Result<Japanese> {
    let cfg = read(&dir.join(CONFIG))?;
    Ok(Japanese {
        half_width_space: proto::get_varint(&cfg, SPACE_CHARACTER_FORM).map_err(bad)? == Some(2),
    })
}

/// Learning off as an older Configurator wrote it (NO_HISTORY), which stopped history predictions too
/// (#374); the next save drops it. Learning is sebtype.conf's now (crate::conf): the input method keeps
/// Mozc's history read-only while it is off.
pub fn old_learning_off(dir: &Path) -> bool {
    read(&dir.join(CONFIG))
        .ok()
        .and_then(|cfg| proto::get_varint(&cfg, HISTORY_LEARNING_LEVEL).ok()?)
        == Some(2)
}

/// Writes config1.db, keeping every other field; true when it changed (Mozc then needs a restart).
pub fn save(dir: &Path, j: &Japanese) -> io::Result<bool> {
    let path = dir.join(CONFIG);
    let cfg = read(&path)?;
    let cfg = proto::set_varint(&cfg, SPACE_CHARACTER_FORM, j.half_width_space.then_some(2))
        .map_err(bad)?;
    let cfg = proto::set_varint(&cfg, HISTORY_LEARNING_LEVEL, None).map_err(bad)?;
    write(&path, &cfg)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Word {
    pub reading: String,
    pub word: String,
    pub pos: usize, // index into POS
    /// Mozc's part of speech when it isn't one of POS (a word from the phone or Mozc's own tool),
    /// kept as it is; pos is then 0.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mozc_pos: Option<u64>,
}

fn string(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn ours(dictionary: &[proto::Field]) -> bool {
    dictionary.iter().any(|f| {
        f.number == 3 && [DICTIONARY_NAME, OLD_SYNC_DICTIONARY].contains(&&*string(f.bytes))
    })
}

/// The words in SebType's dictionaries (other dictionaries, made with Mozc's own tool, are left alone).
pub fn words(dir: &Path) -> io::Result<Vec<Word>> {
    let storage = read(&dir.join(DICTIONARIES))?;
    let mut words = vec![];
    for d in proto::fields(&storage)
        .map_err(bad)?
        .iter()
        .filter(|f| f.number == 2)
    {
        let fields = proto::fields(d.bytes).map_err(bad)?;
        if !ours(&fields) {
            continue;
        }
        for e in fields.iter().filter(|f| f.number == 4) {
            let (mut reading, mut word, mut mozc_pos) = (String::new(), String::new(), POS[0]);
            for f in proto::fields(e.bytes).map_err(bad)? {
                match f.number {
                    1 => reading = string(f.bytes),
                    2 => word = string(f.bytes),
                    5 => mozc_pos = f.varint.unwrap_or(POS[0]),
                    _ => {}
                }
            }
            let pos = POS.iter().position(|&p| p == mozc_pos);
            words.push(Word {
                reading,
                word,
                pos: pos.unwrap_or(0),
                mozc_pos: pos.is_none().then_some(mozc_pos),
            });
        }
    }
    Ok(words)
}

/// Writes SebType's dictionary with words, taking in the old sync dictionary's.
pub fn save_words(dir: &Path, words: &[Word]) -> io::Result<bool> {
    let path = dir.join(DICTIONARIES);
    let storage = read(&path)?;
    let mut out = vec![];
    let mut id = None;
    for f in proto::fields(&storage).map_err(bad)? {
        if f.number == 2 {
            let inner = proto::fields(f.bytes).map_err(bad)?;
            if ours(&inner) {
                if inner
                    .iter()
                    .any(|g| g.number == 3 && g.bytes == DICTIONARY_NAME.as_bytes())
                {
                    id = inner.iter().find(|g| g.number == 1).and_then(|g| g.varint);
                }
                continue;
            }
        }
        out.extend_from_slice(f.whole);
    }
    // A new dictionary needs an id no other one has; the time in nanoseconds is one.
    let id = id.unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    });
    let mut dict = proto::varint_field(1, id);
    dict.extend(proto::bytes_field(3, DICTIONARY_NAME.as_bytes()));
    for w in words {
        let mut e = proto::bytes_field(1, w.reading.as_bytes());
        e.extend(proto::bytes_field(2, w.word.as_bytes()));
        let pos = w.mozc_pos.unwrap_or(POS[w.pos.min(POS.len() - 1)]);
        e.extend(proto::varint_field(5, pos));
        dict.extend(proto::bytes_field(4, &e));
    }
    out.extend(proto::bytes_field(2, &dict));
    write(&path, &out)
}

/// Adds a word to the dictionary as it is now: the sync may have changed it since the window read it.
pub fn add_word(dir: &Path, word: Word) -> io::Result<bool> {
    let mut all = words(dir)?;
    all.push(word);
    save_words(dir, &all)
}

/// Removes a word (every entry with its reading and spelling, as the sync does) from the dictionary
/// as it is now.
pub fn remove_word(dir: &Path, reading: &str, word: &str) -> io::Result<bool> {
    let mut all = words(dir)?;
    all.retain(|w| (w.reading.as_str(), w.word.as_str()) != (reading, word));
    save_words(dir, &all)
}

/// Readings are hiragana (Mozc matches the kana the romaji turns into).
pub fn valid_word(reading: &str, word: &str) -> bool {
    !word.trim().is_empty()
        && !reading.is_empty()
        && reading
            .chars()
            .all(|c| ('\u{3041}'..='\u{309f}').contains(&c) || c == 'ー')
}

/// How many of Mozc's history files there are. A running Mozc forgets them itself
/// (core/src/mozc_inprocess.cpp, #375).
pub fn learned(dir: &Path) -> usize {
    HISTORY.iter().filter(|f| dir.join(f).exists()).count()
}

/// Deletes Mozc's history files, with no Mozc running (Linux without Fcitx5); how many there were.
#[cfg_attr(windows, allow(dead_code))]
pub fn forget(dir: &Path) -> io::Result<usize> {
    let mut n = 0;
    for f in HISTORY {
        match fs::remove_file(dir.join(f)) {
            Ok(()) => n += 1,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_and_dictionary_round_trip_keeping_other_data() {
        // In the crate's target/, not /tmp (#211); removed when the test passes.
        let d = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/mozc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        // A config with setup-ime's keymap fields (41, 42) and another dictionary made by Mozc's tool.
        let mut cfg = proto::varint_field(41, 0);
        cfg.extend(proto::bytes_field(42, b"keymap"));
        fs::write(d.join(CONFIG), &cfg).unwrap();
        let mut other = proto::varint_field(1, 7);
        other.extend(proto::bytes_field(3, "辞書".as_bytes()));
        let mut storage = proto::varint_field(1, 1);
        storage.extend(proto::bytes_field(2, &other));
        fs::write(d.join(DICTIONARIES), &storage).unwrap();

        assert_eq!(load(&d).unwrap(), Japanese::default());
        let j = Japanese {
            half_width_space: true,
        };
        assert!(save(&d, &j).unwrap());
        assert_eq!(load(&d).unwrap(), j);
        assert!(save(&d, &Japanese::default()).unwrap());
        assert_eq!(fs::read(d.join(CONFIG)).unwrap(), cfg);
        // An older Configurator's learning off (NO_HISTORY) goes at the next save (#374).
        let mut old = cfg.clone();
        old.extend(proto::varint_field(HISTORY_LEARNING_LEVEL, 2));
        fs::write(d.join(CONFIG), &old).unwrap();
        assert!(old_learning_off(&d));
        assert!(save(&d, &Japanese::default()).unwrap());
        assert!(!old_learning_off(&d));
        assert_eq!(fs::read(d.join(CONFIG)).unwrap(), cfg);

        let w = vec![Word {
            reading: "せぶ".into(),
            word: "SebType".into(),
            pos: 1,
            mozc_pos: None,
        }];
        save_words(&d, &w).unwrap();
        save_words(&d, &w).unwrap();
        assert_eq!(words(&d).unwrap(), w);
        let all = fs::read(d.join(DICTIONARIES)).unwrap();
        let dicts = proto::fields(&all)
            .unwrap()
            .into_iter()
            .filter(|f| f.number == 2)
            .count();
        assert_eq!(
            dicts, 2,
            "the other dictionary stays and SebType's isn't duplicated"
        );
        assert!(all.starts_with(&storage));
        assert!(valid_word("せぶ", "SebType") && !valid_word("seb", "SebType"));
        fs::remove_dir_all(&d).unwrap();
    }

    /// #273: words the sync brought before #273, in a dictionary of their own, show in My words and
    /// can be removed there; a part of speech the window doesn't offer stays as it was.
    #[test]
    fn synced_words_show_and_can_be_removed() {
        let d = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/mozc-sync-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let entry = |reading: &str, word: &str, pos: u64| {
            let mut e = proto::bytes_field(1, reading.as_bytes());
            e.extend(proto::bytes_field(2, word.as_bytes()));
            e.extend(proto::varint_field(5, pos));
            proto::bytes_field(4, &e)
        };
        let dictionary = |id: u64, name: &str, entries: &[Vec<u8>]| {
            let mut dict = proto::varint_field(1, id);
            dict.extend(proto::bytes_field(3, name.as_bytes()));
            entries.iter().for_each(|e| dict.extend(e));
            proto::bytes_field(2, &dict)
        };
        let mut storage = dictionary(3, "辞書", &[entry("じしょ", "辞書語", 1)]);
        storage.extend(dictionary(5, DICTIONARY_NAME, &[entry("もふ", "モフ", 1)]));
        storage.extend(dictionary(
            6,
            OLD_SYNC_DICTIONARY,
            &[entry("ぴぴ", "ピピ", 0), entry("ぷる", "プル", 5)],
        ));
        fs::write(d.join(DICTIONARIES), &storage).unwrap();

        let shown = |d: &Path| -> Vec<(String, usize, Option<u64>)> {
            words(d)
                .unwrap()
                .into_iter()
                .map(|w| (w.word, w.pos, w.mozc_pos))
                .collect()
        };
        assert_eq!(
            shown(&d),
            [
                ("モフ".into(), 0, None),
                ("ピピ".into(), 0, Some(0)), // 品詞なし, which the window doesn't offer
                ("プル".into(), 2, None),    // 人名
            ]
        );
        assert!(remove_word(&d, "ぷる", "プル").unwrap());
        assert_eq!(
            shown(&d),
            [("モフ".into(), 0, None), ("ピピ".into(), 0, Some(0))]
        );
        let all = fs::read(d.join(DICTIONARIES)).unwrap();
        let names: Vec<_> = proto::fields(&all)
            .unwrap()
            .iter()
            .filter(|f| f.number == 2)
            .map(|f| {
                let inner = proto::fields(f.bytes).unwrap();
                string(inner.iter().find(|g| g.number == 3).unwrap().bytes)
            })
            .collect();
        assert_eq!(
            names,
            ["辞書", DICTIONARY_NAME],
            "one SebType dictionary, Mozc's own kept"
        );
        assert!(String::from_utf8_lossy(&all).contains("ピピ"));
        fs::remove_dir_all(&d).unwrap();
    }
}
