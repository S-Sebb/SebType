//! Sync with the user's own server (#12, #180), as the phone does (#14): 中文's learned words through
//! Rime's sync folder, its My words (#272) and the Japanese dictionary, by sync-server/sebtype_sync.py's own pull and push.
//! The server and username are kept in SebType's folder (sync.json, with the last sync's outcome); the
//! password only in the system's keyring (Secret Service, Credential Manager), handed to the client on
//! its stdin. The schedule (platform::schedule) runs `sebtype-configurator --sync` every half hour, and
//! on Linux the network trigger runs `--network-changed` (network_changed).

use crate::{platform, rime};
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    io::Write,
    path::{Path, PathBuf},
    process::Stdio,
};

/// The client, in the binary so the Configurator and its client are always the same version; written
/// into SebType's folder to run.
const CLIENT: &str = include_str!("../../../sync-server/sebtype_sync.py");
const KEYRING_SERVICE: &str = "SebType sync";
/// Credential Manager names the entry `<user>.<service>`: setup.ps1 deletes it at uninstall.
const KEYRING_USER: &str = "login";

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    #[default]
    NotYet,
    Synced,
    Offline,
    LoginFailed,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Sync {
    pub enabled: bool,
    /// Sync was on at some point since the last delete on the server: Setup then syncs before it deletes
    /// this PC's learned words (setup.ps1, Decisions #2).
    pub ever_on: bool,
    pub server: String,
    pub user: String,
    pub status: Status,
    /// When the last sync went through, in seconds since 1970.
    pub at: i64,
}

fn dir() -> PathBuf {
    platform::sebtype_dir()
}

pub fn load() -> Sync {
    load_in(&dir())
}
fn load_in(dir: &Path) -> Sync {
    fs::read_to_string(dir.join("sync.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save(s: &Sync) -> io::Result<()> {
    save_in(&dir(), s)
}
fn save_in(dir: &Path, s: &Sync) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let tmp = dir.join("sync.json.new");
    fs::write(&tmp, serde_json::to_string_pretty(s)?)?;
    fs::rename(tmp, dir.join("sync.json"))
}

/// Runs f with the schedule to itself, across processes: schedule changes (two Configurators may be
/// open), the network trigger's plans, a sync's outcome and setup-ime.sh's uninstall (#377). Each reads
/// sync's state inside it, so none puts back a schedule just turned off.
pub fn schedule_locked<T>(f: impl FnOnce() -> T) -> io::Result<T> {
    schedule_locked_in(&dir(), f)
}
fn schedule_locked_in<T>(dir: &Path, f: impl FnOnce() -> T) -> io::Result<T> {
    fs::create_dir_all(dir)?;
    locked_in(&dir.join("schedule.lock"), f)
}

fn change_schedule(
    dir: &Path,
    change: impl FnOnce(&mut Sync),
    schedule: impl FnOnce(bool) -> io::Result<()>,
) -> io::Result<Sync> {
    schedule_locked_in(dir, || {
        let mut s = load_in(dir);
        let before = s.clone();
        change(&mut s);
        if s != before {
            save_in(dir, &s)?;
        }
        schedule(s.enabled)?;
        Ok(s)
    })?
}

/// The network changed (the path unit's --network-changed, #377): plans a sync if sync is on.
#[cfg(target_os = "linux")]
pub fn network_changed() -> io::Result<()> {
    schedule_locked(|| platform::network_changed(load().enabled))?
}

/// Makes the schedule again as this Configurator makes it, so one made by an older version gets what
/// this one adds (the network trigger, #377).
pub fn refresh_schedule() -> io::Result<Sync> {
    change_schedule(&dir(), |_| {}, platform::schedule)
}

fn keyring() -> keyring::Result<keyring::Entry> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)
}

