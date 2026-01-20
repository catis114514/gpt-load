#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-gpt-load}"

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

run_with_systemd() {
  local working_dir
  working_dir="$(pwd)"

  local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    if ! command_exists sudo; then
      log "sudo is required to install a systemd service."
      return 1
    fi
    sudo_cmd="sudo"
  fi

  log "Installing systemd service: ${SERVICE_NAME}"
  ${sudo_cmd} bash -c "cat > '${unit_path}'" <<UNIT
[Unit]
Description=GPT-Load
After=network.target

[Service]
Type=simple
WorkingDirectory=${working_dir}
EnvironmentFile=${working_dir}/.env
ExecStart=${working_dir}/dist/gpt-load
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  ${sudo_cmd} systemctl daemon-reload
  ${sudo_cmd} systemctl enable --now "${SERVICE_NAME}.service"
  log "Systemd service started. Check status with: systemctl status ${SERVICE_NAME}.service"
}

run_in_background() {
  local log_dir="data/logs"
  mkdir -p "${log_dir}"
  log "Systemd not available; starting in background (logs: ${log_dir}/gpt-load.out)"
  nohup ./dist/gpt-load >"${log_dir}/gpt-load.out" 2>&1 &
}

main() {
  if [ ! -f ".env" ]; then
    if [ ! -f ".env.example" ]; then
      log "Missing .env.example in the project root."
      exit 1
    fi
    cp .env.example .env
  fi

  local current_key
  current_key="$(grep -E '^AUTH_KEY=' .env | head -n1 | cut -d'=' -f2- || true)"

  if [ -z "$current_key" ]; then
    local new_key
    if [ -n "${AUTH_KEY:-}" ]; then
      new_key="$AUTH_KEY"
    else
      if ! new_key="$(prompt_auth_key)"; then
        log "Failed to generate a random AUTH_KEY. Please edit .env manually."
        exit 1
      fi
    fi

    update_env_value "AUTH_KEY" "$new_key" ".env"
    log "Configured AUTH_KEY and wrote to .env."
    log "Please store this key securely."
  fi

  if [ ! -f "dist/gpt-load" ]; then
    log "Missing dist/gpt-load. Build on another machine and upload it here."
    exit 1
  fi

  chmod +x dist/gpt-load

  if command_exists systemctl; then
    run_with_systemd
    return 0
  fi

  run_in_background
}

main "$@"
