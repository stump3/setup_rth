<div align="center">

> 📖 **[Открыть интерактивную документацию](https://stump3.github.io/setup_rth/README.html)** — тёмная тема, навигация, терминальные превью

</div>

---

# 🛠️ setup.sh — Unified Server Management

> Единый скрипт установки и управления VPN-инфраструктурой.  
> Один файл — полное управление сервером.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/setup_rth/main/setup.sh -o setup.sh
bash setup.sh
```

---

## Компоненты

| Компонент | Описание |
|---|---|
| 🛡️ **Remnawave Panel** | VPN-панель на базе eGames архитектуры с Xray/Reality и cookie-защитой |
| 📡 **MTProxy (telemt)** | Telegram MTProto прокси на Rust. systemd или Docker, hot reload |
| 🚀 **Hysteria2** | Высокоскоростной VPN поверх QUIC/UDP, устойчив к потерям пакетов |

---

## Быстрый старт

```bash
# 1. Подключитесь по SSH
ssh root@YOUR_SERVER_IP

# 2. Скачайте скрипт
curl -fsSL https://raw.githubusercontent.com/stump3/setup_rth/main/setup.sh -o setup.sh

# 3. Запустите
bash setup.sh
```

---

## Главное меню

```
  SERVER-MANAGER  v2603.181008
  ────────────────────────────────────────────

  Remnawave Panel  ● запущена  v2.4.1
  MTProxy (telemt) ● запущен (systemd)
  Hysteria2        ● запущена  1.3.5

  ────────────────────────────────────────────

  1)  🛡️   Remnawave Panel
  2)  📡  MTProxy (telemt)
  3)  🚀  Hysteria2
  4)  📦  Перенос

  0)  Выход
```

Статусы обновляются при каждом входе в меню (параллельно, ~15ms). `● запущен` — работает (с версией), `◐ остановлен` — установлен но не запущен, `○ не установлен` — отсутствует.

---

## 🛡️ Раздел 1 — Remnawave Panel

VPN-панель управления. Архитектура eGames: nginx в `network_mode: host`, Xray (remnanode) принимает Reality-трафик на порту 443, cookie-защита на вход.

### Подменю

```
  1)  🔧  Установка
  2)  ⚙️  Управление
  3)  🌐  WARP Native
  4)  🎨  Страница подписки
  5)  🖼️  Selfsteal шаблон
  6)  🔄  Обновить скрипт
  7)  📦  Миграция на другой сервер
  8)  🗑️  Удалить панель
  0)  ◀️  Назад
```

### Установка

```
  1) 🆕  Установить
  2) 💣  Переустановить (сброс всех данных!)
  0) ◀️  Назад
```

#### Параметры установки

| Параметр | Пример | Описание |
|---|---|---|
| Режим | 1 / 2 | 1 — панель + нода, 2 — только панель |
| Домен панели | panel.example.com | Основной домен |
| Домен подписок | sub.example.com | Для клиентских конфигов |
| Домен selfsteal | node.example.com | Для Reality |
| Метод SSL | 1 / 2 / 3 | Cloudflare / ACME standalone / Gcore |
| Логин суперадмина | авто | Случайные 8 букв `[a-zA-Z]{8}` |
| Пароль суперадмина | авто | Случайный 24 символа |

> ⚠️ **Сохраните логин, пароль и URL с cookie-ключом.** Показываются один раз. Без cookie-URL войти в панель невозможно.
> `https://panel.example.com/auth/login?KEY=VAL`

Перед запуском контейнеров скрипт предлагает паузу для ручного редактирования конфигов через `nano`.

#### Что настраивается автоматически

- Swap 2 GB, BBR, UFW (порты 22/tcp, 443/tcp)
- Docker, certbot, все зависимости
- SSL сертификаты + cron автообновления с renew_hook для nginx
- Маскировочный сайт `/var/www/html` (случайный шаблон из eGamesAPI)
- Регистрация суперадмина, генерация ключей Reality
- Создание конфиг-профиля StealConfig, ноды, хоста
- API-токен для Subscription Page