/// "host", "host:port/path" or "https://…" as an https URL without a trailing slash, as the phone takes
/// it; plain http only to this PC itself (a server on the same PC, and the tests).
pub fn normalize_server(text: &str) -> Option<String> {
    let t = text.trim();
    let url = if t.contains("://") {
        t.to_string()
    } else {
        format!("https://{t}")
    };
    let url = url.trim_end_matches('/').to_string();
    let (scheme, rest) = url.split_once("://")?;
    let authority = rest.split('/').next()?;
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next()?,
        None => authority.split(':').next()?,
    };
    let ok = !host.is_empty()
        && !url.chars().any(char::is_whitespace)
        && match scheme {
            "https" => true,
            "http" => ["localhost", "127.0.0.1", "::1"].contains(&host),
            _ => false,
        };
    ok.then_some(url)
}

/// Saves a login. A first one turns sync on; a changed one keeps sync as it was (as the phone).
pub fn save_login(server: String, user: String, password: &str) -> Result<Sync, String> {
    keyring()
        .and_then(|k| k.set_password(password))
        .map_err(|e| e.to_string())?;
    let login = |s: &mut Sync| {
        let first = s.user.is_empty();
        (s.server, s.user, s.status) = (server, user, Status::NotYet);
        if first {
            s.enabled = true;
        }
        s.ever_on |= s.enabled;
    };
    let on = |on| if on { platform::schedule(true) } else { Ok(()) };
    change_schedule(&dir(), login, on).map_err(|e| e.to_string())
}

pub fn set_enabled(on: bool) -> io::Result<Sync> {
    change_schedule(
        &dir(),
        |s| {
            s.enabled = on;
            s.ever_on |= on;
        },
        platform::schedule,
    )
}

enum Failed {
    Login,
    Offline,
}

