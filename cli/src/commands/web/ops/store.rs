//! Shared on-disk operation store (JSON state + log files under the ops dir).
//! Used by activation, update, genswitch, and nix-store repair jobs.

use std::collections::HashSet;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::utils::locks::{Holder, LockManager};
pub use crate::utils::ops::{append_log, log_path, state_path};
use crate::utils::ops::{operations_dir, write_op_state, OperationKind};

/// How long a web-triggered op may sit in `phase=triggered` before systemd-run
/// has acquired the lock. After this, a missing holder means the spawn failed.
const TRIGGER_GRACE_SECS: u64 = 120;

/// Write op state (no branch / start time / extra fields).
pub fn write_state(id: &str, status: &str, phase: &str, err: Option<&str>) {
    write_op_state(id, status, phase, err, None, None, None);
}

/// Whether a live lock holder still owns this in-progress op.
///
/// Prefer an exact `op_id` match. Holders without `op_id` (plain CLI) keep every
/// in-progress op of that lock kind until the lock is released — then
/// [`reap_stale_in_progress`] marks them failed.
fn op_still_running(id: &str, kind: OperationKind, holders: &[Holder]) -> bool {
    let lock_kind = kind.lock_kind();
    let kind_holders: Vec<&Holder> = holders.iter().filter(|h| h.kind == lock_kind).collect();
    if kind_holders.is_empty() {
        return false;
    }
    if kind_holders.iter().any(|h| h.op_id.as_deref() == Some(id)) {
        return true;
    }
    let claimed: HashSet<&str> = kind_holders
        .iter()
        .filter_map(|h| h.op_id.as_deref())
        .collect();
    // Another tracked op holds the lock — this id is not it.
    if !claimed.is_empty() {
        return false;
    }
    // Untracked holder of this kind (CLI without op_id): treat as still running.
    true
}

fn mark_op_aborted(id: &str, v: &serde_json::Value) {
    let phase = v.get("phase").and_then(|x| x.as_str()).unwrap_or("aborted");
    let started = v.get("started_at").and_then(|x| x.as_str());
    let branch = v.get("branch").and_then(|x| x.as_str());
    let err = "operation is no longer running (aborted or process exited)";
    write_op_state(id, "failed", phase, Some(err), branch, started, None);
    append_log(&log_path(id), &format!("marked failed: {err}"));
}

/// Mark `in_progress` ops failed when no live lock holder owns them.
///
/// CLI activate/update write state under `/tmp/neo-activations` and take a
/// flock-backed system lock. Aborting the process drops the lock but left the
/// JSON as `in_progress`, so the web UI kept showing a running job. Locks are
/// the source of truth; this reaps orphans (with a short grace for the web
/// `triggered` phase before systemd-run acquires the lock).
pub fn reap_stale_in_progress() {
    let dir = operations_dir();
    if !dir.exists() {
        return;
    }
    let holders = LockManager::system().holders();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let Ok(rd) = fs::read_dir(&dir) else {
        return;
    };
    for e in rd.flatten() {
        let name = e.file_name();
        let name = name.to_string_lossy();
        if !name.ends_with(".json") {
            continue;
        }
        let id = name.trim_end_matches(".json");
        let Some(kind) = OperationKind::from_id(id) else {
            continue;
        };
        let Ok(s) = fs::read_to_string(e.path()) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) else {
            continue;
        };
        if v.get("status").and_then(|x| x.as_str()) != Some("in_progress") {
            continue;
        }
        if op_still_running(id, kind, &holders) {
            continue;
        }
        let phase = v.get("phase").and_then(|x| x.as_str()).unwrap_or("");
        if phase == "triggered" {
            let Ok(meta) = e.metadata() else {
                continue;
            };
            let Ok(mtime) = meta.modified() else {
                continue;
            };
            let t = mtime
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            if now.saturating_sub(t) < TRIGGER_GRACE_SECS {
                continue;
            }
        }
        mark_op_aborted(id, &v);
    }
}

/// Most recent in-progress op of `kind` (within the last hour).
pub fn find_recent_in_progress(kind: OperationKind) -> Option<String> {
    // Drop aborted CLI/web jobs before the UI or single-flight checks read them.
    reap_stale_in_progress();
    let prefix = format!("{}_", kind.prefix());
    let dir = operations_dir();
    if !dir.exists() {
        return None;
    }
    let mut best: Option<(String, u64)> = None;
    if let Ok(rd) = fs::read_dir(&dir) {
        for e in rd.flatten() {
            let name = e.file_name();
            let name = name.to_string_lossy();
            if !(name.ends_with(".json") && name.starts_with(&prefix)) {
                continue;
            }
            let Ok(meta) = e.metadata() else { continue };
            let Ok(mtime) = meta.modified() else { continue };
            let t = mtime
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            if now > t + 3600 {
                continue;
            }
            let Ok(s) = fs::read_to_string(e.path()) else {
                continue;
            };
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) else {
                continue;
            };
            if v.get("status").and_then(|x| x.as_str()) != Some("in_progress") {
                continue;
            }
            if best.as_ref().is_none_or(|&(_, bt)| t > bt) {
                let id = name.trim_end_matches(".json").to_string();
                best = Some((id, t));
            }
        }
    }
    best.map(|(id, _)| id)
}

