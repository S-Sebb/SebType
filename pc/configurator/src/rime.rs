//! Chinese (rime-ice in Rime's user folder): the settings as patch entries, the user's own words in
//! custom_phrase.txt, and forgetting learned words. The same files and rules as the phone (#41).

use crate::{patch, write_file};
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
/// An older Configurator's learning off (#374), as it wrote it: only removed (drop_old_learning).
const OLD_LEARNING_OFF: &str = "translator/enable_user_dict: false  # SebType: don't learn";
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
    pub page_size: i32,
}

impl Default for Chinese {
    fn default() -> Self {
        Chinese {
            traditional: false,
            full_width_punctuation: true,
            emoji: true,
            fuzzy: vec![false; FUZZY.len()],
            page_size: DEFAULT_PAGE_SIZE,
        }
    }
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
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
        page_size,
    }
}

/// Learning off as an older Configurator wrote it, which hid the learned words too (#374): known by its
/// comment, as an enable_user_dict someone wrote themselves is theirs. Learning is sebtype.conf's now
/// (crate::conf); only drop_old_learning removes this, once sebtype.conf holds it.
pub fn old_learning_off(dir: &Path) -> bool {
    read(&dir.join(SCHEMA_PATCH))
        .lines()
        .any(|l| l.trim() == OLD_LEARNING_OFF)
}
/// True when there was one (Rime then needs a redeploy).
pub fn drop_old_learning(dir: &Path) -> io::Result<bool> {
    if !old_learning_off(dir) {
        return Ok(false);
    }
    let path = dir.join(SCHEMA_PATCH);
    let text = read(&path);
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| l.trim() != OLD_LEARNING_OFF)
        .collect();
    write_file(&path, &format!("{}\n", kept.join("\n")))
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
        changed |= write_file(
            &path,
            &patch::set(
                &schema,
                &[ASCII_PUNCT, TRADITIONAL, EMOJI, ALGEBRA],
                &entries,
            ),
        )?;
    }
    let path = dir.join(DEFAULT_PATCH);
    let defaults = read(&path);
    if page_size(&defaults) != c.page_size {
        let line = format!("  {PAGE_SIZE}: {}", c.page_size);
        changed |= write_file(&path, &patch::set(&defaults, &[PAGE_SIZE], &[line]))?;
    }
    Ok(changed)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Word {
    pub word: String,
    pub pinyin: String,
    /// What the line has after the pinyin (a weight, a comment), and the lines without a word just above
    /// it (comments, blank lines): kept as they are when My words are saved (#410).
    #[serde(skip)]
    pub rest: String,
    #[serde(skip)]
    pub above: String,
}

impl Word {
    /// The same word: its spelling and pinyin (what else its line has goes with it).
    pub fn same(&self, other: &Word) -> bool {
        (&self.word, &self.pinyin) == (&other.word, &other.pinyin)
    }
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
    my_words(&read(&dir.join(PHRASES))).0
}

/// The words after the marker, and the lines without a word after the last one.
fn my_words(text: &str) -> (Vec<Word>, String) {
    let (mut words, mut above) = (vec![], String::new());
    for l in text.lines().skip_while(|l| *l != MARKER).skip(1) {
        let mut parts = l.splitn(3, '\t');
        match (parts.next(), parts.next()) {
            (Some(word), Some(pinyin)) if !l.starts_with('#') => words.push(Word {
                word: word.into(),
                pinyin: pinyin.into(),
                rest: parts.next().map_or(String::new(), |r| format!("\t{r}")),
                above: std::mem::take(&mut above),
            }),
            _ => above.push_str(&format!("{l}\n")),
        }
    }
    (words, above)
}

/// Saves the user's words after rime-ice's own phrases. Rime reads them when it starts (a redeploy).
pub fn save_words(dir: &Path, words: &[Word]) -> io::Result<bool> {
    save_with(dir, words, "")
}

