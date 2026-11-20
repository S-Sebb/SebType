//! Windows: SebType's text service (windows/, #190) with Rime for Chinese and Mozc for Japanese, set up by
//! SebType's installer (pc/windows/setup, #73). The candidate window's look is sebtype.conf's
//! [Candidates], learning its [Learning]; the languages are the Windows user language list.

use crate::{conf, write_file, Candidates};
use std::{
    env, fs, io,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
};

pub const SYSTEM: &str = "Windows";
/// Windows' UI font for the window's language, so 日本語 gets Japanese kanji shapes.
pub fn ui_font(lang: &str) -> &'static str {
    if lang == "ja" {
        "Yu Gothic UI"
    } else {
        "Microsoft YaHei UI"
    }
}
const NO_WINDOW: u32 = 0x0800_0000; // CREATE_NO_WINDOW: no console flashes up for helper programs
/// SebType's text service: its 中文 and 日本語 profiles (windows/src/tip/tip.h).
const ZH_TIP: &str =
    "0804:{D4E5C593-4F73-475F-936C-0E29A6FE7A02}{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}";
const JA_TIP: &str =
    "0411:{D4E5C593-4F73-475F-936C-0E29A6FE7A02}{B148FB02-C235-45D6-996C-672C783ECD48}";
/// SebType's languages as Windows language tags.
const TAGS: [(&str, &str); 3] = [("en", "en-US"), ("zh", "zh-Hans-CN"), ("ja", "ja")];

fn appdata(var: &str) -> PathBuf {
    PathBuf::from(env::var_os(var).unwrap_or_default())
}
pub fn rime_dir() -> PathBuf {
    appdata("APPDATA").join("Rime")
}
pub fn mozc_dir() -> PathBuf {
    appdata("USERPROFILE").join("AppData\\LocalLow\\Mozc")
}
/// sebtype.conf, which the text service reads its candidate window from and the server its learning.
fn conf_path() -> PathBuf {
    appdata("APPDATA").join("SebType\\sebtype.conf")
}

fn run(program: &str, args: &[&str]) -> io::Result<String> {
    let out = Command::new(program)
        .args(args)
        .creation_flags(NO_WINDOW)
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "{program}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
fn powershell(script: &str) -> io::Result<String> {
    // Windows PowerShell: its language cmdlets are the ones that can change the list (pc/windows/setup/setup.ps1).
    // Its own modules, not those of a PowerShell 7 the Configurator was started from (#299).
    run(
        "powershell.exe",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!(
                "$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'); \
                 [Console]::OutputEncoding = [Text.Encoding]::UTF8; {script}"
            ),
        ],
    )
}

/// SebType's server, next to the Configurator: it hosts Rime and Mozc for the text service.
fn server(arg: &str) -> io::Result<()> {
    let status = Command::new(env::current_exe()?.with_file_name("sebtype-server.exe"))
        .arg(arg)
        .creation_flags(NO_WINDOW)
        .status()?;
    if !status.success() {
        return Err(io::Error::other(format!(
            "sebtype-server.exe {arg}: {status}"
        )));
    }
    Ok(())
}

// --- Languages ---

fn language_list() -> io::Result<Vec<(String, String)>> {
    let out = powershell("Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag + '|' + ($_.InputMethodTips -join ',') }")?;
    Ok(out
        .lines()
        .filter_map(|l| l.split_once('|'))
        .map(|(t, tips)| (t.to_string(), tips.to_string()))
        .collect())
}

pub fn langs() -> io::Result<Vec<(String, bool)>> {
    let list = language_list()?;
    let mut out: Vec<(String, bool)> = list
        .iter()
        .filter_map(|(t, _)| TAGS.iter().find(|(_, tag)| tag == t))
        .map(|(id, _)| (id.to_string(), true))
        .collect();
    for (id, _) in TAGS {
        if !out.iter().any(|(i, _)| i == id) {
            out.push((id.to_string(), false));
        }
    }
    Ok(out)
}

