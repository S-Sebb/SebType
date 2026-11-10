//! Rime `*.custom.yaml` patches, edited as lines so the entries and comments setup-ime and the user put
//! there stay. An entry is a line `  key: value` right under `patch:`, plus the more-indented lines (or
//! `  - ` list items) below it.

fn indent(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

fn entry_key(line: &str) -> Option<&str> {
    if indent(line) != 2 || line.trim_start().starts_with(['#', '-']) {
        return None;
    }
    line.trim_start().split_once(':').map(|(k, _)| k)
}

fn continues(line: &str) -> bool {
    !line.trim().is_empty()
        && (indent(line) > 2 || (indent(line) == 2 && line.trim_start().starts_with("- ")))
}

/// The value written after `key:`, without its comment.
pub fn value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().find(|l| entry_key(l) == Some(key)).map(|l| {
        let v = l.split_once(':').unwrap().1;
        v.split(" #").next().unwrap().trim().trim_matches('"')
    })
}

/// The lines under `key:`, trimmed.
pub fn block(text: &str, key: &str) -> Vec<String> {
    let mut lines = text.lines().skip_while(|l| entry_key(l) != Some(key));
    if lines.next().is_none() {
        return vec![];
    }
    lines
        .take_while(|l| continues(l))
        .map(|l| l.trim().to_string())
        .collect()
}

/// `text` with the entries for `keys` replaced by `entries` (whole lines), which go right under `patch:`.
pub fn set(text: &str, keys: &[&str], entries: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut inserted = false;
    let mut skipping = false;
    for line in text.lines() {
        if skipping && continues(line) {
            continue;
        }
        skipping = false;
        if entry_key(line).is_some_and(|k| keys.contains(&k)) {
            skipping = true;
            continue;
        }
        out.push(line.to_string());
        if !inserted && line.trim_end() == "patch:" {
            out.extend(entries.iter().cloned());
            inserted = true;
        }
    }
    if !inserted && !entries.is_empty() {
        out.push("patch:".into());
        out.extend(entries.iter().cloned());
    }
    let mut s = out.join("\n");
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIVE: &str = "patch:\n  schema/name: \".中文\"  # SebType (#69)\n  # Caps Lock, see lua/caps_passthrough.lua\n  engine/processors/@before 0: lua_processor@*caps_passthrough\n  speller/algebra/+:\n    - derive/^z/zh/\n    - derive/^zh/z/\n  key_binder/bindings/+:\n  - { when: always, toggle: traditionalization, accept: Control+Shift+f }\n";

    #[test]
    fn replaces_only_its_own_entries_and_keeps_the_rest() {
        let out = set(
            LIVE,
            &["speller/algebra/+", "switches/@2/reset"],
            &["  switches/@2/reset: 1".into()],
        );
        assert_eq!(
            out,
            "patch:\n  switches/@2/reset: 1\n  schema/name: \".中文\"  # SebType (#69)\n  # Caps Lock, see lua/caps_passthrough.lua\n  engine/processors/@before 0: lua_processor@*caps_passthrough\n  key_binder/bindings/+:\n  - { when: always, toggle: traditionalization, accept: Control+Shift+f }\n"
        );
        // Setting the same entries again changes nothing.
        assert_eq!(
            set(
                &out,
                &["speller/algebra/+", "switches/@2/reset"],
                &["  switches/@2/reset: 1".into()]
            ),
            out
        );
    }

    #[test]
    fn reads_values_and_blocks() {
        assert_eq!(value(LIVE, "schema/name"), Some(".中文"));
        assert_eq!(value(LIVE, "menu/page_size"), None);
        assert_eq!(
            block(LIVE, "speller/algebra/+"),
            ["- derive/^z/zh/", "- derive/^zh/z/"]
        );
        assert_eq!(block(LIVE, "key_binder/bindings/+").len(), 1);
    }

    #[test]
    fn starts_a_patch_in_an_empty_file() {
        assert_eq!(
            set("", &["menu/page_size"], &["  menu/page_size: 7".into()]),
            "patch:\n  menu/page_size: 7\n"
        );
    }
}
