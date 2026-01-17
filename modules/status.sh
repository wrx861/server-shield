#!/bin/bash
#
# status.sh - Проверка статуса защиты
# Premium UI v3.0
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"
source "$(dirname "$0")/ssh.sh" 2>/dev/null || source "/opt/server-shield/modules/ssh.sh"
source "$(dirname "$0")/kernel.sh" 2>/dev/null || source "/opt/server-shield/modules/kernel.sh"
source "$(dirname "$0")/fail2ban.sh" 2>/dev/null || source "/opt/server-shield/modules/fail2ban.sh"
source "$(dirname "$0")/rkhunter.sh" 2>/dev/null || source "/opt/server-shield/modules/rkhunter.sh"

# Полный статус защиты
show_full_status() {
    print_header_mini "Статус защиты сервера"
    
    # Информация о сервере
    echo ""
    echo -e "    ${WHITE}Сервер${NC}"
    show_info "Hostname" "$(get_hostname)"
    show_info "IP" "$(get_external_ip)"
    show_info "OS" "$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
    show_info "Uptime" "$(uptime -p 2>/dev/null | sed 's/up //')"
    
    # SSH
    echo ""
    echo -e "    ${WHITE}SSH${NC}"
    local ssh_port=$(get_ssh_port 2>/dev/null || echo "22")
    show_info "Порт" "$ssh_port"
    if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
        show_status_line "Пароли" "off" "Отключены"
    else
        show_status_line "Пароли" "on" "Включены"
    fi
    show_status_line "Ключи" "on" "Включены"
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
        show_status_line "Сервис" "on" "Активен"
    else
        show_status_line "Сервис" "off" "Не активен"
    fi
    
    # UFW
    echo ""
    echo -e "    ${WHITE}Firewall (UFW)${NC}"
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        show_status_line "Статус" "on" "Активен"
        local rules_count=$(ufw status | grep -c "ALLOW")
        show_info "Правил" "$rules_count"
    else
        show_status_line "Статус" "off" "Не активен"
    fi
    
    # Kernel Hardening
    echo ""
    echo -e "    ${WHITE}Kernel Hardening${NC}"
    if [[ -f "/etc/sysctl.d/99-shield-hardening.conf" ]]; then
        show_status_line "Статус" "on" "Настроен"
        
        local syn_cookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)
        local rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
        local aslr=$(sysctl -n kernel.randomize_va_space 2>/dev/null)
        
        [[ "$syn_cookies" == "1" ]] && show_status_line "SYN Cookies" "on" || show_status_line "SYN Cookies" "off"
        [[ "$rp_filter" == "1" ]] && show_status_line "RP Filter" "on" || show_status_line "RP Filter" "off"
        [[ "$aslr" == "2" ]] && show_status_line "ASLR" "on" "Полный" || show_status_line "ASLR" "warn" "Частичный"
    else
        show_status_line "Статус" "off" "Не настроен"
    fi
    
    # Fail2Ban
    echo ""
    echo -e "    ${WHITE}Fail2Ban${NC}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        show_status_line "Статус" "on" "Активен"
        local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d':' -f2 | tr -d ' \t')
        local jail_count=$(echo "$jails" | tr ',' '\n' | grep -c .)
        show_info "Джейлов" "$jail_count"
    else
        show_status_line "Статус" "off" "Не активен"
    fi
    
    # RKHunter
    echo ""
    echo -e "    ${WHITE}Rootkit Hunter${NC}"
    if command -v rkhunter &> /dev/null; then
        show_status_line "Статус" "on" "Установлен"
        if [[ -f "/etc/cron.weekly/rkhunter-shield" ]]; then
            show_status_line "Авто-скан" "on" "Еженедельно"
        else
            show_status_line "Авто-скан" "off"
        fi
    else
        show_status_line "Статус" "off" "Не установлен"
    fi
    
    # L7 Shield
    echo ""
    echo -e "    ${WHITE}L7 DDoS Protection${NC}"
    local l7_enabled=$(get_config "L7_ENABLED" "false" 2>/dev/null)
    if [[ "$l7_enabled" == "true" ]]; then
        show_status_line "Статус" "on" "Активен"
    else
        show_status_line "Статус" "off" "Выключен"
    fi
    
    # Telegram
    echo ""
    echo -e "    ${WHITE}Telegram${NC}"
    local tg_token=$(get_config "TG_TOKEN" "")
    if [[ -n "$tg_token" ]]; then
        show_status_line "Статус" "on" "Настроен"
    else
        show_status_line "Статус" "off" "Не настроен"
    fi
    
    # Бэкапы
    echo ""
    echo -e "    ${WHITE}Бэкапы${NC}"
    local backups_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    show_info "Доступно" "$backups_count"
    
    # Итоговая оценка
    echo ""
    print_divider
    echo ""
    
    # Считаем активные компоненты
    local active=0
    local total=6
    
    # SSH (checking password auth)
    grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null && ((active++))
    
    # UFW
    ufw status 2>/dev/null | grep -q "Status: active" && ((active++))
    
    # Kernel
    [[ -f /etc/sysctl.d/99-shield-hardening.conf ]] && ((active++))
    
    # Fail2Ban
    systemctl is-active --quiet fail2ban 2>/dev/null && ((active++))
    
    # L7 Shield
    [[ "$(get_config 'L7_ENABLED' 'false')" == "true" ]] && ((active++))
    
    # Telegram
    [[ -n "$(get_config 'TG_TOKEN' '')" ]] && ((active++))
    
    local percentage=$((active * 100 / total))
    
    echo -ne "    "
    if [[ $percentage -ge 80 ]]; then
        echo -e "${GREEN}██████████${NC} ${WHITE}$percentage%${NC} — Отличная защита!"
    elif [[ $percentage -ge 60 ]]; then
        echo -e "${GREEN}████████${NC}${DIM}██${NC} ${WHITE}$percentage%${NC} — Хорошая защита"
    elif [[ $percentage -ge 40 ]]; then
        echo -e "${YELLOW}██████${NC}${DIM}████${NC} ${WHITE}$percentage%${NC} — Средняя защита"
    else
        echo -e "${RED}████${NC}${DIM}██████${NC} ${WHITE}$percentage%${NC} — Слабая защита!"
    fi
    
    echo -e "    ${DIM}Активно компонентов:${NC} ${WHITE}$active${NC} / ${DIM}$total${NC}"
}

# Краткий статус
show_quick_status() {
    local ssh_status="${RED}○${NC}"
    local ufw_status="${RED}○${NC}"
    local kernel_status="${RED}○${NC}"
    local f2b_status="${RED}○${NC}"
    local l7_status="${RED}○${NC}"
    local tg_status="${RED}○${NC}"
    
    grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null && ssh_status="${GREEN}●${NC}"
    ufw status 2>/dev/null | grep -q "Status: active" && ufw_status="${GREEN}●${NC}"
    [[ -f /etc/sysctl.d/99-shield-hardening.conf ]] && kernel_status="${GREEN}●${NC}"
    systemctl is-active --quiet fail2ban 2>/dev/null && f2b_status="${GREEN}●${NC}"
    [[ "$(get_config 'L7_ENABLED' 'false')" == "true" ]] && l7_status="${GREEN}●${NC}"
    [[ -n "$(get_config 'TG_TOKEN' '')" ]] && tg_status="${GREEN}●${NC}"
    
    echo ""
    echo -e "    SSH:$ssh_status  UFW:$ufw_status  Kernel:$kernel_status  F2B:$f2b_status  L7:$l7_status  TG:$tg_status"
}

# CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        quick) show_quick_status ;;
        *) show_full_status ;;
    esac
fi
