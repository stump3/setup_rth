#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  🛠️  SERVER-MANAGER — VPN Server Management Script                ║
# ║                                                                  ║
# ║  Компоненты:                                                     ║
# ║  • Remnawave Panel  — VPN-панель (eGames архитектура)            ║
# ║  • MTProxy (telemt) — Telegram MTProto прокси (Rust)             ║
# ║  • Hysteria2        — высокоскоростной VPN (QUIC/UDP)            ║
# ║                                                                  ║
# ║  Версия: определяется автоматически из даты изменения файла     ║
# ║  Использование: bash setup.sh                                    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION=$(date -r "$0" +'v%y%m.%d%H%M' 2>/dev/null || echo "v0000.000000")

# ═══════════════════════════════════════════════════════════════════
# ЦВЕТА И ОБЩИЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
PURPLE='\033[0;35m'; GRAY='\033[0;90m'; BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'; RESET="$NC"

# ── Глобальные пути и переменные ────────────────────────────────
PANEL_MGMT_SCRIPT="/usr/local/bin/remnawave_panel"

# Hysteria2
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_SVC="hysteria-server"

# Telemt (полные объявления — используются в get_telemt_version и migrate)
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG_SYSTEMD="/etc/telemt/telemt.toml"
TELEMT_WORK_DIR_SYSTEMD="/opt/telemt"
TELEMT_TLSFRONT_DIR="/opt/telemt/tlsfront"
TELEMT_SERVICE_FILE="/etc/systemd/system/telemt.service"
TELEMT_WORK_DIR_DOCKER="${HOME}/mtproxy"
TELEMT_CONFIG_DOCKER="${HOME}/mtproxy/telemt.toml"
TELEMT_COMPOSE_FILE="${HOME}/mtproxy/docker-compose.yml"
TELEMT_GITHUB_REPO="telemt/telemt"
TELEMT_API_URL="http://127.0.0.1:9091/v1/users"
TELEMT_MODE=""
TELEMT_CONFIG_FILE=""
TELEMT_WORK_DIR=""
TELEMT_CHOSEN_VERSION="latest"

ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
info()    { echo -e "${BLUE}  · $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()     { echo -e "\n${RED}  ✗  $*${NC}\n"; exit 1; }
die()     { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
detail()  { echo -e "${GRAY}    $*${NC}"; }

# Шаг установки: ── [N] Название ──
step() {
    echo ""
    echo -e "${BOLD}${CYAN}  ── $* ──${NC}"
    echo ""
}

# Заголовок раздела (подменю)
header() {
    clear
    echo ""
    echo -e "${BOLD}${WHITE}  $*${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────${NC}"
    echo ""
}

# Секция внутри экрана (без clear)
section() {
    echo ""
    echo -e "${BOLD}${WHITE}  $*${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
}

confirm() {
    # confirm "Вопрос"        — без default, требует y/n
    # confirm "Вопрос" y      — default Y (Enter = да)
    # confirm "Вопрос" n      — default N (Enter = нет)
    local prompt="$1" default="${2:-}"
    local hint
    case "$default" in
        y|Y) hint="[Y/n]" ;;
        n|N) hint="[y/N]" ;;
        *)   hint="[y/n]" ;;
    esac
    while true; do
        read -rp "  $prompt $hint: " r < /dev/tty
        r="${r:-$default}"
        case "$r" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *)   [ -z "$r" ] || warn "Введите y или n" ;;
        esac
    done
}

ask() {
    local var="$1" prompt="$2" default="${3:-}" val=""
    while true; do
        [ -n "$default" ] \
            && read -p "  ${prompt} [${default}]: " val < /dev/tty \
            || read -p "  ${prompt}: " val < /dev/tty
        val="${val:-$default}"
        [ -n "$val" ] && break
        warn "Поле обязательно"
    done
    printf -v "$var" "%s" "$val"
    # export убран — загрязнял окружение всех дочерних процессов.
    # Переменная доступна в вызывающем контексте через printf -v.
}

check_root()    { [ "$EUID" -ne 0 ] && err "Запустите от root: sudo bash $0" || true; }
need_root()     { [ "$(id -u)" -eq 0 ] || die "Эта операция требует прав root."; }
gen_secret()    { openssl rand -hex 16; }
gen_hex64()     { openssl rand -base64 96 | tr -dc 'a-zA-Z0-9' | head -c 64; }
gen_password()  {
    local p=""
    p+=$(tr -dc 'A-Z'    </dev/urandom | head -c 1)
    p+=$(tr -dc 'a-z'    </dev/urandom | head -c 1)
    p+=$(tr -dc '0-9'    </dev/urandom | head -c 1)
    p+=$(tr -dc '!@#%^&*' </dev/urandom | head -c 3)
    p+=$(tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 18)
    echo "$p" | fold -w1 | shuf | tr -d '\n'
}
gen_user()      { tr -dc 'a-zA-Z' </dev/urandom | head -c 8; }

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

check_dns() {
    local domain="$1" server_ip domain_ip
    server_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    domain_ip=$(dig +short -t A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -z "$server_ip" ] && { warn "Не удалось определить IP сервера"; return 1; }
    [ -z "$domain_ip" ] && { warn "A-запись для $domain не найдена"; return 1; }
    [ "$server_ip" != "$domain_ip" ] && { warn "$domain → $domain_ip, сервер → $server_ip"; return 1; }
    ok "DNS $domain → $domain_ip ✓"
    return 0
}

spinner() {
    local pid=$1 text="${2:-Подождите...}" spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' delay=0.1
    printf "${YELLOW}%s${NC}" "$text" > /dev/tty
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r${YELLOW}[%s] %s${NC}" "${spinstr:$i:1}" "$text" > /dev/tty
            sleep $delay
        done
    done
    printf "\r\033[K" > /dev/tty
}

# Установка sshpass (нужна для migrate в обоих разделах)
ensure_sshpass() {
    command -v sshpass &>/dev/null && return 0
    info "Установка sshpass..."
    apt-get install -y -q sshpass 2>/dev/null || \
        yum install -y sshpass 2>/dev/null || \
        die "Не удалось установить sshpass. Установи вручную: apt install sshpass"
    ok "sshpass установлен"
}


# ── SSH-миграция: ввод данных ─────────────────────────────────────
# Результат записывается в переменные: _SSH_IP _SSH_PORT _SSH_USER _SSH_PASS
ask_ssh_target() {
    while true; do
        read -rp "  IP нового сервера: " _SSH_IP < /dev/tty
        [[ "$_SSH_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        warn "Неверный формат IP"
    done
    read -rp "  SSH-порт [22]: "         _SSH_PORT < /dev/tty; _SSH_PORT="${_SSH_PORT:-22}"
    read -rp "  Пользователь [root]: "   _SSH_USER < /dev/tty; _SSH_USER="${_SSH_USER:-root}"
    while true; do
        read -rsp "  Пароль SSH: " _SSH_PASS < /dev/tty; echo
        [ -n "$_SSH_PASS" ] && break
        warn "Пароль не может быть пустым"
    done
}

# ── SSH-миграция: инициализация хелперов RUN/PUT ──────────────────
# init_ssh_helpers [panel|telemt|hysteria|full]
#   panel/full  — StrictHostKeyChecking=no, BatchMode=no  (RUN + PUT)
#   telemt      — StrictHostKeyChecking=accept-new        (RUN + PUT, те же RUN/PUT)
#   hysteria    — StrictHostKeyChecking=no, порт явно     (RUN + PUT)
# После вызова доступны: RUN "cmd", PUT src dst
init_ssh_helpers() {
    local mode="${1:-panel}"
    local strict_opt
    case "$mode" in
        telemt) strict_opt="StrictHostKeyChecking=accept-new" ;;
        *)      strict_opt="StrictHostKeyChecking=no" ;;
    esac
    local base_opts="-p $_SSH_PORT -o $strict_opt -o ConnectTimeout=10"
    [ "$mode" != "telemt" ] && base_opts="$base_opts -o BatchMode=no"

    # shellcheck disable=SC2139
    RUN() { sshpass -p "$_SSH_PASS" ssh  $base_opts "${_SSH_USER}@${_SSH_IP}" "$@"; }
    PUT() { sshpass -p "$_SSH_PASS" scp -rp $base_opts "$@"; }
    export -f RUN PUT 2>/dev/null || true
}

# ── SSH-миграция: проверка подключения ────────────────────────────
check_ssh_connection() {
    RUN "echo ok" >/dev/null 2>&1         || { err "Не удалось подключиться к ${_SSH_IP}:${_SSH_PORT}"; return 1; }
    ok "SSH соединение установлено"
}

# ── Remote: установка зависимостей ───────────────────────────────
# remote_install_deps [panel|full]
#   panel — base (без qrencode/unzip/cron, без /etc/hysteria)
#   full  — base + unzip cron qrencode + /etc/hysteria
remote_install_deps() {
    local variant="${1:-panel}"
    local extra_pkgs="" extra_dirs=""
    if [ "$variant" = "full" ]; then
        extra_pkgs=" unzip cron qrencode"
        extra_dirs=" /etc/hysteria"
    fi

    # ── Показываем что будет выполнено и просим подтверждение ─────
    echo ""
    warn "На сервере ${_SSH_IP} будут выполнены следующие действия:"
    echo ""
    echo "  · apt-get update && apt-get install (curl, docker-deps, certbot...)"
    echo "  · Установка Docker (если не установлен)"
    echo "  · Создание swap-файла 2 GB (если нет)"
    echo "  · Включение BBR (sysctl)"
    echo "  · Открытие портов 22/tcp и 443/tcp в UFW"
    [ "$variant" = "full" ] && echo "  · Установка qrencode, unzip, cron"
    echo ""
    if ! confirm "Продолжить установку зависимостей на ${_SSH_IP}?" y; then
        warn "Отменено пользователем"
        return 1
    fi

    info "Устанавливаем зависимости на новом сервере..."
    RUN bash -s << RDEPS
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q 2>/dev/null
apt-get install -y -q curl wget git jq openssl ca-certificates gnupg dnsutils \
    certbot python3-certbot-dns-cloudflare sshpass${extra_pkgs} 2>/dev/null
command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; systemctl enable docker >/dev/null 2>&1; } # intentional: official Docker installer
[ ! -f /swapfile ] && { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }
grep -q "bbr" /etc/sysctl.conf 2>/dev/null || {
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}
ufw allow 22/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
mkdir -p /opt/remnawave /var/www/html /etc/letsencrypt /etc/ssl/certs/hysteria${extra_dirs}
RDEPS
    ok "Зависимости установлены"
}

# API-запросы к Remnawave
panel_api() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local headers=(
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )
    [ -n "$token" ] && headers+=(-H "Authorization: Bearer $token")
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -X "$method" "$url" "${headers[@]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# ███████████████████  PANEL SECTION  ██████████████████████████████
# ═══════════════════════════════════════════════════════════════════

PANEL_DIR="/opt/remnawave"
PANEL_NGINX_DIR="/opt/nginx"           # используется только если nginx отдельно
# PANEL_MGMT_SCRIPT объявлен глобально

panel_get_base_domain() {
    echo "$1" | awk -F'.' '{if (NF>2) print $(NF-1)"."$NF; else print $0}'
}

panel_is_wildcard_cert() {
    local domain="$1" cert="/etc/letsencrypt/live/$1/fullchain.pem"
    [ -f "$cert" ] && openssl x509 -noout -text -in "$cert" 2>/dev/null | grep -q "\*\.$domain"
}

panel_cert_exists() {
    local domain="$1" base
    [ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ] && return 0
    base=$(panel_get_base_domain "$domain")
    [ "$base" != "$domain" ] && panel_is_wildcard_cert "$base" && return 0
    return 1
}

panel_issue_cert() {
    local domain="$1" base cert_method="$2"
    base=$(panel_get_base_domain "$domain")

    panel_cert_exists "$domain" && { ok "Сертификат для $domain уже есть"; return 0; }
    info "Выпуск сертификата для $domain..."

    case $cert_method in
        1)
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$base" -d "*.$base" \
                --email "${PANEL_CF_EMAIL:-admin@$base}" \
                --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат wildcard для $base выпущен" \
                || { warn "Ошибка certbot для $base"; return 1; }
            ;;
        2)
            ufw allow 80/tcp >/dev/null 2>&1
            certbot certonly --standalone -d "$domain" \
                --email "$PANEL_LE_EMAIL" \
                --agree-tos --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат для $domain выпущен" \
                || { warn "Ошибка certbot для $domain"; ufw delete allow 80/tcp >/dev/null 2>&1; return 1; }
            ufw delete allow 80/tcp >/dev/null 2>&1
            ;;
        3)
            certbot certonly --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$base" -d "*.$base" \
                --email "$PANEL_LE_EMAIL" \
                --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат wildcard для $base выпущен" \
                || { warn "Ошибка certbot для $base"; return 1; }
            ;;
    esac
}

panel_get_cert_domain() {
    local domain="$1" cert_method="$2"
    [ "$cert_method" = "1" ] || [ "$cert_method" = "3" ] \
        && panel_get_base_domain "$domain" \
        || echo "$domain"
}

panel_install() {
    step "Установка Remnawave Panel"
    check_root

    # ── Сбор данных ──────────────────────────────────────────────
    section "Режим"
    echo "  1) Панель + Нода (Reality selfsteal, всё на одном сервере)"
    echo "  2) Только панель (нода на отдельном сервере)"
    echo ""
    local MODE=""
    while [[ ! "$MODE" =~ ^[12]$ ]]; do
        read -p "  Выбор (1/2): " MODE < /dev/tty
    done

    echo ""
    section "Домены"
    local PANEL_DOMAIN SUB_DOMAIN SELFSTEAL_DOMAIN
    while true; do ask PANEL_DOMAIN "Домен панели (panel.example.com)"; validate_domain "$PANEL_DOMAIN" && break || warn "Неверный формат"; done
    while true; do ask SUB_DOMAIN   "Домен подписок (sub.example.com)";  validate_domain "$SUB_DOMAIN"   && break || warn "Неверный формат"; done
    while true; do ask SELFSTEAL_DOMAIN "Домен selfsteal (node.example.com)"; validate_domain "$SELFSTEAL_DOMAIN" && break || warn "Неверный формат"; done

    if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || \
       [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || \
       [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        err "Все три домена должны быть уникальными"
    fi

    echo ""
    section "SSL сертификаты"
    echo "  1) Cloudflare DNS-01 (wildcard, рекомендуется)"
    echo "  2) ACME HTTP-01 (Let's Encrypt)"
    echo "  3) Gcore DNS-01 (wildcard)"
    local CERT_METHOD=""
    while [[ ! "$CERT_METHOD" =~ ^[123]$ ]]; do
        read -p "  Метод (1/2/3): " CERT_METHOD < /dev/tty
    done

    local PANEL_CF_EMAIL="" PANEL_CF_KEY="" PANEL_LE_EMAIL="" GCORE_TOKEN=""
    case $CERT_METHOD in
        1) ask PANEL_CF_KEY   "  Cloudflare API Token"
           ask PANEL_CF_EMAIL "  Email Cloudflare" ;;
        2) ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
        3) ask GCORE_TOKEN    "  Gcore API Token"
           ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
    esac

    echo ""
    info "Проверка DNS..."
    check_dns "$PANEL_DOMAIN"     || warn "Проверьте DNS для $PANEL_DOMAIN"
    check_dns "$SUB_DOMAIN"       || warn "Проверьте DNS для $SUB_DOMAIN"
    check_dns "$SELFSTEAL_DOMAIN" || warn "Проверьте DNS для $SELFSTEAL_DOMAIN"

    # ── Зависимости ──────────────────────────────────────────────
    step "Зависимости"
    [ ! -f /swapfile ] && {
        fallocate -l 2G /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap 2G"
    }
    grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf || {
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    }
    apt-get update -y -q
    PKGS=(curl wget git nano htop socat jq openssl ca-certificates gnupg \
          lsb-release dnsutils unzip cron certbot python3-certbot-dns-cloudflare)
    [ "$CERT_METHOD" = "3" ] && PKGS+=(python3-pip)
    MISSING=(); for p in "${PKGS[@]}"; do dpkg -l "$p" &>/dev/null || MISSING+=("$p"); done
    [ ${#MISSING[@]} -gt 0 ] && apt-get install -y -q "${MISSING[@]}"
    [ "$CERT_METHOD" = "3" ] && {
        certbot plugins 2>/dev/null | grep -q "dns-gcore" || \
            python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1 || true
    }
    systemctl is-active --quiet cron || systemctl start cron
    systemctl is-enabled --quiet cron || systemctl enable cron
    ok "Системные пакеты"
    ! command -v docker &>/dev/null && {
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 # intentional: official Docker installer
        systemctl enable docker >/dev/null 2>&1
        ok "Docker установлен"
    } || ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    ufw allow 22/tcp  comment 'SSH'   >/dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "UFW настроен"

    # ── SSL ──────────────────────────────────────────────────────
    step "SSL сертификаты"
    case $CERT_METHOD in
        1)
            mkdir -p ~/.secrets/certbot
            if echo "$PANEL_CF_KEY" | grep -qE '[A-Z]'; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $PANEL_CF_KEY
EOF
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_email = $PANEL_CF_EMAIL
dns_cloudflare_api_key = $PANEL_CF_KEY
EOF
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini ;;
        3)
            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOF
