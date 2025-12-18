#!/bin/bash
#
# fail2ban.sh - Fail2Ban настройки с гибкими Telegram уведомлениями
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
FAIL2BAN_ACTION="/etc/fail2ban/action.d/telegram.conf"
FAIL2BAN_SUMMARY_SCRIPT="/opt/server-shield/scripts/fail2ban-summary.sh"
FAIL2BAN_CRON="/etc/cron.d/shield-fail2ban-summary"

# Режимы уведомлений:
# off      - выключено
# instant  - мгновенно при каждом бане
# 1h       - сводка каждый час
# 3h       - сводка каждые 3 часа
# 6h       - сводка каждые 6 часов
# daily    - сводка раз в день

# Время бана:
# -1       - навсегда (рекомендуется!)
# 1h       - 1 час (3600)
# 1d       - 1 день (86400)
# 1w       - 1 неделя (604800)

# Получить текущее время бана
get_bantime() {
    get_config "F2B_BANTIME" "3600"
}

# Установить время бана
set_bantime() {
    local bantime="$1"
    save_config "F2B_BANTIME" "$bantime"
    
    # Обновляем конфиг Fail2Ban
    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        # Заменяем bantime в секции [sshd]
        sed -i "s/^bantime = .*/bantime = $bantime/" "$FAIL2BAN_JAIL"
        
        # Перезапускаем Fail2Ban
        systemctl restart fail2ban 2>/dev/null || service fail2ban restart
        log_info "Время бана обновлено"
    fi
}

# Получить человекочитаемое время бана
get_bantime_human() {
    local bantime=$(get_bantime)
    case "$bantime" in
        "-1") echo "Навсегда (permanent)" ;;
        "3600") echo "1 час" ;;
        "86400") echo "24 часа" ;;
        "604800") echo "7 дней" ;;
        *) echo "$bantime секунд" ;;
    esac
}

# Установка и настройка Fail2Ban
setup_fail2ban() {
    local ssh_port="${1:-22}"
    local tg_token="$2"
    local tg_chat_id="$3"
    local bantime="${4:-86400}"  # По умолчанию 24 часа
    
    log_step "Настройка Fail2Ban..."
    
    # Бэкап старого конфига
    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        cp "$FAIL2BAN_JAIL" "$BACKUP_DIR/jail.local.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Сохраняем время бана
    save_config "F2B_BANTIME" "$bantime"
    
    # Сначала создаём Telegram action (если есть токен)
    local ssh_action=""
    if [[ -n "$tg_token" ]] && [[ -n "$tg_chat_id" ]]; then
        # Создаём telegram-shield action для всех jail'ов
        create_telegram_action "$tg_token" "$tg_chat_id"
        
        ssh_action="action = iptables-multiport[name=sshd, port=$ssh_port]
         telegram-shield[name=sshd]"
    fi
    
    # Создаём основной конфиг
    cat > "$FAIL2BAN_JAIL" << JAIL
# ============================================
# Server Shield - Fail2Ban Configuration
# ============================================

[DEFAULT]
bantime = $bantime
findtime = 10m
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1
banaction = iptables-multiport
banaction_allports = iptables-allports

# ============================================
# SSH Защита
# ============================================
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = $bantime
$ssh_action
JAIL

    # Добавляем Telegram скрипты если есть токен
    if [[ -n "$tg_token" ]] && [[ -n "$tg_chat_id" ]]; then
        # По умолчанию - мгновенные уведомления
        save_config "F2B_NOTIFY_MODE" "instant"
        
        # Создаём скрипт для сводки
        setup_summary_script "$tg_token" "$tg_chat_id"
    fi
    
    # Создаём расширенные jail'ы (выключены по умолчанию)
    setup_extended_jails
    
    # Перезапуск сервиса
    systemctl restart fail2ban 2>/dev/null || service fail2ban restart
    systemctl enable fail2ban 2>/dev/null
    
    log_info "Fail2Ban настроен"
}

