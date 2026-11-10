//! Chinese (rime-ice in Rime's user folder): the settings as patch entries, the user's own words in
//! custom_phrase.txt, and forgetting learned words. The same files and rules as the phone (#41).

use crate::patch;
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

const SCHEMA_PATCH: &str = "rime_ice.custom.yaml";
const DEFAULT_PATCH: &str = "default.custom.yaml";
const PHRASES: &str = "custom_phrase.txt";
const MARKER: &str = "# SebType: My words"; // as the phone writes it (ChineseMyWords)

// rime-ice's switches, by their place in rime_ice.schema.yaml.
const ASCII_PUNCT: &str = "switches/@1/reset";
const TRADITIONAL: &str = "switches/@2/reset";
const EMOJI: &str = "switches/@3/reset";
const ALGEBRA: &str = "speller/algebra/+";
const LEARN: &str = "translator/enable_user_dict";
const PAGE_SIZE: &str = "menu/page_size";

/// The phone's fuzzy pinyin pairs (ChineseIMESettings.FuzzyPinyinModes): initial or final, two-way.
pub const FUZZY: [(&str, &str, bool, bool); 12] = [
    ("z", "zh", true, true),
    ("c", "ch", true, true),
    ("s", "sh", true, true),
    ("l", "n", true, true),
    ("f", "h", true, true),
    ("r", "l", true, false),
    ("k", "g", true, false),
    ("an", "ang", false, true),
    ("en", "eng", false, true),
    ("in", "ing", false, true),
    ("ian", "iang", false, true),
    ("uan", "uang", false, true),
];

pub fn fuzzy_label(i: usize) -> String {
    format!("{} = {}", FUZZY[i].0, FUZZY[i].1)
}

