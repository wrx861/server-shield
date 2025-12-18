#!/bin/bash
#
# kernel.sh - Kernel Hardening (sysctl)
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

SYSCTL_CONF="/etc/sysctl.d/99-shield-hardening.conf"

# Применение kernel hardening
apply_kernel_hardening() {
    log_step "Настройка Kernel Hardening..."
    
    # Создаём бэкап текущих настроек
    sysctl -a > "$BACKUP_DIR/sysctl.$(date +%Y%m%d_%H%M%S).backup" 2>/dev/null
    
    # Создаём конфиг
    cat > "$SYSCTL_CONF" << 'SYSCTL'
# ============================================
# Server Shield - Kernel Hardening
# ============================================

# ============ Защита от DDoS (SYN Flood) ============
# Включаем SYN cookies для защиты от SYN-flood атак
net.ipv4.tcp_syncookies = 1

# Уменьшаем количество повторных SYN-ACK
net.ipv4.tcp_synack_retries = 2

# Уменьшаем количество повторных SYN
net.ipv4.tcp_syn_retries = 2

# Увеличиваем очередь подключений
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096

# ============ Защита от IP Spoofing ============
# Отключаем Source Routing (защита от подмены маршрута)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Включаем проверку обратного пути (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ============ Защита от ICMP атак ============
# Игнорируем ICMP redirect (защита от перенаправления трафика)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Не отправляем ICMP redirect
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Игнорируем broadcast ping (защита от Smurf атак)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Игнорируем некорректные ICMP ответы
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ============ Оптимизация TCP ============
# Быстрое переиспользование TIME-WAIT сокетов
net.ipv4.tcp_tw_reuse = 1

# Быстрое закрытие соединений
net.ipv4.tcp_fin_timeout = 15

# Keepalive настройки (обнаружение мёртвых соединений)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# ============ Защита ядра ============
# Защита от переполнения буфера (ASLR)
kernel.randomize_va_space = 2

# Ограничение доступа к dmesg
kernel.dmesg_restrict = 1

# Ограничение ptrace (защита от отладки процессов)
kernel.yama.ptrace_scope = 1

# Защита символьных ссылок
fs.protected_symlinks = 1
fs.protected_hardlinks = 1

# ============ Сохраняем IP Forwarding (для VPN) ============
# Не трогаем - нужно для VPN/моста
# net.ipv4.ip_forward = 1
# net.ipv6.conf.all.forwarding = 1
SYSCTL
    
    # Применяем настройки
    sysctl -p "$SYSCTL_CONF" > /dev/null 2>&1
    
    log_info "Kernel Hardening применён"
}

# Проверка статуса kernel hardening
check_kernel_status() {
    echo ""
    echo -e "${WHITE}Kernel Hardening Статус:${NC}"
    
    if [[ -f "$SYSCTL_CONF" ]]; then
        echo -e "  ${GREEN}✓${NC} Конфиг: ${CYAN}$SYSCTL_CONF${NC}"
        
        # Проверяем ключевые параметры
        local syn_cookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)
        local source_route=$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null)
        local rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
        local aslr=$(sysctl -n kernel.randomize_va_space 2>/dev/null)
        
        echo ""
        echo -e "  ${WHITE}Ключевые параметры:${NC}"
        
        [[ "$syn_cookies" == "1" ]] && echo -e "    ${GREEN}✓${NC} SYN Cookies: Включены" || echo -e "    ${RED}✗${NC} SYN Cookies: Отключены"
        [[ "$source_route" == "0" ]] && echo -e "    ${GREEN}✓${NC} Source Routing: Отключен" || echo -e "    ${RED}✗${NC} Source Routing: Включен"
        [[ "$rp_filter" == "1" ]] && echo -e "    ${GREEN}✓${NC} RP Filter: Включен" || echo -e "    ${RED}✗${NC} RP Filter: Отключен"
        [[ "$aslr" == "2" ]] && echo -e "    ${GREEN}✓${NC} ASLR: Полный" || echo -e "    ${YELLOW}○${NC} ASLR: Частичный"
    else
        echo -e "  ${YELLOW}○${NC} Kernel Hardening не настроен"
    fi
}

# Откат kernel hardening
revert_kernel_hardening() {
    if [[ -f "$SYSCTL_CONF" ]]; then
        rm -f "$SYSCTL_CONF"
        sysctl --system > /dev/null 2>&1
        log_info "Kernel Hardening откачен"
    else
        log_warn "Kernel Hardening не был настроен"
    fi
}
