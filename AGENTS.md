# AGENTS.md

Guidance for coding agents working in this repository.

## Project overview

This repository is an Ansible-based installer for a fleet of Paseo daemons that launch OpenCode over a NetBird mesh. It supports systemd and OpenRC targets across Gentoo, Debian/Ubuntu, Fedora/RHEL, and Arch.

The key invariant: the role templates configuration and service units, but not daemon state. Do not copy, template, or otherwise manage `daemon-keypair.json`; each host must generate its own daemon identity.

## Repository layout

- `site.yml` — main playbook; run from the repository root.
- `inventory.yml` — fleet inventory; one host per box with its own NetBird mesh IP.
- `ansible.cfg` — sets `roles_path = .`, `inventory = inventory.yml`, and `vault_password_file = ./vault-pass.sh`.
- `opencode.jsonc` — committed sanitized OpenCode config; secrets must remain `{env:VAR}` placeholders.
- `group_vars/paseo_fleet/vault.yml.example` — example vault structure. The real `vault.yml` is gitignored.
- `make-vault.sh` — builds encrypted `group_vars/paseo_fleet/vault.yml` from an OpenCode `.env`.
- `opencode-secrets-from-env.sh` — converts an OpenCode `.env` into a vault-ready `paseo_opencode_secrets:` YAML block. It prints secret values; treat output as sensitive.
- `vault-pass.sh` — resolves the Ansible Vault password from env, local file, keyring, or prompt.
- `redact-json.py` / `opencode-effective-config.py` — helper scripts for safe config inspection.
- `paseo/` — the Ansible role. Important subdirs:
  - `paseo/defaults/main.yml` — authoritative defaults and comments for role variables.
  - `paseo/tasks/` — install, password, config, service, OpenCode, and fetch tasks.
  - `paseo/templates/` — systemd/OpenRC/env templates.
  - `paseo/files/` — standalone helper scripts deployed/used by the role.
  - `paseo/example/` — library-style example topology.
- `ansible-role-paseo.tar.gz` — packaged snapshot of the role.

## Development commands

Run commands from the repository root unless noted.

- Install required Ansible collection:
  ```sh
  ansible-galaxy collection install -r paseo/requirements.yml
  ```
- Create/update encrypted vault from local OpenCode secrets:
  ```sh
  ./make-vault.sh
  ```
- Run the main playbook:
  ```sh
  ansible-playbook site.yml --ask-become-pass
  ```
- Manual vault workflow, if needed:
  ```sh
  ./opencode-secrets-from-env.sh ~/.config/opencode/.env >> group_vars/paseo_fleet/vault.yml
  ansible-vault encrypt group_vars/paseo_fleet/vault.yml
  ```
- Inspect an encrypted vault without exposing it in git:
  ```sh
  ansible-vault view group_vars/paseo_fleet/vault.yml
  ```
- Syntax-check the playbook when Ansible is available:
  ```sh
  ansible-playbook --syntax-check site.yml
  ```

There is no package manager, build step, unit-test suite, linter config, or formatter config in this repo. Prefer Ansible syntax checks and targeted script review over inventing unsupported commands.

## Secrets and safety rules

- Never commit real secrets. Keep only sanitized config in git.
- Do not read or print secret values unless explicitly necessary for the user’s request. Prefer key/shape checks over value output.
- The following are intentionally gitignored and should stay that way: `.env`, `.env.*`, `.vault_pass*`, `group_vars/*/vault.yml`, `group_vars/*/vault.yaml`, `host_vars/*/vault.yml`, `host_vars/*/vault.yaml`, `auth.json`, `*.unvaulted.yml`, `*.unvaulted.yaml`, fetched host artifacts, and `*.bak`.
- `opencode.jsonc` must use `{env:VAR}` placeholders for provider secrets. If a new placeholder is added, update the vault generation/docs accordingly.
- `group_vars/paseo_fleet/vault.yml` lives on the controller, is encrypted with Ansible Vault, and is not copied to targets. At runtime, selected values are written to `/etc/paseo/paseo.env` on targets.
- Secret-touching Ansible tasks should use `no_log`.
- `opencode-secrets-from-env.sh` prints secret values; pipe directly to a vault file and encrypt, or avoid running it in contexts where output may be captured.

## Ansible and role conventions

- Keep YAML explicit and readable. Existing files use `---` document starts and descriptive comments for operational gotchas.
- Use role defaults in `paseo/defaults/main.yml` for tunables; keep playbook/inventory focused on deployment-specific overrides.
- Preserve idempotency. Changes should be safe to re-run across a fleet.
- Preserve support for both systemd and OpenRC unless a change is explicitly scoped to one init system.
- Preserve cross-distro behavior for Gentoo, Debian/Ubuntu, Fedora/RHEL, and Arch.
- Prefer per-host overrides in `inventory.yml` for mesh IPs and hostnames.
- Keep `paseo_listen` per host on the NetBird mesh IP by default. Avoid switching to `0.0.0.0` without calling out the security implications.
- The role should manage `config.json` and service files, not daemon identity state.
- The daemon password is written as a bcrypt hash through Paseo’s own hashing code; do not replace this with `paseo daemon set-password` automation. That command is documented here as an interactive TTY prompt and not suitable for noninteractive Ansible.
- Do not hand-add unverified keys to daemon `config.json`; the Paseo schema is strict.

## Paseo/OpenCode gotchas

- Node >= 22 is required for the Paseo CLI. The role defaults to `paseo_min_node_major: 22` and version-gates even when `paseo_manage_node: false`.
- `paseo daemon start --foreground` is the verified supervision mode. The systemd unit needs the daemon in the foreground so restart behavior supervises the real worker.
- NetBird is not installed or managed by this role; services are only ordered after it.
- The service PATH intentionally includes the OpenCode install dir and Paseo npm prefix so Paseo can spawn `opencode`.
- With `ProtectHome=true`, the default `paseo_home_dir` under `/var/lib/paseo` is intentional. If switching to a login user under `/home`, set `paseo_systemd_protect_home: false`.
- Paseo may auto-inject its own MCP into launched agents. A manual `mcp.paseo` block in `opencode.jsonc` is often redundant; check `README.md` and `paseo/README.md` before changing this behavior.
- If a manual MCP block points at `127.0.0.1:6767` while the daemon binds only a mesh IP, the launched OpenCode cannot reach it over loopback. Use a mesh URL per host or bind appropriately with password/firewall boundaries.
- For remote `paseo run` or `schedule create --host` automation, include `--cwd`; remote commands do not inherit a shell working directory.

## Validation checklist

Before handing off changes:

1. Re-read relevant defaults, tasks, templates, and docs touched by the change.
2. Run `ansible-playbook --syntax-check site.yml` when Ansible and required collections are available.
3. If editing shell helpers, run `sh -n <script>` on changed POSIX shell scripts.
4. If editing Python helpers, run `python3 -m py_compile <script>` on changed Python files.
5. Verify no secret files or generated/fetched artifacts were added to git.
6. Review `git diff` for accidental secret output, host-specific state, or daemon identity material.

If validation cannot be run because required tools or credentials are unavailable, state that clearly and explain what was inspected instead.
