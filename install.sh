#!/bin/bash
#
# Server Shield - Установщик
# Premium UI v3.3
#

# ============================================
# ЦВЕТА И СТИЛИ
# ============================================

RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
CYAN=$'\e[0;36m'
PURPLE=$'\e[0;35m'
WHITE=$'\e[1;37m'
DIM=$'\e[2m'
BOLD=$'\e[1m'
NC=$'\e[0m'

# Пути
SHIELD_DIR="/opt/server-shield"
GITHUB_RAW="https://raw.githubusercontent.com/wrx861/server-shield/main"

# ============================================
# PREMIUM UI ФУНКЦИИ
# ============================================

print_logo() {
    echo -e "${CYAN}"
    echo '    ███████╗██╗  ██╗██╗███████╗██╗     ██████╗ '
    echo '    ██╔════╝██║  ██║██║██╔════╝██║     ██╔══██╗'
    echo '    ███████╗███████║██║█████╗  ██║     ██║  ██║'
    echo '    ╚════██║██╔══██║██║██╔══╝  ██║     ██║  ██║'
    echo '    ███████║██║  ██║██║███████╗███████╗██████╔╝'
    echo '    ╚══════╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚═════╝ '
    echo -e "${NC}"
}

print_header() {
    clear
    print_logo
    local version=$(get_version)
    echo -e "    ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    ${WHITE}Server Security Suite${NC}  ${CYAN}v${version}${NC}"
    echo -e "    ${DIM}Enterprise Protection for VPN Providers${NC}"
    echo -e "    ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "    ${CYAN}▸${NC} ${WHITE}$1${NC}"
    echo -e "    ${DIM}─────────────────────────────────────────────${NC}"
}

print_step() {
    echo -e "    ${BLUE}●${NC} $1"
}

print_success() {
    echo -e "    ${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "    ${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "    ${RED}✗${NC} $1"
}

print_info() {
    echo -e "    ${DIM}$1${NC}"
}

print_divider() {
    echo -e "    ${DIM}─────────────────────────────────────────────${NC}"
}

menu_item() {
    local key="$1"
    local text="$2"
    echo -e "    ${WHITE}[$key]${NC} $text"
}

read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    echo -ne "    ${CYAN}▸${NC} $prompt"
    if [[ -n "$default" ]]; then
        echo -ne " ${DIM}[$default]${NC}"
    fi
    echo -ne ": "
    read -r input
    
    if [[ -z "$input" ]]; then
        eval "$var_name=\"$default\""
    else
        eval "$var_name=\"$input\""
    fi
}

# Получить версию
get_version() {
    if [[ -f "$SHIELD_DIR/VERSION" ]]; then
        cat "$SHIELD_DIR/VERSION"
    else
        curl -s "$GITHUB_RAW/VERSION" 2>/dev/null || echo "3.3.0"
    fi
}

# ============================================
# ПРОВЕРКИ
# ============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Требуются права root!"
        exit 1
    fi
}

