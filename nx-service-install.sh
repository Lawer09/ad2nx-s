#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-${1:-./scripts/install-from-git-linux.env}}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

log() {
  printf '[install] %s\n' "$*"
}

fail() {
  printf '[install][error] %s\n' "$*" >&2
  exit 1
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "please run as root"
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "required env is missing: $name"
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    fail "unsupported package manager, expected apt-get, dnf, or yum"
  fi
}

install_packages() {
  local packages=("$@")
  if [[ "${#packages[@]}" -eq 0 ]]; then
    return
  fi
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
  esac
}

ensure_base_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v tar >/dev/null 2>&1 || missing+=("tar")
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "installing base dependencies: ${missing[*]}"
    case "$PKG_MANAGER" in
      apt) install_packages ca-certificates "${missing[@]}" ;;
      dnf|yum) install_packages ca-certificates "${missing[@]}" ;;
    esac
  fi

  if [[ "${RUN_MIGRATIONS}" == "true" ]] && ! command -v psql >/dev/null 2>&1; then
    log "installing postgresql client"
    case "$PKG_MANAGER" in
      apt) install_packages postgresql-client ;;
      dnf|yum) install_packages postgresql ;;
    esac
  fi
}

url_encode() {
  local raw="$1"
  local encoded=""
  local i ch
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-]) encoded+="$ch" ;;
      *) printf -v encoded '%s%%%02X' "$encoded" "'$ch" ;;
    esac
  done
  printf '%s' "$encoded"
}

service_release_version() {
  local service="$1"
  case "$service" in
    gateway-service) printf '%s' "$GATEWAY_RELEASE_VERSION" ;;
    admin-service) printf '%s' "$ADMIN_RELEASE_VERSION" ;;
    node-service) printf '%s' "$NODE_RELEASE_VERSION" ;;
    *) fail "unsupported service: $service" ;;
  esac
}

service_release_url_override() {
  local service="$1"
  case "$service" in
    gateway-service) printf '%s' "${GATEWAY_RELEASE_URL:-}" ;;
    admin-service) printf '%s' "${ADMIN_RELEASE_URL:-}" ;;
    node-service) printf '%s' "${NODE_RELEASE_URL:-}" ;;
    *) fail "unsupported service: $service" ;;
  esac
}

service_release_url() {
  local service="$1"
  local version="$2"
  local override
  override="$(service_release_url_override "$service")"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return
  fi

  local repo_url="${RELEASE_REPO_URL%.git}"
  repo_url="${repo_url%/}"
  local tag
  tag="$(url_encode "${service}/${version}")"
  printf '%s/releases/download/%s/%s-%s-linux-amd64.tar.gz' "$repo_url" "$tag" "$service" "$version"
}

prepare_release_workspace() {
  if [[ -n "${RELEASE_WORK_DIR:-}" ]]; then
    RELEASE_WORK_DIR_AUTO_CREATED="false"
    mkdir -p "$RELEASE_WORK_DIR"
  else
    RELEASE_WORK_DIR_AUTO_CREATED="true"
    RELEASE_WORK_DIR="$(mktemp -d /tmp/nx-platform-service-release.XXXXXX)"
  fi
}