pub fn set_langs(langs: &[(String, bool)]) -> io::Result<()> {
    let list = language_list()?;
    let mut lines = vec!["$l = New-WinUserLanguageList en-US; $l.Clear()".to_string()];
    let mut add = |tag: &str, tips: &str| {
        lines.push(format!(
            "$x = New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage '{tag}'"
        ));
        if !tips.is_empty() {
            lines.push("$x.InputMethodTips.Clear()".into());
            for tip in tips.split(',') {
                lines.push(format!("$x.InputMethodTips.Add('{tip}')"));
            }
        }
        lines.push("$l.Add($x)".into());
    };
    for (id, _) in langs.iter().filter(|(_, on)| *on) {
        let tag = TAGS.iter().find(|(i, _)| i == id).unwrap().1;
        // A language turned back on gets SebType's text service.
        let tips = list
            .iter()
            .find(|(t, _)| t == tag)
            .map(|(_, tips)| tips.clone());
        let tips = tips.unwrap_or_else(|| match id.as_str() {
            "zh" => ZH_TIP.into(),
            "ja" => JA_TIP.into(),
            _ => String::new(),
        });
        add(tag, &tips);
    }
    for (tag, tips) in list
        .iter()
        .filter(|(t, _)| !TAGS.iter().any(|(_, tag)| tag == t))
    {
        add(tag, tips);
    }
    lines.push("Set-WinUserLanguageList $l -Force".into());
    powershell(&lines.join("; ")).map(|_| ())
}

// --- The candidate window: sebtype.conf's [Candidates], which the text service reads ---

pub fn candidates() -> Candidates {
    let text = fs::read_to_string(conf_path()).unwrap_or_default();
    let get = |key| conf::value(&text, "Candidates", key);
    Candidates {
        vertical: get("Vertical") != Some("0"),
        font_size: get("FontSize").and_then(|v| v.parse().ok()).unwrap_or(14),
        picnic: get("Picnic") == Some("1"),
    }
}

/// sebtype.conf with `change` made; true when it changed.
fn edit_conf(change: impl FnOnce(&str) -> String) -> io::Result<bool> {
    let old = fs::read_to_string(conf_path()).unwrap_or_default();
    write_file(&conf_path(), change(&old))
}

/// The text service reads the window's look when it next shows it: nothing to restart.
pub fn set_candidates(c: &Candidates) -> io::Result<bool> {
    let lines = format!(
        "Vertical={}\nFontSize={}\nPicnic={}\n",
        c.vertical as u8, c.font_size, c.picnic as u8
    );
    edit_conf(|old| conf::set_section(old, "Candidates", &lines))
}

// --- Learning: sebtype.conf's [Learning], which the server reads ---

pub fn learning() -> bool {
    conf::learning(&fs::read_to_string(conf_path()).unwrap_or_default())
}
/// The server applies it before /settings returns; a server that can't (one before #374) or didn't answer
/// fails it. Told again on a retry, as the file may already say so while the server doesn't (#374).
pub fn set_learning(on: bool) -> io::Result<()> {
    edit_conf(|old| conf::set_learning(old, on))?;
    server("/settings")
}

// --- Engines ---

/// Returns when Rime is done.
pub fn redeploy_rime() -> io::Result<()> {
    server("/deploy")
}

/// The server's engine forgets before it returns (#375): it closes its files, deletes what it learned and
/// opens new ones, with no key in between; with no server, sebtype-server.exe does it itself.
fn forget(lang: &str) -> io::Result<()> {
    let status = Command::new(env::current_exe()?.with_file_name("sebtype-server.exe"))
        .arg(format!("/forget:{lang}"))
        .creation_flags(NO_WINDOW)
        .status()?;
    match status.code() {
        Some(0) => {}
        Some(7) => {
            return Err(io::Error::other(
                "the SebType server running is too old to forget: sign out and in, then try again",
            ))
        }
        Some(6) => {
            return Err(io::Error::other(format!(
                "something learned couldn't be deleted (sebtype-server.exe /forget:{lang}; server.log says what)"
            )))
        }
        _ => {
            return Err(io::Error::other(format!(
                "sebtype-server.exe /forget:{lang}: {status}"
            )))
        }
    }
    Ok(())
}

pub fn forget_rime() -> io::Result<usize> {
    let n = crate::rime::learned(&rime_dir())?.len();
    forget("zh")?;
    Ok(n)
}

/// Mozc, in SebType's server, reads its config and dictionaries when it starts: it saves and closes (before
/// the server's command returns), and the next Japanese key starts it again.
pub fn restart_mozc() {
    let _ = server("/mozc");
}
/// With the words lock, which a pull holds: as on Linux (linux.rs).
pub fn forget_mozc() -> io::Result<usize> {
    crate::sync::words_locked(|| {
        let n = crate::mozc::learned(&mozc_dir());
        forget("ja")?;
        Ok(n)
    })?
}

// --- Sync (#180) ---

