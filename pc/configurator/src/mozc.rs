//! Japanese (Mozc's profile folder): config1.db's space and learning fields, SebType's own dictionary
//! in user_dictionary.db, and forgetting the input history. Field numbers are Mozc's
//! protocol/config.proto and protocol/user_dictionary_storage.proto.

use crate::proto;
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

const CONFIG: &str = "config1.db";
const DICTIONARIES: &str = "user_dictionary.db";
const SPACE_CHARACTER_FORM: u32 = 47; // FUNDAMENTAL_HALF_WIDTH = 2
const HISTORY_LEARNING_LEVEL: u32 = 50; // NO_HISTORY = 2
const DICTIONARY_NAME: &str = "SebType";
/// What the history files are: Mozc's learned conversions and predictions.
const HISTORY: [&str; 4] = ["segment.db", "boundary.db", "cform.db", ".history.db"];
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
    pub learn: bool,
}

pub fn load(dir: &Path) -> io::Result<Japanese> {
    let cfg = read(&dir.join(CONFIG))?;
    Ok(Japanese {
        half_width_space: proto::get_varint(&cfg, SPACE_CHARACTER_FORM).map_err(bad)? == Some(2),
        learn: proto::get_varint(&cfg, HISTORY_LEARNING_LEVEL).map_err(bad)? != Some(2),
    })
}

/// Writes config1.db, keeping every other field; true when it changed (Mozc then needs a restart).
pub fn save(dir: &Path, j: &Japanese) -> io::Result<bool> {
    let path = dir.join(CONFIG);
    let cfg = read(&path)?;
    let cfg = proto::set_varint(&cfg, SPACE_CHARACTER_FORM, j.half_width_space.then_some(2))
        .map_err(bad)?;
    let cfg =
        proto::set_varint(&cfg, HISTORY_LEARNING_LEVEL, (!j.learn).then_some(2)).map_err(bad)?;
    write(&path, &cfg)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Word {
    pub reading: String,
    pub word: String,
    pub pos: usize, // index into POS
}

fn string(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// The words in SebType's dictionary (other dictionaries, made with Mozc's own tool, are left alone).
pub fn words(dir: &Path) -> io::Result<Vec<Word>> {
    let storage = read(&dir.join(DICTIONARIES))?;
    for d in proto::fields(&storage)
        .map_err(bad)?
        .iter()
        .filter(|f| f.number == 2)
    {
        let fields = proto::fields(d.bytes).map_err(bad)?;
        if !fields
            .iter()
            .any(|f| f.number == 3 && f.bytes == DICTIONARY_NAME.as_bytes())
        {
            continue;
        }
        let mut words = vec![];
        for e in fields.iter().filter(|f| f.number == 4) {
            let (mut reading, mut word, mut pos) = (String::new(), String::new(), 0);
            for f in proto::fields(e.bytes).map_err(bad)? {
                match f.number {
                    1 => reading = string(f.bytes),
                    2 => word = string(f.bytes),
                    5 => pos = POS.iter().position(|&p| Some(p) == f.varint).unwrap_or(0),
                    _ => {}
                }
            }
            words.push(Word { reading, word, pos });
        }
        return Ok(words);
    }
    Ok(vec![])
}

pub fn save_words(dir: &Path, words: &[Word]) -> io::Result<bool> {
    let path = dir.join(DICTIONARIES);
    let storage = read(&path)?;
    let mut out = vec![];
    let mut id = None;
    for f in proto::fields(&storage).map_err(bad)? {
        if f.number == 2 {
            let inner = proto::fields(f.bytes).map_err(bad)?;
            if inner
                .iter()
                .any(|g| g.number == 3 && g.bytes == DICTIONARY_NAME.as_bytes())
            {
                id = inner.iter().find(|g| g.number == 1).and_then(|g| g.varint);
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
        e.extend(proto::varint_field(5, POS[w.pos.min(POS.len() - 1)]));
        dict.extend(proto::bytes_field(4, &e));
    }
    out.extend(proto::bytes_field(2, &dict));
    write(&path, &out)
}

/// Readings are hiragana (Mozc matches the kana the romaji turns into).
pub fn valid_word(reading: &str, word: &str) -> bool {
    !word.trim().is_empty()
        && !reading.is_empty()
        && reading
            .chars()
            .all(|c| ('\u{3041}'..='\u{309f}').contains(&c) || c == 'ー')
}

/// Deletes Mozc's history files; mozc_server must be stopped first, or it writes them back.
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
        let d = std::env::temp_dir().join(format!(
            "sebtype-configurator-test-mozc-{}",
            std::process::id()
        ));
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

        assert_eq!(
            load(&d).unwrap(),
            Japanese {
                half_width_space: false,
                learn: true
            }
        );
        let j = Japanese {
            half_width_space: true,
            learn: false,
        };
        assert!(save(&d, &j).unwrap());
        assert_eq!(load(&d).unwrap(), j);
        assert!(save(
            &d,
            &Japanese {
                half_width_space: false,
                learn: true
            }
        )
        .unwrap());
        assert_eq!(fs::read(d.join(CONFIG)).unwrap(), cfg);

        let w = vec![Word {
            reading: "せぶ".into(),
            word: "SebType".into(),
            pos: 1,
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
    }
}
