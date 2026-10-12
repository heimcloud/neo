# System auto-updater: scheduled neo update/activate.
# The config repo is bootstrapped by neo-bootstrap (neo web service).
{self, ...}: {
  flake.modules.nixos.system-updater = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.neo.services.system-updater;
    updaterPaths = lib.neo.mkUpdaterPaths config.neo.core.volumes.appdata;
    systemHistoryDir = cfg.appdata;
    neo = self.packages.${pkgs.stdenv.hostPlatform.system}.neo;
    activationMode = cfg.activationMode;
    rebootAfterBoot = cfg.rebootAfterBoot;
    path = [
      neo
      pkgs.git
      pkgs.nix
      pkgs.nixos-rebuild
      pkgs.nixos-install-tools
      pkgs.coreutils
      pkgs.bash
      pkgs.jq
      pkgs.systemd
    ];
    environment = {
      NIX_BINARY_PATH = "${pkgs.nix}/bin/nix";
      SUDO_BINARY_PATH = "/run/wrappers/bin/sudo";
      # Scheduled run: wait (up to 1h) for a running activation / restore / … to
      # finish instead of failing on the operation lock like an interactive call.
      NEO_LOCK_WAIT = "3600";
      NEO_ACTIVATION_MODE = activationMode;
    };
  in {
    config = lib.mkIf cfg.enabled {
      # Keep build outputs of live derivations so build-time deps (e.g. crane/cargo
      # crate builds) are not recompiled after each scheduled GC.
      nix.settings.keep-outputs = lib.mkIf (cfg.garbageCollectOlderThen != null) true;

      system.activationScripts.neo-system-updater-history = lib.neo.mkEnsureDirs config [
        {
          dirPath = updaterPaths.stateDir;
          mode = "0775";
          user = "homeserver";
          group = "homeserver";
        }
        {
          dirPath = systemHistoryDir;
          mode = "0775";
          user = "homeserver";
          group = "homeserver";
        }
      ];

      systemd.services.neo-auto-update = {
        description = "Auto update and activate nixos config with neo";
        # neo-bootstrap is part of the neo web service. Wait for it when that
        # service is on so a scheduled update does not start without a config repo.
        wants = lib.optional config.neo.services.neo.enabled "neo-bootstrap.service";
        after = lib.optional config.neo.services.neo.enabled "neo-bootstrap.service";
        inherit path;
        inherit environment;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
          User = "homeserver";
          Group = "homeserver";
        };
        stopIfChanged = false;
        restartIfChanged = false;
        script =
          ''
            run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
            started_at=$(date -Iseconds)
            mkdir -p ${systemHistoryDir}
            hist=${systemHistoryDir}/$run_id.json
            log_file=${systemHistoryDir}/$run_id.log
            exec > >(tee -a "$log_file") 2>&1
            before=$(readlink /nix/var/nix/profiles/system || echo none)
            after=none
            running=none
            rc=""
            changed=false
            failed=false
            reboot_pending=false
            reboot_scheduled=false
            reboot_scheduled_at=""
            activation_mode=${lib.escapeShellArg activationMode}
            reboot_after_boot=${
              if rebootAfterBoot
              then "true"
              else "false"
            }
            hist_done=0

            write_hist() {
              local in_progress=$1
              local finished=$2
              ${pkgs.jq}/bin/jq -n \
                --arg run_id "$run_id" \
                --arg started "$started_at" \
                --arg before "$before" \
                --arg after "$after" \
                --arg running "$running" \
                --arg activation_mode "$activation_mode" \
                --argjson in_progress "$in_progress" \
                --argjson changed "$changed" \
                --argjson failed "$failed" \
                --argjson reboot_pending "$reboot_pending" \
                --argjson reboot_scheduled "$reboot_scheduled" \
                --arg reboot_scheduled_at "$reboot_scheduled_at" \
                --arg rc "$rc" \
                --arg finished "$finished" \
                --arg log "$run_id.log" \
                '{kind:"system",run_id:$run_id,started_at:$started,in_progress:$in_progress,generation_before:$before,generation_after:$after,running_system:$running,activation_mode:$activation_mode,changed:$changed,failed:$failed,reboot_pending:$reboot_pending,reboot_scheduled:$reboot_scheduled,reboot_scheduled_at:(if $reboot_scheduled_at == "" then null else $reboot_scheduled_at end),exit_code:(if $rc == "" then null else ($rc|tonumber) end),finished_at:(if $finished == "" then null else $finished end),log:$log}' \
                > "$hist"
            }

            finalize() {
              [ "$hist_done" -eq 1 ] && return
              hist_done=1
              trap - EXIT INT TERM HUP
              after=$(readlink /nix/var/nix/profiles/system || echo none)
              running=$(readlink /run/current-system || echo none)
              if [ "$before" != "$after" ]; then changed=true; fi
              # Boot mode (or any path where profile advanced but running did not) needs a reboot.
              if [ "$after" != "none" ] && [ "$after" != "$running" ]; then
                reboot_pending=true
              else
                reboot_pending=false
              fi
              if [ "''${1:-}" = abort ]; then
                failed=true
                if [ -z "$rc" ]; then rc=1; fi
              elif [ -n "$rc" ] && [ "$rc" -ne 0 ]; then
                failed=true
              fi
              write_hist false "$(date -Iseconds)"
              echo "Wrote $hist (changed=$changed failed=$failed reboot_pending=$reboot_pending reboot_scheduled=$reboot_scheduled mode=$activation_mode exit=$rc); last.json -> $run_id.json"
            }

            # After a successful boot-mode activate that advanced the profile, schedule a
            # delayed host cycle so the new generation becomes current. Delay lets this
            # oneshot finish history and OnSuccess supervise hooks start first.
            maybe_schedule_reboot() {
              if [ "$failed" = true ]; then return 0; fi
              if [ "$activation_mode" != boot ]; then return 0; fi
              if [ "$reboot_after_boot" != true ]; then return 0; fi
              if [ "$changed" != true ] || [ "$reboot_pending" != true ]; then return 0; fi
              # Replace any prior delayed unit from an earlier run.
              /run/wrappers/bin/sudo systemctl stop neo-auto-update-reboot.timer neo-auto-update-reboot.service 2>/dev/null || true
              /run/wrappers/bin/sudo systemctl reset-failed neo-auto-update-reboot.timer neo-auto-update-reboot.service 2>/dev/null || true
              if /run/wrappers/bin/sudo systemd-run \
                --on-active=60s \
                --unit=neo-auto-update-reboot \
                --description="neo-auto-update: apply boot generation" \
                /run/current-system/sw/bin/systemctl reboot; then
                reboot_scheduled=true
                reboot_scheduled_at=$(date -Iseconds)
                echo "Scheduled delayed host cycle in 60s (activationMode=boot, generation changed, rebootAfterBoot=true)"
              else
                echo "warning: failed to schedule delayed host cycle after boot activate" >&2
              fi
            }

            write_hist true ""
            ln -sfn "$run_id.json" ${systemHistoryDir}/last.json
            echo "Started run $run_id; last.json -> $run_id.json (in_progress) activation_mode=$activation_mode reboot_after_boot=$reboot_after_boot"
            trap 'finalize abort' EXIT INT TERM HUP
          ''
          + lib.optionalString (cfg.garbageCollectOlderThen != null) ''
            /run/wrappers/bin/sudo nix-collect-garbage --delete-older-than ${cfg.garbageCollectOlderThen} || true
          ''
          + ''
            set +e
            ${neo}/bin/neo --profile server update && ${neo}/bin/neo --profile server activate --mode "$activation_mode"
            rc=$?
            set -e
            finalize ok
            maybe_schedule_reboot
            if [ "$reboot_scheduled" = true ]; then
              # Refresh history with reboot_scheduled after the first finalize write.
              finished_at=$(${pkgs.jq}/bin/jq -r '.finished_at // empty' "$hist" 2>/dev/null || true)
              write_hist false "''${finished_at:-$(date -Iseconds)}"
              echo "Updated $hist reboot_scheduled=$reboot_scheduled at $reboot_scheduled_at"
            fi
            exit "$rc"
          '';
      };

      systemd.timers.neo-auto-update = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "5m";
          AccuracySec = "1m";
          Unit = "neo-auto-update.service";
        };
      };

      # homeserver runs neo update/activate and optional GC as this user.
      # (web UI store repair / journalctl / systemd-run / rm live on neo.services.neo)
      security.sudo.extraRules = lib.neo.mkSudoExtraRules {
        users = ["homeserver"];
        commands = [
          # neo activate → sudo nixos-rebuild switch|boot
          {
            package = pkgs.nixos-rebuild;
            name = "nixos-rebuild";
          }
          # neo activate → systemctl reset-failed/stop of rebuild unit;
          # rebootAfterBoot → systemctl stop/reset-failed of delayed reboot unit + systemctl reboot
          {
            package = pkgs.systemd;
            name = "systemctl";
          }
          # rebootAfterBoot → systemd-run --on-active=… transient timer for delayed reboot
          {
            package = pkgs.systemd;
            name = "systemd-run";
          }
          # scheduled GC before update (`sudo nix-collect-garbage --delete-older-than …`)
          {
            package = pkgs.nix;
            name = "nix-collect-garbage";
          }
        ];
      };
    };
  };
}
