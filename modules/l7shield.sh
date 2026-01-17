#!/bin/bash
#
# l7shield.sh - Комплексная L7 защита от DDoS для VPN нод
# Server Security Shield v2.3
#
# Функционал:
# - Connection Limits (iptables)
# - Rate Limiting (iptables + nginx)
# - SYN Flood Protection
# - HTTP Flood Protection (nginx)
# - Auto-ban система
# - GeoIP Blocking
# - IP Blacklists (по URL)
# - Whitelist для VPN портов
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

L7_CONFIG_DIR="$CONFIG_DIR/l7shield"
L7_CONFIG_FILE="$L7_CONFIG_DIR/config.conf"
L7_WHITELIST="$L7_CONFIG_DIR/whitelist.txt"
L7_BLACKLIST="$L7_CONFIG_DIR/blacklist.txt"
L7_BLACKLIST_URLS="$L7_CONFIG_DIR/blacklist_urls.txt"
L7_VPN_PORTS="$L7_CONFIG_DIR/vpn_ports.txt"
L7_GEOIP_ALLOW="$L7_CONFIG_DIR/geoip_allow.txt"
L7_LOG="/opt/server-shield/logs/l7shield.log"
L7_BAN_LOG="/opt/server-shield/logs/l7_bans.log"

L7_SCRIPT="/opt/server-shield/scripts/l7-protect.sh"
L7_NGINX_CONF="/etc/nginx/conf.d/l7shield.conf"
L7_NGINX_MAPS="/etc/nginx/conf.d/l7shield_maps.conf"
L7_CRON="/etc/cron.d/shield-l7"
L7_SERVICE="/etc/systemd/system/shield-l7.service"

IPSET_BLACKLIST="l7_blacklist"
IPSET_WHITELIST="l7_whitelist"
IPSET_GEOBLOCK="l7_geoblock"
IPSET_AUTOBAN="l7_autoban"

# Дефолтные VPN порты
DEFAULT_VPN_PORTS="443 8443 2053 2083 2087 2096"

# ============================================
# GITHUB SYNC КОНФИГУРАЦИЯ
# ============================================

GITHUB_SYNC_ENABLED="true"
GITHUB_REPO="wrx861/blockip"
GITHUB_FILE="iplist.txt"
GITHUB_PAT_FILE="/opt/server-shield/config/github_pat.conf"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_FILE}"
GITHUB_RAW_URL="https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_FILE}"

# Загрузить PAT из файла
load_github_pat() {
    if [[ -f "$GITHUB_PAT_FILE" ]]; then
        GITHUB_PAT=$(cat "$GITHUB_PAT_FILE" | tr -d '\n\r ')
    else
        GITHUB_PAT=""
    fi
}

L7_SYNC_QUEUE="$L7_CONFIG_DIR/sync_queue.txt"
L7_SYNCED_IPS="$L7_CONFIG_DIR/synced_ips.txt"
L7_LAST_SYNC="$L7_CONFIG_DIR/last_sync.txt"

# ============================================
# ИНИЦИАЛИЗАЦИЯ
# ============================================

# Проверить и установить nginx если нужно
ensure_nginx_installed() {
    if command -v nginx &>/dev/null; then
        # Проверяем есть ли модуль headers-more (для more_clear_headers)
        if ! nginx -V 2>&1 | grep -q "headers-more"; then
            log_step "Установка nginx-extras (модуль headers-more)..."
            if command -v apt-get &>/dev/null; then
                apt-get install -y nginx-extras >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi
    
    log_step "Установка Nginx..."
    
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        # Ставим nginx-extras который включает headers-more модуль
        apt-get install -y nginx-extras >/dev/null 2>&1 || apt-get install -y nginx >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y nginx >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y nginx >/dev/null 2>&1
    else
        log_error "Не удалось определить пакетный менеджер"
        return 1
    fi
    
    if command -v nginx &>/dev/null; then
        systemctl enable nginx 2>/dev/null
        systemctl start nginx 2>/dev/null
        log_info "Nginx установлен"
        return 0
    else
        log_error "Не удалось установить Nginx"
        return 1
    fi
}

init_l7_config() {
    mkdir -p "$L7_CONFIG_DIR"
    mkdir -p "$(dirname "$L7_LOG")"
    mkdir -p "$(dirname "$L7_SCRIPT")"
    
    # Дефолтный конфиг
    if [[ ! -f "$L7_CONFIG_FILE" ]]; then
        cat > "$L7_CONFIG_FILE" << 'EOF'
# L7 Shield Configuration
L7_ENABLED="false"

# Connection Limits (per IP)
CONN_LIMIT_GLOBAL="500"       # Макс соединений с одного IP (глобально)
CONN_LIMIT_VPN="300"          # Макс соединений для VPN портов (выше!)
CONN_LIMIT_SSH="10"           # Макс соединений на SSH
CONN_LIMIT_HTTP="100"         # Макс соединений на HTTP/HTTPS (не VPN)

# Rate Limits (new connections per second per IP)
RATE_LIMIT_GLOBAL="50/s"      # Новых соединений в сек
RATE_LIMIT_VPN="100/s"        # Для VPN портов (мягче)
RATE_LIMIT_HTTP="30/s"        # Для HTTP

# SYN Protection
SYN_RATE="1000/s"             # SYN пакетов в секунду
SYN_BURST="2000"              # Burst

# Auto-ban thresholds
AUTOBAN_ENABLED="true"
AUTOBAN_CONN_THRESHOLD="300"  # Бан при > N соединений
AUTOBAN_RATE_THRESHOLD="200"  # Бан при > N запросов/мин
AUTOBAN_TIME="3600"           # Время бана (сек)

# Nginx Rate Limiting
NGINX_RATE_LIMIT="50r/s"      # Запросов в секунду
NGINX_BURST="100"             # Burst
NGINX_NODELAY="yes"           # Без задержки

# GeoIP
GEOIP_ENABLED="false"
GEOIP_MODE="allow"            # allow = только указанные, deny = кроме указанных

# Blacklist URLs update interval (hours)
BLACKLIST_UPDATE_INTERVAL="6"
EOF
    fi
    
    # Дефолтные VPN порты
    if [[ ! -f "$L7_VPN_PORTS" ]]; then
        echo "# VPN порты (один на строку)" > "$L7_VPN_PORTS"
        echo "# Эти порты получают мягкие лимиты" >> "$L7_VPN_PORTS"
        for port in $DEFAULT_VPN_PORTS; do
            echo "$port" >> "$L7_VPN_PORTS"
        done
    fi
    
    # Пустые файлы
    [[ ! -f "$L7_WHITELIST" ]] && echo "# IP whitelist (один на строку)" > "$L7_WHITELIST"
    [[ ! -f "$L7_BLACKLIST" ]] && echo "# IP blacklist (один на строку)" > "$L7_BLACKLIST"
    [[ ! -f "$L7_BLACKLIST_URLS" ]] && echo "# URLs для скачивания blacklist (один на строку)" > "$L7_BLACKLIST_URLS"
    [[ ! -f "$L7_GEOIP_ALLOW" ]] && cat > "$L7_GEOIP_ALLOW" << 'EOF'
# GeoIP - разрешённые страны (ISO коды)
# Раскомментируйте нужные
RU
UA
BY
KZ
# US
# DE
# NL
# FR
EOF
}

# Загрузить конфиг
load_l7_config() {
    init_l7_config
    source "$L7_CONFIG_FILE"
}

# Сохранить параметр конфига
save_l7_param() {
    local key="$1"
    local value="$2"
    
    if grep -q "^${key}=" "$L7_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$L7_CONFIG_FILE"
    else
        echo "${key}=\"${value}\"" >> "$L7_CONFIG_FILE"
    fi
}

# Получить VPN порты
get_vpn_ports() {
    if [[ -f "$L7_VPN_PORTS" ]]; then
        grep -v "^#" "$L7_VPN_PORTS" | grep -v "^$" | tr '\n' ' '
    else
        echo "$DEFAULT_VPN_PORTS"
    fi
}

# ============================================
# IPSET УПРАВЛЕНИЕ
# ============================================

# Создать ipset если не существует
create_ipset() {
    local name="$1"
    local type="${2:-hash:ip}"
    local timeout="${3:-}"
    
    if ! ipset list "$name" &>/dev/null; then
        if [[ -n "$timeout" ]]; then
            ipset create "$name" "$type" timeout "$timeout" maxelem 1000000 2>/dev/null
        else
            ipset create "$name" "$type" maxelem 1000000 2>/dev/null
        fi
    fi
}

# Инициализация всех ipset
init_ipsets() {
    # Проверка ipset
    if ! command -v ipset &>/dev/null; then
        apt-get update -qq && apt-get install -y ipset >/dev/null 2>&1
    fi
    
    create_ipset "$IPSET_BLACKLIST" "hash:ip"
    create_ipset "$IPSET_WHITELIST" "hash:ip"
    create_ipset "$IPSET_GEOBLOCK" "hash:net"
    create_ipset "$IPSET_AUTOBAN" "hash:ip" "3600"  # С таймаутом
}

# Добавить IP в blacklist
add_to_blacklist() {
    local ip="$1"
    local reason="${2:-manual}"
    
    ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    echo "$ip" >> "$L7_BLACKLIST"
    
    # Лог
    echo "$(date '+%Y-%m-%d %H:%M:%S') | BLACKLIST | $ip | $reason" >> "$L7_BAN_LOG"
    log_info "IP $ip добавлен в blacklist ($reason)"
}

# Удалить IP из blacklist
remove_from_blacklist() {
    local ip="$1"
    
    ipset del "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    sed -i "/^$ip$/d" "$L7_BLACKLIST"
    
    log_info "IP $ip удалён из blacklist"
}

# Добавить IP в whitelist
add_to_whitelist() {
    local ip="$1"
    
    ipset add "$IPSET_WHITELIST" "$ip" 2>/dev/null
    if ! grep -q "^$ip$" "$L7_WHITELIST" 2>/dev/null; then
        echo "$ip" >> "$L7_WHITELIST"
    fi
    
    log_info "IP $ip добавлен в whitelist"
}

# Автобан IP
autoban_ip() {
    local ip="$1"
    local reason="$2"
    local timeout="${3:-3600}"
    
    # Не баним whitelist
    if ipset test "$IPSET_WHITELIST" "$ip" 2>/dev/null; then
        return
    fi
    
    ipset add "$IPSET_AUTOBAN" "$ip" timeout "$timeout" 2>/dev/null
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') | AUTOBAN | $ip | $reason | ${timeout}s" >> "$L7_BAN_LOG"
    
    # Telegram уведомление
    if type send_telegram &>/dev/null; then
        local server_name=$(get_server_name 2>/dev/null || hostname)
        send_telegram "🛡️ L7 Shield: Auto-ban

Сервер: $server_name
IP: $ip
Причина: $reason
Время: ${timeout}s"
    fi
}

# ============================================
# BLACKLIST MANAGEMENT (GitHub-powered)
# ============================================

# Добавить IP в blacklist и отправить в GitHub
add_ip_to_global_blacklist() {
    local ip="$1"
    local reason="${2:-manual}"
    local backend=$(detect_firewall)
    
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Неверный IP: $ip"
        return 1
    fi
    
    # Проверяем whitelist
    if grep -q "^$ip$" "$L7_WHITELIST" 2>/dev/null; then
        log_warn "IP $ip в whitelist - не блокируем"
        return 0
    fi
    
    # Добавляем в локальный файл
    if ! grep -q "^$ip$" "$L7_BLACKLIST" 2>/dev/null; then
        echo "$ip" >> "$L7_BLACKLIST"
    fi
    
    # Добавляем в ipset/nftables
    if [[ "$backend" == "nftables" ]]; then
        nft_add_to_set "blacklist" "$ip" 2>/dev/null
    else
        ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    fi
    
    # Добавляем в очередь на синхронизацию
    queue_ip_for_sync "$ip"
    
    # Логируем
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] BLACKLIST ADD: $ip | Reason: $reason" >> "$L7_BAN_LOG"
    log_info "IP $ip добавлен в blacklist ($reason)"
}

# Удалить IP из blacklist
remove_ip_from_blacklist() {
    local ip="$1"
    local backend=$(detect_firewall)
    
    # Удаляем из файла
    sed -i "/^$ip$/d" "$L7_BLACKLIST" 2>/dev/null
    sed -i "/^$ip$/d" "$L7_SYNCED_IPS" 2>/dev/null
    sed -i "/^$ip$/d" "$L7_SYNC_QUEUE" 2>/dev/null
    
    # Удаляем из ipset/nftables
    if [[ "$backend" == "nftables" ]]; then
        nft_del_from_set "blacklist" "$ip" 2>/dev/null
    else
        ipset del "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    fi
    
    log_info "IP $ip удалён из blacklist"
    
    # Примечание: IP остаётся в GitHub (удаление из репозитория не реализовано)
    log_warn "IP останется в общей базе GitHub"
}

# Очистить локальный blacklist (GitHub не трогаем)
clear_local_blacklist() {
    local backend=$(detect_firewall)
    
    if [[ "$backend" == "nftables" ]]; then
        nft flush set inet "$NFT_TABLE" blacklist 2>/dev/null
    else
        ipset flush "$IPSET_BLACKLIST" 2>/dev/null
    fi
    
    echo "# IP blacklist (synced with GitHub)" > "$L7_BLACKLIST"
    > "$L7_SYNC_QUEUE"
    
    log_info "Локальный blacklist очищен"
}

# ============================================
# GEOIP БЛОКИРОВКА
# ============================================

# Установить geoip данные
install_geoip() {
    log_step "Установка GeoIP..."
    
    # Устанавливаем пакеты
    apt-get update -qq
    apt-get install -y geoip-bin geoip-database xtables-addons-common libtext-csv-xs-perl >/dev/null 2>&1
    
    # Обновляем базы
    if command -v geoipupdate &>/dev/null; then
        geoipupdate 2>/dev/null
    fi
    
    # Скачиваем xt_geoip данные
    mkdir -p /usr/share/xt_geoip
    
    # Используем dbip-country-lite (бесплатная)
    if command -v /usr/lib/xtables-addons/xt_geoip_dl &>/dev/null; then
        cd /usr/share/xt_geoip
        /usr/lib/xtables-addons/xt_geoip_dl 2>/dev/null
        /usr/lib/xtables-addons/xt_geoip_build -D /usr/share/xt_geoip *.csv 2>/dev/null
    fi
    
    # Загружаем модуль
    modprobe xt_geoip 2>/dev/null
    
    log_info "GeoIP установлен"
}

