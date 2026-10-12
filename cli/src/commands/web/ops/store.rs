//! Shared on-disk operation store (JSON state + log files under the ops dir).
//! Used by activation, update, genswitch, and nix-store repair jobs.

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::utils::locks::{Holder, LockManager};
pub use crate::utils::ops::{append_log, log_path, state_path};
use crate::utils::ops::{operations_dir, process_alive, write_op_state, OperationKind};

/// How long a web-triggered op may stay in phase `triggered` before the worker
/// rewrites state / takes the lock. After this, the trigger is treated as abandoned
/// (systemd-run never started, or the oneshot failed before writing).
const TRIGGER_GRACE_SECS: u64 = 120;

/// Write op state (no branch / start time / extra fields).
pub fn write_state(id: &str, status: &str, phase: &str, err: Option<&str>) {
    write_op_state(id, status, phase, err, None, None, None);
}

/// Lock `kind` string used in holder files for this op kind.
fn holder_kind(kind: OperationKind) -> &'static str {
    match kind {
        OperationKind::Activation => "activation",
        OperationKind::Update => "update",
        OperationKind::Generation => "generation",
        OperationKind::Repair => "repair",
    }
}

/// Whether an `in_progress` op JSON still has a live worker (or a fresh web trigger).
fn op_still_running(id: &str, v: &serde_json::Value, holders: &[Holder], now: u64) -> bool {
    let phase = v.get("phase").and_then(|x| x.as_str()).unwrap_or("");

    // Lock holder that names this op id (web oneshots, repair, …).
    if holders.iter().any(|h| h.op_id.as_deref() == Some(id)) {
        return true;
    }

    // Web UI writes `triggered` under neo-web's pid before systemd-run starts the
    // real worker. That pid stays alive forever — only a grace window (or a lock
    // holder above) may keep the op "running".
    if phase == "triggered" {
        let started = started_at_epoch(v).unwrap_or(now);
        return now.saturating_sub(started) <= TRIGGER_GRACE_SECS;
    }

    // Recorded worker pid: must still be alive AND still hold a lock.
    // Pid alone is not enough — repair / other in-process jobs write neo-web's
    // pid, which stays alive after the task and lock are gone.
    if let Some(pid) = v.get("pid").and_then(|x| x.as_u64()).map(|p| p as u32) {
        if !process_alive(pid) {
            return false;
        }
        return holders.iter().any(|h| h.pid == pid);
    }

    // Legacy state without pid: plain CLI activate/update take the system lock
    // without an op_id. Do not treat a different op's lock (with its own op_id)
    // as proof this leftover is still running.
    if let Some(kind) = OperationKind::from_id(id) {
        let want = holder_kind(kind);
        if holders.iter().any(|h| h.kind == want && h.op_id.is_none()) {
            return true;
        }
    }
    false
}

/// Best-effort start time: JSON `started_at` (suffix timestamp) is not always
/// epoch seconds — prefer numeric fields, else None (caller uses mtime/now).
fn started_at_epoch(v: &serde_json::Value) -> Option<u64> {
    if let Some(n) = v.get("started_at_epoch").and_then(|x| x.as_u64()) {
        return Some(n);
    }
    // Optional unix seconds written by newer writers.
    if let Some(n) = v.get("started_unix").and_then(|x| x.as_u64()) {
        return Some(n);
    }
    None
}

/// Mark a leftover `in_progress` op as failed so the action bar and monitors clear.
fn mark_op_aborted(id: &str, v: &serde_json::Value) {
    let phase = v.get("phase").and_then(|x| x.as_str()).unwrap_or("unknown");
    let mut extra = serde_json::Map::new();
    for key in ["generation", "mode", "branch", "started_at"] {
        if let Some(val) = v.get(key).cloned() {
            if !val.is_null() {
                extra.insert(key.to_string(), val);
            }
        }
    }
    // Keep the last known worker pid for debugging (do not overwrite with neo-web's).
    if let Some(pid) = v.get("pid").cloned() {
        extra.insert("pid".to_string(), pid);
    }
    write_op_state(
        id,
        "failed",
        phase,
        Some("aborted (process no longer running)"),
        v.get("branch").and_then(|x| x.as_str()),
        v.get("started_at").and_then(|x| x.as_str()),
        Some(serde_json::Value::Object(extra)),
    );
    append_log(
        &log_path(id),
        &format!("{id}: marked aborted (process no longer running)"),
    );
}