dns_gcore_apitoken = $GCORE_TOKEN
EOF
            chmod 600 ~/.secrets/certbot/gcore.ini ;;
    esac

    declare -A PANEL_CERT_MAP
    local domains_arr=("$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN")
    if [ "$CERT_METHOD" = "1" ] || [ "$CERT_METHOD" = "3" ]; then
        declare -A UNIQUE_BASES
        for d in "${domains_arr[@]}"; do
            b=$(panel_get_base_domain "$d"); UNIQUE_BASES["$b"]=1
        done
        for base in "${!UNIQUE_BASES[@]}"; do panel_issue_cert "$base" "$CERT_METHOD"; done
    else
        for d in "${domains_arr[@]}"; do panel_issue_cert "$d" "$CERT_METHOD"; done
    fi

    local PC SC STC
    PC=$(panel_get_cert_domain "$PANEL_DOMAIN"     "$CERT_METHOD")
    SC=$(panel_get_cert_domain "$SUB_DOMAIN"       "$CERT_METHOD")
    STC=$(panel_get_cert_domain "$SELFSTEAL_DOMAIN" "$CERT_METHOD")

    # Cron автообновление
    local CRON_CMD
    [ "$CERT_METHOD" = "2" ] \
        && CRON_CMD="ufw allow 80 && /usr/bin/certbot renew --quiet && ufw delete allow 80 && ufw reload" \
        || CRON_CMD="/usr/bin/certbot renew --quiet"
    crontab -u root -l 2>/dev/null | grep -q "certbot renew" || \
        (crontab -u root -l 2>/dev/null; echo "0 5 * * 0 $CRON_CMD") | crontab -u root -

    for cd in "$PC" "$SC" "$STC"; do
        local renewal="/etc/letsencrypt/renewal/$cd.conf"
        [ -f "$renewal" ] || continue
        local hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
        grep -q "renew_hook" "$renewal" \
            && sed -i "/renew_hook/c\\$hook" "$renewal" \
            || echo "$hook" >> "$renewal"
    done
    ok "Сертификаты и автообновление настроены"

    # ── Генерация конфигурации ───────────────────────────────────
    step "Генерация конфигурации"
    mkdir -p /opt/remnawave && cd /opt/remnawave

    local SUPERADMIN_USER SUPERADMIN_PASS COOKIE_KEY COOKIE_VAL
    local JWT_AUTH JWT_API METRICS_USER METRICS_PASS
    SUPERADMIN_USER=$(gen_user)
    SUPERADMIN_PASS=$(gen_password)
    COOKIE_KEY=$(gen_user)
    COOKIE_VAL=$(gen_user)
    JWT_AUTH=$(gen_hex64)
    JWT_API=$(gen_hex64)
    METRICS_USER=$(gen_user)
    METRICS_PASS=$(gen_user)

    cat > /opt/remnawave/.env << EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
JWT_AUTH_SECRET=$JWT_AUTH
JWT_API_TOKENS_SECRET=$JWT_API
JWT_AUTH_LIFETIME=168
FRONT_END_DOMAIN=$PANEL_DOMAIN
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://your-webhook-url.com/endpoint
WEBHOOK_SECRET_HEADER=$(gen_hex64)
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me
TELEGRAM_NOTIFY_CRM_CHAT_ID=change_me
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOF

    # Монтирование сертификатов — уникальные домены
    local CERT_VOLUMES=""
    declare -A MOUNTED_CERTS
    for cd in "$PC" "$SC" "$STC"; do
        [ -n "${MOUNTED_CERTS[$cd]:-}" ] && continue
        CERT_VOLUMES+="      - /etc/letsencrypt/live/${cd}/fullchain.pem:/etc/nginx/ssl/${cd}/fullchain.pem:ro
      - /etc/letsencrypt/live/${cd}/privkey.pem:/etc/nginx/ssl/${cd}/privkey.pem:ro
"
        MOUNTED_CERTS["$cd"]=1
    done

    # docker-compose
    if [ "$MODE" = "1" ]; then
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.1
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s; timeout: 10s; retries: 3
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s; timeout: 5s; retries: 3; start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.0-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 3s; timeout: 10s; retries: 3
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
${CERT_VOLUMES}    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"
    volumes: [/dev/shm:/dev/shm:rw]
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config: [{subnet: 172.30.0.0/16}]
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
EOFYML
    else
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.1
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s; timeout: 10s; retries: 3
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s; timeout: 5s; retries: 3; start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.0-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 3s; timeout: 10s; retries: 3
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${CERT_VOLUMES}    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 30m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
EOFYML
    fi

    # nginx.conf
    local LISTEN_DIR REAL_IP_P REAL_IP_S
    if [ "$MODE" = "1" ]; then
        LISTEN_DIR="listen unix:/dev/shm/nginx.sock ssl proxy_protocol;"
        REAL_IP_P="\$proxy_protocol_addr"
        REAL_IP_S="\$proxy_protocol_addr"
    else
        LISTEN_DIR="listen 443 ssl;"
        REAL_IP_P="\$remote_addr"
        REAL_IP_S="\$remote_addr"
    fi

    cat > /opt/remnawave/nginx.conf << NGINX_CONF_EOF
server_names_hash_bucket_size 64;

upstream remnawave { server 127.0.0.1:3000; }
upstream remnawave-sub { server 127.0.0.1:3010; }

map \$http_upgrade \$connection_upgrade {
    default upgrade; "" close;
}

# Cookie-защита панели: доступ только с ?${COOKIE_KEY}=${COOKIE_VAL}
map \$http_cookie \$auth_cookie {
    default 0; "~*${COOKIE_KEY}=${COOKIE_VAL}" 1;
}
map \$arg_${COOKIE_KEY} \$auth_query {
    default 0; "${COOKIE_VAL}" 1;
}
map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1; default 0;
}
map \$arg_${COOKIE_KEY} \$set_cookie_header {
    "${COOKIE_VAL}" "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name ${PANEL_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/nginx/ssl/${PC}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${PC}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${PC}/fullchain.pem";
    add_header Set-Cookie \$set_cookie_header;

    location / {
        error_page 418 = @unauthorized;
        recursive_error_pages on;
        if (\$authorized = 0) { return 418; }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP ${REAL_IP_P};
        proxy_set_header X-Forwarded-For ${REAL_IP_P};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
    }
    location @unauthorized {
        root /var/www/html; index index.html; try_files /index.html =444;
    }
}

server {
    server_name ${SUB_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/nginx/ssl/${SC}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${SC}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${SC}/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave-sub;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP ${REAL_IP_S};
        proxy_set_header X-Forwarded-For ${REAL_IP_S};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @sub_error;
    }
    location @sub_error { return 444; }
}

server {
    server_name ${SELFSTEAL_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/nginx/ssl/${STC}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${STC}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${STC}/fullchain.pem";
    root /var/www/html; index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    ${LISTEN_DIR}
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
NGINX_CONF_EOF

    ok "Конфигурация сгенерирована"

    # Маскировочный сайт
    mkdir -p /var/www/html
    if curl -s --max-time 10 -L \
            "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip" \
            -o /tmp/tmpl.zip 2>/dev/null && \
       unzip -q /tmp/tmpl.zip -d /tmp/tmpl 2>/dev/null; then
        TDIRS=(/tmp/tmpl/simple-web-templates-main/*/)
        if [ ${#TDIRS[@]} -gt 0 ]; then
            local _ridx; _ridx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#TDIRS[@]}" 2>/dev/null || echo "0")
            cp -a "${TDIRS[$_ridx]}/." /var/www/html/ 2>/dev/null || true
        fi
        rm -rf /tmp/tmpl /tmp/tmpl.zip
        ok "Маскировочный сайт установлен"
    else
        cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:sans-serif;text-align:center;padding:100px;background:#f5f5f5}h1{color:#333}</style>
</head><body><h1>Welcome</h1><p>Service is running.</p></body></html>
HTMLEOF
        ok "Базовая страница /var/www/html"
    fi

    # ── Пауза — просмотр конфигурации ───────────────────────────
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  📝 Конфигурационные файлы сгенерированы${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}  Перед запуском можно открыть новый SSH-сеанс и проверить${NC}"
    echo -e "${WHITE}  или изменить любой из файлов через nano:${NC}"
    echo ""
    echo -e "  ${CYAN}nano /opt/remnawave/.env${NC}             ${GRAY}# секреты, JWT, домены${NC}"
    echo -e "  ${CYAN}nano /opt/remnawave/docker-compose.yml${NC}  ${GRAY}# образы, порты${NC}"
    echo -e "  ${CYAN}nano /opt/remnawave/nginx.conf${NC}       ${GRAY}# SSL, cookie-защита${NC}"
    echo ""
    echo -e "  ${GRAY}Ctrl+O → Enter — сохранить | Ctrl+X — выйти из nano${NC}"
    echo ""
    read -p "  Нажмите Enter когда готовы к запуску..." < /dev/tty
    ok "Продолжаем установку"

    # ── Запуск и автоконфигурация ────────────────────────────────
    step "Запуск и автоконфигурация"
    cd /opt/remnawave
    [ "$MODE" = "1" ] && ufw allow from 172.30.0.0/16 to any port 2222 proto tcp >/dev/null 2>&1

    docker compose up -d >/dev/null 2>&1 & spinner $! "Запуск контейнеров..."
    ok "Контейнеры запущены"

    info "Ожидание готовности панели (до 2 минут)..."
    sleep 20
    local ATTEMPTS=0
    until curl -s -f --max-time 30 "http://127.0.0.1:3000/api/auth/status" \
            -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' >/dev/null 2>&1; do
        ATTEMPTS=$((ATTEMPTS+1))
        [ "$ATTEMPTS" -ge 5 ] && err "Панель не стартовала. Проверьте: cd /opt/remnawave && docker compose logs remnawave"
        info "Попытка $ATTEMPTS/5, ждём 60с..."; sleep 60
    done
    ok "Панель готова"

    local API="127.0.0.1:3000"
    local REG
    REG=$(panel_api "POST" "http://$API/api/auth/register" "" \
        "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}")
    local TOKEN
    TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty' 2>/dev/null)
    [ -z "$TOKEN" ] && err "Ошибка регистрации: $REG"
    ok "Суперадмин: $SUPERADMIN_USER"

    local KEYS_R PRIV_KEY
    KEYS_R=$(panel_api "GET" "http://$API/api/system/tools/x25519/generate" "$TOKEN")
    PRIV_KEY=$(echo "$KEYS_R" | jq -r '.response.keypairs[0].privateKey // empty' 2>/dev/null)
    [ -z "$PRIV_KEY" ] && err "Ошибка генерации ключей"

    local PUB_R PUB_KEY
    PUB_R=$(panel_api "GET" "http://$API/api/keygen" "$TOKEN")
    PUB_KEY=$(echo "$PUB_R" | jq -r '.response.pubKey // empty' 2>/dev/null)
    [ -z "$PUB_KEY" ] && err "Ошибка получения публичного ключа"
    sed -i "s|SECRET_KEY=\"PUBLIC KEY FROM REMNAWAVE-PANEL\"|SECRET_KEY=\"$PUB_KEY\"|g" \
        /opt/remnawave/docker-compose.yml
    ok "Ключи Reality готовы"

    local OLD_P
    OLD_P=$(panel_api "GET" "http://$API/api/config-profiles" "$TOKEN" | \
        jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid' 2>/dev/null || echo "")
    [ -n "$OLD_P" ] && panel_api "DELETE" "http://$API/api/config-profiles/$OLD_P" "$TOKEN" >/dev/null

    local SHORT_ID DEST_VAL
    SHORT_ID=$(openssl rand -hex 8)
    [ "$MODE" = "1" ] && DEST_VAL='/dev/shm/nginx.sock' || DEST_VAL="${SELFSTEAL_DOMAIN}:443"

    local PROFILE_R
    PROFILE_R=$(panel_api "POST" "http://$API/api/config-profiles" "$TOKEN" "$(jq -n \
        --arg name "StealConfig" --arg domain "$SELFSTEAL_DOMAIN" \
        --arg pk "$PRIV_KEY"     --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" \
        '{name:$name,config:{log:{loglevel:"warning"},dns:{queryStrategy:"UseIPv4",servers:[{address:"https://dns.google/dns-query",skipFallback:false}]},inbounds:[{tag:"Steal",port:443,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{ip:["geoip:private"],type:"field",outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}}' 2>/dev/null)")

    local CFG_UUID IBD_UUID
    CFG_UUID=$(echo "$PROFILE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
    IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[0].uuid // empty' 2>/dev/null)
    [ -z "$CFG_UUID" ] && err "Ошибка создания конфиг-профиля"
    ok "Конфиг-профиль создан"

    local NODE_ADDR
    [ "$MODE" = "2" ] && NODE_ADDR="$SELFSTEAL_DOMAIN" || NODE_ADDR="172.30.0.1"
    panel_api "POST" "http://$API/api/nodes" "$TOKEN" "$(jq -n \
        --arg na "$NODE_ADDR" --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" \
        '{name:"Steal",address:$na,port:2222,configProfile:{activeConfigProfileUuid:$cu,activeInbounds:[$iu]},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,excludedInbounds:[],countryCode:"XX",consumptionMultiplier:1.0}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Нода создана" || warn "Ошибка создания ноды"

    panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
        --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" \
        '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"Steal",address:$addr,port:443,path:"",sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Хост создан" || warn "Ошибка создания хоста"

    local SQUAD_UUIDS
    SQUAD_UUIDS=$(panel_api "GET" "http://$API/api/internal-squads" "$TOKEN" | \
        jq -r '.response.internalSquads[].uuid' 2>/dev/null || echo "")
    for su in $SQUAD_UUIDS; do
        [[ "$su" =~ ^[0-9a-f-]{36}$ ]] || continue
        panel_api "PATCH" "http://$API/api/internal-squads" "$TOKEN" \
            "{\"uuid\":\"$su\",\"inbounds\":[\"$IBD_UUID\"]}" >/dev/null 2>&1 || true
    done
    ok "Squad обновлён"

    local SUB_TOKEN_R SUB_TOKEN
    SUB_TOKEN_R=$(panel_api "POST" "http://$API/api/tokens" "$TOKEN" '{"tokenName":"subscription-page"}')
    SUB_TOKEN=$(echo "$SUB_TOKEN_R" | jq -r '.response.token // empty' 2>/dev/null)
    [ -n "$SUB_TOKEN" ] && {
        sed -i "s|REMNAWAVE_API_TOKEN=PLACEHOLDER|REMNAWAVE_API_TOKEN=$SUB_TOKEN|g" \
            /opt/remnawave/docker-compose.yml
        ok "API-токен для Subscription Page"
    } || warn "Не удалось создать API-токен автоматически"

    docker compose down remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Перезапуск Sub..."
    docker compose up -d remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Запуск Sub..."
    docker compose down >/dev/null 2>&1 & spinner $! "Финальный рестарт..."
    docker compose up -d >/dev/null 2>&1 & spinner $! "Запуск..."
    ok "Стек перезапущен"

    # ── Команда управления ───────────────────────────────────────
    panel_install_mgmt_script "$PANEL_DOMAIN" "$COOKIE_KEY" "$COOKIE_VAL" "$MODE"

    # ── Итог ─────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}  ✓ Remnawave Panel установлена${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Доступ${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Панель    ${NC}https://${PANEL_DOMAIN}"
    echo -e "  ${GRAY}Подписки  ${NC}https://${SUB_DOMAIN}"
    echo -e "  ${GRAY}Selfsteal ${NC}https://${SELFSTEAL_DOMAIN}"
    echo ""
    echo -e "${BOLD}${WHITE}  Учётные данные${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Логин   ${NC}${SUPERADMIN_USER}"
    echo -e "  ${GRAY}Пароль  ${NC}${SUPERADMIN_PASS}"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠  Сохраните — показывается один раз${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${CYAN}https://${PANEL_DOMAIN}/auth/login?${COOKIE_KEY}=${COOKIE_VAL}${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Управление${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Команда   ${NC}remnawave_panel  ${GRAY}или${NC}  rp"
    echo ""
}

panel_install_mgmt_script() {
    local panel_domain="$1" cookie_key="$2" cookie_val="$3" mode="$4"
    local mgmt="/usr/local/bin/remnawave_panel"
    cat > "$mgmt" << 'MGMTEOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; PURPLE='\033[0;35m'; NC='\033[0m'
DIR="/opt/remnawave"
_ok()   { echo -e "${GREEN}✅ $*${NC}"; }
_info() { echo -e "${CYAN}ℹ  $*${NC}"; }
_warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
_spinner() {
    local pid=$1 text="${2:-Подождите...}" spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' delay=0.1
    while kill -0 "$pid" 2>/dev/null; do
        for((i=0;i<${#spinstr};i++)); do
            printf "\r${YELLOW}[%s] %s${NC}" "${spinstr:$i:1}" "$text">/dev/tty; sleep $delay
        done
    done; printf "\r\033[K">/dev/tty
}
do_status() {
    echo -e "${WHITE}📊 Статус:${NC}"
    for c in remnawave remnawave-db remnawave-redis remnawave-nginx remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null | head -1)
        [ -n "$s" ] && echo "$s" | grep -qE "^Up|healthy" \
            && echo -e "  ${GREEN}●${NC} $c — $s" || echo -e "  ${YELLOW}◐${NC} $c — $s" \
            || echo -e "  ${RED}○${NC} $c"
    done
    echo ""
    docker stats --no-stream --format "  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | \
        grep -E "remnawave|remnanode" | sort
}
do_logs() {
    local s="${1:-panel}"; cd "$DIR"
    case $s in
        nginx) docker logs remnawave-nginx --tail=50 -f ;;
        sub)   docker logs remnawave-subscription-page --tail=50 -f ;;
        node)  docker logs remnanode --tail=50 -f ;;
        *)     docker compose logs --tail=50 -f remnawave ;;
    esac
}
do_restart() {
    local s="${1:-all}"; cd "$DIR"
    case $s in
        nginx)  docker compose restart remnawave-nginx; _ok "Nginx перезапущен" ;;
        panel)  docker compose restart remnawave; _ok "Панель перезапущена" ;;
        sub)    docker compose restart remnawave-subscription-page; _ok "Sub перезапущена" ;;
        node)   docker compose restart remnanode; _ok "Нода перезапущена" ;;
        all)
            docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
            docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
            _ok "Всё перезапущено" ;;
        *) echo "Укажите: all|nginx|panel|sub|node" ;;
    esac
}
do_update() {
    cd "$DIR"
    docker compose pull>/dev/null 2>&1 & _spinner $! "Загрузка..."
    docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
    docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
    docker image prune -f>/dev/null 2>&1; _ok "Обновлено"
}
do_ssl() {
    certbot renew --quiet; cd "$DIR"
    docker compose restart remnawave-nginx
    _ok "SSL обновлён"
}
do_backup() {
    local ts b
    ts=$(date +%Y%m%d_%H%M%S); b="$DIR/backups"; mkdir -p "$b"; cd "$DIR"
    docker compose exec -T remnawave-db pg_dump -U postgres postgres>"$b/db_$ts.sql" 2>/dev/null \
        && _ok "БД → $b/db_$ts.sql" || _warn "Ошибка бэкапа БД"
    tar -czf "$b/configs_$ts.tar.gz" "$DIR/.env" "$DIR/docker-compose.yml" "$DIR/nginx.conf" 2>/dev/null
    _ok "Конфиги → $b/configs_$ts.tar.gz"
    find "$b" -mtime +7 -delete 2>/dev/null||true
}
do_health() {
    do_status; echo ""
    echo -e "${WHITE}🔒 SSL:${NC}"
    for d in /etc/letsencrypt/live/*/; do
        dom=$(basename "$d")
        exp=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate 2>/dev/null|sed 's/notAfter=//')
        [ -n "$exp" ] && echo -e "  ${GREEN}✓${NC} $dom — $exp"
    done; echo ""
    echo -e "${WHITE}Nginx:${NC}"
    docker exec remnawave-nginx nginx -t 2>&1|sed 's/^/  /'||true; echo ""
    echo -e "${WHITE}API:${NC}"
    curl -s --max-time 5 "http://127.0.0.1:3000/api/auth/status" \
        -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' 2>/dev/null | \
        jq -e '.response'>/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} API доступен" || echo -e "  ${RED}✗${NC} API недоступен"
}
do_open_port() {
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    ss -tuln|grep -q ":8443" && { _warn "Порт 8443 занят"; return 1; }
    sed -i "/server_name $pd;/a \\    listen 8443 ssl;" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    local ck cv
    ck=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '~\*\K\w+(?==)')
    cv=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '=\K\w+(?= 1)')
    _ok "Порт 8443 открыт."
    echo -e "  ${WHITE}https://${pd}:8443/auth/login?${ck}=${cv}${NC}"
    _warn "Закройте после работы: remnawave_panel close_port"
}
do_close_port() {
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    sed -i "/server_name $pd;/,/}/{s/    listen 8443 ssl;//}" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw delete allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    _ok "Порт 8443 закрыт"
}
do_migrate() {
    header "📦 Перенос Panel на другой сервер"

    # ── Проверки ───────────────────────────────────────────────────
    [ -d /opt/remnawave ] || { err "Панель не установлена"; return 1; }
    [ -f /opt/remnawave/docker-compose.yml ] || { err "docker-compose.yml не найден"; return 1; }
    command -v sshpass &>/dev/null || apt-get install -y -q sshpass 2>/dev/null

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target
    init_ssh_helpers panel
    check_ssh_connection || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    # ── Проверка свободного места ──────────────────────────────────
    _info "Проверяем свободное место на новом сервере..."
    local remote_free local_used
    remote_free=$(RUN "df -BM /opt --output=avail | tail -1 | tr -d 'M'" 2>/dev/null || echo "0")
    local_used=$(du -sm /opt/remnawave 2>/dev/null | awk '{print $1}' || echo "0")
    if [ "$remote_free" -lt "$((local_used * 2))" ] 2>/dev/null; then
        _warn "Мало места на новом сервере: ${remote_free}MB свободно, нужно ~$((local_used * 2))MB"
        read -rp "  Продолжить всё равно? (y/n): " fc < /dev/tty
        [[ "$fc" =~ ^[yY]$ ]] || return 1
    fi

    # ── Установка зависимостей на новом сервере ────────────────────
    remote_install_deps panel

    # ── Дамп БД ────────────────────────────────────────────────────
    _info "Создаём дамп базы данных..."
    local dump="/tmp/panel_migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
    cd /opt/remnawave
    docker compose exec -T remnawave-db pg_dumpall -c -U postgres 2>/dev/null | gzip -9 > "$dump"

    # Проверяем размер дампа
    local dump_size; dump_size=$(stat -c%s "$dump" 2>/dev/null || echo "0")
    if [ "$dump_size" -lt 1000 ]; then
        err "Дамп БД подозрительно мал (${dump_size} байт) — возможна ошибка"
        rm -f "$dump"
        return 1
    fi
    _ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

    # ── Передача файлов ────────────────────────────────────────────
    _info "Передаём файлы панели..."
    PUT "$dump" \
        /opt/remnawave/.env \
        /opt/remnawave/docker-compose.yml \
        /opt/remnawave/nginx.conf \
        "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null \
        && _ok "Файлы панели переданы" || { err "Ошибка передачи файлов панели"; return 1; }

    # SSL сертификаты
    _info "Передаём SSL сертификаты..."
    if [ -d /etc/letsencrypt/live ] && [ -d /etc/letsencrypt/archive ]; then
        PUT /etc/letsencrypt/live \
            /etc/letsencrypt/archive \
            /etc/letsencrypt/renewal \
            "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null \
            && _ok "SSL сертификаты переданы" || _warn "Ошибка передачи SSL — перевыпустите вручную"
    else
        _warn "SSL сертификаты не найдены в /etc/letsencrypt"
    fi

    # Hysteria сертификаты (если есть)
    if [ -d /etc/ssl/certs/hysteria ]; then
        _info "Передаём сертификаты Hysteria2..."
        PUT /etc/ssl/certs/hysteria \
            "${ruser}@${rip}:/etc/ssl/certs/" 2>/dev/null \
            && _ok "Сертификаты Hysteria2 переданы" || _warn "Ошибка передачи сертификатов Hysteria2"
    fi

    # Selfsteal сайт
    if [ -d /var/www/html ] && [ "$(ls -A /var/www/html 2>/dev/null)" ]; then
        _info "Передаём selfsteal сайт..."
        PUT /var/www/html/. "${ruser}@${rip}:/var/www/html/" 2>/dev/null \
            && _ok "Selfsteal сайт передан" || _warn "Ошибка передачи сайта"
    fi

    _ok "Все файлы переданы"

    # ── Запуск на новом сервере ────────────────────────────────────
    _info "Запускаем стек на новом сервере..."
    local dumpb; dumpb=$(basename "$dump")
    RUN bash -s << RSTART
set -e
cd /opt/remnawave

# Удаляем старый volume БД если есть
docker volume rm remnawave-db-data 2>/dev/null || true

# Запускаем только БД и Redis
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
echo "Ждём запуска БД..."
sleep 20

# Проверяем что БД готова
local attempts=0
until docker compose exec -T remnawave-db pg_isready -U postgres >/dev/null 2>&1 || [ \$attempts -ge 10 ]; do
    sleep 3; attempts=\$((attempts+1))
done

# Восстанавливаем дамп
echo "Восстанавливаем базу данных..."
zcat /opt/remnawave/$dumpb | docker compose exec -T remnawave-db psql -U postgres postgres >/dev/null 2>&1 || true

# Запускаем весь стек
docker compose up -d >/dev/null 2>&1
echo "Стек запущен"
RSTART
    _ok "Стек запущен на новом сервере"

    # ── Копируем скрипты управления ────────────────────────────────
    PUT /usr/local/bin/remnawave_panel \
        "${ruser}@${rip}:/usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "chmod +x /usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "grep -q 'alias rp=' /etc/bash.bashrc || echo \"alias rp='remnawave_panel'\" >> /etc/bash.bashrc" 2>/dev/null
    _ok "Скрипт управления установлен"

    # ── Копируем setup.sh ──────────────────────────────────────────
    PUT "$0" "${ruser}@${rip}:/root/setup.sh" 2>/dev/null && \
    RUN "chmod +x /root/setup.sh" 2>/dev/null
    _ok "setup.sh скопирован на новый сервер"

    # ── Очистка ────────────────────────────────────────────────────
    rm -f "$dump"
    RUN "rm -f /opt/remnawave/$dumpb" 2>/dev/null || true

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    _ok "Перенос панели завершён!"
    echo ""
    echo -e "  ${WHITE}Следующие шаги:${NC}"
    echo -e "  ${CYAN}1.${NC} Обновите DNS-записи на новый IP: ${CYAN}${rip}${NC}"
    echo -e "  ${CYAN}2.${NC} После обновления DNS перевыпустите SSL:"
    echo -e "     ${CYAN}ssh ${ruser}@${rip} remnawave_panel ssl${NC}"
    echo -e "  ${CYAN}3.${NC} Проверьте работу панели"
    echo -e "  ${CYAN}4.${NC} Остановите старый сервер когда всё ОК"
    echo ""

    read -rp "  Остановить панель на ЭТОМ сервере? (y/n): " stop_old < /dev/tty
    if [[ "$stop_old" =~ ^[yY]$ ]]; then
        cd /opt/remnawave && docker compose stop >/dev/null 2>&1
        _ok "Панель на старом сервере остановлена"
    else
        _info "Панель на старом сервере продолжает работать"
    fi
}
show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${PURPLE}  REMNAWAVE PANEL${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    for c in remnawave remnawave-nginx remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null|head -1)
        if [ -n "$s" ] && echo "$s"|grep -qE "^Up|healthy"; then
            echo -e "  ${GREEN}●${NC} $c"
        elif [ -n "$s" ]; then
            echo -e "  ${YELLOW}◐${NC} $c — $s"
        else
            echo -e "  ${RED}○${NC} $c"
        fi
    done
    echo ""
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  📋 Логи        ${BOLD}2)${NC}  📊 Статус    ${BOLD}3)${NC}  🔄 Перезапуск"
    echo -e "  ${BOLD}4)${NC}  ▶️  Старт       ${BOLD}5)${NC}  📦 Обновить  ${BOLD}6)${NC}  🔒 SSL"
    echo -e "  ${BOLD}7)${NC}  💾 Бэкап       ${BOLD}8)${NC}  🏥 Диагноз   ${BOLD}9)${NC}  🔓 Порт 8443"
    echo -e " ${BOLD}10)${NC}  🔐 Закрыть    ${BOLD}11)${NC}  📦 Перенос"
    echo ""
    echo -e "  ${BOLD}q)${NC}  Выход"
    echo ""
}
case "$1" in
    status)      do_status ;;
    logs)        do_logs "${2:-panel}" ;;
    restart)     do_restart "${2:-all}" ;;
    start)       cd /opt/remnawave && docker compose up -d; _ok "Запущено" ;;
    stop)        cd /opt/remnawave && docker compose down; _ok "Остановлено" ;;
    update)      do_update ;;
    ssl)         do_ssl ;;
    backup)      do_backup ;;
    health)      do_health ;;
    open_port)   do_open_port ;;
    close_port)  do_close_port ;;
    migrate)     do_migrate ;;
    help|--help)
        echo "remnawave_panel (rp) — управление Remnawave Panel"
        echo "Команды: status logs restart start stop update ssl backup health open_port close_port migrate"
        ;;
    "")
        while true; do
            show_menu
            read -p "Выбор: " ch</dev/tty
            case $ch in
                1) read -p "  Логи (panel/nginx/sub/node) [panel]: " s</dev/tty; do_logs "${s:-panel}" ;;
                2) do_status; read -p "Enter..."</dev/tty ;;
                3) read -p "  Что перезапустить? [all]: " s</dev/tty; do_restart "${s:-all}"; read -p "Enter..."</dev/tty ;;
                4) cd /opt/remnawave && docker compose up -d; _ok "Запущено"; read -p "Enter..."</dev/tty ;;
                5) do_update; read -p "Enter..."</dev/tty ;;
                6) do_ssl; read -p "Enter..."</dev/tty ;;
                7) do_backup; read -p "Enter..."</dev/tty ;;
                8) do_health; read -p "Enter..."</dev/tty ;;
                9) do_open_port; read -p "Enter..."</dev/tty ;;
               10) do_close_port; read -p "Enter..."</dev/tty ;;
               11) do_migrate; read -p "Enter..."</dev/tty ;;
                q|Q) exit 0 ;;
                *) sleep 0.3 ;;
            esac
        done ;;
    *) echo "Неизвестная команда. rp help"; exit 1 ;;
