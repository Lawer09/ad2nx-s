#!/usr/bin/env bash
set -euo pipefail

APP_NAME="firebase-event-recv"
APP_USER="firebaseevt"
APP_GROUP="firebaseevt"
INSTALL_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NGINX_CONF_FILE="/etc/nginx/conf.d/${APP_NAME}.conf"

# ====== 必填/建议修改：根据你的实际情况覆盖环境变量 ======
OWNER="${OWNER:-Lawer09}"
REPO="${REPO:-firebase-event-recv}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RELEASE_TAG="${RELEASE_TAG:-}"

APP_ENV="${APP_ENV:-prod}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8080}"
EVENT_BRIDGE_SECRET="${EVENT_BRIDGE_SECRET:-$(openssl rand -hex 16)}"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-firebase_event}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-change_me}"
MYSQL_DATABASE="${MYSQL_DATABASE:-firebase_event}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"
MYSQL_PARSE_TIME="${MYSQL_PARSE_TIME:-true}"
MYSQL_LOC="${MYSQL_LOC:-Local}"
MYSQL_DSN="${MYSQL_DSN:-${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${MYSQL_DATABASE}?charset=${MYSQL_CHARSET}&parseTime=${MYSQL_PARSE_TIME}&loc=${MYSQL_LOC}}"
MYSQL_APPLY_SCHEMA="${MYSQL_APPLY_SCHEMA:-false}"

REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_DB="${REDIS_DB:-0}"

QUEUE_DIR="${QUEUE_DIR:-${INSTALL_DIR}/data/queue}"
WORKER_CONCURRENCY="${WORKER_CONCURRENCY:-4}"

OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hongkong.aliyuncs.com}"
OSS_ACCESS_KEY_ID="${OSS_ACCESS_KEY_ID:-}"
OSS_ACCESS_KEY_SECRET="${OSS_ACCESS_KEY_SECRET:-}"
OSS_BUCKET="${OSS_BUCKET:-}"
OSS_PREFIX="${OSS_PREFIX:-firebase-events}"

ENABLE_NGINX="${ENABLE_NGINX:-true}"
NGINX_SERVER_NAME="${NGINX_SERVER_NAME:-_}"
NGINX_LISTEN="${NGINX_LISTEN:-80}"
NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-2m}"
# =========================================================

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "please run as root"
    exit 1
  fi
}

install_packages_apt() {
  apt-get update
  local packages=(curl jq tar gzip ca-certificates systemd openssl)
  if [ "${ENABLE_NGINX}" = "true" ]; then
    packages+=(nginx)
  fi
  if [ "${MYSQL_APPLY_SCHEMA}" = "true" ]; then
    packages+=(default-mysql-client)
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_packages_yum() {
  local packages=(curl jq tar gzip ca-certificates systemd openssl)
  if [ "${ENABLE_NGINX}" = "true" ]; then
    packages+=(nginx)
  fi
  if [ "${MYSQL_APPLY_SCHEMA}" = "true" ]; then
    packages+=(mysql)
  fi
  yum install -y "${packages[@]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      echo "unsupported arch: $(uname -m)"
      exit 1
      ;;
  esac
}

install_runtime() {
  if command -v apt-get >/dev/null 2>&1; then
    install_packages_apt
  elif command -v yum >/dev/null 2>&1; then
    install_packages_yum
  else
    echo "unsupported package manager"
    exit 1
  fi

  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${APP_GROUP}"
  fi

  if ! id "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${APP_GROUP}" --home "${INSTALL_DIR}" --shell /sbin/nologin "${APP_USER}"
  fi

  mkdir -p "${INSTALL_DIR}/releases" "${CONF_DIR}" "${QUEUE_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}"
  chmod 750 "${INSTALL_DIR}"
}

write_env_file() {
  cat > "${CONF_DIR}/${APP_NAME}.env" <<EOF_ENV
APP_ENV=${APP_ENV}
HTTP_ADDR=${HTTP_ADDR}
EVENT_BRIDGE_SECRET=${EVENT_BRIDGE_SECRET}

MYSQL_DSN=${MYSQL_DSN}

REDIS_ADDR=${REDIS_ADDR}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}

QUEUE_DIR=${QUEUE_DIR}
WORKER_CONCURRENCY=${WORKER_CONCURRENCY}

OSS_ENDPOINT=${OSS_ENDPOINT}
OSS_ACCESS_KEY_ID=${OSS_ACCESS_KEY_ID}
OSS_ACCESS_KEY_SECRET=${OSS_ACCESS_KEY_SECRET}
OSS_BUCKET=${OSS_BUCKET}
OSS_PREFIX=${OSS_PREFIX}
EOF_ENV

  chmod 600 "${CONF_DIR}/${APP_NAME}.env"
  chown root:"${APP_GROUP}" "${CONF_DIR}/${APP_NAME}.env"
}

write_service_file() {
  cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=firebase-event-recv
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}/current
EnvironmentFile=${CONF_DIR}/${APP_NAME}.env
ExecStart=${INSTALL_DIR}/current/${APP_NAME}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

