#!/bin/sh
# opencode-secrets-from-env.sh — turn an OpenCode secrets .env into a vault-ready Ansible var block.
#
# Reads `export KEY="value"` / `KEY=value` lines and prints:
#
#   paseo_opencode_secrets:
#     KEY: "value"
#     ...
#
# so you can drop it straight into group_vars/<group>/vault.yml and `ansible-vault encrypt` it. The
# key names line up with the {env:VAR} placeholders in your sanitized opencode.json[c]. Run this
# YOURSELF on the box that holds the real .env — it prints the values, so pipe to a file and encrypt.
#
#   ./opencode-secrets-from-env.sh [ENV_FILE]        # default: ~/.config/opencode/.env
#   ./opencode-secrets-from-env.sh > group_vars/paseo_fleet/vault.yml      # then add the password +
#   ansible-vault encrypt group_vars/paseo_fleet/vault.yml                 # encrypt
#
# Exit 0 on success, 1 if the env file is unreadable.
set -eu

env_file="${1:-$HOME/.config/opencode/.env}"
[ -r "$env_file" ] || { echo "opencode-secrets-from-env: cannot read $env_file" >&2; exit 1; }

echo "paseo_opencode_secrets:"
# Drop an optional leading `export `, keep only KEY=... lines, then YAML-quote each value safely.
sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}//; /^[A-Za-z_][A-Za-z0-9_]*=/p' "$env_file" \
| while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    # strip one layer of surrounding single OR double quotes, if present
    case "$val" in
        \"*\") val=${val#\"}; val=${val%\"} ;;
        \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    # escape backslash + double-quote so the YAML double-quoted scalar is always valid
    esc=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '  %s: "%s"\n' "$key" "$esc"
done
