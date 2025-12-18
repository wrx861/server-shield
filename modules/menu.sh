#!/bin/bash
#
# menu.sh - Главное меню управления
#

# Определяем директорию
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключаем модули
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/ssh.sh"
source "$SCRIPT_DIR/keys.sh"
source "$SCRIPT_DIR/firewall.sh"
source "$SCRIPT_DIR/kernel.sh"
source "$SCRIPT_DIR/fail2ban.sh"
source "$SCRIPT_DIR/telegram.sh"
source "$SCRIPT_DIR/rkhunter.sh"
source "$SCRIPT_DIR/backup.sh"
source "$SCRIPT_DIR/status.sh"
source "$SCRIPT_DIR/updater.sh"

# Получить локальную версию (fallback если updater.sh не загружен)
_get_local_version() {
    if [[ -f "/opt/server-shield/VERSION" ]]; then
        cat "/opt/server-shield/VERSION" | tr -d '[:space:]'
    else
        echo "2.1.0"
    fi
}

# Показать статус версии (fallback)
_show_version_info() {
    local local_ver=$(_get_local_version)
    
    # Пробуем использовать функцию из updater.sh
    if type check_updates &>/dev/null; then
        local status=$(check_updates 2>/dev/null)
        echo -ne "  ${WHITE}Версия:${NC} ${CYAN}$local_ver${NC}"
        case "$status" in
            "latest")
                echo -e " ${GREEN}✓ актуальная${NC}"
                ;;
            available:*)
                local new_ver="${status#available:}"
                echo -e " ${YELLOW}⬆ доступно обновление $new_ver${NC}"
                ;;
            *)
                echo ""
                ;;
        esac
    else
        echo -e "  ${WHITE}Версия:${NC} ${CYAN}$local_ver${NC}"
    fi
}

# Главное меню с версией
main_menu() {
    while true; do
        print_header
        
        # Показываем версию и статус обновлений
        _show_version_info
        
        show_quick_status
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${WHITE}Главное меню${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC}  📊  Статус защиты"
        echo -e "  ${WHITE}2)${NC}  🔑  Управление SSH-ключами"
        echo -e "  ${WHITE}3)${NC}  🔒  Настройки SSH"
        echo -e "  ${WHITE}4)${NC}  🔥  Firewall (UFW)"
        echo -e "  ${WHITE}5)${NC}  🤖  Fail2Ban"
        echo -e "  ${WHITE}6)${NC}  📱  Telegram уведомления"
        echo -e "  ${WHITE}7)${NC}  🔍  Rootkit сканирование"
        echo -e "  ${WHITE}8)${NC}  💾  Бэкап и восстановление"
        echo -e "  ${WHITE}9)${NC}  📝  Просмотр логов"
        echo ""
        echo -e "  ${WHITE}r)${NC}  🔄  ${YELLOW}Перенастроить защиту${NC}"
        
        # Проверяем наличие обновлений
        echo ""
        if type check_updates &>/dev/null; then
            local update_status=$(check_updates 2>/dev/null)
            if [[ "$update_status" == available:* ]]; then
                local new_ver="${update_status#available:}"
                echo -e "  ${WHITE}u)${NC}  ${GREEN}⬆️  Обновить до $new_ver${NC}"
            else
                echo -e "  ${WHITE}u)${NC}  ⬆️  Проверить обновления"
            fi
        else
            echo -e "  ${WHITE}u)${NC}  ⬆️  Проверить обновления"
        fi
        
        echo ""
        echo -e "  ${WHITE}0)${NC}  🚪  Выход"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) 
                show_full_status
                press_any_key
                ;;
            2) keys_menu ;;
            3) ssh_menu ;;
            4) firewall_menu ;;
            5) fail2ban_menu ;;
            6) telegram_menu ;;
            7) rkhunter_menu ;;
            8) backup_menu ;;
            9) logs_menu ;;
            u|U) 
                if type update_menu &>/dev/null; then
                    update_menu
                else
                    _do_simple_update
                fi
                ;;
            r|R)
                reconfigure_protection
                ;;
            0) 
                echo ""
                log_info "До свидания! 🛡️"
                exit 0
                ;;
            *) log_error "Неверный выбор" ;;
        esac
    done
}

# Перенастройка защиты (повторный запуск мастера установки)
reconfigure_protection() {
    print_header
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}🔄 ПЕРЕНАСТРОЙКА ЗАЩИТЫ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Это запустит мастер настройки заново."
    echo -e "  Вы сможете изменить:"
    echo ""
    echo -e "    • Роль сервера (Панель/Нода)"
    echo -e "    • IP администратора"
    echo -e "    • IP панели (для нод)"
    echo -e "    • SSH порт"
    echo -e "    • Правила Firewall"
    echo -e "    • Telegram уведомления"
    echo ""
    echo -e "  ${YELLOW}⚠️  Текущие настройки будут перезаписаны!${NC}"
    echo ""
    
    if ! confirm "Запустить перенастройку?" "n"; then
        log_info "Отмена"
        press_any_key
        return
    fi
    
    # Проверяем наличие install.sh
    local install_script="/opt/server-shield/install.sh"
    
    if [[ -f "$install_script" ]]; then
        # Запускаем установщик в режиме перенастройки
        bash "$install_script" --reconfigure
    else
        # Если нет локально - качаем и запускаем
        log_step "Загрузка установщика..."
        bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh) --reconfigure
    fi
    
    press_any_key
}

