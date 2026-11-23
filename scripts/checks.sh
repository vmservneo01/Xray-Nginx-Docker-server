#!/usr/bin/env bash
set -u
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
failed=0

check() {
    local label="$1"; shift
    printf '\n[CHECK] %s\n' "$label"
    if "$@"; then
        echo "[OK] $label"
    else
        echo "[FAIL] $label"
        failed=1
    fi
}

command -v docker >/dev/null 2>&1 || { echo "[FAIL] Docker не установлен"; exit 1; }
docker info >/dev/null 2>&1 || { echo "[FAIL] Docker daemon недоступен (запустите с правами, имеющими доступ к Docker)"; exit 1; }

check "Docker Compose config" docker compose -f docker-compose.yaml config -q
check "Файл generated-values.env и права 600" bash -c 'test -f secrets/generated-values.env && test "$(stat -c %a secrets/generated-values.env)" = 600'
check "Сгенерированный Xray JSON" python3 -c 'import json; json.load(open("xray/config.json", encoding="utf-8"))'
check "TLS сертификат" test -s certs/server.crt
check "TLS приватный ключ" test -s certs/server.key

printf '\n[INFO] Состояние контейнеров:\n'
docker compose -f docker-compose.yaml ps
if docker compose -f docker-compose.yaml ps --status running --services | grep -qx xray; then
    check "Проверка Xray config в контейнере" docker compose -f docker-compose.yaml exec -T xray xray run -test -config /etc/xray/config.json
else
    echo "[WARN] Xray не запущен; проверка внутри контейнера пропущена."
fi
if docker compose -f docker-compose.yaml ps --status running --services | grep -qx nginx; then
    check "Проверка Nginx config в контейнере" docker compose -f docker-compose.yaml exec -T nginx nginx -t
else
    echo "[WARN] Nginx не запущен; проверка внутри контейнера пропущена."
fi

printf '\n'
if [[ "$failed" -eq 0 ]]; then
    echo "Проверки завершены: критических ошибок не обнаружено."
else
    echo "Проверки завершены: есть ошибки, см. строки [FAIL]."
fi
exit "$failed"
