#!/usr/bin/env bash
# ==============================================================================
# Interactive System DoH (DNS-over-HTTPS) Manager for Ubuntu 24.04 VPS
# Uses AdGuardTeam/dnsproxy on 127.0.0.1:53 with full audit & safe rollback
# ==============================================================================

set -uo pipefail

# --- Константы и пути ---
readonly BIN_PATH="/usr/local/bin/dnsproxy"
readonly CONFIG_DIR="/etc/vps-doh"
readonly ENV_FILE="${CONFIG_DIR}/doh.env"
readonly BACKUP_DIR="/var/backups/vps-doh"
readonly SERVICE_NAME="vps-doh"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Утилиты вывода ---
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR ]${NC} $*"; }
header()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }

pause() {
    echo ""
    read -rp "Нажмите Enter для продолжения..." _
}

# --- Проверка прав root ---
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "Скрипт необходимо запускать от имени root (используйте sudo)."
        exit 1
    fi
}

# --- Определение архитектуры ---
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "unsupported" ;;
    esac
}

# --- Проверка наличия базовых утилит ---
ensure_dependencies() {
    local missing=()
    for cmd in curl tar ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v dig >/dev/null 2>&1; then
        missing+=("dnsutils")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Устанавливаем недостающие утилиты: ${missing[*]}..."
        apt-get update -qq && apt-get install -y -qq curl tar iproute2 dnsutils >/dev/null 2>&1 || {
            warn "Не удалось автоматически установить часть утилит, продолжаем с тем, что есть."
        }
    fi
}

# --- Аудит системы и совместимости ---
run_preflight_audit() {
    header "Аудит системы и совместимости компонентов"
    local has_blocker=0

    # 1. ОС и systemd
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
            ok "ОС: ${PRETTY_NAME}"
        else
            warn "Обнаружена ОС: ${PRETTY_NAME:-Unknown} (скрипт оптимизирован под Ubuntu 24.04, но будет работать на любой systemd-системе)."
        fi
    fi

    if ! pidof systemd >/dev/null 2>&1; then
        err "Systemd не обнаружен. Автозапуск сервиса невозможен."
        has_blocker=1
    else
        ok "Init-система: systemd активен."
    fi

    # 2. Архитектура
    local arch
    arch=$(detect_arch)
    if [[ "$arch" == "unsupported" ]]; then
        err "Неподдерживаемая архитектура процессора: $(uname -m)"
        has_blocker=1
    else
        ok "Архитектура: $(uname -m) (dnsproxy: linux-${arch})"
    fi

    # 3. Порт 53
    echo ""
    info "Проверка занятости порта 53 (TCP/UDP):"
    local port53_procs
    port53_procs=$(ss -tulnp 2>/dev/null | grep -E '(:53\s|:53$)' || true)
    if [[ -z "$port53_procs" ]]; then
        ok "Порт 53 свободен."
    else
        echo "$port53_procs" | sed 's/^/    /'
        if echo "$port53_procs" | grep -qvE '(systemd-resolve|dnsproxy)'; then
            warn "На порту 53 обнаружен сторонний DNS-сервер (не systemd-resolved и не dnsproxy)!"
            warn "Если это dnsmasq / AdGuardHome / bind9 / unbound — возникнет конфликт порта 53."
        else
            ok "Порт 53 занят штатным systemd-resolved (или уже установленным dnsproxy) — безопасно для переключения."
        fi
    fi

    # 4. Проверка установленных сервисов (Nginx, 3x-ui, telemt, Amnezia/Docker)
    echo ""
    info "Проверка совместимости с целевым стеком:"

    # Nginx
    if command -v nginx >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        ok "Nginx обнаружен: совместим (порт 53 не использует, подхватит системный DoH)."
    else
        info "Nginx: не установлен (последующая установка полностью совместима)."
    fi

    # 3x-ui / Xray
    if [[ -d /usr/local/x-ui ]] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        ok "3x-ui обнаружен: совместим (использует системный DNS либо внутренний DNS Xray)."
    else
        info "3x-ui: не установлен (последующая установка полностью совместима)."
    fi

    # telemt web proxy
    if systemctl list-unit-files 2>/dev/null | grep -qi 'telemt' || pgrep -fa 'telemt' >/dev/null 2>&1; then
        ok "telemt proxy обнаружен: совместим (порт 53 не использует)."
    else
        info "telemt proxy: не обнаружен (последующая установка полностью совместима)."
    fi

    # Docker / Amnezia VPN
    if command -v docker >/dev/null 2>&1; then
        local amnezia_cnt
        amnezia_cnt=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'amnezia' | wc -l || echo 0)
        if [[ "$amnezia_cnt" -gt 0 ]]; then
            ok "Docker + Amnezia VPN обнаружены (${amnezia_cnt} конт.): совместимы."
        else
            ok "Docker обнаружен: совместим."
        fi
        info "  Примечание для Docker/Amnezia: контейнеры не используют хостовый 127.0.0.1 и продолжат работать через свой DNS-стек без обрывов."
    else
        info "Docker / Amnezia VPN: не установлены (последующая установка полностью совместима)."
    fi

    # 5. Поддержка chattr +i (защита от перезаписи resolv.conf)
    echo ""
    local tmp_test="/tmp/.vps_doh_chattr_test"
    touch "$tmp_test"
    if chattr +i "$tmp_test" 2>/dev/null; then
        chattr -i "$tmp_test" 2>/dev/null || true
        rm -f "$tmp_test"
        ok "Файловая система поддерживает chattr +i (защита /etc/resolv.conf от DHCP/cloud-init)."
    else
        rm -f "$tmp_test"
        warn "Файловая система не поддерживает chattr +i (возможно, LXC/OpenVZ). Перезапись /etc/resolv.conf будет предотвращена отключением systemd-resolved."
    fi

    # 6. Проверка выхода в сеть по HTTPS
    if curl -fsSI --max-time 5 https://github.com >/dev/null 2>&1; then
        ok "Доступ в интернет по HTTPS (порт 443) работает."
    else
        err "Нет доступа к github.com по HTTPS (порт 443). Проверьте сеть или firewall."
        has_blocker=1
    fi

    return "$has_blocker"
}

