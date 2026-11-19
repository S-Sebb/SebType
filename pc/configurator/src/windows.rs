//! Windows: SebType's text service (windows/, #190) with Rime for Chinese and Mozc for Japanese, set up by
//! SebType's installer (pc/windows/setup, #73). The candidate window's look is sebtype.conf's
//! [Candidates]; the languages are the Windows user language list.

use crate::Candidates;
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
/// sebtype.conf, which the text service reads its candidate window from.
fn conf() -> PathBuf {
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
    let text = fs::read_to_string(conf()).unwrap_or_default();
    let get = |key| conf_value(&text, key);
    Candidates {
        vertical: get("Vertical") != Some("0"),
        font_size: get("FontSize").and_then(|v| v.parse().ok()).unwrap_or(14),
        picnic: get("Picnic") == Some("1"),
    }
}

/// A key of sebtype.conf's [Candidates].
fn conf_value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .skip_while(|l| l.trim() != "[Candidates]")
        .skip(1)
        .take_while(|l| !l.trim_start().starts_with('['))
        .find_map(|l| l.strip_prefix(key)?.strip_prefix('='))
        .map(str::trim)
}

/// sebtype.conf `old` with the candidate window settings `c`, its other sections kept.
fn candidate_conf(old: &str, c: &Candidates) -> String {
    let mut out: Vec<&str> = Vec::new();
    let mut lines = old.lines().peekable();
    while let Some(l) = lines.next() {
        if l.trim() == "[Candidates]" {
            while lines
                .peek()
                .is_some_and(|n| !n.trim_start().starts_with('['))
            {
                lines.next();
            }
        } else {
            out.push(l);
        }
    }
    let section = format!(
        "[Candidates]\nVertical={}\nFontSize={}\nPicnic={}\n",
        c.vertical as u8, c.font_size, c.picnic as u8
    );
    let rest = out.join("\n");
    let rest = rest.trim();
    if rest.is_empty() {
        section
    } else {
        format!("{rest}\n{section}")
    }
}

/// The text service reads the window's look when it next shows it: nothing to restart.
pub fn set_candidates(c: &Candidates) -> io::Result<bool> {
    let old = fs::read_to_string(conf()).unwrap_or_default();
    let new = candidate_conf(&old, c);
    if new == old {
        return Ok(false);
    }
    fs::create_dir_all(conf().parent().unwrap())?;
    fs::write(conf(), new)?;
    Ok(true)
}

// --- Engines ---

/// Returns when Rime is done.
pub fn redeploy_rime() -> io::Result<()> {
    server("/deploy")
}

pub fn forget_rime() -> io::Result<usize> {
    // The server holds the learned words open; /deploy starts it again.
    server("/quit")?;
    let n = crate::rime::forget(&rime_dir());
    redeploy_rime()?;
    n
}

/// Mozc, in SebType's server, reads its config and dictionaries when it starts: it saves and closes (before
/// the server's command returns), and the next Japanese key starts it again.
pub fn restart_mozc() {
    let _ = server("/mozc");
}
pub fn forget_mozc() -> io::Result<usize> {
    restart_mozc(); // or it would write the history back
    crate::mozc::forget(&mozc_dir())
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
pub fn restart_mozc_when_idle() {
    let _ = server("/mozc-when-idle");
}

const SYNC_TASK: &str = "SebType sync";

/// Syncs every half hour with a Task Scheduler task while sync is on. It runs as the user, only while
/// they are logged on, which Credential Manager needs.
pub fn schedule(on: bool) -> io::Result<()> {
    if on {
        let exe = env::current_exe()?;
        let command = format!("\"{}\" --sync", exe.display());
        let args = [
            "/create", "/tn", SYNC_TASK, "/tr", &command, "/sc", "minute", "/mo", "30", "/f",
        ];
        return run("schtasks", &args).map(|_| ());
    }
    // No task (sync was never on) is fine.
    let _ = run("schtasks", &["/delete", "/tn", SYNC_TASK, "/f"]);
    Ok(())
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

    #[test]
    fn candidate_conf_replaces_its_section_and_keeps_the_rest() {
        let c = Candidates {
            vertical: false,
            font_size: 16,
            picnic: true,
        };
        let old = "[Other]\nA=1\n[Candidates]\nVertical=1\nFontSize=14\n[Later]\nB=2\n";
        let new = candidate_conf(old, &c);
        assert_eq!(
            new,
            "[Other]\nA=1\n[Later]\nB=2\n[Candidates]\nVertical=0\nFontSize=16\nPicnic=1\n"
        );
        assert_eq!(conf_value(&new, "FontSize"), Some("16"));
        assert_eq!(conf_value(&new, "A"), None);
        assert_eq!(candidate_conf(&new, &c), new);
    }
}
