#!/bin/bash
#
# crowdsecinstall.sh
# Version: 1.0.0
# Author: Biggiko_
# Date: 2026-04-17
# Description: Production-grade installer for CrowdSec + Firewall Bouncer on Ubuntu/Debian.

# =========================================================
# 2. Объявление всех переменных и констант
# =========================================================

SCRIPT_VERSION="1.0.0"
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
# Handles three possible cscli JSON shapes:
# 1) array of bouncer objects      -> .[]?.name
# 2) single object with name       -> .name
# 3) object with nested bouncers   -> .bouncers[]?.name
JQ_BOUNCER_NAMES_FILTER='if type=="array" then .[]?.name // empty elif type=="object" then (.name // (.bouncers[]?.name // empty)) else empty end'
API_KEY_FALLBACK_MIN_LEN=20
API_KEY_REGEX="^[-A-Za-z0-9_+/=]{${API_KEY_FALLBACK_MIN_LEN},}$"
LAPI_START_WAIT_SECONDS=3
LAPI_READY_MAX_WAIT_SECONDS=60
CROWDSEC_RESTART_WAIT_SECONDS=5
BOUNCER_RESTART_WAIT_SECONDS=2

LAPI_PORT="$DEFAULT_LAPI_PORT"
BOUNCER_API_KEY=""
FIREWALL_MODE="iptables"
FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-iptables"

DEPENDENCIES=(
  "curl"
  "wget"
  "jq"
  "netstat"
  "iptables"
  "ss"
  "lsof"
)

SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04")
SUPPORTED_DEBIAN_VERSIONS=("11" "12")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color / Reset

# =========================================================
# 3. Объявление всех вспомогательных функций
# =========================================================

success()  { if [ -f "$LOG_FILE" ]; then echo -e "${GREEN}[✔] $1${NC}" | tee -a "$LOG_FILE"; else echo -e "${GREEN}[✔] $1${NC}"; fi; }
error()    { if [ -f "$LOG_FILE" ]; then echo -e "${RED}[✘] $1${NC}" | tee -a "$LOG_FILE" >&2; else echo -e "${RED}[✘] $1${NC}" >&2; fi; }
warning()  { if [ -f "$LOG_FILE" ]; then echo -e "${YELLOW}[!] $1${NC}" | tee -a "$LOG_FILE"; else echo -e "${YELLOW}[!] $1${NC}"; fi; }
info()     { if [ -f "$LOG_FILE" ]; then echo -e "${BLUE}[i] $1${NC}" | tee -a "$LOG_FILE"; else echo -e "${BLUE}[i] $1${NC}"; fi; }
step()     { if [ -f "$LOG_FILE" ]; then echo -e "\n${CYAN}${BOLD}>>> $1${NC}" | tee -a "$LOG_FILE"; else echo -e "\n${CYAN}${BOLD}>>> $1${NC}"; fi; }

print_separator() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ask_yes_no() {
  # $1 prompt
  # default: yes on empty input
  local prompt="$1"
  local answer
  read -rp "$(echo -e "${YELLOW}➤ ${prompt} [Y/n] (введите y/n и Enter): ${NC}")" answer </dev/tty
  case "$answer" in
    ""|Y|y|yes|YES) return 0 ;;
    N|n|no|NO) return 1 ;;
    *) warning "Некорректный ввод, использую значение по умолчанию: Yes"; return 0 ;;
  esac
}

is_port_busy() {
  local port="$1"
  ss -tulpn 2>/dev/null | grep -q ":${port} " && return 0
  lsof -i :"${port}" 2>/dev/null | grep -q LISTEN && return 0
  return 1
}

