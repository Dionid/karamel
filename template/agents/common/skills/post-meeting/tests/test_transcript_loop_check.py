#!/usr/bin/env python3
"""Поведение transcript-loop-check.py на синтетических данных: находит петлю
по n-граммам в склеенном тексте, не по группировке пословных сегментов
по минутам (тот способ ложно отчитывается «петель нет» — см. docstring
скрипта)."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "transcript-loop-check.py")

fails = 0


def ok(msg):
    print(f"  ok    {msg}")


def fail(msg):
    global fails
    fails += 1
    print(f"  FAIL  {msg}", file=sys.stderr)


def make_segments(words_with_times):
    return [{"text": w, "start": s, "end": e} for (w, s, e) in words_with_times]


def run(meta, extra_args=None):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "meta.json")
        with open(p, "w") as f:
            json.dump(meta, f)
        cmd = [sys.executable, SCRIPT, p] + (extra_args or [])
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr


# ---------------------------------------------------------------- no segments
rc, out = run({"segments": [], "duration": 60000})
if rc == 0 and "segments пусты" in out:
    ok("пустые segments: код 0, честное сообщение")
else:
    fail(f"пустые segments: неожиданно rc={rc} out={out!r}")

# --------------------------------------------------------- no loop, clean text
words = "мы обсудили план на следующий квартал и решили двигаться дальше".split()
segs = make_segments([(w, i * 0.5, i * 0.5 + 0.5) for i, w in enumerate(words)])
rc, out = run({"segments": segs, "duration": len(words) * 0.5 * 1000})
if rc == 0 and "петель не найдено" in out:
    ok("чистый текст без повторов: петель не найдено")
else:
    fail(f"чистый текст: неожиданно rc={rc} out={out!r}")

# ------------------------------------------------------------- real loop found
# Одна и та же 6-словная фраза повторяется 10 раз подряд — ровно тот сценарий,
# который поминутная группировка пословных сегментов пропускает.
loop_phrase = "и конечно я думаю что".split()
loop_words = []
for _ in range(10):
    loop_words.extend(loop_phrase)
all_words = "начало записи здесь".split() + loop_words + "конец записи здесь".split()
segs = make_segments([(w, i * 0.5, i * 0.5 + 0.5) for i, w in enumerate(all_words)])
rc, out = run({"segments": segs, "duration": len(all_words) * 0.5 * 1000})
if rc == 1 and "петля" in out:
    ok("повторяющаяся фраза x10: найдена петля, код возврата 1")
else:
    fail(f"повторяющаяся фраза: не нашёл петлю, rc={rc} out={out!r}")

# --------------------------------------------------------- unresolvable target
proc = subprocess.run([sys.executable, SCRIPT, "/no/such/path-or-id"], capture_output=True, text=True)
if proc.returncode == 2 and "не нашёл meta.json" in (proc.stdout + proc.stderr):
    ok("несуществующий путь/id: честный отказ, код 2")
else:
    fail(f"несуществующий путь/id: неожиданно rc={proc.returncode} out={proc.stdout+proc.stderr!r}")

# ---------------------------------------------------------------------- usage
proc = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True)
if proc.returncode == 2:
    ok("без аргументов: код возврата 2")
else:
    fail(f"без аргументов: ожидался код 2, получен {proc.returncode}")

# ============================================================
#  Позитивный путь: TRANSCRIPTS_DIR только в .env (не экспортирован) —
#  скрипт обязан загрузить .env сам, а не полагаться на вызывающего.
#  Копия скрипта запускается в ИЗОЛИРОВАННОМ workspace root (свой
#  harness.json, свой .env), чтобы не задеть настоящий .env этой команды.
# ============================================================
with tempfile.TemporaryDirectory() as root:
    with open(os.path.join(root, "harness.json"), "w") as f:
        f.write("{}\n")

    recordings_dir = os.path.join(root, "recordings")
    rec_id = "1234567890"
    os.makedirs(os.path.join(recordings_dir, rec_id))
    with open(os.path.join(recordings_dir, rec_id, "meta.json"), "w") as f:
        json.dump({"segments": [], "duration": 5000}, f)

    with open(os.path.join(root, ".env"), "w") as f:
        f.write(f"TRANSCRIPTS_DIR={recordings_dir}\n")

    skills_dir = os.path.join(root, ".claude", "skills", "post-meeting", "scripts")
    os.makedirs(skills_dir)
    script_copy = os.path.join(skills_dir, "transcript-loop-check.py")
    with open(SCRIPT) as src, open(script_copy, "w") as dst:
        dst.write(src.read())
    os.chmod(script_copy, 0o755)

    env = dict(os.environ)
    env.pop("TRANSCRIPTS_DIR", None)  # прибито гвоздями: значение только в .env
    proc = subprocess.run(
        [sys.executable, script_copy, rec_id], capture_output=True, text=True, env=env,
    )
    if proc.returncode == 0 and "segments пусты" in (proc.stdout + proc.stderr):
        ok("TRANSCRIPTS_DIR только в .env: id записи резолвится, .env реально загружен")
    else:
        fail(
            "TRANSCRIPTS_DIR только в .env: id не резолвился — "
            f"rc={proc.returncode} out={proc.stdout + proc.stderr!r}"
        )

print()
if fails == 0:
    print("transcript-loop-check.py: все проверки пройдены")
    sys.exit(0)
print(f"transcript-loop-check.py: провалено проверок: {fails}", file=sys.stderr)
sys.exit(1)
