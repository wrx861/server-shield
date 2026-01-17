#!/bin/bash
#
# menu.sh - Главное меню управления
# Premium UI v3.0
#

# Определяем директорию
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключаем модули
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/ssh.sh" 2>/dev/null || true
source "$SCRIPT_DIR/keys.sh" 2>/dev/null || true
source "$SCRIPT_DIR/firewall.sh" 2>/dev/null || true
source "$SCRIPT_DIR/kernel.sh" 2>/dev/null || true
source "$SCRIPT_DIR/fail2ban.sh" 2>/dev/null || true
source "$SCRIPT_DIR/telegram.sh" 2>/dev/null || true
source "$SCRIPT_DIR/rkhunter.sh" 2>/dev/null || true
source "$SCRIPT_DIR/backup.sh" 2>/dev/null || true
source "$SCRIPT_DIR/status.sh" 2>/dev/null || true
source "$SCRIPT_DIR/updater.sh" 2>/dev/null || true
source "$SCRIPT_DIR/traffic.sh" 2>/dev/null || true
source "$SCRIPT_DIR/monitor.sh" 2>/dev/null || true
source "$SCRIPT_DIR/l7shield.sh" 2>/dev/null || true

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================

main_menu() {
    while true; do
        print_header
        print_status_cards
        print_services_status
        
        echo -e "    ${WHITE}ЗАЩИТА${NC}                        ${WHITE}УТИЛИТЫ${NC}"
        echo ""
        echo -e "    ${CYAN}[1]${NC} Firewall (UFW)          ${CYAN}[7]${NC} Telegram"
        echo -e "    ${CYAN}[2]${NC} Fail2Ban                ${CYAN}[8]${NC} Бэкапы"
        echo -e "    ${CYAN}[3]${NC} DDoS Protection         ${CYAN}[9]${NC} Логи"
        echo -e "    ${CYAN}[4]${NC} SSH Security            ${CYAN}[m]${NC} Мониторинг"
        echo -e "    ${CYAN}[5]${NC} SSH Ключи               ${CYAN}[s]${NC} Полный статус"
        echo -e "    ${CYAN}[6]${NC} Traffic Control"
        
        menu_divider
        
        # Дополнительные инструменты
        menu_item "k" "Rootkit Scanner"
        echo ""
        
        # Обновления
        local update_available=""
        if type check_updates &>/dev/null; then
            local update_status=$(check_updates 2>/dev/null)
            if [[ "$update_status" == available:* ]]; then
                update_available="${update_status#available:}"
                echo -e "    ${GREEN}[u]${NC} ${GREEN}Обновить до $update_available${NC}"
            else
                menu_item_dim "u" "Проверить обновления"
            fi
        else
            menu_item_dim "u" "Проверить обновления"
        fi
        
        echo ""
        echo -e "    ${DIM}[r]${NC} Перенастроить           ${DIM}[0]${NC} Выход"
        
        echo ""
        print_divider
        echo -e "    ${DIM}[?] help${NC}"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in  # ${choice,,} = lowercase
            1) _safe_call firewall_menu ;;
            2) _safe_call fail2ban_menu ;;
            3) _safe_call l7_menu "DDoS Protection" ;;
            4) ssh_menu ;;
            5) _safe_call keys_menu ;;
            6) _safe_call traffic_menu "Traffic Control" ;;
            7) _safe_call telegram_menu ;;
            8) _safe_call backup_menu ;;
            9) logs_menu ;;
            m) _safe_call monitor_menu "Мониторинг" ;;
            k) _safe_call rkhunter_menu "Rootkit Scanner" ;;
            s) 
                _safe_call show_full_status
                press_any_key
                ;;
            u) _safe_call update_menu ;;
            r) reconfigure_menu ;;
            q|0|exit) 
                _exit_app
                ;;
            '?'|h|help)
                show_help_menu
                press_any_key
                ;;
            '')
                # Пустой ввод - просто обновляем экран
                ;;
            *)
                # Неверный ввод - показываем ошибку но не выходим
                ;;
        esac
    done
}

# Безопасный вызов функции (если не существует - показать ошибку)
_safe_call() {
    local func="$1"
    local name="${2:-$func}"
    
    if type "$func" &>/dev/null; then
        "$func"
    else
        print_header_mini "$name"
        echo ""
        log_error "Модуль не загружен"
        echo ""
        echo -e "    ${DIM}Функция $func недоступна${NC}"
        press_any_key
    fi
}

# Выход из приложения
_exit_app() {
    echo ""
    echo -e "    ${GREEN}✓${NC} До свидания!"
    echo ""
    exit 0
}

# ============================================
# МЕНЮ СПРАВКИ
# ============================================