#### Методы SSL

| Метод | Тип | Когда использовать |
|---|---|---|
| 1) Cloudflare DNS-01 | Wildcard `*.base.domain` | Рекомендуется — один сертификат на все поддомены |
| 2) ACME HTTP-01 | Per-domain | Без Cloudflare, порт 80 временно открывается |
| 3) Gcore DNS-01 | Wildcard | Если используется Gcore DNS |

### Как работает cookie-защита

Nginx защищает панель двумя случайными словами, генерируемыми при установке:

- **KEY** — имя cookie и query-параметра (`[a-zA-Z]{8}`, например `xKtBpWnR`)
- **VAL** — значение cookie (`[a-zA-Z]{8}`, например `mQaYjZvL`)

При первом переходе по URL `?KEY=VAL` nginx выставляет cookie через `Set-Cookie` со сроком жизни 1 год.

```nginx
map $http_cookie $auth_cookie {
    default 0;
    "~*xKtBpWnR=mQaYjZvL" 1;
}
map $arg_xKtBpWnR $auth_query {
    default 0;
    "mQaYjZvL" 1;
}
map "$auth_cookie$auth_query" $authorized {
    "~1" 1; default 0;
}
```

> Если URL потерян — `rp open_port` открывает прямой доступ на порт 8443. Восстановить KEY/VAL:
> ```bash
> grep -A2 "map \$http_cookie" /opt/remnawave/nginx.conf | head -4
> ```

### Управление (подменю)

```
  1)  📋  Логи
  2)  📊  Статус
  3)  🔄  Перезапустить
  4)  ▶️   Старт
  5)  📦  Обновить
  6)  🔒  SSL
  7)  💾  Бэкап
  8)  🏥  Диагноз
  9)  🔓  Открыть порт 8443
 10)  🔐  Закрыть порт 8443
 11)  💻  Remnawave CLI
 12)  🔧  Переустановить скрипт (rp)
  0)  ◀️  Назад
```

### Команды управления (`rp`)

```bash
rp                  # интерактивное меню
rp status           # статус контейнеров
rp logs [svc]       # логи: panel / nginx / sub / node
rp restart [svc]    # перезапуск: all / nginx / panel / sub / node
rp start            # запустить стек
rp stop             # остановить стек
rp update           # обновить образы Docker
rp ssl              # обновить SSL
rp backup           # бэкап БД и конфигов (хранится 7 дней)
rp health           # диагностика: статус, SSL, nginx, API
rp open_port        # открыть порт 8443 (если потерян cookie-ключ)
rp close_port       # закрыть порт 8443
rp migrate          # перенос на другой сервер
```

### WARP Native

Интеграция Cloudflare WARP в профиль Xray. Позволяет проксировать определённые домены (whoer.net, browserleaks.com и др.) через WARP для маскировки.

```
  1) ⬇️   Установить WARP
  2) ➕  Добавить в профиль Xray
  3) ➖  Удалить из профиля Xray
  4) 🗑️   Удалить WARP с системы
  0) ◀️  Назад
```

Добавление/удаление работает через API панели — выбирается нужный конфиг-профиль интерактивно.

### Страница подписки

```
  1) 🎨  Установить Orion шаблон
  2) 🏷️   Настроить брендинг
  3) ♻️   Восстановить оригинал
  0) ◀️  Назад
```

**Orion** — кастомный шаблон страницы подписки (монтируется поверх `index.html` в контейнер). Требует `yq` для автоматического обновления docker-compose; без него инструкция выводится вручную.

**Брендинг** — настройка названия, URL логотипа и URL поддержки через `app-config.json`. Применяется без пересборки образа.

**Восстановить оригинал** — удаляет кастомные файлы и перезапускает контейнер.

### Selfsteal шаблон

```
  1) 🎲  Случайный шаблон
  2) 🌐  Simple web templates
  3) 🔷  SNI templates
  4) ⬜  Nothing SNI
  0) ◀️  Назад
```

