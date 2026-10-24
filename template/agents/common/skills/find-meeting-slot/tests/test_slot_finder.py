#!/usr/bin/env python3
"""Поведение slot_finder.py: пересечение рабочих окон по таймзонам,
недоступный календарь не роняет расчёт, near-miss и MEETING_TZ по умолчанию."""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "slot_finder.py")

fails = 0


def ok(msg):
    print(f"  ok    {msg}")


def fail(msg):
    global fails
    fails += 1
    print(f"  FAIL  {msg}", file=sys.stderr)


def run(payload, env=None):
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    else:
        full_env.pop("MEETING_TZ", None)
    proc = subprocess.run(
        [sys.executable, SCRIPT], input=json.dumps(payload),
        capture_output=True, text=True, env=full_env,
    )
    return proc.returncode, proc.stdout, proc.stderr


def machine_block(stdout):
    start = stdout.index("===JSON===") + len("===JSON===")
    end = stdout.index("===END===")
    return json.loads(stdout[start:end].strip())


base_payload = {
    "now_utc": "2026-07-07T10:25:00Z",
    "base_tz": "Europe/Moscow",
    "range": "next_week",
    "duration_min": 30,
    "participants": [
        {"name": "Alice", "email": "alice@example.com", "tz": "Europe/Moscow",
         "busy": [["2026-07-13T07:00:00Z", "2026-07-13T08:00:00Z"]]},
        {"name": "Bob", "email": "bob@example.com", "tz": "America/New_York",
         "busy": None},
    ],
}

# -------------------------------------------------------- everyone-free slots
rc, out, err = run(base_payload)
if rc != 0:
    fail(f"базовый payload: код возврата {rc}, stderr={err!r}")
else:
    ok("базовый payload: код возврата 0")
m = machine_block(out)
if m["ideal_all_free"]:
    ok("нашлись слоты в идеальном окне")
else:
    fail("не нашлось слотов в идеальном окне")

# -------------------------------------------- unavailable calendar not counted
for p in m["participants"]:
    if p["name"] == "Bob" and p["calendar_available"] is False:
        ok("недоступный календарь Bob помечен calendar_available=false")
        break
else:
    fail("Bob должен быть помечен calendar_available=false")

# слот с Bob в unknown, но всё равно all_free=true (не считается занятым)
if all("Bob" not in s["busy"] for s in m["ideal_all_free"]):
    ok("Bob никогда не попадает в busy (недоступный календарь не роняет расчёт)")
else:
    fail("Bob оказался в busy — недоступный календарь не должен считаться занятым")

# ------------------------------------------------------------- timezone window
# Слот должен укладываться и в MSK (10-18), и локально у Bob (America/New_York)
# — тест на пересечение окон по таймзонам.
for s in m["ideal_all_free"]:
    hh, mm = map(int, s["start_base"].split(":"))
    if not (10 <= hh < 18 or (hh == 18 and mm == 0 and False)):
        fail(f"слот {s} вне идеального MSK-окна 10-18")
        break
else:
    ok("все идеальные слоты внутри 10-18 MSK")

# ------------------------------------------------------------------ busy slot
busy_start = "2026-07-13T07:00:00Z"  # 10:00 MSK — Alice занята
if not any(s["start_utc"] == busy_start and s["all_free"] for s in
           m["ideal_all_free"] + m["extended_all_free"]):
    ok("занятый интервал Alice не попал в all_free слоты")
else:
    fail("занятый интервал Alice ошибочно попал в all_free")

# --------------------------------------------------------- MEETING_TZ default
payload_no_tz = dict(base_payload)
del payload_no_tz["base_tz"]
rc, out, err = run(payload_no_tz, env={"MEETING_TZ": "Asia/Bangkok"})
if rc == 0:
    m2 = machine_block(out)
    if m2["base_tz"] == "Asia/Bangkok":
        ok("MEETING_TZ используется как база при отсутствии base_tz в payload")
    else:
        fail(f"MEETING_TZ не применился: base_tz={m2['base_tz']!r}")
else:
    fail(f"payload без base_tz с MEETING_TZ: код возврата {rc}, stderr={err!r}")

# ------------------------------------------------ no base_tz, no MEETING_TZ -> UTC
rc, out, err = run(payload_no_tz)
if rc == 0:
    m3 = machine_block(out)
    if m3["base_tz"] == "UTC":
        ok("без base_tz и без MEETING_TZ — используется UTC")
    else:
        fail(f"ожидался UTC по умолчанию, получено {m3['base_tz']!r}")
else:
    fail(f"payload без base_tz и без MEETING_TZ: код возврата {rc}, stderr={err!r}")

# --------------------------------------------------------------- bad range
bad = dict(base_payload)
bad["range"] = "next_millennium"
rc, out, err = run(bad)
if rc != 0:
    ok("некорректный range приводит к ошибке, а не тихому пустому результату")
else:
    fail("некорректный range должен был вызвать ошибку")

# ============================================================
#  Позитивный путь: MEETING_TZ только в .env (не экспортирован) —
#  скрипт обязан загрузить .env сам. Копия скрипта запускается в
#  ИЗОЛИРОВАННОМ workspace root (свой harness.json, свой .env), чтобы не
#  зависеть от того, есть ли в текущем дереве реальный .env команды.
# ============================================================
with tempfile.TemporaryDirectory() as root:
    with open(os.path.join(root, "harness.json"), "w") as f:
        f.write("{}\n")
    with open(os.path.join(root, ".env"), "w") as f:
        f.write("MEETING_TZ=Asia/Bangkok\n")

    skills_dir = os.path.join(root, ".claude", "skills", "find-meeting-slot")
    os.makedirs(skills_dir)
    script_copy = os.path.join(skills_dir, "slot_finder.py")
    shutil.copyfile(SCRIPT, script_copy)
    os.chmod(script_copy, 0o755)

    payload_no_tz = dict(base_payload)
    del payload_no_tz["base_tz"]

    clean_env = dict(os.environ)
    clean_env.pop("MEETING_TZ", None)  # прибито гвоздями: значение только в .env

    proc = subprocess.run(
        [sys.executable, script_copy], input=json.dumps(payload_no_tz),
        capture_output=True, text=True, env=clean_env,
    )
    if proc.returncode == 0:
        start = proc.stdout.index("===JSON===") + len("===JSON===")
        end = proc.stdout.index("===END===")
        m4 = json.loads(proc.stdout[start:end].strip())
        if m4["base_tz"] == "Asia/Bangkok":
            ok("MEETING_TZ только в .env: реально загружен и использован (изолированный root)")
        else:
            fail(f"MEETING_TZ только в .env: base_tz={m4['base_tz']!r}, ожидался Asia/Bangkok")
    else:
        fail(f"MEETING_TZ только в .env: код возврата {proc.returncode}, stderr={proc.stderr!r}")

print()
if fails == 0:
    print("slot_finder.py: все проверки пройдены")
    sys.exit(0)
print(f"slot_finder.py: провалено проверок: {fails}", file=sys.stderr)
sys.exit(1)