# --- Скачивание последней версии AdGuardTeam/dnsproxy ---
install_dnsproxy_binary() {
    if [[ -x "$BIN_PATH" ]]; then
        local cur_ver
        cur_ver=$("$BIN_PATH" --version 2>&1 | head -n 1 || echo "unknown")
        ok "Бинарник dnsproxy уже установлен (${cur_ver})."
        read -rp "Переустановить/обновить до последней версии? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy]$ ]] && return 0
    fi

    local arch
    arch=$(detect_arch)
    info "Получаем ссылку на последний релиз AdGuardTeam/dnsproxy (linux-${arch})..."

    local download_url
    download_url=$(curl -fsSL "https://api.github.com/repos/AdGuardTeam/dnsproxy/releases/latest" \
        | grep -oE "https://github\.com/AdGuardTeam/dnsproxy/releases/download/[^\"]+dnsproxy-linux-${arch}-v[^\"]+\.tar\.gz" \
        | head -n 1)

    if [[ -z "$download_url" ]]; then
        err "Не удалось получить ссылку на релиз с GitHub API."
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    info "Скачиваем: ${download_url}"
    if ! curl -fsSL "$download_url" -o "${tmp_dir}/dnsproxy.tar.gz"; then
        err "Ошибка при скачивании архива."
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "${tmp_dir}/dnsproxy.tar.gz" -C "$tmp_dir"
    local extracted_bin
    extracted_bin=$(find "$tmp_dir" -type f -name "dnsproxy" | head -n 1)

    if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
        err "Бинарник dnsproxy не найден внутри архива."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Останавливаем сервис на время замены бинарника, если он уже работает
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && systemctl stop "$SERVICE_NAME"

    install -m 0755 "$extracted_bin" "$BIN_PATH"
    rm -rf "$tmp_dir"

    ok "Установлен dnsproxy: $("$BIN_PATH" --version 2>&1 | head -n 1)"
}

