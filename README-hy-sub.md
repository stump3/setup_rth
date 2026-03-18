# 🔗 hy-sub-install.sh — Hysteria2 + Remnawave Integration

> Интегрирует Hysteria2 в подписку Remnawave.  
> Пользователи синхронизируются автоматически через вебхуки. `hy2://` URI появляется в подписке без ручных действий.

```bash
bash hy-sub-install.sh
```

---

## Что устанавливается

| Компонент | Описание |
|---|---|
| 🪝 **hy-webhook** | Python-сервис на `127.0.0.1:8766`. Слушает вебхуки Remnawave, обновляет `userpass` в конфиге Hysteria2, перезапускает сервис |
| 📄 **Форк subscription-page** | Патч TypeScript-бэкенда. При каждом запросе подписки дописывает `hy2://` URI к существующим прокси |

---

## Требования

| Параметр | Условие |
|---|---|
| Права | root |
| Remnawave Panel | Установлена в `/opt/remnawave` |
| Hysteria2 | Конфиг в `/etc/hysteria/config.yaml`, auth `type: userpass` |
| Docker | Для сборки форка subscription-page |
| Python 3 | Для hy-webhook сервиса |

> ⚠️ В конфиге Hysteria2 должен быть блок `auth: type: userpass`. Если его нет — добавьте вручную перед запуском скрипта.

```yaml
auth:
  type: userpass
  userpass:
    # скрипт будет управлять этим блоком
```

---

## Установка

```bash
# 1. Подключитесь по SSH
ssh root@YOUR_SERVER_IP

# 2. Скачайте скрипт
curl -fsSL https://raw.githubusercontent.com/.../hy-sub-install.sh -o hy-sub-install.sh

# 3. Запустите
bash hy-sub-install.sh
```

### Шаги установки

```
━━━ [1/6] Конфигурация ━━━

  ✓ Домен   = your.domain.com  (авто)
  ✓ Порт    = 8443  (авто)

  Название подключения [🇩🇪 Germany Hysteria2]: _
  ✎ Название = 🇩🇪 Germany Hysteria2  (вручную)
  ⚙ Webhook secret = a3f8b2c1…  (сгенерировано)

━━━ [2/6] Webhook сервис ━━━
  ✓ hy-webhook.py создан
  ✓ hy-webhook запущен

━━━ [3/6] Синхронизация пользователей ━━━
  ✓ Пользователи синхронизированы

━━━ [4/6] Вебхуки Remnawave ━━━
  ✓ Вебхуки включены в .env
  ✓ Remnawave перезапущена

━━━ [5/6] Форк subscription-page ━━━
  ✓ Исходники скачаны
  ✓ Патчи применены
  ✓ Docker образ собран: remnawave-sub-hy:local

━━━ [6/6] Docker Compose ━━━
  ✓ subscription-page запущен с форком
```

### Финальный экран

```
  ✅ Установка завершена!

  Статус сервисов
  ────────────────────────────
  ✓  hy-webhook
  ✓  hysteria-server
  ✓  subscription-page

  Конфигурация
  ────────────────────────────
  Домен    your.domain.com
  Порт     8443
  Название 🇩🇪 Germany Hysteria2

  ⚠  Webhook secret — сохраните сейчас, больше не показывается!
  ────────────────────────────
  a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3
```

> ⚠️ **Сохраните webhook secret.** Он нужен при переустановке в режиме «только webhook» — иначе пароли пересчитаются и все клиенты потеряют подключение до обновления подписки.

---

## Переустановка и обновление

При повторном запуске скрипт обнаруживает существующую установку:

```
  ↻  Обнаружена существующая установка

  hy-webhook:         active
  Пользователей в БД: 12

  Что обновить?

  1) Всё заново          — полная переустановка, новый secret
  2) Только webhook      — сервис + конфиг, secret сохранится
  3) Только subscription — пересборка Docker-образа форка
  0) Отмена
```

| Режим | Затронуто | Не затронуто | Secret |
|---|---|---|---|
| 1 — Всё заново | Все 6 шагов | — | новый |
| 2 — Только webhook | hy-webhook.py, .service | docker-compose.yml, subscription-page | сохраняется |
| 3 — Только subscription | Docker-образ, docker-compose.yml | hy-webhook, пользователи, .env | не меняется |

> ⚠️ Режим **1** генерирует новый secret → пароли всех пользователей пересчитываются → подключения сбрасываются. Восстановятся при следующем обновлении подписки клиентом.

---

## Схема работы

**Создание пользователя:**
```
Remnawave → POST /webhook (user.created) → hy-webhook → users.json → config.yaml → reload Hysteria2
```

**Запрос подписки:**
```
Клиент → subscription-page (форк) → Remnawave API → users.json → ответ + hy2:// URI
```

---

## Обрабатываемые события

| Событие | Действие |
|---|---|
| `user.created` | Добавить пользователя → обновить конфиг → reload |
| `user.enabled` | Восстановить пользователя |
| `user.traffic_reset` | Восстановить после сброса трафика |
| `user.deleted` | Удалить из конфига |
| `user.disabled` | Удалить из конфига (отключить доступ) |
| `user.limited` | Лимит трафика — удалить из конфига |
| `user.expired` | Истёк срок — удалить из конфига |
| Остальные | Игнорируются |

