<p align="center">
  <img src="https://raw.githubusercontent.com/wrx861/server-shield/main/assets/logo.png" alt="Shield Logo" width="200"/>
</p>

<h1 align="center">🛡️ Server Shield</h1>

<p align="center">
  <strong>Enterprise-grade Server Security Suite for VPN Providers</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#installation">Installation</a> •
  <a href="#usage">Usage</a> •
  <a href="#ddos-protection">DDoS Protection</a> •
  <a href="#updates">Updates</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.3.0-blue.svg" alt="Version"/>
  <img src="https://img.shields.io/badge/bash-5.0+-green.svg" alt="Bash"/>
  <img src="https://img.shields.io/badge/license-MIT-orange.svg" alt="License"/>
  <img src="https://img.shields.io/badge/platform-Ubuntu%20|%20Debian-lightgrey.svg" alt="Platform"/>
</p>

---

## 🎯 Overview

**Server Shield** — это комплексное решение для защиты Linux серверов, разработанное специально для VPN провайдеров и хостинг-компаний. Простая установка, мощная защита, интуитивное управление.

```
  ┌─────────────────────────────────────────────────────────────┐
  │   ███████╗██╗  ██╗██╗███████╗██╗     ██████╗               │
  │   ██╔════╝██║  ██║██║██╔════╝██║     ██╔══██╗              │
  │   ███████╗███████║██║█████╗  ██║     ██║  ██║              │
  │   ╚════██║██╔══██║██║██╔══╝  ██║     ██║  ██║              │
  │   ███████║██║  ██║██║███████╗███████╗██████╔╝              │
  │   ╚══════╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚═════╝               │
  │          Server Security Suite  v3.3.0                      │
  └─────────────────────────────────────────────────────────────┘
```

---

## ✨ Features

### 🔥 Dual Firewall Backend
- **iptables** — классический, максимальная совместимость
- **nftables** — современный, быстрее на больших списках
- Автоопределение и миграция между backends
- Переключение одним кликом

### 🛡️ L7 DDoS Protection
- Connection limits per IP
- Rate limiting (SYN flood, per-port)
- Malformed packets (NULL, XMAS, SYN-FIN)
- VPN порты с мягкими правилами
- GeoIP блокировка по странам
- Auto-ban атакующих
- IP Blacklists из внешних источников

### 🌐 Nginx Protection
- Rate limit zones
- Connection limits
- Bad bots blocking (User-Agent)
- Bad URI blocking (.php, .env, wp-admin)
- HTTP method filtering
- Slowloris protection

### 🤖 Advanced Protection (NEW in 3.x)
- **JS Challenge Page** — защита от ботов (как Cloudflare)
- **API Rate Limiting** — строгие лимиты для /api/
- **Tarpit Mode** — замедление подозрительных
- **WAF** — SQL/XSS/LFI injection protection
- **Honeypot URLs** — ловушки с автобаном
- **HTTP/2 Protection** — CVE-2023-44487
- **Cloudflare Real IP** — корректный IP за CDN
- **Blocklist Sync** — ipset ↔ nginx синхронизация

### 🚔 Fail2Ban L7 (5 Jails)
- `l7-404` — сканеры (2× 404 = бан 10 мин)
- `l7-429` — rate limit (3× 429 = бан 30 мин)
- `l7-scanner` — .php/.env (1× = бан 1 час)
- `l7-flood` — HTTP flood (500 req/30s = бан 15 мин)
- `l7-badbots` — bad UA (1× = бан 24 часа)

### 📱 Telegram Notifications
- SSH login алерты
- Fail2Ban алерты
- DDoS алерты
- Honeypot алерты
- Поддержка групп и тем

### 🔑 SSH Security
- ED25519 ключи
- Управление authorized_keys
- Смена порта SSH
- Key-only authentication

### 💾 Additional Features
- Backup & Recovery
- Resource Monitoring
- Traffic Shaping (per-client)
- Rootkit Scanner
- Kernel Hardening

---

## 📦 Installation

### Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh)
```

### Требования

- **OS:** Ubuntu 20.04+ / Debian 11+
- **RAM:** 512MB+
- **Access:** Root

---

## 🚀 Usage

### Запуск меню

```bash
shield
```

### Главное меню v3.3

```
ЗАЩИТА                      УТИЛИТЫ
[1] Firewall (UFW)          [7] Telegram
[2] Fail2Ban                [8] Бэкапы
[3] DDoS Protection         [9] Логи
[4] SSH Security            [m] Мониторинг
[5] SSH Ключи               [s] Полный статус
[6] Traffic Control

[k] Rootkit Scanner
[u] Обновления
[0] Выход
```

### DDoS Protection Menu

```
Status: ● ACTIVE  Backend: nftables
Blacklist: 15  Auto-ban: 3  Conn: 1247

[1] Полный статус
[2] Топ атакующих (live)
[3] Включить/Выключить защиту
[4] Перезагрузить правила
[5] VPN порты
[6] IP Blacklist
[7] IP Whitelist
[8] GeoIP блокировка
[9] Настройка лимитов
[n] Nginx защита
[f] Fail2Ban L7
[b] Firewall Backend (nftables)
[l] Логи банов
```

### CLI команды

```bash
# Основные
shield                  # Меню
shield status           # Статус защиты
shield version          # Версия
shield update           # Обновления

