#!/bin/sh
# resolve-opencode-config.sh — print the effective OpenCode config path for the current user.
#
# Resolution order (highest precedence first), mirroring how OpenCode locates its config:
#   1. $OPENCODE_CONFIG            explicit override, used as-is if it exists
#   2. project-local opencode.json[c], found by walking up from --cwd   (only if --cwd given)
#   3. $XDG_CONFIG_HOME/opencode/opencode.json[c]   (default ~/.config/opencode)
# If none exists, prints the DEFAULT path where a global config would live, unless --existing-only.
#
# Usage:
#   resolve-opencode-config.sh [--cwd DIR] [--existing-only] [--explain]
#   resolve-opencode-config.sh --data            # print the data/creds dir instead
#
# Honors HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, OPENCODE_CONFIG.
# Exit 0 with a path on stdout; exit 1 if --existing-only and nothing found; exit 2 on bad args.
set -eu

want_data=0
existing_only=0
explain=0
cwd=""

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
        --data)          want_data=1 ;;
        --existing-only) existing_only=1 ;;
        --explain)       explain=1 ;;
        --cwd)           cwd="${1:-}"; [ $# -gt 0 ] && shift || true ;;
        --cwd=*)         cwd="${arg#--cwd=}" ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

log() { [ "$explain" -eq 1 ] && echo "resolve-opencode-config: $*" >&2 || true; }

: "${HOME:?HOME must be set}"
xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"

# --data: just print the creds/data dir
if [ "$want_data" -eq 1 ]; then
    d="$xdg_data/opencode"
    log "data/creds dir = $d"
    printf '%s\n' "$d"
    exit 0
fi

# 1. explicit env override
if [ -n "${OPENCODE_CONFIG:-}" ]; then
    if [ -e "$OPENCODE_CONFIG" ]; then
        log "OPENCODE_CONFIG=$OPENCODE_CONFIG (exists) -> using it"
        printf '%s\n' "$OPENCODE_CONFIG"
        exit 0
    fi
    log "OPENCODE_CONFIG=$OPENCODE_CONFIG is set but missing; falling through"
fi

# 2. project-local, walking up from --cwd
if [ -n "$cwd" ]; then
    dir="$cwd"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        for name in opencode.json opencode.jsonc; do
            if [ -f "$dir/$name" ]; then
                log "found project config $dir/$name"
                printf '%s\n' "$dir/$name"
                exit 0
            fi
        done
        dir=$(dirname "$dir")
    done
    for name in opencode.json opencode.jsonc; do
        [ -f "/$name" ] && { log "found project config /$name"; printf '%s\n' "/$name"; exit 0; }
    done
    log "no project-local config under $cwd"
fi

# 3. global XDG config
for name in opencode.json opencode.jsonc; do
    cand="$xdg_config/opencode/$name"
    if [ -f "$cand" ]; then
        log "found global config $cand"
        printf '%s\n' "$cand"
        exit 0
    fi
done

# nothing exists
default="$xdg_config/opencode/opencode.json"
if [ "$existing_only" -eq 1 ]; then
    log "no config found and --existing-only set -> exit 1"
    exit 1
fi
log "no config found -> default would-be path $default"
printf '%s\n' "$default"
exit 0