show_help_menu() {
    print_header_mini "Справка"
    
    echo -e "    ${WHITE}НАВИГАЦИЯ${NC}"
    echo ""
    echo -e "    ${CYAN}0-9${NC}     Выбор пункта меню"
    echo -e "    ${CYAN}0, q${NC}    Выход / Назад"
    echo -e "    ${CYAN}Enter${NC}   Обновить экран"
    echo ""
    echo -e "    ${WHITE}БЫСТРЫЕ КОМАНДЫ${NC}"
    echo ""
    echo -e "    ${CYAN}u${NC}       Проверить обновления"
    echo -e "    ${CYAN}r${NC}       Перенастроить"
    echo -e "    ${CYAN}s${NC}       Полный статус"
    echo -e "    ${CYAN}?${NC}       Эта справка"
    echo ""
    echo -e "    ${WHITE}CLI КОМАНДЫ${NC}"
    echo ""
    echo -e "    ${CYAN}shield${NC}              Открыть меню"
    echo -e "    ${CYAN}shield status${NC}       Показать статус"
    echo -e "    ${CYAN}shield l7 enable${NC}    Включить DDoS защиту"
    echo -e "    ${CYAN}shield l7 status${NC}    Статус DDoS защиты"
    echo -e "    ${CYAN}shield help${NC}         Полная справка CLI"
    echo ""
}

# ============================================
# МЕНЮ SSH
# ============================================

ssh_menu() {
    while true; do
        print_header_mini "SSH Security"
        
        # Показываем текущий статус
        local ssh_port=$(get_ssh_port 2>/dev/null || echo "22")
        local ssh_status=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo "unknown")
        
        echo -e "    ${DIM}┌─────────────────────────────────────────────────┐${NC}"
        echo -e "    ${DIM}│${NC} Порт: ${CYAN}$ssh_port${NC}              Статус: $([ "$ssh_status" = "active" ] && echo "${GREEN}● Active${NC}" || echo "${RED}○ Inactive${NC}") ${DIM}│${NC}"
        echo -e "    ${DIM}└─────────────────────────────────────────────────┘${NC}"
        echo ""
        
        menu_item "1" "Изменить порт SSH"
        menu_item "2" "Перезапустить SSH"
        menu_item "3" "Показать конфиг"
        menu_item "4" "Статус подключений"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                _change_ssh_port_wizard
                ;;
            2)
                log_step "Перезапуск SSH..."
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                log_info "SSH перезапущен"
                press_any_key
                ;;
            3)
                echo ""
                if [[ -f /etc/ssh/sshd_config ]]; then
                    grep -v "^#" /etc/ssh/sshd_config | grep -v "^$" | head -30
                fi
                press_any_key
                ;;
            4)
                echo ""
                echo -e "    ${WHITE}Активные SSH соединения:${NC}"
                echo ""
                who 2>/dev/null || echo "    Нет данных"
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# Мастер смены порта SSH
_change_ssh_port_wizard() {
    local current_port=$(get_ssh_port 2>/dev/null || echo "22")
    
    echo ""
    echo -e "    ${WHITE}Смена порта SSH${NC}"
    echo ""
    echo -e "    Текущий порт: ${CYAN}$current_port${NC}"
    echo ""
    echo -e "    ${YELLOW}⚠ ВАЖНО:${NC}"
    echo -e "    ${DIM}• Не закрывайте текущую SSH сессию!${NC}"
    echo -e "    ${DIM}• После смены проверьте подключение в НОВОМ окне${NC}"
    echo -e "    ${DIM}• Рекомендуемые порты: 22222, 33322, 54321${NC}"
    echo ""
    
    local new_port
    input_value "Новый порт" "" new_port
    
    if [[ -z "$new_port" ]]; then
        log_info "Отмена"
        return
    fi
    
    if ! validate_port "$new_port"; then
        log_error "Неверный порт: $new_port"
        press_any_key
        return
    fi
    
    if [[ "$new_port" == "$current_port" ]]; then
        log_warn "Порт не изменился"
        press_any_key
        return
    fi
    
    if confirm_action "Изменить порт SSH на $new_port?" "n"; then
        if type change_ssh_port &>/dev/null; then
            change_ssh_port "$new_port"
        else
            # Fallback
            sed -i "s/^#*Port .*/Port $new_port/" /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh
            
            # UFW
            if command -v ufw &>/dev/null; then
                ufw allow "$new_port/tcp" comment "SSH" 2>/dev/null
                [[ "$current_port" != "22" ]] && ufw delete allow "$current_port/tcp" 2>/dev/null
            fi
        fi
        
        log_info "Порт изменён на $new_port"
        echo ""
        echo -e "    ${YELLOW}Проверьте подключение в НОВОМ окне:${NC}"
        echo -e "    ${CYAN}ssh -p $new_port root@$(get_external_ip 2>/dev/null || echo 'your-ip')${NC}"
    fi
    
    press_any_key
}

# ============================================
# МЕНЮ ЛОГОВ
# ============================================

