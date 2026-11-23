#!/usr/bin/env python3

import os
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / "secrets" / "generated-values.env"
OUT_DIR = ROOT / "output"
OUT_FILE = OUT_DIR / "client-profiles.txt"

def read_values():
    if not ENV_FILE.is_file():
        raise SystemExit("Не найден secrets/generated-values.env.")

    if ENV_FILE.stat().st_mode & 0o077:
        raise SystemExit("Для generated-values.env нужны права 600.")

    values = {}

    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()

        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value

    return values

def enc(value):
    return urllib.parse.quote(str(value), safe="")

def link(scheme, userinfo, ip, port, params, label):
    query = urllib.parse.urlencode(
        params,
        quote_via=urllib.parse.quote,
        safe=""
    )

    return (
        f"{scheme}://{userinfo}@{ip}:{port}"
        f"?{query}#{enc(label)}"
    )

def main():
    v = read_values()

    required = [
        "PUBLIC_IP",
        "CERT_FINGERPRINT",
        "REALITY_PUBLIC_KEY",
        "REALITY_SNI",
        "REALITY_DEST",
        "WS_PATH",
        "XHTTP_PATH",
        "XHTTP_REALITY_PATH",
    ]

    missing = [key for key in required if not v.get(key)]

    if missing:
        raise SystemExit(
            "Не хватает параметров: "
            + ", ".join(missing)
            + ". Сначала создайте ключи и конфигурации."
        )

    ip = v["PUBLIC_IP"]
    fingerprint = v["CERT_FINGERPRINT"].replace(":", "").lower()

    output = []

    for i in range(1, 6):
        uuid = v[f"USER{i}_UUID"]
        sid = v[f"USER{i}_SHORT_ID"]
        trojan = v[f"USER{i}_TROJAN_PASSWORD"]
        hy2 = v[f"USER{i}_HY2_PASSWORD"]

        name = f"User {i}"

        output.append("=" * 60)
        output.append(name.upper())
        output.append("=" * 60)
        output.append("")

        output.append("TLS CERTIFICATE SHA-256 FINGERPRINT:")
        output.append(v["CERT_FINGERPRINT"])
        output.append("")

        profiles = [
            (
                "1. VLESS TLS WS 8443",
                link("vless", uuid, ip, 8443, {
                    "pcs": fingerprint,
                    "path": v["WS_PATH"],
                    "security": "tls",
                    "alpn": "http/1.1",
                    "encryption": "none",
                    "insecure": "0",
                    "fp": "chrome",
                    "type": "ws",
                    "allowInsecure": "0",
                    "sni": ip,
                }, f"{name} - VLESS TLS WS 8443")
            ),
            (
                "2. VLESS REALITY Vision 443",
                link("vless", uuid, ip, 443, {
                    "security": "reality",
                    "encryption": "none",
                    "pbk": v["REALITY_PUBLIC_KEY"],
                    "headerType": "none",
                    "fp": "chrome",
                    "type": "tcp",
                    "flow": "xtls-rprx-vision",
                    "sni": v["REALITY_SNI"],
                    "sid": sid,
                }, f"{name} - VLESS REALITY Vision 443")
            ),
            (
                "3. VLESS XHTTP REALITY 8445",
                link("vless", uuid, ip, 8445, {
                    "mode": "stream-one",
                    "path": v["XHTTP_REALITY_PATH"],
                    "security": "reality",
                    "encryption": "none",
                    "pbk": v["REALITY_PUBLIC_KEY"],
                    "fp": "chrome",
                    "type": "xhttp",
                    "sni": v["REALITY_SNI"],
                    "sid": sid,
                }, f"{name} - VLESS XHTTP REALITY 8445")
            ),
            (
                "4. Trojan gRPC REALITY 8444",
                link("trojan", trojan, ip, 8444, {
                    "mode": "gun",
                    "security": "reality",
                    "pbk": v["REALITY_PUBLIC_KEY"],
                    "fp": "chrome",
                    "type": "grpc",
                    "serviceName": "trojan-tunnel",
                    "sni": v["REALITY_SNI"],
                    "sid": sid,
                }, f"{name} - Trojan gRPC REALITY 8444")
            ),
            (
                "5. VLESS XHTTP TLS 9443",
                link("vless", uuid, ip, 9443, {
                    "vcn": ip,
                    "mode": "packet-up",
                    "pcs": fingerprint,
                    "path": v["XHTTP_PATH"],
                    "security": "tls",
                    "alpn": "h2",
                    "encryption": "none",
                    "insecure": "0",
                    "fp": "chrome",
                    "type": "xhttp",
                    "allowInsecure": "0",
                    "sni": ip,
                }, f"{name} - VLESS XHTTP TLS 9443")
            ),
            (
                "6. Hysteria2 UDP 443",
                link("hysteria2", hy2, ip, 443, {
                    "security": "tls",
                    "insecure": "0",
                    "pinSHA256": v["CERT_FINGERPRINT"],
                    "sni": ip,
                }, f"{name} - Hysteria2 UDP 443")
            ),
        ]

        for title, uri in profiles:
            output.append(title)
            output.append(uri)
            output.append("")

        output.append("")

    OUT_DIR.mkdir(mode=0o700, exist_ok=True)
    OUT_FILE.write_text("\n".join(output) + "\n", encoding="utf-8")
    os.chmod(OUT_FILE, 0o600)

    print(f"Создан файл с профилями: {OUT_FILE}")
    print("Пользователей: 5")
    print("Профилей на пользователя: 6")
    print("Всего профилей: 30")
    print("Секретные ссылки не выводились в терминал.")

if __name__ == "__main__":
    main()