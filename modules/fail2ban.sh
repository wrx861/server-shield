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
    local admin_ip="${5:-}"      # IP админа для whitelist
    
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
    
    # Собираем ignoreip: localhost + IP админа + текущее подключение + whitelist
    local ignoreip="127.0.0.1/8 ::1"
    
    # Добавляем IP админа если указан
    if [[ -n "$admin_ip" ]]; then
        ignoreip="$ignoreip $admin_ip"
        # Также сохраняем в whitelist файл
        mkdir -p "$(dirname "$F2B_WHITELIST")"
        if ! grep -q "^$admin_ip$" "$F2B_WHITELIST" 2>/dev/null; then
            echo "# Admin IP (добавлен при установке)" >> "$F2B_WHITELIST"
            echo "$admin_ip" >> "$F2B_WHITELIST"
        fi
    fi
    
    # Добавляем IP текущего SSH подключения (защита от самобана)
    local current_ip=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -n "$current_ip" ]] && [[ "$current_ip" != "$admin_ip" ]]; then
        ignoreip="$ignoreip $current_ip"
        # Сохраняем в whitelist
        if ! grep -q "^$current_ip$" "$F2B_WHITELIST" 2>/dev/null; then
            echo "# Current session IP (автоопределение)" >> "$F2B_WHITELIST"
            echo "$current_ip" >> "$F2B_WHITELIST"
        fi
        log_info "Ваш текущий IP $current_ip добавлен в whitelist"
    fi
    
    # Добавляем IP из существующего whitelist файла
    if [[ -f "$F2B_WHITELIST" ]]; then
        local whitelist_ips=$(grep -v "^#" "$F2B_WHITELIST" | grep -v "^$" | tr '\n' ' ')
        ignoreip="$ignoreip $whitelist_ips"
    fi
    
    # Убираем дубликаты
    ignoreip=$(echo "$ignoreip" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    
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
ignoreip = $ignoreip
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
    local tg_thread_id="$3"
    
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > "$FAIL2BAN_SUMMARY_SCRIPT" << 'SCRIPT'
#!/bin/bash
# Fail2Ban Summary Report - All Jails
# С поддержкой групп и тем

TOKEN="__TOKEN__"
CHAT_ID="__CHAT_ID__"
THREAD_ID="__THREAD_ID__"

# Получаем имя сервера (пользовательское или hostname)
SERVER_NAME=$(grep "^SERVER_NAME=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)
if [[ -z "$SERVER_NAME" ]]; then
    SERVER_NAME=$(hostname)
fi

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

Сервер: $SERVER_NAME
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

# Формируем параметры для curl
PARAMS="-d chat_id=$CHAT_ID"
PARAMS="$PARAMS --data-urlencode text=$MESSAGE"

# Добавляем thread_id если указан
if [[ -n "$THREAD_ID" ]] && [[ "$THREAD_ID" != "0" ]]; then
    PARAMS="$PARAMS -d message_thread_id=$THREAD_ID"
fi

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" $PARAMS > /dev/null 2>&1
SCRIPT

    # Подставляем токен, chat_id и thread_id
    sed -i "s|__TOKEN__|$tg_token|g" "$FAIL2BAN_SUMMARY_SCRIPT"
    sed -i "s|__CHAT_ID__|$tg_chat_id|g" "$FAIL2BAN_SUMMARY_SCRIPT"
    sed -i "s|__THREAD_ID__|$tg_thread_id|g" "$FAIL2BAN_SUMMARY_SCRIPT"
    
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
    # По умолчанию instant если Telegram настроен, иначе off
    local default="off"
    local tg_token=$(get_config "TG_TOKEN" "")
    if [[ -n "$tg_token" ]]; then
        default="instant"
    fi
    get_config "F2B_NOTIFY_MODE" "$default"
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

# Переинициализировать Telegram action (после смены токена)
reinit_telegram_action() {
    log_step "Переинициализация Telegram уведомлений..."
    
    local tg_token=$(get_config "TG_TOKEN" "")
    local tg_chat_id=$(get_config "TG_CHAT_ID" "")
    local tg_thread_id=$(get_config "TG_THREAD_ID" "")
    
    if [[ -z "$tg_token" ]] || [[ -z "$tg_chat_id" ]]; then
        log_error "Telegram не настроен!"
        echo -e "   Настройте через: ${CYAN}shield telegram${NC}"
        return 1
    fi
    
    # Пересоздаём action и скрипты с поддержкой thread_id
    create_telegram_action "$tg_token" "$tg_chat_id" "$tg_thread_id"
    
    # Пересоздаём скрипт сводки
    setup_summary_script "$tg_token" "$tg_chat_id" "$tg_thread_id"
    
    # Устанавливаем режим instant по умолчанию если не установлен
    local current_mode=$(get_notify_mode)
    if [[ "$current_mode" == "off" ]] || [[ -z "$current_mode" ]]; then
        save_config "F2B_NOTIFY_MODE" "instant"
    fi
    
    # Перезапускаем Fail2Ban
    systemctl restart fail2ban 2>/dev/null || service fail2ban restart
    
    log_info "Telegram уведомления переинициализированы!"
    echo -e "   Token: ${CYAN}${tg_token:0:10}...${NC}"
    echo -e "   Chat ID: ${CYAN}$tg_chat_id${NC}"
    if [[ -n "$tg_thread_id" ]] && [[ "$tg_thread_id" != "0" ]]; then
        echo -e "   Thread ID: ${CYAN}$tg_thread_id${NC} (тема в группе)"
    fi
    echo -e "   Режим: ${CYAN}$(get_notify_mode)${NC}"
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

# Диагностика Telegram уведомлений
diagnose_telegram() {
    print_section "🔍 Диагностика Telegram уведомлений"
    echo ""
    
    local tg_token=$(get_config "TG_TOKEN" "")
    local tg_chat_id=$(get_config "TG_CHAT_ID" "")
    local notify_mode=$(get_notify_mode)
    
    # 1. Проверяем конфиг
    echo -e "${WHITE}1. Конфигурация:${NC}"
    if [[ -n "$tg_token" ]]; then
        echo -e "   ${GREEN}✓${NC} TG_TOKEN: ${CYAN}${tg_token:0:10}...${NC}"
    else
        echo -e "   ${RED}✗${NC} TG_TOKEN: ${RED}Не задан!${NC}"
    fi
    
    if [[ -n "$tg_chat_id" ]]; then
        echo -e "   ${GREEN}✓${NC} TG_CHAT_ID: ${CYAN}$tg_chat_id${NC}"
    else
        echo -e "   ${RED}✗${NC} TG_CHAT_ID: ${RED}Не задан!${NC}"
    fi
    
    echo -e "   Режим уведомлений: ${CYAN}$notify_mode${NC}"
    
    # 2. Проверяем файлы
    echo ""
    echo -e "${WHITE}2. Файлы:${NC}"
    
    if [[ -f "/etc/fail2ban/action.d/telegram-shield.conf" ]]; then
        echo -e "   ${GREEN}✓${NC} telegram-shield.conf существует"
    else
        echo -e "   ${RED}✗${NC} telegram-shield.conf ${RED}НЕ НАЙДЕН!${NC}"
    fi
    
    if [[ -x "/opt/server-shield/scripts/fail2ban-notify-all.sh" ]]; then
        echo -e "   ${GREEN}✓${NC} fail2ban-notify-all.sh существует и исполняемый"
    else
        echo -e "   ${RED}✗${NC} fail2ban-notify-all.sh ${RED}НЕ НАЙДЕН или не исполняемый!${NC}"
    fi
    
    if [[ -f "/opt/server-shield/config/shield.conf" ]]; then
        echo -e "   ${GREEN}✓${NC} shield.conf существует"
    else
        echo -e "   ${RED}✗${NC} shield.conf ${RED}НЕ НАЙДЕН!${NC}"
    fi
    
    # 3. Проверяем jail.local
    echo ""
    echo -e "${WHITE}3. Конфиг Fail2Ban:${NC}"
    if grep -q "telegram-shield" /etc/fail2ban/jail.local 2>/dev/null; then
        echo -e "   ${GREEN}✓${NC} telegram-shield action используется в jail.local"
    else
        echo -e "   ${RED}✗${NC} telegram-shield action ${RED}НЕ ДОБАВЛЕН в jail.local!${NC}"
        echo -e "   ${YELLOW}   Выполните: shield → Fail2Ban → Настройка уведомлений → Переинициализировать${NC}"
    fi
    
    # 4. Проверяем лог отладки
    echo ""
    echo -e "${WHITE}4. Последние вызовы (debug log):${NC}"
    if [[ -f "/opt/server-shield/logs/fail2ban-debug.log" ]]; then
        echo -e "   ${CYAN}$(tail -5 /opt/server-shield/logs/fail2ban-debug.log 2>/dev/null)${NC}"
    else
        echo -e "   ${YELLOW}Лог отладки пуст (нет банов или скрипт не вызывался)${NC}"
    fi
    
    # 5. Тест отправки
    echo ""
    echo -e "${WHITE}5. Тест отправки:${NC}"
    if [[ -n "$tg_token" ]] && [[ -n "$tg_chat_id" ]]; then
        local response
        response=$(curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
            -d "chat_id=${tg_chat_id}" \
            -d "text=🔧 Диагностика: тестовое сообщение от $(hostname)" 2>&1)
        
        if echo "$response" | grep -q '"ok":true'; then
            echo -e "   ${GREEN}✓${NC} Тестовое сообщение отправлено успешно!"
        else
            echo -e "   ${RED}✗${NC} Ошибка отправки!"
            echo -e "   ${RED}$response${NC}"
        fi
    else
        echo -e "   ${YELLOW}Пропущено - токен или chat_id не заданы${NC}"
    fi
}

# Показать забаненные IP (ВСЕ jail'ы)
show_banned_ips() {
    echo ""
    echo -e "${WHITE}Забаненные IP:${NC}"
    echo ""
    
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "  ${RED}fail2ban-client не найден${NC}"
        return
    fi
    
    local found_any=false
    
    # Получаем список всех активных jail'ов
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | tr ',' ' ' | tr -d '\t')
    
    for jail in $jails; do
        jail=$(echo "$jail" | xargs)  # trim
        [[ -z "$jail" ]] && continue
        
        local banned_list=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | cut -d: -f2 | xargs)
        
        if [[ -n "$banned_list" ]] && [[ "$banned_list" != " " ]]; then
            found_any=true
            
            # Определяем название jail
            case "$jail" in
                "sshd") jail_name="🔐 SSH" ;;
                "portscan") jail_name="🔍 Portscan" ;;
                "nginx-http-auth-shield") jail_name="🌐 Nginx Auth" ;;
                "nginx-badbots-shield") jail_name="🤖 Nginx Bots" ;;
                "mysqld-auth-shield") jail_name="🗄️ MySQL" ;;
                *) jail_name="$jail" ;;
            esac
            
            echo -e "  ${YELLOW}$jail_name ($jail):${NC}"
            echo "$banned_list" | tr ' ' '\n' | while read ip; do
                [[ -n "$ip" ]] && echo -e "    ${RED}•${NC} $ip"
            done
            echo ""
        fi
    done
    
    if [[ "$found_any" == false ]]; then
        echo -e "  ${GREEN}Нет забаненных IP ни в одном jail${NC}"
    fi
}