# Настройка мгновенных уведомлений
setup_instant_notifications() {
    local tg_token="$1"
    local tg_chat_id="$2"
    
    cat > "$FAIL2BAN_ACTION" << ACTION
# Telegram уведомления для Fail2Ban (мгновенные)

[Definition]
actionstart = 
actionstop = 
actioncheck = 

actionban = /opt/server-shield/scripts/fail2ban-notify.sh ban "<ip>" "<name>"
actionunban = 
ACTION

    # Создаём скрипт уведомлений
    mkdir -p /opt/server-shield/scripts
    
    cat > /opt/server-shield/scripts/fail2ban-notify.sh << SCRIPT
#!/bin/bash
# Fail2Ban Telegram Notify

TOKEN="$tg_token"
CHAT_ID="$tg_chat_id"
MODE=\$(grep "^F2B_NOTIFY_MODE=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)

# Если режим не instant - не отправляем мгновенно
if [[ "\$MODE" != "instant" ]]; then
    exit 0
fi

ACTION="\$1"
IP="\$2"
JAIL="\$3"
HOSTNAME=\$(hostname)
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

if [[ "\$ACTION" == "ban" ]]; then
    MESSAGE="🚫 Fail2Ban: Бан

Сервер: \$HOSTNAME
IP: \$IP
Jail: \$JAIL
Время: \$DATE"

    curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \\
        -d "chat_id=\$CHAT_ID" \\
        -d "text=\$MESSAGE" > /dev/null 2>&1
fi
SCRIPT

    chmod +x /opt/server-shield/scripts/fail2ban-notify.sh
}

# Скрипт сводки
setup_summary_script() {
    local tg_token="$1"
    local tg_chat_id="$2"
    
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > "$FAIL2BAN_SUMMARY_SCRIPT" << 'SCRIPT'
#!/bin/bash
# Fail2Ban Summary Report - All Jails

TOKEN="__TOKEN__"
CHAT_ID="__CHAT_ID__"
HOSTNAME=$(hostname)
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Список всех jail'ов
JAILS="sshd portscan nginx-http-auth-shield nginx-badbots-shield mysqld-auth-shield"

TOTAL_BANNED=0
TOTAL_ALL=0
JAIL_STATS=""

if command -v fail2ban-client &> /dev/null; then
    for jail in $JAILS; do
        STATUS=$(fail2ban-client status "$jail" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            BANNED=$(echo "$STATUS" | grep "Currently banned" | awk '{print $4}')
            TOTAL=$(echo "$STATUS" | grep "Total banned" | awk '{print $4}')
            
            if [[ -n "$BANNED" ]] && [[ "$BANNED" != "0" ]]; then
                case "$jail" in
                    "sshd") NAME="🔐 SSH" ;;
                    "portscan") NAME="🔍 Portscan" ;;
                    "nginx-http-auth-shield") NAME="🌐 Nginx Auth" ;;
                    "nginx-badbots-shield") NAME="🤖 Nginx Bots" ;;
                    "mysqld-auth-shield") NAME="🗄️ MySQL" ;;
                    *) NAME="$jail" ;;
                esac
                JAIL_STATS="$JAIL_STATS
$NAME: $BANNED забанено"
                TOTAL_BANNED=$((TOTAL_BANNED + BANNED))
            fi
            
            if [[ -n "$TOTAL" ]]; then
                TOTAL_ALL=$((TOTAL_ALL + TOTAL))
            fi
        fi
    done
fi

# Проверяем лог новых банов (если режим не instant)
NEW_BANS=""
BANS_LOG="/opt/server-shield/logs/fail2ban-bans.log"
if [[ -f "$BANS_LOG" ]]; then
    NEW_BANS=$(cat "$BANS_LOG" 2>/dev/null | tail -20)
    # Очищаем лог после отправки
    > "$BANS_LOG"
fi

# Если нет банов - не отправляем
if [[ "$TOTAL_BANNED" == "0" ]] && [[ -z "$NEW_BANS" ]]; then
    exit 0
fi

# Формируем сообщение
MESSAGE="📊 Fail2Ban Сводка

Сервер: $HOSTNAME
IP: $SERVER_IP
Время: $DATE

🔒 Всего забанено: $TOTAL_BANNED
📈 Банов за всё время: $TOTAL_ALL"

if [[ -n "$JAIL_STATS" ]]; then
    MESSAGE="$MESSAGE
$JAIL_STATS"
fi