check_ssh_keys() {
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        echo ""
        echo -e "    ${RED}┌─────────────────────────────────────────────┐${NC}"
        echo -e "    ${RED}│${NC}  ${YELLOW}⚠${NC}  ${WHITE}SSH-КЛЮЧИ НЕ НАЙДЕНЫ!${NC}                  ${RED}│${NC}"
        echo -e "    ${RED}│${NC}                                             ${RED}│${NC}"
        echo -e "    ${RED}│${NC}  ${DIM}Скрипт отключит вход по паролям.${NC}          ${RED}│${NC}"
        echo -e "    ${RED}│${NC}  ${DIM}Без SSH-ключа вы потеряете доступ!${NC}        ${RED}│${NC}"
        echo -e "    ${RED}└─────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Создать SSH-ключ на сервере"
        menu_item "2" "Вставить свой публичный ключ"
        menu_item "0" "Отмена"
        echo ""
        
        echo -ne "    ${CYAN}▸${NC} Выбор: "
        read -r key_choice
        
        case $key_choice in
            1)
                mkdir -p /root/.ssh && chmod 700 /root/.ssh
                ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
                cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                
                echo ""
                print_success "SSH-ключ создан!"
                echo ""
                echo -e "    ${YELLOW}┌─────────────────────────────────────────────┐${NC}"
                echo -e "    ${YELLOW}│${NC}  ${WHITE}СОХРАНИТЕ ПРИВАТНЫЙ КЛЮЧ:${NC}                  ${YELLOW}│${NC}"
                echo -e "    ${YELLOW}└─────────────────────────────────────────────┘${NC}"
                echo ""
                echo -e "${GREEN}$(cat /root/.ssh/id_ed25519)${NC}"
                echo ""
                echo -e "    ${DIM}Скопируйте ключ в Termius/SSH-клиент${NC}"
                echo ""
                read -p "    Нажмите Enter после сохранения..."
                ;;
            2)
                mkdir -p /root/.ssh && chmod 700 /root/.ssh
                echo ""
                echo -ne "    ${CYAN}▸${NC} Публичный ключ: "
                read -r pubkey
                if [[ -n "$pubkey" ]]; then
                    echo "$pubkey" >> /root/.ssh/authorized_keys
                    chmod 600 /root/.ssh/authorized_keys
                    print_success "Ключ добавлен!"
                else
                    print_error "Ключ не введён"
                    exit 1
                fi
                ;;
            *)
                print_info "Установка отменена"
                exit 0
                ;;
        esac
    fi
    
    print_success "SSH-ключи найдены"
}

# ============================================
# ПРОВЕРКА FIREWALL
# ============================================

check_existing_firewall() {
    if ! command -v ufw &> /dev/null; then
        return 0
    fi
    
    local ufw_status=$(ufw status 2>/dev/null)
    
    if echo "$ufw_status" | grep -q "inactive"; then
        return 0
    fi
    
    local rules_count=$(echo "$ufw_status" | grep "ALLOW" | grep -v "(v6)" | wc -l)
    
    if [[ "$rules_count" -eq 0 ]]; then
        return 0
    fi
    
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    ssh_port=${ssh_port:-22}
    
    print_section "СУЩЕСТВУЮЩИЕ ПРАВИЛА FIREWALL"
    echo ""
    echo -e "    ${WHITE}UFW:${NC} ${GREEN}Активен${NC}  ${WHITE}Правил:${NC} ${CYAN}$rules_count${NC}"
    echo ""
    
    echo -e "    ${WHITE}Открытые порты:${NC}"
    echo "$ufw_status" | grep "ALLOW" | grep -v "(v6)" | while read line; do
        local port=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
        [[ ! "$port" =~ ^[0-9]+$ ]] && continue
        
        local desc=""
        case "$port" in
            "$ssh_port") desc="SSH" ;;
            22) desc="SSH" ;;
            80) desc="HTTP" ;;
            443) desc="HTTPS/VPN" ;;
            2222) desc="Panel-Node" ;;
        esac
        
        echo -e "      ${CYAN}•${NC} $port ${desc:+${DIM}($desc)${NC}}"
    done
    
    echo ""
    print_divider
    echo ""
    
    local issues=false
    local port22_open=false
    local ssh_open_all=false
    
    if echo "$ufw_status" | grep -v "(v6)" | grep -E "^22[^0-9]" | grep -q "ALLOW"; then
        port22_open=true
    fi
    
    if echo "$ufw_status" | grep -v "(v6)" | grep -E "^${ssh_port}[^0-9]" | grep -q "Anywhere"; then
        ssh_open_all=true
    fi
    
    if [[ "$port22_open" == true ]] && [[ "$ssh_port" != "22" ]]; then
        issues=true
        print_warn "Порт 22 открыт, но SSH на $ssh_port"
    fi
    
    if [[ "$ssh_open_all" == true ]]; then
        issues=true
        print_warn "SSH открыт для всех IP"
    fi
    
    echo ""
    
    if [[ "$issues" == true ]]; then
        menu_item "1" "${GREEN}Исправить проблемы${NC} (рекомендуется)"
        menu_item "2" "Оставить как есть"
        menu_item "3" "Полная перенастройка"
    else
        print_success "Настройки в порядке"
        echo ""
        menu_item "1" "${GREEN}Оставить${NC} (рекомендуется)"
        menu_item "2" "Полная перенастройка"
    fi
    
    echo ""
    echo -ne "    ${CYAN}▸${NC} Выбор ${DIM}[1]${NC}: "
    read -r fw_choice
    fw_choice=${fw_choice:-1}
    
    export PORT22_OPEN="$port22_open"
    export SSH_OPEN_ALL="$ssh_open_all"
    
    if [[ "$issues" == true ]]; then
        case "$fw_choice" in
            1) FIREWALL_MODE="fix_issues" ;;
            2) FIREWALL_MODE="keep" ;;
            3) FIREWALL_MODE="reset" ;;
            *) FIREWALL_MODE="fix_issues" ;;
        esac
    else
        case "$fw_choice" in
            1) FIREWALL_MODE="keep" ;;
            2) FIREWALL_MODE="reset" ;;
            *) FIREWALL_MODE="keep" ;;
        esac
    fi
    
    export FIREWALL_MODE
}

