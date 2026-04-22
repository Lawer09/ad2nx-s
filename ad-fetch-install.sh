#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ad-monetization-sync"
APP_USER="admon"
APP_GROUP="admon"
INSTALL_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

# ====== 必填：根据你的实际情况修改 ======
OWNER="${OWNER:Lawer09}"
REPO="${REPO:-ad-monetization-sync}"
SERVER_ID="${SERVER_ID:-sync-node-01}"
SERVER_NAME="${SERVER_NAME:-sync-node-01}"
SERVER_HOST_IP="${SERVER_HOST_IP:-47.87.139.70}"

MYSQL_HOST="${MYSQL_HOST:-db.example.com}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-app_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-abc@123}"
MYSQL_DATABASE="${MYSQL_DATABASE:-ad_sync}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"
MYSQL_PARSE_TIME="${MYSQL_PARSE_TIME:-true}"
MYSQL_LOC="${MYSQL_LOC:-Local}"

APP_ENV="${APP_ENV:-prod}"
LOG_LEVEL="${LOG_LEVEL:-info}"
RUN_ON_START="${RUN_ON_START:-true}"

HTTP_TIMEOUT="${HTTP_TIMEOUT:-30s}"
USER_AGENT="${USER_AGENT:-ad-monetization-sync/1.0}"

ACCOUNT_META_INTERVAL="${ACCOUNT_META_INTERVAL:-24h}"
APPS_INTERVAL="${APPS_INTERVAL:-24h}"
AD_UNITS_INTERVAL="${AD_UNITS_INTERVAL:-24h}"
REVENUE_INTERVAL="${REVENUE_INTERVAL:-1h}"
REVENUE_RELOAD_DAYS="${REVENUE_RELOAD_DAYS:-2}"

ADMOB_API_BASE_URL="${ADMOB_API_BASE_URL:-https://admob.googleapis.com/v1}"

# 私有仓库时填写；公有仓库可留空
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# ======================================

install_packages_apt() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl jq tar gzip ca-certificates systemd
}

install_packages_yum() {
  yum install -y curl jq tar gzip ca-certificates systemd
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

  mkdir -p "${INSTALL_DIR}/releases" "${CONF_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}" "${CONF_DIR}"
}

write_env_file() {
  cat > "${CONF_DIR}/${APP_NAME}.env" <<EOF
APP_ENV=${APP_ENV}
LOG_LEVEL=${LOG_LEVEL}
RUN_ON_START=${RUN_ON_START}

SERVER_ID=${SERVER_ID}
SERVER_NAME=${SERVER_NAME}
SERVER_HOST_IP=${SERVER_HOST_IP}

MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_CHARSET=${MYSQL_CHARSET}
MYSQL_PARSE_TIME=${MYSQL_PARSE_TIME}
MYSQL_LOC=${MYSQL_LOC}

HTTP_TIMEOUT=${HTTP_TIMEOUT}
USER_AGENT=${USER_AGENT}

ACCOUNT_META_INTERVAL=${ACCOUNT_META_INTERVAL}
APPS_INTERVAL=${APPS_INTERVAL}
AD_UNITS_INTERVAL=${AD_UNITS_INTERVAL}
REVENUE_INTERVAL=${REVENUE_INTERVAL}
REVENUE_RELOAD_DAYS=${REVENUE_RELOAD_DAYS}

ADMOB_API_BASE_URL=${ADMOB_API_BASE_URL}

GITHUB_TOKEN=${GITHUB_TOKEN}
EOF

  chmod 600 "${CONF_DIR}/${APP_NAME}.env"
}

write_service_file() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Ad Monetization Sync
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}/current
EnvironmentFile=${CONF_DIR}/${APP_NAME}.env
ExecStart=${INSTALL_DIR}/current/${APP_NAME}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

download_and_deploy_latest_release() {
  detect_arch
  local api_url="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  local auth_header=()
  if [ -n "${GITHUB_TOKEN}" ]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  echo "query latest release..."
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "${auth_header[@]}" \
    "${api_url}" \
    > "${tmp_dir}/release.json"

  local tag_name
  tag_name="$(jq -r '.tag_name' "${tmp_dir}/release.json")"
  if [ -z "${tag_name}" ] || [ "${tag_name}" = "null" ]; then
    echo "failed to get latest release tag"
    exit 1
  fi

  local asset_name="${APP_NAME}_linux_${ARCH}.tar.gz"
  local download_url
  download_url="$(jq -r --arg NAME "${asset_name}" '.assets[] | select(.name == $NAME) | .browser_download_url' "${tmp_dir}/release.json")"

  if [ -z "${download_url}" ] || [ "${download_url}" = "null" ]; then
    echo "release asset not found: ${asset_name}"
    exit 1
  fi

  local release_dir="${INSTALL_DIR}/releases/${tag_name}"
  mkdir -p "${release_dir}"

  echo "download ${asset_name} from ${tag_name}..."
  curl -fL \
    "${auth_header[@]}" \
    -H "Accept: application/octet-stream" \
    "${download_url}" \
    -o "${tmp_dir}/${asset_name}"

  tar -xzf "${tmp_dir}/${asset_name}" -C "${release_dir}"
  ln -sfn "${release_dir}" "${INSTALL_DIR}/current"
  chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}"
}

start_service() {
  systemctl daemon-reload
  systemctl enable "${APP_NAME}"
  systemctl restart "${APP_NAME}"
  systemctl status "${APP_NAME}" --no-pager
}

main() {
  install_runtime
  write_env_file
  write_service_file
  download_and_deploy_latest_release
  start_service

  echo
  echo "done."
  echo "view logs:"
  echo "  journalctl -u ${APP_NAME} -f --no-pager"
}

main "$@"