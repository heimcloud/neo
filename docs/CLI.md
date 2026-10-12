# Neo CLI (optional)

**Most people never need this.** Day-to-day Neo is managed in the **web UI**: change settings, activate, done.

The `neo` command-line tool is for **install bootstrap**, automation, and **power users** who prefer a terminal. Product overview: [../README.md](../README.md). Install paths that mention the CLI: [INSTALL.md](INSTALL.md).

```bash
nix run github:madebydamo/neo#neo -- --help
# on a fully installed Neo host:
neo --help
```

## Global flags

| Flag / env | Purpose |
|------------|---------|
| `--settings FILE` | Path to settings. Default: `/etc/neo/settings.toml` if present, else `./settings.toml`. |
| `--profile local \| server` | Which path profile to use. Default: `server` if `/etc/neo/settings.toml` exists, else `local`. Env: `NEO_PROFILE`. |
| `--section …` | Alias for `--profile` (`local` or `server`). Env: `NEO_SECTION`. |
| `--dry-run` | Print actions without applying. |
| `--neo-input` / `NEO_NEO_INPUT` | Override this profile's Neo input URL. |
| `--template` / `NEO_TEMPLATE` | Override this profile's template. |
| `--remote-url` / `NEO_REMOTE_URL` | Override config repo URL. |
| `--nix-path` / `NIX_BINARY_PATH` | Nix binary. |
| `--sudo-path` / `SUDO_BINARY_PATH` | Sudo binary. |
| `--lock-wait SECONDS` / `NEO_LOCK_WAIT` | Wait for a conflicting operation instead of failing at once (default 0). |

## Operation locks

Commands that change the system take Neo's **system lock** exclusively: `activate`, `update`, `update-inputs`, `generation switch|boot`, `init`, `build`, `migrate`, `paste-settings`, `generate-hardware`, `nuke`. Only one of them runs at a time, and never while the web UI restores a service snapshot, clears app data, or repairs the Nix store. `docker-update <c>` locks only that container's unit. A conflict fails right away with the holder, e.g. `Error: Blocked: Activation in progress (started 12:03)`; pass `--lock-wait 600` to wait instead. The scheduled system updater waits up to an hour. Locks are `flock`s under `/run/neo/locks` and are released when the process exits, even after a crash.

On a full install (`/etc/neo/settings.toml` present), commands re-exec as the `homeserver` user when needed and default to the **server** profile (`neo-cli.server.configPath`, `neo-cli.server.neoInput`). Laptop / `nix run` defaults to the **local** profile (`neo-cli.local.configPath`, default `./build`). `neoInput` and `template` are per profile. The server profile defaults to `github:madebydamo/neo` (`#homeserver` for the template). A laptop checkout (`git+file:` or a directory template) belongs under `[neo-cli.local]`. Git identity and other shared keys stay under `[neo-cli]`.

SSH to a finished host as **`homeserver@…`** for `neo` (or **`admin@…`** if you set `core.hashedLinuxPassword`). Same keys on both; no default password. See [INSTALL.md — first login](INSTALL.md#first-login). `nix run github:madebydamo/neo#neo` is currently **`x86_64-linux` only** (Mac / other laptops: [INSTALL.md](INSTALL.md#when-the-laptop-cannot-build-mac-live-usb-or-wrong-architecture)).

## Commands (summary)

| Command | Role |
|---------|------|
| `neo init` | Create config from template (or clone); hardware + settings bootstrap |
| `neo web` | Start the web UI (also how laptop-side Path B config editing works) |
| `neo activate` | Build and apply **this** machine’s config (`--mode switch` default live switch; `--mode boot` / `NEO_ACTIVATION_MODE=boot` sets boot default only) |
| `neo build` | Build without switching |
| `neo update` | Refresh inputs; usually follow with activate |
| `neo update-inputs` | Lower-level input refresh |
| `neo generate-hardware` | Write `hardware-configuration.nix` (`--no-filesystems` if Disko on) |
| `neo paste-settings` | Merge settings into the config tree |
| `neo nuke` | Destroy config at configPath (destructive; prefer `--dry-run` first) |
| `neo edit` | Open settings in `$EDITOR` |
| `neo git` / `neo lg` | Git helpers for the config repo |
| `neo migrate` | Older layout migrations |
| `neo docker-update <name>` | Container image update helper |

**Do not** `activate` a remote machine’s config from your laptop—use [nixos-anywhere](INSTALL.md#path-b--install-from-your-laptop-nixos-anywhere) for first install, then activate **on** the server (or use Activate in the web UI there).

## Typical power-user flows

```bash
neo web                 # UI
neo update && neo activate
neo --dry-run activate
neo activate --mode boot   # build + boot default only; reboot later
```

Scheduled system-updater uses `services.system-updater.activationMode` (`switch` or `boot`). Interactive `neo activate` and web Activate stay on live switch unless you pass `--mode` / `NEO_ACTIVATION_MODE`.

Developers building Neo itself: [AGENTS.md](../AGENTS.md).
