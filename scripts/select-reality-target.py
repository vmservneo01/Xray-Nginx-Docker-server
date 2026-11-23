#!/usr/bin/env python3

import ipaddress
import os
import re
import sys
import tempfile
from pathlib import Path

PROJECT_DIR = Path("/opt/xray-server-final")
ENV_FILE = PROJECT_DIR / "secrets" / "generated-values.env"

DEFAULT_DEST = "www.cloudflare.com:443"
DEFAULT_SNI = "www.cloudflare.com"

def fail(message):
    print(f"[ОШИБКА] {message}", file=sys.stderr)
    sys.exit(1)

def read_env(path):
    values = {}

    if not path.is_file():
        fail(f"Не найден файл: {path}")

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()

        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()

    return values

def validate_ip(value):
    try:
        address = ipaddress.ip_address(value)

        if not isinstance(address, ipaddress.IPv4Address):
            return False

        if not address.is_global:
            return False

        return True

    except ValueError:
        return False

def validate_sni(value):
    if not value or len(value) > 253:
        return False

    if "*" in value:
        return False

    if value.startswith(".") or value.endswith("."):
        return False

    labels = value.split(".")

    if len(labels) < 2:
        return False

    for label in labels:
        if not label or len(label) > 63:
            return False

        if not re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?",
            label
        ):
            return False

    return True

def save_env(path, new_values):
    lines = path.read_text(encoding="utf-8").splitlines()
    output = []
    written = set()

    for line in lines:
        stripped = line.strip()

        if "=" in stripped and not stripped.startswith("#"):
            key = stripped.split("=", 1)[0].strip()

            if key in new_values:
                if key not in written:
                    output.append(f"{key}={new_values[key]}")
                    written.add(key)
                continue

        output.append(line)

    for key, value in new_values.items():
        if key not in written:
            output.append(f"{key}={value}")

    content = "\n".join(output) + "\n"

    fd, temp_name = tempfile.mkstemp(
        prefix=".generated-values.",
        dir=str(path.parent)
    )

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())

        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
        os.chmod(path, 0o600)

    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise

def main():
    print("========================================")
    print("       REALITY target / SNI setup")
    print("========================================")
    print()

    values = read_env(ENV_FILE)

    current_dest = values.get("REALITY_DEST", DEFAULT_DEST)
    current_sni = values.get("REALITY_SNI", DEFAULT_SNI)

    print("Текущие значения:")
    print(f"  REALITY dest: {current_dest}")
    print(f"  REALITY SNI:  {current_sni}")
    print()
    print("Чтобы оставить текущую пару, просто нажми Enter в обоих полях.")
    print("Чтобы задать свою пару, введи публичный IPv4 и соответствующий SNI.")
    print()

    try:
        new_ip = input("REALITY dest IP (IPv4): ").strip()
        new_sni = input("REALITY SNI (домен): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nИзменения не сохранены.")
        sys.exit(1)

    if not new_ip and not new_sni:
        print()
        print("[OK] Текущая REALITY-пара оставлена без изменений.")
        return

    if not new_ip or not new_sni:
        fail("Нужно ввести оба значения или оставить оба поля пустыми.")

    if not validate_ip(new_ip):
        fail("Введён некорректный или непубличный IPv4.")

    if not validate_sni(new_sni):
        fail("Некорректное доменное имя SNI. Wildcard (*) не допускается.")

    new_dest = f"{new_ip}:443"

    save_env(
        ENV_FILE,
        {
            "REALITY_DEST": new_dest,
            "REALITY_SNI": new_sni,
        }
    )

    print()
    print("[OK] REALITY-пара сохранена.")
    print(f"  REALITY dest: {new_dest}")
    print(f"  REALITY SNI:  {new_sni}")
    print()
    print("Остальные значения generated-values.env не изменены.")

if __name__ == "__main__":
    main()