/// SebType's own folder, next to Setup's setup.json: sync's server, username and last outcome, and its
/// client.
pub fn sebtype_dir() -> PathBuf {
    appdata("LOCALAPPDATA").join("SebType")
}

/// The Python the installer puts next to the Configurator (Python's embeddable package, sebtype.iss):
/// Windows has none of its own.
pub fn python() -> Command {
    let exe = env::current_exe().unwrap_or_default();
    let mut c = Command::new(exe.with_file_name("python").join("python.exe"));
    c.creation_flags(NO_WINDOW);
    c
}

/// Rime's 用户资料同步, in SebType's server: Rime merges the other devices' snapshots into the learned
/// words and writes this PC's. Returns when it is done.
pub fn sync_rime(_own: &Path) -> io::Result<()> {
    server("/sync")
}

/// Rime's deploy and Mozc's restart for a sync's pull: the server does them once typing is idle, as they
/// drop what is being typed (#373). The Configurator's own changes and forgetting do them at once.
pub fn redeploy_rime_when_idle() -> io::Result<()> {
    server("/deploy-when-idle")
}
/// The same, returning once the server has it: an idle wait could last as long as someone types.
pub fn queue_rime_redeploy() -> io::Result<()> {
    let status = Command::new(env::current_exe()?.with_file_name("sebtype-server.exe"))
        .args(["/deploy-when-idle", "/queue"])
        .creation_flags(NO_WINDOW)
        .status()?;
    if !status.success() {
        return Err(io::Error::other(format!(
            "sebtype-server.exe /deploy-when-idle /queue: {status}"
        )));
    }
    Ok(())
}
pub fn restart_mozc_when_idle() -> io::Result<()> {
    server("/mozc-when-idle")
}

const SYNC_TASK: &str = "SebType sync";

/// The sync task: every half hour, and half a minute after Windows connects to a network (#377), as the
/// user and only while they are logged on, which Credential Manager needs. A run while one still runs is
/// skipped (IgnoreNew), so a network that comes and goes doesn't stack them.
fn sync_task(exe: &Path) -> String {
    let exe = exe
        .display()
        .to_string()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    // NetworkProfile's event 10000: connected to a network.
    let connected = "<QueryList><Query Id=\"0\" Path=\"Microsoft-Windows-NetworkProfile/Operational\">\
        <Select Path=\"Microsoft-Windows-NetworkProfile/Operational\">\
        *[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>";
    let connected = connected.replace('<', "&lt;").replace('>', "&gt;");
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Repetition><Interval>PT30M</Interval></Repetition>
    </TimeTrigger>
    <EventTrigger>
      <Subscription>{connected}</Subscription>
      <Delay>PT30S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>{exe}</Command><Arguments>--sync</Arguments></Exec>
  </Actions>
</Task>
"#
    )
}

pub fn schedule(on: bool) -> io::Result<()> {
    if on {
        // schtasks reads a task with more than one trigger only from a UTF-16 file.
        let file = env::temp_dir().join(format!("sebtype-sync-task-{}.xml", std::process::id()));
        let utf16: Vec<u8> = "\u{feff}"
            .chars()
            .chain(sync_task(&env::current_exe()?).chars())
            .collect::<String>()
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        fs::write(&file, utf16)?;
        let made = run(
            "schtasks",
            &[
                "/create",
                "/tn",
                SYNC_TASK,
                "/xml",
                &file.to_string_lossy(),
                "/f",
            ],
        );
        let _ = fs::remove_file(&file);
        return made.map(|_| ());
    }
    // No task (sync was never on) is fine.
    let _ = run("schtasks", &["/delete", "/tn", SYNC_TASK, "/f"]);
    Ok(())
}

/// Task Scheduler runs the task for each network connection (sync_task): nothing more to plan.
pub fn sync_started() -> u64 {
    0
}
pub fn after_sync(_seen: u64, _enabled: bool) {}

// --- Updates (#422) ---

pub fn installed_version() -> String {
    crate::update::BUILT.into()
}

/// The downloads, in SebType's folder, which uninstalling removes.
pub fn updates_dir() -> PathBuf {
    sebtype_dir().join("updates")
}

