#!/bin/bash
#
# backup.sh - Бэкап и восстановление конфигурации
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# Создание полного бэкапа
create_full_backup() {
    local backup_name="shield-backup-$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log_step "Создание полного бэкапа..."
    
    mkdir -p "$backup_path"
    
    # SSH конфиг
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$backup_path/"
    
    # UFW правила
    [[ -d /etc/ufw ]] && cp -r /etc/ufw "$backup_path/"
    
    # Fail2Ban конфиг
    [[ -f /etc/fail2ban/jail.local ]] && cp /etc/fail2ban/jail.local "$backup_path/"
    
    # Kernel настройки
    [[ -f /etc/sysctl.d/99-shield-hardening.conf ]] && cp /etc/sysctl.d/99-shield-hardening.conf "$backup_path/"
    
    # SSH ключи
    [[ -f /root/.ssh/authorized_keys ]] && cp /root/.ssh/authorized_keys "$backup_path/"
    
    # Shield конфиг
    [[ -f "$SHIELD_CONFIG" ]] && cp "$SHIELD_CONFIG" "$backup_path/"
    
    # Создаём архив
    cd "$BACKUP_DIR"
    tar -czf "${backup_name}.tar.gz" "$backup_name" 2>/dev/null
    rm -rf "$backup_path"
    
    log_info "Бэкап создан: ${backup_name}.tar.gz"
    echo -e "  Путь: ${CYAN}$BACKUP_DIR/${backup_name}.tar.gz${NC}"
}

# Список бэкапов
list_backups() {
    print_section "Доступные бэкапы"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]]; then
        log_warn "Бэкапы не найдены"
        return 1
    fi
    
    local i=1
    for backup in "$BACKUP_DIR"/*.tar.gz; do
        local name=$(basename "$backup")
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" | cut -d' ' -f1)
        
        echo -e "  ${WHITE}$i)${NC} $name ${CYAN}($size)${NC} - $date"
        ((i++))
    done
    
    return 0
}

# Восстановление из бэкапа
restore_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Файл бэкапа не найден: $backup_file"
        return 1
    fi
    
    log_step "Восстановление из бэкапа..."
    
    # Распаковываем
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"
    
    local backup_name=$(ls "$temp_dir")
    local restore_path="$temp_dir/$backup_name"
    
    # Восстанавливаем SSH
    if [[ -f "$restore_path/sshd_config" ]]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-restore
        cp "$restore_path/sshd_config" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart
        log_info "SSH конфиг восстановлен"
    fi
    
    # Восстанавливаем Fail2Ban
    if [[ -f "$restore_path/jail.local" ]]; then
        cp "$restore_path/jail.local" /etc/fail2ban/jail.local
        systemctl restart fail2ban 2>/dev/null
        log_info "Fail2Ban конфиг восстановлен"
    fi
    
    # Восстанавливаем Kernel
    if [[ -f "$restore_path/99-shield-hardening.conf" ]]; then
        cp "$restore_path/99-shield-hardening.conf" /etc/sysctl.d/
        sysctl -p /etc/sysctl.d/99-shield-hardening.conf > /dev/null 2>&1
        log_info "Kernel настройки восстановлены"
    fi
    
    # Восстанавливаем authorized_keys
    if [[ -f "$restore_path/authorized_keys" ]]; then
        cp "$restore_path/authorized_keys" /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        log_info "SSH ключи восстановлены"
    fi
    
    # Восстанавливаем Shield конфиг
    if [[ -f "$restore_path/shield.conf" ]]; then
        cp "$restore_path/shield.conf" "$SHIELD_CONFIG"
        log_info "Shield конфиг восстановлен"
    fi
    
    # Удаляем временные файлы
    rm -rf "$temp_dir"
    
    log_info "Восстановление завершено!"
}

# Удаление старых бэкапов
cleanup_old_backups() {
    local keep_count="${1:-5}"
    
    log_step "Удаление старых бэкапов (оставляем $keep_count последних)..."
    
    cd "$BACKUP_DIR" 2>/dev/null || return
    
    ls -t shield-backup-*.tar.gz 2>/dev/null | tail -n +$((keep_count+1)) | while read file; do
        rm -f "$file"
        log_info "Удалён: $file"
    done
}

# Меню бэкапов
backup_menu() {
    while true; do
        print_header_mini "Бэкап и восстановление"
        
        local backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l || echo 0)
        local last_backup=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
        local last_date="никогда"
        [[ -n "$last_backup" ]] && last_date=$(stat -c %y "$last_backup" 2>/dev/null | cut -d' ' -f1)
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "    ${DIM}│${NC} Бэкапов: ${CYAN}$backup_count${NC}           Последний: ${CYAN}$last_date${NC}    ${DIM}│${NC}"
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Создать бэкап"
        menu_item "2" "Список бэкапов"
        menu_item "3" "Восстановить из бэкапа"
        menu_item "4" "Удалить старые бэкапы"
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                create_full_backup
                press_any_key
                ;;
            2)
                list_backups
                press_any_key
                ;;
            3)
                if list_backups; then
                    echo ""
                    local backup_num
                    input_value "Номер бэкапа" "" backup_num
                    
                    local i=1
                    for backup in "$BACKUP_DIR"/*.tar.gz; do
                        if [[ $i -eq $backup_num ]]; then
                            if confirm_action "Восстановить из $(basename $backup)?" "n"; then
                                restore_backup "$backup"
                            fi
                            break
                        fi
                        ((i++))
                    done
                fi
                press_any_key
                ;;
            4)
                local keep
                input_value "Сколько бэкапов оставить" "5" keep
                cleanup_old_backups "${keep:-5}"
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}
