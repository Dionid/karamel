# Dispatch prompts

Fill the placeholders and pass the result as the `Agent` tool's `prompt`. Each
agent's own instructions live in [`../../roles/`](../../roles/) — these
templates carry only what is task-specific.

Placeholders:

- `{TASK}` — the task name, i.e. the directory under `worktrees/`
- `{CHANGE}` — the OpenSpec change name
- `{REPOS}` — the repos this task touches, comma-separated
- `{SPEC_REPO}` / `{SPEC_ROOT}` — see [spec-loop/SKILL.md](../spec-loop/SKILL.md) §0
- `{WAVE}` — the wave number from `tasks.md`'s `## Параллелизм` table
- `{ROUND}` — the fix round number (1, 2 or 3)
- `{GROUP}` — the task group id from the same table (`G2`)
- `{PATHS}` — that group's paths from the same table
- `{AGENT_PATH}` — the writing agent's ledger path (`agentPath`)
- `{CHECKOUT}` — the group builder's disposable checkout, printed by `writer.py spawn`
  (see [agent-directed-routing](../agent-directed-routing/SKILL.md)); every
  builder dispatch below is a write-capable child, so it never receives the
  canonical `worktrees/{TASK}/<repo>` to write in

Each wave runs in two phases — **code, review, fixes; then tests, review, fixes**
— so every template below belongs to one of them. The phase order and the gate
between them are in [SKILL.md](SKILL.md); these are only the prompts.

**Never interpolate one agent's summary into another's prompt.** Anything they
need to know, they read from the worktree. That includes sideways: a builder
working group `G3` is never told what `G2`'s builder did.

Builder prompts are emitted only after the `ПАКЕТ ГОТОВ → build loop открыт` line has been
recorded in the ledger for the current tasks.md. A capacity note about who *could* build something
is not permission to create work before that line.

## Scoping a prompt to a group

When the change has a `## Параллелизм` table, add this block to the builder
prompts, right after the `Repos in this task:` line. Without a table there is one
group and nothing to add.

```text
Твоя группа: {GROUP} — только она.
Репозиторий группы: <repo>       # единственный, который ты трогаешь
Пути группы: {PATHS}
Твой checkout: {CHECKOUT}        # одноразовая копия <repo>; пишешь только в ней
Задачи группы: раздел `### {GROUP}` в tasks.md — остальные группы игнорируй,
их ведут другие агенты параллельно с тобой, прямо сейчас, каждый в своём
checkout.

Не выходи за пути группы и за {CHECKOUT}: результат вернётся parent'у патчем и
будет сверен с зарезервированными путями, файл вне них отклоняет весь патч. Нужен
файл снаружи — не правь его: назови его, объясни зачем, и остановись на этом
пункте. Не коммить в {CHECKOUT}. Тесты чужой группы тоже не запускай.
```

Before dispatching the wave, for each group run `writer.py spawn` (scope =
`{PATHS}`, `--parent-scope` = the same group paths), then `start` after the
`Agent` call returns a launch, and after the builder's final result `submit` and
`integrate` it into `worktrees/{TASK}/<repo>`. Groups' scopes are disjoint by the
wave plan, so every spawn succeeds and the builders run concurrently; a refused
spawn means the plan is wrong — fix the plan, do not fall back to a shared
checkout. A group whose patch fails to integrate is reported with its `failedHop`
and recovery bundle; it is not retried automatically.

---

## builder — phase 1, the code

One per group, all of a wave's builders dispatched in the same message.

```text
subagent_type: builder
role: builder
minimum tier/effort: balanced/medium
```

Непосредственный parent выбирает конкретную комбинацию из tracked catalog,
оставаясь не ниже минимума роли из `agent-directed-routing`. Секция группы
должна быть самодостаточной (поля и значения в пункте, не ссылкой на
`design.md`) и открываться строкой `**Образец:**` с примерами из репозитория.

```bash
sed -n '/^#\{2,3\} {GROUP} /,/^#\{2,3\} /p' \
  worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/tasks.md
