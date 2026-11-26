//! Linux: Fcitx5 with SebType's input method (linux/, #190), which hosts Rime and Mozc, set up by
//! pc/linux/setup-ime.sh. A running Fcitx5 is told over D-Bus (busctl); without one, the files are
//! written and read when it starts.

use crate::{conf, write_file, Candidates};
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
/// SebType's pig (logo.svg) at the start of the Picnic window (#94), inside its top left corner as Windows
/// draws it, so the window is one flat rectangle (#461). Fcitx5 scales theme images with the DPI but not
/// with the font, so the pig and the margins are sized here, in px at 96 dpi.
fn picnic_files(font_size: i32) -> [(&'static str, String); 6] {
    // A line of Noto Sans CJK is 1.448 em, 2 px taller than Microsoft YaHei's on Windows: the pig is
    // Windows' (its row and the 12 px margin, by 10/7), 52 px at 14 pt, at the 12 px margin, and the rows
    // start 6 + 9 px right of it. Its 3 px TextMargin is the content's too. The arrows' images are as
    // tall as the pinyin row (TextMargin 4 + 4), so they sit on its middle.
    let line = (f64::from(font_size) * 4.0 / 3.0 * 1.448).round() as i32;
    let height = (line - 2 + 12) * 10 / 7;
    let width = height * 158 / 160; // the logo image is 158x160
    let row = line + 8;
    let arrow = |svg: &str| {
        svg.replace("@ROW@", &row.to_string())
            .replace("@MIDDLE@", &(f64::from(row) / 2.0).to_string())
    };
    [
        (
            "theme.conf",
            include_str!("../fcitx5-theme/theme.conf")
                .replace("@CONTENT_LEFT@", &(12 + width + 6 + 9 - 3).to_string()),
        ),
        (
            "logo.svg",
            include_str!("../fcitx5-theme/logo.svg")
                .replace("@WIDTH@", &width.to_string())
                .replace("@HEIGHT@", &height.to_string()),
        ),
        (
            "panel.svg",
            include_str!("../fcitx5-theme/panel.svg").into(),
        ),
        (
            "highlight.svg",
            include_str!("../fcitx5-theme/highlight.svg").into(),
        ),
        ("prev.svg", arrow(include_str!("../fcitx5-theme/prev.svg"))),
        ("next.svg", arrow(include_str!("../fcitx5-theme/next.svg"))),
    ]
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
pub fn data() -> PathBuf {
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
/// Calls the running Fcitx5's controller. Never starts one: D-Bus would start it outside KWin, where
/// Wayland apps don't reach it.
fn controller(method: &str, args: &[&str]) -> io::Result<String> {
    let mut a = vec![
        "--json=short",
        "--auto-start=no",
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

// --- INI files (Fcitx5's addon configs) ---

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

// --- Languages: SebType's settings, in Super+Space order (the first is home) ---

/// SebType's three languages, those on first in their order, then those off. Without settings all are on.
pub fn langs() -> io::Result<Vec<(String, bool)>> {
    let text = fs::read_to_string(settings()).unwrap_or_default();
    let order =
        conf::value(&text, "Languages", "Order").map_or_else(|| LANGS.join(","), str::to_string);
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
    let order = format!("Order={}\n", on.join(","));
    set_settings(|old| conf::set_section(old, "Languages", &order))
}

/// sebtype.conf with `change` made; the input method reads it again when it changed.
fn set_settings(change: impl FnOnce(&str) -> String) -> io::Result<()> {
    let old = fs::read_to_string(settings()).unwrap_or_default();
    if write_file(&settings(), &change(&old))? {
        reload_addon("sebtype");
    }
    Ok(())
}

// --- Learning: sebtype.conf's [Learning] ---

pub fn learning() -> bool {
    conf::learning(&fs::read_to_string(settings()).unwrap_or_default())
}
/// Fcitx5 has applied it when this returns. Told again on a retry, as the file may already say so while the
/// add-on doesn't (#374); Fcitx5 not running reads it when it starts.
pub fn set_learning(on: bool) -> io::Result<()> {
    let path = settings();
    write_file(
        &path,
        &conf::set_learning(&fs::read_to_string(&path).unwrap_or_default(), on),
    )?;
    if fcitx_running() {
        controller("ReloadAddonConfig", &["s", "sebtype"])?;
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
        pinyin_row: conf::value(
            &fs::read_to_string(settings()).unwrap_or_default(),
            "Candidates",
            "PinyinRow",
        ) != Some("0"),
    }
}

/// Whether a candidate window style was ever chosen: Picnic now, or once (it remembered the look it
/// replaced). Before that, setup offers Picnic (#471).
pub fn candidates_chosen() -> bool {
    candidates().picnic || theme_dir().join("previous").exists()
}

/// The pinyin row is sebtype.conf's (the input method's); the rest classicui's.
pub fn set_candidates(c: &Candidates) -> io::Result<bool> {
    set_settings(|old| {
        conf::set_section(
            old,
            "Candidates",
            if c.pinyin_row { "" } else { "PinyinRow=0\n" },
        )
    })?;
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
            theme_changed |= write_file(&theme_dir().join(name), &text)?;
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
    let changed = write_file(&path, &ui)? | theme_changed;
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
/// With the words lock (crate::sync::words_locked), which a pull holds: Forget keeps the other devices' records as
/// it reads them, so none may change in between (#409).
pub fn forget_mozc() -> io::Result<usize> {
    crate::sync::words_locked(|| {
        if !fcitx_running() {
            return crate::mozc::forget(&mozc_dir());
        }
        let n = crate::mozc::learned(&mozc_dir());
        forget("ja")?;
        Ok(n)
    })?
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
/// Fcitx5 returns once it has the request.
pub fn queue_rime_redeploy() -> io::Result<()> {
    redeploy_rime_when_idle()
}
pub fn restart_mozc_when_idle() -> io::Result<()> {
    if fcitx_running() {
        controller(
            "SetConfig",
            &["sv", "fcitx://config/addon/sebtype/mozc-when-idle", "s", ""],
        )?;
    }
    Ok(())
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
            write_file(&dir.join(name), text)?;
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

// --- Updates (#422) ---

/// The installed version: the newer of this Configurator's and the sebtype package's, so a release
/// installed without a new Configurator (its RPMs, pc/linux/README.md) isn't offered again.
pub fn installed_version() -> String {
    let rpm = Command::new("rpm")
        .args(["-q", "--qf", "%{VERSION}", "sebtype"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
    let built = crate::update::BUILT.to_string();
    match rpm.as_deref().and_then(crate::update::parse) {
        Some(v) if crate::update::parse(&built).is_none_or(|b| v > b) => rpm.unwrap(),
        _ => built,
    }
}

/// Where an install's private download folder goes: the account's runtime folder (0700, in memory),
/// else its cache.
pub fn updates_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .filter(|d| !d.is_empty())
        .map_or_else(|| xdg("XDG_CACHE_HOME", ".cache"), PathBuf::from)
        .join("sebtype-updates")
}

/// The freedesktop notification, as SebType Configurator. A click on it or its button opens the
/// About page, from this process, which waits for it (sebtype-update.service keeps what it starts).
/// `shown` runs once the notification is up.
pub fn notify_update(
    summary: &str,
    body: &str,
    action: &str,
    shown: &mut dyn FnMut(),
) -> io::Result<()> {
    use dbus::{
        arg::{PropMap, Variant},
        blocking::Connection,
        message::MatchRule,
    };
    use std::sync::{Arc, Mutex};
    const NAME: &str = "org.freedesktop.Notifications";
    let c = Connection::new_session().map_err(io::Error::other)?;
    // (the notification's id, clicked or closed): the signals may come before Notify returns
    let seen: Arc<Mutex<(u32, Vec<(u32, bool)>)>> = Default::default();
    let s = seen.clone();
    c.add_match(
        MatchRule::new_signal(NAME, "ActionInvoked"),
        move |(id, _): (u32, String), _, _| {
            s.lock().unwrap().1.push((id, true));
            true
        },
    )
    .map_err(io::Error::other)?;
    let s = seen.clone();
    c.add_match(
        MatchRule::new_signal(NAME, "NotificationClosed"),
        move |(id, _): (u32, u32), _, _| {
            s.lock().unwrap().1.push((id, false));
            true
        },
    )
    .map_err(io::Error::other)?;
    let mut hints = PropMap::new();
    hints.insert(
        "desktop-entry".into(),
        Variant(Box::new("sebtype-configurator".to_string())),
    );
    let (id,): (u32,) = c
        .with_proxy(
            NAME,
            "/org/freedesktop/Notifications",
            Duration::from_secs(10),
        )
        .method_call(
            NAME,
            "Notify",
            // stays until it is clicked or closed
            (
                "SebType",
                0u32,
                "sebtype-configurator",
                summary,
                body,
                vec!["default", action, "update", action],
                hints,
                0i32,
            ),
        )
        .map_err(io::Error::other)?;
    seen.lock().unwrap().0 = id;
    shown();
    let end = Instant::now() + Duration::from_secs(12 * 3600);
    let outcome = loop {
        if let Some(&(_, clicked)) = seen.lock().unwrap().1.iter().find(|(n, _)| *n == id) {
            break Some(clicked);
        }
        if Instant::now() >= end {
            break None;
        }
        c.process(Duration::from_secs(30))
            .map_err(io::Error::other)?;
    };
    match outcome {
        Some(true) => {
            eprintln!("update: opening the About page");
            Command::new(env::current_exe()?).arg("--update").spawn()?;
        }
        Some(false) => {}
        None => {
            let _: Result<(), _> = c
                .with_proxy(
                    NAME,
                    "/org/freedesktop/Notifications",
                    Duration::from_secs(10),
                )
                .method_call(NAME, "CloseNotification", (id,));
        }
    }
    Ok(())
}

/// The admin side of an update, run as root: copies the installer into a new folder only root can
/// write, checks it there against the SHA-256 it was downloaded with, and runs its RPM install step
/// from that copy, so a file changed after the Configurator's check isn't run. Arguments: <sha256>
/// <installer>. Exit 3: the file isn't the release's.
const ROOT_INSTALL: &str = r#"set -eu
[ $# -eq 2 ] || { echo "expected sha256 and installer"; exit 2; }
d=$(mktemp -d)
chmod 700 "$d"
trap 'rm -rf "$d"' EXIT
f=$d/$(basename -- "$2")
cp -- "$2" "$f"
printf '%s  %s\n' "$1" "$f" | sha256sum --check --status - || { echo "$(basename -- "$2") isn't the release's"; exit 3; }
/bin/sh "$f" --install-rpms-only"#;

pub(crate) fn root_install(program: &[&str], files: &[crate::update::Download]) -> Command {
    let mut c = Command::new(program[0]);
    c.args(&program[1..]).args(["-c", ROOT_INSTALL, "sh"]);
    for (path, sha) in files {
        c.arg(sha).arg(path);
    }
    c
}

/// The last line a command printed, for its error.
pub(crate) fn last_line(out: &std::process::Output, or: &str) -> String {
    [&out.stderr, &out.stdout]
        .iter()
        .find_map(|o| {
            let o = String::from_utf8_lossy(o);
            o.lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_string())
        })
        .unwrap_or_else(|| or.to_string())
}

/// Runs the self-extracting installer's root RPM step through pkexec, verifying its SHA-256 inside
/// a root-only temp directory (TOCTOU-safe).
pub(crate) fn run_root_installer(installer: &Path) -> io::Result<()> {
    use sha2::{Digest, Sha256};
    let mut file = fs::File::open(installer)?;
    let mut hasher = Sha256::new();
    io::copy(&mut file, &mut hasher)?;
    let sha = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let files = vec![(installer.to_path_buf(), sha)];
    let out = root_install(&["pkexec", "/bin/sh"], &files).output()?;
    match out.status.code() {
        Some(0) => Ok(()),
        Some(126 | 127) => Err(io::Error::other(
            "not allowed: the admin prompt was cancelled",
        )),
        _ => Err(io::Error::other(last_line(&out, "installer failed"))),
    }
}

/// Parses `busctl --json=short call ... CurrentInputMethod` output (`{"type":"s","data":["sebtype"]}`).
fn parse_current_im(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("data")?.get(0)?.as_str().map(str::to_string)
}

/// True when Fcitx5 is running on the session bus and its active input method is `sebtype` (#442).
pub(crate) fn sebtype_active() -> bool {
    controller("CurrentInputMethod", &[])
        .ok()
        .and_then(|out| parse_current_im(&out))
        .is_some_and(|im| im == "sebtype")
}

/// Parses `busctl --json=short call ... InputMethodGroups` (`{"type":"as","data":[["Default","Rime"]]}`).
fn parse_groups(json: &str) -> Option<Vec<String>> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v["data"][0]
        .as_array()?
        .iter()
        .map(|g| g.as_str().map(str::to_string))
        .collect()
}

/// Parses `... InputMethodGroupInfo s <group>`
/// (`{"type":"sa(ss)","data":["us",[["sebtype",""],["rime",""]]]}`): its layout and input methods.
fn parse_group(json: &str) -> Option<(String, Vec<(String, String)>)> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let layout = v["data"][0].as_str()?.to_string();
    let ims = v["data"][1]
        .as_array()?
        .iter()
        .map(|im| Some((im[0].as_str()?.to_string(), im[1].as_str()?.to_string())))
        .collect::<Option<_>>()?;
    Some((layout, ims))
}

/// Parses `... AvailableInputMethods` (`{"type":"a(ssssssb)","data":[[["sebtype","SebType",...],...]]}`): the
/// input methods' names.
fn parse_im_names(json: &str) -> Option<Vec<String>> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v["data"][0]
        .as_array()?
        .iter()
        .map(|im| im[0].as_str().map(str::to_string))
        .collect()
}

/// A group's name, layout and input methods (each with its layout).
type Group = (String, String, Vec<(String, String)>);

/// The running Fcitx5's groups with fcitx5-rime's Rime (#542), or why they couldn't all be read: a group
/// unread may have it. None while it can't tell: no Fcitx5 runs, or it doesn't know SebType's input method yet
/// (just restarted), which it would drop from a group (setup-ime.sh's step 7 waits the same way).
fn rime_groups() -> io::Result<Option<Vec<Group>>> {
    if !fcitx_running() {
        return Ok(None);
    }
    let unread = |what: &str, out: &str| io::Error::other(format!("{what}: {out}"));
    let out = controller("AvailableInputMethods", &[])?;
    let ims = parse_im_names(&out).ok_or_else(|| unread("AvailableInputMethods", &out))?;
    if !ims.iter().any(|im| im == "sebtype") {
        return Ok(None);
    }
    let out = controller("InputMethodGroups", &[])?;
    let names = parse_groups(&out).ok_or_else(|| unread("InputMethodGroups", &out))?;
    let mut groups = Vec::new();
    for g in names {
        let out = controller("InputMethodGroupInfo", &["s", &g])?;
        let (layout, ims) = parse_group(&out).ok_or_else(|| unread(&g, &out))?;
        if ims.iter().any(|(im, _)| im == "rime") {
            groups.push((g, layout, ims));
        }
    }
    Ok(Some(groups))
}

/// The names of Fcitx5's groups where Rime (fcitx5-rime) won't type Chinese: SebType keeps it off (#542).
/// None while Fcitx5 can't tell (rime_groups).
pub fn rime_group_names() -> Result<Option<Vec<String>>, String> {
    rime_groups()
        .map(|gs| gs.map(|gs| gs.into_iter().map(|(g, ..)| g).collect()))
        .map_err(|e| e.to_string())
}

/// A group's input methods with SebType's for Rime. When the group starts on the keyboard, Rime, Mozc or
/// SebType's, as setup-ime.sh's step 7 lays out the first group: SebType's first (its own entry, with its
/// layout, if the group had one), without keyboard-us, Rime and Mozc, which it types; others stay, a keyboard of
/// the group's own layout too. Fcitx5
/// starts a group on its first input method, and no key switches to another (step 8), so a group that starts
/// on another (pinyin, a keyboard of another layout than the group's) keeps it first: SebType's takes Rime's
/// place only.
fn sebtype_for_rime(layout: &str, ims: &[(String, String)]) -> Vec<(String, String)> {
    const TYPED: [&str; 4] = ["sebtype", "keyboard-us", "rime", "mozc"];
    let types = |im: &str| TYPED.contains(&im) || im == format!("keyboard-{layout}");
    let sebtype = ims.iter().find(|(im, _)| im == "sebtype").cloned();
    if ims.first().is_some_and(|(im, _)| !types(im)) {
        return ims
            .iter()
            .filter_map(|(im, l)| match im.as_str() {
                "rime" if sebtype.is_some() => None,
                "rime" => Some(("sebtype".into(), l.clone())),
                _ => Some((im.clone(), l.clone())),
            })
            .collect();
    }
    let others = ims.iter().filter(|(im, _)| !TYPED.contains(&im.as_str()));
    std::iter::once(sebtype.unwrap_or(("sebtype".into(), String::new())))
        .chain(others.cloned())
        .collect()
}

/// The line setup-ime.sh's --undo-all reads (#611, groups_record there) for SebType's input method put in
/// `group`, which had `before` and now has `after`: its name, 0 (setup didn't make it), its default input
/// method in `profile`, and the input methods taken out, in order.
fn record_line(
    profile: &str,
    group: &str,
    before: &[(String, String)],
    after: &[(String, String)],
) -> String {
    let mut default = "";
    let (mut in_group, mut name, mut im) = (false, "", "");
    for line in profile.lines().chain(["["]) {
        if line.starts_with('[') {
            if in_group && name == group && default.is_empty() {
                default = im;
            }
            let id = line.trim().trim_start_matches("[Groups/").trim_end_matches(']');
            in_group = line.starts_with("[Groups/")
                && !id.is_empty()
                && id.bytes().all(|b| b.is_ascii_digit());
            (name, im) = ("", "");
        } else if let Some(v) = line.strip_prefix("Name=") {
            name = v;
        } else if let Some(v) = line.strip_prefix("DefaultIM=") {
            im = v;
        }
    }
    let taken: Vec<&str> = before
        .iter()
        .map(|(im, _)| im.as_str())
        .filter(|&im| !after.iter().any(|(a, _)| a == im))
        .collect();
    format!("{group}\t0\t{default}\t{}\n", taken.join(" "))
}

/// A backup folder of its own in `dir`, named `time`, never one with an earlier copy in it: a retry in the same
/// second gets `<time>_2`, which a C-sorted `ls` lists after `<time>/…` (README, Removing SebType).
fn new_backup(dir: &Path, time: &str) -> io::Result<PathBuf> {
    let mut backup = dir.join(time);
    for n in 2.. {
        match fs::create_dir(&backup) {
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                backup = dir.join(format!("{time}_{n}"))
            }
            made => {
                made?;
                break;
            }
        }
    }
    Ok(backup)
}

/// Puts SebType's input method in Rime's place in each group with it (sebtype_for_rime), after a copy of Fcitx5's
/// profile as it is now in ~/.local/share/sebtype/backup/<time>, which gives Rime back after SebType is
/// removed. Nothing changes when a group can't be read.
pub fn use_sebtype_for_rime() -> io::Result<()> {
    let groups = rime_groups()?
        .ok_or_else(|| io::Error::other("Fcitx5 isn't running with SebType's input method"))?;
    if groups.is_empty() {
        return Ok(());
    }
    // The running groups, on disk for the copy.
    controller("Save", &[])?;
    let dir = data().join("sebtype/backup");
    fs::create_dir_all(&dir)?;
    let backup = new_backup(
        &dir,
        &chrono::Local::now().format("%Y%m%d-%H%M%S").to_string(),
    )?;
    fs::copy(config().join("fcitx5/profile"), backup.join("profile"))?;
    let profile = fs::read_to_string(backup.join("profile"))?;
    let mut record = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("groups.tsv"))?;
    for (group, layout, before) in groups {
        let ims = sebtype_for_rime(&layout, &before);
        let line = record_line(&profile, &group, &before, &ims);
        io::Write::write_all(&mut record, line.as_bytes())?;
        let count = ims.len().to_string();
        let mut args = vec!["ssa(ss)", &group, &layout, &count];
        for (im, l) in &ims {
            args.extend([im.as_str(), l.as_str()]);
        }
        controller("SetInputMethodGroupInfo", &args)?; // which saves the groups
    }
    Ok(())
}

// --- The setup wizard's ready check (#445) ---

/// The files pc/linux/setup-ime.sh looks in for a global `*_IM_MODULE`.
fn env_files() -> Vec<PathBuf> {
    let home = home();
    let mut files = vec![
        PathBuf::from("/etc/environment"),
        PathBuf::from("/etc/profile"),
    ];
    for dir in [
        PathBuf::from("/etc/environment.d"),
        PathBuf::from("/usr/lib/environment.d"),
        config().join("environment.d"),
        config().join("plasma-workspace/env"),
        PathBuf::from("/etc/profile.d"),
    ] {
        let mut found: Vec<PathBuf> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "conf" || e == "sh"))
            .collect();
        found.sort();
        files.extend(found);
    }
    for f in [
        ".profile",
        ".bash_profile",
        ".bashrc",
        ".zshenv",
        ".zprofile",
    ] {
        files.push(home.join(f));
    }
    files
}

/// `GTK_IM_MODULE=…` or `export QT_IM_MODULE=…`: a global IM module, which overrides Wayland text-input.
fn im_module_line(line: &str) -> bool {
    let l = line.trim_start();
    let l = l
        .strip_prefix("export")
        .filter(|r| r.starts_with(char::is_whitespace))
        .map_or(l, str::trim_start);
    l.split_once('=').is_some_and(|(name, _)| {
        name.strip_suffix("_IM_MODULE").is_some_and(|p| {
            !p.is_empty()
                && p.chars()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        })
    })
}

fn im_modules(files: &[PathBuf]) -> Vec<crate::setup::Need> {
    let mut out = Vec::new();
    for file in files {
        let Ok(text) = fs::read_to_string(file) else {
            continue;
        };
        for (i, l) in text.lines().enumerate().filter(|(_, l)| im_module_line(l)) {
            out.push(crate::setup::Need::ImModule {
                file: file.clone(),
                line: i + 1,
                text: l.trim().to_string(),
            });
        }
    }
    out
}

/// The apps Plasma starts get plasmashell's environment, which only a login sets: XMODIFIERS for XWayland
/// apps, and no global IM module. Without Plasma, this process's own.
fn session_env() -> String {
    procs("plasmashell")
        .first()
        .and_then(|pid| fs::read(format!("/proc/{pid}/environ")).ok())
        .map(|e| String::from_utf8_lossy(&e).replace('\0', "\n"))
        .unwrap_or_else(|| env::vars().map(|(k, v)| format!("{k}={v}\n")).collect())
}

fn session_ready(environ: &str) -> bool {
    environ.lines().any(|l| l == "XMODIFIERS=@im=fcitx") && !environ.lines().any(im_module_line)
}

/// This account's processes named `name`.
fn procs(name: &str) -> Vec<u32> {
    use std::os::unix::fs::MetadataExt;
    let uid = |path: &str| fs::metadata(path).map(|m| m.uid()).ok();
    let me = uid("/proc/self");
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .filter(|pid: &u32| {
            fs::read_to_string(format!("/proc/{pid}/comm")).is_ok_and(|c| c.trim_end() == name)
                && uid(&format!("/proc/{pid}")) == me
        })
        .collect()
}

fn parent(pid: u32) -> Option<u32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // After the command's closing parenthesis: state, then the parent's pid.
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

/// Fcitx5s not started by KWin: Wayland apps reach only the one KWin runs (System Settings → Virtual Keyboard).
fn fcitx_outside_kwin() -> Vec<u32> {
    if busctl(&["status", "org.kde.KWin"]).is_err() {
        return Vec::new();
    }
    procs("fcitx5")
        .into_iter()
        .filter(|&pid| {
            parent(pid)
                .and_then(|p| fs::read_to_string(format!("/proc/{p}/comm")).ok())
                .is_none_or(|c| c.trim_end() != "kwin_wayland")
        })
        .collect()
}

/// What the wizard's last page shows: SebType's input method running where every app reaches it, any
/// global IM module, and a session started with what setup-ime.sh set (#445).
pub(crate) fn ready_checks() -> Vec<(crate::setup::Need, bool)> {
    use crate::setup::Need;
    let mut checks = vec![(
        Need::InputMethod,
        sebtype_active() && fcitx_outside_kwin().is_empty(),
    )];
    checks.extend(im_modules(&env_files()).into_iter().map(|n| (n, false)));
    // Only when it's needed: most sessions have what setup set from the start.
    if !session_ready(&session_env()) {
        checks.push((Need::LogIn, false));
    }
    // No group with Rime left: done, if the page had a Rime row (keep_done). Fcitx5 can't tell (it restarts):
    // no row, so an earlier one stays as it was.
    match rime_group_names() {
        Ok(None) => {}
        Ok(Some(g)) => {
            let done = g.is_empty();
            checks.push((Need::Rime { groups: Ok(g) }, done))
        }
        Err(e) => checks.push((Need::Rime { groups: Err(e) }, false)),
    }
    checks
}

/// What a ready check's button does.
pub(crate) fn fix(need: &crate::setup::Need) -> io::Result<()> {
    use crate::setup::Need;
    match need {
        // An Fcitx5 KWin didn't start goes, so setup's restart under KWin (#442) starts the one apps reach.
        Need::InputMethod => {
            let stray = fcitx_outside_kwin();
            for pid in &stray {
                let _ = Command::new("kill").arg(pid.to_string()).status();
            }
            let t = Instant::now();
            while stray
                .iter()
                .any(|p| Path::new(&format!("/proc/{p}")).exists())
                && t.elapsed() < Duration::from_secs(5)
            {
                std::thread::sleep(Duration::from_millis(100));
            }
            run_user_setup()
        }
        // Plasma's own Log out dialog, where the person confirms.
        Need::LogIn => busctl(&[
            "call",
            "org.kde.LogoutPrompt",
            "/LogoutPrompt",
            "org.kde.LogoutPrompt",
            "promptLogout",
        ])
        .map(|_| ()),
        Need::ImModule { file, line, text } => {
            if fs::OpenOptions::new().append(true).open(file).is_ok() {
                turn_off_line(file, *line, text)
            } else {
                // A system file: the person's editor, which asks for the admin password to save.
                Command::new("xdg-open").arg(file).spawn().map(|_| ())
            }
        }
        Need::Rime { .. } => use_sebtype_for_rime(),
        Need::Languages => Ok(()),
    }
}

/// Comments out the line, marked so it can be found and put back.
fn turn_off_line(file: &Path, line: usize, text: &str) -> io::Result<()> {
    let old = fs::read_to_string(file)?;
    let mut lines: Vec<String> = old.lines().map(str::to_string).collect();
    match lines.get_mut(line - 1) {
        Some(l) if l.trim() == text => *l = format!("# Turned off by SebType Setup (#445): {l}"),
        _ => {
            return Err(io::Error::other(format!(
                "{}:{line} changed",
                file.display()
            )))
        }
    }
    let mut new = lines.join("\n");
    if old.ends_with('\n') {
        new.push('\n');
    }
    // In place, not renamed over: a dotfile may be a link into the person's dotfiles.
    fs::write(file, new)
}

/// Runs `/usr/bin/sebtype-setup </dev/null` for the invoking user.
pub(crate) fn run_user_setup() -> io::Result<()> {
    let out = Command::new("/usr/bin/sebtype-setup")
        .stdin(std::process::Stdio::null())
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "sebtype-setup: {}",
            last_line(&out, "failed")
        )));
    }
    Ok(())
}

