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
# ИНИЦИАЛИЗАЦИЯ
# ============================================

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
# BLACKLIST URLs
# ============================================

# Добавить URL для blacklist
add_blacklist_url() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        return 1
    fi
    
    if ! grep -q "^$url$" "$L7_BLACKLIST_URLS" 2>/dev/null; then
        echo "$url" >> "$L7_BLACKLIST_URLS"
        log_info "URL добавлен: $url"
    else
        log_warn "URL уже существует"
    fi
}

# Удалить URL
remove_blacklist_url() {
    local url="$1"
    sed -i "\|^$url$|d" "$L7_BLACKLIST_URLS"
    log_info "URL удалён"
}

# Скачать и применить blacklist с URL
update_blacklists_from_urls() {
    local urls_file="$L7_BLACKLIST_URLS"
    local temp_file="/tmp/l7_blacklist_download.txt"
    local count=0
    local total=0
    
    if [[ ! -f "$urls_file" ]]; then
        return 0
    fi
    
    log_step "Обновление blacklist из URL..."
    
    > "$temp_file"
    
    while IFS= read -r url; do
        # Пропускаем комментарии и пустые строки
        [[ "$url" =~ ^# ]] && continue
        [[ -z "$url" ]] && continue
        
        echo -ne "  Скачивание: ${url:0:50}... "
        
        local downloaded=$(curl -fsSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null | \
            grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
            sort -u)
        
        if [[ -n "$downloaded" ]]; then
            local url_count=$(echo "$downloaded" | wc -l)
            echo "$downloaded" >> "$temp_file"
            echo -e "${GREEN}$url_count IP${NC}"
            ((total += url_count))
        else
            echo -e "${RED}ошибка${NC}"
        fi
    done < "$urls_file"
    
    if [[ -s "$temp_file" ]]; then
        # Уникальные IP
        local unique_ips=$(sort -u "$temp_file")
        local unique_count=$(echo "$unique_ips" | wc -l)
        
        log_step "Применение $unique_count уникальных IP..."
        
        # Добавляем в ipset
        echo "$unique_ips" | while read -r ip; do
            # Валидация IP
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ipset add "$IPSET_BLACKLIST" "$ip" 2>/dev/null && ((count++))
            fi
        done
        
        log_info "Добавлено $count IP из внешних списков"
    fi
    
    rm -f "$temp_file"
    
    # Сохраняем время обновления
    date +%s > "$L7_CONFIG_DIR/last_blacklist_update"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') | BLACKLIST_UPDATE | Added $count IPs from URLs" >> "$L7_LOG"
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
# NGINX КОНФИГУРАЦИЯ
# ============================================

# Создать nginx конфиг для L7 защиты
create_nginx_config() {
    load_l7_config
    
    if ! command -v nginx &>/dev/null; then
        log_warn "Nginx не установлен"
        return 1
    fi
    
    log_step "Создание nginx L7 конфига..."
    
    # Получаем VPN порты для исключения
    local vpn_ports=$(get_vpn_ports)
    
    # Maps конфигурация
    cat > "$L7_NGINX_MAPS" << 'NGINX_MAPS'
# L7 Shield - Nginx Maps
# Auto-generated by Server Security Shield

# Whitelist IPs (не лимитируем)
geo $l7_whitelist {
    default 0;
    127.0.0.1 1;
    10.0.0.0/8 1;
    172.16.0.0/12 1;
    192.168.0.0/16 1;
    # Добавьте свои IP:
    # 1.2.3.4 1;
}

# Определение bad bots
map $http_user_agent $l7_bad_bot {
    default 0;
    ~*bot 1;
    ~*crawl 1;
    ~*spider 1;
    ~*scanner 1;
    ~*nikto 1;
    ~*sqlmap 1;
    ~*nmap 1;
    ~*masscan 1;
    ~*zgrab 1;
    ~*curl 0;  # curl разрешаем
    "" 1;      # Пустой UA - подозрительно
}

# Определение подозрительных запросов
map $request_uri $l7_bad_request {
    default 0;
    ~*\.php$ 1;
    ~*\.asp 1;
    ~*\.aspx 1;
    ~*wp-admin 1;
    ~*wp-login 1;
    ~*phpmyadmin 1;
    ~*\.env 1;
    ~*\.git 1;
    ~*\.svn 1;
    ~*\.sql 1;
    ~*\.bak 1;
    ~*shell 1;
    ~*eval 1;
    ~*base64 1;
}

# Лимит зона
map $l7_whitelist $l7_limit_key {
    0 $binary_remote_addr;
    1 "";
}
NGINX_MAPS

    # Основной конфиг rate limiting
    cat > "$L7_NGINX_CONF" << NGINX_CONF
# L7 Shield - Nginx Rate Limiting
# Auto-generated by Server Security Shield

# Rate limit zones
limit_req_zone \$l7_limit_key zone=l7_general:50m rate=${NGINX_RATE_LIMIT};
limit_req_zone \$l7_limit_key zone=l7_strict:20m rate=10r/s;
limit_req_zone \$l7_limit_key zone=l7_api:30m rate=30r/s;

# Connection limit zones
limit_conn_zone \$binary_remote_addr zone=l7_conn_perip:20m;
limit_conn_zone \$server_name zone=l7_conn_perserver:20m;

# Status коды для лимитов
limit_req_status 429;
limit_conn_status 429;

# Логирование
limit_req_log_level warn;
limit_conn_log_level warn;
NGINX_CONF

    # Проверяем nginx
    if nginx -t 2>/dev/null; then
        nginx -s reload 2>/dev/null
        log_info "Nginx L7 конфиг создан и применён"
    else
        log_error "Ошибка в nginx конфиге"
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
            fi
        fi
    done
}

# Обновление blacklist URL (раз в N часов)
check_blacklist_update() {
    local last_update_file="/opt/server-shield/config/l7shield/last_blacklist_update"
    local interval="${BLACKLIST_UPDATE_INTERVAL:-6}"
    local interval_sec=$((interval * 3600))
    
    local last_update=0
    [[ -f "$last_update_file" ]] && last_update=$(cat "$last_update_file")
    
    local now=$(date +%s)
    local diff=$((now - last_update))
    
    if [[ $diff -gt $interval_sec ]]; then
        log_l7 "BLACKLIST_UPDATE | Starting scheduled update"
        /opt/server-shield/modules/l7shield.sh update_blacklists
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

# Обновление blacklist каждые 6 часов
0 */6 * * * root $L7_SCRIPT update
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
    
    # Установка зависимостей
    apt-get update -qq
    apt-get install -y ipset conntrack >/dev/null 2>&1
    
    # Инициализация
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
    
    # GeoIP если включен
    if [[ "$GEOIP_ENABLED" == "true" ]]; then
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
    
    # Включаем сервис
    systemctl enable shield-l7 2>/dev/null
    
    # Сохраняем статус
    save_l7_param "L7_ENABLED" "true"
    
    log_info "L7 Shield включен!"
}

# Выключить L7 Shield
disable_l7() {
    log_step "Выключение L7 Shield..."
    
    # Очищаем правила
    clear_l7_rules
    
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
    
    clear_l7_rules
    init_ipsets
    apply_l7_iptables
    
    if [[ "$GEOIP_ENABLED" == "true" ]]; then
        apply_geoip_rules
    fi
    
    log_info "L7 Shield перезагружен"
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

# Меню blacklist
blacklist_menu() {
    while true; do
        print_header
        print_section "🚫 Blacklist"
        
        local blacklist_count=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        local urls_count=$(grep -v "^#" "$L7_BLACKLIST_URLS" 2>/dev/null | grep -v "^$" | wc -l)
        
        echo ""
        echo -e "  ${WHITE}IP в blacklist:${NC} ${RED}$blacklist_count${NC}"
        echo -e "  ${WHITE}URL источников:${NC} ${CYAN}$urls_count${NC}"
        echo ""
        
        # Показываем URLs
        if [[ $urls_count -gt 0 ]]; then
            echo -e "${WHITE}Источники blacklist:${NC}"
            local i=1
            while IFS= read -r url; do
                [[ "$url" =~ ^# ]] && continue
                [[ -z "$url" ]] && continue
                echo -e "  ${WHITE}$i)${NC} ${CYAN}${url:0:60}...${NC}"
                ((i++))
            done < "$L7_BLACKLIST_URLS"
            echo ""
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} Добавить IP вручную"
        echo -e "  ${WHITE}2)${NC} Удалить IP"
        echo -e "  ${WHITE}3)${NC} Показать все IP"
        echo ""
        echo -e "  ${WHITE}4)${NC} Добавить URL источник"
        echo -e "  ${WHITE}5)${NC} Удалить URL источник"
        echo -e "  ${WHITE}6)${NC} ${GREEN}Обновить из всех URL${NC}"
        echo ""
        echo -e "  ${WHITE}7)${NC} Очистить весь blacklist"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            1)
                echo ""
                read -p "IP для блокировки: " ip
                if validate_ip "$ip"; then
                    add_to_blacklist "$ip" "manual"
                else
                    log_error "Неверный IP"
                fi
                ;;
            2)
                echo ""
                read -p "IP для разблокировки: " ip
                remove_from_blacklist "$ip"
                ;;
            3)
                echo ""
                echo -e "${WHITE}Все IP в blacklist:${NC}"
                ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep "^[0-9]" | head -50
                echo ""
                echo -e "${YELLOW}(показано первые 50)${NC}"
                ;;
            4)
                echo ""
                echo -e "${WHITE}Популярные источники:${NC}"
                echo -e "  1) https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http"
                echo -e "  2) https://openproxylist.xyz/http.txt"
                echo -e "  3) https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
                echo ""
                read -p "URL (или номер): " url
                
                case "$url" in
                    1) url="https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=10000&country=all&ssl=all&anonymity=all" ;;
                    2) url="https://openproxylist.xyz/http.txt" ;;
                    3) url="https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt" ;;
                esac
                
                if [[ "$url" =~ ^https?:// ]]; then
                    add_blacklist_url "$url"
                else
                    log_error "Неверный URL"
                fi
                ;;
            5)
                echo ""
                read -p "Номер URL для удаления: " num
                local url_to_del=$(grep -v "^#" "$L7_BLACKLIST_URLS" | grep -v "^$" | sed -n "${num}p")
                if [[ -n "$url_to_del" ]]; then
                    remove_blacklist_url "$url_to_del"
                fi
                ;;
            6)
                update_blacklists_from_urls
                ;;
            7)
                if confirm "Очистить весь blacklist?" "n"; then
                    ipset flush "$IPSET_BLACKLIST" 2>/dev/null
                    echo "# IP blacklist" > "$L7_BLACKLIST"
                    log_info "Blacklist очищен"
                fi
                ;;
            0) return ;;
        esac
        
        press_any_key
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
                # Перезагружаем если активен
                [[ "$L7_ENABLED" == "true" ]] && reload_l7
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
        print_header
        print_section "🛡️ L7 Shield - Защита от DDoS"
        
        load_l7_config
        
        echo ""
        
        # Быстрый статус
        if [[ "$L7_ENABLED" == "true" ]]; then
            echo -e "  ${GREEN}●${NC} Статус: ${GREEN}АКТИВЕН${NC}"
            
            local blacklist_count=$(ipset list "$IPSET_BLACKLIST" 2>/dev/null | grep -c "^[0-9]" || echo 0)
            local autoban_count=$(ipset list "$IPSET_AUTOBAN" 2>/dev/null | grep -c "^[0-9]" || echo 0)
            local total_conn=$(ss -tn state established 2>/dev/null | wc -l)
            
            echo -e "  Blacklist: ${RED}$blacklist_count${NC} | Auto-ban: ${YELLOW}$autoban_count${NC} | Соединений: ${CYAN}$total_conn${NC}"
        else
            echo -e "  ${RED}○${NC} Статус: ${RED}ВЫКЛЮЧЕН${NC}"
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC}  📊 Полный статус"
        echo -e "  ${WHITE}2)${NC}  🎯 Топ атакующих (live)"
        echo ""
        
        if [[ "$L7_ENABLED" == "true" ]]; then
            echo -e "  ${WHITE}3)${NC}  ${RED}🔴 Выключить L7 Shield${NC}"
            echo -e "  ${WHITE}4)${NC}  🔄 Перезагрузить правила"
        else
            echo -e "  ${WHITE}3)${NC}  ${GREEN}🟢 Включить L7 Shield${NC}"
        fi
        
        echo ""
        echo -e "  ${WHITE}5)${NC}  🔌 VPN порты"
        echo -e "  ${WHITE}6)${NC}  🚫 Blacklist (IP + URLs)"
        echo -e "  ${WHITE}7)${NC}  ✅ Whitelist"
        echo -e "  ${WHITE}8)${NC}  🌍 GeoIP блокировка"
        echo -e "  ${WHITE}9)${NC}  ⚙️  Настройка лимитов"
        echo ""
        echo -e "  ${WHITE}n)${NC}  📝 Nginx конфиг (сниппет)"
        echo -e "  ${WHITE}l)${NC}  📜 Логи банов"
        echo ""
        echo -e "  ${WHITE}0)${NC}  Назад"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            1) show_l7_status ;;
            2) show_top_attackers ;;
            3)
                if [[ "$L7_ENABLED" == "true" ]]; then
                    disable_l7
                else
                    enable_l7
                fi
                ;;
            4)
                [[ "$L7_ENABLED" == "true" ]] && reload_l7
                ;;
            5) vpn_ports_menu ;;
            6) blacklist_menu ;;
            7) whitelist_menu ;;
            8) geoip_menu ;;
            9) limits_menu ;;
            n|N)
                show_nginx_snippet
                ;;
            l|L)
                echo ""
                if [[ -f "$L7_BAN_LOG" ]]; then
                    tail -50 "$L7_BAN_LOG"
                else
                    echo "Логов пока нет"
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
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

# CLI обработка
case "${1:-}" in
    enable) enable_l7 ;;
    disable) disable_l7 ;;
    reload) reload_l7 ;;
    status) show_l7_status ;;
    start_silent) start_silent ;;
    stop_silent) stop_silent ;;
    reload_silent) reload_silent ;;
    update_blacklists) update_blacklists_from_urls ;;
    menu|"") l7_menu ;;
    *) echo "Usage: $0 {enable|disable|reload|status|menu}" ;;
esac
