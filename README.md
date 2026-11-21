<div align="center">

# 🛡️ VPS DoH Enabler (`mydns`)

**Интерактивный менеджер системного DNS-over-HTTPS (DoH) для Ubuntu 24.04 на базе `AdGuardTeam/dnsproxy`**

[![OS](https://img.shields.io/badge/OS-Ubuntu%2024.04%20%7C%20systemd-E95420?style=flat-square&logo=ubuntu&logoColor=white)](#требования-и-совместимость)
[![Arch](https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-2ea44f?style=flat-square)](#требования-и-совместимость)
[![Engine](https://img.shields.io/badge/Engine-AdGuard%20dnsproxy-68BC71?style=flat-square&logo=adguard&logoColor=white)](https://github.com/AdGuardTeam/dnsproxy)
[![Shell](https://img.shields.io/badge/Written%20in-Bash-121011?style=flat-square&logo=gnu-bash&logoColor=white)](#)

*Полный аудит системы • 1–3 DoH-провайдера • IPv4-only friendly • Безопасный откат в один клик*

</div>

---

## ✨ Возможности

- 🌐 **Мульти-провайдерность (1–3 DoH-сервера)** — поддержка автобалансировки (`load_balance`) и строгого резервирования (`fallback`).
- 🔍 **Pre-flight аудит системы** — проверка ОС, `systemd`, архитектуры, стека IPv4/IPv6, занятости порта `53`, поддержки `chattr +i` и совместимости с уже установленными сервисами.
- 🧪 **Предварительный тест до переключения** — каждый выбранный DoH-адрес тестируется на временном порту `127.0.0.1:53535` до внесения изменений в системный DNS.
- 🔒 **Безопасность и изоляция** — `dnsproxy` слушает исключительно `127.0.0.1:53` (внешний доступ закрыт), запускается с systemd hardening (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`), а `/etc/resolv.conf` защищается от перезаписи флагом `chattr +i`.
- ⚡ **Оптимизация для IPv4-only VPS** — автоматическое определение рабочего сетевого стека, исключающее таймауты `curl` и `apt` при сломанном или отсутствующем IPv6.
- 🖥️ **Удобная CLI-утилита `mydns`** — устанавливается в `/usr/local/bin/mydns` и поддерживает как интерактивное меню, так и быстрые команды из терминала.
- ♻️ **Безопасный бэкап и полный откат** — сохраняет исходное состояние `systemd-resolved` и `/etc/resolv.conf` и позволяет вернуть всё в первоначальный вид одной командой.

---

## 🚀 Быстрая установка

Запустите установщик от имени `root`:

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh](https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh))
```

Если вы работаете под обычным пользователем с `sudo`:

```bash
sudo bash -c "$(curl -fsSL [https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh](https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh))"
```

> [!TIP]
> После установки скрипт автоматически создаст системную команду `mydns`. Повторно скачивать скрипт с GitHub не нужно — достаточно запускать `sudo mydns`.

---

## 📡 Поддерживаемые DoH-провайдеры

Во время установки или смены провайдеров можно выбрать **от 1 до 3** серверов:

| # | Провайдер | DoH Endpoint | Особенности |
| :-: | :--- | :--- | :--- |
| **1** | **Cloudflare** | `https://cloudflare-dns.com/dns-query` | ⚡ Максимальная скорость |
| **2** | **Quad9** | `https://dns.quad9.net/dns-query` | 🛡️ Защита от угроз, без логов |
| **3** | **Google Public DNS** | `https://dns.google/dns-query` | 🏛️ Высокая стабильность |
| **4** | **AdGuard (Default)** | `https://dns.adguard-dns.com/dns-query` | 🚫 Блокировка рекламы и трекеров |
| **5** | **AdGuard (Clean)** | `https://unfiltered.adguard-dns.com/dns-query` | 🧹 Без фильтрации |
| **6** | **Mullvad DNS** | `https://dns.mullvad.net/dns-query` | 🕵️ Фокус на приватность |
| **7** | **Custom DoH** | `https://...` | ⚙️ Любой свой сервер (NextDNS, ControlD и др.) |

### Режимы работы (при выборе 2–3 провайдеров)

- **`load_balance`** *(рекомендуется)* — `dnsproxy` сам выбирает самый быстрый живой сервер и мгновенно обходит недоступные.
- **`fallback`** — строгий приоритет: всегда используется провайдер #1, а резервные подключаются только при его сбое.

---

## 🛠️ Управление через `mydns` CLI

| Команда | Описание |
| :--- | :--- |
| `sudo mydns` | Открыть интерактивное меню управления |
| `sudo mydns install` | Запустить аудит системы и установку DoH DNS |
| `sudo mydns status` | Проверить статус сервиса, `/etc/resolv.conf` и выполнить тест DNS *(алиасы: `test`, `check`)* |
| `sudo mydns change` | Сменить DoH-провайдеров (1–3 шт.) и режим работы *(алиас: `providers`)* |
| `sudo mydns restart` | Перезапустить сервис `vps-doh` и проверить резолвинг |
| `sudo mydns logs` | Показать последние 30 строк журнала `vps-doh` |
| `sudo mydns update` | Обновить утилиту `mydns` до последней версии с GitHub |
| `sudo mydns rollback [-y]` | Полностью удалить DoH, `mydns` и вернуть стандартный DNS *(алиасы: `uninstall`, `remove`)* |
| `mydns help` | Показать встроенную справку |

---

## 🧩 Требования и совместимость

- **ОС:** оптимизировано для **Ubuntu 24.04 LTS** (работает на любой Linux-системе с `systemd`).
- **Архитектура:** `x86_64` (`amd64`) и `aarch64` (`arm64`).
- **Зависимости:** `curl`, `tar`, `iproute2` (`ss`), `dnsutils` (`dig`) — недостающие пакеты устанавливаются автоматически.

### Совместимость со стеком прокси и VPN

Скрипт автоматически проверяет наличие популярных сервисов и корректно сосуществует с ними:
- **Nginx** — полностью совместим, подхватывает системный DoH.
- **3x-ui (Xray)** — полностью совместим (работает через системный или внутренний DNS Xray).
- **telemt proxy** — полностью совместим (порт 53 не занимает).
- **Docker / Amnezia VPN** — контейнеры не используют хостовый `127.0.0.1` и продолжают работать через собственный DNS-стек без обрывов.

> [!WARNING]
> Если на порту `53` уже работает сторонний DNS-сервер (`dnsmasq`, `AdGuardHome`, `bind9`, `unbound`), аудит предупредит о конфликте. Штатный `systemd-resolved` останавливается и отключается автоматически.

---

## 🏗️ Архитектура и расположение файлов

<details>
<summary><b>📂 Показать структуру файлов и параметры запуска systemd</b></summary>

### Используемые пути

| Путь | Назначение |
| :--- | :--- |
| `/usr/local/bin/dnsproxy` | Исполняемый файл `AdGuardTeam/dnsproxy` |
| `/usr/local/bin/mydns` | Установленная CLI-утилита управления |
| `/etc/vps-doh/doh.env` | Текущая конфигурация (режим, названия и URL провайдеров) |
| `/etc/vps-doh/upstreams.txt` | Список основных DoH-серверов |
| `/etc/vps-doh/fallbacks.txt` | Список резервных серверов (создаётся в режиме `fallback`) |
| `/etc/systemd/system/vps-doh.service` | Unit-файл сервиса `systemd` |
| `/var/backups/vps-doh/` | Однократный бэкап исходного `/etc/resolv.conf` и статуса `systemd-resolved` |

### Параметры запуска `dnsproxy`

- **Прослушивание:** `127.0.0.1:53` (UDP/TCP)
- **Bootstrap DNS:** `1.1.1.1:53`, `9.9.9.9:53`, `8.8.8.8:53`
- **Кэш и защита:** `--cache --cache-optimistic --refuse-any`
- **Systemd Hardening:** `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `LimitNOFILE=65535`

</details>

---

## ♻️ Полный откат и удаление

Чтобы полностью удалить `dnsproxy`, сервис `vps-doh`, конфиги, утилиту `mydns` и вернуть исходный системный DNS (`systemd-resolved` и оригинальный `/etc/resolv.conf`):

```bash
sudo mydns rollback
```

Для запуска без интерактивного подтверждения:

```bash
sudo mydns rollback -y
```

> [!NOTE]
> Если после отката стандартный DNS по какой-либо причине не отвечает, скрипт автоматически пропишет временные резолверы `1.1.1.1` и `8.8.8.8`, чтобы сервер не потерял доступ к сети.

## 📄 Лицензия и ответственность

Перед использованием ознакомьтесь с лицензиями сторонних компонентов и правилами их применения в вашей юрисдикции.

Проект предоставляется «как есть». Администратор сервера самостоятельно отвечает за настройки доступа, безопасность учётных данных, соблюдение законодательства и последствия использования развёрнутой инфраструктуры.

---

<div align="center">

*Less manual work. More control over your server.*

</div>
