//! Picnic-themed Linux GUI setup wizard (`--setup <installer-path>`, #435).
//! The step state machine and Account Sync validation are pure Rust so they are unit-tested on
//! every platform.

#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use crate::sync;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Welcome = 0,
    Installing = 1,
    Sync = 2,
    Ready = 3,
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
        self.step = Step::Sync;
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

#[cfg(target_os = "linux")]
pub fn run(
    installer: std::path::PathBuf,
    started_file: Option<std::path::PathBuf>,
    lang: &str,
) -> Result<(), slint::PlatformError> {
    use crate::{platform, SetupState, SetupWindow};
    use slint::ComponentHandle;
    use std::{cell::RefCell, process::Command, rc::Rc};

    slint::BackendSelector::new().select()?;
    slint::set_xdg_app_id("sebtype-configurator")?;
    let win = SetupWindow::new()?;
    let _ = slint::select_bundled_translation(lang);

    let state = Rc::new(RefCell::new(WizardState::new()));
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

    g.on_server_valid(|server| server_input_valid(&server));
    g.on_can_submit(|server, user, password| can_submit_sync(&server, &user, &password));

    g.on_start_install({
        let weak = win.as_weak();
        let state = state.clone();
        let installer = installer.clone();
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
                        let _ = weak_bg.upgrade_in_event_loop(move |win| {
                            let g = win.global::<SetupState>();
                            g.set_install_error("".into());
                            g.set_step(Step::Sync as i32);
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
            if let Some(win) = weak.upgrade() {
                let g = win.global::<SetupState>();
                g.set_sync_busy(true);
                g.set_sync_error("".into());
            }
            let weak_bg = weak.clone();
            std::thread::spawn(move || {
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
                    let bin = platform::installed_configurator();
                    let _ = Command::new(bin).spawn();
                }
            }
            let _ = slint::quit_event_loop();
        }
    });

    win.show()?;
    if let Some(path) = started_file {
        let _ = std::fs::write(path, "1");
    }
    slint::run_event_loop()
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(st.step, Step::Sync);

        st.skip_sync();
        assert_eq!(st.step, Step::Ready);
        assert!(!st.sync_signed_in);
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