/// The Start menu shortcut's AppUserModelID (sebtype.iss), which Windows shows a toast under.
const AUMID: &str = "SebType.Configurator";

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// A toast. A click on it or its button opens sebtype-configurator:update, which Setup registers to open
/// the About page (sebtype.iss), so nothing waits here.
fn toast_xml(summary: &str, body: &str, action: &str) -> String {
    let open = "sebtype-configurator:update";
    format!(
        "<toast activationType=\"protocol\" launch=\"{open}\"><visual><binding template=\"ToastGeneric\">\
         <text>{}</text><text>{}</text></binding></visual><actions>\
         <action content=\"{}\" activationType=\"protocol\" arguments=\"{open}\"/></actions></toast>",
        xml(summary),
        xml(body),
        xml(action)
    )
}

/// `shown` runs once Windows took the toast.
pub fn notify_update(
    summary: &str,
    body: &str,
    action: &str,
    shown: &mut dyn FnMut(),
) -> io::Result<()> {
    let out = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!(
                "$ErrorActionPreference = 'Stop'; \
                 $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]; \
                 $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]; \
                 $x = New-Object Windows.Data.Xml.Dom.XmlDocument; $x.LoadXml($env:SEBTYPE_TOAST); \
                 [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{AUMID}').Show([Windows.UI.Notifications.ToastNotification]::new($x))"
            ),
        ])
        .env("SEBTYPE_TOAST", toast_xml(summary, body, action))
        .creation_flags(NO_WINDOW)
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "toast: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    shown();
    Ok(())
}

/// A PowerShell script with values set before it, for -EncodedCommand: nothing on the way can change it,
/// and the values are base64, so no quoting.
fn encoded(values: &[(&str, &str)], arrays: &[(&str, &[&str])], script: &str) -> String {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let value = |v: &str| {
        format!(
            "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{}')))",
            STANDARD.encode(v)
        )
    };
    let mut all = String::new();
    for (name, v) in values {
        all += &format!("${name} = {}\n", value(v));
    }
    for (name, vs) in arrays {
        let vs: Vec<String> = vs.iter().map(|v| value(v)).collect();
        all += &format!("${name} = @({})\n", vs.join(", "));
    }
    all += script;
    let utf16: Vec<u8> = all.encode_utf16().flat_map(u16::to_le_bytes).collect();
    STANDARD.encode(utf16)
}

/// Setup as an update runs it: silent but for its progress, with the languages chosen before, and only
/// the machine's part: the person's runs as them (update-user.ps1).
const SETUP_ARGS: [&str; 4] = ["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOUSERSTEPS"];

/// The admin side (start-setup.ps1) for this setup; `root` for the tests only.
fn start_setup_command(setup: &Path, sha: &str, args: &[&str], root: Option<&Path>) -> String {
    let (setup, root) = (setup.to_string_lossy(), root.map(|r| r.to_string_lossy()));
    let mut values = vec![("Setup", &*setup), ("Sha", sha)];
    values.extend(root.as_deref().map(|r| ("Root", r)));
    encoded(
        &values,
        &[("Arguments", args)],
        include_str!("start-setup.ps1"),
    )
}

/// Installs the release's Setup (pc/windows/README.md) through update-user.ps1, which runs it with one UAC
/// prompt from a copy start-setup.ps1 checked where only admins can write, and this person's steps as
/// them. Returns once UAC is approved; the caller then quits, so Setup can replace this exe, and the
/// About page opens again afterwards.
pub fn install_update(files: &[crate::update::Download]) -> io::Result<()> {
    use io::BufRead;
    let (setup, sha) = files.first().ok_or_else(|| io::Error::other("no setup"))?;
    let app = env::current_exe()?;
    let app = app.parent().ok_or_else(|| io::Error::other("no folder"))?;
    let elevated = start_setup_command(setup, sha, &SETUP_ARGS, None);
    let command = encoded(
        &[
            ("App", &app.to_string_lossy()),
            ("State", &sebtype_dir().to_string_lossy()),
            ("Elevated", &elevated),
        ],
        &[],
        include_str!("update-user.ps1"),
    );
    let mut user = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &command])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .creation_flags(NO_WINDOW)
        .spawn()?;
    let mut line = String::new();
    io::BufReader::new(user.stdout.take().unwrap()).read_line(&mut line)?;
    match line.trim() {
        "approved" => Ok(()), // it runs on: Setup, then this person's steps
        "cancelled" => Err(io::Error::other(
            "not allowed: the admin prompt was cancelled",
        )),
        l => Err(io::Error::other(
            l.strip_prefix("error: ")
                .unwrap_or("the update didn't start")
                .to_string(),
        )),
    }
}