esac
MGMTEOF
    chmod +x "$mgmt"
    grep -q "alias rp=" /etc/bash.bashrc 2>/dev/null || \
        echo "alias rp='remnawave_panel'" >> /etc/bash.bashrc
    ok "Команда 'remnawave_panel' (rp) создана"
}


get_remnawave_version() {
    docker logs remnawave 2>/dev/null | grep -o "Remnawave Backend v[0-9.]*" | tail -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | tr -d '\n' || echo ""
}

get_telemt_version() {
    "$TELEMT_BIN" --version 2>/dev/null | awk '{print $2}' | head -1 || echo ""
}

get_hysteria_version() {
    /usr/local/bin/hysteria version 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo ""
}


# ═══════════════════════════════════════════════════════════════════
# ████████████████████  PANEL EXTENSIONS  ██████████████████████████
# ═══════════════════════════════════════════════════════════════════

PANEL_TOKEN_FILE="/opt/remnawave/.panel_token"
PANEL_API="http://127.0.0.1:3000"

# ── API утилиты ───────────────────────────────────────────────────
panel_api_request() {
    local method="$1" url="$2" token="$3" data="$4"
    local args=(-s -X "$method" "${PANEL_API}${url}"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}"
}

panel_get_token() {
    # Проверяем сохранённый токен
    if [ -f "$PANEL_TOKEN_FILE" ]; then
        local token; token=$(cat "$PANEL_TOKEN_FILE")
        local test; test=$(panel_api_request "GET" "/api/config-profiles" "$token")
        if echo "$test" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'configProfiles' in str(d) else 1)" 2>/dev/null; then
            echo "$token"
            return 0
        fi
        rm -f "$PANEL_TOKEN_FILE"
    fi
    # Логин
    local username password
    read -rp "  Логин панели: " username < /dev/tty
    read -rsp "  Пароль панели: " password < /dev/tty; echo ""
        local resp; resp=$(panel_api_request "POST" "/api/auth/login" "" \
        "$(printf '{"username":"%s","password":"%s"}' "$username" "$password")")
    local token; token=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('accessToken',''))" 2>/dev/null)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        err "Не удалось получить токен: $resp"
        return 1
    fi
    echo "$token" > "$PANEL_TOKEN_FILE"
    ok "Авторизация успешна"
    echo "$token"
}

# ── Автообновление скрипта ────────────────────────────────────────
panel_update_script() {
    header "Обновление скрипта"
    local script_url="https://raw.githubusercontent.com/stump3/setup_rth/main/setup.sh"
    info "Проверяем обновления..."
    local remote; remote=$(curl -fsSL "$script_url" 2>/dev/null)
    [ -z "$remote" ] && { warn "Не удалось получить скрипт с GitHub"; return 1; }
    local remote_ver; remote_ver=$(echo "$remote" | grep "^SCRIPT_VERSION=" | head -1 | sed 's/SCRIPT_VERSION=//;s/[^a-zA-Z0-9._-]//g' | tr -d ' ')
    local local_ver; local_ver=$(date -r "$0" +'v%y%m.%d%H%M' 2>/dev/null || echo "unknown")
    info "Локальная версия: $local_ver"
    info "Версия на GitHub: $remote_ver"
    echo ""
    read -rp "  Обновить? (y/n): " ch < /dev/tty
    [[ "$ch" =~ ^[yY]$ ]] || { info "Отменено"; return; }
    local tmp; tmp=$(mktemp)
    curl -fsSL "$script_url" -o "$tmp" || { err "Ошибка загрузки"; rm -f "$tmp"; return 1; }
    cp "$tmp" "$0" && chmod +x "$0"
    rm -f "$tmp"
    ok "Скрипт обновлён! Перезапустите: bash $0"
}

# ── Удаление панели ───────────────────────────────────────────────
panel_remove() {
    header "Удалить панель"
    echo -e "  ${BOLD}1)${RESET} 🗑️   Только скрипт (setup.sh)"
    echo -e "  ${BOLD}2)${RESET} 💣  Скрипт + все данные панели (необратимо!)"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1)
            read -rp "  Удалить setup.sh? (y/n): " c < /dev/tty
            [[ "$c" =~ ^[yY]$ ]] || return
            rm -f "$0"
            ok "Скрипт удалён"
            exit 0
            ;;
        2)
            echo ""
            warn "ЭТО УДАЛИТ ВСЕ ДАННЫЕ ПАНЕЛИ, БД, КОНФИГИ!"
            warn "Действие необратимо!"
            echo ""
            read -rp "  Введите 'DELETE' для подтверждения: " c < /dev/tty
            [ "$c" != "DELETE" ] && { info "Отменено"; return; }
            info "Останавливаем контейнеры..."
            cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans 2>/dev/null || true
            docker system prune -a --volumes -f >/dev/null 2>&1 || true
            rm -rf /opt/remnawave
            rm -f "$0"
            ok "Панель и скрипт удалены"
            exit 0
            ;;
        0) return ;;
    esac
}

# ── Переустановка панели ──────────────────────────────────────────
panel_reinstall() {
    header "Переустановить панель"
    echo ""
    warn "ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ: БД, пользователи, конфиги!"
    warn "После переустановки потребуется заново настроить панель."
    echo ""
    read -rp "  Продолжить? Введите 'YES': " c < /dev/tty
    [ "$c" != "YES" ] && { info "Отменено"; return; }
    info "Удаляем старую установку..."
    cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans >/dev/null 2>&1 || true
    docker system prune -a --volumes -f >/dev/null 2>&1 || true
    rm -rf /opt/remnawave
    ok "Старая установка удалена"
    info "Запускаем установку заново..."
    panel_install
}

# ── WARP Native ───────────────────────────────────────────────────
panel_warp_menu() {
    clear
    header "WARP Native"
    echo -e "  ${BOLD}1)${RESET} ⬇️   Установить WARP"
    echo -e "  ${BOLD}2)${RESET} ➕  Добавить в профиль Xray"
    echo -e "  ${BOLD}3)${RESET} ➖  Удалить из профиля Xray"
    echo -e "  ${BOLD}4)${RESET} 🗑️   Удалить WARP с системы"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh); read -rp "Enter..." < /dev/tty ;;
        2) panel_warp_add_config ;;
        3) panel_warp_remove_config ;;
        4) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh); read -rp "Enter..." < /dev/tty ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    panel_warp_menu
}

panel_warp_select_profile() {
    local resp="$1"
    echo "$resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
ps = d.get('response', {}).get('configProfiles', [])
for i, p in enumerate(ps, 1):
    print(str(i) + ') ' + p['name'] + ' [' + p['uuid'] + ']')
PY
}

panel_warp_get_uuid() {
    local resp="$1"
    local num="$2"
    echo "$resp" | python3 - "$num" << 'PY'
import sys, json
d = json.load(sys.stdin)
num = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ps = d.get('response', {}).get('configProfiles', [])
try:
    print(ps[num - 1]['uuid'])
except Exception:
    pass
PY
}

panel_warp_add_config() {
    header "WARP — Добавить в профиль"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
if not any(o.get('tag') == 'warp-out' for o in ob):
    ob.append({'tag': 'warp-out', 'protocol': 'freedom',
        'settings': {'domainStrategy': 'UseIP'},
        'streamSettings': {'sockopt': {'interface': 'warp', 'tcpFastOpen': True}}})
    cfg['outbounds'] = ob
rules = cfg.get('routing', {}).get('rules', [])
if not any(r.get('outboundTag') == 'warp-out' for r in rules):
    rules.append({'type': 'field',
        'domain': ['whoer.net', 'browserleaks.com', '2ip.io', '2ip.ru'],
        'outboundTag': 'warp-out'})
    cfg['routing']['rules'] = rules
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP добавлен в профиль!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}

