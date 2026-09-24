# Searxng service implementation (redis + main app). Web UI is behind optional tinyauth via swag proxy.
#
# After searxng image bumps, settings.yml in appdata can still list engine modules the
# image removed (FileNotFoundError on register). preStart prunes a known-removed set,
# seeds limiter.toml (botdetection / trusted docker proxies), and relies on SWAG to
# forward X-Real-IP / X-Forwarded-For.
{...}: {
  flake.modules.nixos.searxng = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.searxng;
      appdata = "${config.neo.core.volumes.appdata}/searxng";
      domain = config.neo.services.swag.domain;

      # Engines whose modules were dropped from docker.io/searxng/searxng (verified
      # absent on upstream master searx/engines/*.py). Extend as future bumps remove more.
      removedEngines = [
        "adobe_stock"
        "aol"
        "cara"
        "loc"
        "podcastindex"
        "presearch"
        "reddit"
        "svgrepo"
      ];

      # Docker / private ranges so botdetection accepts X-Forwarded-* from SWAG.
      limiterToml = pkgs.writeText "searxng-limiter.toml" ''
        [botdetection]
        ipv4_prefix = 32
        ipv6_prefix = 48
        trusted_proxies = [
          "127.0.0.0/8",
          "::1",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "fd00::/8",
        ]

        [botdetection.ip_limit]
        filter_link_local = false
        link_token = false

        [botdetection.ip_lists]
        pass_searxng_org = true
      '';

      prunePy = pkgs.writeText "neo-searxng-prune-engines.py" ''
        import re, sys
        path = sys.argv[1]
        removed = {${lib.concatMapStringsSep ", " (e: ''"${e}"'') removedEngines}}
        try:
            text = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            sys.exit(0)
        engines_m = re.search(r"(?m)^(engines:\s*\n)", text)
        if not engines_m:
            sys.exit(0)
        start = engines_m.end()
        next_m = re.search(r"(?m)^[a-zA-Z0-9_]+:\s*", text[start:])
        end = start + next_m.start() if next_m else len(text)
        head, body, tail = text[:start], text[start:end], text[end:]
        items = re.split(r"(?m)^(?=- name:\s)", body)
        kept = []
        for item in items:
            if not item.strip():
                continue
            eng = re.search(r"(?m)^\s+engine:\s*([^\s#]+)", item)
            nam = re.search(r"(?m)^- name:\s*[\"']?([^\"'\n#]+)", item)
            tokens = set()
            if eng:
                tokens.add(eng.group(1).strip().strip("\"'"))
            if nam:
                tokens.add(nam.group(1).strip().lower().replace(" ", "_"))
                tokens.add(nam.group(1).strip())
            if tokens & removed:
                continue
            kept.append(item)
        new_body = "".join(kept)
        if new_body != body:
            open(path, "w", encoding="utf-8").write(head + new_body + tail)
            print("neo-searxng: pruned removed engines from", path)
      '';
    in {
      config = mkIf cfg.enabled {
        systemd.services.docker-searxng-redis.preStart = lib.neo.mkEnsureDirs config [
          appdata
          "${appdata}/redis"
        ];
        systemd.services.docker-searxng.preStart =
          (lib.neo.mkEnsureDirs config [
            appdata
            "${appdata}/searxng"
            "${appdata}/cache"
          ])
          + ''
            # Seed limiter.toml (botdetection trusted_proxies for SWAG → searxng).
            install -m 0644 ${limiterToml} ${appdata}/searxng/limiter.toml
            # Drop engine entries whose modules the current image no longer ships.
            ${pkgs.python3}/bin/python3 ${prunePy} ${appdata}/searxng/settings.yml || true
          '';

        virtualisation.oci-containers.containers = {
          searxng-redis = {
            image = cfg.containers."searxng-redis";
            autoStart = true;
            cmd = [
              "valkey-server"
              "--save"
              "30"
              "1"
              "--loglevel"
              "warning"
            ];
            volumes = [
              "${appdata}/redis:/data"
            ];
          };

          searxng = {
            image = cfg.containers.searxng;
            autoStart = true;
            environment = {
              SEARXNG_BASE_URL = "https://${cfg.subdomain}.${domain}";
              TZ = config.neo.core.timeZone;
            };
            volumes = [
              "${appdata}/searxng:/etc/searxng:rw"
              "${appdata}/cache:/var/cache/searxng:rw"
            ];
          };
        };
      };
    };
}
