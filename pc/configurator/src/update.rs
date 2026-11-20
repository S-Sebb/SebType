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
    /// GitHub's checksum of the file, "sha256:<hex>".
    #[serde(default)]
    pub digest: Option<String>,
}
#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    assets: Vec<Asset>,
}

/// The asset's SHA-256 from the release, which the install is bound to: an asset without one isn't
/// installed.
pub fn sha256(a: &Asset) -> Result<String, String> {
    a.digest
        .as_deref()
        .and_then(|d| d.strip_prefix("sha256:"))
        .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| format!("{}: the release gives no SHA-256", a.name))
}

pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::Digest;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut fs::File::open(path)?, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
}

/// The packages SebType's Fedora release installs (pc/linux/README.md, #423): its own and the librime
/// it builds against; librime's other packages only where they are already installed.
const RPMS: [&str; 4] = ["sebtype", "librime", "librime-lua", "librime-octagram"];
const RPMS_IF_INSTALLED: [&str; 3] = ["librime-predict", "librime-tools", "librime-devel"];

/// An RPM file's package name and version: <name>-<version>-<release>.<arch>.rpm.
fn package<'a>(file: &'a str, arch: &str) -> Option<(&'a str, &'a str)> {
    let nvr = file
        .strip_suffix(".rpm")?
        .strip_suffix(arch)?
        .strip_suffix('.')?;
    let (nv, _) = nvr.rsplit_once('-')?;
    nv.rsplit_once('-')
}

pub fn rpm_installed(name: &str) -> bool {
    Command::new("rpm")
        .args(["-q", "--quiet", name])
        .status()
        .is_ok_and(|s| s.success())
}

/// What this PC installs from a release of `version`, or nothing when the release lacks part of it.
/// Windows: its setup. Linux: SebType's RPMs of this machine's arch, the optional ones for the packages
/// `installed` finds.
pub fn wanted(
    assets: &[Asset],
    version: &str,
    windows: bool,
    arch: &str,
    installed: impl Fn(&str) -> bool,
) -> Vec<Asset> {
    let safe = |a: &&Asset| !a.name.contains(['/', '\\']) && !a.name.starts_with('.');
    let find =
        |pred: &dyn Fn(&Asset) -> bool| assets.iter().filter(safe).find(|a| pred(a)).cloned();
    if windows {
        let name = format!("SebType-setup-{version}.exe");
        return find(&|a| a.name == name).into_iter().collect();
    }
    let rpm = |name: &str| {
        find(&|a| {
            package(&a.name, arch)
                .is_some_and(|(n, v)| n == name && (name != "sebtype" || v == version))
        })
    };
    // An installed package the release doesn't replace would hold dnf to the old librime (#423).
    let needed = RPMS
        .iter()
        .chain(RPMS_IF_INSTALLED.iter().filter(|n| installed(n)));
    let (files, missing): (Vec<_>, Vec<_>) =
        needed.map(|n| (n, rpm(n))).partition(|(_, a)| a.is_some());
    if !missing.is_empty() {
        let names: Vec<&str> = missing.iter().map(|(n, _)| **n).collect();
        eprintln!(
            "update: the release has no {arch} RPM of {}",
            names.join(", ")
        );
        return vec![];
    }
    files.into_iter().filter_map(|(_, a)| a).collect()
}

/// A test's release served on this PC: http://127.0.0.1:<port>/<path>, nothing else (no other host, no
/// user part). Its assets then come from the same server.
#[cfg(any(test, feature = "update-test"))]
fn local(url: &str) -> Option<(String, String)> {
    let (authority, _) = url.strip_prefix("http://")?.split_once('/')?;
    let port = authority.strip_prefix("127.0.0.1:")?;
    (!port.is_empty() && port.len() <= 5 && port.bytes().all(|b| b.is_ascii_digit()))
        .then(|| (url.to_string(), format!("http://127.0.0.1:{port}/")))
}

/// Where releases come from: GitHub. Only the tests' builds (the update-test feature, pc/configurator/
/// build.sh) take SEBTYPE_UPDATE_URL, a release served on this PC.
fn source() -> (String, String) {
    #[cfg(any(test, feature = "update-test"))]
    if let Some(s) = std::env::var("SEBTYPE_UPDATE_URL")
        .ok()
        .and_then(|u| local(&u))
    {
        return s;
    }
    (API.into(), DOWNLOADS.into())
}

/// curl, which Linux and Windows (10 and later, System32) both have: no curlrc, https only, redirects
/// too, except to the tests' server on this PC.
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
        "-q",
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
    let files = wanted(
        &r.assets,
        &v,
        cfg!(windows),
        std::env::consts::ARCH,
        rpm_installed,
    );
    Ok((!files.is_empty()).then_some((v, files)))
}

