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
pub fn forget_mozc() -> io::Result<usize> {
    let n = crate::mozc::learned(&mozc_dir());
    forget("ja")?;
    Ok(n)
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

pub fn open_url(url: &str) {
    let _ = Command::new("rundll32")
        .args(["url.dll,FileProtocolHandler", url])
        .creation_flags(NO_WINDOW)
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The sync task also runs when Windows connects to a network (#377), half a minute later, and never
    /// twice at once.
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
