use anyhow::{Context, Result};
use std::process::{Command, Stdio};

use crate::utils::{
    format_command, get_current_branch, git_cmd, has_staged_changes, record_generation_in_commit,
    resolve_suffix, run_nix, run_write_flake, OperationKind, OperationLog,
};

pub fn activate(
    config_path: &str,
    dry_run: bool,
    nix_cmd: &str,
    sudo_cmd: &str,
    activation_suffix: Option<&str>,
) -> Result<()> {
    if dry_run {
        println!(
            "DRY-RUN: activate (write-flake + toplevel build + git branch dance + pre-clean + nixos-rebuild; exit 0 or 4 treated as success (keep branch, 'Activated using...'); other non-zero keeps branch but errors)"
        );
        return Ok(());
    }

    let suffix = resolve_suffix(activation_suffix, "NEO_ACTIVATION_SUFFIX");
    let op = OperationLog::new(OperationKind::Activation, &suffix);
    op.write_state("in_progress", "starting", None, None);
    let _tee = op.capture_stdio();

    op.step("write-flake", || run_write_flake(config_path, nix_cmd))?;
    op.write_state("in_progress", "write-flake-done", None, None);

    op.step("toplevel-build", || {
        run_nix(
            config_path,
            nix_cmd,
            &[
                "build",
                ".#nixosConfigurations.neo.config.system.build.toplevel",
            ],
        )
    })?;
    op.write_state("in_progress", "toplevel-built", None, None);

    let activation_branch = format!("activation_{}", suffix);
    let build_branch = format!("build_{}", suffix);
    let orig_branch = get_current_branch(config_path).unwrap_or_else(|_| "master".to_string());

    op.step("git-add", || git_cmd(config_path, &["add", "."]))?;
    let has_changes = has_staged_changes(config_path);
    // The build branch only carries the commit over to the activation branch.
    let drop_build_branch = || {
        if has_changes {
            let _ = git_cmd(config_path, &["branch", "-D", &build_branch]);
        }
    };
    if has_changes {
        op.step("build-branch", || {
            git_cmd(config_path, &["switch", "-C", &build_branch])
        })?;
        op.step("build-commit", || {
            git_cmd(
                config_path,
                &["commit", "-m", &format!("Build: {}", suffix)],
            )
        })?;
    }

    if let Err(e) = git_cmd(config_path, &["switch", "-C", &activation_branch]) {
        drop_build_branch();
        let _ = git_cmd(config_path, &["switch", &orig_branch]);
        op.write_state("failed", "branch-failed", Some(&e.to_string()), None);
        return Err(e);
    }
    op.write_state(
        "in_progress",
        "branches-created",
        None,
        Some(&activation_branch),
    );

    if has_changes {
        op.step("amend-add", || git_cmd(config_path, &["add", "."]))?;
        op.step("amend-commit", || {
            git_cmd(
                config_path,
                &[
                    "commit",
                    "--amend",
                    "-m",
                    &format!("Activation: {}", activation_branch),
                ],
            )
        })?;
    }

    op.write_state("in_progress", "pre-rebuild", None, Some(&activation_branch));
    // Best-effort clear of a leftover nixos-rebuild transient unit (see
    // `rebuild_unit_preclean_actions`); nothing runs when it is not loaded.
    preclean_rebuild_unit(sudo_cmd, config_path);
    let mut rebuild = Command::new(sudo_cmd);
    rebuild
        .current_dir(config_path)
        .args(["nixos-rebuild", "switch", "--flake", ".#neo"]);
    let display = format_command(&rebuild);
    println!("→ {display}");
    let status = rebuild
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("failed to spawn: {display}"))?;
    let code = status.code().unwrap_or(-1);

    // Exit 4: the switch succeeded with warnings (common for user session reloads).
    let warnings = code == 4;
    drop_build_branch();
    if !status.success() && !warnings {
        println!(
            "nixos-rebuild failed (non-zero exit {}). Keeping {} branch+checkout (check 'systemctl --failed' and logs).",
            code, activation_branch
        );
        op.write_state(
            "failed",
            "rebuild-failed",
            Some(&format!("exit code {}", code)),
            None,
        );
        anyhow::bail!("Command failed: {display} (exit {code})");
    }
    if warnings {
        println!(
            "warning: nixos-rebuild exited 4 (success with warnings). The switch succeeded and the new generation is active. This is common for user session reloads (dbus-broker), non-critical service restarts, etc. Treating as success for activation tracking."
        );
    }
    let phase = if warnings {
        "completed-with-warnings"
    } else {
        "completed"
    };
    op.write_state("success", phase, None, Some(&activation_branch));
    record_gen_after_activate(config_path, &activation_branch, has_changes);
    println!(
        "Activated using branch {}{}",
        activation_branch,
        if warnings {
            " (exit code 4 / warnings)"
        } else {
            ""
        }
    );
    Ok(())
}