get_process_on_port() {
  local port="$1"
  local proc
  # ss line example: users:(("nginx",pid=1234,fd=6))
  proc="$(ss -tulpn 2>/dev/null | grep ":${port} " | head -1 | awk -F'users:\\(\\(' '{print $2}' | awk -F'\\)\\)' '{print $1}')"
  if [ -z "$proc" ]; then
    proc="$(lsof -i :"${port}" 2>/dev/null | awk 'NR==2 {print $1 " (pid " $2 ")"}')"
  fi
  [ -n "$proc" ] && echo "$proc" || echo "неизвестный процесс"
}

validate_port() {
  local port="$1"
  if ! echo "$port" | grep -Eq '^[0-9]+$'; then
    return 1
  fi
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
}

init_logging() {
  touch "$LOG_FILE" 2>/dev/null || {
    error "Не удалось создать лог-файл: $LOG_FILE"
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

print_banner() {
  echo -e "${CYAN}${BOLD}"
  cat <<'EOF'
   ______                    __ _____           
  / ____/________ _      __/ // ___/___  _____
 / /   / ___/ __ \ | /| / / / \__ \/ _ \/ ___/
/ /___/ /  / /_/ / |/ |/ / / ___/ /  __/ /__  
\____/_/   \____/|__/|__/_/ /____/\___/\___/  
EOF
  echo -e "${NC}"
  echo -e "${BLUE}CrowdSec + Firewall Bouncer Installer${NC}"
  echo -e "${BLUE}Version: ${SCRIPT_VERSION} | Author: ${SCRIPT_AUTHOR} | Date: ${SCRIPT_DATE}${NC}"
}

preflight_checks() {
  # 1.1 OS check
  if [ ! -f /etc/os-release ]; then
    error "Файл /etc/os-release не найден, невозможно определить ОС"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release

  local os_ok=1
  local version_ok=1
  local v

  if [ "$ID" = "ubuntu" ]; then
    os_ok=0
    version_ok=1
    for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
      [ "$VERSION_ID" = "$v" ] && version_ok=0
    done
  elif [ "$ID" = "debian" ]; then
    os_ok=0
    version_ok=1
    for v in "${SUPPORTED_DEBIAN_VERSIONS[@]}"; do
      [ "$VERSION_ID" = "$v" ] && version_ok=0
    done
  fi

  if [ "$os_ok" -ne 0 ] || [ "$version_ok" -ne 0 ]; then
    warning "Обнаружена неподдерживаемая ОС: ${PRETTY_NAME}"
    if ! ask_yes_no "Продолжить на неподдерживаемой ОС?"; then
      error "Установка отменена пользователем"
      exit 1
    fi
  else
    success "Поддерживаемая ОС: ${PRETTY_NAME}"
  fi

  # 1.3 Dependencies
  step "Проверка зависимостей"
  apt-get update -y >/dev/null 2>&1

  local dep
  local dep_found
  for dep in "${DEPENDENCIES[@]}"; do
    dep_found=1
    if [ "$dep" = "netstat" ]; then
      command -v netstat >/dev/null 2>&1 && dep_found=0
    else
      command -v "$dep" >/dev/null 2>&1 && dep_found=0
    fi

    if [ "$dep_found" -eq 0 ]; then
      success "Зависимость найдена: ${dep}"
      continue
    fi

    warning "Зависимость отсутствует: ${dep}, устанавливаю..."
    case "$dep" in
      netstat) apt-get install -y net-tools >/dev/null 2>&1 ;;
      ss) apt-get install -y iproute2 >/dev/null 2>&1 ;;
      lsof) apt-get install -y lsof >/dev/null 2>&1 ;;
      *) apt-get install -y "$dep" >/dev/null 2>&1 ;;
    esac

    if [ $? -ne 0 ]; then
      warning "Не удалось установить зависимость: ${dep}. Продолжаю."
    else
      success "Установлено: ${dep}"
    fi
  done

  detect_firewall_mode

  # 1.4 Internet check
  curl -s --max-time 5 "$CROWDSEC_REPO_INSTALL_URL" > /dev/null
  if [ $? -ne 0 ]; then
    error "Нет доступа к ${CROWDSEC_REPO_INSTALL_URL}. Проверьте интернет-соединение."
    exit 1
  fi
  success "Интернет-соединение проверено"
}

