// SebType Configurator (#72): SebType's settings on the PC. It keeps no settings file of its own: every
// value is read from, and written to, the engines' own files (the ones setup-ime sets up), then the
// engine is redeployed or restarted.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod mozc;
mod patch;
mod proto;
mod rime;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
use windows as platform;

use serde::{Deserialize, Serialize};
use slint::{ComponentHandle, Model, ModelRc, VecModel};
use std::{rc::Rc, sync::mpsc, time::Duration};

slint::include_modules!();

/// The candidate window's look, as the platform draws it (page size is Rime's, in rime::Chinese).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidates {
    pub vertical: bool,
    pub font_size: i32,
    pub picnic: bool,
}

/// What Export settings writes and Import settings reads.
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Backup {
    sebtype_configurator: u32,
    languages: Vec<(String, bool)>,
    chinese: rime::Chinese,
    japanese: mozc::Japanese,
    candidates: Candidates,
    chinese_words: Vec<rime::Word>,
    japanese_words: Vec<mozc::Word>,
}

fn lang_row(id: &str, on: bool) -> Lang {
    Lang { id: id.into(), on }
}

/// The window's language: the system's when it is 中文 or 日本語, else English (#118). Slint picks the
/// same one by itself; choosing it here keeps the font in step with it.
fn language() -> &'static str {
    let system = sys_locale::get_locale().unwrap_or_default();
    ["zh", "ja"]
        .into_iter()
        .find(|l| system.starts_with(l))
        .unwrap_or("en")
}

struct Ui {
    langs: Rc<VecModel<Lang>>,
    fuzzy: Rc<VecModel<Fuzzy>>,
    zh_words: Rc<VecModel<ZhWord>>,
    ja_words: Rc<VecModel<JaWord>>,
}

thread_local! {
    static TOAST: slint::Timer = slint::Timer::default();
}

/// What a change did, worded by the window (app.slint), and the file or error it names.
type Toast = (Msg, String);

fn toast(app: &AppWindow, (msg, arg): Toast) {
    let state = app.global::<State>();
    state.set_toast(msg);
    state.set_toast_arg(arg.into());
    let weak = app.as_weak();
    TOAST.with(|t| {
        t.start(
            slint::TimerMode::SingleShot,
            Duration::from_millis(2600),
            move || {
                if let Some(app) = weak.upgrade() {
                    app.global::<State>().set_toast(Msg::None);
                }
            },
        )
    });
}

type Job = Box<dyn FnOnce() -> Result<Toast, Toast> + Send>;

/// Runs jobs one after another off the window's thread, and shows each one's outcome.
fn worker(weak: slint::Weak<AppWindow>) -> mpsc::Sender<Job> {
    let (tx, rx) = mpsc::channel::<Job>();
    std::thread::spawn(move || {
        for job in rx {
            let (Ok(t) | Err(t)) = job();
            if t.0 != Msg::None {
                let _ = weak.upgrade_in_event_loop(move |app| toast(&app, t));
            }
        }
    });
    tx
}

fn say(msg: Msg) -> Toast {
    (msg, String::new())
}
fn err(e: impl std::fmt::Display) -> Toast {
    (Msg::Failed, e.to_string())
}

fn chinese(s: &State, ui: &Ui) -> rime::Chinese {
    rime::Chinese {
        traditional: s.get_zh_script() == 1,
        full_width_punctuation: s.get_zh_full_punct(),
        emoji: s.get_zh_emoji(),
        fuzzy: ui.fuzzy.iter().map(|f| f.on).collect(),
        learn: s.get_learn(),
        page_size: s.get_page_size(),
    }
}
fn japanese(s: &State) -> mozc::Japanese {
    mozc::Japanese {
        half_width_space: s.get_ja_half_space(),
        learn: s.get_learn(),
    }
}
fn candidates(s: &State) -> Candidates {
    Candidates {
        vertical: s.get_vertical(),
        font_size: s.get_font_size(),
        picnic: s.get_picnic(),
    }
}
fn langs(ui: &Ui) -> Vec<(String, bool)> {
    ui.langs.iter().map(|l| (l.id.to_string(), l.on)).collect()
}

