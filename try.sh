#!/bin/bash
#
# crowdsecinstall.sh
# Version: 1.1.0
# Author: Biggiko_
# Date: 2026-04-17
# Description: Production-grade installer for CrowdSec + Firewall Bouncer on Ubuntu/Debian.

# =========================================================
# ПЕРЕМЕННЫЕ И КОНСТАНТЫ
# =========================================================

SCRIPT_VERSION="1.1.0"
SCRIPT_AUTHOR="Biggiko_"
SCRIPT_DATE="2026-04-17"

CROWDSEC_REPO_INSTALL_URL="https://install.crowdsec.net"
CONSOLE_URL="https://app.crowdsec.net"
DEFAULT_LAPI_PORT=8080
FALLBACK_LAPI_PORT=7422
CONFIG_YAML="/etc/crowdsec/config.yaml"
CREDENTIALS_YAML="/etc/crowdsec/local_api_credentials.yaml"
BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
ACQUISITION_YAML="/etc/crowdsec/acquisition.yaml"
LOG_FILE="/var/log/crowdsec-install.log"
BOUNCER_NAME="AutoBouncer-$(hostname)"
API_KEY_FALLBACK_MIN_LEN=20
LAPI_START_WAIT_SECONDS=5
CROWDSEC_RESTART_WAIT_SECONDS=5
BOUNCER_RESTART_WAIT_SECONDS=3

# Эти переменные будут определены позже в ходе работы скрипта
LAPI_PORT="$DEFAULT_LAPI_PORT"
BOUNCER_API_KEY=""
FIREWALL_MODE="iptables"
FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-iptables"

DEPENDENCIES=(
  "curl"
  "wget"
  "jq"
  "net-tools"
  "iptables"
  "iproute2"
  "lsof"
)

SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04")
SUPPORTED_DEBIAN_VERSIONS=("11" "12")

# =========================================================
# ЦВЕТА
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =========================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =========================================================

success()  { echo -e "${GREEN}[✔] $1${NC}" | tee -a "$LOG_FILE"; }
error()    { echo -e "${RED}[✘] $1${NC}" | tee -a "$LOG_FILE" >&2; }
warning()  { echo -e "${YELLOW}[!] $1${NC}" | tee -a "$LOG_FILE"; }
info()     { echo -e "${BLUE}[i] $1${NC}" | tee -a "$LOG_FILE"; }
step()     { echo -e "\n${CYAN}${BOLD}>>> $1${NC}" | tee -a "$LOG_FILE"; }

print_separator() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Логировать команду без перехвата её вывода
log_cmd() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CMD: $*" >> "$LOG_FILE"
}

ask_yes_no() {
  # $1 = prompt; возвращает 0 = Yes, 1 = No
  local prompt="$1"
  local answer
  # read идёт напрямую в /dev/tty, чтобы промпт всегда был виден
  read -rp "$(echo -e "${YELLOW}➤ ${prompt} [Y/n]: ${NC}")" answer </dev/tty
  case "$answer" in
    ""|Y|y|yes|YES) return 0 ;;
    N|n|no|NO)      return 1 ;;
    *) warning "Некорректный ввод, использую значение по умолчанию: Yes"; return 0 ;;
  esac
}

is_port_busy() {
  local port="$1"
  ss -tulpn 2>/dev/null | grep -q ":${port}[[:space:]]" && return 0
  lsof -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN && return 0
  return 1
}