```

Если секция не самодостаточна или в ней нет образцов, верните её архитектору
для уточнения до dispatch; не компенсируйте пробел произвольным выбором роли,
tier или effort.

Фаза 2 на слабой модели не идёт никогда — см. её раздел ниже.

```text
Фаза 1 — код. Реализуй change `{CHANGE}`; твой рабочий checkout репозитория группы — {CHECKOUT}
(остальной worktree `worktrees/{TASK}/` читай, не пиши).
Тесты в этой фазе НЕ пишутся.
Эта карточка существует потому что пакет спеки уже отмечен в ledger строкой `ПАКЕТ ГОТОВ → build loop открыт`;
не создавай дополнительных builder cards/processes и не расширяй wave scope.

Repos in this task: {REPOS}
Spec artifacts: worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/
Work list: that directory's tasks.md
Требования, которым должен соответствовать код: that directory's specs/

Read the code and the spec yourself — the spec through `.claude/skills/openspec-read/`
if this repository has that skill, otherwise directly with `openspec show`/`openspec status` —
a MODIFIED delta amends specs/<capability>/spec.md, it does not replace it. Two
steps, in order:

1. implement the tasks;
2. run each touched repo's lint, typecheck/compile and build (read that repo's
   own package.json/Makefile/README for the real command names), and fix what
   they report.

НИ ОДНОГО ТЕСТА В ЭТОЙ ФАЗЕ: ни spec-файла, ни тестового конфига, ни CI-джобы,
ни placeholder'а с describe.skip. Следом идёт ревью кода, и оно должно читать
реализацию, а не диф наполовину из тестов. Если какое-то место, по-твоему,
невозможно обосновать без теста — напиши это в отчёте и назови место; тест всё
равно не пиши.

Тесты ты напишешь во второй фазе, после того как ревью закроется. Поэтому не
подгоняй реализацию под будущие тесты и не оставляй заглушек «под тест».

Report red as red and a checker you could not run as "not run" — a read-only
reviewer reads all of it after you.

No commits, no pushes.
```

---

## builder — phase 2, the tests

After the code review has closed: no Blocking open, and the user has ruled on
every Should-fix (§4b of [SKILL.md](SKILL.md)). Resume each group's phase-1
builder with `SendMessage` where it survives; spawn a fresh one only where it does
not. All groups of the wave in one message. Each dispatch gets a **new**
`writer.py spawn` — a fresh checkout cut from the canonical tree that already
contains the integrated phase-1 code and its fixes; a resumed builder is told the
new `{CHECKOUT}` and that the old one is gone.

```text
subagent_type: builder        # only when the phase-1 agent is gone
role: builder
minimum tier/effort: balanced/medium
```

Фаза 2 требует вывести, какой тест
покраснеет, если код перестанет выполнять требование, и отличить неверный код
от неверного теста на красном прогоне. Списка, который это заменяет, не
существует — `tasks.md` говорит, что покрыть, но не чем именно. Resume
пережившего фазу 1 агента по `SendMessage` этого не нарушает: `SendMessage`
продолжает агента на его собственной модели, а на слабой модели фаза 1 шла
только там, где проверка выше разрешила, — поэтому такую группу в фазе 2
диспатчат **свежим** агентом на модели определения, а не резюмят.

```text
Фаза 2 — тесты. Твой checkout: {CHECKOUT} (свежий снимок с уже
интегрированным кодом фазы 1; пишешь только в нём, не коммить).
Ревью кода по волне {WAVE} закрыто: Blocking закрыты, по
Should-fix пользователь решил, что правим, и это тоже сделано. Теперь покрой
свою группу тестами.

Требования, которые должны утверждать тесты:
worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/specs/

Реализация уже прочитана независимым ревьюером и сверена со спекой — поэтому
писать тесты, глядя на код, здесь законно: он и есть проверенный артефакт.
НО ожидаемые значения берутся из требования, а не из прогона. Тест, в котором
expected списан с того, что вернул код, — это не тест, и следующее ревью
нацелено ровно на это.