download_and_deploy_latest_release() {
  detect_arch

  if systemctl is-active --quiet "${APP_NAME}"; then
    echo "stop existing service..."
    systemctl stop "${APP_NAME}"
  fi

  local api_url
  if [ -n "${RELEASE_TAG}" ]; then
    api_url="https://api.github.com/repos/${OWNER}/${REPO}/releases/tags/${RELEASE_TAG}"
  else
    api_url="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  local auth_header=()
  if [ -n "${GITHUB_TOKEN}" ]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  echo "query release..."
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_header[@]}" \
    "${api_url}" \
    > "${tmp_dir}/release.json"

  local tag_name
  tag_name="$(jq -r '.tag_name' "${tmp_dir}/release.json")"
  if [ -z "${tag_name}" ] || [ "${tag_name}" = "null" ]; then
    echo "failed to get release tag"
    cat "${tmp_dir}/release.json"
    exit 1
  fi

  local asset_name="${APP_NAME}-linux-${ARCH}.tar.gz"
  local asset_api_url
  asset_api_url="$(jq -r --arg NAME "${asset_name}" '.assets[] | select(.name == $NAME) | .url' "${tmp_dir}/release.json")"

  if [ -z "${asset_api_url}" ] || [ "${asset_api_url}" = "null" ]; then
    echo "release asset not found: ${asset_name}"
    echo "available assets:"
    jq -r '.assets[].name' "${tmp_dir}/release.json" || true
    exit 1
  fi

  local release_dir="${INSTALL_DIR}/releases/${tag_name}"
  rm -rf "${release_dir}"
  mkdir -p "${release_dir}"

  echo "download ${asset_name} from ${tag_name}..."
  curl -fL \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_header[@]}" \
    "${asset_api_url}" \
    -o "${tmp_dir}/${asset_name}"

  tar -xzf "${tmp_dir}/${asset_name}" -C "${release_dir}"

  if [ -f "${release_dir}/${APP_NAME}-linux-${ARCH}" ]; then
    mv "${release_dir}/${APP_NAME}-linux-${ARCH}" "${release_dir}/${APP_NAME}"
  fi
  chmod +x "${release_dir}/${APP_NAME}"

  ln -sfn "${release_dir}" "${INSTALL_DIR}/current"
  chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}"
}

apply_mysql_schema() {
  if [ "${MYSQL_APPLY_SCHEMA}" != "true" ]; then
    return 0
  fi

  if [ ! -f "${INSTALL_DIR}/current/sql/001_init.sql" ]; then
    echo "schema file not found: ${INSTALL_DIR}/current/sql/001_init.sql"
    exit 1
  fi

  echo "apply mysql schema..."
  MYSQL_PWD="${MYSQL_PASSWORD}" mysql \
    -h "${MYSQL_HOST}" \
    -P "${MYSQL_PORT}" \
    -u "${MYSQL_USER}" \
    "${MYSQL_DATABASE}" \
    < "${INSTALL_DIR}/current/sql/001_init.sql"
}

write_nginx_conf() {
  if [ "${ENABLE_NGINX}" != "true" ]; then
    return 0
  fi

  cat > "${NGINX_CONF_FILE}" <<EOF_NGINX
server {
    listen ${NGINX_LISTEN};
    server_name ${NGINX_SERVER_NAME};

    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

    access_log /var/log/nginx/${APP_NAME}.access.log;
    error_log  /var/log/nginx/${APP_NAME}.error.log;

    location /api/v1/firebase/events {
        proxy_pass http://${HTTP_ADDR};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 3s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }

    location /healthz {
        proxy_pass http://${HTTP_ADDR};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF_NGINX

  nginx -t
  systemctl enable nginx || true
  systemctl reload nginx || systemctl restart nginx
}

start_service() {
  systemctl daemon-reload
  systemctl enable "${APP_NAME}"
  systemctl restart "${APP_NAME}"
  systemctl status "${APP_NAME}" --no-pager
}

print_done() {
  echo
  echo "done."
  echo "env file: ${CONF_DIR}/${APP_NAME}.env"
  echo "service:  ${SERVICE_FILE}"
  if [ "${ENABLE_NGINX}" = "true" ]; then
    echo "nginx:    ${NGINX_CONF_FILE}"
  fi
  echo
  echo "view logs:"
  echo "  journalctl -u ${APP_NAME} -f --no-pager"
  echo
  echo "check health:"
  echo "  curl -i http://127.0.0.1:8080/healthz"
  echo
  echo "EVENT_BRIDGE_SECRET=${EVENT_BRIDGE_SECRET}"
  echo "请把该值同步到 Firebase 转发函数的密钥配置中。"
}

main() {
  need_root
  install_runtime
  write_env_file
  write_service_file
  download_and_deploy_latest_release
  apply_mysql_schema
  write_nginx_conf
  start_service
  print_done
}

main "$@"