/// save_words, with the comment lines of words taken out from the end (take_out) before the old end's.
fn save_with(dir: &Path, words: &[Word], orphans: &str) -> io::Result<bool> {
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
        text.push_str(&format!(
            "{}{}\t{}{}\n",
            w.above,
            w.word.trim(),
            w.pinyin,
            w.rest
        ));
    }
    text.push_str(orphans);
    text.push_str(&my_words(&old).1);
    write_file(&path, &text)
}

/// Adds a word to My words as they are now: the sync may have changed them since the window read them.
/// Returns the list written, for the window to show.
pub fn add_word(dir: &Path, word: Word) -> io::Result<Vec<Word>> {
    let mut all = words(dir);
    all.push(word);
    save_words(dir, &all)?;
    Ok(all)
}

/// Changes the word at i in all, keeping what else its line has (crate::put_in_place); returns the comment
/// lines that go to the end of My words (take_out).
pub fn edit_in(all: &mut Vec<Word>, i: usize, mut new: Word) -> String {
    (new.rest, new.above) = (all[i].rest.clone(), all[i].above.clone());
    let mut orphans = String::new();
    crate::put_in_place(all, i, new, Word::same, |all, j| {
        orphans.push_str(&take_out(all, j))
    });
    orphans
}

/// Changes the word at i of My words as shown (edit_in), returning the list written. Nothing changes, and
/// My words as they are now come back as Err, when they are no longer as shown (the sync or another
/// window changed them): i may be another word now.
pub fn edit_word(
    dir: &Path,
    shown: &[Word],
    i: usize,
    new: Word,
) -> io::Result<Result<Vec<Word>, Vec<Word>>> {
    let mut all = words(dir);
    if all != shown {
        return Ok(Err(all));
    }
    let orphans = edit_in(&mut all, i, new);
    save_with(dir, &all, &orphans)?;
    Ok(Ok(all))
}

/// Removes the word at i of My words as shown, as edit_word.
pub fn remove_word(dir: &Path, shown: &[Word], i: usize) -> io::Result<bool> {
    let mut all = words(dir);
    if all != shown {
        return Ok(false);
    }
    let orphans = take_out(&mut all, i);
    save_with(dir, &all, &orphans).map(|_| true)
}

/// Takes out the entry at i. The comment lines above it stay, above the next entry, or else returned
/// for the end of My words.
pub fn take_out(all: &mut Vec<Word>, i: usize) -> String {
    let w = all.remove(i);
    match all.get_mut(i) {
        Some(next) => {
            next.above.insert_str(0, &w.above);
            String::new()
        }
        None => w.above,
    }
}

