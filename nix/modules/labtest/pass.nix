# Synthetic fixture for validating the Heimcloud Ops automated lab stage.
# Harmless: adds one static file under /etc. Never merge upstream.
{...}: {
  flake.modules.nixos.labtest-pass = {...}: {
    environment.etc."neo-labtest/marker".text = "heimcloud ops lab-test validation: pass branch\n";
  };
}
