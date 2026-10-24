#!/usr/bin/env python3
"""Redact configured GitHub credentials from CLI output, including failures."""
import os
import re
import sys

values = {os.environ.get(name, "") for name in ("GITHUB_TOKEN", "GH_TOKEN")}
for line in sys.stdin:
    for value in sorted(values - {""}, key=len, reverse=True):
        line = line.replace(value, "<redacted>")
    line = re.sub(r"(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+", "<redacted>", line)
    sys.stdout.write(line)