# Простое обновление (fallback если updater.sh не загружен)
_do_simple_update() {
    print_header
    print_section "⬆️ Обновление Server Shield"
    
    local local_ver=$(_get_local_version)
    echo ""
    echo -e "  Текущая версия: ${CYAN}$local_ver${NC}"
    echo ""
    
    log_step "Проверка обновлений..."
    
    local remote_ver=$(curl -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/wrx861/server-shield/main/VERSION" 2>/dev/null | tr -d '[:space:]')
    
    if [[ -z "$remote_ver" ]]; then
        log_error "Не удалось проверить обновления. Проверьте интернет."
        press_any_key
        return
    fi
    
    echo -e "  Последняя версия: ${GREEN}$remote_ver${NC}"
    echo ""
    
    if [[ "$local_ver" == "$remote_ver" ]]; then
        log_info "У вас установлена последняя версия!"
        press_any_key
        return
    fi
    
    log_info "Доступно обновление: $remote_ver"
    echo ""
    
    if confirm "Обновить сейчас?" "y"; then
        log_step "Скачивание обновлений..."
        
        local GITHUB_RAW="https://raw.githubusercontent.com/wrx861/server-shield/main"
        local SHIELD_DIR="/opt/server-shield"
        
        # Скачиваем модули
        local modules=("utils.sh" "ssh.sh" "keys.sh" "firewall.sh" "kernel.sh" "fail2ban.sh" "telegram.sh" "rkhunter.sh" "backup.sh" "status.sh" "menu.sh" "updater.sh")
        
        for module in "${modules[@]}"; do
            echo -e "   Обновление: $module"
            curl -fsSL "$GITHUB_RAW/modules/$module" -o "$SHIELD_DIR/modules/$module" 2>/dev/null
        done
        
        # Скачиваем основные файлы
        echo -e "   Обновление: shield.sh"
        curl -fsSL "$GITHUB_RAW/shield.sh" -o "$SHIELD_DIR/shield.sh" 2>/dev/null
        
        echo -e "   Обновление: VERSION"
        curl -fsSL "$GITHUB_RAW/VERSION" -o "$SHIELD_DIR/VERSION" 2>/dev/null
        
        # Делаем исполняемыми
        chmod +x "$SHIELD_DIR"/*.sh 2>/dev/null
        chmod +x "$SHIELD_DIR/modules/"*.sh 2>/dev/null
        
        echo ""
        log_info "Обновление завершено!"
        echo -e "  ${YELLOW}Перезапустите shield для применения:${NC} ${CYAN}shield${NC}"
    fi
    
    press_any_key
}

# Меню SSH
ssh_menu() {
    while true; do
        print_header
        print_section "🔒 Настройки SSH"
        
        check_ssh_status
        
        echo ""
        echo -e "  ${WHITE}1)${NC} Изменить порт SSH"
        echo -e "  ${WHITE}2)${NC} Перезапустить SSH"
        echo -e "  ${WHITE}3)${NC} Показать конфиг SSH"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                echo ""
                local current_port=$(get_ssh_port)
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "  ${WHITE}Смена порта SSH${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo -e "  Текущий порт: ${CYAN}$current_port${NC}"
                echo ""
                echo -e "  ${YELLOW}⚠️  ВАЖНО:${NC}"
                echo -e "  • Не закрывайте текущую SSH сессию до проверки!"
                echo -e "  • После смены откройте НОВОЕ окно и проверьте подключение"
                echo -e "  • Рекомендуемые порты: 22222, 33322, 54321"
                echo -e "  • Порт 2222 занят для связи панели с нодами!"
                echo ""
                read -p "Новый порт SSH (Enter для отмены): " new_port
                if [[ -n "$new_port" ]]; then
                    change_ssh_port "$new_port"
                else
                    log_info "Отмена"
                fi
                ;;
            2)
                restart_ssh_service
                log_info "SSH перезапущен"
                ;;
            3)
                less /etc/ssh/sshd_config
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Меню логов
logs_menu() {
    while true; do
        print_header
        print_section "📝 Просмотр логов"
        echo ""
        echo -e "  ${WHITE}1)${NC} Логи авторизации (auth.log)"
        echo -e "  ${WHITE}2)${NC} Логи Fail2Ban"
        echo -e "  ${WHITE}3)${NC} Логи UFW"
        echo -e "  ${WHITE}4)${NC} Логи Rootkit Hunter"
        echo -e "  ${WHITE}5)${NC} Последние SSH входы"
        echo -e "  ${WHITE}6)${NC} Неудачные попытки входа"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                echo ""
                if [[ -f /var/log/auth.log ]]; then
                    tail -50 /var/log/auth.log | less
                else
                    journalctl -u ssh --no-pager -n 50
                fi
                ;;
            2)
                echo ""
                if [[ -f /var/log/fail2ban.log ]]; then
                    tail -50 /var/log/fail2ban.log | less
                else
                    log_warn "Лог Fail2Ban не найден"
                fi
                ;;
            3)
                echo ""
                if [[ -f /var/log/ufw.log ]]; then
                    tail -50 /var/log/ufw.log | less
                else
                    log_warn "Лог UFW не найден"
                fi
                ;;
            4)
                echo ""
                if [[ -f /var/log/rkhunter.log ]]; then
                    tail -100 /var/log/rkhunter.log | less
                else
                    log_warn "Лог rkhunter не найден"
                fi
                ;;
            5)
                echo ""
                echo -e "${WHITE}Последние успешные входы:${NC}"
                last -20
                ;;
            6)
                echo ""
                echo -e "${WHITE}Неудачные попытки входа:${NC}"
                if [[ -f /var/log/auth.log ]]; then
                    grep "Failed password" /var/log/auth.log | tail -20
                else
                    journalctl -u ssh --no-pager | grep "Failed password" | tail -20
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Запуск главного меню
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root
    init_directories
    main_menu
fi