logs_menu() {
    while true; do
        print_header_mini "Логи"
        
        menu_item "1" "Авторизация (auth.log)"
        menu_item "2" "Fail2Ban"
        menu_item "3" "Firewall (UFW)"
        menu_item "4" "Rootkit Hunter"
        menu_item "5" "DDoS Protection"
        menu_divider
        menu_item "6" "Последние входы"
        menu_item "7" "Неудачные попытки"
        menu_divider
        menu_item "0" "Назад"
        
        local choice=$(read_choice)
        
        case "${choice,,}" in
            1)
                echo ""
                _show_log "/var/log/auth.log" "journalctl -u ssh -n 50"
                ;;
            2)
                echo ""
                _show_log "/var/log/fail2ban.log"
                ;;
            3)
                echo ""
                _show_log "/var/log/ufw.log"
                ;;
            4)
                echo ""
                _show_log "/var/log/rkhunter.log"
                ;;
            5)
                echo ""
                local l7_log="/opt/server-shield/logs/l7shield/bans.log"
                _show_log "$l7_log"
                ;;
            6)
                echo ""
                echo -e "    ${WHITE}Последние входы:${NC}"
                echo ""
                last -15 2>/dev/null || echo "    Нет данных"
                press_any_key
                ;;
            7)
                echo ""
                echo -e "    ${WHITE}Неудачные попытки входа:${NC}"
                echo ""
                if [[ -f /var/log/auth.log ]]; then
                    grep -i "failed\|invalid" /var/log/auth.log 2>/dev/null | tail -20
                else
                    journalctl -u ssh 2>/dev/null | grep -i "failed\|invalid" | tail -20
                fi
                press_any_key
                ;;
            0|q) return ;;
        esac
    done
}

# Показать лог файл
_show_log() {
    local file="$1"
    local fallback="$2"
    
    if [[ -f "$file" ]]; then
        tail -50 "$file" 2>/dev/null | less
    elif [[ -n "$fallback" ]]; then
        eval "$fallback" 2>/dev/null | less
    else
        log_warn "Лог не найден: $file"
        press_any_key
    fi
}

# ============================================
# МЕНЮ ПЕРЕНАСТРОЙКИ
# ============================================

reconfigure_menu() {
    print_header_mini "Перенастройка"
    
    echo -e "    ${WHITE}Это запустит мастер настройки заново.${NC}"
    echo ""
    echo -e "    Вы сможете изменить:"
    echo -e "    ${DIM}• Роль сервера (Панель/Нода)${NC}"
    echo -e "    ${DIM}• IP администратора${NC}"
    echo -e "    ${DIM}• SSH порт${NC}"
    echo -e "    ${DIM}• Правила Firewall${NC}"
    echo -e "    ${DIM}• Telegram уведомления${NC}"
    echo ""
    echo -e "    ${YELLOW}⚠ Текущие настройки будут перезаписаны!${NC}"
    
    if ! confirm_action "Запустить перенастройку?" "n"; then
        return
    fi
    
    local install_script="/opt/server-shield/install.sh"
    
    if [[ -f "$install_script" ]]; then
        bash "$install_script" --reconfigure
    else
        log_step "Загрузка установщика..."
        bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh) --reconfigure
    fi
    
    press_any_key
}

# ============================================
# ПРОСТОЕ ОБНОВЛЕНИЕ (fallback)
# ============================================

_do_simple_update() {
    print_header_mini "Обновление"
    
    local local_ver=$(_get_version 2>/dev/null || echo "unknown")
    show_info "Текущая версия" "$local_ver"
    
    log_step "Проверка обновлений..."
    
    local remote_ver=$(curl -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/wrx861/server-shield/main/VERSION" 2>/dev/null | tr -d '[:space:]')
    
    if [[ -z "$remote_ver" ]]; then
        log_error "Не удалось проверить обновления"
        press_any_key
        return
    fi
    
    show_info "Последняя версия" "$remote_ver"
    echo ""
    
    if [[ "$local_ver" == "$remote_ver" ]]; then
        log_info "У вас последняя версия!"
        press_any_key
        return
    fi
    
    if confirm_action "Обновить до $remote_ver?" "y"; then
        log_step "Скачивание обновлений..."
        
        local GITHUB_RAW="https://raw.githubusercontent.com/wrx861/server-shield/main"
        local SHIELD_DIR="/opt/server-shield"
        
        local modules=("utils.sh" "ssh.sh" "keys.sh" "firewall.sh" "kernel.sh" "fail2ban.sh" "telegram.sh" "rkhunter.sh" "backup.sh" "status.sh" "menu.sh" "updater.sh" "l7shield.sh")
        
        for module in "${modules[@]}"; do
            curl -fsSL "$GITHUB_RAW/modules/$module" -o "$SHIELD_DIR/modules/$module" 2>/dev/null
        done
        
        curl -fsSL "$GITHUB_RAW/shield.sh" -o "$SHIELD_DIR/shield.sh" 2>/dev/null
        curl -fsSL "$GITHUB_RAW/VERSION" -o "$SHIELD_DIR/VERSION" 2>/dev/null
        
        chmod +x "$SHIELD_DIR"/*.sh "$SHIELD_DIR/modules/"*.sh 2>/dev/null
        
        log_info "Обновление завершено!"
        echo ""
        echo -e "    ${YELLOW}Перезапустите shield:${NC} ${CYAN}shield${NC}"
    fi
    
    press_any_key
}

# ============================================
# ЗАПУСК
# ============================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root
    init_directories
    main_menu
fi