if [[ -n "$NEW_BANS" ]]; then
    MESSAGE="$MESSAGE

📋 Новые баны:
$NEW_BANS"
fi

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "text=$MESSAGE" > /dev/null 2>&1
SCRIPT

    # Подставляем токен и chat_id
    sed -i "s|__TOKEN__|$tg_token|g" "$FAIL2BAN_SUMMARY_SCRIPT"
    sed -i "s|__CHAT_ID__|$tg_chat_id|g" "$FAIL2BAN_SUMMARY_SCRIPT"
    
    chmod +x "$FAIL2BAN_SUMMARY_SCRIPT"
}

# Настройка cron для сводки
setup_summary_cron() {
    local mode="$1"
    
    # Удаляем старый cron
    rm -f "$FAIL2BAN_CRON"
    
    case "$mode" in
        "off"|"instant")
            # Без cron
            ;;
        "1h")
            echo "0 * * * * root $FAIL2BAN_SUMMARY_SCRIPT" > "$FAIL2BAN_CRON"
            ;;
        "3h")
            echo "0 */3 * * * root $FAIL2BAN_SUMMARY_SCRIPT" > "$FAIL2BAN_CRON"
            ;;
        "6h")
            echo "0 */6 * * * root $FAIL2BAN_SUMMARY_SCRIPT" > "$FAIL2BAN_CRON"
            ;;
        "daily")
            echo "0 9 * * * root $FAIL2BAN_SUMMARY_SCRIPT" > "$FAIL2BAN_CRON"
            ;;
    esac
    
    # Перезагружаем cron
    systemctl reload cron 2>/dev/null || service cron reload 2>/dev/null
}

# Получить текущий режим уведомлений
get_notify_mode() {
    get_config "F2B_NOTIFY_MODE" "off"
}

# Установить режим уведомлений
set_notify_mode() {
    local mode="$1"
    save_config "F2B_NOTIFY_MODE" "$mode"
    setup_summary_cron "$mode"
    
    # Уведомления теперь работают через telegram-shield action
    # Режим (instant/summary) проверяется в скрипте fail2ban-notify-all.sh
    # Перезапуск не нужен - скрипт сам читает режим из конфига
    
    log_info "Режим уведомлений сохранён"
}

# Отправить сводку сейчас
send_summary_now() {
    if [[ -x "$FAIL2BAN_SUMMARY_SCRIPT" ]]; then
        "$FAIL2BAN_SUMMARY_SCRIPT"
        log_info "Сводка отправлена"
    else
        log_error "Скрипт сводки не настроен. Настройте Telegram."
    fi
}

# Проверка статуса
check_fail2ban_status() {
    echo ""
    echo -e "${WHITE}Fail2Ban Статус:${NC}"
    
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Сервис: ${GREEN}Активен${NC}"
        
        if command -v fail2ban-client &> /dev/null; then
            local banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}')
            local total=$(fail2ban-client status sshd 2>/dev/null | grep "Total banned" | awk '{print $4}')
            
            echo -e "  ${WHITE}SSH Jail:${NC}"
            echo -e "    Сейчас забанено: ${CYAN}${banned:-0}${NC}"
            echo -e "    Всего банов: ${CYAN}${total:-0}${NC}"
        fi
        
        # Показываем время бана
        local bantime_human=$(get_bantime_human)
        echo ""
        echo -e "  ${WHITE}Время бана:${NC} ${CYAN}$bantime_human${NC}"
        
        # Показываем режим уведомлений
        local mode=$(get_notify_mode)
        echo ""
        echo -e "  ${WHITE}Telegram уведомления:${NC}"
        case "$mode" in
            "off") echo -e "    Режим: ${RED}Выключены${NC}" ;;
            "instant") echo -e "    Режим: ${YELLOW}Мгновенно (при каждом бане)${NC}" ;;
            "1h") echo -e "    Режим: ${GREEN}Сводка каждый час${NC}" ;;
            "3h") echo -e "    Режим: ${GREEN}Сводка каждые 3 часа${NC}" ;;
            "6h") echo -e "    Режим: ${GREEN}Сводка каждые 6 часов${NC}" ;;
            "daily") echo -e "    Режим: ${GREEN}Сводка раз в день (9:00)${NC}" ;;
        esac
    else
        echo -e "  ${RED}✗${NC} Сервис: ${RED}Не активен${NC}"
    fi
}

