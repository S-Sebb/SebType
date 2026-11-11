//! Linux: Fcitx5 with fcitx5-rime and fcitx5-mozc, set up by pc/linux/setup-ime.sh. A running Fcitx5
//! is told over D-Bus (busctl); without one, its files are written and read when it starts.

use crate::Candidates;
use std::{env, fs, io, path::PathBuf, process::Command};

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
/// SebType's pig (logo.svg) at the start of the Picnic window (#94). Fcitx5 scales theme images with the
/// DPI but not with the font, so the logo is sized here: a little under the window's inner height.
fn picnic_files(font_size: i32) -> [(&'static str, String); 6] {
    let height = 16 + font_size * 6 / 5; // px at 96 dpi: 28 at 10 pt, 44 at 24 pt
    let width = (height * 158 + 80) / 160; // the logo image is 158x160
    [
        (
            "theme.conf",
            // 9 px before the logo (OverlayOffsetX), 4 after it
            include_str!("../fcitx5-theme/theme.conf")
                .replace("@LOGO_MARGIN@", &(width + 13).to_string()),
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
        ("prev.svg", include_str!("../fcitx5-theme/prev.svg").into()),
        ("next.svg", include_str!("../fcitx5-theme/next.svg").into()),
    ]
}
/// SebType's languages as Fcitx5 input methods.
const IMS: [(&str, &str); 3] = [("en", "keyboard-us"), ("zh", "rime"), ("ja", "mozc")];

fn xdg(var: &str, fallback: &str) -> PathBuf {
    env::var_os(var)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(fallback))
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
    config().join("mozc")
}
fn profile() -> PathBuf {
    config().join("fcitx5/profile")
}
fn classicui() -> PathBuf {
    config().join("fcitx5/conf/classicui.conf")
}
fn mozc_conf() -> PathBuf {
    config().join("fcitx5/conf/mozc.conf")
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

// --- INI files (Fcitx5's profile and addon configs) ---

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

// --- Languages: the first input method group, in Super+Space order ---

struct Group {
    name: String,
    layout: String,
    items: Vec<(String, String)>, // input method, layout
}

fn group() -> io::Result<Group> {
    if fcitx_running() {
        let name: serde_json::Value =
            serde_json::from_str(&controller("CurrentInputMethodGroup", &[])?)?;
        let name = name["data"][0].as_str().unwrap_or("Default").to_string();
        let info: serde_json::Value =
            serde_json::from_str(&controller("InputMethodGroupInfo", &["s", &name])?)?;
        let d = &info["data"];
        let items = d[1]
            .as_array()
            .into_iter()
            .flatten()
            .map(|i| (s(&i[0]), s(&i[1])))
            .collect();
        return Ok(Group {
            name,
            layout: s(&d[0]),
            items,
        });
    }
    // The profile: [Groups/0] Name= / Default Layout=, then [Groups/0/Items/N] Name= / Layout=.
    let text = fs::read_to_string(profile()).unwrap_or_default();
    let mut g = Group {
        name: "Default".into(),
        layout: "us".into(),
        items: vec![],
    };
    let mut section = String::new();
    for line in text.lines() {
        if let Some(s) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = s.to_string();
            if section.starts_with("Groups/0/Items/") {
                g.items.push((String::new(), String::new()));
            }
        } else if let Some((k, v)) = line.split_once('=') {
            match (section.as_str(), k) {
                ("Groups/0", "Name") => g.name = v.into(),
                ("Groups/0", "Default Layout") => g.layout = v.into(),
                (s, "Name") if s.starts_with("Groups/0/Items/") => {
                    g.items.last_mut().unwrap().0 = v.into()
                }
                (s, "Layout") if s.starts_with("Groups/0/Items/") => {
                    g.items.last_mut().unwrap().1 = v.into()
                }
                _ => {}
            }
        }
    }
    Ok(g)
}
fn s(v: &serde_json::Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

/// SebType's three languages, those on first in their order, then those off.
pub fn langs() -> io::Result<Vec<(String, bool)>> {
    let g = group()?;
    let mut out: Vec<(String, bool)> = g
        .items
        .iter()
        .filter_map(|(im, _)| IMS.iter().find(|(_, n)| n == im))
        .map(|(id, _)| (id.to_string(), true))
        .collect();
    for (id, _) in IMS {
        if !out.iter().any(|(i, _)| i == id) {
            out.push((id.to_string(), false));
        }
    }
    Ok(out)
}

pub fn set_langs(langs: &[(String, bool)]) -> io::Result<()> {
    let g = group()?;
    let layout_of = |im: &str| {
        g.items
            .iter()
            .find(|(n, _)| n == im)
            .map(|(_, l)| l.clone())
            .unwrap_or_default()
    };
    let mut items: Vec<(String, String)> = langs
        .iter()
        .filter(|(_, on)| *on)
        .filter_map(|(id, _)| IMS.iter().find(|(i, _)| i == id))
        .map(|(_, im)| (im.to_string(), layout_of(im)))
        .collect();
    // Input methods that aren't SebType's stay, after SebType's.
    items.extend(
        g.items
            .iter()
            .filter(|(im, _)| !IMS.iter().any(|(_, n)| n == im))
            .cloned(),
    );
    if fcitx_running() {
        let n = items.len().to_string();
        let mut args = vec!["ssa(ss)", &g.name, &g.layout, &n];
        for (im, layout) in &items {
            args.push(im);
            args.push(layout);
        }
        controller("SetInputMethodGroupInfo", &args)?;
        return Ok(());
    }
    // Fcitx5 not running: rewrite the group's items in its profile.
    let text = fs::read_to_string(profile()).unwrap_or_default();
    let mut out = String::new();
    let mut skip = false;
    for line in text.lines() {
        if let Some(s) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            skip = s.starts_with("Groups/0/Items/");
            if skip {
                continue;
            }
        }
        if !skip {
            out.push_str(line);
            out.push('\n');
        }
    }
    for (i, (im, layout)) in items.iter().enumerate() {
        out.push_str(&format!(
            "\n[Groups/0/Items/{i}]\nName={im}\nLayout={layout}\n"
        ));
    }
    write_if_changed(&profile(), &out).map(|_| ())
}

// --- The candidate window: Fcitx5's classic UI draws it for Rime and Mozc alike ---

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
    let mut changed = write_if_changed(&path, &ui)? | theme_changed;
    // fcitx5-mozc lays out its own candidates (its Vertical option, on by default).
    let mozc = fs::read_to_string(mozc_conf()).unwrap_or_default();
    let mozc_changed = write_if_changed(&mozc_conf(), &ini_set(&mozc, "Vertical", tf(c.vertical)))?;
    if changed {
        reload_addon("classicui");
    }
    if mozc_changed {
        reload_addon("mozc");
    }
    changed |= mozc_changed;
    Ok(changed)
}