Устанавливает маскировочный HTML-сайт в `/var/www/html`. Шаблон рандомизируется (`<title>`, meta-теги) при каждой установке. Источники: eGamesAPI, distillium/sni-templates, prettyleaf/nothing-sni.

### Обновление скрипта

Сравнивает `SCRIPT_VERSION_STATIC` локальной версии с GitHub, предлагает обновить. Если локальная версия новее — предупреждает.

---

## 📡 Раздел 2 — MTProxy (telemt)

Telegram MTProto прокси на Rust. Поддерживает ограничения на пользователей, hot reload без разрыва соединений.

### Подменю

```
  1) Установить
  2) Добавить пользователя
  3) Пользователи и ссылки
  4) Статус и логи
  5) Обновить
  6) Остановить
  7) Мигрировать на новый сервер  (только systemd)
  8) Сменить режим (systemd ↔ Docker)
  0) Назад
```

> При входе в раздел MTProxy — если сервис уже запущен, режим (systemd/Docker) определяется **автоматически**, меню выбора пропускается.

### Режимы запуска

| Режим | Плюсы | Когда выбирать |
|---|---|---|
| systemd | Hot reload, меньше RAM, миграция | Рекомендуется по умолчанию |
| Docker | Изоляция, простое обновление | Если уже используете Docker-стек |

### Параметры установки

| Параметр | По умолчанию | Описание |
|---|---|---|
| Порт | 8443 | Telegram: 443, 8443, 2053, 2083, 2087, 2096 |
| Домен-маскировка | petrovich.ru | Любой крупный HTTPS-сайт |
| Имя пользователя | — | Минимум один |
| Секрет | авто | 32 hex-символа |

### Ограничения на пользователей

| Параметр | Описание |
|---|---|
| max_tcp_conns | Максимум одновременных подключений |
| max_unique_ips | Максимум уникальных IP-адресов |
| data_quota_bytes | Квота трафика в ГБ |
| expiration_rfc3339 | Срок действия в днях |

> ℹ️ Добавление пользователя применяется через hot reload — существующие соединения не прерываются.

---

## 🚀 Раздел 3 — Hysteria2

Высокоскоростной VPN поверх QUIC/UDP. Эффективен на нестабильных каналах и при высоких потерях пакетов.

### Подменю

```
  1)  🔧  Установка
  2)  ⚙️   Управление
  3)  👥  Пользователи
  4)  🔗  Подписка
  5)  📦  Миграция на другой сервер
  0)  ◀️  Назад
```

При входе в меню автоматически отображаются версия и `домен:порт` из конфига.

### Управление (подменю)

```
  1) 📊  Статус
  2) 📋  Логи
  3) 🔄  Перезапустить
  0) ◀️  Назад
```

### Пользователи (подменю)

```
  1) ➕  Добавить пользователя
  2) ➖  Удалить пользователя
  3) 👥  Пользователи и ссылки
  0) ◀️  Назад
```

**Добавление пользователя:**
- Проверяет занятость имени, предлагает заменить пароль или отменить
- Предлагает выбрать название подключения из уже использованных или ввести новое
- Генерирует URI и QR-код
- Сохраняет в `/root/hysteria-{домен}-users.txt`

**Удаление пользователя:**
- Показывает список, удаляет из конфига, перезапускает сервис

**Пользователи и ссылки:**
- Выбор пользователя → URI + QR-код
- Парсинг пароля через Python (корректно обрабатывает спецсимволы `:`, `#`, `"` в пароле)
- Название подключения берётся из сохранённых URI-файлов

### Подписка (подменю)

```
  1)  📤  Опубликовать подписку
  2)  🔗  Объединить с подпиской Remnawave (merger)
  3)  🪝  Интеграция с Remnawave (webhook + sub-page)
  0)  ◀️  Назад
```

#### Опубликовать подписку

Генерирует Base64-подписку со всеми URI пользователей. Публикуется через `hy-merger` или отдельный endpoint.

#### Объединить с Remnawave (merger)

