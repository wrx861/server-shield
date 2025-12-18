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
# СБОР НАСТРОЕК
# =====================================================

collect_settings() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}НАСТРОЙКА ЗАЩИТЫ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    
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
    echo ""
    echo -e "${WHITE}4. Новый порт SSH${NC} (текущий: 22)"
    echo -e "   ${YELLOW}⚠️  Порт 2222 занят панелью для связи с нодами!${NC}"
    echo -e "   Рекомендуется: 22222, 54321, 33322 и т.п."
    echo -e "   Нажмите ${WHITE}Enter${NC} чтобы оставить 22"
    read -p "   SSH порт: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    
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
    if [[ "$SERVER_TYPE" == "1" ]]; then
        setup_firewall_panel "$ADMIN_IP" "$SSH_PORT"
    else
        setup_firewall_node "$ADMIN_IP" "$PANEL_IP" "$SSH_PORT" "$EXTRA_PORTS"
    fi
    
    echo -e "   Настройка Kernel Hardening..."
    apply_kernel_hardening
    
    echo -e "   Настройка Fail2Ban..."
    setup_fail2ban "$SSH_PORT" "$TG_TOKEN" "$TG_CHAT_ID"
    
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
