//! Windows: SebType's Weasel (小狼毫) for Chinese and Mozc for Japanese, set up by pc/windows/setup-ime.ps1
//! (later the installer, #73). Weasel's look is its weasel.custom.yaml; the languages are the Windows
//! user language list.

use crate::{patch, Candidates};
use std::{env, fs, io, os::windows::process::CommandExt, path::PathBuf, process::Command};

pub const SYSTEM: &str = "Windows";
pub const UI_FONT: &str = "Microsoft YaHei UI";
const NO_WINDOW: u32 = 0x0800_0000; // CREATE_NO_WINDOW: no console flashes up for helper programs
const WEASEL_TIP: &str =
    "0804:{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}{3D02CAB6-2B8E-4781-BA20-1C9267529467}";
/// SebType's languages as Windows language tags.
const TAGS: [(&str, &str); 3] = [("en", "en-US"), ("zh", "zh-Hans-CN"), ("ja", "ja")];
const STYLE: &str = "weasel.custom.yaml";
const PICNIC: &str = "sebtype_picnic";
/// Weasel colours are 0xBBGGRR. Picnic: cream panel, brown text and border, key-pink highlight.
const PICNIC_SCHEME: [&str; 12] = [
    "    name: SebType Picnic",
    "    author: SebType",
    "    text_color: 0x222f4a",
    "    back_color: 0xe8f7ff",
    "    border_color: 0x1c335b",
    "    shadow_color: 0x00000000",
    "    hilited_text_color: 0x222f4a",
    "    hilited_back_color: 0xe6e0fd",
    "    hilited_candidate_text_color: 0xffffff",
    "    hilited_candidate_back_color: 0x6a50c2",
    "    candidate_text_color: 0x222f4a",
    "    comment_text_color: 0x3f5373",
];

fn appdata(var: &str) -> PathBuf {
    PathBuf::from(env::var_os(var).unwrap_or_default())
}
pub fn rime_dir() -> PathBuf {
    appdata("APPDATA").join("Rime")
}
/// SebType's own Mozc (#65) keeps Mozc's folder; until then Google 日本語入力's has the same files.
pub fn mozc_dir() -> PathBuf {
    let low = appdata("USERPROFILE").join("AppData\\LocalLow");
    let own = low.join("Mozc");
    if own.exists() {
        own
    } else {
        low.join("Google\\Google Japanese Input")
    }
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
    // Windows PowerShell: its language cmdlets are the ones that can change the list (setup-ime.ps1).
    run(
        "powershell.exe",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!("[Console]::OutputEncoding = [Text.Encoding]::UTF8; {script}"),
        ],
    )
}

fn weasel_root() -> Option<PathBuf> {
    let out = run(
        "reg",
        &[
            "query",
            "HKLM\\SOFTWARE\\WOW6432Node\\Rime\\Weasel",
            "/v",
            "WeaselRoot",
        ],
    )
    .ok()?;
    out.lines()
        .find_map(|l| l.split_once("REG_SZ"))
        .map(|(_, v)| PathBuf::from(v.trim()))
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
        // A language turned back on gets the keyboard SebType set up: Weasel for Chinese.
        let tips = list
            .iter()
            .find(|(t, _)| t == tag)
            .map(|(_, tips)| tips.clone());
        let tips = tips.unwrap_or_else(|| {
            if id == "zh" {
                WEASEL_TIP.into()
            } else {
                String::new()
            }
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

// --- The candidate window: Weasel's style, in weasel.custom.yaml ---

fn style_text() -> String {
    fs::read_to_string(rime_dir().join(STYLE)).unwrap_or_default()
}

pub fn candidates() -> Candidates {
    let s = style_text();
    let shipped = fs::read_to_string(rime_dir().join("weasel.yaml")).unwrap_or_default();
    Candidates {
        vertical: patch::value(&s, "style/horizontal") != Some("true"),
        font_size: patch::value(&s, "style/font_point")
            .and_then(|v| v.parse().ok())
            .or_else(|| {
                shipped.lines().find_map(|l| {
                    l.trim()
                        .strip_prefix("font_point:")?
                        .split('#')
                        .next()?
                        .trim()
                        .parse()
                        .ok()
                })
            })
            .unwrap_or(14),
        picnic: patch::value(&s, "style/color_scheme") == Some(PICNIC),
    }
}

pub fn set_candidates(c: &Candidates) -> io::Result<bool> {
    let keys = [
        "style/horizontal",
        "style/font_point",
        "style/color_scheme",
        "preset_color_schemes/sebtype_picnic",
    ];
    let mut entries = vec![
        format!("  style/horizontal: {}", !c.vertical),
        format!("  style/font_point: {}", c.font_size),
    ];
    if c.picnic {
        entries.push(format!("  style/color_scheme: {PICNIC}"));
        entries.push(format!("  preset_color_schemes/{PICNIC}:"));
        entries.extend(PICNIC_SCHEME.iter().map(|l| l.to_string()));
    }
    let old = style_text();
    let new = patch::set(&old, &keys, &entries);
    if new == old {
        return Ok(false);
    }
    fs::create_dir_all(rime_dir())?;
    fs::write(rime_dir().join(STYLE), new)?;
    redeploy_rime()?;
    Ok(true)
}

// --- Engines ---

pub fn redeploy_rime() -> io::Result<()> {
    let Some(root) = weasel_root() else {
        return Ok(());
    };
    // The exact argument "/deploy": with anything else the deployer opens its settings window instead.
    Command::new(root.join("WeaselDeployer.exe"))
        .arg("/deploy")
        .creation_flags(NO_WINDOW)
        .status()?;
    Ok(())
}

pub fn forget_rime() -> io::Result<usize> {
    let root = weasel_root();
    if let Some(r) = &root {
        let _ = Command::new(r.join("WeaselServer.exe"))
            .arg("/q")
            .creation_flags(NO_WINDOW)
            .status();
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    let n = crate::rime::forget(&rime_dir());
    if let Some(r) = &root {
        Command::new(r.join("WeaselServer.exe"))
            .creation_flags(NO_WINDOW)
            .spawn()?;
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    redeploy_rime()?;
    n
}

fn stop_mozc() {
    for exe in ["mozc_server.exe", "GoogleIMEJaConverter.exe"] {
        let _ = run("taskkill", &["/F", "/IM", exe]);
    }
}
pub fn restart_mozc() {
    stop_mozc();
}
pub fn forget_mozc() -> io::Result<usize> {
    stop_mozc();
    std::thread::sleep(std::time::Duration::from_millis(300));
    crate::mozc::forget(&mozc_dir())
}

pub fn open_url(url: &str) {
    let _ = Command::new("rundll32")
        .args(["url.dll,FileProtocolHandler", url])
        .creation_flags(NO_WINDOW)
        .spawn();
}