panel_warp_remove_config() {
    header "WARP — Удалить из профиля"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
cfg['outbounds'] = [o for o in ob if o.get('tag') != 'warp-out']
rules = cfg.get('routing', {}).get('rules', [])
cfg['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'warp-out']
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP удалён из профиля!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}

# ── Selfsteal шаблоны ─────────────────────────────────────────────
panel_template_menu() {
    clear
    header "Selfsteal — шаблон сайта"
    echo -e "  ${BOLD}1)${RESET} 🎲  Случайный шаблон"
    echo -e "  ${BOLD}2)${RESET} 🌐  Simple web templates"
    echo -e "  ${BOLD}3)${RESET} 🔷  SNI templates"
    echo -e "  ${BOLD}4)${RESET} ⬜  Nothing SNI"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_install_template "" ;;
        2) panel_install_template "simple" ;;
        3) panel_install_template "sni" ;;
        4) panel_install_template "nothing" ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    panel_template_menu
}

panel_install_template() {
    local src="$1"
    local urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )
    local selected_url
    case "$src" in
        "simple")  selected_url="${urls[0]}" ;;
        "sni")     selected_url="${urls[1]}" ;;
        "nothing") selected_url="${urls[2]}" ;;
        *)
            local idx; idx=$(python3 -c "import random; print(random.randrange(3))" 2>/dev/null || echo "$((RANDOM % 3))")
            selected_url="${urls[$idx]}"
            ;;
    esac
    info "Скачиваем шаблон..."
    cd /opt/ || return 1
    rm -f main.zip
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    wget -q --timeout=30 "$selected_url" -O main.zip || { err "Ошибка загрузки"; return 1; }
    unzip -o main.zip &>/dev/null || { err "Ошибка распаковки"; return 1; }
    rm -f main.zip
    local dir template
    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        dir="simple-web-templates-main"
        cd "$dir" && rm -rf assets .gitattributes README.md _config.yml 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        dir="nothing-sni-main"
        cd "$dir" && rm -rf .github README.md 2>/dev/null
        template="$((RANDOM % 8 + 1)).html"
    else
        dir="sni-templates-main"
        cd "$dir" && rm -rf assets README.md index.html 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    fi
    # Рандомизация HTML
    local rand_id; rand_id=$(openssl rand -hex 8)
    local rand_title="Page_$(openssl rand -hex 4)"
    find "./$template" -type f -name "*.html" -exec sed -i         -e "s|<title>.*</title>|<title>${rand_title}</title>|"         -e "s/<\/head>/<meta name="page-id" content="${rand_id}">
<\/head>/"         {} \; 2>/dev/null || true
    # Копируем в /var/www/html
    mkdir -p /var/www/html
    rm -rf /var/www/html/*
    if [ -d "./$template" ]; then
        cp -a "./$template"/. /var/www/html/
    elif [ -f "./$template" ]; then
        cp "./$template" /var/www/html/index.html
    fi
    cd /opt/
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    ok "Шаблон установлен: $template"
    read -rp "Enter..." < /dev/tty
}

# ── Страница подписки ─────────────────────────────────────────────
panel_subpage_menu() {
    clear
    header "Страница подписки"
    echo -e "  ${BOLD}1)${RESET} 🎨  Установить Orion шаблон"
    echo -e "  ${BOLD}2)${RESET} 🏷️   Настроить брендинг"
    echo -e "  ${BOLD}3)${RESET} ♻️   Восстановить оригинал"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_subpage_install_orion ;;
        2) panel_subpage_branding ;;
        3) panel_subpage_restore ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    panel_subpage_menu
}

panel_subpage_install_orion() {
    header "Установка Orion шаблона"
    [ -f /opt/remnawave/docker-compose.yml ] || { warn "Панель не установлена"; return 1; }
    local index="/opt/remnawave/index.html"
    local compose="/opt/remnawave/docker-compose.yml"
    local primary="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
    local fallback="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
    info "Скачиваем Orion..."
    rm -f "$index"
    if ! curl -fsSL "$primary" -o "$index" 2>/dev/null; then
        curl -fsSL "$fallback" -o "$index" || { err "Ошибка загрузки"; return 1; }
    fi
    # Монтируем в docker-compose
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$compose"
        yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$compose"
    else
        # Простая замена если нет yq
        warn "yq не установлен — монтирование не добавлено автоматически"
        warn "Добавьте вручную в docker-compose.yml:"
        echo "  volumes:"
        echo "    - ./index.html:/opt/app/frontend/index.html"
    fi
    cd /opt/remnawave
    docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Orion установлен!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_branding() {
    header "Брендинг подписки"
    local config="/opt/remnawave/app-config.json"
    if [ -f "$config" ]; then
        local name logo support
        name=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('name','—'))" 2>/dev/null)
        logo=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('logoUrl','—'))" 2>/dev/null)
        support=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('supportUrl','—'))" 2>/dev/null)
        echo ""
        echo -e "  ${GRAY}Текущие значения:${NC}"
        echo -e "  Название:  ${CYAN}${name}${NC}"
        echo -e "  Логотип:   ${CYAN}${logo}${NC}"
        echo -e "  Поддержка: ${CYAN}${support}${NC}"
        echo ""
    fi
    local new_name new_logo new_support
    read -rp "  Название (Enter — пропустить): " new_name < /dev/tty
    read -rp "  URL логотипа (Enter — пропустить): " new_logo < /dev/tty
    read -rp "  URL поддержки (Enter — пропустить): " new_support < /dev/tty
    # Обновляем конфиг
    NEW_NAME="$new_name" NEW_LOGO="$new_logo" NEW_SUPPORT="$new_support"     CONFIG_FILE="$config" python3 << 'PYEOF'
import json, os
config_file = os.environ["CONFIG_FILE"]
try:
    with open(config_file) as f:
        d = json.load(f)
except Exception:
    d = {"config": {}}
d.setdefault("config", {}).setdefault("branding", {})
n = os.environ.get("NEW_NAME")
l = os.environ.get("NEW_LOGO")
s = os.environ.get("NEW_SUPPORT")
if n: d["config"]["branding"]["name"]       = n
if l: d["config"]["branding"]["logoUrl"]    = l
if s: d["config"]["branding"]["supportUrl"] = s
with open(config_file, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print("OK")
PYEOF
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Брендинг обновлён!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_restore() {
    header "Восстановить оригинал"
    read -rp "  Восстановить оригинальную страницу подписки? (y/n): " c < /dev/tty
    [[ "$c" =~ ^[yY]$ ]] || return
    rm -f /opt/remnawave/index.html /opt/remnawave/app-config.json
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i /opt/remnawave/docker-compose.yml
    fi
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Оригинал восстановлен!"
    read -rp "Enter..." < /dev/tty
}

# ── Remnawave CLI ─────────────────────────────────────────────────
panel_cli() {
    header "Remnawave CLI"
    info "Запуск интерактивного CLI панели..."
    docker exec -it remnawave remnawave || warn "Не удалось запустить CLI. Панель запущена?"
    read -rp "Enter..." < /dev/tty
}

panel_menu() {
    local ver; ver=$(get_remnawave_version)
    local panel_domain=""
    [ -f /opt/remnawave/.env ] && panel_domain=$(grep "^FRONT_END_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d '"' || true)
    clear
    echo ""
    echo -e "${BOLD}${WHITE}  🛡️  Remnawave Panel${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    if [ -n "$ver" ] || [ -n "$panel_domain" ]; then
        [ -n "$ver" ]          && echo -e "  ${GRAY}Версия  ${NC}${ver}"
        [ -n "$panel_domain" ] && echo -e "  ${GRAY}Домен   ${NC}${panel_domain}"
        echo ""
    fi
    echo -e "  ${BOLD}1)${RESET}  🔧  Установка"
    echo -e "  ${BOLD}2)${RESET}  ⚙️   Управление"
    echo -e "  ${BOLD}3)${RESET}  🌐  WARP Native"
    echo -e "  ${BOLD}4)${RESET}  🎨  Страница подписки"
    echo -e "  ${BOLD}5)${RESET}  🖼️   Selfsteal шаблон"
    echo -e "  ${BOLD}6)${RESET}  🔄  Обновить скрипт"
    echo -e "  ${BOLD}7)${RESET}  📦  Миграция на другой сервер"
    echo -e "  ${BOLD}8)${RESET}  🗑️   Удалить панель"
    echo ""
    echo -e "  ${BOLD}0)${RESET}  ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_submenu_install ;;
        2) panel_submenu_manage ;;
        3) panel_warp_menu ;;
        4) panel_subpage_menu ;;
        5) panel_template_menu ;;
        6) panel_update_script; read -rp "Enter..." < /dev/tty ;;
        7) [ -x "$PANEL_MGMT_SCRIPT" ] && "$PANEL_MGMT_SCRIPT" migrate             || warn "Панель не установлена." ;;
        8) panel_remove ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    panel_menu
}

panel_submenu_install() {
    clear
    header "Remnawave Panel — Установка"
    echo -e "  ${BOLD}1)${RESET} 🆕  Установить"
    echo -e "  ${BOLD}2)${RESET} 💣  Переустановить (сброс всех данных!)"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_install ;;
        2) panel_reinstall ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

panel_submenu_manage() {
    clear
    header "Remnawave Panel — Управление"
    echo -e "  ${BOLD}1)${RESET} 📋  Логи"
    echo -e "  ${BOLD}2)${RESET} 📊  Статус"
    echo -e "  ${BOLD}3)${RESET} 🔄  Перезапустить"
    echo -e "  ${BOLD}4)${RESET} ▶️   Старт"
    echo -e "  ${BOLD}5)${RESET} 📦  Обновить"
    echo -e "  ${BOLD}6)${RESET} 🔒  SSL"
    echo -e "  ${BOLD}7)${RESET} 💾  Бэкап"
    echo -e "  ${BOLD}8)${RESET} 🏥  Диагноз"
    echo -e "  ${BOLD}9)${RESET} 🔓  Открыть порт 8443"
    echo -e " ${BOLD}10)${RESET} 🔐  Закрыть порт 8443"
    echo -e " ${BOLD}11)${RESET} 💻  Remnawave CLI"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    [ -x "$PANEL_MGMT_SCRIPT" ] || { warn "Панель не установлена."; return; }
    case "$ch" in
        1)  "$PANEL_MGMT_SCRIPT" logs ;;
        2)  "$PANEL_MGMT_SCRIPT" status ;;
        3)  "$PANEL_MGMT_SCRIPT" restart ;;
        4)  "$PANEL_MGMT_SCRIPT" start ;;
        5)  "$PANEL_MGMT_SCRIPT" update ;;
        6)  "$PANEL_MGMT_SCRIPT" ssl ;;
        7)  "$PANEL_MGMT_SCRIPT" backup ;;
        8)  "$PANEL_MGMT_SCRIPT" health ;;
        9)  "$PANEL_MGMT_SCRIPT" open_port ;;
        10) "$PANEL_MGMT_SCRIPT" close_port ;;
        11) panel_cli ;;
        0)  return ;;
        *)  warn "Неверный выбор" ;;
    esac
    panel_submenu_manage
}


# ═══════════════════════════════════════════════════════════════════
# ████████████████████  TELEMT SECTION  ████████████████████████████
# ═══════════════════════════════════════════════════════════════════

# Переменные Telemt объявлены глобально в начале скрипта

telemt_choose_mode() {
    header "telemt MTProxy — метод установки"
    echo -e "  ${BOLD}1)${RESET} ${BOLD}systemd${RESET} — бинарник с GitHub"
    echo -e "     ${CYAN}Рекомендуется:${RESET} hot reload, меньше RAM, миграция"
    echo ""
    echo -e "  ${BOLD}2)${RESET} ${BOLD}Docker${RESET} — образ с Docker Hub"
    echo ""
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    read -rp "Выбор [1/2]: " ch
    case "$ch" in
        1) TELEMT_MODE="systemd"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD" ;;
        2) TELEMT_MODE="docker";  TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER";  TELEMT_WORK_DIR="$TELEMT_WORK_DIR_DOCKER" ;;
        0) return 1 ;;
        *) warn "Неверный выбор"; telemt_choose_mode ;;
    esac
    ok "Режим: $TELEMT_MODE"
}

telemt_check_deps() {
    for cmd in curl openssl python3; do
        command -v "$cmd" &>/dev/null || die "Не найдена команда: $cmd"
    done
    if [ "$TELEMT_MODE" = "docker" ]; then
        command -v docker &>/dev/null || die "Docker не установлен."
        docker compose version &>/dev/null || die "Нужен Docker Compose v2."
    else
        command -v systemctl &>/dev/null || die "systemctl не найден. Используй Docker-режим."
    fi
}

telemt_is_running() {
    if [ "$TELEMT_MODE" = "systemd" ]; then
        systemctl is-active --quiet telemt 2>/dev/null
    else
        docker compose -f "$TELEMT_COMPOSE_FILE" ps --status running 2>/dev/null | grep -q "telemt"
    fi
}

TELEMT_CHOSEN_VERSION="latest"

telemt_pick_version() {
    info "Получаю список версий..."
    local versions
    versions=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${TELEMT_GITHUB_REPO}/releases?per_page=10" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -10 || true)
    [ -z "$versions" ] && { warn "Не удалось получить список. Используется latest."; TELEMT_CHOSEN_VERSION="latest"; return; }
    echo ""
    echo -e "${BOLD}Доступные версии:${RESET}"
    local i=1; local -a va=()
    while IFS= read -r v; do
        [ $i -eq 1 ] && echo -e "  ${GREEN}${BOLD}$i)${RESET} $v  ${CYAN}← последняя${RESET}" \
                      || echo -e "  ${BOLD}$i)${RESET} $v"
        va+=("$v"); i=$((i+1))
    done <<< "$versions"
    echo ""
    local ch; read -rp "Версия [1]: " ch; ch="${ch:-1}"
    if echo "$ch" | grep -qE '^[0-9]+$' && [ "$ch" -ge 1 ] && [ "$ch" -le "${#va[@]}" ]; then
        TELEMT_CHOSEN_VERSION="${va[$((ch-1))]}"
    else
        warn "Неверный выбор, используется latest."; TELEMT_CHOSEN_VERSION="latest"
    fi
}

telemt_download_binary() {
    local ver="${1:-latest}" arch libc url
    arch=$(uname -m); case "$arch" in x86_64) ;; aarch64|arm64) arch="aarch64" ;; *) die "Архитектура не поддерживается: $arch" ;; esac
    ldd --version 2>&1 | grep -iq musl && libc="musl" || libc="gnu"
    [ "$ver" = "latest" ] \
        && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
        || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
    info "Скачиваю telemt $ver..."
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp" && install -m 0755 "$tmp/telemt" "$TELEMT_BIN" && rm -rf "$tmp" \
        && ok "Установлен: $TELEMT_BIN" || { rm -rf "$tmp"; die "Не удалось скачать бинарник."; }
}

telemt_write_config() {
    local port="$1" domain="$2"; shift 2
    local tls_front_dir api_listen api_wl
    if [ "$TELEMT_MODE" = "systemd" ]; then
        mkdir -p "$TELEMT_CONFIG_DIR" "$TELEMT_TLSFRONT_DIR"
        tls_front_dir="$TELEMT_TLSFRONT_DIR"; api_listen="127.0.0.1:9091"; api_wl='["127.0.0.1/32"]'
    else
        mkdir -p "$TELEMT_WORK_DIR_DOCKER"; tls_front_dir="tlsfront"; api_listen="0.0.0.0:9091"; api_wl='["127.0.0.0/8"]'
    fi
    { cat <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = $port

[server.api]
enabled   = true
listen    = "$api_listen"
whitelist = $api_wl

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "$domain"
mask          = true
tls_emulation = true
tls_front_dir = "$tls_front_dir"

[access.users]
EOF
      for pair in "$@"; do echo "${pair%% *} = \"${pair#* }\""; done
    } > "$TELEMT_CONFIG_FILE"
    [ "$TELEMT_MODE" = "systemd" ] && chmod 640 "$TELEMT_CONFIG_FILE"
}

telemt_write_service() {
    cat > "$TELEMT_SERVICE_FILE" <<'EOF'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
}

telemt_write_compose() {
    local port="$1"
    cat > "$TELEMT_COMPOSE_FILE" <<EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
      - "${port}:${port}/tcp"
      - "127.0.0.1:9091:9091/tcp"
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    tmpfs: [/tmp:rw,nosuid,nodev,noexec,size=16m]
    ulimits: {nofile: {soft: 65536, hard: 65536}}
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
EOF
}

telemt_fetch_links() {
    local attempt=0
    info "Запрашиваю данные через API..."
    while [ $attempt -lt 15 ]; do
        local resp; resp=$(curl -s --max-time 5 "$TELEMT_API_URL" 2>/dev/null || true)
        if echo "$resp" | grep -q "tg://proxy"; then
            echo ""
            echo "$resp" | python3 -c "
import sys, json
BOLD='\\033[1m'; CYAN='\\033[0;36m'; GREEN='\\033[0;32m'; GRAY='\\033[0;37m'; RESET='\\033[0m'
def fmt_bytes(b):
    if not b: return '0 B'
    for u in ('B','KB','MB','GB','TB'):
        if b < 1024: return f'{b:.1f} {u}' if u != 'B' else f'{int(b)} B'
        b /= 1024
    return f'{b:.2f} PB'
data = json.load(sys.stdin)
users = data if isinstance(data, list) else data.get('users', data.get('data', []))
if isinstance(users, dict): users = list(users.values())
for u in users:
    name = u.get('username') or u.get('name') or 'user'
    tls  = u.get('links', {}).get('tls', [])
    conns = u.get('current_connections', 0)
    aips  = u.get('active_unique_ips', 0)
    al    = u.get('active_unique_ips_list', [])
    rips  = u.get('recent_unique_ips', 0)
    rl    = u.get('recent_unique_ips_list', [])
    oct   = u.get('total_octets', 0)
    mc    = u.get('max_tcp_conns')
    mi    = u.get('max_unique_ips')
    q     = u.get('data_quota_bytes')
    exp   = u.get('expiration_rfc3339')
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}      {tls[0]}')
    print(f'{BOLD}│  Подключений:{RESET} {conns}' + (f' / {mc}' if mc else ''))
    print(f'{BOLD}│  Активных IP:{RESET} {aips}' + (f' / {mi}' if mi else ''))
    for ip in al: print(f'{BOLD}│{RESET}    {GREEN}▸ {ip}{RESET}')
    print(f'{BOLD}│  Недавних IP:{RESET} {rips}')
    print(f'{BOLD}│  Трафик:{RESET}      {fmt_bytes(oct)}' + (f' / {fmt_bytes(q)}' if q else ''))
    if exp: print(f'{BOLD}│  Истекает:{RESET}    {exp}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null || echo "$resp"
            return 0
        fi
        attempt=$((attempt+1)); sleep 2; echo -n "."
    done
    echo ""; warn "API не ответил. Попробуй: curl -s $TELEMT_API_URL"
    return 1
}

telemt_ask_users() {
    TELEMT_USER_PAIRS=()
    info "Добавление пользователей"
    while true; do
        local uname; read -rp "  Имя [Enter чтобы завершить]: " uname
        [ -z "$uname" ] && [ ${#TELEMT_USER_PAIRS[@]} -gt 0 ] && break
        [ -z "$uname" ] && { warn "Нужен хотя бы один пользователь!"; continue; }
        local secret; read -rp "  Секрет (32 hex) [Enter = сгенерировать]: " secret
        if [ -z "$secret" ]; then
            secret=$(gen_secret); ok "Секрет: $secret"
        elif ! echo "$secret" | grep -qE '^[0-9a-fA-F]{32}$'; then
            warn "Секрет должен быть 32 hex-символа"; continue
        fi
        TELEMT_USER_PAIRS+=("$uname $secret"); ok "Пользователь '$uname' добавлен"
        echo ""
    done
}

telemt_menu_install() {
    header "Установка MTProxy (${TELEMT_MODE})"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    local port; read -rp "Порт прокси [8443]: " port; port="${port:-8443}"
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { warn "Порт $port занят!"; read -rp "Другой порт: " port; }
    local domain; read -rp "Домен-маскировка [petrovich.ru]: " domain; domain="${domain:-petrovich.ru}"
    echo ""; telemt_ask_users

    if [ "$TELEMT_MODE" = "systemd" ]; then
        telemt_pick_version
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"
        id telemt &>/dev/null || useradd -d "$TELEMT_WORK_DIR" -m -r -U telemt
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        mkdir -p "$TELEMT_TLSFRONT_DIR"
        chown -R telemt:telemt "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
        telemt_write_service
        systemctl daemon-reload; systemctl enable telemt; systemctl start telemt
        ok "Сервис запущен"
    else
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        telemt_write_compose "$port"
        cd "$TELEMT_WORK_DIR_DOCKER"
        docker compose pull -q; docker compose up -d
        ok "Контейнер запущен"
    fi
    command -v ufw &>/dev/null && ufw allow "${port}/tcp" &>/dev/null && ok "ufw: порт $port открыт"
    sleep 3; header "Ссылки"
    echo -e "${BOLD}IP:${RESET} $(get_public_ip)"
    telemt_fetch_links
}

telemt_menu_add_user() {
    header "Добавить пользователя"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден. Сначала выполни установку."
    local uname; read -rp "  Имя: " uname; [ -z "$uname" ] && die "Имя не может быть пустым"
    grep -q "^${uname} = " "$TELEMT_CONFIG_FILE" && die "Пользователь '$uname' уже существует"
    local secret; read -rp "  Секрет [Enter = сгенерировать]: " secret
    [ -z "$secret" ] && { secret=$(gen_secret); ok "Секрет: $secret"; } \
        || echo "$secret" | grep -qE '^[0-9a-fA-F]{32}$' || die "Секрет должен быть 32 hex"
    echo ""; echo -e "${BOLD}Ограничения (Enter = пропустить):${RESET}"
    local mc mi qg ed
    read -rp "  Макс. подключений:    " mc
    read -rp "  Макс. уникальных IP:  " mi
    read -rp "  Квота трафика (ГБ):   " qg
    read -rp "  Срок действия (дней): " ed
    echo "$uname = \"$secret\"" >> "$TELEMT_CONFIG_FILE"
    local has=0 block=""
    [ -n "$mc" ] && { block+="\nmax_tcp_conns = $mc"; has=1; }
    [ -n "$mi" ] && { block+="\nmax_unique_ips = $mi"; has=1; }
    [ -n "$qg" ] && { local qb; qb=$(python3 -c "print(int($qg*1024**3))"); block+="\ndata_quota_bytes = $qb"; has=1; }
    [ -n "$ed" ] && { local exp; exp=$(python3 -c "from datetime import datetime,timezone,timedelta; dt=datetime.now(timezone.utc)+timedelta(days=int($ed)); print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))"); block+="\nexpiration_rfc3339 = \"$exp\""; has=1; }
    [ "$has" -eq 1 ] && { printf "\n[access.user_limits.$uname]$block\n" >> "$TELEMT_CONFIG_FILE"; ok "Ограничения применены"; }
    ok "Пользователь '$uname' добавлен"
    telemt_is_running && {
        if [ "$TELEMT_MODE" = "systemd" ]; then
            info "Hot reload..."
            systemctl reload telemt 2>/dev/null || systemctl restart telemt
        else
            cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart telemt
        fi; sleep 2
    }
    header "Ссылки"; telemt_fetch_links
}

telemt_menu_delete_user() {
    header "Удалить пользователя"
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."

    # Собираем список пользователей из [access.users]
    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/ =.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/{print}' "$TELEMT_CONFIG_FILE")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя для удаления:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi

    local selected="${users[$((ch-1))]}"
    read -rp "  Удалить '${selected}'? (y/N): " _yn < /dev/tty
    [[ "${_yn:-N}" =~ ^[yY]$ ]] || { warn "Отменено"; return; }

    # Удаляем строку пользователя из [access.users]
    sed -i "/^${selected} = /d" "$TELEMT_CONFIG_FILE"
    # Удаляем секцию [access.user_limits.USERNAME] если есть
    sed -i "/^\[access\.user_limits\.${selected}\]/,/^\[/{/^\[access\.user_limits\.${selected}\]/d; /^\[/!{/^$/d; d}}" "$TELEMT_CONFIG_FILE"

    ok "Пользователь '${selected}' удалён"

    # Hot reload
    if telemt_is_running; then
        if [ "$TELEMT_MODE" = "systemd" ]; then
            info "Hot reload..."
            systemctl reload telemt 2>/dev/null || systemctl restart telemt
        else
            cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart telemt >/dev/null 2>&1
        fi
        sleep 1
        ok "Конфиг применён"
    fi
}

telemt_menu_links()  { header "Пользователи и ссылки"; telemt_is_running || die "Сервис не запущен."; telemt_fetch_links; }

telemt_menu_status() {
    header "Статус"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        systemctl status telemt --no-pager||true; echo ""; info "Последние логи:"; journalctl -u telemt --no-pager -n 30
    else
        cd "$TELEMT_WORK_DIR_DOCKER" 2>/dev/null || die "Директория не найдена"
        docker compose ps; echo ""; info "Последние логи:"; docker compose logs --tail=20
    fi
}

telemt_menu_update() {
    header "Обновление"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        need_root
        info "Текущая версия: $($TELEMT_BIN --version 2>/dev/null||echo неизвестна)"
        telemt_pick_version; systemctl stop telemt
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"; systemctl start telemt
    else
        cd "$TELEMT_WORK_DIR_DOCKER" || die "Директория не найдена"
        docker compose pull; docker compose up -d
    fi
    ok "Обновлено"
}

telemt_menu_stop() {
    header "Остановка"
    if [ "$TELEMT_MODE" = "systemd" ]; then need_root; systemctl stop telemt
    else cd "$TELEMT_WORK_DIR_DOCKER" || die ""; docker compose down; fi
    ok "Остановлено"
}

telemt_menu_migrate() {
    header "Миграция MTProxy на новый сервер"
    need_root
    [ "$TELEMT_MODE" != "systemd" ] && die "Миграция доступна только в systemd-режиме."
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."
    ensure_sshpass

    echo -e "${BOLD}Данные нового сервера:${RESET}"; echo ""
    ask_ssh_target
    init_ssh_helpers telemt
    # Алиасы для совместимости с остальным кодом функции
    RRUN() { RUN "$@"; }
    RSCP() { PUT "$@" "${_SSH_USER}@${_SSH_IP}:/tmp/"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oP '"K[^"]+' || echo "petrovich.ru")
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"
    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}"
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}"

    local users_block
    users_block=$(awk '/^\[access\.users\]/{found=1;next} found&&/^\[/{exit} found&&/=/{print}' "$TELEMT_CONFIG_FILE")
    [ -z "$users_block" ] && die "Не найдено пользователей в конфиге"
    ok "Пользователей: $(echo "$users_block" | grep -c "=")"

    local remote_config
    remote_config="$(cat <<RCONF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = $new_pp

[server.api]
enabled   = true
listen    = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "$new_dom"
mask          = true
tls_emulation = true
tls_front_dir = "$TELEMT_TLSFRONT_DIR"

[access.users]
$users_block
RCONF
)"
    local limits_block
    limits_block=$(awk '/^\[access\.user_limits\./{found=1} found{print}' "$TELEMT_CONFIG_FILE" || true)

    info "Копирую скрипт на новый сервер..."
    RSCP "$(realpath "$0")" &>/dev/null; ok "Скрипт скопирован в /tmp/"
    info "Копирую конфиг..."
    echo "$remote_config" | RRUN "mkdir -p /etc/telemt && cat > /etc/telemt/telemt.toml"
    [ -n "$limits_block" ] && { echo "$limits_block" | RRUN "echo '' >> /etc/telemt/telemt.toml && cat >> /etc/telemt/telemt.toml"; ok "Лимиты перенесены"; }

    header "Установка на $nh"
    RRUN bash << REMOTE_INSTALL
set -e
ARCH=\$(uname -m); case "\$ARCH" in x86_64) ;; aarch64) ARCH="aarch64" ;; *) echo "Архитектура не поддерживается"; exit 1 ;; esac
LIBC=\$(ldd --version 2>&1|grep -iq musl&&echo musl||echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-\${ARCH}-linux-\${LIBC}.tar.gz"
TMP=\$(mktemp -d); curl -fsSL "\$URL"|tar -xz -C "\$TMP"; install -m 0755 "\$TMP/telemt" /usr/local/bin/telemt; rm -rf "\$TMP"
echo "[OK] Telemt установлен"
id telemt &>/dev/null||useradd -d /opt/telemt -m -r -U telemt
mkdir -p /opt/telemt/tlsfront; chown -R telemt:telemt /etc/telemt /opt/telemt
cat > /etc/systemd/system/telemt.service << 'SERVICE'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
echo "[OK] Сервис запущен"
command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null && echo "[OK] Порт $new_pp открыт"
REMOTE_INSTALL

    ok "Установка завершена!"
    header "Новые ссылки"; echo -e "${BOLD}Новый IP:${RESET} $nh"; info "Жду запуска..."; sleep 5
    local nl; nl=$(RRUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null"||true)
    if echo "$nl" | grep -q "tg://proxy"; then
        echo "$nl" | python3 -c "
import sys,json
BOLD='\\033[1m'; CYAN='\\033[0;36m'; RESET='\\033[0m'
data=json.load(sys.stdin); users=data if isinstance(data,list) else data.get('users',data.get('data',[]))
if isinstance(users,dict): users=list(users.values())
for u in users:
    name=u.get('username') or u.get('name') or 'user'
    tls=u.get('links',{}).get('tls',[])
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}  {tls[0]}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null
        ok "Миграция завершена! Разошли новые ссылки."
        warn "Старый сервер ещё работает. Когда будешь готов: systemctl stop telemt"
    else
        warn "Сервис запущен, но API пока не ответил. Проверь: curl -s http://127.0.0.1:9091/v1/users"
    fi
}

telemt_menu_migrate_docker() {
    header "Миграция MTProxy (Docker) на новый сервер"
    need_root
    [ "$TELEMT_MODE" != "docker" ] && die "Эта функция только для Docker-режима."
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден: $TELEMT_CONFIG_FILE"
    [ ! -f "$TELEMT_COMPOSE_FILE" ] && die "docker-compose.yml не найден: $TELEMT_COMPOSE_FILE"
    ensure_sshpass

    echo -e "${BOLD}Данные нового сервера:${RESET}"; echo ""
    ask_ssh_target
    init_ssh_helpers telemt
    RRUN() { RUN "$@"; }
    RSCP() { sshpass -p "$_SSH_PASS" scp -P "$_SSH_PORT"         -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$1" "${_SSH_USER}@${_SSH_IP}:$2"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oP '"K[^"]+' || echo "petrovich.ru")
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"

    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}"
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}"

    # Обновляем порт и домен в конфиге если изменились
    local config_to_send
    config_to_send=$(sed "s/^port = .*/port = $new_pp/; s/tls_domain.*=.*/tls_domain    = \"$new_dom\"/" "$TELEMT_CONFIG_FILE")

    info "Проверяю Docker на новом сервере..."
    # intentional: official Docker installer
    RRUN "command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 && systemctl enable docker; }" \
        && ok "Docker готов" || die "Не удалось установить Docker"

    info "Копирую конфиг и compose файл..."
    RRUN "mkdir -p $(dirname "$TELEMT_CONFIG_FILE") $(dirname "$TELEMT_COMPOSE_FILE")"
    echo "$config_to_send" | RRUN "cat > $TELEMT_CONFIG_FILE"
    RSCP "$TELEMT_COMPOSE_FILE" "$TELEMT_COMPOSE_FILE"
    ok "Файлы скопированы"

    info "Запускаю контейнер на новом сервере..."
    RRUN "cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose pull -q && docker compose up -d"         && ok "Контейнер запущен" || die "Ошибка запуска контейнера"

    # Открываем порт
    RRUN "command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null || true"

    # Проверяем ссылки
    ok "Миграция завершена!"
    header "Новые ссылки"
    echo -e "${BOLD}Новый IP:${RESET} $nh"
    info "Жду запуска..."
    sleep 5
    local nl; nl=$(RRUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null" || true)
    if echo "$nl" | grep -q "tg://proxy"; then
        echo "$nl" | python3 -c "
import sys,json
BOLD='\033[1m'; CYAN='\033[0;36m'; RESET='\033[0m'
data=json.load(sys.stdin); users=data if isinstance(data,list) else data.get('users',data.get('data',[]))
if isinstance(users,dict): users=list(users.values())
for u in users:
    name=u.get('username') or u.get('name') or 'user'
    tls=u.get('links',{}).get('tls',[])
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}  {tls[0]}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null
        warn "Старый контейнер ещё работает. Когда будешь готов:"
        echo -e "     ${CYAN}cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose down${NC}"
    else
        warn "Сервис запущен, но API пока не ответил. Проверь:"
        echo -e "     ${CYAN}ssh ${nu}@${nh} curl -s http://127.0.0.1:9091/v1/users${NC}"
    fi
}

