# Searxng reverse proxy for SWAG.
# Explicitly set X-Real-IP / X-Forwarded-For / X-Forwarded-Proto so searxng
# botdetection sees client IPs (in addition to SWAG's shared proxy.conf).
{...}: {
  flake.modules.nixos.searxng-swag = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.searxng;
    base = lib.neo.mkSubdomainProxyConf {
      inherit config cfg;
      upstream = "searxng";
      port = 8080;
      maxBodySize = null;
    };
    # Inject after the shared proxy.conf include (idempotent if proxy.conf already sets them).
    withFwd =
      builtins.replaceStrings
      [
        "    include /config/nginx/proxy.conf;\n"
      ]
      [
        ''
            include /config/nginx/proxy.conf;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        ''
      ]
      base;
  in {
    config.neo.services.searxng.proxyConf = lib.mkDefault withFwd;
  };
}
