# Codex Additional Option Design

## Context

This repository installs and configures a Paseo daemon fleet. The current role
installs OpenCode for the `paseo_user`, deploys a sanitized `opencode.jsonc`,
injects OpenCode secrets through `/etc/paseo/paseo.env`, and keeps the Paseo
daemon path focused on templating service/config files instead of daemon state.

The requested change is to make Codex available as an additional option on the
same hosts. Codex should not replace OpenCode as the agent Paseo launches, and
the role must not invent unverified Paseo `config.json` keys or manage
`daemon-keypair.json`.

Current Codex documentation supports this additive shape:

- Codex CLI is available on Linux and can run interactively or through
  `codex exec`.
- Durable Codex state and config live under `CODEX_HOME`, defaulting to
  `~/.codex`.
- The standalone installer supports `CODEX_NON_INTERACTIVE=1` and
  `CODEX_INSTALL_DIR`.
- `CODEX_API_KEY` is intended for `codex exec`, while persisted user login
  belongs in Codex auth storage under `CODEX_HOME`.
- Codex can run as an MCP server or app-server, but those are out of scope for
  the first additive install/config pass.

## Goals

- Add optional Codex installation for `paseo_user`.
- Keep existing OpenCode installation and configuration behavior unchanged.
- Allow managed Codex config under a dedicated `CODEX_HOME`.
- Reuse the existing target environment file pattern for Codex-related secrets.
- Preserve support for systemd and OpenRC.
- Preserve cross-distro behavior for Gentoo, Debian/Ubuntu, Fedora/RHEL, and
  Arch.
- Document how to enable Codex and what authentication modes are supported.

## Non-goals

- Do not change which agent Paseo launches by default.
- Do not run or supervise `codex app-server`, `codex mcp-server`, or
  `codex remote-control` as a service in this first pass.
- Do not copy or template `daemon-keypair.json`.
- Do not write unverified keys to Paseo daemon `config.json`.
- Do not persist raw Codex access tokens or API keys in tracked files.
- Do not fetch or print secret values during validation.

## Proposed Role Variables

Add these defaults in `paseo/defaults/main.yml`:

```yaml
paseo_install_codex: false
paseo_codex_install_url: "https://chatgpt.com/codex/install.sh"
paseo_codex_install_dir: "{{ paseo_home_dir }}/.local/bin"
paseo_codex_bin: "{{ paseo_codex_install_dir }}/codex"
paseo_codex_symlink: true
paseo_codex_upgrade: false
paseo_codex_home: "{{ paseo_home_dir }}/.codex"
paseo_deploy_codex_config: false
paseo_codex_config: {}
paseo_codex_config_dest: "{{ paseo_codex_home }}/config.toml"
paseo_codex_secrets: {}
```

`paseo_codex_config` should be a dictionary rendered to TOML. If Ansible's
available filters do not provide reliable TOML rendering, the implementation can
use a small local template that supports the simple top-level/table structure
needed by Codex config. The first implementation should avoid a broad custom
TOML serializer unless tests or examples justify it.

The existing `paseo_env_file` should include both `paseo_opencode_secrets` and
`paseo_codex_secrets`. The merge must fail clearly on duplicate keys with
different values, because a single env file cannot represent two different
values for the same variable.

## Task Structure

Add `paseo/tasks/codex_install.yml`:

- Ensure `curl`, `tar`, and CA certificates are present using the same
  distro-aware pattern as `opencode_install.yml`.
- Ensure `paseo_codex_home` and `paseo_codex_install_dir` exist for
  `paseo_user`.
- Check `{{ paseo_codex_bin }} --version`.
- Run the standalone installer only when Codex is missing or
  `paseo_codex_upgrade` is true.
- Run the installer as `paseo_user` with:
  - `HOME={{ paseo_home_dir }}`
  - `CODEX_HOME={{ paseo_codex_home }}`
  - `CODEX_INSTALL_DIR={{ paseo_codex_install_dir }}`
  - `CODEX_NON_INTERACTIVE=1`