telemt_main_menu() {
    while true; do
        local mode_label=""; [ "$TELEMT_MODE" = "systemd" ] && mode_label="systemd" || mode_label="Docker"
        local ver telemt_port
        ver=$(get_telemt_version 2>/dev/null || true)
        telemt_port=""
        [ -f "$TELEMT_CONFIG_FILE" ] && telemt_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" 2>/dev/null | grep -oE "[0-9]+" | head -1 || true)
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  📡  MTProxy (telemt)${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$telemt_port" ]; then
            [ -n "$ver" ]         && echo -e "  ${GRAY}Версия  ${NC}${ver}  ${GRAY}(${mode_label})${NC}"
            [ -n "$telemt_port" ] && echo -e "  ${GRAY}Порт    ${NC}${telemt_port}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET} 🔧  Установка"
        echo -e "  ${BOLD}2)${RESET} ⚙️   Управление"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи"
        echo -e "  ${BOLD}4)${RESET} 📦  Миграция на другой сервер"
        echo -e "  ${BOLD}5)${RESET} 🔀  Сменить режим (systemd ↔ Docker)"
        echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_install ;;
            2) telemt_submenu_manage ;;
            3) telemt_submenu_users ;;
            4) if [ "$TELEMT_MODE" = "systemd" ]; then
                   telemt_menu_migrate
               else
                   telemt_menu_migrate_docker
               fi ;;
            5) telemt_choose_mode; telemt_check_deps ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_submenu_manage() {
    clear
    header "MTProxy — Управление"
    echo -e "  ${BOLD}1)${RESET} 📊  Статус и логи"
    echo -e "  ${BOLD}2)${RESET} 🔄  Обновить"
    echo -e "  ${BOLD}3)${RESET} ⏹️   Остановить"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) telemt_menu_status; read -rp "Enter..." < /dev/tty ;;
        2) telemt_menu_update ;;
        3) telemt_menu_stop; read -rp "Enter..." < /dev/tty ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    telemt_submenu_manage
}

telemt_submenu_users() {
    clear
    header "MTProxy — Пользователи"
    echo -e "  ${BOLD}1)${RESET} ➕  Добавить пользователя"
    echo -e "  ${BOLD}2)${RESET} ➖  Удалить пользователя"
    echo -e "  ${BOLD}3)${RESET} 👥  Пользователи и ссылки"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) telemt_menu_add_user ;;
        2) telemt_menu_delete_user ;;
        3) telemt_menu_links; read -rp "Enter..." < /dev/tty ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    telemt_submenu_users
}

telemt_section() {
    if [ -z "$TELEMT_MODE" ]; then
        # Автоопределение если уже установлен
        if systemctl is-active --quiet telemt 2>/dev/null || systemctl is-enabled --quiet telemt 2>/dev/null; then
            TELEMT_MODE="systemd"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
        elif { docker ps --format "{{.Names}}" 2>/dev/null || true; } | grep -q "^telemt$"; then
            TELEMT_MODE="docker"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_DOCKER"
        else
            telemt_choose_mode || return
        fi
    fi
    telemt_check_deps
    telemt_main_menu
}

# ═══════════════════════════════════════════════════════════════════
# ████████████████████  MIGRATE SECTION  ███████████████████████████
# ═══════════════════════════════════════════════════════════════════

