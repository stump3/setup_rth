#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Hysteria2 → Remnawave Subscription Integration                 ║
# ║  Устанавливает:                                                  ║
# ║  1. hy-webhook  — синхронизация пользователей через вебхук      ║
# ║  2. Форк subscription-page — добавляет Hysteria2 URI в подписку ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

STEP_CURRENT=0
STEP_TOTAL=6

ok()     { echo -e "${GREEN}  ✓ $*${NC}"; }
info()   { echo -e "${DIM}    $*${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()    { echo -e "\n${RED}  ✗  $*${NC}\n"; exit 1; }
detail() { echo -e "${DIM}    → $*${NC}"; }   # авто-определённое значение

step() {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━ [${STEP_CURRENT}/${STEP_TOTAL}] $* ━━━${NC}"
    echo ""
}

# Статус с пометкой источника (auto/manual)
cfg_auto()   { echo -e "${GREEN}  ✓ ${WHITE}$1${NC}${DIM} = $2  (авто)${NC}"; }
cfg_manual() { echo -e "${YELLOW}  ✎ ${WHITE}$1${NC}${DIM} = $2  (вручную)${NC}"; }
cfg_gen()    { echo -e "${CYAN}  ⚙ ${WHITE}$1${NC}${DIM} = $2  (сгенерировано)${NC}"; }

[ "$(id -u)" -ne 0 ] && err "Запустите от root"
[ -d /opt/remnawave ] || err "Remnawave не установлена"
[ -f /etc/hysteria/config.yaml ] || err "Hysteria2 не установлена"

# ── Режим: установка или переустановка ───────────────────────────
IS_INSTALLED=false
[ -f /etc/systemd/system/hy-webhook.service ] && IS_INSTALLED=true

if $IS_INSTALLED; then
    # Читаем текущий secret из сервиса
    EXISTING_SECRET=$(grep "^Environment=WEBHOOK_SECRET=" /etc/systemd/system/hy-webhook.service         | cut -d= -f3 || echo "")

    echo ""
    echo -e "${BOLD}${YELLOW}  ↻  Обнаружена существующая установка${NC}"
    echo ""
    echo -e "  ${DIM}hy-webhook:        ${NC}$(systemctl is-active hy-webhook 2>/dev/null || echo inactive)"
    echo -e "  ${DIM}Пользователей в БД:${NC} $(python3 -c "import json; d=json.load(open('/var/lib/hy-webhook/users.json')); print(len(d))" 2>/dev/null || echo "?")"
    echo ""
    echo -e "${BOLD}${WHITE}  Что обновить?${NC}"
    echo ""
    echo -e "  1) Всё заново          ${DIM}— полная переустановка, новый secret${NC}"
    echo -e "  2) Только webhook      ${DIM}— сервис + конфиг, secret сохранится${NC}"
    echo -e "  3) Только subscription ${DIM}— пересборка Docker-образа форка${NC}"
    echo -e "  0) Отмена"
    echo ""
    read -rp "  Выбор [0-3]: " REINSTALL_MODE < /dev/tty

    case "$REINSTALL_MODE" in
        1)
            echo ""
            echo -e "  ${YELLOW}Будет выполнено:${NC} полная переустановка, новый webhook secret"
            echo -e "  ${DIM}Затронуто: hy-webhook.service, config.yaml, docker-compose.yml${NC}"
            echo ""
            read -rp "  Продолжить? [y/N]: " _confirm < /dev/tty
            [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
            STEP_TOTAL=6
            ;;
        2)
            echo ""
            echo -e "  ${YELLOW}Будет выполнено:${NC} обновление hy-webhook, secret сохраняется"
            echo -e "  ${DIM}Затронуто: hy-webhook.py, hy-webhook.service${NC}"
            echo -e "  ${DIM}Не затронуто: docker-compose.yml, subscription-page${NC}"
            echo ""
            read -rp "  Продолжить? [y/N]: " _confirm < /dev/tty
            [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
            WEBHOOK_SECRET="${EXISTING_SECRET}"
            STEP_TOTAL=3
            ;;
        3)
            echo ""
            echo -e "  ${YELLOW}Будет выполнено:${NC} пересборка и перезапуск subscription-page"
            echo -e "  ${DIM}Затронуто: Docker-образ, docker-compose.yml${NC}"
            echo -e "  ${DIM}Не затронуто: hy-webhook, пользователи${NC}"
            echo ""
            read -rp "  Продолжить? [y/N]: " _confirm < /dev/tty
            [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
            STEP_TOTAL=2
            ;;
        0|"")
            echo "Отменено."
            exit 0
            ;;
        *)
            err "Неверный выбор"
            ;;
    esac
