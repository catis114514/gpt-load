#!/usr/bin/env bash
set -euo pipefail

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

main() {
  if ! command_exists go; then
    log "Go is required but was not found."
    exit 1
  fi

  if ! command_exists node || ! command_exists npm; then
    log "Node.js and npm are required but were not found."
    exit 1
  fi

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

  log "Downloading Go modules..."
  go mod download

  log "Building frontend..."
  (cd web && npm install && npm run build)

  log "Starting backend..."
  go run ./main.go
}

main "$@"
