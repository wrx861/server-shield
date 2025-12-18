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
        
        # Проверяем cron
        if [[ -f "$CRON_SCRIPT" ]]; then
            echo -e "  ${GREEN}✓${NC} Cron: ${CYAN}Еженедельно${NC}"
        else
            echo -e "  ${YELLOW}○${NC} Cron: Не настроен"
        fi
        
        # Последнее сканирование
        if [[ -f "$RKHUNTER_LOG" ]]; then
            local last_scan=$(stat -c %y "$RKHUNTER_LOG" 2>/dev/null | cut -d' ' -f1)
            echo -e "  ${WHITE}Последнее сканирование:${NC} $last_scan"
        fi
    else
        echo -e "  ${YELLOW}○${NC} rkhunter: ${YELLOW}Не установлен${NC}"
    fi
}

# Меню rkhunter
rkhunter_menu() {
    while true; do
        print_header
        print_section "🔍 Rootkit Hunter"
        
        check_rkhunter_status
        
        echo ""
        echo -e "  ${WHITE}1)${NC} Запустить сканирование"
        echo -e "  ${WHITE}2)${NC} Обновить базу данных"
        echo -e "  ${WHITE}3)${NC} Показать лог"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) run_rkhunter_scan ;;
            2)
                log_step "Обновление базы..."
                rkhunter --update
                rkhunter --propupd
                log_info "База обновлена"
                ;;
            3)
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
