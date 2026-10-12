# System auto-updater: scheduled neo update/activate.
# Config repo bootstrap is neo-bootstrap, owned by the neo web service.
{...}: {
  flake.modules.nixos.system-updater-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.system-updater = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "System auto-updater (scheduled neo update/activate)" {
                rank = 0;
                default = true;
              };
              schedule = mkOption {
                type = types.str;
                default = "*-*-* 04:00:00";
                description = "systemd OnCalendar schedule for auto-update (e.g. daily, *-*-* 04:00:00)";
                rank = 10;
              };
              activationMode = mkOption {
                type = types.enum ["switch" "boot"];
                default = "switch";
                description = ''
                  How scheduled activate applies the new generation.
                  switch (default): live nixos-rebuild switch — running system becomes the new generation immediately.
                  boot: nixos-rebuild boot only — sets the boot default; the running system stays on the old generation until reboot (avoids unattended live restarts of dhcpcd/journald and similar freezes on edge boxes). Interactive neo activate and the web Activate button stay on switch unless you pass --mode boot / NEO_ACTIVATION_MODE=boot.
                '';
                rank = 15;
                ui = lib.neo.ui.mkUi {
                  label = "Activation mode";
                  summary = true;
                  choiceLabels = {
                    switch = "Live switch";
                    boot = "Boot only (reboot later)";
                  };
                };
              };
              garbageCollectOlderThen = mkOption {
                type = types.nullOr types.str;
                default = "30d";
                description = "Value passed to nix-collect-garbage --delete-older-than at the end of each auto-update (e.g. 30d, 60d); set to null to skip GC. When set, also enables nix keep-outputs so build-time deps (e.g. Rust crate builds) survive GC while their generation is still live";
                rank = 20;
              };
            }
            // lib.neo.mkSystemdUnits ["neo-auto-update"]
            // lib.neo.mkSystemdTimers ["neo-auto-update"]
            // lib.neo.mkAppdata (lib.neo.mkUpdaterPaths config.neo.core.volumes.appdata).systemHistoryDir
            // lib.neo.mkServiceMeta {
              category = "Core";
              icon = "https://api.iconify.design/mdi/update.svg";
              description = ''
                Periodically runs neo update + activate so system packages and Neo modules stay current.
                When enabled, a systemd timer runs scheduled upgrades (with optional nix garbage collection).
                activationMode=boot builds and sets the next boot default without a live switch (safer on boxes where unattended switch freezes networking).
                The configuration repository is created by neo-bootstrap on the neo web service, which stays enabled when this timer is off.
                CLI path and neo input settings live under neo-cli. Updates use the server profile (configPath and neoInput). This option only controls whether automatic system updates run.
              '';
            }
            // lib.neo.mkSkillOptions {};
        };
        default = {};
        description = "System auto-updater configuration";
      };
    };
}
