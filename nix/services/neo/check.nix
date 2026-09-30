# neo-bootstrap creates the server config repo as root, then neo init runs
# as homeserver. AppData is root:root 0755, so a homeserver preStart cannot
# mkdir the repo. neo-web requires the unit, and the unit is not part of
# system-updater, so it still exists when scheduled updates are disabled.
{...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    neoLib = lib.extend (final: prev: {
      neo =
        (prev.neo or {})
        // (import ../../lib/firewall.nix {lib = final;}).libExtensions.firewall.neo
        // (import ../../lib/sudo.nix {lib = final;}).libExtensions.sudo.neo
        // (import ../../lib/activation/file.nix {}).libExtensions.activate-file.neo
        // (import ../../lib/setup-service.nix {lib = final;}).libExtensions.setup-service.neo;
    });
    neoModule =
      (import ./default.nix {
        self = {
          packages.${pkgs.stdenv.hostPlatform.system}.neo = pkgs.coreutils;
        };
      }).flake.modules.nixos.neo;
    configPath = "/var/neo/DATA/AppData/configuration";
    eval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs = {lib = neoLib;};
      modules = [
        neoModule
        {
          options.neo.services.neo = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkEnableOption "neo";
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 8091;
                };
                iframeCookieSupport = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
              };
            };
            default = {};
          };
          options.neo.services.swag.domain = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          options.neo.neo-cli.server.configPath = lib.mkOption {
            type = lib.types.str;
            default = configPath;
          };
          config = {
            boot.isContainer = true;
            fileSystems."/" = {
              device = "x";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            documentation.enable = false;
            neo.services.neo.enabled = true;
            neo.services.swag.domain = null;
          };
        }
      ];
    };

    bootstrap = eval.config.systemd.services.neo-bootstrap;
    web = eval.config.systemd.services.neo-web;
    pre = bootstrap.serviceConfig.ExecStartPre or [];
    preList =
      if builtins.isList pre
      then pre
      else [pre];
    privileged = builtins.any (p: lib.hasPrefix "+" (toString p)) preList;
    activation = eval.config.system.activationScripts.neo-bootstrap-config;
    activationText = activation.text or activation;
    ownsRepo =
      lib.hasInfix "chown homeserver:homeserver" activationText
      && lib.hasInfix configPath activationText
      && lib.hasInfix "mkdir -p" activationText;
    webRequires = builtins.elem "neo-bootstrap.service" (web.requires or []);
    webAfter = builtins.elem "neo-bootstrap.service" (web.after or []);
    wanted = builtins.elem "multi-user.target" (bootstrap.wantedBy or []);
    runsAsHomeserver = (bootstrap.serviceConfig.User or "") == "homeserver";
    noRestartOnSwitch =
      (bootstrap.stopIfChanged or true) == false
      && (bootstrap.restartIfChanged or true) == false;
  in {
    checks.neo-bootstrap = pkgs.runCommand "neo-bootstrap" {} ''
      set -euo pipefail
      ${lib.optionalString (!privileged) ''
        echo "FAIL neo-bootstrap ExecStartPre must run as root ('+' prefix) so it can mkdir under root-owned AppData" >&2
        echo ${lib.escapeShellArg (builtins.toJSON preList)} >&2
        exit 1
      ''}
      ${lib.optionalString (!ownsRepo) ''
        echo "FAIL neo-bootstrap activation must mkdir and chown the server config repo to homeserver" >&2
        echo ${lib.escapeShellArg activationText} >&2
        exit 1
      ''}
      ${lib.optionalString (!webRequires || !webAfter) ''
        echo "FAIL neo-web must require and order after neo-bootstrap.service" >&2
        exit 1
      ''}
      ${lib.optionalString (!wanted) ''
        echo "FAIL neo-bootstrap must be wanted by multi-user.target" >&2
        exit 1
      ''}
      ${lib.optionalString (!runsAsHomeserver) ''
        echo "FAIL neo-bootstrap main process must run as homeserver" >&2
        exit 1
      ''}
      ${lib.optionalString (!noRestartOnSwitch) ''
        echo "FAIL neo-bootstrap must set stopIfChanged=restartIfChanged=false so activate does not restart it under the system lock" >&2
        exit 1
      ''}
      if grep -q 'systemd.services.neo-bootstrap' ${./../system-updater/default.nix}; then
        echo "FAIL neo-bootstrap must be defined on the neo web service, not system-updater" >&2
        exit 1
      fi
      touch "$out"
    '';
  };
}
