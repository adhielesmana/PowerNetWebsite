#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[deploy] %s\n' "$*"
}

error() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

APP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$APP_ROOT/.env"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +o allexport
  fi
}

run_as_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    error "root privileges are required for this step but 'sudo' is unavailable"
  fi
}

upsert_env_value() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$ENV_FILE" ]]; then
    awk -v key="$key" -v value="$value" 'BEGIN { pattern = "^" key "="; found = 0 }
      $0 ~ pattern { print key "=" value; found = 1; next }
      { print }
      END { if (!found) print key "=" value }' "$ENV_FILE" > "$tmp"
  else
    printf '%s\n' "$key=$value" > "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local reply
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " reply
  else
    read -rp "$prompt: " reply
  fi
  if [[ -z "$reply" ]]; then
    reply="$default"
  fi
  printf '%s' "$reply"
}

prompt_bool() {
  local prompt="$1"
  local default="${2:-y}"
  local reply
  while true; do
    read -rp "$prompt [y/n] (default: $default): " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Please answer y or n.\n' ;;
    esac
  done
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  elif command -v ss >/dev/null 2>&1; then
    ss -tnl "( sport = :$port )" >/dev/null 2>&1 && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "LISTEN|LISTENING" | grep -Eq "[.:]$port( |$)" && return 0
  fi
  return 1
}

ensure_port_available() {
  local port="$1"
  log "Checking port ${port} for conflicts"
  if port_in_use "$port"; then
    error "Port ${port} is already listening on this host. Stop the conflicting service or set DOCKER_PORT to a different value before rerunning deploy.sh."
  fi
}

infer_server_name() {
  if [[ -n "${PRODUCTION_HOSTNAME:-}" ]]; then
    printf '%s' "$PRODUCTION_HOSTNAME"
    return
  fi

  if command -v hostname >/dev/null 2>&1; then
    local host_name
    host_name=$(hostname -f 2>/dev/null || hostname)
    if [[ -n "$host_name" ]]; then
      printf '%s' "$host_name"
      return
    fi
  fi

  printf '_'
}

ensure_production_config() {
  local prompt_when_dev="${1:-false}"
  local deploy_env="${DEPLOY_ENV:-development}"
  if [[ "$deploy_env" != "production" && "$prompt_when_dev" != "true" ]]; then
    return
  fi

  if [[ -z "${PRODUCTION_HOSTNAME:-}" ]]; then
    local hostname
    hostname=$(prompt_value 'Enter the production hostname (e.g. powernet.example.com)')
    if [[ -z "$hostname" ]]; then
      error 'Production hostname is required when DEPLOY_ENV=production'
    fi
    PRODUCTION_HOSTNAME="$hostname"
    upsert_env_value PRODUCTION_HOSTNAME "$hostname"
  fi

  if [[ -z "${PRODUCTION_ENABLE_SSL:-}" ]]; then
    if prompt_bool 'Enable HTTPS with a self-signed certificate?' y; then
      PRODUCTION_ENABLE_SSL=true
    else
      PRODUCTION_ENABLE_SSL=false
    fi
    upsert_env_value PRODUCTION_ENABLE_SSL "${PRODUCTION_ENABLE_SSL}"
  fi

  if [[ "${PRODUCTION_ENABLE_SSL,,}" == "true" ]]; then
    generate_ssl_assets
  fi
}

