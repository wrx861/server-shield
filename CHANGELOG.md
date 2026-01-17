# Changelog

All notable changes to Server Shield will be documented in this file.

## [3.4.9] - 2025-01 - Input Buffer Fix

### 🔧 Исправления
- Исправлена проблема с двойным нажатием в меню
- Очистка буфера ввода перед чтением выбора
- Очистка буфера после "Нажмите любую клавишу"

---

## [3.4.8] - 2025-01 - UX Improvements

### 🎨 Улучшения UX
- При выходе из настроек лимитов теперь спрашивает "Применить изменения?"
- Исправлен вывод ошибок nftables (не показываются дважды)
- Улучшены сообщения о процессе

---

## [3.4.7] - 2025-01 - Performance & Compatibility

### ⚡ Производительность
- Оптимизирована синхронизация GitHub (быстрый batch режим вместо цикла)
- Добавлен прогресс-бар при добавлении IP
- Используется grep -F для быстрой фильтрации

### 🔧 Совместимость
- Закомментирован `more_clear_headers` (требует nginx-extras)
- Автоустановка nginx-extras если возможно
- Исправлена работа с разными версиями nginx

---

## [3.4.6] - 2025-01 - Secure PAT Storage

### 🔐 Безопасность
- PAT токен теперь хранится в отдельном файле `/opt/server-shield/config/github_pat.conf`
- Токен не коммитится в репозиторий (GitHub не отзовёт)
- Добавлено меню настройки PAT токена (пункт 4 в GitHub Sync)
- Права файла 600 (только root)

### 🔧 Исправления
- Исправлена работа с приватными репозиториями (использование API URL)

---

## [3.4.5] - 2025-01 - Auto Nginx Install

### 🔧 Улучшения
- Автоматическая установка Nginx при включении L7 Shield
- Поддержка apt/yum/dnf пакетных менеджеров

---

## [3.4.4] - 2025-01 - nftables Fix

### 🔧 Исправления
- Исправлен синтаксис nftables для совместимости со старыми версиями
- Удалены неподдерживаемые флаги timeout/dynamic из sets
- Упрощена конфигурация nftables

---

## [3.4.3] - 2025-01 - Menu Fix

### 🎨 Исправления
- Исправлено выравнивание двухколоночного меню (использован echo вместо printf)

---

## [3.4.2] - 2025-01 - UI Fixes

### 🎨 Исправления интерфейса
- Исправлено выравнивание двухколоночного меню
- Исправлен статус-блок в меню Blacklist
- Cron синхронизация изменена с 5 мин на 12 часов

---

## [3.4.0] - 2025-01 - GitHub-Synced Blocklist

### 🌐 Централизованная база атакующих IP
- **GitHub-powered blocklist** — общая база IP атакующих для всех пользователей
- Автоматическая синхронизация с приватным репозиторием `wrx861/blockip`
- Двунаправленный sync: скачивание общей базы + отправка локальных банов
- Cron-job каждые 12 часов для автоматической синхронизации

### 🔄 Новый Blacklist Workflow
- Удалена старая система URL-блоклистов
- Все забаненные IP автоматически попадают в общую базу
- При включении L7 Shield сразу загружается общая база
- Очередь на отправку IP с дедупликацией

### 📋 Обновлённое меню Blacklist
- Новый дизайн меню с GitHub статистикой
- Показ очереди на отправку
- Ручная синхронизация одним кликом
- Показ времени последней синхронизации

### 🔧 API & CLI
- `github_full_sync` — полная синхронизация
- `check_github_connection` — проверка подключения
- `queue_ip_for_sync` — добавление IP в очередь
- CLI: `shield l7 sync` — ручная синхронизация
- Улучшенная обработка ошибок GitHub API

### ⚠️ Breaking Changes
- Удалены функции `add_blacklist_url`, `remove_blacklist_url`, `update_blacklists_from_urls`
- Файл `blacklist_urls.txt` больше не используется

---

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