/// Runs sebtype_sync.py with the login: its output, or how it failed.
fn client(s: &Sync, args: &[&std::ffi::OsStr]) -> Result<String, Failed> {
    let password = keyring()
        .and_then(|k| k.get_password())
        .map_err(|_| Failed::Login)?;
    let script = dir().join("sebtype_sync.py");
    if fs::read_to_string(&script).ok().as_deref() != Some(CLIENT) {
        fs::create_dir_all(dir()).map_err(|_| Failed::Offline)?;
        fs::write(&script, CLIENT).map_err(|_| Failed::Offline)?;
    }
    let mut child = platform::python()
        .args(["-I", "-X", "utf8"])
        .arg(&script)
        .args(args)
        .args(["--server", &s.server, "--user", &s.user, "--password-stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| Failed::Offline)?;
    let mut stdin = child.stdin.take().unwrap();
    let _ = writeln!(stdin, "{password}");
    drop(stdin);
    let out = child.wait_with_output().map_err(|_| Failed::Offline)?;
    match out.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        Some(3) => Err(Failed::Login),
        _ => Err(Failed::Offline),
    }
}

/// Runs f holding the lock file at path, which other processes wait for.
fn locked_in<T>(path: &Path, f: impl FnOnce() -> T) -> io::Result<T> {
    let file = fs::File::create(path)?;
    file.lock()?;
    Ok(f())
}

/// Runs f with My words to itself: the window's word edits and a sync's pull each read the words and
/// write them back, so one done in the middle of the other would be lost (#272).
pub fn words_locked<T>(f: impl FnOnce() -> T) -> io::Result<T> {
    fs::create_dir_all(dir())?;
    locked_in(&dir().join("words.lock"), f)
}

/// Rime reads My words when it deploys. A pull that changed them leaves the flag file, which only a
/// deploy that went through removes, so a failed deploy or a sync cut off after the pull is retried.
fn deploy_if_pending(flag: &Path, deploy: impl FnOnce() -> io::Result<()>) -> io::Result<()> {
    if flag.exists() {
        deploy()?;
        fs::remove_file(flag)?;
    }
    Ok(())
}

/// One sync, as the phone's: the other devices' changes come down, Rime merges them and writes this
/// PC's own snapshot, and that goes up with the Japanese dictionary.
fn sync_with(s: &Sync, rime_dir: &Path, mozc_db: Option<&Path>) -> Result<(), Failed> {
    let mut args = vec!["--rime-dir".as_ref(), rime_dir.as_os_str()];
    if let Some(db) = mozc_db {
        args.extend(["--mozc-db".as_ref(), db.as_os_str()]);
    }
    let pull = [&["pull".as_ref()], &args[..]].concat();
    let phrases = rime_dir.join(rime::PHRASES);
    let flag = dir().join("rime-deploy-pending");
    // What the pull changed, read even when it fails part way: it may have changed words by then.
    let (pulled, mozc_changed) = words_locked(|| {
        let (zh, ja) = (fs::read(&phrases).ok(), mozc_db.map(fs::read));
        let pulled = client(s, &pull);
        if fs::read(&phrases).ok() != zh {
            fs::write(&flag, "").map_err(|_| Failed::Offline)?;
        }
        let ja_now = mozc_db.map(fs::read);
        Ok::<_, Failed>((pulled, ja.map(|r| r.ok()) != ja_now.map(|r| r.ok())))
    })
    .map_err(|_| Failed::Offline)??;
    if mozc_changed {
        platform::restart_mozc_when_idle(); // Mozc reads its dictionary when it starts
    }
    deploy_if_pending(&flag, platform::redeploy_rime_when_idle).map_err(|_| Failed::Offline)?;
    pulled?;
    // A save that didn't go through (typing never idle, #373) would push an old snapshot: the sync fails,
    // so Setup keeps the words (#271).
    if let Some(own) = rime::own_sync_folder(rime_dir) {
        platform::sync_rime(&own).map_err(|_| Failed::Offline)?;
    }
    let push = [&["push".as_ref()], &args[..]].concat();
    client(s, &push)?;
    Ok(())
}

/// One sync at a time, between the window and the schedule.
fn lock() -> io::Result<fs::File> {
    fs::create_dir_all(dir())?;
    let f = fs::File::create(dir().join("sync.lock"))?;
    f.lock()?;
    Ok(f)
}

/// Syncs if sync is on (or, before Setup deletes the learned words, was ever on), and keeps the
/// outcome for the window. Err when a sync was due and didn't go through: Setup then keeps the words
/// (setup.ps1).
pub fn run(before_removal: bool) -> Result<Sync, Sync> {
    let lock = lock();
    let mut s = load();
    if !(s.enabled || before_removal && s.ever_on) || s.user.is_empty() {
        return Ok(s);
    }
    if lock.is_err() {
        return Err(s);
    }
    let seen = schedule_locked(platform::sync_started).unwrap_or_default();
    let mozc_db = platform::mozc_dir().join("user_dictionary.db");
    let mozc_db = platform::mozc_dir().is_dir().then_some(mozc_db.as_path());
    s.status = match sync_with(&s, &platform::rime_dir(), mozc_db) {
        Ok(()) => {
            s.at = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs() as i64);
            Status::Synced
        }
        Err(Failed::Login) => Status::LoginFailed,
        Err(Failed::Offline) => Status::Offline,
    };
    // Only the outcome: sync may have been turned off, or SebType removed, while this one ran.
    let _ = schedule_locked(|| {
        let mut now = load();
        if !now.user.is_empty() {
            (now.status, now.at) = (s.status, s.at);
            let _ = save(&now);
        }
        platform::after_sync(seen, now.enabled);
    });
    if s.status == Status::Synced {
        Ok(s)
    } else {
        Err(s)
    }
}

