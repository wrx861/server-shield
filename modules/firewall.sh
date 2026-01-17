#!/bin/bash
#
# firewall.sh - UFW Firewall настройки
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# ============================================
# АНАЛИЗ ТЕКУЩИХ ПРАВИЛ
# ============================================

# Получить список открытых портов
get_open_ports() {
    if ! command -v ufw &> /dev/null; then
        echo ""
        return
    fi
    
    # Парсим вывод ufw status
    ufw status 2>/dev/null | grep -E "ALLOW" | while read line; do
        # Извлекаем порт/протокол и комментарий
        local port=$(echo "$line" | awk '{print $1}')
        local from=$(echo "$line" | grep -oP "from \K[^ ]+" || echo "Anywhere")
        echo "$port ($from)"
    done
}

# Получить список whitelist IP
get_whitelist_ips() {
    ufw status 2>/dev/null | grep -E "ALLOW" | grep -v "/" | while read line; do
        local ip=$(echo "$line" | grep -oP "from \K[0-9.]+" 2>/dev/null)
        [[ -n "$ip" ]] && echo "$ip"
    done | sort -u
}

# Получить текущий SSH порт
get_current_ssh_port() {
    local port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    echo "${port:-22}"
}

# Показать текущие правила красиво
show_current_rules() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}📋 ТЕКУЩИЕ ПРАВИЛА FIREWALL${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Проверяем статус UFW
    local ufw_status=$(ufw status 2>/dev/null | head -1)
    
    if echo "$ufw_status" | grep -q "inactive"; then
        echo -e "  ${YELLOW}⚠️  UFW не активен${NC}"
        echo -e "  ${WHITE}Текущее состояние:${NC} Все порты открыты (нет защиты)"
        return 1
    elif echo "$ufw_status" | grep -q "active"; then
        echo -e "  ${GREEN}✓${NC} UFW активен"
    else
        echo -e "  ${RED}✗${NC} UFW не установлен"
        return 1
    fi
    
    # Политика по умолчанию
    echo ""
    echo -e "  ${WHITE}Политика по умолчанию:${NC}"
    local default_in=$(ufw status verbose 2>/dev/null | grep "Default:" | head -1)
    if echo "$default_in" | grep -q "deny"; then
        echo -e "    Входящие: ${GREEN}Блокируются${NC} (хорошо)"
    else
        echo -e "    Входящие: ${RED}Разрешены${NC} (опасно!)"
    fi
    
    # Получаем текущий SSH порт
    local ssh_port=$(get_current_ssh_port)
    
    # Открытые порты (только IPv4, без дублей)
    echo ""
    echo -e "  ${WHITE}Открытые порты:${NC}"
    
    local ports_found=false
    local seen_ports=""
    
    # Парсим вывод ufw status правильно
    # Формат: "22/tcp                     ALLOW       Anywhere"
    # или:    "2222                       ALLOW       64.188.71.12"
    while IFS= read -r line; do
        # Пропускаем IPv6 правила (содержат "(v6)" или "::")
        if echo "$line" | grep -qE "\(v6\)|::"; then
            continue
        fi
        
        # Пропускаем пустые строки и заголовки
        if [[ -z "$line" ]] || echo "$line" | grep -qE "^To|^--"; then
            continue
        fi
        
        # Извлекаем порт (первое поле)
        local port=$(echo "$line" | awk '{print $1}')
        
        # Пропускаем whitelist IP (первое поле = Anywhere)
        # Формат: "Anywhere                   ALLOW       64.188.71.12"
        if [[ "$port" == "Anywhere" ]]; then
            continue
        fi
        
        # Нормализуем порт (убираем /tcp, /udp)
        local port_num=$(echo "$port" | cut -d'/' -f1)
        
        # Проверяем что это число (порт), а не что-то другое
        if ! [[ "$port_num" =~ ^[0-9]+$ ]]; then
            continue
        fi
        
        # Определяем источник (откуда разрешено)
        local from="Anywhere"
        if echo "$line" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
            from=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        fi
        
        # Создаём уникальный ключ: порт + источник
        local unique_key="${port_num}_${from}"
        
        # Пропускаем если уже видели этот порт с этим источником
        if echo "$seen_ports" | grep -q "|${unique_key}|"; then
            continue
        fi
        seen_ports="${seen_ports}|${unique_key}|"
        
        ports_found=true
        
        # Определяем описание порта
        local desc=""
        
        # Проверяем SSH порт динамически
        if [[ "$port_num" == "$ssh_port" ]]; then
            desc="SSH"
        else
            case "$port_num" in
                22) desc="SSH" ;;
                80) desc="HTTP" ;;
                443) desc="HTTPS/VPN" ;;
                2222) desc="Panel-Node" ;;
                3306) desc="MySQL" ;;
                8080) desc="HTTP-ALT" ;;
                *) desc="" ;;
            esac
        fi
        
        # Выводим (используем port_num без /tcp)
        if [[ "$from" == "Anywhere" ]]; then
            echo -e "    ${YELLOW}•${NC} ${CYAN}$port_num${NC} ← Открыт для всех ${desc:+${WHITE}($desc)${NC}}"
        else
            echo -e "    ${GREEN}•${NC} ${CYAN}$port_num${NC} ← Только ${CYAN}$from${NC} ${desc:+${WHITE}($desc)${NC}}"
        fi
        
    done < <(ufw status 2>/dev/null | grep "ALLOW")
    
    if [[ "$ports_found" == false ]]; then
        echo -e "    ${RED}Нет открытых портов!${NC}"
    fi
    
    # Whitelist IP (полный доступ ко всем портам)
    echo ""
    echo -e "  ${WHITE}IP с полным доступом:${NC}"
    
    local whitelist_found=false
    # Ищем правила вида "Anywhere ALLOW X.X.X.X" (без указания порта)
    while IFS= read -r line; do
        # Пропускаем IPv6
        if echo "$line" | grep -qE "\(v6\)|::"; then
            continue
        fi
        
        # Ищем строки где первое поле "Anywhere" (доступ ко всем портам)
        if echo "$line" | grep -q "^Anywhere.*ALLOW"; then
            local ip=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
            if [[ -n "$ip" ]]; then
                echo -e "    ${GREEN}•${NC} $ip"
                whitelist_found=true
            fi
        fi
    done < <(ufw status 2>/dev/null | grep "ALLOW")
    
    if [[ "$whitelist_found" == false ]]; then
        echo -e "    ${YELLOW}Нет IP с полным доступом${NC}"
    fi
    
    echo ""
    return 0
}

