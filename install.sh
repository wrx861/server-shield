#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}##################################################${NC}"
echo -e "${GREEN}#     🛡️ SERVER SECURITY SHIELD (2025) 🛡️      #${NC}"
echo -e "${GREEN}##################################################${NC}"
echo ""

# 1. ПРОВЕРКА НАЛИЧИЯ SSH КЛЮЧЕЙ (ЗАЩИТА ОТ ДУРАКА)
if [ ! -s /root/.ssh/authorized_keys ]; then
    echo -e "${RED}[CRITICAL ERROR] У пользователя ROOT нет SSH-ключей!${NC}"
    echo -e "${YELLOW}Сначала добавь свой Public Key в /root/.ssh/authorized_keys${NC}"
    echo -e "${YELLOW}Иначе после отключения паролей ты потеряешь доступ.${NC}"
    exit 1
fi

# 2. ВЫБОР РОЛИ
echo -e "${YELLOW}Какую роль выполняет этот сервер?${NC}"
echo "1) 🧠 БАЗА (Панель управления / Бот)"
echo "2) 🚀 НОДА (VPN сервер)"
read -p "Твой выбор (1 или 2): " SERVER_TYPE

# 3. ВВОД IP АДРЕСОВ
echo ""
echo -e "${YELLOW}Введите ВАШ Домашний IP (для доступа к SSH):${NC}"
echo -e "Если не знаете, зайдите на 2ip.ru. С этого IP будет полный доступ."
read -p "IP Админа: " ADMIN_IP

if [[ -z "$ADMIN_IP" ]]; then
    echo -e "${RED}IP не введен. Отмена.${NC}"
    exit 1
fi

PANEL_IP=""
if [ "$SERVER_TYPE" == "2" ]; then
    echo ""
    echo -e "${YELLOW}Введите IP вашей ПАНЕЛИ (для управления нодой):${NC}"
    read -p "IP Панели: " PANEL_IP
fi

# 4. УСТАНОВКА СОФТА
echo ""
echo -e "${GREEN}>>> [1/4] Установка софта защиты...${NC}"
apt-get update -q
apt-get install -y ufw fail2ban chrony unattended-upgrades apt-listchanges

# 5. НАСТРОЙКА SSH (ОТКЛЮЧЕНИЕ ПАРОЛЕЙ)
echo -e "${GREEN}>>> [2/4] Бетонируем SSH (Только ключи)...${NC}"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config
service ssh restart

# 6. НАСТРОЙКА UFW (ФАЕРВОЛ)
echo -e "${GREEN}>>> [3/4] Настройка Фаервола (UFW)...${NC}"
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing

# Правило для Админа (SSH)
ufw allow from $ADMIN_IP to any port 22 proto tcp comment 'Admin SSH'

if [ "$SERVER_TYPE" == "1" ]; then
    # === НАСТРОЙКИ ДЛЯ ПАНЕЛИ ===
    echo -e "${GREEN}--- Применяем правила для ПАНЕЛИ ---${NC}"
    ufw allow 80/tcp comment 'Web HTTP'
    ufw allow 443/tcp comment 'Web HTTPS'
    # Можно добавить порт бота, если он не через nginx
    # ufw allow 8080/tcp
    
elif [ "$SERVER_TYPE" == "2" ]; then
    # === НАСТРОЙКИ ДЛЯ НОДЫ ===
    echo -e "${GREEN}--- Применяем правила для НОДЫ ---${NC}"
    
    # Доступ для Панели
    if [[ ! -z "$PANEL_IP" ]]; then
        ufw allow from $PANEL_IP to any comment 'Panel Access'
    fi
    
    # Стандартный порт VPN
    ufw allow 443 comment 'VLESS Reality'
    
    # Спрос доп. портов
    echo ""
    echo -e "${YELLOW}Нужно ли открыть дополнительные порты для VPN? (например 9643 5443)${NC}"
    echo -e "Введите порты через пробел или нажмите Enter, если не нужно:"
    read -a EXTRA_PORTS
    
    for port in "${EXTRA_PORTS[@]}"; do
        ufw allow $port comment 'Custom VPN Port'
        echo "Открыт порт: $port"
    done
fi

# Включение UFW
echo "y" | ufw enable

# 7. ДОПОЛНИТЕЛЬНАЯ ЗАЩИТА
echo -e "${GREEN}>>> [4/4] Финальная полировка (Fail2Ban, Chrony)...${NC}"
# Chrony
timedatectl set-ntp true
systemctl restart chrony

# Fail2Ban Local Config
cat > /etc/fail2ban/jail.local <<FAIL
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
FAIL
systemctl restart fail2ban
systemctl enable fail2ban

# Auto Upgrades
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

echo ""
echo -e "${GREEN}##################################################${NC}"
echo -e "${GREEN}#           СЕРВЕР УСПЕШНО ЗАЩИЩЕН!              #${NC}"
echo -e "${GREEN}##################################################${NC}"
echo -e "SSH доступен только с IP: $ADMIN_IP"
if [ "$SERVER_TYPE" == "2" ]; then
    echo -e "Управление разрешено с IP: $PANEL_IP"
fi
echo -e "Вход по паролям: ОТКЛЮЧЕН"