fn fuzzy_rules(i: usize) -> Vec<String> {
    let (a, b, initial, two_way) = FUZZY[i];
    let rule = |x: &str, y: &str| {
        if initial {
            format!("derive/^{x}/{y}/")
        } else {
            format!("derive/{x}$/{y}/")
        }
    };
    let mut rules = vec![rule(a, b)];
    if two_way {
        rules.push(rule(b, a));
    }
    rules
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Chinese {
    pub traditional: bool,
    pub full_width_punctuation: bool,
    pub emoji: bool,
    pub fuzzy: Vec<bool>,
    pub learn: bool,
    pub page_size: i32,
}

impl Default for Chinese {
    fn default() -> Self {
        Chinese {
            traditional: false,
            full_width_punctuation: true,
            emoji: true,
            fuzzy: vec![false; FUZZY.len()],
            learn: true,
            page_size: 5,
        }
    }
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// Writes `text` unless the file already holds it; true when it wrote.
fn write(path: &Path, text: &str) -> io::Result<bool> {
    if read(path) == text {
        return Ok(false);
    }
    let tmp = path.with_extension("sebtype-tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, path)?;
    Ok(true)
}

pub fn load(dir: &Path) -> Chinese {
    let schema = read(&dir.join(SCHEMA_PATCH));
    let rules = patch::block(&schema, ALGEBRA);
    let page_size = page_size(dir, &read(&dir.join(DEFAULT_PATCH)));
    Chinese {
        full_width_punctuation: patch::value(&schema, ASCII_PUNCT) != Some("1"),
        traditional: patch::value(&schema, TRADITIONAL) == Some("1"),
        emoji: patch::value(&schema, EMOJI) != Some("0"),
        fuzzy: (0..FUZZY.len())
            .map(|i| {
                fuzzy_rules(i)
                    .iter()
                    .all(|r| rules.contains(&format!("- {r}")))
            })
            .collect(),
        learn: patch::value(&schema, LEARN) != Some("false"),
        page_size,
    }
}

fn page_size(dir: &Path, defaults_patch: &str) -> i32 {
    patch::value(defaults_patch, PAGE_SIZE)
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| default_page_size(dir))
}

/// rime-ice's own page size (default.yaml's `menu: page_size:`), 5 when it can't be read.
fn default_page_size(dir: &Path) -> i32 {
    let text = read(&dir.join("default.yaml"));
    let mut in_menu = false;
    for line in text.lines() {
        if !line.starts_with(' ') && !line.is_empty() {
            in_menu = line.trim_end() == "menu:";
        } else if in_menu {
            if let Some(v) = line.trim().strip_prefix("page_size:") {
                return v.split('#').next().unwrap().trim().parse().unwrap_or(5);
            }
        }
    }
    5
}

/// Writes the patches; true when something changed (Rime then needs a redeploy). Only what differs
/// from rime-ice goes in, as on the phone, so the default settings add no patch entries.
pub fn save(dir: &Path, c: &Chinese) -> io::Result<bool> {
    let path = dir.join(SCHEMA_PATCH);
    let mut entries = vec![];
    if !c.full_width_punctuation {
        entries.push(format!(
            "  {ASCII_PUNCT}: 1  # SebType: half-width punctuation"
        ));
    }
    if c.traditional {
        entries.push(format!("  {TRADITIONAL}: 1  # SebType: start in 繁體"));
    }
    if !c.emoji {
        entries.push(format!("  {EMOJI}: 0  # SebType: no emoji in candidates"));
    }
    if !c.learn {
        entries.push(format!("  {LEARN}: false  # SebType: don't learn"));
    }
    // Appended (not replaced): rime-ice's own rules give abbreviated pinyin.
    let rules: Vec<String> = (0..FUZZY.len())
        .filter(|&i| c.fuzzy.get(i) == Some(&true))
        .flat_map(fuzzy_rules)
        .collect();
    if !rules.is_empty() {
        entries.push(format!("  {ALGEBRA}:  # SebType: fuzzy pinyin"));
        entries.extend(rules.iter().map(|r| format!("    - {r}")));
    }
    let schema = read(&path);
    let mut changed = false;
    if path.exists() || !entries.is_empty() {
        changed |= write(
            &path,
            &patch::set(
                &schema,
                &[ASCII_PUNCT, TRADITIONAL, EMOJI, LEARN, ALGEBRA],
                &entries,
            ),
        )?;
    }
    let path = dir.join(DEFAULT_PATCH);
    let defaults = read(&path);
    if page_size(dir, &defaults) != c.page_size {
        let line = format!("  {PAGE_SIZE}: {}", c.page_size);
        changed |= write(&path, &patch::set(&defaults, &[PAGE_SIZE], &[line]))?;
    }
    Ok(changed)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Word {
    pub word: String,
    pub pinyin: String,
}

/// The code Rime matches: lowercase pinyin letters only, so "Xiao Ming" and "xiao'ming" both work.
pub fn normalize_pinyin(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase())
        .collect()
}

pub fn valid_word(word: &str, pinyin: &str) -> bool {
    !word.trim().is_empty()
        && !word.contains(['\t', '\n'])
        && !pinyin.is_empty()
        && pinyin.chars().all(|c| c.is_ascii_lowercase())
}

pub fn words(dir: &Path) -> Vec<Word> {
    read(&dir.join(PHRASES))
        .lines()
        .skip_while(|l| *l != MARKER)
        .skip(1)
        .filter_map(|l| {
            let mut parts = l.split('\t');
            Some(Word {
                word: parts.next()?.to_string(),
                pinyin: parts.next()?.to_string(),
            })
        })
        .collect()
}

/// Saves the user's words after rime-ice's own phrases. Rime reads them when it starts (a redeploy).
pub fn save_words(dir: &Path, words: &[Word]) -> io::Result<bool> {
    let path = dir.join(PHRASES);
    let old = read(&path);
    let mut text: String = old
        .lines()
        .take_while(|l| *l != MARKER)
        .map(|l| format!("{l}\n"))
        .collect();
    text.push_str(MARKER);
    text.push('\n');
    for w in words {
        text.push_str(&format!("{}\t{}\n", w.word.trim(), w.pinyin));
    }
    write(&path, &text)
}

/// Deletes what Rime learned (its user dictionaries and their sync snapshots); the settings and the
/// user's own words stay. Rime must restart (redeploy) afterwards.
pub fn forget(dir: &Path) -> io::Result<usize> {
    fn walk(dir: &Path, n: &mut usize) -> io::Result<()> {
        for e in fs::read_dir(dir)? {
            let path = e?.path();
            let name = path.file_name().unwrap().to_string_lossy();
            if name.ends_with(".userdb") && path.is_dir() {
                fs::remove_dir_all(&path)?;
                *n += 1;
            } else if name.ends_with(".userdb.txt") || name.ends_with(".userdb.kct") {
                fs::remove_file(&path)?;
                *n += 1;
            } else if path.is_dir() && !path.is_symlink() {
                walk(&path, n)?;
            }
        }
        Ok(())
    }
    let mut n = 0;
    walk(dir, &mut n)?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sebtype-configurator-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn settings_round_trip_and_keep_setup_entries() {
        let d = temp("rime");
        let setup = "patch:\n  schema/name: \".中文\"  # SebType (#69)\n";
        fs::write(d.join(SCHEMA_PATCH), setup).unwrap();
        fs::write(
            d.join("default.yaml"),
            "menu:\n  page_size: 5  # 候选词个数\n",
        )
        .unwrap();
        assert_eq!(load(&d), Chinese::default());
        // Defaults write nothing new.
        assert!(!save(&d, &Chinese::default()).unwrap());
        assert!(!d.join(DEFAULT_PATCH).exists());

        let mut c = Chinese {
            traditional: true,
            full_width_punctuation: false,
            emoji: false,
            learn: false,
            page_size: 7,
            ..Chinese::default()
        };
        c.fuzzy[0] = true;
        c.fuzzy[5] = true;
        assert!(save(&d, &c).unwrap());
        assert_eq!(load(&d), c);
        assert!(read(&d.join(SCHEMA_PATCH)).contains("schema/name"));
        assert!(
            !save(&d, &c).unwrap(),
            "saving the same settings again changes nothing"
        );
        assert!(save(
            &d,
            &Chinese {
                page_size: 7,
                ..Chinese::default()
            }
        )
        .unwrap());
        assert_eq!(read(&d.join(SCHEMA_PATCH)), setup);
    }

    #[test]
    fn words_go_after_rime_ices_phrases_and_forget_keeps_them() {
        let d = temp("words");
        fs::write(d.join(PHRASES), "# rime-ice\n你好\tnihao\t1\n").unwrap();
        let w = vec![Word {
            word: "小明".into(),
            pinyin: normalize_pinyin("Xiao'Ming"),
        }];
        save_words(&d, &w).unwrap();
        assert_eq!(words(&d), w);
        save_words(&d, &[]).unwrap();
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("# rime-ice\n你好\tnihao\t1\n{MARKER}\n")
        );
        assert!(
            valid_word("小明", "xiaoming")
                && !valid_word("小\t明", "xiaoming")
                && !valid_word("小明", "")
        );

        fs::create_dir_all(d.join("rime_ice.userdb")).unwrap();
        fs::create_dir_all(d.join("sync/abc")).unwrap();
        fs::write(d.join("sync/abc/rime_ice.userdb.txt"), "x").unwrap();
        assert_eq!(forget(&d).unwrap(), 2);
        assert!(!d.join("rime_ice.userdb").exists() && d.join(PHRASES).exists());
    }
}
