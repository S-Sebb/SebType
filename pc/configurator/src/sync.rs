//! Sync with the user's own server (#12, #180), as the phone does (#14): 中文's learned words through
//! Rime's sync folder, and the Japanese dictionary, by sync-server/sebtype_sync.py's own pull and push.
//! The server and username are kept in SebType's folder (sync.json, with the last sync's outcome); the
//! password only in the system's keyring (Secret Service, Credential Manager), handed to the client on
//! its stdin. The schedule (platform::schedule) runs `sebtype-configurator --sync` every half hour.

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
    fs::read_to_string(dir().join("sync.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save(s: &Sync) -> io::Result<()> {
    fs::create_dir_all(dir())?;
    let tmp = dir().join("sync.json.new");
    fs::write(&tmp, serde_json::to_string_pretty(s)?)?;
    fs::rename(tmp, dir().join("sync.json"))
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
    let mut s = load();
    let first = s.user.is_empty();
    (s.server, s.user, s.status) = (server, user, Status::NotYet);
    if first {
        s.enabled = true;
    }
    s.ever_on |= s.enabled;
    save(&s).map_err(|e| e.to_string())?;
    if s.enabled {
        platform::schedule(true).map_err(|e| e.to_string())?;
    }
    Ok(s)
}

pub fn set_enabled(on: bool) -> io::Result<Sync> {
    let mut s = load();
    s.enabled = on;
    s.ever_on |= on;
    save(&s)?;
    platform::schedule(on)?;
    Ok(s)
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

/// How many words pull added to Mozc's dictionary, from its "pull: N file(s), M new word(s) for Mozc".
fn new_mozc_words(pulled: &str) -> usize {
    pulled
        .split(", ")
        .nth(1)
        .and_then(|w| w.split(' ').next()?.parse().ok())
        .unwrap_or(0)
}

/// One sync, as the phone's: the other devices' changes come down, Rime merges them and writes this
/// PC's own snapshot, and that goes up with the Japanese dictionary.
fn sync_with(s: &Sync, rime_dir: &Path, mozc_db: Option<&Path>) -> Result<(), Failed> {
    let mut args = vec!["--rime-dir".as_ref(), rime_dir.as_os_str()];
    if let Some(db) = mozc_db {
        args.extend(["--mozc-db".as_ref(), db.as_os_str()]);
    }
    let pull = [&["pull".as_ref()], &args[..]].concat();
    let pulled = client(s, &pull)?;
    if let Some(own) = rime::own_sync_folder(rime_dir) {
        platform::sync_rime(&own);
    }
    let push = [&["push".as_ref()], &args[..]].concat();
    client(s, &push)?;
    if new_mozc_words(&pulled) > 0 {
        platform::restart_mozc(); // Mozc reads its dictionary when it starts
    }
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
/// outcome for the window.
pub fn run(before_removal: bool) -> Sync {
    let Ok(_lock) = lock() else { return load() };
    let mut s = load();
    if !(s.enabled || before_removal && s.ever_on) || s.user.is_empty() {
        return s;
    }
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
    let _ = save(&s);
    s
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
        platform::sync_rime(&own);
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
        };
        mozc::save_words(&mozc_dir, &[pc_ja]).unwrap();

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

        keyring().unwrap().set_password(&password).unwrap();
        let on = Sync {
            enabled: true,
            server: server.clone(),
            user: user.clone(),
            ever_on: true,
            ..Sync::default()
        };
        save(&on).unwrap();
        assert_eq!(run(false).status, Status::Synced);

        // A word on the PC reaches the server.
        assert!(get(&format!("/v1/files/{device}/rime_ice.userdb.txt")).contains("莫福姬"));
        assert!(get(&format!("/v1/files/{device}/mozc_dictionary.txt"))
            .contains("もふてすと\tモフ試験語"));
        // A word from another device reaches the PC's Rime (merged into its learned words, which its
        // own snapshot is written from) and Mozc.
        assert!(
            fs::read_to_string(&pc_snapshot).unwrap().contains("普噜莫"),
            "Rime merged the phone's word"
        );
        let db = fs::read(mozc_dir.join("user_dictionary.db")).unwrap();
        assert!(
            String::from_utf8_lossy(&db).contains("プルモ試験語"),
            "Mozc got the phone's word"
        );

        // A wrong password is the status line's, and touches nothing.
        keyring()
            .unwrap()
            .set_password("made-up-wrong-password")
            .unwrap();
        assert_eq!(run(false).status, Status::LoginFailed);
        keyring().unwrap().set_password(&password).unwrap();

        // Turned off, the schedule's sync does nothing; Setup's, before it deletes learned words, still
        // syncs, since sync was on.
        set_enabled(false).unwrap();
        assert_eq!(run(false).status, Status::LoginFailed);
        assert_eq!(run(true).status, Status::Synced);

        // Delete clears the server and turns sync off; the PC's words stay.
        assert!(delete_on_server());
        assert_eq!(get("/v1/files").replace(' ', ""), "{\"files\":[]}");
        assert!(!load().enabled && !load().ever_on);
        assert!(fs::read_to_string(&pc_snapshot).unwrap().contains("莫福姬"));
    }

    #[test]
    fn mozc_words_come_from_pulls_line() {
        assert_eq!(
            new_mozc_words("pull: 2 file(s), 3 new word(s) for Mozc\n"),
            3
        );
        assert_eq!(
            new_mozc_words("pull: 0 file(s), 0 new word(s) for Mozc\n"),
            0
        );
    }
}
