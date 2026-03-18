#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[deploy] %s\n' "$*" >&2
}

error() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

APP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$APP_ROOT/.env"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" != *=* ]] && continue

      local key="${line%%=*}"
      local value="${line#*=}"

      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"

      if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
      fi

      printf -v "$key" '%s' "$value"
      export "$key"
    done < "$ENV_FILE"
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
    case "$(lowercase "$reply")" in
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
    ss -ltnH 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" { found = 1 } END { exit(found ? 0 : 1) }' && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "LISTEN|LISTENING" | grep -Eq "[.:]$port( |$)" && return 0
  fi
  return 1
}

docker_port_owned() {
  local port="$1"
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local container_id
  container_id=$(compose_service_container_id)
  if [[ -z "$container_id" ]]; then
    return 1
  fi

  if docker port "$container_id" 80/tcp 2>/dev/null | grep -Eq "(^|:)${port}$"; then
    return 0
  fi
  return 1
}

ensure_port_available() {
  local port="$1"
  log "Checking port ${port} for conflicts"
  if port_in_use "$port"; then
    if docker_port_owned "$port"; then
      log "Port ${port} is already held by Docker; assuming the existing container belongs to this deployment."
      return
    fi
    error "Port ${port} is already listening on this host. Stop the conflicting service or set DOCKER_PORT to a different value before rerunning deploy.sh."
  fi
}

find_available_port() {
  local candidate="${1:-8080}"
  while (( candidate <= 65535 )); do
    if docker_port_owned "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
    if ! port_in_use "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
    log "Port ${candidate} is busy; trying $((candidate + 1))"
    candidate=$((candidate + 1))
  done
  error "Unable to find a free port from ${1:-8080} up to 65535; please set DOCKER_PORT manually."
}

compose_service_container_id() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$APP_ROOT/docker-compose.yml" ps -q powernet-site 2>/dev/null | tail -n 1
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$APP_ROOT/docker-compose.yml" ps -q powernet-site 2>/dev/null | tail -n 1
  fi
}

compose_service_running() {
  local container_id
  container_id=$(compose_service_container_id)
  [[ -n "$container_id" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == "true" ]]
}

run_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$APP_ROOT/docker-compose.yml" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$APP_ROOT/docker-compose.yml" "$@"
  else
    error 'Docker Compose v2 or v1 is required to start the container'
  fi
}