/// What a finished update's own side couldn't do, once (update-user.ps1).
pub fn update_error() -> Option<String> {
    let file = sebtype_dir().join("update-error.txt");
    let e = fs::read_to_string(&file).ok()?;
    let _ = fs::remove_file(file);
    Some(e)
}

pub fn open_url(url: &str) {
    let _ = Command::new("rundll32")
        .args(["url.dll,FileProtocolHandler", url])
        .creation_flags(NO_WINDOW)
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A click on the toast or its button opens the About page through Setup's protocol; the text is escaped.
    #[test]
    fn the_toast_opens_the_about_page() {
        let t = toast_xml("SebType 0.2.0 <is> available", "A & B", "Update…");
        assert!(t.starts_with(
            "<toast activationType=\"protocol\" launch=\"sebtype-configurator:update\">"
        ));
        assert!(t.contains("<text>SebType 0.2.0 &lt;is&gt; available</text><text>A &amp; B</text>"));
        assert!(t.contains("activationType=\"protocol\" arguments=\"sebtype-configurator:update\""));
    }

    /// The admin side (here not elevated, in a folder of the test's) starts Setup from its own copy
    /// once that has the release's SHA-256, and nothing when the download isn't the release's.
    #[test]
    fn an_update_starts_only_a_checked_copy_of_the_setup() {
        let d = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "target/test-tmp/start-setup-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let root = d.join("protected");
        // a stand-in for Setup that needs no admin
        let setup = d.join("SebType setup.exe");
        fs::copy(r"C:\Windows\System32\PING.EXE", &setup).unwrap();
        let sha = crate::update::sha256_file(&setup).unwrap();
        let run = |sha: &str| {
            Command::new("powershell.exe")
                .args(["-NoProfile", "-NonInteractive", "-EncodedCommand"])
                .arg(start_setup_command(
                    &setup,
                    sha,
                    &["-n", "1", "127.0.0.1"],
                    Some(&root),
                ))
                .output()
                .unwrap()
        };
        let out = run(&sha);
        let said = String::from_utf8_lossy(&out.stdout).trim().to_string();
        assert_eq!(out.status.code(), Some(0), "{out:?}");
        let copy = said
            .splitn(3, ' ')
            .nth(2)
            .map(PathBuf::from)
            .unwrap_or_default();
        assert!(
            said.starts_with("started ") && copy.starts_with(&root),
            "{said}"
        );
        assert_eq!(crate::update::sha256_file(&copy).unwrap(), sha);
        let out = run(&"0".repeat(64));
        assert_eq!(out.status.code(), Some(90), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("SebType setup.exe isn't the release's")
        );
        // nothing of the refused copy left (the first one may be: Windows holds an exe just run a moment)
        let first = copy.parent().and_then(Path::file_name).unwrap();
        let left: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert!(left.iter().all(|n| n == first), "{left:?}");
        let _ = fs::remove_dir_all(&d);
    }

    /// The admin side runs Setup without the person's steps: an administrator approving UAC for them
    /// would get those (update-user.ps1 runs them as the person).
    #[test]
    fn an_update_runs_setup_without_the_persons_steps() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        let utf16 = STANDARD
            .decode(start_setup_command(
                Path::new(r"C:\a\SebType-setup-0.2.0.exe"),
                "ab",
                &SETUP_ARGS,
                None,
            ))
            .unwrap();
        let units: Vec<u16> = utf16
            .chunks(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let script = String::from_utf16(&units).unwrap();
        let switch = STANDARD.encode("/NOUSERSTEPS");
        assert!(
            script
                .lines()
                .any(|l| l.starts_with("$Arguments = @(") && l.contains(&switch)),
            "{script}"
        );
        assert!(
            !script.lines().any(|l| l.starts_with("$Root =")),
            "the shipping one copies into Program Files"
        );
    }

    #[test]
    fn sync_task_runs_when_the_network_comes_back() {
        let task = sync_task(Path::new(r"C:\Program Files\A&B\sebtype-configurator.exe"));
        assert!(task.contains("<Interval>PT30M</Interval>"));
        assert!(task.contains(
            "Path=\"Microsoft-Windows-NetworkProfile/Operational\"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]&lt;/Select&gt;"
        ));
        assert!(task.contains("<Delay>PT30S</Delay>"));
        assert!(task.contains("<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"));
        assert!(task.contains(
            r"<Command>C:\Program Files\A&amp;B\sebtype-configurator.exe</Command><Arguments>--sync</Arguments>"
        ));
    }
}