/// Deletes every device's learned words and dictionaries on the server, and turns sync off; the words
/// on this PC stay. False if the server couldn't be reached (nothing deleted, sync stays as it was).
pub fn delete_on_server() -> bool {
    let Ok(_lock) = lock() else { return false };
    let s = load();
    if s.user.is_empty() || client(&s, &["delete".as_ref()]).is_err() {
        return false;
    }
    drop(_lock);
    let Ok(mut s) = set_enabled(false) else {
        return false;
    };
    s.ever_on = false; // nothing of this PC's is on the server any more
    save(&s).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_addresses_are_https_except_to_this_pc() {
        let n = |t: &str| normalize_server(t);
        assert_eq!(
            n(" sync.example.com/ ").as_deref(),
            Some("https://sync.example.com")
        );
        assert_eq!(
            n("sync.example.com:8443/sebtype").as_deref(),
            Some("https://sync.example.com:8443/sebtype")
        );
        assert_eq!(
            n("http://127.0.0.1:8740").as_deref(),
            Some("http://127.0.0.1:8740")
        );
        assert_eq!(n("http://[::1]:8740").as_deref(), Some("http://[::1]:8740"));
        for bad in ["http://sync.example.com", "ftp://x", "", "https://", "a b"] {
            assert_eq!(n(bad), None, "{bad:?}");
        }
    }

    /// The client against a real sebtype_sync.py server, both ways, with a private keyring, Fcitx5, Rime
    /// and Mozc: run by test.sh in a private D-Bus session on a sandbox account, never the desktop's.
    /// Made-up words and a throwaway login only.
    #[test]
    #[ignore]
    #[cfg(target_os = "linux")]
    fn private_server_syncs_both_ways_and_delete_clears_it() {
        use crate::mozc;
        let var = |n: &str| std::env::var(n).unwrap_or_else(|_| panic!("{n} not set"));
        let (server, user, password) = (
            var("SEBTYPE_TEST_SYNC_SERVER"),
            var("SEBTYPE_TEST_SYNC_USER"),
            var("SEBTYPE_TEST_SYNC_PASSWORD"),
        );
        // The server as another device sees it; the login goes to curl on stdin, never on a command line.
        let http = |method: &str, path: &str, body: &str| {
            let mut c = std::process::Command::new("curl")
                .args(["-sSf", "-K", "-", "-X", method, "--data-binary", body])
                .arg(format!("{server}{path}"))
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            let mut stdin = c.stdin.take().unwrap();
            writeln!(stdin, "user = \"{user}:{password}\"").unwrap();
            drop(stdin);
            let out = c.wait_with_output().unwrap();
            assert!(out.status.success(), "{method} {path}");
            String::from_utf8(out.stdout).unwrap()
        };
        let get = |path: &str| http("GET", path, "");

        let rime_dir = platform::rime_dir();
        let own = rime::own_sync_folder(&rime_dir).expect("no installation.yaml");
        let device = own.file_name().unwrap().to_string_lossy().into_owned();
        let snapshot = |device: &str, line: &str| {
            format!(
                "# Rime user dictionary\n#@/db_name\trime_ice\n#@/db_type\tuserdb\n#@/rime_version\t1.16.1\n\
                 #@/tick\t3\n#@/user_id\t{device}\n{line}\n"
            )
        };

        // A word this PC's Rime learned: Rime takes in its own folder's snapshot too, then the snapshot
        // goes, so only Rime's learned words hold it until the sync writes it again.
        fs::create_dir_all(&own).unwrap();
        let pc_snapshot = own.join("rime_ice.userdb.txt");
        let pc_word = "mo fu ji \t莫福姬\tc=3 d=1 t=3";
        fs::write(&pc_snapshot, snapshot(&device, pc_word)).unwrap();
        platform::sync_rime(&own).unwrap();
        assert!(
            fs::read_to_string(&pc_snapshot).unwrap().contains("莫福姬"),
            "Rime took in the PC's word"
        );
        fs::remove_file(&pc_snapshot).unwrap();
        let mozc_dir = platform::mozc_dir();
        let pc_ja = mozc::Word {
            reading: "もふてすと".into(),
            word: "モフ試験語".into(),
            pos: 0,
            mozc_pos: None,
        };
        mozc::save_words(&mozc_dir, &[pc_ja]).unwrap();
        let pc_zh = rime::Word {
            word: "莫噗试词".into(),
            pinyin: "mopushici".into(),
        };
        rime::save_words(&rime_dir, &[pc_zh]).unwrap();

        // Another device's words on the server.
        http("DELETE", "/v1/files", "");
        http(
            "PUT",
            "/v1/files/sebtype-test-phone/rime_ice.userdb.txt",
            &snapshot("sebtype-test-phone", "pu lu mo \t普噜莫\tc=2 d=1 t=3"),
        );
        http(
            "PUT",
            "/v1/files/sebtype-test-phone/mozc_dictionary.txt",
            "ぷるもて\tプルモ試験語\t名詞\n",
        );
        http(
            "PUT",
            "/v1/files/sebtype-test-phone/zh_my_words.userdb.txt",
            "pulumoci\t普噜莫词\t名詞\t\t1000\n",
        );

        keyring().unwrap().set_password(&password).unwrap();
        let on = Sync {
            enabled: true,
            server: server.clone(),
            user: user.clone(),
            ever_on: true,
            ..Sync::default()
        };
        save(&on).unwrap();
        assert_eq!(run(false).unwrap().status, Status::Synced);

        // A word on the PC reaches the server.
        assert!(get(&format!("/v1/files/{device}/rime_ice.userdb.txt")).contains("莫福姬"));
        assert!(get(&format!("/v1/files/{device}/mozc_dictionary.txt"))
            .contains("もふてすと\tモフ試験語"));
        assert!(get(&format!("/v1/files/{device}/zh_my_words.userdb.txt"))
            .contains("mopushici\t莫噗试词"));
        // A word from another device reaches the PC's Rime (merged into its learned words, which its
        // own snapshot is written from) and Mozc.
        assert!(
            fs::read_to_string(&pc_snapshot).unwrap().contains("普噜莫"),
            "Rime merged the phone's word"
        );
        assert!(
            mozc::words(&mozc_dir)
                .unwrap()
                .iter()
                .any(|w| w.word == "プルモ試験語"),
            "Mozc got the phone's word, in My words (#273)"
        );
        assert!(
            rime::words(&rime_dir).iter().any(|w| w.word == "普噜莫词"),
            "Chinese My words got the phone's word (#272)"
        );

        // A wrong password is the status line's, and touches nothing.
        keyring()
            .unwrap()
            .set_password("made-up-wrong-password")
            .unwrap();
        assert_eq!(run(false).unwrap_err().status, Status::LoginFailed);
        keyring().unwrap().set_password(&password).unwrap();

        // Turned off, the schedule's sync does nothing; Setup's, before it deletes learned words, still
        // syncs, since sync was on.
        set_enabled(false).unwrap();
        assert_eq!(run(false).map(|s| s.status), Ok(Status::LoginFailed));
        assert_eq!(run(true).unwrap().status, Status::Synced);

        // Delete clears the server and turns sync off; the PC's words stay.
        assert!(delete_on_server());
        assert_eq!(get("/v1/files").replace(' ', ""), "{\"files\":[]}");
        assert!(!load().enabled && !load().ever_on);
        assert!(fs::read_to_string(&pc_snapshot).unwrap().contains("莫福姬"));
    }

    /// Setup deletes learned words only when this says nothing is left unsynced (#271): a due sync that
    /// doesn't go through is an error, and a sync that was never on is not. A private profile, a server
    /// nobody listens on, and no keyring to read: never the account's own login.
    #[test]
    fn a_due_sync_that_fails_is_an_error() {
        let d = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/sync-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        for var in [
            "LOCALAPPDATA",
            "APPDATA",
            "USERPROFILE",
            "XDG_DATA_HOME",
            "XDG_CONFIG_HOME",
        ] {
            std::env::set_var(var, &d);
        }
        std::env::set_var("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);

        let never_on = Sync {
            server,
            user: "made-up".into(),
            ..Sync::default()
        };
        save(&never_on).unwrap();
        assert!(run(true).is_ok(), "never on: nothing to sync");

        save(&Sync {
            ever_on: true,
            ..never_on.clone()
        })
        .unwrap();
        assert!(
            run(false).is_ok(),
            "off: the schedule's sync has nothing to do"
        );
        let failed = run(true).unwrap_err();
        assert_ne!(failed.status, Status::Synced);
        assert_eq!(load().status, failed.status, "kept for the window");

        save(&Sync {
            enabled: true,
            ..never_on
        })
        .unwrap();
        assert!(run(false).is_err());
        fs::remove_dir_all(&d).unwrap();
    }

    fn temp(name: &str) -> std::path::PathBuf {
        let d = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// A pull that changed My words deploys Rime until a deploy goes through (#272).
    #[test]
    fn a_pending_deploy_stays_until_one_goes_through() {
        let d = temp("deploy");
        let flag = d.join("rime-deploy-pending");
        let mut deploys = 0;
        deploy_if_pending(&flag, || {
            deploys += 1;
            Ok(())
        })
        .unwrap();
        assert_eq!(deploys, 0, "nothing pending");
        fs::write(&flag, "").unwrap();
        assert!(deploy_if_pending(&flag, || Err(io::Error::other("made up"))).is_err());
        assert!(flag.exists(), "a failed deploy is tried again");
        deploy_if_pending(&flag, || Ok(())).unwrap();
        assert!(!flag.exists());
        fs::remove_dir_all(&d).unwrap();
    }

    /// The startup refresh of one Configurator, slow to make the schedule, and sync turned off in another
    /// meanwhile: the schedule ends off (#377). The refresh runs in a second process, this test's own
    /// executable running slow_refresh_in_another_process.
    #[test]
    fn a_refresh_in_another_configurator_cant_bring_back_a_schedule_turned_off() {
        let d = temp("schedule");
        let on = Sync {
            enabled: true,
            ..Default::default()
        };
        save_in(&d, &on).unwrap();
        let mut other = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "sync::tests::slow_refresh_in_another_process",
            ])
            .env("SEBTYPE_TEST_SCHEDULE_DIR", &d)
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let end = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !d.join("refreshing").exists() {
            assert!(
                std::time::Instant::now() < end,
                "the other process never refreshed"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let off = change_schedule(&d, |s| s.enabled = false, |on| made(&d, on)).unwrap();
        assert!(other.wait().unwrap().success());
        assert!(!off.enabled);
        assert_eq!(
            fs::read_to_string(d.join("made")).unwrap(),
            "true\nfalse\n",
            "the schedule ends off"
        );
        fs::remove_dir_all(&d).unwrap();
    }

    fn made(d: &Path, on: bool) -> io::Result<()> {
        let mut f = fs::File::options()
            .create(true)
            .append(true)
            .open(d.join("made"))?;
        writeln!(f, "{on}")
    }

    #[test]
    #[ignore]
    fn slow_refresh_in_another_process() {
        let d = PathBuf::from(std::env::var_os("SEBTYPE_TEST_SCHEDULE_DIR").unwrap());
        change_schedule(
            &d,
            |_| {},
            |on| {
                fs::write(d.join("refreshing"), "")?;
                std::thread::sleep(std::time::Duration::from_millis(500));
                made(&d, on)
            },
        )
        .unwrap();
    }

    /// A word edit waits for a pull that holds the words, and the other way round (#272).
    #[test]
    fn word_edits_wait_for_each_other() {
        let d = temp("words-lock");
        let lock = d.join("words.lock");
        let (held, release) = (
            std::sync::mpsc::channel::<()>(),
            std::sync::mpsc::channel::<()>(),
        );
        let path = lock.clone();
        let holder = std::thread::spawn(move || {
            locked_in(&path, || {
                held.0.send(()).unwrap();
                release.1.recv().unwrap();
                std::time::Instant::now()
            })
            .unwrap()
        });
        held.1.recv().unwrap();
        let waiter = std::thread::spawn(move || locked_in(&lock, std::time::Instant::now).unwrap());
        std::thread::sleep(std::time::Duration::from_millis(200));
        release.0.send(()).unwrap();
        let released = holder.join().unwrap();
        assert!(
            waiter.join().unwrap() >= released,
            "ran only after the release"
        );
        fs::remove_dir_all(&d).unwrap();
    }
}
