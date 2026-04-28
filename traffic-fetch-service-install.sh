#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

OWNER="your-org"
REPO="${OWNER}/traffic-platform-sync"
APP_NAME="traffic-platform-sync"
INSTALL_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
SERVICE_NAME="${APP_NAME}"
ARCH="linux-amd64"
VERSION="${1:-latest}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
MYSQL_URL="${MYSQL_HOST:-db.example.com:3306/test?charset=utf8mb4&parseTime=True&loc=Local}"
MYSQL_USER="${MYSQL_USER:-app_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-abc@123}"

log "start install for ${APP_NAME} (version=${VERSION})"

if [ -n "${GITHUB_TOKEN}" ]; then
  CURL_AUTH=( -H "Authorization: token ${GITHUB_TOKEN}" )
else
  CURL_AUTH=()
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  log "stopping existing service: ${SERVICE_NAME}"
  systemctl stop "${SERVICE_NAME}" || true
  systemctl disable "${SERVICE_NAME}" || true
fi

log "prepare directories"
mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
cd /tmp

if [ "${VERSION}" = "latest" ]; then
  log "query latest release"
  DOWNLOAD_URL=$(curl -s "${CURL_AUTH[@]}" "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep "browser_download_url" \
    | grep "${ARCH}.tar.gz" \
    | cut -d '"' -f 4)
else
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${APP_NAME}-${ARCH}.tar.gz"
fi

if [ -z "${DOWNLOAD_URL}" ]; then
  log "release asset not found"
  exit 1
fi

log "download: ${DOWNLOAD_URL}"
curl -L "${CURL_AUTH[@]}" -o "${APP_NAME}.tar.gz" "${DOWNLOAD_URL}"
log "extract package"
rm -rf "${APP_NAME}-release"
mkdir -p "${APP_NAME}-release"
tar -xzf "${APP_NAME}.tar.gz" -C "${APP_NAME}-release"

log "install binary and assets"
chmod +x "${APP_NAME}-release/${APP_NAME}-${ARCH}"
mv "${APP_NAME}-release/${APP_NAME}-${ARCH}" "${INSTALL_DIR}/${APP_NAME}"
cp -r "${APP_NAME}-release/migrations" "${INSTALL_DIR}/" || true

if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
  log "install default config"
  cp "${APP_NAME}-release/configs/config.yaml" "${CONFIG_DIR}/config.yaml"
  log "please edit ${CONFIG_DIR}/config.yaml before starting in production"
fi

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\&/]/\\\\&/g'
}

MYSQL_URL_ESCAPED="$(escape_sed "${MYSQL_URL}")"
MYSQL_USER_ESCAPED="$(escape_sed "${MYSQL_USER}")"
MYSQL_PASSWORD_ESCAPED="$(escape_sed "${MYSQL_PASSWORD}")"

log "update database config"
sed -i "s|^  username:.*|  username: \"${MYSQL_USER_ESCAPED}\"|" "${CONFIG_DIR}/config.yaml"
sed -i "s|^  password:.*|  password: \"${MYSQL_PASSWORD_ESCAPED}\"|" "${CONFIG_DIR}/config.yaml"
sed -i "s|^  url:.*|  url: \"tcp(${MYSQL_URL_ESCAPED})\"|" "${CONFIG_DIR}/config.yaml"

log "write systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
[Unit]
Description=Traffic Platform Sync Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${APP_NAME} -config ${CONFIG_DIR}/config.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"
systemctl status "${SERVICE_NAME}" --no-pager

log "done"