/// The installed Configurator binary (not the temporary one extracted during `--setup`).
pub(crate) fn installed_configurator() -> PathBuf {
    let user_bin = data().join("sebtype/configurator/sebtype-configurator");
    if user_bin.is_file() {
        user_bin
    } else {
        PathBuf::from("/usr/libexec/sebtype/sebtype-configurator")
    }
}

/// Installs the release's RPMs through the self-extracting installer with the system's admin prompt
/// (polkit), then sebtype-setup's part for this account, without one (pc/linux/README.md). The input
/// method runs the new version once Fcitx5 restarts, at the next login: never restarted here.
pub fn install_update(files: &[crate::update::Download]) -> io::Result<()> {
    if files.len() != 1 {
        return Err(io::Error::other("no installer"));
    }
    let out = root_install(&["pkexec", "/bin/sh"], files).output()?;
    match out.status.code() {
        Some(0) => {}
        Some(126 | 127) => {
            return Err(io::Error::other(
                "not allowed: the admin prompt was cancelled",
            ))
        }
        _ => return Err(io::Error::other(last_line(&out, "installer failed"))),
    }
    let out = Command::new("/usr/bin/sebtype-setup")
        .stdin(std::process::Stdio::null())
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "sebtype-setup: {}",
            last_line(&out, "failed")
        )));
    }
    Ok(())
}