# Применить GeoIP правила
apply_geoip_rules() {
    load_l7_config
    
    if [[ "$GEOIP_ENABLED" != "true" ]]; then
        return
    fi
    
    # Проверяем модуль
    if ! lsmod | grep -q xt_geoip; then
        modprobe xt_geoip 2>/dev/null || {
            log_warn "Модуль xt_geoip не загружен"
            return 1
        }
    fi
    
    # Читаем разрешённые страны
    local countries=""
    while IFS= read -r country; do
        [[ "$country" =~ ^# ]] && continue
        [[ -z "$country" ]] && continue
        countries="$countries,$country"
    done < "$L7_GEOIP_ALLOW"
    
    countries="${countries:1}"  # Убираем первую запятую
    
    if [[ -z "$countries" ]]; then
        log_warn "Нет стран в списке GeoIP"
        return
    fi
    
    log_step "Применение GeoIP ($GEOIP_MODE): $countries"
    
    # Удаляем старые правила
    iptables -D INPUT -m geoip ! --src-cc "$countries" -j DROP 2>/dev/null
    iptables -D INPUT -m geoip --src-cc "$countries" -j DROP 2>/dev/null
    
    if [[ "$GEOIP_MODE" == "allow" ]]; then
        # Только указанные страны разрешены
        iptables -I INPUT -m geoip ! --src-cc "$countries" -j DROP
    else
        # Указанные страны заблокированы
        iptables -I INPUT -m geoip --src-cc "$countries" -j DROP
    fi
    
    log_info "GeoIP правила применены"
}

# ============================================
# IPTABLES ПРАВИЛА
# ============================================

# Очистить L7 правила
clear_l7_rules() {
    log_step "Очистка L7 правил..."
    
    # Удаляем цепочку L7SHIELD если есть
    iptables -D INPUT -j L7SHIELD 2>/dev/null
    iptables -F L7SHIELD 2>/dev/null
    iptables -X L7SHIELD 2>/dev/null
    
    # Удаляем GeoIP правила
    iptables -D INPUT -m geoip ! --src-cc RU,UA,BY,KZ -j DROP 2>/dev/null
    
    # Удаляем connlimit правила
    iptables -D INPUT -p tcp --syn -m connlimit --connlimit-above 500 -j DROP 2>/dev/null
    
    log_info "L7 правила очищены"
}

# Применить L7 правила iptables
apply_l7_iptables() {
    load_l7_config
    
    local vpn_ports=$(get_vpn_ports)
    local ssh_port=$(get_config "SSH_PORT" "22")
    
    log_step "Применение L7 iptables правил..."
    
    # Создаём цепочку
    iptables -N L7SHIELD 2>/dev/null
    iptables -F L7SHIELD
    
    # =====================================
    # WHITELIST (всегда пропускаем)
    # =====================================
    iptables -A L7SHIELD -m set --match-set "$IPSET_WHITELIST" src -j ACCEPT
    
    # =====================================
    # BLACKLIST & AUTOBAN (всегда блокируем)
    # =====================================
    iptables -A L7SHIELD -m set --match-set "$IPSET_BLACKLIST" src -j DROP
    iptables -A L7SHIELD -m set --match-set "$IPSET_AUTOBAN" src -j DROP
    
    # =====================================
    # ESTABLISHED соединения пропускаем
    # =====================================
    iptables -A L7SHIELD -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # =====================================
    # SYN FLOOD PROTECTION
    # =====================================
    iptables -A L7SHIELD -p tcp --syn -m limit --limit "$SYN_RATE" --limit-burst "$SYN_BURST" -j ACCEPT
    iptables -A L7SHIELD -p tcp --syn -j DROP
    
    # =====================================
    # VPN ПОРТЫ (мягкие лимиты)
    # =====================================
    for port in $vpn_ports; do
        # Высокий лимит соединений для VPN
        iptables -A L7SHIELD -p tcp --dport "$port" -m connlimit --connlimit-above "$CONN_LIMIT_VPN" --connlimit-mask 32 -j DROP
        
        # Rate limit для новых соединений VPN
        iptables -A L7SHIELD -p tcp --dport "$port" --syn -m hashlimit \
            --hashlimit-name "vpn_$port" \
            --hashlimit-above "$RATE_LIMIT_VPN" \
            --hashlimit-mode srcip \
            --hashlimit-burst 200 \
            -j DROP
        
        # Разрешаем VPN
        iptables -A L7SHIELD -p tcp --dport "$port" -j ACCEPT
    done
    
    # =====================================
    # SSH (строгие лимиты)
    # =====================================
    iptables -A L7SHIELD -p tcp --dport "$ssh_port" -m connlimit --connlimit-above "$CONN_LIMIT_SSH" --connlimit-mask 32 -j DROP
    iptables -A L7SHIELD -p tcp --dport "$ssh_port" --syn -m hashlimit \
        --hashlimit-name "ssh" \
        --hashlimit-above "5/min" \
        --hashlimit-mode srcip \
        --hashlimit-burst 10 \
        -j DROP
    iptables -A L7SHIELD -p tcp --dport "$ssh_port" -j ACCEPT
    
    # =====================================
    # HTTP/HTTPS (не VPN порты)
    # =====================================
    iptables -A L7SHIELD -p tcp --dport 80 -m connlimit --connlimit-above "$CONN_LIMIT_HTTP" --connlimit-mask 32 -j DROP
    iptables -A L7SHIELD -p tcp --dport 80 --syn -m hashlimit \
        --hashlimit-name "http80" \
        --hashlimit-above "$RATE_LIMIT_HTTP" \
        --hashlimit-mode srcip \
        --hashlimit-burst 50 \
        -j DROP
    
    # 443 может быть VPN - проверяем
    if ! echo "$vpn_ports" | grep -q "443"; then
        iptables -A L7SHIELD -p tcp --dport 443 -m connlimit --connlimit-above "$CONN_LIMIT_HTTP" --connlimit-mask 32 -j DROP
    fi
    
    # =====================================
    # ГЛОБАЛЬНЫЙ ЛИМИТ (всё остальное)
    # =====================================
    iptables -A L7SHIELD -p tcp -m connlimit --connlimit-above "$CONN_LIMIT_GLOBAL" --connlimit-mask 32 -j DROP
    iptables -A L7SHIELD -p tcp --syn -m hashlimit \
        --hashlimit-name "global" \
        --hashlimit-above "$RATE_LIMIT_GLOBAL" \
        --hashlimit-mode srcip \
        --hashlimit-burst 100 \
        -j DROP
    
    # =====================================
    # INVALID пакеты
    # =====================================
    iptables -A L7SHIELD -m state --state INVALID -j DROP
    
    # =====================================
    # NULL пакеты
    # =====================================
    iptables -A L7SHIELD -p tcp --tcp-flags ALL NONE -j DROP
    
    # =====================================
    # XMAS пакеты
    # =====================================
    iptables -A L7SHIELD -p tcp --tcp-flags ALL ALL -j DROP
    
    # По умолчанию - разрешаем
    iptables -A L7SHIELD -j RETURN
    
    # Подключаем цепочку
    iptables -D INPUT -j L7SHIELD 2>/dev/null
    iptables -I INPUT 1 -j L7SHIELD
    
    log_info "L7 iptables правила применены"
}

# ============================================
# NFTABLES ПОДДЕРЖКА
# ============================================

NFT_TABLE="l7shield"
NFT_CHAIN="input"
NFT_CONF="/etc/nftables.d/l7shield.nft"

# Определить какой firewall используется
detect_firewall() {
    # Проверяем что доступно и активно
    if command -v nft &>/dev/null && nft list tables &>/dev/null 2>&1; then
        # nftables установлен и работает
        if [[ -f "$L7_CONFIG_DIR/firewall_backend" ]]; then
            cat "$L7_CONFIG_DIR/firewall_backend"
        else
            # Автоопределение
            if iptables -V 2>/dev/null | grep -q "nf_tables"; then
                echo "nftables"
            elif systemctl is-active --quiet nftables 2>/dev/null; then
                echo "nftables"
            else
                echo "iptables"
            fi
        fi
    else
        echo "iptables"
    fi
}

# Установить backend firewall
set_firewall_backend() {
    local backend="$1"
    
    if [[ "$backend" != "iptables" && "$backend" != "nftables" ]]; then
        log_error "Неверный backend: $backend (iptables или nftables)"
        return 1
    fi
    
    mkdir -p "$L7_CONFIG_DIR"
    echo "$backend" > "$L7_CONFIG_DIR/firewall_backend"
    save_l7_param "FIREWALL_BACKEND" "$backend"
    log_info "Firewall backend установлен: $backend"
}

# Проверить доступность nftables
check_nftables_available() {
    if ! command -v nft &>/dev/null; then
        return 1
    fi
    
    if ! nft list tables &>/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# Установить nftables если нужно
install_nftables() {
    log_step "Установка nftables..."
    
    apt-get update -qq
    apt-get install -y nftables >/dev/null 2>&1
    
    # Включаем и запускаем сервис
    systemctl enable nftables 2>/dev/null
    systemctl start nftables 2>/dev/null
    
    # Создаём директорию для конфигов
    mkdir -p /etc/nftables.d
    
    # Добавляем include в основной конфиг если нужно
    if ! grep -q "include.*nftables.d" /etc/nftables.conf 2>/dev/null; then
        echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
    fi
    
    log_info "nftables установлен"
}

# Очистить nftables правила L7 Shield
clear_nft_rules() {
    log_step "Очистка nftables правил..."
    
    # Удаляем таблицу L7 Shield если существует
    nft delete table inet "$NFT_TABLE" 2>/dev/null
    
    # Удаляем конфиг файл
    rm -f "$NFT_CONF"
    
    log_info "nftables правила очищены"
}

# Создать nftables конфиг
generate_nft_config() {
    load_l7_config
    
    local vpn_ports=$(get_vpn_ports | tr ' ' ',')
    local ssh_port=$(get_config "SSH_PORT" "22")
    
    # Читаем whitelist
    local whitelist_ips=""
    if [[ -f "$L7_WHITELIST" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" || "$ip" =~ ^# ]] && continue
            whitelist_ips="$whitelist_ips $ip,"
        done < "$L7_WHITELIST"
        whitelist_ips="${whitelist_ips%,}"  # Убираем последнюю запятую
    fi
    
    # Читаем blacklist
    local blacklist_ips=""
    if [[ -f "$L7_BLACKLIST" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" || "$ip" =~ ^# ]] && continue
            blacklist_ips="$blacklist_ips $ip,"
        done < "$L7_BLACKLIST"
        blacklist_ips="${blacklist_ips%,}"
    fi
    
    mkdir -p /etc/nftables.d
    
    cat > "$NFT_CONF" << NFTABLES
#!/usr/sbin/nft -f
#
# L7 Shield - nftables Configuration
# Server Security Shield v3.4
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
#

# Удаляем старую таблицу если есть
table inet $NFT_TABLE
delete table inet $NFT_TABLE

# Создаём таблицу L7 Shield
table inet $NFT_TABLE {
    
    # ==========================================
    # SETS (аналог ipset)
    # ==========================================
    
    # Whitelist - никогда не блокируем
    set whitelist {
        type ipv4_addr
        flags interval
        elements = { 127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16${whitelist_ips:+, $whitelist_ips} }
    }
    
    # Blacklist - всегда блокируем
    set blacklist {
        type ipv4_addr
        flags interval
        ${blacklist_ips:+elements = { $blacklist_ips \}}
    }
    
    # Autoban - временные баны (упрощённый для совместимости)
    set autoban {
        type ipv4_addr
    }
    
    # ==========================================
    # CHAINS
    # ==========================================
    
    chain input {
        type filter hook input priority -100; policy accept;
        
        # ===== WHITELIST (пропускаем) =====
        ip saddr @whitelist accept
        
        # ===== BLACKLIST & AUTOBAN (блокируем) =====
        ip saddr @blacklist drop
        ip saddr @autoban drop
        
        # ===== ESTABLISHED соединения =====
        ct state established,related accept
        
        # ===== INVALID пакеты =====
        ct state invalid drop
        
        # ===== SYN FLOOD PROTECTION =====
        tcp flags syn limit rate ${SYN_RATE:-100/second} burst ${SYN_BURST:-200} packets accept
        tcp flags syn drop
        
        # ===== MALFORMED PACKETS =====
        # NULL пакеты
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 drop
        # XMAS пакеты
        tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn|rst|psh|ack|urg drop
        # SYN-FIN
        tcp flags & (syn|fin) == syn|fin drop
        # SYN-RST
        tcp flags & (syn|rst) == syn|rst drop
        
        # ===== VPN ПОРТЫ (мягкие лимиты) =====
        tcp dport { $vpn_ports } ct count over ${CONN_LIMIT_VPN:-500} drop
        tcp dport { $vpn_ports } accept
        
        # ===== SSH (строгие лимиты) =====
        tcp dport $ssh_port ct count over ${CONN_LIMIT_SSH:-10} drop
        tcp dport $ssh_port accept
        
        # ===== HTTP/HTTPS =====
        tcp dport { 80, 443 } ct count over ${CONN_LIMIT_HTTP:-100} drop
        
        # ===== ГЛОБАЛЬНЫЙ ЛИМИТ =====
        tcp ct count over ${CONN_LIMIT_GLOBAL:-200} drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTABLES

    log_info "nftables конфиг создан: $NFT_CONF"
}

# Применить nftables правила
apply_nft_rules() {
    load_l7_config
    
    log_step "Применение nftables правил..."
    
    # Генерируем конфиг
    generate_nft_config
    
    # Применяем (скрываем вывод, показываем только ошибки)
    local output
    output=$(nft -f "$NFT_CONF" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        log_info "nftables правила применены"
        return 0
    else
        log_error "Ошибка применения nftables:"
        echo "$output" | head -5
        return 1
    fi
}

# Добавить IP в nftables set
nft_add_to_set() {
    local set_name="$1"
    local ip="$2"
    local timeout="${3:-}"
    
    if [[ -n "$timeout" ]]; then
        nft add element inet "$NFT_TABLE" "$set_name" "{ $ip timeout ${timeout}s }" 2>/dev/null
    else
        nft add element inet "$NFT_TABLE" "$set_name" "{ $ip }" 2>/dev/null
    fi
}

# Удалить IP из nftables set
nft_del_from_set() {
    local set_name="$1"
    local ip="$2"
    
    nft delete element inet "$NFT_TABLE" "$set_name" "{ $ip }" 2>/dev/null
}

# Показать содержимое nftables set
nft_list_set() {
    local set_name="$1"
    
    nft list set inet "$NFT_TABLE" "$set_name" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | sort -u
}

# Добавить в blacklist (универсально)
add_to_blacklist_universal() {
    local ip="$1"
    local reason="${2:-manual}"
    local backend=$(detect_firewall)
    
    if [[ "$backend" == "nftables" ]]; then
        nft_add_to_set "blacklist" "$ip"
    else
        ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    fi
    
    # Также добавляем в файл
    echo "$ip" >> "$L7_BLACKLIST"
    
    log_info "IP $ip добавлен в blacklist ($backend)"
}

# Добавить в whitelist (универсально)
add_to_whitelist_universal() {
    local ip="$1"
    local backend=$(detect_firewall)
    
    if [[ "$backend" == "nftables" ]]; then
        nft_add_to_set "whitelist" "$ip"
    else
        ipset add "$IPSET_WHITELIST" "$ip" 2>/dev/null
    fi
    
    echo "$ip" >> "$L7_WHITELIST"
    log_info "IP $ip добавлен в whitelist ($backend)"
}

# Автобан (универсально)
autoban_ip_universal() {
    local ip="$1"
    local timeout="${2:-$AUTOBAN_TIME}"
    local reason="${3:-auto}"
    local backend=$(detect_firewall)
    
    # Проверяем whitelist
    if grep -q "^$ip$" "$L7_WHITELIST" 2>/dev/null; then
        return 0
    fi
    
    if [[ "$backend" == "nftables" ]]; then
        nft_add_to_set "autoban" "$ip" "$timeout"
    else
        ipset add "$IPSET_AUTOBAN" "$ip" timeout "$timeout" 2>/dev/null
    fi
    
    # Добавляем в очередь на синхронизацию с GitHub
    queue_ip_for_sync "$ip"
    
    # Логируем
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] BAN: $ip | Reason: $reason | Time: ${timeout}s | Backend: $backend" >> "$L7_BAN_LOG"
}

# Статус nftables
show_nft_status() {
    echo ""
    echo -e "${WHITE}nftables Status:${NC}"
    echo ""
    
    if ! check_nftables_available; then
        echo -e "  ${RED}○${NC} nftables не установлен или не активен"
        return 1
    fi
    
    echo -e "  ${GREEN}●${NC} nftables активен"
    echo ""
    
    # Проверяем таблицу L7 Shield
    if nft list table inet "$NFT_TABLE" &>/dev/null; then
        echo -e "  ${GREEN}●${NC} Таблица $NFT_TABLE загружена"
        
        # Считаем элементы в sets
        local whitelist_count=$(nft_list_set "whitelist" | wc -l)
        local blacklist_count=$(nft_list_set "blacklist" | wc -l)
        local autoban_count=$(nft_list_set "autoban" | wc -l)
        
        echo ""
        echo -e "  ${WHITE}Sets:${NC}"
        echo -e "    Whitelist: ${GREEN}$whitelist_count${NC} IP"
        echo -e "    Blacklist: ${RED}$blacklist_count${NC} IP"
        echo -e "    Autoban: ${YELLOW}$autoban_count${NC} IP"
        
        # Статистика правил
        echo ""
        echo -e "  ${WHITE}Chains:${NC}"
        nft list chain inet "$NFT_TABLE" input 2>/dev/null | grep -c "accept\|drop" | while read count; do
            echo -e "    Input rules: $count"
        done
    else
        echo -e "  ${YELLOW}○${NC} Таблица $NFT_TABLE не загружена"
    fi
}

# Миграция с iptables на nftables
migrate_to_nftables() {
    log_step "Миграция с iptables на nftables..."
    
    # Проверяем что nftables доступен
    if ! check_nftables_available; then
        log_step "Установка nftables..."
        install_nftables
    fi
    
    # Собираем текущие данные из ipset
    local whitelist_ips=""
    local blacklist_ips=""
    
    if command -v ipset &>/dev/null; then
        whitelist_ips=$(ipset list "$IPSET_WHITELIST" 2>/dev/null | grep "^[0-9]" | tr '\n' ' ')
        blacklist_ips=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep "^[0-9]" | tr '\n' ' ')
    fi
    
    # Очищаем iptables
    clear_l7_rules
    
    # Применяем nftables
    apply_nft_rules
    
    # Добавляем мигрированные IP в nftables sets
    for ip in $whitelist_ips; do
        nft_add_to_set "whitelist" "$ip" 2>/dev/null
    done
    
    for ip in $blacklist_ips; do
        nft_add_to_set "blacklist" "$ip" 2>/dev/null
    done
    
    # Устанавливаем backend
    set_firewall_backend "nftables"
    
    log_info "Миграция завершена! Теперь используется nftables"
    
    echo ""
    echo -e "${WHITE}Мигрировано:${NC}"
    echo -e "  Whitelist: $(echo $whitelist_ips | wc -w) IP"
    echo -e "  Blacklist: $(echo $blacklist_ips | wc -w) IP"
}

# Миграция с nftables на iptables
migrate_to_iptables() {
    log_step "Миграция с nftables на iptables..."
    
    # Собираем данные из nftables
    local whitelist_ips=$(nft_list_set "whitelist")
    local blacklist_ips=$(nft_list_set "blacklist")
    
    # Очищаем nftables
    clear_nft_rules
    
    # Инициализируем ipset
    init_ipsets
    
    # Применяем iptables
    apply_l7_iptables
    
    # Добавляем мигрированные IP
    for ip in $whitelist_ips; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ipset add "$IPSET_WHITELIST" "$ip" 2>/dev/null
    done
    
    for ip in $blacklist_ips; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
    done
    
    # Устанавливаем backend
    set_firewall_backend "iptables"
    
    log_info "Миграция завершена! Теперь используется iptables"
}

# Меню выбора firewall backend
firewall_backend_menu() {
    while true; do
        print_header_mini "Firewall Backend"
        
        local current=$(detect_firewall)
        
        echo ""
        echo -e "    ${WHITE}Текущий backend:${NC} ${CYAN}$current${NC}"
        echo ""
        
        # Статус iptables
        if command -v iptables &>/dev/null; then
            local ipt_version=$(iptables -V 2>/dev/null | head -1)
            show_status_line "iptables" "on" "$ipt_version"
        else
            show_status_line "iptables" "off" "Не установлен"
        fi
        
        # Статус nftables
        if check_nftables_available; then
            local nft_version=$(nft -v 2>/dev/null | head -1)
            show_status_line "nftables" "on" "$nft_version"
        else
            show_status_line "nftables" "off" "Не установлен"
        fi
        
        echo ""
        print_divider
        echo ""
        
        echo -e "    ${WHITE}Выбор backend:${NC}"
        if [[ "$current" == "iptables" ]]; then
            menu_item "1" "Переключиться на nftables" "${GREEN}"
        else
            menu_item "1" "Переключиться на iptables" "${GREEN}"
        fi
        
        menu_divider
        menu_item "2" "Статус nftables"
        menu_item "3" "Показать правила"
        menu_item "4" "Перезагрузить правила"
        menu_divider
        menu_item "0" "Назад"
        
        echo ""
        print_divider
        echo -e "    ${DIM}iptables — классический, совместимость${NC}"
        echo -e "    ${DIM}nftables — современный, быстрее на больших списках${NC}"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                if [[ "$current" == "iptables" ]]; then
                    if confirm_action "Переключиться на nftables?" "y"; then
                        migrate_to_nftables
                    fi
                else
                    if confirm_action "Переключиться на iptables?" "y"; then
                        migrate_to_iptables
                    fi
                fi
                press_any_key
                ;;
            2)
                show_nft_status
                press_any_key
                ;;
            3)
                echo ""
                if [[ "$current" == "nftables" ]]; then
                    nft list table inet "$NFT_TABLE" 2>/dev/null | head -80
                else
                    iptables -L L7SHIELD -n -v 2>/dev/null | head -40
                fi
                press_any_key
                ;;
            4)
                if [[ "$current" == "nftables" ]]; then
                    apply_nft_rules
                else
                    apply_l7_iptables
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# ============================================
# GITHUB SYNC - СИНХРОНИЗАЦИЯ BLACKLIST
# ============================================

# Инициализация файлов синхронизации
init_github_sync() {
    mkdir -p "$L7_CONFIG_DIR"
    touch "$L7_SYNC_QUEUE" 2>/dev/null
    touch "$L7_SYNCED_IPS" 2>/dev/null
    touch "$L7_LAST_SYNC" 2>/dev/null
}

# Проверить доступность GitHub API
check_github_connection() {
    # Загружаем PAT из файла
    load_github_pat
    
    # Убедимся что PAT загружен
    if [[ -z "$GITHUB_PAT" ]]; then
        log_error "GitHub PAT не настроен"
        echo -e "    ${DIM}Создайте файл: $GITHUB_PAT_FILE${NC}"
        echo -e "    ${DIM}И добавьте в него ваш GitHub PAT токен${NC}"
        return 1
    fi
    
    local response=$(curl -sS --connect-timeout 5 --max-time 10 \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/user" 2>&1)
    
    if echo "$response" | grep -q '"login"'; then
        return 0
    elif echo "$response" | grep -q "Bad credentials"; then
        log_error "Неверный GitHub PAT токен"
        return 1
    elif echo "$response" | grep -q "rate limit"; then
        log_warn "GitHub API rate limit exceeded"
        return 2
    else
        log_error "Не удалось подключиться к GitHub"
        return 3
    fi
}

# Скачать IP из GitHub (с обработкой ошибок)
github_download_ips() {
    load_github_pat
    
    local temp_file="/tmp/github_ips_$$.txt"
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Используем API URL (работает для приватных репо)
        local http_code=$(curl -sS -w "%{http_code}" \
            --connect-timeout 10 --max-time 60 \
            -H "Authorization: token $GITHUB_PAT" \
            -H "Accept: application/vnd.github.v3.raw" \
            "$GITHUB_RAW_URL" -o "$temp_file" 2>/dev/null)
        
        case "$http_code" in
            200)
                # Успех - быстрый парсинг с cut и grep
                # Поддержка форматов: IP, IP:port, IP/CIDR
                cut -d':' -f1 "$temp_file" 2>/dev/null | \
                    cut -d'/' -f1 | \
                    grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
                    sort -u
                rm -f "$temp_file"
                return 0
                ;;
            404)
                # Файл не существует - это OK для первого запуска
                rm -f "$temp_file"
                return 0
                ;;
            401|403)
                log_error "Ошибка авторизации GitHub (код $http_code)"
                rm -f "$temp_file"
                return 1
                ;;
            *)
                ((retry_count++))
                if [[ $retry_count -lt $max_retries ]]; then
                    sleep 2
                fi
                ;;
        esac
    done
    
    rm -f "$temp_file"
    log_error "Не удалось скачать IP из GitHub после $max_retries попыток"
    return 1
}

# Получить SHA файла для обновления
github_get_sha() {
    local response=$(curl -sS --connect-timeout 10 --max-time 15 \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API_URL" 2>/dev/null)
    
    if echo "$response" | grep -q '"sha"'; then
        echo "$response" | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4
    fi
}

# Отправить IP в GitHub (с обработкой ошибок)
github_upload_ips() {
    local new_ips="$1"
    
    if [[ -z "$new_ips" ]]; then
        return 0
    fi
    
    log_step "Отправка IP в GitHub..."
    
    # Получаем текущие IP из GitHub
    local current_ips=$(github_download_ips 2>/dev/null | sort -u)
    
    # Объединяем с новыми (без дубликатов)
    local all_ips=$(echo -e "${current_ips}\n${new_ips}" | grep -v "^$" | sort -u)
    
    # Подсчитываем сколько реально новых
    local total_count=$(echo "$all_ips" | grep -c "^[0-9]" 2>/dev/null || echo 0)
    local new_count=$(echo "$new_ips" | grep -c "^[0-9]" 2>/dev/null || echo 0)
    
    # Получаем SHA для обновления
    local sha=$(github_get_sha)
    
    # Кодируем в base64
    local content_base64=$(echo "$all_ips" | base64 -w 0)
    
    # Формируем JSON (используем jq если есть, иначе вручную)
    local hostname_short=$(hostname -s 2>/dev/null || hostname)
    local json_data
    
    if [[ -n "$sha" ]]; then
        json_data="{\"message\":\"Auto-sync: +${new_count} IPs from ${hostname_short}\",\"content\":\"${content_base64}\",\"sha\":\"${sha}\"}"
    else
        json_data="{\"message\":\"Initial sync from ${hostname_short}\",\"content\":\"${content_base64}\"}"
    fi
    
    # Отправляем
    local response=$(curl -sS --connect-timeout 15 --max-time 30 -X PUT \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$GITHUB_API_URL" 2>&1)
    
    if echo "$response" | grep -q '"sha"'; then
        log_info "Отправлено $new_count IP в GitHub (всего: $total_count)"
        return 0
    elif echo "$response" | grep -q "409"; then
        log_warn "Конфликт версий - повторите синхронизацию"
        return 2
    elif echo "$response" | grep -q "Bad credentials\|401"; then
        log_error "Ошибка авторизации GitHub"
        return 1
    else
        log_error "Ошибка отправки в GitHub"
        echo "$response" | grep -o '"message":"[^"]*"' | head -1 >&2
        return 1
    fi
}

# Добавить IP в очередь на синхронизацию
queue_ip_for_sync() {
    local ip="$1"
    
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    
    # Проверяем не в whitelist ли
    if grep -q "^$ip$" "$L7_WHITELIST" 2>/dev/null; then
        return 0
    fi
    
    # Проверяем не синхронизирован ли уже
    if grep -q "^$ip$" "$L7_SYNCED_IPS" 2>/dev/null; then
        return 0
    fi
    
    # Добавляем в очередь
    if ! grep -q "^$ip$" "$L7_SYNC_QUEUE" 2>/dev/null; then
        echo "$ip" >> "$L7_SYNC_QUEUE"
    fi
}

# Полная синхронизация с GitHub
github_full_sync() {
    init_github_sync
    
    log_step "Синхронизация с GitHub..."
    
    # Проверяем подключение к GitHub
    if ! check_github_connection; then
        log_error "Синхронизация невозможна - проверьте подключение и PAT"
        return 1
    fi
    
    local backend=$(detect_firewall)
    local added=0
    local uploaded=0
    
    # 1. Скачиваем IP из GitHub
    log_step "Загрузка IP из общей базы..."
    local remote_ips=$(github_download_ips 2>/dev/null)
    local remote_count=$(echo "$remote_ips" | grep -c "^[0-9]" || echo 0)
    
    if [[ $remote_count -gt 0 ]]; then
        log_info "Получено $remote_count IP из GitHub"
        log_step "Применение IP (это может занять несколько минут)..."
        
        # Сохраняем во временный файл для быстрой обработки
        local temp_remote="/tmp/github_remote_$$.txt"
        echo "$remote_ips" > "$temp_remote"
        
        # Фильтруем whitelist
        local filtered_ips
        if [[ -f "$L7_WHITELIST" ]]; then
            filtered_ips=$(grep -vFxf "$L7_WHITELIST" "$temp_remote" 2>/dev/null || cat "$temp_remote")
        else
            filtered_ips=$(cat "$temp_remote")
        fi
        
        # Находим новые IP (которых нет в blacklist)
        local new_ips
        if [[ -f "$L7_BLACKLIST" ]]; then
            new_ips=$(echo "$filtered_ips" | grep -vFxf "$L7_BLACKLIST" 2>/dev/null || echo "$filtered_ips")
        else
            new_ips="$filtered_ips"
        fi
        
        local new_count=$(echo "$new_ips" | grep -c "^[0-9]" || echo 0)
        
        if [[ $new_count -gt 0 ]]; then
            log_step "Добавление $new_count новых IP..."
            
            # Добавляем в blacklist файл
            echo "$new_ips" >> "$L7_BLACKLIST"
            sort -u "$L7_BLACKLIST" -o "$L7_BLACKLIST" 2>/dev/null
            
            # Добавляем в firewall (пакетно)
            local progress=0
            echo "$new_ips" | while IFS= read -r ip; do
                [[ -z "$ip" ]] && continue
                
                if [[ "$backend" == "nftables" ]]; then
                    nft add element inet l7shield blacklist { "$ip" } 2>/dev/null
                else
                    ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
                fi
                
                ((progress++))
                # Показываем прогресс каждые 5000 IP
                if (( progress % 5000 == 0 )); then
                    echo -ne "    → Обработано: $progress / $new_count IP\r"
                fi
            done
            echo ""
            
            added=$new_count
        fi
        
        # Обновляем synced_ips
        echo "$filtered_ips" >> "$L7_SYNCED_IPS"
        sort -u "$L7_SYNCED_IPS" -o "$L7_SYNCED_IPS" 2>/dev/null
        
        rm -f "$temp_remote"
    fi
    
    # 2. Отправляем наши новые IP в GitHub
    if [[ -s "$L7_SYNC_QUEUE" ]]; then
        local queue_ips=$(cat "$L7_SYNC_QUEUE" | sort -u)
        local queue_count=$(echo "$queue_ips" | grep -c "^[0-9]" || echo 0)
        
        if [[ $queue_count -gt 0 ]]; then
            log_step "Отправка $queue_count IP в GitHub..."
            if github_upload_ips "$queue_ips"; then
                # Перемещаем из очереди в synced
                cat "$L7_SYNC_QUEUE" >> "$L7_SYNCED_IPS"
                sort -u "$L7_SYNCED_IPS" -o "$L7_SYNCED_IPS"
                > "$L7_SYNC_QUEUE"
                uploaded=$queue_count
            fi
        fi
    fi
    
    # 3. Сохраняем время последней синхронизации
    date '+%Y-%m-%d %H:%M:%S' > "$L7_LAST_SYNC"
    
    log_info "Sync завершён: +$added локально, +$uploaded в GitHub"
}

# Скрипт для cron синхронизации
create_github_sync_cron() {
    local sync_script="/opt/server-shield/scripts/l7-github-sync.sh"
    
    mkdir -p "$(dirname "$sync_script")"
    
    cat > "$sync_script" << 'SCRIPT'
#!/bin/bash
#
# L7 Shield - GitHub IP Sync
# Автоматическая синхронизация blacklist
#

source /opt/server-shield/modules/utils.sh 2>/dev/null
source /opt/server-shield/modules/l7shield.sh 2>/dev/null

# Выполняем синхронизацию
github_full_sync >> /opt/server-shield/logs/github_sync.log 2>&1
SCRIPT
    
    chmod +x "$sync_script"
    
    # Добавляем в cron (каждые 12 часов)
    local cron_line="0 */12 * * * root $sync_script"
    if ! grep -q "l7-github-sync" "$L7_CRON" 2>/dev/null; then
        echo "$cron_line" >> "$L7_CRON"
    fi
    
    log_info "GitHub sync cron настроен (каждые 12 ч)"
}

# Показать статус синхронизации
show_github_sync_status() {
    echo ""
    echo -e "    ${WHITE}GitHub Sync Status:${NC}"
    echo ""
    
    # Последняя синхронизация
    if [[ -f "$L7_LAST_SYNC" ]]; then
        local last=$(cat "$L7_LAST_SYNC")
        show_info "Последняя синхронизация" "$last"
    else
        show_status_line "Синхронизация" "off" "Не выполнялась"
    fi
    
    # Очередь на отправку
    local queue_count=0
    [[ -f "$L7_SYNC_QUEUE" ]] && queue_count=$(grep -c "^[0-9]" "$L7_SYNC_QUEUE" 2>/dev/null || echo 0)
    show_info "В очереди на отправку" "$queue_count IP"
    
    # Всего синхронизировано
    local synced_count=0
    [[ -f "$L7_SYNCED_IPS" ]] && synced_count=$(grep -c "^[0-9]" "$L7_SYNCED_IPS" 2>/dev/null || echo 0)
    show_info "Всего синхронизировано" "$synced_count IP"
    
    # Локальный blacklist
    local local_count=0
    [[ -f "$L7_BLACKLIST" ]] && local_count=$(grep -c "^[0-9]" "$L7_BLACKLIST" 2>/dev/null || echo 0)
    show_info "Локальный blacklist" "$local_count IP"
    
    # Статус cron
    if grep -q "l7-github-sync" "$L7_CRON" 2>/dev/null; then
        show_status_line "Auto-sync" "on" "каждые 12 ч"
    else
        show_status_line "Auto-sync" "off"
    fi
}

# Меню GitHub Sync
github_sync_menu() {
    while true; do
        print_header_mini "GitHub IP Sync"
        
        # Загружаем PAT
        load_github_pat
        
        # Статус PAT
        if [[ -n "$GITHUB_PAT" ]]; then
            echo -e "    ${GREEN}●${NC} PAT токен настроен"
        else
            echo -e "    ${RED}●${NC} PAT токен не настроен"
        fi
        
        show_github_sync_status
        
        echo ""
        print_divider
        echo ""
        
        menu_item "1" "Синхронизировать сейчас"
        menu_item "2" "Показать очередь на отправку"
        menu_item "3" "Показать последние синхронизированные"
        menu_divider
        menu_item "4" "Настроить PAT токен"
        
        if grep -q "l7-github-sync" "$L7_CRON" 2>/dev/null; then
            menu_item "5" "Выключить auto-sync"
        else
            menu_item "5" "Включить auto-sync"
        fi
        
        menu_item "6" "Просмотр лога синхронизации"
        menu_divider
        menu_item "0" "Назад"
        
        echo ""
        echo -e "    ${DIM}Репозиторий: github.com/${GITHUB_REPO}${NC}"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                github_full_sync
                press_any_key
                ;;
            2)
                echo ""
                echo -e "    ${WHITE}Очередь на отправку:${NC}"
                if [[ -s "$L7_SYNC_QUEUE" ]]; then
                    head -20 "$L7_SYNC_QUEUE" | while read ip; do
                        echo -e "    ${YELLOW}$ip${NC}"
                    done
                    local total=$(wc -l < "$L7_SYNC_QUEUE")
                    [[ $total -gt 20 ]] && echo -e "    ${DIM}... и ещё $((total-20))${NC}"
                else
                    echo -e "    ${DIM}Пусто${NC}"
                fi
                press_any_key
                ;;
            3)
                echo ""
                echo -e "    ${WHITE}Последние синхронизированные:${NC}"
                if [[ -s "$L7_SYNCED_IPS" ]]; then
                    tail -20 "$L7_SYNCED_IPS" | while read ip; do
                        echo -e "    ${GREEN}$ip${NC}"
                    done
                else
                    echo -e "    ${DIM}Пусто${NC}"
                fi
                press_any_key
                ;;
            4)
                echo ""
                echo -e "    ${WHITE}Настройка GitHub PAT токена${NC}"
                echo ""
                echo -e "    ${DIM}1. Создайте токен: https://github.com/settings/tokens?type=beta${NC}"
                echo -e "    ${DIM}2. Repository access → Only select: wrx861/blockip${NC}"
                echo -e "    ${DIM}3. Permissions → Contents → Read and write${NC}"
                echo ""
                echo -ne "    ${WHITE}Вставьте PAT токен:${NC} "
                read -r new_pat
                if [[ "$new_pat" == github_pat_* ]]; then
                    mkdir -p "$(dirname "$GITHUB_PAT_FILE")"
                    echo "$new_pat" > "$GITHUB_PAT_FILE"
                    chmod 600 "$GITHUB_PAT_FILE"
                    log_info "PAT токен сохранён"
                    
                    # Проверяем
                    load_github_pat
                    if check_github_connection; then
                        log_info "Токен работает!"
                    fi
                else
                    log_error "Неверный формат токена (должен начинаться с github_pat_)"
                fi
                press_any_key
                ;;
            5)
                if grep -q "l7-github-sync" "$L7_CRON" 2>/dev/null; then
                    sed -i '/l7-github-sync/d' "$L7_CRON"
                    log_info "Auto-sync выключен"
                else
                    create_github_sync_cron
                fi
                press_any_key
                ;;
            6)
                echo ""
                if [[ -f "/opt/server-shield/logs/github_sync.log" ]]; then
                    tail -30 "/opt/server-shield/logs/github_sync.log"
                else
                    log_warn "Лог пуст"
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# ============================================
# NGINX КОНФИГУРАЦИЯ
# ============================================

# Путь к кастомным nginx конфигам (для VPN панелей)
L7_NGINX_CUSTOM_PATHS="$L7_CONFIG_DIR/nginx_paths.txt"

# Проверка установлен ли nginx
check_nginx_installed() {
    if command -v nginx &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Получить все пути с nginx конфигами
get_nginx_config_paths() {
    local paths=()
    
    # Стандартные пути
    [[ -d "/etc/nginx/sites-enabled" ]] && paths+=("/etc/nginx/sites-enabled")
    [[ -d "/etc/nginx/conf.d" ]] && paths+=("/etc/nginx/conf.d")
    
    # Кастомные пути из конфига
    if [[ -f "$L7_NGINX_CUSTOM_PATHS" ]]; then
        while IFS= read -r path; do
            [[ "$path" =~ ^# ]] && continue
            [[ -z "$path" ]] && continue
            [[ -d "$path" ]] && paths+=("$path")
        done < "$L7_NGINX_CUSTOM_PATHS"
    fi
    
    # Автопоиск популярных VPN панелей
    local vpn_paths=(
        "/opt/remnawave"
        "/opt/marzban"
        "/opt/x-ui"
        "/opt/3x-ui"
        "/opt/hiddify"
        "/opt/v2ray"
        "/root/remnawave"
        "/root/marzban"
    )
    
    for vpath in "${vpn_paths[@]}"; do
        if [[ -d "$vpath" ]]; then
            # Ищем nginx.conf или *.conf
            for conf in "$vpath"/*.conf "$vpath"/nginx/*.conf "$vpath"/config/*.conf; do
                if [[ -f "$conf" ]] && grep -q "server\s*{" "$conf" 2>/dev/null; then
                    local dir=$(dirname "$conf")
                    if [[ ! " ${paths[*]} " =~ " ${dir} " ]]; then
                        paths+=("$dir")
                    fi
                fi
            done
        fi
    done
    
    printf '%s\n' "${paths[@]}" | sort -u
}

# Добавить кастомный путь для поиска nginx конфигов
add_nginx_custom_path() {
    local path="$1"
    
    if [[ ! -d "$path" ]]; then
        log_error "Директория не существует: $path"
        return 1
    fi
    
    mkdir -p "$(dirname "$L7_NGINX_CUSTOM_PATHS")"
    
    if ! grep -q "^$path$" "$L7_NGINX_CUSTOM_PATHS" 2>/dev/null; then
        echo "$path" >> "$L7_NGINX_CUSTOM_PATHS"
        log_info "Путь добавлен: $path"
    else
        log_warn "Путь уже существует"
    fi
}

# Создать полный nginx конфиг для L7 защиты
create_nginx_config() {
    load_l7_config
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        echo ""
        echo -e "${YELLOW}Установите nginx:${NC}"
        echo "  apt install nginx"
        return 1
    fi
    
    log_step "Создание nginx L7 конфигов..."
    
    # Создаём директорию для конфигов
    mkdir -p /etc/nginx/conf.d
    
    # ==========================================
    # 1. MAPS - определение переменных
    # ==========================================
    cat > "$L7_NGINX_MAPS" << 'NGINX_MAPS'
# ================================================
# L7 Shield - Nginx Maps Configuration
# Server Security Shield
# ================================================

# Whitelist IPs (не лимитируем, не блокируем)
geo $l7_whitelist {
    default 0;
    127.0.0.1 1;
    10.0.0.0/8 1;
    172.16.0.0/12 1;
    192.168.0.0/16 1;
    # Добавьте IP админов/панели:
    # 1.2.3.4 1;
}

# Blacklist IPs (блокируем сразу)
geo $l7_blacklist {
    default 0;
    # Забаненные IP добавляются сюда:
    # 5.6.7.8 1;
}

# Определение bad bots по User-Agent
map $http_user_agent $l7_bad_bot {
    default 0;
    "" 1;                    # Пустой UA
    "-" 1;                   # Прочерк
    ~*bot 1;
    ~*crawl 1;
    ~*spider 1;
    ~*scanner 1;
    ~*nikto 1;
    ~*sqlmap 1;
    ~*nmap 1;
    ~*masscan 1;
    ~*zgrab 1;
    ~*gobuster 1;
    ~*dirbuster 1;
    ~*wpscan 1;
    ~*acunetix 1;
    ~*nessus 1;
    ~*openvas 1;
    ~*w3af 1;
    ~*burp 1;
    ~*wget 0;                # wget разрешаем
    ~*curl 0;                # curl разрешаем
}

# Подозрительные URI (сканеры, эксплойты)
map $request_uri $l7_bad_request {
    default 0;
    # PHP/ASP атаки
    ~*\.php$ 1;
    ~*\.php\? 1;
    ~*\.asp 1;
    ~*\.aspx 1;
    ~*\.jsp 1;
    ~*\.cgi 1;
    # WordPress атаки
    ~*wp-admin 1;
    ~*wp-login 1;
    ~*wp-content 1;
    ~*wp-includes 1;
    ~*xmlrpc\.php 1;
    # Админки
    ~*phpmyadmin 1;
    ~*pma 1;
    ~*adminer 1;
    ~*mysql 1;
    # Конфиги и бэкапы
    ~*\.env 1;
    ~*\.git 1;
    ~*\.svn 1;
    ~*\.htaccess 1;
    ~*\.htpasswd 1;
    ~*\.sql 1;
    ~*\.bak 1;
    ~*\.old 1;
    ~*\.backup 1;
    ~*\.config 1;
    ~*\.ini 1;
    ~*\.log 1;
    # Эксплойты
    ~*shell 1;
    ~*eval\( 1;
    ~*base64 1;
    ~*exec\( 1;
    ~*system\( 1;
    ~*passthru 1;
    ~*\.\.\/ 1;
    ~*\/\.\. 1;
    # AWS/Cloud metadata
    ~*169\.254\.169\.254 1;
    ~*metadata 1;
}

# Разрешённые HTTP методы
map $request_method $l7_bad_method {
    default 1;
    GET 0;
    POST 0;
    HEAD 0;
    OPTIONS 0;
    PUT 0;
    DELETE 0;
    PATCH 0;
}

# Ключ для rate limiting (whitelist не лимитируется)
map $l7_whitelist $l7_limit_key {
    0 $binary_remote_addr;
    1 "";
}

# Определение WebSocket
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

# Real IP за прокси/CDN (Cloudflare, etc)
# Раскомментируйте если используете CDN:
# set_real_ip_from 103.21.244.0/22;
# set_real_ip_from 103.22.200.0/22;
# set_real_ip_from 103.31.4.0/22;
# set_real_ip_from 104.16.0.0/13;
# set_real_ip_from 104.24.0.0/14;
# set_real_ip_from 108.162.192.0/18;
# set_real_ip_from 131.0.72.0/22;
# set_real_ip_from 141.101.64.0/18;
# set_real_ip_from 162.158.0.0/15;
# set_real_ip_from 172.64.0.0/13;
# set_real_ip_from 173.245.48.0/20;
# set_real_ip_from 188.114.96.0/20;
# set_real_ip_from 190.93.240.0/20;
# set_real_ip_from 197.234.240.0/22;
# set_real_ip_from 198.41.128.0/17;
# real_ip_header CF-Connecting-IP;
NGINX_MAPS

    # ==========================================
    # 2. RATE LIMITING ZONES
    # ==========================================
    cat > "$L7_NGINX_CONF" << NGINX_CONF
# ================================================
# L7 Shield - Nginx Rate Limiting & Protection
# Server Security Shield
# ================================================

# Rate limit zones (запросов в секунду)
limit_req_zone \$l7_limit_key zone=l7_general:50m rate=${NGINX_RATE_LIMIT};
limit_req_zone \$l7_limit_key zone=l7_strict:20m rate=5r/s;
limit_req_zone \$l7_limit_key zone=l7_api:30m rate=30r/s;
limit_req_zone \$l7_limit_key zone=l7_login:10m rate=1r/s;

# Connection limit zones (соединений на IP)
limit_conn_zone \$binary_remote_addr zone=l7_conn_perip:20m;
limit_conn_zone \$server_name zone=l7_conn_perserver:20m;

# Status коды при превышении лимитов
limit_req_status 429;
limit_conn_status 429;

# Логирование лимитов
limit_req_log_level warn;
limit_conn_log_level warn;

# Глобальные настройки безопасности
server_tokens off;
# more_clear_headers Server;  # Требует nginx-extras

# Защита от clickjacking (в http блоке)
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
NGINX_CONF

    # Проверяем nginx
    echo ""
    log_step "Проверка конфигурации..."
    
    if nginx -t 2>&1; then
        nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null
        echo ""
        log_info "Nginx L7 конфиги созданы!"
        echo -e "  ${WHITE}Maps:${NC} $L7_NGINX_MAPS"
        echo -e "  ${WHITE}Zones:${NC} $L7_NGINX_CONF"
        echo ""
        echo -e "${YELLOW}Теперь примените защиту к сайтам через меню${NC}"
    else
        log_error "Ошибка в nginx конфиге"
        echo ""
        echo -e "${RED}Проверьте конфигурацию:${NC}"
        nginx -t
        rm -f "$L7_NGINX_CONF" "$L7_NGINX_MAPS"
        return 1
    fi
}

# Сниппет для вставки в server блоки nginx
show_nginx_snippet() {
    cat << 'SNIPPET'

# ================================================
# L7 Shield - Вставьте в ваш server {} блок:
# ================================================

# Rate limiting
limit_req zone=l7_general burst=100 nodelay;
limit_conn l7_conn_perip 100;

# Блокировка bad bots
if ($l7_bad_bot) {
    return 444;
}

# Блокировка плохих запросов
if ($l7_bad_request) {
    return 444;
}

# Защита от slowloris
client_body_timeout 10s;
client_header_timeout 10s;
keepalive_timeout 30s;
send_timeout 10s;

# Буферы
client_body_buffer_size 1k;
client_header_buffer_size 1k;
client_max_body_size 10m;
large_client_header_buffers 2 1k;

# ================================================
SNIPPET
}

# Автоматическая интеграция L7 Shield в nginx
apply_nginx_protection() {
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    echo ""
    log_step "Поиск nginx конфигов..."
    
    # Получаем все пути для поиска
    local search_paths=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && search_paths+=("$path")
    done < <(get_nginx_config_paths)
    
    if [[ ${#search_paths[@]} -eq 0 ]]; then
        log_warn "Не найдены директории с nginx конфигами"
        echo ""
        echo -e "${YELLOW}Добавьте путь к вашим конфигам через меню${NC}"
        return 1
    fi
    
    # Ищем все конфиги с server блоками
    local nginx_configs=()
    
    for search_path in "${search_paths[@]}"; do
        for conf in "$search_path"/* "$search_path"/*.conf; do
            [[ ! -f "$conf" ]] && continue
            [[ "$conf" =~ l7shield ]] && continue
            [[ "$conf" =~ \.bak\. ]] && continue
            
            # Проверяем что это nginx конфиг с server блоком
            if grep -q "server\s*{" "$conf" 2>/dev/null; then
                nginx_configs+=("$conf")
            fi
        done
    done
    
    if [[ ${#nginx_configs[@]} -eq 0 ]]; then
        log_warn "Не найдены nginx конфиги с server блоками"
        echo ""
        echo -e "${WHITE}Проверенные директории:${NC}"
        for p in "${search_paths[@]}"; do
            echo "  $p"
        done
        echo ""
        echo -e "${YELLOW}Добавьте путь к вашим конфигам через меню${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Найденные nginx конфиги:${NC}"
    local i=1
    for conf in "${nginx_configs[@]}"; do
        local dir=$(dirname "$conf")
        local name=$(basename "$conf")
        # Проверяем уже ли добавлена защита
        if grep -q "L7 Shield Protection" "$conf" 2>/dev/null; then
            echo -e "  ${WHITE}$i)${NC} ${GREEN}✓${NC} ${CYAN}$dir/${NC}$name"
        else
            echo -e "  ${WHITE}$i)${NC} ${YELLOW}○${NC} ${CYAN}$dir/${NC}$name"
        fi
        ((i++))
    done
    
    echo ""
    echo -e "  ${WHITE}a)${NC} Применить ко ВСЕМ"
    echo -e "  ${WHITE}0)${NC} Отмена"
    echo ""
    read -p "Выберите конфиг (номер или 'a'): " choice
    
    if [[ "$choice" == "0" ]]; then
        return 0
    fi
    
    local configs_to_update=()
    
    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        configs_to_update=("${nginx_configs[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nginx_configs[@]} ]]; then
        configs_to_update=("${nginx_configs[$((choice-1))]}")
    else
        log_error "Неверный выбор"
        return 1
    fi
    
    # Создаём бэкап и применяем защиту
    local updated=0
    local skipped=0
    
    for conf in "${configs_to_update[@]}"; do
        # Проверяем уже есть защита
        if grep -q "L7 Shield Protection" "$conf" 2>/dev/null; then
            echo -e "  ${CYAN}Пропуск:${NC} $(basename "$conf") (уже защищён)"
            ((skipped++))
            continue
        fi
        
        # Бэкап
        cp "$conf" "${conf}.bak.$(date +%Y%m%d_%H%M%S)"
        
        # Блок защиты для вставки
        local protection_block='
    # ============ L7 Shield Protection ============
    # Rate limiting
    limit_req zone=l7_general burst=100 nodelay;
    limit_conn l7_conn_perip 100;
    
    # Блокировка blacklist
    if ($l7_blacklist) {
        return 444;
    }
    
    # Блокировка bad bots
    if ($l7_bad_bot) {
        return 444;
    }
    
    # Блокировка плохих запросов  
    if ($l7_bad_request) {
        return 444;
    }
    
    # Блокировка плохих HTTP методов
    if ($l7_bad_method) {
        return 444;
    }
    
    # Защита от slowloris
    client_body_timeout 10s;
    client_header_timeout 10s;
    keepalive_timeout 30s;
    send_timeout 10s;
    
    # Буферы
    client_body_buffer_size 8k;
    client_header_buffer_size 2k;
    client_max_body_size 50m;
    large_client_header_buffers 4 4k;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    # ============ End L7 Shield ============
'
        
        # Вставляем после первого "server {" 
        if grep -q "server\s*{" "$conf"; then
            # Создаём временный файл с защитой
            awk -v protection="$protection_block" '
                /server\s*\{/ && !inserted {
                    print
                    print protection
                    inserted=1
                    next
                }
                {print}
            ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
            
            echo -e "  ${GREEN}✓ Обновлён:${NC} $(basename "$conf")"
            ((updated++))
        else
            echo -e "  ${YELLOW}? Пропуск:${NC} $(basename "$conf") (не найден server блок)"
        fi
    done
    
    echo ""
    
    if [[ $updated -gt 0 ]]; then
        # Проверяем конфиг nginx
        log_step "Проверка конфигурации nginx..."
        
        if nginx -t 2>&1; then
            echo ""
            log_step "Перезагрузка nginx..."
            
            if nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null; then
                echo ""
                log_info "Nginx защита применена!"
                echo -e "  Обновлено: ${GREEN}$updated${NC} конфигов"
                [[ $skipped -gt 0 ]] && echo -e "  Пропущено: ${CYAN}$skipped${NC} (уже защищены)"
            else
                log_error "Не удалось перезагрузить nginx"
            fi
        else
            log_error "Ошибка в конфигурации nginx!"
            echo ""
            echo -e "${YELLOW}Восстанавливаем из бэкапа...${NC}"
            
            for conf in "${configs_to_update[@]}"; do
                local backup=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
                if [[ -f "$backup" ]]; then
                    cp "$backup" "$conf"
                    echo -e "  Восстановлен: $(basename "$conf")"
                fi
            done
            
            nginx -t && log_info "Конфиг восстановлен"
        fi
    else
        log_info "Нечего обновлять"
    fi
}

# Удалить L7 Shield защиту из nginx конфигов
remove_nginx_protection() {
    if ! check_nginx_installed; then
        log_error "Nginx не установлен"
        return 1
    fi
    
    log_step "Удаление L7 Shield из nginx конфигов..."
    
    local removed=0
    
    # Получаем все пути для поиска
    local search_paths=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && search_paths+=("$path")
    done < <(get_nginx_config_paths)
    
    # Ищем все конфиги с нашей защитой
    for search_path in "${search_paths[@]}"; do
        for conf in "$search_path"/* "$search_path"/*.conf; do
            [[ ! -f "$conf" ]] && continue
            [[ "$conf" =~ l7shield ]] && continue
            [[ "$conf" =~ \.bak\. ]] && continue
            
            if grep -q "L7 Shield Protection" "$conf" 2>/dev/null; then
                # Бэкап
                cp "$conf" "${conf}.bak.$(date +%Y%m%d_%H%M%S)"
                
                # Удаляем блок между маркерами
                sed -i '/# ============ L7 Shield Protection ============/,/# ============ End L7 Shield ============/d' "$conf"
                
                echo -e "  ${GREEN}✓${NC} Очищен: $conf"
                ((removed++))
            fi
        done
    done
    
    if [[ $removed -gt 0 ]]; then
        if nginx -t 2>&1 && (nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null); then
            log_info "L7 Shield удалён из $removed конфигов"
        fi
    else
        log_info "L7 Shield не найден в nginx конфигах"
    fi
}

# Показать добавленные кастомные пути
show_nginx_paths() {
    echo ""
    echo -e "${WHITE}Пути для поиска nginx конфигов:${NC}"
    echo ""
    
    # Стандартные
    echo -e "  ${CYAN}Стандартные:${NC}"
    [[ -d "/etc/nginx/sites-enabled" ]] && echo "    /etc/nginx/sites-enabled"
    [[ -d "/etc/nginx/conf.d" ]] && echo "    /etc/nginx/conf.d"
    
    # Автообнаруженные VPN панели
    echo ""
    echo -e "  ${CYAN}Автообнаруженные VPN панели:${NC}"
    local found=0
    for vpath in /opt/remnawave /opt/marzban /opt/x-ui /opt/3x-ui /opt/hiddify /root/remnawave /root/marzban; do
        if [[ -d "$vpath" ]]; then
            echo "    $vpath"
            ((found++))
        fi
    done
    [[ $found -eq 0 ]] && echo "    (не найдено)"
    
    # Кастомные
    echo ""
    echo -e "  ${CYAN}Добавленные вручную:${NC}"
    if [[ -f "$L7_NGINX_CUSTOM_PATHS" ]] && [[ -s "$L7_NGINX_CUSTOM_PATHS" ]]; then
        while IFS= read -r path; do
            [[ "$path" =~ ^# ]] && continue
            [[ -z "$path" ]] && continue
            if [[ -d "$path" ]]; then
                echo "    $path"
            else
                echo -e "    ${RED}$path (не существует)${NC}"
            fi
        done < "$L7_NGINX_CUSTOM_PATHS"
    else
        echo "    (не добавлено)"
    fi
}

# Меню nginx интеграции
nginx_menu() {
    while true; do
        print_header_mini "Nginx Protection"
        
        # Проверяем статус nginx
        if ! check_nginx_installed; then
            log_error "Nginx не установлен"
            echo ""
            echo -e "    ${YELLOW}Установите:${NC} apt install nginx"
            press_any_key
            return
        fi
        
        # Статус блок
        local nginx_ver=$(nginx -v 2>&1 | cut -d'/' -f2)
        local maps_ok=$([[ -f "$L7_NGINX_MAPS" ]] && echo "true" || echo "false")
        local zones_ok=$([[ -f "$L7_NGINX_CONF" ]] && echo "true" || echo "false")
        
        # Считаем защищённые конфиги
        local protected=0 total=0
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            for conf in "$path"/* "$path"/*.conf; do
                [[ ! -f "$conf" ]] && continue
                [[ "$conf" =~ l7shield ]] && continue
                [[ "$conf" =~ \.bak\. ]] && continue
                grep -q "server\s*{" "$conf" 2>/dev/null || continue
                ((total++))
                grep -q "L7 Shield" "$conf" 2>/dev/null && ((protected++))
            done
        done < <(get_nginx_config_paths 2>/dev/null)
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "    ${DIM}│${NC} Nginx: ${GREEN}$nginx_ver${NC}                                       ${DIM}│${NC}"
        if [[ "$maps_ok" == "true" && "$zones_ok" == "true" ]]; then
            echo -e "    ${DIM}│${NC} L7 Config: ${GREEN}● Ready${NC}    Protected: ${CYAN}$protected${NC}/${total}          ${DIM}│${NC}"
        else
            echo -e "    ${DIM}│${NC} L7 Config: ${RED}○ Not configured${NC}                        ${DIM}│${NC}"
        fi
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Создать L7 конфиги (zones, maps)"
        menu_item "2" "Применить защиту к конфигам"
        menu_item "3" "Убрать защиту из конфигов"
        menu_divider
        menu_item "4" "Показать пути поиска"
        menu_item "5" "Добавить путь"
        menu_divider
        menu_item "6" "Показать сниппет"
        menu_item "7" "Перезагрузить nginx"
        menu_divider
        menu_item "0" "Назад"
        
        echo ""
        echo -e "    ${DIM}Что защищает nginx:${NC}"
        echo -e "    ${DIM}• Rate limit (req/s), Connection limit${NC}"
        echo -e "    ${DIM}• Bad bots, Scanners (.php, .env)${NC}"
        echo -e "    ${DIM}• Slowloris protection${NC}"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                create_nginx_config
                press_any_key
                ;;
            2)
                if [[ "$maps_ok" != "true" || "$zones_ok" != "true" ]]; then
                    log_warn "Сначала создайте L7 конфиги (пункт 1)"
                else
                    apply_nginx_protection
                fi
                press_any_key
                ;;
            3)
                if confirm_action "Убрать L7 защиту из nginx конфигов?" "n"; then
                    remove_nginx_protection
                fi
                press_any_key
                ;;
            4)
                show_nginx_paths
                press_any_key
                ;;
            5)
                echo ""
                echo -e "    ${WHITE}Введите путь к nginx конфигам:${NC}"
                echo -e "    ${DIM}Примеры: /opt/remnawave, /opt/marzban${NC}"
                local custom_path
                input_value "Путь" "" custom_path
                if [[ -n "$custom_path" ]]; then
                    add_nginx_custom_path "$custom_path"
                fi
                press_any_key
                ;;
            6)
                show_nginx_snippet
                press_any_key
                ;;
            7)
                if nginx -t 2>&1; then
                    nginx -s reload 2>/dev/null || systemctl reload nginx
                    log_info "Nginx перезагружен"
                else
                    log_error "Ошибка в конфигурации nginx"
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# ============================================
# AUTOBAN СИСТЕМА
# ============================================

# Скрипт автоматического бана
create_autoban_script() {
    load_l7_config
    
    mkdir -p "$(dirname "$L7_SCRIPT")"
    
    cat > "$L7_SCRIPT" << 'SCRIPT'
#!/bin/bash
#
# L7 Shield - Auto-protection Script
# Server Security Shield
#

source /opt/server-shield/modules/utils.sh 2>/dev/null
source /opt/server-shield/config/l7shield/config.conf 2>/dev/null

LOG="/opt/server-shield/logs/l7shield.log"
BAN_LOG="/opt/server-shield/logs/l7_bans.log"
IPSET_AUTOBAN="l7_autoban"
IPSET_WHITELIST="l7_whitelist"

log_l7() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG"
}

# Получить топ IP по соединениям
get_top_connections() {
    ss -tn state established 2>/dev/null | \
        awk 'NR>1 {split($4,a,":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -20
}

# Получить топ IP по SYN
get_top_syn() {
    ss -tn state syn-recv 2>/dev/null | \
        awk 'NR>1 {split($4,a,":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -20
}

# Анализ nginx access.log
analyze_nginx_log() {
    local logfile="${1:-/var/log/nginx/access.log}"
    local minutes="${2:-1}"
    
    if [[ ! -f "$logfile" ]]; then
        return
    fi
    
    local since=$(date -d "$minutes minutes ago" '+%d/%b/%Y:%H:%M' 2>/dev/null)
    
    # Топ IP за последние N минут
    awk -v since="$since" '
        $4 >= "["since {print $1}
    ' "$logfile" 2>/dev/null | sort | uniq -c | sort -rn | head -20
}

# Проверка и бан
check_and_ban() {
    if [[ "$AUTOBAN_ENABLED" != "true" ]]; then
        return
    fi
    
    local threshold="${AUTOBAN_CONN_THRESHOLD:-300}"
    local ban_time="${AUTOBAN_TIME:-3600}"
    
    # Проверка по соединениям
    get_top_connections | while read count ip; do
        # Пропускаем whitelist
        if ipset test "$IPSET_WHITELIST" "$ip" 2>/dev/null; then
            continue
        fi
        
        # Пропускаем локальные
        if [[ "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
            continue
        fi
        
        if [[ "$count" -gt "$threshold" ]]; then
            if ! ipset test "$IPSET_AUTOBAN" "$ip" 2>/dev/null; then
                ipset add "$IPSET_AUTOBAN" "$ip" timeout "$ban_time" 2>/dev/null
                log_l7 "AUTOBAN | $ip | connections: $count > $threshold"
                echo "$(date '+%Y-%m-%d %H:%M:%S') | AUTOBAN | $ip | connections: $count" >> "$BAN_LOG"
                
                # Добавляем в очередь на GitHub sync
                echo "$ip" >> "/opt/server-shield/config/l7shield/sync_queue.txt"
            fi
        fi
    done
    
    # Проверка nginx (HTTP flood)
    local rate_threshold="${AUTOBAN_RATE_THRESHOLD:-200}"
    
    analyze_nginx_log "/var/log/nginx/access.log" 1 | while read count ip; do
        if ipset test "$IPSET_WHITELIST" "$ip" 2>/dev/null; then
            continue
        fi
        
        if [[ "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
            continue
        fi
        
        if [[ "$count" -gt "$rate_threshold" ]]; then
            if ! ipset test "$IPSET_AUTOBAN" "$ip" 2>/dev/null; then
                ipset add "$IPSET_AUTOBAN" "$ip" timeout "$ban_time" 2>/dev/null
                log_l7 "AUTOBAN | $ip | requests/min: $count > $rate_threshold"
                echo "$(date '+%Y-%m-%d %H:%M:%S') | AUTOBAN | $ip | http_flood: $count req/min" >> "$BAN_LOG"
                
                # Добавляем в очередь на GitHub sync
                echo "$ip" >> "/opt/server-shield/config/l7shield/sync_queue.txt"
            fi
        fi
    done
}

# Обновление blacklist (GitHub sync каждые N часов)
check_blacklist_update() {
    local last_update_file="/opt/server-shield/config/l7shield/last_blacklist_update"
    local interval="${BLACKLIST_UPDATE_INTERVAL:-1}"  # По умолчанию каждый час
    local interval_sec=$((interval * 3600))
    
    local last_update=0
    [[ -f "$last_update_file" ]] && last_update=$(cat "$last_update_file")
    
    local now=$(date +%s)
    local diff=$((now - last_update))
    
    if [[ $diff -gt $interval_sec ]]; then
        log_l7 "GITHUB_SYNC | Starting scheduled sync"
        /opt/server-shield/modules/l7shield.sh sync
        date +%s > "$last_update_file"
    fi
}

# Main
case "${1:-}" in
    check)
        check_and_ban
        ;;
    update)
        check_blacklist_update
        ;;
    *)
        check_and_ban
        check_blacklist_update
        ;;
esac
SCRIPT

    chmod +x "$L7_SCRIPT"
}

# Создать cron для автоматической защиты
create_l7_cron() {
    cat > "$L7_CRON" << CRON
# L7 Shield - Auto-protection
# Проверка каждую минуту
* * * * * root $L7_SCRIPT check

# GitHub sync каждый час
0 * * * * root $L7_SCRIPT update
CRON

    systemctl reload cron 2>/dev/null
    log_info "L7 Shield cron создан"
}

# ============================================
# SYSTEMD SERVICE
# ============================================

create_l7_service() {
    cat > "$L7_SERVICE" << SERVICE
[Unit]
Description=L7 Shield - Server Security Shield
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/server-shield/modules/l7shield.sh start_silent
ExecStop=/opt/server-shield/modules/l7shield.sh stop_silent
ExecReload=/opt/server-shield/modules/l7shield.sh reload_silent

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
}

# ============================================
# УПРАВЛЕНИЕ
# ============================================

# Включить L7 Shield
enable_l7() {
    load_l7_config
    
    log_step "Включение L7 Shield..."
    
    # Установка nginx если нужно
    ensure_nginx_installed
    
    local backend=$(detect_firewall)
    log_info "Используется backend: $backend"
    
    # Установка зависимостей
    apt-get update -qq
    
    if [[ "$backend" == "nftables" ]]; then
        apt-get install -y nftables conntrack >/dev/null 2>&1
        
        # Применяем nftables правила
        apply_nft_rules
    else
        apt-get install -y ipset conntrack >/dev/null 2>&1
        
        # Инициализация ipset
        init_ipsets
        
        # Загрузка whitelist
        if [[ -f "$L7_WHITELIST" ]]; then
            grep -v "^#" "$L7_WHITELIST" | grep -v "^$" | while read ip; do
                ipset add "$IPSET_WHITELIST" "$ip" 2>/dev/null
            done
        fi
        
        # Загрузка blacklist
        if [[ -f "$L7_BLACKLIST" ]]; then
            grep -v "^#" "$L7_BLACKLIST" | grep -v "^$" | while read ip; do
                ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
            done
        fi
        
        # Применяем правила
        apply_l7_iptables
    fi
    
    # GeoIP если включен (только для iptables)
    if [[ "$GEOIP_ENABLED" == "true" && "$backend" == "iptables" ]]; then
        apply_geoip_rules
    fi
    
    # Nginx
    if command -v nginx &>/dev/null; then
        create_nginx_config
    fi
    
    # Скрипты
    create_autoban_script
    create_l7_cron
    create_l7_service
    
    # GitHub Sync - настраиваем автосинхронизацию и первый sync
    init_github_sync
    create_github_sync_cron
    log_step "Синхронизация IP с GitHub..."
    github_full_sync
    
    # Включаем сервис
    systemctl enable shield-l7 2>/dev/null
    
    # Сохраняем статус
    save_l7_param "L7_ENABLED" "true"
    save_l7_param "FIREWALL_BACKEND" "$backend"
    
    log_info "L7 Shield включен! (backend: $backend)"
}

# Выключить L7 Shield
disable_l7() {
    log_step "Выключение L7 Shield..."
    
    local backend=$(detect_firewall)
    
    # Очищаем правила
    if [[ "$backend" == "nftables" ]]; then
        clear_nft_rules
    else
        clear_l7_rules
    fi
    
    # Удаляем cron
    rm -f "$L7_CRON"
    
    # Останавливаем сервис
    systemctl stop shield-l7 2>/dev/null
    systemctl disable shield-l7 2>/dev/null
    
    # Удаляем nginx конфиг
    rm -f "$L7_NGINX_CONF" "$L7_NGINX_MAPS"
    nginx -s reload 2>/dev/null
    
    # Сохраняем статус
    save_l7_param "L7_ENABLED" "false"
    
    log_info "L7 Shield выключен"
}

# Перезагрузить правила
reload_l7() {
    load_l7_config
    
    if [[ "$L7_ENABLED" != "true" ]]; then
        log_warn "L7 Shield не включен"
        return 1
    fi
    
    log_step "Перезагрузка L7 Shield..."
    
    local backend=$(detect_firewall)
    
    if [[ "$backend" == "nftables" ]]; then
        apply_nft_rules
    else
        clear_l7_rules
        init_ipsets
        apply_l7_iptables
        
        if [[ "$GEOIP_ENABLED" == "true" ]]; then
            apply_geoip_rules
        fi
    fi
    
    log_info "L7 Shield перезагружен (backend: $backend)"
}

# Silent версии для systemd
start_silent() {
    init_l7_config
    load_l7_config
    [[ "$L7_ENABLED" != "true" ]] && exit 0
    init_ipsets
    
    # Загрузка whitelist
    if [[ -f "$L7_WHITELIST" ]]; then
        grep -v "^#" "$L7_WHITELIST" | grep -v "^$" | while read ip; do
            ipset add "$IPSET_WHITELIST" "$ip" 2>/dev/null
        done
    fi
    
    # Загрузка blacklist
    if [[ -f "$L7_BLACKLIST" ]]; then
        grep -v "^#" "$L7_BLACKLIST" | grep -v "^$" | while read ip; do
            ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null
        done
    fi
    
    apply_l7_iptables
    [[ "$GEOIP_ENABLED" == "true" ]] && apply_geoip_rules
}

stop_silent() {
    clear_l7_rules
}

reload_silent() {
    stop_silent
    start_silent
}

# ============================================
# СТАТИСТИКА И СТАТУС
# ============================================

show_l7_status() {
    load_l7_config
    
    print_section "🛡️ L7 Shield Status"
    
    echo ""
    
    # Статус
    if [[ "$L7_ENABLED" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} L7 Shield: ${GREEN}АКТИВЕН${NC}"
    else
        echo -e "  ${RED}○${NC} L7 Shield: ${RED}ВЫКЛЮЧЕН${NC}"
    fi
    
    # ipset статистика
    echo ""
    echo -e "  ${WHITE}IP Sets:${NC}"
    
    local blacklist_count=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
    local whitelist_count=$(ipset list "$IPSET_WHITELIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
    local autoban_count=$(ipset list "$IPSET_AUTOBAN" 2>/dev/null | grep -c "^[0-9]" || echo 0)
    
    echo -e "    Blacklist: ${RED}$blacklist_count${NC} IP"
    echo -e "    Whitelist: ${GREEN}$whitelist_count${NC} IP"
    echo -e "    Auto-banned: ${YELLOW}$autoban_count${NC} IP"
    
    # VPN порты
    echo ""
    echo -e "  ${WHITE}VPN порты:${NC}"
    local vpn_ports=$(get_vpn_ports)
    echo -e "    ${CYAN}$vpn_ports${NC}"
    
    # Лимиты
    echo ""
    echo -e "  ${WHITE}Connection Limits:${NC}"
    echo -e "    Global: ${CYAN}$CONN_LIMIT_GLOBAL${NC}"
    echo -e "    VPN: ${CYAN}$CONN_LIMIT_VPN${NC}"
    echo -e "    SSH: ${CYAN}$CONN_LIMIT_SSH${NC}"
    
    # GeoIP
    echo ""
    if [[ "$GEOIP_ENABLED" == "true" ]]; then
        echo -e "  ${WHITE}GeoIP:${NC} ${GREEN}Включен${NC} ($GEOIP_MODE)"
    else
        echo -e "  ${WHITE}GeoIP:${NC} ${YELLOW}Выключен${NC}"
    fi
    
    # Текущие соединения
    echo ""
    echo -e "  ${WHITE}Текущие соединения:${NC}"
    local total_conn=$(ss -tn state established 2>/dev/null | wc -l)
    local syn_conn=$(ss -tn state syn-recv 2>/dev/null | wc -l)
    echo -e "    Established: ${CYAN}$total_conn${NC}"
    echo -e "    SYN-RECV: ${YELLOW}$syn_conn${NC}"
    
    # Топ IP
    echo ""
    echo -e "  ${WHITE}Топ 5 IP по соединениям:${NC}"
    ss -tn state established 2>/dev/null | \
        awk 'NR>1 {split($4,a,":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -5 | \
        while read count ip; do
            echo -e "    ${CYAN}$ip${NC}: $count"
        done
}

# Показать топ атакующих
show_top_attackers() {
    print_section "🎯 Топ атакующих"
    
    echo ""
    echo -e "${WHITE}По количеству соединений (сейчас):${NC}"
    echo ""
    
    ss -tn state established 2>/dev/null | \
        awk 'NR>1 {split($4,a,":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -15 | \
        while read count ip; do
            if [[ $count -gt 50 ]]; then
                echo -e "  ${RED}$count${NC} - $ip"
            elif [[ $count -gt 20 ]]; then
                echo -e "  ${YELLOW}$count${NC} - $ip"
            else
                echo -e "  ${GREEN}$count${NC} - $ip"
            fi
        done
    
    echo ""
    echo -e "${WHITE}SYN-RECV (возможный SYN flood):${NC}"
    echo ""
    
    ss -tn state syn-recv 2>/dev/null | \
        awk 'NR>1 {split($4,a,":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read count ip; do
            echo -e "  ${RED}$count${NC} - $ip"
        done
    
    # Nginx
    if [[ -f /var/log/nginx/access.log ]]; then
        echo ""
        echo -e "${WHITE}Топ по HTTP запросам (последняя минута):${NC}"
        echo ""
        
        local since=$(date -d "1 minute ago" '+%d/%b/%Y:%H:%M' 2>/dev/null)
        awk -v since="$since" '
            $4 >= "["since {print $1}
        ' /var/log/nginx/access.log 2>/dev/null | \
            sort | uniq -c | sort -rn | head -10 | \
            while read count ip; do
                if [[ $count -gt 100 ]]; then
                    echo -e "  ${RED}$count${NC} req/min - $ip"
                elif [[ $count -gt 50 ]]; then
                    echo -e "  ${YELLOW}$count${NC} req/min - $ip"
                else
                    echo -e "  ${GREEN}$count${NC} req/min - $ip"
                fi
            done
    fi
}

# ============================================
# МЕНЮ
# ============================================

# Меню VPN портов
vpn_ports_menu() {
    while true; do
        print_header
        print_section "🔌 VPN Порты"
        
        echo ""
        echo -e "${WHITE}Текущие VPN порты (мягкие лимиты):${NC}"
        echo ""
        
        local i=1
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue
            echo -e "  ${WHITE}$i)${NC} ${CYAN}$line${NC}"
            ((i++))
        done < "$L7_VPN_PORTS"
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}a)${NC} Добавить порт"
        echo -e "  ${WHITE}d)${NC} Удалить порт"
        echo -e "  ${WHITE}r)${NC} Сбросить на дефолтные"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            a|A)
                echo ""
                read -p "Введите порт: " port
                if validate_port "$port"; then
                    if ! grep -q "^$port$" "$L7_VPN_PORTS"; then
                        echo "$port" >> "$L7_VPN_PORTS"
                        log_info "Порт $port добавлен"
                        
                        # Перезагружаем если активен
                        [[ "$L7_ENABLED" == "true" ]] && reload_l7
                    else
                        log_warn "Порт уже существует"
                    fi
                else
                    log_error "Неверный порт"
                fi
                ;;
            d|D)
                echo ""
                read -p "Номер порта для удаления: " num
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    local port_to_del=$(grep -v "^#" "$L7_VPN_PORTS" | grep -v "^$" | sed -n "${num}p")
                    if [[ -n "$port_to_del" ]]; then
                        sed -i "/^$port_to_del$/d" "$L7_VPN_PORTS"
                        log_info "Порт $port_to_del удалён"
                        [[ "$L7_ENABLED" == "true" ]] && reload_l7
                    fi
                fi
                ;;
            r|R)
                echo "# VPN порты" > "$L7_VPN_PORTS"
                for port in $DEFAULT_VPN_PORTS; do
                    echo "$port" >> "$L7_VPN_PORTS"
                done
                log_info "Порты сброшены на дефолтные"
                [[ "$L7_ENABLED" == "true" ]] && reload_l7
                ;;
            0) return ;;
        esac
        
        press_any_key
    done
}

# Меню blacklist (GitHub-powered)
blacklist_menu() {
    while true; do
        print_header_mini "IP Blacklist (GitHub Sync)"
        
        local backend=$(detect_firewall)
        local blacklist_count=0
        local queue_count=0
        local synced_count=0
        
        # Получаем статистику
        if [[ "$backend" == "nftables" ]]; then
            blacklist_count=$(nft_list_set "blacklist" 2>/dev/null | wc -l)
        else
            blacklist_count=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        fi
        
        [[ -f "$L7_SYNC_QUEUE" ]] && queue_count=$(grep -c "^[0-9]" "$L7_SYNC_QUEUE" 2>/dev/null || echo 0)
        [[ -f "$L7_SYNCED_IPS" ]] && synced_count=$(grep -c "^[0-9]" "$L7_SYNCED_IPS" 2>/dev/null || echo 0)
        
        # Статус блок
        echo ""
        show_info "Заблокировано" "${blacklist_count} IP"
        show_info "В очереди" "${queue_count} IP"
        show_info "Синхронизировано" "${synced_count} IP"
        show_info "Репозиторий" "github.com/${GITHUB_REPO}"
        
        # Последняя синхронизация
        if [[ -f "$L7_LAST_SYNC" ]]; then
            local last_sync=$(cat "$L7_LAST_SYNC")
            show_info "Последний sync" "$last_sync"
        fi
        
        echo ""
        print_divider
        echo ""
        
        menu_item "1" "Добавить IP в blacklist"
        menu_item "2" "Удалить IP из blacklist"
        menu_item "3" "Показать заблокированные IP"
        menu_divider
        menu_item "4" "Синхронизировать с GitHub"
        menu_item "5" "Показать очередь на отправку"
        menu_divider
        menu_item "6" "Очистить локальный blacklist"
        menu_divider
        menu_item "0" "Назад"
        
        echo ""
        echo -e "    ${DIM}Авто-sync каждые 12 часов${NC}"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                echo ""
                echo -ne "    ${WHITE}IP для блокировки:${NC} "
                read -r ip
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    add_ip_to_global_blacklist "$ip" "manual"
                else
                    log_error "Неверный IP адрес"
                fi
                press_any_key
                ;;
            2)
                echo ""
                echo -ne "    ${WHITE}IP для разблокировки:${NC} "
                read -r ip
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    remove_ip_from_blacklist "$ip"
                else
                    log_error "Неверный IP адрес"
                fi
                press_any_key
                ;;
            3)
                echo ""
                echo -e "    ${WHITE}Заблокированные IP (первые 50):${NC}"
                echo ""
                if [[ "$backend" == "nftables" ]]; then
                    nft_list_set "blacklist" 2>/dev/null | head -50 | while read ip; do
                        echo -e "    ${RED}●${NC} $ip"
                    done
                else
                    ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep "^[0-9]" | head -50 | while read ip; do
                        echo -e "    ${RED}●${NC} $ip"
                    done
                fi
                [[ $blacklist_count -gt 50 ]] && echo -e "    ${DIM}... и ещё $((blacklist_count - 50)) IP${NC}"
                press_any_key
                ;;
            4)
                echo ""
                github_full_sync
                press_any_key
                ;;
            5)
                echo ""
                echo -e "    ${WHITE}Очередь на отправку в GitHub:${NC}"
                echo ""
                if [[ -s "$L7_SYNC_QUEUE" ]]; then
                    head -20 "$L7_SYNC_QUEUE" | while read ip; do
                        echo -e "    ${YELLOW}→${NC} $ip"
                    done
                    [[ $queue_count -gt 20 ]] && echo -e "    ${DIM}... и ещё $((queue_count - 20)) IP${NC}"
                else
                    echo -e "    ${DIM}Очередь пуста${NC}"
                fi
                press_any_key
                ;;
            6)
                if confirm_action "Очистить локальный blacklist?" "n"; then
                    clear_local_blacklist
                    log_warn "GitHub база не затронута"
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# Меню whitelist
whitelist_menu() {
    while true; do
        print_header
        print_section "✅ Whitelist"
        
        echo ""
        echo -e "${WHITE}IP в whitelist (никогда не блокируются):${NC}"
        echo ""
        
        local i=1
        ipset list "$IPSET_WHITELIST" 2>/dev/null | grep "^[0-9]" | while read ip; do
            echo -e "  ${WHITE}$i)${NC} ${GREEN}$ip${NC}"
            ((i++))
        done
        
        # Также из файла
        grep -v "^#" "$L7_WHITELIST" 2>/dev/null | grep -v "^$" | while read ip; do
            if ! ipset test "$IPSET_WHITELIST" "$ip" 2>/dev/null; then
                echo -e "  ${YELLOW}○${NC} $ip (не загружен)"
            fi
        done
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} Добавить IP"
        echo -e "  ${WHITE}2)${NC} Удалить IP"
        echo -e "  ${WHITE}3)${NC} Добавить текущий IP"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            1)
                echo ""
                read -p "IP для whitelist: " ip
                if validate_ip "$ip"; then
                    add_to_whitelist "$ip"
                else
                    log_error "Неверный IP"
                fi
                ;;
            2)
                echo ""
                read -p "IP для удаления: " ip
                ipset del "$IPSET_WHITELIST" "$ip" 2>/dev/null
                sed -i "/^$ip$/d" "$L7_WHITELIST"
                log_info "IP $ip удалён из whitelist"
                ;;
            3)
                local current_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
                if [[ -n "$current_ip" ]]; then
                    add_to_whitelist "$current_ip"
                else
                    log_error "Не удалось определить IP"
                fi
                ;;
            0) return ;;
        esac
        
        press_any_key
    done
}

# Меню GeoIP
geoip_menu() {
    while true; do
        print_header
        print_section "🌍 GeoIP Блокировка"
        
        load_l7_config
        
        echo ""
        if [[ "$GEOIP_ENABLED" == "true" ]]; then
            echo -e "  ${GREEN}●${NC} GeoIP: ${GREEN}Включен${NC}"
            echo -e "  Режим: ${CYAN}$GEOIP_MODE${NC}"
        else
            echo -e "  ${RED}○${NC} GeoIP: ${RED}Выключен${NC}"
        fi
        
        echo ""
        echo -e "${WHITE}Разрешённые страны:${NC}"
        while IFS= read -r country; do
            [[ "$country" =~ ^# ]] && continue
            [[ -z "$country" ]] && continue
            echo -e "  ${GREEN}✓${NC} $country"
        done < "$L7_GEOIP_ALLOW"
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        if [[ "$GEOIP_ENABLED" == "true" ]]; then
            echo -e "  ${WHITE}1)${NC} ${RED}Выключить GeoIP${NC}"
        else
            echo -e "  ${WHITE}1)${NC} ${GREEN}Включить GeoIP${NC}"
        fi
        
        echo -e "  ${WHITE}2)${NC} Изменить режим (allow/deny)"
        echo -e "  ${WHITE}3)${NC} Добавить страну"
        echo -e "  ${WHITE}4)${NC} Удалить страну"
        echo -e "  ${WHITE}5)${NC} Установить GeoIP базы"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            1)
                if [[ "$GEOIP_ENABLED" == "true" ]]; then
                    save_l7_param "GEOIP_ENABLED" "false"
                    iptables -D INPUT -m geoip ! --src-cc RU,UA,BY,KZ -j DROP 2>/dev/null
                    log_info "GeoIP выключен"
                else
                    save_l7_param "GEOIP_ENABLED" "true"
                    apply_geoip_rules
                    log_info "GeoIP включен"
                fi
                ;;
            2)
                echo ""
                echo "Текущий режим: $GEOIP_MODE"
                echo "  allow - только указанные страны разрешены"
                echo "  deny  - указанные страны заблокированы"
                read -p "Новый режим (allow/deny): " mode
                if [[ "$mode" == "allow" || "$mode" == "deny" ]]; then
                    save_l7_param "GEOIP_MODE" "$mode"
                    [[ "$GEOIP_ENABLED" == "true" ]] && apply_geoip_rules
                fi
                ;;
            3)
                echo ""
                echo "Примеры кодов: RU, UA, BY, KZ, US, DE, NL, FR"
                read -p "Код страны (ISO): " country
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
                if [[ ${#country} -eq 2 ]]; then
                    echo "$country" >> "$L7_GEOIP_ALLOW"
                    log_info "Страна $country добавлена"
                    [[ "$GEOIP_ENABLED" == "true" ]] && apply_geoip_rules
                fi
                ;;
            4)
                echo ""
                read -p "Код страны для удаления: " country
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
                sed -i "/^$country$/d" "$L7_GEOIP_ALLOW"
                [[ "$GEOIP_ENABLED" == "true" ]] && apply_geoip_rules
                ;;
            5)
                install_geoip
                ;;
            0) return ;;
        esac
        
        press_any_key
    done
}

# Меню лимитов
limits_menu() {
    while true; do
        print_header
        print_section "⚙️ Настройка лимитов"
        
        load_l7_config
        
        echo ""
        echo -e "${WHITE}Connection Limits (макс соединений с 1 IP):${NC}"
        echo -e "  1) Глобальный: ${CYAN}$CONN_LIMIT_GLOBAL${NC}"
        echo -e "  2) VPN порты: ${CYAN}$CONN_LIMIT_VPN${NC}"
        echo -e "  3) SSH: ${CYAN}$CONN_LIMIT_SSH${NC}"
        echo -e "  4) HTTP: ${CYAN}$CONN_LIMIT_HTTP${NC}"
        
        echo ""
        echo -e "${WHITE}Rate Limits (новых соединений/сек):${NC}"
        echo -e "  5) Глобальный: ${CYAN}$RATE_LIMIT_GLOBAL${NC}"
        echo -e "  6) VPN: ${CYAN}$RATE_LIMIT_VPN${NC}"
        echo -e "  7) HTTP: ${CYAN}$RATE_LIMIT_HTTP${NC}"
        
        echo ""
        echo -e "${WHITE}Auto-ban:${NC}"
        echo -e "  8) Порог соединений: ${CYAN}$AUTOBAN_CONN_THRESHOLD${NC}"
        echo -e "  9) Порог запросов/мин: ${CYAN}$AUTOBAN_RATE_THRESHOLD${NC}"
        echo -e "  t) Время бана: ${CYAN}${AUTOBAN_TIME}s${NC}"
        
        echo ""
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Номер параметра для изменения: " choice
        
        case $choice in
            1)
                read -p "Новый лимит соединений (глобальный): " val
                save_l7_param "CONN_LIMIT_GLOBAL" "$val"
                ;;
            2)
                read -p "Новый лимит соединений (VPN): " val
                save_l7_param "CONN_LIMIT_VPN" "$val"
                ;;
            3)
                read -p "Новый лимит соединений (SSH): " val
                save_l7_param "CONN_LIMIT_SSH" "$val"
                ;;
            4)
                read -p "Новый лимит соединений (HTTP): " val
                save_l7_param "CONN_LIMIT_HTTP" "$val"
                ;;
            5)
                read -p "Rate limit глобальный (напр. 50/s): " val
                save_l7_param "RATE_LIMIT_GLOBAL" "$val"
                ;;
            6)
                read -p "Rate limit VPN (напр. 100/s): " val
                save_l7_param "RATE_LIMIT_VPN" "$val"
                ;;
            7)
                read -p "Rate limit HTTP (напр. 30/s): " val
                save_l7_param "RATE_LIMIT_HTTP" "$val"
                ;;
            8)
                read -p "Порог для auto-ban (соединений): " val
                save_l7_param "AUTOBAN_CONN_THRESHOLD" "$val"
                ;;
            9)
                read -p "Порог для auto-ban (запросов/мин): " val
                save_l7_param "AUTOBAN_RATE_THRESHOLD" "$val"
                ;;
            t|T)
                read -p "Время бана (секунд): " val
                save_l7_param "AUTOBAN_TIME" "$val"
                ;;
            0) 
                # Спрашиваем нужно ли применить изменения
                if [[ "$L7_ENABLED" == "true" ]]; then
                    echo ""
                    echo -ne "    ${YELLOW}Применить изменения? [y/N]:${NC} "
                    read -r apply
                    if [[ "${apply,,}" == "y" ]]; then
                        reload_l7
                    else
                        echo -e "    ${DIM}Изменения сохранены, перезагрузите вручную${NC}"
                        sleep 1
                    fi
                fi
                return 
                ;;
        esac
        
        press_any_key
    done
}

# Главное меню L7 Shield
l7_menu() {
    init_l7_config
    
    while true; do
        print_header_mini "DDoS Protection"
        
        load_l7_config
        
        local backend=$(detect_firewall)
        
        # Статус блок - универсальный для обоих backends
        local blacklist_count=0
        local autoban_count=0
        
        if [[ "$backend" == "nftables" ]]; then
            blacklist_count=$(nft_list_set "blacklist" 2>/dev/null | wc -l || echo 0)
            autoban_count=$(nft_list_set "autoban" 2>/dev/null | wc -l || echo 0)
        else
            blacklist_count=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
            autoban_count=$(ipset list "$IPSET_AUTOBAN" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        fi
        
        local total_conn=$(ss -tn state established 2>/dev/null | wc -l || echo 0)
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        if [[ "$L7_ENABLED" == "true" ]]; then
            echo -e "    ${DIM}│${NC} Status: ${GREEN}● ACTIVE${NC}  Backend: ${CYAN}$backend${NC}               ${DIM}│${NC}"
        else
            echo -e "    ${DIM}│${NC} Status: ${RED}○ DISABLED${NC}                                  ${DIM}│${NC}"
        fi
        echo -e "    ${DIM}│${NC} Blacklist: ${RED}$blacklist_count${NC}  Auto-ban: ${YELLOW}$autoban_count${NC}  Conn: ${CYAN}$total_conn${NC}     ${DIM}│${NC}"
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Полный статус"
        menu_item "2" "Топ атакующих (live)"
        menu_divider
        
        if [[ "$L7_ENABLED" == "true" ]]; then
            echo -e "    ${RED}[3]${NC} ${RED}Выключить защиту${NC}"
            menu_item "4" "Перезагрузить правила"
        else
            echo -e "    ${GREEN}[3]${NC} ${GREEN}Включить защиту${NC}"
        fi
        
        menu_divider
        menu_item "5" "VPN порты (исключения)"
        menu_item "6" "IP Blacklist"
        menu_item "7" "IP Whitelist"
        menu_item "8" "GeoIP блокировка"
        menu_item "9" "Настройка лимитов"
        menu_divider
        menu_item "n" "Nginx защита"
        menu_item "f" "Fail2Ban L7"
        menu_item "b" "Firewall Backend ($backend)"
        menu_item "g" "GitHub IP Sync"
        menu_item "l" "Логи банов"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1) 
                show_l7_status 
                press_any_key
                ;;
            2) 
                show_top_attackers 
                press_any_key
                ;;
            3)
                if [[ "$L7_ENABLED" == "true" ]]; then
                    if confirm_action "Выключить DDoS защиту?" "n"; then
                        disable_l7
                    fi
                else
                    enable_l7
                fi
                press_any_key
                ;;
            4)
                [[ "$L7_ENABLED" == "true" ]] && reload_l7
                press_any_key
                ;;
            5) vpn_ports_menu ;;
            6) blacklist_menu ;;
            7) whitelist_menu ;;
            8) geoip_menu ;;
            9) limits_menu ;;
            n) nginx_menu ;;
            f) fail2ban_l7_menu ;;
            b) firewall_backend_menu ;;
            g) github_sync_menu ;;
            l)
                echo ""
                if [[ -f "$L7_BAN_LOG" ]]; then
                    echo -e "    ${WHITE}Последние 30 банов:${NC}"
                    echo ""
                    tail -30 "$L7_BAN_LOG" | while read line; do
                        echo "    $line"
                    done
                else
                    log_warn "Логов пока нет"
                fi
                press_any_key
                ;;
            0|q) return ;;
            *)
                # Пустой ввод или неверный - просто обновляем меню
                ;;
        esac
    done
}

# ============================================
# FAIL2BAN L7 ИНТЕГРАЦИЯ (ENHANCED)
# ============================================

L7_F2B_JAIL="/etc/fail2ban/jail.d/l7shield.conf"
L7_F2B_FILTER_404="/etc/fail2ban/filter.d/l7-404.conf"
L7_F2B_FILTER_429="/etc/fail2ban/filter.d/l7-429.conf"
L7_F2B_FILTER_SCAN="/etc/fail2ban/filter.d/l7-scanner.conf"
L7_F2B_FILTER_FLOOD="/etc/fail2ban/filter.d/l7-flood.conf"
L7_F2B_FILTER_BADBOTS="/etc/fail2ban/filter.d/l7-badbots.conf"
L7_F2B_ACTION_IPSET="/etc/fail2ban/action.d/l7-ipset.conf"

# Создать Fail2Ban фильтры и jails для L7
setup_fail2ban_l7() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_error "Fail2Ban не установлен"
        echo ""
        echo -e "${YELLOW}Установите: apt install fail2ban${NC}"
        return 1
    fi
    
    log_step "Настройка Fail2Ban L7 защиты (Enhanced)..."
    
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
    
    # ==========================================
    # Фильтр: 404 ошибки (сканеры)
    # ==========================================
    cat > "$L7_F2B_FILTER_404" << 'FILTER'
# L7 Shield - Блокировка сканеров по 404
# 2 ошибки 404 = бан

[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH) [^"]*" 404
            ^<HOST> - - \[.*\] "[A-Z]+ [^"]*" 404

ignoreregex = \.(css|js|png|jpg|jpeg|gif|ico|woff|woff2|ttf|svg|map)
              /favicon\.ico
              /robots\.txt
              /sitemap\.xml
FILTER

    # ==========================================
    # Фильтр: 429 ошибки (rate limit exceeded)
    # ==========================================
    cat > "$L7_F2B_FILTER_429" << 'FILTER'
# L7 Shield - Блокировка при превышении rate limit
# Кто получил 429 — значит уже атакует

[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH) [^"]*" 429
            ^<HOST> - - \[.*\] "[A-Z]+ [^"]*" 429
            limiting requests, excess: .* by zone .* client: <HOST>
            delaying request, excess: .* by zone .* client: <HOST>

ignoreregex =
FILTER

    # ==========================================
    # Фильтр: Сканеры (подозрительные URI)
    # ==========================================
    cat > "$L7_F2B_FILTER_SCAN" << 'FILTER'
# L7 Shield - Блокировка сканеров по подозрительным URI

[Definition]
failregex = ^<HOST> .* "(GET|POST) .*\.(php|asp|aspx|jsp|cgi)[^"]*"
            ^<HOST> .* "(GET|POST) .*(\.env|\.git|\.svn|\.htaccess|\.htpasswd)[^"]*"
            ^<HOST> .* "(GET|POST) .*(wp-admin|wp-login|wp-content|wp-includes|xmlrpc\.php)[^"]*"
            ^<HOST> .* "(GET|POST) .*(phpmyadmin|pma|adminer|mysql)[^"]*"
            ^<HOST> .* "(GET|POST) .*(shell|eval|exec|system|passthru|base64)[^"]*"
            ^<HOST> .* "(GET|POST) .*(\.\./|\.\.\\\\)[^"]*"
            ^<HOST> .* "(GET|POST) .*(\.sql|\.bak|\.backup|\.old|\.config|\.ini|\.log)[^"]*"

ignoreregex =
FILTER

    # ==========================================
    # Фильтр: HTTP Flood (много запросов)
    # ==========================================
    cat > "$L7_F2B_FILTER_FLOOD" << 'FILTER'
# L7 Shield - Защита от HTTP Flood
# Слишком много запросов за короткое время

[Definition]
# Считаем все успешные запросы (200-399)
# Если слишком много - бан
failregex = ^<HOST> - - \[.*\] "[A-Z]+ [^"]*" [23]\d{2}

ignoreregex =
FILTER

    # ==========================================
    # Фильтр: Bad Bots по User-Agent
    # ==========================================
    cat > "$L7_F2B_FILTER_BADBOTS" << 'FILTER'
# L7 Shield - Блокировка bad bots по User-Agent

[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD) [^"]*" \d+ \d+ "[^"]*" "(|-)$
            ^<HOST> .* "(GET|POST|HEAD) [^"]*" \d+ \d+ "[^"]*" ".*(bot|crawl|spider|scanner|nikto|sqlmap|nmap|masscan|zgrab|gobuster|dirbuster|wpscan|acunetix|nessus|openvas|w3af|burp).*"

ignoreregex = Googlebot
              Bingbot
              Yandex
              baiduspider
              DuckDuckBot
FILTER

    # ==========================================
    # Action: добавление в ipset (синхронизация с L7 Shield)
    # ==========================================
    cat > "$L7_F2B_ACTION_IPSET" << 'ACTION'
# L7 Shield - Добавление в ipset для синхронизации

[Definition]
actionstart = ipset create <ipset_name> hash:ip timeout <bantime> -exist

actionstop = 

actioncheck = 

actionban = ipset add <ipset_name> <ip> timeout <bantime> -exist

actionunban = ipset del <ipset_name> <ip> -exist

[Init]
ipset_name = l7_autoban
ACTION

    # ==========================================
    # Jail конфигурация (Enhanced)
    # ==========================================
    cat > "$L7_F2B_JAIL" << JAIL
# ================================================
# L7 Shield - Fail2Ban Jails (Enhanced)
# Server Security Shield
# ================================================

# Блокировка сканеров по 404 ошибкам
# 2 ошибки за 1 минуту = бан на 10 минут
[l7-404]
enabled = true
port = http,https
filter = l7-404
logpath = /var/log/nginx/access.log
          /var/log/nginx/*access*.log
maxretry = 2
findtime = 60
bantime = 600
action = iptables-multiport[name=l7-404, port="http,https", protocol=tcp]
         l7-ipset[ipset_name=l7_autoban, bantime=600]

# Блокировка при превышении rate limit
# 3 ошибки 429 = бан на 30 минут
[l7-429]
enabled = true
port = http,https
filter = l7-429
logpath = /var/log/nginx/access.log
          /var/log/nginx/error.log
          /var/log/nginx/*access*.log
          /var/log/nginx/*error*.log
maxretry = 3
findtime = 60
bantime = 1800
action = iptables-multiport[name=l7-429, port="http,https", protocol=tcp]
         l7-ipset[ipset_name=l7_autoban, bantime=1800]

# Блокировка сканеров (подозрительные URI)
# 1 попытка = бан на 1 час
[l7-scanner]
enabled = true
port = http,https
filter = l7-scanner
logpath = /var/log/nginx/access.log
          /var/log/nginx/*access*.log
maxretry = 1
findtime = 60
bantime = 3600
action = iptables-multiport[name=l7-scanner, port="http,https", protocol=tcp]
         l7-ipset[ipset_name=l7_autoban, bantime=3600]

# HTTP Flood защита
# 500 запросов за 30 сек = бан на 15 минут
[l7-flood]
enabled = true
port = http,https
filter = l7-flood
logpath = /var/log/nginx/access.log
          /var/log/nginx/*access*.log
maxretry = 500
findtime = 30
bantime = 900
action = iptables-multiport[name=l7-flood, port="http,https", protocol=tcp]
         l7-ipset[ipset_name=l7_autoban, bantime=900]

# Bad Bots по User-Agent
# 1 запрос с плохим UA = бан на 24 часа
[l7-badbots]
enabled = true
port = http,https
filter = l7-badbots
logpath = /var/log/nginx/access.log
          /var/log/nginx/*access*.log
maxretry = 1
findtime = 60
bantime = 86400
action = iptables-multiport[name=l7-badbots, port="http,https", protocol=tcp]
         l7-ipset[ipset_name=l7_autoban, bantime=86400]
JAIL

    # Перезагружаем Fail2Ban
    log_step "Перезагрузка Fail2Ban..."
    
    if fail2ban-client reload 2>&1; then
        echo ""
        log_info "Fail2Ban L7 защита (Enhanced) активирована!"
        echo ""
        echo -e "${WHITE}Созданные jails:${NC}"
        echo -e "  ${GREEN}●${NC} l7-404     — 2× 404 ошибки = бан 10 мин"
        echo -e "  ${GREEN}●${NC} l7-429     — 3× 429 ошибки = бан 30 мин"
        echo -e "  ${GREEN}●${NC} l7-scanner — 1× сканер URI = бан 1 час"
        echo -e "  ${GREEN}●${NC} l7-flood   — 500 req/30s = бан 15 мин"
        echo -e "  ${GREEN}●${NC} l7-badbots — bad UA = бан 24 часа"
        echo ""
        echo -e "${CYAN}Все баны автоматически синхронизируются с ipset!${NC}"
    else
        log_error "Ошибка перезагрузки Fail2Ban"
        return 1
    fi
}

# Показать статус Fail2Ban L7 jails
show_fail2ban_l7_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_error "Fail2Ban не установлен"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Fail2Ban L7 Jails:${NC}"
    echo ""
    
    for jail in l7-404 l7-429 l7-scanner l7-flood l7-badbots; do
        local status=$(fail2ban-client status "$jail" 2>/dev/null)
        
        if [[ -n "$status" ]]; then
            local currently=$(echo "$status" | grep "Currently banned" | awk '{print $NF}')
            local total=$(echo "$status" | grep "Total banned" | awk '{print $NF}')
            echo -e "  ${GREEN}●${NC} $jail: забанено ${RED}$currently${NC} (всего: $total)"
        else
            echo -e "  ${RED}○${NC} $jail: не активен"
        fi
    done
    
    echo ""
}

# Список забаненных IP в L7 jails
show_fail2ban_l7_banned() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_error "Fail2Ban не установлен"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Забаненные IP (L7 Shield):${NC}"
    echo ""
    
    for jail in l7-404 l7-429 l7-scanner l7-flood l7-badbots; do
        local banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | cut -d: -f2)
        
        if [[ -n "$banned" && "$banned" != " " ]]; then
            echo -e "  ${CYAN}[$jail]${NC}"
            for ip in $banned; do
                echo -e "    ${RED}$ip${NC}"
            done
        fi
    done
    
    echo ""
}

# Разбанить IP в L7 jails
unban_ip_l7() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        read -p "IP для разбана: " ip
    fi
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    for jail in l7-404 l7-429 l7-scanner l7-flood l7-badbots; do
        fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null && \
            echo -e "  ${GREEN}✓${NC} Разбанен в $jail: $ip"
    done
    
    # Также удаляем из ipset
    ipset del l7_autoban "$ip" 2>/dev/null && \
        echo -e "  ${GREEN}✓${NC} Удалён из ipset l7_autoban: $ip"
}

# Удалить Fail2Ban L7 конфиги
remove_fail2ban_l7() {
    log_step "Удаление Fail2Ban L7 защиты..."
    
    # Останавливаем jails
    for jail in l7-404 l7-429 l7-scanner l7-flood l7-badbots; do
        fail2ban-client stop "$jail" 2>/dev/null
    done
    
    # Удаляем файлы
    rm -f "$L7_F2B_JAIL" "$L7_F2B_FILTER_404" "$L7_F2B_FILTER_429" "$L7_F2B_FILTER_SCAN"
    rm -f "$L7_F2B_FILTER_FLOOD" "$L7_F2B_FILTER_BADBOTS" "$L7_F2B_ACTION_IPSET"
    
    # Перезагружаем
    fail2ban-client reload 2>/dev/null
    
    log_info "Fail2Ban L7 защита удалена"
}

# Меню Fail2Ban L7
fail2ban_l7_menu() {
    while true; do
        print_header_mini "Fail2Ban L7 Protection"
        
        echo ""
        
        # Проверка Fail2Ban
        if ! command -v fail2ban-client &>/dev/null; then
            echo -e "    ${RED}✗${NC} Fail2Ban не установлен"
            echo ""
            echo -e "    ${YELLOW}Установите: apt install fail2ban${NC}"
            echo ""
            press_any_key
            return
        fi
        
        # Проверяем nginx
        if ! check_nginx_installed; then
            echo -e "    ${RED}✗${NC} Nginx не установлен"
            echo ""
            press_any_key
            return
        fi
        
        # Статус jails
        local any_active=false
        for jail in l7-404 l7-429 l7-scanner l7-flood l7-badbots; do
            fail2ban-client status "$jail" &>/dev/null && any_active=true
        done
        
        if [[ "$any_active" == "true" ]]; then
            show_fail2ban_l7_status
        else
            echo -e "    ${YELLOW}○${NC} L7 jails не настроены"
        fi
        
        echo ""
        print_divider
        echo ""
        
        menu_item "1" "Настроить Fail2Ban L7 защиту (Enhanced)"
        menu_item "2" "Статус jails"
        menu_item "3" "Список забаненных IP"
        menu_item "4" "Разбанить IP"
        menu_item "5" "Отключить L7 защиту"
        menu_divider
        menu_item "0" "Назад"
        
        echo ""
        print_divider
        echo -e "    ${WHITE}Что защищает (Enhanced):${NC}"
        echo -e "    ${DIM}• l7-404     — 2× 404 ошибки = бан 10 мин${NC}"
        echo -e "    ${DIM}• l7-429     — 3× 429 ошибки = бан 30 мин${NC}"
        echo -e "    ${DIM}• l7-scanner — 1× .php/.env = бан 1 час${NC}"
        echo -e "    ${DIM}• l7-flood   — 500 req/30s = бан 15 мин${NC}"
        echo -e "    ${DIM}• l7-badbots — bad UA = бан 24 часа${NC}"
        echo ""
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                setup_fail2ban_l7
                ;;
            2)
                show_fail2ban_l7_status
                ;;
            3)
                show_fail2ban_l7_banned
                ;;
            4)
                unban_ip_l7
                ;;
            5)
                if confirm_action "Отключить Fail2Ban L7 защиту?" "n"; then
                    remove_fail2ban_l7
                fi
                ;;
            0|q) return ;;
        esac
        
        press_any_key
    done
}

# Статус для главного меню
get_l7_status_line() {
    load_l7_config 2>/dev/null
    
    if [[ "$L7_ENABLED" == "true" ]]; then
        local autoban=$(ipset list "$IPSET_AUTOBAN" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        echo -e "${GREEN}●${NC} Banned: $autoban"
    else
        echo -e "${RED}○${NC}"
    fi
}

# ============================================
# JS CHALLENGE PAGE (BOT PROTECTION)
# ============================================

L7_JS_CHALLENGE_DIR="/var/www/l7shield"
L7_JS_CHALLENGE_CONF="/etc/nginx/conf.d/l7shield_challenge.conf"
L7_JS_CHALLENGE_HTML="$L7_JS_CHALLENGE_DIR/challenge.html"
L7_JS_VERIFIED_COOKIE="l7_verified"

# Создать JS Challenge страницу (как у Cloudflare "I'm Under Attack")
setup_js_challenge() {
    log_step "Настройка JS Challenge защиты..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    mkdir -p "$L7_JS_CHALLENGE_DIR"
    
    # Генерируем уникальный секретный ключ для HMAC
    local secret_key=$(openssl rand -hex 16)
    save_l7_param "JS_CHALLENGE_SECRET" "$secret_key"
    
    # HTML страница с JS проверкой
    cat > "$L7_JS_CHALLENGE_HTML" << 'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Проверка безопасности</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
        }
        .container {
            text-align: center;
            padding: 40px;
            background: rgba(255,255,255,0.05);
            border-radius: 20px;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.1);
            max-width: 400px;
        }
        .shield-icon {
            font-size: 64px;
            margin-bottom: 20px;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { transform: scale(1); }
            50% { transform: scale(1.1); }
        }
        h1 {
            font-size: 24px;
            margin-bottom: 10px;
            color: #4ecdc4;
        }
        p {
            color: #888;
            margin-bottom: 30px;
            font-size: 14px;
        }
        .loader {
            width: 50px;
            height: 50px;
            border: 3px solid rgba(78, 205, 196, 0.2);
            border-top-color: #4ecdc4;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin: 0 auto 20px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .status {
            font-size: 12px;
            color: #666;
        }
        .error {
            color: #ff6b6b;
            display: none;
        }
        noscript .container {
            border-color: #ff6b6b;
        }
    </style>
</head>
<body>
    <noscript>
        <div class="container">
            <div class="shield-icon">🚫</div>
            <h1>JavaScript отключен</h1>
            <p>Для доступа к сайту необходимо включить JavaScript в браузере.</p>
        </div>
    </noscript>
    <div class="container" id="main">
        <div class="shield-icon">🛡️</div>
        <h1>Проверка безопасности</h1>
        <p>Пожалуйста, подождите. Идёт проверка вашего браузера...</p>
        <div class="loader"></div>
        <div class="status" id="status">Вычисление...</div>
        <div class="error" id="error">Ошибка проверки. Попробуйте обновить страницу.</div>
    </div>
    <script>
        (function() {
            var startTime = Date.now();
            
            // Собираем fingerprint браузера
            function getFingerprint() {
                var fp = [];
                fp.push(navigator.userAgent);
                fp.push(navigator.language);
                fp.push(screen.width + 'x' + screen.height);
                fp.push(new Date().getTimezoneOffset());
                fp.push(navigator.hardwareConcurrency || 0);
                fp.push(navigator.deviceMemory || 0);
                fp.push(!!window.localStorage);
                fp.push(!!window.sessionStorage);
                fp.push(!!window.indexedDB);
                return fp.join('|');
            }
            
            // Простой хэш
            function simpleHash(str) {
                var hash = 0;
                for (var i = 0; i < str.length; i++) {
                    var char = str.charCodeAt(i);
                    hash = ((hash << 5) - hash) + char;
                    hash = hash & hash;
                }
                return Math.abs(hash).toString(16);
            }
            
            // Proof of Work (небольшая задержка для защиты от ботов)
            function proofOfWork(difficulty) {
                var nonce = 0;
                var target = '0'.repeat(difficulty);
                var data = getFingerprint() + startTime;
                
                while (true) {
                    var hash = simpleHash(data + nonce);
                    if (hash.startsWith(target)) {
                        return { nonce: nonce, hash: hash };
                    }
                    nonce++;
                    if (nonce > 100000) break;
                }
                return { nonce: nonce, hash: hash };
            }
            
            // Обновляем статус
            document.getElementById('status').textContent = 'Проверка браузера...';
            
            // Выполняем проверку с небольшой задержкой
            setTimeout(function() {
                try {
                    var pow = proofOfWork(2);
                    var token = simpleHash(getFingerprint() + pow.hash + pow.nonce);
                    var elapsed = Date.now() - startTime;
                    
                    document.getElementById('status').textContent = 'Верификация...';
                    
                    // Устанавливаем cookie и перенаправляем
                    var expires = new Date(Date.now() + 3600000).toUTCString();
                    document.cookie = 'l7_verified=' + token + '; path=/; expires=' + expires + '; SameSite=Strict';
                    document.cookie = 'l7_ts=' + startTime + '; path=/; expires=' + expires + '; SameSite=Strict';
                    
                    // Перенаправление
                    setTimeout(function() {
                        window.location.reload();
                    }, 500);
                } catch (e) {
                    document.getElementById('error').style.display = 'block';
                    document.getElementById('status').style.display = 'none';
                }
            }, 1500);
        })();
    </script>
</body>
</html>
HTML

    # Nginx конфиг для JS Challenge
    cat > "$L7_JS_CHALLENGE_CONF" << 'NGINX'
# ================================================
# L7 Shield - JS Challenge Configuration
# Server Security Shield
# ================================================

# Режим JS Challenge (0=off, 1=on, 2=under_attack)
map $l7_challenge_mode $l7_need_challenge {
    default 0;
    "on" 1;
    "under_attack" 1;
}

# Проверка cookie верификации
map $cookie_l7_verified $l7_is_verified {
    default 0;
    "~.+" 1;
}

# Комбинированная проверка: нужен challenge И не верифицирован
map "$l7_need_challenge:$l7_is_verified" $l7_do_challenge {
    default 0;
    "1:0" 1;
}

# Локация для challenge страницы
# Добавьте в ваш server блок:
# include /etc/nginx/conf.d/l7shield_challenge.conf;
#
# И добавьте в location /:
# if ($l7_do_challenge) {
#     return 503;
# }
# error_page 503 @challenge;

# location @challenge {
#     root /var/www/l7shield;
#     rewrite ^ /challenge.html break;
# }
NGINX

    log_info "JS Challenge страница создана!"
    echo ""
    echo -e "${WHITE}Файлы:${NC}"
    echo -e "  HTML: ${CYAN}$L7_JS_CHALLENGE_HTML${NC}"
    echo -e "  Nginx: ${CYAN}$L7_JS_CHALLENGE_CONF${NC}"
    echo ""
    echo -e "${YELLOW}Для активации добавьте в server блок nginx:${NC}"
    echo ""
    echo "  # В начале server блока:"
    echo "  set \$l7_challenge_mode \"off\";  # on | under_attack | off"
    echo ""
    echo "  # В location /:"
    echo "  if (\$l7_do_challenge) {"
    echo "      return 503;"
    echo "  }"
    echo "  error_page 503 @challenge;"
    echo ""
    echo "  # После всех location:"
    echo "  location @challenge {"
    echo "      root /var/www/l7shield;"
    echo "      rewrite ^ /challenge.html break;"
    echo "  }"
}

# Включить/выключить JS Challenge режим
toggle_js_challenge() {
    local mode="${1:-on}"
    
    echo ""
    echo -e "${WHITE}Режимы JS Challenge:${NC}"
    echo -e "  ${CYAN}off${NC}          — выключен"
    echo -e "  ${CYAN}on${NC}           — включен для всех"
    echo -e "  ${CYAN}under_attack${NC} — агрессивный режим"
    echo ""
    
    log_info "Режим JS Challenge: $mode"
    save_l7_param "JS_CHALLENGE_MODE" "$mode"
    
    echo ""
    echo -e "${YELLOW}Измените в nginx конфиге:${NC}"
    echo "  set \$l7_challenge_mode \"$mode\";"
    echo ""
    echo "И перезагрузите nginx: ${CYAN}nginx -s reload${NC}"
}

# ============================================
# API RATE LIMITING (строже для /api/)
# ============================================

L7_API_RATE_CONF="/etc/nginx/conf.d/l7shield_api.conf"

# Настройка строгих лимитов для API
setup_api_rate_limiting() {
    log_step "Настройка API Rate Limiting..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    # Читаем текущие настройки
    load_l7_config
    local api_rate="${API_RATE_LIMIT:-10r/s}"
    local api_burst="${API_BURST:-20}"
    local api_ban_time="${API_BAN_TIME:-300}"
    
    cat > "$L7_API_RATE_CONF" << NGINX
# ================================================
# L7 Shield - API Rate Limiting
# Строгие лимиты для /api/ эндпоинтов
# ================================================

# API rate limit zone (строже чем основной)
limit_req_zone \$l7_limit_key zone=l7_api_strict:30m rate=${api_rate};

# API burst zone для временных всплесков
limit_req_zone \$l7_limit_key zone=l7_api_burst:20m rate=2r/s;

# Лимит соединений для API
limit_conn_zone \$binary_remote_addr zone=l7_api_conn:20m;

# Переменная для определения API запросов
map \$request_uri \$is_api_request {
    default 0;
    ~^/api/ 1;
    ~^/v[0-9]+/ 1;
    ~^/graphql 1;
    ~^/webhook 1;
}

# Включите в location /api/ или location ~ ^/(api|v[0-9]+)/:
#
# limit_req zone=l7_api_strict burst=${api_burst} nodelay;
# limit_conn l7_api_conn 10;
#
# Для защиты от брутфорса авторизации:
# location ~ ^/api/(auth|login|register) {
#     limit_req zone=l7_api_burst burst=5 nodelay;
#     ...
# }
NGINX

    log_info "API Rate Limiting настроен!"
    echo ""
    echo -e "${WHITE}Файл:${NC} ${CYAN}$L7_API_RATE_CONF${NC}"
    echo ""
    echo -e "${WHITE}Текущие настройки:${NC}"
    echo -e "  API Rate: ${CYAN}$api_rate${NC}"
    echo -e "  API Burst: ${CYAN}$api_burst${NC}"
    echo ""
    echo -e "${YELLOW}Добавьте в location /api/:${NC}"
    echo "  limit_req zone=l7_api_strict burst=$api_burst nodelay;"
    echo "  limit_conn l7_api_conn 10;"
    
    # Перезагружаем nginx
    nginx -t 2>&1 && nginx -s reload 2>/dev/null
}

# Изменить лимиты API
configure_api_limits() {
    load_l7_config
    
    echo ""
    echo -e "${WHITE}Текущие настройки API:${NC}"
    echo -e "  1) Rate limit: ${CYAN}${API_RATE_LIMIT:-10r/s}${NC}"
    echo -e "  2) Burst: ${CYAN}${API_BURST:-20}${NC}"
    echo -e "  3) Ban time: ${CYAN}${API_BAN_TIME:-300}s${NC}"
    echo ""
    
    local choice
    input_value "Параметр для изменения (1-3)" "" choice
    
    case "$choice" in
        1)
            local val
            input_value "Новый rate limit (напр. 10r/s)" "${API_RATE_LIMIT:-10r/s}" val
            save_l7_param "API_RATE_LIMIT" "$val"
            ;;
        2)
            local val
            input_value "Новый burst" "${API_BURST:-20}" val
            save_l7_param "API_BURST" "$val"
            ;;
        3)
            local val
            input_value "Время бана (сек)" "${API_BAN_TIME:-300}" val
            save_l7_param "API_BAN_TIME" "$val"
            ;;
    esac
    
    # Пересоздаём конфиг
    setup_api_rate_limiting
}

# ============================================
# TARPIT MODE (замедление подозрительных)
# ============================================

L7_TARPIT_CONF="/etc/nginx/conf.d/l7shield_tarpit.conf"

# Настройка Tarpit режима
setup_tarpit_mode() {
    log_step "Настройка Tarpit Mode..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    load_l7_config
    local tarpit_delay="${TARPIT_DELAY:-5}"
    
    cat > "$L7_TARPIT_CONF" << NGINX
# ================================================
# L7 Shield - Tarpit Mode
# Замедление подозрительных запросов
# ================================================

# Определение подозрительных клиентов
# На основе количества 429 ошибок
map \$cookie_l7_tarpit \$l7_is_tarpitted {
    default 0;
    "~.+" 1;
}

# Счётчик запросов для tarpit
limit_req_zone \$binary_remote_addr zone=l7_tarpit_zone:10m rate=1r/s;

# Добавьте в server блок:
#
# # Tarpit для подозрительных
# location @tarpit {
#     # Искусственная задержка
#     echo_sleep ${tarpit_delay};
#     
#     # Или через proxy с задержкой
#     # proxy_connect_timeout ${tarpit_delay}s;
#     # proxy_read_timeout 60s;
#     # proxy_pass http://127.0.0.1:\$server_port;
#     
#     return 204;
# }
#
# # В основном location:
# if (\$l7_is_tarpitted) {
#     # Задержка ответа
#     set \$tarpit_delay ${tarpit_delay};
# }
NGINX

    log_info "Tarpit Mode настроен!"
    echo ""
    echo -e "${WHITE}Tarpit Mode:${NC}"
    echo -e "  Вместо блокировки — замедляем ответы"
    echo -e "  Подозрительные IP получают задержку ${CYAN}${tarpit_delay}s${NC}"
    echo ""
    echo -e "${WHITE}Это связывает ресурсы атакующего!${NC}"
    echo ""
    echo -e "${YELLOW}Для активации нужен модуль echo-nginx или lua-nginx${NC}"
    echo "  apt install libnginx-mod-http-echo"
}

# Изменить задержку tarpit
configure_tarpit() {
    load_l7_config
    
    local val
    input_value "Задержка tarpit (сек)" "${TARPIT_DELAY:-5}" val
    save_l7_param "TARPIT_DELAY" "$val"
    
    setup_tarpit_mode
}

# ============================================
# СИНХРОНИЗАЦИЯ IPSET <-> NGINX GEO
# ============================================

L7_NGINX_GEO_SYNC="/etc/nginx/conf.d/l7shield_geo_sync.conf"
L7_SYNC_SCRIPT="/opt/server-shield/scripts/l7-sync-blocklist.sh"

# Создать скрипт синхронизации
setup_blocklist_sync() {
    log_step "Настройка синхронизации blocklist..."
    
    mkdir -p "$(dirname "$L7_SYNC_SCRIPT")"
    
    cat > "$L7_SYNC_SCRIPT" << 'SCRIPT'
#!/bin/bash
#
# L7 Shield - Синхронизация ipset <-> nginx geo blocklist
# Запускается по cron каждые 12 часов
#

IPSET_BLACKLIST="l7_blacklist"
IPSET_AUTOBAN="l7_autoban"
NGINX_GEO_FILE="/etc/nginx/conf.d/l7shield_geo_blocklist.conf"
TEMP_FILE="/tmp/l7_geo_sync.tmp"
LOG_FILE="/opt/server-shield/logs/l7_sync.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Собираем все IP из ipset
collect_ips() {
    {
        ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep "^[0-9]"
        ipset list "$IPSET_AUTOBAN" 2>/dev/null | grep "^[0-9]"
    } | sort -u
}

# Генерируем nginx geo файл
generate_nginx_geo() {
    local ips="$1"
    local count=$(echo "$ips" | grep -c "^[0-9]" || echo 0)
    
    cat > "$TEMP_FILE" << EOF
# ================================================
# L7 Shield - Auto-generated Blocklist
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# IPs: $count
# ================================================

geo \$l7_blocked_ip {
    default 0;
EOF
    
    echo "$ips" | while read -r ip; do
        [[ -n "$ip" ]] && echo "    $ip 1;" >> "$TEMP_FILE"
    done
    
    echo "}" >> "$TEMP_FILE"
    
    # Проверяем синтаксис и применяем
    if nginx -t -c /etc/nginx/nginx.conf 2>/dev/null; then
        mv "$TEMP_FILE" "$NGINX_GEO_FILE"
        nginx -s reload 2>/dev/null
        log "Синхронизировано: $count IP"
    else
        log "ERROR: nginx config invalid"
        rm -f "$TEMP_FILE"
    fi
}

# Основная логика
main() {
    local ips=$(collect_ips)
    local new_count=$(echo "$ips" | grep -c "^[0-9]" || echo 0)
    
    # Проверяем изменились ли IP
    local old_count=0
    if [[ -f "$NGINX_GEO_FILE" ]]; then
        old_count=$(grep -c "1;$" "$NGINX_GEO_FILE" 2>/dev/null || echo 0)
    fi
    
    if [[ "$new_count" != "$old_count" ]]; then
        generate_nginx_geo "$ips"
    fi
}

main
SCRIPT

    chmod +x "$L7_SYNC_SCRIPT"
    
    # Добавляем в cron
    local cron_line="0 */12 * * * root $L7_SYNC_SCRIPT"
    if ! grep -q "l7-sync-blocklist" "$L7_CRON" 2>/dev/null; then
        echo "$cron_line" >> "$L7_CRON"
    fi
    
    # Первый запуск
    "$L7_SYNC_SCRIPT"
    
    log_info "Синхронизация blocklist настроена!"
    echo ""
    echo -e "${WHITE}Синхронизация:${NC}"
    echo -e "  ipset blacklist/autoban → nginx geo blocklist"
    echo -e "  Интервал: каждые 12 часов"
    echo ""
    echo -e "${WHITE}Скрипт:${NC} ${CYAN}$L7_SYNC_SCRIPT${NC}"
    echo ""
    echo -e "${YELLOW}Добавьте в nginx server блок:${NC}"
    echo "  if (\$l7_blocked_ip) {"
    echo "      return 444;"
    echo "  }"
}

# Принудительная синхронизация
force_blocklist_sync() {
    if [[ -f "$L7_SYNC_SCRIPT" ]]; then
        log_step "Синхронизация blocklist..."
        "$L7_SYNC_SCRIPT"
        log_info "Синхронизация завершена"
    else
        log_error "Скрипт синхронизации не найден"
        echo "Запустите настройку: Nginx защита → Синхронизация blocklist"
    fi
}

# ============================================
# РАСШИРЕННОЕ МЕНЮ NGINX
# ============================================

nginx_menu() {
    while true; do
        print_header_mini "Nginx Protection"
        
        # Проверка nginx
        if ! check_nginx_installed; then
            echo ""
            log_error "Nginx не установлен!"
            echo ""
            echo -e "  ${YELLOW}Установите: apt install nginx${NC}"
            echo ""
            press_any_key
            return
        fi
        
        # Статус конфигов
        echo ""
        echo -e "    ${WHITE}Статус конфигураций:${NC}"
        echo ""
        
        [[ -f "$L7_NGINX_CONF" ]] && \
            show_status_line "Rate Limiting" "on" || \
            show_status_line "Rate Limiting" "off"
        
        [[ -f "$L7_NGINX_MAPS" ]] && \
            show_status_line "Bad Bots/URI блокировка" "on" || \
            show_status_line "Bad Bots/URI блокировка" "off"
        
        [[ -f "$L7_JS_CHALLENGE_HTML" ]] && \
            show_status_line "JS Challenge Page" "on" || \
            show_status_line "JS Challenge Page" "off"
        
        [[ -f "$L7_API_RATE_CONF" ]] && \
            show_status_line "API Rate Limiting" "on" || \
            show_status_line "API Rate Limiting" "off"
        
        [[ -f "$L7_TARPIT_CONF" ]] && \
            show_status_line "Tarpit Mode" "on" || \
            show_status_line "Tarpit Mode" "off"
        
        [[ -f "$L7_SYNC_SCRIPT" ]] && \
            show_status_line "Blocklist Sync" "on" || \
            show_status_line "Blocklist Sync" "off"
        
        echo ""
        print_divider
        echo ""
        
        menu_item "1" "Создать базовые конфиги"
        menu_item "2" "Показать сниппет для server блока"
        menu_divider
        menu_item "3" "JS Challenge Page (защита от ботов)"
        menu_item "4" "API Rate Limiting (строже для /api/)"
        menu_item "5" "Tarpit Mode (замедление атакующих)"
        menu_item "6" "Синхронизация blocklist"
        menu_divider
        menu_item "7" "Применить защиту к сайту"
        menu_item "8" "Пути nginx конфигов"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                create_nginx_config
                press_any_key
                ;;
            2)
                show_nginx_snippet
                press_any_key
                ;;
            3)
                echo ""
                menu_item "a" "Настроить JS Challenge"
                menu_item "b" "Включить режим"
                menu_item "c" "Выключить режим"
                
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_js_challenge ;;
                    b) toggle_js_challenge "on" ;;
                    c) toggle_js_challenge "off" ;;
                esac
                press_any_key
                ;;
            4)
                echo ""
                menu_item "a" "Настроить API Rate Limiting"
                menu_item "b" "Изменить лимиты"
                
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_api_rate_limiting ;;
                    b) configure_api_limits ;;
                esac
                press_any_key
                ;;
            5)
                echo ""
                menu_item "a" "Настроить Tarpit Mode"
                menu_item "b" "Изменить задержку"
                
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_tarpit_mode ;;
                    b) configure_tarpit ;;
                esac
                press_any_key
                ;;
            6)
                echo ""
                menu_item "a" "Настроить синхронизацию"
                menu_item "b" "Синхронизировать сейчас"
                
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_blocklist_sync ;;
                    b) force_blocklist_sync ;;
                esac
                press_any_key
                ;;
            7)
                apply_nginx_protection
                press_any_key
                ;;
            8)
                nginx_paths_menu
                ;;
            0|q) return ;;
        esac
    done
}

