#!/usr/bin/env python3
"""Сквозная проверка block-local-integration-tests.py: integration/e2e — только в CI.

Хук смотрит на ИСПОЛНЯЕМУЮ команду, а не на текст, поэтому у него две
противоположные ошибки, и обе дорогие:

  * пропуск: `cd x && npx nx run api:e2e` или `docker compose exec api pytest
    tests/integration` уходит локально, а гард выглядит рабочим;
  * ложный отказ: `rg e2e`, сообщение коммита со словом integration или
    `vitest run src/integration_utils.test.ts` заблокированы — и гард снимают
    целиком.

Каждый случай гоняется во всех трёх формах payload, которые шлют агенты:
Claude Code (snake_case, строка), Codex (camelCase, строка) и Codex с argv
`["bash", "-lc", cmd]`. Вердикт обязан совпадать во всех трёх.

    python3 agents/common/tests/block-local-integration-tests.test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "block-local-integration-tests.py"
SWITCH = "WORKSPACE_ALLOW_LOCAL_INTEGRATION"

BLOCK = [
    # пакетные менеджеры
    "npm run test:integration",
    "npm run test:e2e",
    "npm run e2e",
    "npm run test:e2e:ci",
    "npm run-script integration",
    "npm --prefix api run test:e2e",
    "yarn test:e2e",
    "yarn run e2e",
    "yarn workspace api test:integration",
    "pnpm test:e2e",
    "pnpm run e2e",
    "pnpm --filter api run test:integration",
    "pnpm -r run e2e",
    "npm test -- tests/integration",
    # pytest
    "pytest -m integration",
    'pytest -m "integration and not slow"',
    'pytest -m "unit or e2e"',
    "pytest tests/integration/",
    "pytest tests/integration/test_api.py::test_ok",
    "pytest -q integration_tests",
    "pytest tests/test_integration.py",
    "python -m pytest -m integration",
    "python3 -m pytest tests/e2e",
    "uv run pytest tests/integration",
    "poetry run pytest -m integration",
    'pytest -m "integration(db)"',
    # jest / vitest
    "jest --config jest.e2e.config.js",
    "npx jest --config test/jest-e2e.json",
    "npx jest e2e/login.spec.ts",
    "vitest run --config vitest.integration.config.ts",
    "vitest run tests/integration",
    "vitest run --project e2e",
    "npx vitest run src/app.e2e.ts",
    "jest test/app.e2e-spec.ts",
    "pnpm exec jest src/foo.integration.test.ts",
    # go
    "go test -tags integration ./...",
    "go test -tags=integration,foo ./...",
    "go test -run Integration ./...",
    "go test -run 'TestE2E.*' ./...",
    "go test ./integration/...",
    "go test ./pkg/foo/foo_integration_test.go",
    "gotestsum --format dots -- -tags integration ./...",
    # playwright / cypress
    "playwright test",
    "npx playwright test",
    "yarn playwright test --project chromium",
    "cypress run",
    "npx cypress open",
    # nx
    "nx run api:e2e",
    "npx nx run api-e2e:e2e:ci",
    "nx e2e api",
    "nx api:e2e",
    "nx run-many -t e2e",
    "nx run-many --targets=lint,e2e",
    "nx affected -t e2e",
    "nx affected:e2e",
    "pnpm nx run api:e2e",
    # составные команды и обёртки
    "cd api && npm run test:e2e",
    "npm ci; npm run e2e",
    "false || npm run e2e",
    "npm run e2e | tee log.txt",
    "echo $(npm run e2e)",
    'echo "result: $(go test -tags integration ./...)"',
    "echo `npm run e2e`",
    "npm run lint\nnpm run test:e2e",
    "(cd api && npm run e2e)",
    "CI=1 npm run e2e",
    "env CI=1 npm run e2e",
    "sudo -u app npm run e2e",
    "timeout 600 npm run e2e",
    "timeout -s KILL 10m npm run e2e",
    "nice -n 10 npm run e2e",
    "command npm run e2e",
    "nohup npm run e2e > out.log 2>&1 &",
    "bash -c 'npm run e2e'",
    'sh -c "cd api && pytest tests/integration"',
    "bash -lc 'go test -run Integration ./...'",
    "eval 'npm run e2e'",
    "bash <<'EOF'\nnpm run e2e\nEOF",
    "if npm run e2e; then echo ok; fi",
    # контейнеры
    "docker exec -it api npm run test:e2e",
    "docker exec -e CI=1 -w /app api pytest tests/integration",
    "docker compose exec api pytest -m integration",
    "docker compose -f dev.yml exec -T api sh -c 'npm run e2e'",
    "docker compose run --rm api go test -tags integration ./...",
    "docker-compose exec api npm run e2e",
    "podman exec api npm run e2e",
    "kubectl exec -it pod-1 -c app -- go test -run Integration ./...",
    "kubectl -n dev exec pod-1 -- npm run test:e2e",
    # выключатель в самой команде не выключает
    f"{SWITCH}=1 npm run e2e",
]

ALLOW = [
    # unit
    "npm test",
    "npm run test",
    "npm run test:unit",
    "yarn test",
    "pnpm test",
    "pytest",
    "pytest tests/unit",
    'pytest -m "not integration"',
    'pytest -m "not (integration or e2e)"',
    "pytest --ignore=tests/integration",
    "pytest --ignore tests/integration tests",
    "pytest tests/unit > integration/log.txt",
    "go test ./...",
    "go test -run TestParse ./...",
    "go test -skip Integration ./...",
    "go test -c -tags integration ./...",
    "vitest run src/integration_utils.test.ts",
    "jest src/integrations/foo.test.ts",
    "vitest run",
    "jest --config jest.config.js",
    "nx run api:test",
    "nx run api:build",
    "nx run api-e2e:build",
    "nx run-many -t lint test",
    "nx affected -t build",
    "nx graph",
    "pnpm install --filter e2e",
    "yarn add -D e2e-utils",
    "pnpm build e2e",
    # сборка/lint/typecheck e2e — не прогон
    "npm run e2e:build",
    "npm run build:e2e",
    "npm run lint:e2e",
    "npm run typecheck:e2e",
    "pnpm run e2e:typecheck",
    # сбор/листинг
    "pytest --collect-only tests/integration",
    "pytest --co -m integration",
    "jest --listTests --config jest.e2e.config.js",
    "vitest list tests/integration",
    "playwright test --list",
    "npx playwright install chromium",
    "cypress verify",
    # текст, а не запуск
    "rg 'npm run e2e' .",
    "rg -n 'pytest -m integration' docs",
    "grep -r test:e2e package.json",
    "echo npm run e2e",
    "echo 'go test -tags integration ./...'",
    'git commit -m "run pytest -m integration in CI only"',
    "git commit -F - <<'EOF'\nnpm run e2e locally is forbidden\nEOF",
    "cat <<EOF > notes.md\nnx run api:e2e\nEOF",
    "printf '%s\\n' 'playwright test'",
    "ls tests/integration",
    "cat tests/e2e/login.spec.ts",
    "# npm run e2e\nnpm test",
    "command -v playwright",
    "ssh ci-runner 'npm run e2e'",
    "docker compose up -d",
    "docker exec api ls tests/integration",
    "kubectl exec pod-1 -- cat /app/e2e.log",
    "git log --grep=e2e",
]


def shapes(cmd: str) -> dict[str, dict]:
    return {
        "claude snake+str": {"tool_name": "Bash", "tool_input": {"command": cmd}},
        "codex camel+str": {"toolName": "shell", "toolInput": {"command": cmd}},
        "codex camel+argv": {"toolName": "shell",
                             "toolInput": {"command": ["bash", "-lc", cmd]}},
    }


def clean_env(**extra: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k != SWITCH}
    env.update(extra)
    return env


def run(stdin: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([str(HOOK)], input=stdin, capture_output=True, text=True,
                          env=env or clean_env(), timeout=30)


def denied(proc: subprocess.CompletedProcess) -> bool:
    out = proc.stdout.strip()
    if not out:
        return False
    try:
        spec = json.loads(out).get("hookSpecificOutput") or {}
    except ValueError:
        return False
    return spec.get("permissionDecision") == "deny"


def main() -> int:
    failures = 0
    checked = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures, checked
        checked += 1
        if ok:
            print(f"  ok    {name}")
        else:
            failures += 1
            print(f"  FAIL  {name}{(' — ' + detail) if detail else ''}")

    check("хук исполняемый", bool(HOOK.stat().st_mode & 0o111))

    for want, cases in ((True, BLOCK), (False, ALLOW)):
        for cmd in cases:
            for shape, payload in shapes(cmd).items():
                p = run(json.dumps(payload))
                ok = p.returncode == 0 and denied(p) == want
                verdict = "блок" if want else "пропуск"
                check(f"{verdict} [{shape}] {cmd!r}", ok,
                      f"exit={p.returncode} stdout={p.stdout[:160]!r}")

    # Причина отказа говорит, что делать и что писать в отчёте.
    p = run(json.dumps(shapes("nx run api:e2e")["claude snake+str"]))
    reason = (json.loads(p.stdout or "{}").get("hookSpecificOutput") or {}) \
        .get("permissionDecisionReason", "")
    check("причина называет CI и выключатель", "CI" in reason and SWITCH in reason, reason)
    check("причина просит «integration не запускались локально»",
          "integration не запускались локально" in reason, reason)

    # Субагент блокируется так же, как root.
    payload = dict(shapes("go test -run Integration ./...")["claude snake+str"],
                   agent_id="sub-1", agent_type="worker")
    check("субагент тоже блокируется", denied(run(json.dumps(payload))))

    # Выключатель — только окружение процесса хука и только `1`.
    cmd = json.dumps(shapes("npm run test:e2e")["claude snake+str"])
    check(f"{SWITCH}=1 в окружении снимает отказ",
          not denied(run(cmd, clean_env(**{SWITCH: "1"}))))
    check(f"{SWITCH}=0 не снимает отказ", denied(run(cmd, clean_env(**{SWITCH: "0"}))))

    # Не shell-инструмент не трогается, даже с похожим полем.
    check("не shell-инструмент — пропуск",
          not denied(run(json.dumps({"tool_name": "Read",
                                     "tool_input": {"command": "npm run e2e"}}))))
    check("codex exec_command с полем cmd — блок",
          denied(run(json.dumps({"toolName": "exec_command",
                                 "toolInput": {"cmd": "npm run e2e"}}))))

    # Fail-open: всё непонятное — exit 0 без вывода.
    garbage = ("", "не json", "{}", "[1, 2]", '{"tool_input": null}',
               '{"tool_name": "Bash", "tool_input": {"command": 42}}',
               '{"tool_name": "Bash", "tool_input": {"command": ["npm", 1]}}',
               '{"tool_name": "Bash", "tool_input": {"command": "npm run \\"e2e"}}',
               '{"tool_name": "Bash", "tool_input": {"command": "pytest -m \\"integration(\\""}}',
               '{"tool_name": "Bash", "tool_input": {"command": "$(((("}}',
               '{"tool_name": "Bash"')
    for raw in garbage:
        p = run(raw)
        if raw.startswith('{"tool_name": "Bash", "tool_input": {"command": "npm run'):
            ok = p.returncode == 0  # битая кавычка: решение любое, но без падения
        elif "integration(" in raw:
            ok = p.returncode == 0
        else:
            ok = p.returncode == 0 and not p.stdout.strip()
        check(f"fail-open {raw[:50]!r}", ok, f"exit={p.returncode} out={p.stdout[:80]!r}")

    if failures:
        print(f"\n  {failures} из {checked} проверок провалено")
        return 1
    print(f"\n  {checked} проверок пройдено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