/// What Rime learned (its user dictionaries and their snapshots, and the snapshots in its sync folder, which
/// its sync merges back); the settings and the user's own words aren't in it. A running Rime forgets them
/// itself (core/src/rime.cpp's forget, #375), the same way.
pub fn learned(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let snapshot = |path: &Path, name: &str| {
        let name = file_name(name);
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
            if file_name(&name).ends_with(".userdb") && path.is_dir() {
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
                    if file_name(&name).ends_with(".txt") && snapshot(&path, &name) {
                        // One it can't read may be Rime's, and merge back once it can: not forgotten.
                        let rime = rime_snapshot(&path).map_err(|e| {
                            io::Error::new(e.kind(), format!("{}: {e}", path.display()))
                        })?;
                        if rime {
                            found.push(path);
                        }
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
fn rime_snapshot(path: &Path) -> io::Result<bool> {
    use io::BufRead;
    let mut line = vec![];
    io::BufReader::new(fs::File::open(path)?).read_until(b'\n', &mut line)?;
    Ok(line.trim_ascii_end() == b"# Rime user dictionary")
}

/// A file's name as Rime's lookup matches it: in any case on Windows, whose folders ignore it.
fn file_name(name: &str) -> std::borrow::Cow<'_, str> {
    if cfg!(windows) {
        name.to_ascii_lowercase().into()
    } else {
        name.into()
    }
}

/// Deletes what Rime learned, with no Rime running (Linux without Fcitx5); how many there were.
#[cfg_attr(windows, allow(dead_code))]
pub fn forget(dir: &Path) -> io::Result<usize> {
    let learned = learned(dir)?;
    for p in &learned {
        // A user dictionary is a folder; a link to a snapshot loses only the link.
        if file_name(&p.file_name().unwrap().to_string_lossy()).ends_with(".userdb") {
            fs::remove_dir_all(p)?;
        } else {
            fs::remove_file(p)?;
        }
    }
    Ok(learned.len())
}

/// installation.yaml's top-level entries; none when there is no file yet (before Rime's first start). An
/// error when it isn't one YAML mapping (a key twice too): what Rime makes of that isn't guessed.
fn installation(dir: &Path) -> io::Result<yaml_rust2::yaml::Hash> {
    let file = dir.join("installation.yaml");
    let text = match fs::read_to_string(&file) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Default::default()),
        r => r?,
    };
    let bad = |why: String| io::Error::other(format!("{}: {why}", file.display()));
    let mut docs = YamlLoader::load_from_str(&text).map_err(|e| bad(e.to_string()))?;
    match (docs.pop(), docs.is_empty()) {
        (None | Some(Yaml::Null), true) => Ok(Default::default()),
        (Some(Yaml::Hash(h)), true) => Ok(h),
        _ => Err(bad("not one YAML mapping".into())),
    }
}

/// Rime's sync folder: installation.yaml's sync_dir, else `<dir>/sync` (Rime's deployment_tasks.cc). Only
/// a missing or null sync_dir is the default and only a text a path: anything else (a tag that doesn't fit,
/// a number, a list) is refused, and a relative path too, which Rime takes from its working directory.
fn sync_folder(dir: &Path) -> io::Result<PathBuf> {
    let sync = match installation(dir)?.get(&Yaml::String("sync_dir".into())) {
        None | Some(Yaml::Null) => return Ok(dir.join("sync")),
        Some(Yaml::String(v)) => PathBuf::from(v),
        Some(other) => {
            return Err(io::Error::other(format!(
                "installation.yaml's sync_dir {other:?} isn't a path"
            )))
        }
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
    let id = installation(dir)
        .ok()?
        .get(&Yaml::String("installation_id".into()))?
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
        // An older Configurator's learning off (#374): another setting's save keeps it, as learning may
        // not be in sebtype.conf yet; drop_old_learning removes it.
        let old = format!("{setup}  {OLD_LEARNING_OFF}\n");
        fs::write(d.join(SCHEMA_PATCH), &old).unwrap();
        assert!(old_learning_off(&d));
        assert!(!save(
            &d,
            &Chinese {
                page_size: 7,
                ..Chinese::default()
            }
        )
        .unwrap());
        assert!(old_learning_off(&d));
        assert!(drop_old_learning(&d).unwrap());
        assert!(!old_learning_off(&d));
        assert!(!drop_old_learning(&d).unwrap());
        assert_eq!(read(&d.join(SCHEMA_PATCH)), setup);
        // One written by hand, without SebType's comment, is the person's own: kept (#374).
        let own = format!("{setup}  translator/enable_user_dict: false\n");
        fs::write(d.join(SCHEMA_PATCH), &own).unwrap();
        assert!(!old_learning_off(&d));
        assert!(!drop_old_learning(&d).unwrap());
        assert_eq!(read(&d.join(SCHEMA_PATCH)), own);
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn words_go_after_rime_ices_phrases_and_forget_keeps_them() {
        let d = temp("words");
        fs::write(d.join(PHRASES), "# rime-ice\n你好\tnihao\t1\n").unwrap();
        let w = vec![Word {
            word: "小明".into(),
            pinyin: normalize_pinyin("Xiao'Ming"),
            ..Default::default()
        }];
        save_words(&d, &w).unwrap();
        assert_eq!(words(&d), w);
        // The window's row: the nth entry the same as w, in My words as shown (read now).
        let at = |w: &Word, n: usize| {
            let shown = words(&d);
            let i = (0..shown.len())
                .filter(|&i| shown[i].same(w))
                .nth(n)
                .unwrap();
            (shown, i)
        };
        let edit = |old: &Word, n, new| {
            let (shown, i) = at(old, n);
            // The list written comes back, for the window to show.
            assert_eq!(edit_word(&d, &shown, i, new).unwrap(), Ok(words(&d)));
        };
        let remove = |old: &Word, n| {
            let (shown, i) = at(old, n);
            assert!(remove_word(&d, &shown, i).unwrap());
        };
        // Add and remove work on the file as the sync left it, not on the window's list, and Add returns
        // that file's list for the window to show.
        let other = Word {
            word: "噗莫".into(),
            pinyin: "pumo".into(),
            ..Default::default()
        };
        let added = add_word(&d, other.clone()).unwrap();
        assert_eq!(added, [w[0].clone(), other.clone()]);
        assert_eq!(words(&d), added);
        remove(&w[0], 0);
        assert_eq!(words(&d), [other.clone()]);
        // Edit (#410) keeps the word's place; a word edited into one already there leaves one entry.
        add_word(&d, w[0].clone()).unwrap();
        let lin = Word {
            word: "小林".into(),
            pinyin: "xiaolin".into(),
            ..Default::default()
        };
        edit(&other, 0, lin.clone());
        assert_eq!(words(&d), [lin.clone(), w[0].clone()]);
        edit(&lin, 0, w[0].clone());
        assert_eq!(words(&d), [w[0].clone()]);
        // My words changed since they were shown (the sync took one out): Edit and Delete change nothing,
        // as the row may be another word now.
        let shown = [other.clone(), w[0].clone()];
        // Edit returns them as they are now, for the window to show behind the draft.
        assert_eq!(
            edit_word(&d, &shown, 1, lin.clone()).unwrap(),
            Err(vec![w[0].clone()])
        );
        assert!(!remove_word(&d, &shown, 1).unwrap());
        assert_eq!(words(&d), [w[0].clone()]);
        add_word(&d, lin.clone()).unwrap();
        assert_eq!(words(&d), [w[0].clone(), lin.clone()]);
        // What else the lines have (a weight, comments between them) stays through Edit and Add.
        let head = "# rime-ice\n你好\tnihao\t1\n";
        fs::write(
            d.join(PHRASES),
            format!("{head}{MARKER}\n# from the phone\n小明\txiaoming\t9\n小林\txiaolin\n# end\n"),
        )
        .unwrap();
        let lin2 = Word {
            word: "小琳".into(),
            pinyin: "xiaolin".into(),
            ..Default::default()
        };
        edit(&lin, 0, lin2);
        assert_eq!(add_word(&d, other.clone()).unwrap(), words(&d));
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n# from the phone\n小明\txiaoming\t9\n小琳\txiaolin\n噗莫\tpumo\n# end\n")
        );
        save_words(&d, &[]).unwrap();
        assert_eq!(read(&d.join(PHRASES)), format!("{head}{MARKER}\n# end\n"));
        // Of two identical rows, Edit and Delete change the one chosen (its occurrence), with its own line.
        let ming = w[0].clone();
        let mings = format!("{head}{MARKER}\n小明\txiaoming\t1\n小明\txiaoming\t2\n");
        fs::write(d.join(PHRASES), &mings).unwrap();
        let min = Word {
            word: "小敏".into(),
            pinyin: "xiaomin".into(),
            ..Default::default()
        };
        edit(&ming, 1, min);
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n小明\txiaoming\t1\n小敏\txiaomin\t2\n")
        );
        fs::write(d.join(PHRASES), &mings).unwrap();
        remove(&ming, 1);
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n小明\txiaoming\t1\n")
        );
        // A comment line stays when the word under it goes: over the next word, or at the end.
        let noted =
            format!("{head}{MARKER}\n# section note\n小明\txiaoming\n# lin\n小林\txiaolin\n");
        fs::write(d.join(PHRASES), &noted).unwrap();
        remove(&ming, 0);
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n# section note\n# lin\n小林\txiaolin\n")
        );
        fs::write(d.join(PHRASES), &noted).unwrap();
        edit(&lin, 0, ming.clone()); // 小林 into 小明, which goes
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n# section note\n# lin\n小明\txiaoming\n")
        );
        fs::write(d.join(PHRASES), &noted).unwrap();
        remove(&lin, 0);
        assert_eq!(
            read(&d.join(PHRASES)),
            format!("{head}{MARKER}\n# section note\n小明\txiaoming\n# lin\n")
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
            // Rime's lookup matches names in any case on Windows only.
            ("ghi/LUNA.USERDB.TXT", snapshot, cfg!(unix)),
            ("ghi/ZH_MY_WORDS.USERDB.TXT", snapshot, true),
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
        // Two devices' snapshots, and on Unix a linked device's, on Windows an upper-case one.
        assert_eq!(forget(&d).unwrap(), 3);
        for (name, _, kept) in files {
            assert_eq!(home.join(name).exists(), kept, "{name}");
        }
        #[cfg(unix)]
        {
            assert!(!elsewhere.join("rime_ice.userdb.txt").exists());
            // One it can't read may merge back once it can: forgetting fails and deletes nothing.
            use std::os::unix::fs::PermissionsExt;
            let locked = home.join("abc/rime_ice.userdb.txt");
            fs::write(&locked, snapshot).unwrap();
            fs::write(home.join("def/luna_pinyin.userdb.txt"), snapshot).unwrap();
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
            if fs::File::open(&locked).is_err() {
                // (root reads it anyway)
                let e = forget(&d).unwrap_err();
                assert!(e.to_string().contains("abc"), "{e}");
                assert!(home.join("def/luna_pinyin.userdb.txt").exists());
            }
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).unwrap();
        }

        // Quoted as YAML quotes (a backslash escaped in double quotes); Rime's default only when there is
        // no sync_dir or it is null; anything else refused: a path Rime would take from its working
        // directory, a value that isn't a text, a key twice, or a file that isn't one YAML mapping.
        let path = home.display().to_string();
        let escaped = path.replace('\\', "\\\\");
        for (yaml, want) in [
            (format!("sync_dir: '{path}'"), Some(home.clone())),
            (format!("sync_dir: \"{escaped}\""), Some(home.clone())),
            (format!("sync_dir: !!str '{path}'"), Some(home.clone())),
            ("sync_dir: ~".into(), Some(d.join("sync"))),
            ("sync_dir: null".into(), Some(d.join("sync"))),
            ("installation_id: abc".into(), Some(d.join("sync"))),
            ("".into(), Some(d.join("sync"))),
            ("sync_dir: sync".into(), None),
            ("sync_dir: ~/sync".into(), None),
            ("sync_dir: \"\"".into(), None),
            (format!("sync_dir: !!int {path}"), None),
            ("sync_dir: 5".into(), None),
            (format!("sync_dir: ['{path}']"), None),
            (format!("sync_dir: '{path}'\nsync_dir: '{path}'"), None),
            (format!("sync_dir: '{path}'\n---\n["), None),
            (format!("sync_dir: '{path}'\n---\na: b"), None),
            (format!("- sync_dir: '{path}'"), None),
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
            format!("sync_dir: '{}'\n", d.join("sync").display()),
        )
        .unwrap();
        assert_eq!(learned(&d).unwrap().len(), 1);
        for f in [&home, &elsewhere] {
            fs::remove_dir_all(f).unwrap();
        }
        fs::remove_dir_all(&d).unwrap();
    }
}
