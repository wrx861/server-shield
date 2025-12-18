#!/bin/bash
#
# Server Shield v2.0 - Главный установщик
#

# Цвета
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
CYAN=$'\e[0;36m'
WHITE=$'\e[1;37m'
NC=$'\e[0m'

# Пути
SHIELD_DIR="/opt/server-shield"
GITHUB_RAW="https://raw.githubusercontent.com/wrx861/server-shield/main"

# Функции вывода
print_header() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       🛡️  SERVER SECURITY SHIELD v2.0  🛡️           ║${NC}"
    echo -e "${GREEN}║         Защита сервера за 30 секунд                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

# =====================================================
# ПРОВЕРКИ
# =====================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от root!"
        exit 1
    fi
}

check_ssh_keys() {
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠️  ВНИМАНИЕ! SSH-ключи не найдены!                ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Скрипт отключит вход по паролям!${NC}"
        echo -e "Если вы не добавите SSH-ключ — потеряете доступ!"
        echo ""
        echo -e "${WHITE}Выберите действие:${NC}"
        echo "  1) Создать новый SSH-ключ на сервере"
        echo "  2) Вставить свой публичный ключ"
        echo "  0) Отмена установки"
        echo ""
        read -p "Ваш выбор: " key_choice
        
        case $key_choice in
            1)
                mkdir -p /root/.ssh
                chmod 700 /root/.ssh
                ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
                cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                
                echo ""
                log_info "SSH-ключ создан!"
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}  ВАЖНО! Сохраните приватный ключ в Termius/SSH-клиент:${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${GREEN}$(cat /root/.ssh/id_ed25519)${NC}"
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
                read -p "Нажмите Enter после сохранения ключа..."
                ;;
            2)
                mkdir -p /root/.ssh
                chmod 700 /root/.ssh
                echo ""
                echo -e "Вставьте ваш публичный ключ (ssh-ed25519 или ssh-rsa):"
                read -r pubkey
                if [[ -n "$pubkey" ]]; then
                    echo "$pubkey" >> /root/.ssh/authorized_keys
                    chmod 600 /root/.ssh/authorized_keys
                    log_info "Ключ добавлен!"
                else
                    log_error "Ключ не введён"
                    exit 1
                fi
                ;;
            0)
                log_info "Установка отменена"
                exit 0
                ;;
            *)
                log_error "Неверный выбор"
                exit 1
                ;;
        esac
    fi
    
    log_info "SSH-ключи найдены ✓"
}

# =====================================================
# ПРОВЕРКА ТЕКУЩЕГО FIREWALL
# =====================================================

