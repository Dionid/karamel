#!/usr/bin/env python3
"""Detect Whisper repetition loops in a recording's meta.json, plus recovery
windows.

Why this exists instead of a manual check. "Group segments by minute and
count unique texts" LIES and reports "no loops": recordings from Superwhisper-
style tools carry `segments` word-by-word (~0.5s each), so any minute has
many unique one-word texts even inside a loop, and the repeated phrase as a
whole never fits in a single segment — a grep over segments won't find it.

The correct approach is to look for repeated n-grams in the JOINED text and
map the character offset back to segment time.

Usage:
  python3 scripts/transcript-loop-check.py <path-to-meta.json> [--rms] [--wav <path>]

  # or, given TRANSCRIPTS_DIR and a recording id whose folder holds meta.json:
  python3 scripts/transcript-loop-check.py <recording-id> [--rms]

Exit code 1 if at least one loop window contains real speech (or its RMS
could not be ruled out); 0 if no loop was found, or all loop windows were
silence.
"""

import json
import math
import os
import struct
import subprocess
import sys
from collections import Counter

NGRAM = 6           # phrase length in words
MIN_REPEATS = 4      # this many repeats already counts as a loop
SPEECH_DB = -46.0    # above this threshold in a window = speech, not silence


def load_env():
    """Load the workspace root .env into this process, the same way
    env-check.sh finds the root — TRANSCRIPTS_DIR usually only lives in
    .env, and nothing else loads it into our environment for us."""
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


load_env()


def resolve_meta_path(arg):
    if os.path.isfile(arg):
        return arg
    if os.path.isdir(arg):
        cand = os.path.join(arg, "meta.json")
        if os.path.isfile(cand):
            return cand
    base = os.environ.get("TRANSCRIPTS_DIR")
    if base:
        cand = os.path.join(base, arg, "meta.json")
        if os.path.isfile(cand):
            return cand
    return None


def load(path):
    with open(path) as f:
        return json.load(f)


def offset_map(segs):
    """[(start_off, end_off, start_s, end_s)] against ' '.join(texts)."""
    out, pos = [], 0
    for s in segs:
        t = s.get("text", "")
        out.append((pos, pos + len(t), s.get("start"), s.get("end")))
        pos += len(t) + 1
    return out


def time_at(omap, off):
    for a, b, st, en in omap:
        if a <= off <= b:
            return st, en
    return None, None


def rms_db(path, start, dur):
    if not path or not os.path.exists(path):
        return None
    try:
        p = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(start),
             "-t", str(dur), "-i", path, "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
            capture_output=True)
    except FileNotFoundError:
        print("ffmpeg не найден в PATH — RMS не снять", file=sys.stderr)
        return None
    n = len(p.stdout) // 2
    if n == 0:
        return None
    vals = struct.unpack("<%dh" % n, p.stdout[:n * 2])
    ms = sum(v * v for v in vals) / n
    if ms <= 0:
        return -120.0
    return 20 * math.log10(math.sqrt(ms) / 32768.0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_rms = "--rms" in sys.argv
    wav_override = None
    if "--wav" in sys.argv:
        i = sys.argv.index("--wav")
        wav_override = sys.argv[i + 1] if i + 1 < len(sys.argv) else None

    if not args:
        print(__doc__)
        return 2

    meta_path = resolve_meta_path(args[0])
    if not meta_path:
        print(f"не нашёл meta.json для '{args[0]}' — передай путь к файлу/папке, "
              f"или задай TRANSCRIPTS_DIR и передай id записи", file=sys.stderr)
        return 2

    d = load(meta_path)
    segs = d.get("segments") or []
    dur = d.get("duration", 0) / 1000
    if not segs:
        print(f"{meta_path}: segments пусты — проверять нечего (duration={dur:.0f}s)")
        return 0

    joined = " ".join(s.get("text", "") for s in segs)
    omap = offset_map(segs)
    words = joined.split()

    grams = Counter()
    for i in range(len(words) - NGRAM):
        grams[" ".join(words[i:i + NGRAM])] += 1
    suspects = [(g, c) for g, c in grams.items() if c >= MIN_REPEATS]

    print(f"=== {meta_path}: {dur/60:.1f} мин, {len(segs)} сегментов, "
          f"{len(joined)} симв (segments пословные: "
          f"{'да' if len(segs)/max(dur,1) > 1.2 else 'нет'}) ===")
    if not suspects:
        print("петель не найдено")
        return 0

    suspects.sort(key=lambda x: -x[1])

    raw_win = []
    for gram, cnt in suspects:
        first = joined.find(gram)
        last = joined.rfind(gram)
        st, _ = time_at(omap, first)
        _, en = time_at(omap, last + len(gram))
        if st is None or en is None:
            continue
        raw_win.append((st, en, cnt, gram))

    raw_win.sort()
    windows = []
    for st, en, cnt, gram in raw_win:
        if windows and st <= windows[-1][1] + 2:
            pst, pen, pcnt, pgram = windows[-1]
            windows[-1] = (pst, max(pen, en), max(pcnt, cnt),
                           pgram if pcnt >= cnt else gram)
        else:
            windows.append((st, en, cnt, gram))

    for st, en, cnt, gram in windows:
        print(f"\nпетля x{cnt}: «{gram[:70]}»")
        print(f"  окно {st:.0f}-{en:.0f} с ({st/60:.1f}-{en/60:.1f} мин), "
              f"длительность {en-st:.0f} с")

    if not want_rms:
        print("\nдобавь --rms [--wav <путь>], чтобы понять, речь там была или тишина")
        return 1 if windows else 0

    wav = wav_override or os.path.join(os.path.dirname(meta_path), "output.wav")
    if not os.path.exists(wav):
        print(f"\nwav отсутствует ({wav}) — RMS не снять, "
              f"восстановление невозможно, пометить пропуск в артефакте")
        return 1

    print("\n=== RMS по окнам ===")
    speech = []
    for st, en, cnt, _ in windows:
        r = rms_db(wav, st, max(en - st, 2))
        if r is None:
            print(f"  {st:.0f}-{en:.0f} с: RMS не снят")
            continue
        is_speech = r > SPEECH_DB
        print(f"  {st:.0f}-{en:.0f} с: {r:6.1f} dBFS -> "
              f"{'РЕЧЬ, догонять локальной транскрипцией' if is_speech else 'тишина, потери нет'}")
        if is_speech:
            speech.append((st, en))

    if speech:
        print("\n=== окна на восстановление ===")
        for st, en in speech:
            a = max(0, st - 6)
            t = (en - st) + 12
            print(f"  ffmpeg -y -ss {a:.0f} -t {t:.0f} -i {wav} /tmp/loop_{int(st)}.wav")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
