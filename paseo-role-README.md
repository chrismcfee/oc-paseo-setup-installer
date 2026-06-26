# ansible-role: paseo

Deploys a headless [Paseo](https://getpaseo.com) daemon as one-per-host over a NetBird mesh,
with optional OpenCode wiring. Built from the `paseo-gentoo-netbird` runbook (§8 outline), with
three correctness fixes folded into the units (see [Fixes baked in](#fixes-baked-in)).

The role templates **config, never state**: it manages `config.json` and the service unit, but
never touches `daemon-keypair.json`. Each box generates its own identity on first start, so you
can run the same play across the whole fleet without two daemons ever sharing an identity.

**Platforms:** systemd **or** OpenRC (auto-detected), on Gentoo, Debian/Ubuntu, Fedora/RHEL, and Arch.

## What it does

1. Creates a system `paseo` user (home under `/var/lib/paseo` so a hardened unit can write there).
2. Installs Node (≥20, version-gated) and the Paseo CLI into a per-user npm prefix.
3. **Downloads + installs the OpenCode CLI** (official installer → `~/.opencode/bin`, version-pinnable)
   for that user, and **deploys your sanitized `opencode.json[c]`** into its config dir.
4. **Injects your OpenCode provider secrets** (the `{env:VAR}` values) into the daemon's environment —
   one file loaded by **both** systemd and OpenRC — so OpenCode resolves them when Paseo launches it.
5. Seeds + deep-merges `config.json` (listen on the mesh IP, Host-header allowlist, worktrees root),
   preserving the password hash and any keys it doesn't manage.
6. Sets the daemon password from Vault — idempotently, with rotation support.
7. Drops a systemd unit **or** OpenRC script (auto-detected) and enables/starts it.

## Quickstart

From the repo root — a ready-to-run `site.yml` + `inventory.yml` + `ansible.cfg` live there:

```bash
ansible-galaxy collection install -r paseo/requirements.yml

# 1. Your sanitized OpenCode config is at the repo root as opencode.jsonc (secrets already
#    replaced by {env:VAR}). Put real mesh IPs in inventory.yml.

# 2. Secrets -> encrypted Vault in one shot (reads your OpenCode .env, derives the daemon password
#    from PASEO_TOKEN, prompts for a vault password). Values never hit your terminal:
./make-vault.sh                       # writes group_vars/paseo_fleet/vault.yml (encrypted)
#    (or do it by hand: ./opencode-secrets-from-env.sh >> vault.yml ; ansible-vault encrypt vault.yml)

# 3. Go (systemd or OpenRC, auto-detected per host). The vault password auto-resolves via
#    vault-pass.sh (env var / .vault_pass / keyring, or it prompts) — no --ask-vault-pass needed.
ansible-playbook site.yml --ask-become-pass
```

`example/` keeps the original library-style three-box (`cargogen2` / `ryzen-4090` / `pi-livingroom`)
topology if you'd rather drive the role that way.

## Fixes baked in

These diverge from the runbook's literal unit files on purpose:

- **systemd runs Paseo in the foreground.** `paseo daemon start` self-detaches and exits 0. Under
  the runbook's `Type=simple` + bare `daemon start`, systemd reaps the launcher's exit and — with
  the default `KillMode=control-group` — SIGTERMs the real worker (or, if it escapes the cgroup,
  orphans it unsupervised). That's the same double-detach failure the runbook carefully avoids for
  OpenRC. The unit here appends `paseo_foreground_flag` so the worker is the main PID, which also
  delivers the crash-restart you'd otherwise need `supervise-daemon` for.
- **Ordered after NetBird on both init systems.** The runbook's systemd unit only waits on
  `network-online.target`, which doesn't guarantee the WireGuard interface/IP is up — so a bind to
  `100.x` can still `EADDRNOTAVAIL`. This adds `After=`/`Wants=netbird.service` to match the OpenRC
  `after netbird`.
- **PATH baked into both units.** Neither runbook unit puts the npm prefix bin on PATH for *spawned*
  processes, so a per-user `opencode` isn't found when Paseo launches it. Both templates export
  `paseo_service_path` (npm prefix + `/usr/local/bin` first).

## Verified against @getpaseo/cli (0.1.101)

These were confirmed empirically against the real CLI, not guessed:

- **Daemon runs in the foreground with `--foreground`.** `paseo daemon start --foreground` is a real
  flag; the systemd unit uses it so the worker is the main PID and `Restart=` supervises it.
- **The password is written, not prompted.** `paseo daemon set-password` is a pure interactive TTY
  prompt (no `--stdin`/flag) and additionally crashes on Node < 22 — so the role never calls it. It
  hashes the password with paseo's own `hashDaemonPassword()` (bcryptjs cost 12) on the target and
  writes it to `config.json` → `daemon.auth.password` (the exact key the daemon's strict schema
  validates). Rotation-safe via a sha256 marker; nothing is logged.
- **Node ≥ 22 is required** (`paseo_min_node_major: 22`). The CLI's prompts use `util.styleText`'s
  array form, which only exists on Node 22+. Fedora and Arch ship Node ≥22 (distro packages are fine);
  on Debian/Ubuntu the distro Node is too old — install from NodeSource (or set
  `paseo_manage_node: false` and provide your own ≥22).
- **Config keys are confirmed:** `daemon.listen` (string), `daemon.hostnames` (array or `true`),
  `worktrees.root`, `daemon.auth.password`. The schema is **strict** — the role writes only known
  keys, so don't hand-add others to `config.json` or the daemon will refuse to start.

## Out of scope (manage separately)

- **NetBird itself** — must be installed and up; the role only *orders after* it.
- **OpenCode is now installed + configured by the role** — see
  [OpenCode: install + deploy](#opencode-install--deploy). Still yours to provide: the *contents* of
  your sanitized `opencode.json[c]` and the secret *values* (via Vault). If a provider authenticates
  through `opencode auth login` rather than an `{env:VAR}` apiKey, hand the role its `auth.json` via
  `paseo_opencode_auth` (Vault); otherwise that one piece stays out of scope.
- **`daemon-keypair.json`** — deliberately never templated or copied.

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `paseo_listen` | `127.0.0.1:6767` | **Override per host** to the mesh IP. The IP is auto-added to the allowlist. |
| `paseo_hostnames` | `[localhost, 127.0.0.1]` | Extra Host-header names; the listen IP is appended for you. |
| `paseo_relay_enabled` | `false` | Paseo's hosted relay (app.paseo.sh). Off for mesh-only fleets. |
| `paseo_min_node_major` | `22` | Confirmed required — the CLI's prompts need Node ≥22. |
| `paseo_set_password` | `true` | `false` = rely on the mesh as the sole boundary (no password). |
| `paseo_daemon_password` | `""` | Required when above is true — pull from Vault. |
| `paseo_foreground_flag` | `--foreground` | Verify on your build. Empty string disables it. |
| `paseo_init_system` | auto | `systemd` or `openrc` from `ansible_service_mgr`. |
| `paseo_after_netbird` / `paseo_netbird_unit` | `true` / `netbird` | Ordering dependency. |
| `paseo_manage_node` | `true` | `false` if you provide Node yourself (version still gated). |
| `paseo_cli_version` | `""` | Pin the CLI; empty tracks latest. |
| `paseo_opencode_bin` | `""` | If set, symlinks a pre-existing opencode binary into `/usr/local/bin`. |
| `paseo_install_opencode` | `true` | Download+install OpenCode (official installer) for `paseo_user`. |
| `paseo_opencode_version` | `""` | Pin OpenCode (e.g. `1.17.9`); empty = latest at first install. |
| `paseo_deploy_opencode_config` | `true` | Deploy your sanitized config (needs `paseo_opencode_config_src`). |
| `paseo_opencode_config_src` | `opencode.json` | Sanitized config on the controller; the repo `site.yml` points it at `{{ playbook_dir }}/opencode.jsonc`. |
| `paseo_opencode_secrets` | `{}` | `{env:VAR}` → value map (Vault); injected into the daemon environment. |
| `paseo_opencode_auth` | `{}` | Optional `auth.json` dict (Vault) for providers using `opencode auth login`. |
| `paseo_systemd_protect_home` | `true` | See own-user mode below. |
| `paseo_home_dir` / `paseo_state_dir` | `/var/lib/paseo` / `…/.paseo` | Distinct `state_dir` per daemon for multiple-on-one-host. |

Full list with comments in `defaults/main.yml`.

## Own-user mode (Direction A without duplication)

If you'd rather the daemon inherit your existing OpenCode env (runbook §6's "your tools, your
configs" path), point the role at your login user:

```yaml
paseo_user: eris
paseo_group: eris
paseo_home_dir: /home/eris
paseo_systemd_protect_home: false   # else opencode can't read ~/.config & ~/.local/share
```

`ProtectHome=true` hides `/home`, so it must be off when home lives there; `ReadWritePaths` follows
`paseo_home_dir` automatically. This trades isolation for zero env duplication.

## OpenCode: install + deploy

The role downloads OpenCode with the **official installer** (prebuilt binary → `~/.opencode/bin`,
honoring `VERSION=`; needs `curl` + `tar` and outbound access to github.com), then deploys *your*
config. Because `opencode.json` carries secrets, the split is:

- **the config file** (providers, models, plugins, MCP servers) is sanitized — every secret becomes
  an OpenCode `{env:VAR}` placeholder — and lives at the repo root as `opencode.jsonc`;
- **the secret values** live only in Ansible Vault and are injected into the **daemon's environment**
  (`/etc/paseo/paseo.env`, `0640 root:paseo`, loaded by both init systems), so `{env:VAR}` resolves
  when Paseo launches OpenCode.

Nothing secret is ever templated into the config or committed.

### Secrets → Vault

Keep the real values in `~/.config/opencode/.env` (`export NAME="value"`, sourced from your shell rc
for interactive use), then turn that into the vault block — the keys must match the `{env:VAR}` names
in `opencode.jsonc`:

```sh
./opencode-secrets-from-env.sh ~/.config/opencode/.env >> group_vars/paseo_fleet/vault.yml
ansible-vault encrypt group_vars/paseo_fleet/vault.yml
```

These land in `paseo_opencode_secrets` and are written to the daemon env file (never logged).

### Provider credentials (auth.json)

Some providers don't take an apiKey in the config — they store creds in
`~/.local/share/opencode/auth.json` (what `opencode auth login` writes), which the dedicated `paseo`
user won't have. If your primary model needs it, paste that JSON as a dict into `paseo_opencode_auth`
(Vault) and the role writes it `0600`. Leave it empty if an `{env:VAR}` apiKey in the config suffices.

### Verify on your topology

- **Your manual `mcp.paseo` block is probably redundant.** Paseo auto-injects its own MCP into the
  agents it launches: the `/mcp/agents` endpoint is exempt from the daemon password and is
  authenticated by a per-daemon-run *capability token* Paseo injects itself — not your `PASEO_TOKEN`.
  So you can likely delete the `mcp.paseo` block (and `PASEO_TOKEN`) from `opencode.jsonc` and let
  Paseo wire the loopback with the correct local URL + token. Keep `daemon.mcp.injectIntoAgents` at
  its default (on) for that. This is also why hand-adding that one auth header never quite worked.
- **Loopback MCP vs mesh bind (only if you keep the manual block).** If your config points `mcp.paseo`
  at `127.0.0.1:6767` but a host binds only its mesh IP (`paseo_listen: 100.x:6767`), the OpenCode
  Paseo launches there can't reach Paseo on loopback. Fix per host by using the mesh IP in that URL,
  or `paseo_listen: "0.0.0.0:6767"` (password + firewall as the boundary).
- **`PASEO_TOKEN` == daemon password.** If OpenCode calls Paseo back with `Bearer {env:PASEO_TOKEN}`,
  set `PASEO_TOKEN` (in `paseo_opencode_secrets`) to the same value as `paseo_daemon_password`.
- **Own-user mode skips the transport.** Running the daemon as your login user (below) lets it reuse
  the `~/.config/opencode` + creds already on the box: set `paseo_deploy_opencode_config: false` and
  `paseo_install_opencode: false` if OpenCode's already there.

## OpenCode config

OpenCode's config location isn't fixed, so the role resolves it the way OpenCode does, via
`files/resolve-opencode-config.sh` (POSIX sh, standalone-usable):

1. `$OPENCODE_CONFIG` if set and present,
2. a project-local `opencode.json[c]` walking up from `paseo_opencode_config_cwd` (if given),
3. `$XDG_CONFIG_HOME/opencode/opencode.json[c]` (default `~/.config/opencode/`),
4. else the default would-be path (so a fresh file can be created there).

It resolves for **the user the daemon runs as** (`paseo_user`), with that user's HOME. Three things
you can do, independently or together:

- **Discover** (default on): leave `paseo_opencode_config_path` empty and the role fills it in. Set
  it explicitly to skip discovery and pin a file.
- **Fetch it back**: `paseo_fetch_opencode_config: true` pulls the resolved config to the controller
  at `<paseo_opencode_config_fetch_dir>/<host>/<remote/path>` — per host, so a fleet run doesn't
  clobber. (Creds under `~/.local/share/opencode/` are deliberately **not** fetched; use the script's
  `--data` flag by hand if you need that dir.)
- **Wire Direction B**: `paseo_manage_opencode_mcp: true` deep-merges only the `mcp.paseo` block
  (`oauth:false` + `{env:PASEO_PASSWORD}`) into the resolved file, creating it if absent and leaving
  everything else untouched.
- **Print the effective config**: `paseo_print_opencode_config: true` reproduces opencode's
  global + project + `$OPENCODE_CONFIG` merge from the files (jsonc-aware) and prints the resolved
  *values* to the play output. Secrets are redacted unless `paseo_print_opencode_config_raw: true`.
  This is a file-level approximation of opencode's resolution — verify against `opencode mcp list`
  if exact semantics matter.

Standalone, on any box:

```sh
# where does opencode read its config?
./resolve-opencode-config.sh --explain
# where are its creds?
./resolve-opencode-config.sh --data
# include a project-local config in the search
./resolve-opencode-config.sh --cwd /path/to/project

# print the effective (merged) config values, redacted
./opencode-effective-config.py --explain
./opencode-effective-config.py --cwd /path/to/project --raw   # include secrets
```

## Daemon config

Grab each host's `config.json` back to the controller with `paseo_fetch_daemon_config: true`.
Because that file holds the bcrypt password hash, it's **redacted by default** — the hash (and
anything that looks like a credential) is stripped on the host before the file moves, landing at
`<paseo_daemon_config_fetch_dir>/<host>/config.json`. Set `paseo_daemon_config_redact: false` to
pull the raw file (which then nests under the full remote path, `…/<host>/<remote/path>/config.json`).

Redaction is value-aware (any bcrypt-looking string is caught regardless of the key name), so it
still works even though the exact key Paseo stores the hash under is build-dependent. Standalone:

```sh
./redact-json.py /var/lib/paseo/.paseo/config.json          # sanitized copy to stdout
```



- The password task gates on a sha256 marker of the desired secret: green when unchanged, re-runs on
  rotation. The marker is non-reversible and every password-touching task is `no_log`.
- On the first run, `set-password` writes `config.json` in its own format; the config merge then
  normalises it to canonical JSON (preserving the hash) in the same run. Subsequent runs are stable.
- Changing `hostnames`/`listen` later re-merges cleanly without clobbering the password.

## Notes from the runbook worth keeping in mind

- `schedule create --host` requires `--cwd`; remote `paseo run`/`schedule` don't inherit a shell's
  working dir. Bake `--cwd` into any automation you build on top.
- The OpenRC delegation wrapper gives up auto-restart-on-crash (documented tradeoff). For crash
  supervision on OpenRC, point `supervise-daemon` at Paseo's foreground mode with `/api/health` as
  the liveness probe.
