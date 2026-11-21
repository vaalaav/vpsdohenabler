#!/usr/bin/env bash
# ==============================================================================
# Interactive System DoH (DNS-over-HTTPS) Manager & `mydns` CLI for Ubuntu 24.04
# Uses AdGuardTeam/dnsproxy on 127.0.0.1:53 with full audit & safe rollback
# Supports 1-3 DoH providers (load_balance / strict fallback) & IPv4-only VPS
# ==============================================================================

set -uo pipefail

# --- Константы и пути ---
readonly BIN_PATH="/usr/local/bin/dnsproxy"
readonly MYDNS_BIN="/usr/local/bin/mydns"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/vaalaav/vpsdohenabler/main/vps-doh.sh"
readonly CONFIG_DIR="/etc/vps-doh"
readonly ENV_FILE="${CONFIG_DIR}/doh.env"
readonly UPSTREAMS_FILE="${CONFIG_DIR}/upstreams.txt"
readonly FALLBACKS_FILE="${CONFIG_DIR}/fallbacks.txt"
readonly BACKUP_DIR="/var/backups/vps-doh"
readonly SERVICE_NAME="vps-doh"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Сетевой стек (определяется автоматически)
CURL_IP_FLAG=""
HAS_IPV4=0
HAS_IPV6=0

# Выбранные провайдеры (от 1 до 3)
SELECTED_NAMES=()
SELECTED_URLS=()
SELECTED_MODE="single"

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
        err "Скрипт необходимо запускать от имени root (используйте: sudo mydns)."
        exit 1
    fi
}

# --- Справка по CLI ---
show_help() {
    cat <<EOF
mydns — CLI-утилита управления системным DoH DNS (Ubuntu 24.04)

Использование:
  sudo mydns                  Открыть интерактивное меню (как в установщике)
  sudo mydns install          Запустить аудит и установку DoH DNS (1–3 провайдера)
  sudo mydns status           Проверить статус сервиса, resolv.conf и тест DNS
  sudo mydns change           Сменить DoH-провайдеров (1–3 шт.) и режим работы
  sudo mydns restart          Перезапустить сервис ${SERVICE_NAME} и проверить DNS
  sudo mydns logs             Показать последние логи сервиса ${SERVICE_NAME}
  sudo mydns update           Обновить утилиту mydns из GitHub
  sudo mydns rollback [-y]    Откатить DNS к стандартным настройкам и удалить mydns
  mydns help                  Показать эту справку
EOF
}

# --- Определение архитектуры ---
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "unsupported" ;;
    esac
}

# --- Определение рабочего сетевого стека (IPv4 / IPv6) ---
detect_network_stack() {
    HAS_IPV4=0
    HAS_IPV6=0
    CURL_IP_FLAG=""

    if curl -4 -fsSI --max-time 5 https://github.com >/dev/null 2>&1 || \
       curl -4 -fsSI --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
        HAS_IPV4=1
    fi

    if curl -6 -fsSI --max-time 4 https://cloudflare.com >/dev/null 2>&1; then
        HAS_IPV6=1
    fi

    # Предпочитаем IPv4 для curl, чтобы исключить таймауты на сломанном IPv6
    if [[ "$HAS_IPV4" -eq 1 ]]; then
        CURL_IP_FLAG="-4"
    elif [[ "$HAS_IPV6" -eq 1 ]]; then
        CURL_IP_FLAG="-6"
    fi
}

# Обёртка над curl с учётом доступного стека
safe_curl() {
    if [[ -n "$CURL_IP_FLAG" ]]; then
        curl "$CURL_IP_FLAG" "$@"
    else
        curl "$@"
    fi
}