fn apply_chinese(c: rime::Chinese) -> Result<Toast, Toast> {
    if rime::save(&platform::rime_dir(), &c).map_err(err)? {
        platform::redeploy_rime().map_err(err)?;
        return Ok(say(Msg::ZhRedeployed));
    }
    Ok(say(Msg::Applied))
}
fn apply_japanese(j: mozc::Japanese) -> Result<Toast, Toast> {
    if mozc::save(&platform::mozc_dir(), &j).map_err(err)? {
        platform::restart_mozc();
    }
    Ok(say(Msg::JaNextTime))
}

fn set_langs_model(app: &AppWindow, ui: &Ui, list: Vec<(String, bool)>) {
    ui.langs.set_vec(
        list.iter()
            .map(|(id, on)| lang_row(id, *on))
            .collect::<Vec<_>>(),
    );
    refresh_langs(app, ui);
    app.global::<State>().set_langs_ready(true);
}
fn refresh_langs(app: &AppWindow, ui: &Ui) {
    app.global::<State>()
        .set_langs_on(ui.langs.iter().filter(|l| l.on).count() as i32);
}
fn refresh_fuzzy(app: &AppWindow, ui: &Ui) {
    let on: Vec<String> = ui
        .fuzzy
        .iter()
        .filter(|f| f.on)
        .map(|f| f.label.to_string())
        .collect();
    app.global::<State>()
        .set_fuzzy_summary(on.join(" · ").into());
}

/// Reads every setting from the engines' files into the window.
fn load(app: &AppWindow, ui: &Ui) {
    let s = app.global::<State>();
    let (rime_dir, mozc_dir) = (platform::rime_dir(), platform::mozc_dir());
    s.set_zh_available(rime_dir.is_dir());
    s.set_ja_available(mozc_dir.is_dir());
    let c = rime::load(&rime_dir);
    let j = mozc::load(&mozc_dir).unwrap_or_default();
    s.set_zh_script(i32::from(c.traditional));
    s.set_zh_full_punct(c.full_width_punctuation);
    s.set_zh_emoji(c.emoji);
    s.set_page_size(c.page_size.clamp(5, 9));
    s.set_learn(if rime_dir.is_dir() { c.learn } else { j.learn });
    s.set_ja_half_space(j.half_width_space);
    ui.fuzzy.set_vec(
        (0..rime::FUZZY.len())
            .map(|i| Fuzzy {
                label: rime::fuzzy_label(i).into(),
                on: c.fuzzy[i],
            })
            .collect::<Vec<_>>(),
    );
    refresh_fuzzy(app, ui);
    ui.zh_words.set_vec(
        rime::words(&rime_dir)
            .into_iter()
            .map(|w| ZhWord {
                word: w.word.into(),
                code: w.pinyin.into(),
            })
            .collect::<Vec<_>>(),
    );
    ui.ja_words.set_vec(
        mozc::words(&mozc_dir)
            .unwrap_or_default()
            .into_iter()
            .map(|w| JaWord {
                reading: w.reading.into(),
                word: w.word.into(),
                pos: w.pos as i32,
            })
            .collect::<Vec<_>>(),
    );
    let k = platform::candidates();
    s.set_vertical(k.vertical);
    s.set_font_size(k.font_size);
    s.set_picnic(k.picnic);
}

fn zh_words(ui: &Ui) -> Vec<rime::Word> {
    ui.zh_words
        .iter()
        .map(|w| rime::Word {
            word: w.word.into(),
            pinyin: w.code.into(),
        })
        .collect()
}
fn ja_words(ui: &Ui) -> Vec<mozc::Word> {
    ui.ja_words
        .iter()
        .map(|w| mozc::Word {
            reading: w.reading.into(),
            word: w.word.into(),
            pos: w.pos as usize,
        })
        .collect()
}