get_process_on_port() {
  local port="$1"
  local proc
  proc="$(ss -tulpn 2>/dev/null | grep ":${port}[[:space:]]" | head -1 \
    | grep -oP 'users:\(\("\K[^"]+' | head -1)"
  [ -z "$proc" ] && proc="$(lsof -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null \
    | awk 'NR==2 {print $1 " (pid " $2 ")"}')"
  [ -n "$proc" ] && echo "$proc" || echo "неизвестный процесс"
}

validate_port() {
  local port="$1"
  echo "$port" | grep -Eq '^[0-9]+$' || return 1
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
}

# =========================================================
# ИНИЦИАЛИЗАЦИЯ ЛОГА (без exec-редиректа, чтобы не ломать read)
# =========================================================

init_logging() {
  touch "$LOG_FILE" 2>/dev/null || {
    echo -e "${RED}[✘] Не удалось создать лог-файл: $LOG_FILE${NC}" >&2
    exit 1
  }
  {
    echo ""
    echo "============================================================"
    echo "CrowdSec installation started at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Script version: $SCRIPT_VERSION"
    echo "============================================================"
  } >> "$LOG_FILE"
}

# =========================================================
# БАННЕР
# =========================================================

print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  cat <<'BANNER'
   ______                    __ _____           
  / ____/________ _      __/ // ___/___  _____  
 / /   / ___/ __ \ | /| / / / \__ \/ _ \/ ___/  
/ /___/ /  / /_/ / |/ |/ / / ___/ /  __/ /__   
\____/_/   \____/|__/|__/_/ /____/\___/\___/   
BANNER
  echo -e "${NC}"
  echo -e "  ${BLUE}CrowdSec + Firewall Bouncer Installer${NC}"
  echo -e "  ${BLUE}Version: ${SCRIPT_VERSION} | Author: ${SCRIPT_AUTHOR} | Date: ${SCRIPT_DATE}${NC}"
  echo ""
}

# =========================================================
# ШАГ 1 — PRE-FLIGHT CHECKS
# =========================================================

preflight_checks() {

  # 1.1 — Root check
  if [ "$(id -u)" -ne 0 ]; then
    error "Скрипт должен выполняться от root."
    error "Запустите: sudo bash crowdsecinstall.sh"
    exit 1
  fi
  success "Запуск от root подтверждён"

  # 1.2 — OS check
  if [ ! -f /etc/os-release ]; then
    error "Файл /etc/os-release не найден — невозможно определить ОС"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release

  local os_supported=1
  local ver
  if [ "$ID" = "ubuntu" ]; then
    for ver in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
      [ "$VERSION_ID" = "$ver" ] && os_supported=0
    done
  elif [ "$ID" = "debian" ]; then
    for ver in "${SUPPORTED_DEBIAN_VERSIONS[@]}"; do
      [ "$VERSION_ID" = "$ver" ] && os_supported=0
    done
  fi

  if [ "$os_supported" -ne 0 ]; then
    warning "Обнаружена неподдерживаемая ОС: ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
    if ! ask_yes_no "Продолжить установку на неподдерживаемой ОС?"; then
      error "Установка отменена пользователем"
      exit 1
    fi
  else
    success "Поддерживаемая ОС: ${PRETTY_NAME}"
  fi

  # 1.3 — Зависимости
  step "Проверка и установка зависимостей"
  apt-get update -y >> "$LOG_FILE" 2>&1

  local dep cmd
  for dep in "${DEPENDENCIES[@]}"; do
    # Для net-tools реальная команда — netstat, для iproute2 — ss
    case "$dep" in
      net-tools) cmd="netstat" ;;
      iproute2)  cmd="ss" ;;
      *)         cmd="$dep" ;;
    esac

    if command -v "$cmd" >/dev/null 2>&1; then
      success "Зависимость найдена: ${dep}"
      continue
    fi

    warning "Зависимость отсутствует: ${dep}, устанавливаю..."
    apt-get install -y "$dep" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      warning "Не удалось установить зависимость: ${dep}. Продолжаю без неё."
    else
      success "Установлено: ${dep}"
    fi
  done

  # 1.4 — Определение режима firewall (iptables vs nftables)
  detect_firewall_mode

  # 1.5 — Проверка интернета
  curl -s --max-time 10 "$CROWDSEC_REPO_INSTALL_URL" -o /dev/null
  if [ $? -ne 0 ]; then
    error "Нет доступа к ${CROWDSEC_REPO_INSTALL_URL}. Проверьте интернет-соединение."
    exit 1
  fi
  success "Интернет-соединение проверено"
}

