#!/bin/bash
#
# telegram.sh - Telegram уведомления
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# Получаем настройки Telegram
get_tg_config() {
    TG_TOKEN=$(get_config "TG_TOKEN" "")
    TG_CHAT_ID=$(get_config "TG_CHAT_ID" "")
}

# Отправка сообщения в Telegram с проверкой
send_telegram() {
    local message="$1"
    
    get_tg_config
    
    if [[ -z "$TG_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        return 1
    fi
    
    # Отправляем и проверяем результат
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" 2>&1)
    
    # Проверяем успех
    if echo "$response" | grep -q '"ok":true'; then
        return 0
    else
        echo "$response" >> /opt/server-shield/logs/telegram_errors.log 2>/dev/null
        return 1
    fi
}

# Уведомление о SSH входе
send_ssh_login() {
    local user="$1"
    local ip="$2"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🔓 SSH Login

Сервер: ${hostname}
IP сервера: ${server_ip}
Пользователь: ${user}
IP клиента: ${ip}
Время: ${date}"
    
    send_telegram "$message"
}

# Уведомление о бане Fail2Ban
send_ban() {
    local ip="$1"
    local jail="$2"
    local bantime="$3"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🚫 Fail2Ban: IP Забанен

Сервер: ${hostname}
IP сервера: ${server_ip}
Забанен IP: ${ip}
Jail: ${jail}
Время бана: ${bantime}
Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление о разбане
send_unban() {
    local ip="$1"
    local jail="$2"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="✅ Fail2Ban: IP Разбанен

Сервер: ${hostname}
IP: ${ip}
Jail: ${jail}
Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление об установке защиты
send_install_complete() {
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local ssh_port=$(get_config "SSH_PORT" "22")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🛡️ Server Shield Установлен!

Сервер: ${hostname}
IP: ${server_ip}
SSH порт: ${ssh_port}

✅ SSH Hardening
✅ Kernel Hardening
✅ UFW Firewall
✅ Fail2Ban
✅ Telegram уведомления

Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление о rootkit
send_rootkit_alert() {
    local warning="$1"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="⚠️ Rootkit Alert!

Сервер: ${hostname}
IP: ${server_ip}
Предупреждение:
${warning}

Дата: ${date}

⚠️ Требуется проверка!"
    
    send_telegram "$message"
}

# Тестовое сообщение
send_test() {
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    get_tg_config
    
    local message="🧪 Тестовое сообщение

Сервер: ${hostname}
IP: ${server_ip}
Дата: ${date}

✅ Telegram уведомления работают!"
    
    echo ""
    log_step "Отправка тестового сообщения..."
    echo -e "   Token: ${TG_TOKEN:0:10}..."
    echo -e "   Chat ID: ${TG_CHAT_ID}"
    echo ""
    
    # Отправляем и показываем результат
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" 2>&1)
    
    if echo "$response" | grep -q '"ok":true'; then
        log_info "Сообщение успешно отправлено!"
        return 0
    else
        log_error "Ошибка отправки!"
        echo ""
        echo -e "${RED}Ответ Telegram API:${NC}"
        echo "$response" | head -5
        echo ""
        echo -e "${YELLOW}Проверьте:${NC}"
        echo "  1. Токен бота правильный?"
        echo "  2. Вы написали боту /start?"
        echo "  3. Chat ID правильный? (ваш личный ID - просто число, напр. 123456789)"
        return 1
    fi
}

# Настройка SSH Login уведомлений
setup_ssh_login_notify() {
    log_step "Настройка SSH Login уведомлений..."
    
    get_tg_config
    
    # Создаём скрипт для PAM с токеном напрямую
    cat > /etc/ssh/notify-login.sh << SCRIPT
#!/bin/bash
if [ "\$PAM_TYPE" = "open_session" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \\
        -d "chat_id=${TG_CHAT_ID}" \\
        -d "text=🔓 SSH Login%0A%0AСервер: \$(hostname)%0AПользователь: \$PAM_USER%0AIP: \$PAM_RHOST%0AВремя: \$(date '+%Y-%m-%d %H:%M:%S')" \\
        > /dev/null 2>&1
fi
SCRIPT
    
    chmod +x /etc/ssh/notify-login.sh
    
    # Добавляем в PAM (если ещё не добавлено)
    if ! grep -q "notify-login.sh" /etc/pam.d/sshd 2>/dev/null; then
        echo "session optional pam_exec.so /etc/ssh/notify-login.sh" >> /etc/pam.d/sshd
    fi
    
    log_info "SSH Login уведомления настроены"
}

# Меню Telegram
telegram_menu() {
    while true; do
        print_header
        print_section "📱 Telegram Уведомления"
        
        get_tg_config
        
        echo ""
        if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
            echo -e "  ${GREEN}✓${NC} Telegram настроен"
            echo -e "    Chat ID: ${CYAN}$TG_CHAT_ID${NC}"
        else
            echo -e "  ${YELLOW}○${NC} Telegram не настроен"
        fi
        
        echo ""
        echo -e "  ${WHITE}1)${NC} Настроить Telegram"
        echo -e "  ${WHITE}2)${NC} Отправить тестовое сообщение"
        echo -e "  ${WHITE}3)${NC} Отключить Telegram"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                echo ""
                echo -e "${WHITE}Шаг 1: Получите токен бота${NC}"
                echo "  1. Откройте @BotFather в Telegram"
                echo "  2. Отправьте /newbot"
                echo "  3. Скопируйте токен"
                echo ""
                read -p "Bot Token: " token
                
                echo ""
                echo -e "${WHITE}Шаг 2: Узнайте ваш Telegram ID${NC}"
                echo "  1. Откройте @userinfobot или @getmyid_bot в Telegram"
                echo "  2. Нажмите /start"
                echo "  3. Скопируйте ваш ID (просто число, напр. 123456789)"
                echo ""
                echo -e "  ${CYAN}💡 Используйте один и тот же токен и ID на всех серверах!${NC}"
                echo -e "  ${CYAN}   Уведомления со всех нод/панелей придут в один чат.${NC}"
                echo ""
                read -p "ID администратора: " chat_id
                
                if [[ -n "$token" ]] && [[ -n "$chat_id" ]]; then
                    save_config "TG_TOKEN" "$token"
                    save_config "TG_CHAT_ID" "$chat_id"
                    
                    # Сначала тестируем
                    TG_TOKEN="$token"
                    TG_CHAT_ID="$chat_id"
                    
                    if send_test; then
                        setup_ssh_login_notify
                        log_info "Telegram настроен!"
                    else
                        log_warn "Настройки сохранены, но тест не прошёл. Проверьте данные."
                    fi
                fi
                ;;
            2)
                send_test
                ;;
            3)
                save_config "TG_TOKEN" ""
                save_config "TG_CHAT_ID" ""
                rm -f /etc/ssh/notify-login.sh
                sed -i '/notify-login.sh/d' /etc/pam.d/sshd 2>/dev/null
                log_info "Telegram отключен"
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# CLI интерфейс
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    action="$1"
    shift
    
    case "$action" in
        send_ssh_login) send_ssh_login "$@" ;;
        send_ban) send_ban "$@" ;;
        send_unban) send_unban "$@" ;;
        send_test) send_test ;;
        *) telegram_menu ;;
    esac
fi