Устанавливает сервис `hy-merger` — Python HTTP-сервер на порту `18080`, который:
1. Получает подписку Remnawave для токена пользователя
2. Добавляет к ней Hysteria2 URI из `/etc/hy-merger-uris.txt`
3. Возвращает объединённый Base64

Добавляет `location` в nginx selfsteal домена. Имя endpoint настраивается (по умолчанию `hy-merge`).

```
Ссылка: https://node.example.com/hy-merge/ТОКЕН_ПОЛЬЗОВАТЕЛЯ
```

После добавления новых пользователей Hysteria2 нужно обновить URI вручную:
```bash
printf '%s\n' $(cat /root/hysteria-*.txt | grep hy2://) > /etc/hy-merger-uris.txt
systemctl restart hy-merger
```

#### Интеграция с Remnawave (webhook + sub-page)

Запускает отдельный скрипт `hy-sub-install.sh`. Устанавливает:

1. **hy-webhook** — синхронизирует пользователей между Remnawave и Hysteria2 через вебхук
2. **Форк subscription-page** — Docker-образ с патчем, добавляющим `hy2://` URI в подписку

Параметры (домен, порт, название) передаются автоматически из конфига, без дополнительных вопросов.

При повторном запуске — меню выбора:
```
  1) Переустановить полностью
  2) Обновить форк subscription-page
  3) Обновить hy-webhook
  0) Отмена
```

**Сборка frontend:** команда `npm run cb` (vite build). Требует сборки перед `docker build`.

### Требования перед установкой Hysteria2

> ⚠️ Отдельный домен с A-записью на IP сервера (например `cdn.example.com`).
> Порт 80/tcp — скрипт открывает **автоматически** перед получением сертификата и закрывает после.

### Параметры установки

| Параметр | По умолчанию | Описание |
|---|---|---|
| Домен | — | FQDN вида `cdn.example.com` с A-записью на сервер |
| Email | — | Для ACME-уведомлений, необязателен |
| CA | Let's Encrypt | Центр сертификации |
| Порт | 8443 | UDP — скрипт проверяет занятость в реальном времени |
| Логин | Admin | Имя пользователя |
| Пароль | авто | Генерируется если не указан |
| Название | Hysteria2 | Отображается в URI и клиенте (например: 🇩🇪 Germany Hysteria2) |
| Masquerade | bing.com | Режим маскировки трафика |
| Алгоритм | BBR | BBR или Brutal |

### Port Hopping

Рандомизация UDP-порта — усложняет блокировку.

Форматы `listen` в конфиге: `0.0.0.0:8443`, `0.0.0.0:8443,20000-29999`, `[::]:8443,20000-29999`.

Настраивается при установке интеграции с Remnawave (hy-sub-install.sh):

```
  0) Пропустить
  1) 8443 + 20000-29999  ★ рекомендуется
  2) 8443 + 40000-49999
  3) 8443 + 50000-59999
  4) Свой диапазон...
```

> Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+

### Выбор CA

| CA | Срок | Когда использовать |
|---|---|---|
| Let's Encrypt | 90 дней | По умолчанию, рекомендуется |
| ZeroSSL | 90 дней | Если Let's Encrypt заблокирован провайдером |
| Buypass | 180 дней | Если нужен более долгий срок |

### Режимы маскировки

| Вариант | Тип | Описание |
|---|---|---|
| bing.com | proxy | Рекомендуется, поддерживает HTTP/3 |
| yahoo.com | proxy | Стабильный |
| cdn.apple.com | proxy | Нейтральный |
| speed.hetzner.de | proxy | Нейтральный |
| /var/www/html | file | Локальная заглушка Remnawave |
| Свой URL | proxy | Любой HTTP/3 сайт |

### Алгоритмы скорости

| Алгоритм | Когда использовать |
|---|---|
| BBR | Стабильный канал — рекомендуется по умолчанию |
| Brutal | Нестабильный канал, потери >5%, мобильный интернет. Создаёт до 1.4× нагрузки — следите за трафиком на VPS с лимитом |