# --- Выбор провайдера DoH ---
select_doh_provider() {
    header "Выбор DoH DNS провайдера"
    echo "  1) Cloudflare         (https://cloudflare-dns.com/dns-query)        — максимальная скорость"
    echo "  2) Quad9              (https://dns.quad9.net/dns-query)             — защита от угроз, без логов"
    echo "  3) Google Public DNS  (https://dns.google/dns-query)                — высокая стабильность"
    echo "  4) AdGuard (Default)  (https://dns.adguard-dns.com/dns-query)       — с блокировкой рекламы"
    echo "  5) AdGuard (Clean)    (https://unfiltered.adguard-dns.com/dns-query)— без фильтрации"
    echo "  6) Mullvad DNS        (https://dns.mullvad.net/dns-query)           — фокус на приватность"
    echo "  7) Указать свой DoH адрес (например, NextDNS, ControlD или свой сервер)"
    echo ""

    while true; do
        read -rp "Выберите вариант [1-7]: " choice
        case "$choice" in
            1) SELECTED_NAME="Cloudflare";        SELECTED_URL="https://cloudflare-dns.com/dns-query"; break ;;
            2) SELECTED_NAME="Quad9";             SELECTED_URL="https://dns.quad9.net/dns-query"; break ;;
            3) SELECTED_NAME="Google Public DNS"; SELECTED_URL="https://dns.google/dns-query"; break ;;
            4) SELECTED_NAME="AdGuard Default";   SELECTED_URL="https://dns.adguard-dns.com/dns-query"; break ;;
            5) SELECTED_NAME="AdGuard Clean";     SELECTED_URL="https://unfiltered.adguard-dns.com/dns-query"; break ;;
            6) SELECTED_NAME="Mullvad DNS";       SELECTED_URL="https://dns.mullvad.net/dns-query"; break ;;
            7)
                echo ""
                read -rp "Введите полный DoH URL (начинается с https://): " custom_url
                custom_url="${custom_url// /}"
                if [[ "$custom_url" =~ ^https://.+ ]]; then
                    SELECTED_NAME="Custom DoH"
                    SELECTED_URL="$custom_url"
                    break
                else
                    err "Некорректный формат. URL должен начинаться с https:// (например: https://dns.nextdns.io/abc123)."
                fi
                ;;
            *) err "Введите число от 1 до 7." ;;
        esac
    done

    ok "Выбран провайдер: ${SELECTED_NAME} (${SELECTED_URL})"
}

# --- Предварительный тест выбранного DoH до переключения системы ---
pretest_doh_upstream() {
    local url="$1"
    info "Предварительный тест DoH-сервера ${url} на временном порту 53535..."

    "$BIN_PATH" -l 127.0.0.1 -p 53535 -u "$url" -b 1.1.1.1:53 -b 9.9.9.9:53 >/dev/null 2>&1 &
    local test_pid=$!
    sleep 1

    local test_ok=0
    if command -v dig >/dev/null 2>&1; then
        local res
        res=$(dig @127.0.0.1 -p 53535 cloudflare.com +short +time=4 +tries=1 2>/dev/null | head -n 1)
        if [[ -n "$res" && ! "$res" =~ ^\; ]]; then
            ok "Тестовый DoH-запрос успешен (cloudflare.com -> ${res})."
            test_ok=1
        fi
    else
        # Запасная проверка доступности HTTPS-эндпоинта, если dig не установлен
        if curl -fsS --max-time 5 -o /dev/null "${url}?name=cloudflare.com&type=A" \
           -H "accept: application/dns-json" 2>/dev/null || curl -sI --max-time 5 "$url" >/dev/null 2>&1; then
            ok "DoH-сервер отвечает по HTTPS."
            test_ok=1
        fi
    fi

    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true

    if [[ "$test_ok" -ne 1 ]]; then
        err "Выбранный DoH-сервер (${url}) не ответил на тестовый запрос!"
        return 1
    fi
    return 0
}

# --- Создание бэкапа исходных настроек (выполняется только один раз) ---
backup_original_state() {
    if [[ -f "${BACKUP_DIR}/backup.done" ]]; then
        info "Резервная копия исходных настроек уже существует в ${BACKUP_DIR}."
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    # Статус systemd-resolved
    systemctl is-active --quiet systemd-resolved 2>/dev/null && echo "yes" > "${BACKUP_DIR}/resolved.was_active" || echo "no" > "${BACKUP_DIR}/resolved.was_active"
    systemctl is-enabled --quiet systemd-resolved 2>/dev/null && echo "yes" > "${BACKUP_DIR}/resolved.was_enabled" || echo "no" > "${BACKUP_DIR}/resolved.was_enabled"

    # Исходный /etc/resolv.conf
    if [[ -L /etc/resolv.conf ]]; then
        echo "symlink" > "${BACKUP_DIR}/resolv.type"
        readlink /etc/resolv.conf > "${BACKUP_DIR}/resolv.target"
    elif [[ -f /etc/resolv.conf ]]; then
        echo "file" > "${BACKUP_DIR}/resolv.type"
        cp -a /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak"
    else
        echo "none" > "${BACKUP_DIR}/resolv.type"
    fi

    date -Iseconds > "${BACKUP_DIR}/backup.done"
    ok "Исходные настройки DNS сохранены в ${BACKUP_DIR}."
}

