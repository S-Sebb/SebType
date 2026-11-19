//! Chinese (rime-ice in Rime's user folder): the settings as patch entries, the user's own words in
//! custom_phrase.txt, and forgetting learned words. The same files and rules as the phone (#41).

use crate::patch;
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
};
use yaml_rust2::{Yaml, YamlLoader};

const SCHEMA_PATCH: &str = "rime_ice.custom.yaml";
const DEFAULT_PATCH: &str = "default.custom.yaml";
pub const PHRASES: &str = "custom_phrase.txt";
const MARKER: &str = "# SebType: My words"; // as the phone writes it (ChineseMyWords)
/// The sync's record of My words (sebtype_sync.py's ZH_FILE, #272): named like Rime's snapshots, but
/// not learned words, so forget keeps it.
const SYNCED_WORDS: &str = "zh_my_words.userdb.txt";

// rime-ice's switches, by their place in rime_ice.schema.yaml.
const ASCII_PUNCT: &str = "switches/@1/reset";
const TRADITIONAL: &str = "switches/@2/reset";
const EMOJI: &str = "switches/@3/reset";
const ALGEBRA: &str = "speller/algebra/+";
const LEARN: &str = "translator/enable_user_dict";
const PAGE_SIZE: &str = "menu/page_size";
/// SebType's page size on the PCs (Decisions #2, #163), which the setup scripts write into
/// default.custom.yaml; rime-ice's default.yaml has 5.
const DEFAULT_PAGE_SIZE: i32 = 6;

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
            page_size: DEFAULT_PAGE_SIZE,
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
    let page_size = page_size(&read(&dir.join(DEFAULT_PATCH)));
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

fn page_size(defaults_patch: &str) -> i32 {
    patch::value(defaults_patch, PAGE_SIZE)
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_PAGE_SIZE)
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
    if page_size(&defaults) != c.page_size {
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

/// Adds a word to My words as they are now: the sync may have changed them since the window read them.
pub fn add_word(dir: &Path, word: Word) -> io::Result<bool> {
    let mut all = words(dir);
    all.push(word);
    save_words(dir, &all)
}

/// Removes a word from My words as they are now.
pub fn remove_word(dir: &Path, word: &Word) -> io::Result<bool> {
    let mut all = words(dir);
    all.retain(|w| w != word);
    save_words(dir, &all)
}

/// What Rime learned (its user dictionaries and their snapshots, and the snapshots in its sync folder, which
/// its sync merges back); the settings and the user's own words aren't in it. A running Rime forgets them
/// itself (core/src/rime.cpp's forget, #375), the same way.
pub fn learned(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let snapshot = |path: &Path, name: &str| {
        name != SYNCED_WORDS
            && (name.ends_with(".userdb.txt") || name.ends_with(".userdb.kct"))
            && path.is_file()
    };
    fn walk(
        dir: &Path,
        snapshot: &dyn Fn(&Path, &str) -> bool,
        out: &mut Vec<PathBuf>,
    ) -> io::Result<()> {
        for e in fs::read_dir(dir)? {
            let path = e?.path();
            let name = path.file_name().unwrap().to_string_lossy();
            if name.ends_with(".userdb") && path.is_dir() {
                out.push(path);
            } else if snapshot(&path, &name) {
                out.push(path);
            } else if path.is_dir() && !path.is_symlink() {
                walk(&path, snapshot, out)?;
            }
        }
        Ok(())
    }
    let sync = sync_folder(dir)?;
    let mut found = vec![];
    walk(dir, &snapshot, &mut found)?;
    // The sync folder may be anywhere, among files that aren't Rime's: only what Rime's sync merges, a
    // snapshot it wrote directly in a device's folder (a link to one too, as Rime follows it).
    match fs::read_dir(&sync) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        devices => {
            for device in devices? {
                let device = device?.path();
                if !device.is_dir() {
                    continue;
                }
                for file in fs::read_dir(&device)? {
                    let path = file?.path();
                    let name = path.file_name().unwrap().to_string_lossy();
                    if name.ends_with(".txt") && snapshot(&path, &name) && rime_snapshot(&path) {
                        found.push(path);
                    }
                }
            }
        }
    }
    // By its folder's real path: a sync folder inside Rime's folder is found twice.
    let mut learned = std::collections::BTreeSet::new();
    for p in found {
        learned.insert(fs::canonicalize(p.parent().unwrap())?.join(p.file_name().unwrap()));
    }
    Ok(learned.into_iter().collect())
}

