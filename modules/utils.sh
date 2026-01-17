#!/bin/bash
#
# utils.sh - Общие функции и переменные
# Premium UI Design v3.0
#

# Цвета
export RED=$'\e[0;31m'
export GREEN=$'\e[0;32m'
export YELLOW=$'\e[1;33m'
export BLUE=$'\e[0;34m'
export PURPLE=$'\e[0;35m'
export CYAN=$'\e[0;36m'
export WHITE=$'\e[1;37m'
export DIM=$'\e[2m'
export BOLD=$'\e[1m'
export NC=$'\e[0m' # No Color

# Директории
export SHIELD_DIR="/opt/server-shield"
export BACKUP_DIR="$SHIELD_DIR/backups"
export CONFIG_DIR="$SHIELD_DIR/config"
export LOG_DIR="$SHIELD_DIR/logs"

# Конфиг файл
export SHIELD_CONFIG="$CONFIG_DIR/shield.conf"

# ============================================
# PREMIUM UI FUNCTIONS
# ============================================

# Получить версию
_get_version() {
    if [[ -f "$SHIELD_DIR/VERSION" ]]; then
        cat "$SHIELD_DIR/VERSION" 2>/dev/null | tr -d '[:space:]'
    else
        echo "3.0.0"
    fi
}

# Получить имя сервера
_get_server_display_name() {
    local custom_name=$(get_config "SERVER_NAME" "" 2>/dev/null)
    if [[ -n "$custom_name" ]]; then
        echo "$custom_name"
    else
        hostname -s 2>/dev/null || hostname
    fi
}

