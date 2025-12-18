#!/bin/bash
#
# firewall.sh - UFW Firewall настройки
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# Настройка фаервола для Панели
setup_firewall_panel() {
    local admin_ip="$1"
    local ssh_port="$2"
    
    log_step "Настройка фаервола для ПАНЕЛИ..."
    
    # Сброс
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH
    if [[ -n "$admin_ip" ]]; then
        ufw allow from "$admin_ip" to any port "$ssh_port" proto tcp comment 'Admin SSH'
        log_info "SSH доступ ограничен для IP: $admin_ip"
    else
        ufw allow "$ssh_port"/tcp comment 'SSH'
        log_warn "SSH открыт для всех IP (рекомендуется ограничить)"
    fi
    
    # Web порты
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # Включаем UFW
    echo "y" | ufw enable > /dev/null
    
    log_info "Фаервол для ПАНЕЛИ настроен"
}

# Настройка фаервола для Ноды
setup_firewall_node() {
    local admin_ip="$1"
    local panel_ip="$2"
    local ssh_port="$3"
    local extra_ports="$4"
    
    log_step "Настройка фаервола для НОДЫ..."
    
    # Сброс
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH для админа
    if [[ -n "$admin_ip" ]]; then
        ufw allow from "$admin_ip" to any port "$ssh_port" proto tcp comment 'Admin SSH'
        log_info "SSH доступ для админа: $admin_ip"
    fi
    
    # Доступ для панели (все порты)
    if [[ -n "$panel_ip" ]]; then
        ufw allow from "$panel_ip" comment 'Panel Full Access'
        log_info "Полный доступ для панели: $panel_ip"
    fi
    
    # Если ни админ, ни панель не указаны - открываем SSH для всех
    if [[ -z "$admin_ip" ]] && [[ -z "$panel_ip" ]]; then
        ufw allow "$ssh_port"/tcp comment 'SSH'
        log_warn "SSH открыт для всех IP"
    fi
    
    # VPN порт (стандартный)
    ufw allow 443 comment 'VLESS/VPN'
    
    # Дополнительные порты
    if [[ -n "$extra_ports" ]]; then
        for port in $extra_ports; do
            if validate_port "$port"; then
                ufw allow "$port" comment 'Custom VPN'
                log_info "Открыт порт: $port"
            fi
        done
    fi
    
    # Включаем UFW
    echo "y" | ufw enable > /dev/null
    
    log_info "Фаервол для НОДЫ настроен"
}

# Добавить IP в whitelist
firewall_allow_ip() {
    local ip="$1"
    local port="${2:-}"
    local comment="${3:-Manual}"
    
    if ! validate_ip "$ip"; then
        log_error "Неверный IP: $ip"
        return 1
    fi
    
    if [[ -n "$port" ]]; then
        ufw allow from "$ip" to any port "$port" comment "$comment"
        log_info "Разрешён доступ $ip к порту $port"
    else
        ufw allow from "$ip" comment "$comment"
        log_info "Разрешён полный доступ для $ip"
    fi
}

# Удалить IP из whitelist
firewall_deny_ip() {
    local ip="$1"
    
    if ! validate_ip "$ip"; then
        log_error "Неверный IP: $ip"
        return 1
    fi
    
    # Удаляем все правила для этого IP
    ufw delete allow from "$ip" 2>/dev/null
    
    log_info "Удалены правила для $ip"
}

# Открыть порт
firewall_open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local comment="${3:-Manual}"
    
    if ! validate_port "$port"; then
        log_error "Неверный порт: $port"
        return 1
    fi
    
    ufw allow "$port/$proto" comment "$comment"
    log_info "Открыт порт: $port/$proto"
}

# Закрыть порт
firewall_close_port() {
    local port="$1"
    local proto="${2:-tcp}"
    
    if ! validate_port "$port"; then
        log_error "Неверный порт: $port"
        return 1
    fi
    
    ufw delete allow "$port/$proto" 2>/dev/null
    log_info "Закрыт порт: $port/$proto"
}

# Показать статус фаервола
firewall_status() {
    echo ""
    echo -e "${WHITE}Статус UFW:${NC}"
    echo ""
    ufw status verbose
}

# Показать правила в удобном виде
firewall_rules() {
    echo ""
    echo -e "${WHITE}Правила UFW:${NC}"
    echo ""
    ufw status numbered
}

# Меню управления фаерволом
firewall_menu() {
    while true; do
        print_header
        print_section "🔥 Управление Firewall (UFW)"
        echo ""
        echo -e "  ${WHITE}1)${NC} Статус фаервола"
        echo -e "  ${WHITE}2)${NC} Список правил"
        echo -e "  ${WHITE}3)${NC} Добавить IP в whitelist"
        echo -e "  ${WHITE}4)${NC} Удалить IP из whitelist"
        echo -e "  ${WHITE}5)${NC} Открыть порт"
        echo -e "  ${WHITE}6)${NC} Закрыть порт"
        echo -e "  ${WHITE}7)${NC} Сбросить все правила"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) firewall_status ;;
            2) firewall_rules ;;
            3)
                read -p "IP адрес: " ip
                read -p "Порт (Enter для всех): " port
                firewall_allow_ip "$ip" "$port" "Manual"
                ;;
            4)
                read -p "IP адрес: " ip
                firewall_deny_ip "$ip"
                ;;
            5)
                read -p "Порт: " port
                read -p "Протокол (tcp/udp/both) [tcp]: " proto
                proto=${proto:-tcp}
                if [[ "$proto" == "both" ]]; then
                    firewall_open_port "$port" "tcp"
                    firewall_open_port "$port" "udp"
                else
                    firewall_open_port "$port" "$proto"
                fi
                ;;
            6)
                read -p "Порт: " port
                read -p "Протокол (tcp/udp/both) [tcp]: " proto
                proto=${proto:-tcp}
                if [[ "$proto" == "both" ]]; then
                    firewall_close_port "$port" "tcp"
                    firewall_close_port "$port" "udp"
                else
                    firewall_close_port "$port" "$proto"
                fi
                ;;
            7)
                if confirm "Сбросить ВСЕ правила фаервола?" "n"; then
                    ufw --force reset
                    log_info "Фаервол сброшен"
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}
