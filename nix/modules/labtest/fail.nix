# Synthetic fixture for validating the Heimcloud Ops automated lab stage.
# Deliberately failing but harmless: a standalone oneshot unit that exits 1
# (no dependencies, nothing depends on it). The lab test must report it in
# `systemctl --failed` and roll back. Never merge upstream.
{...}: {
  flake.modules.nixos.labtest-fail = {pkgs, ...}: {
    systemd.services.neo-labtest-fail = {
      description = "Synthetic lab-test fixture that fails on purpose";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/false";
      };
    };
  };
}
