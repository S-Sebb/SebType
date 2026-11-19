//! Updates (#422): the latest GitHub release against the installed version, once a day from the setup's
//! schedule (`--check-updates`: a systemd user timer on Linux, a Task Scheduler task on Windows) and
//! from the About page's Check now. A newer release shows a notification once; installing it is the
//! person's click (the About page's Update…) and the system's admin prompt. The state is update.json in
//! SebType's folder: the switch, and the last check's outcome.

use crate::platform;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

const API: &str = "https://api.github.com/repos/S-Sebb/SebType/releases/latest";
const DOWNLOADS: &str = "https://github.com/S-Sebb/SebType/releases/download/";

/// The installed version: SebType's one version (VERSION, #420), built in.
pub const BUILT: &str = env!("SEBTYPE_VERSION");

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Update {
    /// The Configurator's "Check for updates automatically".
    pub auto: bool,
    /// When the last check went through, in seconds since 1970.
    pub checked: i64,
    /// The newer release it found ("" when none was newer).
    pub latest: String,
    /// The release the daily check has notified: each one is offered once.
    pub notified: String,
}
impl Default for Update {
    fn default() -> Self {
        Self {
            auto: true,
            checked: 0,
            latest: String::new(),
            notified: String::new(),
        }
    }
}

fn file() -> PathBuf {
    platform::sebtype_dir().join("update.json")
}
pub fn load() -> Update {
    fs::read_to_string(file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}
pub fn save(u: &Update) -> std::io::Result<()> {
    crate::write_file(&file(), serde_json::to_string_pretty(u)?).map(|_| ())
}

pub type Version = (u64, u64, u64);

/// A release tag's version: `v` and plain MAJOR.MINOR.PATCH only. The tags from before SebType's own
/// numbers (`v0.1.30-sebtype.N`, FUTO's) and pre-releases are none.
pub fn parse(tag: &str) -> Option<Version> {
    let mut n = tag.strip_prefix('v').unwrap_or(tag).split('.').map(|p| {
        (!p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
            .then(|| p.parse().ok())
            .flatten()
    });
    let v = (n.next()??, n.next()??, n.next()??);
    n.next().is_none().then_some(v)
}

/// The release's version when it is newer than the installed one.
pub fn newer(installed: &str, tag: &str) -> Option<String> {
    let v = parse(tag)?;
    (parse(installed).is_none_or(|i| v > i)).then(|| format!("{}.{}.{}", v.0, v.1, v.2))
}

#[derive(Clone, Debug, Deserialize)]
pub struct Asset {
    pub name: String,
    pub size: u64,
    pub browser_download_url: String,
}
#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    assets: Vec<Asset>,
}

/// What this PC installs from a release of `version`. Windows: its setup. Linux (Fedora's RPMs): every
/// package of this machine's arch and noarch, in one dnf transaction, which must have SebType's own;
/// no sources or debug packages.
pub fn wanted(assets: &[Asset], version: &str, windows: bool, arch: &str) -> Vec<Asset> {
    let safe = |a: &&Asset| !a.name.contains(['/', '\\']) && !a.name.starts_with('.');
    if windows {
        let name = format!("SebType-setup-{version}.exe");
        return assets
            .iter()
            .filter(safe)
            .filter(|a| a.name == name)
            .take(1)
            .cloned()
            .collect();
    }
    let rpms: Vec<Asset> = assets
        .iter()
        .filter(safe)
        .filter(|a| a.name.ends_with(&format!(".{arch}.rpm")) || a.name.ends_with(".noarch.rpm"))
        .filter(|a| !a.name.contains("-debuginfo-") && !a.name.contains("-debugsource-"))
        .cloned()
        .collect();
    let own = format!("sebtype-{version}-");
    if rpms.iter().any(|a| a.name.starts_with(&own)) {
        rpms
    } else {
        vec![]
    }
}

/// Where releases come from: GitHub, or for the tests a release served on this PC
/// (SEBTYPE_UPDATE_URL, only to 127.0.0.1), whose assets then come from the same server.
fn source() -> (String, String) {
    if let Ok(url) = std::env::var("SEBTYPE_UPDATE_URL") {
        if let Some(rest) = url.strip_prefix("http://127.0.0.1:") {
            let port: String = rest.chars().take_while(char::is_ascii_digit).collect();
            return (url.clone(), format!("http://127.0.0.1:{port}/"));
        }
    }
    (API.into(), DOWNLOADS.into())
}

/// curl, which Linux and Windows (10 and later, System32) both have: https only, redirects too, except to
/// the tests' server on this PC.
fn curl(url: &str) -> Command {
    let mut c = Command::new("curl");
    #[cfg(windows)]
    std::os::windows::process::CommandExt::creation_flags(&mut c, 0x0800_0000); // no console window
    let proto = if url.starts_with("https://") {
        "=https"
    } else {
        "=http"
    };
    c.args([
        "-fsSL",
        "--proto",
        proto,
        "--proto-redir",
        proto,
        "-A",
        "SebType-Configurator",
    ]);
    c
}

fn latest_release() -> Result<Release, String> {
    let (api, _) = source();
    let out = curl(&api)
        .args([
            "--max-time",
            "30",
            "-H",
            "Accept: application/vnd.github+json",
            &api,
        ])
        .output()
        .map_err(|e| format!("curl: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("GitHub's answer: {e}"))
}

/// The newer release and what this PC would install from it, or None when the installed one is current.
/// A release without this PC's files counts as none.
pub fn check() -> Result<Option<(String, Vec<Asset>)>, String> {
    let r = latest_release()?;
    let Some(v) = newer(&platform::installed_version(), &r.tag_name) else {
        return Ok(None);
    };
    let files = wanted(&r.assets, &v, cfg!(windows), std::env::consts::ARCH);
    Ok((!files.is_empty()).then_some((v, files)))
}

/// Downloads the assets into dir, emptied first: each only from the release's download address, and
/// whole (the size GitHub gives).
pub fn download(assets: &[Asset], dir: &Path) -> Result<Vec<PathBuf>, String> {
    let (_, downloads) = source();
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    assets
        .iter()
        .map(|a| {
            let url = &a.browser_download_url;
            if !url.starts_with(&downloads) {
                return Err(format!("{} isn't from {downloads}", a.name));
            }
            let (part, path) = (dir.join(format!("{}.part", a.name)), dir.join(&a.name));
            let out = curl(url)
                .args(["--max-time", "1800", "-o"])
                .arg(&part)
                .arg(url)
                .output()
                .map_err(|e| format!("curl: {e}"))?;
            if !out.status.success() {
                return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
            }
            let size = fs::metadata(&part).map_or(0, |m| m.len());
            if size != a.size {
                let _ = fs::remove_file(&part);
                return Err(format!("{}: {size} bytes, not {}", a.name, a.size));
            }
            fs::rename(&part, &path).map_err(|e| e.to_string())?;
            Ok(path)
        })
        .collect()
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Checks and keeps the outcome: the newer version, if any.
pub fn check_and_save() -> Result<Option<String>, String> {
    let found = check()?.map(|(v, _)| v);
    let mut u = load();
    (u.checked, u.latest) = (now(), found.clone().unwrap_or_default());
    let _ = save(&u);
    Ok(found)
}

/// The schedule's daily check (`--check-updates`): nothing while the switch is off; a newer release is
/// notified once, and a click on the notification opens the About page.
pub fn scheduled() -> Result<(), String> {
    if !load().auto {
        return Ok(());
    }
    let Some(v) = check_and_save()? else {
        return Ok(());
    };
    let mut u = load();
    if u.notified == v {
        return Ok(());
    }
    u.notified = v.clone();
    save(&u).map_err(|e| e.to_string())?;
    let summary = crate::tr("SebType {} is available").replacen("{}", &v, 1);
    let body = crate::tr("You have {}. Installing it needs an administrator's approval").replacen(
        "{}",
        &platform::installed_version(),
        1,
    );
    platform::notify_update(&summary, &body, &crate::tr("Update…")).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_newer_plain_version_is_offered() {
        assert_eq!(newer("0.1.0", "v0.2.0").as_deref(), Some("0.2.0"));
        assert_eq!(newer("0.1.9", "v0.1.10").as_deref(), Some("0.1.10"));
        assert_eq!(newer("0.1.0", "v0.1.0"), None);
        assert_eq!(newer("0.2.0", "v0.1.5"), None);
    }

    /// The tags from before SebType's own numbers (#420) are never newer than 0.1.0, nor are pre-releases.
    #[test]
    fn old_sebtype_tags_and_prereleases_are_skipped() {
        assert_eq!(parse("v0.1.30-sebtype.208"), None);
        assert_eq!(newer("0.1.0", "v0.1.30-sebtype.208"), None);
        assert_eq!(newer("0.1.0", "v0.2.0-rc.1"), None);
        assert_eq!(newer("0.1.0", "v0.2"), None);
        assert_eq!(newer("0.1.0", "v0.2.0.1"), None);
        assert_eq!(newer("0.1.0", "v0.+2.0"), None);
    }

    fn asset(name: &str) -> Asset {
        Asset {
            name: name.into(),
            size: 1,
            browser_download_url: format!("{DOWNLOADS}v0.2.0/{name}"),
        }
    }
    fn names(a: Vec<Asset>) -> Vec<String> {
        a.into_iter().map(|a| a.name).collect()
    }

    #[test]
    fn each_system_takes_its_own_files() {
        let all: Vec<Asset> = [
            "SebType-0.2.0-arm64-v8a.apk",
            "SebType-setup-0.2.0.exe",
            "sebtype-0.2.0-1.fc44.x86_64.rpm",
            "librime-sebtype-1.16.1-3.fc44.x86_64.rpm",
            "sebtype-data-0.2.0-1.fc44.noarch.rpm",
            "sebtype-debuginfo-0.2.0-1.fc44.x86_64.rpm",
            "sebtype-0.2.0-1.fc44.src.rpm",
            "sebtype-0.2.0-1.fc44.aarch64.rpm",
        ]
        .map(asset)
        .into();
        assert_eq!(
            names(wanted(&all, "0.2.0", true, "x86_64")),
            ["SebType-setup-0.2.0.exe"]
        );
        assert_eq!(
            names(wanted(&all, "0.2.0", false, "x86_64")),
            [
                "sebtype-0.2.0-1.fc44.x86_64.rpm",
                "librime-sebtype-1.16.1-3.fc44.x86_64.rpm",
                "sebtype-data-0.2.0-1.fc44.noarch.rpm"
            ]
        );
        // Another version's setup, or packages without SebType's own, install nothing.
        assert!(wanted(&all, "0.3.0", true, "x86_64").is_empty());
        assert!(wanted(&all[3..5], "0.2.0", false, "x86_64").is_empty());
    }

    /// A file that isn't whole, or doesn't come from the release's address, is never kept.
    #[test]
    fn a_download_is_whole_and_from_the_release() {
        use std::io::{Read, Write};
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/update-{}", std::process::id()));
        let server = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = server.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for s in server.incoming() {
                let mut s = s.unwrap();
                let mut req = [0; 1024];
                let _ = s.read(&mut req);
                let _ = s.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
                );
            }
        });
        std::env::set_var(
            "SEBTYPE_UPDATE_URL",
            format!("http://127.0.0.1:{port}/latest.json"),
        );
        let at = |size, url: String| Asset {
            name: "SebType-setup-0.2.0.exe".into(),
            size,
            browser_download_url: url,
        };
        let here = format!("http://127.0.0.1:{port}/SebType-setup-0.2.0.exe");
        let got = download(&[at(5, here.clone())], &dir).unwrap();
        assert_eq!(fs::read(&got[0]).unwrap(), b"hello");
        assert!(download(&[at(6, here)], &dir)
            .unwrap_err()
            .contains("5 bytes, not 6"));
        assert!(download(
            &[at(5, "https://example.com/SebType-setup-0.2.0.exe".into())],
            &dir
        )
        .is_err());
        assert!(fs::read_dir(&dir).unwrap().next().is_none(), "nothing kept");
        fs::remove_dir_all(&dir).unwrap();
    }
}
