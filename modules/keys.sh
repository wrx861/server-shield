#!/bin/bash
#
# keys.sh - Управление SSH ключами
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

SSH_DIR="/root/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
PRIVATE_KEY="$SSH_DIR/id_ed25519"
PUBLIC_KEY="$SSH_DIR/id_ed25519.pub"

# Инициализация SSH директории
init_ssh_dir() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
}

# Меню управления ключами
keys_menu() {
    while true; do
        print_header
        print_section "🔑 Управление SSH-ключами"
        echo ""
        echo -e "  ${WHITE}1)${NC} Создать новую пару ключей"
        echo -e "  ${WHITE}2)${NC} Показать публичный ключ"
        echo -e "  ${WHITE}3)${NC} Показать приватный ключ (для Termius)"
        echo -e "  ${WHITE}4)${NC} Список авторизованных ключей"
        echo -e "  ${WHITE}5)${NC} Добавить публичный ключ"
        echo -e "  ${WHITE}6)${NC} Удалить ключ"
        echo -e "  ${WHITE}7)${NC} Проверить наличие ключей"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) generate_key ;;
            2) show_public_key ;;
            3) show_private_key ;;
            4) list_authorized_keys ;;
            5) add_public_key ;;
            6) remove_key ;;
            7) check_keys ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Генерация новой пары ключей
generate_key() {
    print_section "Генерация SSH-ключа"
    
    init_ssh_dir
    
    # Проверяем существование ключа
    if [[ -f "$PRIVATE_KEY" ]]; then
        log_warn "Ключ уже существует: $PRIVATE_KEY"
        if ! confirm "Перезаписать существующий ключ?"; then
            return
        fi
        rm -f "$PRIVATE_KEY" "$PUBLIC_KEY"
    fi
    
    # Генерируем ключ
    log_step "Генерация ED25519 ключа..."
    ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -N "" -q
    
    if [[ $? -eq 0 ]]; then
        log_info "Ключ успешно создан!"
        
        # Добавляем в authorized_keys
        cat "$PUBLIC_KEY" >> "$AUTH_KEYS"
        
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  ВАЖНО! Сохраните приватный ключ в надёжное место!${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${WHITE}Публичный ключ (добавлен в authorized_keys):${NC}"
        echo -e "${CYAN}$(cat "$PUBLIC_KEY")${NC}"
        echo ""
        echo -e "${WHITE}Приватный ключ (скопируйте в Termius):${NC}"
        echo -e "${GREEN}$(cat "$PRIVATE_KEY")${NC}"
    else
        log_error "Ошибка генерации ключа"
    fi
}

# Показать публичный ключ
show_public_key() {
    print_section "Публичный ключ"
    
    if [[ -f "$PUBLIC_KEY" ]]; then
        echo ""
        echo -e "${WHITE}Файл:${NC} $PUBLIC_KEY"
        echo ""
        echo -e "${CYAN}$(cat "$PUBLIC_KEY")${NC}"
    else
        echo ""
        log_info "Файл публичного ключа не найден на сервере"
        echo ""
        echo -e "${WHITE}Это нормально, если вы:${NC}"
        echo -e "  • Добавили свой ключ извне (скопировали в authorized_keys)"
        echo -e "  • Используете ключ созданный на другом устройстве"
        echo ""
        echo -e "${WHITE}Ваши авторизованные ключи в authorized_keys:${NC}"
        if [[ -f "$AUTH_KEYS" ]] && [[ -s "$AUTH_KEYS" ]]; then
            cat "$AUTH_KEYS"
        else
            log_warn "authorized_keys пуст"
        fi
        echo ""
        log_info "Для создания нового ключа на сервере: 'Создать новую пару ключей'"
    fi
}

# Показать приватный ключ
show_private_key() {
    print_section "Приватный ключ"
    
    echo ""
    echo -e "${RED}⚠️  ВНИМАНИЕ: Никому не показывайте приватный ключ!${NC}"
    echo ""
    
    if ! confirm "Показать приватный ключ?"; then
        return
    fi
    
    if [[ -f "$PRIVATE_KEY" ]]; then
        echo ""
        echo -e "${WHITE}Файл:${NC} $PRIVATE_KEY"
        echo -e "${WHITE}Скопируйте всё содержимое (включая BEGIN и END):${NC}"
        echo ""
        echo -e "${GREEN}$(cat "$PRIVATE_KEY")${NC}"
    else
        echo ""
        log_info "Приватный ключ не найден на сервере"
        echo ""
        echo -e "${WHITE}Это нормально, если вы:${NC}"
        echo -e "  • Создали ключ на своём компьютере и добавили публичный на сервер"
        echo -e "  • Приватный ключ должен быть только у вас!"
        echo ""
        log_info "Для создания новой пары ключей на сервере: 'Создать новую пару ключей'"
    fi
}

# Список авторизованных ключей
list_authorized_keys() {
    print_section "Авторизованные ключи"
    
    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        log_warn "Нет авторизованных ключей!"
        return
    fi
    
    echo ""
    local i=1
    while IFS= read -r line; do
        if [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]]; then
            # Извлекаем тип и комментарий
            local key_type=$(echo "$line" | awk '{print $1}')
            local key_comment=$(echo "$line" | awk '{print $3}')
            local key_short=$(echo "$line" | awk '{print substr($2,1,20)}')...
            
            echo -e "  ${WHITE}$i)${NC} ${CYAN}$key_type${NC} $key_short ${YELLOW}[$key_comment]${NC}"
            ((i++))
        fi
    done < "$AUTH_KEYS"
    
    echo ""
    echo -e "${WHITE}Всего ключей:${NC} $((i-1))"
}