// --- Engines ---

/// fcitx5-rime's deploy (its 重新部署 menu entry): Rime rereads its files and rebuilds what changed.
pub fn redeploy_rime() -> io::Result<()> {
    if fcitx_running() {
        controller(
            "SetConfig",
            &["sv", "fcitx://config/addon/rime/deploy", "s", ""],
        )?;
    }
    Ok(())
}

/// Rime is restarted by the deploy, which closes the learned-words database before it opens a new one.
pub fn forget_rime() -> io::Result<usize> {
    let n = crate::rime::forget(&rime_dir())?;
    redeploy_rime()?;
    Ok(n)
}

fn stop_mozc() {
    let user = env::var("USER").unwrap_or_default();
    if let Ok(out) = Command::new("pgrep")
        .args(["-x", "-u", &user, "mozc_server"])
        .output()
    {
        for pid in String::from_utf8_lossy(&out.stdout).split_whitespace() {
            let _ = Command::new("kill").arg(pid).status();
        }
    }
}
/// mozc_server reads its config and dictionaries when it starts; fcitx5-mozc starts it on the next key.
pub fn restart_mozc() {
    stop_mozc();
}
pub fn forget_mozc() -> io::Result<usize> {
    stop_mozc();
    std::thread::sleep(std::time::Duration::from_millis(300)); // it saves its files on the way out
    crate::mozc::forget(&mozc_dir())
}

pub fn open_url(url: &str) {
    let _ = Command::new("xdg-open").arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picnic_logo_follows_the_font_size() {
        for (size, w, h, margin) in [(9, 26, 26, 39), (10, 28, 28, 41), (24, 43, 44, 56)] {
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
    /// its own Fcitx5 on a copy of rime-ice (keyboard-us, rime and mozc in its group), never the desktop's.
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
            .contains(" width=\"28\" height=\"28\" "));
        assert!(candidates().picnic);
    }
}
