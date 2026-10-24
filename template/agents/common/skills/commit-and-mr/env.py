#!/usr/bin/env python3
"""Read selected dotenv assignments as literal data; never execute .env code."""
import json
import re
import shlex
import sys
from pathlib import Path


def load(path, names):
    values = {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, sep, raw = line.partition("=")
        name = name.strip()
        if not sep or name not in names:
            continue
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ValueError(f"invalid variable name at line {number}")
        raw = raw.strip()
        # shlex removes literal quotes/comments but never expands variables,
        # command substitution, redirections, or backticks.
        lexer = shlex.shlex(raw, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        parts = list(lexer)
        if len(parts) > 1:
            raise ValueError(f"quote whitespace in dotenv assignment at line {number}")
        value = parts[0] if parts else ""
        if "\0" in value or "\n" in value or "\r" in value:
            raise ValueError(f"invalid dotenv value at line {number}")
        values[name] = value
    return values


if __name__ == "__main__":
    try:
        print(json.dumps(load(sys.argv[1], set(sys.argv[2:]))))
    except (OSError, ValueError) as error:
        # Do not include exception text: malformed values may carry credentials.
        print("error: cannot parse selected root .env assignments", file=sys.stderr)
        sys.exit(1)