---

## Генерация паролей

Пароль детерминированный — вычисляется из имени пользователя и webhook secret:

```
sha256("{safe_username}:{WEBHOOK_SECRET}")[:32]
```

При одинаковом secret один и тот же пользователь всегда получит один и тот же пароль. При переустановке в режиме **2** (secret сохраняется) — все пароли останутся прежними.

---

## Подпись вебхука

Remnawave отправляет заголовок `X-Remnawave-Signature` — HMAC-SHA256 от тела запроса, ключ `WEBHOOK_SECRET_HEADER`. Сервис проверяет подпись идентично.

```bash
# Тест вручную
SECRET=$(grep "WEBHOOK_SECRET=" /etc/systemd/system/hy-webhook.service | cut -d= -f3)
PAYLOAD='{"scope":"user","event":"user.created","data":{"username":"test_user_01"}}'
SIG=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" -hex | cut -d' ' -f2)
curl -s -X POST http://127.0.0.1:8766/webhook \
  -H "Content-Type: application/json" \
  -H "X-Remnawave-Signature: $SIG" \
  -d "$PAYLOAD"
```

---

## 📁 Файлы и пути

| Путь | Назначение |
|---|---|
| `/opt/hy-webhook/hy-webhook.py` | Python webhook-сервис |
| `/var/lib/hy-webhook/users.json` | БД пользователей `{safe_username: password}` |
| `/etc/systemd/system/hy-webhook.service` | Systemd unit |
| `/opt/hy-subpage/` | Исходники форка subscription-page |
| `/opt/remnawave/docker-compose.yml` | Обновляется: образ + env + volumes |
| `/opt/remnawave/.env` | Обновляется: `WEBHOOK_*` переменные |
| `/etc/hysteria/config.yaml` | Обновляется: блок `userpass` |

---

## ⌨️ Ручное управление

```bash
# Статус и логи hy-webhook
systemctl status hy-webhook
journalctl -u hy-webhook -f
journalctl -u hy-webhook -n 50

# Health-check
curl -s http://127.0.0.1:8766/health | python3 -m json.tool

# Принудительная пересинхронизация конфига
systemctl restart hy-webhook

# Логи subscription-page
docker logs remnawave-subscription-page --tail 50 -f

# Список пользователей в БД
python3 -c "import json; d=json.load(open('/var/lib/hy-webhook/users.json')); [print(k) for k in d]"
```

---

## 🔧 Устранение проблем

### hy-webhook не запускается

```bash
journalctl -u hy-webhook -n 30 --no-pager
ss -tlnp | grep 8766      # порт не занят?
which python3              # python3 доступен?
```

### 401 на вебхуке — неверная подпись

Несовпадение `WEBHOOK_SECRET` в сервисе и `WEBHOOK_SECRET_HEADER` в `.env` панели.

```bash
# Значение в сервисе
grep "WEBHOOK_SECRET=" /etc/systemd/system/hy-webhook.service

# Значение в .env панели
grep "WEBHOOK_SECRET_HEADER" /opt/remnawave/.env
```

Если значения расходятся — запустите скрипт в режиме **2 (только webhook)**.

### hy2:// не появляется в подписке

```bash
# 1. Пользователь в БД?
curl -s http://127.0.0.1:8766/health

# 2. Форк запущен?
docker ps | grep subscription-page

# 3. Ошибки в форке?
docker logs remnawave-subscription-page --tail 30
```

### Hysteria2 не перезапускается после обновления конфига

```bash
# Проверить синтаксис конфига
hysteria server --config /etc/hysteria/config.yaml --check 2>/dev/null \
  || journalctl -u hysteria-server -n 20 --no-pager
```

### Пользователь создан до установки скрипта

Существующие пользователи переносятся на шаге **[3/6]** при первой установке. Если нужно пересинхронизировать вручную:

```bash
systemctl restart hy-webhook   # при старте применяет users.json к config.yaml
```

### subscription-page не запустился после сборки

```bash
docker logs remnawave-subscription-page

# Пересобрать форк (режим 3)
bash hy-sub-install.sh
```

---

## 📋 Переменные среды

### hy-webhook.service

| Переменная | По умолчанию | Описание |
|---|---|---|
| `WEBHOOK_SECRET` | сгенерированный | HMAC-ключ проверки подписи (= `WEBHOOK_SECRET_HEADER` в панели) |
| `HYSTERIA_CONFIG` | `/etc/hysteria/config.yaml` | Путь к конфигу Hysteria2 |
| `USERS_DB` | `/var/lib/hy-webhook/users.json` | БД пользователей |
| `LISTEN_PORT` | `8766` | Локальный порт сервиса |
| `HYSTERIA_SVC` | `hysteria-server` | Имя systemd-сервиса Hysteria2 |

### docker-compose.yml (subscription-page)

| Переменная | Описание |
|---|---|
| `HY_DOMAIN` | Домен Hysteria2 |
| `HY_PORT` | Порт Hysteria2 |
| `HY_NAME` | Название подключения в клиенте |
| `HY_USERS_DB` | `/var/lib/hy-webhook/users.json` |
