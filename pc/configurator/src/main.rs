// SebType Configurator (#72): SebType's settings on the PC. It keeps no settings file of its own: every
// value is read from, and written to, the engines' own files (the ones setup-ime sets up) or SebType's
// sebtype.conf, then the engine is redeployed, restarted or told.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod conf;
mod migrate;
mod mozc;
mod patch;
mod proto;
mod rime;
mod sync;
mod update;

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
    /// The Privacy switch (#374). A backup from before it has it as chinese.learn and japanese.learn.
    learning: Option<bool>,
}

/// A backup's settings, learning from an older one's engine settings.
fn parse_backup(text: &str) -> serde_json::Result<Backup> {
    let v: serde_json::Value = serde_json::from_str(text)?;
    let old = ["chinese", "japanese"]
        .iter()
        .find_map(|e| v[e]["learn"].as_bool());
    let mut b: Backup = serde_json::from_value(v)?;
    b.learning = b.learning.or(old);
    Ok(b)
}

/// Writes `data` unless the file already holds it; true when it wrote. Through a file renamed over it, so a
/// write cut off leaves the old file whole: never one cut short.
pub fn write_file(path: &std::path::Path, data: impl AsRef<[u8]>) -> std::io::Result<bool> {
    let data = data.as_ref();
    if std::fs::read(path).ok().as_deref() == Some(data) {
        return Ok(false);
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".sebtype-tmp");
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)?;
    Ok(true)
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
/// msgid → msgstr of a .po file.
fn catalog(po: &str) -> std::collections::BTreeMap<String, String> {
    let unquote = |l: &str| {
        l.trim()
            .trim_matches('"')
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
    };
    let (mut map, mut id, mut text, mut in_id) = (
        std::collections::BTreeMap::new(),
        String::new(),
        String::new(),
        false,
    );
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

/// A window string in the window's language, for text shown outside it (the update's notification): the
/// same translations, from lang/.
fn tr(english: &str) -> String {
    let po = match language() {
        "zh" => include_str!("../lang/zh/LC_MESSAGES/sebtype-configurator.po"),
        "ja" => include_str!("../lang/ja/LC_MESSAGES/sebtype-configurator.po"),
        _ => return english.into(),
    };
    catalog(po)
        .remove(english)
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| english.into())
}

