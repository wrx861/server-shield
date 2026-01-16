# Server Security Shield - PRD

## Описание проекта
Bash-скрипт для комплексной защиты Linux серверов (VPN ноды, панели управления). Проект обеспечивает многоуровневую защиту от угроз через интерактивное меню и CLI команды.

## Основные модули

### Существующие модули
- **shield.sh** - главный CLI скрипт
- **menu.sh** - интерактивное меню
- **utils.sh** - общие функции
- **firewall.sh** - управление UFW
- **ssh.sh** - настройки SSH
- **keys.sh** - SSH-ключи
- **fail2ban.sh** - защита от брутфорса
- **telegram.sh** - уведомления
- **kernel.sh** - hardening ядра
- **rkhunter.sh** - rootkit сканер
- **backup.sh** - бэкапы
- **status.sh** - статус системы
- **updater.sh** - обновления
- **traffic.sh** - ограничение скорости
- **monitor.sh** - мониторинг ресурсов

### Новый модуль: L7 Shield (Выполнено ✅)
**Файл:** `/app/modules/l7shield.sh`

**Функционал:**
- ✅ Connection Limits (iptables connlimit)
- ✅ Rate Limiting (iptables hashlimit + nginx)
- ✅ SYN Flood Protection
- ✅ HTTP Flood Protection (nginx)
- ✅ Auto-ban система (автоматический бан при превышении лимитов)
- ✅ GeoIP Blocking (блокировка по странам)
- ✅ IP Blacklists (загрузка с URL)
- ✅ IP Whitelist (защита VPN клиентов)
- ✅ Настраиваемые VPN порты (исключения из агрессивной фильтрации)
- ✅ Интеграция в главное меню
- ✅ CLI команды (shield l7 enable/disable/status/top)
- ✅ Systemd сервис для автозапуска
- ✅ Cron задачи для автоматической защиты
- ✅ Telegram уведомления о банах

**Дефолтные VPN порты:** 443, 8443, 2053, 2083, 2087, 2096

**Предустановленные источники blacklist:**
- https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http
- https://openproxylist.xyz/http.txt
- https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt

---

## Завершённые задачи (Декабрь 2025)

### 1. L7 Shield Module - ГОТОВО ✅
- Создан полный модуль защиты от L7 DDoS
- Интегрирован в главное меню (пункт "l")
- Добавлены CLI команды: `shield l7 enable/disable/reload/status/top`
- Production-ready для крупных VPN проектов (10-400 клиентов)

---

## Архитектура

```
/app/
├── shield.sh           # Main CLI
├── install.sh          # Установщик
├── uninstall.sh        # Удаление
├── VERSION             # Версия
├── README.md
└── modules/
    ├── utils.sh        # Утилиты
    ├── menu.sh         # Главное меню
    ├── l7shield.sh     # L7 DDoS Protection ✅ NEW
    ├── firewall.sh     # UFW
    ├── ssh.sh          # SSH настройки
    ├── keys.sh         # SSH ключи
    ├── fail2ban.sh     # Fail2Ban
    ├── telegram.sh     # Уведомления
    ├── kernel.sh       # Kernel hardening
    ├── rkhunter.sh     # Rootkit сканер
    ├── backup.sh       # Бэкапы
    ├── status.sh       # Статус
    ├── updater.sh      # Обновления
    ├── traffic.sh      # Traffic shaping
    └── monitor.sh      # Мониторинг
```

---

## Использование L7 Shield

### Через меню
```bash
shield        # Открыть меню
# Выбрать "l" - L7 Shield
```

### Через CLI
```bash
shield l7 enable     # Включить защиту
shield l7 disable    # Выключить
shield l7 status     # Статус
shield l7 top        # Топ атакующих
shield l7 reload     # Перезагрузить правила
```

### Конфигурация
Файл: `/opt/server-shield/config/l7shield/config.conf`

```bash
# Connection Limits
CONN_LIMIT_GLOBAL="500"    # Глобальный лимит
CONN_LIMIT_VPN="300"       # Для VPN портов (мягче)
CONN_LIMIT_SSH="10"        # SSH

# Rate Limits
RATE_LIMIT_VPN="100/s"     # Для VPN
RATE_LIMIT_HTTP="30/s"     # HTTP

# Auto-ban
AUTOBAN_ENABLED="true"
AUTOBAN_CONN_THRESHOLD="300"
AUTOBAN_TIME="3600"

# GeoIP
GEOIP_ENABLED="false"
GEOIP_MODE="allow"
```

---

## Будущие задачи (Backlog)

### P1 - Высокий приоритет
- [ ] Интеграция с Cloudflare для дополнительной защиты
- [ ] Расширенная статистика атак (графики, история)
- [ ] Автоматическая эскалация при DDoS

### P2 - Средний приоритет
- [ ] Поддержка nftables (альтернатива iptables)
- [ ] REST API для удалённого управления
- [ ] Интеграция с SIEM системами

### P3 - Низкий приоритет
- [ ] Web UI для управления
- [ ] Мульти-сервер синхронизация blacklist
- [ ] Machine Learning для детекции атак

---

## Язык
Проект на русском языке. Все коммуникации с пользователем на русском.