# Показать забаненные IP
show_banned_ips() {
    echo ""
    echo -e "${WHITE}Забаненные IP:${NC}"
    echo ""
    
    if command -v fail2ban-client &> /dev/null; then
        local banned_list=$(fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" | cut -d: -f2)
        
        if [[ -n "$banned_list" ]]; then
            echo "$banned_list" | tr ' ' '\n' | while read ip; do
                [[ -n "$ip" ]] && echo -e "  ${RED}•${NC} $ip"
            done
        else
            echo -e "  ${GREEN}Нет забаненных IP${NC}"
        fi
    fi
}

# Разбанить IP
unban_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    if command -v fail2ban-client &> /dev/null; then
        fail2ban-client set sshd unbanip "$ip" 2>/dev/null
        log_info "IP $ip разбанен"
    fi
}

# Бан IP вручную
ban_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    if ! validate_ip "$ip"; then
        log_error "Неверный IP: $ip"
        return 1
    fi
    
    if command -v fail2ban-client &> /dev/null; then
        fail2ban-client set sshd banip "$ip" 2>/dev/null
        log_info "IP $ip забанен"
    fi
}

# Меню настройки уведомлений
notifications_menu() {
    while true; do
        print_header
        print_section "🔔 Настройка уведомлений Fail2Ban"
        
        local current_mode=$(get_notify_mode)
        
        echo ""
        echo -e "  ${WHITE}Текущий режим:${NC}"
        case "$current_mode" in
            "off") echo -e "    ${RED}○ Выключены${NC}" ;;
            "instant") echo -e "    ${YELLOW}● Мгновенно (при каждом бане)${NC}" ;;
            "1h") echo -e "    ${GREEN}● Сводка каждый час${NC}" ;;
            "3h") echo -e "    ${GREEN}● Сводка каждые 3 часа${NC}" ;;
            "6h") echo -e "    ${GREEN}● Сводка каждые 6 часов${NC}" ;;
            "daily") echo -e "    ${GREEN}● Сводка раз в день (9:00)${NC}" ;;
        esac
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${WHITE}Выберите режим:${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} 🔕 Выключить уведомления"
        echo -e "  ${WHITE}2)${NC} ⚡ Мгновенно (при каждом бане) ${YELLOW}— может флудить!${NC}"
        echo -e "  ${WHITE}3)${NC} 📊 Сводка каждый час ${GREEN}— рекомендуется${NC}"
        echo -e "  ${WHITE}4)${NC} 📊 Сводка каждые 3 часа"
        echo -e "  ${WHITE}5)${NC} 📊 Сводка каждые 6 часов"
        echo -e "  ${WHITE}6)${NC} 📊 Сводка раз в день (9:00)"
        echo ""
        echo -e "  ${WHITE}7)${NC} 📤 Отправить сводку сейчас"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                set_notify_mode "off"
                log_info "Уведомления выключены"
                ;;
            2)
                set_notify_mode "instant"
                log_info "Режим: мгновенные уведомления"
                ;;
            3)
                set_notify_mode "1h"
                log_info "Режим: сводка каждый час"
                ;;
            4)
                set_notify_mode "3h"
                log_info "Режим: сводка каждые 3 часа"
                ;;
            5)
                set_notify_mode "6h"
                log_info "Режим: сводка каждые 6 часов"
                ;;
            6)
                set_notify_mode "daily"
                log_info "Режим: сводка раз в день"
                ;;
            7)
                send_summary_now
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Меню настройки времени бана
bantime_menu() {
    while true; do
        print_header
        print_section "⏱️ Настройка времени бана"
        
        local current_bantime=$(get_bantime)
        local current_human=$(get_bantime_human)
        
        echo ""
        echo -e "  ${WHITE}Текущее время бана:${NC} ${CYAN}$current_human${NC}"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${WHITE}Выберите время бана:${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} ⏱️  1 час"
        echo -e "  ${WHITE}2)${NC} ⏱️  24 часа"
        echo -e "  ${WHITE}3)${NC} ⏱️  7 дней"
        echo -e "  ${WHITE}4)${NC} 🔒 Навсегда (permanent) ${GREEN}— рекомендуется для сканеров${NC}"
        echo ""
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите время: " choice
        
        case $choice in
            1)
                set_bantime "3600"
                log_info "Время бана: 1 час"
                ;;
            2)
                set_bantime "86400"
                log_info "Время бана: 24 часа"
                ;;
            3)
                set_bantime "604800"
                log_info "Время бана: 7 дней"
                ;;
            4)
                set_bantime "-1"
                log_info "Время бана: Навсегда (permanent)"
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Главное меню Fail2Ban
fail2ban_menu() {
    while true; do
        print_header
        print_section "🤖 Управление Fail2Ban"
        
        check_fail2ban_status
        
        # Показываем текущее время бана
        local bantime_human=$(get_bantime_human)
        echo ""
        echo -e "  ${WHITE}Время бана:${NC} ${CYAN}$bantime_human${NC}"
        
        echo ""
        echo -e "  ${WHITE}1)${NC} Статус Fail2Ban"
        echo -e "  ${WHITE}2)${NC} Список забаненных IP"
        echo -e "  ${WHITE}3)${NC} Разбанить IP"
        echo -e "  ${WHITE}4)${NC} Забанить IP"
        echo -e "  ${WHITE}5)${NC} 🔔 Настройка уведомлений"
        echo -e "  ${WHITE}6)${NC} ⏱️  Настройка времени бана"
        echo -e "  ${WHITE}7)${NC} 🛡️  Расширенная защита"
        echo -e "  ${WHITE}8)${NC} 📋 Whitelist (доверенные IP)"
        echo -e "  ${WHITE}9)${NC} Перезапустить Fail2Ban"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) check_fail2ban_status ;;
            2) show_banned_ips ;;
            3)
                show_banned_ips
                echo ""
                read -p "IP для разбана: " ip
                unban_ip "$ip"
                ;;
            4)
                read -p "IP для бана: " ip
                ban_ip "$ip"
                ;;
            5) notifications_menu ;;
            6) bantime_menu ;;
            7) extended_protection_menu ;;
            8) whitelist_menu ;;
            9)
                systemctl restart fail2ban
                log_info "Fail2Ban перезапущен"
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# ============================================
# РАСШИРЕННАЯ ЗАЩИТА
# ============================================