detect_firewall_mode() {
  # Надёжное определение: проверяем, что реально работает в ядре
  local mode_detected="iptables"

  # Если nft доступен и nftables модуль загружен — используем nftables
  if command -v nft >/dev/null 2>&1; then
    if nft list tables >/dev/null 2>&1; then
      # Дополнительно проверяем, что iptables-legacy не используется явно
      if iptables --version 2>/dev/null | grep -q "legacy"; then
        mode_detected="iptables"
      else
        mode_detected="nftables"
      fi
    fi
  fi

  # Явная проверка: если iptables указывает на nft backend
  if command -v iptables >/dev/null 2>&1; then
    if iptables --version 2>/dev/null | grep -qi "nf_tables"; then
      mode_detected="nftables"
    fi
  fi

  FIREWALL_MODE="$mode_detected"
  if [ "$FIREWALL_MODE" = "nftables" ]; then
    FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-nftables"
  else
    FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-iptables"
  fi
  info "Режим Firewall Bouncer: ${FIREWALL_MODE} (${FIREWALL_BOUNCER_PACKAGE})"
}

# =========================================================
# ШАГ 2 — УСТАНОВКА CROWDSEC
# =========================================================

install_crowdsec() {
  dpkg -l crowdsec 2>/dev/null | grep -q "^ii"
  if [ $? -eq 0 ]; then
    info "CrowdSec уже установлен, пропускаю..."
    return 0
  fi

  step "Добавление репозитория CrowdSec"
  log_cmd "curl -fsSL $CROWDSEC_REPO_INSTALL_URL | sh"
  curl -fsSL "$CROWDSEC_REPO_INSTALL_URL" | sh >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось добавить репозиторий CrowdSec"
    exit 1
  fi
  success "Репозиторий CrowdSec добавлен"

  apt-get update -y >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось выполнить apt-get update"
    exit 1
  fi

  step "Установка пакета crowdsec"
  log_cmd "apt-get install -y crowdsec"
  apt-get install -y crowdsec >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось установить пакет crowdsec"
    exit 1
  fi
  success "CrowdSec установлен"

  systemctl list-unit-files 2>/dev/null | grep -q "crowdsec"
  if [ $? -ne 0 ]; then
    error "Systemd unit для CrowdSec не найден после установки"
    exit 1
  fi
  success "Systemd unit CrowdSec обнаружен"
}

# =========================================================
# ШАГ 3 — КОНФИГУРАЦИЯ LAPI ПОРТА
# =========================================================