wait_for_compose_service() {
  local attempts=0
  local max_attempts=30

  while (( attempts < max_attempts )); do
    if compose_service_running; then
      return
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  error 'Docker container did not reach the running state in time'
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

  if [[ "$(lowercase "${PRODUCTION_ENABLE_SSL}")" == "true" ]]; then
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
  local openssl_config="$cert_dir_current/${primary_host}.cnf"
  local regenerate_ssl=false

  if [[ ! -f "$cert_working" || ! -f "$key_working" || "${PRODUCTION_SSL_HOSTS:-}" != "$PRODUCTION_HOSTNAME" ]]; then
    regenerate_ssl=true
  fi

  if [[ "$regenerate_ssl" == true ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      error "'openssl' is required to generate certificates"
    fi

    local san_index=1
    {
      printf '[req]\n'
      printf 'distinguished_name=req_distinguished_name\n'
      printf 'x509_extensions=v3_req\n'
      printf 'prompt=no\n'
      printf '[req_distinguished_name]\n'
      printf 'CN=%s\n' "$primary_host"
      printf '[v3_req]\n'
      printf 'subjectAltName=@alt_names\n'
      printf '[alt_names]\n'
      for hostname in $PRODUCTION_HOSTNAME; do
        printf 'DNS.%s=%s\n' "$san_index" "$hostname"
        san_index=$((san_index + 1))
      done
    } > "$openssl_config"

    log "Generating self-signed certificate for ${PRODUCTION_HOSTNAME}"
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:4096 \
      -keyout "$key_working" \
      -out "$cert_working" \
      -config "$openssl_config" \
      -extensions v3_req >/dev/null 2>&1
    rm -f "$openssl_config"
  fi

  local host_cert_dir="${HOST_SSL_CERT_DIR:-/etc/ssl/powernet}"
  local target_cert="$host_cert_dir/$cert_name"
  if [[ "$regenerate_ssl" == false && -n "${PRODUCTION_SSL_CERT_PATH:-}" && -f "${PRODUCTION_SSL_CERT_PATH}" ]]; then
    target_cert="${PRODUCTION_SSL_CERT_PATH}"
  fi
  local target_key="$host_cert_dir/$key_name"
  if [[ "$regenerate_ssl" == false && -n "${PRODUCTION_SSL_KEY_PATH:-}" && -f "${PRODUCTION_SSL_KEY_PATH}" ]]; then
    target_key="${PRODUCTION_SSL_KEY_PATH}"
  fi

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
  upsert_env_value PRODUCTION_SSL_HOSTS "$PRODUCTION_HOSTNAME"
}

start_docker_site() {
  log 'Ensuring Docker container is running'
  if ! command -v docker >/dev/null 2>&1; then
    error 'Docker CLI is required but not installed'
  fi

  local desired_port="${DOCKER_PORT:-8080}"
  local docker_port
  docker_port=$(find_available_port "$desired_port")
  export DOCKER_PORT="$docker_port"
  upsert_env_value DOCKER_PORT "$docker_port"
  log "Binding Docker container to host port ${docker_port}"

  COMPOSE_PROGRESS=plain run_compose up -d --build --remove-orphans
  wait_for_compose_service
}

deploy_with_docker() {
  log 'Docker deployment selected (nginx not found on host)'
  start_docker_site
}

write_nginx_proxy_conf() {
  local config_path="$1"
  local proxy_port="$2"
  local server_name="$3"
  local ssl_enabled="$4"
  local cert_path="${PRODUCTION_SSL_CERT_PATH:-}"
  local key_path="${PRODUCTION_SSL_KEY_PATH:-}"

  local temp
  temp=$(mktemp)
  cat <<EOF > "$temp"
upstream powernet-site {
  server 127.0.0.1:${proxy_port};
}

server {
  listen 80;
  server_name ${server_name};

  location / {
    proxy_pass http://powernet-site;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  if [[ "$ssl_enabled" == true && -n "$cert_path" && -n "$key_path" ]]; then
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

  location / {
    proxy_pass http://powernet-site;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
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

resolve_nginx_conf_path() {
  if [[ -n "${HOST_NGINX_CONF:-}" ]]; then
    printf '%s' "$HOST_NGINX_CONF"
    return
  fi

  if [[ -d /etc/nginx/conf.d ]]; then
    printf '/etc/nginx/conf.d/powernet-site.conf'
    return
  fi

  if [[ -d /etc/nginx/sites-available ]]; then
    printf '/etc/nginx/sites-available/powernet-site.conf'
    return
  fi

  printf '/etc/nginx/conf.d/powernet-site.conf'
}

activate_nginx_conf() {
  local config_path="$1"
  if [[ "$config_path" == /etc/nginx/sites-available/* && -d /etc/nginx/sites-enabled ]]; then
    run_as_root ln -sfn "$config_path" "/etc/nginx/sites-enabled/$(basename "$config_path")"
  fi
}

cleanup_legacy_nginx_configs() {
  local active_path="$1"
  local known_paths=(
    /etc/nginx/conf.d/powernet-site.conf
    /etc/nginx/sites-available/powernet-site.conf
    /etc/nginx/sites-enabled/powernet-site.conf
  )

  for path in "${known_paths[@]}"; do
    if [[ "$path" != "$active_path" && -e "$path" ]]; then
      run_as_root rm -f "$path"
    fi
  done
}

deploy_to_host_nginx() {
  local config_path
  config_path=$(resolve_nginx_conf_path)
  log 'Host nginx detected; proxying to Docker container'

  start_docker_site

  local proxy_port="${DOCKER_PORT:-8080}"
  local server_scopes="${PRODUCTION_HOSTNAME:-$(infer_server_name)}"
  local ssl_enabled=false
  if [[ "$(lowercase "${PRODUCTION_ENABLE_SSL}")" == "true" && -n "${PRODUCTION_SSL_CERT_PATH:-}" && -n "${PRODUCTION_SSL_KEY_PATH:-}" ]]; then
    ssl_enabled=true
  fi

  write_nginx_proxy_conf "$config_path" "$proxy_port" "$server_scopes" "$ssl_enabled"
  activate_nginx_conf "$config_path"
  cleanup_legacy_nginx_configs "$config_path"

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
  local deploy_env="${DEPLOY_ENV:-production}"
  log "Deployment target: $deploy_env"

  ensure_production_config true

  if command -v nginx >/dev/null 2>&1; then
    deploy_to_host_nginx
  else
    deploy_with_docker
  fi

  log 'Deployment complete'
}

main "$@"