fn export(backup: Backup, file: String) -> Result<Toast, Toast> {
    let Some(path) = rfd::FileDialog::new()
        .set_file_name(file)
        .add_filter("JSON", &["json"])
        .save_file()
    else {
        return Ok(say(Msg::None));
    };
    std::fs::write(&path, serde_json::to_string_pretty(&backup).map_err(err)?).map_err(err)?;
    Ok((Msg::Exported, path.display().to_string()))
}

fn import() -> Result<Option<Backup>, Toast> {
    let Some(path) = rfd::FileDialog::new()
        .add_filter("JSON", &["json"])
        .pick_file()
    else {
        return Ok(None);
    };
    let b: Backup =
        serde_json::from_str(&std::fs::read_to_string(path).map_err(err)?).map_err(err)?;
    if b.sebtype_configurator != 1 {
        return Err(say(Msg::NotABackup));
    }
    let (rime_dir, mozc_dir) = (platform::rime_dir(), platform::mozc_dir());
    if rime_dir.is_dir() {
        rime::save(&rime_dir, &b.chinese).map_err(err)?;
        rime::save_words(&rime_dir, &b.chinese_words).map_err(err)?;
        platform::redeploy_rime().map_err(err)?;
    }
    if mozc_dir.is_dir() {
        mozc::save(&mozc_dir, &b.japanese).map_err(err)?;
        mozc::save_words(&mozc_dir, &b.japanese_words).map_err(err)?;
        platform::restart_mozc();
    }
    platform::set_candidates(&b.candidates).map_err(err)?;
    if !b.languages.is_empty() {
        platform::set_langs(&b.languages).map_err(err)?;
    }
    Ok(Some(b))
}