### Результат установки

```
hy2://Admin:Pass@cdn.example.com:8443?sni=cdn.example.com&alpn=h3&insecure=0#Germany Hysteria2
```

Файлы сохраняются в `/root/`:

| Файл | Содержимое |
|---|---|
| `hysteria-{домен}.txt` | URI первого пользователя |
| `hysteria-{домен}.yaml` | Конфиг Clash/Mihomo |
| `hysteria-{домен}.png` | QR-код PNG |
| `hysteria-{домен}-users.txt` | URI всех добавленных пользователей |

### Совместимость

| Компонент | Конфликт | Решение |
|---|---|---|
| Xray/Reality UDP 443 | ⚠️ есть | Выбрать другой порт — скрипт проверит автоматически |
| nginx TCP 80/443 | ℹ️ частично | Порт 80 открывается временно только для ACME |
| MTProxy 2053/8443 | ℹ️ частично | Скрипт показывает занятые порты в меню |
| certbot / Let's Encrypt | ✅ нет | Hysteria использует собственный ACME-клиент |

---

## 📦 Раздел 4 — Перенос

Перенос сервисов на новый сервер через SSH + пароль. `sshpass` устанавливается автоматически.

```
  1) 🛡️   Перенести Remnawave Panel
  2) 📡  Перенести MTProxy (telemt)
  3) 🚀  Перенести Hysteria2
  4) 📦  Перенести всё (Panel + MTProxy + Hysteria2)
  5) 💾  Бэкап / Восстановление (backup-restore)
  0) Назад
```

### Параметры подключения

| Параметр | По умолчанию |
|---|---|
| IP нового сервера | — |
| SSH-порт | 22 |
| Пользователь | root |
| Пароль SSH | скрытый ввод |

### Перенос Remnawave Panel

Что переносится:
- `.env`, `docker-compose.yml`, `nginx.conf`
- Дамп БД (pg_dumpall, gzip) — проверяется минимальный размер
- SSL сертификаты (`/etc/letsencrypt/`)
- Hysteria2 сертификаты (`/etc/ssl/certs/hysteria/`, если есть)
- Selfsteal сайт `/var/www/html`
- Скрипт управления `remnawave_panel` + `setup.sh`

Перед запуском проверяется свободное место на новом сервере. На новом сервере устанавливаются зависимости (с подтверждением).

### Перенос Hysteria2

1. Установка hysteria на новом сервере (`get.hy2.sh`)
2. Копирование конфига и SSL
3. Открытие портов, запуск сервиса
4. Копирование URI-файлов и `setup.sh`
5. Опциональный мониторинг DNS (30-секундные проверки, таймаут 60 минут) с автоматическим перезапуском

### Мониторинг DNS после переноса

```
  [  1] cdn.example.com → 5.6.7.8 — ожидание......
  [  2] cdn.example.com → 5.6.7.8 — ожидание......
  [  3] cdn.example.com → 1.2.3.4

✅ DNS обновлён
✅ Сервис перезапущен — ACME переиздаст сертификат автоматически
```

### Бэкап / Восстановление