# Спросить пользователя что делать с текущими правилами
ask_firewall_action() {
    local role="$1"  # panel или node
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}🔧 ВЫБЕРИТЕ ДЕЙСТВИЕ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${WHITE}1)${NC} 🛡️  Применить надёжные правила Shield"
    if [[ "$role" == "panel" ]]; then
        echo -e "      ${CYAN}SSH + HTTP(80) + HTTPS(443)${NC}"
    else
        echo -e "      ${CYAN}SSH + HTTPS(443/VPN) + доступ для панели${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}2)${NC} ➕ Добавить защиту к текущим правилам"
    echo -e "      ${CYAN}Сохранит ваши порты + добавит hardening${NC}"
    echo ""
    echo -e "  ${WHITE}3)${NC} 📋 Оставить текущие правила"
    echo -e "      ${CYAN}Ничего не менять${NC}"
    echo ""
    echo -e "  ${WHITE}0)${NC} ❌ Отмена"
    echo ""
    read -p "Ваш выбор: " choice
    
    echo "$choice"
}

# Сохранить текущие пользовательские порты
get_custom_ports() {
    # Получаем порты, которые не являются стандартными (22, 80, 443)
    ufw status 2>/dev/null | grep -E "ALLOW" | while read line; do
        local port=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
        case "$port" in
            22|80|443|2222) ;; # Пропускаем стандартные
            *) 
                if [[ "$port" =~ ^[0-9]+$ ]]; then
                    echo "$port"
                fi
                ;;
        esac
    done | sort -u
}

# ============================================
# НАСТРОЙКА FIREWALL (ОБНОВЛЁННАЯ)
# ============================================

# Отключить IPv6 в UFW
disable_ipv6_ufw() {
    local ufw_default="/etc/default/ufw"
    
    if [[ -f "$ufw_default" ]]; then
        # Проверяем текущее значение
        if grep -q "^IPV6=yes" "$ufw_default"; then
            log_step "Отключение IPv6 в UFW..."
            sed -i 's/^IPV6=yes/IPV6=no/' "$ufw_default"
            log_info "IPv6 в UFW отключен"
        fi
    fi
}