/// The install runs in the window, which shows its errors: none left over.
pub fn update_error() -> Option<String> {
    None
}

pub fn open_url(url: &str) {
    let _ = Command::new("xdg-open").arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The admin side of an update runs a copy of the installer it checked itself: a file changed
    /// after the Configurator's check makes it refuse; the stub installer runs from the copy with
    /// --install-rpms-only.
    #[test]
    fn an_update_installs_only_the_files_it_checked() {
        let d = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "target/test-tmp/root-install-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let ran = d.join("installer-ran");
        let installer = d.join("SebType-setup-0.2.0-linux-x86_64.sh");
        fs::write(
            &installer,
            format!("#!/bin/sh\necho \"$0|$*\" > '{}'\n", ran.display()),
        )
        .unwrap();
        let files = vec![(
            installer.clone(),
            crate::update::sha256_file(&installer).unwrap(),
        )];
        let out = root_install(&["sh"], &files).output().unwrap();
        assert!(out.status.success(), "{out:?}");
        let got = fs::read_to_string(&ran).unwrap();
        let (path, args) = got.trim().split_once('|').unwrap();
        assert_ne!(Path::new(path), installer, "ran original instead of copy");
        assert!(path.ends_with("/SebType-setup-0.2.0-linux-x86_64.sh"));
        assert_eq!(args, "--install-rpms-only");
        fs::remove_file(&ran).unwrap();
        // replaced after the check
        fs::write(&installer, "#!/bin/sh\necho tampered\n").unwrap();
        let out = root_install(&["sh"], &files).output().unwrap();
        assert_eq!(out.status.code(), Some(3), "{out:?}");
        assert!(
            last_line(&out, "").contains("SebType-setup-0.2.0-linux-x86_64.sh isn't the release's")
        );
        assert!(!ran.exists(), "installer ran");
        fs::remove_dir_all(&d).unwrap();
    }

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

    /// #445: the ready check finds a global IM module as setup-ime.sh does, and its button turns off only
    /// that line; a session counts as started for SebType with XMODIFIERS and no IM module.
    #[test]
    fn global_im_module_found_and_turned_off() {
        let d = std::env::temp_dir().join(format!("sebtype-im-module-{}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        let f = d.join(".profile");
        fs::write(
            &f,
            "# QT_IM_MODULE=fcitx\nexport PATH=$PATH:~/bin\n  export QT_IM_MODULE=fcitx\nGTK_IM_MODULE=ibus\nMY_GTK_IM_MODULE_X=1\n",
        )
        .unwrap();
        let found = im_modules(std::slice::from_ref(&f));
        let crate::setup::Need::ImModule { line, text, .. } = &found[0] else {
            panic!()
        };
        assert_eq!(
            (found.len(), *line, text.as_str()),
            (2, 3, "export QT_IM_MODULE=fcitx")
        );
        turn_off_line(&f, *line, text).unwrap();
        assert_eq!(im_modules(std::slice::from_ref(&f)).len(), 1);
        assert!(fs::read_to_string(&f).unwrap().contains(
            "\n# Turned off by SebType Setup (#445):   export QT_IM_MODULE=fcitx\nGTK_IM_MODULE=ibus\n"
        ));
        // A line that moved since the check isn't touched.
        assert!(turn_off_line(&f, 1, "GTK_IM_MODULE=ibus").is_err());
        let _ = fs::remove_dir_all(&d);

        assert!(session_ready("HOME=/home/a\nXMODIFIERS=@im=fcitx\n"));
        assert!(!session_ready("HOME=/home/a\n"));
        assert!(!session_ready(
            "XMODIFIERS=@im=fcitx\nGTK_IM_MODULE=fcitx\n"
        ));
    }

    #[test]
    fn finds_rime_in_fcitx5_groups_and_puts_sebtype_in_its_place() {
        assert_eq!(
            parse_groups(r#"{"type":"as","data":[["Default","My=Rime"]]}"#).unwrap(),
            ["Default", "My=Rime"]
        );
        assert!(parse_groups("not json").is_none());
        assert_eq!(
            parse_im_names(
                r#"{"type":"a(ssssssb)","data":[[["keyboard-us","English","","","","en",false],["sebtype","SebType","","","","",true]]]}"#
            )
            .unwrap(),
            ["keyboard-us", "sebtype"]
        );
        assert!(parse_im_names("not json").is_none());
        let (layout, ims) =
            parse_group(r#"{"type":"sa(ss)","data":["us",[["keyboard-us",""],["rime",""]]]}"#)
                .unwrap();
        assert_eq!(layout, "us");
        let im = |n: &str, l: &str| (n.to_string(), l.to_string());
        assert_eq!(ims, [im("keyboard-us", ""), im("rime", "")]);
        // Fcitx5's usual group with Rime starts on SebType's, which no key would reach second.
        assert_eq!(sebtype_for_rime("us", &ims), [im("sebtype", "")]);
        // Others stay, after it; SebType's own entry keeps its layout, wherever it was; keyboard-us goes too.
        assert_eq!(
            sebtype_for_rime(
                "us",
                &[
                    im("keyboard-us", ""),
                    im("rime", "ru"),
                    im("hangul", ""),
                    im("sebtype", "jp")
                ]
            ),
            [im("sebtype", "jp"), im("hangul", "")]
        );
        assert_eq!(
            sebtype_for_rime("de", &[im("keyboard-de", ""), im("rime", "")]),
            [im("sebtype", ""), im("keyboard-de", "")]
        );
        // A group that starts on another input method keeps it first: SebType's takes Rime's place only.
        assert_eq!(
            sebtype_for_rime(
                "us",
                &[im("pinyin", ""), im("keyboard-us", ""), im("rime", "")]
            ),
            [im("pinyin", ""), im("keyboard-us", ""), im("sebtype", "")]
        );
        assert_eq!(
            sebtype_for_rime(
                "us",
                &[im("keyboard-de", ""), im("rime", ""), im("sebtype", "")]
            ),
            [im("keyboard-de", ""), im("sebtype", "")]
        );
    }

    /// #542: Use SebType's retry in the same second gets a backup folder of its own, after the first in the
    /// order README's `LC_ALL=C ls` gives.
    #[test]
    fn a_backup_in_the_same_second_gets_its_own_folder() {
        let dir = std::env::temp_dir().join(format!("sebtype-backup-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let first = new_backup(&dir, "20261125-100000").unwrap();
        fs::write(first.join("profile"), "before").unwrap();
        let second = new_backup(&dir, "20261125-100000").unwrap();
        assert_eq!(second, dir.join("20261125-100000_2"));
        assert_eq!(fs::read_to_string(first.join("profile")).unwrap(), "before");
        assert!(fs::read_dir(&second).unwrap().next().is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn parses_current_input_method_from_busctl_json() {
        assert_eq!(
            parse_current_im(r#"{"type":"s","data":["sebtype"]}"#).as_deref(),
            Some("sebtype")
        );
        assert_eq!(
            parse_current_im(r#"{"type":"s","data":["keyboard-us"]}"#).as_deref(),
            Some("keyboard-us")
        );
        assert_eq!(parse_current_im(r#"{"type":"s","data":[]}"#), None);
        assert_eq!(parse_current_im("not json"), None);
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
        for (size, w, h, margin) in [(9, 37, 38, 61), (14, 51, 52, 75), (24, 79, 80, 103)] {
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
        // Learning off is sebtype.conf's (#374): Rime keeps its learned words in use.
        set_learning(false).unwrap();
        assert!(!learning());
        assert!(
            langs().unwrap()[0] == ("zh".into(), true),
            "the languages kept"
        );
        let translator = schema.split("\ntranslator:\n").nth(1).unwrap();
        assert!(
            !translator
                .split('\n')
                .take_while(|l| l.starts_with(' '))
                .any(|l| l == "  enable_user_dict: false"),
            "learned words in use"
        );
        set_learning(true).unwrap();
        assert!(learning());

        // Picnic with SebType's pig (#94); test.sh then draws this window in a nested KWin.
        // 中文's pinyin row off and on again (#447): sebtype.conf's, which the input method reads. 14 pt, as
        // Windows' test draws its window.
        let mut picnic = Candidates {
            vertical: false,
            font_size: 14,
            picnic: true,
            pinyin_row: false,
        };
        assert!(set_candidates(&picnic).unwrap());
        assert!(!candidates().pinyin_row);
        assert_eq!(
            conf::value(
                &fs::read_to_string(settings()).unwrap(),
                "Candidates",
                "PinyinRow"
            ),
            Some("0")
        );
        picnic.pinyin_row = true;
        set_candidates(&picnic).unwrap();
        assert!(candidates().pinyin_row);
        assert!(fs::read_to_string(theme_dir().join("logo.svg"))
            .unwrap()
            .contains(" width=\"51\" height=\"52\" "));
        assert!(candidates().picnic);
        // Back to setup's Chinese settings, for the candidate window test.sh then draws as Windows' test
        // does: the Fcitx5 it starts deploys them.
        rime::save(&dir, &Chinese::default()).unwrap();
    }

    /// Use SebType on the Rime row (#542), against test.sh's made-up Fcitx5 (rime-button): its groups
    /// "Rime" (English and Rime) and "Work" (Rime) become SebType's alone, and "Default" stays. Work's first
    /// write fails after Rime's went through; the retry, often in the same second, keeps the first copy of
    /// the profile, from before either change.
    #[test]
    #[ignore]
    fn private_fake_fcitx5_puts_sebtype_first_in_rime_groups() {
        let profile = || fs::read_to_string(config().join("fcitx5/profile")).unwrap();
        let before = profile();
        assert_eq!(
            rime_group_names(),
            Ok(Some(vec!["Rime".into(), "Work".into()]))
        );
        assert!(use_sebtype_for_rime().is_err());
        use_sebtype_for_rime().unwrap();
        let group =
            |g: &str| parse_group(&controller("InputMethodGroupInfo", &["s", g]).unwrap()).unwrap();
        let sebtype = vec![("sebtype".to_string(), String::new())];
        assert_eq!(group("Rime"), ("us".to_string(), sebtype.clone()));
        assert_eq!(group("Work"), ("us".to_string(), sebtype));
        assert_eq!(group("Default").1.len(), 2);
        assert_eq!(rime_group_names(), Ok(Some(vec![])));
        let mut backups: Vec<_> = fs::read_dir(data().join("sebtype/backup"))
            .unwrap()
            .map(|b| b.unwrap().path())
            .filter(|b| b.is_dir())
            .map(|b| b.join("profile"))
            .collect();
        backups.sort();
        assert_eq!(backups.len(), 2, "{backups:?}");
        assert_eq!(fs::read_to_string(&backups[0]).unwrap(), before);
        assert_ne!(fs::read_to_string(&backups[1]).unwrap(), before);
        assert_ne!(profile(), before);
        // What each group lost, for setup-ime.sh --undo-all (#611), each line written before its group's
        // change: Work's once for the failed write and once for the retry.
        assert_eq!(
            fs::read_to_string(data().join("sebtype/backup/groups.tsv")).unwrap(),
            "Rime\t0\tkeyboard-us\tkeyboard-us rime\nWork\t0\trime\trime\nWork\t0\trime\trime\n"
        );
    }

    /// The Rime row and Use SebType against test.sh's made-up Fcitx5 that doesn't know SebType's input
    /// method yet (no row), or can't list its groups or read one (FAKE_FCITX5_MODE): an error, not a row
    /// done, and nothing changed.
    #[test]
    #[ignore]
    fn private_fake_fcitx5_unread_groups_change_nothing() {
        let profile = || fs::read_to_string(config().join("fcitx5/profile")).unwrap();
        let before = profile();
        if std::env::var("FAKE_FCITX5_MODE").unwrap() == "no-sebtype" {
            assert_eq!(rime_group_names(), Ok(None));
        } else {
            assert!(rime_group_names().is_err());
        }
        assert!(use_sebtype_for_rime().is_err());
        // The Ready page's Rime row from before stays open: the recheck couldn't tell.
        use crate::setup::{keep_done, Need};
        let shown = [(
            Need::Rime {
                groups: Ok(vec!["Rime".into()]),
            },
            false,
        )];
        let now = keep_done(&shown, ready_checks());
        let rime: Vec<_> = now
            .iter()
            .filter(|(n, _)| matches!(n, Need::Rime { .. }))
            .collect();
        assert_eq!(rime.len(), 1);
        assert!(!rime[0].1, "an unread recheck ticked Rime's row: {now:?}");
        assert_eq!(profile(), before);
        assert!(!data().join("sebtype/backup").exists());
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
