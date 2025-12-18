#!/bin/bash
#
# ssh.sh - SSH Hardening
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# Файл конфига SSH
SSH_CONFIG="/etc/ssh/sshd_config"

# Универсальная функция перезапуска SSH (надёжная)
restart_ssh_service() {
    local target_port="${1:-}"
    
    # 1. Проверяем конфиг на ошибки
    if ! sshd -t 2>/dev/null; then
        log_error "Ошибка в конфиге SSH!"
        sshd -t  # Покажем ошибку
        return 1
    fi
    
    # 2. Определяем имя сервиса
    local service_name=""
    if systemctl list-units --type=service | grep -q "ssh.service"; then
        service_name="ssh"
    elif systemctl list-units --type=service | grep -q "sshd.service"; then
        service_name="sshd"
    fi
    
    # 3. Перезапускаем через systemctl
    if [[ -n "$service_name" ]]; then
        systemctl restart "$service_name" 2>/dev/null
        sleep 1
        
        # Проверяем запустился ли
        if systemctl is-active --quiet "$service_name"; then
            return 0
        fi
        
        # Если не запустился - пробуем stop/start
        systemctl stop "$service_name" 2>/dev/null
        sleep 1
        systemctl start "$service_name" 2>/dev/null
        sleep 1
        
        if systemctl is-active --quiet "$service_name"; then
            return 0
        fi
    fi
    
    # 4. Пробуем через service
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    sleep 1
    
    # 5. Крайний случай - убиваем и запускаем напрямую
    if [[ -n "$target_port" ]] && ! ss -tlnp | grep -q ":$target_port"; then
        pkill -9 sshd 2>/dev/null
        sleep 1
        /usr/sbin/sshd 2>/dev/null
        sleep 1
    fi
    
    return 0
}

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
    log_step "Перезапуск SSH..."
    restart_ssh_service "$new_port"
    
    # Проверяем что SSH запустился на новом порту (до 5 попыток)
    local attempts=0
    local max_attempts=5
    
    while [[ $attempts -lt $max_attempts ]]; do
        sleep 1
        if ss -tlnp | grep -q ":$new_port"; then
            log_info "✓ SSH работает на порту $new_port"
            break
        fi
        attempts=$((attempts + 1))
        
        if [[ $attempts -lt $max_attempts ]]; then
            log_warn "SSH не на порту $new_port, попытка $attempts/$max_attempts..."
            restart_ssh_service "$new_port"
        fi
    done
    
    # Финальная проверка
    if ! ss -tlnp | grep -q ":$new_port"; then
        log_error "SSH не запустился на порту $new_port после $max_attempts попыток"
        # Аварийный запуск напрямую
        pkill -9 sshd 2>/dev/null
        sleep 1
        /usr/sbin/sshd
        sleep 2
        
        if ss -tlnp | grep -q ":$new_port"; then
            log_info "✓ SSH запущен напрямую на порту $new_port"
        else
            log_error "Не удалось запустить SSH на порту $new_port"
        fi
    fi
    
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
    
    # Получаем ADMIN_IP из конфига (если был указан при установке)
    local admin_ip=$(get_config "ADMIN_IP" "")
    
    # Также проверяем есть ли правило с IP ограничением для старого порта
    if [[ -z "$admin_ip" ]]; then
        # Пробуем найти IP из текущих правил UFW для старого порта
        admin_ip=$(ufw status | grep -E "^${old_port}[^0-9]|^${old_port}/" | grep -v "Anywhere" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # Также проверяем правила с комментарием SSH или Admin
    if [[ -z "$admin_ip" ]]; then
        admin_ip=$(ufw status | grep -iE "ssh|admin" | grep -v "Anywhere" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # Показываем что нашли
    if [[ -n "$admin_ip" ]]; then
        log_info "Найден IP админа: $admin_ip"
    else
        log_warn "IP админа не найден — порт будет открыт для всех"
    fi
    
    # 1. СНАЧАЛА открываем НОВЫЙ порт в UFW (до изменения SSH!)
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        log_step "Открываем порт $new_port в UFW..."
        
        # Сначала удаляем ВСЕ существующие правила для нового порта
        # (чтобы не было дубликатов "для всех" и "для IP")
        ufw delete allow ${new_port}/tcp 2>/dev/null
        ufw delete allow ${new_port} 2>/dev/null
        # Удаляем правила с IP для этого порта
        ufw status numbered 2>/dev/null | grep " $new_port" | grep -oP '^\[\s*\K\d+' | sort -rn | while read num; do
            [[ -n "$num" ]] && echo "y" | ufw delete $num 2>/dev/null
        done
        
        # Теперь добавляем правильное правило
        if [[ -n "$admin_ip" ]]; then
            ufw allow from "$admin_ip" to any port "$new_port" proto tcp comment 'Admin SSH'
            log_info "SSH порт $new_port открыт ТОЛЬКО для IP: $admin_ip"
        else
            ufw allow ${new_port}/tcp comment 'SSH'
            log_info "SSH порт $new_port открыт для всех"
        fi
        
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
    
    # 3. Перезапускаем SSH с проверкой
    log_step "Перезапуск SSH..."
    restart_ssh_service "$new_port"
    
    # 4. Проверяем что SSH работает на новом порту (до 5 попыток)
    local attempts=0
    local max_attempts=5
    local ssh_started=false
    
    while [[ $attempts -lt $max_attempts ]]; do
        sleep 1
        if ss -tlnp | grep -q ":$new_port"; then
            ssh_started=true
            break
        fi
        attempts=$((attempts + 1))
        log_warn "SSH не на порту $new_port, попытка $attempts/$max_attempts..."
        restart_ssh_service "$new_port"
    done
    
    # Аварийный запуск если не удалось
    if [[ "$ssh_started" == false ]]; then
        log_warn "Аварийный запуск SSH..."
        pkill -9 sshd 2>/dev/null
        sleep 1
        /usr/sbin/sshd
        sleep 2
        ss -tlnp | grep -q ":$new_port" && ssh_started=true
    fi
    
    if [[ "$ssh_started" == false ]]; then
        log_error "SSH не запустился на порту $new_port!"
        log_warn "Откат изменений..."
        
        # Откат конфига
        sed -i "s/^Port.*/Port $old_port/" "$SSH_CONFIG"
        restart_ssh_service "$old_port"
        
        # Удаляем новый порт из UFW (все варианты)
        ufw delete allow ${new_port}/tcp 2>/dev/null
        ufw delete allow from "$admin_ip" to any port "$new_port" 2>/dev/null
        
        # Восстанавливаем старый порт
        if [[ -n "$admin_ip" ]]; then
            ufw allow from "$admin_ip" to any port "$old_port" proto tcp comment 'Admin SSH'
        else
            ufw allow ${old_port}/tcp comment 'SSH'
        fi
        
        log_error "Смена порта не удалась. Порт остался: $old_port"
        return 1
    fi
    
    # 5. Успех! Удаляем ВСЕ старые SSH порты из UFW
    if command -v ufw &> /dev/null; then
        log_step "Удаляем старые SSH правила..."
        
        # Удаляем старый порт (все варианты)
        if [[ "$old_port" != "$new_port" ]]; then
            ufw delete allow ${old_port}/tcp 2>/dev/null
            ufw delete allow ${old_port} 2>/dev/null
        fi
        
        # Удаляем стандартный порт 22 если он не новый
        if [[ "$new_port" != "22" ]]; then
            ufw delete allow 22/tcp 2>/dev/null
            ufw delete allow 22 2>/dev/null
        fi
        
        # Удаляем все правила с комментарием SSH кроме нового порта
        # А также правила с IP ограничением для старых портов
        ufw status numbered 2>/dev/null | grep -v "$new_port" | grep -iE "ssh|$old_port" | grep -oP '^\[\s*\K\d+' | sort -rn | while read num; do
            [[ -n "$num" ]] && echo "y" | ufw delete $num 2>/dev/null
        done
        
        log_info "Старые SSH правила удалены"
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