# Полное отключение IPv6 в системе
disable_ipv6_system() {
    log_step "Полное отключение IPv6 в системе..."
    
    local sysctl_conf="/etc/sysctl.d/99-disable-ipv6.conf"
    
    # Создаём конфиг для отключения IPv6
    cat > "$sysctl_conf" << 'SYSCTL'
# Disable IPv6 - Server Shield
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL

    # Применяем настройки
    sysctl -p "$sysctl_conf" > /dev/null 2>&1
    
    # Отключаем в UFW тоже
    disable_ipv6_ufw
    
    # Проверяем
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == "1" ]]; then
        log_info "IPv6 полностью отключен в системе"
    else
        log_warn "IPv6 будет отключен после перезагрузки"
    fi
}

# Включить IPv6 обратно
enable_ipv6_system() {
    log_step "Включение IPv6 в системе..."
    
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    
    # Включаем обратно
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
    
    # В UFW
    local ufw_default="/etc/default/ufw"
    if [[ -f "$ufw_default" ]]; then
        sed -i 's/^IPV6=no/IPV6=yes/' "$ufw_default"
    fi
    
    log_info "IPv6 включен (может потребоваться перезагрузка)"
}

# Проверить статус IPv6
check_ipv6_status() {
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == "1" ]]; then
        echo "disabled"
    else
        echo "enabled"
    fi
}

# Настройка фаервола для Панели
setup_firewall_panel() {
    local admin_ip="$1"
    local ssh_port="$2"
    local skip_prompt="${3:-false}"
    
    # Показываем текущие правила
    show_current_rules
    
    # Спрашиваем что делать (если не пропускаем промпт)
    local action="1"
    if [[ "$skip_prompt" != "true" ]]; then
        action=$(ask_firewall_action "panel")
    fi
    
    case "$action" in
        1)
            # Полный сброс и надёжные правила
            log_step "Применение надёжных правил для ПАНЕЛИ..."
            
            # Отключаем IPv6
            disable_ipv6_ufw
            
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
            
            echo "y" | ufw enable > /dev/null
            log_info "Фаервол для ПАНЕЛИ настроен"
            ;;
        2)
            # Добавить защиту к текущим
            log_step "Добавление защиты к текущим правилам..."
            
            # Устанавливаем политику deny если не установлена
            ufw default deny incoming 2>/dev/null
            ufw default allow outgoing 2>/dev/null
            
            # Добавляем SSH если нет
            if ! ufw status | grep -q "$ssh_port"; then
                if [[ -n "$admin_ip" ]]; then
                    ufw allow from "$admin_ip" to any port "$ssh_port" proto tcp comment 'Admin SSH'
                else
                    ufw allow "$ssh_port"/tcp comment 'SSH'
                fi
            fi
            
            # Добавляем web порты если нет
            ufw status | grep -q "80/tcp" || ufw allow 80/tcp comment 'HTTP'
            ufw status | grep -q "443/tcp" || ufw allow 443/tcp comment 'HTTPS'
            
            echo "y" | ufw enable > /dev/null
            log_info "Защита добавлена к текущим правилам"
            ;;
        3)
            log_info "Текущие правила сохранены"
            ;;
        0|*)
            log_info "Настройка фаервола отменена"
            return 1
            ;;
    esac
}