detect_firewall_mode() {
  local mode_detected="iptables"

  if command -v nft >/dev/null 2>&1; then
    if nft list tables >/dev/null 2>&1; then
      if iptables --version 2>/dev/null | grep -q "legacy"; then
        mode_detected="iptables"
      elif iptables --version 2>/dev/null | grep -qi "nf_tables"; then
        mode_detected="nftables"
      fi
    fi
  fi

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

install_crowdsec() {
  dpkg -l crowdsec 2>/dev/null | grep -q "^ii"
  if [ $? -eq 0 ]; then
    info "CrowdSec уже установлен, пропускаю..."
    return 0
  fi

  step "Добавление репозитория CrowdSec"
  curl -fsSL "$CROWDSEC_REPO_INSTALL_URL" | sh
  if [ $? -ne 0 ]; then
    error "Не удалось добавить репозиторий CrowdSec"
    exit 1
  fi
  success "Репозиторий CrowdSec добавлен"

  apt-get update -y || { error "Не удалось выполнить apt-get update"; exit 1; }

  step "Установка пакета crowdsec"
  apt-get install -y crowdsec || { error "Не удалось установить пакет crowdsec"; exit 1; }
  success "CrowdSec установлен"

  systemctl list-unit-files | grep -q "crowdsec"
  if [ $? -ne 0 ]; then
    error "Systemd unit для CrowdSec не найден после установки"
    exit 1
  fi
  success "Systemd unit CrowdSec найден"
}

configure_lapi_port() {
  if [ ! -f "$CONFIG_YAML" ]; then
    error "Файл конфигурации CrowdSec не найден: $CONFIG_YAML"
    exit 1
  fi

  if [ ! -f "$CREDENTIALS_YAML" ]; then
    error "Файл credentials не найден: $CREDENTIALS_YAML"
    exit 1
  fi

  local current_port
  current_port="$(grep -oP 'listen_uri:\s*\K[^:]+:\K\d+' "$CONFIG_YAML" 2>/dev/null | head -1)"
  [ -z "$current_port" ] && current_port="$DEFAULT_LAPI_PORT"

  info "Текущий LAPI порт из конфигурации: $current_port"

  if ! is_port_busy "$current_port"; then
    success "Порт ${current_port} свободен"
    LAPI_PORT="$current_port"
    return 0
  fi

  local holder
  holder="$(get_process_on_port "$current_port")"
  if echo "$holder" | grep -qi "crowdsec"; then
    info "Порт ${current_port} используется самим crowdsec — порт оставляю без изменений."
    LAPI_PORT="$current_port"
    return 0
  fi

  warning "Порт ${current_port} занят процессом: ${holder}"

  local new_port=""

  if ask_yes_no "Автоматически переключить на порт ${FALLBACK_LAPI_PORT}?"; then
    if ! is_port_busy "$FALLBACK_LAPI_PORT"; then
      new_port="$FALLBACK_LAPI_PORT"
      success "Будет использован fallback порт: ${new_port}"
    else
      warning "Порт ${FALLBACK_LAPI_PORT} тоже занят. Нужно ввести порт вручную."
    fi
  fi

  while [ -z "$new_port" ]; do
    local custom_port
    read -rp "$(echo -e "${YELLOW}➤ Введите свободный порт (1024-65535) и нажмите Enter: ${NC}")" custom_port </dev/tty
    if ! validate_port "$custom_port"; then
      warning "Некорректный порт: ${custom_port}"
      continue
    fi
    if [ "$custom_port" = "$current_port" ]; then
      warning "Это текущий занятый порт ${current_port}, выберите другой."
      continue
    fi
    if is_port_busy "$custom_port"; then
      warning "Порт ${custom_port} уже занят, выберите другой."
      continue
    fi
    new_port="$custom_port"
  done

  LAPI_PORT="$new_port"

  if [ "$LAPI_PORT" = "$current_port" ]; then
    success "Порт не изменился: ${LAPI_PORT}"
    return 0
  fi

  info "Применяю новый порт LAPI: ${LAPI_PORT}"

  sed -i -E "/^[[:space:]]*listen_uri:/ s|:${current_port}([[:space:]]*(#.*)?$)|:${LAPI_PORT}\1|g" "$CONFIG_YAML" || {
    error "Не удалось обновить listen_uri в $CONFIG_YAML"
    exit 1
  }

  sed -i -E "/^[[:space:]]*url:[[:space:]]*http(s)?:\\/\\// s|:${current_port}([[:space:]]*(#.*)?$)|:${LAPI_PORT}\1|g" "$CREDENTIALS_YAML" || {
    error "Не удалось обновить url в $CREDENTIALS_YAML"
    exit 1
  }

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

  success "LAPI порт успешно изменен на ${LAPI_PORT}"

  systemctl restart crowdsec || { error "Не удалось перезапустить crowdsec после смены LAPI порта"; exit 1; }
  sleep "$CROWDSEC_RESTART_WAIT_SECONDS"
  success "crowdsec перезапущен после смены LAPI порта"
}

install_and_configure_bouncer() {
  dpkg -l "$FIREWALL_BOUNCER_PACKAGE" 2>/dev/null | grep -q "^ii"
  if [ $? -eq 0 ]; then
    info "${FIREWALL_BOUNCER_PACKAGE} уже установлен"
  else
    apt-get install -y "$FIREWALL_BOUNCER_PACKAGE" || { error "Не удалось установить ${FIREWALL_BOUNCER_PACKAGE}"; exit 1; }
    success "Firewall bouncer установлен (${FIREWALL_BOUNCER_PACKAGE})"
  fi

  systemctl start crowdsec || { error "Не удалось запустить crowdsec перед генерацией ключа"; exit 1; }
  local lapi_wait_elapsed=0
  while [ "$lapi_wait_elapsed" -lt "$LAPI_READY_MAX_WAIT_SECONDS" ]; do
    cscli bouncers list -o json >/dev/null 2>&1 && break
    sleep "$LAPI_START_WAIT_SECONDS"
    lapi_wait_elapsed=$((lapi_wait_elapsed + LAPI_START_WAIT_SECONDS))
  done
  if [ "$lapi_wait_elapsed" -ge "$LAPI_READY_MAX_WAIT_SECONDS" ]; then
    error "LAPI не стал доступен за ${LAPI_READY_MAX_WAIT_SECONDS} секунд"
    exit 1
  fi

  local bouncer_check_result=1
  local bouncers_list_output
  bouncers_list_output="$(cscli bouncers list -o json 2>/dev/null || true)"

  if [ -n "$bouncers_list_output" ] && echo "$bouncers_list_output" | jq -e 'type=="array" or type=="object"' >/dev/null 2>&1; then
    echo "$bouncers_list_output" | jq -r "$JQ_BOUNCER_NAMES_FILTER" 2>/dev/null | grep -Fq "$BOUNCER_NAME"
    bouncer_check_result=$?
  else
    cscli bouncers list 2>/dev/null | grep -Fq "$BOUNCER_NAME"
    bouncer_check_result=$?
  fi

  if [ $bouncer_check_result -eq 0 ]; then
    warning "Баунсер уже зарегистрирован, пересоздаю ключ"
    local delete_help
    local delete_output
    local delete_rc
    local need_fallback_delete=1
    delete_help="$(cscli bouncers delete --help 2>&1 || true)"
    if echo "$delete_help" | grep -Eq -- '(^|[[:space:]])(-f|--force)([[:space:]]|,|$)'; then
      delete_output="$(cscli bouncers delete "$BOUNCER_NAME" -f 2>&1)"
      delete_rc=$?
      [ $delete_rc -eq 0 ] && need_fallback_delete=0
    fi
    if [ $need_fallback_delete -eq 1 ]; then
      delete_output="$(printf 'y\n' | cscli bouncers delete "$BOUNCER_NAME" 2>&1)"
      delete_rc=$?
    fi
    [ $delete_rc -ne 0 ] && { warning "Не удалось удалить старый баунсер, продолжаю"; echo "$delete_output"; }
  fi

  local bouncer_key_json
  bouncer_key_json="$(cscli bouncers add "$BOUNCER_NAME" -o json 2>&1)"
  if [ $? -ne 0 ]; then
    error "Не удалось создать API ключ"
    echo "$bouncer_key_json"
    exit 1
  fi

  BOUNCER_API_KEY="$(echo "$bouncer_key_json" | jq -r 'if type=="string" then . elif type=="object" then (.api_key // .key // .credentials.api_key // .credentials.key // empty) else empty end' 2>/dev/null | head -n1)"
  if ! echo "$BOUNCER_API_KEY" | grep -Eq "$API_KEY_REGEX"; then
    BOUNCER_API_KEY=""
  fi
  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    # Last-resort JSON fallback for non-standard nesting from older/newer cscli versions.
    BOUNCER_API_KEY="$(echo "$bouncer_key_json" | jq -r '.. | .api_key? // .key? // empty' 2>/dev/null | head -n1)"
    if ! echo "$BOUNCER_API_KEY" | grep -Eq "$API_KEY_REGEX"; then
      BOUNCER_API_KEY=""
    fi
  fi
  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    # Fallback: extract token-like value only from key=value or key: value patterns.
    BOUNCER_API_KEY="$(echo "$bouncer_key_json" | grep -Eio "(api[ _-]?key|key)[^:=]*[:=][[:space:]]*[-A-Za-z0-9_+/=]{${API_KEY_FALLBACK_MIN_LEN},}" | grep -Eo "[-A-Za-z0-9_+/=]{${API_KEY_FALLBACK_MIN_LEN},}" | head -n1)"
    [ -n "$BOUNCER_API_KEY" ] && warning "API ключ извлечён fallback-парсингом текста, проверьте корректность"
  fi
  if [ -z "$BOUNCER_API_KEY" ] || [ "$BOUNCER_API_KEY" = "null" ]; then
    error "API ключ пустой или невалидный"
    exit 1
  fi
  success "API ключ для баунсера создан"

  mkdir -p "$(dirname "$BOUNCER_CONFIG")" || { error "Не удалось создать каталог для конфига баунсера"; exit 1; }

  if [ ! -s "$BOUNCER_CONFIG" ]; then
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
      if [ $? -ne 0 ]; then
        error "Не удалось добавить iptables_chains в $BOUNCER_CONFIG"
        exit 1
      fi

      if iptables -S DOCKER-USER >/dev/null 2>&1 || ip6tables -S DOCKER-USER >/dev/null 2>&1; then
        printf '  - DOCKER-USER\n' >> "$BOUNCER_CONFIG" || {
          error "Не удалось добавить DOCKER-USER в $BOUNCER_CONFIG"
          exit 1
        }
      fi
    fi
    success "Создан новый конфиг баунсера: $BOUNCER_CONFIG"
  else
    sed -i -E "s|^api_key:.*|api_key: \"${BOUNCER_API_KEY}\"|g" "$BOUNCER_CONFIG"
    if [ $? -ne 0 ]; then
      error "Не удалось обновить api_key в $BOUNCER_CONFIG"
      exit 1
    fi

    if grep -q "^api_url:" "$BOUNCER_CONFIG"; then
      sed -i -E "s|^api_url:.*|api_url: \"http://127.0.0.1:${LAPI_PORT}\"|g" "$BOUNCER_CONFIG" || {
        error "Не удалось обновить api_url в $BOUNCER_CONFIG"
        exit 1
      }
    else
      printf '\napi_url: "http://127.0.0.1:%s"\n' "$LAPI_PORT" >> "$BOUNCER_CONFIG" || {
        error "Не удалось добавить api_url в $BOUNCER_CONFIG"
        exit 1
      }
    fi

    if grep -q "^mode:" "$BOUNCER_CONFIG"; then
      sed -i -E "s|^mode:.*|mode: ${FIREWALL_MODE}|g" "$BOUNCER_CONFIG" || {
        error "Не удалось обновить mode в $BOUNCER_CONFIG"
        exit 1
      }
    else
      printf '\nmode: %s\n' "$FIREWALL_MODE" >> "$BOUNCER_CONFIG" || {
        error "Не удалось добавить mode в $BOUNCER_CONFIG"
        exit 1
      }
    fi
    success "Конфиг баунсера обновлен (api_key/api_url)"
  fi
}

configure_nginx_protection() {
  print_separator
  info "Обнаружена возможность настройки L7 защиты для Nginx"
  info "Будут установлены коллекции: nginx, http-crawlers, http-dos"
  if ! ask_yes_no "Установить защиту L7 для Nginx?"; then
    info "Настройка L7 для Nginx пропущена"
    return 0
  fi

  command -v nginx >/dev/null 2>&1 || dpkg -l nginx 2>/dev/null | grep -q "^ii"
  if [ $? -ne 0 ]; then
    warning "Nginx не установлен."
    if ! ask_yes_no "Продолжить установку коллекций без установленного Nginx?"; then
      info "Установка Nginx-коллекций отменена пользователем"
      return 0
    fi
  fi

  local collections=(
    "crowdsecurity/nginx"
    "crowdsecurity/http-crawlers"
    "crowdsecurity/http-dos"
    "crowdsecurity/iptables"
  )
  local collection
  for collection in "${collections[@]}"; do
    cscli collections install "$collection"
    if [ $? -ne 0 ]; then
      warning "Не удалось установить коллекцию: $collection"
    else
      success "Коллекция установлена: $collection"
    fi
  done

  touch "$ACQUISITION_YAML" || { error "Не удалось создать/открыть $ACQUISITION_YAML"; exit 1; }

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
      exit 1
    fi
    success "Добавлен блок Nginx в acquisition.yaml"
  else
    info "Блок Nginx уже присутствует в acquisition.yaml"
  fi

  [ -f /var/log/nginx/access.log ] || warning "access.log не найден, Nginx возможно не запускался"
}

finalize_installation() {
  systemctl daemon-reload || { error "Не удалось выполнить systemctl daemon-reload"; exit 1; }

  local service
  for service in crowdsec crowdsec-firewall-bouncer; do
    systemctl enable "$service"
    [ $? -ne 0 ] && warning "Не удалось включить автозапуск $service"
  done

  systemctl restart crowdsec || { error "Не удалось перезапустить crowdsec"; exit 1; }
  sleep "$CROWDSEC_RESTART_WAIT_SECONDS"

  systemctl restart crowdsec-firewall-bouncer || { error "Не удалось перезапустить crowdsec-firewall-bouncer"; exit 1; }
  sleep "$BOUNCER_RESTART_WAIT_SECONDS"

  for service in crowdsec crowdsec-firewall-bouncer; do
    systemctl is-active --quiet "$service"
    if [ $? -eq 0 ]; then
      success "$service — работает"
    else
      error "$service — не запустился"
      journalctl -u "$service" --no-pager -n 20
    fi
  done

  cscli bouncers list
  echo ""
  cscli metrics --no-unit 2>/dev/null | head -30
}

connect_console() {
  local console_token
  local enroll_output

  info "Подключение к CrowdSec Console"
  echo "1) Откройте ${CONSOLE_URL}"
  echo "2) Перейдите в Security Engines -> Add Security Engine"
  echo "3) Скопируйте Enrollment Token"

  while true; do
    read -rsp "$(echo -e "${YELLOW}➤ Вставьте Enrollment Token и нажмите Enter: ${NC}")" console_token </dev/tty
    echo ""
    if [ -z "$console_token" ]; then
      warning "Токен не может быть пустым."
      continue
    fi
    if ! echo "$console_token" | grep -Eq '^[A-Za-z0-9._+=-]{10,}$'; then
      warning "Токен выглядит некорректно (разрешены только латиница/цифры и . _ + = -)."
      continue
    fi
    break
  done

  local enroll_rc
  enroll_output="$(cscli console enroll "$console_token" 2>&1)"
  enroll_rc=$?

  console_token=""

  if [ "$enroll_rc" -ne 0 ]; then
    warning "Не удалось выполнить enrollment в Console. Шаг будет пропущен."
    echo "$enroll_output" | tee -a "$LOG_FILE"
    info "Продолжаю установку без подключения к CrowdSec Console."
    return 0
  fi
  success "Enrollment token принят."

  read -rp "$(echo -e "${YELLOW}➤ Подтвердите подключение на ${CONSOLE_URL}, затем нажмите Enter для продолжения: ${NC}")" _ </dev/tty

  systemctl restart crowdsec || { error "Не удалось перезапустить crowdsec после подтверждения в Console"; exit 1; }
  sleep "$CROWDSEC_RESTART_WAIT_SECONDS"
  success "crowdsec перезапущен после подключения к Console"
}

print_final_summary() {
  local key_preview
  if [ -n "$BOUNCER_API_KEY" ] && [ "$BOUNCER_API_KEY" != "null" ]; then
    key_preview="${BOUNCER_API_KEY:0:8}... (скрыт)"
  else
    key_preview="недоступен"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "           ✅  УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  📌 КОНФИГУРАЦИЯ:"
  echo "     LAPI Порт:     ${LAPI_PORT}"
  echo "     Баунсер:       ${BOUNCER_NAME}"
  echo "     API Ключ:      ${key_preview}"
  echo "     Console:       ${CONSOLE_URL}"
  echo ""
  echo "  📊 ПОЛЕЗНЫЕ КОМАНДЫ:"
  echo "     Список баунсеров:  cscli bouncers list"
  echo "     Список решений:    cscli decisions list"
  echo "     Метрики:           cscli metrics"
  echo "     Логи CrowdSec:     journalctl -u crowdsec -f"
  echo "     Логи Баунсера:     journalctl -u crowdsec-firewall-bouncer -f"
  echo "     Лог установки:     cat /var/log/crowdsec-install.log"
  echo ""
  echo "  🌐 WEB DASHBOARD (опционально):"
  echo "     cscli dashboard setup --listen 0.0.0.0"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =========================================================
# 4. MAIN() — точка входа, вызывающая шаги по порядку
# =========================================================

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✘] Этот скрипт должен запускаться от root. Используйте: sudo bash crowdsecinstall.sh${NC}" >&2
    exit 1
  fi

  init_logging
  success "Проверка root пройдена"
  print_banner

  print_separator
  step "ШАГ 1/7: Pre-flight проверки"
  preflight_checks

  print_separator
  step "ШАГ 2/7: Установка CrowdSec"
  install_crowdsec

  print_separator
  step "ШАГ 3/7: Конфигурация LAPI порта"
  configure_lapi_port

  print_separator
  step "ШАГ 4/7: Установка и конфигурация Firewall Bouncer"
  install_and_configure_bouncer

  print_separator
  step "ШАГ 5/7: Настройка L7 защиты (Nginx)"
  configure_nginx_protection

  print_separator
  step "ШАГ 6/7: Финализация и запуск сервисов"
  finalize_installation

  print_separator
  step "ШАГ 7/7: Подключение к CrowdSec Console"
  connect_console

  print_final_summary
}

# =========================================================
# 5. Вызов main() в конце файла
# =========================================================

main "$@"