generate_ssl_assets() {
  local cert_dir_current="$APP_ROOT/certs"
  mkdir -p "$cert_dir_current"
  local primary_host="${PRODUCTION_HOSTNAME%% *}"
  primary_host="${primary_host//[^[:alnum:].-]/_}"
  if [[ -z "$primary_host" ]]; then
    primary_host="powernet-site"
  fi
  local cert_name="${primary_host}.crt"
  local key_name="${primary_host}.key"
  local cert_working="$cert_dir_current/$cert_name"
  local key_working="$cert_dir_current/$key_name"

  if [[ ! -f "$cert_working" || ! -f "$key_working" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      error "'openssl' is required to generate certificates"
    fi
    log "Generating self-signed certificate for ${PRODUCTION_HOSTNAME}"
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:4096 \
      -keyout "$key_working" \
      -out "$cert_working" \
      -subj "/CN=${PRODUCTION_HOSTNAME}" >/dev/null 2>&1
  fi

  local host_cert_dir="${HOST_SSL_CERT_DIR:-/etc/ssl/powernet}"
  local target_cert="${PRODUCTION_SSL_CERT_PATH:-$host_cert_dir/$cert_name}"
  local target_key="${PRODUCTION_SSL_KEY_PATH:-$host_cert_dir/$key_name}"

  run_as_root mkdir -p "$(dirname "$target_cert")"
  run_as_root mkdir -p "$(dirname "$target_key")"
  run_as_root cp -f "$cert_working" "$target_cert"
  run_as_root cp -f "$key_working" "$target_key"
  run_as_root chmod 644 "$target_cert"
  run_as_root chmod 600 "$target_key"

  PRODUCTION_SSL_CERT_PATH="$target_cert"
  PRODUCTION_SSL_KEY_PATH="$target_key"
  upsert_env_value PRODUCTION_SSL_CERT_PATH "$target_cert"
  upsert_env_value PRODUCTION_SSL_KEY_PATH "$target_key"
}

deploy_with_docker() {
  log 'Docker deployment selected (nginx not found on host)'
  if ! command -v docker >/dev/null 2>&1; then
    error 'Docker CLI is required but not installed'
  fi

  local docker_port="${DOCKER_PORT:-8080}"
  ensure_port_available "$docker_port"
  export DOCKER_PORT="$docker_port"
  log "Binding container to host port ${docker_port}"

  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$APP_ROOT/docker-compose.yml" up -d --build
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$APP_ROOT/docker-compose.yml" up -d --build
  else
    error 'Docker Compose v2 or v1 is required to start the container'
  fi
}

write_nginx_conf() {
  local config_path="$1"
  local site_root="$2"
  local server_name
  server_name=$(infer_server_name)
  local ssl_enabled=false
  local cert_path="${PRODUCTION_SSL_CERT_PATH:-}"
  local key_path="${PRODUCTION_SSL_KEY_PATH:-}"

  if [[ "${PRODUCTION_ENABLE_SSL,,}" == "true" && -n "$cert_path" && -n "$key_path" ]]; then
    ssl_enabled=true
  fi

  local temp
  temp=$(mktemp)
  cat <<EOF > "$temp"
server {
  listen 80;
  server_name ${server_name};

  root ${site_root};
  index index.html;
EOF

  if [[ "$ssl_enabled" == true ]]; then
    cat <<'EOF' >> "$temp"
  return 301 https://$host$request_uri;
}
EOF
    cat <<EOF >> "$temp"
server {
  listen 443 ssl http2;
  server_name ${server_name};

  ssl_certificate ${cert_path};
  ssl_certificate_key ${key_path};
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;
  ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM';
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 10m;

  root ${site_root};
  index index.html;
EOF
    cat <<'EOF' >> "$temp"
  location / {
    try_files $uri $uri/ /index.html;
  }

  location ~* \.(png|jpg|jpeg|gif|svg|ico|css|js|woff|woff2)$ {
    expires 7d;
    add_header Cache-Control "public, max-age=604800, immutable";
  }
}
EOF
  else
    cat <<'EOF' >> "$temp"
  location / {
    try_files $uri $uri/ /index.html;
  }

  location ~* \.(png|jpg|jpeg|gif|svg|ico|css|js|woff|woff2)$ {
    expires 7d;
    add_header Cache-Control "public, max-age=604800, immutable";
  }
}
EOF
  fi

  run_as_root mkdir -p "$(dirname "$config_path")"
  run_as_root cp "$temp" "$config_path"
  rm -f "$temp"
}

reload_nginx_service() {
  if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl reload nginx
  elif command -v service >/dev/null 2>&1; then
    run_as_root service nginx reload
  else
    run_as_root nginx -s reload
  fi
}

deploy_to_host_nginx() {
  local site_root="${HOST_NGINX_ROOT:-/var/www/powernet-site}"
  local config_path="${HOST_NGINX_CONF:-/etc/nginx/conf.d/powernet-site.conf}"
  log 'Host nginx detected; syncing static assets and configuration'
  ensure_production_config true
  if [[ ! -d "$site_root" ]]; then
    run_as_root mkdir -p "$site_root"
  fi

  for entry in index.html styles.css script.js assets vendor; do
    if [[ -e "$APP_ROOT/$entry" ]]; then
      run_as_root rm -rf "$site_root/$entry" >/dev/null 2>&1 || true
      run_as_root cp -a "$APP_ROOT/$entry" "$site_root/"
    fi
  done

  write_nginx_conf "$config_path" "$site_root"

  log 'Validating nginx configuration'
  run_as_root nginx -t
  log 'Reloading nginx'
  reload_nginx_service
}

main() {
  load_env
  PRODUCTION_ENABLE_SSL="${PRODUCTION_ENABLE_SSL:-}"
  PRODUCTION_HOSTNAME="${PRODUCTION_HOSTNAME:-}"
  PRODUCTION_SSL_CERT_PATH="${PRODUCTION_SSL_CERT_PATH:-}"
  PRODUCTION_SSL_KEY_PATH="${PRODUCTION_SSL_KEY_PATH:-}"
  local deploy_env="${DEPLOY_ENV:-development}"
  log "Deployment target: $deploy_env"

  ensure_production_config

  if command -v nginx >/dev/null 2>&1; then
    deploy_to_host_nginx
  else
    deploy_with_docker
  fi

  log 'Deployment complete'
}

main "$@"
