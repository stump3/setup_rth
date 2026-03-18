#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — Hysteria2 ↔ Remnawave Subscription Sync       ║
# ║                                                                  ║
# ║  Устанавливает:                                                  ║
# ║  1. hy-webhook  — синхронизация пользователей через вебхук      ║
# ║  2. Форк subscription-page — Hysteria2 URI в подписке            ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
info() { echo -e "${CYAN}ℹ  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
err()  { echo -e "${RED}✗  $*${NC}"; exit 1; }
step() { echo ""; echo -e "${BOLD}${CYAN}━━━ $* ━━━${NC}"; echo ""; }

[ "$(id -u)" -ne 0 ] && err "Запустите от root"
[ -d /opt/remnawave ] || err "Remnawave не установлена"
[ -f /etc/hysteria/config.yaml ] || err "Hysteria2 не установлена"

# ── Параметры ─────────────────────────────────────────────────────
step "Конфигурация"

HY_DOMAIN=$(grep -A2 'domains:' /etc/hysteria/config.yaml | grep -- '- ' | head -1 | tr -d ' -')
HY_PORT=$(grep '^listen:' /etc/hysteria/config.yaml | grep -oE '[0-9]+' | tail -1)
SUB_DOMAIN=$(grep "^SUB_PUBLIC_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d '"' | cut -d'/' -f1)

info "Hysteria2 домен: ${HY_DOMAIN:-не определён}"
info "Hysteria2 порт:  ${HY_PORT:-не определён}"
info "Sub домен:       ${SUB_DOMAIN:-не определён}"

[ -z "$HY_DOMAIN" ]   && { read -rp "  Домен Hysteria2: " HY_DOMAIN < /dev/tty; }
[ -z "$HY_PORT" ]     && { read -rp "  Порт Hysteria2 [8443]: " HY_PORT < /dev/tty; HY_PORT="${HY_PORT:-8443}"; }
[ -z "$SUB_DOMAIN" ]  && { read -rp "  Домен подписок Remnawave: " SUB_DOMAIN < /dev/tty; }

read -rp "  Название подключения [🇩🇪 Germany Hysteria2]: " HY_NAME < /dev/tty
HY_NAME="${HY_NAME:-🇩🇪 Germany Hysteria2}"

WEBHOOK_SECRET=$(openssl rand -hex 32)
info "Webhook secret сгенерирован"

# ── Шаг 1: hy-webhook ────────────────────────────────────────────
step "Установка hy-webhook"

mkdir -p /opt/hy-webhook /var/lib/hy-webhook

# Берём актуальный скрипт из текущей директории или скачиваем
if [ -f "$(dirname "$0")/hy-webhook.py" ]; then
    cp "$(dirname "$0")/hy-webhook.py" /opt/hy-webhook/hy-webhook.py
    info "Используется локальный hy-webhook.py"
elif [ -f /root/hy-webhook.py ]; then
    cp /root/hy-webhook.py /opt/hy-webhook/hy-webhook.py
    info "Используется /root/hy-webhook.py"
else
    info "Скачиваем hy-webhook.py с GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/stump3/setup_rth/main/hy-webhook.py" \
        -o /opt/hy-webhook/hy-webhook.py 2>/dev/null \
        || err "Не удалось скачать hy-webhook.py"
fi

chmod +x /opt/hy-webhook/hy-webhook.py
ok "hy-webhook.py установлен"

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
    ok "hy-webhook запущен (порт 8766)"
else
    warn "hy-webhook не запустился: journalctl -u hy-webhook -n 20"
fi

# ── Шаг 2: Синхронизация пользователей ───────────────────────────
step "Синхронизация существующих пользователей Hysteria2"

python3 << 'SYNCEOF'
import re, json, os

HYSTERIA_CONFIG = "/etc/hysteria/config.yaml"
USERS_DB = "/var/lib/hy-webhook/users.json"

with open(HYSTERIA_CONFIG) as f:
    config = f.read()

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

# ── Шаг 3: Вебхуки в панели ──────────────────────────────────────
step "Настройка вебхуков Remnawave"

sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=true|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=http://127.0.0.1:8766/webhook|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=${WEBHOOK_SECRET}|" /opt/remnawave/.env

ok "Вебхуки включены в .env"
cd /opt/remnawave && docker compose restart remnawave >/dev/null 2>&1
ok "Remnawave перезапущена"

# ── Шаг 4: Форк subscription-page ───────────────────────────────
step "Установка форка subscription-page"

command -v docker &>/dev/null || err "Docker не найден"
mkdir -p /opt/hy-subpage

info "Скачиваем исходники subscription-page..."
curl -fsSL "https://github.com/remnawave/subscription-page/archive/refs/heads/main.tar.gz" \
    -o /opt/hy-subpage/source.tar.gz \
    || err "Не удалось скачать исходники"

tar -xzf /opt/hy-subpage/source.tar.gz -C /opt/hy-subpage --strip-components=1
rm /opt/hy-subpage/source.tar.gz
ok "Исходники скачаны"

ROOTSVC="/opt/hy-subpage/backend/src/modules/root/root.service.ts"
AXSVC="/opt/hy-subpage/backend/src/common/axios/axios.service.ts"

# Патч 1: импорт fs
sed -i "s|import { nanoid } from 'nanoid';|import { nanoid } from 'nanoid';\nimport * as fs from 'node:fs';|" "$ROOTSVC"
ok "Патч 1: импорт fs"

# Патч 2: инжекция URI + метод getHysteriaUriForUser
python3 - << 'PATCHEOF'
import sys

rootsvc = "/opt/hy-subpage/backend/src/modules/root/root.service.ts"
with open(rootsvc) as f:
    content = f.read()

# Инжекция URI перед if (subscriptionDataResponse.headers)
inject = """            // ── Hysteria2 URI injection ──────────────────────────
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
            // ─────────────────────────────────────────────────────"""

old = "            if (subscriptionDataResponse.headers) {"
if old in content:
    content = content.replace(old, inject + "\n\n" + old, 1)
    print("OK: inject добавлен")
else:
    print("WARN: inject не найден")

# Метод getHysteriaUriForUser перед последней }
method = """
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
"""

content = content.rstrip()
if content.endswith('}'):
    content = content[:-1].rstrip() + '\n' + method

with open(rootsvc, 'w') as f:
    f.write(content)
print("OK: getHysteriaUriForUser добавлен")
PATCHEOF
ok "Патч 2: инжекция URI"

# Патч 3: getUserByShortUuid в axios.service.ts
python3 - << 'AXPATCHEOF'
axsvc = "/opt/hy-subpage/backend/src/common/axios/axios.service.ts"
with open(axsvc) as f:
    content = f.read()

method = """
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
"""

insert_before = "    public async getSubscription("
if insert_before in content:
    content = content.replace(insert_before, method + "\n" + insert_before, 1)
    print("OK: getUserByShortUuid добавлен")
else:
    print("WARN: место вставки не найдено")

with open(axsvc, 'w') as f:
    f.write(content)
AXPATCHEOF
ok "Патч 3: getUserByShortUuid"

# ── Сборка образа ─────────────────────────────────────────────────
info "Сборка Docker образа (2-5 минут)..."
cd /opt/hy-subpage

if [ ! -d "frontend/dist" ]; then
    info "Сборка frontend..."
    docker run --rm -v "$(pwd)/frontend:/app" -w /app node:24-alpine \
        sh -c "npm ci && npm run build" >/dev/null 2>&1 \
        && ok "Frontend собран" || warn "Ошибка сборки frontend"
fi

docker build -t remnawave-sub-hy:local . 2>&1 | tail -5
ok "Docker образ собран: remnawave-sub-hy:local"

# ── Шаг 5: docker-compose.yml ────────────────────────────────────
step "Обновление docker-compose.yml"

python3 - << COMPOSEEOF
import re

with open("/opt/remnawave/docker-compose.yml") as f:
    content = f.read()

# Меняем образ
content = re.sub(
    r'(image:\s*)remnawave/subscription-page:[^\n]+',
    r'\1remnawave-sub-hy:local',
    content
)

# Добавляем env и volumes если ещё нет
env_block = """    environment:
      - HY_DOMAIN=${HY_DOMAIN}
      - HY_PORT=${HY_PORT}
      - HY_NAME=${HY_NAME}
      - HY_USERS_DB=/var/lib/hy-webhook/users.json
    volumes:
      - /var/lib/hy-webhook:/var/lib/hy-webhook:ro
"""

marker = 'container_name: remnawave-subscription-page\n'
if marker in content and 'HY_DOMAIN' not in content:
    content = content.replace(marker, marker + env_block)
    print("OK: docker-compose обновлён")
elif 'HY_DOMAIN' in content:
    print("INFO: уже настроен")
else:
    print("WARN: блок subscription-page не найден")

with open("/opt/remnawave/docker-compose.yml", "w") as f:
    f.write(content)
COMPOSEEOF

# ── Шаг 6: nginx location /merge/ на sub домене ──────────────────
step "Настройка nginx"

if [ -f /opt/remnawave/nginx.conf ]; then
    if grep -q "location /merge/" /opt/remnawave/nginx.conf; then
        warn "location /merge/ уже существует"
    else
        python3 - << 'NGINXEOF'
with open('/opt/remnawave/nginx.conf') as f:
    cfg = f.read()

loc = """    location /merge/ {
        proxy_pass http://127.0.0.1:8765/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
"""

# Первое вхождение @redirect — это блок sub домена
if '    location @redirect {' in cfg:
    cfg = cfg.replace('    location @redirect {', loc + '    location @redirect {', 1)
    print("OK: location /merge/ добавлен в sub домен")
else:
    print("WARN: @redirect не найден")

with open('/opt/remnawave/nginx.conf', 'w') as f:
    f.write(cfg)
NGINXEOF
        ok "nginx.conf обновлён"
    fi
fi

# ── Запуск ────────────────────────────────────────────────────────
cd /opt/remnawave
docker compose up -d remnawave-subscription-page 2>&1 | tail -3
docker compose restart remnawave-nginx >/dev/null 2>&1
sleep 3

if docker ps --format '{{.Names}}' | grep -q "remnawave-subscription-page"; then
    ok "subscription-page запущен"
else
    warn "Проверьте: docker logs remnawave-subscription-page"
fi

# ── Итог ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ Установка завершена!                                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${WHITE}Webhook secret (сохраните!):${NC}"
echo -e "  ${CYAN}${WEBHOOK_SECRET}${NC}"
echo ""
echo -e "  ${WHITE}Проверка:${NC}"
echo -e "  ${CYAN}curl -s http://127.0.0.1:8766/health${NC}"
echo ""
echo -e "  ${WHITE}Подписка:${NC}"
echo -e "  ${CYAN}https://${SUB_DOMAIN}/ТОКЕН_ПОЛЬЗОВАТЕЛЯ${NC}"
echo ""
echo -e "  ${YELLOW}При создании пользователя в панели его Hysteria2 URI"
echo -e "  появится в подписке автоматически.${NC}"