# Разбанить IP (во ВСЕХ jail'ах)
unban_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    if ! command -v fail2ban-client &> /dev/null; then
        log_error "fail2ban-client не найден"
        return 1
    fi
    
    local unbanned=false
    
    # Получаем список всех активных jail'ов
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | tr ',' ' ' | tr -d '\t')
    
    for jail in $jails; do
        jail=$(echo "$jail" | xargs)  # trim
        [[ -z "$jail" ]] && continue
        
        # Проверяем есть ли IP в этом jail
        if fail2ban-client status "$jail" 2>/dev/null | grep -q "$ip"; then
            fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_info "IP $ip разбанен в jail '$jail'"
                unbanned=true
            fi
        fi
    done
    
    if [[ "$unbanned" == false ]]; then
        log_warn "IP $ip не найден ни в одном jail"
    fi
}

# Бан IP вручную (в указанный jail или sshd по умолчанию)
ban_ip() {
    local ip="$1"
    local jail="${2:-sshd}"
    
    if [[ -z "$ip" ]]; then
        log_error "IP не указан"
        return 1
    fi
    
    if ! validate_ip "$ip"; then
        log_error "Неверный IP: $ip"
        return 1
    fi
    
    if command -v fail2ban-client &> /dev/null; then
        fail2ban-client set "$jail" banip "$ip" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_info "IP $ip забанен в jail '$jail'"
        else
            log_error "Не удалось забанить IP $ip в jail '$jail'"
        fi
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
        echo -e "  ${WHITE}8)${NC} 🔧 Переинициализировать Telegram (после смены токена)"
        echo -e "  ${WHITE}9)${NC} 🔍 Диагностика (если не работает)"
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
            8)
                reinit_telegram_action
                ;;
            9)
                diagnose_telegram
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
        print_header_mini "Fail2Ban"
        
        # Статус
        local f2b_status=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")
        local jails_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}' || echo 0)
        local total_banned=$(fail2ban-client status 2>/dev/null | grep -A100 "Jail list" | grep "Currently banned" | awk '{sum+=$NF} END {print sum}' 2>/dev/null || echo 0)
        local bantime_human=$(get_bantime_human 2>/dev/null || echo "N/A")
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        if [[ "$f2b_status" == "active" ]]; then
            echo -e "    ${DIM}│${NC} Status: ${GREEN}● Running${NC}      Jails: ${CYAN}$jails_count${NC}                ${DIM}│${NC}"
        else
            echo -e "    ${DIM}│${NC} Status: ${RED}○ Stopped${NC}                                    ${DIM}│${NC}"
        fi
        echo -e "    ${DIM}│${NC} Banned: ${RED}$total_banned${NC}            Ban time: ${CYAN}$bantime_human${NC}        ${DIM}│${NC}"
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Статус Fail2Ban"
        menu_item "2" "Список забаненных IP"
        menu_item "3" "Разбанить IP"
        menu_item "4" "Забанить IP"
        menu_divider
        menu_item "5" "Уведомления"
        menu_item "6" "Время бана"
        menu_item "7" "Расширенная защита"
        menu_item "8" "Whitelist (доверенные IP)"
        menu_divider
        menu_item "9" "Перезапустить Fail2Ban"
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1) 
                check_fail2ban_status 
                press_any_key
                ;;
            2) 
                show_banned_ips 
                press_any_key
                ;;
            3)
                show_banned_ips
                echo ""
                local ip
                input_value "IP для разбана" "" ip
                [[ -n "$ip" ]] && unban_ip "$ip"
                press_any_key
                ;;
            4)
                local ip
                input_value "IP для бана" "" ip
                [[ -n "$ip" ]] && ban_ip "$ip"
                press_any_key
                ;;
            5) notifications_menu ;;
            6) bantime_menu ;;
            7) extended_protection_menu ;;
            8) whitelist_f2b_menu ;;
            9)
                log_step "Перезапуск Fail2Ban..."
                systemctl restart fail2ban
                log_info "Fail2Ban перезапущен"
                press_any_key
                ;;
            0|q) return ;;
        esac
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
    # Получаем список игнорируемых портов из конфига (для VPN клиентов)
    local ignore_ports=$(get_config "PORTSCAN_IGNORE_PORTS" "443,8443")
    
    cat > /etc/fail2ban/filter.d/portscan.conf << FILTER
