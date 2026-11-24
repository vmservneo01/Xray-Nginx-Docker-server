#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="/opt/Xray-Nginx-Docker-server"
CERT_DIR="${PROJECT_DIR}/certs"
SECRETS_DIR="${PROJECT_DIR}/secrets"

XRAY_IMAGE="ghcr.io/xtls/xray-core:26.6.27"
CERT_DAYS=365

CERT_FILE="${CERT_DIR}/server.crt"
CERT_KEY="${CERT_DIR}/server.key"
GENERATED_FILE="${SECRETS_DIR}/generated-values.env"

log() {
    printf '[INFO] %s\n' "$1"
}

fail() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

for cmd in docker openssl curl awk grep python3 sha256sum cut cat; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "Не найдена необходимая команда: $cmd"
done

[[ -d "$PROJECT_DIR" ]] ||
    fail "Нет каталога проекта: $PROJECT_DIR"

mkdir -p "$CERT_DIR" "$SECRETS_DIR"
chmod 700 "$CERT_DIR" "$SECRETS_DIR"

# Не перезаписываем ранее созданные ключи и сертификаты.
if [[ -e "$CERT_FILE" || -e "$CERT_KEY" || -e "$GENERATED_FILE" ]]; then
    fail "Найдены ранее созданные файлы. Ничего не изменено. Сначала проверь и сохрани существующие данные."
fi

SUCCESS=0

cleanup() {
    if [[ "$SUCCESS" != "1" ]]; then
        rm -f "$CERT_FILE" "$CERT_KEY" "$GENERATED_FILE"
    fi
}

trap cleanup EXIT

# Определяем публичный IPv4.
log "Определяем публичный IPv4..."

PUBLIC_IP=""

for endpoint in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip"
do
    PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || true)"

    if [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    fi

    PUBLIC_IP=""
done

[[ -n "$PUBLIC_IP" ]] ||
    fail "Не удалось определить публичный IPv4."

# Проверяем корректность IP и исключаем частные и служебные адреса.
python3 - "$PUBLIC_IP" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
    if not isinstance(ip, ipaddress.IPv4Address) or not ip.is_global:
        raise ValueError("Адрес не является глобальным публичным IPv4")
except ValueError as e:
    print(f"Ошибка проверки IP: {e}", file=sys.stderr)
    sys.exit(1)
PY

log "Публичный IP определён: $PUBLIC_IP"

# Создаём самоподписанный TLS-сертификат с IP в SAN.
log "Создаём TLS-сертификат..."

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -nodes \
    -days "$CERT_DAYS" \
    -keyout "$CERT_KEY" \
    -out "$CERT_FILE" \
    -subj "/CN=${PUBLIC_IP}" \
    -addext "subjectAltName=IP:${PUBLIC_IP}" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"

chmod 600 "$CERT_KEY"
chmod 644 "$CERT_FILE"

# Проверяем сертификат, IP в SAN и соответствие приватного ключа.
openssl x509 -in "$CERT_FILE" -noout >/dev/null
openssl x509 -in "$CERT_FILE" -noout -checkip "$PUBLIC_IP" >/dev/null

CERT_PUB_HASH="$(
    openssl x509 -in "$CERT_FILE" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum | awk '{print $1}'
)"

KEY_PUB_HASH="$(
    openssl pkey -in "$CERT_KEY" -pubout -outform DER |
    sha256sum | awk '{print $1}'
)"

[[ "$CERT_PUB_HASH" == "$KEY_PUB_HASH" ]] ||
    fail "Открытая часть сертификата не соответствует приватному ключу."

# Получаем SHA-256 fingerprint сертификата.
CERT_FINGERPRINT="$(
    openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 |
    cut -d= -f2
)"

[[ -n "$CERT_FINGERPRINT" ]] ||
    fail "Не удалось получить SHA-256 fingerprint сертификата."

# Генерируем REALITY X25519.
log "Генерируем REALITY X25519..."

XRAY_OUTPUT="$(docker run --rm "$XRAY_IMAGE" x25519)"

REALITY_PRIVATE_KEY="$(
    printf '%s\n' "$XRAY_OUTPUT" |
    awk -F': ' '/^PrivateKey:/ {print $2; exit}'
)"

REALITY_PUBLIC_KEY="$(
    printf '%s\n' "$XRAY_OUTPUT" |
    awk -F': ' '/^Password \(PublicKey\):|^Password:/ {print $2; exit}'
)"

[[ -n "$REALITY_PRIVATE_KEY" ]] ||
    fail "Не удалось получить REALITY PrivateKey от Xray."

[[ -n "$REALITY_PUBLIC_KEY" ]] ||
    fail "Не удалось получить REALITY PublicKey от Xray."

# Генерируем данные пяти пользователей.
log "Генерируем данные пяти пользователей..."

{
    printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
# Fingerprint самоподписанного TLS-сертификата.
    printf 'CERT_FINGERPRINT=%s\n' "$CERT_FINGERPRINT"

    printf 'REALITY_PRIVATE_KEY=%s\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%s\n' "$REALITY_PUBLIC_KEY"

    # REALITY по умолчанию использует Cloudflare.
    # Позже эти значения можно заменить через ручной выбор REALITY-пары.
    printf 'REALITY_DEST=%s\n' 'www.cloudflare.com:443'
    printf 'REALITY_SNI=%s\n' 'www.cloudflare.com'

    for i in 1 2 3 4 5; do
        UUID="$(cat /proc/sys/kernel/random/uuid)"
        SHORT_ID="$(openssl rand -hex 8)"
        TROJAN_PASSWORD="$(openssl rand -hex 24)"
        HY2_PASSWORD="$(openssl rand -hex 24)"

        printf 'USER%s_UUID=%s\n' "$i" "$UUID"
        printf 'USER%s_SHORT_ID=%s\n' "$i" "$SHORT_ID"
        printf 'USER%s_TROJAN_PASSWORD=%s\n' "$i" "$TROJAN_PASSWORD"
        printf 'USER%s_HY2_PASSWORD=%s\n' "$i" "$HY2_PASSWORD"
    done
} > "$GENERATED_FILE"

chmod 600 "$GENERATED_FILE"

SUCCESS=1

log "Готово."
printf '\n'
printf 'Публичный IP: %s\n' "$PUBLIC_IP"
printf 'Сертификат: %s\n' "$CERT_FILE"
printf 'Приватный TLS-ключ: %s\n' "$CERT_KEY"
printf 'Данные Xray и пользователей: %s\n' "$GENERATED_FILE"
printf 'SHA-256 fingerprint: %s\n' "$CERT_FINGERPRINT"
printf '\n'

log "Fingerprint и остальные значения сохранены в generated-values.env."
log "Файл с секретными значениями имеет права 600."

