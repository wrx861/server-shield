#!/bin/bash
#
# updater.sh - Проверка и установка обновлений
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

GITHUB_RAW="https://raw.githubusercontent.com/wrx861/server-shield/main"
LOCAL_VERSION_FILE="/opt/server-shield/VERSION"
UPDATE_CHECK_FILE="/opt/server-shield/config/last_update_check"
UPDATE_CACHE_FILE="/opt/server-shield/config/update_cache"
UPDATE_CHECK_INTERVAL=3600  # Проверять раз в час (секунды)

# Получить локальную версию
get_local_version() {
    if [[ -f "$LOCAL_VERSION_FILE" ]]; then
        cat "$LOCAL_VERSION_FILE"
    else
        echo "0.0.0"
    fi
}

# Получить версию с GitHub (с кэшированием)
get_remote_version() {
    local current_time=$(date +%s)
    local last_check=0
    local cached_version=""
    
    # Читаем кэш
    if [[ -f "$UPDATE_CACHE_FILE" ]]; then
        last_check=$(head -1 "$UPDATE_CACHE_FILE" 2>/dev/null || echo "0")
        cached_version=$(tail -1 "$UPDATE_CACHE_FILE" 2>/dev/null || echo "")
    fi
    
    # Если кэш свежий — возвращаем из кэша
    local time_diff=$((current_time - last_check))
    if [[ $time_diff -lt $UPDATE_CHECK_INTERVAL ]] && [[ -n "$cached_version" ]]; then
        echo "$cached_version"
        return
    fi
    
    # Иначе делаем запрос к GitHub
    local remote_version
    remote_version=$(curl -fsSL --connect-timeout 3 --max-time 5 "$GITHUB_RAW/VERSION" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "$remote_version" ]]; then
        # Сохраняем в кэш
        mkdir -p "$(dirname "$UPDATE_CACHE_FILE")" 2>/dev/null
        echo "$current_time" > "$UPDATE_CACHE_FILE"
        echo "$remote_version" >> "$UPDATE_CACHE_FILE"
        echo "$remote_version"
    else
        # Если запрос не удался — возвращаем кэш если есть
        if [[ -n "$cached_version" ]]; then
            echo "$cached_version"
        else
            echo ""
        fi
    fi
}

# Принудительная проверка обновлений (без кэша)
get_remote_version_force() {
    local remote_version
    remote_version=$(curl -fsSL --connect-timeout 5 --max-time 10 "$GITHUB_RAW/VERSION" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "$remote_version" ]]; then
        # Обновляем кэш
        local current_time=$(date +%s)
        mkdir -p "$(dirname "$UPDATE_CACHE_FILE")" 2>/dev/null
        echo "$current_time" > "$UPDATE_CACHE_FILE"
        echo "$remote_version" >> "$UPDATE_CACHE_FILE"
        echo "$remote_version"
    else
        echo ""
    fi
}

# Сравнить версии (возвращает 0 если remote новее)
version_gt() {
    local v1="$1"
    local v2="$2"
    
    # Убираем возможные пробелы и переносы
    v1=$(echo "$v1" | tr -d '[:space:]')
    v2=$(echo "$v2" | tr -d '[:space:]')
    
    if [[ "$v1" == "$v2" ]]; then
        return 1
    fi
    
    # Сравниваем версии
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    return 1
}

# Проверить наличие обновлений
check_updates() {
    local local_ver=$(get_local_version)
    local remote_ver=$(get_remote_version)
    
    if [[ -z "$remote_ver" ]]; then
        echo "error"
        return
    fi
    
    if version_gt "$remote_ver" "$local_ver"; then
        echo "available:$remote_ver"
    else
        echo "latest"
    fi
    
    # Сохраняем время проверки
    date +%s > "$UPDATE_CHECK_FILE" 2>/dev/null
}

# Показать статус версии (для header)
show_version_status() {
    local local_ver=$(get_local_version)
    local status=$(check_updates)
    
    echo -ne "  ${WHITE}Версия:${NC} ${CYAN}$local_ver${NC}"
    
    case "$status" in
        "latest")
            echo -e " ${GREEN}✓ актуальная${NC}"
            ;;
        available:*)
            local new_ver="${status#available:}"
            echo -e " ${YELLOW}⬆ доступно обновление $new_ver${NC}"
            ;;
        "error")
            echo -e " ${RED}(не удалось проверить)${NC}"
            ;;
    esac
}

# Быстрая проверка (без вывода, только возврат)
has_update() {
    local status=$(check_updates)
    [[ "$status" == available:* ]]
}

# Получить версию обновления
get_update_version() {
    local status=$(check_updates)
    if [[ "$status" == available:* ]]; then
        echo "${status#available:}"
    fi
}