# Fail2Ban filter for port scanning detection
# Поддерживает syslog формат и kern.log/ufw.log
# Игнорирует VPN порты: $ignore_ports

[Definition]
# Формат syslog: timestamp hostname kernel: [UFW BLOCK] ... SRC=IP
# Формат kern.log: timestamp hostname kernel: [UFW BLOCK] ... SRC=IP
failregex = ^\s*\S+\s+\S+\s+\S+\s+kernel:\s+\[UFW BLOCK\].*SRC=<HOST>
            ^.*\[UFW BLOCK\].*SRC=<HOST>
            UFW BLOCK.*SRC=<HOST>

# Игнорируем запросы на VPN порты (443, 8443 и т.д.) - это клиенты проверяют доступность
ignoreregex = DPT=(443|8443|80)\\s
              DPT=443\\s
              DPT=8443\\s
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
# Пробуем разные логи: syslog (Ubuntu 22+), ufw.log, kern.log
logpath = /var/log/syslog
          /var/log/ufw.log
          /var/log/kern.log
# ВАЖНО: backend = auto для чтения из файла (не systemd)
backend = auto
maxretry = 5
findtime = 120
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
    local tg_token="${1:-$(get_config "TG_TOKEN" "")}"
    local tg_chat_id="${2:-$(get_config "TG_CHAT_ID" "")}"
    local tg_thread_id="${3:-$(get_config "TG_THREAD_ID" "")}"
    
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

    # Создаём скрипт уведомлений с поддержкой thread_id
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > /opt/server-shield/scripts/fail2ban-notify-all.sh << SCRIPT
#!/bin/bash
# Fail2Ban Telegram Notify - All Jails
# С поддержкой групп и тем (topics)

