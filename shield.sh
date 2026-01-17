#!/bin/bash
#
# shield.sh - CLI команда управления Server Shield
#

SHIELD_DIR="/opt/server-shield"
MODULES_DIR="$SHIELD_DIR/modules"

# Проверяем установку
if [[ ! -d "$SHIELD_DIR" ]]; then
    echo "Ошибка: Server Shield не установлен"
    echo "Запустите install.sh для установки"
    exit 1
fi

# Подключаем модули
source "$MODULES_DIR/utils.sh"
source "$MODULES_DIR/updater.sh" 2>/dev/null

# Получить версию
get_version() {
    if [[ -f "$SHIELD_DIR/VERSION" ]]; then
        cat "$SHIELD_DIR/VERSION"
    else
        echo "2.0.0"
    fi
}

# Помощь
show_help() {
    local version=$(get_version)
    echo ""
    echo "Server Shield v$version - CLI"
    echo ""
    echo "Использование: shield [команда] [опции]"
    echo ""
    echo "Команды:"
    echo "  (none)          Открыть интерактивное меню"
    echo "  status          Показать статус защиты"
    echo "  version         Показать версию"
    echo "  update          Проверить и установить обновления"
    echo ""
    echo "  keys            Управление SSH-ключами"
    echo "    generate      Создать новую пару ключей"
    echo "    show          Показать публичный ключ"
    echo "    list          Список авторизованных ключей"
    echo "    add           Добавить ключ"
    echo "    remove        Удалить ключ"
    echo ""
    echo "  firewall        Управление фаерволом"
    echo "    allow <ip>    Добавить IP в whitelist"
    echo "    deny <ip>     Удалить IP из whitelist"
    echo "    open <port>   Открыть порт"
    echo "    close <port>  Закрыть порт"
    echo "    rules         Показать правила"
    echo ""
    echo "  ssh             Настройки SSH"
    echo "    port <num>    Изменить порт"
    echo ""
    echo "  l7              L7 Shield (DDoS Protection)"
    echo "    enable        Включить L7 защиту"
    echo "    disable       Выключить L7 защиту"
    echo "    reload        Перезагрузить правила"
    echo "    status        Показать статус"
    echo "    top           Топ атакующих"
    echo ""
    echo "  traffic         Traffic Control (скорость клиентов)"
    echo "    status        Показать статус"
    echo "    add           Добавить лимит для порта"
    echo "    remove        Удалить лимит"
    echo "    restart       Перезапустить"
    echo ""
    echo "  backup          Бэкап/восстановление"
    echo "    create        Создать бэкап"
    echo "    list          Список бэкапов"
    echo "    restore       Восстановить"
    echo ""
    echo "  telegram        Telegram уведомления"
    echo "    test          Отправить тест"
    echo ""
    echo "  scan            Запустить rootkit скан"
    echo "  logs            Просмотр логов"
    echo "  help            Эта справка"
    echo ""
    echo "Примеры:"
    echo "  shield                    # Открыть меню"
    echo "  shield status             # Показать статус"
    echo "  shield update             # Обновить"
    echo "  shield l7 enable          # Включить DDoS защиту"
    echo "  shield l7 top             # Топ атакующих"
    echo "  shield traffic status     # Статус лимитов скорости"
    echo "  shield keys generate      # Создать ключ"
    echo "  shield firewall allow 1.2.3.4  # Добавить IP"
    echo ""
}

# Показать версию
show_version() {
    local version=$(get_version)
    echo ""
    echo "🛡️ Server Shield v$version"
    echo ""
    
    if type show_version_status &>/dev/null; then
        show_version_status
    fi
    echo ""
}

# Обработка команд
case "$1" in
    "")
        # Открываем меню
        source "$MODULES_DIR/menu.sh"
        main_menu
        ;;
    status)
        source "$MODULES_DIR/status.sh"
        show_full_status
        ;;
    version|-v|--version)
        show_version
        ;;
    update)
        source "$MODULES_DIR/updater.sh"
        do_update
        ;;
    keys)
        source "$MODULES_DIR/keys.sh"
        keys_cli "$2"
        ;;
    firewall)
        source "$MODULES_DIR/firewall.sh"
        case "$2" in
            allow) firewall_allow_ip "$3" "$4" ;;
            deny) firewall_deny_ip "$3" ;;
            open) firewall_open_port "$3" "$4" ;;
            close) firewall_close_port "$3" "$4" ;;
            rules) firewall_rules ;;
            status) firewall_status ;;
            *) firewall_menu ;;
        esac
        ;;
    ssh)
        source "$MODULES_DIR/ssh.sh"
        case "$2" in
            port) change_ssh_port "$3" ;;
            status) check_ssh_status ;;
            *) check_ssh_status ;;
        esac
        ;;
    backup)
        source "$MODULES_DIR/backup.sh"
        case "$2" in
            create) create_full_backup ;;
            list) list_backups ;;
            restore) restore_backup "$3" ;;
            *) backup_menu ;;
        esac
        ;;
    telegram)
        source "$MODULES_DIR/telegram.sh"
        case "$2" in
            test) send_test ;;
            *) telegram_menu ;;
        esac
        ;;
    scan)
        source "$MODULES_DIR/rkhunter.sh"
        run_rkhunter_scan
        ;;
    traffic|tc)
        source "$MODULES_DIR/traffic.sh"
        case "$2" in
            status) show_traffic_status ;;
            add) add_limit ;;
            remove) remove_limit ;;
            restart) restart_limiter ;;
            *) traffic_menu ;;
        esac
        ;;
    l7|l7shield|ddos)
        source "$MODULES_DIR/l7shield.sh"
        case "$2" in
            enable) enable_l7 ;;
            disable) disable_l7 ;;
            reload) reload_l7 ;;
            status) show_l7_status ;;
            top) show_top_attackers ;;
            *) l7_menu ;;
        esac
        ;;
    logs)
        source "$MODULES_DIR/menu.sh"
        logs_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Используйте: shield help"
        exit 1
        ;;
esac
