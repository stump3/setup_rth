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
  SERVER-MANAGER  v2603.172335
  ────────────────────────────────────────────

  Remnawave Panel  ● запущена  v2.4.1
  MTProxy (telemt) ● запущен (systemd)
  Hysteria2        ○ не установлена

  ────────────────────────────────────────────

  1)  🛡️   Remnawave Panel
  2)  📡  MTProxy (telemt)
  3)  🚀  Hysteria2
  4)  📦  Перенос

  0)  Выход
```

Статусы: `● запущен` — работает (с версией если доступна), `◐ остановлен` — установлен но не запущен, `○ не установлен` — отсутствует.

---

## 🛡️ Раздел 1 — Remnawave Panel

VPN-панель управления. Архитектура eGames: nginx в `network_mode: host`, Xray (remnanode) принимает Reality-трафик на порту 443, cookie-защита на вход.

### Подменю

```
  1) Установить
  2) Управление (remnawave_panel)
  0) Назад
```

### Параметры установки

| Параметр | Пример | Описание |
|---|---|---|
| Режим | 1 / 2 | 1 — панель + нода, 2 — только панель |
| Домен панели | panel.example.com | Основной домен |
| Домен подписок | sub.example.com | Для клиентских конфигов |
| Домен selfsteal | node.example.com | Для Reality |
| Метод SSL | 1 / 2 / 3 | Cloudflare / ACME standalone / Gcore |
| Логин суперадмина | авто | Случайные 8 букв `[a-zA-Z]{8}`, генерируется автоматически |
| Пароль суперадмина | авто | Случайный, генерируется автоматически |

> ⚠️ **Сохраните логин, пароль и URL с cookie-ключом.** Логин и пароль генерируются автоматически — восстановить их нельзя. Без cookie-URL войти в панель невозможно.  
> `https://panel.example.com/auth/login?KEY=VAL`

### Как работает cookie-защита

Nginx защищает панель двумя случайными словами, которые генерируются при установке:

- **KEY** — имя cookie и query-параметра (`[a-zA-Z]{8}`, например `xKtBpWnR`)
- **VAL** — значение cookie (`[a-zA-Z]{8}`, например `mQaYjZvL`)

При первом переходе по URL `?KEY=VAL` nginx выставляет cookie через `Set-Cookie` со сроком жизни 1 год. После этого браузер предъявляет её при каждом запросе и URL больше не нужен.

```nginx
# Как это выглядит в nginx.conf:
map $http_cookie $auth_cookie {
    default 0;
    "~*xKtBpWnR=mQaYjZvL" 1;   # ← авторизован по cookie
}
map $arg_xKtBpWnR $auth_query {
    default 0;
    "mQaYjZvL" 1;               # ← авторизован по query-параметру
}
map "$auth_cookie$auth_query" $authorized {
    "~1" 1;   # хотя бы одно из двух совпало
    default 0;
}
```

> Если URL потерян — используйте `rp open_port`, чтобы открыть прямой доступ на порт 8443 без cookie-проверки. Потом восстановите URL из `nginx.conf`:
> ```bash
> grep -A2 "map \$arg_" /opt/remnawave/nginx.conf | head -4
> # Первый аргумент — KEY, значение в кавычках — VAL
> ```

### Команды управления (`rp`)

```bash
rp                  # интерактивное меню
rp status           # статус контейнеров
rp logs [svc]       # логи: panel / nginx / sub / node
rp restart [svc]    # перезапуск: all / nginx / panel / sub / node
rp ssl              # обновить SSL
rp backup           # бэкап БД и конфигов
rp health           # диагностика
rp open_port        # открыть порт 8443 (если потерян cookie-ключ)
rp close_port       # закрыть порт 8443
rp migrate          # перенос на другой сервер
```

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
  0)  ◀️   Назад
```

### Подписка (пункт 4)

```
  1)  📤  Опубликовать подписку
  2)  🔗  Объединить с подпиской Remnawave (merger)
  3)  🪝  Интеграция с Remnawave (webhook + sub-page)
  0)  ◀️   Назад
```

> Пункт **3 — Интеграция с Remnawave** запускает полную интеграцию через webhook-синхронизацию пользователей и форк subscription-page. Hysteria2 URI автоматически появятся в подписке клиентов.

### Требования перед установкой

> ⚠️ Отдельный домен с A-записью на IP сервера (например `cdn.example.com`).  
> Порт 80/tcp — скрипт открывает **автоматически** перед получением сертификата и закрывает после.

### Совместимость

| Компонент | Конфликт | Решение |
|---|---|---|
| Xray/Reality UDP 443 | ⚠️ есть | Выбрать другой порт — скрипт проверит автоматически |
| nginx TCP 80/443 | ℹ️ частично | Порт 80 открывается временно только для ACME |
| MTProxy 2053/8443 | ℹ️ частично | Скрипт показывает занятые порты в меню |
| certbot / Let's Encrypt | ✅ нет | Hysteria использует собственный ACME-клиент |

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

### Добавить пользователя

При добавлении нового пользователя скрипт:
- Показывает список уже существующих пользователей
- Если имя занято — предлагает ввести другое, заменить пароль или отменить
- Предлагает выбрать название подключения из уже использованных или ввести новое
- Генерирует URI и QR-код

### Пользователи и ссылки (пункт 6)

Показывает всех пользователей из конфига. Выберите нужного — получите URI и QR-код повторно.

### Результат установки

```
hy2://Admin:Pass@cdn.example.com:8443?sni=cdn.example.com&alpn=h3&insecure=0#Germany Hysteria2
```

Файлы сохраняются в `/root/`:

| Файл | Содержимое |
|---|---|
| `hysteria-{домен}.txt` | URI подключения |
| `hysteria-{домен}.yaml` | Конфиг Clash/Mihomo |
| `hysteria-{домен}.png` | QR-код PNG |
| `hysteria-{домен}-users.txt` | URI всех добавленных пользователей |

---

## 📦 Раздел 4 — Перенос

Перенос сервисов на новый сервер через SSH + пароль. `sshpass` устанавливается автоматически.

```
  1) Перенести Remnawave Panel
  2) Перенести MTProxy (telemt, только systemd)
  3) Перенести Hysteria2
  4) Перенести всё (Panel + MTProxy + Hysteria2)
  0) Назад
