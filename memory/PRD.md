# Server Security Shield - PRD

## Описание проекта
Bash-скрипт для комплексной защиты Linux серверов (VPN ноды, панели управления). Проект обеспечивает многоуровневую защиту от угроз через интерактивное меню и CLI команды.

**Текущая версия:** 3.3.0
**Язык интерфейса:** Русский

---

## Статус проекта

### Завершено ✅

#### v3.3.0 - nftables Support (NEW!)
- **nftables backend** — современная альтернатива iptables
- **Автоопределение** firewall (iptables или nftables)
- **Миграция** правил между backends
- **nftables sets** — whitelist, blacklist, autoban
- Все защиты портированы на nftables

#### v3.2.0 - P1 Features
- Cloudflare Real IP, HTTP/2 Protection, WAF, Honeypot URLs

#### v3.1.0 - P0 Features
- JS Challenge, API Rate Limiting, Tarpit Mode, Blocklist Sync, Fail2Ban (5 jails)

#### v3.0.x - Core
- Premium UI, L7 Shield, iptables/ipset, nginx protection

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

**Переключение:**
```
DDoS Protection → Firewall Backend → Переключиться
```

---

## Архитектура v3.3.0

```
/app/
├── shield.sh           # Main CLI
├── VERSION             # 3.3.0
├── CHANGELOG.md
└── modules/
    ├── l7shield.sh     # L7 DDoS Protection (~5000 lines)
    │   ├── iptables rules
    │   ├── nftables rules (NEW)
    │   ├── nginx protection
    │   └── fail2ban integration
    ├── utils.sh
    ├── menu.sh
    └── ...
```

---

## nftables Table Structure

```nft
table inet l7shield {
    # Sets (аналог ipset)
    set whitelist { type ipv4_addr; flags interval }
    set blacklist { type ipv4_addr; flags interval, timeout }
    set autoban { type ipv4_addr; flags timeout; timeout 3600s }
    
    chain input {
        # Whitelist → accept
        # Blacklist → drop
        # Autoban → drop
        # Established → accept
        # SYN flood protection
        # Malformed packets
        # VPN ports (soft limits)
        # SSH (strict limits)
        # HTTP/HTTPS
        # Global limits
    }
}
```

---

## Полный список защит

| Уровень | Защита | iptables | nftables |
|---------|--------|----------|----------|
| L3/L4 | Connection limits | ✅ | ✅ |
| L3/L4 | Rate limiting | ✅ | ✅ |
| L3/L4 | SYN flood | ✅ | ✅ |
| L3/L4 | Blacklist/Whitelist | ✅ ipset | ✅ sets |
| L3/L4 | Auto-ban | ✅ | ✅ |
| L3/L4 | GeoIP | ✅ | ⏳ TODO |
| L7 | Nginx rate limiting | ✅ | ✅ |
| L7 | Bad bots/URI | ✅ | ✅ |
| L7 | JS Challenge | ✅ | ✅ |
| L7 | WAF | ✅ | ✅ |
| L7 | Honeypot | ✅ | ✅ |

---

## CLI

```bash
shield                  # Меню
shield status           # Статус
shield l7 enable        # Включить защиту
shield l7 disable       # Выключить
shield l7 reload        # Перезагрузить

# Backend определяется автоматически
```

---

## Будущие задачи (Backlog)

### P2 - Средний приоритет
- [ ] Статистика атак (графики)
- [ ] REST API для управления
- [ ] GeoIP для nftables

### P3 - Низкий приоритет
- [ ] Web UI
- [ ] Multi-server sync
- [ ] ML детекция

---

## Changelog Summary

- **v3.3.0** — nftables backend support
- **v3.2.0** — P1 (Cloudflare, HTTP/2, WAF, Honeypot)
- **v3.1.0** — P0 (JS Challenge, API Limits, Tarpit, Sync, F2B)
- **v3.0.x** — UI, L7 Shield core
