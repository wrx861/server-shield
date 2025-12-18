#!/bin/bash
#
# status.sh - Проверка статуса защиты
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"
source "$(dirname "$0")/ssh.sh" 2>/dev/null || source "/opt/server-shield/modules/ssh.sh"
source "$(dirname "$0")/kernel.sh" 2>/dev/null || source "/opt/server-shield/modules/kernel.sh"
source "$(dirname "$0")/fail2ban.sh" 2>/dev/null || source "/opt/server-shield/modules/fail2ban.sh"
source "$(dirname "$0")/rkhunter.sh" 2>/dev/null || source "/opt/server-shield/modules/rkhunter.sh"

# Полный статус защиты
show_full_status() {
    print_header
    print_section "📊 Статус защиты сервера"
    
    # Информация о сервере
    echo ""
    echo -e "${WHITE}Сервер:${NC}"
    echo -e "  Hostname: ${CYAN}$(get_hostname)${NC}"
    echo -e "  IP: ${CYAN}$(get_external_ip)${NC}"
    echo -e "  OS: ${CYAN}$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
    echo -e "  Uptime: ${CYAN}$(uptime -p 2>/dev/null | sed 's/up //')${NC}"
    
    # SSH
    check_ssh_status
    
    # UFW
    echo ""
    echo -e "${WHITE}Firewall (UFW):${NC}"
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "  ${GREEN}✓${NC} Статус: ${GREEN}Активен${NC}"
        local rules_count=$(ufw status | grep -c "ALLOW")
        echo -e "  Правил: ${CYAN}$rules_count${NC}"
    else
        echo -e "  ${RED}✗${NC} Статус: ${RED}Не активен${NC}"
    fi
    
    # Kernel Hardening
    check_kernel_status
    
    # Fail2Ban
    check_fail2ban_status
    
    # Rootkit Hunter
    check_rkhunter_status
    
    # Telegram
    echo ""
    echo -e "${WHITE}Telegram:${NC}"
    local tg_token=$(get_config "TG_TOKEN" "")
    if [[ -n "$tg_token" ]]; then
        echo -e "  ${GREEN}✓${NC} Статус: ${GREEN}Настроен${NC}"
    else
        echo -e "  ${YELLOW}○${NC} Статус: ${YELLOW}Не настроен${NC}"
    fi
    
    # Бэкапы
    echo ""
    echo -e "${WHITE}Бэкапы:${NC}"
    local backups_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    echo -e "  Доступно бэкапов: ${CYAN}$backups_count${NC}"
    
    # Итоговая оценка
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Считаем активные компоненты
    local active=0
    local total=5
    
    # SSH (checking password auth)
    grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null && ((active++))
    
    # UFW
    ufw status 2>/dev/null | grep -q "Status: active" && ((active++))
    
    # Kernel
    [[ -f /etc/sysctl.d/99-shield-hardening.conf ]] && ((active++))
    
    # Fail2Ban
    systemctl is-active --quiet fail2ban 2>/dev/null && ((active++))
    
    # Telegram
    [[ -n "$(get_config 'TG_TOKEN' '')" ]] && ((active++))
    
    local percentage=$((active * 100 / total))
    
    if [[ $percentage -ge 80 ]]; then
        echo -e "  ${GREEN}██████████${NC} ${WHITE}$percentage%${NC} - Отличная защита!"
    elif [[ $percentage -ge 60 ]]; then
        echo -e "  ${YELLOW}████████${NC}░░ ${WHITE}$percentage%${NC} - Хорошая защита"
    elif [[ $percentage -ge 40 ]]; then
        echo -e "  ${YELLOW}██████${NC}░░░░ ${WHITE}$percentage%${NC} - Средняя защита"
    else
        echo -e "  ${RED}████${NC}░░░░░░ ${WHITE}$percentage%${NC} - Слабая защита!"
    fi
    
    echo -e "  ${WHITE}Активно компонентов:${NC} $active / $total"
}

# Краткий статус
show_quick_status() {
    local ssh_status="${RED}✗${NC}"
    local ufw_status="${RED}✗${NC}"
    local kernel_status="${RED}✗${NC}"
    local f2b_status="${RED}✗${NC}"
    local tg_status="${RED}✗${NC}"
    
    grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null && ssh_status="${GREEN}✓${NC}"
    ufw status 2>/dev/null | grep -q "Status: active" && ufw_status="${GREEN}✓${NC}"
    [[ -f /etc/sysctl.d/99-shield-hardening.conf ]] && kernel_status="${GREEN}✓${NC}"
    systemctl is-active --quiet fail2ban 2>/dev/null && f2b_status="${GREEN}✓${NC}"
    [[ -n "$(get_config 'TG_TOKEN' '')" ]] && tg_status="${GREEN}✓${NC}"
    
    echo ""
    echo -e "  SSH: $ssh_status  UFW: $ufw_status  Kernel: $kernel_status  Fail2Ban: $f2b_status  Telegram: $tg_status"
}

# CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        quick) show_quick_status ;;
        *) show_full_status ;;
    esac
fi