const REBUILD_UNIT: &str = "nixos-rebuild-switch-to-configuration.service";

/// Clear a leftover `nixos-rebuild` transient unit before the switch. The unit
/// is only loaded while a switch is in flight or after one failed; asking
/// systemctl to reset/stop it otherwise prints "Unit … not loaded" /
/// "Failed to stop …" on every activate. So read LoadState/ActiveState first
/// and only act on a loaded unit; stdio stays silenced, status is ignored.
fn preclean_rebuild_unit(sudo_cmd: &str, config_path: &str) {
    let show = Command::new(sudo_cmd)
        .current_dir(config_path)
        .args([
            "systemctl",
            "show",
            "-p",
            "LoadState",
            "-p",
            "ActiveState",
            REBUILD_UNIT,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    for action in rebuild_unit_preclean_actions(&show) {
        let _ = Command::new(sudo_cmd)
            .current_dir(config_path)
            .args(["systemctl", action, REBUILD_UNIT])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

/// systemctl actions for the rebuild unit, from `systemctl show -p LoadState
/// -p ActiveState` output: none unless it is loaded; `reset-failed` for a
/// failed leftover; `reset-failed` + `stop` for one still running.
fn rebuild_unit_preclean_actions(show: &str) -> &'static [&'static str] {
    let prop = |key: &str| {
        show.lines()
            .find_map(|l| l.trim().strip_prefix(key)?.strip_prefix('='))
            .map(str::trim)
            .unwrap_or("")
    };
    if prop("LoadState") != "loaded" {
        return &[];
    }
    match prop("ActiveState") {
        "failed" => &["reset-failed"],
        "inactive" => &[],
        _ => &["reset-failed", "stop"],
    }
}

/// Embed generation number in the activation commit message (no sidecar files).
/// `has_activation_commit` is true when this run created/amended a real Activation commit
/// (dirty tree); otherwise we add an empty commit so re-activates still get history + gen.
fn record_gen_after_activate(
    config_path: &str,
    activation_branch: &str,
    has_activation_commit: bool,
) {
    match record_generation_in_commit(config_path, activation_branch, has_activation_commit) {
        Ok(gen) => {
            println!(
                "Recorded generation {} on {} commit for {}",
                gen,
                if has_activation_commit {
                    "amended"
                } else {
                    "empty"
                },
                activation_branch
            );
        }
        Err(e) => {
            eprintln!("warning: could not record generation in commit: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::rebuild_unit_preclean_actions as actions;

    #[test]
    fn preclean_skips_a_unit_that_is_not_loaded() {
        assert!(actions("LoadState=not-found\nActiveState=inactive\n").is_empty());
        assert!(actions("LoadState=not-found\n").is_empty());
        // systemctl failed / printed nothing.
        assert!(actions("").is_empty());
    }

    #[test]
    fn preclean_acts_only_as_far_as_needed_on_a_loaded_unit() {
        assert_eq!(
            actions("LoadState=loaded\nActiveState=failed\n"),
            ["reset-failed"]
        );
        assert!(actions("LoadState=loaded\nActiveState=inactive\n").is_empty());
        assert_eq!(
            actions("ActiveState=active\nLoadState=loaded\n"),
            ["reset-failed", "stop"]
        );
        assert_eq!(
            actions("LoadState=loaded\nActiveState=activating\n"),
            ["reset-failed", "stop"]
        );
    }
}