configure_lapi_port() {
  if [ ! -f "$CONFIG_YAML" ]; then
    error "Файл конфигурации не найден: $CONFIG_YAML"
    exit 1
  fi
  if [ ! -f "$CREDENTIALS_YAML" ]; then
    error "Файл credentials не найден: $CREDENTIALS_YAML"
    exit 1
  fi

  # Читаем текущий порт из конфига
  local current_port
  current_port="$(grep -oP 'listen_uri:\s*\S+:\K\d+' "$CONFIG_YAML" 2>/dev/null | head -1)"
  [ -z "$current_port" ] && current_port="$DEFAULT_LAPI_PORT"
  info "Текущий LAPI порт из конфигурации: ${current_port}"

  # Проверяем занятость порта
  if ! is_port_busy "$current_port"; then
    success "Порт ${current_port} свободен"
    LAPI_PORT="$current_port"
    return 0
  fi

  # Порт занят — определяем кем
  local holder
  holder="$(get_process_on_port "$current_port")"

  # Если занят самим crowdsec — всё нормально (демон уже работает)
  if echo "$holder" | grep -qi "crowdsec"; then
    info "Порт ${current_port} используется самим CrowdSec — оставляю без изменений"
    LAPI_PORT="$current_port"
    return 0
  fi

  warning "Порт ${current_port} занят процессом: ${holder}"

  # Выбор нового порта
  local new_port=""

  if ask_yes_no "Автоматически переключить на порт ${FALLBACK_LAPI_PORT}?"; then
    if ! is_port_busy "$FALLBACK_LAPI_PORT"; then
      new_port="$FALLBACK_LAPI_PORT"
      success "Будет использован порт: ${new_port}"
    else
      warning "Порт ${FALLBACK_LAPI_PORT} тоже занят. Введите порт вручную."
    fi
  fi

  # Ручной ввод, если автовыбор не сработал
  while [ -z "$new_port" ]; do
    local custom_port
    read -rp "$(echo -e "${YELLOW}➤ Введите свободный порт (1024-65535): ${NC}")" custom_port </dev/tty
    if ! validate_port "$custom_port"; then
      warning "Некорректный порт: '${custom_port}' — нужно число от 1024 до 65535"
      continue
    fi
    if is_port_busy "$custom_port"; then
      warning "Порт ${custom_port} занят — выберите другой"
      continue
    fi
    new_port="$custom_port"
  done

  LAPI_PORT="$new_port"
  info "Применяю новый порт LAPI: ${LAPI_PORT} (был: ${current_port})"

  # Патч config.yaml
  sed -i -E "s|(listen_uri:[[:space:]]*)([^:]+:)${current_port}|\1\2${LAPI_PORT}|g" "$CONFIG_YAML"
  if [ $? -ne 0 ]; then
    error "Не удалось обновить listen_uri в $CONFIG_YAML"
    exit 1
  fi

  # Патч local_api_credentials.yaml
  sed -i -E "s|(url:[[:space:]]*http://[^:]+:)${current_port}|\1${LAPI_PORT}|g" "$CREDENTIALS_YAML"
  if [ $? -ne 0 ]; then
    error "Не удалось обновить url в $CREDENTIALS_YAML"
    exit 1
  fi

  # Верификация
  grep -q "${LAPI_PORT}" "$CONFIG_YAML"
  if [ $? -ne 0 ]; then
    error "Верификация не пройдена: новый порт не найден в $CONFIG_YAML"
    exit 1
  fi
  grep -q "${LAPI_PORT}" "$CREDENTIALS_YAML"
  if [ $? -ne 0 ]; then
    error "Верификация не пройдена: новый порт не найден в $CREDENTIALS_YAML"
    exit 1
  fi

  success "LAPI порт успешно изменён на ${LAPI_PORT}"

  # Перезапуск CrowdSec чтобы применить новый порт
  systemctl restart crowdsec >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось перезапустить crowdsec после смены LAPI порта"
    exit 1
  fi
  sleep "$CROWDSEC_RESTART_WAIT_SECONDS"
  success "crowdsec перезапущен с новым портом"
}

# =========================================================
# ШАГ 4 — УСТАНОВКА И КОНФИГУРАЦИЯ БАУНСЕРА
# =========================================================

