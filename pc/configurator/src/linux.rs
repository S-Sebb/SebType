//! Linux: Fcitx5 with SebType's input method (linux/, #190), which hosts Rime and Mozc, set up by
//! pc/linux/setup-ime.sh. A running Fcitx5 is told over D-Bus (busctl); without one, the files are
//! written and read when it starts.

use crate::Candidates;
use std::{
    env, fs, io,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant, SystemTime},
};

pub const SYSTEM: &str = "Linux";
/// Noto's CJK font in the window's language, so 日本語 gets Japanese kanji shapes.
pub fn ui_font(lang: &str) -> &'static str {
    if lang == "ja" {
        "Noto Sans CJK JP"
    } else {
        "Noto Sans CJK SC"
    }
}
const PICNIC: &str = "sebtype-picnic";
/// SebType's pig (logo.svg) at the start of the Picnic window (#94), rising above the box onto a tab
/// at its top left (panel.svg, #162). Fcitx5 scales theme images with the DPI but not with the font, so
/// the pig, the tab and the margins are sized here, in px at 96 dpi.
fn picnic_files(font_size: i32) -> [(&'static str, String); 6] {
    let height = (16 + font_size * 6 / 5) * 12 / 7; // the pig: 48 at 10 pt, 75 at 24 pt
    let width = (height * 158 + 80) / 160; // the logo image is 158x160
                                           // The box Fcitx5 draws round one line of Noto Sans CJK (1.448 em): ContentMargin 7 + 9 and
                                           // TextMargin 4 + 4, less the 2 px shadow. 41 at 10 pt.
    let line = (f64::from(font_size) * 4.0 / 3.0 * 1.448).round() as i32;
    let box_h = 22 + line;
    // The pig sits 6 px in and 5 px down from the tab's corner (border 2, 3 of cream), with its feet
    // 2 px above the bottom border: the box's top is that far below the tab's.
    let tab_h = height + 11 - box_h;
    let tab_w = 6 + width + 11; // 3 of cream, the border and 6 more right of the pig
    let (left, top) = (tab_w + 6, tab_h + 12); // the tab and its corners in panel.svg's fixed corner
    let (w, h) = (left + 2 + 12, top + 2 + 14);
    [
        (
            "theme.conf",
            include_str!("../fcitx5-theme/theme.conf")
                .replace("@CONTENT_LEFT@", &(tab_w + 2).to_string())
                .replace("@CONTENT_TOP@", &(tab_h + 7).to_string())
                .replace("@PANEL_LEFT@", &left.to_string())
                .replace("@PANEL_TOP@", &top.to_string()),
        ),
        (
            "logo.svg",
            include_str!("../fcitx5-theme/logo.svg")
                .replace("@WIDTH@", &width.to_string())
                .replace("@HEIGHT@", &height.to_string()),
        ),
        (
            "panel.svg",
            include_str!("../fcitx5-theme/panel.svg")
                .replace("@WIDTH@", &w.to_string())
                .replace("@HEIGHT@", &h.to_string())
                .replace("@PATH@", &panel_outline(tab_w, tab_h, w, h)),
        ),
        (
            "highlight.svg",
            include_str!("../fcitx5-theme/highlight.svg").into(),
        ),
        ("prev.svg", include_str!("../fcitx5-theme/prev.svg").into()),
        ("next.svg", include_str!("../fcitx5-theme/next.svg").into()),
    ]
}

/// The window's outline in a w x h panel.svg: the box from tab_h down, with a tab_w wide tab on its top
/// left, both with the box's 12 px corners, and a 4 px curve where the tab meets the box's top. On the
/// 2 px border's centre line, so the border fills the image's edge.
fn panel_outline(tab_w: i32, tab_h: i32, w: i32, h: i32) -> String {
    let (r, f) = (11, 4);
    let (xt, yb, xr, yd) = (tab_w - 1, tab_h + 1, w - 1, h - 3);
    format!(
        "M1 {a}A{r} {r} 0 0 1 {a} 1H{b}A{r} {r} 0 0 1 {xt} {a}V{c}A{f} {f} 0 0 0 {d} {yb}H{e}\
         A{r} {r} 0 0 1 {xr} {g}V{i}A{r} {r} 0 0 1 {e} {yd}H{a}A{r} {r} 0 0 1 1 {i}Z",
        a = 1 + r,
        b = xt - r,
        c = yb - f,
        d = xt + f,
        e = xr - r,
        g = yb + r,
        i = yd - r,
    )
}
/// SebType's languages, as its settings name them.
const LANGS: [&str; 3] = ["en", "zh", "ja"];

fn home() -> PathBuf {
    PathBuf::from(env::var_os("HOME").unwrap_or_default())
}
fn xdg(var: &str, fallback: &str) -> PathBuf {
    env::var_os(var)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(fallback))
}
fn config() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config")
}
fn data() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}
pub fn rime_dir() -> PathBuf {
    data().join("fcitx5/rime")
}
pub fn mozc_dir() -> PathBuf {
    mozc_profile(&home(), &config())
}
/// Mozc's own rule (engines/mozc: base/system_util.cc), which the input method follows too
/// (linux/src/sebtype.cpp): ~/.mozc when an older Mozc made it, else XDG's mozc folder.
fn mozc_profile(home: &Path, config: &Path) -> PathBuf {
    let old = home.join(".mozc");
    if old.is_dir() {
        old
    } else {
        config.join("mozc")
    }
}
/// SebType's own settings, which its input method reads (core/: Settings).
fn settings() -> PathBuf {
    config().join("sebtype/sebtype.conf")
}
fn classicui() -> PathBuf {
    config().join("fcitx5/conf/classicui.conf")
}
fn theme_dir() -> PathBuf {
    data().join("fcitx5/themes").join(PICNIC)
}

