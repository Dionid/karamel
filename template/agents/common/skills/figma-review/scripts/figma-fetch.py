#!/usr/bin/env python3
"""
figma-fetch.py — Download PNG/SVG renders of Figma nodes via Figma REST API.

Examples:
  ./figma-fetch.py --url 'https://figma.com/design/KEY/file?node-id=1-2' --out refs/
  ./figma-fetch.py --file-key KEY --node-ids 1:2,1:3 --out refs/ --scale 2
  ./figma-fetch.py --url ... --format svg --out icons/

Requires FIGMA_TOKEN in the workspace root .env (scope: File content
read-only; generate at https://www.figma.com/settings -> Personal access
tokens). Checked via env-check.sh so the value never has to be typed here.
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request


def load_env():
    """Load the workspace root .env into this process. FIGMA_TOKEN usually
    only lives in .env — env-check.sh only inspects that file, it never
    sources it, and telling the user to `export FIGMA_TOKEN=...` would mean
    typing the secret into a command line. Load it ourselves instead."""
    here = os.path.dirname(os.path.abspath(__file__))
    d = here
    while True:
        if os.path.exists(os.path.join(d, "harness.json")) or \
           os.path.exists(os.path.join(d, "workspace.json")):
            env_path = os.path.join(d, ".env")
            if os.path.exists(env_path):
                with open(env_path) as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        key, _, val = line.partition("=")
                        key = key.strip()
                        val = val.strip()
                        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                            val = val[1:-1]
                        os.environ.setdefault(key, val)
            return
        parent = os.path.dirname(d)
        if parent == d:
            return
        d = parent


def get_token():
    load_env()
    token = os.environ.get("FIGMA_TOKEN")
    if token:
        return token
    sys.exit(
        "FIGMA_TOKEN не задан — задай его в .env (см. env.example рядом с "
        "этим скиллом; проверить наличие можно через "
        ".claude/skills/env-check/env-check.sh FIGMA_TOKEN)."
    )


def parse_figma_url(url: str):
    """Extract (file_key, node_id) from a Figma URL.

    Accepts both `node-id=1-2` and `node-id=1:2` formats; returns colon form.
    """
    m = re.search(r'figma\.com/(?:design|file)/([^/?]+)', url)
    if not m:
        raise SystemExit(f'Cannot parse fileKey from URL: {url}')
    file_key = m.group(1)
    nm = re.search(r'node-id=([^&]+)', url)
    if not nm:
        raise SystemExit(f'No node-id= in URL: {url}')
    node_id = urllib.parse.unquote(nm.group(1)).replace('-', ':')
    return file_key, node_id


def call_figma(token: str, path: str):
    req = urllib.request.Request(
        f'https://api.figma.com{path}',
        headers={'X-Figma-Token': token},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--url', help='Figma URL (with node-id). Can be repeated.', action='append', default=[])
    p.add_argument('--file-key', help='Figma fileKey (use with --node-ids)')
    p.add_argument('--node-ids', help='Comma-separated node IDs (use with --file-key)')
    p.add_argument('--out', required=True, help='Output directory')
    p.add_argument('--scale', type=float, default=1.0, help='Render scale (1, 2, 3, 4); default 1')
    p.add_argument('--format', default='png', choices=['png', 'svg', 'jpg', 'pdf'])
    p.add_argument('--label', help='Optional label prefix for output filenames')
    args = p.parse_args()

    token = get_token()

    # Build (file_key, [node_ids]) pairs
    jobs = {}
    for u in args.url:
        fk, nid = parse_figma_url(u)
        jobs.setdefault(fk, []).append(nid)
    if args.file_key and args.node_ids:
        jobs.setdefault(args.file_key, []).extend(args.node_ids.split(','))
    if not jobs:
        sys.exit('Provide at least one --url or (--file-key + --node-ids)')

    os.makedirs(args.out, exist_ok=True)

    for file_key, node_ids in jobs.items():
        # De-dupe while preserving order
        seen = set()
        ids = [n for n in node_ids if not (n in seen or seen.add(n))]
        query = urllib.parse.urlencode({
            'ids': ','.join(ids),
            'format': args.format,
            'scale': args.scale,
        })
        data = call_figma(token, f'/v1/images/{file_key}?{query}')
        if data.get('err'):
            sys.exit(f'Figma API error for {file_key}: {data["err"]}')
        for nid, src in (data.get('images') or {}).items():
            if not src:
                print(f'  SKIP {nid} (null url — node may not be exportable)')
                continue
            safe = nid.replace(':', '_').replace(';', '-')
            scale_tag = '' if args.scale == 1 else f'@{int(args.scale)}x'
            base = (args.label + '-' if args.label else '') + safe
            fname = f'{base}{scale_tag}.{args.format}'
            path = os.path.join(args.out, fname)
            urllib.request.urlretrieve(src, path)
            print(f'  saved {path} ({os.path.getsize(path)} bytes)')


if __name__ == '__main__':
    main()