# ============================================
# СБОР НАСТРОЕК
# ============================================

collect_settings() {
    print_section "НАСТРОЙКА ЗАЩИТЫ"
    
    # Firewall
    check_existing_firewall
    
    # Имя сервера
    echo ""
    echo -e "    ${WHITE}Название сервера${NC} ${DIM}(для Telegram)${NC}"
    echo -e "    ${DIM}Примеры: USA-Node-1, NL-Panel, DE-VPN${NC}"
    read_input "Имя" "$(hostname)" SERVER_NAME
    
    # Роль
    echo ""
    echo -e "    ${WHITE}Роль сервера:${NC}"
    menu_item "1" "Панель управления / База"
    menu_item "2" "VPN Нода"
    echo ""
    echo -ne "    ${CYAN}▸${NC} Выбор ${DIM}[1]${NC}: "
    read -r SERVER_TYPE
    SERVER_TYPE=${SERVER_TYPE:-1}
    
    # IP админа
    echo ""
    echo -e "    ${WHITE}IP администратора${NC} ${DIM}(для SSH)${NC}"
    
    local client_ip=""
    client_ip=$(echo "$SSH_CLIENT" 2>/dev/null | awk '{print $1}')
    [[ -z "$client_ip" ]] && client_ip=$(echo "$SSH_CONNECTION" 2>/dev/null | awk '{print $1}')
    
    if [[ -n "$client_ip" ]]; then
        echo -e "    ${DIM}Ваш IP: ${CYAN}$client_ip${NC}"
        echo -e "    ${DIM}Enter = использовать, 0 = пропустить${NC}"
        read_input "IP админа" "$client_ip" ADMIN_IP
        [[ "$ADMIN_IP" == "0" ]] && ADMIN_IP=""
    else
        read_input "IP админа" "" ADMIN_IP
    fi
    
    if [[ -n "$ADMIN_IP" ]]; then
        echo ""
        echo -e "    ${YELLOW}⚠ SSH будет доступен ТОЛЬКО с ${WHITE}$ADMIN_IP${NC}"
    fi
    
    # IP панели (для нод)
    PANEL_IP=""
    if [[ "$SERVER_TYPE" == "2" ]]; then
        echo ""
        echo -e "    ${WHITE}IP Панели управления${NC}"
        read_input "IP Панели" "" PANEL_IP
    fi
    
    # SSH порт
    local current_ssh=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    current_ssh=${current_ssh:-22}
    
    echo ""
    echo -e "    ${WHITE}Порт SSH${NC} ${DIM}(текущий: $current_ssh)${NC}"
    echo -e "    ${DIM}Порт 2222 занят панелями!${NC}"
    read_input "SSH порт" "$current_ssh" SSH_PORT
    
    # VPN порты (для нод)
    EXTRA_PORTS=""
    if [[ "$SERVER_TYPE" == "2" ]]; then
        echo ""
        echo -e "    ${WHITE}Доп. VPN порты${NC} ${DIM}(443 откроется авто)${NC}"
        read_input "Порты через пробел" "" EXTRA_PORTS
    fi
    
    # Telegram
    echo ""
    echo -e "    ${WHITE}Telegram уведомления${NC}"
    echo -e "    ${DIM}Получите токен у @BotFather${NC}"
    read_input "Bot Token" "" TG_TOKEN
    
    TG_CHAT_ID=""
    if [[ -n "$TG_TOKEN" ]]; then
        echo -e "    ${DIM}ID узнайте у @userinfobot${NC}"
        read_input "Chat ID" "" TG_CHAT_ID
    fi
    
    # Traffic limit (для нод)
    SETUP_TRAFFIC_LIMIT=""
    TRAFFIC_RATE=""
    TRAFFIC_PORTS=""
    if [[ "$SERVER_TYPE" == "2" ]]; then
        echo ""
        echo -e "    ${WHITE}Ограничение скорости клиентов${NC}"
        echo -ne "    ${CYAN}▸${NC} Настроить? ${DIM}(y/N)${NC}: "
        read -r setup_traffic
        
        if [[ "$setup_traffic" =~ ^[Yy]$ ]]; then
            SETUP_TRAFFIC_LIMIT="yes"
            read_input "Лимит (Mbps)" "10" TRAFFIC_RATE
            read_input "VPN порты" "443" TRAFFIC_PORTS
        fi
    fi
}