# Меню путей nginx
nginx_paths_menu() {
    while true; do
        print_header_mini "Пути Nginx конфигов"
        
        echo ""
        echo -e "    ${WHITE}Найденные пути:${NC}"
        echo ""
        
        local i=1
        while IFS= read -r path; do
            echo -e "    ${CYAN}$i)${NC} $path"
            ((i++))
        done < <(get_nginx_config_paths)
        
        echo ""
        print_divider
        echo ""
        
        menu_item "a" "Добавить кастомный путь"
        menu_item "s" "Сканировать VPN панели"
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            a)
                local path
                input_value "Путь к директории nginx" "" path
                [[ -n "$path" ]] && add_nginx_custom_path "$path"
                press_any_key
                ;;
            s)
                log_step "Поиск VPN панелей..."
                local found=0
                for vpath in /opt/remnawave /opt/marzban /opt/x-ui /opt/3x-ui /opt/hiddify /root/remnawave /root/marzban; do
                    if [[ -d "$vpath" ]]; then
                        log_info "Найдено: $vpath"
                        ((found++))
                    fi
                done
                [[ $found -eq 0 ]] && log_warn "VPN панели не найдены"
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# ============================================
# P1: CLOUDFLARE REAL IP SUPPORT
# ============================================

L7_CLOUDFLARE_CONF="/etc/nginx/conf.d/l7shield_cloudflare.conf"