# Whitelist файл
F2B_WHITELIST="/opt/server-shield/config/fail2ban-whitelist.txt"

# Получить whitelist IP
get_whitelist() {
    if [[ -f "$F2B_WHITELIST" ]]; then
        cat "$F2B_WHITELIST" | grep -v "^#" | grep -v "^$"
    fi
}

# Добавить IP в whitelist
add_to_whitelist() {
    local ip="$1"
    local comment="$2"
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    mkdir -p "$(dirname "$F2B_WHITELIST")"
    
    # Проверяем, не добавлен ли уже
    if grep -q "^$ip$" "$F2B_WHITELIST" 2>/dev/null; then
        log_warn "IP $ip уже в whitelist"
        return 0
    fi
    
    # Добавляем
    if [[ -n "$comment" ]]; then
        echo "# $comment" >> "$F2B_WHITELIST"
    fi
    echo "$ip" >> "$F2B_WHITELIST"
    
    # Обновляем ignoreip в jail.local
    update_ignoreip
    
    log_info "IP $ip добавлен в whitelist"
}

# Удалить IP из whitelist
remove_from_whitelist() {
    local ip="$1"
    
    if [[ -f "$F2B_WHITELIST" ]]; then
        sed -i "/^$ip$/d" "$F2B_WHITELIST"
        update_ignoreip
        log_info "IP $ip удалён из whitelist"
    fi
}

# Обновить ignoreip в jail.local
update_ignoreip() {
    local whitelist_ips=$(get_whitelist | tr '\n' ' ')
    local ignoreip="127.0.0.1/8 ::1 $whitelist_ips"
    
    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        sed -i "s/^ignoreip = .*/ignoreip = $ignoreip/" "$FAIL2BAN_JAIL"
        systemctl reload fail2ban 2>/dev/null
    fi
}

