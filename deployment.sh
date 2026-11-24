#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR="/opt/Xray-Nginx-Docker-server"

log() {
    printf '\n[INFO] %s\n' "$1"
}

fail() {
    printf '\n[ERROR] %s\n' "$1" >&2
    exit 1
}

if [[ "$EUID" -ne 0 ]]; then
    fail "Запусти сценарий так: sudo bash deployment.sh"
fi

if [[ "$PROJECT_DIR" != "$EXPECTED_DIR" ]]; then
    fail "Проект должен находиться в $EXPECTED_DIR. Текущий путь: $PROJECT_DIR"
fi

for file in \
    scripts/create-keys-and-cert.sh \
    scripts/select-reality-target.py \
    scripts/build-configs.sh \
    scripts/generate-client-profiles.py \
    docker-compose.yaml
do
    [[ -f "$PROJECT_DIR/$file" ]] || fail "Не найден файл: $file"
done

# Определяем владельца файлов проекта.
OWNER="${PROJECT_OWNER:-${SUDO_USER:-root}}"

id "$OWNER" >/dev/null 2>&1 ||
    fail "Пользователь $OWNER не найден."

OWNER_GROUP="$(id -gn "$OWNER")"

log "Владелец файлов проекта: $OWNER:$OWNER_GROUP"

# Проверяем Docker и Compose.
DOCKER_READY=0

if command -v docker >/dev/null 2>&1 &&
   docker compose version >/dev/null 2>&1; then
    DOCKER_READY=1
fi

if [[ "$DOCKER_READY" != "1" ]]; then
    echo "Docker Engine или Docker Compose не обнаружен."
    read -r -p "Установить Docker из официального репозитория? [Y/n] " answer

    if [[ "$answer" =~ ^[Nn]$ ]]; then
        fail "Установка Docker отменена."
    fi

    . /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] ||
        fail "Автоматическая установка рассчитана на Ubuntu."

    CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$CODENAME" ]] || fail "Не удалось определить кодовое имя Ubuntu."

    apt-get update
    apt-get install -y ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH="$(dpkg --print-architecture)"

    printf '%s\n' \
        "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

command -v docker >/dev/null 2>&1 ||
    fail "Команда docker не найдена."

docker compose version >/dev/null 2>&1 ||
    fail "Docker Compose plugin не найден."

systemctl enable --now docker

docker info >/dev/null 2>&1 ||
    fail "Docker Engine не отвечает."

# Создаём необходимые каталоги.
log "Подготавливаем каталоги проекта."

mkdir -p \
    "$PROJECT_DIR/certs" \
    "$PROJECT_DIR/secrets" \
    "$PROJECT_DIR/logs/xray" \
    "$PROJECT_DIR/logs/nginx" \
    "$PROJECT_DIR/output" \
    "$PROJECT_DIR/backups"

# Проверяем состояние ранее созданных сертификатов и секретов.
CERT_FILE="$PROJECT_DIR/certs/server.crt"
CERT_KEY="$PROJECT_DIR/certs/server.key"
GENERATED_FILE="$PROJECT_DIR/secrets/generated-values.env"

EXISTING_COUNT=0

for file in "$CERT_FILE" "$CERT_KEY" "$GENERATED_FILE"; do
    if [[ -e "$file" ]]; then
        EXISTING_COUNT=$((EXISTING_COUNT + 1))
    fi
done

cd "$PROJECT_DIR"

if [[ "$EXISTING_COUNT" == "0" ]]; then
    log "Шаг 1/5: создаём TLS-сертификат и ключи Xray."
    bash scripts/create-keys-and-cert.sh

elif [[ "$EXISTING_COUNT" == "3" ]]; then
    log "Шаг 1/5: существующие сертификаты и секреты найдены."
    log "Повторная генерация не выполняется."

    [[ -s "$CERT_FILE" ]] || fail "TLS-сертификат пуст."
    [[ -s "$CERT_KEY" ]] || fail "TLS-ключ пуст."
    [[ -s "$GENERATED_FILE" ]] || fail "Файл generated-values.env пуст."

else
    fail "Обнаружен неполный набор сертификатов и секретов. Ничего не перезаписано. Проверь certs/ и secrets/."
fi

# Проверяем, что fingerprint действительно записан в env.
grep -q '^CERT_FINGERPRINT=.' "$GENERATED_FILE" ||
    fail "В generated-values.env отсутствует CERT_FINGERPRINT."

# Выбираем REALITY dest/SNI.
# Пустой ввод оставляет текущие значения, по умолчанию Cloudflare.
log "Шаг 2/5: настройка REALITY dest и SNI."

python3 scripts/select-reality-target.py

# Собираем конфигурации.
log "Шаг 3/5: собираем конфигурации Xray и Nginx."

bash scripts/build-configs.sh

# Проверяем синтаксис Docker Compose.
docker compose -f docker-compose.yaml config -q

# Проверяем конфигурацию Xray до запуска.
log "Шаг 4/5: проверяем конфигурацию Xray."

docker compose -f docker-compose.yaml run \
    --rm \
    --no-deps \
    --entrypoint xray \
    xray run -test -config /etc/xray/config.json

# Сначала запускаем Xray.
log "Запускаем контейнер Xray."

docker compose -f docker-compose.yaml up -d xray

# Проверяем конфигурацию Nginx в контейнере.
log "Проверяем конфигурацию Nginx."

docker compose -f docker-compose.yaml run \
    --rm \
    --no-deps \
    nginx nginx -t

# Запускаем Nginx.
log "Запускаем контейнер Nginx."

docker compose -f docker-compose.yaml up -d nginx

# Проверяем состояние Nginx.
docker compose -f docker-compose.yaml exec -T nginx nginx -t

# Создаём клиентские профили.
log "Шаг 5/5: создаём клиентские профили."

python3 scripts/generate-client-profiles.py

# Устанавливаем владельца и права.
log "Настраиваем владельца и права файлов."

chown -R "$OWNER:$OWNER_GROUP" "$PROJECT_DIR"

chmod 700 \
    "$PROJECT_DIR/certs" \
    "$PROJECT_DIR/secrets" \
    "$PROJECT_DIR/output" \
    "$PROJECT_DIR/backups"

chmod 700 "$PROJECT_DIR"/scripts/*.sh
chmod 700 "$PROJECT_DIR"/scripts/*.py

chmod 600 "$GENERATED_FILE"
chmod 600 "$CERT_KEY"
chmod 600 "$PROJECT_DIR/xray/config.json"
chmod 600 "$PROJECT_DIR/nginx/nginx.conf"
chmod 600 "$PROJECT_DIR/output/client-profiles.txt"

chmod 644 "$CERT_FILE"

log "Развёртывание завершено."

echo
echo "Проверь состояние контейнеров:"
echo "  cd $PROJECT_DIR && sudo docker compose ps"
echo
echo "Проверь журналы:"
echo "  cd $PROJECT_DIR && sudo docker compose logs --tail=50"
echo
echo "Клиентские профили:"
echo "  $PROJECT_DIR/output/client-profiles.txt"
echo
echo "Проверка проекта:"
echo "  cd $PROJECT_DIR && sudo bash scripts/checks.sh"