# --- Установка CLI-утилиты mydns в /usr/local/bin/mydns ---
install_mydns_cli() {
    local self_path="${BASH_SOURCE[0]:-$0}"
    local resolved_self=""
    resolved_self=$(readlink -f "$self_path" 2>/dev/null || echo "$self_path")

    # Если уже запущены прямо из /usr/local/bin/mydns — просто проверяем права
    if [[ "$resolved_self" == "$MYDNS_BIN" ]]; then
        chmod 0755 "$MYDNS_BIN" 2>/dev/null || true
        ok "CLI-утилита mydns уже установлена (${MYDNS_BIN})."
        return 0
    fi

    # Если запущены из обычного локального файла — копируем себя
    if [[ -f "$self_path" && "$self_path" != /dev/fd/* && "$self_path" != /proc/*/fd/* ]]; then
        if install -m 0755 "$self_path" "$MYDNS_BIN"; then
            ok "CLI-утилита mydns установлена (${MYDNS_BIN}). Запуск: sudo mydns"
            return 0
        fi
    fi

    # Если запущены через process substitution (bash <(curl ...)) — скачиваем с GitHub
    [[ -z "$CURL_IP_FLAG" ]] && detect_network_stack
    info "Устанавливаем CLI-утилиту mydns из репозитория..."
    local tmp_script
    tmp_script=$(mktemp)
    if safe_curl -fsSL --max-time 20 "$REPO_RAW_URL" -o "$tmp_script" && bash -n "$tmp_script" 2>/dev/null; then
        install -m 0755 "$tmp_script" "$MYDNS_BIN"
        rm -f "$tmp_script"
        ok "CLI-утилита mydns установлена (${MYDNS_BIN}). Запуск: sudo mydns"
        return 0
    else
        rm -f "$tmp_script"
        warn "Не удалось автоматически установить ${MYDNS_BIN} из GitHub."
        return 1
    fi
}

# --- Обновление утилиты mydns из GitHub ---
action_update_self() {
    header "Обновление CLI-утилиты mydns"
    detect_network_stack

    local tmp_script
    tmp_script=$(mktemp)
    info "Скачиваем свежую версию с GitHub..."
    if ! safe_curl -fsSL --max-time 20 "$REPO_RAW_URL" -o "$tmp_script"; then
        err "Не удалось скачать обновление с ${REPO_RAW_URL}"
        rm -f "$tmp_script"
        return 1
    fi

    if ! head -n 1 "$tmp_script" | grep -q '^#!/usr/bin/env bash' || ! bash -n "$tmp_script" 2>/dev/null; then
        err "Скачанный файл повреждён или не прошёл проверку синтаксиса Bash."
        rm -f "$tmp_script"
        return 1
    fi

    install -m 0755 "$tmp_script" "$MYDNS_BIN"
    # Если раньше ставили как /usr/local/bin/vps-doh, обновим и его
    if [[ -f /usr/local/bin/vps-doh ]]; then
        install -m 0755 "$tmp_script" /usr/local/bin/vps-doh
    fi
    rm -f "$tmp_script"

    ok "Утилита mydns успешно обновлена (${MYDNS_BIN})."
    info "Перезапустите утилиту командой: sudo mydns"
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
        local apt_opts=()
        [[ "$HAS_IPV6" -eq 0 && "$HAS_IPV4" -eq 1 ]] && apt_opts=(-o Acquire::ForceIPv4=true)
        apt-get "${apt_opts[@]}" update -qq && apt-get "${apt_opts[@]}" install -y -qq curl tar iproute2 dnsutils >/dev/null 2>&1 || {
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

    # 3. Сетевой стек (IPv4 / IPv6)
    echo ""
    info "Проверка сетевого стека (IPv4 / IPv6):"
    detect_network_stack
    if [[ "$HAS_IPV4" -eq 1 ]]; then
        ok "IPv4: работает (используется как основной стек для загрузки и bootstrap DNS)."
    else
        warn "IPv4: недоступен."
    fi

    if [[ "$HAS_IPV6" -eq 1 ]]; then
        ok "IPv6: работает."
    else
        info "IPv6: отсутствует или недоступен — скрипт автоматически работает в режиме IPv4-only."
    fi

    if [[ "$HAS_IPV4" -eq 0 && "$HAS_IPV6" -eq 0 ]]; then
        err "Нет выхода в интернет по HTTPS (порт 443). Проверьте сеть или firewall."
        has_blocker=1
    fi

    # 4. Порт 53
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

    # 5. Проверка установленных сервисов (Nginx, 3x-ui, telemt, Amnezia/Docker)
    echo ""
    info "Проверка совместимости с целевым стеком:"

    if command -v nginx >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        ok "Nginx обнаружен: совместим (порт 53 не использует, подхватит системный DoH)."
    else
        info "Nginx: не установлен (последующая установка полностью совместима)."
    fi

    if [[ -d /usr/local/x-ui ]] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        ok "3x-ui обнаружен: совместим (использует системный DNS либо внутренний DNS Xray)."
    else
        info "3x-ui: не установлен (последующая установка полностью совместима)."
    fi

    if systemctl list-unit-files 2>/dev/null | grep -qi 'telemt' || pgrep -fa 'telemt' >/dev/null 2>&1; then
        ok "telemt proxy обнаружен: совместим (порт 53 не использует)."
    else
        info "telemt proxy: не обнаружен (последующая установка полностью совместима)."
    fi

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

    # 6. Поддержка chattr +i (защита от перезаписи resolv.conf)
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

    [[ -z "$CURL_IP_FLAG" ]] && detect_network_stack

    local arch
    arch=$(detect_arch)
    info "Получаем ссылку на последний релиз AdGuardTeam/dnsproxy (linux-${arch})..."

    local download_url=""
    local latest_tag=""

    # Способ 1: через HTTP-редирект github.com (без лимитов GitHub API)
    local redirect_url
    redirect_url=$(safe_curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 15 \
        "https://github.com/AdGuardTeam/dnsproxy/releases/latest" 2>/dev/null || true)

    if [[ "$redirect_url" =~ /tag/(v[^/[:space:]]+)$ ]]; then
        latest_tag="${BASH_REMATCH[1]}"
        download_url="https://github.com/AdGuardTeam/dnsproxy/releases/download/${latest_tag}/dnsproxy-linux-${arch}-${latest_tag}.tar.gz"
    fi

    # Способ 2 (резервный): через GitHub API с User-Agent
    if [[ -z "$download_url" ]]; then
        warn "Редирект не сработал, пробуем через GitHub API..."
        download_url=$(safe_curl -fsSL --max-time 15 -H "User-Agent: vps-doh-installer" \
            "https://api.github.com/repos/AdGuardTeam/dnsproxy/releases/latest" 2>/dev/null \
            | grep -oE "https://github\.com/AdGuardTeam/dnsproxy/releases/download/[^\"]+dnsproxy-linux-${arch}-v[^\"]+\.tar\.gz" \
            | head -n 1 || true)
    fi

    if [[ -z "$download_url" ]]; then
        err "Не удалось получить ссылку на релиз AdGuardTeam/dnsproxy."
        info "Проверьте доступ вручную: curl -4 -I https://github.com/AdGuardTeam/dnsproxy/releases/latest"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    info "Скачиваем: ${download_url}"
    if ! safe_curl -fsSL --max-time 60 "$download_url" -o "${tmp_dir}/dnsproxy.tar.gz"; then
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

    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && systemctl stop "$SERVICE_NAME"

    install -m 0755 "$extracted_bin" "$BIN_PATH"
    rm -rf "$tmp_dir"

    ok "Установлен dnsproxy: $("$BIN_PATH" --version 2>&1 | head -n 1)"
}

# --- Проверка дубликата URL ---
is_url_selected() {
    local check_url="$1"
    local u
    for u in "${SELECTED_URLS[@]+"${SELECTED_URLS[@]}"}"; do
        [[ "$u" == "$check_url" ]] && return 0
    done
    return 1
}

# --- Выбор от 1 до 3 провайдеров DoH ---
select_doh_providers() {
    SELECTED_NAMES=()
    SELECTED_URLS=()
    SELECTED_MODE="single"

    local slot
    for slot in 1 2 3; do
        header "Выбор DoH DNS провайдера (${slot} из 3)"

        if [[ ${#SELECTED_URLS[@]} -gt 0 ]]; then
            info "Уже выбрано:"
            local idx
            for idx in "${!SELECTED_URLS[@]}"; do
                echo -e "    $((idx + 1))) ${BOLD}${SELECTED_NAMES[$idx]}${NC} (${SELECTED_URLS[$idx]})"
            done
            echo ""
        fi

        echo "  1) Cloudflare         (https://cloudflare-dns.com/dns-query)        — максимальная скорость"
        echo "  2) Quad9              (https://dns.quad9.net/dns-query)             — защита от угроз, без логов"
        echo "  3) Google Public DNS  (https://dns.google/dns-query)                — высокая стабильность"
        echo "  4) AdGuard (Default)  (https://dns.adguard-dns.com/dns-query)       — с блокировкой рекламы"
        echo "  5) AdGuard (Clean)    (https://unfiltered.adguard-dns.com/dns-query)— без фильтрации"
        echo "  6) Mullvad DNS        (https://dns.mullvad.net/dns-query)           — фокус на приватность"
        echo "  7) Указать свой DoH адрес (например, NextDNS, ControlD или свой сервер)"
        if [[ "$slot" -gt 1 ]]; then
            echo "  0) Завершить выбор (оставить выбранных: ${#SELECTED_URLS[@]})"
        fi
        echo ""

        local picked_name=""
        local picked_url=""
        local done_selecting=0

        while true; do
            if [[ "$slot" -eq 1 ]]; then
                read -rp "Выберите основной провайдер #1 [1-7]: " choice
            else
                read -rp "Выберите резервный провайдер #${slot} [0-7] (0 = хватит): " choice
            fi

            if [[ "$slot" -gt 1 && ( "$choice" == "0" || -z "$choice" ) ]]; then
                done_selecting=1
                break
            fi

            case "$choice" in
                1) picked_name="Cloudflare";        picked_url="https://cloudflare-dns.com/dns-query" ;;
                2) picked_name="Quad9";             picked_url="https://dns.quad9.net/dns-query" ;;
                3) picked_name="Google Public DNS"; picked_url="https://dns.google/dns-query" ;;
                4) picked_name="AdGuard Default";   picked_url="https://dns.adguard-dns.com/dns-query" ;;
                5) picked_name="AdGuard Clean";     picked_url="https://unfiltered.adguard-dns.com/dns-query" ;;
                6) picked_name="Mullvad DNS";       picked_url="https://dns.mullvad.net/dns-query" ;;
                7)
                    echo ""
                    read -rp "Введите полный DoH URL (начинается с https://): " custom_url
                    custom_url="${custom_url// /}"
                    if [[ "$custom_url" =~ ^https://.+ ]]; then
                        picked_name="Custom DoH #${slot}"
                        picked_url="$custom_url"
                    else
                        err "Некорректный формат. URL должен начинаться с https:// (например: https://dns.nextdns.io/abc123)."
                        continue
                    fi
                    ;;
                *)
                    err "Некорректный ввод."
                    continue
                    ;;
            esac

            if is_url_selected "$picked_url"; then
                warn "Этот DoH-адрес уже добавлен в список. Выберите другой."
                continue
            fi

            SELECTED_NAMES+=("$picked_name")
            SELECTED_URLS+=("$picked_url")
            ok "Добавлен провайдер #${slot}: ${picked_name} (${picked_url})"
            break
        done

        [[ "$done_selecting" -eq 1 ]] && break
    done

    # Выбор режима отказоустойчивости при выборе 2 или 3 провайдеров
    if [[ ${#SELECTED_URLS[@]} -gt 1 ]]; then
        echo ""
        header "Режим переключения между провайдерами"
        echo "  1) Автобалансировка и быстрое переключение (load_balance) [рекомендуется]"
        echo "     dnsproxy сам выбирает самый быстрый живой сервер и мгновенно обходит упавшие."
        echo "  2) Строгий приоритет (основной + резервные fallback)"
        echo "     Всегда используется #1 (${SELECTED_NAMES[0]}). Остальные включаются только при его сбое."
        echo ""
        read -rp "Выберите режим [1-2] (по умолчанию 1): " mode_choice
        case "$mode_choice" in
            2) SELECTED_MODE="fallback" ;;
            *) SELECTED_MODE="load_balance" ;;
        esac
        ok "Выбран режим работы: ${SELECTED_MODE}"
    else
        SELECTED_MODE="single"
    fi
}

# --- Тест одного DoH-сервера на временном порту ---
test_single_doh_upstream() {
    local name="$1"
    local url="$2"
    info "Тест DoH [${name}]: ${url}..."

    "$BIN_PATH" -l 127.0.0.1 -p 53535 -u "$url" -b 1.1.1.1:53 -b 9.9.9.9:53 -b 8.8.8.8:53 >/dev/null 2>&1 &
    local test_pid=$!
    sleep 1

    local test_ok=0
    if command -v dig >/dev/null 2>&1; then
        local res
        res=$(dig -4 @127.0.0.1 -p 53535 cloudflare.com A +short +time=4 +tries=1 2>/dev/null | head -n 1)
        if [[ -n "$res" && ! "$res" =~ ^\; ]]; then
            ok "  [${name}] работает (cloudflare.com -> ${res})."
            test_ok=1
        fi
    else
        if safe_curl -fsS --max-time 5 -o /dev/null "${url}?name=cloudflare.com&type=A" \
           -H "accept: application/dns-json" 2>/dev/null || safe_curl -sI --max-time 5 "$url" >/dev/null 2>&1; then
            ok "  [${name}] отвечает по HTTPS."
            test_ok=1
        fi
    fi

    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true

    [[ "$test_ok" -eq 1 ]] && return 0 || return 1
}

# --- Предварительный тест всех выбранных DoH-провайдеров ---
pretest_all_selected() {
    header "Предварительное тестирование выбранных DoH-серверов"
    local working_names=()
    local working_urls=()
    local failed_count=0
    local i

    for i in "${!SELECTED_URLS[@]}"; do
        if test_single_doh_upstream "${SELECTED_NAMES[$i]}" "${SELECTED_URLS[$i]}"; then
            working_names+=("${SELECTED_NAMES[$i]}")
            working_urls+=("${SELECTED_URLS[$i]}")
        else
            err "  [${SELECTED_NAMES[$i]}] (${SELECTED_URLS[$i]}) не ответил!"
            failed_count=$((failed_count + 1))
        fi
    done

    if [[ ${#working_urls[@]} -eq 0 ]]; then
        err "Ни один из выбранных DoH-серверов не прошёл проверку!"
        return 1
    fi

    if [[ "$failed_count" -gt 0 ]]; then
        echo ""
        warn "Часть серверов (${failed_count}) не прошла проверку. Рабочих осталось: ${#working_urls[@]}."
        read -rp "Продолжить установку только с рабочими серверами? [Y/n]: " keep_working
        if [[ "$keep_working" =~ ^[Nn]$ ]]; then
            return 1
        fi
        SELECTED_NAMES=("${working_names[@]}")
        SELECTED_URLS=("${working_urls[@]}")
        [[ ${#SELECTED_URLS[@]} -eq 1 ]] && SELECTED_MODE="single"
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

    systemctl is-active --quiet systemd-resolved 2>/dev/null && echo "yes" > "${BACKUP_DIR}/resolved.was_active" || echo "no" > "${BACKUP_DIR}/resolved.was_active"
    systemctl is-enabled --quiet systemd-resolved 2>/dev/null && echo "yes" > "${BACKUP_DIR}/resolved.was_enabled" || echo "no" > "${BACKUP_DIR}/resolved.was_enabled"

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
    mkdir -p "$CONFIG_DIR"

    : > "$UPSTREAMS_FILE"
    rm -f "$FALLBACKS_FILE"

    local exec_extra=""
    if [[ "$SELECTED_MODE" == "fallback" && ${#SELECTED_URLS[@]} -gt 1 ]]; then
        echo "${SELECTED_URLS[0]}" > "$UPSTREAMS_FILE"
        : > "$FALLBACKS_FILE"
        local i
        for (( i=1; i<${#SELECTED_URLS[@]}; i++ )); do
            echo "${SELECTED_URLS[$i]}" >> "$FALLBACKS_FILE"
        done
        exec_extra="-f ${FALLBACKS_FILE}"
    else
        local u
        for u in "${SELECTED_URLS[@]}"; do
            echo "$u" >> "$UPSTREAMS_FILE"
        done
        if [[ ${#SELECTED_URLS[@]} -gt 1 ]]; then
            exec_extra="--upstream-mode=load_balance"
        fi
    fi

    local joined_names joined_urls
    joined_names=$(IFS=', '; echo "${SELECTED_NAMES[*]}")
    joined_urls=$(IFS=', '; echo "${SELECTED_URLS[*]}")

    cat > "$ENV_FILE" <<EOF
DOH_MODE="${SELECTED_MODE}"
DOH_COUNT="${#SELECTED_URLS[@]}"
DOH_NAMES="${joined_names}"
DOH_URLS="${joined_urls}"
EOF

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=System DNS-over-HTTPS Proxy (AdGuardTeam/dnsproxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -l 127.0.0.1 -p 53 -u ${UPSTREAMS_FILE} ${exec_extra} -b 1.1.1.1:53 -b 9.9.9.9:53 -b 8.8.8.8:53 --cache --cache-optimistic --refuse-any
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

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        info "Останавливаем и отключаем systemd-resolved..."
        systemctl stop systemd-resolved
    fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1

    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
# Managed by vps-doh (${joined_names} | mode: ${SELECTED_MODE})
nameserver 127.0.0.1
options edns0 trust-ad
EOF

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

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Сервис ${SERVICE_NAME}: активен (автозапуск включён: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo no))."
    else
        err "Сервис ${SERVICE_NAME} НЕ запущен!"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
        failed=1
    fi

    if ss -tulnp 2>/dev/null | grep -E '127\.0\.0\.1:53\b' | grep -q 'dnsproxy'; then
        ok "Порт 127.0.0.1:53 слушает dnsproxy (публичный доступ извне закрыт)."
    else
        err "dnsproxy не слушает 127.0.0.1:53!"
        failed=1
    fi

    if [[ -x "$MYDNS_BIN" ]]; then
        ok "CLI-утилита mydns: установлена (${MYDNS_BIN})."
    else
        warn "CLI-утилита mydns не установлена."
    fi

    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        info "Режим: ${DOH_MODE:-single} | Провайдеров: ${DOH_COUNT:-1}"
        info "Провайдеры: ${DOH_NAMES:-${DOH_NAME:-unknown}}"
    fi

    if [[ -f "$UPSTREAMS_FILE" ]]; then
        info "Основные DoH upstreams (${UPSTREAMS_FILE}):"
        sed 's/^/    /' "$UPSTREAMS_FILE"
    fi
    if [[ -f "$FALLBACKS_FILE" ]]; then
        info "Резервные DoH fallbacks (${FALLBACKS_FILE}):"
        sed 's/^/    /' "$FALLBACKS_FILE"
    fi

    info "Содержимое /etc/resolv.conf:"
    grep -v '^#' /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
    if command -v lsattr >/dev/null 2>&1; then
        local attrs
        attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' || true)
        [[ "$attrs" == *"i"* ]] && ok "Защита /etc/resolv.conf от слёта: активна (+i)." || warn "Флаг +i на /etc/resolv.conf не установлен."
    fi

    echo ""
    info "Тест разрешения имён через системный DNS:"
    local domains=("cloudflare.com" "github.com" "google.com")
    for d in "${domains[@]}"; do
        if command -v dig >/dev/null 2>&1; then
            local out time_ms ip
            out=$(dig -4 @127.0.0.1 +time=4 +tries=1 "$d" A 2>/dev/null)
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
            ip=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}')
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

# --- Логи и перезапуск сервиса ---
action_logs_and_restart() {
    header "Логи и управление сервисом ${SERVICE_NAME}"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        warn "Сервис ${SERVICE_NAME} не установлен."
        return 1
    fi

    info "Последние 25 строк журнала:"
    journalctl -u "$SERVICE_NAME" -n 25 --no-pager || true
    echo ""
    read -rp "Перезапустить сервис ${SERVICE_NAME} сейчас? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        systemctl restart "$SERVICE_NAME"
        sleep 1
        verify_doh
    fi
}

# --- Откат к стандартным настройкам ---
rollback_to_default() {
    header "Откат DNS к стандартным настройкам"

    if [[ ! -f "${BACKUP_DIR}/backup.done" ]] && \
       ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service" && \
       [[ ! -f "$MYDNS_BIN" ]]; then
        warn "Установленный vps-doh, бэкап и утилита mydns не найдены. Откатывать нечего."
        return 0
    fi

    info "Останавливаем и удаляем сервис ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    info "Удаляем бинарник dnsproxy, конфигурацию и CLI-утилиту mydns..."
    rm -f "$BIN_PATH" "$MYDNS_BIN"
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
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

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

    if getent ahostsv4 cloudflare.com >/dev/null 2>&1 || getent ahosts cloudflare.com >/dev/null 2>&1; then
        ok "Системный DNS после отката работает исправно."
    else
        warn "DNS после отката не отвечает! Временно прописываем 1.1.1.1 и 8.8.8.8 в /etc/resolv.conf..."
        rm -f /etc/resolv.conf
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    fi
}

# --- Полный сценарий установки ---
action_install() {
    detect_network_stack
    ensure_dependencies
    if ! run_preflight_audit; then
        err "Обнаружены критические проблемы при проверке системы. Установка прервана."
        return 1
    fi

    echo ""
    read -rp "Продолжить установку и настройку DoH? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0

    install_dnsproxy_binary || return 1
    select_doh_providers

    if ! pretest_all_selected; then
        read -rp "Повторить выбор DoH-провайдеров? [Y/n]: " retry
        if [[ ! "$retry" =~ ^[Nn]$ ]]; then
            select_doh_providers
            pretest_all_selected || { err "Повторный тест не прошёл. Отмена."; return 1; }
        else
            return 1
        fi
    fi

    backup_original_state
    apply_doh_config
    install_mydns_cli

    if ! verify_doh; then
        err "После применения настроек DNS работает некорректно!"
        read -rp "Выполнить автоматический откат к исходным настройкам? [Y/n]: " do_rb
        if [[ ! "$do_rb" =~ ^[Nn]$ ]]; then
            rollback_to_default
        fi
    else
        echo ""
        ok "Готово! Системный DoH DNS успешно настроен и закреплён."
        info "Для управления в любой момент используйте команду: ${BOLD}sudo mydns${NC}"
    fi
}

# --- Быстрая смена провайдеров ---
action_change_provider() {
    if [[ ! -x "$BIN_PATH" ]]; then
        warn "DoH ещё не установлен. Запускаем полную установку..."
        action_install
        return
    fi

    detect_network_stack
    select_doh_providers
    if ! pretest_all_selected; then
        err "Проверка выбранных серверов не пройдена. Изменения не применены."
        return 1
    fi

    apply_doh_config
    verify_doh
}

# --- Главное меню ---
main_menu() {
    require_root
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}${BOLD}====================================================${NC}"
        echo -e "${CYAN}${BOLD}   mydns — VPS System DoH DNS Manager (Ubuntu 24)   ${NC}"
        echo -e "${CYAN}${BOLD}====================================================${NC}"

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ -f "$ENV_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$ENV_FILE"
            echo -e " Статус: ${GREEN}АКТИВЕН${NC} | Режим: ${BOLD}${DOH_MODE:-single}${NC} (${DOH_COUNT:-1} пров.)"
            echo -e " Провайдеры: ${BOLD}${DOH_NAMES:-${DOH_NAME:-?}}${NC}"
        else
            echo -e " Статус: ${YELLOW}НЕ УСТАНОВЛЕН (используется системный DNS)${NC}"
        fi
        echo "----------------------------------------------------"
        echo "  1) Установить и настроить DoH DNS (1–3 провайдера)"
        echo "  2) Проверить статус и работу DNS"
        echo "  3) Сменить DoH провайдеров (1–3 шт.)"
        echo "  4) Логи и перезапуск сервиса DoH"
        echo "  5) Обновить утилиту mydns с GitHub"
        echo "  6) Откатить всё к стандартным настройкам (Удалить)"
        echo "  0) Выход"
        echo "----------------------------------------------------"
        read -rp "Выберите действие [0-6]: " menu_choice

        case "$menu_choice" in
            1) action_install; pause ;;
            2) verify_doh; pause ;;
            3) action_change_provider; pause ;;
            4) action_logs_and_restart; pause ;;
            5) action_update_self; pause ;;
            6)
                echo ""
                read -rp "Вы уверены, что хотите полностью удалить DoH, mydns и вернуть стандартный DNS? [y/N]: " rb_ans
                [[ "$rb_ans" =~ ^[Yy]$ ]] && rollback_to_default
                pause
                ;;
            0) exit 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# --- Обработка аргументов командной строки (CLI-режим mydns) ---
handle_cli_args() {
    local cmd="${1:-}"
    case "$cmd" in
        "")
            main_menu
            ;;
        -h|--help|help)
            show_help
            ;;
        install)
            require_root
            action_install
            ;;
        status|test|check)
            require_root
            verify_doh
            ;;
        change|providers)
            require_root
            action_change_provider
            ;;
        restart)
            require_root
            systemctl restart "$SERVICE_NAME" && sleep 1 && verify_doh
            ;;
        logs)
            require_root
            journalctl -u "$SERVICE_NAME" -n 30 --no-pager
            ;;
        update)
            require_root
            action_update_self
            ;;
        rollback|uninstall|remove)
            require_root
            if [[ "${2:-}" == "-y" || "${2:-}" == "--yes" ]]; then
                rollback_to_default
            else
                read -rp "Удалить DoH, утилиту mydns и вернуть стандартный DNS? [y/N]: " rb_ans
                [[ "$rb_ans" =~ ^[Yy]$ ]] && rollback_to_default
            fi
            ;;
        *)
            err "Неизвестная команда: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

handle_cli_args "$@"