# Premium ASCII Header
print_header() {
    local version=$(_get_version)
    clear
    echo ""
    echo -e "  ${DIM}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC}                                                             ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}███████╗${NC}${WHITE}██╗  ██╗${NC}${CYAN}██╗${NC}${WHITE}███████╗${NC}${CYAN}██╗     ${NC}${WHITE}██████╗ ${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}██╔════╝${NC}${WHITE}██║  ██║${NC}${CYAN}██║${NC}${WHITE}██╔════╝${NC}${CYAN}██║     ${NC}${WHITE}██╔══██╗${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}███████╗${NC}${WHITE}███████║${NC}${CYAN}██║${NC}${WHITE}█████╗  ${NC}${CYAN}██║     ${NC}${WHITE}██║  ██║${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}╚════██║${NC}${WHITE}██╔══██║${NC}${CYAN}██║${NC}${WHITE}██╔══╝  ${NC}${CYAN}██║     ${NC}${WHITE}██║  ██║${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}███████║${NC}${WHITE}██║  ██║${NC}${CYAN}██║${NC}${WHITE}███████╗${NC}${CYAN}███████╗${NC}${WHITE}██████╔╝${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}   ${CYAN}╚══════╝${NC}${WHITE}╚═╝  ╚═╝${NC}${CYAN}╚═╝${NC}${WHITE}╚══════╝${NC}${CYAN}╚══════╝${NC}${WHITE}╚═════╝ ${NC}              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}                                                             ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}          ${DIM}Server Security Suite${NC}  ${WHITE}v${version}${NC}                      ${DIM}│${NC}"
    echo -e "  ${DIM}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Компактный header для подменю
print_header_mini() {
    local title="$1"
    local version=$(_get_version)
    clear
    echo ""
    echo -e "  ${CYAN}${BOLD}SHIELD${NC} ${DIM}v${version}${NC} │ ${WHITE}${title}${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# Статус карточки
print_status_cards() {
    # Получаем статусы
    local protected=true
    local blocked=$(get_total_blocked 2>/dev/null || echo "0")
    local uptime=$(uptime -p 2>/dev/null | sed 's/up //' | cut -d',' -f1 || echo "N/A")
    
    echo -e "    ╭──────────────╮  ╭──────────────╮  ╭──────────────╮"
    if [[ "$protected" == "true" ]]; then
        echo -e "    │ ${GREEN}●${NC} ${WHITE}PROTECTED${NC}  │  │ Blocked ${RED}${blocked}${NC} │  │ Up ${GREEN}${uptime}${NC} │"
    else
        echo -e "    │ ${RED}○${NC} ${RED}UNPROTECTED${NC}│  │ Blocked ${RED}${blocked}${NC} │  │ Up ${GREEN}${uptime}${NC} │"
    fi
    echo -e "    ╰──────────────╯  ╰──────────────╯  ╰──────────────╯"
    echo ""
}

# Статус-бар сервисов
print_services_status() {
    local ssh_status=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null)
    local ufw_status=$(ufw status 2>/dev/null | grep -q "Status: active" && echo "active" || echo "inactive")
    local f2b_status=$(systemctl is-active fail2ban 2>/dev/null)
    local ddos_status=$(get_config "L7_ENABLED" "false" 2>/dev/null)
    local tg_token=$(get_config "TG_TOKEN" "" 2>/dev/null)
    
    echo -e "    ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
    echo -ne "    ${DIM}│${NC} "
    
    # SSH
    [[ "$ssh_status" == "active" ]] && echo -ne "${GREEN}✓${NC} SSH    " || echo -ne "${RED}○${NC} SSH    "
    
    # UFW
    [[ "$ufw_status" == "active" ]] && echo -ne "${GREEN}✓${NC} UFW    " || echo -ne "${RED}○${NC} UFW    "
    
    # Fail2Ban
    [[ "$f2b_status" == "active" ]] && echo -ne "${GREEN}✓${NC} Fail2Ban    " || echo -ne "${RED}○${NC} Fail2Ban    "
    
    # DDoS
    [[ "$ddos_status" == "true" ]] && echo -ne "${GREEN}✓${NC} DDoS    " || echo -ne "${RED}○${NC} DDoS    "
    
    # Telegram
    [[ -n "$tg_token" ]] && echo -ne "${GREEN}✓${NC} TG" || echo -ne "${RED}○${NC} TG"
    
    echo -e "   ${DIM}│${NC}"
    echo -e "    ${DIM}└──────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Получить общее количество заблокированных
get_total_blocked() {
    local total=0
    
    # Fail2Ban
    local f2b=$(fail2ban-client status 2>/dev/null | grep "Total banned" | awk '{sum+=$NF} END {print sum}')
    [[ -n "$f2b" ]] && total=$((total + f2b))
    
    # ipset blacklist
    local ipset_bl=$(ipset list l7_blacklist 2>/dev/null | grep -c "^[0-9]" || echo 0)
    total=$((total + ipset_bl))
    
    # ipset autoban
    local ipset_ab=$(ipset list l7_autoban 2>/dev/null | grep -c "^[0-9]" || echo 0)
    total=$((total + ipset_ab))
    
    # Форматируем число
    if [[ $total -ge 1000 ]]; then
        echo "$(echo "scale=1; $total/1000" | bc)K"
    else
        echo "$total"
    fi
}

# Функция вывода секции (новый стиль)
print_section() {
    local title="$1"
    echo ""
    echo -e "  ${DIM}┌─${NC} ${WHITE}${title}${NC} ${DIM}$(printf '─%.0s' $(seq 1 $((55 - ${#title}))))┐${NC}"
}

# Закрыть секцию
print_section_end() {
    echo -e "  ${DIM}└───────────────────────────────────────────────────────────┘${NC}"
}

# Разделитель
print_divider() {
    echo -e "    ${DIM}──────────────────────────────────────────────────────${NC}"
}

# Подсказки внизу
print_footer() {
    echo ""
    echo -e "    ${DIM}──────────────────────────────────────────────────────${NC}"
    echo -e "    ${DIM}q:quit  r:refresh  u:update  ?:help${NC}"
}

# Функции логирования (обновленные)
log_info() {
    echo -e "    ${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "    ${YELLOW}!${NC} $1"
}

log_error() {
    echo -e "    ${RED}✗${NC} $1"
}

log_step() {
    echo -e "    ${CYAN}→${NC} $1"
}

# Функция проверки root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от root!"
        exit 1
    fi
}

# Функция проверки ОС
check_os() {
    if [[ -f /etc/debian_version ]]; then
        export OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        export OS="rhel"
        log_error "RHEL/CentOS пока не поддерживается"
        exit 1
    else
        log_error "Неподдерживаемая ОС"
        exit 1
    fi
}

# Функция создания директорий
init_directories() {
    mkdir -p "$SHIELD_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
}

# Функция сохранения конфига
save_config() {
    local key="$1"
    local value="$2"
    
    # Создаём файл если не существует
    touch "$SHIELD_CONFIG"
    
    # Удаляем старое значение если есть
    sed -i "/^${key}=/d" "$SHIELD_CONFIG"
    
    # Добавляем новое
    echo "${key}=${value}" >> "$SHIELD_CONFIG"
}

# Функция чтения конфига
get_config() {
    local key="$1"
    local default="$2"
    
    if [[ -f "$SHIELD_CONFIG" ]]; then
        local value=$(grep "^${key}=" "$SHIELD_CONFIG" | cut -d'=' -f2-)
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# Функция подтверждения
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Функция ожидания нажатия клавиши
press_any_key() {
    echo ""
    echo -ne "    ${DIM}Нажмите любую клавишу...${NC}"
    read -n 1 -s -r
    echo ""
    # Очищаем буфер ввода
    read -t 0.1 -n 10000 discard 2>/dev/null || true
}

# Функция проверки IP адреса
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Функция проверки порта
validate_port() {
    local port="$1"
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    fi
    return 1
}

# Функция получения внешнего IP
get_external_ip() {
    curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "N/A"
}

# Функция получения hostname
get_hostname() {
    hostname -f 2>/dev/null || hostname
}

# Функция получения имени сервера (пользовательское или hostname)
get_server_name() {
    local custom_name=$(get_config "SERVER_NAME" "")
    if [[ -n "$custom_name" ]]; then
        echo "$custom_name"
    else
        get_hostname
    fi
}

# ============================================
# UNIVERSAL MENU FUNCTIONS
# ============================================

# Чтение ввода с валидацией
read_choice() {
    # Очищаем буфер ввода перед чтением
    read -t 0.1 -n 10000 discard 2>/dev/null || true
    echo "" >&2
    echo -ne "    ${WHITE}▸${NC} " >&2
    read -r REPLY
    echo "$REPLY"
}

# Меню опция (для отображения)
menu_item() {
    local key="$1"
    local text="$2"
    local status="${3:-}"
    
    if [[ -n "$status" ]]; then
        echo -e "    ${CYAN}[$key]${NC} $text ${status}"
    else
        echo -e "    ${CYAN}[$key]${NC} $text"
    fi
}

# Меню опция (неактивная)
menu_item_dim() {
    local key="$1"
    local text="$2"
    echo -e "    ${DIM}[$key] $text${NC}"
}

# Разделитель меню
menu_divider() {
    echo ""
}

# Ожидание с сообщением
wait_message() {
    local msg="$1"
    echo -ne "    ${CYAN}→${NC} $msg..."
}

# Завершение ожидания
wait_done() {
    echo -e " ${GREEN}✓${NC}"
}

wait_fail() {
    echo -e " ${RED}✗${NC}"
}

# Статус индикатор
status_on() {
    echo -e "${GREEN}● ON${NC}"
}

status_off() {
    echo -e "${RED}○ OFF${NC}"
}

status_ok() {
    echo -e "${GREEN}✓${NC}"
}

status_err() {
    echo -e "${RED}✗${NC}"
}

# Подтверждение с новым стилем
confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    echo ""
    if [[ "$default" == "y" ]]; then
        echo -ne "    ${YELLOW}?${NC} $prompt ${DIM}[Y/n]${NC} "
    else
        echo -ne "    ${YELLOW}?${NC} $prompt ${DIM}[y/N]${NC} "
    fi
    
    read -r response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Ввод значения
input_value() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    echo ""
    if [[ -n "$default" ]]; then
        echo -ne "    ${WHITE}$prompt${NC} ${DIM}[$default]${NC}: "
    else
        echo -ne "    ${WHITE}$prompt${NC}: "
    fi
    
    read -r value
    value="${value:-$default}"
    
    if [[ -n "$var_name" ]]; then
        eval "$var_name='$value'"
    else
        echo "$value"
    fi
}

# Ввод пароля (скрытый)
input_password() {
    local prompt="$1"
    local var_name="$2"
    
    echo ""
    echo -ne "    ${WHITE}$prompt${NC}: "
    read -rs value
    echo ""
    
    if [[ -n "$var_name" ]]; then
        eval "$var_name='$value'"
    else
        echo "$value"
    fi
}

# Показать информацию
show_info() {
    local label="$1"
    local value="$2"
    echo -e "    ${DIM}$label:${NC} ${WHITE}$value${NC}"
}

# Показать статус строку
show_status_line() {
    local label="$1"
    local status="$2"
    local extra="${3:-}"
    
    if [[ "$status" == "on" ]] || [[ "$status" == "active" ]] || [[ "$status" == "true" ]] || [[ "$status" == "enabled" ]]; then
        echo -e "    ${GREEN}●${NC} $label ${extra}"
    elif [[ "$status" == "warn" ]] || [[ "$status" == "warning" ]]; then
        echo -e "    ${YELLOW}●${NC} $label ${extra}"
    else
        echo -e "    ${RED}○${NC} $label ${extra}"
    fi
}

# Таблица header
table_header() {
    local cols="$1"
    echo -e "    ${DIM}$cols${NC}"
    echo -e "    ${DIM}$(echo "$cols" | sed 's/./-/g')${NC}"
}

# Прогресс бар
progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-30}"
    
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar="${GREEN}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${DIM}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${NC}"
    
    echo -e "$bar ${WHITE}${percent}%${NC}"
}

# Спиннер для долгих операций
spinner() {
    local pid=$1
    local msg="${2:-Processing}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#spin} ))
        printf "\r    ${CYAN}${spin:$i:1}${NC} $msg..."
        sleep 0.1
    done
    printf "\r    ${GREEN}✓${NC} $msg... done\n"
}

# Проверка валидного выбора в меню
is_valid_choice() {
    local choice="$1"
    shift
    local valid_choices=("$@")
    
    for valid in "${valid_choices[@]}"; do
        [[ "$choice" == "$valid" ]] && return 0
    done
    return 1
}