/// Whether a file starts as Rime writes a snapshot (TsvWriter, user_db.cc).
fn rime_snapshot(path: &Path) -> bool {
    use io::BufRead;
    let mut line = String::new();
    fs::File::open(path)
        .and_then(|f| io::BufReader::new(f).read_line(&mut line))
        .is_ok()
        && line.trim_end_matches(['\r', '\n']) == "# Rime user dictionary"
}

/// Deletes what Rime learned, with no Rime running (Linux without Fcitx5); how many there were.
#[cfg_attr(windows, allow(dead_code))]
pub fn forget(dir: &Path) -> io::Result<usize> {
    let learned = learned(dir)?;
    for p in &learned {
        // A user dictionary is a folder; a link to a snapshot loses only the link.
        if p.extension().is_some_and(|e| e == "userdb") {
            fs::remove_dir_all(p)?;
        } else {
            fs::remove_file(p)?;
        }
    }
    Ok(learned.len())
}

/// installation.yaml as Rime (yaml-cpp) reads it; None when there is none yet (before Rime's first start).
fn installation(dir: &Path) -> io::Result<Option<Yaml>> {
    let file = dir.join("installation.yaml");
    let text = match fs::read_to_string(&file) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        r => r?,
    };
    let docs = YamlLoader::load_from_str(&text)
        .map_err(|e| io::Error::other(format!("{}: {e}", file.display())))?;
    Ok(Some(docs.into_iter().next().unwrap_or(Yaml::Null)))
}

/// Rime's sync folder: installation.yaml's sync_dir, else `<dir>/sync` (Rime's deployment_tasks.cc). A
/// relative one, which Rime takes from its working directory, is refused: the folder it syncs is unknown.
fn sync_folder(dir: &Path) -> io::Result<PathBuf> {
    let sync = match installation(dir)?.as_ref().map(|y| &y["sync_dir"]) {
        // Rime takes any scalar as a path; null (as `~`) or none is its default.
        Some(Yaml::String(v) | Yaml::Real(v)) => PathBuf::from(v),
        Some(Yaml::Integer(v)) => PathBuf::from(v.to_string()),
        Some(Yaml::Boolean(v)) => PathBuf::from(v.to_string()),
        _ => return Ok(dir.join("sync")),
    };
    if !sync.is_absolute() {
        return Err(io::Error::other(format!(
            "installation.yaml's sync_dir {sync:?} is relative, so the folder Rime syncs is unknown"
        )));
    }
    Ok(sync)
}

