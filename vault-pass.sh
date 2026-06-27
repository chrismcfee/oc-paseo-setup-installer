#!/bin/sh
# vault-pass.sh — resolve the Ansible Vault password so you never type --ask-vault-pass.
# Wired in via ansible.cfg (vault_password_file = ./vault-pass.sh). Ansible runs this for EVERY
# command (eagerly) and requires a NON-EMPTY password, so set up ONE source below before running
# anything from this repo. This script holds NO secret — it only *fetches* one.
#
# Provide the password via ONE of (first hit wins):
#   1. $ANSIBLE_VAULT_PASSWORD          export it for a shell/session or CI
#   2. ./.vault_pass                    a 0600 file you create (gitignored)
#   3. system keyring via secret-tool   most secure — store it once (recommended):
#        secret-tool store --label="paseo ansible vault" service ansible-vault key paseo
# (Or pass --ask-vault-pass on a one-off run; that overrides this file.)
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

echo "vault-pass.sh: no vault password source set up. Do ONE of these once, then re-run:" >&2
echo "  secret-tool store --label='paseo ansible vault' service ansible-vault key paseo   # keyring" >&2
echo "  export ANSIBLE_VAULT_PASSWORD=...                                                  # session" >&2
echo "  printf %s 'YOUR_PASS' > '$here/.vault_pass' && chmod 600 '$here/.vault_pass'        # file" >&2
echo "(or pass --ask-vault-pass for a one-off run. Vault-less commands: prefix ANSIBLE_VAULT_PASSWORD=x)" >&2
exit 1