```

### Параметры подключения

| Параметр | По умолчанию |
|---|---|
| IP нового сервера | — |
| SSH-порт | 22 |
| Пользователь | root |
| Пароль SSH | скрытый ввод |

### Мониторинг DNS после переноса Hysteria2

После переноса скрипт предлагает ждать обновления DNS и автоматически перезапустить сервис:

```
  [  1] cdn.example.com → 5.6.7.8 — ожидание......
  [  2] cdn.example.com → 5.6.7.8 — ожидание......
  [  3] cdn.example.com → 1.2.3.4

✅ DNS обновлён
✅ Сервис перезапущен — ACME переиздаст сертификат автоматически
```

Таймаут — 60 минут.

### После переноса

```bash
# Остановить старые сервисы
systemctl stop hysteria-server
systemctl stop telemt
cd /opt/remnawave && docker compose down
```

---

## 📁 Файлы и пути

### Hysteria2

| Путь | Назначение |
|---|---|
| `/etc/hysteria/config.yaml` | Конфигурация сервера |
| `/usr/local/bin/hysteria` | Бинарник |
| `/root/hysteria-{домен}.txt` | URI подключения |
| `/root/hysteria-{домен}.yaml` | Конфиг Clash/Mihomo |
| `/root/hysteria-{домен}.png` | QR-код PNG |
| `/root/hysteria-{домен}-users.txt` | URI всех пользователей |

### Remnawave Panel

| Путь | Назначение |
|---|---|
| `/opt/remnawave/.env` | Конфигурация панели |
| `/opt/remnawave/docker-compose.yml` | Docker Compose |
| `/opt/remnawave/nginx.conf` | Nginx |
| `/opt/remnawave/backups/` | Бэкапы |
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
# Открыть порт 80 и перезапустить
ufw allow 80/tcp
systemctl restart hysteria-server

# Проверить что порт 80 свободен
ss -tulpn | grep :80

# Проверить DNS (должны совпадать)
curl -4 ifconfig.me
dig +short cdn.example.com
```

### Клиент не подключается

```bash
systemctl status hysteria-server
ss -tulpn | grep PORT
ufw status | grep PORT
```

### Сменить CA после установки

```bash
nano /etc/hysteria/config.yaml
# Изменить строку: ca: zerossl
systemctl restart hysteria-server
```

### DNS не обновился после переноса

```bash
dig +short A cdn.example.com
ssh root@NEW_IP systemctl restart hysteria-server
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

Функции доступны во всех разделах скрипта:

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
| `ask VAR "подсказка" [default]` | Обязательный ввод в переменную через `printf -v` (безопасно) |
| `gen_user` | 8 случайных букв `[a-zA-Z]` |
| `gen_password` | Пароль 24 символа (upper+lower+digit+special) |
| `gen_secret` | 32 hex-символа |
| `gen_hex64` | 64 символа `[a-zA-Z0-9]` |
| `check_dns "domain"` | Проверка A-записи против IP сервера |
| `validate_domain "domain"` | Валидация FQDN |
| `spinner PID "текст"` | Анимация ожидания |


---

## ⚠️ Известные ограничения

| # | Описание | Статус |
|---|---|---|
| 1 | SSH-ввод (IP/порт/пользователь/пароль) дублировался в 5 функциях миграции | ✅ Исправлено: `ask_ssh_target()` + `init_ssh_helpers()` |
| 2 | Блоки remote-зависимостей дублировались в `do_migrate` и `migrate_all` | ✅ Исправлено: `remote_install_deps [panel\|full]` |
| 3 | `panel_api_request()` не проверяет HTTP-статус ответа | Допустимо — caller обрабатывает |
| 4 | `panel_submenu_manage` вызывал `diag`/`open8443`/`close8443` — несуществующие команды `rp` | ✅ Исправлено: `health`/`open_port`/`close_port` |
| 5 | `panel_subpage_branding`: `$new_name`/`$new_logo` инъецировались в Python heredoc | ✅ Исправлено: передача через env vars |
| 6 | `hysteria_show_links`: QR рендерился без проверки наличия `qrencode` | ✅ Исправлено: guard + fallback-сообщение |
| 7 | `rp show_menu` использовал устаревший стиль с рамками `╔╗` | ✅ Исправлено: новый стиль с `──` |
