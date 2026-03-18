#!/usr/bin/env python3
"""
Remnawave → Hysteria2 Webhook Sync Service
Слушает вебхуки Remnawave и синхронизирует пользователей с Hysteria2

Заголовок подписи: X-Remnawave-Signature (HMAC-SHA256 от тела запроса)
Источник: webhook-logger.processor.ts → createHmac('sha256', WEBHOOK_SECRET_HEADER)

Санитизация имён: [a-zA-Z0-9_-], минимум 6 символов
Источник: backend/src/common/utils/sanitize-username.ts
"""

import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── Конфиг ────────────────────────────────────────────────────────
WEBHOOK_SECRET  = os.environ.get("WEBHOOK_SECRET", "")        # = WEBHOOK_SECRET_HEADER в .env панели
HYSTERIA_CONFIG = os.environ.get("HYSTERIA_CONFIG", "/etc/hysteria/config.yaml")
USERS_DB        = os.environ.get("USERS_DB", "/var/lib/hy-webhook/users.json")
LISTEN_PORT     = int(os.environ.get("LISTEN_PORT", "8766"))
HYSTERIA_SVC    = os.environ.get("HYSTERIA_SVC", "hysteria-server")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("hy-webhook")

# ── Утилиты ───────────────────────────────────────────────────────

