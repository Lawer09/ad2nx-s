#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

ensure_deps() {
  local missing=()
  for cmd in curl jq tar gzip; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi

  log "missing deps: ${missing[*]}, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl jq tar gzip ca-certificates >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq tar gzip ca-certificates >/dev/null 2>&1
  else
    log "unsupported package manager"
    exit 1
  fi

  for cmd in curl jq tar gzip; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "install failed: missing ${cmd}"
      exit 1
    fi
  done
}

REPO="${OWNER:-Lawer09}/traffic-platform-sync"
APP_NAME="traffic-platform-sync"
INSTALL_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
SERVICE_NAME="${APP_NAME}"
ARCH="linux-amd64"
ARCH_ALT="linux_amd64"
VERSION="${1:-latest}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

MYSQL_HOST="${MYSQL_HOST:-db.example.com}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-app_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-abc@123}"
MYSQL_DATABASE="${MYSQL_DATABASE:-ad_sync}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"
MYSQL_PARSE_TIME="${MYSQL_PARSE_TIME:-true}"
MYSQL_LOC="${MYSQL_LOC:-Local}"
MYSQL_URL="tcp(${MYSQL_HOST}:${MYSQL_PORT})/${MYSQL_DATABASE}?charset=${MYSQL_CHARSET}&parseTime=${MYSQL_PARSE_TIME}&loc=${MYSQL_LOC}"

log "start install for ${APP_NAME} (version=${VERSION})"

ensure_deps

if [ -n "${GITHUB_TOKEN}" ]; then
  CURL_AUTH=( -H "Authorization: token ${GITHUB_TOKEN}" )
else
  CURL_AUTH=()
fi

if [ "${VERSION}" = "latest" ]; then
  log "query latest release"
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
else
  log "query release tag ${VERSION}"
  API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  log "stopping existing service: ${SERVICE_NAME}"
  systemctl stop "${SERVICE_NAME}" || true
  systemctl disable "${SERVICE_NAME}" || true
fi

log "prepare directories"
mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
cd /tmp

log "fetch release metadata"
API_TMP="/tmp/${APP_NAME}-release.json"
API_ERR="/tmp/${APP_NAME}-release.err"
HTTP_CODE=$(curl -sS -L \
  --connect-timeout 10 --max-time 20 \
  -w "%{http_code}" \
  -o "${API_TMP}" \
  "${CURL_AUTH[@]}" "${API_URL}" 2>"${API_ERR}" || true)

log "metadata status: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ]; then
  log "GitHub API failed (status=${HTTP_CODE})"
  log "API url: ${API_URL}"
  log "error: $(tail -n 2 "${API_ERR}" 2>/dev/null || true)"
  log "response: $(head -n 5 "${API_TMP}" 2>/dev/null || true)"
  exit 1
fi

DOWNLOAD_URL=""
ASSET_API_URL=""
DOWNLOAD_URL=$(jq -r --arg ARCH "${ARCH}" --arg ARCH_ALT "${ARCH_ALT}" '
  .assets[]
  | select(.name != null)
  | select(((.name | contains($ARCH)) or (.name | contains($ARCH_ALT))) and ((.name | tostring | endswith(".tar.gz")) or (.name | tostring | endswith(".tgz"))))
  | .browser_download_url
' "${API_TMP}" | head -n 1)
ASSET_API_URL=$(jq -r --arg ARCH "${ARCH}" --arg ARCH_ALT "${ARCH_ALT}" '
  .assets[]
  | select(.name != null)
  | select(((.name | contains($ARCH)) or (.name | contains($ARCH_ALT))) and ((.name | tostring | endswith(".tar.gz")) or (.name | tostring | endswith(".tgz"))))
  | .url
' "${API_TMP}" | head -n 1)

if [ "${DOWNLOAD_URL}" = "null" ]; then
  DOWNLOAD_URL=""
fi

if [ "${ASSET_API_URL}" = "null" ]; then
  ASSET_API_URL=""
fi

if [ -z "${DOWNLOAD_URL}" ] && [ -z "${ASSET_API_URL}" ]; then
  log "release asset not found"
  exit 1
fi

if [ -n "${ASSET_API_URL}" ]; then
  log "download via GitHub API asset"
  curl -fL "${CURL_AUTH[@]}" \
    -H "Accept: application/octet-stream" \
    -o "${APP_NAME}.tar.gz" "${ASSET_API_URL}"
else
  log "download: ${DOWNLOAD_URL}"
  curl -fL "${CURL_AUTH[@]}" -o "${APP_NAME}.tar.gz" "${DOWNLOAD_URL}"
fi
log "extract package"
rm -rf "${APP_NAME}-release"
mkdir -p "${APP_NAME}-release"
if ! tar -tzf "${APP_NAME}.tar.gz" >/dev/null 2>&1; then
  log "downloaded file is not a valid tar.gz"
  log "first bytes: $(head -c 200 "${APP_NAME}.tar.gz" | tr -dc '[:print:]' | sed 's/\s\+/ /g')"
  exit 1
fi
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

update_database_config() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v user="${MYSQL_USER}" -v pass="${MYSQL_PASSWORD}" -v url="${MYSQL_URL}" '
    function emit_db() {
      if (!user_done) print "  username: \"" user "\""
      if (!pass_done) print "  password: \"" pass "\""
      if (!url_done)  print "  url: \"" url "\""
    }
    {
      if (in_db && $0 ~ /^[^[:space:]]/) {
        emit_db(); in_db=0
      }
      if ($0 ~ /^database:/) {
        print
        in_db=1
        user_done=0; pass_done=0; url_done=0
        next
      }
      if (in_db) {
        if ($0 ~ /username:/) { print "  username: \"" user "\""; user_done=1; next }
        if ($0 ~ /password:/) { print "  password: \"" pass "\""; pass_done=1; next }
        if ($0 ~ /url:/)      { print "  url: \"" url "\""; url_done=1; next }
      }
      print
    }
    END { if (in_db) emit_db() }
  ' "${file}" > "${tmp}"

  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

log "update database config"
update_database_config "${CONFIG_DIR}/config.yaml"

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