fi

# ── Читаем параметры ─────────────────────────────────────────────
step "Конфигурация"

# Hysteria домен из конфига
HY_DOMAIN=$(grep -A2 'domains:' /etc/hysteria/config.yaml | grep -- '- ' | head -1 | tr -d ' -')
HY_PORT=$(grep '^listen:' /etc/hysteria/config.yaml | grep -oE '[0-9]+$')

if [ -n "$HY_DOMAIN" ]; then
    cfg_auto "Домен" "$HY_DOMAIN"
else
    warn "Домен не найден в конфиге Hysteria2"
    read -rp "  Введите домен вручную: " HY_DOMAIN < /dev/tty
    cfg_manual "Домен" "$HY_DOMAIN"
fi

if [ -n "$HY_PORT" ]; then
    cfg_auto "Порт" "$HY_PORT"
else
    HY_PORT="443"
    cfg_manual "Порт" "$HY_PORT (по умолчанию)"
fi

echo ""
read -rp "  Название подключения [🇩🇪 Germany Hysteria2]: " HY_NAME < /dev/tty
HY_NAME="${HY_NAME:-🇩🇪 Germany Hysteria2}"
cfg_manual "Название" "$HY_NAME"

# Читаем SUB_PUBLIC_DOMAIN из .env
SUB_DOMAIN=$(grep "^SUB_PUBLIC_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d '"')
PANEL_URL=$(grep "^APP_PORT=" /opt/remnawave/.env 2>/dev/null && echo "http://127.0.0.1:3000" || echo "http://127.0.0.1:3000")

# Генерируем webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
cfg_gen "Webhook secret" "${WEBHOOK_SECRET:0:8}…"

# ── Шаг 1: Webhook сервис ────────────────────────────────────────
# Пропускаем webhook если выбран режим "только subscription"
if $IS_INSTALLED && [ "${REINSTALL_MODE:-1}" = "3" ]; then
    :
else
step "Webhook сервис"

mkdir -p /opt/hy-webhook /var/lib/hy-webhook

cat > /opt/hy-webhook/hy-webhook.py << 'PYEOF'
#!/usr/bin/env python3
import hashlib, hmac, json, logging, os, re, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

WEBHOOK_SECRET  = os.environ.get("WEBHOOK_SECRET", "")
HYSTERIA_CONFIG = os.environ.get("HYSTERIA_CONFIG", "/etc/hysteria/config.yaml")
USERS_DB        = os.environ.get("USERS_DB", "/var/lib/hy-webhook/users.json")
LISTEN_PORT     = int(os.environ.get("LISTEN_PORT", "8766"))
HYSTERIA_SVC    = os.environ.get("HYSTERIA_SVC", "hysteria-server")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", handlers=[logging.StreamHandler(sys.stdout)])
log = logging.getLogger("hy-webhook")

def load_users():
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    try:
        with open(USERS_DB) as f: return json.load(f)
    except: return {}

def save_users(users):
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f: json.dump(users, f, indent=2)

def gen_password(username):
    seed = f"{username}:{WEBHOOK_SECRET}"
    return hashlib.sha256(seed.encode()).hexdigest()[:32]

def reload_hysteria():
    try:
        r = subprocess.run(["systemctl", "reload-or-restart", HYSTERIA_SVC], capture_output=True, text=True, timeout=10)
        if r.returncode == 0: log.info("Hysteria2 перезапущен")
        else: log.warning(f"Ошибка перезапуска: {r.stderr}")
    except Exception as e: log.error(f"Не удалось перезапустить: {e}")

def update_hysteria_config(users):
    try:
        with open(HYSTERIA_CONFIG) as f: config = f.read()
        lines = ["  userpass:"]
        for u, p in users.items():
            safe = re.sub(r'[^\w\-.]', '_', u)
            lines.append(f'    {safe}: "{p}"')
        new_block = "\n".join(lines)
        pattern = r'(\s*userpass:\s*\n(?:[ \t]+[^\n]+\n?)*)'
        if re.search(pattern, config):
            config = re.sub(pattern, "\n" + new_block + "\n", config)
        else:
            config = re.sub(r'(auth:\s*\n\s*type:\s*userpass\s*\n)', r'\1' + new_block + "\n", config)
        with open(HYSTERIA_CONFIG, "w") as f: f.write(config)
        log.info(f"Конфиг обновлён, пользователей: {len(users)}")
        return True
    except Exception as e:
        log.error(f"Ошибка обновления конфига: {e}"); return False

def verify_signature(body, signature):
    if not WEBHOOK_SECRET: return True
    expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature.lower().replace("sha256=", ""))