check_existing_firewall() {
    # Проверяем установлен ли UFW и есть ли правила
    if ! command -v ufw &> /dev/null; then
        return 0
    fi
    
    local ufw_status=$(ufw status 2>/dev/null)
    
    # Если UFW не активен — пропускаем
    if echo "$ufw_status" | grep -q "inactive"; then
        return 0
    fi
    
    # Считаем количество правил (только IPv4)
    local rules_count=$(echo "$ufw_status" | grep "ALLOW" | grep -v "(v6)" | wc -l)
    
    if [[ "$rules_count" -eq 0 ]]; then
        return 0
    fi
    
    # Получаем текущий SSH порт
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    ssh_port=${ssh_port:-22}
    
    # Есть правила - показываем их
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  ОБНАРУЖЕНЫ СУЩЕСТВУЮЩИЕ ПРАВИЛА FIREWALL        ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}UFW статус:${NC} ${GREEN}Активен${NC}"
    echo -e "  ${WHITE}Правил (IPv4):${NC} ${CYAN}$rules_count${NC}"
    echo ""
    echo -e "  ${WHITE}Текущие открытые порты:${NC}"
    
    # Показываем правила (только IPv4, без дублей)
    local seen_ports=""
    echo "$ufw_status" | grep "ALLOW" | while read line; do
        # Пропускаем IPv6
        if echo "$line" | grep -qE "\(v6\)|::"; then
            continue
        fi
        
        local port=$(echo "$line" | awk '{print $1}')
        
        # Нормализуем порт для проверки дубликатов (убираем /tcp, /udp)
        local port_num=$(echo "$port" | cut -d'/' -f1)
        
        # Определяем источник
        local from="Anywhere"
        if echo "$line" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
            from=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        fi
        
        # Создаём уникальный ключ: порт + источник
        local unique_key="${port_num}_${from}"
        
        # Пропускаем дубликаты
        if echo "$seen_ports" | grep -q "|${unique_key}|"; then
            continue
        fi
        seen_ports="${seen_ports}|${unique_key}|"
        
        # Определяем тип порта
        local desc=""
        
        if [[ "$port_num" == "$ssh_port" ]]; then
            desc="SSH"
        else
            case "$port_num" in
                22) desc="SSH" ;;
                80) desc="HTTP" ;;
                443) desc="HTTPS/VPN" ;;
                2222) desc="Panel-Node" ;;
                3306) desc="MySQL" ;;
            esac
        fi
        
        if [[ "$from" == "Anywhere" ]]; then
            echo -e "    ${YELLOW}•${NC} ${CYAN}$port_num${NC} ← открыт для всех ${desc:+${WHITE}($desc)${NC}}"
        else
            echo -e "    ${GREEN}•${NC} ${CYAN}$port_num${NC} ← только ${CYAN}$from${NC} ${desc:+${WHITE}($desc)${NC}}"
        fi
    done
    
    # Показываем whitelist IP (полный доступ)
    local whitelist_found=false
    echo ""
    echo -e "  ${WHITE}IP с полным доступом:${NC}"
    echo "$ufw_status" | grep "ALLOW" | grep -v "(v6)" | while read line; do
        if echo "$line" | grep -q "^Anywhere.*ALLOW"; then
            local ip=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
            if [[ -n "$ip" ]]; then
                echo -e "    ${GREEN}•${NC} $ip"
                whitelist_found=true
            fi
        fi
    done
    
    if [[ "$whitelist_found" == false ]]; then
        echo -e "    ${YELLOW}Нет${NC}"
    fi
    
    # Анализируем текущие правила
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}🔍 АНАЛИЗ БЕЗОПАСНОСТИ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local issues_found=false
    local port22_open=false
    local ssh_open_all=false
    
    # Проверяем открыт ли порт 22 (стандартный SSH)
    if echo "$ufw_status" | grep -v "(v6)" | grep -E "^22[^0-9]|^22/tcp" | grep -q "ALLOW"; then
        port22_open=true
    fi
    
    # Проверяем открыт ли текущий SSH порт для всех
    if echo "$ufw_status" | grep -v "(v6)" | grep -E "^${ssh_port}[^0-9]|^${ssh_port}/tcp" | grep -q "Anywhere"; then
        ssh_open_all=true
    fi
    
    # Показываем проблемы
    
    # 1. Порт 22 открыт, но SSH на другом порту
    if [[ "$port22_open" == true ]] && [[ "$ssh_port" != "22" ]]; then
        issues_found=true
        echo -e "  ${RED}⚠️${NC}  Порт 22 открыт, но SSH работает на порту $ssh_port"
        echo -e "      ${WHITE}Рекомендация:${NC} закрыть неиспользуемый порт 22"
    fi
    
    # 2. SSH порт открыт для всех
    if [[ "$ssh_open_all" == true ]]; then
        issues_found=true
        echo -e "  ${YELLOW}⚠️${NC}  SSH (порт $ssh_port) открыт для ВСЕХ IP"
        echo -e "      ${WHITE}Рекомендация:${NC} ограничить доступ по IP"
    elif [[ "$ssh_port" != "22" ]] || [[ "$port22_open" == false ]]; then
        echo -e "  ${GREEN}✓${NC}  SSH (порт $ssh_port) защищён"
    fi
    
    # 3. Проверяем default policy
    if ufw status verbose 2>/dev/null | grep -q "deny (incoming)"; then
        echo -e "  ${GREEN}✓${NC}  Входящие подключения блокируются по умолчанию"
    else
        issues_found=true
        echo -e "  ${YELLOW}⚠️${NC}  Входящие подключения НЕ блокируются по умолчанию"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}Что сделать?${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ "$issues_found" == true ]]; then
        echo -e "  ${WHITE}1)${NC} 🔒 Исправить проблемы (рекомендуется)"
        if [[ "$port22_open" == true ]] && [[ "$ssh_port" != "22" ]]; then
            echo -e "      ${CYAN}• Закроем порт 22${NC}"
        fi
        if [[ "$ssh_open_all" == true ]]; then
            echo -e "      ${CYAN}• Ограничим SSH по IP админа/панели${NC}"
        fi
        echo ""
        echo -e "  ${WHITE}2)${NC} ✅ Оставить как есть"
        echo -e "      ${CYAN}Ничего не меняем${NC}"
        echo ""
        echo -e "  ${WHITE}3)${NC} 🔄 Полная перенастройка"
        echo -e "      ${CYAN}Сбросить всё и настроить с нуля${NC}"
    else
        echo -e "  ${GREEN}✓ У вас уже хорошо настроено!${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} ✅ Оставить текущие правила (рекомендуется)"
        echo ""
        echo -e "  ${WHITE}2)${NC} 🔄 Полная перенастройка"
        echo -e "      ${CYAN}Сбросить всё и настроить с нуля${NC}"
    fi
    
    echo ""
    read -p "  Ваш выбор [1]: " fw_choice
    fw_choice=${fw_choice:-1}
    
    # Сохраняем флаги для использования в apply_protection
    export PORT22_OPEN="$port22_open"
    export SSH_OPEN_ALL="$ssh_open_all"
    
    # Преобразуем выбор в FIREWALL_MODE
    if [[ "$issues_found" == true ]]; then
        case "$fw_choice" in
            1)
                # Исправить проблемы
                FIREWALL_MODE="fix_issues"
                ;;
            2)
                # Оставить как есть
                FIREWALL_MODE="keep"
                ;;
            3)
                # Полная перенастройка
                FIREWALL_MODE="reset"
                ;;
            *)
                FIREWALL_MODE="fix_issues"
                ;;
        esac
    else
        case "$fw_choice" in
            1)
                # Оставить как есть
                FIREWALL_MODE="keep"
                ;;
            2)
                # Полная перенастройка
                FIREWALL_MODE="reset"
                ;;
            *)
                FIREWALL_MODE="keep"
                ;;
        esac
    fi
    
    export FIREWALL_MODE
}

