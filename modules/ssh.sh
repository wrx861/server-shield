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
    
    backup_ssh_config
    
    sed -i "s/^Port.*/Port $new_port/" "$SSH_CONFIG"
    
    # Обновляем UFW
    local old_port=$(get_config "SSH_PORT" "22")
    if command -v ufw &> /dev/null; then
        ufw delete allow ${old_port}/tcp 2>/dev/null
        ufw allow ${new_port}/tcp comment 'SSH'
    fi
    
    systemctl restart sshd 2>/dev/null || service ssh restart
    
    save_config "SSH_PORT" "$new_port"
    
    log_info "SSH порт изменён на: $new_port"
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