def process_event(payload):
    scope = payload.get("scope", "")
    event = payload.get("event", "")
    data  = payload.get("data", {})
    if scope != "user": return
    username = data.get("username", "")
    if not username: return
    log.info(f"Событие: {event}, пользователь: {username}")
    users = load_users()
    changed = False
    safe = re.sub(r'[^\w\-.]', '_', username)
    if event == "user.created":
        if safe not in users:
            users[safe] = gen_password(safe); changed = True
            log.info(f"Добавлен: {safe}")
    elif event in ("user.deleted", "user.disabled"):
        if safe in users:
            del users[safe]; changed = True
            log.info(f"Удалён: {safe}")
    elif event in ("user.enabled",):
        if safe not in users:
            users[safe] = gen_password(safe); changed = True
            log.info(f"Восстановлен: {safe}")
    if changed:
        save_users(users)
        if update_hysteria_config(users): reload_hysteria()

class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/health":
            users = load_users()
            body = json.dumps({"status": "ok", "users": len(users)}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        sig = self.headers.get("X-Webhook-Signature", "")
        if WEBHOOK_SECRET and not verify_signature(body, sig):
            log.warning("Неверная подпись"); self.send_response(401); self.end_headers(); return
        try:
            process_event(json.loads(body))
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        except Exception as e:
            log.error(f"Ошибка: {e}"); self.send_response(500); self.end_headers()

def main():
    log.info(f"Запуск hy-webhook на порту {LISTEN_PORT}")
    users = load_users()
    if users:
        log.info(f"Загружено {len(users)} пользователей")
        update_hysteria_config(users)
    HTTPServer(("127.0.0.1", LISTEN_PORT), WebhookHandler).serve_forever()

if __name__ == "__main__": main()
PYEOF

chmod +x /opt/hy-webhook/hy-webhook.py
ok "hy-webhook.py создан"
info "/opt/hy-webhook/hy-webhook.py"

# Systemd сервис
cat > /etc/systemd/system/hy-webhook.service << SVCEOF
[Unit]
Description=Remnawave → Hysteria2 Webhook Sync
After=network.target hysteria-server.service

[Service]
Type=simple
Environment=WEBHOOK_SECRET=${WEBHOOK_SECRET}
Environment=HYSTERIA_CONFIG=/etc/hysteria/config.yaml
Environment=USERS_DB=/var/lib/hy-webhook/users.json
Environment=LISTEN_PORT=8766
Environment=HYSTERIA_SVC=hysteria-server
ExecStart=/usr/bin/python3 /opt/hy-webhook/hy-webhook.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now hy-webhook
sleep 2

if systemctl is-active --quiet hy-webhook; then
    ok "hy-webhook запущен"
    info "$(systemctl status hy-webhook --no-pager | grep Active: | sed 's/.*Active: //)"
else
    warn "hy-webhook не запустился"
    info "Диагностика: journalctl -u hy-webhook -n 20"
fi
fi  # end skip mode3 webhook

# ── Шаг 2: Синхронизируем существующих пользователей ────────────
if $IS_INSTALLED && [ "${REINSTALL_MODE:-1}" = "3" ]; then
    :
else
step "Синхронизация пользователей"

# Читаем существующих из конфига Hysteria
python3 << SYNCEOF
import re, json, hashlib, os

HYSTERIA_CONFIG = "/etc/hysteria/config.yaml"
USERS_DB = "/var/lib/hy-webhook/users.json"
WEBHOOK_SECRET = "${WEBHOOK_SECRET}"

with open(HYSTERIA_CONFIG) as f:
    config = f.read()

# Парсим существующих пользователей из userpass блока
users = {}
in_userpass = False
for line in config.split('\n'):
    if 'userpass:' in line:
        in_userpass = True
        continue
    if in_userpass:
        m = re.match(r'\s{4}(\S+):\s*"([^"]+)"', line)
        if m:
            users[m.group(1)] = m.group(2)
        elif line.strip() and not line.startswith(' '):
            break

os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
with open(USERS_DB, 'w') as f:
    json.dump(users, f, indent=2)

print(f"Синхронизировано пользователей: {len(users)}")
for u in users:
    print(f"  - {u}")
SYNCEOF

ok "Пользователи синхронизированы"
fi  # end skip sync

# ── Шаг 3: Включаем вебхуки в панели ────────────────────────────
if $IS_INSTALLED && [ "${REINSTALL_MODE:-1}" != "1" ]; then
    :  # При частичном обновлении не трогаем .env
else
step "Вебхуки Remnawave"

# Обновляем .env
sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=true|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=http://127.0.0.1:8766/webhook|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=${WEBHOOK_SECRET}|" /opt/remnawave/.env

ok "Вебхуки включены в .env"
info "WEBHOOK_URL=http://127.0.0.1:8766/webhook"

# Перезапускаем панель
info "Перезапускаем Remnawave..."
cd /opt/remnawave && docker compose restart remnawave >/dev/null 2>&1
ok "Remnawave перезапущена"
fi  # end skip webhooks

# ── Шаг 4: Форк subscription-page ───────────────────────────────
step "Форк subscription-page"

# Проверяем есть ли Docker
command -v docker &>/dev/null || err "Docker не найден"

# Определяем текущий образ subscription-page
CURRENT_IMAGE=$(grep "image:" /opt/remnawave/docker-compose.yml | grep -i "subscription" | awk '{print $2}' | head -1)
info "Текущий образ: $CURRENT_IMAGE"

# Создаём директорию для форка
mkdir -p /opt/hy-subpage

# Скачиваем исходники subscription-page
info "Скачиваем исходники subscription-page..."
SUBPAGE_VERSION=$(echo "$CURRENT_IMAGE" | grep -oP ':\K[^:]+$' || echo "latest")
curl -fsSL "https://github.com/remnawave/subscription-page/archive/refs/heads/main.tar.gz" \
    -o /opt/hy-subpage/source.tar.gz 2>/dev/null \
    || { warn "Не удалось скачать исходники — нужен интернет на сервере"; exit 1; }

tar -xzf /opt/hy-subpage/source.tar.gz -C /opt/hy-subpage --strip-components=1
rm /opt/hy-subpage/source.tar.gz
ok "Исходники скачаны"

# Применяем патч к root.service.ts
ROOTSVC="/opt/hy-subpage/backend/src/modules/root/root.service.ts"
AXSVC="/opt/hy-subpage/backend/src/common/axios/axios.service.ts"

# Патч 1: Добавляем импорт fs
sed -i "s|import { nanoid } from 'nanoid';|import { nanoid } from 'nanoid';\nimport * as fs from 'node:fs';|" "$ROOTSVC"

# Патч 2: Инжектируем Hysteria2 URI в ответ подписки
python3 << PATCHEOF
import re

with open("$ROOTSVC") as f:
    content = f.read()

old = "            if (!subscriptionDataResponse) {\n                res.socket?.destroy();\n                return;\n            }\n\n            if (subscriptionDataResponse.headers) {"

new = """            if (!subscriptionDataResponse) {
                res.socket?.destroy();
                return;
            }

            // ── Hysteria2 URI injection ──────────────────────────
            try {
                const hyUri = await this.getHysteriaUriForUser(shortUuidLocal, clientIp);
                if (hyUri) {
                    const raw = subscriptionDataResponse.response as string;
                    let lines: string[] = [];
                    try {
                        lines = Buffer.from(raw, 'base64').toString('utf-8')
                            .split('\\n').filter(l => l.trim());
                    } catch {
                        lines = raw.split('\\n').filter(l => l.trim());
                    }
                    lines.push(hyUri);
                    subscriptionDataResponse = {
                        ...subscriptionDataResponse,
                        response: Buffer.from(lines.join('\\n')).toString('base64'),
                    };
                }
            } catch (e) {
                this.logger.warn('Hysteria2 inject error: ' + e);
            }
            // ─────────────────────────────────────────────────────

            if (subscriptionDataResponse.headers) {"""

if old in content:
    content = content.replace(old, new)
    print("OK: inject добавлен")
else:
    print("WARN: inject не найден — возможно версия отличается")

# Добавляем метод getHysteriaUriForUser перед последней }
method = '''
    private async getHysteriaUriForUser(
        shortUuid: string,
        clientIp: string,
    ): Promise<string | null> {
        try {
            const usersDb = process.env.HY_USERS_DB || '/var/lib/hy-webhook/users.json';
            const hyDomain = process.env.HY_DOMAIN || '';
            const hyPort = process.env.HY_PORT || '8443';
            const hyName = process.env.HY_NAME || 'Hysteria2';
            if (!hyDomain) return null;
            let users: Record<string, string> = {};
            try {
                const raw = fs.readFileSync(usersDb, 'utf-8');
                users = JSON.parse(raw);
            } catch { return null; }
            const userInfo = await this.axiosService.getUserByShortUuid(clientIp, shortUuid);
            if (!userInfo.isOk || !userInfo.response) return null;
            const username = (userInfo.response as any).response?.username;
            if (!username) return null;
            const safeUsername = username.replace(/[^\\w\\-.]/g, '_');
            const password = users[safeUsername] || users[username];
            if (!password) return null;
            return 'hy2://' + encodeURIComponent(safeUsername) + ':' + password +
                '@' + hyDomain + ':' + hyPort +
                '?sni=' + hyDomain + '&alpn=h3&insecure=0#' + encodeURIComponent(hyName);
        } catch (e) {
            this.logger.warn('getHysteriaUriForUser error: ' + e);
            return null;
        }
    }
}
'''
content = content.rstrip()
if content.endswith('}'):
    content = content[:-1].rstrip() + '\n' + method

with open("$ROOTSVC", 'w') as f:
    f.write(content)
print("OK: метод добавлен")
PATCHEOF

# Патч 3: Добавляем getUserByShortUuid в axios.service.ts
python3 << AXPATCHEOF
with open("$AXSVC") as f:
    content = f.read()

method = '''
    public async getUserByShortUuid(
        clientIp: string,
        shortUuid: string,
    ): Promise<any> {
        try {
            const { data } = await this.axiosInstance.request({
                method: 'GET',
                url: 'api/users/get-by/short-uuid/' + shortUuid,
                headers: { 'x-remnawave-real-ip': clientIp },
            });
            return { isOk: true, response: data };
        } catch (error: any) {
            this.logger.error('Error in GetUserByShortUuid: ' + error.message);
            return { isOk: false };
        }
    }
'''

# Вставляем перед последним методом getSubscription
insert_before = "    public async getSubscription("
if insert_before in content:
    content = content.replace(insert_before, method + "\n    public async getSubscription(", 1)
    print("OK: getUserByShortUuid добавлен")
else:
    print("WARN: место вставки не найдено")

with open("$AXSVC", 'w') as f:
    f.write(content)
AXPATCHEOF

ok "Патчи применены"

# Собираем Docker образ
info "Сборка Docker образа (это займёт 2-5 минут)..."
cd /opt/hy-subpage

# Сначала собираем frontend если нужно
if [ ! -d "frontend/dist" ]; then
    info "Сборка frontend..."
    docker run --rm -v "$(pwd)/frontend:/app" -w /app node:24-alpine \
        sh -c "npm ci && npm run build" >/dev/null 2>&1 \
        && ok "Frontend собран" \
        || warn "Ошибка сборки frontend — используем существующий образ"
fi

docker build -t remnawave-sub-hy:local . 2>&1 | tail -5
ok "Docker образ собран: remnawave-sub-hy:local"

# ── Шаг 5: Обновляем docker-compose.yml ─────────────────────────
step "Docker Compose"

python3 << COMPOSEEOF
import re

with open("/opt/remnawave/docker-compose.yml") as f:
    content = f.read()

# Меняем образ subscription-page
content = re.sub(
    r'(remnawave-subscription-page:.*?\n\s+image:\s*)remnawave/subscription-page:[^\n]+',
    r'\1remnawave-sub-hy:local',
    content,
    flags=re.DOTALL
)

# Добавляем environment и volumes к subscription-page
env_block = """    environment:
      - HY_DOMAIN=${HY_DOMAIN}
      - HY_PORT=${HY_PORT}
      - HY_NAME=${HY_NAME}
      - HY_USERS_DB=/var/lib/hy-webhook/users.json
    volumes:
      - /var/lib/hy-webhook:/var/lib/hy-webhook:ro"""

# Находим блок remnawave-subscription-page и добавляем после image:
pattern = r'(container_name: remnawave-subscription-page\n)'
if re.search(pattern, content):
    content = re.sub(pattern, r'\1' + env_block + '\n', content)
    print("OK: docker-compose обновлён")
else:
    print("WARN: блок subscription-page не найден")

with open("/opt/remnawave/docker-compose.yml", "w") as f:
    f.write(content)
COMPOSEEOF

# Перезапускаем subscription-page
cd /opt/remnawave
docker compose up -d remnawave-subscription-page 2>&1 | tail -3
sleep 3

if docker ps --format '{{.Names}}' | grep -q "remnawave-subscription-page"; then
    ok "subscription-page запущен с форком"
    info "Образ: remnawave-sub-hy:local"
else
    warn "Контейнер не запустился"
    info "Диагностика: docker logs remnawave-subscription-page"
fi

# ── Итог ────────────────────────────────────────────────────────

# Проверяем статусы сервисов
HY_WH_STATUS=$(systemctl is-active hy-webhook 2>/dev/null || echo "inactive")
HY_SVC_STATUS=$(systemctl is-active hysteria-server 2>/dev/null || echo "inactive")
SUB_STATUS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription-page" && echo "running" || echo "stopped")

_svc_line() {
    local name="$1" status="$2"
    if [ "$status" = "active" ] || [ "$status" = "running" ]; then
        echo -e "  ${GREEN}✓${NC}  $name"
    else
        echo -e "  ${RED}✗${NC}  $name ${DIM}($status)${NC}"
    fi
}

echo ""
echo -e "${BOLD}${GREEN}  ✅ Установка завершена!${NC}"
echo ""
echo -e "${BOLD}${WHITE}  Статус сервисов${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
_svc_line "hy-webhook" "$HY_WH_STATUS"
_svc_line "hysteria-server" "$HY_SVC_STATUS"
_svc_line "subscription-page" "$SUB_STATUS"
echo ""
echo -e "${BOLD}${WHITE}  Конфигурация${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Домен   ${NC}${HY_DOMAIN}"
echo -e "  ${DIM}Порт    ${NC}${HY_PORT}"
echo -e "  ${DIM}Название${NC}${HY_NAME}"
echo ""
if $IS_INSTALLED && [ "${REINSTALL_MODE:-1}" = "2" ]; then
    echo -e "${BOLD}${WHITE}  Webhook secret${NC}${DIM} (не изменился)${NC}"
    echo -e "  ${DIM}────────────────────────────${NC}"
    echo -e "  ${DIM}${WEBHOOK_SECRET}${NC}"
else
    echo -e "${BOLD}${YELLOW}  ⚠  Webhook secret — сохраните сейчас, больше не показывается!${NC}"
    echo -e "  ${DIM}────────────────────────────${NC}"
    echo -e "  ${CYAN}${WEBHOOK_SECRET}${NC}"
fi
echo ""
echo -e "${BOLD}${WHITE}  Проверка${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Health:  ${NC}curl -s http://127.0.0.1:8766/health"
echo -e "  ${DIM}Логи:    ${NC}journalctl -u hy-webhook -f"
echo -e "  ${DIM}Контейнер: ${NC}docker logs remnawave-subscription-page"
echo ""
echo -e "${BOLD}${WHITE}  Что дальше${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  • Новые пользователи панели получат Hysteria2 URI автоматически"
echo -e "  • Существующим пользователям — попросите обновить подписку в клиенте"
echo ""
