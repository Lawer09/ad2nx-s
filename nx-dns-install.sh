#!/usr/bin/env bash
set -euo pipefail

APP_NAME="nx-dns-service"
APP_USER="${APP_USER:-nxdnsservice}"
APP_GROUP="${APP_GROUP:-nxdnsservice}"
INSTALL_DIR="${INSTALL_DIR:-/opt/${APP_NAME}}"
CONF_DIR="${CONF_DIR:-/etc/${APP_NAME}}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

OWNER="${OWNER:-Lawer09}"
REPO="${REPO:-nx-dns-service}"

APP_ENV="${APP_ENV:-prod}"
HTTP_ADDR="${HTTP_ADDR:-:8080}"
API_TOKEN="${API_TOKEN:-$(openssl rand -hex 24)}"

MYSQL_DSN="${MYSQL_DSN:-}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-nx}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-nx}"
MYSQL_DATABASE="${MYSQL_DATABASE:-nx_dns_service}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"
MYSQL_PARSE_TIME="${MYSQL_PARSE_TIME:-true}"
MYSQL_LOC="${MYSQL_LOC:-Local}"

DOMAIN_SYNC_INTERVAL_SECONDS="${DOMAIN_SYNC_INTERVAL_SECONDS:-300}"
RANDOM_SUBDOMAIN_LENGTH="${RANDOM_SUBDOMAIN_LENGTH:-8}"
DEFAULT_DNS_TTL="${DEFAULT_DNS_TTL:-600}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RELEASE_TAG="${RELEASE_TAG:-}"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "please run as root"
    exit 1
  fi
}

install_packages_apt() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl jq tar gzip ca-certificates systemd openssl
}

install_packages_yum() {
  yum install -y curl jq tar gzip ca-certificates systemd openssl
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
  cat > "${CONF_DIR}/${APP_NAME}.env" <<EOF_ENV
APP_ENV=${APP_ENV}
HTTP_ADDR=${HTTP_ADDR}
API_TOKEN=${API_TOKEN}

MYSQL_DSN=${MYSQL_DSN}
MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_CHARSET=${MYSQL_CHARSET}
MYSQL_PARSE_TIME=${MYSQL_PARSE_TIME}
MYSQL_LOC=${MYSQL_LOC}

DOMAIN_SYNC_INTERVAL_SECONDS=${DOMAIN_SYNC_INTERVAL_SECONDS}
RANDOM_SUBDOMAIN_LENGTH=${RANDOM_SUBDOMAIN_LENGTH}
DEFAULT_DNS_TTL=${DEFAULT_DNS_TTL}
EOF_ENV

  chmod 600 "${CONF_DIR}/${APP_NAME}.env"
  chown "${APP_USER}:${APP_GROUP}" "${CONF_DIR}/${APP_NAME}.env"
}

write_service_file() {
  cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=NX DNS Multi Provider Service
Wants=network-online.target
After=network-online.target

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
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${INSTALL_DIR} ${CONF_DIR}

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

  local asset_name="${APP_NAME}_linux_${ARCH}.tar.gz"
  local checksum_name="${asset_name}.sha256"

  local asset_api_url
  asset_api_url="$(jq -r --arg NAME "${asset_name}" '.assets[] | select(.name == $NAME) | .url' "${tmp_dir}/release.json")"

  if [ -z "${asset_api_url}" ] || [ "${asset_api_url}" = "null" ]; then
    echo "release asset not found: ${asset_name}"
    echo "available assets:"
    jq -r '.assets[].name' "${tmp_dir}/release.json" || true
    exit 1
  fi

  local checksum_api_url
  checksum_api_url="$(jq -r --arg NAME "${checksum_name}" '.assets[] | select(.name == $NAME) | .url' "${tmp_dir}/release.json")"

  echo "download ${asset_name} from ${tag_name}..."
  curl -fL \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_header[@]}" \
    "${asset_api_url}" \
    -o "${tmp_dir}/${asset_name}"

  if [ -n "${checksum_api_url}" ] && [ "${checksum_api_url}" != "null" ]; then
    curl -fL \
      -H "Accept: application/octet-stream" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${auth_header[@]}" \
      "${checksum_api_url}" \
      -o "${tmp_dir}/${checksum_name}"
    local expected_sha
    expected_sha="$(awk -v n="${asset_name}" '
      {
        file=$2
        sub(/^\*/, "", file)
        sub(/^.*\//, "", file)
        if (file == n) {
          print $1
          exit
        }
      }
    ' "${tmp_dir}/${checksum_name}")"
    if [ -z "${expected_sha}" ]; then
      expected_sha="$(awk 'NR==1 {print $1}' "${tmp_dir}/${checksum_name}")"
    fi
    if [ -z "${expected_sha}" ]; then
      echo "invalid checksum file: ${checksum_name}"
      cat "${tmp_dir}/${checksum_name}" || true
      exit 1
    fi
    local actual_sha
    actual_sha="$(sha256sum "${tmp_dir}/${asset_name}" | awk '{print $1}')"
    if [ "${expected_sha}" != "${actual_sha}" ]; then
      echo "checksum mismatch for ${asset_name}"
      echo "expected: ${expected_sha}"
      echo "actual:   ${actual_sha}"
      exit 1
    fi
  fi

  local release_dir="${INSTALL_DIR}/releases/${tag_name}"
  rm -rf "${release_dir}"
  mkdir -p "${release_dir}"
  tar -xzf "${tmp_dir}/${asset_name}" -C "${release_dir}"
  chmod +x "${release_dir}/${APP_NAME}"
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
  require_root
  install_runtime
  write_env_file
  write_service_file
  download_and_deploy_latest_release
  start_service

  echo
  echo "done."
  echo "env file: ${CONF_DIR}/${APP_NAME}.env"
  echo "current release: ${INSTALL_DIR}/current"
  echo "view logs: journalctl -u ${APP_NAME} -f --no-pager"
}

main "$@"