cleanup_release_workspace() {
  if [[ "${RELEASE_WORK_DIR_AUTO_CREATED:-false}" == "true" && -n "${RELEASE_WORK_DIR:-}" && -d "$RELEASE_WORK_DIR" ]]; then
    rm -rf "$RELEASE_WORK_DIR"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local -a curl_args=(
    -fsSL
    --retry 3
    --retry-delay 2
    --connect-timeout 15
    -H "User-Agent: nx-platform-service-installer"
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${curl_args[@]}" "$url" -o "$output"
}

download_release_archive() {
  local service="$1"
  local version="$2"
  local url archive
  url="$(service_release_url "$service" "$version")"
  archive="${RELEASE_WORK_DIR}/${service}-${version}-linux-amd64.tar.gz"
  log "downloading ${service} release ${version}"
  download_file "$url" "$archive"
  printf '%s' "$archive"
}

extract_release_archive() {
  local service="$1"
  local archive="$2"
  local extract_root="${RELEASE_WORK_DIR}/extract/${service}"
  rm -rf "$extract_root"
  mkdir -p "$extract_root"
  tar -C "$extract_root" -xzf "$archive"
  [[ -d "${extract_root}/${service}" ]] || fail "unexpected archive layout for ${service}: ${archive}"
  printf '%s' "${extract_root}/${service}"
}

normalize_defaults() {
  : "${SERVICES:=gateway-service admin-service node-service}"
  : "${APP_ENV:=prod}"
  : "${RELEASE_REPO_URL:=https://github.com/your-org/nx-platform-service}"
  : "${RELEASE_VERSION:=v0.1.0}"
  : "${GATEWAY_RELEASE_VERSION:=$RELEASE_VERSION}"
  : "${ADMIN_RELEASE_VERSION:=$RELEASE_VERSION}"
  : "${NODE_RELEASE_VERSION:=$RELEASE_VERSION}"
  : "${SERVICE_ROOT:=/opt}"
  : "${RUN_MIGRATIONS:=true}"
  : "${SEED_DEV:=false}"
  : "${START_SERVICES:=true}"
  : "${JWT_SECRET:=change-me}"
  : "${GATEWAY_HTTP_ADDR:=:8080}"
  : "${ADMIN_HTTP_ADDR:=:8081}"
  : "${NODE_HTTP_ADDR:=:8082}"
  : "${GATEWAY_LOG_LEVEL:=info}"
  : "${ADMIN_LOG_LEVEL:=info}"
  : "${NODE_LOG_LEVEL:=info}"
  : "${GATEWAY_REDIS_ADDR:=127.0.0.1:6379}"
  : "${GATEWAY_REDIS_PASSWORD:=}"
  : "${GATEWAY_REDIS_DB:=0}"
  : "${GATEWAY_REPLAY_WINDOW:=5m}"
  : "${ADMIN_JWT_ACCESS_TTL:=2h}"
  : "${ADMIN_JWT_REFRESH_TTL:=168h}"
  : "${ADMIN_REDIS_ADDR:=127.0.0.1:6379}"
  : "${ADMIN_REDIS_PASSWORD:=}"
  : "${ADMIN_REDIS_DB:=0}"
  : "${NODE_REDIS_ADDR:=127.0.0.1:6379}"
  : "${NODE_REDIS_PASSWORD:=}"
  : "${NODE_REDIS_DB:=0}"
  : "${GATEWAY_ADMIN_BASE_URL:=http://127.0.0.1:8081}"
  : "${GATEWAY_NODE_BASE_URL:=http://127.0.0.1:8082}"

  : "${GATEWAY_JWT_SECRET:=$JWT_SECRET}"
  : "${ADMIN_JWT_SECRET:=$JWT_SECRET}"
  : "${ADMIN_INTERNAL_API_TOKEN:=${GATEWAY_ADMIN_INTERNAL_TOKEN:-change-me-admin-internal}}"
  : "${GATEWAY_ADMIN_INTERNAL_TOKEN:=$ADMIN_INTERNAL_API_TOKEN}"
  : "${NODE_INTERNAL_API_TOKEN:=${GATEWAY_NODE_INTERNAL_TOKEN:-change-me-node-internal}}"
  : "${GATEWAY_NODE_INTERNAL_TOKEN:=$NODE_INTERNAL_API_TOKEN}"
}

service_selected() {
  local target="$1"
  local service
  for service in $SERVICES; do
    [[ "$service" == "$target" ]] && return 0
  done
  return 1
}

validate_env() {
  local service version override
  for service in $SERVICES; do
    version="$(service_release_version "$service")"
    override="$(service_release_url_override "$service")"
    if [[ -z "$version" && -z "$override" ]]; then
      fail "release version or direct release URL is required for ${service}"
    fi
    if [[ -z "${RELEASE_REPO_URL:-}" && -z "$override" ]]; then
      fail "RELEASE_REPO_URL is required when ${service} does not specify a direct release URL"
    fi
  done

  if service_selected gateway-service; then
    require_env GATEWAY_MACHINE_CREDENTIALS
  fi
  if service_selected admin-service; then
    require_env ADMIN_DATABASE_DSN
  fi
  if service_selected node-service; then
    require_env NODE_DATABASE_DSN
  fi
}

write_gateway_config() {
  local config_path="$1"
  {
    printf 'app_name: gateway-service\n'
    printf 'app_env: "%s"\n' "$(yaml_escape "$APP_ENV")"
    printf 'http_addr: "%s"\n' "$(yaml_escape "$GATEWAY_HTTP_ADDR")"
    printf 'redis:\n'
    printf '  addr: "%s"\n' "$(yaml_escape "$GATEWAY_REDIS_ADDR")"
    printf '  password: "%s"\n' "$(yaml_escape "$GATEWAY_REDIS_PASSWORD")"
    printf '  db: %s\n' "$GATEWAY_REDIS_DB"
    printf '  prefix: gateway-service\n'
    printf 'jwt:\n'
    printf '  secret: "%s"\n' "$(yaml_escape "$GATEWAY_JWT_SECRET")"
    printf 'log:\n'
    printf '  level: "%s"\n' "$(yaml_escape "$GATEWAY_LOG_LEVEL")"
    printf '  format: json\n'
    printf 'security:\n'
    printf '  replay_window: "%s"\n' "$(yaml_escape "$GATEWAY_REPLAY_WINDOW")"
    printf 'apps: []\n'
    printf 'machines:\n'
    local old_ifs="$IFS"
    IFS=',' read -r -a machine_entries <<< "$GATEWAY_MACHINE_CREDENTIALS"
    IFS="$old_ifs"
    local count=0
    local entry machine_left machine_secret machine_id machine_subtype
    for entry in "${machine_entries[@]}"; do
      entry="$(echo "$entry" | xargs)"
      [[ -z "$entry" ]] && continue
      machine_left="${entry%%=*}"
      machine_secret="${entry#*=}"
      machine_id="${machine_left%%:*}"
      machine_subtype="${machine_left#*:}"
      if [[ "$machine_subtype" == "$machine_id" ]]; then
        machine_subtype="node_agent"
      fi
      if [[ -z "$machine_id" || -z "$machine_secret" || "$machine_id" == "$machine_secret" ]]; then
        fail "invalid GATEWAY_MACHINE_CREDENTIALS entry: $entry"
      fi
      printf '  - machine_id: "%s"\n' "$(yaml_escape "$machine_id")"
      printf '    subject_subtype: "%s"\n' "$(yaml_escape "$machine_subtype")"
      printf '    secret: "%s"\n' "$(yaml_escape "$machine_secret")"
      printf '    enabled: true\n'
      count=$((count + 1))
    done
    if [[ "$count" -eq 0 ]]; then
      fail "GATEWAY_MACHINE_CREDENTIALS did not produce any valid machine credentials"
    fi
    printf 'routes:\n'
    printf '  - name: admin-login\n'
    printf '    prefix: /api/v1/admin/auth/login\n'
    printf '    base_url: "%s"\n' "$(yaml_escape "$GATEWAY_ADMIN_BASE_URL")"
    printf '    auth: public\n'
    printf '    internal_token: "%s"\n' "$(yaml_escape "$GATEWAY_ADMIN_INTERNAL_TOKEN")"
    printf '    timeout: 10s\n'
    printf '    rate_limit:\n'
    printf '      enabled: true\n'
    printf '      key_by: ip\n'
    printf '      qps: 2\n'
    printf '      burst: 5\n'
    printf '    enabled: true\n'
    printf '  - name: admin-service\n'
    printf '    prefix: /api/v1/admin/\n'
    printf '    base_url: "%s"\n' "$(yaml_escape "$GATEWAY_ADMIN_BASE_URL")"
    printf '    auth: jwt\n'
    printf '    internal_token: "%s"\n' "$(yaml_escape "$GATEWAY_ADMIN_INTERNAL_TOKEN")"
    printf '    timeout: 10s\n'
    printf '    enabled: true\n'
    printf '  - name: node-service\n'
    printf '    prefix: /api/v2/agent/\n'
    printf '    base_url: "%s"\n' "$(yaml_escape "$GATEWAY_NODE_BASE_URL")"
    printf '    auth: machine_token\n'
    printf '    internal_token: "%s"\n' "$(yaml_escape "$GATEWAY_NODE_INTERNAL_TOKEN")"
    printf '    timeout: 10s\n'
    printf '    rate_limit:\n'
    printf '      enabled: true\n'
    printf '      key_by: machine_id\n'
    printf '      qps: 20\n'
    printf '      burst: 40\n'
    printf '    enabled: true\n'
  } > "$config_path"
}

write_admin_config() {
  local config_path="$1"
  {
    printf 'app_name: admin-service\n'
    printf 'app_env: "%s"\n' "$(yaml_escape "$APP_ENV")"
    printf 'http_addr: "%s"\n' "$(yaml_escape "$ADMIN_HTTP_ADDR")"
    printf 'database:\n'
    printf '  driver: postgres\n'
    printf '  dsn: "%s"\n' "$(yaml_escape "$ADMIN_DATABASE_DSN")"
    printf 'redis:\n'
    printf '  addr: "%s"\n' "$(yaml_escape "$ADMIN_REDIS_ADDR")"
    printf '  password: "%s"\n' "$(yaml_escape "$ADMIN_REDIS_PASSWORD")"
    printf '  db: %s\n' "$ADMIN_REDIS_DB"
    printf '  prefix: admin-service\n'
    printf 'jwt:\n'
    printf '  secret: "%s"\n' "$(yaml_escape "$ADMIN_JWT_SECRET")"
    printf '  access_ttl: "%s"\n' "$(yaml_escape "$ADMIN_JWT_ACCESS_TTL")"
    printf '  refresh_ttl: "%s"\n' "$(yaml_escape "$ADMIN_JWT_REFRESH_TTL")"
    printf 'log:\n'
    printf '  level: "%s"\n' "$(yaml_escape "$ADMIN_LOG_LEVEL")"
    printf '  format: json\n'
    printf 'internal:\n'
    printf '  api_token: "%s"\n' "$(yaml_escape "$ADMIN_INTERNAL_API_TOKEN")"
    printf '  services: []\n'
  } > "$config_path"
}

write_node_config() {
  local config_path="$1"
  {
    printf 'app_name: node-service\n'
    printf 'app_env: "%s"\n' "$(yaml_escape "$APP_ENV")"
    printf 'http_addr: "%s"\n' "$(yaml_escape "$NODE_HTTP_ADDR")"
    printf 'database:\n'
    printf '  driver: postgres\n'
    printf '  dsn: "%s"\n' "$(yaml_escape "$NODE_DATABASE_DSN")"
    printf 'redis:\n'
    printf '  addr: "%s"\n' "$(yaml_escape "$NODE_REDIS_ADDR")"
    printf '  password: "%s"\n' "$(yaml_escape "$NODE_REDIS_PASSWORD")"
    printf '  db: %s\n' "$NODE_REDIS_DB"
    printf '  prefix: node-service\n'
    printf 'log:\n'
    printf '  level: "%s"\n' "$(yaml_escape "$NODE_LOG_LEVEL")"
    printf '  format: json\n'
    printf 'internal:\n'
    printf '  api_token: "%s"\n' "$(yaml_escape "$NODE_INTERNAL_API_TOKEN")"
    printf '  timeout: 10s\n'
  } > "$config_path"
}

write_service_env() {
  local service="$1"
  local service_dir="$2"
  local env_path="/etc/${service}.env"
  {
    printf 'APP_NAME=%s\n' "$service"
    printf 'APP_ENV=%s\n' "$APP_ENV"
    case "$service" in
      gateway-service) printf 'HTTP_ADDR=%s\n' "$GATEWAY_HTTP_ADDR" ;;
      admin-service) printf 'HTTP_ADDR=%s\n' "$ADMIN_HTTP_ADDR" ;;
      node-service) printf 'HTTP_ADDR=%s\n' "$NODE_HTTP_ADDR" ;;
    esac
    printf 'CONFIG_FILE=%s/configs/config.yaml\n' "$service_dir"
  } > "$env_path"
  chmod 600 "$env_path"
}

