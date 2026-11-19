//! sebtype.conf, SebType's own settings (core/: Settings), shared with the input method (Linux) and the
//! text service (Windows): INI sections, each written whole, the others kept.

/// A key of `section`.
pub fn value<'a>(text: &'a str, section: &str, key: &str) -> Option<&'a str> {
    let header = format!("[{section}]");
    text.lines()
        .skip_while(|l| l.trim() != header)
        .skip(1)
        .take_while(|l| !l.trim_start().starts_with('['))
        .find_map(|l| l.strip_prefix(key)?.strip_prefix('='))
        .map(str::trim)
}

/// `text` with `section` holding `lines` (each ending in a newline) at the end, or gone when they are empty.
pub fn set_section(text: &str, section: &str, lines: &str) -> String {
    let header = format!("[{section}]");
    let mut out: Vec<&str> = Vec::new();
    let mut inside = false;
    for l in text.lines() {
        if l.trim_start().starts_with('[') {
            inside = l.trim() == header;
        }
        if !inside {
            out.push(l);
        }
    }
    let rest = out.join("\n");
    let rest = rest.trim();
    let section = if lines.is_empty() {
        String::new()
    } else {
        format!("{header}\n{lines}")
    };
    match (rest.is_empty(), section.is_empty()) {
        (true, _) => section,
        (false, true) => format!("{rest}\n"),
        (false, false) => format!("{rest}\n{section}"),
    }
}

/// Learning from typing, in every language. Off, the engines still use what they learned and learn
/// nothing new, as in a private field (#374): Rime's no_learning, Mozc's history read-only.
pub fn learning(text: &str) -> bool {
    value(text, "Learning", "On") != Some("false")
}
pub fn set_learning(text: &str, on: bool) -> String {
    set_section(text, "Learning", if on { "" } else { "On=false\n" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_section_is_replaced_or_removed_and_the_rest_kept() {
        let old = "[Other]\nA=1\n[Candidates]\nVertical=1\nFontSize=14\n[Later]\nB=2\n";
        let new = set_section(old, "Candidates", "Vertical=0\nFontSize=16\n");
        assert_eq!(
            new,
            "[Other]\nA=1\n[Later]\nB=2\n[Candidates]\nVertical=0\nFontSize=16\n"
        );
        assert_eq!(value(&new, "Candidates", "FontSize"), Some("16"));
        assert_eq!(value(&new, "Candidates", "A"), None);
        assert_eq!(
            set_section(&new, "Candidates", "Vertical=0\nFontSize=16\n"),
            new
        );
        assert_eq!(
            set_section(&new, "Candidates", ""),
            "[Other]\nA=1\n[Later]\nB=2\n"
        );
        assert_eq!(
            set_section("", "Languages", "Order=zh\n"),
            "[Languages]\nOrder=zh\n"
        );
    }

    #[test]
    fn learning_off_is_the_cores_learning_section() {
        let langs = "[Languages]\nOrder=en,zh,ja\n";
        assert!(learning(langs));
        let off = set_learning(langs, false);
        // As core/src/core.cpp (Settings::serialize) writes and reads it.
        assert_eq!(off, "[Languages]\nOrder=en,zh,ja\n[Learning]\nOn=false\n");
        assert!(!learning(&off));
        assert_eq!(set_learning(&off, true), langs);
    }
}