install_and_configure_bouncer() {

  # 4.1 — Идемпотентная проверка установки пакета
  dpkg -l "$FIREWALL_BOUNCER_PACKAGE" 2>/dev/null | grep -q "^ii"
  if [ $? -eq 0 ]; then
    info "${FIREWALL_BOUNCER_PACKAGE} уже установлен"
  else
    log_cmd "apt-get install -y $FIREWALL_BOUNCER_PACKAGE"
    apt-get install -y "$FIREWALL_BOUNCER_PACKAGE" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось установить ${FIREWALL_BOUNCER_PACKAGE}"
      exit 1
    fi
    success "Firewall bouncer установлен (${FIREWALL_BOUNCER_PACKAGE})"
  fi

  # 4.2 — Убеждаемся что CrowdSec LAPI запущен
  systemctl is-active --quiet crowdsec
  if [ $? -ne 0 ]; then
    info "Запускаю crowdsec для генерации ключа..."
    systemctl start crowdsec >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось запустить crowdsec"
      exit 1
    fi
    sleep "$LAPI_START_WAIT_SECONDS"
  fi

  # 4.3 — Удаление старой регистрации баунсера (идемпотентность)
  local existing_bouncers
  existing_bouncers="$(cscli bouncers list -o json 2>/dev/null)"

  local bouncer_exists=1
  if [ -n "$existing_bouncers" ]; then
    # Пробуем разные структуры JSON которые cscli может вернуть
    echo "$existing_bouncers" | jq -e --arg n "$BOUNCER_NAME" \
      'if type=="array" then .[]?.name else .bouncers[]?.name end | select(. == $n)' \
      >/dev/null 2>&1
    bouncer_exists=$?
  fi
  # Fallback: plain text list
  if [ $bouncer_exists -ne 0 ]; then
    cscli bouncers list 2>/dev/null | grep -Fq "$BOUNCER_NAME"
    bouncer_exists=$?
  fi

  if [ $bouncer_exists -eq 0 ]; then
    warning "Баунсер '${BOUNCER_NAME}' уже зарегистрирован — пересоздаю ключ"
    # cscli bouncers delete принимает имя как аргумент, флаг -f появился в новых версиях
    cscli bouncers delete "$BOUNCER_NAME" 2>/dev/null || true
    sleep 1
  fi

  # 4.4 — Генерация API-ключа
  info "Генерирую API ключ для баунсера '${BOUNCER_NAME}'..."
  local key_json
  key_json="$(cscli bouncers add "$BOUNCER_NAME" -o json 2>&1)"
  if [ $? -ne 0 ]; then
    error "Не удалось создать API ключ:"
    echo "$key_json" | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "$key_json" >> "$LOG_FILE"

  # Парсим ключ — пробуем все известные поля
  BOUNCER_API_KEY="$(echo "$key_json" | jq -r \
    '.api_key // .key // .credentials.api_key // .credentials.key // empty' \
    2>/dev/null | grep -v null | head -n1)"

  # Рекурсивный поиск по всему JSON (для нестандартных версий cscli)
  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    BOUNCER_API_KEY="$(echo "$key_json" | jq -r \
      '.. | scalars | select(type=="string" and length > 20)' \
      2>/dev/null | head -n1)"
    [ -n "$BOUNCER_API_KEY" ] && warning "API ключ извлечён через fallback-парсинг"
  fi

  # Текстовый fallback (старые версии cscli без JSON)
  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    BOUNCER_API_KEY="$(echo "$key_json" | grep -Eio \
      "(api[_-]?key|key)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_/-]{${API_KEY_FALLBACK_MIN_LEN},}" \
      | grep -Eo "[A-Za-z0-9_/-]{${API_KEY_FALLBACK_MIN_LEN},}" | head -n1)"
    [ -n "$BOUNCER_API_KEY" ] && warning "API ключ извлечён через текстовый fallback"
  fi

  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    error "Не удалось извлечь API ключ из ответа cscli"
    error "Ответ был: $key_json"
    exit 1
  fi
  success "API ключ для баунсера успешно создан"

  # 4.5 — Создание/обновление конфига баунсера
  mkdir -p "$(dirname "$BOUNCER_CONFIG")"
  if [ $? -ne 0 ]; then
    error "Не удалось создать каталог для конфига баунсера"
    exit 1
  fi

  if [ ! -s "$BOUNCER_CONFIG" ]; then
    # Конфиг отсутствует или пустой — создаём с нуля
    info "Создаю новый конфиг баунсера: $BOUNCER_CONFIG"
    cat > "$BOUNCER_CONFIG" <<EOF
api_key: "${BOUNCER_API_KEY}"
api_url: "http://127.0.0.1:${LAPI_PORT}"
update_frequency: 10s
log_mode: file
log_dir: /var/log/crowdsec/
log_level: info
log_compression: true
log_max_size: 100
log_max_backups: 3
mode: ${FIREWALL_MODE}
EOF
    if [ $? -ne 0 ]; then
      error "Не удалось создать конфиг баунсера"
      exit 1
    fi

    if [ "$FIREWALL_MODE" = "iptables" ]; then
      cat >> "$BOUNCER_CONFIG" <<'EOF'
