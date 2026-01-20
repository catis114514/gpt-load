#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-gpt-load}"
BIN_PATH="/usr/local/bin/gpt-load"
ENV_DIR="/etc/gpt-load"
ENV_FILE="${ENV_DIR}/env"
LOG_DIR="${ENV_DIR}/logs"
LOG_FILE="${LOG_DIR}/gpt-load.out"
MAX_LOG_BYTES=$((5 * 1024 * 1024))

log() {
  printf "[gpt-load] %s\n" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

generate_random() {
  if command_exists openssl; then
    openssl rand -hex 16
    return 0
  fi

  if command_exists python3; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
    return 0
  fi

  return 1
}

update_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -q "^${key}=" "$file"; then
    sed -i.bak "s#^${key}=.*#${key}=${value}#" "$file"
  else
    printf "\n%s=%s\n" "$key" "$value" >> "$file"
  fi
  rm -f "${file}.bak"
}

prompt_auth_key() {
  local input_key

  printf "Enter AUTH_KEY (leave empty to auto-generate): "
  read -r input_key
  if [ -n "$input_key" ]; then
    printf "%s" "$input_key"
    return 0
  fi

  if ! input_key="$(generate_random)"; then
    return 1
  fi

  printf "sk-prod-%s" "$input_key"
}

require_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    echo ""
    return 0
  fi

  if ! command_exists sudo; then
    log "sudo is required for this operation."
    exit 1
  fi

  echo "sudo"
}

ensure_env_file() {
  local source_env=""

  if [ -f "${ENV_FILE}" ]; then
    source_env="${ENV_FILE}"
  elif [ -f ".env" ]; then
    source_env=".env"
  else
    if [ -f ".env.example" ]; then
      cp .env.example .env
      source_env=".env"
    else
      log "Missing .env or .env.example in the current directory."
      exit 1
    fi
  fi

  if [ "$source_env" != "${ENV_FILE}" ]; then
    mkdir -p "${ENV_DIR}"
    mv "$source_env" "${ENV_FILE}"
  fi
}

ensure_auth_key() {
  local current_key
  current_key="$(grep -E '^AUTH_KEY=' "${ENV_FILE}" | head -n1 | cut -d'=' -f2- || true)"

  if [ -z "$current_key" ]; then
    local new_key
    if [ -n "${AUTH_KEY:-}" ]; then
      new_key="$AUTH_KEY"
    else
      if ! new_key="$(prompt_auth_key)"; then
        log "Failed to generate a random AUTH_KEY. Please edit ${ENV_FILE} manually."
        exit 1
      fi
    fi

    update_env_value "AUTH_KEY" "$new_key" "${ENV_FILE}"
    log "Configured AUTH_KEY and wrote to ${ENV_FILE}."
    log "Please store this key securely."
  fi
}

rotate_log_if_needed() {
  if [ -f "${LOG_FILE}" ]; then
    local size
    size=$(stat -c%s "${LOG_FILE}")
    if [ "$size" -ge "$MAX_LOG_BYTES" ]; then
      mv "${LOG_FILE}" "${LOG_FILE}.1"
      : > "${LOG_FILE}"
    fi
  fi
}

