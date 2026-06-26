#!/usr/bin/env python3
"""Redact secrets from a JSON document for safe export.

Reads JSON from a file argument (or stdin) and writes pretty, key-sorted JSON to stdout, replacing
bcrypt-looking string values and values under secret-ish keys with "<redacted>". Recurses through
nested objects and arrays. Intended for exporting paseo/opencode config without leaking the
password hash or inline credentials.

  redact-json.py [PATH] [--keys a,b,c]

  --keys   extra comma-separated key-name substrings to treat as secret (case-insensitive)

Exit 0 on success, 1 on invalid JSON, 2 on bad args.
"""
import sys
import json
import re
import argparse

BCRYPT = re.compile(r'^\$2[aby]\$\d{2}\$')
PLACEHOLDER = "<redacted>"
BASE_KEYS = ["password", "passwd", "secret", "token", "apikey", "api_key", "bearer", "credential"]


def redact(obj, key_re):
    if isinstance(obj, dict):
        return {k: (PLACEHOLDER if key_re.search(str(k)) else redact(v, key_re))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(x, key_re) for x in obj]
    if isinstance(obj, str) and BCRYPT.match(obj):
        return PLACEHOLDER
    return obj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", help="JSON file (default: stdin)")
    ap.add_argument("--keys", default="", help="extra comma-separated secret key substrings")
    args = ap.parse_args()

    raw = open(args.path).read() if args.path else sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"redact-json: invalid JSON ({args.path or 'stdin'}): {e}", file=sys.stderr)
        sys.exit(1)

    keys = BASE_KEYS + [k.strip() for k in args.keys.split(",") if k.strip()]
    key_re = re.compile("(?i)(" + "|".join(re.escape(k) for k in keys) + ")")
    print(json.dumps(redact(data, key_re), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