def load_users() -> dict:
    """Загружает БД пользователей {safe_username: password}"""
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    try:
        with open(USERS_DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_users(users: dict):
    """Сохраняет БД пользователей"""
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f:
        json.dump(users, f, indent=2)


def sanitize(username: str) -> str:
    """
    Санитизирует имя пользователя по правилам Remnawave.
    Источник: backend/src/common/utils/sanitize-username.ts
      - Допустимые символы: [a-zA-Z0-9_-]
      - Точка НЕ допустима (заменяется на _)
      - Минимальная длина: 6 символов, дополняется _
    """
    result = re.sub(r'[^a-zA-Z0-9_\-]', '_', username)
    if len(result) < 6:
        result = result + '_' * (6 - len(result))
    return result


def gen_password(safe_username: str) -> str:
    """
    Генерирует детерминированный пароль: sha256(safe_username:secret)[:32]
    Пароль привязан к санитизированному имени — при одном и том же secret
    всегда воспроизводится для того же пользователя.
    """
    seed = f"{safe_username}:{WEBHOOK_SECRET}"
    return hashlib.sha256(seed.encode()).hexdigest()[:32]


def reload_hysteria():
    """Перезапускает hysteria-server через systemctl"""
    try:
        result = subprocess.run(
            ["systemctl", "reload-or-restart", HYSTERIA_SVC],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            log.info("Hysteria2 перезапущен")
        else:
            log.warning(f"Ошибка перезапуска: {result.stderr.strip()}")
    except Exception as e:
        log.error(f"Не удалось перезапустить hysteria: {e}")


def update_hysteria_config(users: dict) -> bool:
    """Обновляет блок userpass в конфиге Hysteria2"""
    try:
        with open(HYSTERIA_CONFIG) as f:
            config = f.read()

        # Строим новый блок userpass
        # Имена в users.json уже санитизированы, повторная обработка не нужна
        userpass_lines = ["  userpass:"]
        for username, password in users.items():
            userpass_lines.append(f'    {username}: "{password}"')
        new_userpass = "\n".join(userpass_lines)

        # Заменяем существующий блок userpass
        pattern = r'(\s*userpass:\s*\n(?:[ \t]+[^\n]+\n?)*)'
        if re.search(pattern, config):
            config = re.sub(pattern, "\n" + new_userpass + "\n", config)
        else:
            # Добавляем после строки "type: userpass"
            config = re.sub(
                r'(auth:\s*\n\s*type:\s*userpass\s*\n)',
                r'\1' + new_userpass + "\n",
                config
            )

        with open(HYSTERIA_CONFIG, "w") as f:
            f.write(config)

        log.info(f"Конфиг обновлён, пользователей: {len(users)}")
        return True
    except Exception as e:
        log.error(f"Ошибка обновления конфига: {e}")
        return False


def verify_signature(body: bytes, signature: str) -> bool:
    """
    Проверяет подпись вебхука.
    Remnawave отправляет заголовок X-Remnawave-Signature:
      createHmac('sha256', WEBHOOK_SECRET_HEADER).update(payload).digest('hex')
    Источник: webhook-logger.processor.ts
    """
    if not WEBHOOK_SECRET:
        return True  # без секрета — принимаем всё (не рекомендуется в production)
    expected = hmac.new(
        WEBHOOK_SECRET.encode(),
        body,
        hashlib.sha256
    ).hexdigest()
    # Remnawave отправляет чистый hex без префикса "sha256="
    return hmac.compare_digest(expected, signature.strip().lower())


# ── Обработка событий ─────────────────────────────────────────────

def _add_user(safe: str, users: dict) -> bool:
    """Добавляет пользователя если его нет. Возвращает True если были изменения."""
    if safe in users:
        log.debug(f"Пользователь {safe} уже существует")
        return False
    users[safe] = gen_password(safe)
    log.info(f"Добавлен: {safe}")
    return True


def _remove_user(safe: str, users: dict) -> bool:
    """Удаляет пользователя если есть. Возвращает True если были изменения."""
    if safe not in users:
        log.debug(f"Пользователь {safe} не найден в БД")
        return False
    del users[safe]
    log.info(f"Удалён: {safe}")
    return True


def process_event(payload: dict):
    """
    Обрабатывает вебхук событие от Remnawave.

    Структура payload (scope: "user"):
      {
        "scope": "user",
        "event": "user.created",
        "timestamp": "...",
        "data": { "username": "...", "shortUuid": "...", ... },  ← ExtendedUsersSchema
        "meta": null
      }

    Полный список событий: backend/libs/contract/constants/events/events.ts
    """
    scope = payload.get("scope", "")
    event = payload.get("event", "")
    data  = payload.get("data", {})

    if scope != "user":
        log.debug(f"Пропуск события scope={scope}")
        return

    username = data.get("username", "")
    if not username:
        log.warning("Нет username в payload")
        return

    safe = sanitize(username)
    log.info(f"Событие: {event}, пользователь: {username!r} → {safe!r}")

    users   = load_users()
    changed = False

    # Пользователь активен — добавить/восстановить доступ
    if event in ("user.created", "user.enabled", "user.traffic_reset"):
        changed = _add_user(safe, users)

    # Пользователь недоступен — убрать из конфига Hysteria2
    elif event in ("user.deleted", "user.disabled", "user.limited", "user.expired"):
        changed = _remove_user(safe, users)

    # Остальные события (user.modified, user.revoked, user.expires_in_*,
    # user.first_connected, user.bandwidth_usage_threshold_reached, user.not_connected)
    # не влияют на доступ к Hysteria2
    else:
        log.debug(f"Событие {event!r} не требует изменений конфига")
        return

    if changed:
        save_users(users)
        if update_hysteria_config(users):
            reload_hysteria()


# ── HTTP сервер ───────────────────────────────────────────────────

class WebhookHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # используем собственный логгер вместо BaseHTTPServer

    def do_GET(self):
        if self.path == "/health":
            users = load_users()
            body = json.dumps({
                "status": "ok",
                "users": len(users),
                "secret_set": bool(WEBHOOK_SECRET),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        # Remnawave подписывает тело заголовком X-Remnawave-Signature
        # Источник: webhook-logger.processor.ts
        signature = self.headers.get("X-Remnawave-Signature", "")
        if WEBHOOK_SECRET and not verify_signature(body, signature):
            log.warning(
                f"Неверная подпись. "
                f"Получен: {signature[:16] + '…' if signature else '(пусто)'}, "
                f"IP: {self.client_address[0]}"
            )
            self.send_response(401)
            self.end_headers()
            return

        try:
            payload = json.loads(body)
            process_event(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        except json.JSONDecodeError:
            log.error("Невалидный JSON в теле запроса")
            self.send_response(400)
            self.end_headers()
        except Exception as e:
            log.error(f"Ошибка обработки события: {e}", exc_info=True)
            self.send_response(500)
            self.end_headers()


def main():
    log.info(f"Запуск hy-webhook на порту {LISTEN_PORT}")
    log.info(f"Hysteria конфиг: {HYSTERIA_CONFIG}")
    log.info(f"БД пользователей: {USERS_DB}")
    log.info(
        f"Подпись: {'включена (X-Remnawave-Signature)' if WEBHOOK_SECRET else 'ОТКЛЮЧЕНА — установите WEBHOOK_SECRET!'}"
    )

    # При старте применяем текущую БД к конфигу Hysteria2
    users = load_users()
    if users:
        log.info(f"Загружено {len(users)} пользователей из БД, синхронизируем конфиг...")
        update_hysteria_config(users)
    else:
        log.info("БД пуста — ожидаем первые события")

    server = HTTPServer(("127.0.0.1", LISTEN_PORT), WebhookHandler)
    log.info("Готов принимать вебхуки")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Остановка сервиса")


if __name__ == "__main__":
    main()
