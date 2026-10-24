#!/usr/bin/env python3
"""Stop-хук: не дать секрету уйти в ответ пользователю.

ЗАЧЕМ. `block-secret-reads.sh` стоит на ВХОДЕ: он разбирает команду Bash и
запрещает прочитать `.env` или напечатать secret-именованную переменную. Этого
мало, и это видно из чужого инцидента: токен попадает в транскрипт не только
через `.env`, но и через вывод обычной команды — `git remote -v` на чекауте,
чей origin содержит credentials, лог с заголовком Authorization, дамп конфига.
Таких путей больше, чем можно перечислить в списке READER, поэтому вторая
граница ставится не на чтении, а на ВЫХОДЕ: строка формата живого ключа не
уходит в тред.

ПРАВИЛО. Проверяется только последнее сообщение ассистента — то, что реально
увидит человек. Совпал формат вендорского ключа или credentials в URL — ответ
не отдаётся, агенту возвращается причина с НАЗВАНИЕМ типа ключа, но никогда с
самим фрагментом: `reason` дописывается в транскрипт, и секрет в нём означал бы
ровно ту утечку, которую хук предотвращает.

Что НЕ считается секретом намеренно: адреса, хеши транзакций, идентификаторы,
номера и любые числа. Хук смотрит на префиксные форматы вендоров и на
credentials в URL — то есть на формы, которые ни при каких обстоятельствах не
являются содержательной частью ответа.

ТОЛЬКО CLAUDE CODE. У Codex событие `Stop` есть, но даёт ли он `transcript_path`
и в какой форме — не проверено, а хук без транскрипта тихо пропускает всё. Такая
запись в `config.append.toml` создавала бы уверенность, которой нет, поэтому её
нет: подключать Codex имеет смысл вместе с тестом на его форму payload, как это
сделано у `block-secret-reads.sh`.

FAIL-OPEN. Любая ошибка чтения, разбора или доступа — пропускаем (exit 0). Гард
не имеет права сделать агента неотвечающим: цена молчания выше цены пропуска,
а вторая граница на входе всё равно стоит. Обратная полярность у тестов — см.
`--selftest`, который обязан падать громко.

Проверка: `agents/common/hooks/scan-outgoing-secrets.py --selftest`
"""

from __future__ import annotations

import json
import re
import sys

# Префиксные форматы секретов поддерживаемых интеграций.
PATTERNS = (
    ("Slack bot/user token", re.compile(r"\bxox[baprs]-[0-9A-Za-z\-]{10,}")),
    ("Slack app token", re.compile(r"\bxapp-[0-9]-[0-9A-Za-z\-]{10,}")),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9\-_]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{32,}")),
    ("GitHub token", re.compile(r"\b(?:ghp|gho|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}")),
    ("private key block", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("credentials in URL", re.compile(r"://[A-Za-z0-9_\-]+:[^\s/@\"']{8,}@")),
)

# Заглушки из документации и шаблонов. Два разных списка, и это не дублирование.
#
# В САМОМ фрагменте заглушку видно надёжно: `ghp_xxxxxxxx`, `YOUR_TOKEN_HERE`,
# `<token>`. Здесь можно позволить широкий список.
#
# В ОКНЕ вокруг фрагмента — только сильные документные слова. Широкий список в
# окне опасен: `...` или `xxx` в соседнем предложении обелили бы живой токен,
# а «вот токен: ghp_… (сокращено)» — это ровно та фраза, рядом с которой
# секрет и печатают.
#
# Порог `x{4,}` вместо `xxx`: три символа случайно встречаются в настоящем
# 32-символьном теле ключа примерно раз на десять тысяч, четыре — на миллион.
# Заглушки в документации пишут длинными сериями, им порог не мешает.
FRAGMENT_PLACEHOLDER = re.compile(
    r"(REDACTED|EXAMPLE|PLACEHOLDER|SAMPLE|DUMMY|FAKE|TEST[_\-]?(TOKEN|KEY)"
    r"|YOUR[_\-]?(TOKEN|KEY|SECRET|PAT)|HERE|x{4,}|<[^>]{3,}>)",
    re.I,
)
WINDOW_PLACEHOLDER = re.compile(
    r"(REDACTED|EXAMPLE|PLACEHOLDER|SAMPLE|DUMMY|FAKE"
    r"|YOUR[_\-]?(TOKEN|KEY|SECRET|PAT))",
    re.I,
)
WINDOW = 40