# =====================================================
# СБОР НАСТРОЕК
# =====================================================

collect_settings() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}НАСТРОЙКА ЗАЩИТЫ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    
    # 0. Проверяем текущие правила UFW
    check_existing_firewall
    
    # 1. Роль сервера
    echo ""
    echo -e "${WHITE}1. Какую роль выполняет этот сервер?${NC}"
    echo "   1) 🧠 БАЗА (Панель управления / Бот)"
    echo "   2) 🚀 НОДА (VPN сервер)"
    read -p "   Ваш выбор (1 или 2): " SERVER_TYPE
    SERVER_TYPE=${SERVER_TYPE:-1}
    
    # 2. IP админа
    echo ""
    echo -e "${WHITE}2. IP адрес администратора (для SSH доступа)${NC}"
    echo ""
    echo -e "   ${YELLOW}⚠️  ВНИМАНИЕ: Если вы укажете IP — только с него${NC}"
    echo -e "   ${YELLOW}   можно будет подключиться по SSH!${NC}"
    echo ""
    echo -e "   Ваш текущий IP: ${CYAN}$(curl -s ifconfig.me 2>/dev/null || echo 'не определён')${NC}"
    echo -e "   Узнать IP: https://2ip.ru"
    echo ""
    echo -e "   Нажмите ${WHITE}Enter${NC} чтобы пропустить (настроите позже через меню)"
    read -p "   IP админа: " ADMIN_IP
    
    # 3. IP панели (для нод)
    PANEL_IP=""
    if [[ "$SERVER_TYPE" == "2" ]]; then
        echo ""
        echo -e "${WHITE}3. IP адрес Панели управления${NC}"
        echo -e "   Панель получит полный доступ к этой ноде."
        echo -e "   Нажмите ${WHITE}Enter${NC} чтобы пропустить"
        read -p "   IP Панели: " PANEL_IP
    fi
    
    # 4. SSH порт
    # Определяем текущий порт из sshd_config
    local current_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    current_ssh_port=${current_ssh_port:-22}
    
    echo ""
    echo -e "${WHITE}4. Порт SSH${NC} (текущий: ${CYAN}$current_ssh_port${NC})"
    echo -e "   ${YELLOW}⚠️  Порт 2222 занят панелью для связи с нодами!${NC}"
    echo -e "   Рекомендуется: 22222, 54321, 33322 и т.п."
    echo -e "   Нажмите ${WHITE}Enter${NC} чтобы оставить ${CYAN}$current_ssh_port${NC}"
    read -p "   SSH порт: " SSH_PORT
    SSH_PORT=${SSH_PORT:-$current_ssh_port}
    
    # 5. Доп. VPN порты (для нод)
    EXTRA_PORTS=""
    if [[ "$SERVER_TYPE" == "2" ]]; then
        echo ""
        echo -e "${WHITE}5. Дополнительные VPN порты${NC}"
        echo -e "   Порт 443 откроется автоматически."
        echo -e "   Введите доп. порты через пробел (напр. 8443 9443)"
        echo -e "   Нажмите ${WHITE}Enter${NC} чтобы пропустить"
        read -p "   Доп. порты: " EXTRA_PORTS
    fi
    
    # 6. Telegram
    echo ""
    echo -e "${WHITE}6. Telegram уведомления${NC}"
    echo -e "   Получите токен у @BotFather"
    echo -e "   Нажмите ${WHITE}Enter${NC} чтобы пропустить (настроите позже)"
    read -p "   Bot Token: " TG_TOKEN
    
    TG_CHAT_ID=""
    if [[ -n "$TG_TOKEN" ]]; then
        echo -e "   ${WHITE}Как узнать ваш Telegram ID:${NC}"
        echo -e "   1. Откройте @userinfobot или @getmyid_bot в Telegram"
        echo -e "   2. Нажмите /start"
        echo -e "   3. Скопируйте ваш ID (просто число, напр. ${CYAN}123456789${NC})"
        echo ""
        echo -e "   ${CYAN}💡 Один токен и ID можно использовать на всех серверах!${NC}"
        echo ""
        read -p "   ID администратора: " TG_CHAT_ID
    fi
}