Напиши и прогони те слои, которые есть в репозитории (читай его собственный
package.json/README за реальными командами): unit и integration.
E2E — только если пункты твоей группы в tasks.md просят об этом по имени; если
не просят, не пиши ничего (ни spec, ни конфиг, ни CI job). Если в этом
репозитории есть отдельный e2e-скилл, следуй ему, когда e2e действительно
запрошен.

Проверь каждое требование контрфактически: какой тест покраснеет, если код
перестанет его выполнять? Нет ответа — покрытия нет.

Красный тест означает, что неверно ОДНО из двух — код или тест. Выяснить какое
и есть работа. Если неверен код, правь код (его пропустило ревью — так бывает,
статическое чтение не запускает запросы и не применяет миграции) и отдельно
назови это в отчёте: файл, что поймал тест, что изменил. Если неверен тест —
правь тест и назови требование, которое он должен был утверждать. Не выгибай
проверенный код под свежую ассерцию.

Report red as red and a suite you could not run as "not run".

No commits, no pushes.
```

---

## reviewer — code pass

Once per wave, after **every** phase-1 builder in it has returned. Scope it to the
wave's paths — list every group of the wave, not one.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Review wave {WAVE} of change `{CHANGE}` in `worktrees/{TASK}/` — branch commits
and uncommitted work under the paths below. This is the CODE pass.

Spec: worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/

Groups in this wave, built in parallel by agents that could not see each other:
- {GROUP}: <repo> — {PATHS}
- {GROUP}: <repo> — {PATHS}

There are no tests in this diff, and that is deliberate — they are written only
after this review closes. So your whole budget goes on one question: does this
code do what the change says it does? Read the delta specs first and the
code second, requirement by requirement — through `.claude/skills/openspec-read/`
if this repository has that skill, so a MODIFIED block is read as an amendment to
specs/<capability>/spec.md rather than as the whole requirement.

Nothing here has been executed either. Lint and a compiler prove the code parses
and type-checks — not that a query runs, a dependency is wired, a migration
applies, or the data is shaped the way the code assumes. Raise defects of that
kind on inspection where you can trace them in the code; where you cannot, label
it a question rather than a finding.

Look hardest at the seam between the groups: a contract one side produces and
another consumes differently, the same logic written twice, a spec requirement
that fell between them.

Use the worktree-review skill. Read the diff and the surrounding code yourself.
Rank findings defect-first, each with path:line, the input that produces the
wrong result, and what the right result is; group them by the group whose paths
they sit in. Do not pad the list. A defect outside these paths belongs to a later
wave — name it and move on.

Severity decides who acts, so label it deliberately: **Blocking goes back to the
builder automatically; Should-fix goes to the user, who decides whether it is
worth changing; below that is reported and ships as it is.** A Should-fix is
therefore read by someone who is not reading the code — state the failure it
causes and what it costs to fix, not just the line it sits on.

If a test file turns up in this diff, review it and say so — the phase split was
not respected.

The spec was written before this code. Code that diverges from the
change's spec is a finding for the user to rule on — do not edit the spec into
agreement with it. Write nothing at all; end with the SPEC: line.
```

---

## reviewer — test pass

Once per wave, after **every** phase-2 builder in it has returned. Same paths as
the code pass.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Review the TESTS of wave {WAVE} of change `{CHANGE}` in `worktrees/{TASK}/`.

Spec: worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/
Groups and paths:
- {GROUP}: <repo> — {PATHS}
- {GROUP}: <repo> — {PATHS}

The implementation already passed a code review against this spec, and the tests
were written afterwards, from that reviewed code. That is what makes them worth
reviewing separately: a suite written against code tends to agree with the code
whether or not the code matches the requirement.

Your question is one thing: do these suites assert the SPEC, or do they merely
agree with the CODE? Concretely —
- an expected value copied off a run instead of derived from the requirement;
- an assertion aimed at an internal call, a mock's arguments or a private shape
  rather than observable behaviour;
- a delta-spec requirement with no test that would go red if the code stopped
  honouring it — name the requirement, not just the gap;