struct Ui {
    langs: Rc<VecModel<Lang>>,
    fuzzy: Rc<VecModel<Fuzzy>>,
    zh_words: Rc<VecModel<ZhWord>>,
    ja_words: Rc<VecModel<JaWord>>,
    // My words as the lists show them, with what else each entry has: Edit and Delete change the file
    // only while it still holds them (rime::edit_word).
    zh_shown: std::cell::RefCell<Vec<rime::Word>>,
    ja_shown: std::cell::RefCell<Vec<mozc::Word>>,
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
        page_size: s.get_page_size(),
    }
}
fn japanese(s: &State) -> mozc::Japanese {
    mozc::Japanese {
        half_width_space: s.get_ja_half_space(),
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

/// Learning in sebtype.conf, which the input method applies at once. Then an older Configurator's learning
/// off in Rime's and Mozc's own settings, which hid the learned words too (#374), goes: only once the
/// input method has the choice, or the engine it restarts would learn.
fn apply_learning(on: bool) -> std::io::Result<()> {
    platform::set_learning(on)?;
    drop_old_learning()
}
/// The engines read their settings again once typing is idle, as a sync's pull has them do (#373): a
/// start of the Configurator, or a scheduled sync, keeps what is being typed.
fn drop_old_learning() -> std::io::Result<()> {
    let pending = platform::sebtype_dir().join("learning-migration-pending");
    migrate::drop_old(
        &platform::rime_dir(),
        &platform::mozc_dir(),
        &pending,
        |e| match e {
            migrate::Engine::Rime => platform::queue_rime_redeploy(),
            migrate::Engine::Mozc => platform::restart_mozc_when_idle(),
        },
    )
}
/// An older Configurator's learning off moves into sebtype.conf (#374): at every start, before anything
/// saves Rime's or Mozc's settings, and from setup (--migrate) on an upgrade. A refresh left from one that
/// didn't finish is retried.
fn migrate_learning() -> std::io::Result<()> {
    if migrate::old_learning_off(&platform::rime_dir(), &platform::mozc_dir()) {
        return apply_learning(false);
    }
    drop_old_learning()
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
    // Off too while an older Configurator's learning off stays (its migration failed).
    s.set_learn(platform::learning() && !migrate::old_learning_off(&rime_dir, &mozc_dir));
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
    show_words(ui);
    let k = platform::candidates();
    s.set_vertical(k.vertical);
    s.set_font_size(k.font_size);
    s.set_picnic(k.picnic);
}

/// Shows My words as the files hold them now.
fn show_words(ui: &Ui) {
    show_zh(ui, rime::words(&platform::rime_dir()));
    show_ja(ui, mozc::words(&platform::mozc_dir()).unwrap_or_default());
}

fn show_zh(ui: &Ui, words: Vec<rime::Word>) {
    ui.zh_words.set_vec(
        words
            .iter()
            .map(|w| ZhWord {
                word: w.word.as_str().into(),
                code: w.pinyin.as_str().into(),
            })
            .collect::<Vec<_>>(),
    );
    *ui.zh_shown.borrow_mut() = words;
}

fn show_ja(ui: &Ui, words: Vec<mozc::Word>) {
    ui.ja_words.set_vec(
        words
            .iter()
            .map(|w| JaWord {
                reading: w.reading.as_str().into(),
                word: w.word.as_str().into(),
                pos: w.pos as i32,
            })
            .collect::<Vec<_>>(),
    );
    *ui.ja_shown.borrow_mut() = words;
}

/// The outcome of a Delete in the file: when My words had changed since they were shown, nothing
/// was saved, and the lists show them as they are now.
fn saved_or_reload(weak: &slint::Weak<AppWindow>, saved: bool) -> Result<(), Toast> {
    if saved {
        return Ok(());
    }
    let _ = weak.upgrade_in_event_loop(|_| with_ui(show_words));
    Err(say(Msg::WordsChanged))
}

/// The outcome of an Edit in the file, for the window: saved, the list written shows and the editor
/// closes. Otherwise the lists show My words as they are now and the editor stays open, with its draft,
/// on the row edited, for Save to try again; when that row is gone, the draft goes into Add (to_add).
fn edited<W: PartialEq + Send + 'static>(
    weak: &slint::Weak<AppWindow>,
    outcome: Result<Vec<W>, Vec<W>>,
    old: W,
    show: fn(&Ui, Vec<W>),
    set_editing: fn(&State, i32),
    to_add: impl FnOnce(&State) + Send + 'static,
) -> Result<(), Toast> {
    let (list, row, refused) = match outcome {
        Ok(list) => (list, -1, None),
        Err(now) => match now.iter().position(|w| *w == old) {
            Some(k) => (now, k as i32, Some(Msg::WordsChanged)),
            None => (now, -1, Some(Msg::WordGone)),
        },
    };
    let _ = weak.upgrade_in_event_loop(move |app| {
        let s = app.global::<State>();
        with_ui(|ui| show(ui, list));
        set_editing(&s, row);
        if refused == Some(Msg::WordGone) {
            to_add(&s);
        }
    });
    refused.map_or(Ok(()), |m| Err(say(m)))
}

/// Puts new at i as the only entry of its word: a word edited into one already there takes that one's
/// place. remove takes out the others.
fn put_in_place<T>(
    all: &mut Vec<T>,
    mut i: usize,
    new: T,
    same: impl Fn(&T, &T) -> bool,
    mut remove: impl FnMut(&mut Vec<T>, usize),
) {
    all[i] = new;
    while let Some(j) = (0..all.len()).find(|&j| j != i && same(&all[j], &all[i])) {
        remove(all, j);
        i -= usize::from(j < i);
    }
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
    let b = parse_backup(&std::fs::read_to_string(path).map_err(err)?).map_err(err)?;
    if b.sebtype_configurator != 1 {
        return Err(say(Msg::NotABackup));
    }
    let (rime_dir, mozc_dir) = (platform::rime_dir(), platform::mozc_dir());
    if rime_dir.is_dir() {
        rime::save(&rime_dir, &b.chinese).map_err(err)?;
        sync::words_locked(|| rime::save_words(&rime_dir, &b.chinese_words))
            .and_then(|r| r)
            .map_err(err)?;
        platform::redeploy_rime().map_err(err)?;
    }
    if mozc_dir.is_dir() {
        mozc::save(&mozc_dir, &b.japanese).map_err(err)?;
        sync::words_locked(|| mozc::save_words(&mozc_dir, &b.japanese_words))
            .and_then(|r| r)
            .map_err(err)?;
        platform::restart_mozc();
    }
    platform::set_candidates(&b.candidates).map_err(err)?;
    if !b.languages.is_empty() {
        platform::set_langs(&b.languages).map_err(err)?;
    }
    apply_learning(b.learning.unwrap_or(true)).map_err(err)?;
    Ok(Some(b))
}

/// Shows sync's switch, its status line and the login.
fn show_sync(app: &AppWindow, s: &sync::Sync, syncing: bool) {
    let st = app.global::<State>();
    st.set_sync_on(s.enabled);
    st.set_sync_server(s.server.trim_start_matches("https://").into());
    st.set_sync_user(s.user.as_str().into());
    st.set_sync_at(
        chrono::DateTime::from_timestamp(s.at, 0)
            .map(|t| {
                t.with_timezone(&chrono::Local)
                    .format("%Y-%m-%d %H:%M")
                    .to_string()
            })
            .unwrap_or_default()
            .into(),
    );
    st.set_sync_status(match (s.enabled, syncing, s.status) {
        (false, _, _) => SyncStatus::Off,
        (true, true, _) => SyncStatus::Syncing,
        (true, false, sync::Status::NotYet) => SyncStatus::NotYet,
        (true, false, sync::Status::Synced) => SyncStatus::Synced,
        (true, false, sync::Status::Offline) => SyncStatus::Offline,
        (true, false, sync::Status::LoginFailed) => SyncStatus::LoginFailed,
    });
}

/// Runs a sync step off the window's thread (a sync can take a while, so not on the settings' worker),
/// then syncs if sync is on, showing "Syncing…" meanwhile.
fn sync_job(
    weak: slint::Weak<AppWindow>,
    step: impl FnOnce() -> Result<sync::Sync, String> + Send + 'static,
) {
    std::thread::spawn(move || {
        let s = match step() {
            Ok(s) => s,
            Err(e) => {
                let s = sync::load();
                let _ = weak.upgrade_in_event_loop(move |app| {
                    show_sync(&app, &s, false);
                    toast(&app, err(e));
                });
                return;
            }
        };
        let shown = s.clone();
        let _ = weak.upgrade_in_event_loop(move |app| show_sync(&app, &shown, shown.enabled));
        if s.enabled {
            let s = sync::run(false).unwrap_or_else(|s| s);
            let _ = weak.upgrade_in_event_loop(move |app| show_sync(&app, &s, false));
        }
    });
}

/// The About page's update section, from the last check.
fn show_update(app: &AppWindow, u: &update::Update) {
    let st = app.global::<State>();
    st.set_update_auto(u.auto);
    st.set_update_checked(
        chrono::DateTime::from_timestamp(u.checked, 0)
            .map(|t| {
                t.with_timezone(&chrono::Local)
                    .format("%Y-%m-%d %H:%M")
                    .to_string()
            })
            .unwrap_or_default()
            .into(),
    );
    st.set_update_installed(platform::installed_version().into());
    // An update installed since the check isn't newer any more.
    let newer = update::newer(&platform::installed_version(), &u.latest);
    st.set_update_version(newer.clone().unwrap_or_default().into());
    st.set_update_status(match (newer, u.checked) {
        (Some(_), _) => UpdateStatus::Available,
        (None, 0) => UpdateStatus::None,
        (None, _) => UpdateStatus::UpToDate,
    });
}

fn set_update_status(weak: &slint::Weak<AppWindow>, status: UpdateStatus, error: String) {
    let _ = weak.upgrade_in_event_loop(move |app| {
        let st = app.global::<State>();
        st.set_update_status(status);
        st.set_update_error(error.into());
    });
}

/// Check now, off the window's thread.
fn check_updates(weak: slint::Weak<AppWindow>) {
    set_update_status(&weak, UpdateStatus::Checking, String::new());
    std::thread::spawn(move || match update::check_and_save() {
        Ok(_) => {
            let _ = weak.upgrade_in_event_loop(|app| show_update(&app, &update::load()));
        }
        Err(e) => set_update_status(&weak, UpdateStatus::Offline, e),
    });
}

/// Update…: the release's files, checked, then the system's installer with its admin prompt. On Windows
/// Setup replaces this exe, so the window closes once Setup has started.
fn install_update(weak: slint::Weak<AppWindow>) {
    set_update_status(&weak, UpdateStatus::Downloading, String::new());
    std::thread::spawn(move || {
        let installed = (|| {
            let (_, files) = update::check()?.ok_or("SebType is up to date".to_string())?;
            let dir = update::private_dir().map_err(|e| e.to_string())?;
            let installed = update::download(&files, &dir).and_then(|paths| {
                set_update_status(&weak, UpdateStatus::Installing, String::new());
                platform::install_update(&paths).map_err(|e| e.to_string())
            });
            // Windows' Setup still runs from it, held open: the next install removes it.
            if cfg!(not(windows)) {
                let _ = std::fs::remove_dir_all(&dir);
            }
            installed
        })();
        match installed {
            Err(e) => set_update_status(&weak, UpdateStatus::Failed, e),
            Ok(()) if cfg!(windows) => {
                let _ = slint::quit_event_loop();
            }
            Ok(()) => set_update_status(&weak, UpdateStatus::Installed, String::new()),
        }
    });
}

fn main() -> Result<(), slint::PlatformError> {
    // Which sources the Linux RPM built it from (linux/versions.sh, configurator_sources; "dev" elsewhere).
    if std::env::args().any(|a| a == "--sources") {
        println!("{}", option_env!("SEBTYPE_SOURCES").unwrap_or("dev"));
        return Ok(());
    }
    // Setup's step on an install or upgrade (pc/linux/setup-ime.sh, pc/windows/setup/setup.ps1): --migrate
    // only migrates, and exits 1 if that failed.
    let migrated = migrate_learning();
    if let Err(e) = &migrated {
        eprintln!("learning: {e}");
    }
    if std::env::args().any(|a| a == "--migrate") {
        std::process::exit(i32::from(migrated.is_err()));
    }
    // The schedule's sync (platform::schedule), and Setup's before it deletes learned words: no window.
    // Exit 1 when the sync was due and didn't go through: Setup then keeps the words (setup.ps1).
    if let Some(a) = std::env::args().find(|a| a == "--sync" || a == "--sync-before-removal") {
        std::process::exit(sync::run(a == "--sync-before-removal").map_or(1, |_| 0));
    }
    // The schedule's daily update check (#422, sebtype-update.timer, the "SebType update check" task).
    if std::env::args().any(|a| a == "--check-updates") {
        std::process::exit(update::scheduled().map_or_else(
            |e| {
                eprintln!("--check-updates: {e}");
                1
            },
            |_| 0,
        ));
    }
    // The network trigger's: plans a sync soon (#377).
    #[cfg(target_os = "linux")]
    if std::env::args().any(|a| a == "--network-changed") {
        std::process::exit(sync::network_changed().map_or(1, |_| 0));
    }
    // For tests without a window (pc/windows/setup/test-forget.ps1, #375): Privacy's Forget for zh or ja.
    if let Some(i) = std::env::args().position(|a| a == "--forget") {
        let forgot = match std::env::args().nth(i + 1).as_deref() {
            Some("zh") => platform::forget_rime(),
            Some("ja") => platform::forget_mozc(),
            other => Err(std::io::Error::other(format!("zh or ja, not {other:?}"))),
        };
        std::process::exit(forgot.map_or_else(
            |e| {
                eprintln!("--forget: {e}");
                1
            },
            |_| 0,
        ));
    }
    // For tests without a window (pc/linux/test-setup-ime.sh, pc/windows/setup/test-private.ps1): the
    // Privacy page's learning switch, --learning on or off.
    if let Some(i) = std::env::args().position(|a| a == "--learning") {
        let on = std::env::args().nth(i + 1).as_deref() == Some("on");
        std::process::exit(match apply_learning(on) {
            Ok(_) => 0,
            Err(e) => {
                eprintln!("--learning: {e}");
                1
            }
        });
    }
    // For tests without a window (pc/windows/setup/test.ps1): the server, username and password on
    // stdin, one per line, saved as Server and login's Save does.
    if std::env::args().any(|a| a == "--save-login") {
        let mut lines = std::io::stdin().lines().map_while(Result::ok);
        let mut line = || lines.next().unwrap_or_default();
        let (server, user, password) = (line(), line(), line());
        let saved = sync::normalize_server(&server)
            .ok_or("not an https address".to_string())
            .and_then(|server| sync::save_login(server, user.trim().to_string(), &password));
        std::process::exit(match saved {
            Ok(_) => 0,
            Err(e) => {
                eprintln!("--save-login: {e}");
                1
            }
        });
    }
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
        zh_shown: Default::default(),
        ja_shown: Default::default(),
    });
    let s = app.global::<State>();
    s.set_version(env!("SEBTYPE_VERSION").into());
    s.set_system(platform::SYSTEM.into());
    s.set_ui_font(platform::ui_font(lang).into());
    s.set_langs(ModelRc::from(ui.langs.clone()));
    s.set_fuzzy(ModelRc::from(ui.fuzzy.clone()));
    s.set_zh_words(ModelRc::from(ui.zh_words.clone()));
    s.set_ja_words(ModelRc::from(ui.ja_words.clone()));
    ui.langs
        .set_vec(["en", "zh", "ja"].map(|id| lang_row(id, true)).to_vec());
    load(&app, &ui);
    show_sync(&app, &sync::load(), false);
    if sync::load().enabled {
        std::thread::spawn(sync::refresh_schedule);
    }
    UI.with(|u| *u.borrow_mut() = Some(ui.clone()));
    // The schedule syncs while the window is open too: its outcome shows up here.
    let sync_refresh = slint::Timer::default();
    sync_refresh.start(slint::TimerMode::Repeated, Duration::from_secs(10), {
        let weak = app.as_weak();
        move || {
            if let Some(app) = weak.upgrade() {
                if app.global::<State>().get_sync_status() != SyncStatus::Syncing {
                    show_sync(&app, &sync::load(), false);
                }
            }
        }
    });

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
    // The update's notification (#422): the About page, checking.
    let from_notification = args.iter().any(|a| a == "--update");
    if from_notification {
        nav.set_page(5);
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
        let (weak, run) = (app.as_weak(), run.clone());
        move || {
            let on = weak.unwrap().global::<State>().get_learn();
            run(Box::new(move || {
                apply_learning(on).map_err(err)?;
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
            let w = rime::Word {
                word: word.trim().into(),
                pinyin,
                ..Default::default()
            };
            let mut all = ui.zh_shown.borrow().clone();
            all.push(w.clone());
            show_zh(&ui, all);
            let weak = weak.clone();
            run(Box::new(move || {
                let all = sync::words_locked(|| rime::add_word(&platform::rime_dir(), w))
                    .and_then(|r| r)
                    .map_err(err)?;
                let _ = weak.upgrade_in_event_loop(|_| with_ui(|ui| show_zh(ui, all)));
                platform::redeploy_rime().map_err(err)?;
                Ok(say(Msg::SavedZh))
            }));
            true
        }
    });
    s.on_edit_zh_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i, word, code| {
            let pinyin = rime::normalize_pinyin(&code);
            if !rime::valid_word(&word, &pinyin) {
                toast(&weak.unwrap(), say(Msg::PinyinLettersOnly));
                return;
            }
            let new = rime::Word {
                word: word.trim().into(),
                pinyin,
                ..Default::default()
            };
            let (shown, i) = (ui.zh_shown.borrow().clone(), i as usize);
            let weak = weak.clone();
            run(Box::new(move || {
                let draft = new.clone();
                let outcome =
                    sync::words_locked(|| rime::edit_word(&platform::rime_dir(), &shown, i, new))
                        .and_then(|r| r)
                        .map_err(err)?;
                edited(
                    &weak,
                    outcome,
                    shown[i].clone(),
                    show_zh,
                    |s, row| s.set_zh_editing(row),
                    move |s| {
                        s.set_zh_add_word(draft.word.into());
                        s.set_zh_add_code(draft.pinyin.into());
                    },
                )?;
                platform::redeploy_rime().map_err(err)?;
                Ok(say(Msg::SavedZh))
            }));
        }
    });
    s.on_remove_zh_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i| {
            let (shown, i) = (ui.zh_shown.borrow().clone(), i as usize);
            let mut all = shown.clone();
            rime::take_out(&mut all, i);
            show_zh(&ui, all);
            let weak = weak.clone();
            run(Box::new(move || {
                let saved =
                    sync::words_locked(|| rime::remove_word(&platform::rime_dir(), &shown, i))
                        .and_then(|r| r)
                        .map_err(err)?;
                saved_or_reload(&weak, saved)?;
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
            let w = mozc::Word {
                reading: reading.into(),
                word: word.trim().into(),
                pos: pos as usize,
                ..Default::default()
            };
            let mut all = ui.ja_shown.borrow().clone();
            all.push(w.clone());
            show_ja(&ui, all);
            let weak = weak.clone();
            run(Box::new(move || {
                let all = sync::words_locked(|| mozc::add_word(&platform::mozc_dir(), w))
                    .and_then(|r| r)
                    .map_err(err)?;
                let _ = weak.upgrade_in_event_loop(|_| with_ui(|ui| show_ja(ui, all)));
                platform::restart_mozc();
                Ok(say(Msg::SavedJa))
            }));
            true
        }
    });
    s.on_edit_ja_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i, reading, word, pos| {
            if !mozc::valid_word(&reading, &word) {
                toast(&weak.unwrap(), say(Msg::ReadingHiraganaOnly));
                return;
            }
            let new = mozc::Word {
                reading: reading.into(),
                word: word.trim().into(),
                pos: pos as usize,
                ..Default::default()
            };
            let (shown, i) = (ui.ja_shown.borrow().clone(), i as usize);
            let weak = weak.clone();
            run(Box::new(move || {
                let draft = new.clone();
                let outcome =
                    sync::words_locked(|| mozc::edit_word(&platform::mozc_dir(), &shown, i, new))
                        .and_then(|r| r)
                        .map_err(err)?;
                edited(
                    &weak,
                    outcome,
                    shown[i].clone(),
                    show_ja,
                    |s, row| s.set_ja_editing(row),
                    move |s| {
                        s.set_ja_add_reading(draft.reading.into());
                        s.set_ja_add_word(draft.word.into());
                        s.set_ja_add_pos(draft.pos as i32);
                    },
                )?;
                platform::restart_mozc();
                Ok(say(Msg::SavedJa))
            }));
        }
    });
    s.on_word_matches(|query, word, code| {
        let q = query.trim().to_lowercase();
        let pinyin = rime::normalize_pinyin(&q); // "xiao ming" finds xiaoming
        q.is_empty()
            || word.to_lowercase().contains(&q)
            || code.to_lowercase().contains(&q)
            || (!pinyin.is_empty() && code.contains(&pinyin))
    });
    s.on_remove_ja_word({
        let (ui, weak, run) = (ui.clone(), app.as_weak(), run.clone());
        move |i| {
            let (shown, i) = (ui.ja_shown.borrow().clone(), i as usize);
            let mut all = shown.clone();
            all.remove(i);
            show_ja(&ui, all);
            let weak = weak.clone();
            run(Box::new(move || {
                let saved =
                    sync::words_locked(|| mozc::remove_word(&platform::mozc_dir(), &shown, i))
                        .and_then(|r| r)
                        .map_err(err)?;
                saved_or_reload(&weak, saved)?;
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
                chinese_words: ui.zh_shown.borrow().clone(),
                japanese_words: mozc::words(&platform::mozc_dir()).unwrap_or_default(),
                learning: Some(st.get_learn()),
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
    s.on_sync_toggled({
        let weak = app.as_weak();
        move |on| {
            sync_job(weak.clone(), move || {
                sync::set_enabled(on).map_err(|e| e.to_string())
            })
        }
    });
    s.on_save_login({
        let weak = app.as_weak();
        move |server, user, password| {
            let Some(server) = sync::normalize_server(&server) else {
                return false;
            };
            let (user, password) = (user.trim().to_string(), password.to_string());
            sync_job(weak.clone(), move || {
                sync::save_login(server, user, &password)
            });
            true
        }
    });
    s.on_delete_on_server({
        let weak = app.as_weak();
        move || {
            let weak = weak.clone();
            std::thread::spawn(move || {
                let deleted = sync::delete_on_server();
                let s = sync::load();
                let _ = weak.upgrade_in_event_loop(move |app| {
                    show_sync(&app, &s, false);
                    toast(
                        &app,
                        say(if deleted {
                            Msg::SyncDeleted
                        } else {
                            Msg::SyncDeleteFailed
                        }),
                    );
                });
            });
        }
    });
    s.on_open_help(|| platform::open_url("https://github.com/S-Sebb/SebType/issues"));

    show_update(&app, &update::load());
    s.on_update_auto_changed({
        let weak = app.as_weak();
        move || {
            let mut u = update::load();
            u.auto = weak.unwrap().global::<State>().get_update_auto();
            let saved = update::save(&u);
            if let (Some(app), Err(e)) = (weak.upgrade(), saved) {
                toast(&app, err(e));
            }
        }
    });
    s.on_check_updates({
        let weak = app.as_weak();
        move || check_updates(weak.clone())
    });
    s.on_install_update({
        let weak = app.as_weak();
        move || install_update(weak.clone())
    });
    if from_notification {
        check_updates(app.as_weak());
    }

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
    use super::catalog;
    use std::{fs, path::Path};

    /// Learning goes in a backup and comes back (#374), from an older one's chinese.learn and japanese.learn too.
    #[test]
    fn a_backup_keeps_learning() {
        let parse = |text: &str| super::parse_backup(text).unwrap().learning;
        for on in [false, true] {
            let b = super::Backup {
                sebtype_configurator: 1,
                learning: Some(on),
                ..Default::default()
            };
            assert_eq!(parse(&serde_json::to_string(&b).unwrap()), Some(on));
        }
        let old = |learn| {
            format!(
                r#"{{"sebtype_configurator":1,"chinese":{{"traditional":true,"learn":{learn}}},"japanese":{{"half_width_space":true,"learn":{learn}}}}}"#
            )
        };
        let b = super::parse_backup(&old(false)).unwrap();
        assert_eq!(b.learning, Some(false));
        assert!(b.chinese.traditional && b.japanese.half_width_space);
        assert_eq!(parse(&old(true)), Some(true));
        // Japanese only (no Rime folder when it was made).
        let ja = r#"{"sebtype_configurator":1,"japanese":{"learn":false}}"#;
        assert_eq!(parse(ja), Some(false));
        assert_eq!(parse(r#"{"sebtype_configurator":1}"#), None);
    }

    /// What the window shows the same in every language: names, keys, licences and the sample candidates.
    #[rustfmt::skip]
    const SAME_IN_EVERY_LANGUAGE: &[&str] = &[
        "SebType", "English", "中文", "日本語", " · 中文", " · 日本語", "zh", "ja", "Windows", "简体", "繁體", "Picnic",
        "Mozc", "Nunito", "Win+Space", "Shift", "Alt+`", "Ctrl+Shift+F", "日本語 あ ⇄ ア", "中文 简 ⇄ 繁", "Win+V",
        "Klipper", "A−", "A+", "小明", "xiaoming", "せぶ → SebType", "ni hao", "你好", "拟好", "你", "呢", "泥", "尼",
        "妮", "倪", "雾凇拼音 rime-ice · 白霜拼音 rime-frost", "Rime (librime)",
        "Rime (librime) · Fcitx5 · fcitx5-rime", "GPL-3.0", "BSD-3-Clause",
        "BSD-3-Clause · LGPL-2.1+", "SIL Open Font License 1.1", ".json", "sync.example.com",
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