# DDoS Protection
shield l7 enable        # Включить
shield l7 disable       # Выключить
shield l7 status        # Статус
shield l7 reload        # Перезагрузить
shield l7 top           # Топ атакующих

# Traffic Control
shield traffic status   # Статус лимитов
shield traffic add      # Добавить лимит

# Firewall
shield firewall allow 1.2.3.4
shield firewall deny 1.2.3.4
shield firewall open 8080
shield firewall rules

# SSH
shield ssh port 2222
shield keys generate
shield keys show

# Другое
shield scan             # Rootkit скан
shield logs             # Логи
shield help             # Справка
```

---

## 🛡️ DDoS Protection

### Уровни защиты

| Уровень | Технология | Защита |
|---------|------------|--------|
| L3/L4 | iptables/nftables | Connection limits, SYN flood, Rate limiting |
| L7 | Nginx | Rate limiting, Bad bots, WAF, Honeypot |
| Reactive | Fail2Ban | 404 scanners, 429 flood, Bad UA |

### Firewall Backends

| Backend | Описание | Рекомендация |
|---------|----------|--------------|
| iptables | Классический, ipset | Ubuntu 18-20, Debian 10 |
| nftables | Современный, встроенные sets | Ubuntu 22+, Debian 11+ |

Переключение: `DDoS Protection → Firewall Backend`

### VPN порты

Shield автоматически определяет VPN порты и применяет мягкие правила:

```
Default: 443, 8443, 2053, 2083, 2087, 2096
```

### Nginx интеграция

Автопоиск конфигов в:
- `/etc/nginx/sites-enabled/`
- `/etc/nginx/conf.d/`
- `/opt/remnawave/`
- `/opt/marzban/`
- `/opt/3x-ui/`
- `/opt/hiddify/`

---

## 🔄 Updates

### Через меню

```bash
shield
# Нажмите [u] — Обновления
```

### Через CLI

```bash
shield update
```

### Автопроверка

Shield проверяет обновления при каждом запуске и показывает уведомление.

---

## 📁 File Structure

```
/opt/server-shield/
├── shield.sh           # Main CLI
├── VERSION             # 3.3.0
├── README.md
├── CHANGELOG.md
├── install.sh
├── uninstall.sh
├── config/
│   ├── shield.conf
│   └── l7shield/
│       ├── config.conf
│       ├── whitelist.txt
│       ├── blacklist.txt
│       └── vpn_ports.txt
├── logs/
├── backups/
├── scripts/
│   ├── l7-autoban.sh
│   ├── l7-sync-blocklist.sh
│   └── l7-honeypot-ban.sh
└── modules/
    ├── utils.sh        # UI functions
    ├── menu.sh         # Main menu
    ├── l7shield.sh     # DDoS Protection (~5000 lines)
    ├── firewall.sh     # UFW
    ├── fail2ban.sh     # Fail2Ban
    ├── telegram.sh     # Notifications
    ├── ssh.sh          # SSH settings
    ├── keys.sh         # SSH keys
    ├── backup.sh       # Backup/restore
    ├── monitor.sh      # Resource monitor
    ├── traffic.sh      # Traffic shaping
    ├── rkhunter.sh     # Rootkit scanner
    ├── kernel.sh       # Kernel hardening
    ├── status.sh       # Status display
    └── updater.sh      # Updates
```

---

## 📝 Changelog

### v3.3.0 (2025-01)
- 🔥 **nftables backend** — современная альтернатива iptables
- Автоопределение firewall
- Миграция iptables ↔ nftables
- nftables sets для IP списков

### v3.2.0 (2025-01)
- 🌐 Cloudflare Real IP Support
- ⚡ HTTP/2 Attack Protection
- 🔍 WAF (SQL/XSS/LFI protection)
- 🍯 Honeypot URLs

### v3.1.0 (2025-01)
- 🛡️ JS Challenge Page
- 🚀 API Rate Limiting
- 🐌 Tarpit Mode
- 🔄 Blocklist Sync
- 🚔 Enhanced Fail2Ban (5 jails)

### v3.0.0 (2025-01)
- 🎨 Premium UI v3.0
- 🛡️ L7 DDoS Protection
- 🌐 Nginx integration
- 📱 Telegram improvements

---

## 🔧 Troubleshooting

### Shield не запускается

```bash
chmod +x /opt/server-shield/shield.sh
chmod +x /opt/server-shield/modules/*.sh
```

### UFW заблокировал SSH

```bash
ufw allow 22/tcp
ufw reload
```

### nftables не работает

```bash
# Проверить статус
systemctl status nftables

# Установить
apt install nftables
systemctl enable nftables
systemctl start nftables
```

### Проверка правил

```bash
# iptables
iptables -L L7SHIELD -n -v

# nftables
nft list table inet l7shield
```

---

## 🤝 Contributing

Pull requests welcome!

---

## 📄 License

MIT License

---

## 💬 Support

- **Issues:** [GitHub Issues](https://github.com/wrx861/server-shield/issues)

---

<p align="center">
  Made with ❤️ for VPN providers
</p>