migrate_all() {
    header "Перенос всего стека (Panel + MTProxy + Hysteria2)"
    echo ""
    ensure_sshpass

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target
    init_ssh_helpers full
    check_ssh_connection || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    # ── Зависимости ────────────────────────────────────────────────
    remote_install_deps full

    # ── Panel ──────────────────────────────────────────────────────
    if [ -d /opt/remnawave ] && [ -f /opt/remnawave/docker-compose.yml ]; then
        info "Переносим Panel..."

        # Дамп БД со сжатием
        local dump="/tmp/panel_migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
        cd /opt/remnawave
        docker compose exec -T remnawave-db pg_dumpall -c -U postgres 2>/dev/null | gzip -9 > "$dump"
        local dump_size; dump_size=$(stat -c%s "$dump" 2>/dev/null || echo "0")
        if [ "$dump_size" -lt 1000 ]; then
            err "Дамп БД подозрительно мал (${dump_size} байт)"
            rm -f "$dump"; return 1
        fi
        ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

        # Передача файлов
        PUT "$dump" /opt/remnawave/.env /opt/remnawave/docker-compose.yml /opt/remnawave/nginx.conf \
            "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null && ok "Файлы панели переданы" \
            || { err "Ошибка передачи файлов панели"; rm -f "$dump"; return 1; }

        # SSL
        [ -d /etc/letsencrypt/live ] && \
            PUT /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal \
                "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null \
            && ok "SSL сертификаты переданы" || warn "Ошибка передачи SSL"

        # Selfsteal
        [ -d /var/www/html ] && [ "$(ls -A /var/www/html 2>/dev/null)" ] && \
            PUT /var/www/html/. "${ruser}@${rip}:/var/www/html/" 2>/dev/null && ok "Selfsteal сайт передан" || true

        # Hysteria сертификаты
        [ -d /etc/ssl/certs/hysteria ] && \
            PUT /etc/ssl/certs/hysteria "${ruser}@${rip}:/etc/ssl/certs/" 2>/dev/null \
            && ok "Сертификаты Hysteria2 переданы" || true

        # Восстановление
        local dumpb; dumpb=$(basename "$dump")
        RUN bash -s << RPANEL
set -e; cd /opt/remnawave
docker volume rm remnawave-db-data 2>/dev/null || true
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
sleep 20
zcat /opt/remnawave/$dumpb | docker compose exec -T remnawave-db psql -U postgres postgres >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1
RPANEL
        rm -f "$dump"; RUN "rm -f /opt/remnawave/$dumpb" 2>/dev/null || true
        PUT /usr/local/bin/remnawave_panel "${ruser}@${rip}:/usr/local/bin/remnawave_panel" 2>/dev/null
        RUN "chmod +x /usr/local/bin/remnawave_panel && grep -q 'alias rp=' /etc/bash.bashrc || echo \"alias rp='remnawave_panel'\" >> /etc/bash.bashrc" 2>/dev/null || true
        ok "Panel перенесена"
    else
        warn "Panel не найдена, пропускаю"
    fi

    # ── MTProxy ────────────────────────────────────────────────────
    if [ -f "$TELEMT_CONFIG_SYSTEMD" ]; then
        info "Переносим MTProxy..."
        local cp dp ub lb
        cp=$(grep -E "^port\s*=" "$TELEMT_CONFIG_SYSTEMD" | head -1 | grep -oE "[0-9]+" || echo "8443")
        dp=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_SYSTEMD" | head -1 | grep -oP '(?<="K)[^"]+' || echo "petrovich.ru")
        ub=$(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/{print}' "$TELEMT_CONFIG_SYSTEMD")
        lb=$(awk '/^\[access\.user_limits\./{f=1} f{print}' "$TELEMT_CONFIG_SYSTEMD" || true)

        echo "$ub" | RUN "mkdir -p /etc/telemt && { cat << 'NCONF'
[general]
use_middle_proxy = true
log_level = \"normal\"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = \"*\"

[server]
port = $cp

[server.api]
enabled   = true
listen    = \"127.0.0.1:9091\"
whitelist = [\"127.0.0.1/32\"]

[[server.listeners]]
ip = \"0.0.0.0\"

[censorship]
tls_domain    = \"$dp\"
mask          = true
tls_emulation = true
tls_front_dir = \"/opt/telemt/tlsfront\"

[access.users]
NCONF
cat; } > /etc/telemt/telemt.toml"
        [ -n "$lb" ] && echo "$lb" | RUN "echo '' >> /etc/telemt/telemt.toml && cat >> /etc/telemt/telemt.toml"

        RUN bash << RTELEMT
set -e
ARCH=\$(uname -m); LIBC=\$(ldd --version 2>&1|grep -iq musl&&echo musl||echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-\${ARCH}-linux-\${LIBC}.tar.gz"
TMP=\$(mktemp -d); curl -fsSL "\$URL"|tar -xz -C "\$TMP"; install -m 0755 "\$TMP/telemt" /usr/local/bin/telemt; rm -rf "\$TMP"
id telemt &>/dev/null || useradd -d /opt/telemt -m -r -U telemt
mkdir -p /opt/telemt/tlsfront; chown -R telemt:telemt /etc/telemt /opt/telemt
cat > /etc/systemd/system/telemt.service << 'SVC'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecReload=/bin/kill -HUP \$MAINPID
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
command -v ufw &>/dev/null && ufw allow $cp/tcp >/dev/null 2>&1 || true
RTELEMT
        ok "MTProxy перенесён"
    else
        warn "MTProxy (systemd) не найден, пропускаю"
    fi

    # ── Hysteria2 ──────────────────────────────────────────────────
    if hy_is_installed 2>/dev/null && [ -f "$HYSTERIA_CONFIG" ]; then
        info "Переносим Hysteria2..."
        PUT /etc/hysteria/config.yaml "${ruser}@${rip}:/etc/hysteria/" 2>/dev/null
        [ -d /var/lib/hysteria ] && PUT /var/lib/hysteria "${ruser}@${rip}:/var/lib/" 2>/dev/null || true
        # Копируем URI файлы
        for f in /root/hysteria-*.txt; do
            [ -f "$f" ] && PUT "$f" "${ruser}@${rip}:/root/" 2>/dev/null || true
        done
        # Используем официальный установщик — тот же что в hysteria_migrate/hysteria_install
        RUN "bash <(curl -fsSL https://get.hy2.sh/) && systemctl enable hysteria-server && systemctl restart hysteria-server" \
            || { warn "Ошибка установки Hysteria2 на новом сервере"; }
        ok "Hysteria2 перенесена"
    else
        warn "Hysteria2 не найдена, пропускаю"
    fi

    # ── Копируем скрипт ────────────────────────────────────────────
    PUT "$0" "${ruser}@${rip}:/root/setup.sh" 2>/dev/null && \
        RUN "chmod +x /root/setup.sh" 2>/dev/null && ok "setup.sh скопирован" || true

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ ПЕРЕНОС ВСЕГО СТЕКА ЗАВЕРШЁН                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}Следующие шаги:${NC}"
    echo -e "  ${CYAN}1.${NC} Обновите DNS-записи на новый IP: ${CYAN}${rip}${NC}"
    echo -e "  ${CYAN}2.${NC} После обновления DNS перевыпустите SSL:"
    echo -e "     ${CYAN}ssh ${ruser}@${rip} remnawave_panel ssl${NC}"
    echo -e "  ${CYAN}3.${NC} Проверьте работу всех сервисов"
    echo -e "  ${CYAN}4.${NC} Остановите старые сервисы когда всё ОК"
    echo ""

    read -rp "  Остановить все сервисы на ЭТОМ сервере? (y/n): " stop_old < /dev/tty
    if [[ "$stop_old" =~ ^[yY]$ ]]; then
        [ -d /opt/remnawave ] && cd /opt/remnawave && docker compose stop >/dev/null 2>&1 && ok "Panel остановлена"
        systemctl stop telemt 2>/dev/null && ok "MTProxy остановлен" || true
        systemctl stop hysteria-server 2>/dev/null && ok "Hysteria2 остановлена" || true
    fi
}

# ═══════════════════════════════════════════════════════════════════
# ███████████████████  HYSTERIA2 SECTION  ██████████████████████████
# ═══════════════════════════════════════════════════════════════════



hy_is_installed() { command -v hysteria &>/dev/null; }

hy_is_running() { systemctl is-active --quiet hysteria-server 2>/dev/null; }

hy_port_is_free() {
    local p="$1"
    ss -tulpn 2>/dev/null | awk '{print $5}' | grep -qE ":${p}$" && return 1 || return 0
}

hy_port_label() {
    local p="$1"
    if hy_port_is_free "$p"; then
        echo "свободен ✓"
    else
        local proc
        proc=$(ss -tulpn 2>/dev/null | awk '{print $5,$7}' | grep ":${p} " \
            | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
        [ -n "$proc" ] && echo "занят ($proc) ✗" || echo "занят ✗"
    fi
}

hy_is_valid_fqdn() {
    local d="$1"
    [[ "$d" == *.* ]] || return 1
    [[ "${#d}" -le 253 ]] || return 1
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

hy_get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" \
               "https://icanhazip.com" "https://checkip.amazonaws.com"; do
        ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d ' \r\n' || true)"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

hy_resolve_a() {
    local domain="$1"
    if command -v dig &>/dev/null; then
        dig +short A "$domain" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.' || true
    else
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true
    fi
}

# ── Вспомогательные функции для чтения конфига ───────────────────
hy_get_domain() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ""; return 1; }
    hy_get_domain
}

hy_get_port() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ""; return 1; }
    hy_get_port
}

