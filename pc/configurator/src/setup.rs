//! The Picnic-themed setup wizard: Linux's (`--setup <installer-path>`, #435) from Welcome, Windows Setup's
//! (`--setup-after-install`, #471) from Common settings (#444) once Setup has copied the files. The step
//! state machine and Account Sync validation are pure Rust so they are unit-tested on every platform.

// Installing is Linux's: Windows Setup copies the files itself.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use crate::{platform, rime, sync, Candidates};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Welcome = 0,
    Installing = 1,
    Common = 2,
    Sync = 3,
    Ready = 4,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallPhase {
    Packages = 0,
    UserSetup = 1,
    Failed = 2,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WizardState {
    pub step: Step,
    pub install_phase: InstallPhase,
    pub install_error: Option<String>,
    pub sync_signed_in: bool,
    pub open_configurator: bool,
}

impl Default for WizardState {
    fn default() -> Self {
        Self::new()
    }
}

impl WizardState {
    pub fn new() -> Self {
        Self {
            step: Step::Welcome,
            install_phase: InstallPhase::Packages,
            install_error: None,
            sync_signed_in: false,
            open_configurator: true,
        }
    }

    pub fn start_install(&mut self) {
        self.step = Step::Installing;
        self.install_phase = InstallPhase::Packages;
        self.install_error = None;
    }

    pub fn packages_installed(&mut self) {
        if self.step == Step::Installing {
            self.install_phase = InstallPhase::UserSetup;
        }
    }

    pub fn install_failed(&mut self, error: String) {
        self.step = Step::Installing;
        self.install_phase = InstallPhase::Failed;
        self.install_error = Some(error);
    }

    pub fn install_succeeded(&mut self) {
        self.install_error = None;
        self.step = Step::Common;
    }

    pub fn common_saved(&mut self) {
        if self.step == Step::Common {
            self.step = Step::Sync;
        }
    }

    pub fn skip_sync(&mut self) {
        if self.step == Step::Sync {
            self.sync_signed_in = false;
            self.step = Step::Ready;
        }
    }

    pub fn sync_succeeded(&mut self) {
        if self.step == Step::Sync {
            self.sync_signed_in = true;
            self.step = Step::Ready;
        }
    }
}

/// The Common settings page (#444): what it shows first is what the Configurator would, and Next saves it
/// as the Configurator's Keyboard and Theme pages do, so a Next without a change keeps everything.
#[derive(Clone, Debug, PartialEq)]
pub struct Common {
    pub traditional: bool,
    pub page_size: i32,
    pub picnic: bool,
    pub vertical: bool,
    // The rest of the Configurator's settings, saved back as they were.
    chinese: rime::Chinese,
    candidates: Candidates,
}

impl Common {
    pub fn load() -> Self {
        Self::load_for(false)
    }

    /// An update over an earlier SebType keeps its candidate window as it is, chosen or not.
    pub fn load_for(update: bool) -> Self {
        Self::from(
            rime::load(&platform::rime_dir()),
            platform::candidates(),
            update || platform::candidates_chosen(),
        )
    }

    /// Picnic until the person has chosen a candidate window style (#471).
    fn from(chinese: rime::Chinese, candidates: Candidates, chosen: bool) -> Self {
        Common {
            traditional: chinese.traditional,
            page_size: chinese.page_size.clamp(5, 9),
            picnic: candidates.picnic || !chosen,
            vertical: candidates.vertical,
            chinese,
            candidates,
        }
    }

    /// The Configurator's Chinese settings and candidate window, with this page's choices in them.
    fn applied(&self) -> (rime::Chinese, Candidates) {
        let chinese = rime::Chinese {
            traditional: self.traditional,
            page_size: self.page_size,
            ..self.chinese.clone()
        };
        let candidates = Candidates {
            picnic: self.picnic,
            vertical: self.vertical,
            ..self.candidates.clone()
        };
        (chinese, candidates)
    }

    pub fn save(&self) -> std::io::Result<()> {
        let (chinese, candidates) = self.applied();
        crate::save_candidates(&chinese, &candidates)
    }

    /// Windows Setup's page reads and sends them as `key=value` (main's `--common-settings`).
    pub fn to_lines(&self) -> String {
        let b = |on: bool| u8::from(on);
        format!(
            "traditional={}\npage-size={}\npicnic={}\nvertical={}\n",
            b(self.traditional),
            self.page_size,
            b(self.picnic),
            b(self.vertical)
        )
    }

    /// These settings with the `key=value`s given changed; others are ignored.
    pub fn with(mut self, pairs: &[String]) -> Self {
        for (key, value) in pairs.iter().filter_map(|p| p.split_once('=')) {
            match key {
                "traditional" => self.traditional = value == "1",
                "page-size" => {
                    self.page_size = value.parse().map_or(self.page_size, |n: i32| n.clamp(5, 9))
                }
                "picnic" => self.picnic = value == "1",
                "vertical" => self.vertical = value == "1",
                _ => {}
            }
        }
        self
    }
}

/// What the last page checks (#445): each row is done, or says what is left with a button that does it.
#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(dead_code)] // each system makes only its own
pub enum Need {
    /// Linux: Fcitx5 runs SebType's input method. The button runs SebType's setup for this account again.
    InputMethod,
    /// Linux: KDE's session started with XMODIFIERS and without a global IM module, which only a login
    /// gives the apps it starts (X11 apps reach SebType through XMODIFIERS). The button logs out.
    LogIn,
    /// Linux: a global `*_IM_MODULE` line, which SebType leaves to the person (pc/linux/README.md). The
    /// button opens the file.
    ImModule {
        file: std::path::PathBuf,
        line: usize,
        text: String,
    },
    /// Windows: each 中文 and 日本語 in the language list has SebType's text service. The button adds it.
    Languages,
    /// Linux: Fcitx5 groups with fcitx5-rime's Rime, which won't type Chinese beside SebType's input method (#542).
    /// The button puts SebType's input method in its place. An error, when Fcitx5's groups couldn't be read,
    /// keeps the row open rather than done.
    Rime { groups: Result<Vec<String>, String> },
}

/// This check's rows, with those an earlier one showed and this one doesn't find any more kept, done, in
/// their place: a step stays on the page, ticked, once the person has done it.
/// The Rime row is one row whichever groups it lists, so a group done of several isn't a second row. The
/// check gives it done, with no groups, only when Fcitx5 said so: shown only in place of an earlier Rime row.
/// When the check couldn't ask (no Fcitx5 while it restarts), an earlier Rime row stays as it was.
pub fn keep_done(before: &[(Need, bool)], mut now: Vec<(Need, bool)>) -> Vec<(Need, bool)> {
    let rime = |n: &Need| matches!(n, Need::Rime { .. });
    let same = |a: &Need, b: &Need| a == b || (rime(a) && rime(b));
    if !before.iter().any(|(n, _)| rime(n)) {
        now.retain(|(n, ok)| !(rime(n) && *ok));
    }
    for (i, (need, ok)) in before.iter().enumerate() {
        if !now.iter().any(|(n, _)| same(n, need)) {
            now.insert(i.min(now.len()), (need.clone(), *ok || !rime(need)));
        }
    }
    now
}

/// A path in the home folder as `~/…`, which fits the page.
fn home_short(path: &std::path::Path) -> String {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    match home.as_deref().and_then(|h| path.strip_prefix(h).ok()) {
        Some(rest) => format!("~/{}", rest.display()),
        None => path.display().to_string(),
    }
}

/// Names as the page lists them in the page's language: “Default”, “Rime”; “Default”、“Rime” in 中文;
/// 「Default」、「Rime」 in 日本語. The translations put no spaces around them.
pub fn quoted(names: &[String], lang: &str) -> String {
    let (open, close, sep) = match lang {
        "ja" => ("「", "」", "、"),
        "zh" => ("“", "”", "、"),
        _ => ("“", "”", ", "),
    };
    names
        .iter()
        .map(|n| format!("{open}{n}{close}"))
        .collect::<Vec<_>>()
        .join(sep)
}

/// The page's rows, as SetupState's ready-checks shows them.
fn ready_rows(checks: &[(Need, bool)], lang: &str) -> Vec<crate::ReadyCheck> {
    checks
        .iter()
        .map(|(need, ok)| {
            let (kind, file, line, text) = match need {
                Need::InputMethod => (0, String::new(), 0, String::new()),
                Need::LogIn => (1, String::new(), 0, String::new()),
                Need::ImModule { file, line, text } => {
                    (2, home_short(file), *line as i32, text.clone())
                }
                Need::Languages => (3, String::new(), 0, String::new()),
                // line: how many groups, or 0 with the reason they couldn't be read
                Need::Rime { groups: Ok(g) } => (4, String::new(), g.len() as i32, quoted(g, lang)),
                Need::Rime { groups: Err(e) } => (4, String::new(), 0, e.clone()),
            };
            // A line in the person's own file is turned off by the button; a system file opens.
            let own = matches!(need, Need::ImModule { file, .. }
                if std::fs::OpenOptions::new().append(true).open(file).is_ok());
            crate::ReadyCheck {
                kind,
                ok: *ok,
                own,
                file: file.into(),
                line,
                text: text.into(),
            }
        })
        .collect()
}

/// Inline validation for the Account Sync server field: empty is allowed (no error shown before
/// typing); non-empty must normalize to a valid https:// (or localhost http://) address.
pub fn server_input_valid(server: &str) -> bool {
    let trimmed = server.trim();
    trimmed.is_empty() || sync::normalize_server(trimmed).is_some()
}

/// True when all three Account Sync fields are filled and the server address is valid.
pub fn can_submit_sync(server: &str, user: &str, password: &str) -> bool {
    !server.trim().is_empty()
        && !user.trim().is_empty()
        && !password.is_empty()
        && sync::normalize_server(server).is_some()
}

/// KWin takes a Wayland window's icon from the launcher its app id names, and the wizard runs before
/// SebType's launcher is installed (#439): a hidden launcher of its own, with the pig, until it closes.
pub struct WizardLauncher(Vec<std::path::PathBuf>);

impl WizardLauncher {
    pub const APP_ID: &'static str = "sebtype-setup";

    pub fn write(data: &std::path::Path) -> std::io::Result<Self> {
        const PIG: &[u8] = include_bytes!(
            "../../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png"
        );
        let icon = data.join("sebtype/setup-icon.png");
        let desktop = data.join(format!("applications/{}.desktop", Self::APP_ID));
        let made = WizardLauncher(vec![desktop.clone(), icon.clone()]); // removes what was written if one fails
        for p in &made.0 {
            std::fs::create_dir_all(p.parent().unwrap())?;
        }
        std::fs::write(&icon, PIG)?;
        // Exec=true: an application entry needs one, and NoDisplay keeps it out of the menus.
        std::fs::write(
            &desktop,
            format!(
                "[Desktop Entry]\nType=Application\nName=SebType Setup\nIcon={}\nExec=true\nNoDisplay=true\n",
                icon.display()
            ),
        )?;
        Ok(made)
    }
}

impl Drop for WizardLauncher {
    fn drop(&mut self) {
        for p in &self.0 {
            let _ = std::fs::remove_file(p);
        }
    }
}

/// Where the wizard starts.
pub enum Start {
    /// Linux: Welcome, then the installer at this path; `started_file` is written once the window shows.
    Install {
        installer: std::path::PathBuf,
        started_file: Option<std::path::PathBuf>,
    },
    /// Windows Setup has welcomed, set the languages and copied the files.
    AfterInstall,
}

pub fn run(start: Start, lang: &str) -> Result<(), slint::PlatformError> {
    use crate::{platform, Chrome, SetupState, SetupWindow, SyncCheck};
    use slint::ComponentHandle;
    use std::{cell::RefCell, process::Command, rc::Rc};

    #[cfg(target_os = "linux")]
    let _launcher = WizardLauncher::write(&platform::data()).ok();
    slint::BackendSelector::new().select()?;
    #[cfg(target_os = "linux")]
    slint::set_xdg_app_id(WizardLauncher::APP_ID)?;
    let win = SetupWindow::new()?;
    win.global::<Chrome>().set_frameless(crate::own_title_bar());
    let _ = slint::select_bundled_translation(lang);

    let after_install = matches!(start, Start::AfterInstall);
    // Windows Setup says so; Linux's installer hasn't run yet.
    #[cfg(target_os = "linux")]
    let update = platform::installed_configurator().exists();
    #[cfg(not(target_os = "linux"))]
    let update = std::env::args().any(|a| a == "--upgrade");
    let state = Rc::new(RefCell::new(WizardState::new()));
    if after_install {
        // Only the languages page is Setup's own.
        state.borrow_mut().step = Step::Common;
    }
    let sync_ui = |win: &SetupWindow, st: &WizardState| {
        let g = win.global::<SetupState>();
        g.set_step(st.step as i32);
        g.set_install_phase(st.install_phase.clone() as i32);
        g.set_install_error(st.install_error.clone().unwrap_or_default().into());
        g.set_open_configurator(st.open_configurator);
    };

    let g = win.global::<SetupState>();
    g.set_ui_font(platform::ui_font(lang).into());
    sync_ui(&win, &state.borrow());
    if after_install {
        g.set_first_step(Step::Common as i32);
        g.set_show_langs(false);
        show_common(&win, &Common::load_for(update), &[]);
    }

    g.on_server_valid(|server| server_input_valid(&server));
    g.on_can_submit(|server, user, password| can_submit_sync(&server, &user, &password));

    #[cfg(target_os = "linux")]
    if let Start::Install { installer, .. } = &start {
        let installer = installer.clone();
        g.on_start_install({
            let weak = win.as_weak();
            let state = state.clone();
            move || {
                {
                    let mut st = state.borrow_mut();
                    st.start_install();
                    if let Some(win) = weak.upgrade() {
                        let g = win.global::<SetupState>();
                        g.set_step(st.step as i32);
                        g.set_install_phase(st.install_phase.clone() as i32);
                        g.set_install_error("".into());
                    }
                }
                let weak_bg = weak.clone();
                let installer_bg = installer.clone();
                std::thread::spawn(move || {
                    if let Err(e) = platform::run_root_installer(&installer_bg) {
                        let msg = e.to_string();
                        let _ = weak_bg.upgrade_in_event_loop(move |win| {
                            let g = win.global::<SetupState>();
                            g.set_install_phase(InstallPhase::Failed as i32);
                            g.set_install_error(msg.into());
                        });
                        return;
                    }
                    let _ = weak_bg.upgrade_in_event_loop(move |win| {
                        win.global::<SetupState>()
                            .set_install_phase(InstallPhase::UserSetup as i32);
                    });
                    match platform::run_user_setup() {
                        Ok(()) => {
                            let (common, langs) = (
                                Common::load_for(update),
                                platform::langs().unwrap_or_default(),
                            );
                            let _ = weak_bg.upgrade_in_event_loop(move |win| {
                                let g = win.global::<SetupState>();
                                g.set_install_error("".into());
                                show_common(&win, &common, &langs);
                                g.set_step(Step::Common as i32);
                            });
                        }
                        Err(e) => {
                            let msg = e.to_string();
                            let _ = weak_bg.upgrade_in_event_loop(move |win| {
                                let g = win.global::<SetupState>();
                                g.set_install_phase(InstallPhase::Failed as i32);
                                g.set_install_error(msg.into());
                            });
                        }
                    }
                });
            }
        });
    }

    g.on_save_common({
        let weak = win.as_weak();
        move || {
            let Some(win) = weak.upgrade() else { return };
            let g = win.global::<SetupState>();
            let common = Common {
                traditional: g.get_traditional(),
                page_size: g.get_page_size(),
                picnic: g.get_picnic(),
                vertical: g.get_vertical(),
                ..Common::load_for(update)
            };
            // The languages in their order, each on or off as the page shows it; none where Windows
            // Setup's own page set them.
            let langs: Vec<(String, bool)> = if !g.get_show_langs() {
                Vec::new()
            } else {
                platform::langs().unwrap_or_default()
            }
            .into_iter()
            .map(|(id, _)| {
                let on = match id.as_str() {
                    "en" => g.get_lang_en(),
                    "zh" => g.get_lang_zh(),
                    _ => g.get_lang_ja(),
                };
                (id, on)
            })
            .collect();
            g.set_common_busy(true);
            let weak = weak.clone();
            std::thread::spawn(move || {
                let saved = if langs.is_empty() {
                    Ok(())
                } else {
                    platform::set_langs(&langs)
                }
                .and_then(|_| common.save());
                let _ = weak.upgrade_in_event_loop(move |win| {
                    let g = win.global::<SetupState>();
                    g.set_common_busy(false);
                    match saved {
                        Ok(()) => {
                            g.set_common_error("".into());
                            g.set_step(Step::Sync as i32);
                        }
                        Err(e) => g.set_common_error(e.to_string().into()),
                    }
                });
            });
        }
    });

    g.on_skip_sync({
        let weak = win.as_weak();
        let state = state.clone();
        move || {
            let mut st = state.borrow_mut();
            st.step = Step::Sync;
            st.skip_sync();
            if let Some(win) = weak.upgrade() {
                let g = win.global::<SetupState>();
                g.set_sync_error("".into());
                g.set_step(Step::Ready as i32);
            }
        }
    });

    g.on_save_sync({
        let weak = win.as_weak();
        move |server, user, password| {
            let Some(server) = sync::normalize_server(&server) else {
                if let Some(win) = weak.upgrade() {
                    win.global::<SetupState>()
                        .set_sync_error("An https:// address".into());
                }
                return;
            };
            let (user, password) = (user.trim().to_string(), password.to_string());
            let Some(win) = weak.upgrade() else { return };
            let g = win.global::<SetupState>();
            // After a check that failed, Save anyway: the login is kept without another check.
            let check_first = matches!(g.get_sync_check(), SyncCheck::None | SyncCheck::Connected);
            g.set_sync_busy(true);
            g.set_sync_error("".into());
            if check_first {
                g.set_sync_check(SyncCheck::Checking);
            }
            let weak_bg = weak.clone();
            std::thread::spawn(move || {
                if check_first {
                    let check = sync::check(&server, &user, &password);
                    if check != sync::Check::Connected {
                        let _ = weak_bg.upgrade_in_event_loop(move |win| {
                            let g = win.global::<SetupState>();
                            g.set_sync_busy(false);
                            g.set_sync_check(crate::sync_check(Some(check)));
                        });
                        return;
                    }
                    // The tick shows a moment before the page moves on (or says why saving failed).
                    let _ = weak_bg.upgrade_in_event_loop(|win| {
                        win.global::<SetupState>()
                            .set_sync_check(SyncCheck::Connected);
                    });
                    std::thread::sleep(std::time::Duration::from_millis(1500));
                }
                let res = sync::save_login(server, user, &password);
                let _ = weak_bg.upgrade_in_event_loop(move |win| {
                    let g = win.global::<SetupState>();
                    g.set_sync_busy(false);
                    match res {
                        Ok(_) => {
                            g.set_sync_error("".into());
                            g.set_step(Step::Ready as i32);
                        }
                        Err(e) => {
                            g.set_sync_error(e.into());
                        }
                    }
                });
            });
        }
    });

    g.on_finish({
        let weak = win.as_weak();
        move || {
            if let Some(win) = weak.upgrade() {
                if win.global::<SetupState>().get_open_configurator() {
                    #[cfg(target_os = "linux")]
                    let bin = platform::installed_configurator();
                    #[cfg(not(target_os = "linux"))]
                    let bin = std::env::current_exe().unwrap_or_default();
                    let _ = Command::new(bin).spawn();
                }
            }
            let _ = slint::quit_event_loop();
        }
    });

    // The last page checks what SebType needs while it shows (#445): the page's timer asks every few
    // seconds, one check at a time, off the window's thread (Windows' takes PowerShell a second).
    let checks = std::sync::Arc::new(std::sync::Mutex::new(Vec::<(Need, bool)>::new()));
    let checking = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let recheck = {
        let weak = win.as_weak();
        let (checks, checking) = (checks.clone(), checking.clone());
        let lang = lang.to_string();
        move || {
            use std::sync::atomic::Ordering;
            if checking.swap(true, Ordering::SeqCst) {
                return;
            }
            let (weak, checks, checking, lang) =
                (weak.clone(), checks.clone(), checking.clone(), lang.clone());
            std::thread::spawn(move || {
                let rows = {
                    let mut c = checks.lock().unwrap();
                    *c = keep_done(&c, platform::ready_checks());
                    ready_rows(&c, &lang)
                };
                checking.store(false, Ordering::SeqCst);
                let _ = weak.upgrade_in_event_loop(move |win| {
                    let g = win.global::<SetupState>();
                    g.set_ready(rows.iter().all(|r| r.ok));
                    g.set_ready_checks(Rc::new(slint::VecModel::from(rows)).into());
                });
            });
        }
    };
    g.on_recheck(recheck.clone());
    g.on_fix({
        let weak = win.as_weak();
        move |i| {
            let Some(need) = checks
                .lock()
                .unwrap()
                .get(i as usize)
                .map(|(n, _)| n.clone())
            else {
                return;
            };
            let Some(win) = weak.upgrade() else { return };
            let g = win.global::<SetupState>();
            g.set_fixing(i);
            g.set_ready_error("".into());
            let weak = weak.clone();
            std::thread::spawn(move || {
                let done = platform::fix(&need).map_err(|e| e.to_string());
                let _ = weak.upgrade_in_event_loop(move |win| {
                    let g = win.global::<SetupState>();
                    g.set_fixing(-1);
                    g.set_ready_error(done.err().unwrap_or_default().into());
                    g.invoke_recheck();
                });
            });
        }
    });

    // For screenshots (pc/configurator/test.sh): --step N opens that step, Common settings as installed;
    // --theme picnic or system shows it in that style.
    if let Some(step) = std::env::args()
        .position(|a| a == "--step")
        .and_then(|i| std::env::args().nth(i + 1)?.parse().ok())
    {
        show_common(
            &win,
            &Common::load(),
            &platform::langs().unwrap_or_default(),
        );
        g.set_step(step);
        recheck();
    }
    if let Some(theme) = std::env::args().skip_while(|a| a != "--theme").nth(1) {
        g.set_picnic(theme != "system");
    }

    win.show()?;
    if let Start::Install {
        started_file: Some(path),
        ..
    } = &start
    {
        let _ = std::fs::write(path, "1");
    }
    slint::run_event_loop()
}

/// The Common settings page shows these values.
fn show_common(win: &crate::SetupWindow, common: &Common, langs: &[(String, bool)]) {
    use slint::ComponentHandle;
    let g = win.global::<crate::SetupState>();
    let on = |id: &str| langs.iter().any(|(i, on)| i == id && *on);
    g.set_lang_en(on("en"));
    g.set_lang_zh(on("zh"));
    g.set_lang_ja(on("ja"));
    g.set_traditional(common.traditional);
    g.set_page_size(common.page_size);
    g.set_picnic(common.picnic);
    g.set_vertical(common.vertical);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wizard_launcher_names_the_pig_and_goes_when_dropped() {
        let data =
            std::env::temp_dir().join(format!("sebtype-wizard-launcher-{}", std::process::id()));
        let desktop = data.join("applications/sebtype-setup.desktop");
        let icon = data.join("sebtype/setup-icon.png");
        let launcher = WizardLauncher::write(&data).unwrap();
        let entry = std::fs::read_to_string(&desktop).unwrap();
        assert!(
            entry.contains(&format!("\nIcon={}\n", icon.display())),
            "{entry}"
        );
        assert!(entry.contains("\nNoDisplay=true\n"), "{entry}");
        assert!(std::fs::read(&icon).unwrap().starts_with(b"\x89PNG"));
        drop(launcher);
        assert!(!desktop.exists() && !icon.exists());
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn wizard_happy_path_with_sync() {
        let mut st = WizardState::new();
        assert_eq!(st.step, Step::Welcome);
        assert!(st.open_configurator);

        st.start_install();
        assert_eq!(st.step, Step::Installing);
        assert_eq!(st.install_phase, InstallPhase::Packages);

        st.packages_installed();
        assert_eq!(st.install_phase, InstallPhase::UserSetup);

        st.install_succeeded();
        assert_eq!(st.step, Step::Common);

        st.common_saved();
        assert_eq!(st.step, Step::Sync);

        st.sync_succeeded();
        assert_eq!(st.step, Step::Ready);
        assert!(st.sync_signed_in);
    }

    #[test]
    fn wizard_failure_retry_and_skip_sync() {
        let mut st = WizardState::new();
        st.start_install();
        st.install_failed("cancelled".into());
        assert_eq!(st.step, Step::Installing);
        assert_eq!(st.install_phase, InstallPhase::Failed);
        assert_eq!(st.install_error.as_deref(), Some("cancelled"));

        // Retry resets error and restarts from Packages.
        st.start_install();
        assert_eq!(st.install_phase, InstallPhase::Packages);
        assert_eq!(st.install_error, None);

        st.packages_installed();
        st.install_succeeded();
        assert_eq!(st.step, Step::Common);
        st.common_saved();
        assert_eq!(st.step, Step::Sync);

        st.skip_sync();
        assert_eq!(st.step, Step::Ready);
        assert!(!st.sync_signed_in);
    }

    /// #444: the page shows the installed defaults (6 per page, 简体), Next without a change writes nothing new,
    /// and its choices reach Rime's files while the Configurator's other settings stay.
    #[test]
    fn common_settings_page_writes_the_settings() {
        let dir = std::env::temp_dir().join(format!("sebtype-common-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let candidates = Candidates {
            vertical: false,
            font_size: 13,
            picnic: true,
            pinyin_row: false,
        };
        let page = Common::from(rime::load(&dir), candidates.clone(), true);
        assert_eq!((page.traditional, page.page_size), (false, 6));
        // Picnic until a style is chosen (#471); a chosen System style stays.
        let system = Candidates {
            picnic: false,
            ..candidates.clone()
        };
        assert!(Common::from(rime::load(&dir), system.clone(), false).picnic);
        assert!(!Common::from(rime::load(&dir), system, true).picnic);
        let (c, k) = page.applied();
        assert!(
            !rime::save(&dir, &c).unwrap(),
            "a Next without a change writes nothing"
        );
        assert_eq!(k, candidates);

        let mut chinese = rime::load(&dir);
        chinese.emoji = false;
        rime::save(&dir, &chinese).unwrap();
        let page = Common::from(rime::load(&dir), candidates.clone(), true).with(&[
            "traditional=1".into(),
            "page-size=8".into(),
            "picnic=0".into(),
            "vertical=1".into(),
        ]);
        assert_eq!(
            page.to_lines(),
            "traditional=1\npage-size=8\npicnic=0\nvertical=1\n"
        );
        let (c, k) = page.applied();
        assert!(rime::save(&dir, &c).unwrap());
        let saved = rime::load(&dir);
        assert!(saved.traditional && !saved.emoji);
        assert_eq!(saved.page_size, 8);
        assert_eq!(
            k,
            Candidates {
                vertical: true,
                font_size: 13,
                picnic: false,
                pinyin_row: false,
            }
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #542: group names in the quotes of the page's language, as its other strings quote.
    #[test]
    fn group_names_are_quoted_as_the_language_quotes() {
        let names = ["Default".to_string(), "My=Rime".to_string()];
        assert_eq!(quoted(&names, "en"), "“Default”, “My=Rime”");
        assert_eq!(quoted(&names, "zh"), "“Default”、“My=Rime”");
        assert_eq!(quoted(&names, "ja"), "「Default」、「My=Rime」");
    }

    /// #542: Rime's row stays one row as its groups get done, and ticks once none is left.
    #[test]
    fn rime_row_stays_one_row() {
        let rime = |g: &[&str]| Need::Rime {
            groups: Ok(g.iter().map(|g| g.to_string()).collect()),
        };
        let first = keep_done(&[], vec![(rime(&["Default", "Work"]), false)]);
        assert_eq!(
            keep_done(&first, vec![(rime(&["Work"]), false)]),
            [(rime(&["Work"]), false)]
        );
        // Fcitx5 said none is left: ticked.
        assert_eq!(
            keep_done(&first, vec![(rime(&[]), true)]),
            [(rime(&[]), true)]
        );
        assert_eq!(keep_done(&first, vec![]), first);
        // No Rime row before, none now: no row.
        assert_eq!(keep_done(&[], vec![(rime(&[]), true)]), []);
    }

    /// #445: a step the person did stays on the last page, ticked, in its place; the page is ready once
    /// every row is.
    #[test]
    fn a_done_step_stays_ticked() {
        let module = |line| Need::ImModule {
            file: "/home/a/.profile".into(),
            line,
            text: "export QT_IM_MODULE=fcitx".into(),
        };
        let first = keep_done(
            &[],
            vec![
                (Need::InputMethod, true),
                (module(3), false),
                (module(9), false),
                (Need::LogIn, false),
            ],
        );
        let now = keep_done(
            &first,
            vec![
                (Need::InputMethod, true),
                (module(9), false),
                (Need::LogIn, false),
            ],
        );
        assert_eq!(now[1], (module(3), true));
        assert_eq!(now.len(), 4);
        let rows = ready_rows(&now, "en");
        assert_eq!(
            rows.iter().map(|r| (r.kind, r.ok)).collect::<Vec<_>>(),
            [(0, true), (2, true), (2, false), (1, false)]
        );
        assert!(
            !rows[1].own,
            "a file that isn't there isn't the person's to change"
        );
    }

    #[test]
    fn sync_field_validation() {
        assert!(server_input_valid(""));
        assert!(server_input_valid("   "));
        assert!(server_input_valid("sync.example.com"));
        assert!(server_input_valid("https://sync.example.com:8443/sebtype"));
        assert!(server_input_valid("http://127.0.0.1:8080"));
        assert!(!server_input_valid("http://example.com"));
        assert!(!server_input_valid("ftp://sync.example.com"));
        assert!(!server_input_valid("has space.example.com"));

        assert!(!can_submit_sync("", "alice", "pw"));
        assert!(!can_submit_sync("sync.example.com", "", "pw"));
        assert!(!can_submit_sync("sync.example.com", "alice", ""));
        assert!(!can_submit_sync("http://example.com", "alice", "pw"));
        assert!(can_submit_sync("sync.example.com", "alice", "pw"));
        assert!(can_submit_sync("https://sync.example.com", "alice", " "));
    }
}