# Настройка Cloudflare Real IP
setup_cloudflare_realip() {
    log_step "Настройка Cloudflare Real IP..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    # Получаем актуальные IP диапазоны Cloudflare
    log_step "Загрузка IP диапазонов Cloudflare..."
    
    local cf_ipv4=$(curl -s https://www.cloudflare.com/ips-v4 2>/dev/null)
    local cf_ipv6=$(curl -s https://www.cloudflare.com/ips-v6 2>/dev/null)
    
    if [[ -z "$cf_ipv4" ]]; then
        log_warn "Не удалось загрузить IP Cloudflare, используем кэшированные"
        cf_ipv4="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
    fi
    
    cat > "$L7_CLOUDFLARE_CONF" << NGINX
# ================================================
# L7 Shield - Cloudflare Real IP Support
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ================================================

# Cloudflare IPv4 ranges
NGINX

    echo "$cf_ipv4" | while read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from $ip;" >> "$L7_CLOUDFLARE_CONF"
    done
    
    if [[ -n "$cf_ipv6" ]]; then
        echo "" >> "$L7_CLOUDFLARE_CONF"
        echo "# Cloudflare IPv6 ranges" >> "$L7_CLOUDFLARE_CONF"
        echo "$cf_ipv6" | while read -r ip; do
            [[ -n "$ip" ]] && echo "set_real_ip_from $ip;" >> "$L7_CLOUDFLARE_CONF"
        done
    fi
    
    cat >> "$L7_CLOUDFLARE_CONF" << 'NGINX'

# Заголовок с реальным IP
real_ip_header CF-Connecting-IP;

# Рекурсивный поиск (для нескольких прокси)
real_ip_recursive on;

# Также поддержка X-Forwarded-For (для других CDN)
# real_ip_header X-Forwarded-For;

# Переменная для логирования реального IP
# Используйте $realip_remote_addr в log_format
NGINX

    # Проверяем и перезагружаем nginx
    if nginx -t 2>&1; then
        nginx -s reload 2>/dev/null
        log_info "Cloudflare Real IP настроен!"
        echo ""
        echo -e "${WHITE}Файл:${NC} ${CYAN}$L7_CLOUDFLARE_CONF${NC}"
        echo ""
        echo -e "${WHITE}Теперь nginx будет видеть реальные IP посетителей за Cloudflare${NC}"
        echo ""
        echo -e "${YELLOW}Рекомендация:${NC} Обновите log_format для использования \$realip_remote_addr"
    else
        log_error "Ошибка в nginx конфиге"
        nginx -t
        rm -f "$L7_CLOUDFLARE_CONF"
        return 1
    fi
}

# Обновить IP диапазоны Cloudflare
update_cloudflare_ips() {
    log_step "Обновление IP диапазонов Cloudflare..."
    setup_cloudflare_realip
}

# Удалить Cloudflare конфиг
remove_cloudflare_realip() {
    if [[ -f "$L7_CLOUDFLARE_CONF" ]]; then
        rm -f "$L7_CLOUDFLARE_CONF"
        nginx -s reload 2>/dev/null
        log_info "Cloudflare Real IP удалён"
    else
        log_warn "Конфиг не найден"
    fi
}

# ============================================
# P1: HTTP/2 ATTACK PROTECTION
# ============================================

L7_HTTP2_CONF="/etc/nginx/conf.d/l7shield_http2.conf"

# Настройка HTTP/2 защиты
setup_http2_protection() {
    log_step "Настройка HTTP/2 Attack Protection..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    cat > "$L7_HTTP2_CONF" << 'NGINX'
# ================================================
# L7 Shield - HTTP/2 Attack Protection
# Защита от HTTP/2 специфичных атак
# ================================================

# === HTTP/2 Rapid Reset Attack (CVE-2023-44487) ===
# Ограничение количества concurrent streams
http2_max_concurrent_streams 100;

# Ограничение размера заголовков
http2_max_header_size 16k;
http2_max_field_size 8k;

# Таймауты HTTP/2
http2_recv_timeout 30s;
http2_idle_timeout 180s;

# === HTTP/2 HPACK Bomb Protection ===
# Ограничение размера таблицы сжатия
http2_chunk_size 8k;

# === HTTP/2 Slow Read Attack ===
# Минимальная скорость чтения
http2_body_preread_size 64k;

# === Общие ограничения ===
# Максимальный размер буфера
http2_recv_buffer_size 256k;

# Количество запросов в одном соединении
http2_max_requests 1000;

# === Large Header Attack Protection ===
large_client_header_buffers 4 8k;

# === Connection Flood Protection ===
# Ограничение keepalive соединений
keepalive_requests 100;
keepalive_timeout 65s;

# === Request Smuggling Protection ===
ignore_invalid_headers on;
underscores_in_headers off;
NGINX

    # Проверяем и перезагружаем nginx
    if nginx -t 2>&1; then
        nginx -s reload 2>/dev/null
        log_info "HTTP/2 Attack Protection настроен!"
        echo ""
        echo -e "${WHITE}Защита от:${NC}"
        echo -e "  ${GREEN}●${NC} HTTP/2 Rapid Reset Attack (CVE-2023-44487)"
        echo -e "  ${GREEN}●${NC} HPACK Bomb"
        echo -e "  ${GREEN}●${NC} HTTP/2 Slow Read"
        echo -e "  ${GREEN}●${NC} Large Header Attack"
        echo -e "  ${GREEN}●${NC} Request Smuggling"
    else
        log_error "Ошибка в nginx конфиге"
        nginx -t
        rm -f "$L7_HTTP2_CONF"
        return 1
    fi
}

# Удалить HTTP/2 защиту
remove_http2_protection() {
    if [[ -f "$L7_HTTP2_CONF" ]]; then
        rm -f "$L7_HTTP2_CONF"
        nginx -s reload 2>/dev/null
        log_info "HTTP/2 защита удалена"
    else
        log_warn "Конфиг не найден"
    fi
}

# ============================================
# P1: REQUEST BODY INSPECTION (WAF)
# ============================================

L7_WAF_CONF="/etc/nginx/conf.d/l7shield_waf.conf"
L7_WAF_RULES="/etc/nginx/l7shield_waf_rules.conf"

# Настройка базового WAF
setup_waf_protection() {
    log_step "Настройка WAF (Request Body Inspection)..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    # Основной конфиг WAF
    cat > "$L7_WAF_CONF" << 'NGINX'
# ================================================
# L7 Shield - Basic WAF (Request Body Inspection)
# Базовая проверка POST данных на инъекции
# ================================================

# Максимальный размер тела запроса для инспекции
client_max_body_size 10m;
client_body_buffer_size 128k;

# Включаем буферизацию тела запроса для проверки
client_body_in_single_buffer on;

# Timeout для получения тела
client_body_timeout 30s;
NGINX

    # Правила WAF (для использования в location)
    cat > "$L7_WAF_RULES" << 'NGINX'
# ================================================
# L7 Shield - WAF Rules
# Включите в location: include /etc/nginx/l7shield_waf_rules.conf;
# ================================================

# === SQL Injection Protection ===
set $waf_block 0;

# SQL keywords в аргументах
if ($args ~* "(union|select|insert|update|delete|drop|truncate|alter|exec|execute|xp_|sp_|0x)" ) {
    set $waf_block 1;
}

# SQL injection patterns
if ($args ~* "('|\")(.*)(--|#|/\*)" ) {
    set $waf_block 1;
}

# === XSS Protection ===
if ($args ~* "(<script|javascript:|vbscript:|onclick|onerror|onload|onmouseover)" ) {
    set $waf_block 1;
}

if ($args ~* "(document\.|window\.|eval\(|alert\(|prompt\(|confirm\()" ) {
    set $waf_block 1;
}

# === Path Traversal Protection ===
if ($args ~* "(\.\./|\.\.\\\\|%2e%2e%2f|%252e%252e%252f)" ) {
    set $waf_block 1;
}

if ($request_uri ~* "(\.\./|\.\.\\\\)" ) {
    set $waf_block 1;
}

# === Command Injection Protection ===
if ($args ~* "(;|\||`|\$\(|%0a|%0d)" ) {
    set $waf_block 1;
}

if ($args ~* "(cat%20|ls%20|wget%20|curl%20|bash|/bin/|/etc/passwd)" ) {
    set $waf_block 1;
}

# === File Inclusion Protection ===
if ($args ~* "(file://|php://|zip://|data://|expect://|input://)" ) {
    set $waf_block 1;
}

# === SSRF Protection ===
if ($args ~* "(127\.0\.0\.1|localhost|169\.254\.|10\.|172\.16\.|192\.168\.)" ) {
    set $waf_block 1;
}

# === Block if WAF triggered ===
if ($waf_block = 1) {
    return 403;
}
NGINX

    # Проверяем nginx
    if nginx -t 2>&1; then
        nginx -s reload 2>/dev/null
        log_info "WAF Protection настроен!"
        echo ""
        echo -e "${WHITE}Файлы:${NC}"
        echo -e "  ${CYAN}$L7_WAF_CONF${NC}"
        echo -e "  ${CYAN}$L7_WAF_RULES${NC}"
        echo ""
        echo -e "${WHITE}Защита от:${NC}"
        echo -e "  ${GREEN}●${NC} SQL Injection"
        echo -e "  ${GREEN}●${NC} XSS (Cross-Site Scripting)"
        echo -e "  ${GREEN}●${NC} Path Traversal"
        echo -e "  ${GREEN}●${NC} Command Injection"
        echo -e "  ${GREEN}●${NC} File Inclusion (LFI/RFI)"
        echo -e "  ${GREEN}●${NC} SSRF"
        echo ""
        echo -e "${YELLOW}Для активации добавьте в location:${NC}"
        echo "  include /etc/nginx/l7shield_waf_rules.conf;"
    else
        log_error "Ошибка в nginx конфиге"
        nginx -t
        rm -f "$L7_WAF_CONF" "$L7_WAF_RULES"
        return 1
    fi
}

# Удалить WAF
remove_waf_protection() {
    rm -f "$L7_WAF_CONF" "$L7_WAF_RULES"
    nginx -s reload 2>/dev/null
    log_info "WAF защита удалена"
}

# Тест WAF правил
test_waf_rules() {
    echo ""
    echo -e "${WHITE}Тестирование WAF правил...${NC}"
    echo ""
    
    local base_url="http://localhost"
    local tests=(
        "?id=1' OR '1'='1"
        "?search=<script>alert(1)</script>"
        "?file=../../../etc/passwd"
        "?cmd=;cat /etc/passwd"
        "?url=http://127.0.0.1/admin"
    )
    
    local test_names=(
        "SQL Injection"
        "XSS"
        "Path Traversal"
        "Command Injection"
        "SSRF"
    )
    
    for i in "${!tests[@]}"; do
        local response=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}${tests[$i]}" 2>/dev/null)
        
        if [[ "$response" == "403" ]]; then
            echo -e "  ${GREEN}✓${NC} ${test_names[$i]}: заблокирован (403)"
        elif [[ "$response" == "000" ]]; then
            echo -e "  ${YELLOW}?${NC} ${test_names[$i]}: нет соединения"
        else
            echo -e "  ${RED}✗${NC} ${test_names[$i]}: пропущен ($response)"
        fi
    done
    
    echo ""
}

# ============================================
# P1: HONEYPOT URLs
# ============================================

L7_HONEYPOT_CONF="/etc/nginx/conf.d/l7shield_honeypot.conf"
L7_HONEYPOT_LOG="/var/log/nginx/honeypot.log"
L7_HONEYPOT_SCRIPT="/opt/server-shield/scripts/l7-honeypot-ban.sh"

# Настройка Honeypot URLs
setup_honeypot_urls() {
    log_step "Настройка Honeypot URLs..."
    
    if ! check_nginx_installed; then
        log_error "Nginx не установлен!"
        return 1
    fi
    
    mkdir -p "$(dirname "$L7_HONEYPOT_SCRIPT")"
    
    # Nginx конфиг с honeypot locations
    cat > "$L7_HONEYPOT_CONF" << 'NGINX'
# ================================================
# L7 Shield - Honeypot URLs
# Ловушки для автоматических сканеров и ботов
# Любой доступ = мгновенный бан
# ================================================

# Формат лога для honeypot
log_format honeypot '$remote_addr - [$time_local] "$request" '
                    '$status "$http_user_agent" "$http_referer"';

# === Скрытые honeypot locations ===
# Добавьте в ваш server блок:
# include /etc/nginx/conf.d/l7shield_honeypot.conf;

# WordPress honeypots
location = /wp-login.php {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /wp-admin {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /xmlrpc.php {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# PHP honeypots
location ~ \.php$ {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# Admin panels honeypots
location = /admin {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /administrator {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /phpmyadmin {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /pma {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# Config files honeypots
location = /.env {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /.git/config {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /config.php {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /configuration.php {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# Backup files honeypots
location ~* \.(sql|bak|backup|old|orig|save)$ {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# Shell honeypots
location ~* (shell|c99|r57|WSO|FilesMan) {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

# Hidden trap (добавьте ссылку на эту страницу в robots.txt с Disallow)
location = /trap-for-bots {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}

location = /secret-admin-panel {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}
NGINX

    # Скрипт автобана из honeypot лога
    cat > "$L7_HONEYPOT_SCRIPT" << 'SCRIPT'
#!/bin/bash
#
# L7 Shield - Honeypot Auto-Ban
# Автоматический бан IP из honeypot лога
#

HONEYPOT_LOG="/var/log/nginx/honeypot.log"
IPSET_NAME="l7_autoban"
BAN_TIME="86400"  # 24 часа
STATE_FILE="/tmp/l7_honeypot_processed"

# Создаём ipset если не существует
ipset create "$IPSET_NAME" hash:ip timeout "$BAN_TIME" -exist 2>/dev/null

# Получаем последнюю обработанную позицию
last_pos=0
[[ -f "$STATE_FILE" ]] && last_pos=$(cat "$STATE_FILE")

# Получаем текущий размер лога
current_size=$(stat -c%s "$HONEYPOT_LOG" 2>/dev/null || echo 0)

# Если лог меньше (был ротирован) - начинаем сначала
[[ "$current_size" -lt "$last_pos" ]] && last_pos=0

# Читаем новые записи
if [[ "$current_size" -gt "$last_pos" ]]; then
    tail -c +$((last_pos + 1)) "$HONEYPOT_LOG" 2>/dev/null | while read -r line; do
        ip=$(echo "$line" | awk '{print $1}')
        
        # Валидация IP
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Проверяем что не в whitelist
            if ! ipset test l7_whitelist "$ip" 2>/dev/null; then
                # Добавляем в autoban
                ipset add "$IPSET_NAME" "$ip" timeout "$BAN_TIME" -exist 2>/dev/null
                
                # Логируем
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] HONEYPOT BAN: $ip" >> /opt/server-shield/logs/l7_bans.log
                
                # Отправляем в Telegram если настроен
                if [[ -f /opt/server-shield/modules/telegram.sh ]]; then
                    source /opt/server-shield/modules/telegram.sh
                    send_alert "🍯 Honeypot Ban" "IP: $ip\nПричина: Доступ к honeypot URL\nБан: 24 часа" 2>/dev/null
                fi
            fi
        fi
    done
    
    # Сохраняем позицию
    echo "$current_size" > "$STATE_FILE"
fi
SCRIPT

    chmod +x "$L7_HONEYPOT_SCRIPT"
    
    # Добавляем в cron (каждую минуту)
    local cron_line="* * * * * root $L7_HONEYPOT_SCRIPT"
    if ! grep -q "l7-honeypot-ban" "$L7_CRON" 2>/dev/null; then
        echo "$cron_line" >> "$L7_CRON"
    fi
    
    # Создаём robots.txt с ловушкой
    log_info "Создание robots.txt с ловушкой..."
    
    cat > "/var/www/html/robots.txt" 2>/dev/null << 'ROBOTS'
User-agent: *
Allow: /

# Trap for bad bots (do not remove)
Disallow: /trap-for-bots
Disallow: /secret-admin-panel
ROBOTS

    # Проверяем nginx
    if nginx -t 2>&1; then
        nginx -s reload 2>/dev/null
        log_info "Honeypot URLs настроены!"
        echo ""
        echo -e "${WHITE}Honeypot locations:${NC}"
        echo -e "  ${RED}●${NC} /wp-login.php, /wp-admin, /xmlrpc.php"
        echo -e "  ${RED}●${NC} /admin, /administrator, /phpmyadmin"
        echo -e "  ${RED}●${NC} /.env, /.git/config, *.sql, *.bak"
        echo -e "  ${RED}●${NC} /trap-for-bots (скрытая ловушка)"
        echo ""
        echo -e "${WHITE}Автоматический бан:${NC}"
        echo -e "  Любой доступ к honeypot = бан на 24 часа"
        echo -e "  Скрипт: ${CYAN}$L7_HONEYPOT_SCRIPT${NC}"
        echo ""
        echo -e "${YELLOW}Добавьте в ваш server блок:${NC}"
        echo "  include /etc/nginx/conf.d/l7shield_honeypot.conf;"
    else
        log_error "Ошибка в nginx конфиге"
        nginx -t
        rm -f "$L7_HONEYPOT_CONF"
        return 1
    fi
}

# Показать статистику honeypot
show_honeypot_stats() {
    echo ""
    echo -e "${WHITE}Honeypot статистика:${NC}"
    echo ""
    
    if [[ -f "$L7_HONEYPOT_LOG" ]]; then
        local total=$(wc -l < "$L7_HONEYPOT_LOG" 2>/dev/null || echo 0)
        local unique_ips=$(awk '{print $1}' "$L7_HONEYPOT_LOG" 2>/dev/null | sort -u | wc -l)
        local today=$(grep "$(date '+%d/%b/%Y')" "$L7_HONEYPOT_LOG" 2>/dev/null | wc -l)
        
        echo -e "  Всего попыток: ${RED}$total${NC}"
        echo -e "  Уникальных IP: ${YELLOW}$unique_ips${NC}"
        echo -e "  Сегодня: ${CYAN}$today${NC}"
        echo ""
        
        echo -e "${WHITE}Топ атакующих:${NC}"
        awk '{print $1}' "$L7_HONEYPOT_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -10 | while read count ip; do
            echo -e "  ${RED}$count${NC} — $ip"
        done
        
        echo ""
        echo -e "${WHITE}Последние 5 попыток:${NC}"
        tail -5 "$L7_HONEYPOT_LOG" 2>/dev/null | while read line; do
            echo -e "  ${DIM}$line${NC}"
        done
    else
        log_warn "Лог honeypot пуст или не существует"
    fi
}

# Добавить кастомный honeypot URL
add_honeypot_url() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        input_value "URL для honeypot (начиная с /)" "" url
    fi
    
    if [[ -z "$url" || ! "$url" =~ ^/ ]]; then
        log_error "URL должен начинаться с /"
        return 1
    fi
    
    # Добавляем в конфиг
    cat >> "$L7_HONEYPOT_CONF" << NGINX

# Custom honeypot: $url
location = $url {
    access_log /var/log/nginx/honeypot.log honeypot;
    return 444;
}
NGINX

    if nginx -t 2>&1 && nginx -s reload 2>/dev/null; then
        log_info "Honeypot URL добавлен: $url"
    else
        log_error "Ошибка добавления"
    fi
}

# Удалить honeypot
remove_honeypot_urls() {
    rm -f "$L7_HONEYPOT_CONF" "$L7_HONEYPOT_SCRIPT"
    sed -i '/l7-honeypot-ban/d' "$L7_CRON" 2>/dev/null
    nginx -s reload 2>/dev/null
    log_info "Honeypot URLs удалены"
}

# ============================================
# РАСШИРЕННОЕ МЕНЮ NGINX (ОБНОВЛЕНО)
# ============================================

nginx_menu() {
    while true; do
        print_header_mini "Nginx Protection"
        
        # Проверка nginx
        if ! check_nginx_installed; then
            echo ""
            log_error "Nginx не установлен!"
            echo ""
            echo -e "  ${YELLOW}Установите: apt install nginx${NC}"
            echo ""
            press_any_key
            return
        fi
        
        # Статус конфигов
        echo ""
        echo -e "    ${WHITE}Базовая защита:${NC}"
        [[ -f "$L7_NGINX_CONF" ]] && \
            show_status_line "Rate Limiting" "on" || \
            show_status_line "Rate Limiting" "off"
        [[ -f "$L7_NGINX_MAPS" ]] && \
            show_status_line "Bad Bots/URI" "on" || \
            show_status_line "Bad Bots/URI" "off"
        
        echo ""
        echo -e "    ${WHITE}Расширенная защита (P0):${NC}"
        [[ -f "$L7_JS_CHALLENGE_HTML" ]] && \
            show_status_line "JS Challenge" "on" || \
            show_status_line "JS Challenge" "off"
        [[ -f "$L7_API_RATE_CONF" ]] && \
            show_status_line "API Rate Limiting" "on" || \
            show_status_line "API Rate Limiting" "off"
        [[ -f "$L7_TARPIT_CONF" ]] && \
            show_status_line "Tarpit Mode" "on" || \
            show_status_line "Tarpit Mode" "off"
        [[ -f "$L7_SYNC_SCRIPT" ]] && \
            show_status_line "Blocklist Sync" "on" || \
            show_status_line "Blocklist Sync" "off"
        
        echo ""
        echo -e "    ${WHITE}Продвинутая защита (P1):${NC}"
        [[ -f "$L7_CLOUDFLARE_CONF" ]] && \
            show_status_line "Cloudflare Real IP" "on" || \
            show_status_line "Cloudflare Real IP" "off"
        [[ -f "$L7_HTTP2_CONF" ]] && \
            show_status_line "HTTP/2 Protection" "on" || \
            show_status_line "HTTP/2 Protection" "off"
        [[ -f "$L7_WAF_RULES" ]] && \
            show_status_line "WAF (Injection)" "on" || \
            show_status_line "WAF (Injection)" "off"
        [[ -f "$L7_HONEYPOT_CONF" ]] && \
            show_status_line "Honeypot URLs" "on" || \
            show_status_line "Honeypot URLs" "off"
        
        echo ""
        print_divider
        echo ""
        
        echo -e "    ${WHITE}БАЗОВАЯ:${NC}"
        menu_item "1" "Создать базовые конфиги"
        menu_item "2" "Показать сниппет для server блока"
        
        echo ""
        echo -e "    ${WHITE}P0 ЗАЩИТА:${NC}"
        menu_item "3" "JS Challenge Page"
        menu_item "4" "API Rate Limiting"
        menu_item "5" "Tarpit Mode"
        menu_item "6" "Blocklist Sync"
        
        echo ""
        echo -e "    ${WHITE}P1 ЗАЩИТА:${NC}"
        menu_item "7" "Cloudflare Real IP"
        menu_item "8" "HTTP/2 Protection"
        menu_item "9" "WAF (Request Inspection)"
        menu_item "h" "Honeypot URLs"
        
        menu_divider
        menu_item "a" "Применить защиту к сайту"
        menu_item "p" "Пути nginx конфигов"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                create_nginx_config
                press_any_key
                ;;
            2)
                show_nginx_snippet
                press_any_key
                ;;
            3)
                echo ""
                menu_item "a" "Настроить JS Challenge"
                menu_item "b" "Включить режим"
                menu_item "c" "Выключить режим"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_js_challenge ;;
                    b) toggle_js_challenge "on" ;;
                    c) toggle_js_challenge "off" ;;
                esac
                press_any_key
                ;;
            4)
                echo ""
                menu_item "a" "Настроить API Rate Limiting"
                menu_item "b" "Изменить лимиты"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_api_rate_limiting ;;
                    b) configure_api_limits ;;
                esac
                press_any_key
                ;;
            5)
                echo ""
                menu_item "a" "Настроить Tarpit Mode"
                menu_item "b" "Изменить задержку"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_tarpit_mode ;;
                    b) configure_tarpit ;;
                esac
                press_any_key
                ;;
            6)
                echo ""
                menu_item "a" "Настроить синхронизацию"
                menu_item "b" "Синхронизировать сейчас"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_blocklist_sync ;;
                    b) force_blocklist_sync ;;
                esac
                press_any_key
                ;;
            7)
                echo ""
                menu_item "a" "Настроить Cloudflare Real IP"
                menu_item "b" "Обновить IP диапазоны"
                menu_item "c" "Удалить"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_cloudflare_realip ;;
                    b) update_cloudflare_ips ;;
                    c) remove_cloudflare_realip ;;
                esac
                press_any_key
                ;;
            8)
                echo ""
                menu_item "a" "Настроить HTTP/2 Protection"
                menu_item "b" "Удалить"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_http2_protection ;;
                    b) remove_http2_protection ;;
                esac
                press_any_key
                ;;
            9)
                echo ""
                menu_item "a" "Настроить WAF"
                menu_item "b" "Тест WAF правил"
                menu_item "c" "Удалить"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_waf_protection ;;
                    b) test_waf_rules ;;
                    c) remove_waf_protection ;;
                esac
                press_any_key
                ;;
            h)
                echo ""
                menu_item "a" "Настроить Honeypot URLs"
                menu_item "b" "Статистика"
                menu_item "c" "Добавить URL"
                menu_item "d" "Удалить"
                local sub=$(read_choice)
                case "${sub,,}" in
                    a) setup_honeypot_urls ;;
                    b) show_honeypot_stats ;;
                    c) add_honeypot_url ;;
                    d) remove_honeypot_urls ;;
                esac
                press_any_key
                ;;
            a)
                apply_nginx_protection
                press_any_key
                ;;
            p)
                nginx_paths_menu
                ;;
            0|q) return ;;
        esac
    done
}

# CLI обработка (только при прямом запуске, не при source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        enable) enable_l7 ;;
        disable) disable_l7 ;;
        reload) reload_l7 ;;
        status) show_l7_status ;;
        start_silent) start_silent ;;
        stop_silent) stop_silent ;;
        reload_silent) reload_silent ;;
        sync|sync_blocklist|github_sync) github_full_sync ;;
        menu|"") l7_menu ;;
        *) echo "Usage: $0 {enable|disable|reload|status|sync|menu}" ;;
    esac
fi