# Добавить публичный ключ
add_public_key() {
    print_section "Добавить публичный ключ"
    
    init_ssh_dir
    
    echo ""
    echo -e "${WHITE}Вставьте публичный ключ (начинается с ssh-ed25519 или ssh-rsa):${NC}"
    echo ""
    read -r new_key
    
    if [[ -z "$new_key" ]]; then
        log_error "Ключ не введён"
        return
    fi
    
    # Проверяем формат
    if [[ ! "$new_key" =~ ^ssh-(ed25519|rsa|ecdsa) ]]; then
        log_error "Неверный формат ключа. Должен начинаться с ssh-ed25519, ssh-rsa или ssh-ecdsa"
        return
    fi
    
    # Проверяем на дубликат
    if grep -qF "$new_key" "$AUTH_KEYS" 2>/dev/null; then
        log_warn "Этот ключ уже добавлен"
        return
    fi
    
    # Добавляем
    echo "$new_key" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    
    log_info "Ключ успешно добавлен!"
}

# Удалить ключ
remove_key() {
    print_section "Удалить ключ"
    
    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        log_warn "Нет авторизованных ключей"
        return
    fi
    
    # Показываем список
    list_authorized_keys
    
    # Считаем ключи
    local total_keys=$(grep -c "^ssh-" "$AUTH_KEYS" 2>/dev/null || echo 0)
    
    if [[ $total_keys -le 1 ]]; then
        log_error "Нельзя удалить последний ключ! Вы потеряете доступ к серверу."
        return
    fi
    
    echo ""
    read -p "Введите номер ключа для удаления (или 0 для отмены): " key_num
    
    if [[ "$key_num" == "0" ]]; then
        return
    fi
    
    if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [[ $key_num -lt 1 ]] || [[ $key_num -gt $total_keys ]]; then
        log_error "Неверный номер"
        return
    fi
    
    # Создаём бэкап
    cp "$AUTH_KEYS" "$BACKUP_DIR/authorized_keys.$(date +%Y%m%d_%H%M%S)"
    
    # Удаляем ключ
    local line_to_delete=$(grep -n "^ssh-" "$AUTH_KEYS" | sed -n "${key_num}p" | cut -d: -f1)
    sed -i "${line_to_delete}d" "$AUTH_KEYS"
    
    log_info "Ключ #$key_num удалён"
}

# Проверка наличия ключей
check_keys() {
    print_section "Проверка SSH-ключей"
    echo ""
    
    # Проверяем authorized_keys
    if [[ -f "$AUTH_KEYS" ]] && [[ -s "$AUTH_KEYS" ]]; then
        local count=$(grep -c "^ssh-" "$AUTH_KEYS" 2>/dev/null || echo 0)
        echo -e "  ${GREEN}✓${NC} authorized_keys: ${CYAN}$count ключ(ей)${NC}"
    else
        echo -e "  ${RED}✗${NC} authorized_keys: ${RED}Пусто или не существует${NC}"
        echo -e "    ${YELLOW}⚠️  Добавьте ключ перед включением защиты!${NC}"
    fi
    
    # Проверяем приватный ключ
    if [[ -f "$PRIVATE_KEY" ]]; then
        echo -e "  ${GREEN}✓${NC} Приватный ключ: ${CYAN}Существует${NC}"
    else
        echo -e "  ${YELLOW}○${NC} Приватный ключ: ${YELLOW}Не создан на сервере${NC}"
    fi
    
    # Проверяем публичный ключ
    if [[ -f "$PUBLIC_KEY" ]]; then
        echo -e "  ${GREEN}✓${NC} Публичный ключ: ${CYAN}Существует${NC}"
    else
        echo -e "  ${YELLOW}○${NC} Публичный ключ: ${YELLOW}Не создан на сервере${NC}"
    fi
    
    # Проверяем права
    echo ""
    echo -e "${WHITE}Права доступа:${NC}"
    
    if [[ -d "$SSH_DIR" ]]; then
        local dir_perms=$(stat -c %a "$SSH_DIR" 2>/dev/null)
        if [[ "$dir_perms" == "700" ]]; then
            echo -e "  ${GREEN}✓${NC} ~/.ssh: 700 (правильно)"
        else
            echo -e "  ${RED}✗${NC} ~/.ssh: $dir_perms (должно быть 700)"
        fi
    fi
    
    if [[ -f "$AUTH_KEYS" ]]; then
        local file_perms=$(stat -c %a "$AUTH_KEYS" 2>/dev/null)
        if [[ "$file_perms" == "600" ]]; then
            echo -e "  ${GREEN}✓${NC} authorized_keys: 600 (правильно)"
        else
            echo -e "  ${RED}✗${NC} authorized_keys: $file_perms (должно быть 600)"
        fi
    fi
}

# CLI команды для ключей
keys_cli() {
    local action="$1"
    
    case "$action" in
        generate) generate_key ;;
        show) show_public_key ;;
        private) show_private_key ;;
        list) list_authorized_keys ;;
        add) add_public_key ;;
        remove) remove_key ;;
        check) check_keys ;;
        *) keys_menu ;;
    esac
}