# ── Установка ─────────────────────────────────────────────────────
hysteria_install() {
    step "Установка / Переустановка Hysteria2"

    # ── Переустановка ──────────────────────────────────────────────
    if hy_is_installed; then
        echo ""
        echo -e "  ${YELLOW}Hysteria2 уже установлена.${NC}"
        echo -e "  ${BOLD}1)${RESET} Переустановить (сохранить пользователей и настройки)"
        echo -e "  ${BOLD}2)${RESET} Переустановить полностью (сброс конфига)"
        echo -e "  ${BOLD}0)${RESET} Отмена"
        echo ""
        local reinstall_ch
        read -rp "  Выбор: " reinstall_ch < /dev/tty
        case "$reinstall_ch" in
            1)
                info "Переустановка с сохранением конфига..."
                local backup_cfg="/tmp/hysteria_backup_$(date +%Y%m%d_%H%M%S).yaml"
                cp "$HYSTERIA_CONFIG" "$backup_cfg" 2>/dev/null && info "Конфиг сохранён: $backup_cfg"
                systemctl stop "$HYSTERIA_SVC" 2>/dev/null || true
                bash <(curl -fsSL https://get.hy2.sh/) || { err "Ошибка установки"; return 1; }
                cp "$backup_cfg" "$HYSTERIA_CONFIG"
                systemctl restart "$HYSTERIA_SVC"
                ok "Hysteria2 переустановлена, конфиг восстановлен"
                return 0
                ;;
            2)
                warn "Конфиг будет удалён!"
                read -rp "  Продолжить? (y/N): " _yn < /dev/tty
                [[ "${_yn:-N}" =~ ^[yY]$ ]] || return 1
                systemctl stop "$HYSTERIA_SVC" 2>/dev/null || true
                rm -f "$HYSTERIA_CONFIG"
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор"; return 1 ;;
        esac
    fi

    # ── Домен ──────────────────────────────────────────────────────
    local domain=""
    while true; do
        read -rp "  Домен (например cdn.example.com): " domain < /dev/tty
        hy_is_valid_fqdn "$domain" && break
        warn "Некорректный домен. Нужен FQDN вида sub.example.com"
    done

    # ── Email ──────────────────────────────────────────────────────
    local email=""
    read -rp "  Email для ACME (необязателен, Enter — пропустить): " email < /dev/tty
    email="${email// /}"

    # ── CA ─────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Центр сертификации (CA):${NC}"
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    echo "  │  1) Let's Encrypt  — стандарт, рекомендуется                    │"
    echo "  │  2) ZeroSSL        — резерв если Let's Encrypt заблокирован      │"
    echo "  │  3) Buypass        — сертификат на 180 дней вместо 90            │"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    local ca_choice="" ca_name ca_label
    while [[ ! "$ca_choice" =~ ^[123]$ ]]; do
        read -rp "  Выбор [1]: " ca_choice < /dev/tty
        ca_choice="${ca_choice:-1}"
    done
    case "$ca_choice" in
        1) ca_name="letsencrypt"; ca_label="Let's Encrypt" ;;
        2) ca_name="zerossl";     ca_label="ZeroSSL" ;;
        3) ca_name="buypass";     ca_label="Buypass" ;;
    esac
    ok "CA: $ca_label"

    # ── Порт / Port Hopping ────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Режим порта:${NC}"
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  1) Один порт      — стандарт                          │"
    echo "  │  2) Port Hopping   — диапазон UDP (обход блокировок)   │"
    echo "  └────────────────────────────────────────────────────────┘"
    local port_mode=""
    while [[ ! "$port_mode" =~ ^[12]$ ]]; do
        read -rp "  Выбор [1]: " port_mode < /dev/tty
        port_mode="${port_mode:-1}"
    done

    local port port_hop_start port_hop_end listen_addr
    if [ "$port_mode" = "2" ]; then
        echo ""
        echo -e "  ${WHITE}Диапазон портов для Port Hopping:${NC}"
        read -rp "  Начало диапазона [20000]: " port_hop_start < /dev/tty
        port_hop_start="${port_hop_start:-20000}"
        read -rp "  Конец диапазона [29999]: "  port_hop_end < /dev/tty
        port_hop_end="${port_hop_end:-29999}"
        # Основной порт — первый в диапазоне
        port="$port_hop_start"
        listen_addr="0.0.0.0:${port_hop_start}-${port_hop_end}"
        ok "Port Hopping: UDP ${port_hop_start}-${port_hop_end}"
    else
        echo ""
        echo -e "  ${WHITE}Выберите UDP порт:${NC}"
        echo "  ⚠️  Порт 443 занят Xray/Reality если установлен Remnawave"
        info "Проверка портов..."
        local l8443 l2053 l2083 l2087
        l8443=$(hy_port_label 8443); l2053=$(hy_port_label 2053)
        l2083=$(hy_port_label 2083); l2087=$(hy_port_label 2087)
        echo "  ┌──────────────────────────────────────────────────────────┐"
        printf "  │  1) 8443  — рекомендуется  [%-26s]  │\n" "$l8443"
        printf "  │  2) 2053  — альтернатива   [%-26s]  │\n" "$l2053"
        printf "  │  3) 2083  — альтернатива   [%-26s]  │\n" "$l2083"
        printf "  │  4) 2087  — альтернатива   [%-26s]  │\n" "$l2087"
        echo "  │  5) Ввести свой порт                                     │"
        echo "  └──────────────────────────────────────────────────────────┘"
        local port_choice=""
        while [[ ! "$port_choice" =~ ^[12345]$ ]]; do
            read -rp "  Выбор [1]: " port_choice < /dev/tty
            port_choice="${port_choice:-1}"
        done
        case "$port_choice" in
            1) port=8443 ;; 2) port=2053 ;; 3) port=2083 ;; 4) port=2087 ;;
            5) while true; do
                   read -rp "  Порт (1-65535): " port < /dev/tty
                   [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) && break
                   warn "Некорректный порт"
               done ;;
        esac
        listen_addr="0.0.0.0:${port}"
        if ! hy_port_is_free "$port"; then
            warn "Порт $port занят!"
            local fp; read -rp "  Продолжить? (y/N): " fp < /dev/tty
            [[ "${fp:-N}" =~ ^[yY]$ ]] || { warn "Отмена"; return 1; }
        fi
        ok "Порт: $port"
    fi

    # ── IPv6 ───────────────────────────────────────────────────────
    echo ""
    local use_ipv6=false
    if ip -6 addr show 2>/dev/null | grep -q "inet6.*global"; then
        read -rp "  Включить IPv6 поддержку? (y/N): " ipv6_ch < /dev/tty
        [[ "${ipv6_ch:-N}" =~ ^[yY]$ ]] && {
            use_ipv6=true
            if [ "$port_mode" = "2" ]; then
                listen_addr="[::]:${port_hop_start}-${port_hop_end}"
            else
                listen_addr="[::]:${port}"
            fi
            ok "IPv6 включён"
        }
    fi

    # ── Пользователь ───────────────────────────────────────────────
    local username pass
    read -rp "  Логин [admin]: " username < /dev/tty
    username="${username:-admin}"
    read -rp "  Пароль (пусто = авто): " pass < /dev/tty
    if [ -z "$pass" ]; then
        pass=$(openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $pass"
    fi

    # ── Название подключения ───────────────────────────────────────
    local conn_name
    read -rp "  Название подключения [Hysteria2]: " conn_name < /dev/tty
    conn_name="${conn_name:-Hysteria2}"

    # ── Masquerade ─────────────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Режим маскировки:${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  1) bing.com          — рекомендуется, поддерживает HTTP/3  │"
    echo "  │  2) yahoo.com         — стабильный, поддерживает HTTP/3     │"
    echo "  │  3) cdn.apple.com     — нейтральный, поддерживает HTTP/3    │"
    echo "  │  4) speed.hetzner.de  — нейтральный, поддерживает HTTP/3    │"
    echo "  │  5) /var/www/html     — локальная заглушка (Remnawave)      │"
    echo "  │  6) Ввести свой URL                                          │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    local masq_choice="" masq_type masq_url
    masq_type="proxy"; masq_url=""
    while [[ ! "$masq_choice" =~ ^[123456]$ ]]; do
        read -rp "  Выбор [1]: " masq_choice < /dev/tty
        masq_choice="${masq_choice:-1}"
    done
    case "$masq_choice" in
        1) masq_url="https://www.bing.com" ;;
        2) masq_url="https://www.yahoo.com" ;;
        3) masq_url="https://cdn.apple.com" ;;
        4) masq_url="https://speed.hetzner.de" ;;
        5) masq_type="file"
           if [ ! -d /var/www/html ]; then
               mkdir -p /var/www/html
               cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Please wait</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.dots{display:flex;gap:15px;margin-bottom:30px}.d{width:20px;height:20px;background:#fff;border-radius:50%;animation:b 1.4s infinite ease-in-out both}.d:nth-child(1){animation-delay:-0.32s}.d:nth-child(2){animation-delay:-0.16s}@keyframes b{0%,80%,100%{transform:scale(0);opacity:0.2}40%{transform:scale(1);opacity:1}}.t{color:#555;font-size:14px;letter-spacing:2px;font-weight:600}</style></head><body><div class="dots"><div class="d"></div><div class="d"></div><div class="d"></div></div><div class="t">RETRYING CONNECTION</div></body></html>
HTML
               ok "Заглушка создана: /var/www/html"
           else
               ok "Используется существующая /var/www/html"
           fi ;;
        6) while true; do
               read -rp "  URL (https://...): " masq_url < /dev/tty
               [[ "$masq_url" =~ ^https?:// ]] && break
               warn "URL должен начинаться с https://"
           done ;;
    esac
    [ "$masq_type" = "proxy" ] && ok "Маскировка: proxy → $masq_url" \
                                || ok "Маскировка: file → /var/www/html"

    # ── Алгоритм скорости ──────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Алгоритм контроля скорости:${NC}"
    echo "  [1] BBR    — стандартный, рекомендуется для стабильных каналов"
    echo "  [2] Brutal — агрессивный, для нестабильных каналов / мобильного"
    local speed_mode use_brutal=false bw_up bw_down
    read -rp "  Выбор [1]: " speed_mode < /dev/tty
    speed_mode="${speed_mode:-1}"
    if [ "$speed_mode" = "2" ]; then
        use_brutal=true
        warn "Указывайте реальную скорость — Brutal создаёт до 1.4× нагрузки"
        read -rp "  Download (Mbps) [100]: " bw_down < /dev/tty; bw_down="${bw_down:-100}"
        read -rp "  Upload (Mbps) [50]: "   bw_up   < /dev/tty; bw_up="${bw_up:-50}"
        ok "Brutal: ↓${bw_down} / ↑${bw_up} Mbps"
    else
        ok "BBR (по умолчанию)"
    fi

    # ── Зависимости ────────────────────────────────────────────────
    step "Установка зависимостей"
    apt-get update -y -q && apt-get install -y -q curl ca-certificates openssl qrencode dnsutils

    # ── Проверка DNS ───────────────────────────────────────────────
    step "Проверка DNS"
    local server_ip domain_ips
    server_ip=$(hy_get_public_ip || true)
    [ -z "$server_ip" ] && { err "Не удалось определить IP сервера"; return 1; }
    ok "IP сервера: $server_ip"
    domain_ips=$(hy_resolve_a "$domain" || true)
    [ -z "$domain_ips" ] && { err "Домен $domain не резолвится. Создайте A-запись → $server_ip"; return 1; }
    echo "  A-записи: $(echo "$domain_ips" | tr '\n' ' ')"
    if ! echo "$domain_ips" | grep -qx "$server_ip"; then
        warn "Домен не указывает на этот сервер ($server_ip)!"
        local fc; read -rp "  Продолжить принудительно? (y/N): " fc < /dev/tty
        [[ "${fc:-N}" =~ ^[yY]$ ]] || { warn "Исправьте DNS и запустите снова"; return 1; }
    else
        ok "DNS корректен: $domain → $server_ip"
    fi

    # ── Установка бинарника ────────────────────────────────────────
    step "Установка Hysteria2"
    bash <(curl -fsSL https://get.hy2.sh/) || { err "Ошибка установки"; return 1; }
    command -v hysteria &>/dev/null || { err "Бинарник hysteria не найден"; return 1; }
    ok "Hysteria2 установлен: $(hysteria version 2>/dev/null | grep Version | awk '{print $2}')"

    # ── Конфиг ────────────────────────────────────────────────────
    step "Запись конфигурации"
    install -d -m 0755 "$HYSTERIA_DIR"
    local acme_email_line=""
    [ -n "$email" ] && acme_email_line="  email: ${email}"

    local bw_block=""
    $use_brutal && bw_block="
bandwidth:
  up: ${bw_up} mbps
  down: ${bw_down} mbps"

    local masq_block
    if [ "$masq_type" = "file" ]; then
        masq_block="masquerade:
  type: file
  file:
    dir: /var/www/html"
    else
        masq_block="masquerade:
  type: proxy
  proxy:
    url: ${masq_url}
    rewriteHost: true"
    fi

    cat > "$HYSTERIA_CONFIG" << EOF
listen: ${listen_addr}

acme:
  type: http
  domains:
    - ${domain}
  ca: ${ca_name}
${acme_email_line}

auth:
  type: userpass
  userpass:
    ${username}: "${pass}"
${bw_block}
${masq_block}

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
    ok "Конфигурация записана: $HYSTERIA_CONFIG"

    # ── Сервис ─────────────────────────────────────────────────────
    systemctl daemon-reload
    command -v ufw &>/dev/null && ufw allow 80/tcp >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1
    ok "UFW: временно открыт порт 80 для ACME"
    systemctl enable --now "$HYSTERIA_SVC"

    # Ждём сертификат
    info "Ждём получения сертификата..."
    local i=0
    while [ $i -lt 30 ]; do
        journalctl -u "$HYSTERIA_SVC" -n 20 --no-pager 2>/dev/null | grep -q "server up and running" && break
        sleep 1; i=$((i+1))
    done
    command -v ufw &>/dev/null && ufw delete allow 80/tcp >/dev/null 2>&1
    ok "UFW: порт 80 закрыт"
    ok "Сервис $HYSTERIA_SVC запущен"

    # ── UFW ────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow 22/tcp >/dev/null 2>&1
        if [ "$port_mode" = "2" ]; then
            ufw allow "${port_hop_start}:${port_hop_end}/udp" >/dev/null 2>&1
            ok "UFW: открыт диапазон ${port_hop_start}-${port_hop_end}/udp"
        else
            ufw allow "${port}/udp" >/dev/null 2>&1
            ufw allow "${port}/tcp" >/dev/null 2>&1
            ok "UFW: открыт ${port}/udp и ${port}/tcp"
        fi
        ufw --force enable >/dev/null 2>&1
    fi

    # ── Проверка сертификата ───────────────────────────────────────
    sleep 3
    local cert_expiry=""
    local cert_path="/var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt"
    if [ -f "$cert_path" ]; then
        cert_expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
        [ -n "$cert_expiry" ] && ok "Сертификат действует до: $cert_expiry"
    fi

    # ── URI и файлы ────────────────────────────────────────────────
    local uri txt_file yaml_file qr_file
    local uri_port="$port"
    [ "$port_mode" = "2" ] && uri_port="${port_hop_start}-${port_hop_end}"
    uri="hy2://${username}:${pass}@${domain}:${uri_port}?sni=${domain}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    txt_file="/root/hysteria-${domain}.txt"
    yaml_file="/root/hysteria-${domain}.yaml"
    qr_file="/root/hysteria-${domain}.png"

    echo "$uri" > "$txt_file"

    cat > "$yaml_file" << EOF
proxies:
  - name: ${conn_name}
    type: hysteria2
    server: ${domain}
    port: ${port}
$([ "$port_mode" = "2" ] && echo "    ports: ${port_hop_start}-${port_hop_end}")
    username: ${username}
    password: "${pass}"
    sni: ${domain}
    alpn:
      - h3
    skip-cert-verify: false
$($use_brutal && echo "    up: \"${bw_up} mbps\"" && echo "    down: \"${bw_down} mbps\"")

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - ${conn_name}

rules:
  - MATCH,Proxy
EOF

    qrencode -o "$qr_file" -s 8 "$uri" 2>/dev/null && ok "QR PNG: $qr_file"

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}  ✓ Hysteria2 установлен${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Конфигурация${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Сервер    ${NC}${domain}:${uri_port}"
    echo -e "  ${GRAY}Логин     ${NC}${username}"
    echo -e "  ${GRAY}Пароль    ${NC}${pass}"
    echo -e "  ${GRAY}Режим     ${NC}$( [ "$port_mode" = "2" ] && echo "Port Hopping ${port_hop_start}-${port_hop_end}" || echo "Один порт" )"
    echo -e "  ${GRAY}IPv6      ${NC}$( $use_ipv6 && echo "включён" || echo "выключен" )"
    echo -e "  ${GRAY}Алгоритм  ${NC}$( $use_brutal && echo "Brutal ↓${bw_down}/↑${bw_up} Mbps" || echo "BBR" )"
    [ -n "$cert_expiry" ] && echo -e "  ${GRAY}SSL до    ${NC}${cert_expiry}"
    echo ""
    echo -e "${BOLD}${WHITE}  URI подключения${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${CYAN}${uri}${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Файлы${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}URI          ${NC}${txt_file}"
    echo -e "  ${GRAY}Clash/Mihomo ${NC}${yaml_file}"
    echo -e "  ${GRAY}QR PNG       ${NC}${qr_file}"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}${WHITE}  QR-код${NC}"
        echo -e "${GRAY}  ──────────────────────────────${NC}"
        qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
        echo ""
    fi
}

# ── Статус ────────────────────────────────────────────────────────
hysteria_status() {
    header "Hysteria2 — Статус"
    if hy_is_installed; then
        echo -e "  Версия:  $(hysteria version 2>/dev/null | head -1)"
    fi
    systemctl --no-pager status "$HYSTERIA_SVC" 2>/dev/null || warn "Сервис не найден"
    if [ -f "$HYSTERIA_CONFIG" ]; then
        echo ""
        echo -e "  ${WHITE}Конфигурация:${NC}"
        local dom port usr
        dom=$(hy_get_domain 2>/dev/null || echo "—")
        port=$(hy_get_port 2>/dev/null || echo "—")
        # Первый пользователь из userpass (Python для надёжности)
        usr=$(python3 -c "
import re, sys
try:
    cfg = open('$HYSTERIA_CONFIG').read()
    m = re.search(r'userpass:
(    ([^
:]+):', cfg)
    print(m.group(2).strip() if m else '—')
except: print('—')
" 2>/dev/null || echo "—")
        echo "    Домен: $dom    Порт: $port    Пользователь: $usr"
    fi
}

# ── Логи ──────────────────────────────────────────────────────────
hysteria_logs() {
    header "Hysteria2 — Логи"
    journalctl -u "$HYSTERIA_SVC" -n 80 --no-pager 2>/dev/null || warn "Логи недоступны"
}

# ── Перезапуск ────────────────────────────────────────────────────
hysteria_restart() {
    systemctl restart "$HYSTERIA_SVC" && ok "Hysteria2 перезапущен" || warn "Ошибка перезапуска"
}

# ── Добавить пользователя ─────────────────────────────────────────
# ── Удалить пользователя Hysteria2 ───────────────────────────────
hysteria_delete_user() {
    header "Hysteria2 — Удалить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя для удаления:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi

    local selected="${users[$((ch-1))]}"
    read -rp "  Удалить '${selected}'? (y/N): " _yn < /dev/tty
    [[ "${_yn:-N}" =~ ^[yY]$ ]] || { warn "Отменено"; return; }

    # Удаляем строку из userpass
    sed -i "/^    ${selected}:/d" "$HYSTERIA_CONFIG"

    ok "Пользователь '${selected}' удалён"

    # Перезапускаем сервис
    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
    sleep 1
    ok "Конфиг применён"
}

hysteria_add_user() {
    header "Hysteria2 — Добавить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден. Сначала установите Hysteria2"; return 1; }

    local new_user new_pass
    # Показываем существующих пользователей
    local existing
    existing=$(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:" | sed 's/:.*//' | tr -d ' ' | tr '\n' ' ')
    [ -n "$existing" ] && info "Существующие пользователи: ${existing}"

    # Ввод имени с проверкой на дубликат
    while true; do
        read -rp "  Имя пользователя: " new_user < /dev/tty
        [ -z "$new_user" ] && { warn "Имя не может быть пустым"; continue; }
        if grep -qE "^    ${new_user}:" "$HYSTERIA_CONFIG" 2>/dev/null; then
            warn "Пользователь '${new_user}' уже существует."
            echo ""
            echo -e "  ${BOLD}1)${RESET} Ввести другое имя"
            echo -e "  ${BOLD}2)${RESET} Заменить пароль для '${new_user}'"
            echo -e "  ${BOLD}0)${RESET} Отмена"
            local ch; read -rp "  Выбор: " ch < /dev/tty
            case "$ch" in
                1) continue ;;
                2)
                    read -rp "  Новый пароль (пусто = авто): " new_pass < /dev/tty
                    if [ -z "$new_pass" ]; then
                        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
                        info "Сгенерирован пароль: $new_pass"
                    fi
                    sed -i "s/^    ${new_user}:.*$/    ${new_user}: \"${new_pass}\"/" "$HYSTERIA_CONFIG"
                    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
                    ok "Пароль для '${new_user}' обновлён"
                    return 0 ;;
                *) return 0 ;;
            esac
        else
            break
        fi
    done

    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    # Вставляем под userpass:
    sed -i "/^  userpass:/a\\    ${new_user}: \"${new_pass}\"" "$HYSTERIA_CONFIG"
    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
    ok "Пользователь '${new_user}' добавлен"

    # Генерируем URI для нового пользователя
    local dom port conn_name uri
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    # Собираем существующие названия из URI-файла
    local users_file="/root/hysteria-${dom}-users.txt"
    local main_file="/root/hysteria-${dom}.txt"
    local -a existing_names=()
    for f in "$users_file" "$main_file"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            local n; n=$(echo "$line" | grep -a "hy2://" | sed 's/.*#//')
            [ -n "$n" ] && existing_names+=("$n")
        done < "$f"
    done
    # Убираем дубликаты
    local -a unique_names=()
    for n in "${existing_names[@]}"; do
        local found=0
        for u in "${unique_names[@]}"; do [ "$u" = "$n" ] && found=1 && break; done
        [ $found -eq 0 ] && unique_names+=("$n")
    done

    echo ""
    echo -e "  ${WHITE}Название подключения:${NC}"
    local i=1
    for n in "${unique_names[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${n}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}${i})${RESET} Ввести новое название"
    echo ""
    local ch; read -rp "  Выбор [${i}]: " ch < /dev/tty
    ch="${ch:-$i}"
    if [[ "$ch" =~ ^[0-9]+$ ]] && [ "$ch" -ge 1 ] && [ "$ch" -lt "$i" ]; then
        conn_name="${unique_names[$((ch-1))]}"
    else
        read -rp "  Новое название [${new_user}]: " conn_name < /dev/tty
        conn_name="${conn_name:-$new_user}"
    fi
    uri="hy2://${new_user}:${new_pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    echo "  QR-код:"
    qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    echo "$uri" >> "/root/hysteria-${dom}-users.txt"
    ok "URI сохранён: /root/hysteria-${dom}-users.txt"
}

# ── Миграция ──────────────────────────────────────────────────────
hysteria_migrate() {
    header "Hysteria2 — Перенос на новый сервер"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Hysteria2 не установлена на этом сервере"; return 1; }
    ensure_sshpass

    ask_ssh_target
    init_ssh_helpers hysteria
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    info "Проверка подключения..."
    RUN echo ok >/dev/null 2>&1 || { err "Не удалось подключиться к ${rip}:${rport}"; return 1; }
    ok "Подключение успешно"

    # Получаем домен из конфига
    local domain hy_port
    domain=$(hy_get_domain)
    hy_port=$(hy_get_port)

    # 1. Установка Hysteria2 на новом сервере
    info "Установка Hysteria2 на новом сервере..."
    RUN "bash <(curl -fsSL https://get.hy2.sh/)" || { err "Ошибка установки"; return 1; }
    ok "Hysteria2 установлен"

    # 2. Копирование конфига
    info "Копирование конфигурации..."
    RUN "mkdir -p /etc/hysteria"
    PUT "$HYSTERIA_CONFIG" "${ruser}@${rip}:/etc/hysteria/config.yaml"
    ok "Конфиг скопирован"

    # 3. Копирование сертификата Let's Encrypt
    if [ -d "/etc/letsencrypt/live/${domain}" ]; then
        info "Копирование SSL-сертификата..."
        RUN "mkdir -p /etc/letsencrypt"
        PUT /etc/letsencrypt/live    "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        PUT /etc/letsencrypt/archive "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        PUT /etc/letsencrypt/renewal "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        ok "Сертификат скопирован (действует до истечения, затем обновится автоматически)"
    else
        warn "Сертификат /etc/letsencrypt/live/${domain} не найден — Hysteria переиздаст его через ACME после смены DNS"
    fi

    # 4. Открытие портов и запуск
    info "Открытие портов и запуск сервиса..."
    RUN bash << REMOTE
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow ${hy_port}/udp >/dev/null 2>&1 || true
ufw allow ${hy_port}/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
apt-get install -y qrencode >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now hysteria-server
REMOTE
    ok "Сервис запущен на новом сервере"

    # 5. Копирование URI-файлов
    # Копируем URI-файлы с явной проверкой — glob в scp без файлов передаёт литеральную строку с *
    for _f in /root/hysteria-${domain}*.txt /root/hysteria-${domain}*.yaml; do
        [ -f "$_f" ] && PUT "$_f" "${ruser}@${rip}:/root/" 2>/dev/null || true
    done

    # 6. Копирование этого скрипта
    local script_path; script_path=$(realpath "$0" 2>/dev/null || echo "/root/setup.sh")
    PUT "$script_path" "${ruser}@${rip}:${script_path}" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅  Перенос Hysteria2 завершён                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Следующие шаги:${NC}"
    echo ""
    echo -e "  ${WHITE}1. Обновите DNS A-запись:${NC}"
    echo -e "     ${CYAN}${domain}${NC}  →  ${WHITE}${rip}${NC}"
    echo ""
    echo -e "  ${WHITE}2. После обновления DNS сертификат обновится автоматически.${NC}"
    echo ""
    echo -e "  ${WHITE}3. Проверьте работу на новом сервере, затем остановите старый:${NC}"
    echo -e "     ${CYAN}systemctl stop hysteria-server${NC}"
    echo ""

    # ── Мониторинг DNS и автоматический перезапуск ────────────────
    local wait_dns
    read -rp "  Ждать обновления DNS и автоматически перезапустить сервис? (y/N): " wait_dns < /dev/tty
    if [[ "${wait_dns:-N}" =~ ^[yY]$ ]]; then
        echo ""
        info "Мониторинг DNS: ожидаем когда ${domain} → ${rip}"
        info "Проверка каждые 30 секунд. Ctrl+C для отмены."
        echo ""

        local attempt=0 max_attempts=120  # максимум 60 минут
        local resolved_ip=""

        while true; do
            attempt=$((attempt + 1))
            resolved_ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)

            printf "  [%3d] %s → %s" "$attempt" "$domain" "${resolved_ip:-не резолвится}"

            if [ "$resolved_ip" = "$rip" ]; then
                echo ""
                echo ""
                ok "DNS обновлён: ${domain} → ${rip}"
                echo ""
                info "Перезапускаем hysteria-server на новом сервере..."
                if RUN "systemctl restart hysteria-server" 2>/dev/null; then
                    ok "Сервис перезапущен — ACME переиздаст сертификат автоматически"
                    echo ""
                    info "Проверка статуса через 10 секунд..."
                    sleep 10
                    local svc_status
                    svc_status=$(RUN "systemctl is-active hysteria-server" 2>/dev/null || echo "unknown")
                    if [ "$svc_status" = "active" ]; then
                        ok "hysteria-server активен ✓"
                    else
                        warn "Сервис не запустился. Проверьте логи:"
                        echo -e "     ${CYAN}ssh ${ruser}@${rip} journalctl -u hysteria-server -n 30${NC}"
                    fi
                else
                    warn "Не удалось перезапустить сервис. Перезапустите вручную:"
                    echo -e "     ${CYAN}ssh ${ruser}@${rip} systemctl restart hysteria-server${NC}"
                fi
                echo ""
                echo -e "  ${YELLOW}Убедитесь что всё работает, затем остановите старый сервер:${NC}"
                echo -e "     ${CYAN}systemctl stop hysteria-server${NC}"
                echo ""
                break
            else
                # Показываем прогресс-бар ожидания 30 секунд
                printf " — ожидание"
                for i in $(seq 1 6); do
                    sleep 5
                    printf "."
                done
                printf "
[K"
            fi

            if [ "$attempt" -ge "$max_attempts" ]; then
                echo ""
                warn "Таймаут 60 минут. DNS так и не обновился."
                warn "Обновите DNS вручную и перезапустите сервис:"
                echo -e "     ${CYAN}ssh ${ruser}@${rip} systemctl restart hysteria-server${NC}"
                break
            fi
        done
    fi
}

# ── Показать ссылки пользователей ────────────────────────────────
hysteria_show_links() {
    header "Hysteria2 — Пользователи и ссылки"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""

    local ch; read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi

    local selected="${users[$((ch-1))]}"
    local pass
    # Python-парсинг надёжнее sed — не ломается на спецсимволах (: # " в пароле)
    if command -v python3 &>/dev/null; then
        pass=$(python3 -c "
import sys, re
cfg = open('$HYSTERIA_CONFIG').read()
m = re.search(r'^ {4}' + re.escape('${selected}') + r':\s*[\"\x27]?([^\"\x27\n]+)[\"\x27]?', cfg, re.M)
print(m.group(1).strip() if m else '')
" 2>/dev/null)
    else
        pass=$(grep -E "^    ${selected}:" "$HYSTERIA_CONFIG" | sed 's/.*: //' | tr -d '"' | tr -d "'")
    fi

    # Ищем сохранённое название из URI-файлов
    local conn_name=""
    for f in "/root/hysteria-${dom}-users.txt" "/root/hysteria-${dom}.txt"; do
        [ -f "$f" ] || continue
        local found_name
        found_name=$(grep -a "hy2://${selected}:" "$f" 2>/dev/null | sed 's/.*#//' | tail -1 || true)
        if [ -n "$found_name" ]; then
            conn_name="$found_name"
            break
        fi
    done
    # Если не нашли — используем имя пользователя
    conn_name="${conn_name:-$selected}"

    local uri="hy2://${selected}:${pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"

    echo ""
    echo -e "  ${CYAN}Пользователь:${NC} ${selected}"
    echo -e "  ${CYAN}Сервер:${NC}       ${dom}:${port}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}${WHITE}  QR-код${NC}"
        echo -e "${GRAY}  ──────────────────────────────${NC}"
        qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    else
        echo -e "  ${GRAY}QR: установите qrencode — apt install qrencode${NC}"
    fi
    echo ""
}

# ── Подменю Hysteria2 ─────────────────────────────────────────────
# hysteria_merge_sub удалена — используется hysteria_merge_sub (http.server, без зависимостей)

# ── Merged подписка (Remnawave + Hysteria2) ──────────────────────
hysteria_merge_sub() {
    header "Hysteria2 — Объединённая подписка"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Hysteria2 не установлена"; return 1; }
    command -v python3 &>/dev/null || { warn "Требуется python3"; return 1; }

    local dom
    dom=$(hy_get_domain)

    # Собираем URI Hysteria2
    local -a hy_uris=()
    for f in "/root/hysteria-${dom}.txt" "/root/hysteria-${dom}-users.txt"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^hy2:// ]] && hy_uris+=("$line")
        done < "$f"
    done
    [ ${#hy_uris[@]} -eq 0 ] && { warn "URI Hysteria2 не найдены"; return 1; }

    # Домен подписок из .env
    local sub_domain=""
    [ -f /opt/remnawave/.env ] && sub_domain=$(grep "^SUB_PUBLIC_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d ' ')
    if [ -z "$sub_domain" ]; then
        read -rp "  Домен подписок Remnawave (sub.example.com): " sub_domain < /dev/tty
    fi
    info "Домен подписок: $sub_domain"

    # Selfsteal домен
    local selfsteal_dom=""
    if [ -f /opt/remnawave/nginx.conf ]; then
        selfsteal_dom=$(grep -B3 "root /var/www/html" /opt/remnawave/nginx.conf | grep "server_name" | awk '{print $2}' | tr -d ';' | head -1)
    fi

    local merge_name
    read -rp "  Имя endpoint'а [hy-merge]: " merge_name < /dev/tty
    merge_name="${merge_name:-hy-merge}"

    # Записываем URI в файл для merger скрипта
    local hy_uris_file="/etc/hy-merger-uris.txt"
    printf '%s\n' "${hy_uris[@]}" > "$hy_uris_file"
    ok "URI сохранены: $hy_uris_file (${#hy_uris[@]} шт.)"

    # Создаём Python merger скрипт
    local script_path="/usr/local/bin/hy_sub_merger.py"
    cat > "$script_path" << 'PYEOF'
#!/usr/bin/env python3
import http.server, urllib.request, base64, ssl, os

HY_URIS_FILE = "/etc/hy-merger-uris.txt"
SUB_DOMAIN = os.environ.get("SUB_DOMAIN", "")
PORT = int(os.environ.get("MERGER_PORT", "18080"))

def get_hy_uris():
    try:
        with open(HY_URIS_FILE) as f:
            return [l.strip() for l in f if l.strip().startswith("hy2://")]
    except:
        return []

class MergerHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        token = self.path.strip("/")
        if not token:
            self.send_response(404); self.end_headers(); return
        rw_uris = []
        try:
            ctx = ssl.create_default_context()
            url = f"https://{SUB_DOMAIN}/{token}"
            req = urllib.request.Request(url, headers={"User-Agent": "clash"})
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                raw = resp.read()
            try:
                decoded = base64.b64decode(raw).decode("utf-8")
            except:
                decoded = raw.decode("utf-8")
            rw_uris = [l for l in decoded.splitlines() if l.strip()]
        except Exception as e:
            pass
        all_uris = rw_uris + get_hy_uris()
        merged = base64.b64encode("\n".join(all_uris).encode()).decode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Profile-Update-Interval", "12")
        self.end_headers()
        self.wfile.write(merged.encode())

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), MergerHandler)
    print(f"Merger running on port {PORT}", flush=True)
    server.serve_forever()
PYEOF
    chmod +x "$script_path"
    ok "Merger скрипт: $script_path"

    # Systemd сервис
    cat > /etc/systemd/system/hy-merger.service << SVCEOF
[Unit]
Description=Hysteria2 Subscription Merger
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/hy_sub_merger.py
Restart=always
RestartSec=5
Environment=MERGER_PORT=18080
Environment=SUB_DOMAIN=${sub_domain}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now hy-merger
    sleep 2
    if systemctl is-active --quiet hy-merger; then
        ok "Сервис hy-merger запущен"
    else
        warn "Сервис не запустился: journalctl -u hy-merger -n 20"
        return 1
    fi

    # Добавляем location в nginx конфиг панели
    if [ -f /opt/remnawave/nginx.conf ]; then
        if grep -q "hy-merger" /opt/remnawave/nginx.conf; then
            info "location уже есть в nginx.conf"
        else
            local loc_block="
    # Hysteria2 merged subscription
    location ~* ^/${merge_name}/(.+)\$ {
        proxy_pass http://127.0.0.1:18080/\$1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }"
            # Вставляем перед "root /var/www/html"
            sed -i "s|    root /var/www/html; index index.html;|${loc_block}\n    root /var/www/html; index index.html;|" /opt/remnawave/nginx.conf
            cd /opt/remnawave && docker compose restart remnawave-nginx >/dev/null 2>&1
            ok "location добавлен в nginx, перезапущен"
        fi
    else
        warn "nginx.conf не найден — добавьте location вручную"
    fi

    echo ""
    echo -e "  ${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  Объединённая подписка готова!${NC}"
    echo -e "  ${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    if [ -n "$selfsteal_dom" ]; then
        echo -e "  ${CYAN}Ссылка (вместо оригинальной Remnawave):${NC}"
        echo -e "  ${WHITE}https://${selfsteal_dom}/${merge_name}/ТОКЕН${NC}"
        echo ""
        echo -e "  ${GRAY}Пример: https://${selfsteal_dom}/${merge_name}/uR5UffbwYXMA${NC}"
    else
        echo -e "  https://SELFSTEAL_DOMAIN/${merge_name}/ТОКЕН"
    fi
    echo ""
    echo -e "  ${YELLOW}Обновить URI Hysteria (после добавления пользователей):${NC}"
    echo -e "  ${CYAN}printf '%s\\n' \$(cat /root/hysteria-*.txt | grep hy2://) > /etc/hy-merger-uris.txt${NC}"
    echo -e "  ${CYAN}systemctl restart hy-merger${NC}"
}


hysteria_menu() {
    while true; do
        # Защита от set -e: || true на всех внешних командах
        local ver dom port
        ver=$(get_hysteria_version 2>/dev/null || true)
        dom=$(hy_get_domain 2>/dev/null || true)
        port=$(hy_get_port 2>/dev/null || true)
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  🚀  Hysteria2${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$dom" ]; then
            [ -n "$ver" ] && echo -e "  ${GRAY}Версия  ${NC}${ver}"
            [ -n "$dom" ] && echo -e "  ${GRAY}Сервер  ${NC}${dom}${port:+:$port}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  🔧  Установка"
        echo -e "  ${BOLD}2)${RESET}  ⚙️   Управление"
        echo -e "  ${BOLD}3)${RESET}  👥  Пользователи"
        echo -e "  ${BOLD}4)${RESET}  🔗  Подписка"
        echo -e "  ${BOLD}5)${RESET}  📦  Миграция на другой сервер"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ◀️   Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_install ;;
            2) hysteria_submenu_manage ;;
            3) hysteria_submenu_users ;;
            4) hysteria_submenu_sub ;;
            5) hysteria_migrate; read -rp "Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

hysteria_submenu_manage() {
    while true; do
        clear
        header "Hysteria2 — Управление"
        echo -e "  ${BOLD}1)${RESET} 📊  Статус"
        echo -e "  ${BOLD}2)${RESET} 📋  Логи"
        echo -e "  ${BOLD}3)${RESET} 🔄  Перезапустить"
        echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_status; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_logs;   read -rp "Enter..." < /dev/tty ;;
            3) hysteria_restart; read -rp "Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

hysteria_submenu_users() {
    while true; do
        clear
        header "Hysteria2 — Пользователи"
        echo -e "  ${BOLD}1)${RESET} ➕  Добавить пользователя"
        echo -e "  ${BOLD}2)${RESET} ➖  Удалить пользователя"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи и ссылки"
        echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_add_user; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_delete_user; read -rp "Enter..." < /dev/tty ;;
            3) hysteria_show_links; read -rp "Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}


# ── Интеграция Hysteria2 → Remnawave (webhook + subscription-page) ────────────

# Ожидаемая SHA256 контрольная сумма hy-sub-install.sh
# Обновите это значение при каждом целевом обновлении скрипта
HY_SUB_INSTALL_SHA256="REPLACE_WITH_ACTUAL_SHA256"

hysteria_remnawave_integration() {
    local script_url="https://raw.githubusercontent.com/stump3/setup_rth/main/hy-sub-install.sh"
    local tmp; tmp=$(mktemp /tmp/hy-sub-install.XXXXXX.sh)

    info "Скачиваем hy-sub-install.sh..."
    if ! curl -fsSL "$script_url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "Не удалось скачать hy-sub-install.sh с GitHub"
        return 1
    fi

    # ── Проверка контрольной суммы ────────────────────────────────
    if [ "$HY_SUB_INSTALL_SHA256" != "REPLACE_WITH_ACTUAL_SHA256" ]; then
        local actual_sha
        actual_sha=$(sha256sum "$tmp" | awk '"'"'{print $1}'"'"')
        if [ "$actual_sha" != "$HY_SUB_INSTALL_SHA256" ]; then
            rm -f "$tmp"
            err "Контрольная сумма не совпадает!
  Ожидалось: $HY_SUB_INSTALL_SHA256
  Получено:  $actual_sha
  Скрипт не будет выполнен. Возможна компрометация репозитория."
            return 1
        fi
        ok "Контрольная сумма верна ✓"
    else
        warn "Контрольная сумма не задана — выполнение без проверки"
        warn "Установите HY_SUB_INSTALL_SHA256 для защиты от компрометации"
        echo ""
        if ! confirm "Продолжить без проверки контрольной суммы?" n; then
            rm -f "$tmp"
            return 1
        fi
    fi

    chmod +x "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

hysteria_submenu_sub() {
    while true; do
        clear
        header "Hysteria2 — Подписка"
        echo -e "  ${BOLD}1)${RESET} 📤  Опубликовать подписку"
        echo -e "  ${BOLD}2)${RESET} 🔗  Объединить с подпиской Remnawave (merger)"
        echo -e "  ${BOLD}3)${RESET} 🪝  Интеграция с Remnawave (webhook + sub-page)"
        echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_publish_sub; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_merge_sub; read -rp "Enter..." < /dev/tty ;;
            3) hysteria_remnawave_integration ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}


migrate_menu() {
    clear
    echo ""
    echo -e "${BOLD}${WHITE}  📦  Перенос сервисов${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}1)${RESET} 🛡️   Перенести Remnawave Panel"
    echo -e "  ${BOLD}2)${RESET} 📡  Перенести MTProxy (telemt)"
    echo -e "  ${BOLD}3)${RESET} 🚀  Перенести Hysteria2"
    echo -e "  ${BOLD}4)${RESET} 📦  Перенести всё (Panel + MTProxy + Hysteria2)"
    echo -e "  ${BOLD}5)${RESET} 💾  Бэкап / Восстановление (backup-restore)"
    echo -e "  ${BOLD}0)${RESET} ◀️   Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) do_migrate ;;
        2) [ -z "$TELEMT_MODE" ] && {
               TELEMT_MODE="systemd"
               TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"
               TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
           }
           telemt_menu_migrate ;;
        3) hysteria_migrate ;;
        4) check_root; migrate_all ;;
        5) panel_backup_restore ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    migrate_menu
}

