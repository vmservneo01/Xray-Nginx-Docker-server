#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

python3 - "$PROJECT_DIR" <<'PY'
import json
import os
import re
import secrets
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
env_file = root / "secrets/generated-values.env"
xray_template = root / "xray/config.json.template"
nginx_template = root / "nginx/nginx.conf.template"
xray_output = root / "xray/config.json"
nginx_output = root / "nginx/nginx.conf"

for path in (env_file, xray_template, nginx_template):
    if not path.is_file():
        raise SystemExit(f"Не найден обязательный файл: {path.relative_to(root)}")

if env_file.stat().st_mode & 0o077:
    raise SystemExit("ОШИБКА: generated-values.env доступен группе или другим пользователям. Нужны права 600.")

values = {}
for line_no, line in enumerate(env_file.read_text(encoding="utf-8").splitlines(), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"Некорректная строка в generated-values.env: {line_no}")
    key, value = line.split("=", 1)
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
        raise SystemExit(f"Некорректное имя переменной в строке {line_no}")
    if key in values:
        raise SystemExit(f"Повторяющееся имя переменной: {key}")
    if not value or any(c.isspace() for c in value):
        raise SystemExit(f"Пустое или некорректное значение переменной: {key}")
    values[key] = value

new_values = {}
for key in ("WS_PATH", "XHTTP_PATH", "XHTTP_REALITY_PATH"):
    if key not in values:
        new_values[key] = "/" + secrets.token_hex(20)

if new_values:
    with env_file.open("a", encoding="utf-8") as f:
        for key, value in new_values.items():
            f.write(f"{key}={value}\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(env_file, 0o600)
    values.update(new_values)

required_target_values = ("REALITY_DEST", "REALITY_SNI")
missing_target_values = [key for key in required_target_values if key not in values]
if missing_target_values:
    raise SystemExit("Сначала запустите scripts/select-reality-target.py; отсутствуют: " +
                     ", ".join(missing_target_values))

templates = {
    xray_output: xray_template.read_text(encoding="utf-8"),
    nginx_output: nginx_template.read_text(encoding="utf-8"),
}
placeholder_re = re.compile(r"__([A-Z][A-Z0-9_]*)__")
rendered = {}

for output, content in templates.items():
    names = set(placeholder_re.findall(content))
    missing = sorted(name for name in names if name not in values)
    if missing:
        raise SystemExit(
            f"В шаблоне {output.relative_to(root)} нет значений для: " + ", ".join(missing)
        )
    result = placeholder_re.sub(lambda m: values[m.group(1)], content)
    if placeholder_re.search(result):
        raise SystemExit(f"В {output.relative_to(root)} остались незаполненные заполнители.")
    rendered[output] = result

try:
    json.loads(rendered[xray_output])
except json.JSONDecodeError as e:
    raise SystemExit(
        f"Ошибка JSON в шаблоне Xray: строка {e.lineno}, столбец {e.colno}: {e.msg}"
    )

stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
for output in rendered:
    if output.exists():
        backup = output.with_name(output.name + ".bak." + stamp)
        shutil.copy2(output, backup)
        os.chmod(backup, 0o600)
        print(f"Резервная копия: {backup.relative_to(root)}")

for output, content in rendered.items():
    fd, temp_name = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, output)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

print("Конфигурации созданы.")
print("JSON Xray: проверка пройдена.")
print("Секретные значения не выводились.")
PY