# Создать фильтр для portscan
create_portscan_filter() {
    cat > /etc/fail2ban/filter.d/portscan.conf << 'FILTER'
# Fail2Ban filter for port scanning detection
[Definition]
failregex = UFW BLOCK.* SRC=<HOST>
ignoreregex =
FILTER
}

# Создать фильтр для nginx-auth
create_nginx_auth_filter() {
    cat > /etc/fail2ban/filter.d/nginx-http-auth-shield.conf << 'FILTER'
# Fail2Ban filter for Nginx HTTP auth failures
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).* HTTP/.*" (401|403)
            no user/password was provided for basic authentication.*client: <HOST>
            user .* was not found in.*client: <HOST>
            user .* password mismatch.*client: <HOST>
ignoreregex =
FILTER
}

# Создать фильтр для nginx-badbots
create_nginx_badbots_filter() {
    cat > /etc/fail2ban/filter.d/nginx-badbots-shield.conf << 'FILTER'
# Fail2Ban filter for bad bots and scanners
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD) /(wp-admin|wp-login|phpmyadmin|admin|administrator|mysql|pma|dbadmin|myadmin|phpMyAdmin).* HTTP/.*" (404|403)
            ^<HOST> .* "(GET|POST|HEAD) /.*\.(env|git|svn|bak|old|sql|tar|gz|zip).* HTTP/.*"
ignoreregex =
FILTER
}

# Создать фильтр для mysql
create_mysql_filter() {
    cat > /etc/fail2ban/filter.d/mysqld-auth-shield.conf << 'FILTER'
# Fail2Ban filter for MySQL auth failures
[Definition]
failregex = Access denied for user .* from '<HOST>'
            Host '<HOST>' is blocked because of many connection errors
ignoreregex =
FILTER
}

# Добавить расширенные jail'ы
setup_extended_jails() {
    local bantime=$(get_bantime)
    
    # Создаём фильтры
    create_portscan_filter
    create_nginx_auth_filter
    create_nginx_badbots_filter
    create_mysql_filter
    
    # Проверяем есть ли Telegram action
    local tg_action=""
    if [[ -f "/etc/fail2ban/action.d/telegram-shield.conf" ]]; then
        tg_action="
         telegram-shield[name=portscan]"
        tg_action_nginx_auth="
         telegram-shield[name=nginx-auth]"
        tg_action_nginx_bots="
         telegram-shield[name=nginx-bots]"
        tg_action_mysql="
         telegram-shield[name=mysql]"
    else
        tg_action=""
        tg_action_nginx_auth=""
        tg_action_nginx_bots=""
        tg_action_mysql=""
    fi
    
    # Добавляем jail'ы в конфиг
    cat >> "$FAIL2BAN_JAIL" << JAILS

# ============================================
# Защита от сканирования портов
# ============================================
[portscan]
enabled = false
filter = portscan
logpath = /var/log/ufw.log
maxretry = 10
findtime = 60
bantime = $bantime
action = iptables-allports[name=portscan]$tg_action

# ============================================
# Защита Nginx - ошибки авторизации
# ============================================
[nginx-http-auth-shield]
enabled = false
filter = nginx-http-auth-shield
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 300
bantime = $bantime
action = iptables-multiport[name=nginx-auth, port="http,https"]$tg_action_nginx_auth

# ============================================
# Защита Nginx - сканеры и боты
# ============================================
[nginx-badbots-shield]
enabled = false
filter = nginx-badbots-shield
logpath = /var/log/nginx/access.log
maxretry = 15
findtime = 300
bantime = $bantime
action = iptables-multiport[name=nginx-bots, port="http,https"]$tg_action_nginx_bots

# ============================================
# Защита MySQL
# ============================================
[mysqld-auth-shield]
enabled = false
filter = mysqld-auth-shield
logpath = /var/log/mysql/error.log
maxretry = 5
findtime = 300
bantime = $bantime
action = iptables-multiport[name=mysql, port="3306"]$tg_action_mysql
JAILS

    log_info "Расширенные jail'ы созданы (отключены по умолчанию)"
}