# --- Применение конфигурации и запуск сервиса ---
apply_doh_config() {
    local name="$1"
    local url="$2"

    mkdir -p "$CONFIG_DIR"
    cat > "$ENV_FILE" <<EOF
DOH_NAME="${name}"
DOH_UPSTREAM="${url}"
EOF

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=System DNS-over-HTTPS Proxy (AdGuardTeam/dnsproxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH} -l 127.0.0.1 -p 53 -u \${DOH_UPSTREAM} -b 1.1.1.1:53 -b 9.9.9.9:53 -b 8.8.8.8:53 --cache --cache-optimistic --refuse-any
Restart=always
RestartSec=2
LimitNOFILE=65535

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # Отключаем systemd-resolved, чтобы освободить порт 53
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        info "Останавливаем и отключаем systemd-resolved..."
        systemctl stop systemd-resolved
    fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
    fi

    # Перезагружаем systemd и запускаем vps-doh
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1

    # Настраиваем /etc/resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
# Managed by vps-doh (${name})
nameserver 127.0.0.1
options edns0 trust-ad
EOF

    # Защищаем от перезаписи (DHCP / netplan / cloud-init)
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        ok "Файл /etc/resolv.conf защищён от перезаписи (chattr +i)."
    else
        warn "Не удалось установить chattr +i на /etc/resolv.conf."
    fi
}

# --- Проверка работы DoH ---
verify_doh() {
    header "Проверка работы DoH DNS"
    local failed=0

    # 1. Сервис
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Сервис ${SERVICE_NAME}: активен (автозапуск включён: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo no))."
    else
        err "Сервис ${SERVICE_NAME} НЕ запущен!"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
        failed=1
    fi

    # 2. Порт 53
    if ss -tulnp 2>/dev/null | grep -E '127\.0\.0\.1:53\b' | grep -q 'dnsproxy'; then
        ok "Порт 127.0.0.1:53 слушает dnsproxy (публичный доступ извне закрыт)."
    else
        err "dnsproxy не слушает 127.0.0.1:53!"
        failed=1
    fi

    # 3. Текущий провайдер и /etc/resolv.conf
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        info "Текущий DoH upstream: ${DOH_NAME:-unknown} -> ${DOH_UPSTREAM:-unknown}"
    fi
    info "Содержимое /etc/resolv.conf:"
    grep -v '^#' /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
    if command -v lsattr >/dev/null 2>&1; then
        local attrs
        attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' || true)
        [[ "$attrs" == *"i"* ]] && ok "Защита /etc/resolv.conf от слёта: активна (+i)." || warn "Флаг +i на /etc/resolv.conf не установлен."
    fi

    # 4. Реальные DNS-запросы
    echo ""
    info "Тест разрешения имён через системный DNS:"
    local domains=("cloudflare.com" "github.com" "google.com")
    for d in "${domains[@]}"; do
        if command -v dig >/dev/null 2>&1; then
            local out time_ms ip
            out=$(dig +time=4 +tries=1 "$d" 2>/dev/null)
            ip=$(echo "$out" | awk '/^[^;].*\sIN\sA\s/ {print $5; exit}')
            time_ms=$(echo "$out" | awk '/Query time:/ {print $4}')
            if [[ -n "$ip" ]]; then
                ok "  ${d} -> ${ip} (${time_ms:-?} ms)"
            else
                err "  Не удалось разрешить ${d}!"
                failed=1
            fi
        else
            local ip
            ip=$(getent ahosts "$d" 2>/dev/null | awk '{print $1; exit}')
            if [[ -n "$ip" ]]; then
                ok "  ${d} -> ${ip}"
            else
                err "  Не удалось разрешить ${d}!"
                failed=1
            fi
        fi
    done

    return "$failed"
}