TOKEN="$tg_token"
CHAT_ID="$tg_chat_id"
THREAD_ID="$tg_thread_id"

# Логируем вызов для отладки
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Called with: \$1 \$2 \$3" >> /opt/server-shield/logs/fail2ban-debug.log

# Проверяем режим уведомлений (по умолчанию instant)
MODE=\$(grep "^F2B_NOTIFY_MODE=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)
MODE=\${MODE:-instant}

# Если режим off - не отправляем
if [[ "\$MODE" == "off" ]]; then
    exit 0
fi

# Если режим не instant - логируем для сводки и выходим
if [[ "\$MODE" != "instant" ]]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1 | \$2 | \$3" >> /opt/server-shield/logs/fail2ban-bans.log
    exit 0
fi

JAIL="\$1"
IP="\$2"
ACTION="\$3"

# Получаем имя сервера (пользовательское или hostname)
SERVER_NAME=\$(grep "^SERVER_NAME=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)
if [[ -z "\$SERVER_NAME" ]]; then
    SERVER_NAME=\$(hostname)
fi

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

Сервер: \$SERVER_NAME
Причина: \$DESC
IP: \$IP
Время: \$DATE"

# Формируем параметры для curl
PARAMS="-d chat_id=\$CHAT_ID"
PARAMS="\$PARAMS --data-urlencode text=\$MESSAGE"

# Добавляем thread_id если указан (для тем в группах)
if [[ -n "\$THREAD_ID" ]] && [[ "\$THREAD_ID" != "0" ]]; then
    PARAMS="\$PARAMS -d message_thread_id=\$THREAD_ID"
fi

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \$PARAMS > /dev/null 2>&1
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

# Получить IP текущего SSH подключения
get_current_session_ip() {
    # Пробуем несколько способов определить IP
    local ip=""
    
    # Способ 1: who am i
    ip=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    [[ -n "$ip" ]] && echo "$ip" && return
    
    # Способ 2: SSH_CLIENT
    ip=$(echo "$SSH_CLIENT" 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && echo "$ip" && return
    
    # Способ 3: SSH_CONNECTION
    ip=$(echo "$SSH_CONNECTION" 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && echo "$ip" && return
    
    echo ""
}

# Автодобавление текущего IP в whitelist
auto_whitelist_current_ip() {
    local current_ip=$(get_current_session_ip)
    
    if [[ -n "$current_ip" ]]; then
        if ! grep -q "^$current_ip$" "$F2B_WHITELIST" 2>/dev/null; then
            add_to_whitelist "$current_ip" "Auto: текущая сессия $(date '+%Y-%m-%d')"
            log_info "Ваш IP $current_ip автоматически добавлен в whitelist"
            return 0
        fi
    fi
    return 1
}

# Меню whitelist Fail2Ban
whitelist_f2b_menu() {
    while true; do
        print_header_mini "Whitelist (Fail2Ban)"
        
        local current_ip=$(get_current_session_ip 2>/dev/null)
        local current_in_whitelist=false
        [[ -n "$current_ip" ]] && grep -q "^$current_ip$" "$F2B_WHITELIST" 2>/dev/null && current_in_whitelist=true
        
        echo -e "    ${DIM}IP в whitelist никогда не будут забанены Fail2Ban${NC}"
        echo ""
        
        if [[ -n "$current_ip" ]]; then
            if [[ "$current_in_whitelist" == true ]]; then
                echo -e "    Ваш IP: ${GREEN}$current_ip${NC} ${GREEN}✓ защищён${NC}"
            else
                echo -e "    Ваш IP: ${YELLOW}$current_ip${NC} ${RED}✗ НЕ защищён!${NC}"
            fi
            echo ""
        fi
        
        local whitelist=$(get_whitelist 2>/dev/null)
        if [[ -n "$whitelist" ]]; then
            echo -e "    ${WHITE}Whitelist:${NC}"
            echo "$whitelist" | while read ip; do
                if [[ "$ip" == "$current_ip" ]]; then
                    echo -e "      ${GREEN}●${NC} $ip ${CYAN}(вы)${NC}"
                else
                    echo -e "      ${GREEN}●${NC} $ip"
                fi
            done
        else
            echo -e "    ${YELLOW}Whitelist пуст${NC}"
        fi
        
        menu_divider
        
        if [[ -n "$current_ip" ]] && [[ "$current_in_whitelist" == false ]]; then
            echo -e "    ${GREEN}[1]${NC} ${GREEN}Добавить мой IP ($current_ip)${NC}"
            menu_item "2" "Добавить другой IP"
        else
            menu_item "1" "Добавить IP"
        fi
        menu_item "3" "Удалить IP"
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                if [[ -n "$current_ip" ]] && [[ "$current_in_whitelist" == false ]]; then
                    add_to_whitelist "$current_ip" "Админ (добавлен вручную)"
                else
                    local ip comment
                    input_value "IP для whitelist" "" ip
                    input_value "Комментарий (опционально)" "" comment
                    [[ -n "$ip" ]] && add_to_whitelist "$ip" "$comment"
                fi
                press_any_key
                ;;
            2)
                local ip comment
                input_value "IP для whitelist" "" ip
                input_value "Комментарий (опционально)" "" comment
                [[ -n "$ip" ]] && add_to_whitelist "$ip" "$comment"
                press_any_key
                ;;
            3)
                local ip
                input_value "IP для удаления" "" ip
                [[ -n "$ip" ]] && remove_from_whitelist "$ip"
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# Меню расширенной защиты
extended_protection_menu() {
    while true; do
        print_header_mini "Расширенная защита Fail2Ban"
        
        # Статус jail'ов
        local portscan_status=$(get_jail_status "portscan" 2>/dev/null)
        local nginx_auth_status=$(get_jail_status "nginx-http-auth-shield" 2>/dev/null)
        local nginx_bots_status=$(get_jail_status "nginx-badbots-shield" 2>/dev/null)
        local mysql_status=$(get_jail_status "mysqld-auth-shield" 2>/dev/null)
        local ignore_ports=$(get_config "PORTSCAN_IGNORE_PORTS" "443,8443" 2>/dev/null)
        
        echo -e "    ${WHITE}Статус jail'ов:${NC}"
        echo ""
        echo -e "    ${GREEN}●${NC} SSH брутфорс      — ${GREEN}Включен${NC}"
        
        if [[ "$portscan_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Portscan          — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Portscan          — ${RED}Выключен${NC}"
        fi
        
        if [[ "$nginx_auth_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Nginx брутфорс    — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Nginx брутфорс    — ${RED}Выключен${NC}"
        fi
        
        if [[ "$nginx_bots_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} Nginx боты        — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} Nginx боты        — ${RED}Выключен${NC}"
        fi
        
        if [[ "$mysql_status" == "enabled" ]]; then
            echo -e "    ${GREEN}●${NC} MySQL брутфорс    — ${GREEN}Включен${NC}"
        else
            echo -e "    ${RED}○${NC} MySQL брутфорс    — ${RED}Выключен${NC}"
        fi
        
        echo ""
        echo -e "    ${DIM}Игнор портов (VPN):${NC} ${CYAN}$ignore_ports${NC}"
        
        menu_divider
        menu_item "1" "Portscan (вкл/выкл)"
        menu_item "2" "Nginx брутфорс (вкл/выкл)"
        menu_item "3" "Nginx боты (вкл/выкл)"
        menu_item "4" "MySQL брутфорс (вкл/выкл)"
        menu_divider
        echo -e "    ${GREEN}[5]${NC} ${GREEN}Включить всё${NC}"
        echo -e "    ${RED}[6]${NC} ${RED}Выключить всё${NC}"
        menu_item "7" "Настроить игнор портов"
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1) toggle_jail "portscan"; press_any_key ;;
            2) toggle_jail "nginx-http-auth-shield"; press_any_key ;;
            3) toggle_jail "nginx-badbots-shield"; press_any_key ;;
            4) toggle_jail "mysqld-auth-shield"; press_any_key ;;
            5)
                enable_all_jails
                press_any_key
                ;;
            6)
                disable_all_jails
                press_any_key
                ;;
            7) configure_ignore_ports; press_any_key ;;
            0|q) return ;;
        esac
    done
}

# Вспомогательные функции для extended_protection_menu
enable_all_jails() {
    log_step "Включение всех jail'ов..."
    create_portscan_filter 2>/dev/null
    toggle_jail "portscan" "enable"
    toggle_jail "nginx-http-auth-shield" "enable"
    toggle_jail "nginx-badbots-shield" "enable"
    toggle_jail "mysqld-auth-shield" "enable"
    sleep 1
    log_info "Все jail'ы включены"
}

disable_all_jails() {
    log_step "Выключение всех jail'ов..."
    toggle_jail "portscan" "disable"
    toggle_jail "nginx-http-auth-shield" "disable"
    toggle_jail "nginx-badbots-shield" "disable"
    toggle_jail "mysqld-auth-shield" "disable"
    sleep 1
    log_info "Все jail'ы выключены"
}

configure_ignore_ports() {
    print_header_mini "Настройка игнорируемых портов"
    
    local current=$(get_config "PORTSCAN_IGNORE_PORTS" "443,8443")
    echo -e "    ${DIM}Эти порты не будут триггерить portscan защиту${NC}"
    echo -e "    ${DIM}Для VPN клиентов (HAPP и др.)${NC}"
    echo ""
    echo -e "    ${WHITE}Текущие:${NC} ${CYAN}$current${NC}"
    echo ""
    
    local ports
    input_value "Новые порты (через запятую)" "$current" ports
    
    if [[ -n "$ports" ]]; then
        save_config "PORTSCAN_IGNORE_PORTS" "$ports"
        create_portscan_filter 2>/dev/null
        
        if get_jail_status "portscan" | grep -q "enabled"; then
            fail2ban-client reload portscan 2>/dev/null
        fi
        
        log_info "Игнорируемые порты обновлены: $ports"
    fi
}

# Настройка игнорируемых портов для portscan (для VPN клиентов типа HAPP)
configure_portscan_ignore_ports() {
    print_section "⚙️ Настройка игнорируемых портов"
    
    local current_ports=$(get_config "PORTSCAN_IGNORE_PORTS" "443,8443")
    
    echo ""
    echo -e "${WHITE}Эти порты будут исключены из детекта сканирования.${NC}"
    echo -e "${WHITE}Используйте для VPN портов, чтобы клиенты (HAPP и др.)${NC}"
    echo -e "${WHITE}не банились при проверке доступности.${NC}"
    echo ""
    echo -e "Текущие порты: ${CYAN}$current_ports${NC}"
    echo ""
    echo -e "${YELLOW}Примеры:${NC}"
    echo -e "  443,8443        — HTTPS и альтернативный"
    echo -e "  443,8443,2053   — плюс Cloudflare порт"
    echo -e "  443             — только HTTPS"
    echo ""
    
    read -p "Порты через запятую [$current_ports]: " new_ports
    new_ports=${new_ports:-$current_ports}
    
    # Валидация
    if [[ ! "$new_ports" =~ ^[0-9,]+$ ]]; then
        log_error "Неверный формат. Используйте только цифры и запятые."
        return 1
    fi
    
    # Сохраняем
    save_config "PORTSCAN_IGNORE_PORTS" "$new_ports"
    
    # Пересоздаём фильтр
    create_portscan_filter
    
    # Перезагружаем Fail2Ban если portscan включен
    if [[ "$(get_jail_status 'portscan')" == "enabled" ]]; then
        systemctl reload fail2ban 2>/dev/null
        log_info "Fail2Ban перезагружен с новыми настройками"
    fi
    
    log_info "Порты обновлены: $new_ports"
    echo ""
    echo -e "${GREEN}Теперь запросы на порты ${CYAN}$new_ports${GREEN} не будут считаться сканированием.${NC}"
    press_any_key
}