# Создать универсальный Telegram action для всех jail'ов
create_telegram_action() {
    local tg_token="${1:-$(get_config "TG_BOT_TOKEN" "")}"
    local tg_chat_id="${2:-$(get_config "TG_CHAT_ID" "")}"
    
    # Если Telegram не настроен - пропускаем
    if [[ -z "$tg_token" ]] || [[ -z "$tg_chat_id" ]]; then
        return
    fi
    
    cat > /etc/fail2ban/action.d/telegram-shield.conf << ACTION
# Server Shield - Telegram notifications for all jails
[Definition]
actionstart =
actionstop =
actioncheck =

actionban = /opt/server-shield/scripts/fail2ban-notify-all.sh "<name>" "<ip>" "ban"
actionunban =

[Init]
name = default
ACTION

    # Создаём скрипт уведомлений
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > /opt/server-shield/scripts/fail2ban-notify-all.sh << SCRIPT
#!/bin/bash
# Fail2Ban Telegram Notify - All Jails

TOKEN="$tg_token"
CHAT_ID="$tg_chat_id"

# Проверяем режим уведомлений
MODE=\$(grep "^F2B_NOTIFY_MODE=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)

# Если режим не instant - не отправляем мгновенно (будет сводка)
if [[ "\$MODE" != "instant" ]]; then
    # Логируем для сводки
    echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1 | \$2 | \$3" >> /opt/server-shield/logs/fail2ban-bans.log
    exit 0
fi

JAIL="\$1"
IP="\$2"
ACTION="\$3"
HOSTNAME=\$(hostname)
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

# Определяем эмодзи и описание по типу jail
case "\$JAIL" in
    "sshd"|"ssh")
        EMOJI="🔐"
        DESC="SSH брутфорс"
        ;;
    "portscan")
        EMOJI="🔍"
        DESC="Сканирование портов"
        ;;
    "nginx-auth")
        EMOJI="🌐"
        DESC="Nginx брутфорс"
        ;;
    "nginx-bots")
        EMOJI="🤖"
        DESC="Nginx сканер/бот"
        ;;
    "mysql")
        EMOJI="🗄️"
        DESC="MySQL брутфорс"
        ;;
    *)
        EMOJI="🚫"
        DESC="\$JAIL"
        ;;
esac

MESSAGE="\$EMOJI Fail2Ban: Бан

Сервер: \$HOSTNAME
Причина: \$DESC
IP: \$IP
Время: \$DATE"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \\
    -d "chat_id=\$CHAT_ID" \\
    -d "text=\$MESSAGE" > /dev/null 2>&1
SCRIPT

    chmod +x /opt/server-shield/scripts/fail2ban-notify-all.sh
}

# Включить/выключить jail
toggle_jail() {
    local jail="$1"
    local action="$2"  # enable/disable
    
    if [[ "$action" == "enable" ]]; then
        sed -i "/^\[$jail\]/,/^\[/ s/enabled = false/enabled = true/" "$FAIL2BAN_JAIL"
        log_info "Jail '$jail' включен"
    else
        sed -i "/^\[$jail\]/,/^\[/ s/enabled = true/enabled = false/" "$FAIL2BAN_JAIL"
        log_info "Jail '$jail' выключен"
    fi
    
    systemctl reload fail2ban 2>/dev/null
}