write_systemd_unit() {
  local service="$1"
  local service_dir="$2"
  local unit_path="/etc/systemd/system/${service}.service"
  {
    printf '[Unit]\n'
    printf 'Description=NX %s\n' "$service"
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n\n'
    printf '[Service]\n'
    printf 'WorkingDirectory=%s\n' "$service_dir"
    printf 'EnvironmentFile=/etc/%s.env\n' "$service"
    printf 'ExecStart=%s/bin/%s\n' "$service_dir" "$service"
    printf 'Restart=always\n'
    printf 'RestartSec=3\n'
    printf 'LimitNOFILE=1048576\n\n'
    printf '[Install]\n'
    printf 'WantedBy=multi-user.target\n'
  } > "$unit_path"
}

install_service_artifacts() {
  local service="$1"
  local package_dir="$2"
  local service_dir="${SERVICE_ROOT}/${service}"
  mkdir -p "$service_dir"
  rm -rf "${service_dir}/bin" "${service_dir}/configs" "${service_dir}/deploy" "${service_dir}/migrations"
  rm -f "${service_dir}/README.md"
  cp -a "${package_dir}/." "$service_dir/"
  mkdir -p "${service_dir}/bin" "${service_dir}/configs"
  install -m 0755 "${package_dir}/bin/${service}" "${service_dir}/bin/${service}"

  case "$service" in
    gateway-service) write_gateway_config "${service_dir}/configs/config.yaml" ;;
    admin-service) write_admin_config "${service_dir}/configs/config.yaml" ;;
    node-service) write_node_config "${service_dir}/configs/config.yaml" ;;
    *) fail "unsupported service: $service" ;;
  esac

  write_service_env "$service" "$service_dir"
  write_systemd_unit "$service" "$service_dir"
}