# =====================================================
# УСТАНОВКА
# =====================================================

install_packages() {
    log_step "Установка необходимых пакетов..."
    
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y
    
    for pkg in ufw fail2ban chrony rkhunter unattended-upgrades apt-listchanges curl; do
        echo -e "   Установка: $pkg"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" > /dev/null 2>&1 || true
    done
    
    log_info "Пакеты установлены"
}

download_shield_files() {
    log_step "Скачивание Server Shield..."
    
    mkdir -p "$SHIELD_DIR"/{modules,backups,config,logs}
    
    local modules=(
        "utils.sh"
        "ssh.sh"
        "keys.sh"
        "firewall.sh"
        "kernel.sh"
        "fail2ban.sh"
        "telegram.sh"
        "rkhunter.sh"
        "backup.sh"
        "status.sh"
        "menu.sh"
    )
    
    for module in "${modules[@]}"; do
        echo -e "   Скачивание: $module"
        if ! curl -fsSL "$GITHUB_RAW/modules/$module" -o "$SHIELD_DIR/modules/$module" 2>/dev/null; then
            log_error "Не удалось скачать $module"
            exit 1
        fi
    done
    
    echo -e "   Скачивание: shield.sh"
    curl -fsSL "$GITHUB_RAW/shield.sh" -o "$SHIELD_DIR/shield.sh" 2>/dev/null || true
    
    echo -e "   Скачивание: uninstall.sh"
    curl -fsSL "$GITHUB_RAW/uninstall.sh" -o "$SHIELD_DIR/uninstall.sh" 2>/dev/null || true
    
    chmod +x "$SHIELD_DIR"/*.sh 2>/dev/null || true
    chmod +x "$SHIELD_DIR/modules/"*.sh 2>/dev/null || true
    
    ln -sf "$SHIELD_DIR/shield.sh" /usr/local/bin/shield
    
    log_info "Server Shield установлен в $SHIELD_DIR"
}

apply_protection() {
    log_step "Применение защиты..."
    
    source "$SHIELD_DIR/modules/utils.sh"
    source "$SHIELD_DIR/modules/ssh.sh"
    source "$SHIELD_DIR/modules/firewall.sh"
    source "$SHIELD_DIR/modules/kernel.sh"
    source "$SHIELD_DIR/modules/fail2ban.sh"
    source "$SHIELD_DIR/modules/telegram.sh"
    source "$SHIELD_DIR/modules/rkhunter.sh"
    source "$SHIELD_DIR/modules/backup.sh"
    
    init_directories
    
    echo -e "   Настройка SSH..."
    harden_ssh "$SSH_PORT"
    
    echo -e "   Настройка Firewall..."
    # Учитываем выбор пользователя по firewall
    case "${FIREWALL_MODE}" in
        "reset")
            # Полный сброс и надёжные правила
            log_step "Полная перенастройка firewall..."
            if [[ "$SERVER_TYPE" == "1" ]]; then
                setup_firewall_panel "$ADMIN_IP" "$SSH_PORT" "true"
            else
                setup_firewall_node "$ADMIN_IP" "$PANEL_IP" "$SSH_PORT" "$EXTRA_PORTS" "true"
            fi
            ;;
        "fix_issues")
            # Исправить найденные проблемы
            log_step "Исправление проблем безопасности..."
            
            # Отключаем IPv6 в UFW
            if [[ -f "/etc/default/ufw" ]] && grep -q "^IPV6=yes" "/etc/default/ufw"; then
                sed -i 's/^IPV6=yes/IPV6=no/' "/etc/default/ufw"
            fi
            
            # 1. Закрываем порт 22 если SSH на другом порту
            if [[ "${PORT22_OPEN}" == "true" ]] && [[ "$SSH_PORT" != "22" ]]; then
                log_step "Закрываем неиспользуемый порт 22..."
                ufw delete allow 22/tcp 2>/dev/null
                ufw delete allow 22 2>/dev/null
                # Удаляем все правила с портом 22
                while ufw status numbered | grep -q " 22[^0-9]"; do
                    local rule_num=$(ufw status numbered | grep " 22[^0-9]" | head -1 | grep -oP '^\[\s*\K\d+')
                    [[ -n "$rule_num" ]] && echo "y" | ufw delete "$rule_num" 2>/dev/null || break
                done
                log_info "Порт 22 закрыт"
            fi
            
            # 2. Ограничиваем SSH по IP если открыт для всех
            if [[ "${SSH_OPEN_ALL}" == "true" ]]; then
                log_step "Ограничение SSH доступа..."
                
                # Удаляем текущие правила SSH (открытые для всех)
                ufw delete allow ${SSH_PORT}/tcp 2>/dev/null
                ufw delete allow ${SSH_PORT} 2>/dev/null
                
                # Для ноды: SSH доступ для админа И панели
                if [[ "$SERVER_TYPE" == "2" ]]; then
                    if [[ -n "$ADMIN_IP" ]]; then
                        ufw allow from "$ADMIN_IP" to any port "$SSH_PORT" proto tcp comment 'Admin SSH'
                        log_info "SSH доступ для админа: $ADMIN_IP"
                    fi
                    if [[ -n "$PANEL_IP" ]]; then
                        # Панель получает полный доступ (включая SSH)
                        if ! ufw status | grep -q "$PANEL_IP"; then
                            ufw allow from "$PANEL_IP" comment 'Panel Full Access'
                            log_info "Полный доступ для панели: $PANEL_IP"
                        fi
                    fi
                    # Если ни админ, ни панель не указаны — предупреждаем но открываем
                    if [[ -z "$ADMIN_IP" ]] && [[ -z "$PANEL_IP" ]]; then
                        ufw allow "$SSH_PORT"/tcp comment 'SSH'
                        log_warn "SSH оставлен открытым (не указан IP админа/панели)"
                    fi
                else
                    # Для панели: SSH только для админа
                    if [[ -n "$ADMIN_IP" ]]; then
                        ufw allow from "$ADMIN_IP" to any port "$SSH_PORT" proto tcp comment 'Admin SSH'
                        log_info "SSH доступ для админа: $ADMIN_IP"
                    else
                        ufw allow "$SSH_PORT"/tcp comment 'SSH'
                        log_warn "SSH оставлен открытым (не указан IP админа)"
                    fi
                fi
            fi
            
            # Для ноды: убеждаемся что панель имеет доступ
            if [[ "$SERVER_TYPE" == "2" ]] && [[ -n "$PANEL_IP" ]]; then
                if ! ufw status | grep -q "$PANEL_IP"; then
                    log_step "Добавляем доступ для панели $PANEL_IP..."
                    ufw allow from "$PANEL_IP" comment 'Panel Full Access'
                fi
            fi
            
            ufw --force reload 2>/dev/null
            log_info "Проблемы безопасности исправлены"
            ;;
        "keep"|*)
            # Оставить как есть
            log_info "Firewall оставлен без изменений"
            
            # Отключаем IPv6 в UFW (это безопасно)
            if [[ -f "/etc/default/ufw" ]] && grep -q "^IPV6=yes" "/etc/default/ufw"; then
                sed -i 's/^IPV6=yes/IPV6=no/' "/etc/default/ufw"
            fi
            
            # Только убедимся что SSH порт открыт
            if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
                if ! ufw status | grep -q "$SSH_PORT"; then
                    log_warn "Открываем SSH порт $SSH_PORT..."
                    ufw allow "$SSH_PORT"/tcp comment 'SSH'
                fi
            fi
            ;;
    esac
    
    # КРИТИЧНО: Для ноды ВСЕГДА проверяем доступ панели
    if [[ "$SERVER_TYPE" == "2" ]] && [[ -n "$PANEL_IP" ]]; then
        if ! ufw status | grep -q "$PANEL_IP"; then
            log_step "Добавляем доступ для панели $PANEL_IP..."
            ufw allow from "$PANEL_IP" comment 'Panel Full Access'
            log_info "Панель $PANEL_IP получила полный доступ"
        else
            log_info "Доступ для панели $PANEL_IP уже настроен"
        fi
    fi
    
    # Перезагружаем UFW после всех изменений
    ufw --force reload 2>/dev/null
    
    echo -e "   Настройка Kernel Hardening..."
    apply_kernel_hardening
    
    echo -e "   Настройка Fail2Ban..."
    # Передаём IP админа для whitelist (5-й параметр)
    setup_fail2ban "$SSH_PORT" "$TG_TOKEN" "$TG_CHAT_ID" "86400" "$ADMIN_IP"
    
    if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        echo -e "   Настройка Telegram..."
        save_config "TG_TOKEN" "$TG_TOKEN"
        save_config "TG_CHAT_ID" "$TG_CHAT_ID"
        setup_ssh_login_notify
    fi
    
    echo -e "   Настройка Rootkit Hunter..."
    setup_rkhunter
    
    echo -e "   Настройка Auto Updates..."
    echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
    
    timedatectl set-ntp true 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true
    
    echo -e "   Создание бэкапа..."
    create_full_backup
    
    log_info "Защита применена"
}

show_result() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         🎉 СЕРВЕР ЗАЩИЩЁН! 🎉                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}Итоги:${NC}"
    echo -e "    ✅ SSH Hardening (порт: ${CYAN}$SSH_PORT${NC})"
    echo -e "    ✅ Kernel Hardening (anti-DDoS)"
    echo -e "    ✅ UFW Firewall"
    echo -e "    ✅ Fail2Ban"
    
    if [[ -n "$TG_TOKEN" ]]; then
        echo -e "    ✅ Telegram уведомления"
    else
        echo -e "    ⚠️  Telegram (настройте позже: ${CYAN}shield telegram${NC})"
    fi
    
    echo -e "    ✅ Rootkit сканирование"
    echo -e "    ✅ Auto Updates"
    echo -e "    ✅ Бэкап создан"
    echo ""
    
    if [[ -n "$ADMIN_IP" ]]; then
        echo -e "  ${WHITE}SSH доступ:${NC} Только с IP ${CYAN}$ADMIN_IP${NC}"
    else
        echo -e "  ${YELLOW}SSH доступ:${NC} С любого IP (рекомендуется ограничить)"
    fi
    
    echo -e "  ${WHITE}Вход по паролям:${NC} ${RED}ОТКЛЮЧЁН${NC}"
    echo ""
    echo -e "  ${WHITE}Управление:${NC} ${CYAN}shield${NC} или ${CYAN}shield help${NC}"
    echo ""
    
    if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        source "$SHIELD_DIR/modules/telegram.sh"
        send_install_complete
    fi
}

# =====================================================
# MAIN
# =====================================================

main() {
    print_header
    check_root
    check_ssh_keys
    collect_settings
    
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}УСТАНОВКА${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
    
    install_packages
    download_shield_files
    apply_protection
    show_result
}

main "$@"
