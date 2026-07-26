# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read `AGENTS.md` too — its secrets/safety rules, Ansible conventions, and validation checklist apply to all work here. This file adds the commands and cross-file architecture it doesn't cover.

## What this repo is

Ansible automation that deploys a fleet of [Paseo](https://getpaseo.com) daemons plus the [OpenCode](https://opencode.ai) CLI they launch, reachable over a NetBird mesh, on systemd **or** OpenRC (auto-detected per host) across Gentoo, Debian/Ubuntu, Fedora/RHEL, and Arch. There is no package manager, build step, unit-test suite, linter, or formatter — validation is Ansible syntax checks, shell/Python compile checks, and the smoke-test playbooks below.

## Claude → Codex orchestration (Pattern A)

This repo includes a portable Claude-orchestrates / Codex-implements kit:

- Short pointer: [`.claude/README-codex-orchestration.md`](.claude/README-codex-orchestration.md)
- Full guide: [`docs/guides/CLAUDE_CODEX_ORCHESTRATION.md`](docs/guides/CLAUDE_CODEX_ORCHESTRATION.md)
- Skills: `/codex-impl` (one feature), `/features-parallel` (many)
- Scripts: `.claude/scripts/feature-worktree.sh`, `feature-status.sh`, `.claude/skills/codex-impl/scripts/run-codex.sh`

Main checkout stays put; features run in `.worktrees/<slug>` on `feat/<slug>`. Prefer `ansible-playbook --syntax-check` / `sh -n` / `py_compile` for verify — not heavy debug builds.

## Commands

All commands run from the repo root (`ansible.cfg` sets `roles_path = .`, `inventory = inventory.yml`, `vault_password_file = ./vault-pass.sh`).

**Vault password prerequisite:** Ansible executes `vault-pass.sh` eagerly for *every* command and requires a non-empty result. Before running anything, one source must exist: `$ANSIBLE_VAULT_PASSWORD`, a `./.vault_pass` file, or the keyring (`secret-tool store --label="paseo ansible vault" service ansible-vault key paseo`).

```sh
# One-time: install the required collection (community.general)
ansible-galaxy collection install -r paseo/requirements.yml

# Syntax-check (the closest thing to a fast "test")
ansible-playbook --syntax-check site.yml

# Full fleet deploy
ansible-playbook site.yml --ask-become-pass

# Single-host smoke tests — run the full role against ONE inventory host
# (real daemon + service; no OpenCode provider secrets needed, throwaway passwords inline)
ansible-playbook test-gentoo.yml --ask-become-pass   # hosts: gentoo
ansible-playbook test-arch.yml --ask-become-pass     # hosts: archtest
ansible-playbook dev-arch.yml --ask-become-pass      # hosts: arch
ansible-playbook dev-desk.yml --ask-become-pass      # hosts: fed4090

# Vault management (see the make-vault.sh caveat under "Load-bearing design decisions")
./make-vault.sh                                      # ~/.config/opencode/.env → encrypted group_vars/paseo_fleet/vault.yml
ansible-vault view group_vars/paseo_fleet/vault.yml
ansible-vault edit group_vars/paseo_fleet/vault.yml

# When editing helper scripts
sh -n <script.sh>
python3 -m py_compile <script.py>
```

Debugging a failing secret-bearing task: add `-e paseo_no_log=false` (output is censored by default via `paseo_no_log`). Never leave it off, and never commit runs/logs made with it off.

## Architecture

Two layers:

- **Repo root — the deployment.** `site.yml` (the play) + `inventory.yml` (the real fleet: per-host mesh hostname, `paseo_listen`, SSH creds from vault) + `ansible.cfg` + vault plumbing + `opencode.jsonc` (the committed, sanitized OpenCode config — secrets are `{env:VAR}` placeholders only).
- **`paseo/` — a self-contained role** (`homelab.paseo`), also usable library-style (see `paseo/example/`). `paseo/defaults/main.yml` is the authoritative, commented list of every tunable.

### Role task flow (`paseo/tasks/main.yml`)

1. Assert inputs; compute `paseo_effective_hostnames` — the listen IP is auto-appended to the Host-header allowlist (avoids the "open port + valid password, still rejected" trap).
2. `install.yml` — system `paseo` user (home `/var/lib/paseo` so `ProtectHome=true` still works), Node (per-distro branches, version-gated ≥22 even when `paseo_manage_node: false`), Paseo CLI into a per-user npm prefix. `npm root -g` is queried at runtime because lib64 profiles (Gentoo) put global modules under `lib64/`, and `password.yml` must `chdir` into the CLI package dir.
3. `opencode_install.yml` (only when `paseo_install_opencode`) — official installer (`curl | bash` into `~/.opencode/bin`, honors `VERSION=`); the install task itself re-runs only when OpenCode is missing, a pinned version differs, or `paseo_opencode_upgrade` is set.
4. `claude_install.yml` (only when `paseo_install_claude`, default **false**) — Anthropic's native installer (`curl | bash -s <version>`); idempotency reads the launcher symlink with `readlink -e` so a no-op play never execs the ~260 MB binary. When a binary already exists it calls `claude install <version>` instead, because the bootstrap always downloads `latest` before the pin.
5. `password.yml` (only when `paseo_set_password`, default true) — see below.
6. `config.yml` — deep-merges only owned keys into `config.json`: `daemon.listen`, `daemon.hostnames`, `daemon.relay.enabled`, `worktrees.root`. Everything else (the password hash, unknown keys) survives.
7. `opencode.yml` — deploy the sanitized config (+ optional `auth.json` from vault), and the optional discover/fetch/MCP-merge/print paths.
8. `claude.yml` (only when `paseo_install_claude`) — **must run after `config.yml`**, since it deep-merges `agents.providers.claude.command` into the same `config.json`. Also deploys the role-owned `~/.claude/settings.json` and merges the onboarding flag into `~/.claude.json`.
9. `fetch_daemon_config.yml` (only when `paseo_fetch_daemon_config`, default false), `selinux.yml` (`paseo_manage_selinux` + RedHat + SELinux enabled: relabel each enabled agent's bin dir `bin_t`), then `service.yml` — env file (only when the **union** of `paseo_opencode_secrets` and `paseo_claude_secrets` is non-empty; units tolerate its absence), systemd unit or OpenRC init.d + conf.d, flush handlers, enable+start.

### Load-bearing design decisions

- **Config, never state.** The role manages `config.json` and service units but must never copy/template `daemon-keypair.json` — each host generates its own identity. The daemon's config schema is **strict**: don't add unverified keys or the daemon refuses to start.
- **The password is written, not prompted.** `paseo daemon set-password` is an interactive TTY prompt (no flags) — never automate it. `password.yml` runs Paseo's own `hashDaemonPassword()` (bcryptjs cost 12) via `node` from inside the installed CLI package on the target and merges the hash into `config.json` at `daemon.auth.password`. A sha256 marker file (`.ansible_pw_marker`) gates the work so the bcrypt salt only changes on real rotation (idempotent re-runs).
- **Secrets pipeline (structure is committed, values never are):** `~/.config/opencode/.env` → `make-vault.sh` → encrypted `group_vars/paseo_fleet/vault.yml` (controller-only, gitignored) → decrypted in memory at run time → written to `/etc/paseo/paseo.env` (0640 root:paseo) on each target → loaded by both init systems (systemd `EnvironmentFile=`, OpenRC sourcing) → Paseo launches OpenCode with that env, so `{env:VAR}` in `opencode.jsonc` resolves.
- **`make-vault.sh` does not produce the whole vault this fleet needs.** It writes `paseo_opencode_secrets` plus a single unsuffixed `vault_paseo_daemon_password` (derived from `PASEO_TOKEN` in the `.env`) — but that unsuffixed var is consumed only by `paseo/example/site.yml`. The real `inventory.yml` consumes per-host `vault_paseo_daemon_password_<host>` and `vault_ssh_password_<host>` vars, which the script never generates. It also **replaces** `vault.yml` wholesale (previous file → `.bak`, gitignored). After re-running it, re-add the per-host vars with `ansible-vault edit` or recover them from the `.bak`.
- **Daemon passwords are per host.** `inventory.yml` maps `paseo_daemon_password` to `vault_paseo_daemon_password_<host>` vars. `site.yml` deliberately sets no play-level password — play vars would override the per-host ones. Keep it that way.
- **Init-system duality.** `paseo_init_system` auto-detects from `ansible_service_mgr`; every service-level feature (env file, NetBird ordering, PATH) must work on both systemd and OpenRC. systemd runs `paseo daemon start --foreground` so the worker is the main PID (`daemon start` self-detaches and exits 0; under `Type=simple` that SIGTERMs the real worker). Both units get `paseo_service_path` baked in (OpenCode install dir + npm prefix bin first) so the spawned `opencode` is found. Units order after NetBird so the mesh IP exists before bind (`EADDRNOTAVAIL` otherwise).
- **`paseo_opencode_secrets` is replaced wholesale, not merged.** Ansible dicts don't merge across var files — if the vault defines it, a group-vars copy in `inventory.yml` is ignored. Keep all keys in one place.
- **One env file for all agents.** There is exactly one `EnvironmentFile=`/one sourced file, so `paseo_opencode_secrets` and `paseo_claude_secrets` are unioned in `service.yml` (`_paseo_agent_secrets`) rather than each getting its own file. The gate tests the **union** — gating on the OpenCode dict alone would leave a Claude-only host with no env file, and `ANTHROPIC_API_KEY` would silently never reach the daemon. Key names must not collide across the two dicts.
- **PATH is the only agent-discovery lever.** Paseo decides a provider is "available" by running `which -a <cli>` **inside the daemon process**, so only the daemon's own PATH (`paseo_service_path`, baked into both units) counts. Setting a PATH in `agents.providers.<id>.env` does **not** work — that env reaches the spawned child, never the lookup. `paseo_service_path` is therefore built from the `paseo_agent_path_dirs` list and joined with `reject('eq','')`: a naive concatenation leaves an empty `::` element when an agent is disabled, and an empty PATH element means the **current directory** — a real privilege problem for a root-installed unit.
- **Auth is not part of availability.** A host with an agent CLI installed but no valid credential still reports *ready* and only fails at the first prompt. The availability probe also treats a non-zero exit *or* a 2-second hang as success, so *ready* means "a binary answered", not "a working install".
- **`hasCompletedOnboarding` is an unsupported bet.** Claude Code's first-run wizard blocks non-interactive use, and the flag that suppresses it (`~/.claude.json` → `hasCompletedOnboarding`) is undocumented internal state. The role read-modify-writes it (never templates that file — it also holds `machineID` and update bookkeeping) and this may break on a Claude Code upgrade. `paseo_seed_claude_onboarding: false` opts out.
- **Provider overrides are not strict, but the config root is.** Verified against the daemon's own `PersistedConfigSchema`: unknown keys at the root or under `daemon` are **rejected**, while unknown keys under `agents.providers.<id>` are silently stripped. `command` must be a non-empty array of strings — a bare string is rejected. The role sets only `command`, so there is less to break on a daemon upgrade.

### Duplicated files — keep in sync

`paseo-role-README.md`, `redact-json.py`, and `opencode-effective-config.py` at the repo root are byte-identical copies of `paseo/README.md`, `paseo/files/redact-json.py`, and `paseo/files/opencode-effective-config.py`. If you edit one, mirror the change. `ansible-role-paseo.tar.gz` is a packaged snapshot of `paseo/`.

## Secrets rules (critical)

- Only sanitized config is committed: `opencode.jsonc` must keep every secret as an `{env:VAR}` placeholder; only `vault.yml.example` is tracked. If you add a new `{env:NEW_VAR}` placeholder, the value goes in the `.env` → re-run `./make-vault.sh`.
- Never print secret values; prefer key/shape checks. `opencode-secrets-from-env.sh` prints values — pipe straight to a vault file.
- Secret-touching tasks use `no_log: "{{ paseo_no_log }}"` (or bare `no_log: true`) — preserve this on any new task that handles passwords/keys.
- Gitignored and must stay so: `.env` / `.env.*`, `.vault_pass` / `.vault_pass.*`, `group_vars/*/vault.yml`, `auth.json`, `*.unvaulted.yml`, `/fetched-opencode/`, `/fetched-daemon-config/`, `*.bak`.