run_migrations_for_service() {
  local service="$1"
  local dsn="$2"
  local migration_dir="${SERVICE_ROOT}/${service}/migrations"
  [[ -d "$migration_dir" ]] || return

  log "running migrations for $service"
  psql "$dsn" -f "${migration_dir}/001_init_schema.sql"
  if [[ "${SEED_DEV}" == "true" && -f "${migration_dir}/999_seed_dev.sql" ]]; then
    psql "$dsn" -f "${migration_dir}/999_seed_dev.sql"
  fi
}

restart_services() {
  systemctl daemon-reload
  local ordered=()
  local service
  for service in $SERVICES; do
    [[ "$service" == "admin-service" ]] && ordered+=("$service")
    [[ "$service" == "node-service" ]] && ordered+=("$service")
  done
  for service in $SERVICES; do
    [[ "$service" == "gateway-service" ]] && ordered+=("$service")
  done
  for service in "${ordered[@]}"; do
    log "enabling and restarting $service"
    systemctl enable "$service"
    systemctl restart "$service"
  done
}

main() {
  require_root
  normalize_defaults
  validate_env
  detect_pkg_manager
  ensure_base_dependencies
  prepare_release_workspace
  trap cleanup_release_workspace EXIT

  local service
  for service in $SERVICES; do
    local version archive package_dir
    version="$(service_release_version "$service")"
    archive="$(download_release_archive "$service" "$version")"
    package_dir="$(extract_release_archive "$service" "$archive")"
    install_service_artifacts "$service" "$package_dir"
  done

  if [[ "$RUN_MIGRATIONS" == "true" ]]; then
    for service in $SERVICES; do
      case "$service" in
        admin-service) run_migrations_for_service "$service" "$ADMIN_DATABASE_DSN" ;;
        node-service) run_migrations_for_service "$service" "$NODE_DATABASE_DSN" ;;
      esac
    done
  fi

  if [[ "$START_SERVICES" == "true" ]]; then
    restart_services
  fi

  log "installation completed"
}

main "$@"
