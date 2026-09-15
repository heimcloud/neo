# Gitea reverse proxy for SWAG (large uploads for git push / LFS).
{...}: {
  flake.modules.nixos.gitea-swag = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.gitea;
  in {
    config.neo.services.gitea.proxyConf = lib.mkDefault (lib.neo.mkSubdomainProxyConf {
      inherit config cfg;
      upstream = "gitea";
      port = cfg.port;
      maxBodySize = "0";
      auth = false;
    });
  };
}
