#!/bin/bash
#
# Удаление Server Shield
#

RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
NC=$'\e[0m'

SHIELD_DIR="/opt/server-shield"

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║         Удаление Server Shield                        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Это действие:${NC}"
echo "  1. Удалит Server Shield"
echo "  2. Восстановит вход по паролям"
echo "  3. Сбросит UFW правила"
echo ""
read -p "Вы уверены? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Отмена."
    exit 0
fi

echo ""
echo -e "${YELLOW}[→] Удаление...${NC}"

# Восстанавливаем SSH
if [[ -f /etc/ssh/sshd_config ]]; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^Port.*/Port 22/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || service ssh restart
    echo -e "${GREEN}[✓]${NC} SSH: вход по паролям включён, порт 22"
fi

# Сброс UFW
if command -v ufw &> /dev/null; then
    ufw --force reset > /dev/null 2>&1
    ufw default allow incoming
    ufw default allow outgoing
    echo "y" | ufw enable > /dev/null
    echo -e "${GREEN}[✓]${NC} UFW: сброшен"
fi

# Удаляем kernel hardening
rm -f /etc/sysctl.d/99-shield-hardening.conf
sysctl --system > /dev/null 2>&1
echo -e "${GREEN}[✓]${NC} Kernel: hardening удалён"

# Удаляем cron
rm -f /etc/cron.weekly/rkhunter-shield
echo -e "${GREEN}[✓]${NC} Cron: задачи удалены"

# Удаляем симлинк
rm -f /usr/local/bin/shield
echo -e "${GREEN}[✓]${NC} CLI: удалён"

# Удаляем директорию
if [[ -d "$SHIELD_DIR" ]]; then
    # Сохраняем бэкапы
    if [[ -d "$SHIELD_DIR/backups" ]]; then
        mkdir -p /root/shield-backups
        cp -r "$SHIELD_DIR/backups/"* /root/shield-backups/ 2>/dev/null
        echo -e "${GREEN}[✓]${NC} Бэкапы сохранены в /root/shield-backups/"
    fi
    
    rm -rf "$SHIELD_DIR"
    echo -e "${GREEN}[✓]${NC} Server Shield: удалён"
fi

echo ""
echo -e "${GREEN}Готово! Server Shield удалён.${NC}"
echo -e "Вход по паролям: ${GREEN}ВКЛЮЧЁН${NC}"
echo -e "SSH порт: ${GREEN}22${NC}"
echo ""
