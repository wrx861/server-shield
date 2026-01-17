# Server Security Shield - PRD

## Описание проекта
Bash-скрипт для комплексной защиты Linux серверов (VPN ноды, панели управления). Проект обеспечивает многоуровневую защиту от угроз через интерактивное меню и CLI команды.

**Текущая версия:** 3.4.0
**Язык интерфейса:** Русский

---

## Статус проекта

### Завершено ✅

#### v3.4.0 - GitHub-Synced Blocklist (NEW!)
- **Централизованная база IP** — общая база атакующих для всех пользователей
- Синхронизация с приватным репозиторием `wrx861/blockip`
- Двунаправленный sync: скачивание + отправка локальных банов
- Автоматический cron каждые 5 минут
- 41,000+ уникальных IP в общей базе
- Удалена старая система URL-блоклистов

#### v3.3.0 - nftables Support
- Полная поддержка nftables как альтернатива iptables
- Автоопределение firewall backend
- Миграция правил между backends
- nftables sets вместо ipset

#### v3.2.0 - P1 Features
- Cloudflare Real IP, HTTP/2 Protection, WAF, Honeypot URLs

#### v3.1.0 - P0 Features
- JS Challenge, API Rate Limiting, Tarpit Mode, Blocklist Sync, Fail2Ban (5 jails)

#### v3.0.x - Core
- Premium UI, L7 Shield, iptables/ipset, nginx protection

---

## GitHub IP Sync Architecture

### Конфигурация
```bash
GITHUB_PAT="github_pat_..."  # Fine-grained token
GITHUB_REPO="wrx861/blockip"
GITHUB_FILE="iplist.txt"
```

### Рабочий процесс
1. **Включение L7 Shield** → автоматический первый sync
2. **Autoban IP** → добавление в очередь sync_queue.txt
3. **Cron (каждые 5 мин)** → github_full_sync
4. **Sync функция**:
   - Скачивает IP из GitHub
   - Добавляет в локальный blacklist (ipset/nftables)
   - Отправляет локальные баны в GitHub

### Файлы
```
/opt/server-shield/config/l7shield/
├── sync_queue.txt      # Очередь на отправку в GitHub
├── synced_ips.txt      # Уже синхронизированные IP
├── last_sync.txt       # Время последней синхронизации
├── blacklist.txt       # Локальный blacklist
└── whitelist.txt       # Whitelist (не синхронизируется)
```

---

## Firewall Backends

### iptables (классический)
- Широкая совместимость
- ipset для IP списков
- Зрелый и стабильный

### nftables (современный)
- Замена iptables в новых Linux
- Быстрее на больших списках
- Встроенные sets (не нужен ipset)
- Ubuntu 22.04+, Debian 11+

---

## Архитектура v3.4.0

```
/app/
├── shield.sh           # Main CLI
├── VERSION             # 3.4.0
├── CHANGELOG.md
└── modules/
    ├── l7shield.sh     # L7 DDoS Protection (~5500 lines)
    │   ├── iptables/nftables rules
    │   ├── nginx protection
    │   ├── fail2ban integration
    │   └── GitHub sync (NEW)
    ├── utils.sh
    ├── menu.sh
    └── ...
```

---

## CLI

```bash
shield                  # Меню
shield status           # Статус
shield l7 enable        # Включить защиту
shield l7 disable       # Выключить
shield l7 reload        # Перезагрузить
shield l7 sync          # Синхронизация с GitHub (NEW)
```

---

## Будущие задачи (Backlog)

### P1 - Высокий приоритет
- [ ] Статистика атак (графики)
- [ ] REST API для управления

### P2 - Средний приоритет
- [ ] GeoIP для nftables
- [ ] Web UI

### P3 - Низкий приоритет
- [ ] Multi-server sync (без GitHub)
- [ ] ML детекция

---

## Changelog Summary

- **v3.4.0** — GitHub-synced IP blocklist
- **v3.3.0** — nftables backend support
- **v3.2.0** — P1 (Cloudflare, HTTP/2, WAF, Honeypot)
- **v3.1.0** — P0 (JS Challenge, API Limits, Tarpit, Sync, F2B)
- **v3.0.x** — UI, L7 Shield core
