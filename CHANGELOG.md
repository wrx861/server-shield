# Changelog

All notable changes to Server Shield will be documented in this file.

## [3.3.0] - 2025-01 - nftables Support

### 🔥 nftables Backend
- Полная поддержка nftables как альтернатива iptables
- Автоопределение firewall backend
- Миграция правил между iptables ↔ nftables
- nftables sets вместо ipset (whitelist, blacklist, autoban)
- Все текущие защиты портированы на nftables:
  - Connection limits
  - Rate limiting (SYN flood, per-port)
  - Malformed packets (NULL, XMAS, SYN-FIN)
  - VPN порты с мягкими лимитами

### 📋 Menu
- Новый пункт меню: Firewall Backend
- Показ текущего backend в статусе
- Одним кликом переключение iptables ↔ nftables

### 🔧 API
- `detect_firewall` — определение текущего backend
- `migrate_to_nftables` — миграция на nftables
- `migrate_to_iptables` — миграция на iptables
- `nft_add_to_set`, `nft_del_from_set` — управление sets
- Универсальные функции: `add_to_blacklist_universal`, `autoban_ip_universal`

---

## [3.2.0] - 2025-01 - P1 Features

### 🌐 Cloudflare Real IP Support
- Автоматическая загрузка IP диапазонов Cloudflare
- Поддержка IPv4 и IPv6

### ⚡ HTTP/2 Attack Protection
- Защита от HTTP/2 Rapid Reset (CVE-2023-44487)
- HPACK Bomb, Slow Read, Large Header защита

### 🔍 WAF (Request Body Inspection)
- SQL Injection, XSS, Path Traversal защита
- Command Injection, LFI/RFI, SSRF защита

### 🍯 Honeypot URLs
- 15+ honeypot locations
- Автоматический бан на 24 часа

---

## [3.1.0] - 2025-01 - P0 Features

### 🛡️ JS Challenge, API Rate Limiting, Tarpit Mode
### 🔄 Blocklist Sync, Enhanced Fail2Ban (5 jails)

---

## [3.0.x] - 2025-01

### Premium UI v3.0, L7 Shield Module

---

## [2.x] - 2024
- UFW, Fail2Ban, SSH, Telegram, Backup, Monitor