/// Drop ops older than 7 days, then keep only the 10 newest files.
/// Called from the action-bar watcher and once at op trigger start — not from
/// per-poll monitor/status/log fragment builders (those are on the hot path).
pub fn gc_old_ops() {
    reap_stale_in_progress();
    let dir = operations_dir();
    if !dir.exists() {
        return;
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if let Ok(rd) = fs::read_dir(&dir) {
        for e in rd.flatten() {
            let p = e.path();
            if let Ok(meta) = e.metadata() {
                if let Ok(mtime) = meta.modified() {
                    let t = mtime
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs();
                    if now > t + 7 * 86400 {
                        let _ = fs::remove_file(&p);
                    }
                }
            }
        }
    }
    let mut files: Vec<_> = match fs::read_dir(&dir) {
        Ok(rd) => rd.flatten().collect(),
        Err(_) => return,
    };
    if files.len() > 10 {
        files.sort_by_key(|e| {
            e.metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH)
        });
        for old in files.iter().take(files.len() - 10) {
            let _ = fs::remove_file(old.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::utils::locks::OpInfo;

    fn holder(kind: &str, op_id: Option<&str>) -> Holder {
        Holder {
            id: "1-0".into(),
            scopes: vec![],
            kind: kind.into(),
            label: kind.into(),
            op_id: op_id.map(str::to_string),
            pid: 1,
            started_at: 0,
            guarded_units: vec![],
        }
    }

    #[test]
    fn still_running_matches_op_id() {
        let h = vec![holder("activation", Some("activation_a"))];
        assert!(op_still_running(
            "activation_a",
            OperationKind::Activation,
            &h
        ));
        assert!(!op_still_running(
            "activation_b",
            OperationKind::Activation,
            &h
        ));
    }

    #[test]
    fn still_running_untracked_kind_keeps_all() {
        let h = vec![holder("activation", None)];
        assert!(op_still_running(
            "activation_a",
            OperationKind::Activation,
            &h
        ));
    }

    #[test]
    fn still_running_empty_is_stale() {
        assert!(!op_still_running(
            "activation_a",
            OperationKind::Activation,
            &[]
        ));
    }

    #[test]
    fn genswitch_maps_to_generation_lock_kind() {
        let h = vec![holder("generation", Some("genswitch_1"))];
        assert!(op_still_running(
            "genswitch_1",
            OperationKind::Generation,
            &h
        ));
    }

    fn with_temp_ops_and_run<F: FnOnce()>(name: &str, f: F) {
        // Env overrides are process-global; serialize these two integration tests.
        static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _env = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let base = std::env::temp_dir().join(format!(
            "neo-reap-{}-{}-{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let run = base.join("run");
        let ops = base.join("ops");
        fs::create_dir_all(run.join("locks")).unwrap();
        fs::create_dir_all(&ops).unwrap();
        // SAFETY: test-only; held under ENV_LOCK so no concurrent set_var.
        unsafe {
            std::env::set_var("NEO_RUN_DIR", &run);
            std::env::set_var(crate::utils::ops::OPERATIONS_DIR_ENV, &ops);
        }
        f();
        unsafe {
            std::env::remove_var("NEO_RUN_DIR");
            std::env::remove_var(crate::utils::ops::OPERATIONS_DIR_ENV);
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn reap_marks_orphaned_in_progress() {
        with_temp_ops_and_run("orphan", || {
            let id = "activation_reaptest";
            write_op_state(
                id,
                "in_progress",
                "toplevel-build",
                None,
                None,
                Some("reaptest"),
                None,
            );
            let path = state_path(id);
            assert!(path.exists());

            // No live holders → orphaned.
            reap_stale_in_progress();
            let v: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(v["status"], "failed");
            assert!(v["error"].as_str().unwrap().contains("no longer running"));
        });
    }

    #[test]
    fn reap_keeps_op_with_live_holder() {
        with_temp_ops_and_run("live", || {
            let mgr = LockManager::system();
            let id = "activation_livetest";
            let lock = mgr
                .try_acquire(
                    &crate::utils::locks::LockSpec::system_change(),
                    &OpInfo::new("activation", "Activation").with_op_id(id),
                )
                .expect("lock");

            write_op_state(
                id,
                "in_progress",
                "toplevel-build",
                None,
                None,
                Some("livetest"),
                None,
            );
            reap_stale_in_progress();
            let v: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(state_path(id)).unwrap()).unwrap();
            assert_eq!(v["status"], "in_progress");

            drop(lock);
            reap_stale_in_progress();
            let v: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(state_path(id)).unwrap()).unwrap();
            assert_eq!(v["status"], "failed");
        });
    }
}