fn main() -> Result<(), slint::PlatformError> {
    // Wayland matches the window to its launcher (and icon) by this id: sebtype-configurator.desktop.
    slint::BackendSelector::new().select()?;
    slint::set_xdg_app_id("sebtype-configurator")?;
    let app = AppWindow::new()?;
    let lang = language();
    let _ = slint::select_bundled_translation(lang);
    let ui = Rc::new(Ui {
        langs: Rc::new(VecModel::default()),
        fuzzy: Rc::new(VecModel::default()),
        zh_words: Rc::new(VecModel::default()),
        ja_words: Rc::new(VecModel::default()),
    });
    let s = app.global::<State>();
    s.set_version(env!("CARGO_PKG_VERSION").into());
    s.set_system(platform::SYSTEM.into());
    s.set_ui_font(platform::ui_font(lang).into());
    s.set_langs(ModelRc::from(ui.langs.clone()));
    s.set_fuzzy(ModelRc::from(ui.fuzzy.clone()));
    s.set_zh_words(ModelRc::from(ui.zh_words.clone()));
    s.set_ja_words(ModelRc::from(ui.ja_words.clone()));
    ui.langs
        .set_vec(["en", "zh", "ja"].map(|id| lang_row(id, true)).to_vec());
    load(&app, &ui);
    UI.with(|u| *u.borrow_mut() = Some(ui.clone()));

    // For screenshots and tests: --page N (0 Languages … 5 About) and --sub N open that screen.
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1)?.parse().ok())
    };
    let nav = app.global::<Nav>();
    if let Some(p) = arg("--page") {
        nav.set_page(p);
    }
    if let Some(p) = arg("--sub") {
        nav.set_sub(p);
    }

    let jobs = worker(app.as_weak());
    let run = {
        let jobs = jobs.clone();
        move |job: Job| {
            let _ = jobs.send(job);
        }
    };

    // The language list can take a second to read on Windows (PowerShell), so it comes in after the window.
    {
        let weak = app.as_weak();
        run(Box::new(move || {
            let list = platform::langs().map_err(err)?;
            let _ = weak
                .upgrade_in_event_loop(move |app| with_ui(|ui| set_langs_model(&app, ui, list)));
            Ok(say(Msg::None))
        }));
    }

    s.on_set_lang({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i, on| {
            let mut row = ui.langs.row_data(i as usize).unwrap();
            row.on = on;
            ui.langs.set_row_data(i as usize, row);
            refresh_langs(&weak.unwrap(), &ui);
            let list = langs(&ui);
            run(Box::new(move || {
                platform::set_langs(&list)
                    .map(|_| say(Msg::Applied))
                    .map_err(err)
            }));
        }
    });
    s.on_move_lang({
        let (ui, run) = (ui.clone(), run.clone());
        move |from, to| {
            let row = ui.langs.remove(from as usize);
            ui.langs.insert(to as usize, row);
            let list = langs(&ui);
            run(Box::new(move || {
                platform::set_langs(&list)
                    .map(|_| say(Msg::Applied))
                    .map_err(err)
            }));
        }
    });
    s.on_zh_changed({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move || {
            let c = chinese(&weak.unwrap().global::<State>(), &ui);
            run(Box::new(move || apply_chinese(c)));
        }
    });
    s.on_fuzzy_changed({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i, on| {
            let mut row = ui.fuzzy.row_data(i as usize).unwrap();
            row.on = on;
            ui.fuzzy.set_row_data(i as usize, row);
            let app = weak.unwrap();
            refresh_fuzzy(&app, &ui);
            let c = chinese(&app.global::<State>(), &ui);
            run(Box::new(move || apply_chinese(c)));
        }
    });
    s.on_learn_changed({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move || {
            let app = weak.unwrap();
            let (c, j) = (
                chinese(&app.global::<State>(), &ui),
                japanese(&app.global::<State>()),
            );
            run(Box::new(move || {
                if platform::mozc_dir().is_dir() {
                    apply_japanese(j)?;
                }
                if platform::rime_dir().is_dir() {
                    return apply_chinese(c);
                }
                Ok(say(Msg::Applied))
            }));
        }
    });
    s.on_ja_changed({
        let (weak, run) = (app.as_weak(), run.clone());
        move || {
            let j = japanese(&weak.unwrap().global::<State>());
            run(Box::new(move || apply_japanese(j)));
        }
    });
    s.on_candidates_changed({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move || {
            let app = weak.unwrap();
            let (c, k) = (
                chinese(&app.global::<State>(), &ui),
                candidates(&app.global::<State>()),
            );
            run(Box::new(move || {
                let deployed = rime::save(&platform::rime_dir(), &c).map_err(err)?;
                platform::set_candidates(&k).map_err(err)?;
                if deployed {
                    platform::redeploy_rime().map_err(err)?;
                }
                Ok(say(Msg::Applied))
            }));
        }
    });
    s.on_theme_changed({
        let (weak, run) = (app.as_weak(), run.clone());
        move || {
            let k = candidates(&weak.unwrap().global::<State>());
            run(Box::new(move || {
                platform::set_candidates(&k)
                    .map(|_| say(Msg::ThemeNextTime))
                    .map_err(err)
            }));
        }
    });
    s.on_add_zh_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |word, code| {
            let pinyin = rime::normalize_pinyin(&code);
            if !rime::valid_word(&word, &pinyin) {
                toast(&weak.unwrap(), say(Msg::PinyinLettersOnly));
                return false;
            }
            ui.zh_words.push(ZhWord {
                word: word.trim().into(),
                code: pinyin.into(),
            });
            let words = zh_words(&ui);
            run(Box::new(move || {
                rime::save_words(&platform::rime_dir(), &words).map_err(err)?;
                platform::redeploy_rime().map_err(err)?;
                Ok(say(Msg::SavedZh))
            }));
            true
        }
    });
    s.on_remove_zh_word({
        let (ui, run) = (ui.clone(), run.clone());
        move |i| {
            ui.zh_words.remove(i as usize);
            let words = zh_words(&ui);
            run(Box::new(move || {
                rime::save_words(&platform::rime_dir(), &words).map_err(err)?;
                platform::redeploy_rime().map_err(err)?;
                Ok(say(Msg::DeletedZh))
            }));
        }
    });
    s.on_add_ja_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |reading, word, pos| {
            if !mozc::valid_word(&reading, &word) {
                toast(&weak.unwrap(), say(Msg::ReadingHiraganaOnly));
                return false;
            }
            ui.ja_words.push(JaWord {
                reading,
                word: word.trim().into(),
                pos,
            });
            let words = ja_words(&ui);
            run(Box::new(move || {
                mozc::save_words(&platform::mozc_dir(), &words).map_err(err)?;
                platform::restart_mozc();
                Ok(say(Msg::SavedJa))
            }));
            true
        }
    });
    s.on_remove_ja_word({
        let (ui, run) = (ui.clone(), run.clone());
        move |i| {
            ui.ja_words.remove(i as usize);
            let words = ja_words(&ui);
            run(Box::new(move || {
                mozc::save_words(&platform::mozc_dir(), &words).map_err(err)?;
                platform::restart_mozc();
                Ok(say(Msg::Deleted))
            }));
        }
    });
    s.on_forget({
        let run = run.clone();
        move |lang| {
            run(Box::new(move || {
                let n = if lang == "zh" {
                    platform::forget_rime()
                } else {
                    platform::forget_mozc()
                }
                .map_err(err)?;
                Ok(say(if n == 0 {
                    Msg::NothingLearned
                } else {
                    Msg::Forgotten
                }))
            }));
        }
    });
    s.on_export_settings({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move || {
            let app = weak.unwrap();
            let st = app.global::<State>();
            let b = Backup {
                sebtype_configurator: 1,
                languages: langs(&ui),
                chinese: chinese(&st, &ui),
                japanese: japanese(&st),
                candidates: candidates(&st),
                chinese_words: zh_words(&ui),
                japanese_words: ja_words(&ui),
            };
            let file = st.get_backup_file().into();
            run(Box::new(move || export(b, file)));
        }
    });
    s.on_import_settings({
        let (weak, run) = (app.as_weak(), run.clone());
        move || {
            let weak = weak.clone();
            run(Box::new(move || {
                let Some(b) = import()? else {
                    return Ok(say(Msg::None));
                };
                let _ =
                    weak.upgrade_in_event_loop(move |app| reload_after_import(&app, b.languages));
                Ok(say(Msg::Imported))
            }));
        }
    });
    s.on_redeploy({
        let run = run.clone();
        move || {
            run(Box::new(|| {
                platform::redeploy_rime().map_err(err)?;
                platform::restart_mozc();
                Ok(say(Msg::Redeployed))
            }))
        }
    });
    s.on_open_help(|| platform::open_url("https://github.com/S-Sebb/SebType/issues"));

    app.run()
}

