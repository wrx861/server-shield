#!/bin/bash
#
# ssh.sh - SSH Hardening
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# Файл конфига SSH
SSH_CONFIG="/etc/ssh/sshd_config"

# Функция бэкапа SSH конфига
backup_ssh_config() {
    local backup_file="$BACKUP_DIR/sshd_config.$(date +%Y%m%d_%H%M%S)"
    cp "$SSH_CONFIG" "$backup_file"
    log_info "Бэкап SSH конфига: $backup_file"
}

# Основная функция hardening SSH
harden_ssh() {
    local new_port="${1:-22}"
    
    log_step "Настройка SSH Hardening..."
    
    # Бэкап
    backup_ssh_config
    
    # Основные настройки безопасности
    declare -A ssh_settings=(
        ["Port"]="$new_port"
        ["PermitRootLogin"]="prohibit-password"
        ["PasswordAuthentication"]="no"
        ["PubkeyAuthentication"]="yes"
        ["UsePAM"]="yes"
        ["X11Forwarding"]="no"
        ["AllowAgentForwarding"]="no"
        ["AllowTcpForwarding"]="no"
        ["PermitEmptyPasswords"]="no"
        ["MaxAuthTries"]="3"
        ["MaxSessions"]="5"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="3"
        ["LoginGraceTime"]="60"
    )
    
    # Применяем настройки
    for key in "${!ssh_settings[@]}"; do
        local value="${ssh_settings[$key]}"
        
        # Удаляем старые записи (закомментированные и нет)
        sed -i "/^#*${key}/d" "$SSH_CONFIG"
        
        # Добавляем новую
        echo "${key} ${value}" >> "$SSH_CONFIG"
    done
    
    # Добавляем баннер
    if ! grep -q "^Banner" "$SSH_CONFIG"; then
        echo "Banner /etc/ssh/banner" >> "$SSH_CONFIG"
    fi
    
    # Создаём баннер
    cat > /etc/ssh/banner << 'BANNER'
╔═══════════════════════════════════════════════════════════╗
║  ⚠️  AUTHORIZED ACCESS ONLY  ⚠️                           ║
║  All connections are monitored and logged.                ║
║  Unauthorized access will be prosecuted.                  ║
╚═══════════════════════════════════════════════════════════╝
BANNER
    
    # Открываем порт в UFW если он активен и порт не стандартный
    if command -v ufw &> /dev/null && [[ "$new_port" != "22" ]]; then
        # Проверяем активен ли UFW
        if ufw status | grep -q "active"; then
            log_step "Открываем SSH порт $new_port в UFW..."
            ufw allow ${new_port}/tcp comment 'SSH'
        fi
    fi
    
    # Перезапуск SSH
    systemctl restart sshd 2>/dev/null || service ssh restart
    
    # Сохраняем порт в конфиг
    save_config "SSH_PORT" "$new_port"
    
    log_info "SSH Hardening завершён. Порт: $new_port"
}

# Функция смены порта SSH
change_ssh_port() {
    local new_port="$1"
    
    if ! validate_port "$new_port"; then
        log_error "Неверный порт: $new_port"
        return 1
    fi
    
    local old_port=$(get_ssh_port)
    
    # Проверяем что порт отличается
    if [[ "$old_port" == "$new_port" ]]; then
        log_info "Порт уже установлен: $new_port"
        return 0
    fi
    
    backup_ssh_config
    
    log_step "Смена SSH порта: $old_port → $new_port"
    
    # 1. СНАЧАЛА открываем НОВЫЙ порт в UFW (до изменения SSH!)
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        log_step "Открываем порт $new_port в UFW..."
        ufw allow ${new_port}/tcp comment 'SSH'
        
        # Проверяем что порт открылся
        if ! ufw status | grep -q "$new_port"; then
            log_error "Не удалось открыть порт $new_port в UFW!"
            return 1
        fi
    fi
    
    # 2. Меняем порт в sshd_config
    if grep -q "^Port " "$SSH_CONFIG"; then
        sed -i "s/^Port.*/Port $new_port/" "$SSH_CONFIG"
    else
        echo "Port $new_port" >> "$SSH_CONFIG"
    fi
    
    # 3. Перезапускаем SSH
    log_step "Перезапуск SSH..."
    systemctl restart sshd 2>/dev/null || service ssh restart
    
    # 4. Проверяем что SSH работает на новом порту
    sleep 2
    if ss -tlnp | grep -q ":$new_port"; then
        log_info "SSH успешно запущен на порту $new_port"
        
        # 5. Только теперь удаляем старый порт из UFW
        if command -v ufw &> /dev/null && [[ "$old_port" != "$new_port" ]]; then
            log_step "Закрываем старый порт $old_port..."
            # Удаляем все варианты правил для старого порта
            ufw delete allow ${old_port}/tcp 2>/dev/null
            ufw delete allow ${old_port} 2>/dev/null
            # Удаляем правила с IP ограничением
            ufw status numbered | grep " $old_port " | grep -oP '^\[\s*\K\d+' | sort -rn | while read num; do
                echo "y" | ufw delete $num 2>/dev/null
            done
        fi
        
        # Сохраняем в конфиг
        save_config "SSH_PORT" "$new_port"
        
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✅ SSH порт успешно изменён на: $new_port              ${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  Не закрывайте текущую сессию!${NC}"
        echo -e "   Откройте новое окно и проверьте подключение:"
        echo -e "   ${CYAN}ssh -p $new_port root@$(curl -s ifconfig.me 2>/dev/null || echo 'ваш_ip')${NC}"
        echo ""
    else
        log_error "SSH не запустился на порту $new_port!"
        log_warn "Откат изменений..."
        
        # Откат
        sed -i "s/^Port.*/Port $old_port/" "$SSH_CONFIG"
        systemctl restart sshd 2>/dev/null || service ssh restart
        
        # Удаляем новый порт из UFW
        ufw delete allow ${new_port}/tcp 2>/dev/null
        
        log_error "Смена порта не удалась. Порт остался: $old_port"
        return 1
    fi
}

# Функция получения текущего порта
get_ssh_port() {
    local port=$(grep "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}')
    if [[ -z "$port" ]]; then
        # Если Port не указан явно — SSH использует 22 по умолчанию
        echo "22"
    else
        echo "$port"
    fi
}

# Функция проверки статуса SSH
check_ssh_status() {
    echo ""
    echo -e "${WHITE}SSH Статус:${NC}"
    echo -e "  Порт: ${CYAN}$(get_ssh_port)${NC}"
    echo -e "  Пароли: ${RED}Отключены${NC}"
    echo -e "  Ключи: ${GREEN}Включены${NC}"
    
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
        echo -e "  Сервис: ${GREEN}Активен${NC}"
    else
        echo -e "  Сервис: ${RED}Не активен${NC}"
    fi
}
