#!/usr/bin/env python3
"""Print OpenCode's effective config, merged from files, approximating OpenCode's own resolution.

Order (matches resolve-opencode-config.sh):
  * if $OPENCODE_CONFIG is set and exists -> that file IS the config (no layering)
  * else deep-merge the global config ($XDG_CONFIG_HOME/opencode/opencode.json[c],
    default ~/.config/opencode) with a project-local opencode.json[c] walked up from --cwd
    (if given); the project config wins on conflicts.

Parses .json and (tolerantly) .jsonc. Redacts secrets by default (bcrypt values + secret-ish keys);
use --raw to keep them. Pretty, key-sorted JSON to stdout; --explain lists contributing files on
stderr.

  opencode-effective-config.py [--cwd DIR] [--raw] [--explain]

NOTE: this is a FILE-level merge that approximates OpenCode's behavior. If exact semantics matter
for your build (array merge rules, env interpolation, precedence), verify against OpenCode's own
output such as `opencode mcp list`.
"""
import sys
import os
import json
import re
import argparse

BCRYPT = re.compile(r'^\$2[aby]\$\d{2}\$')
SECRET_KEYS = re.compile(r'(?i)(password|passwd|secret|token|apikey|api_key|bearer|credential)')
PLACEHOLDER = "<redacted>"


def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas, respecting string literals."""
    out = []
    i, n = 0, len(text)
    in_str = False
    quote = ''
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                in_str = False
            i += 1
            continue
        if c in '"\'':
            in_str = True
            quote = c
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    s = ''.join(out)
    return re.sub(r',(\s*[}\]])', r'\1', s)


def load(path):
    with open(path) as f:
        raw = f.read()
    if path.endswith('.jsonc'):
        raw = strip_jsonc(raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"opencode-effective-config: invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)


def deep_merge(a, b):
    out = dict(a)
    for k, v in b.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def redact(obj):
    if isinstance(obj, dict):
        return {k: (PLACEHOLDER if SECRET_KEYS.search(str(k)) else redact(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    if isinstance(obj, str) and BCRYPT.match(obj):
        return PLACEHOLDER
    return obj


def find_in(directory):
    for name in ('opencode.json', 'opencode.jsonc'):
        p = os.path.join(directory, name)
        if os.path.isfile(p):
            return p
    return None


def find_project(cwd):
    d = os.path.abspath(cwd)
    while True:
        p = find_in(d)
        if p:
            return p
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cwd', default='')
    ap.add_argument('--raw', action='store_true')
    ap.add_argument('--explain', action='store_true')
    args = ap.parse_args()

    home = os.environ.get('HOME')
    if not home:
        print('opencode-effective-config: HOME must be set', file=sys.stderr)
        sys.exit(2)
    xdg_config = os.environ.get('XDG_CONFIG_HOME', os.path.join(home, '.config'))

    sources = []
    oc_env = os.environ.get('OPENCODE_CONFIG')
    if oc_env and os.path.exists(oc_env):
        merged = load(oc_env)
        sources.append(f"{oc_env} (OPENCODE_CONFIG)")
    else:
        merged = {}
        gp = find_in(os.path.join(xdg_config, 'opencode'))
        if gp:
            merged = deep_merge(merged, load(gp))
            sources.append(gp + " (global)")
        if args.cwd:
            pp = find_project(args.cwd)
            if pp:
                merged = deep_merge(merged, load(pp))
                sources.append(pp + " (project, wins)")

    if args.explain:
        if sources:
            print("effective config merged from: " + ", ".join(sources), file=sys.stderr)
        else:
            print("no opencode config found; printing empty object", file=sys.stderr)

    if not args.raw:
        merged = redact(merged)
    print(json.dumps(merged, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