- a test that still passes with the feature removed or the assertion deleted;
- happy path only: no error case, no boundary, no empty result, no duplicate;
- a suite skipped, .only'd or narrowed to stay green;
- an integration test that stubs the very thing it exists to exercise.

Do NOT re-open the implementation — except here, which you must review as
unreviewed code, because it changed after the code pass:
<files the phase-2 builders reported as code fixes, from git diff — or "none">

Use the worktree-review skill. Rank findings defect-first with path:line and the
concrete failure. Blocking goes back to the builders automatically; Should-fix
goes to the user at the close of the whole change, not now — so write it to be
legible without the code in front of you, and say for each whether it is about the
suites or about the implementation. Read-only — write nothing. The SPEC ruling was made on the code pass: repeat it
only if the code above moved behaviour, otherwise end with
"SPEC: unaffected — ruled on the code pass".
```

---

## reviewer — final full pass

Once, after the last wave's test pass, on a change with **two or more** waves. A
single-wave change is already covered by its two wave passes — don't run this a
third time over the same code. **No path scope** — this is the only pass that sees
the change as a whole, code and tests together in a single review.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Review everything in `worktrees/{TASK}/` — every repo with a checkout there,
branch commits and uncommitted work.

Change under review: {CHANGE}
Spec: worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/

This change was built wave by wave, and each wave was reviewed only within its
own paths. Look hardest at what no single wave could see: a contract an early
wave defined and a later one consumed differently, a spec requirement that fell
between waves, the same logic implemented twice in two repos.

Code and tests both exist now, so this is one pass over both. On the tests, the
question is the one the per-wave test passes asked inside their own paths: does a
suite assert the requirement, or does it merely agree with the code it was written
from? A cross-wave requirement that no group's suite would catch is exactly the
gap this pass is for.

Use the worktree-review skill. Read the diff and the surrounding code yourself.
Rank findings defect-first, each with path:line and the concrete failure it
causes. Blocking goes back to the builders automatically; Should-fix goes to the
user to rule on. Read-only — do not fix anything.

Findings the user already ruled on at an earlier wave's gate are recorded in
`worktrees/{TASK}/.build-loop/progress.md` — read it, and do not re-file one that
was declined there. If you think a declined finding is worse than the ruling
assumed, say so once, naming the ledger line.

The spec was written before this code. Code that diverges from the
change's spec is a finding for the user to rule on — do not edit the spec into
agreement with it. Write nothing at all; end with the SPEC: line.
```

---

## reviewer — scoped re-review after a fix round

One per round, in either phase, covering **every** group's findings from that
round. Not the whole wave again.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Fix round <{ROUND}|решения> of the <code|test> phase for change `{CHANGE}` in
`worktrees/{TASK}/` is done. Verify these findings specifically — nothing else:

1. [Blocking] {GROUP} <repo> path/to/file.ts:LINE — <the finding as originally written>
2. [Should-fix] {GROUP} <repo> path/to/file.ts:LINE — <…, only in a decision round>

For each: read the current code at that location and say ADDRESSED,
NOT ADDRESSED, or ADDRESSED BUT INTRODUCES <new problem>, with the evidence.
Where the fix came with a test, say whether that test would actually fail
against the old code.