# ============================================
# УСТАНОВКА
# ============================================

install_packages() {
    print_step "Установка пакетов..."
    
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y >/dev/null 2>&1
    
    for pkg in ufw fail2ban chrony rkhunter unattended-upgrades curl ipset nftables; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || true
    done
    
    print_success "Пакеты установлены"
}

download_shield_files() {
    print_step "Скачивание Server Shield..."
    
    mkdir -p "$SHIELD_DIR"/{modules,backups,config,logs,scripts}
    
    local modules=(
        "utils.sh" "ssh.sh" "keys.sh" "firewall.sh" "kernel.sh"
        "fail2ban.sh" "telegram.sh" "rkhunter.sh" "backup.sh"
        "status.sh" "menu.sh" "traffic.sh" "monitor.sh"
        "updater.sh" "l7shield.sh"
    )
    
    for module in "${modules[@]}"; do
        curl -fsSL "$GITHUB_RAW/modules/$module" -o "$SHIELD_DIR/modules/$module" 2>/dev/null || true
    done
    
    curl -fsSL "$GITHUB_RAW/shield.sh" -o "$SHIELD_DIR/shield.sh" 2>/dev/null || true
    curl -fsSL "$GITHUB_RAW/uninstall.sh" -o "$SHIELD_DIR/uninstall.sh" 2>/dev/null || true
    curl -fsSL "$GITHUB_RAW/VERSION" -o "$SHIELD_DIR/VERSION" 2>/dev/null || echo "3.3.0" > "$SHIELD_DIR/VERSION"
    curl -fsSL "$GITHUB_RAW/README.md" -o "$SHIELD_DIR/README.md" 2>/dev/null || true
    curl -fsSL "$GITHUB_RAW/CHANGELOG.md" -o "$SHIELD_DIR/CHANGELOG.md" 2>/dev/null || true
    
    chmod +x "$SHIELD_DIR"/*.sh 2>/dev/null || true
    chmod +x "$SHIELD_DIR/modules/"*.sh 2>/dev/null || true
    
    ln -sf "$SHIELD_DIR/shield.sh" /usr/local/bin/shield
    
    print_success "Server Shield установлен"
}

apply_protection() {
    print_step "Применение защиты..."
    
    source "$SHIELD_DIR/modules/utils.sh"
    source "$SHIELD_DIR/modules/ssh.sh"
    source "$SHIELD_DIR/modules/firewall.sh"
    source "$SHIELD_DIR/modules/kernel.sh"
    source "$SHIELD_DIR/modules/fail2ban.sh"
    source "$SHIELD_DIR/modules/telegram.sh"
    source "$SHIELD_DIR/modules/backup.sh"
    
    init_directories
    
    # SSH
    harden_ssh "$SSH_PORT"
    print_success "SSH Hardening"
    
    # Firewall
    case "${FIREWALL_MODE}" in
        "reset")
            if [[ "$SERVER_TYPE" == "1" ]]; then
                setup_firewall_panel "$ADMIN_IP" "$SSH_PORT" "true"
            else
                setup_firewall_node "$ADMIN_IP" "$PANEL_IP" "$SSH_PORT" "$EXTRA_PORTS" "true"
            fi
            ;;
        "fix_issues")
            if [[ -f "/etc/default/ufw" ]]; then
                sed -i 's/^IPV6=yes/IPV6=no/' "/etc/default/ufw" 2>/dev/null
            fi
            
            if [[ "${PORT22_OPEN}" == "true" ]] && [[ "$SSH_PORT" != "22" ]]; then
                ufw delete allow 22/tcp 2>/dev/null
                ufw delete allow 22 2>/dev/null
            fi
            
            if [[ "${SSH_OPEN_ALL}" == "true" ]]; then
                ufw delete allow ${SSH_PORT}/tcp 2>/dev/null
            fi
            
            if [[ -n "$ADMIN_IP" ]]; then
                ufw allow from "$ADMIN_IP" to any port "$SSH_PORT" proto tcp comment 'Admin SSH' 2>/dev/null
            else
                ufw allow "$SSH_PORT"/tcp comment 'SSH' 2>/dev/null
            fi
            
            if [[ "$SERVER_TYPE" == "2" ]] && [[ -n "$PANEL_IP" ]]; then
                ufw allow from "$PANEL_IP" comment 'Panel Full Access' 2>/dev/null
            fi
            
            ufw --force reload 2>/dev/null
            ;;
        "keep"|*)
            if [[ -f "/etc/default/ufw" ]]; then
                sed -i 's/^IPV6=yes/IPV6=no/' "/etc/default/ufw" 2>/dev/null
            fi
            ;;
    esac
    print_success "UFW Firewall"
    
    # Kernel
    apply_kernel_hardening
    print_success "Kernel Hardening"
    
    # Fail2Ban
    setup_fail2ban "$SSH_PORT" "$TG_TOKEN" "$TG_CHAT_ID" "86400" "$ADMIN_IP"
    print_success "Fail2Ban"
    
    # Telegram
    if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        save_config "TG_TOKEN" "$TG_TOKEN"
        save_config "TG_CHAT_ID" "$TG_CHAT_ID"
        setup_ssh_login_notify
        print_success "Telegram"
    fi
    
    # Сохраняем настройки
    [[ -n "$ADMIN_IP" ]] && save_config "ADMIN_IP" "$ADMIN_IP"
    [[ -n "$SERVER_NAME" ]] && save_config "SERVER_NAME" "$SERVER_NAME"
    save_config "SSH_PORT" "$SSH_PORT"
    save_config "RKHUNTER_ENABLED" "false"
    
    # Auto Updates
    echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
    print_success "Auto Updates"
    
    # Traffic limit
    if [[ "$SETUP_TRAFFIC_LIMIT" == "yes" ]] && [[ -n "$TRAFFIC_RATE" ]]; then
        source "$SHIELD_DIR/modules/traffic.sh" 2>/dev/null || true
        if type save_traffic_config &>/dev/null; then
            local iface=$(detect_interface)
            save_traffic_config "IFACE" "$iface"
            save_traffic_config "PORTS" "$TRAFFIC_PORTS"
            save_traffic_config "RATE" "$TRAFFIC_RATE"
            save_traffic_config "ENABLED" "true"
            apply_limits 2>/dev/null
            enable_autostart 2>/dev/null
            print_success "Traffic Limit: ${TRAFFIC_RATE} Mbps"
        fi
    fi
    
    # Backup
    create_full_backup
    print_success "Бэкап создан"
}

show_result() {
    local version=$(cat "$SHIELD_DIR/VERSION" 2>/dev/null || echo "3.3.0")
    
    echo ""
    echo ""
    print_logo
    echo -e "    ${GREEN}┌─────────────────────────────────────────────┐${NC}"
    echo -e "    ${GREEN}│${NC}                                             ${GREEN}│${NC}"
    echo -e "    ${GREEN}│${NC}        ${WHITE}СЕРВЕР ЗАЩИЩЁН!${NC}                      ${GREEN}│${NC}"
    echo -e "    ${GREEN}│${NC}                                             ${GREEN}│${NC}"
    echo -e "    ${GREEN}└─────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "    ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "    ${WHITE}Установлено:${NC}"
    echo ""
    echo -e "    ${GREEN}✓${NC} SSH Hardening          ${DIM}порт: ${CYAN}$SSH_PORT${NC}"
    echo -e "    ${GREEN}✓${NC} Kernel Hardening       ${DIM}anti-DDoS${NC}"
    echo -e "    ${GREEN}✓${NC} UFW Firewall"
    echo -e "    ${GREEN}✓${NC} Fail2Ban"
    
    if [[ -n "$TG_TOKEN" ]]; then
        echo -e "    ${GREEN}✓${NC} Telegram"
    else
        echo -e "    ${YELLOW}○${NC} Telegram              ${DIM}shield telegram${NC}"
    fi
    
    echo -e "    ${DIM}○${NC} Rootkit Scanner       ${DIM}shield → k${NC}"
    echo -e "    ${GREEN}✓${NC} Auto Updates"
    echo -e "    ${GREEN}✓${NC} Бэкап создан"
    
    if [[ "$SETUP_TRAFFIC_LIMIT" == "yes" ]]; then
        echo -e "    ${GREEN}✓${NC} Traffic Limit         ${DIM}${TRAFFIC_RATE} Mbps/клиент${NC}"
    elif [[ "$SERVER_TYPE" == "2" ]]; then
        echo -e "    ${DIM}○${NC} Traffic Limit         ${DIM}shield → 6${NC}"
    fi
    
    echo -e "    ${DIM}○${NC} DDoS Protection       ${DIM}shield → 3${NC}"
    
    echo ""
    echo -e "    ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ -n "$ADMIN_IP" ]]; then
        echo -e "    ${WHITE}SSH доступ:${NC}     Только ${CYAN}$ADMIN_IP${NC}"
    else
        echo -e "    ${WHITE}SSH доступ:${NC}     ${YELLOW}Любой IP${NC} ${DIM}(рекомендуется ограничить)${NC}"
    fi
    
    echo -e "    ${WHITE}Вход по паролям:${NC} ${RED}ОТКЛЮЧЁН${NC}"
    echo ""
    echo -e "    ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "    ${WHITE}Управление:${NC}  ${CYAN}shield${NC}  или  ${CYAN}shield help${NC}"
    echo ""
    
    # Telegram notification
    if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        source "$SHIELD_DIR/modules/telegram.sh" 2>/dev/null
        send_install_complete 2>/dev/null
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    local reconfigure=false
    [[ "$1" == "--reconfigure" ]] && reconfigure=true
    
    print_header
    check_root
    
    if [[ "$reconfigure" == true ]]; then
        echo -e "    ${YELLOW}┌─────────────────────────────────────────────┐${NC}"
        echo -e "    ${YELLOW}│${NC}        ${WHITE}РЕЖИМ ПЕРЕНАСТРОЙКИ${NC}                 ${YELLOW}│${NC}"
        echo -e "    ${YELLOW}└─────────────────────────────────────────────┘${NC}"
        echo ""
    else
        check_ssh_keys
    fi
    
    collect_settings
    
    echo ""
    print_section "УСТАНОВКА"
    echo ""
    
    if [[ "$reconfigure" == false ]]; then
        install_packages
        download_shield_files
    fi
    
    apply_protection
    show_result
}

main "$@"
