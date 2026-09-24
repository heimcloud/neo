# Searxng reverse proxy for SWAG.
# Header forwarding (X-Real-IP / X-Forwarded-For / X-Forwarded-Proto) comes from
# SWAG's shared proxy.conf — do not re-set them here (duplicates become comma
# lists and break searxng botdetection IP parsing).
{...}: {
  flake.modules.nixos.searxng-swag = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.searxng;
  in {
    config.neo.services.searxng.proxyConf = lib.mkDefault (lib.neo.mkSubdomainProxyConf {
      inherit config cfg;
      upstream = "searxng";
      port = 8080;
      maxBodySize = null;
    });
  };
}