/// This PC's own folder in Rime's sync folder, `<sync_dir>/<installation_id>`, read from
/// installation.yaml as Rime reads it; None before Rime's first start or when it can't tell.
pub fn own_sync_folder(dir: &Path) -> Option<PathBuf> {
    let id = installation(dir).ok()??["installation_id"]
        .as_str()
        .filter(|v| !v.is_empty())?
        .to_string();
    Some(sync_folder(dir).ok()?.join(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        // In the crate's target/, not /tmp (#211); each test removes its folder when it passes.
        let d = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/{name}-{}", std::process::id()));
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
        assert_eq!(load(&d).page_size, 6, "SebType's 6, not rime-ice's 5");
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
        fs::remove_dir_all(&d).unwrap();
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
        // Add and remove work on the file as the sync left it, not on the window's list.
        let other = Word {
            word: "噗莫".into(),
            pinyin: "pumo".into(),
        };
        add_word(&d, other.clone()).unwrap();
        assert_eq!(words(&d), [w[0].clone(), other.clone()]);
        remove_word(&d, &w[0]).unwrap();
        assert_eq!(words(&d), [other]);
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
        fs::write(d.join("sync/abc").join(SYNCED_WORDS), "x").unwrap();
        assert_eq!(forget(&d).unwrap(), 2);
        assert!(
            d.join("sync/abc").join(SYNCED_WORDS).exists(),
            "My words' sync record stays"
        );
        assert!(!d.join("rime_ice.userdb").exists() && d.join(PHRASES).exists());

        // A sync folder outside Rime's folder (#396), such as a home folder: only the snapshots Rime's sync
        // merges go, every device's (through a link too), and nothing else there.
        let home = d.with_extension("home#rime");
        let elsewhere = d.with_extension("elsewhere");
        for f in [&home, &elsewhere] {
            let _ = fs::remove_dir_all(f);
        }
        let snapshot = "# Rime user dictionary\n#@/db_name\trime_ice\n";
        let files = [
            ("abc/rime_ice.userdb.txt", snapshot, false),
            ("def/luna_pinyin.userdb.txt", snapshot, false),
            ("abc/zh_my_words.userdb.txt", snapshot, true),
            ("abc/notes.txt", "x", true),
            ("abc/other.userdb.txt", "an app's own", true),
            ("abc/dir.userdb.txt/inside.txt", "x", true),
            ("abc/rime_ice.userdb/data", "x", true),
            ("top.userdb.txt", snapshot, true),
            ("archive/deep/custom.userdb.txt", snapshot, true),
        ];
        for (name, text, _) in files {
            let p = home.join(name);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, text).unwrap();
        }
        fs::create_dir_all(&elsewhere).unwrap();
        fs::write(elsewhere.join("rime_ice.userdb.txt"), snapshot).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&elsewhere, home.join("linked")).unwrap();
        // Unquoted, as Rime reads it: the # is in the path, not a comment.
        fs::write(
            d.join("installation.yaml"),
            format!(
                "installation_id: abc\nsync_dir: {}  # a comment\n",
                home.display()
            ),
        )
        .unwrap();
        assert_eq!(own_sync_folder(&d), Some(home.join("abc")));
        assert_eq!(forget(&d).unwrap(), if cfg!(unix) { 3 } else { 2 });
        for (name, _, kept) in files {
            assert_eq!(home.join(name).exists(), kept, "{name}");
        }
        assert!(!elsewhere.join("rime_ice.userdb.txt").exists());

        // Quoted as YAML quotes; Rime's default when there is no sync_dir or it is null; refused when Rime
        // would take it from its working directory, or installation.yaml isn't YAML.
        let path = home.display().to_string();
        for (yaml, want) in [
            (format!("sync_dir: '{path}'"), Some(home.clone())),
            (format!("sync_dir: \"{path}\""), Some(home.clone())),
            ("sync_dir: ~".into(), Some(d.join("sync"))),
            ("installation_id: abc".into(), Some(d.join("sync"))),
            ("sync_dir: sync".into(), None),
            ("sync_dir: ~/sync".into(), None),
            ("sync_dir: \"\"".into(), None),
            ("sync_dir: [".into(), None),
        ] {
            fs::write(d.join("installation.yaml"), &yaml).unwrap();
            assert_eq!(sync_folder(&d).ok(), want, "{yaml}");
        }
        assert!(forget(&d).is_err(), "nothing deleted where it can't tell");

        // Inside Rime's folder, each snapshot is counted once.
        fs::write(d.join("sync/abc/rime_ice.userdb.txt"), snapshot).unwrap();
        fs::write(
            d.join("installation.yaml"),
            format!("sync_dir: \"{}\"\n", d.join("sync").display()),
        )
        .unwrap();
        assert_eq!(learned(&d).unwrap().len(), 1);
        for f in [&home, &elsewhere] {
            fs::remove_dir_all(f).unwrap();
        }
        fs::remove_dir_all(&d).unwrap();
    }
}