Report any new defect the fix itself introduced. Do not open a general review
and do not raise unrelated findings. Read-only — no SPEC: ruling on a re-review,
it was made on the code pass.
```

---

## reviewer — closing pass for a small change built without a spec

**Not part of the build loop's wave/phase machinery**, and used instead of it: a
small change made without going through `spec-loop` writes its tests alongside
the code and gets one review over both. The two-phase order buys review quality
at the cost of extra dispatches and barriers, which is worth it for a wave of
parallel agents and not for one change in one context.

Such a change ends with one of these, before `commit-and-mr` — the whole review
of the change, and the only place its spec impact is ever judged. Skip the agent
entirely on a diff you can read in a minute and run `worktree-review` inline
instead.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Review everything in `worktrees/{TASK}/`: every repo with a checkout there,
branch commits and uncommitted work. There is no spec for this change and no
other reviewer; you are the whole review.

What was asked for: <the user's request, in one or two lines>

Use the worktree-review skill. Read the diff and the surrounding code yourself —
the person who wrote it is the same one dispatching you, so nothing in this
prompt is evidence. Rank findings defect-first, each with path:line, the input
that produces the wrong result, and what the right result is.

Then rule on the spec, per your agent instructions: unaffected, drift (edit
specs/<capability>/spec.md), or unspecified (create the OpenSpec change from the
code that exists). A brand new capability you propose rather than write. The
`openspec/` directory under {CHECKOUT}/{SPEC_ROOT}/ is the only thing you may
write — `{CHECKOUT}` being the disposable checkout of `{SPEC_REPO}` this prompt
names (`writer.py spawn` it first; agentPath {AGENT_PATH}); no checkout named, you
write nothing. Never the code you just reviewed. End with the
SPEC: line and list what you wrote.
```

---

## analyst — read-only study for an infrastructure-only fix

The opening dispatch when a change touches only deploy/CI/monitoring
plumbing — CI/CD config, a container build file, a Helm/Kustomize/Terraform
manifest, an alert rule — and no business logic. Read-only: findings and at most
1-2 blocking questions, no proposal, no delta spec, nothing written.

```text
subagent_type: analyst
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Infrastructure study — worktrees/{TASK}/, repos: {REPOS}. Infrastructure only, not
business code: <what's broken or being asked for, in one or two lines>.

If this workspace has a skill that maps repos to their deploy mechanism (which
repo owns this element, and which of the deploy tools in use here — a
container/werf-style build, Helm, Kustomize, Terraform, or something else —
governs it), start there. Then read the element itself, its CI history (through
whatever this workspace uses to read GitHub/CI, if anything), and live state
through a read-only Kubernetes/logs skill where the fix depends on it, if this
workspace has one.

This is a findings-and-questions-only study — nothing written, no proposal.md, no
delta spec. Report СЕГОДНЯ (what exists now, the deploy mechanism, root cause if
this is a bug) and at most 1-2 blocking questions; anything non-blocking comes
with the default you would assume.
```

---

## reviewer — closing pass for an infrastructure-only fix

Same shape as the closing pass for a small change above — one review, no
phases — but the second question is a durable-decision ruling, not a spec ruling:
an infrastructure-only fix never touches `{SPEC_REPO}`/OpenSpec.

```text
subagent_type: reviewer
minimum tier/effort: strong/high (see agent-directed-routing)
fork_turns: none
```

```text
Review everything in `worktrees/{TASK}/`: repos {REPOS}, branch commits and
uncommitted work. No spec applies to this change; you are the whole review.

What was asked for: <the user's request, in one or two lines>

Use the worktree-review skill. Read the diff yourself — verify it against
whatever this workspace's own tooling offers for the deploy mechanism involved
(a lint/template/validate/dry-run command for the tool in use), not just by
reading. Rank findings defect-first, each with path:line, the input that produces
the wrong result, and what the right result is.

Then rule on the decision: does this represent a durable decision about how this
team does infrastructure (a new deploy mechanism for something that didn't have
one, a rule about secrets, a convention for scheduled jobs or worker manifests)
rather than a one-off fix? None → say so in one line. A decision → draft it in
your report, in the shape a `<knowledge-root>/decisions/DEC-NNN.md` entry takes if this
manifest resolves that directory through the knowledge skill — do not write the file yourself: recording it
needs a task checkout of the manifest-owned knowledge repository, which your prompt does not
give you, and that is the orchestrator's step, after your review closes. End
with the DECISION: line.
```

---

## builder — fix round 1 (resume, do not re-dispatch)

Either phase. Continue the same agent with `SendMessage`; it already has the code
in context. One message per affected group, all of them sent together, each
carrying that group's **whole Blocking** list — Should-fix is not dispatched here
at all, it waits for the user's ruling at the gate.

