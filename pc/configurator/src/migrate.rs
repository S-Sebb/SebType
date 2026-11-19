//! An older Configurator's learning off (#374), which hid the learned words: rime-ice's enable_user_dict
//! and Mozc's NO_HISTORY. It moves to sebtype.conf, and the engines read their settings again.

use crate::{mozc, rime};
use std::{fs, io, path::Path};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Engine {
    Rime,
    Mozc,
}
const ENGINES: [(Engine, &str); 2] = [(Engine::Rime, "rime"), (Engine::Mozc, "mozc")];

/// Learning off as an older Configurator left it. Rime's line has SebType's comment; Mozc's NO_HISTORY has
/// no mark, so it counts as SebType's when Rime's agrees, or with no Rime folder for the old switch to have
/// written to (it wrote both where it could). Otherwise it is the person's own, from Mozc's own tool.
pub fn old_learning_off(rime_dir: &Path, mozc_dir: &Path) -> bool {
    rime::old_learning_off(rime_dir) || old_mozc(rime_dir, mozc_dir)
}
fn old_mozc(rime_dir: &Path, mozc_dir: &Path) -> bool {
    mozc::old_learning_off(mozc_dir) && (rime::old_learning_off(rime_dir) || !rime_dir.is_dir())
}

/// Removes the old learning off and has `refresh` make each engine read its settings again. `pending`
/// lists the engines still to refresh, written before anything is removed and cleared only as each
/// refresh goes through: a refresh that failed, or a run cut off, is retried by the next call.
pub fn drop_old(
    rime_dir: &Path,
    mozc_dir: &Path,
    pending: &Path,
    refresh: impl Fn(Engine) -> io::Result<()>,
) -> io::Result<()> {
    let listed = fs::read_to_string(pending).unwrap_or_default();
    let mut todo: Vec<Engine> = ENGINES
        .iter()
        .filter(|(e, name)| {
            listed.lines().any(|l| l == *name)
                || match e {
                    Engine::Rime => rime::old_learning_off(rime_dir),
                    Engine::Mozc => old_mozc(rime_dir, mozc_dir),
                }
        })
        .map(|(e, _)| *e)
        .collect();
    if todo.is_empty() {
        return Ok(());
    }
    write_pending(pending, &todo)?;
    // Mozc's first: its NO_HISTORY counts as SebType's by Rime's line.
    if todo.contains(&Engine::Mozc) {
        mozc::drop_old_learning(mozc_dir)?;
    }
    rime::drop_old_learning(rime_dir)?;
    while let Some(&e) = todo.first() {
        refresh(e)?;
        todo.remove(0);
        write_pending(pending, &todo)?;
    }
    Ok(())
}

fn write_pending(pending: &Path, todo: &[Engine]) -> io::Result<()> {
    if todo.is_empty() {
        return fs::remove_file(pending);
    }
    let names: Vec<&str> = ENGINES
        .iter()
        .filter(|(e, _)| todo.contains(e))
        .map(|(_, n)| *n)
        .collect();
    fs::create_dir_all(pending.parent().unwrap())?;
    fs::write(pending, names.join("\n") + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto;
    use std::{cell::RefCell, path::PathBuf};

    const PATCH: &str = "rime_ice.custom.yaml";
    const SETUP: &str = "patch:\n  schema/name: \".中文\"  # SebType (#69)\n";
    const OLD_RIME: &str = "  translator/enable_user_dict: false  # SebType: don't learn\n";

    fn dirs(name: &str) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        // In the crate's target/, not /tmp (#211); each test removes its folder when it passes.
        let d = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("target/test-tmp/{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let (rime, mozc) = (d.join("rime"), d.join("mozc"));
        fs::create_dir_all(&rime).unwrap();
        fs::create_dir_all(&mozc).unwrap();
        let pending = d.join("sebtype/learning-migration");
        (d, rime, mozc, pending)
    }
    fn no_history() -> Vec<u8> {
        let mut cfg = proto::varint_field(41, 0);
        cfg.extend(proto::varint_field(50, 2));
        cfg
    }

    #[test]
    fn a_failed_refresh_is_retried_by_the_next_migration() {
        let (d, rime, mozc, pending) = dirs("migrate-retry");
        fs::write(rime.join(PATCH), format!("{SETUP}{OLD_RIME}")).unwrap();
        fs::write(mozc.join("config1.db"), no_history()).unwrap();
        assert!(old_learning_off(&rime, &mozc));
        let done = RefCell::new(Vec::new());
        // Rime's refresh fails (as if Fcitx5 or the server didn't take it): the old settings are gone, so
        // only the list remembers what is left to do.
        let failing = |e| {
            if e == Engine::Rime {
                return Err(io::Error::other("Fcitx5 didn't answer"));
            }
            done.borrow_mut().push(e);
            Ok(())
        };
        assert!(drop_old(&rime, &mozc, &pending, failing).is_err());
        assert!(!old_learning_off(&rime, &mozc));
        assert_eq!(fs::read_to_string(rime.join(PATCH)).unwrap(), SETUP);
        assert_eq!(
            fs::read(mozc.join("config1.db")).unwrap(),
            proto::varint_field(41, 0)
        );
        assert_eq!(fs::read_to_string(&pending).unwrap(), "rime\nmozc\n");
        let ok = |e| {
            done.borrow_mut().push(e);
            Ok(())
        };
        drop_old(&rime, &mozc, &pending, ok).unwrap();
        assert_eq!(*done.borrow(), [Engine::Rime, Engine::Mozc]);
        assert!(!pending.exists());
        drop_old(&rime, &mozc, &pending, ok).unwrap();
        assert_eq!(done.borrow().len(), 2, "nothing left to do");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn restrictions_sebtype_did_not_write_stay() {
        let (d, rime, mozc, pending) = dirs("migrate-own");
        // Written by hand: no SebType comment; Mozc's NO_HISTORY with Chinese set up and its learning on.
        let own = format!("{SETUP}  translator/enable_user_dict: false\n");
        fs::write(rime.join(PATCH), &own).unwrap();
        fs::write(mozc.join("config1.db"), no_history()).unwrap();
        assert!(!old_learning_off(&rime, &mozc));
        drop_old(&rime, &mozc, &pending, |_| panic!("nothing to refresh")).unwrap();
        assert_eq!(fs::read_to_string(rime.join(PATCH)).unwrap(), own);
        assert_eq!(fs::read(mozc.join("config1.db")).unwrap(), no_history());
        assert!(!pending.exists());
        // With no Chinese set up, the old switch wrote only Mozc's: SebType's.
        fs::remove_dir_all(&rime).unwrap();
        assert!(old_learning_off(&rime, &mozc));
        drop_old(&rime, &mozc, &pending, |e| {
            assert_eq!(e, Engine::Mozc);
            Ok(())
        })
        .unwrap();
        assert!(!old_learning_off(&rime, &mozc));
        fs::remove_dir_all(&d).unwrap();
    }
}
