#!/bin/sh
# vault-pass.sh — resolve the Ansible Vault password so you never type --ask-vault-pass.
# Wired in via ansible.cfg (vault_password_file = ./vault-pass.sh): Ansible runs this and reads the
# password from stdout. This script is safe to commit — it holds NO secret, it only *fetches* one.
#
# Resolution order (first hit wins):
#   1. $ANSIBLE_VAULT_PASSWORD          ephemeral:  export ANSIBLE_VAULT_PASSWORD=... (a session, CI)
#   2. ./.vault_pass                    a 0600 file you create (gitignored) — simplest persistent option
#   3. system keyring via secret-tool   most secure; service=ansible-vault key=paseo
#   4. interactive prompt               last resort (like --ask-vault-pass, minus the flag)
#
# To go prompt-free, set up ONE persistent source. Keyring (recommended), once:
#   secret-tool store --label="paseo ansible vault" service ansible-vault key paseo
set -eu
here=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]; then
    printf '%s' "$ANSIBLE_VAULT_PASSWORD"
    exit 0
fi

if [ -r "$here/.vault_pass" ]; then
    cat "$here/.vault_pass"
    exit 0
fi

if command -v secret-tool >/dev/null 2>&1; then
    if pw=$(secret-tool lookup service ansible-vault key paseo 2>/dev/null) && [ -n "$pw" ]; then
        printf '%s' "$pw"
        exit 0
    fi
fi

# Last resort: prompt on the terminal (no echo). Works even when Ansible invokes us with a piped
# stdin, because we read straight from /dev/tty. Skipped in non-interactive contexts (CI).
if [ -r /dev/tty ]; then
    printf 'Vault password: ' > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    IFS= read -r _pw < /dev/tty || true
    stty echo < /dev/tty 2>/dev/null || true
    printf '\n' > /dev/tty
    if [ -n "${_pw:-}" ]; then
        printf '%s' "$_pw"
        exit 0
    fi
fi

echo "vault-pass: no vault password found (and no terminal to prompt). Use ONE of:" >&2
echo "  export ANSIBLE_VAULT_PASSWORD=...   (this shell only)" >&2
echo "  printf '%s' 'YOUR_PASS' > '$here/.vault_pass' && chmod 600 '$here/.vault_pass'" >&2
echo "  secret-tool store --label='paseo ansible vault' service ansible-vault key paseo" >&2
exit 1