panel_backup_restore() {
    header "Бэкап / Восстановление"
    local script_url="https://raw.githubusercontent.com/Remnawave/backup-restore/main/backup-restore.sh"
    local script_path="/usr/local/bin/remnawave-backup"

    if command -v remnawave-backup &>/dev/null; then
        info "backup-restore уже установлен — запускаем..."
        remnawave-backup
        return
    fi

    info "Скачиваем backup-restore скрипт..."
    if curl -fsSL "$script_url" -o "$script_path" 2>/dev/null; then
        chmod +x "$script_path"
        ok "backup-restore установлен: $script_path"
        remnawave-backup
    else
        err "Не удалось скачать скрипт"
        echo -e "  Установите вручную:"
        echo -e "  ${CYAN}curl -fsSL $script_url | bash${NC}"
    fi
}


# ═══════════════════════════════════════════════════════════════════
# ГЛАВНОЕ МЕНЮ
# ═══════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${PURPLE}  SERVER-MANAGER${NC}${GRAY}  ${SCRIPT_VERSION}${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        echo ""

        # Быстрый статус с версиями
        local panel_status telemt_status hysteria_status
        local rw_ver hy_ver
        rw_ver=$(get_remnawave_version 2>/dev/null)
        hy_ver=$(get_hysteria_version 2>/dev/null)

        if { docker ps --format '{{.Names}}' 2>/dev/null || true; } | grep -q "^remnawave$"; then
            panel_status="${GREEN}●${NC} запущена${rw_ver:+  ${GRAY}${rw_ver}${NC}}"
        elif [ -d /opt/remnawave ]; then
            panel_status="${YELLOW}◐${NC} остановлена"
        else
            panel_status="${GRAY}○ не установлена${NC}"
        fi

        if systemctl is-active --quiet telemt 2>/dev/null; then
            telemt_status="${GREEN}●${NC} запущен (systemd)"
        elif { docker ps --format '{{.Names}}' 2>/dev/null || true; } | grep -q "^telemt$"; then
            telemt_status="${GREEN}●${NC} запущен (Docker)"
        elif [ -f "$TELEMT_CONFIG_SYSTEMD" ] || [ -f "$TELEMT_CONFIG_DOCKER" ]; then
            telemt_status="${YELLOW}◐${NC} остановлен"
        else
            telemt_status="${GRAY}○ не установлен${NC}"
        fi

        if hy_is_running 2>/dev/null; then
            hysteria_status="${GREEN}●${NC} запущена${hy_ver:+  ${GRAY}${hy_ver}${NC}}"
        elif hy_is_installed 2>/dev/null; then
            hysteria_status="${YELLOW}◐${NC} остановлена"
        else
            hysteria_status="${GRAY}○ не установлена${NC}"
        fi

        echo -e "  ${GRAY}Remnawave Panel  ${NC}$(echo -e "$panel_status")"
        echo -e "  ${GRAY}MTProxy (telemt) ${NC}$(echo -e "$telemt_status")"
        echo -e "  ${GRAY}Hysteria2        ${NC}$(echo -e "$hysteria_status")"
        echo ""
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET}  🛡️   Remnawave Panel"
        echo -e "  ${BOLD}2)${RESET}  📡  MTProxy (telemt)"
        echo -e "  ${BOLD}3)${RESET}  🚀  Hysteria2"
        echo -e "  ${BOLD}4)${RESET}  📦  Перенос"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  Выход"
        echo ""
        local ch; read -rp "  Выбор: " ch
        case "$ch" in
            1) panel_menu ;;
            2) telemt_section ;;
            3) hysteria_menu ;;
            4) migrate_menu ;;
            0) exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ─── Точка входа ───────────────────────────────────────────────────
check_root
main_menu