Запускает официальный скрипт [Remnawave backup-restore](https://github.com/Remnawave/backup-restore). При повторном вызове — использует уже установленный `remnawave-backup`.

---

## 📁 Файлы и пути

### Hysteria2

| Путь | Назначение |
|---|---|
| `/etc/hysteria/config.yaml` | Конфигурация сервера |
| `/usr/local/bin/hysteria` | Бинарник |
| `/root/hysteria-{домен}.txt` | URI первого пользователя |
| `/root/hysteria-{домен}.yaml` | Конфиг Clash/Mihomo |
| `/root/hysteria-{домен}.png` | QR-код PNG |
| `/root/hysteria-{домен}-users.txt` | URI всех пользователей |
| `/etc/hy-merger-uris.txt` | URI для merger (если используется) |
| `/usr/local/bin/hy_sub_merger.py` | Merger скрипт |
| `/etc/systemd/system/hy-merger.service` | Systemd-сервис merger |

### Интеграция Hysteria2 ↔ Remnawave

| Путь | Назначение |
|---|---|
| `/opt/hy-webhook/hy-webhook.py` | Webhook-сервис синхронизации |
| `/etc/hy-webhook.env` | Секреты (600, показывается один раз) |
| `/var/lib/hy-webhook/users.json` | БД пользователей для subscription-page |
| `/etc/systemd/system/hy-webhook.service` | Systemd-сервис |
| `/opt/hy-subpage/` | Исходники форка subscription-page |

### Remnawave Panel

| Путь | Назначение |
|---|---|
| `/opt/remnawave/.env` | Конфигурация панели |
| `/opt/remnawave/docker-compose.yml` | Docker Compose |
| `/opt/remnawave/nginx.conf` | Nginx |
| `/opt/remnawave/backups/` | Бэкапы (хранятся 7 дней) |
| `/opt/remnawave/index.html` | Orion шаблон (если установлен) |
| `/opt/remnawave/app-config.json` | Брендинг подписки |
| `/opt/remnawave/.panel_token` | Кэш API-токена для CLI операций |
| `/usr/local/bin/remnawave_panel` | Скрипт управления (`rp`) |

### MTProxy (systemd)

| Путь | Назначение |
|---|---|
| `/usr/local/bin/telemt` | Бинарник |
| `/etc/telemt/telemt.toml` | Конфиг |
| `/etc/systemd/system/telemt.service` | Systemd-сервис |

---

## ⌨️ Ручное управление

### Hysteria2

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -f
systemctl restart hysteria-server
nano /etc/hysteria/config.yaml
```

### Интеграция Hysteria2 ↔ Remnawave

```bash
# Webhook
journalctl -u hy-webhook -f
curl -s http://127.0.0.1:8766/health
systemctl restart hy-webhook

# Merger
systemctl status hy-merger
journalctl -u hy-merger -f

# Обновить URI после добавления пользователей
printf '%s\n' $(cat /root/hysteria-*.txt | grep hy2://) > /etc/hy-merger-uris.txt
systemctl restart hy-merger

# Subscription page
docker logs remnawave-subscription-page --tail=50
```

### MTProxy

```bash
systemctl status telemt
journalctl -u telemt -f
systemctl reload telemt    # hot reload без разрыва соединений
systemctl restart telemt
```

### Remnawave Panel

```bash
cd /opt/remnawave
docker compose ps
docker compose logs -f remnawave
docker compose restart
```

---

## 🔧 Устранение проблем

### Hysteria2 не запускается

```bash
journalctl -u hysteria-server -n 50 --no-pager
```

Частые причины: порт занят, домен не резолвится, ACME не получил сертификат.

### ACME не выдаёт сертификат

```bash
ufw allow 80/tcp
systemctl restart hysteria-server

# Проверить что порт 80 свободен
ss -tulpn | grep :80

# Проверить DNS (должны совпадать)
curl -4 ifconfig.me
dig +short cdn.example.com
```

### Subscription-page: ERR_HTTP2_PROTOCOL_ERROR в браузере

Ошибка возникает если frontend не был собран при сборке Docker-образа. Пересборка:

```bash
cd /opt/hy-subpage

# Сборка frontend
docker run --rm -v "$(pwd)/frontend:/app" -w /app node:24-alpine \
    sh -c "npm ci && npm run cb"

# Пересборка образа
docker build --no-cache -t remnawave-sub-hy:local .

# Перезапуск
cd /opt/remnawave
docker compose up -d --force-recreate remnawave-subscription-page
```

> Команда сборки: `npm run cb` (не `npm run build`).

### Subscription-page: hy2:// не появляется в подписке

```bash
# Проверить статус webhook
curl -s http://127.0.0.1:8766/health

# Проверить users.json
cat /var/lib/hy-webhook/users.json

# Синхронизировать вручную
journalctl -u hy-webhook -n 30
```

### Клиент не подключается

```bash
systemctl status hysteria-server
ss -tulpn | grep PORT
ufw status | grep PORT
```

### DNS не обновился после переноса

```bash
dig +short A cdn.example.com
ssh root@NEW_IP systemctl restart hysteria-server
```

### Потерян cookie-ключ от панели

```bash
# Восстановить KEY и VAL
grep -A2 "map \$http_cookie" /opt/remnawave/nginx.conf | head -4

# Открыть прямой доступ на порт 8443
rp open_port
```

---

## 📋 Требования

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 22.04 / 24.04, Debian 11 / 12 |
| Права | root |
| Hysteria2: домен | Отдельный от Panel и MTProxy, A-запись на IP сервера |
| Hysteria2: порт 80 | Скрипт открывает автоматически для ACME и закрывает после |
| Panel: порт 443 | Свободен до установки |
| MTProxy: порт | 8443 или другой из списка Telegram |

---

## 🔧 Внутренние утилиты

| Функция | Описание |
|---|---|
| `ok "текст"` | Зелёный вывод `✓ текст` |
| `info "текст"` | Синий вывод `· текст` |
| `warn "текст"` | Жёлтый вывод `⚠ текст` |
| `err "текст"` | Красный вывод + exit 1 |
| `step "текст"` | Заголовок шага установки `── текст ──` |
| `header "текст"` | Заголовок раздела (с clear) |
| `section "текст"` | Секция внутри экрана (без clear) |
| `confirm "вопрос" [y\|n]` | Интерактивное подтверждение с опциональным default |
| `ask VAR "подсказка" [default]` | Обязательный ввод в переменную через `printf -v` |
| `gen_user` | 8 случайных букв `[a-zA-Z]` |
| `gen_password` | Пароль 24 символа (upper+lower+digit+special) |
| `gen_secret` | 16 hex-символов |
| `gen_hex64` | 64 символа `[a-zA-Z0-9]` |
| `check_dns "domain"` | Проверка A-записи против IP сервера |
| `validate_domain "domain"` | Валидация FQDN |
| `spinner PID "текст"` | Анимация ожидания |
| `ask_ssh_target` | Ввод IP/порт/пользователь/пароль SSH (результат в `_SSH_*`) |
| `init_ssh_helpers [mode]` | Инициализация `RUN` и `PUT` для SSH-миграции |
| `remote_install_deps [panel\|full]` | Установка зависимостей на удалённом сервере |
| `panel_api_request` | HTTP-запросы к API Remnawave |
| `panel_get_token` | Авторизация в панели с кэшем токена |
| `_main_menu_refresh_status` | Параллельное обновление статусов и версий (~15ms) |

---

## ⚠️ Известные ограничения

| # | Описание | Статус |
|---|---|---|
| 1 | SSH-ввод дублировался в 5 функциях миграции | ✅ `ask_ssh_target()` + `init_ssh_helpers()` |
| 2 | Блоки remote-зависимостей дублировались в `do_migrate` и `migrate_all` | ✅ `remote_install_deps [panel\|full]` |
| 3 | `panel_api_request()` не проверяет HTTP-статус ответа | Допустимо — caller обрабатывает |
| 4 | `panel_submenu_manage` вызывал несуществующие команды `rp` | ✅ `health`/`open_port`/`close_port` |
| 5 | `panel_subpage_branding`: переменные инъецировались в Python heredoc | ✅ передача через env vars |
| 6 | `hysteria_show_links`: QR рендерился без проверки `qrencode` | ✅ guard + fallback-сообщение |
| 7 | `rp show_menu` использовал устаревший стиль с рамками `╔╗` | ✅ новый стиль с `──` |
| 8 | `hy-sub-install.sh`: frontend собирался командой `npm run build` (не существует) | ⚠️ Нужна команда `npm run cb` |
| 9 | `hy-sub-install.sh`: патч вставляется до проверки `if (!subscriptionDataResponse)` — при ошибке панели inject выполняется на null | ⚠️ Требует исправления порядка вставки |
