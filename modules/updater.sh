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

# Получить MD5 хэш файла
get_file_hash() {
    local file="$1"
    if [[ -f "$file" ]]; then
        md5sum "$file" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# Получить MD5 хэш из URL (без скачивания всего файла)
get_remote_hash() {
    local url="$1"
    curl -fsSL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | md5sum | awk '{print $1}'
}

# Выполнить обновление (умное — только изменённые файлы)
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
    
    log_step "Проверка изменений..."
    
    # Список всех файлов для проверки
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
        "traffic.sh"
        "monitor.sh"
        "updater.sh"
        "l7shield.sh"
    )
    
    local updated_count=0
    local skipped_count=0
    local new_count=0
    
    # Проверяем и обновляем модули
    for module in "${modules[@]}"; do
        local local_file="$SHIELD_DIR/modules/$module"
        local remote_url="$GITHUB_RAW/modules/$module"
        
        # Проверяем существует ли локальный файл
        if [[ ! -f "$local_file" ]]; then
            # Новый файл — скачиваем
            echo -e "   ${GREEN}+ Новый:${NC} $module"
            if curl -fsSL "$remote_url" -o "$local_file" 2>/dev/null; then
                ((new_count++))
            fi
            continue
        fi
        
        # Получаем хэши
        local local_hash=$(get_file_hash "$local_file")
        local remote_hash=$(get_remote_hash "$remote_url")
        
        if [[ -z "$remote_hash" ]]; then
            echo -e "   ${YELLOW}? Пропуск:${NC} $module (не удалось получить)"
            continue
        fi
        
        if [[ "$local_hash" == "$remote_hash" ]]; then
            # Файл не изменился
            ((skipped_count++))
        else
            # Файл изменился — обновляем
            echo -e "   ${CYAN}↻ Обновление:${NC} $module"
            if curl -fsSL "$remote_url" -o "$local_file" 2>/dev/null; then
                ((updated_count++))
            fi
        fi
    done
    
    # Основные файлы
    local main_files=("shield.sh" "VERSION" "README.md" "uninstall.sh")
    
    for file in "${main_files[@]}"; do
        local local_file="$SHIELD_DIR/$file"
        local remote_url="$GITHUB_RAW/$file"
        
        if [[ ! -f "$local_file" ]]; then
            echo -e "   ${GREEN}+ Новый:${NC} $file"
            curl -fsSL "$remote_url" -o "$local_file" 2>/dev/null && ((new_count++))
            continue
        fi
        
        local local_hash=$(get_file_hash "$local_file")
        local remote_hash=$(get_remote_hash "$remote_url")
        
        if [[ -n "$remote_hash" ]] && [[ "$local_hash" != "$remote_hash" ]]; then
            echo -e "   ${CYAN}↻ Обновление:${NC} $file"
            curl -fsSL "$remote_url" -o "$local_file" 2>/dev/null && ((updated_count++))
        else
            ((skipped_count++))
        fi
    done
    
    # Делаем исполняемыми
    chmod +x "$SHIELD_DIR"/*.sh 2>/dev/null
    chmod +x "$SHIELD_DIR/modules/"*.sh 2>/dev/null
    
    echo ""
    log_info "Обновление завершено!"
    echo -e "  Новая версия: ${GREEN}$remote_ver${NC}"
    echo ""
    echo -e "  ${GREEN}Обновлено:${NC} $updated_count файлов"
    echo -e "  ${GREEN}Новых:${NC} $new_count файлов"
    echo -e "  ${CYAN}Без изменений:${NC} $skipped_count файлов"
    echo ""
    
    if [[ $updated_count -gt 0 ]] || [[ $new_count -gt 0 ]]; then
        echo -e "  ${YELLOW}Перезапустите shield для применения изменений:${NC}"
        echo -e "  ${CYAN}shield${NC}"
    fi
    
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
    while true; do
        print_header_mini "Обновление"
        
        local local_ver=$(get_local_version)
        # Принудительная проверка при входе в меню
        local status=$(check_updates_force 2>/dev/null)
        local remote_ver=""
        
        if [[ "$status" == available:* ]]; then
            remote_ver="${status#available:}"
        fi
        
        # Статус блок
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "    ${DIM}│${NC} Текущая версия: ${CYAN}$local_ver${NC}                            ${DIM}│${NC}"
        
        case "$status" in
            "latest")
                echo -e "    ${DIM}│${NC} Статус: ${GREEN}● Последняя версия${NC}                       ${DIM}│${NC}"
                ;;
            available:*)
                local new_ver="${status#available:}"
                echo -e "    ${DIM}│${NC} Статус: ${YELLOW}● Доступно $new_ver${NC}                        ${DIM}│${NC}"
                ;;
            *)
                echo -e "    ${DIM}│${NC} Статус: ${RED}○ Не удалось проверить${NC}                  ${DIM}│${NC}"
                ;;
        esac
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        case "$status" in
            available:*)
                local new_ver="${status#available:}"
                echo -e "    ${GREEN}[1]${NC} ${GREEN}Обновить до $new_ver${NC}"
                menu_item "2" "Проверить ещё раз"
                menu_item "3" "Показать что нового"
                ;;
            "latest")
                menu_item "1" "Проверить обновления"
                menu_item "2" "Переустановить текущую версию"
                ;;
            *)
                menu_item "1" "Повторить проверку"
                ;;
        esac
        
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                if [[ "$status" == available:* ]]; then
                    echo ""
                    if confirm_action "Обновить до $new_ver?" "y"; then
                        do_update
                    fi
                else
                    log_step "Проверка обновлений..."
                    local force_status=$(check_updates_force)
                    case "$force_status" in
                        "latest")
                            log_info "У вас последняя версия!"
                            ;;
                        available:*)
                            local nv="${force_status#available:}"
                            log_info "Доступно обновление: $nv"
                            if confirm_action "Обновить сейчас?" "y"; then
                                do_update
                            fi
                            ;;
                        *)
                            log_error "Не удалось проверить обновления"
                            ;;
                    esac
                fi
                press_any_key
                ;;
            2)
                if [[ "$status" == available:* ]]; then
                    log_step "Проверка обновлений..."
                    check_updates_force > /dev/null
                    log_info "Проверка завершена"
                elif [[ "$status" == "latest" ]]; then
                    echo ""
                    log_warn "Переустановка текущей версии..."
                    if confirm_action "Переустановить $local_ver?" "n"; then
                        do_update
                    fi
                fi
                press_any_key
                ;;
            3)
                if [[ "$status" == available:* ]]; then
                    show_changelog
                    press_any_key
                fi
                ;;
            0|q) return ;;
        esac
    done
}

# Показать что нового
show_changelog() {
    echo ""
    echo -e "    ${WHITE}Что нового в обновлении:${NC}"
    echo ""
    
    local changelog=$(curl -fsSL --connect-timeout 5 "$GITHUB_RAW/CHANGELOG.md" 2>/dev/null | head -50)
    
    if [[ -n "$changelog" ]]; then
        echo "$changelog" | while read line; do
            echo "    $line"
        done
    else
        echo -e "    ${DIM}Не удалось загрузить changelog${NC}"
    fi
}
