# The ledger — format

Reference for §1 of [SKILL.md](SKILL.md). The rules that decide what you dispatch
live there; this is what the file looks like.

**One ledger per task, shared with [`spec-loop`](../spec-loop/SKILL.md)** — it
opens with the `## Спека` section written while the spec bundle was being completed,
and the waves are appended below it. Whichever loop gets there first creates the file.

## Creating it

```bash
mkdir -p worktrees/<task>/.build-loop
```

```markdown
# Build loop — task: <task> — change: <change-name>
Repos: <repo>, <repo>, <spec-repo>
Spec: worktrees/<task>/<spec-repo>/<spec-root>/openspec/changes/<change-name>/

## Спека (spec-loop, шаги 1–4)
- Изучение — analyst + architect параллельно; 7 вопросов после слияния
- Вопросы — заданы 5 блокирующих; ответы в change/proposal.md
- proposal.md — analyst
- delta-спеки — analyst; feasibility от architect: 2 находки (backfill,
  публикуемый контракт одного из репозиториев) → requirement R3 переписан
  аналитиком до закрытия пакета
- design.md + tasks.md — architect; coverage от analyst: чисто
- bundle (proposal + delta-спеки + design.md + tasks.md) — validate ok,
  cross-read и coverage закрыты
- ПАКЕТ ГОТОВ → build loop открыт

## План волн (из tasks.md `## Параллелизм`, после проверки — см. §2)
- Волна 1: G1 (<repo с публикуемым пакетом>)
- Волна 2: G2 (<repo>), G3 (<repo>) — параллельно
- Волна 3: G4 (<repo>) — зависит от G2
```

**Only the `ПАКЕТ ГОТОВ → build loop открыт` line licenses the build loop to start**, and only if it
names the bundle that was actually validated and cross-read. `openspec status`
says an artefact exists; nothing but this line says the bundle is complete. A legacy `УТВЕРЖДЁН` line
written before this rule change counts as the same marker on resume.

## Reading a half-finished wave off it

Resume **per group and per phase**. A `dispatched` line with no matching result is
that group's in-flight builder — `git -C worktrees/<task>/<repo> status/log` says
what actually landed in *its* paths, then continue it. One group mid-flight says
nothing about the others; a phase with every group complete and no matching review
line is your next dispatch. When a line is missing altogether, test files present
in a group's paths are the corroborating evidence for which phase it reached.

## Appending

One line after every agent returns, with the evidence. **Every line carries its
phase (`Ф1` / `Ф2`); a builder line also its group id, a review line its wave** —
with several builders in flight and two phases per wave, an unprefixed line cannot
be attributed after a compaction.

```markdown
### Волна 2 — G2 (<repo>), G3 (<repo2>) — параллельно
- Ф1 G2 builder — dispatched; Ф1 G3 builder — dispatched
- Ф1 G3 builder — complete — 4 файла; lint+build green, тестов нет (по регламенту)
- Ф1 G2 builder — complete — 7 файлов; lint+build green (см. package.json репозитория)
- Ф1 W2 ревью кода — 3 blocking, 2 should-fix, 1 nit (findings-w2-code.md)
- Ф1 W2 раунд 1 — G2+G3 resumed, все blocking → B1, B3 ADDRESSED; B2 NOT
- Ф1 W2 раунд 2 — G2 fresh/сильная модель → B2 ADDRESSED; ре-ревью чистое
- W2 ГЕЙТ (единственный в волне) — открытых blocking нет; S1+S2 показаны
- W2 решение — S1 править (G2), S2 declined («волна 3 перепишет»)
- W2 раунд решения — G2 resumed → S1 ADDRESSED; ре-ревью чистое
- Ф1 W2 ЗАКРЫТА — все находки фазы кода с исходом → фаза 2
- Ф2 G2 builder — dispatched; Ф2 G3 builder — dispatched
- Ф2 G3 builder — complete — 6 unit green; код не двигал
- Ф2 G2 builder — complete — 14 unit / 5 integration green; **код правил**:
  fee.ts:88 (integration поймал округление, ревью не увидело); e2e NOT RUN
  (не просили)
- Ф2 W2 ревью тестов — 2 should-fix (findings-w2-tests.md); SPEC: unaffected
- Ф2 W2 should-fix НЕ отдавались — S3 (про наборы), S4 (про КОД: fee.ts:88)
  → в закрывающий список, гейта в фазе 2 нет
- Ф2 W2 ЗАКРЫТА — blocking нет; волна 3 разблокирована
```

**A gate line and a decision line always come in pairs.** A `ГЕЙТ` line with no
`решение` after it is a wave waiting on the user, not a wave you may advance —
after a compaction that pair is the only thing that says whether the wave was
allowed into phase 2. Record the ruling itself, not "спросил": a `declined` you
cannot quote is a finding that comes back at the final review.

**One gate per wave, and it lives in phase 1.** A `ГЕЙТ` line under `Ф2` is a
mistake: that phase's Should-fix are recorded as *not dispatched*, carried to the
close, and marked `про наборы` or `про КОД` — the second kind means the user will
be ruling on touching already-reviewed code, and at the close nothing else says
so. Its surviving Blocking, by contrast, gets a line the moment it happens: it went
to the user out of band and the wave stopped.

**`код правил` in a phase-2 line is the metric of the whole arrangement** — it
says the code review passed something only execution caught. Never fold it into a
"green" summary; it is what §6 reports at the close.

Long findings go beside the ledger as `findings-w<N>-code.md` /
`findings-w<N>-tests.md` rather than into the line.