/// A new folder for one install's downloads, which only this account can use: in updates_dir (the
/// account's runtime folder on Linux, SebType's on Windows), where older ones are removed.
pub fn private_dir() -> std::io::Result<PathBuf> {
    let parent = platform::updates_dir();
    fs::create_dir_all(&parent)?;
    for old in fs::read_dir(&parent)?.flatten() {
        if old.file_name().to_string_lossy().starts_with("update-") {
            let _ = fs::remove_dir_all(old.path());
        }
    }
    let mut b = fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o700);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let dir = parent.join(format!("update-{}-{nanos}", std::process::id()));
    b.create(&dir)?; // a new one: fails when it exists
    Ok(dir)
}

/// A downloaded file and the SHA-256 it was checked against, which the install checks again.
pub type Download = (PathBuf, String);

/// Downloads the assets into dir: each only from the release's download address, whole (the size
/// GitHub gives) and with the release's SHA-256.
pub fn download(assets: &[Asset], dir: &Path) -> Result<Vec<Download>, String> {
    let (_, downloads) = source();
    assets
        .iter()
        .map(|a| {
            let url = &a.browser_download_url;
            if !url.starts_with(&downloads) {
                return Err(format!("{} isn't from {downloads}", a.name));
            }
            let sha = sha256(a)?;
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
            let got = sha256_file(&part).map_err(|e| e.to_string())?;
            let wrong = if size != a.size {
                Some(format!("{}: {size} bytes, not {}", a.name, a.size))
            } else {
                (got != sha).then(|| format!("{}: its SHA-256 isn't the release's", a.name))
            };
            if let Some(e) = wrong {
                let _ = fs::remove_file(&part);
                return Err(e);
            }
            fs::rename(&part, &path).map_err(|e| e.to_string())?;
            Ok((path, sha))
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

/// The schedule's daily check (`--check-updates`).
pub fn scheduled() -> Result<(), String> {
    notify_once(
        load,
        |u| save(u),
        check_and_save,
        |v, shown| {
            let summary = crate::tr("SebType {} is available").replacen("{}", v, 1);
            let body = crate::tr("You have {}. Installing it needs an administrator's approval")
                .replacen("{}", &platform::installed_version(), 1);
            platform::notify_update(&summary, &body, &crate::tr("Update…"), shown)
                .map_err(|e| e.to_string())
        },
    )
}

/// Nothing while the switch is off, also when it was turned off during the check; a newer release is
/// notified once: kept as notified when the notification is shown (`shown`), so one that failed is
/// tried again the next day.
fn notify_once(
    load: impl Fn() -> Update,
    save: impl Fn(&Update) -> std::io::Result<()>,
    check: impl FnOnce() -> Result<Option<String>, String>,
    notify: impl FnOnce(&str, &mut dyn FnMut()) -> Result<(), String>,
) -> Result<(), String> {
    if !load().auto {
        return Ok(());
    }
    let Some(v) = check()? else {
        return Ok(());
    };
    let u = load();
    if !u.auto || u.notified == v {
        return Ok(());
    }
    let mut saved = Ok(());
    notify(&v, &mut || {
        let mut u = load();
        u.notified = v.clone();
        saved = save(&u).map_err(|e| e.to_string());
    })?;
    saved
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
            digest: None,
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
            "librime-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-lua-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-octagram-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-predict-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-tools-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-devel-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-debuginfo-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "sebtype-0.2.0-1.fc44.src.rpm",
            "sebtype-0.2.0-1.fc44.aarch64.rpm",
        ]
        .map(asset)
        .into();
        assert_eq!(
            names(wanted(&all, "0.2.0", true, "x86_64", |_| true)),
            ["SebType-setup-0.2.0.exe"]
        );
        let base = [
            "sebtype-0.2.0-1.fc44.x86_64.rpm",
            "librime-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-lua-1.16.1-2.sebtype4.fc44.x86_64.rpm",
            "librime-octagram-1.16.1-2.sebtype4.fc44.x86_64.rpm",
        ];
        assert_eq!(
            names(wanted(&all, "0.2.0", false, "x86_64", |_| false)),
            base
        );
        // librime's other packages only where they are installed already
        let mut with_tools = base.to_vec();
        with_tools.push("librime-tools-1.16.1-2.sebtype4.fc44.x86_64.rpm");
        assert_eq!(
            names(wanted(&all, "0.2.0", false, "x86_64", |p| p == "librime-tools")),
            with_tools
        );
        assert_eq!(
            names(wanted(&all, "0.2.0", false, "aarch64", |_| false)),
            Vec::<String>::new(),
            "no librime of that arch"
        );
        // Another version's setup or SebType, or a release without a required package, installs nothing.
        assert!(wanted(&all, "0.3.0", true, "x86_64", |_| false).is_empty());
        assert!(wanted(&all, "0.3.0", false, "x86_64", |_| false).is_empty());
        assert!(wanted(&all[..5], "0.2.0", false, "x86_64", |_| false).is_empty());
        // An installed librime-tools the release has none of: dnf couldn't upgrade librime, so nothing.
        assert!(wanted(&all[..6], "0.2.0", false, "x86_64", |p| p
            == "librime-tools")
        .is_empty());
        assert_eq!(
            wanted(&all[..6], "0.2.0", false, "x86_64", |_| false).len(),
            4
        );
    }

    /// Only a release on 127.0.0.1 (the tests' builds), however the address is written.
    #[test]
    fn a_test_release_is_only_on_this_pc() {
        assert_eq!(
            local("http://127.0.0.1:8123/latest.json"),
            Some((
                "http://127.0.0.1:8123/latest.json".into(),
                "http://127.0.0.1:8123/".into()
            ))
        );
        for url in [
            "http://127.0.0.1:8123@attacker.example/latest.json",
            "http://127.0.0.1:8123:@attacker.example/latest.json",
            "http://user@127.0.0.1:8123/latest.json",
            "http://127.0.0.1:8123?@attacker.example/latest.json",
            "http://127.0.0.1:8123#@attacker.example/latest.json",
            "http://127.0.0.1:8123\\@attacker.example/latest.json",
            "http://127.0.0.1.attacker.example:8123/latest.json",
            "http://127.0.0.1:/latest.json",
            "http://127.0.0.1:8123",
            "https://attacker.example/latest.json",
        ] {
            assert_eq!(local(url), None, "{url}");
        }
    }

    #[test]
    fn the_release_gives_each_file_a_sha256() {
        let mut a = asset("SebType-setup-0.2.0.exe");
        assert!(sha256(&a).is_err(), "no digest");
        a.digest = Some(format!("sha256:{}", "AB".repeat(32)));
        assert_eq!(sha256(&a).unwrap(), "ab".repeat(32));
        for d in [
            "md5:00",
            "sha256:abc",
            &format!("sha512:{}", "a".repeat(64)),
        ] {
            a.digest = Some(d.into());
            assert!(sha256(&a).is_err(), "{d}");
        }
    }

    const HELLO: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

    /// A file that isn't whole, isn't the release's or doesn't come from its address is never kept.
    #[test]
    fn a_download_is_whole_and_from_the_release() {
        use std::io::{Read, Write};
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/update-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
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
        let at = |size, url: String, sha: &str| Asset {
            name: "SebType-setup-0.2.0.exe".into(),
            size,
            browser_download_url: url,
            digest: Some(format!("sha256:{sha}")),
        };
        let here = format!("http://127.0.0.1:{port}/SebType-setup-0.2.0.exe");
        let got = download(&[at(5, here.clone(), HELLO)], &dir).unwrap();
        assert_eq!(fs::read(&got[0].0).unwrap(), b"hello");
        assert_eq!(got[0].1, HELLO);
        fs::remove_file(&got[0].0).unwrap();
        assert!(download(&[at(6, here.clone(), HELLO)], &dir)
            .unwrap_err()
            .contains("5 bytes, not 6"));
        let other = "0".repeat(64);
        assert!(download(&[at(5, here.clone(), &other)], &dir)
            .unwrap_err()
            .contains("SHA-256 isn't the release's"));
        let mut none = at(5, here, HELLO);
        none.digest = None;
        assert!(download(&[none], &dir).unwrap_err().contains("no SHA-256"));
        assert!(download(
            &[at(
                5,
                "https://example.com/SebType-setup-0.2.0.exe".into(),
                HELLO
            )],
            &dir
        )
        .is_err());
        assert!(fs::read_dir(&dir).unwrap().next().is_none(), "nothing kept");
        fs::remove_dir_all(&dir).unwrap();
    }

    /// The daily check's notification: once per release, kept as notified only once it was shown, and
    /// none when the switch went off while the check ran.
    #[test]
    fn a_release_is_notified_once_it_was_shown() {
        use std::cell::{Cell, RefCell};
        let state = RefCell::new(Update::default());
        let loads = Cell::new(0);
        let load = || {
            loads.set(loads.get() + 1);
            state.borrow().clone()
        };
        let save = |u: &Update| {
            *state.borrow_mut() = u.clone();
            Ok(())
        };
        let found = || Ok(Some("0.2.0".to_string()));
        let shown = Cell::new(0);
        // the notification fails: not notified, so it comes again
        let failed = notify_once(load, save, found, |_, _| {
            Err("no notification server".into())
        });
        assert!(failed.is_err());
        assert_eq!(state.borrow().notified, "");
        // shown, then the click is awaited: notified once it is shown
        notify_once(load, save, found, |v, done| {
            assert_eq!(v, "0.2.0");
            done();
            shown.set(shown.get() + 1);
            assert_eq!(state.borrow().notified, "0.2.0");
            Ok(())
        })
        .unwrap();
        notify_once(load, save, found, |_, _| panic!("notified twice")).unwrap();
        assert_eq!(shown.get(), 1);
        // the switch turned off while the check ran: nothing shown
        state.borrow_mut().notified.clear();
        let before = loads.get();
        let off_after = || {
            loads.set(loads.get() + 1);
            let mut u = state.borrow().clone();
            u.auto = loads.get() == before + 1;
            u
        };
        notify_once(off_after, save, found, |_, _| {
            panic!("notified with the switch off")
        })
        .unwrap();
        // and off before it: not even checked
        state.borrow_mut().auto = false;
        notify_once(
            load,
            save,
            || panic!("checked with the switch off"),
            |_, _| Ok(()),
        )
        .unwrap();
    }
}
