#!/bin/sh
# make-vault.sh — build an encrypted Ansible Vault from your OpenCode secrets .env, in one shot.
#
# Produces group_vars/paseo_fleet/vault.yml containing:
#   vault_paseo_daemon_password: "<PASEO_TOKEN from your .env>"   # matches the loopback bearer
#   paseo_opencode_secrets:
#     <every  export KEY="value"  from your .env>
#
# The plaintext is staged in a private (umask 077) temp file and handed to `ansible-vault encrypt` —
# secret VALUES are never printed. The vault password comes from the repo's vault-pass.sh resolver
# (env var / .vault_pass / keyring, or it prompts). Run it on the box that holds the real .env.
#
#   ./make-vault.sh [ENV_FILE] [OUT_FILE]
#     ENV_FILE  default: ~/.config/opencode/.env
#     OUT_FILE  default: group_vars/paseo_fleet/vault.yml
#
# Re-run any time to refresh keys (an existing OUT_FILE is backed up to OUT_FILE.bak first).
set -eu

here=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
env_file="${1:-$HOME/.config/opencode/.env}"
out="${2:-group_vars/paseo_fleet/vault.yml}"

[ -r "$env_file" ] || { echo "make-vault: cannot read $env_file" >&2; exit 1; }
command -v ansible-vault >/dev/null 2>&1 || { echo "make-vault: ansible-vault not found" >&2; exit 1; }
[ -x "$here/opencode-secrets-from-env.sh" ] || {
    echo "make-vault: opencode-secrets-from-env.sh must sit next to this script" >&2; exit 1; }

# Daemon password = the PASEO_TOKEN value, so it matches the Bearer your OpenCode uses to call Paseo.
pw=$(sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}//; s/^PASEO_TOKEN=//p' "$env_file" | head -n1)
case "$pw" in \"*\") pw=${pw#\"}; pw=${pw%\"} ;; \'*\') pw=${pw#\'}; pw=${pw%\'} ;; esac
[ -n "$pw" ] || echo "make-vault: WARNING: no PASEO_TOKEN in $env_file; daemon password left blank — edit after." >&2
pw_esc=$(printf '%s' "$pw" | sed 's/\\/\\\\/g; s/"/\\"/g')

umask 077
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM
{
    printf 'vault_paseo_daemon_password: "%s"\n' "$pw_esc"
    "$here/opencode-secrets-from-env.sh" "$env_file"
} > "$tmp"

mkdir -p "$(dirname "$out")"
[ -e "$out" ] && cp -p "$out" "$out.bak"
ansible-vault encrypt "$tmp" --output "$out"
echo "make-vault: wrote encrypted $out   (verify: ansible-vault view $out)" >&2
