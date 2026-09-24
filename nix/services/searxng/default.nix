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

      # Display `name:` values (case-insensitive exact) for engines whose modules were
      # dropped from docker.io/searxng/searxng. Include every settings.yml name that
      # shared a removed module (e.g. adobe stock video). torch uses engine: xpath —
      # match on name only. Extend as future bumps remove more.
      removedEngineNames = [
        "adobe stock"
        "adobe stock video"
        "adobe stock audio"
        "aol"
        "aol images"
        "aol videos"
        "cara"
        "library of congress"
        "podcastindex"
        "presearch"
        "presearch images"
        "presearch videos"
        "presearch news"
        "reddit"
        "svgrepo"
        "torch"
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

      prunePython = pkgs.python3.withPackages (p: [p.pyyaml]);

      prunePy = pkgs.writeText "neo-searxng-prune-engines.py" ''
        import sys
        import yaml

        path = sys.argv[1]
        removed = {${lib.concatMapStringsSep ", " (e: ''"${e}"'') removedEngineNames}}
        removed_cf = {n.casefold() for n in removed}

        try:
            with open(path, encoding="utf-8") as f:
                data = yaml.safe_load(f)
        except FileNotFoundError:
            print("neo-searxng: removed 0 engine(s) from", path, "(missing)")
            sys.exit(0)
        except Exception as exc:
            print("neo-searxng: removed 0 engine(s) from", path, "(parse error:", exc, ")")
            sys.exit(0)

        if not isinstance(data, dict):
            print("neo-searxng: removed 0 engine(s) from", path, "(not a mapping)")
            sys.exit(0)

        engines = data.get("engines")
        if not isinstance(engines, list):
            print("neo-searxng: removed 0 engine(s) from", path, "(no engines list)")
            sys.exit(0)

        kept = []
        removed_count = 0
        for entry in engines:
            if isinstance(entry, dict):
                name = entry.get("name")
                if isinstance(name, str) and name.casefold() in removed_cf:
                    removed_count += 1
                    continue
            kept.append(entry)

        if removed_count:
            data["engines"] = kept
            with open(path, "w", encoding="utf-8") as f:
                yaml.safe_dump(
                    data,
                    f,
                    default_flow_style=False,
                    allow_unicode=True,
                    sort_keys=False,
                )

        print("neo-searxng: removed", removed_count, "engine(s) from", path)
        sys.exit(0)
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
            ${prunePython}/bin/python3 ${prunePy} ${appdata}/searxng/settings.yml
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