# --- Откат к стандартным настройкам ---
rollback_to_default() {
    header "Откат DNS к стандартным настройкам"

    if [[ ! -f "${BACKUP_DIR}/backup.done" ]] && ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        warn "Установленный vps-doh и бэкап не найдены. Откатывать нечего."
        return 0
    fi

    info "Останавливаем и удаляем сервис ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    info "Удаляем бинарник и конфигурацию..."
    rm -f "$BIN_PATH"
    rm -rf "$CONFIG_DIR"

    info "Восстанавливаем /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf

    if [[ -f "${BACKUP_DIR}/resolv.type" ]]; then
        local rtype
        rtype=$(cat "${BACKUP_DIR}/resolv.type")
        case "$rtype" in
            symlink)
                local target
                target=$(cat "${BACKUP_DIR}/resolv.target")
                ln -sf "$target" /etc/resolv.conf
                ok "Восстановлен симлинк /etc/resolv.conf -> ${target}"
                ;;
            file)
                cp -a "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf
                ok "Восстановлен исходный файл /etc/resolv.conf"
                ;;
            *)
                ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                ;;
        esac
    else
        # Стандартный симлинк для Ubuntu 24.04
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    # Восстанавливаем systemd-resolved
    local restore_resolved="yes"
    if [[ -f "${BACKUP_DIR}/resolved.was_active" ]]; then
        restore_resolved=$(cat "${BACKUP_DIR}/resolved.was_active")
    fi

    if [[ "$restore_resolved" == "yes" ]]; then
        info "Включаем и запускаем systemd-resolved..."
        systemctl enable systemd-resolved >/dev/null 2>&1 || true
        systemctl restart systemd-resolved
        sleep 1
        if systemctl is-active --quiet systemd-resolved; then
            ok "systemd-resolved снова активен."
        else
            warn "Не удалось запустить systemd-resolved."
        fi
    fi

    rm -rf "$BACKUP_DIR"

    # Проверка DNS после отката
    if getent ahosts cloudflare.com >/dev/null 2>&1; then
        ok "Системный DNS после отката работает исправно."
    else
        warn "DNS после отката не отвечает! Временно прописываем 1.1.1.1 и 8.8.8.8 в /etc/resolv.conf..."
        rm -f /etc/resolv.conf
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    fi
}

# --- Полный сценарий установки ---
action_install() {
    ensure_dependencies
    if ! run_preflight_audit; then
        err "Обнаружены критические проблемы при проверке системы. Установка прервана."
        return 1
    fi

    echo ""
    read -rp "Продолжить установку и настройку DoH? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0

    install_dnsproxy_binary || return 1
    select_doh_provider

    if ! pretest_doh_upstream "$SELECTED_URL"; then
        read -rp "Тест не прошёл. Попробовать другой DoH провайдер? [Y/n]: " retry
        if [[ ! "$retry" =~ ^[Nn]$ ]]; then
            select_doh_provider
            pretest_doh_upstream "$SELECTED_URL" || { err "Повторный тест не прошёл. Отмена."; return 1; }
        else
            return 1
        fi
    fi

    backup_original_state
    apply_doh_config "$SELECTED_NAME" "$SELECTED_URL"

    if ! verify_doh; then
        err "После применения настроек DNS работает некорректно!"
        read -rp "Выполнить автоматический откат к исходным настройкам? [Y/n]: " do_rb
        if [[ ! "$do_rb" =~ ^[Nn]$ ]]; then
            rollback_to_default
        fi
    else
        echo ""
        ok "Готово! Системный DoH DNS (${SELECTED_NAME}) успешно настроен и закреплён."
    fi
}

# --- Быстрая смена провайдера ---
action_change_provider() {
    if [[ ! -x "$BIN_PATH" ]]; then
        warn "DoH ещё не установлен. Запускаем полную установку..."
        action_install
        return
    fi

    select_doh_provider
    if ! pretest_doh_upstream "$SELECTED_URL"; then
        err "Новый DoH-сервер не прошёл тест. Изменения не применены."
        return 1
    fi

    apply_doh_config "$SELECTED_NAME" "$SELECTED_URL"
    verify_doh
}

# --- Главное меню ---
main_menu() {
    require_root
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}${BOLD}====================================================${NC}"
        echo -e "${CYAN}${BOLD}   VPS System DoH DNS Manager (Ubuntu 24.04)        ${NC}"
        echo -e "${CYAN}${BOLD}====================================================${NC}"

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ -f "$ENV_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$ENV_FILE"
            echo -e " Статус: ${GREEN}АКТИВЕН${NC} | Провайдер: ${BOLD}${DOH_NAME:-?}${NC} (${DOH_UPSTREAM:-?})"
        else
            echo -e " Статус: ${YELLOW}НЕ УСТАНОВЛЕН (используется системный DNS)${NC}"
        fi
        echo "----------------------------------------------------"
        echo "  1) Установить и настроить DoH DNS (с аудитом)"
        echo "  2) Проверить статус и работу DNS"
        echo "  3) Сменить DoH провайдера"
        echo "  4) Откатить всё к стандартным настройкам (Удалить)"
        echo "  0) Выход"
        echo "----------------------------------------------------"
        read -rp "Выберите действие [0-4]: " menu_choice

        case "$menu_choice" in
            1) action_install; pause ;;
            2) verify_doh; pause ;;
            3) action_change_provider; pause ;;
            4)
                echo ""
                read -rp "Вы уверены, что хотите полностью удалить DoH и вернуть стандартный DNS? [y/N]: " rb_ans
                [[ "$rb_ans" =~ ^[Yy]$ ]] && rollback_to_default
                pause
                ;;
            0) exit 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

main_menu
