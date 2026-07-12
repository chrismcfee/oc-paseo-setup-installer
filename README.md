# README

Opinionated reproducible dev environments extendable via ansible playbooks

(Original name was opencode-paseo installer)

adding support in for editors such as neovim, lsp servers, and alternatives for all kinds of dev environments to make reproducible dev environments a little less manual.

## Old readme:

#### oc-paseo-setup-installer

Ansible automation that stands up a fleet of [**Paseo**](https://getpaseo.com) daemons and the
[**OpenCode**](https://opencode.ai) CLI they drive — installed, configured, secured, and reachable
remotely over a [NetBird](https://netbird.io) mesh — on **systemd _or_ OpenRC**, across **Gentoo,
Debian/Ubuntu, Fedora/RHEL, and Arch** (all auto-detected per host).

One daemon per box, each binding its own mesh IP. The role templates **config, never state**: it
manages `config.json` and the service unit but never touches a daemon's keypair, so the same play
runs across the whole fleet without two daemons ever sharing an identity.

> **Verified, not guessed.** The Paseo CLI (`@getpaseo/cli`) was installed and inspected to pin the
> exact daemon flags, the `config.json` schema, and the password hashing. The generated `config.json`
> and bcrypt password were tested against the **real daemon** (health check + live auth). See
> [What's verified](#whats-verified).

---

############ What it does

1. Creates a hardened system `paseo` user (home under `/var/lib/paseo`).
2. Installs Node (≥22, version-gated) and the Paseo CLI into a per-user npm prefix.
3. **Downloads + installs the OpenCode CLI** (official installer) for that user, and **deploys your
   sanitized `opencode.jsonc`** to its config dir.
4. **Injects your OpenCode provider secrets** from Ansible Vault into the daemon's environment — one
   file loaded by **both** systemd and OpenRC — so `{env:VAR}` resolves when Paseo launches OpenCode.
5. Writes the daemon's bcrypt password directly into `config.json` (rotation-safe, idempotent).
6. Templates `config.json` to bind the mesh IP with a Host-header allowlist.
7. Drops a **systemd unit** or **OpenRC service** (auto-detected) and enables + starts it.

## How it works

```
                        ┌──────────────── your controller (workstation) ────────────────┐
   ~/.config/opencode/.env   ──►  group_vars/paseo_fleet/vault.yml   ──►  ansible-playbook
   (real secrets, never        (ansible-vault encrypted, gitignored)     site.yml
    committed)                  built by make-vault.sh                    (vault-pass.sh
                                                                           resolves the pw)
                        └───────────────────────────────┬───────────────────────────────┘
                                                         │  over SSH, become: true
                                                         ▼
                        ┌──────────────────────── each target box ──────────────────────┐
   opencode.jsonc  ──►  ~/.config/opencode/opencode.jsonc      (deployed verbatim)
   ({env:VAR})          /etc/paseo/paseo.env  0640 root:paseo  (secret VALUES land here)
                        config.json  daemon.{listen,hostnames,auth.password,relay}
                        systemd paseo.service  /  OpenRC /etc/init.d/paseo
                                     │  binds 100.x:6767 on the NetBird mesh
                                     ▼
                        paseo daemon  ──launches──►  opencode  (inherits the env → {env:VAR} resolves)
                        └───────────────────────────────────────────────────────────────┘
```

############# Repository layout

```
.
├── README.md                      ← you are here (project overview + usage)
├── site.yml                       ← main playbook: run from repo root
├── inventory.yml                  ← your fleet: one host per box + its mesh IP
├── ansible.cfg                    ← roles_path, inventory, vault-password resolver
├── opencode.jsonc                 ← your SANITIZED OpenCode config (secrets are {env:VAR})
├── group_vars/paseo_fleet/
│   └── vault.yml.example          ← template for the encrypted secrets (copy → vault.yml)
│
├── make-vault.sh                  ← build the encrypted vault from your .env, one shot
├── opencode-secrets-from-env.sh   ← .env  →  paseo_opencode_secrets: YAML block
├── vault-pass.sh                  ← resolves the vault password (env / file / keyring / prompt)
├── redact-json.py                 ← strip secrets from a JSON config for safe export
├── opencode-effective-config.py   ← print OpenCode's merged effective config
│
├── paseo/                         ← the Ansible role (homelab.paseo)
│   ├── README.md                  ← role reference: full variable list + internals
│   ├── defaults/main.yml          ← every tunable, commented
│   ├── tasks/                     ← install, opencode_install, password, config, service, …
│   ├── templates/                 ← paseo.service.j2, paseo.openrc.j2, paseo.conf.d.j2, paseo.env.j2
│   ├── files/                     ← resolve-opencode-config.sh + helper scripts
│   └── example/                   ← library-style example (drive the role directly)
│
└── ansible-role-paseo.tar.gz      ← packaged snapshot of the role/
```

## #Requirements

**Controller (your workstation):**
- Ansible ≥ 2.14 and the `community.general` collection:
  ```bash
  ansible-galaxy collection install -r paseo/requirements.yml
  ```
- `ansible-vault` (ships with Ansible). `secret-tool` (libsecret) optional, for keyring-backed vault.

**Targets (each box):**
- SSH access + `sudo` (the play uses `become: true`).
- **Node ≥ 22** — installed by the role on Gentoo/Debian/Fedora/Arch, or provide your own.
- Outbound HTTPS to npm + `github.com` (OpenCode's installer pulls a release binary).
- **NetBird** installed and up (the role only *orders after* it; it does not manage NetBird).

## Quickstart

Run everything from the repo root.

```bash
# 1. Collection
ansible-galaxy collection install -r paseo/requirements.yml

# 2. Your OpenCode config already lives at ./opencode.jsonc (secrets are {env:VAR} placeholders).
#    Edit inventory.yml with your real hosts + NetBird mesh IPs.

# 3. Choose your vault password ONCE — vault-pass.sh resolves it for every run (no --ask-vault-pass).
#    Keyring (recommended), or an env var / a ./.vault_pass file:
secret-tool store --label="paseo ansible vault" service ansible-vault key paseo

# 4. Build the encrypted vault from your OpenCode secrets .env (values never hit your terminal):
./make-vault.sh                       # reads ~/.config/opencode/.env → group_vars/paseo_fleet/vault.yml

# 5. Go (systemd or OpenRC, auto-detected per host):
ansible-playbook site.yml --ask-become-pass
```

That's it — each box ends up with a running Paseo daemon bound to its mesh IP, with OpenCode installed
and wired to your providers.

## Configuration

### `opencode.jsonc` (the config you deploy)
Your real OpenCode config with **every secret replaced by `{env:VAR}`**. It is committed (no secrets
in it); the matching values live only in the vault. Update it any time and re-run the play. If you
introduce a new `{env:NEW_VAR}`, add `NEW_VAR` to your `.env` and re-run `make-vault.sh`.

### `inventory.yml` (your fleet)
One entry per box, each binding its own mesh IP:
```yaml
all:
  children:
    paseo_fleet:
      hosts:
        box-a:
          ansible_host: 100.64.0.1
          paseo_listen: "100.64.0.1:6767"
          paseo_hostnames: ["box-a"]
```

### Key role variables
Set on the play, in `inventory.yml`, or per host. Full list in [`paseo/README.md`](paseo/README.md).

| Variable | Default | Notes |
|---|---|---|
| `paseo_listen` | `127.0.0.1:6767` | **Override per host** to the mesh IP. |
| `paseo_set_password` | `true` | `false` = rely on the mesh as the sole boundary. |
| `paseo_install_opencode` | `true` | Download + install OpenCode for the daemon user. |
| `paseo_opencode_version` | `""` | Pin OpenCode; empty = latest at first install. |
| `paseo_deploy_opencode_config` | `true` | Deploy your sanitized `opencode.jsonc`. |
| `paseo_opencode_secrets` | `{}` | `{env:VAR}` → value map, from Vault. |
| `paseo_opencode_auth` | `{}` | Optional `auth.json` (Vault) for `opencode auth login` providers. |
| `paseo_relay_enabled` | `false` | Paseo's hosted relay; off for mesh-only fleets. |
| `paseo_manage_node` | `true` | `false` if you provide Node ≥22 yourself. |

## Secrets & Vault

The split is deliberate: **structure is committed, values never are.**

- **Where the vault lives:** `group_vars/paseo_fleet/vault.yml` on the **controller**, encrypted with
  `ansible-vault` (AES-256). It is **gitignored** and **never copied to targets**.
- **At run time:** Ansible decrypts it in memory; the values are written to each target at
  `/etc/paseo/paseo.env` (`0640 root:paseo`), loaded by the service.
- **The vault password** is resolved by [`vault-pass.sh`](vault-pass.sh) (wired via `ansible.cfg`), in
  order: `$ANSIBLE_VAULT_PASSWORD` → `./.vault_pass` → system keyring. Set up **one** source once and
  you never pass `--ask-vault-pass`; the password itself is never stored in the repo. Ansible reads it
  for every command, so set a source before running — `vault-pass.sh` prints how if you haven't.

To rotate or add keys: edit `~/.config/opencode/.env`, re-run `./make-vault.sh`, re-run the play.

## Helper scripts

| Script | What it does |
|---|---|
| [`make-vault.sh`](make-vault.sh) | One shot: `.env` → encrypted `group_vars/paseo_fleet/vault.yml` (derives the daemon password from `PASEO_TOKEN`). Secret values never print. |
| [`opencode-secrets-from-env.sh`](opencode-secrets-from-env.sh) | `.env` → a `paseo_opencode_secrets:` YAML block (the piece `make-vault.sh` uses). |
| [`vault-pass.sh`](vault-pass.sh) | Resolves the Ansible Vault password (env / file / keyring / prompt). No secret in the script. |
| [`redact-json.py`](redact-json.py) | Strip bcrypt hashes / credentials from a JSON config for safe export. |
| [`opencode-effective-config.py`](opencode-effective-config.py) | Reproduce OpenCode's merged effective config (jsonc-aware), redacted by default. |

## Supported platforms

| Init system | Distros |
|---|---|
| systemd **or** OpenRC (auto-detected) | Gentoo · Debian/Ubuntu · Fedora/RHEL · Arch |

Node ≥ 22 is required (the Paseo CLI's prompts use `util.styleText`'s array form). Fedora and Arch
ship Node ≥22; on Debian/Ubuntu the distro Node is usually too old — install from NodeSource, or set
`paseo_manage_node: false` and provide your own.

## What's verified

Confirmed empirically against `@getpaseo/cli` 0.1.101 (and the real daemon):

- `paseo daemon start --foreground` is the correct supervision flag.
- The password is bcrypt (cost 12) at `config.json` → `daemon.auth.password`; `set-password` is an
  un-pipeable TTY prompt, so the role hashes with Paseo's own `hashDaemonPassword()` on the target.
  A generated config + hash were loaded by the **live daemon**: `/api/health` returned `200`, the
  correct password authenticated, a wrong one was rejected.
- The config schema is **strict** — the role writes only the keys it validates against
  (`daemon.listen` / `daemon.hostnames` / `worktrees.root` / `daemon.auth.password` / `daemon.relay`).
- **Note:** Paseo auto-injects its own MCP (with a capability token) into agents it launches, so a
  manual `mcp.paseo` block in `opencode.jsonc` is usually redundant. See `paseo/README.md`.

## Security

- Only **sanitized** config is committed: `opencode.jsonc` uses `{env:VAR}` placeholders (audited — no
  inline keys), and only `vault.yml.example` (empty placeholders) is tracked.
- [`.gitignore`](.gitignore) keeps vault files, `.vault_pass*`, `.env`, `auth.json`, `*.unvaulted.yml`,
  fetched host artifacts, and `*.bak` out of git. Every secret-touching task is `no_log`.
- The daemon `config.json` and the secrets env file are `0600`/`0640`, owned by the `paseo` user.

## Further reading

- [`paseo/README.md`](paseo/README.md) — the role reference: every variable, the OpenCode wiring
  modes (discover / fetch / print / MCP), own-user mode, and the daemon-config export options.
- [`paseo/example/`](paseo/example/) — a library-style three-box example that drives the role directly.

## License

MIT (see `paseo/meta/main.yml`). Built from the `paseo-gentoo-netbird` runbook, with correctness
fixes folded into the units.