def scan(text: str) -> list[str]:
    """→ отсортированный список НАЗВАНИЙ найденных типов ключей. Без фрагментов."""
    if not text:
        return []
    labels = []
    for label, rx in PATTERNS:
        for m in rx.finditer(text):
            frag = m.group(0)
            around = text[max(0, m.start() - WINDOW):m.end() + WINDOW]
            if FRAGMENT_PLACEHOLDER.search(frag) or WINDOW_PLACEHOLDER.search(around):
                continue
            if label not in labels:
                labels.append(label)
            break
    return labels


def last_assistant_text(path: str) -> str:
    """Текст последнего сообщения ассистента — то, что увидит человек.

    Берётся последняя запись роли assistant, у которой есть блоки text:
    записи с одними tool_use наружу не уходят и проверять в них нечего.
    """
    found = ""
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get("message")
            if not isinstance(msg, dict) or msg.get("role") != "assistant":
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            chunks = [b.get("text", "") for b in content
                      if isinstance(b, dict) and b.get("type") == "text"]
            if chunks:
                found = "\n".join(chunks)
    return found


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    # Валидный JSON — ещё не ожидаемая форма: список или строка разбирается
    # без ошибки, а `.get` на них падает уже за пределами try. Пойман
    # guards-fail-open.test.py при первом же прогоне.
    if not isinstance(payload, dict):
        return 0
    # Хук уже держит этот ход — второй отказ превратил бы защиту в петлю.
    if payload.get("stop_hook_active"):
        return 0
    path = payload.get("transcript_path")
    if not path:
        return 0
    try:
        text = last_assistant_text(path)
    except Exception:
        return 0
    labels = scan(text)
    if not labels:
        return 0
    print(json.dumps({
        "decision": "block",
        "reason": (
            "В ответе строка формата живого ключа (" + ", ".join(labels) + "). "
            "Перепиши сообщение без неё: назови переменную по имени или скажи, "
            "что credential задан, не показывая значение. Сам фрагмент здесь не "
            "приводится намеренно."
        ),
    }, ensure_ascii=False))
    return 0


def selftest() -> int:
    """Образцы собираются из кусков во время работы.

    Литеральный токен в этом файле сделал бы сам файл тем, что хук обязан
    ловить: он лежит в репозитории, попадает в diff и в вывод grep, то есть
    ровно в те места, откуда секрет и утекает.
    """
    gl = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2"
    xo = "xoxb-" + "1234567890-0987654321-" + "aBcDeFgHiJkLmNoPqRsT"
    ant = "sk-ant-" + "api03-" + "R7kQ2mN8pL4vX1zB6tY3wC5jH9dF0sA"
    aws = "AKIA" + "QRSTUVWX1234ABCD"
    url = "postgres://user:" + "s3cretpassw0rd" + "@db.internal:5432/app"
    cases = [
        ("живой GitHub PAT", gl, ["GitHub token"]),
        ("живой Slack-токен", xo, ["Slack bot/user token"]),
        ("живой ключ Anthropic", ant, ["Anthropic key"]),
        ("живой AWS-ключ", aws, ["AWS access key"]),
        ("credentials в URL", url, ["credentials in URL"]),
        ("несколько сразу", gl + " и " + aws, ["GitHub token", "AWS access key"]),
        ("заглушка не секрет", "ghp_YOUR_TOKEN_HERE", []),
        ("плейсхолдер в самом фрагменте",
         "пример: " + gl.replace("A1b2C3d4E5f6G7h8I9j0K1l2", "xxxxxxxxxxxx"), []),
        ("слово EXAMPLE рядом обеляет", "EXAMPLE config: " + gl, []),
        ("многоточие рядом НЕ обеляет — так и печатают живой токен",
         "вот токен: " + gl + " (сокращено ...)", ["GitHub token"]),
        ("обычный ответ", "MR !36 открыт, пайплайн зелёный, 42 теста прошли", []),
        ("адрес и хеш не секрет",
         "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq, tx 0x9f2c" + "a" * 40, []),
        ("имя переменной без значения", "GITHUB_TOKEN задан в .env", []),
        ("пустой текст", "", []),
    ]
    bad = 0
    for name, text, want in cases:
        got = scan(text)
        if sorted(got) != sorted(want):
            print(f"  FAIL  {name}: ожидалось {want}, получено {got}")
            bad += 1
        else:
            print(f"  ok    {name}")

    # Фрагмент секрета не должен появляться в том, что хук печатает наружу.
    reason = json.dumps({"labels": scan(gl)}, ensure_ascii=False)
    if gl in reason:
        print("  FAIL  вывод хука содержит сам фрагмент")
        bad += 1
    else:
        print("  ok    вывод хука не содержит фрагмент")

    if bad:
        print(f"\nscan-outgoing-secrets: провалено проверок: {bad}")
        return 1
    print("\nSELFTEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
