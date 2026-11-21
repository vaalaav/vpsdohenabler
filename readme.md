# vpsdohenabler (`mydns`)

![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)
![Systemd](https://img.shields.io/badge/Init-systemd-blue)
![Arch](https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-lightgrey)
![Engine](https://img.shields.io/badge/Engine-AdGuardTeam%2Fdnsproxy-68BC71)

Интерактивный менеджер системного **DNS-over-HTTPS (DoH)** и CLI-утилита **`mydns`** для VPS (оптимизировано под **Ubuntu 24.04**, совместимо с другими systemd-дистрибутивами).

Скрипт разворачивает локальный шифрованный DNS-прокси [AdGuardTeam/dnsproxy](https://github.com/AdGuardTeam/dnsproxy) на `127.0.0.1:53`, проводит предварительный аудит системы, тестирует выбранные DoH-серверы до применения настроек и обеспечивает безопасный откат к исходной конфигурации.

---

## Основные возможности

- **Выбор от 1 до 3 DoH-провайдеров**: поддержка популярных публичных серверов и произвольных URL (NextDNS, ControlD, собственный DoH-сервер).
- **Два режима отказоустойчивости** (при выборе 2–3 провайдеров):
  - `load_balance` *(рекомендуется)* — автоматическая балансировка с выбором самого быстрого живого сервера и мгновенным обходом недоступных.
  - `fallback` — строгий приоритет: всегда используется провайдер #1, а #2 и #3 подключаются только при его сбое.
- **Предварительное тестирование**: перед изменением системного DNS каждый выбранный DoH-сервер проверяется на временном порту `127.0.0.1:53535`.
- **Автоопределение IPv4 / IPv6**: корректная работа на **IPv4-only VPS** (автоматический выбор `-4` для `curl` и `Acquire::ForceIPv4=true` для `apt`, исключение таймаутов на сломанном IPv6).
- **Аудит совместимости**: проверка ОС, архитектуры, занятости порта 53, поддержки `chattr +i` и совместимости с популярным стеком VPS (**Nginx**, **3x-ui**, **telemt proxy**, **Docker / Amnezia VPN**).
- **Безопасность и защита от слёта**:
  - `dnsproxy` слушает строго локальный интерфейс `127.0.0.1:53` (закрыт от внешнего мира).
  - Включено кэширование (`--cache --cache-optimistic`) и защита от DNS amplification (`--refuse-any`).
  - Systemd-сервис изолирован (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `CAP_NET_BIND_SERVICE`).
  - `/etc/resolv.conf` защищается атрибутом `chattr +i` от перезаписи со стороны DHCP и `cloud-init`.
- **Полный бэкап и безопасный откат**: сохранение исходного состояния `systemd-resolved` и `/etc/resolv.conf` с возможностью полного удаления и восстановления одной командой.

---

## Быстрая установка

Запустите установщик от имени `root`:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh)
```

> **Примечание:** если на сервере сломан IPv6, добавьте флаг `-4`:
> ```bash
> sudo bash <(curl -4 -fsSL https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh)
> ```

В процессе установки скрипт автоматически установит глобальную CLI-утилиту **`mydns`** в `/usr/local/bin/mydns`. После этого вы сможете управлять DoH из любой директории командой `sudo mydns`.

---

## Поддерживаемые DoH-провайдеры

| # | Провайдер | DoH URL | Особенности |
|---|---|---|---|
| 1 | **Cloudflare** | `https://cloudflare-dns.com/dns-query` | Максимальная скорость |
| 2 | **Quad9** | `https://dns.quad9.net/dns-query` | Защита от угроз, без логов |
| 3 | **Google Public DNS** | `https://dns.google/dns-query` | Высокая стабильность |
| 4 | **AdGuard (Default)** | `https://dns.adguard-dns.com/dns-query` | С блокировкой рекламы и трекеров |
| 5 | **AdGuard (Clean)** | `https://unfiltered.adguard-dns.com/dns-query` | Без фильтрации |
| 6 | **Mullvad DNS** | `https://dns.mullvad.net/dns-query` | Фокус на приватность |
| 7 | **Свой DoH URL** | `https://...` | NextDNS, ControlD или собственный сервер |

---

## Использование CLI (`mydns`)

Запуск без аргументов открывает **интерактивное меню**:

```bash
sudo mydns
```

Также доступны прямые команды CLI:

| Команда | Описание |
|---|---|
| `sudo mydns` | Открыть интерактивное меню управления |
| `sudo mydns install` | Провести аудит системы и установить DoH DNS (1–3 провайдера) |
| `sudo mydns status` *(или `test`, `check`)* | Проверить статус сервиса, `/etc/resolv.conf`, флаг `+i` и замерить скорость DNS-запросов |
| `sudo mydns change` *(или `providers`)* | Быстро сменить DoH-провайдеров и режим работы (`load_balance` / `fallback`) |
| `sudo mydns restart` | Перезапустить сервис `vps-doh` и выполнить проверку DNS |
| `sudo mydns logs` | Показать последние 30 строк журнала `journalctl` для `vps-doh` |
| `sudo mydns update` | Обновить утилиту `mydns` до последней версии из GitHub (с проверкой синтаксиса) |
| `sudo mydns rollback [-y]` *(или `uninstall`, `remove`)* | Полностью удалить DoH, `mydns` и вернуть исходные настройки DNS (`-y` — без подтверждения) |
| `mydns help` | Показать справку по командам |

---

## Совместимость со стеком VPS

- **Nginx / 3x-ui / telemt proxy**: полностью совместимы, порт 53 не конфликтует, приложения автоматически используют системный DoH (либо собственный DNS в Xray).
- **Docker / Amnezia VPN**: контейнеры не обращаются к хостовому `127.0.0.1` и продолжают работать через свой сетевой стек без обрывов.
- **Сторонние локальные DNS-серверы** (`dnsmasq`, `AdGuardHome`, `bind9`, `unbound`): если порт 53 уже занят сторонним сервисом, аудит предупредит о возможном конфликте до начала установки.
- **Контейнерная виртуализация (LXC / OpenVZ)**: если файловая система не поддерживает `chattr +i`, скрипт автоматически переключится на защиту `/etc/resolv.conf` через отключение `systemd-resolved`.

---

## Структура файлов на сервере

| Путь | Назначение |
|---|---|
| `/usr/local/bin/dnsproxy` | Бинарный файл `AdGuardTeam/dnsproxy` |
| `/usr/local/bin/mydns` | Установленная CLI-утилита управления |
| `/etc/systemd/system/vps-doh.service` | Юнит-файл systemd |
| `/etc/vps-doh/doh.env` | Метаданные текущей конфигурации (режим, имена и URL провайдеров) |
| `/etc/vps-doh/upstreams.txt` | Список основных DoH-серверов |
| `/etc/vps-doh/fallbacks.txt` | Список резервных DoH-серверов (в режиме `fallback`) |
| `/var/backups/vps-doh/` | Резервная копия исходного `/etc/resolv.conf` и статуса `systemd-resolved` |

---

## Удаление и откат

Чтобы полностью удалить `dnsproxy`, конфигурацию и утилиту `mydns`, вернув стандартный системный DNS (`systemd-resolved` и исходный `/etc/resolv.conf`):

```bash
sudo mydns rollback
```

Или без интерактивного подтверждения:

```bash
sudo mydns rollback -y
```

> Если после отката стандартный DNS по какой-либо причине не отвечает, скрипт автоматически пропишет резервные серверы `1.1.1.1` и `8.8.8.8` в `/etc/resolv.conf`, чтобы сервер не потерял доступ к сети.

---

## Требования

- **ОС**: Ubuntu 24.04 (или другой Linux-дистрибутив с `systemd`).
- **Архитектура**: `x86_64` (`amd64`) или `aarch64` (`arm64`).
- **Права**: `root` / `sudo`.
- **Зависимости**: `curl`, `tar`, `iproute2` (`ss`), `dnsutils` (`dig`) — при отсутствии устанавливаются автоматически.