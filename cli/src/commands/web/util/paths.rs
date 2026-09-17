use std::path::{Path, PathBuf};

/// Parent directory of settings.toml (config repo root).
pub fn config_dir(settings_path: &Path) -> PathBuf {
    settings_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn sudo_cmd() -> String {
    std::env::var("SUDO_BINARY_PATH").unwrap_or_else(|_| "sudo".to_string())
}

pub fn nix_bin() -> String {
    std::env::var("NIX_BINARY_PATH")
        .unwrap_or_else(|_| "/run/current-system/sw/bin/nix".to_string())
}

pub fn neo_bin() -> String {
    std::env::var("NEO_BINARY_PATH")
        .unwrap_or_else(|_| "/run/current-system/sw/bin/neo".to_string())
}

/// Docker CLI for inspect/pull. neo-web's systemd PATH does not include docker,
/// so a bare `"docker"` lookup fails with ENOENT (`os error 2`).
pub fn docker_bin() -> String {
    let env = std::env::var("DOCKER_BINARY_PATH").ok();
    resolve_env_bin(env.as_deref(), "/run/current-system/sw/bin/docker")
}

fn resolve_env_bin(value: Option<&str>, fallback: &str) -> String {
    match value {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => fallback.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{docker_bin, resolve_env_bin};

    #[test]
    fn docker_bin_default_is_nixos_system_path_not_bare_name() {
        assert!(
            std::env::var("DOCKER_BINARY_PATH")
                .ok()
                .filter(|p| !p.is_empty())
                .is_none(),
            "DOCKER_BINARY_PATH is set; unset it to assert the default"
        );
        assert_eq!(docker_bin(), "/run/current-system/sw/bin/docker");
    }

    #[test]
    fn docker_bin_uses_env_when_set() {
        assert_eq!(
            resolve_env_bin(
                Some("/nix/store/abc/bin/docker"),
                "/run/current-system/sw/bin/docker"
            ),
            "/nix/store/abc/bin/docker"
        );
    }

    #[test]
    fn docker_bin_treats_empty_env_as_unset() {
        assert_eq!(
            resolve_env_bin(Some(""), "/run/current-system/sw/bin/docker"),
            "/run/current-system/sw/bin/docker"
        );
    }
}