iptables_chains:
  - INPUT
  - FORWARD
EOF
      # Добавляем DOCKER-USER только если Docker реально есть
      if iptables -S DOCKER-USER >/dev/null 2>&1 || ip6tables -S DOCKER-USER >/dev/null 2>&1; then
        echo "  - DOCKER-USER" >> "$BOUNCER_CONFIG"
        info "Добавлена цепочка DOCKER-USER (Docker обнаружен)"
      fi
    fi

    success "Конфиг баунсера создан: $BOUNCER_CONFIG"
  else
    # Конфиг существует — обновляем только api_key и api_url
    info "Обновляю api_key и api_url в существующем конфиге"

    sed -i -E "s|^api_key:.*|api_key: \"${BOUNCER_API_KEY}\"|" "$BOUNCER_CONFIG"
    if [ $? -ne 0 ]; then
      error "Не удалось обновить api_key в $BOUNCER_CONFIG"
      exit 1
    fi

    if grep -q "^api_url:" "$BOUNCER_CONFIG"; then
      sed -i -E "s|^api_url:.*|api_url: \"http://127.0.0.1:${LAPI_PORT}\"|" "$BOUNCER_CONFIG"
      if [ $? -ne 0 ]; then
        error "Не удалось обновить api_url в $BOUNCER_CONFIG"
        exit 1
      fi
    else
      echo "" >> "$BOUNCER_CONFIG"
      echo "api_url: \"http://127.0.0.1:${LAPI_PORT}\"" >> "$BOUNCER_CONFIG"
    fi

    # Обновляем mode если он уже есть
    if grep -q "^mode:" "$BOUNCER_CONFIG"; then
      sed -i -E "s|^mode:.*|mode: ${FIREWALL_MODE}|" "$BOUNCER_CONFIG"
    fi

    success "Конфиг баунсера обновлён (api_key / api_url)"
  fi
}

# =========================================================
# ШАГ 5 — L7 ЗАЩИТА (NGINX)
# =========================================================

configure_nginx_protection() {
  print_separator
  info "Возможность настройки L7 защиты для Nginx"
  info "Коллекции: crowdsecurity/nginx, http-crawlers, http-dos, iptables"

  if ! ask_yes_no "Установить защиту L7 для Nginx?"; then
    info "Настройка L7 для Nginx пропущена"
    return 0
  fi

  # Проверяем наличие Nginx
  command -v nginx >/dev/null 2>&1 || dpkg -l nginx 2>/dev/null | grep -q "^ii"
  if [ $? -ne 0 ]; then
    warning "Nginx не обнаружен на этом сервере"
    if ! ask_yes_no "Продолжить установку коллекций без Nginx?"; then
      info "Установка Nginx-коллекций отменена"
      return 0
    fi
  fi

  local collections=(
    "crowdsecurity/nginx"
    "crowdsecurity/http-crawlers"
    "crowdsecurity/http-dos"
    "crowdsecurity/iptables"
  )
  local col
  for col in "${collections[@]}"; do
    log_cmd "cscli collections install $col"
    cscli collections install "$col" 2>&1 | tee -a "$LOG_FILE"
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
      warning "Не удалось установить коллекцию: $col (продолжаю)"
    else
      success "Коллекция установлена: $col"
    fi
  done

  # Настройка acquisition.yaml
  touch "$ACQUISITION_YAML" 2>/dev/null || {
    error "Не удалось открыть $ACQUISITION_YAML"
    exit 1
  }

  grep -q "/var/log/nginx" "$ACQUISITION_YAML"
  if [ $? -ne 0 ]; then
    cat >> "$ACQUISITION_YAML" <<'EOF'
---
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
EOF
    if [ $? -ne 0 ]; then
      error "Не удалось обновить $ACQUISITION_YAML"
      exit 
      main "$@"
