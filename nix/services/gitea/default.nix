# Gitea service implementation (official image, SQLite).
{...}: {
  flake.modules.nixos.gitea = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.gitea;
      appdata = "${config.neo.core.volumes.appdata}/gitea";
      domain = config.neo.services.swag.domain or null;
      rootUrl =
        if cfg.rootUrl != null && cfg.rootUrl != ""
        then cfg.rootUrl
        else if (cfg.customDomains or []) != []
        then "https://${builtins.head cfg.customDomains}"
        else if domain != null && domain != ""
        then "https://${cfg.subdomain}.${domain}"
        else "http://localhost:${toString cfg.port}";
      rootHost = let
        stripped = lib.removePrefix "https://" (lib.removePrefix "http://" rootUrl);
      in
        builtins.head (lib.splitString "/" stripped);
      sshDomain =
        if cfg.ssh.domain != null && cfg.ssh.domain != ""
        then cfg.ssh.domain
        else rootHost;
      sshEnv =
        if cfg.ssh.enable
        then {
          GITEA__server__START_SSH_SERVER = "true";
          GITEA__server__DISABLE_SSH = "false";
          GITEA__server__SSH_DOMAIN = sshDomain;
          GITEA__server__SSH_PORT = toString cfg.ssh.port;
          GITEA__server__SSH_LISTEN_PORT = "22";
        }
        else {
          GITEA__server__DISABLE_SSH = "true";
        };
      sshPorts =
        optional cfg.ssh.enable "127.0.0.1:${toString cfg.ssh.listenPort}:22";
    in {
      config = mkIf cfg.enabled {
        systemd.services.docker-gitea.preStart = lib.neo.mkEnsureDirs config [
          "${appdata}/data"
        ];

        virtualisation.oci-containers.containers.gitea = {
          image = cfg.containers.gitea;
          autoStart = true;
          environment =
            {
              USER_UID = "1000";
              USER_GID = "1000";
              GITEA__server__DOMAIN = rootHost;
              GITEA__server__ROOT_URL = "${rootUrl}/";
              GITEA__server__HTTP_PORT = toString cfg.port;
              GITEA__database__DB_TYPE = "sqlite3";
              GITEA__service__DISABLE_REGISTRATION = lib.boolToString cfg.disableRegistration;
              GITEA__security__INSTALL_LOCK = "true";
            }
            // sshEnv;
          volumes = [
            "${appdata}/data:/data"
          ];
          ports = sshPorts;
          networks = ["internal"];
        };
      };
    };
}