fn busctl(args: &[&str]) -> io::Result<String> {
    let out = Command::new("busctl").arg("--user").args(args).output()?;
    if !out.status.success() {
        return Err(io::Error::other(
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
fn controller(method: &str, args: &[&str]) -> io::Result<String> {
    let mut a = vec![
        "--json=short",
        "call",
        "org.fcitx.Fcitx5",
        "/controller",
        "org.fcitx.Fcitx.Controller1",
        method,
    ];
    a.extend_from_slice(args);
    busctl(&a)
}
fn fcitx_running() -> bool {
    busctl(&["status", "org.fcitx.Fcitx5"]).is_ok()
}
fn reload_addon(addon: &str) {
    if fcitx_running() {
        let _ = controller("ReloadAddonConfig", &["s", addon]);
    }
}

// --- INI files (SebType's settings and Fcitx5's addon configs) ---

fn ini_get(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix('='))
        .map(|v| v.trim().trim_matches('"').to_string())
}
/// Sets a key of a section-less config (classicui.conf), keeping its comments.
fn ini_set(text: &str, key: &str, value: &str) -> String {
    let line = format!("{key}={value}");
    let mut found = false;
    let mut out: Vec<String> = text
        .lines()
        .map(|l| {
            if !found && l.strip_prefix(key).is_some_and(|r| r.starts_with('=')) {
                found = true;
                line.clone()
            } else {
                l.to_string()
            }
        })
        .collect();
    if !found {
        out.push(line);
    }
    out.join("\n") + "\n"
}

fn write_if_changed(path: &PathBuf, text: &str) -> io::Result<bool> {
    if fs::read_to_string(path).ok().as_deref() == Some(text) {
        return Ok(false);
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, text)?;
    Ok(true)
}

// --- Languages: SebType's settings, in Super+Space order (the first is home) ---

/// SebType's three languages, those on first in their order, then those off. Without settings all are on.
pub fn langs() -> io::Result<Vec<(String, bool)>> {
    let text = fs::read_to_string(settings()).unwrap_or_default();
    let order = ini_get(&text, "Order").unwrap_or_else(|| LANGS.join(","));
    let mut out: Vec<(String, bool)> = Vec::new();
    for id in order.split(',').filter(|id| LANGS.contains(id)) {
        if !out.iter().any(|(i, _)| i == id) {
            out.push((id.to_string(), true));
        }
    }
    for id in LANGS {
        if !out.iter().any(|(i, _)| i == id) {
            out.push((id.to_string(), false));
        }
    }
    Ok(out)
}

pub fn set_langs(langs: &[(String, bool)]) -> io::Result<()> {
    let on: Vec<&str> = langs
        .iter()
        .filter(|(_, on)| *on)
        .map(|(id, _)| id.as_str())
        .collect();
    let text = format!("[Languages]\nOrder={}\n", on.join(","));
    if write_if_changed(&settings(), &text)? {
        reload_addon("sebtype");
    }
    Ok(())
}

// --- The candidate window: Fcitx5's classic UI draws it for Chinese and Japanese alike ---

pub fn candidates() -> Candidates {
    let ui = fs::read_to_string(classicui()).unwrap_or_default();
    let font = ini_get(&ui, "Font").unwrap_or_else(|| "Sans 10".into());
    Candidates {
        vertical: ini_get(&ui, "Vertical Candidate List").as_deref() == Some("True"),
        font_size: font
            .rsplit(' ')
            .next()
            .and_then(|n| n.parse().ok())
            .unwrap_or(10),
        picnic: ini_get(&ui, "Theme").as_deref() == Some(PICNIC),
    }
}

pub fn set_candidates(c: &Candidates) -> io::Result<bool> {
    let path = classicui();
    let mut ui = fs::read_to_string(&path).unwrap_or_default();
    let tf = |b: bool| if b { "True" } else { "False" };
    ui = ini_set(&ui, "Vertical Candidate List", tf(c.vertical));
    let font = ini_get(&ui, "Font").unwrap_or_else(|| "Sans 10".into());
    let family = font
        .rsplit_once(' ')
        .filter(|(_, n)| n.parse::<f32>().is_ok())
        .map_or(font.as_str(), |(f, _)| f);
    ui = ini_set(&ui, "Font", &format!("\"{family} {}\"", c.font_size));

    let saved = theme_dir().join("previous");
    let current = (ini_get(&ui, "Theme"), ini_get(&ui, "DarkTheme"));
    let mut theme_changed = false;
    if c.picnic {
        fs::create_dir_all(theme_dir())?;
        for (name, text) in picnic_files(c.font_size) {
            theme_changed |= write_if_changed(&theme_dir().join(name), &text)?;
        }
        if current.0.as_deref() != Some(PICNIC) {
            // Remember the system look, for 系统样式 and for setup-ime.sh --undo-configurator.
            let (t, d) = (
                current.0.unwrap_or("default".into()),
                current.1.unwrap_or("default".into()),
            );
            fs::write(&saved, format!("Theme={t}\nDarkTheme={d}\n"))?;
        }
        ui = ini_set(&ui, "Theme", PICNIC);
        ui = ini_set(&ui, "DarkTheme", PICNIC);
    } else if current.0.as_deref() == Some(PICNIC) {
        let prev = fs::read_to_string(&saved).unwrap_or_default();
        ui = ini_set(
            &ui,
            "Theme",
            &ini_get(&prev, "Theme").unwrap_or("default".into()),
        );
        ui = ini_set(
            &ui,
            "DarkTheme",
            &ini_get(&prev, "DarkTheme").unwrap_or("default".into()),
        );
    }
    let changed = write_if_changed(&path, &ui)? | theme_changed;
    if changed {
        reload_addon("classicui");
    }
    Ok(changed)
}

// --- Engines ---

/// Rime's deploy, by SebType's input method: Rime rereads its files and rebuilds what changed.
pub fn redeploy_rime() -> io::Result<()> {
    if fcitx_running() {
        controller(
            "SetConfig",
            &["sv", "fcitx://config/addon/sebtype/deploy", "s", ""],
        )?;
    }
    Ok(())
}

/// SebType's input method forgets before it answers (#375): the engine closes its files, deletes what it
/// learned and opens new ones, between two keys. Its answer is what it couldn't delete, and why. Without
/// Fcitx5 nothing has them open.
fn forget(lang: &str) -> io::Result<()> {
    let out = busctl(&[
        "--json=short",
        "call",
        "org.fcitx.Fcitx5",
        "/sebtype",
        "org.sebtype.Core1",
        "Forget",
        "s",
        lang,
    ])?;
    let answer: serde_json::Value = serde_json::from_str(&out).map_err(io::Error::other)?;
    match answer["data"][0].as_str() {
        Some("") => Ok(()),
        Some(left) => Err(io::Error::other(left.to_string())),
        None => Err(io::Error::other(format!("Forget answered {out}"))),
    }
}

pub fn forget_rime() -> io::Result<usize> {
    if !fcitx_running() {
        return crate::rime::forget(&rime_dir());
    }
    let n = crate::rime::learned(&rime_dir())?.len();
    forget("zh")?;
    Ok(n)
}

/// Mozc, in SebType's input method, reads its config and dictionaries when it starts: it saves and closes
/// (before the call returns), and the next Japanese key starts it again.
pub fn restart_mozc() {
    if fcitx_running() {
        let _ = controller(
            "SetConfig",
            &["sv", "fcitx://config/addon/sebtype/mozc", "s", ""],
        );
    }
}
pub fn forget_mozc() -> io::Result<usize> {
    if !fcitx_running() {
        return crate::mozc::forget(&mozc_dir());
    }
    let n = crate::mozc::learned(&mozc_dir());
    forget("ja")?;
    Ok(n)
}

// --- Sync (#180) ---

/// SebType's own folder: sync's server, username and last outcome, and its client.
pub fn sebtype_dir() -> PathBuf {
    data().join("sebtype")
}

pub fn python() -> Command {
    Command::new("python3")
}

/// Rime's deploy and Mozc's restart for a sync's pull: the input method does them once typing is idle,
/// as they drop what is being typed (#373). The Configurator's own changes and forgetting do them at once.
pub fn redeploy_rime_when_idle() -> io::Result<()> {
    if fcitx_running() {
        controller(
            "SetConfig",
            &[
                "sv",
                "fcitx://config/addon/sebtype/deploy-when-idle",
                "s",
                "",
            ],
        )?;
    }
    Ok(())
}
pub fn restart_mozc_when_idle() {
    if fcitx_running() {
        let _ = controller(
            "SetConfig",
            &["sv", "fcitx://config/addon/sebtype/mozc-when-idle", "s", ""],
        );
    }
}

/// Rime's sync, which SebType's input method runs when Fcitx5 saves: it merges the other devices' snapshots into
/// the learned words and writes this PC's into `own`. Without a running Fcitx5 there is nothing to wait for.
pub fn sync_rime(own: &Path) -> io::Result<()> {
    if !fcitx_running() {
        return Ok(());
    }
    await_snapshot(own, Duration::from_secs(30), || {
        controller("Save", &[]).map(|_| ())
    })
}

/// Asks for Rime's sync every 5 s until this PC's snapshot in `own` is newer than the first ask, at most
/// `timeout`. The input method puts it off until typing is idle (#373) and Rime skips it while it is busy
/// (deploying after a start); an error when it didn't write in time, as the snapshot that would go up is
/// an old one.
fn await_snapshot(
    own: &Path,
    timeout: Duration,
    mut save: impl FnMut() -> io::Result<()>,
) -> io::Result<()> {
    let newest = || {
        fs::read_dir(own)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".userdb.txt"))
            .filter_map(|e| e.metadata().ok()?.modified().ok())
            .max()
    };
    let start = SystemTime::now();
    let end = Instant::now() + timeout;
    let mut ask = Instant::now();
    while Instant::now() < end {
        if Instant::now() >= ask {
            save()?;
            ask += Duration::from_secs(5);
        }
        std::thread::sleep(Duration::from_millis(300));
        if newest().is_some_and(|t| t >= start) {
            std::thread::sleep(Duration::from_secs(1)); // a schema's dictionaries are written one by one
            return Ok(());
        }
    }
    Err(io::Error::other("Rime didn't write its snapshot in time"))
}

const SYNC_TIMER: &str = "sebtype-sync.timer";
const SYNC_PATH: &str = "sebtype-sync.path";
/// The one sync planned after the network changed: a transient timer (network_changed).
const SYNC_SOON: &str = "sebtype-sync-soon";
const NETWORK_STATE: &str = "network-state";

fn sync_units(exe: &Path) -> [(&'static str, String); 4] {
    let exe = exe.display();
    [
        (
            "sebtype-sync.service",
            format!(
                "[Unit]\nDescription=SebType sync with your own server\n\n[Service]\nType=oneshot\nExecStart=\"{exe}\" --sync\n"
            ),
        ),
        (
            SYNC_TIMER,
            // As the phone: every half hour, and soon after login.
            "[Unit]\nDescription=SebType sync every half hour\n\n[Timer]\nOnStartupSec=2min\nOnUnitActiveSec=30min\n\n[Install]\nWantedBy=timers.target\n".into(),
        ),
        (
            SYNC_PATH,
            // And when the network comes back (#377): the DNS servers change then, and systemd-resolved or
            // NetworkManager rewrites its resolv.conf, which a user unit can watch without root.
            "[Unit]\nDescription=SebType sync when the network comes back\n\n[Path]\n\
             PathChanged=/run/systemd/resolve/resolv.conf\nPathChanged=/run/NetworkManager/resolv.conf\n\
             PathChanged=/etc/resolv.conf\nUnit=sebtype-sync-network.service\n\n[Install]\nWantedBy=paths.target\n"
                .into(),
        ),
        (
            // Returns at once: systemd doesn't watch the paths while it runs. No start limit: the path's
            // own limit is enough for something this quick, and hitting one would stop the trigger.
            "sebtype-sync-network.service",
            format!(
                "[Unit]\nDescription=SebType sync planned after the network changed\nStartLimitIntervalSec=0\n\n[Service]\nType=oneshot\nExecStart=\"{exe}\" --network-changed\n"
            ),
        ),
    ]
}

/// The network trigger's state, in SebType's folder (#377): how many times the network has changed,
/// and when the last sync started on CLOCK_BOOTTIME with the boot's id. That clock counts suspend, and
/// setting the wall clock doesn't move it.
#[derive(Debug, Default, PartialEq)]
struct NetworkState {
    changes: u64,
    last_sync: Option<BootTime>,
}
type BootTime = (String, Duration);

impl NetworkState {
    fn load(dir: &Path) -> Self {
        let text = fs::read_to_string(dir.join(NETWORK_STATE)).unwrap_or_default();
        let mut s = Self::default();
        for line in text.lines() {
            match line.split(' ').collect::<Vec<_>>()[..] {
                ["changes", n] => s.changes = n.parse().unwrap_or(0),
                ["last-sync", boot, secs] => {
                    s.last_sync = secs
                        .parse()
                        .ok()
                        .map(|t| (boot.to_string(), Duration::from_secs_f64(t)))
                }
                _ => {}
            }
        }
        s
    }
    fn save(&self, dir: &Path) -> io::Result<()> {
        let mut text = format!("changes {}\n", self.changes);
        if let Some((boot, t)) = &self.last_sync {
            text += &format!("last-sync {boot} {}\n", t.as_secs_f64());
        }
        fs::create_dir_all(dir)?;
        fs::write(dir.join(NETWORK_STATE), text)
    }
}

/// /proc/uptime is CLOCK_BOOTTIME.
fn boot_time() -> Option<BootTime> {
    let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
    let up = fs::read_to_string("/proc/uptime").ok()?;
    let up: f64 = up.split(' ').next()?.parse().ok()?;
    Some((boot.trim().to_string(), Duration::from_secs_f64(up)))
}

/// Since the last sync started, if it was on this boot.
fn since(last: &Option<BootTime>, now: &Option<BootTime>) -> Option<Duration> {
    match (last, now) {
        (Some((b, then)), Some((boot, now))) if b == boot => now.checked_sub(*then),
        _ => None,
    }
}

// These run with the schedule locked (sync::schedule_locked), so none plans a sync once sync is off.

/// The network changed (the path unit's --network-changed, #377): counts the change and plans one sync
/// for it, which later changes join while it is planned.
pub fn network_changed(enabled: bool) -> io::Result<()> {
    if !enabled {
        return Ok(());
    }
    let dir = sebtype_dir();
    let mut s = NetworkState::load(&dir);
    s.changes += 1;
    s.save(&dir)?;
    plan_network_sync(&s)
}

/// Notes when a sync starts, and returns the changes it has seen.
pub fn sync_started() -> u64 {
    let dir = sebtype_dir();
    let mut s = NetworkState::load(&dir);
    s.last_sync = boot_time();
    let _ = s.save(&dir);
    s.changes
}

/// A sync that was running when the network changed may have missed it, and the sync planned for the
/// change may have come while it ran: it plans another.
pub fn after_sync(seen: u64, enabled: bool) {
    let s = NetworkState::load(&sebtype_dir());
    if enabled && s.changes > seen {
        let _ = plan_network_sync(&s);
    }
}

fn plan_network_sync(s: &NetworkState) -> io::Result<()> {
    let delay = network_sync_delay(since(&s.last_sync, &boot_time()));
    // Fails while one is planned (its unit exists): that one takes this change too.
    Command::new("systemd-run")
        .args([
            "--user",
            "--quiet",
            "--collect",
            &format!("--unit={SYNC_SOON}"),
            &format!("--on-active={}", delay.as_secs()),
            "--timer-property=AccuracySec=1s",
            "--timer-property=RemainAfterElapse=no",
            "systemctl",
            "--user",
            "start",
            "--no-block",
            "sebtype-sync.service",
        ])
        .output()?;
    Ok(())
}

/// A connection rewrites resolv.conf more than once: the sync waits for it to settle. Syncs start at
/// least 2 minutes apart, so DNS rewritten after each one (a VPN) can't keep them going.
fn network_sync_delay(since_last_sync: Option<Duration>) -> Duration {
    let (settle, apart) = (Duration::from_secs(15), Duration::from_secs(120));
    since_last_sync.map_or(settle, |t| apart.saturating_sub(t).max(settle))
}

/// Syncs every half hour and when the network comes back, with systemd user units, while sync is on.
pub fn schedule(on: bool) -> io::Result<()> {
    let dir = config().join("systemd/user");
    let systemctl = |args: &[&str]| -> io::Result<()> {
        let out = Command::new("systemctl")
            .arg("--user")
            .args(args)
            .output()?;
        if !out.status.success() {
            return Err(io::Error::other(
                String::from_utf8_lossy(&out.stderr).trim().to_string(),
            ));
        }
        Ok(())
    };
    let units = sync_units(&env::current_exe()?);
    if on {
        for (name, text) in &units {
            write_if_changed(&dir.join(name), text)?;
        }
        systemctl(&["daemon-reload"])?;
        return systemctl(&["enable", "--now", SYNC_TIMER, SYNC_PATH]);
    }
    if !dir.join(SYNC_TIMER).exists() {
        return Ok(());
    }
    let _ = systemctl(&["disable", "--now", SYNC_TIMER, SYNC_PATH]);
    // A --network-changed waiting for the schedule lock stops too.
    let _ = systemctl(&[
        "stop",
        &format!("{SYNC_SOON}.timer"),
        "sebtype-sync-network.service",
    ]);
    for (name, _) in &units {
        // A schedule from before #377 has only the service and the timer.
        let _ = fs::remove_file(dir.join(name));
    }
    let _ = fs::remove_file(sebtype_dir().join(NETWORK_STATE));
    systemctl(&["daemon-reload"])
}

pub fn open_url(url: &str) {
    let _ = Command::new("xdg-open").arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sync waits for Rime's snapshot, and fails when the save never came (typing never idle, #373), so
    /// the old snapshot doesn't go up and Setup keeps the words.
    #[test]
    fn a_save_that_never_comes_fails_the_sync() {
        let d = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/snapshot-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let old = d.join("rime_ice.userdb.txt");
        fs::write(&old, "old").unwrap();
        let file = fs::File::options().write(true).open(&old).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();
        let mut asked = 0;
        let waited = await_snapshot(&d, Duration::from_secs(6), || {
            asked += 1;
            Ok(())
        });
        assert!(waited.is_err(), "no new snapshot");
        assert_eq!(asked, 2, "asked again after 5 s");
        assert!(await_snapshot(&d, Duration::from_secs(6), || fs::write(&old, "new")).is_ok());
        fs::remove_dir_all(&d).unwrap();
    }

    /// The network coming back plans a sync (#377): the path unit's service only plans it, so it never
    /// blocks the trigger.
    #[test]
    fn sync_runs_when_the_network_comes_back() {
        let units = sync_units(Path::new("/opt/sebtype/sebtype-configurator"));
        let text = |name: &str| &units.iter().find(|(n, _)| *n == name).unwrap().1;
        let path = text(SYNC_PATH);
        assert!(path.contains("\n[Path]\nPathChanged=/run/systemd/resolve/resolv.conf\n"));
        assert!(path.contains("\nPathChanged=/run/NetworkManager/resolv.conf\n"));
        assert!(path.contains("\nUnit=sebtype-sync-network.service\n"));
        assert!(path.ends_with("\n[Install]\nWantedBy=paths.target\n"));
        let network = text("sebtype-sync-network.service");
        assert!(
            network.contains("\nStartLimitIntervalSec=0\n"),
            "a burst would stop the trigger"
        );
        assert!(
            network.contains("ExecStart=\"/opt/sebtype/sebtype-configurator\" --network-changed\n")
        );
        assert!(text("sebtype-sync.service")
            .contains("ExecStart=\"/opt/sebtype/sebtype-configurator\" --sync\n"));
    }

    /// A network sync waits for the change to settle, and starts at least 2 minutes after the last.
    #[test]
    fn network_state_counts_on_the_boot_clock() {
        let d = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "target/test-tmp/network-state-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&d);
        assert_eq!(NetworkState::load(&d), NetworkState::default());
        let at = |boot: &str, t: f64| Some((boot.to_string(), Duration::from_secs_f64(t)));
        let s = NetworkState {
            changes: 3,
            last_sync: at("b1", 100.5),
        };
        s.save(&d).unwrap();
        assert_eq!(NetworkState::load(&d), s);
        fs::remove_dir_all(&d).unwrap();
        assert_eq!(
            since(&at("b1", 100.5), &at("b1", 130.5)),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            since(&at("b1", 100.0), &at("b2", 130.0)),
            None,
            "another boot"
        );
        assert_eq!(since(&None, &at("b1", 130.0)), None);
        let now = boot_time().unwrap();
        assert_eq!(boot_time().unwrap().0, now.0);
    }

    #[test]
    fn network_syncs_start_apart() {
        let s = Duration::from_secs;
        assert_eq!(network_sync_delay(None), s(15));
        assert_eq!(network_sync_delay(Some(s(30))), s(90));
        assert_eq!(network_sync_delay(Some(s(110))), s(15));
        assert_eq!(network_sync_delay(Some(s(3600))), s(15));
    }

    #[test]
    fn picnic_logo_follows_the_font_size() {
        for (size, w, h, margin) in [(9, 43, 44, 62), (10, 47, 48, 66), (24, 74, 75, 93)] {
            let files = picnic_files(size);
            let text = |name: &str| &files.iter().find(|(n, _)| *n == name).unwrap().1;
            assert!(text("logo.svg").starts_with(&format!(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"{w}\" height=\"{h}\" "
            )), "logo at {size} pt");
            assert!(
                text("theme.conf")
                    .contains(&format!("[InputPanel/ContentMargin]\nLeft={margin}\n")),
                "margin at {size} pt"
            );
            assert!(
                files.iter().all(|(_, t)| !t.contains('@')),
                "a placeholder left at {size} pt"
            );
        }
    }

    #[test]
    fn picnic_tab_has_room_for_its_corners_at_every_size() {
        for size in 9..=24 {
            let files = picnic_files(size);
            let conf = &files[0].1;
            let top: i32 = conf
                .split("[InputPanel/ContentMargin]")
                .nth(1)
                .and_then(|m| m.lines().find_map(|l| l.strip_prefix("Top=")))
                .unwrap()
                .parse()
                .unwrap();
            // The tab rises tab_h = Top - 7 px: its 12 px corner and the 4 px curve into the box need 15.
            assert!(
                (15..=24).contains(&(top - 7)),
                "tab {} px at {size} pt",
                top - 7
            );
        }
    }

    #[test]
    fn mozc_profile_prefers_legacy_folder_like_mozc() {
        // In the crate's target/, not /tmp (#211); removed when the test passes.
        let home = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "target/test-tmp/mozc-profile-{}",
            std::process::id()
        ));
        let config = home.join(".config");
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(config.join("mozc")).unwrap();
        assert_eq!(mozc_profile(&home, &config), config.join("mozc"));
        fs::create_dir(home.join(".mozc")).unwrap();
        assert_eq!(mozc_profile(&home, &config), home.join(".mozc"));
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn ini_set_replaces_or_appends_and_keeps_comments() {
        let t = "# Theme\nTheme=plasma\n# Font\nFont=\"Noto Sans 10\"\n";
        assert_eq!(
            ini_set(t, "Theme", PICNIC),
            "# Theme\nTheme=sebtype-picnic\n# Font\nFont=\"Noto Sans 10\"\n"
        );
        assert_eq!(ini_get(t, "Font").as_deref(), Some("Noto Sans 10"));
        assert!(ini_set(t, "DarkTheme", "x").ends_with("DarkTheme=x\n"));
    }

    /// The real Fcitx5 and Rime take what the app writes: run by test.sh in a private D-Bus session with
    /// its own Fcitx5 with SebType's input method on a copy of rime-ice, never the desktop's.
    #[test]
    #[ignore]
    fn private_fcitx5_takes_languages_and_chinese_settings() {
        use crate::rime::{self, Chinese};
        assert!(fcitx_running(), "no Fcitx5 on this bus");
        let on = |v: &[(&str, bool)]| {
            v.iter()
                .map(|(i, b)| (i.to_string(), *b))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            langs().unwrap(),
            on(&[("en", true), ("zh", true), ("ja", true)])
        );
        set_langs(&on(&[("zh", true), ("en", true), ("ja", false)])).unwrap();
        assert_eq!(
            langs().unwrap(),
            on(&[("zh", true), ("en", true), ("ja", false)])
        );

        let dir = rime_dir();
        let c = Chinese {
            traditional: true,
            full_width_punctuation: false,
            emoji: false,
            fuzzy: vec![true; 1],
            learn: false,
            page_size: 8,
        };
        assert!(rime::save(&dir, &c).unwrap());
        assert_eq!(
            rime::load(&dir),
            Chinese {
                fuzzy: [vec![true], vec![false; rime::FUZZY.len() - 1]].concat(),
                ..c
            }
        );
        let built = dir.join("build/rime_ice.schema.yaml");
        let before = fs::metadata(&built).and_then(|m| m.modified()).ok();
        redeploy_rime().unwrap();
        let end = std::time::Instant::now() + std::time::Duration::from_secs(240);
        while fs::metadata(&built).and_then(|m| m.modified()).ok() == before {
            assert!(std::time::Instant::now() < end, "Rime did not redeploy");
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        std::thread::sleep(std::time::Duration::from_secs(2)); // the deploy writes it in steps
        let schema = fs::read_to_string(&built).unwrap();
        // Built schemas have sorted keys: a switch's reset comes right after its name.
        for (name, reset) in [("ascii_punct", 1), ("traditionalization", 1), ("emoji", 0)] {
            assert!(
                schema.contains(&format!("  - name: {name}\n    reset: {reset}\n")),
                "{name} reset {reset}"
            );
        }
        assert!(schema.contains("\"derive/^z/zh/\""), "fuzzy z = zh");
        assert!(schema.contains("menu:\n  page_size: 8\n"), "page size");
        let translator = schema.split("\ntranslator:\n").nth(1).unwrap();
        assert!(
            translator
                .split("\n")
                .take_while(|l| l.starts_with(' '))
                .any(|l| l == "  enable_user_dict: false"),
            "learn"
        );

        // Picnic with SebType's pig (#94); test.sh then draws this window in a nested KWin.
        let picnic = Candidates {
            vertical: false,
            font_size: 10,
            picnic: true,
        };
        assert!(set_candidates(&picnic).unwrap());
        assert!(fs::read_to_string(theme_dir().join("logo.svg"))
            .unwrap()
            .contains(" width=\"47\" height=\"48\" "));
        assert!(candidates().picnic);
    }

    /// The Configurator's forget while SebType's input method has Rime and Mozc open: run by
    /// pc/linux/test-forget.py in test.sh's private Fcitx5, which types before and after (#375).
    #[test]
    #[ignore]
    fn private_fcitx5_forgets() {
        assert!(fcitx_running(), "no Fcitx5 on this bus");
        // Mozc may hold what it learned in memory only: it saves every few minutes.
        let (rime, mozc) = (forget_rime(), forget_mozc());
        println!("Rime: {rime:?}, Mozc: {mozc:?}");
        assert!(rime.is_ok() && mozc.is_ok());
    }
}