# Выполнить обновление
do_update() {
    print_section "⬆️ Обновление Server Shield"
    
    local local_ver=$(get_local_version)
    local remote_ver=$(get_remote_version)
    
    if [[ -z "$remote_ver" ]]; then
        log_error "Не удалось получить информацию о версии"
        return 1
    fi
    
    echo ""
    echo -e "  Текущая версия: ${CYAN}$local_ver${NC}"
    echo -e "  Новая версия:   ${GREEN}$remote_ver${NC}"
    echo ""
    
    if ! version_gt "$remote_ver" "$local_ver"; then
        log_info "У вас уже установлена последняя версия"
        return 0
    fi
    
    if ! confirm "Обновить Server Shield?" "y"; then
        log_info "Обновление отменено"
        return 0
    fi
    
    echo ""
    log_step "Создание бэкапа..."
    source "$SHIELD_DIR/modules/backup.sh" 2>/dev/null
    create_full_backup
    
    log_step "Скачивание обновлений..."
    
    # Список файлов для обновления
    local modules=(
        "utils.sh"
        "ssh.sh"
        "keys.sh"
        "firewall.sh"
        "kernel.sh"
        "fail2ban.sh"
        "telegram.sh"
        "rkhunter.sh"
        "backup.sh"
        "status.sh"
        "menu.sh"
        "updater.sh"
    )
    
    # Скачиваем модули
    for module in "${modules[@]}"; do
        echo -e "   Обновление: $module"
        if ! curl -fsSL "$GITHUB_RAW/modules/$module" -o "$SHIELD_DIR/modules/$module" 2>/dev/null; then
            log_error "Ошибка при скачивании $module"
            return 1
        fi
    done
    
    # Скачиваем основные файлы
    echo -e "   Обновление: shield.sh"
    curl -fsSL "$GITHUB_RAW/shield.sh" -o "$SHIELD_DIR/shield.sh" 2>/dev/null
    
    echo -e "   Обновление: VERSION"
    curl -fsSL "$GITHUB_RAW/VERSION" -o "$SHIELD_DIR/VERSION" 2>/dev/null
    
    # Делаем исполняемыми
    chmod +x "$SHIELD_DIR"/*.sh 2>/dev/null
    chmod +x "$SHIELD_DIR/modules/"*.sh 2>/dev/null
    
    echo ""
    log_info "Обновление завершено!"
    echo -e "  Новая версия: ${GREEN}$remote_ver${NC}"
    echo ""
    echo -e "  ${YELLOW}Перезапустите shield для применения изменений:${NC}"
    echo -e "  ${CYAN}shield${NC}"
    
    return 0
}

# Принудительная проверка обновлений
check_updates_force() {
    local local_ver=$(get_local_version)
    local remote_ver=$(get_remote_version_force)
    
    if [[ -z "$remote_ver" ]]; then
        echo "error"
        return
    fi
    
    if version_gt "$remote_ver" "$local_ver"; then
        echo "available:$remote_ver"
    else
        echo "latest"
    fi
}

# Меню обновлений
update_menu() {
    print_header
    print_section "⬆️ Обновление Server Shield"
    
    show_version_status
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local status=$(check_updates)
    
    case "$status" in
        "latest")
            echo -e "  ${GREEN}✓ У вас установлена последняя версия${NC}"
            echo ""
            echo -e "  ${WHITE}1)${NC} Проверить обновления сейчас"
            echo -e "  ${WHITE}2)${NC} Переустановить текущую версию"
            ;;
        available:*)
            local new_ver="${status#available:}"
            echo -e "  ${YELLOW}⬆ Доступно обновление: $new_ver${NC}"
            echo ""
            echo -e "  ${WHITE}1)${NC} ${GREEN}Обновить до $new_ver${NC}"
            echo -e "  ${WHITE}2)${NC} Проверить обновления сейчас"
            ;;
        "error")
            echo -e "  ${RED}Не удалось проверить обновления${NC}"
            echo -e "  Проверьте подключение к интернету"
            echo ""
            echo -e "  ${WHITE}1)${NC} Повторить проверку"
            ;;
    esac
    
    echo -e "  ${WHITE}0)${NC} Назад"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1)
            if [[ "$status" == available:* ]]; then
                do_update
            else
                log_step "Проверка обновлений..."
                # Принудительная проверка (без кэша)
                local force_status=$(check_updates_force)
                case "$force_status" in
                    "latest")
                        log_info "У вас установлена последняя версия"
                        ;;
                    available:*)
                        local new_ver="${force_status#available:}"
                        log_info "Доступно обновление: $new_ver"
                        if confirm "Обновить сейчас?" "y"; then
                            do_update
                        fi
                        ;;
                    "error")
                        log_error "Не удалось проверить обновления"
                        ;;
                esac
            fi
            ;;
        2)
            if [[ "$status" == "latest" ]]; then
                # Принудительная проверка
                log_step "Проверка обновлений..."
                local force_status=$(check_updates_force)
                case "$force_status" in
                    "latest")
                        log_info "У вас установлена последняя версия"
                        ;;
                    available:*)
                        local new_ver="${force_status#available:}"
                        log_info "Доступно обновление: $new_ver"
                        if confirm "Обновить сейчас?" "y"; then
                            do_update
                        fi
                        ;;
                    "error")
                        log_error "Не удалось проверить обновления"
                        ;;
                esac
            fi
            ;;
        0) return ;;
    esac
    
    press_any_key
}
