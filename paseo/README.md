# ansible-role: paseo

Deploys a headless [Paseo](https://getpaseo.com) daemon as one-per-host over a NetBird mesh,
with optional OpenCode wiring. Built from the `paseo-gentoo-netbird` runbook (§8 outline), with
three correctness fixes folded into the units (see [Fixes baked in](#fixes-baked-in)).

The role templates **config, never state**: it manages `config.json` and the service unit, but
never touches `daemon-keypair.json`. Each box generates its own identity on first start, so you
can run the same play across the whole fleet without two daemons ever sharing an identity.

## What it does

1. Creates a system `paseo` user (home under `/var/lib/paseo` so a hardened unit can write there).
2. Installs Node (≥20, version-gated) and the Paseo CLI into a per-user npm prefix.
3. Seeds + deep-merges `config.json` (listen on the mesh IP, Host-header allowlist, worktrees root),
   preserving the password hash and any keys it doesn't manage.
4. Sets the daemon password from Vault — idempotently, with rotation support.
5. Drops a systemd unit **or** OpenRC script (auto-detected) and enables/starts it.

## Quickstart

```bash
ansible-galaxy collection install -r roles/paseo/requirements.yml
# edit example/inventory.yml with real mesh IPs; create + encrypt the vault file
ansible-playbook -i example/inventory.yml example/site.yml --ask-vault-pass
```

See `example/` for a working three-box (`cargogen2` / `ryzen-4090` / `pi-livingroom`) topology.

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

## Verify these on your build

The role is honest about two things the runbook itself flags as version-dependent:

- **`paseo_foreground_flag`** defaults to `--foreground`. Confirm with `paseo daemon start --help`
  (could be `--no-detach` / `run`). If your build has no foreground mode, switch the systemd unit to
  `Type=forking` with a `PIDFile=` instead — but foreground is strongly preferred.
- **`set-password` is non-interactive via stdin.** The runbook shows an interactive prompt; the role
  pipes the password on stdin (one newline appended). If your build uses a flag, override
  `paseo_set_password_argv` (e.g. add `--stdin` / `--password-stdin`). If it prompts twice, put the
  password on two lines in `paseo_set_password_stdin`.

## Out of scope (manage separately)

- **NetBird itself** — must be installed and up; the role only *orders after* it.
- **Each box's OpenCode provider env** — binary, `opencode.json` (TensorZero routing), and model
  creds are your own per-machine setup (runbook §6). The role can *discover* that config, *fetch* it
  back, and inject just the MCP *client* block — see [OpenCode config](#opencode-config) — but it
  doesn't manage your provider/model setup.
- **`daemon-keypair.json`** — deliberately never templated or copied.

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `paseo_listen` | `127.0.0.1:6767` | **Override per host** to the mesh IP. The IP is auto-added to the allowlist. |
| `paseo_hostnames` | `[localhost, 127.0.0.1]` | Extra Host-header names; the listen IP is appended for you. |
| `paseo_set_password` | `true` | `false` = rely on the mesh as the sole boundary (no password). |
| `paseo_daemon_password` | `""` | Required when above is true — pull from Vault. |
| `paseo_foreground_flag` | `--foreground` | Verify on your build. Empty string disables it. |
| `paseo_init_system` | auto | `systemd` or `openrc` from `ansible_service_mgr`. |
| `paseo_after_netbird` / `paseo_netbird_unit` | `true` / `netbird` | Ordering dependency. |
| `paseo_manage_node` | `true` | `false` if you provide Node yourself (version still gated). |
| `paseo_cli_version` | `""` | Pin the CLI; empty tracks latest. |
| `paseo_opencode_bin` | `""` | If set, symlinks your opencode binary into `/usr/local/bin`. |
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
