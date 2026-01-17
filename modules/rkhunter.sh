#!/bin/bash
#
# rkhunter.sh - Rootkit Hunter
# Premium UI v3.0
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

RKHUNTER_CONF="/etc/rkhunter.conf"
RKHUNTER_LOG="/var/log/rkhunter.log"
CRON_SCRIPT="/etc/cron.weekly/rkhunter-shield"

# ============================================
# СТАТУС
# ============================================

# Проверка статуса rkhunter
check_rkhunter_status() {
    echo ""
    
    if command -v rkhunter &> /dev/null; then
        show_status_line "rkhunter" "on" "Установлен"
        
        # Проверяем cron (включено/выключено)
        if [[ -f "$CRON_SCRIPT" ]]; then
            show_status_line "Авто-сканирование" "on" "(еженедельно)"
        else
            show_status_line "Авто-сканирование" "off"
        fi
        
        # Последнее сканирование
        if [[ -f "$RKHUNTER_LOG" ]]; then
            local last_scan=$(stat -c %y "$RKHUNTER_LOG" 2>/dev/null | cut -d' ' -f1)
            show_info "Последнее сканирование" "$last_scan"
        fi
    else
        show_status_line "rkhunter" "off" "Не установлен"
        echo ""
        echo -e "    ${DIM}Установится автоматически при включении${NC}"
    fi
}

# Проверить включен ли rkhunter
is_rkhunter_enabled() {
    [[ -f "$CRON_SCRIPT" ]] && return 0 || return 1
}

# ============================================
# ОПЕРАЦИИ
# ============================================

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
    print_header_mini "Rootkit Сканирование"
    
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

# Обновить базу данных
update_rkhunter_db() {
    log_step "Обновление базы..."
    rkhunter --update
    rkhunter --propupd
    log_info "База обновлена"
}

# Показать лог
show_rkhunter_log() {
    if [[ -f "$RKHUNTER_LOG" ]]; then
        less "$RKHUNTER_LOG"
    else
        log_warn "Лог не найден"
    fi
}

# ============================================
# МЕНЮ
# ============================================

rkhunter_menu() {
    while true; do
        print_header_mini "Rootkit Hunter"
        
        # Статус
        check_rkhunter_status
        
        local enabled=$(is_rkhunter_enabled && echo "true" || echo "false")
        
        echo ""
        print_divider
        echo ""
        
        if [[ "$enabled" == "true" ]]; then
            menu_item "1" "Выключить авто-сканирование" "${RED}●${NC}"
        else
            menu_item "1" "Включить авто-сканирование" "${GREEN}○${NC}"
        fi
        menu_item "2" "Запустить сканирование сейчас"
        menu_item "3" "Обновить базу данных"
        menu_item "4" "Просмотр лога"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                if [[ "$enabled" == "true" ]]; then
                    disable_rkhunter
                else
                    enable_rkhunter
                fi
                press_any_key
                ;;
            2)
                run_rkhunter_scan
                press_any_key
                ;;
            3)
                update_rkhunter_db
                press_any_key
                ;;
            4)
                show_rkhunter_log
                ;;
            0|q)
                return
                ;;
            *)
                # Неверный ввод - просто обновляем экран
                ;;
        esac
    done
}
