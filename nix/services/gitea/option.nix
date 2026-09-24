# Gitea (self-hosted Git) service options.
# SQLite by default for a lean Heimcloud credentials forge. Tinyauth off so Gitea owns login
# (HTTPS git clone / API tokens); enable auth in settings if you want forward-auth in front.
{...}: {
  flake.modules.nixos.gitea-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.gitea = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Gitea self-hosted Git service" {rank = 0;};
              port = mkOption {
                type = types.port;
                default = 3000;
                internal = true;
                description = "Internal HTTP port Gitea listens on (HTTP_PORT)";
              };
              rootUrl = mkOption {
                type = types.nullOr types.str;
                default = null;
                rank = 10;
                description = ''
                  Public ROOT_URL for Gitea (e.g. https://git.heimcloud.site).
                  When null: first customDomains entry as https://…, else https://<subdomain>.<swag.domain>.
                '';
              };
              disableRegistration = mkOption {
                type = types.bool;
                default = true;
                rank = 20;
                description = "Disable open registration (invite/admin-created users only)";
              };
              ssh = mkOption {
                type = types.submodule {
                  options = {
                    enable = mkEnableOption "Gitea built-in SSH server (deploy-key clones)" {rank = 0;};
                    port = mkOption {
                      type = types.port;
                      default = 2222;
                      rank = 10;
                      description = "SSH_PORT advertised in clone URLs / UI (not the host sshd)";
                    };
                    listenPort = mkOption {
                      type = types.port;
                      default = 2222;
                      rank = 20;
                      description = "Host loopback publish port: 127.0.0.1:listenPort → container :22";
                    };
                    domain = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      rank = 30;
                      description = "SSH_DOMAIN; null = hostname derived from rootUrl / customDomains";
                    };
                  };
                };
                default = {};
                rank = 30;
                description = "Built-in Gitea SSH (deploy keys). Keep disabled until edge TCP forward exists.";
              };
            }
            // lib.neo.mkReverseProxyOptions {
              subdomain = "gitea";
              auth.enabled = false;
              auth.publicPaths = [
                "^/api/healthz$"
                "^/api/v1/version$"
              ];
            }
            // lib.neo.mkContainerDefinitions {
              gitea = "gitea/gitea:1.22.6";
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/gitea"
            // lib.neo.mkServiceMeta {
              category = "Files";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/gitea.svg";
              description = ''
                Gitea is a lightweight, self-hosted Git service with issues, PRs, and package registries.
                Neo runs the official Docker image with SQLite storage under appdata — suitable for private
                credential and config repos without a separate Postgres. Point ROOT_URL / customDomains at
                your public hostname (e.g. git.heimcloud.site) when published via streamproxy.
                Registration is disabled by default; create users via the admin account after first boot.
              '';
              projectUrl = "https://about.gitea.com/";
              githubUrl = "https://github.com/go-gitea/gitea";
              releaseUrl = "https://github.com/go-gitea/gitea/releases";
            }
            // lib.neo.mkSkillOptions {};
        };
        default = {};
        description = "Gitea service configuration";
      };
    };
}