/// Finish `in_progress` ops whose worker is gone (Ctrl-C / kill / crashed oneshot).
/// Safe to call from the action-bar watcher and monitors; no-op when nothing is stale.
pub fn reconcile_stale_ops() {
    let dir = operations_dir();
    if !dir.exists() {
        return;
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // One holders() pass: also drops dead holder files.
    let holders = LockManager::system().holders();
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
        if OperationKind::from_id(id).is_none() {
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
        // Age of "triggered" uses file mtime when no epoch field is present.
        let mtime = e
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(now);
        let mut v_for_check = v.clone();
        if v_for_check.get("started_unix").is_none()
            && v_for_check.get("started_at_epoch").is_none()
            && v_for_check.get("phase").and_then(|x| x.as_str()) == Some("triggered")
        {
            v_for_check["started_unix"] = serde_json::json!(mtime);
        }
        if !op_still_running(id, &v_for_check, &holders, now) {
            mark_op_aborted(id, &v);
        }
    }
}

/// Most recent in-progress op of `kind` (within the last hour).
pub fn find_recent_in_progress(kind: OperationKind) -> Option<String> {
    reconcile_stale_ops();
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
    reconcile_stale_ops();
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
    use crate::utils::locks::{HeldScope, LockMode};
    use serde_json::json;

    fn holder(kind: &str, op_id: Option<&str>, pid: u32) -> Holder {
        Holder {
            id: format!("{pid}-0"),
            scopes: vec![HeldScope {
                scope: "system".into(),
                mode: LockMode::Exclusive,
            }],
            kind: kind.into(),
            label: kind.into(),
            op_id: op_id.map(|s| s.into()),
            pid,
            started_at: 0,
            guarded_units: vec![],
        }
    }

    #[test]
    fn live_when_lock_names_op() {
        let id = "activation_1";
        let v = json!({"status": "in_progress", "phase": "starting", "pid": 1});
        let holders = vec![holder("activation", Some(id), 42)];
        assert!(op_still_running(id, &v, &holders, 1_000));
    }

    #[test]
    fn dead_when_pid_gone_and_no_lock() {
        let id = "activation_1";
        // PID unlikely to exist.
        let v = json!({"status": "in_progress", "phase": "toplevel-build", "pid": 4294967294u64});
        assert!(!op_still_running(id, &v, &[], 1_000));
    }

    #[test]
    fn triggered_grace_then_stale() {
        let id = "activation_1";
        let v = json!({
            "status": "in_progress",
            "phase": "triggered",
            "pid": std::process::id(),
            "started_unix": 1000u64,
        });
        assert!(op_still_running(id, &v, &[], 1000 + 30));
        assert!(!op_still_running(
            id,
            &v,
            &[],
            1000 + TRIGGER_GRACE_SECS + 1
        ));
    }

    #[test]
    fn legacy_without_pid_needs_cli_style_holder() {
        let id = "update_1";
        let v = json!({"status": "in_progress", "phase": "flake update"});
        assert!(!op_still_running(id, &v, &[], 1_000));
        // Another update with its own op_id must not keep this leftover "running".
        let other = vec![holder("update", Some("update_other"), 9)];
        assert!(!op_still_running(id, &v, &other, 1_000));
        let holders = vec![holder("update", None, 9)];
        assert!(op_still_running(id, &v, &holders, 1_000));
    }

    #[test]
    fn live_pid_requires_matching_lock_holder() {
        let id = "activation_1";
        let pid = std::process::id();
        let v = json!({
            "status": "in_progress",
            "phase": "toplevel-build",
            "pid": pid,
        });
        // Alive pid but no lock (Ctrl-C after flock dropped, or in-process task ended).
        assert!(!op_still_running(id, &v, &[], 1_000));
        let holders = vec![holder("activation", None, pid)];
        assert!(op_still_running(id, &v, &holders, 1_000));
    }

    #[test]
    fn web_pid_alone_does_not_keep_repair_alive() {
        // Repair runs inside neo-web: pid stays alive after the task drops the lock.
        let id = "repair_1";
        let v = json!({
            "status": "in_progress",
            "phase": "nix-store-verify-repair",
            "pid": std::process::id(),
        });
        assert!(!op_still_running(id, &v, &[], 1_000));
        let holders = vec![holder("repair", Some(id), std::process::id())];
        assert!(op_still_running(id, &v, &holders, 1_000));
    }
}