```text
Ревью <кода|тестов> волны {WAVE} вернуло по твоей группе эти Blocking — все,
одним раундом. Твой новый checkout: {CHECKOUT} (прежний удалён после
интеграции; пишешь только в новом, не коммить):

1. [Blocking] path/to/file.ts:LINE — <finding, and the concrete failure>
2. [Blocking] path/to/file.ts:LINE — <…>

Fix exactly these. Do not refactor around them and do not touch anything the
list does not name. Re-run the affected checkers — and in the test phase the
affected suites — and report their real output.

В фазе кода тесты по-прежнему не пишутся: если находка про недостающее покрытие,
это ошибка ревью, скажи об этом и не пиши тест.

Раундов всего три, этот первый. Закрывай список целиком, а не лёгкую половину.
Если считаешь находку неверной — скажи с технической причиной и кодом, который
это доказывает, вместо того чтобы что-то менять.
```

---

## builder — fix round 2 (fresh agent, stronger model)

```text
subagent_type: builder
role: builder
minimum tier/effort: strong/high for fix rounds 2 and 3
```

```text
Change `{CHANGE}`, group {GROUP}, фаза <кода|тестов>. Your checkout: {CHECKOUT}
(write only there, never commit; read the rest of `worktrees/{TASK}/`).
These findings survived fix round 1:

1. <finding, path:line, and the concrete failure>
2. <…>

Already tried, and did not work:
- round 1: <what was changed, and why it did not resolve the finding>

Read the code fresh — the previous attempt is context for what to avoid, not a
description of the current state. Есть ещё один раунд после этого, и на нём
цикл закрывается.

Re-run the affected checkers and suites and report their real output.
```

---

## builder — fix round 3 (fresh agent, last one)

```text
subagent_type: builder
role: builder
minimum tier/effort: strong/high for fix rounds 2 and 3
```

```text
Change `{CHANGE}`, group {GROUP}, фаза <кода|тестов>. Your checkout: {CHECKOUT}
(write only there, never commit; read the rest of `worktrees/{TASK}/`).
These findings survived two fix rounds:

1. <finding, path:line, and the concrete failure>
2. <…>

Already tried, and did not work:
- round 1: <what was changed, and why it did not resolve the finding>
- round 2: <what was changed, and why it did not resolve the finding>

Read the code fresh — both previous attempts are context for what to avoid, not a
description of the current state.

Это последний раунд. Дальше раунда нет: всё, что останется открытым, уходит к
пользователю как BLOCKED, и волны за этой встают. Поэтому если находка не
закрывается без изменения дизайна или спеки — НЕ продавливай её.
Назови структурное препятствие: какое требование или какая граница мешает, что
пришлось бы поменять, и почему это решение не твоё. Такой ответ полезнее
обходного пути, который прячет проблему, и именно он попадёт пользователю.

Re-run the affected checkers and suites and report their real output.
```

---

## builder — the decision round (what the user picked at the gate)

**A separate budget from R1–R3**, dispatched once after the wave's ruling gate
(§4b of [SKILL.md](SKILL.md)) — or after the closing ruling ([close.md](close.md)),
which works the same way — and closed by one scoped re-review. Resume each affected
group's builder; only the findings the user picked.

```text
По волне {WAVE}, фаза <кода|тестов>: пользователь разобрал список находок и
решил править вот эти. Только их:

1. [Should-fix] path/to/file.ts:LINE — <finding, and the concrete failure>
2. [<severity>] path/to/file.ts:LINE — <…>

Остальные находки по твоей группе он посмотрел и **править не стал** — это его
решение, а не недосмотр: не трогай их и не «заодно почини». Если какая-то из
этих правок задевает то, что он отклонил, скажи об этом и остановись, а не
решай сам.

Раунд один: второй автоматической попытки по этому списку нет, всё
незакрывшееся уходит обратно к пользователю. Поэтому находку, которую нельзя
закрыть без изменения дизайна, назови структурным препятствием, а
не продавливай.

Re-run the affected checkers — and in the test phase the affected suites — and
report their real output.
```