thread_local! {
    // The window's models, for results that come back from the worker thread.
    static UI: std::cell::RefCell<Option<Rc<Ui>>> = const { std::cell::RefCell::new(None) };
}

fn with_ui(f: impl FnOnce(&Ui)) {
    UI.with(|u| f(u.borrow().as_ref().unwrap()));
}

fn reload_after_import(app: &AppWindow, languages: Vec<(String, bool)>) {
    with_ui(|ui| {
        load(app, ui);
        if !languages.is_empty() {
            set_langs_model(app, ui, languages);
        }
    });
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, fs, path::Path};

    /// What the window shows the same in every language: names, keys, licences and the sample candidates.
    #[rustfmt::skip]
    const SAME_IN_EVERY_LANGUAGE: &[&str] = &[
        "SebType", "English", "中文", "日本語", " · 中文", " · 日本語", "zh", "ja", "Windows", "简体", "繁體", "Picnic",
        "Mozc", "Nunito", "Win+Space", "Shift", "Alt+`", "Ctrl+Shift+F", "日本語 あ ⇄ ア", "中文 简 ⇄ 繁", "Win+V",
        "Klipper", "A−", "A+", "小明", "xiaoming", "せぶ → SebType", "ni hao", "你好", "拟好", "你", "呢", "泥", "尼",
        "妮", "倪", "雾凇拼音 rime-ice · 白霜拼音 rime-frost", "Rime (librime)", " · 小狼毫 Weasel",
        " · Fcitx5 · fcitx5-rime", "GPL-3.0", "BSD-3-Clause", "BSD-3-Clause · GPL-3.0",
        "BSD-3-Clause · LGPL-2.1+", "SIL Open Font License 1.1", ".json",
    ];

    /// The string literals of a .slint file that the window can show, each with whether it is the
    /// English of an @tr.
    fn literals(src: &str) -> Vec<(String, bool)> {
        let (mut out, mut rest) = (vec![], src);
        while let Some(i) = rest.find(['"', '/']) {
            if rest[i..].starts_with("//") {
                rest = rest[i..].find('\n').map_or("", |n| &rest[i + n..]);
                continue;
            }
            if rest[i..].starts_with('/') {
                rest = &rest[i + 1..];
                continue;
            }
            let before = rest[..i].trim_end();
            let (mut s, mut chars, mut end) =
                (String::new(), rest[i + 1..].char_indices(), rest.len());
            while let Some((j, c)) = chars.next() {
                match c {
                    '\\' => s.extend(chars.next().map(|(_, e)| e)),
                    '"' => {
                        end = i + 2 + j;
                        break;
                    }
                    c => s.push(c),
                }
            }
            if !["import", "from", "@image-url("]
                .iter()
                .any(|k| before.ends_with(k))
            {
                out.push((s, before.ends_with("@tr(")));
            }
            rest = &rest[end..];
        }
        out
    }

    /// msgid → msgstr of a .po file.
    fn catalog(po: &str) -> BTreeMap<String, String> {
        let unquote = |l: &str| {
            l.trim()
                .trim_matches('"')
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
        };
        let (mut map, mut id, mut text, mut in_id) =
            (BTreeMap::new(), String::new(), String::new(), false);
        for line in po.lines().chain(["msgid \"\""]) {
            if let Some(rest) = line.strip_prefix("msgid ") {
                if !id.is_empty() {
                    map.insert(std::mem::take(&mut id), std::mem::take(&mut text));
                }
                (id, text, in_id) = (unquote(rest), String::new(), true);
            } else if let Some(rest) = line.strip_prefix("msgstr ") {
                (text, in_id) = (unquote(rest), false);
            } else if line.starts_with('"') {
                if in_id {
                    id += &unquote(line)
                } else {
                    text += &unquote(line)
                }
            }
        }
        map
    }

    #[test]
    fn every_string_is_translated() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let (mut english, mut untranslated) = (vec![], vec![]);
        for f in fs::read_dir(dir.join("ui")).unwrap() {
            let path = f.unwrap().path();
            if path.extension().is_some_and(|e| e == "slint") {
                for (s, tr) in literals(&fs::read_to_string(&path).unwrap()) {
                    if tr {
                        if !english.contains(&s) {
                            english.push(s);
                        }
                    } else if s.chars().any(char::is_alphabetic)
                        && !SAME_IN_EVERY_LANGUAGE.contains(&s.as_str())
                    {
                        untranslated.push(format!("{}: {s:?} is not in @tr", path.display()));
                    }
                }
            }
        }
        assert!(
            english.len() > 100,
            "found only {} @tr strings",
            english.len()
        );
        for lang in ["zh", "ja"] {
            let po = dir.join(format!("lang/{lang}/LC_MESSAGES/sebtype-configurator.po"));
            let cat = catalog(&fs::read_to_string(&po).unwrap());
            for s in &english {
                let t = cat.get(s).map_or("", String::as_str);
                if t.is_empty() {
                    untranslated.push(format!("{lang}: {s:?} has no translation"));
                } else if t.matches("{}").count() != s.matches("{}").count() {
                    untranslated.push(format!("{lang}: {t:?} has other {{}} than {s:?}"));
                }
            }
            untranslated.extend(
                cat.keys()
                    .filter(|k| !english.contains(k))
                    .map(|k| format!("{lang}: {k:?} is no longer in the window")),
            );
        }
        assert!(untranslated.is_empty(), "\n{}", untranslated.join("\n"));
    }
}