- Assert the installed binary exists.
- Optionally symlink it to `/usr/local/bin/codex`.

Add `paseo/tasks/codex.yml`:

- Ensure `paseo_codex_home` exists with mode `0700`.
- Deploy `config.toml` when `paseo_deploy_codex_config` is true.
- Set owner/group to `paseo_user`/`paseo_group` and mode `0600`.
- Notify `restart paseo` only if the service environment changed in a way that
  affects processes launched by Paseo. Codex config file changes alone do not
  require restarting Paseo unless the role explicitly documents that restart
  as a convenience.

Update `paseo/tasks/main.yml`:

- Import `codex_install.yml` when `paseo_install_codex` is true.
- Import `codex.yml` when Codex config deployment is enabled or
  `paseo_codex_secrets` is non-empty.

## Environment Data Flow

The existing env template writes one shell-compatible/systemd-compatible file at
`/etc/paseo/paseo.env`. Extend the source data to:

```yaml
_paseo_env_secrets: "{{ paseo_opencode_secrets | combine(paseo_codex_secrets) }}"
```

Before rendering, compute duplicate intersections between the two secret maps.
If a key exists in both maps and the values differ, fail with a non-secret error
that names only the key.

Codex-specific examples:

- `CODEX_API_KEY` for one-off `codex exec` automation.
- `CODEX_ACCESS_TOKEN` only for trusted automation where the operator wants to
  pipe it into `codex login --with-access-token` or expose it to a controlled
  process.
- Provider-specific keys referenced by Codex `model_providers.*.env_key`.

The docs must make clear that `CODEX_API_KEY` is not a general persisted CLI
login and is intended for `codex exec`.

## Service PATH

Update the default `paseo_service_path` to include `paseo_codex_install_dir`
when Codex installation is enabled. The implementation should avoid changing
the existing OpenCode-first ordering for current deployments. A safe default is:

```yaml
paseo_service_path: "{{ paseo_opencode_install_dir }}/bin:{{ paseo_codex_install_dir }}:{{ paseo_bin_dir }}:/usr/local/bin:/usr/bin:/bin"
```

Because `paseo_install_codex` defaults to false, adding the Codex install dir to
PATH is harmless even before the binary exists.

## Documentation

Update `README.md` and `paseo/README.md` with:

- A short "Codex optional support" section.
- Variables table entries for the Codex defaults.
- Example inventory or play vars showing:

```yaml
paseo_install_codex: true
paseo_deploy_codex_config: true
paseo_codex_config:
  model: "gpt-5.5"
  approval_policy: "on-request"
  sandbox_mode: "workspace-write"
paseo_codex_secrets:
  CODEX_API_KEY: "{{ vault_codex_api_key }}"
```

The docs must state that this makes Codex available on the host, but does not
make Paseo launch Codex instead of OpenCode.

## Error Handling

- Missing installer dependencies should fail through package-manager tasks.
- Installer failure should surface the installer command failure without
  printing secrets.
- Config rendering should fail before writing a partial invalid file if the
  input shape is unsupported.
- Secret key collisions should fail with key names only, not values.
- Codex install should not run when disabled.

## Testing and Validation

Run these checks before handoff:

- `ansible-playbook --syntax-check site.yml` when Ansible and collections are
  available.
- If a shell helper is added or changed, `sh -n <script>`.
- If a Python helper is added or changed, `python3 -m py_compile <script>`.
- Review `git diff` for accidental secrets, fetched artifacts, daemon identity
  material, or unrelated inventory/config edits.

Targeted review should verify:

- `daemon-keypair.json` is not referenced by new tasks.
- No task prints Codex secret values.
- Existing OpenCode defaults remain compatible.
- systemd and OpenRC still load the same env file.

## Deferred Decisions

- Whether to support a pinned Codex version is not specified by current Codex
  installer environment docs. The first pass should omit version pinning unless
  a documented supported installer knob is found.
- Managed `codex login --with-access-token` is intentionally omitted. The first
  pass only installs Codex, deploys config, and injects env.