# Проверить статус jail
get_jail_status() {
    local jail="$1"
    
    if grep -A2 "^\[$jail\]" "$FAIL2BAN_JAIL" 2>/dev/null | grep -q "enabled = true"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Меню whitelist
whitelist_menu() {
    while true; do
        print_header
        print_section "📋 Whitelist - Доверенные IP"
        
        echo ""
        echo -e "  ${WHITE}IP в whitelist никогда не будут забанены${NC}"
        echo -e "  ${CYAN}Добавьте сюда: ноды, боты, API сервера${NC}"
        echo ""
        
        local whitelist=$(get_whitelist)
        if [[ -n "$whitelist" ]]; then
            echo -e "  ${WHITE}Текущий whitelist:${NC}"
            echo "$whitelist" | while read ip; do
                echo -e "    ${GREEN}•${NC} $ip"
            done
        else
            echo -e "  ${YELLOW}Whitelist пуст${NC}"
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} Добавить IP"
        echo -e "  ${WHITE}2)${NC} Удалить IP"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                echo ""
                read -p "IP для whitelist: " ip
                read -p "Комментарий (опционально): " comment
                add_to_whitelist "$ip" "$comment"
                ;;
            2)
                echo ""
                read -p "IP для удаления: " ip
                remove_from_whitelist "$ip"
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Меню расширенной защиты
extended_protection_menu() {
    while true; do
        print_header
        print_section "🛡️ Расширенная защита Fail2Ban"
        
        echo ""
        echo -e "  ${WHITE}Статус jail'ов:${NC}"
        echo ""
        
        # SSH (всегда включен)
        echo -e "    ${GREEN}●${NC} SSH брутфорс — ${GREEN}Включен${NC}"
        
        # Portscan
        local portscan_status=$(get_jail_status "portscan")
        if [[ "$portscan_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Сканирование портов — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Сканирование портов — ${RED}Выключен${NC}"
        fi
        
        # Nginx auth
        local nginx_auth_status=$(get_jail_status "nginx-http-auth-shield")
        if [[ "$nginx_auth_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Nginx брутфорс — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Nginx брутфорс — ${RED}Выключен${NC}"
        fi
        
        # Nginx badbots
        local nginx_bots_status=$(get_jail_status "nginx-badbots-shield")
        if [[ "$nginx_bots_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Nginx сканеры/боты — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Nginx сканеры/боты — ${RED}Выключен${NC}"
        fi
        
        # MySQL
        local mysql_status=$(get_jail_status "mysqld-auth-shield")
        if [[ "$mysql_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} MySQL брутфорс — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} MySQL брутфорс — ${RED}Выключен${NC}"
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} 🔍 Сканирование портов (вкл/выкл)"
        echo -e "  ${WHITE}2)${NC} 🌐 Nginx брутфорс (вкл/выкл)"
        echo -e "  ${WHITE}3)${NC} 🤖 Nginx сканеры/боты (вкл/выкл)"
        echo -e "  ${WHITE}4)${NC} 🗄️  MySQL брутфорс (вкл/выкл)"
        echo ""
        echo -e "  ${WHITE}5)${NC} ✅ Включить всё"
        echo -e "  ${WHITE}6)${NC} ❌ Выключить всё"
        echo ""
        echo -e "  ${WHITE}w)${NC} 📋 Whitelist (доверенные IP)"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                if [[ "$(get_jail_status 'portscan')" == "enabled" ]]; then
                    toggle_jail "portscan" "disable"
                else
                    toggle_jail "portscan" "enable"
                fi
                sleep 1
                ;;
            2)
                if [[ "$(get_jail_status 'nginx-http-auth-shield')" == "enabled" ]]; then
                    toggle_jail "nginx-http-auth-shield" "disable"
                else
                    toggle_jail "nginx-http-auth-shield" "enable"
                fi
                sleep 1
                ;;
            3)
                if [[ "$(get_jail_status 'nginx-badbots-shield')" == "enabled" ]]; then
                    toggle_jail "nginx-badbots-shield" "disable"
                else
                    toggle_jail "nginx-badbots-shield" "enable"
                fi
                sleep 1
                ;;
            4)
                if [[ "$(get_jail_status 'mysqld-auth-shield')" == "enabled" ]]; then
                    toggle_jail "mysqld-auth-shield" "disable"
                else
                    toggle_jail "mysqld-auth-shield" "enable"
                fi
                sleep 1
                ;;
            5)
                toggle_jail "portscan" "enable"
                toggle_jail "nginx-http-auth-shield" "enable"
                toggle_jail "nginx-badbots-shield" "enable"
                toggle_jail "mysqld-auth-shield" "enable"
                sleep 1
                ;;
            6)
                toggle_jail "portscan" "disable"
                toggle_jail "nginx-http-auth-shield" "disable"
                toggle_jail "nginx-badbots-shield" "disable"
                toggle_jail "mysqld-auth-shield" "disable"
                sleep 1
                ;;
            w|W) whitelist_menu ;;
            0) return ;;
            *) 
                log_error "Неверный выбор"
                press_any_key
                ;;
        esac
    done
}