install_systemd_service() {
  if ! command_exists systemctl; then
    return 1
  fi

  local sudo_cmd
  sudo_cmd="$(require_sudo)"

  local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
  log "Installing systemd service: ${SERVICE_NAME}"
  ${sudo_cmd} bash -c "cat > '${unit_path}'" <<UNIT
[Unit]
Description=GPT-Load
After=network.target

[Service]
Type=simple
WorkingDirectory=${ENV_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  ${sudo_cmd} systemctl daemon-reload
  ${sudo_cmd} systemctl enable --now "${SERVICE_NAME}.service"
  log "Systemd service started. Check status with: systemctl status ${SERVICE_NAME}.service"
  return 0
}

run_in_background() {
  mkdir -p "${LOG_DIR}"
  rotate_log_if_needed
  log "Systemd not available; starting in background (logs: ${LOG_FILE})"
  nohup "${BIN_PATH}" >"${LOG_FILE}" 2>&1 &
}

install_or_update() {
  if [ ! -f "dist/gpt-load" ]; then
    log "Missing dist/gpt-load in the current directory. Build elsewhere and upload it here before installing."
    exit 1
  fi

  ensure_env_file
  ensure_auth_key

  local sudo_cmd
  sudo_cmd="$(require_sudo)"

  ${sudo_cmd} mkdir -p "${ENV_DIR}" "${LOG_DIR}"
  ${sudo_cmd} mv -f dist/gpt-load "${BIN_PATH}"
  ${sudo_cmd} chmod +x "${BIN_PATH}"

  if ! install_systemd_service; then
    run_in_background
  fi

  prompt_cleanup
}

start_service() {
  if command_exists systemctl; then
    local sudo_cmd
    sudo_cmd="$(require_sudo)"
    ${sudo_cmd} systemctl start "${SERVICE_NAME}.service"
    return 0
  fi

  run_in_background
}

stop_service() {
  if command_exists systemctl; then
    local sudo_cmd
    sudo_cmd="$(require_sudo)"
    ${sudo_cmd} systemctl stop "${SERVICE_NAME}.service"
    return 0
  fi

  pkill -f "${BIN_PATH}" || true
}

show_logs() {
  if command_exists systemctl; then
    local sudo_cmd
    sudo_cmd="$(require_sudo)"
    ${sudo_cmd} journalctl -u "${SERVICE_NAME}.service" -f
    return 0
  fi

  if [ ! -f "${LOG_FILE}" ]; then
    log "Log file not found: ${LOG_FILE}"
    exit 1
  fi
  tail -f "${LOG_FILE}"
}

edit_config() {
  local editor="${EDITOR:-vi}"
  if [ ! -f "${ENV_FILE}" ]; then
    log "Config file not found: ${ENV_FILE}"
    exit 1
  fi
  ${editor} "${ENV_FILE}"
}

uninstall() {
  local sudo_cmd
  sudo_cmd="$(require_sudo)"

  if command_exists systemctl; then
    ${sudo_cmd} systemctl stop "${SERVICE_NAME}.service" || true
    ${sudo_cmd} systemctl disable "${SERVICE_NAME}.service" || true
    ${sudo_cmd} rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    ${sudo_cmd} systemctl daemon-reload || true
  fi

  ${sudo_cmd} rm -f "${BIN_PATH}"
  ${sudo_cmd} rm -rf "${ENV_DIR}"

  log "Uninstalled ${SERVICE_NAME}."
}

prompt_cleanup() {
  local current_dir
  current_dir="$(pwd)"

  if [ ! -f "${current_dir}/scripts/one-click.sh" ]; then
    return 0
  fi

  printf "Delete installation directory (%s) to free space? [y/N]: " "${current_dir}"
  read -r answer
  case "$answer" in
    y|Y)
      rm -rf "${current_dir}"
      ;;
    *)
      ;;
  esac
}

show_menu() {
  while true; do
    cat <<MENU

GPT-Load Management Menu
[1] Install/Update
[2] Start Service
[3] Stop Service
[4] View Logs (tail -f)
[5] Edit Config
[6] Uninstall
[0] Exit
MENU
    printf "Select an option: "
    read -r choice
    case "$choice" in
      1) install_or_update ;;
      2) start_service ;;
      3) stop_service ;;
      4) show_logs ;;
      5) edit_config ;;
      6) uninstall ;;
      0) exit 0 ;;
      *) log "Invalid option." ;;
    esac
  done
}

main() {
  case "${1:-}" in
    install|update)
      install_or_update
      ;;
    start)
      start_service
      ;;
    stop)
      stop_service
      ;;
    logs)
      show_logs
      ;;
    edit)
      edit_config
      ;;
    uninstall)
      uninstall
      ;;
    "")
      show_menu
      ;;
    *)
      log "Usage: $0 [install|update|start|stop|logs|edit|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