# Настройка фаервола для Ноды
setup_firewall_node() {
    local admin_ip="$1"
    local panel_ip="$2"
    local ssh_port="$3"
    local extra_ports="$4"
    local skip_prompt="${5:-false}"
    
    # Показываем текущие правила
    show_current_rules
    
    # Спрашиваем что делать
    local action="1"
    if [[ "$skip_prompt" != "true" ]]; then
        action=$(ask_firewall_action "node")
    fi
    
    case "$action" in
        1)
            # Полный сброс и надёжные правила
            log_step "Применение надёжных правил для НОДЫ..."
            
            # Отключаем IPv6
            disable_ipv6_ufw
            
            ufw --force reset > /dev/null 2>&1
            ufw default deny incoming
            ufw default allow outgoing
            
            # SSH для админа
            if [[ -n "$admin_ip" ]]; then
                ufw allow from "$admin_ip" to any port "$ssh_port" proto tcp comment 'Admin SSH'
                log_info "SSH доступ для админа: $admin_ip"
            fi
            
            # Доступ для панели
            if [[ -n "$panel_ip" ]]; then
                ufw allow from "$panel_ip" comment 'Panel Full Access'
                log_info "Полный доступ для панели: $panel_ip"
            fi
            
            # Если ни админ, ни панель не указаны
            if [[ -z "$admin_ip" ]] && [[ -z "$panel_ip" ]]; then
                ufw allow "$ssh_port"/tcp comment 'SSH'
                log_warn "SSH открыт для всех IP"
            fi
            
            # VPN порт
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
            
            echo "y" | ufw enable > /dev/null
            log_info "Фаервол для НОДЫ настроен"
            ;;
        2)
            # Добавить защиту к текущим
            log_step "Добавление защиты к текущим правилам..."
            
            ufw default deny incoming 2>/dev/null
            ufw default allow outgoing 2>/dev/null
            
            # SSH
            if ! ufw status | grep -q "$ssh_port"; then
                if [[ -n "$admin_ip" ]]; then
                    ufw allow from "$admin_ip" to any port "$ssh_port" proto tcp comment 'Admin SSH'
                else
                    ufw allow "$ssh_port"/tcp comment 'SSH'
                fi
            fi
            
            # Панель
            if [[ -n "$panel_ip" ]] && ! ufw status | grep -q "$panel_ip"; then
                ufw allow from "$panel_ip" comment 'Panel Full Access'
            fi
            
            # VPN
            ufw status | grep -q "443" || ufw allow 443 comment 'VLESS/VPN'
            
            echo "y" | ufw enable > /dev/null
            log_info "Защита добавлена к текущим правилам"
            ;;
        3)
            log_info "Текущие правила сохранены"
            ;;
        0|*)
            log_info "Настройка фаервола отменена"
            return 1
            ;;
    esac
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
        print_header_mini "Firewall (UFW)"
        
        # Статус блок
        local ufw_status=$(ufw status 2>/dev/null | head -1)
        local ufw_active=false
        local rules_count=0
        local ipv6_status=$(check_ipv6_status 2>/dev/null || echo "unknown")
        
        if echo "$ufw_status" | grep -q "active"; then
            ufw_active=true
            rules_count=$(ufw status 2>/dev/null | grep -c "ALLOW" || echo 0)
        fi
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
        if [[ "$ufw_active" == "true" ]]; then
            echo -e "    ${DIM}│${NC} Status: ${GREEN}● Active${NC}       Rules: ${CYAN}$rules_count${NC}                 ${DIM}│${NC}"
        else
            echo -e "    ${DIM}│${NC} Status: ${RED}○ Inactive${NC}     ${RED}NO PROTECTION!${NC}              ${DIM}│${NC}"
        fi
        if [[ "$ipv6_status" == "disabled" ]]; then
            echo -e "    ${DIM}│${NC} IPv6: ${GREEN}Disabled${NC}                                     ${DIM}│${NC}"
        else
            echo -e "    ${DIM}│${NC} IPv6: ${YELLOW}Enabled${NC}                                      ${DIM}│${NC}"
        fi
        echo -e "    ${DIM}└─────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Показать правила"
        menu_item "2" "Список правил (с номерами)"
        menu_item "3" "Перенастроить (Панель/Нода)"
        menu_divider
        menu_item "4" "Добавить IP в whitelist"
        menu_item "5" "Удалить IP из whitelist"
        menu_item "6" "Открыть порт"
        menu_item "7" "Закрыть порт"
        menu_divider
        menu_item "8" "Сбросить все правила"
        
        if [[ "$ufw_active" == "true" ]]; then
            echo -e "    ${RED}[9]${NC} ${RED}Выключить UFW${NC}"
        else
            echo -e "    ${GREEN}[9]${NC} ${GREEN}Включить UFW${NC}"
        fi
        
        if [[ "$ipv6_status" == "disabled" ]]; then
            menu_item "i" "Включить IPv6"
        else
            echo -e "    ${YELLOW}[i]${NC} ${YELLOW}Отключить IPv6 (рекомендуется)${NC}"
        fi
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1) 
                show_current_rules 
                press_any_key
                ;;
            2) 
                firewall_rules 
                press_any_key
                ;;
            3)
                reconfigure_firewall_menu
                press_any_key
                ;;
            4)
                echo ""
                local ip port
                input_value "IP адрес" "" ip
                input_value "Порт (Enter для полного доступа)" "" port
                [[ -n "$ip" ]] && firewall_allow_ip "$ip" "$port" "Manual"
                press_any_key
                ;;
            5)
                echo ""
                echo -e "    ${WHITE}Текущие IP в whitelist:${NC}"
                ufw status 2>/dev/null | grep "ALLOW" | grep -v "/" | while read line; do
                    echo "    $line"
                done
                echo ""
                local ip
                input_value "IP для удаления" "" ip
                [[ -n "$ip" ]] && firewall_deny_ip "$ip"
                press_any_key
                ;;
            6)
                echo ""
                local port proto
                input_value "Порт" "" port
                input_value "Протокол (tcp/udp/both)" "tcp" proto
                if [[ -n "$port" ]]; then
                    if [[ "$proto" == "both" ]]; then
                        firewall_open_port "$port" "tcp"
                        firewall_open_port "$port" "udp"
                    else
                        firewall_open_port "$port" "${proto:-tcp}"
                    fi
                fi
                press_any_key
                ;;
            7)
                echo ""
                echo -e "    ${WHITE}Открытые порты:${NC}"
                ufw status 2>/dev/null | grep "ALLOW" | grep "/" | while read line; do
                    echo "    $line"
                done
                echo ""
                local port proto
                input_value "Порт для закрытия" "" port
                input_value "Протокол (tcp/udp/both)" "tcp" proto
                if [[ -n "$port" ]]; then
                    if [[ "$proto" == "both" ]]; then
                        firewall_close_port "$port" "tcp"
                        firewall_close_port "$port" "udp"
                    else
                        firewall_close_port "$port" "${proto:-tcp}"
                    fi
                fi
                press_any_key
                ;;
            8)
                echo ""
                echo -e "    ${RED}⚠ ВНИМАНИЕ: Это удалит ВСЕ правила!${NC}"
                if confirm_action "Сбросить все правила?" "n"; then
                    ufw --force reset
                    log_info "Фаервол сброшен"
                fi
                press_any_key
                ;;
            9)
                if [[ "$ufw_active" == "true" ]]; then
                    echo ""
                    echo -e "    ${YELLOW}⚠ Отключение UFW уберёт защиту!${NC}"
                    if confirm_action "Выключить UFW?" "n"; then
                        ufw disable
                        log_warn "UFW выключен"
                    fi
                else
                    log_step "Включение UFW..."
                    echo "y" | ufw enable > /dev/null 2>&1
                    log_info "UFW включен"
                fi
                press_any_key
                ;;
            i)
                if [[ "$ipv6_status" == "disabled" ]]; then
                    if confirm_action "Включить IPv6?" "n"; then
                        enable_ipv6_system 2>/dev/null
                    fi
                else
                    echo -e "    ${DIM}Отключение IPv6 рекомендуется для безопасности${NC}"
                    if confirm_action "Отключить IPv6?" "y"; then
                        disable_ipv6_system 2>/dev/null
                        [[ "$ufw_active" == "true" ]] && ufw reload 2>/dev/null
                    fi
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# Меню перенастройки фаервола
reconfigure_firewall_menu() {
    print_header_mini "Перенастройка Firewall"
    
    echo -e "    ${WHITE}Выберите роль сервера:${NC}"
    echo ""
    menu_item "1" "ПАНЕЛЬ (SSH + HTTP + HTTPS)"
    menu_item "2" "НОДА (SSH + VPN 443 + доступ панели)"
    menu_item "0" "Отмена"
    
    local choice=$(read_choice)
    
    case "${choice,,}" in
        1)
            local ssh_port=$(get_config "SSH_PORT" "22")
            local new_ssh_port admin_ip
            input_value "SSH порт" "$ssh_port" new_ssh_port
            input_value "IP админа (Enter для доступа отовсюду)" "" admin_ip
            setup_firewall_panel "$admin_ip" "${new_ssh_port:-$ssh_port}"
            ;;
        2)
            local ssh_port=$(get_config "SSH_PORT" "22")
            local new_ssh_port admin_ip panel_ip extra_ports
            input_value "SSH порт" "$ssh_port" new_ssh_port
            input_value "IP админа (Enter для пропуска)" "" admin_ip
            input_value "IP Панели (Enter для пропуска)" "" panel_ip
            input_value "Доп. VPN порты через пробел" "" extra_ports
            setup_firewall_node "$admin_ip" "$panel_ip" "${new_ssh_port:-$ssh_port}" "$extra_ports"
            ;;
        0|*) 
            log_info "Отмена"
            ;;
    esac
}
