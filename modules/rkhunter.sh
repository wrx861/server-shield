#!/bin/bash
#
# rkhunter.sh - Rootkit Hunter
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

RKHUNTER_CONF="/etc/rkhunter.conf"
RKHUNTER_LOG="/var/log/rkhunter.log"
CRON_SCRIPT="/etc/cron.weekly/rkhunter-shield"

# Установка и настройка rkhunter
setup_rkhunter() {
    log_step "Настройка Rootkit Hunter..."
    
    # СНАЧАЛА исправляем конфиг (до запуска rkhunter)
    if [[ -f "$RKHUNTER_CONF" ]]; then
        # Включаем автообновление
        sed -i 's/^#\?UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/' "$RKHUNTER_CONF"
        sed -i 's/^#\?MIRRORS_MODE=.*/MIRRORS_MODE=0/' "$RKHUNTER_CONF"
        # WEB_CMD="" отключает автоскачивание (избегаем ошибки с /bin/false)
        sed -i 's/^#\?WEB_CMD=.*/WEB_CMD=""/' "$RKHUNTER_CONF"
    fi
    
    # Теперь обновляем базу данных
    rkhunter --update --quiet 2>/dev/null
    
    # Создаём базовый снимок системы
    rkhunter --propupd --quiet 2>/dev/null
    
    # Создаём cron задачу для еженедельного сканирования
    cat > "$CRON_SCRIPT" << 'CRON'
#!/bin/bash
#
# Server Shield - Weekly Rootkit Scan
#

LOG_FILE="/var/log/rkhunter-weekly.log"

# Обновляем базу
rkhunter --update --quiet 2>/dev/null

# Запускаем сканирование
rkhunter --check --skip-keypress --quiet --report-warnings-only > "$LOG_FILE" 2>&1

# Проверяем результат
if [[ -s "$LOG_FILE" ]]; then
    # Есть предупреждения - отправляем в Telegram
    WARNING=$(head -20 "$LOG_FILE")
    /opt/server-shield/modules/telegram.sh send_rootkit_alert "$WARNING"
fi
CRON
    
    chmod +x "$CRON_SCRIPT"
    
    log_info "Rootkit Hunter настроен (еженедельное сканирование)"
}

# Запуск сканирования
run_rkhunter_scan() {
    print_section "Rootkit Сканирование"
    
    echo ""
    log_step "Запуск сканирования... (это может занять несколько минут)"
    echo ""
    
    if command -v rkhunter &> /dev/null; then
        rkhunter --check --skip-keypress --report-warnings-only
        
        echo ""
        if [[ $? -eq 0 ]]; then
            log_info "Сканирование завершено. Угроз не обнаружено."
        else
            log_warn "Сканирование завершено с предупреждениями!"
            log_info "Полный лог: $RKHUNTER_LOG"
        fi
    else
        log_error "rkhunter не установлен"
    fi
}

# Проверка статуса
check_rkhunter_status() {
    echo ""
    echo -e "${WHITE}Rootkit Hunter Статус:${NC}"
    
    if command -v rkhunter &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} rkhunter: ${GREEN}Установлен${NC}"
        
        # Проверяем cron (включено/выключено)
        if [[ -f "$CRON_SCRIPT" ]]; then
            echo -e "  ${GREEN}●${NC} Авто-сканирование: ${GREEN}ВКЛЮЧЕНО${NC} (еженедельно)"
        else
            echo -e "  ${RED}○${NC} Авто-сканирование: ${YELLOW}ВЫКЛЮЧЕНО${NC}"
        fi
        
        # Последнее сканирование
        if [[ -f "$RKHUNTER_LOG" ]]; then
            local last_scan=$(stat -c %y "$RKHUNTER_LOG" 2>/dev/null | cut -d' ' -f1)
            echo -e "  ${WHITE}Последнее сканирование:${NC} $last_scan"
        fi
    else
        echo -e "  ${YELLOW}○${NC} rkhunter: ${YELLOW}Не установлен${NC}"
        echo -e "  ${CYAN}   Установится при включении${NC}"
    fi
}

# Включить еженедельное сканирование
enable_rkhunter() {
    log_step "Включение Rootkit Hunter..."
    
    # Проверяем установлен ли
    if ! command -v rkhunter &> /dev/null; then
        log_step "Установка rkhunter..."
        apt-get update -qq
        apt-get install -y rkhunter > /dev/null
    fi
    
    # Настраиваем конфиг
    if [[ -f "$RKHUNTER_CONF" ]]; then
        sed -i 's/^#\?UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/' "$RKHUNTER_CONF"
        sed -i 's/^#\?MIRRORS_MODE=.*/MIRRORS_MODE=0/' "$RKHUNTER_CONF"
        sed -i 's/^#\?WEB_CMD=.*/WEB_CMD=""/' "$RKHUNTER_CONF"
    fi
    
    # Обновляем базу
    rkhunter --update --quiet 2>/dev/null
    rkhunter --propupd --quiet 2>/dev/null
    
    # Создаём cron задачу
    cat > "$CRON_SCRIPT" << 'CRON'
#!/bin/bash
# Server Shield - Weekly Rootkit Scan
LOG_FILE="/var/log/rkhunter-weekly.log"
rkhunter --update --quiet 2>/dev/null
rkhunter --check --skip-keypress --quiet --report-warnings-only > "$LOG_FILE" 2>&1
if [[ -s "$LOG_FILE" ]]; then
    WARNING=$(head -20 "$LOG_FILE")
    /opt/server-shield/modules/telegram.sh send_rootkit_alert "$WARNING" 2>/dev/null
fi
CRON
    chmod +x "$CRON_SCRIPT"
    
    save_config "RKHUNTER_ENABLED" "true"
    log_info "Rootkit Hunter включен (еженедельное сканирование)"
}

# Выключить еженедельное сканирование
disable_rkhunter() {
    log_step "Выключение Rootkit Hunter..."
    
    # Удаляем cron задачу
    rm -f "$CRON_SCRIPT"
    
    save_config "RKHUNTER_ENABLED" "false"
    log_info "Rootkit Hunter выключен"
}

# Проверить включен ли rkhunter
is_rkhunter_enabled() {
    [[ -f "$CRON_SCRIPT" ]] && return 0 || return 1
}

# Меню rkhunter
rkhunter_menu() {
    while true; do
        print_header
        print_section "🔍 Rootkit Hunter"
        
        check_rkhunter_status
        
        local enabled=$(is_rkhunter_enabled && echo "true" || echo "false")
        
        echo ""
        if [[ "$enabled" == "true" ]]; then
            echo -e "  ${WHITE}1)${NC} ${RED}Выключить${NC} еженедельное сканирование"
        else
            echo -e "  ${WHITE}1)${NC} ${GREEN}Включить${NC} еженедельное сканирование"
        fi
        echo -e "  ${WHITE}2)${NC} Запустить сканирование сейчас"
        echo -e "  ${WHITE}3)${NC} Обновить базу данных"
        echo -e "  ${WHITE}4)${NC} Показать лог"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                if [[ "$enabled" == "true" ]]; then
                    disable_rkhunter
                else
                    enable_rkhunter
                fi
                ;;
            2) run_rkhunter_scan ;;
            3)
                log_step "Обновление базы..."
                rkhunter --update
                rkhunter --propupd
                log_info "База обновлена"
                ;;
            4)
                if [[ -f "$RKHUNTER_LOG" ]]; then
                    less "$RKHUNTER_LOG"
                else
                    log_warn "Лог не найден"
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}
