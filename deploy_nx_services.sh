#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    err "missing env: ${name}"
  fi
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || err "missing command: ${name}"
}

require_cmd curl
require_cmd tar
require_cmd python3

# ===== required env =====
require_env GITHUB_OWNER
require_env GITHUB_REPO
require_env GITHUB_TOKEN
require_env INSTALL_DIR

# ===== optional env =====
ARCH="${ARCH:-amd64}"                       # amd64 / arm64
RELEASE_TAG="${RELEASE_TAG:-latest}"       # latest or v1.0.0
CONFIG_DIR="${CONFIG_DIR:-/etc/nxpanel-services}"
OVERWRITE_CONFIGS="${OVERWRITE_CONFIGS:-false}"   # true/false
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

RELEASES_DIR="${INSTALL_DIR}/releases"
CURRENT_LINK="${INSTALL_DIR}/current"
SCRIPT_DIR="${INSTALL_DIR}/scripts"
RUN_DIR="${INSTALL_DIR}/run"
LOG_DIR="${INSTALL_DIR}/logs"
TMP_DIR="${INSTALL_DIR}/tmp"

ASSET_NAME="nxpanel-services-linux-${ARCH}.tar.gz"
EXTRACTED_DIR_NAME="linux-${ARCH}"

mkdir -p "$RELEASES_DIR" "$SCRIPT_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_DIR" "$CONFIG_DIR"

get_release_metadata() {
  local url
  if [ "$RELEASE_TAG" = "latest" ]; then
    url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
  else
    url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}"
  fi

  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
    "$url"
}

get_asset_id_by_name() {
  local json_file="$1"
  local asset_name="$2"

  python3 - "$json_file" "$asset_name" <<'PY'
import json, sys

json_file = sys.argv[1]
asset_name = sys.argv[2]

with open(json_file, "r", encoding="utf-8") as f:
    data = json.load(f)

for asset in data.get("assets", []):
    if asset.get("name") == asset_name:
        print(asset.get("id"))
        sys.exit(0)

sys.exit(1)
PY
}

get_release_tag_name() {
  local json_file="$1"

  python3 - "$json_file" <<'PY'
import json, sys

json_file = sys.argv[1]
with open(json_file, "r", encoding="utf-8") as f:
    data = json.load(f)

print(data.get("tag_name", "unknown"))
PY
}

download_release_asset() {
  local asset_id="$1"
  local target="$2"
  local url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/assets/${asset_id}"

  log "downloading asset id=${asset_id} -> ${target}"
  curl -fL \
    -H "Accept: application/octet-stream" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
    -o "$target" \
    "$url"
}

write_start_script() {
  local script_path="$1"
  local svc_name="$2"
  local bin_path="$3"
  local config_path="$4"
  local log_path="$5"
  local pid_path="$6"

  cat > "$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${bin_path}"
CONFIG_PATH="${config_path}"
LOG_PATH="${log_path}"
PID_PATH="${pid_path}"

if [ ! -x "\$BIN_PATH" ]; then
  echo "[ERROR] binary not found or not executable: \$BIN_PATH" >&2
  exit 1
fi

if [ ! -f "\$CONFIG_PATH" ]; then
  echo "[ERROR] config not found: \$CONFIG_PATH" >&2
  exit 1
fi

if [ -f "\$PID_PATH" ]; then
  OLD_PID="\$(cat "\$PID_PATH" || true)"
  if [ -n "\$OLD_PID" ] && kill -0 "\$OLD_PID" >/dev/null 2>&1; then
    echo "[INFO] ${svc_name} already running, pid=\$OLD_PID"
    exit 0
  fi
fi

mkdir -p "\$(dirname "\$LOG_PATH")" "\$(dirname "\$PID_PATH")"

nohup "\$BIN_PATH" -config "\$CONFIG_PATH" >> "\$LOG_PATH" 2>&1 &
NEW_PID=\$!
echo "\$NEW_PID" > "\$PID_PATH"

sleep 1
if kill -0 "\$NEW_PID" >/dev/null 2>&1; then
  echo "[INFO] ${svc_name} started, pid=\$NEW_PID"
else
  echo "[ERROR] ${svc_name} failed to start, check log: \$LOG_PATH" >&2
  exit 1
fi
EOF

  chmod +x "$script_path"
}

write_stop_script() {
  local script_path="$1"
  local svc_name="$2"
  local pid_path="$3"

  cat > "$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

PID_PATH="${pid_path}"

if [ ! -f "\$PID_PATH" ]; then
  echo "[INFO] ${svc_name} not running (pid file missing)"
  exit 0
fi

PID="\$(cat "\$PID_PATH" || true)"
if [ -z "\$PID" ]; then
  echo "[INFO] ${svc_name} not running (empty pid)"
  rm -f "\$PID_PATH"
  exit 0
fi

if kill -0 "\$PID" >/dev/null 2>&1; then
  kill "\$PID" || true
  sleep 1
  if kill -0 "\$PID" >/dev/null 2>&1; then
    kill -9 "\$PID" || true
  fi
  echo "[INFO] ${svc_name} stopped, pid=\$PID"
else
  echo "[INFO] ${svc_name} process not found, cleaning pid file"
fi

rm -f "\$PID_PATH"
EOF

  chmod +x "$script_path"
}

RELEASE_JSON_PATH="${TMP_DIR}/release.json"
TARBALL_PATH="${TMP_DIR}/${ASSET_NAME}"

log "fetching release metadata"
get_release_metadata > "${RELEASE_JSON_PATH}"

ASSET_ID="$(get_asset_id_by_name "${RELEASE_JSON_PATH}" "${ASSET_NAME}" || true)"
[ -n "${ASSET_ID}" ] || err "asset not found in release: ${ASSET_NAME}"

RELEASE_DIR_BASENAME="$(get_release_tag_name "${RELEASE_JSON_PATH}")"
if [ -z "${RELEASE_DIR_BASENAME}" ] || [ "${RELEASE_DIR_BASENAME}" = "unknown" ]; then
  RELEASE_DIR_BASENAME="$(date +"latest-%Y%m%d-%H%M%S")"
fi

TARGET_RELEASE_DIR="${RELEASES_DIR}/${RELEASE_DIR_BASENAME}"

download_release_asset "${ASSET_ID}" "${TARBALL_PATH}"

mkdir -p "${TARGET_RELEASE_DIR}"
log "extracting package to: ${TARGET_RELEASE_DIR}"
tar -xzf "${TARBALL_PATH}" -C "${TARGET_RELEASE_DIR}"

PACKAGE_DIR="${TARGET_RELEASE_DIR}/${EXTRACTED_DIR_NAME}"
[ -d "${PACKAGE_DIR}" ] || err "extracted package dir not found: ${PACKAGE_DIR}"

for bin in user-report-service node-report-service dispatch-service; do
  if [ -f "${PACKAGE_DIR}/${bin}" ]; then
    chmod +x "${PACKAGE_DIR}/${bin}"
  else
    warn "binary not found in package: ${PACKAGE_DIR}/${bin}"
  fi
done

for cfg in user-report-service.json node-report-service.json dispatch-service.json; do
  SRC_CFG="${PACKAGE_DIR}/configs/${cfg}"
  DST_CFG="${CONFIG_DIR}/${cfg}"

  if [ -f "${SRC_CFG}" ]; then
    if [ ! -f "${DST_CFG}" ]; then
      cp -f "${SRC_CFG}" "${DST_CFG}"
      log "config initialized: ${DST_CFG}"
    else
      if [ "${OVERWRITE_CONFIGS}" = "true" ]; then
        cp -f "${SRC_CFG}" "${DST_CFG}"
        log "config overwritten: ${DST_CFG}"
      else
        log "config exists, keep current: ${DST_CFG}"
      fi
    fi
  else
    warn "config not found in package: ${SRC_CFG}"
  fi
done

ln -sfn "${PACKAGE_DIR}" "${CURRENT_LINK}"
log "current linked to: ${PACKAGE_DIR}"

write_start_script \
  "${SCRIPT_DIR}/start-user-report.sh" \
  "user-report-service" \
  "${CURRENT_LINK}/user-report-service" \
  "${CONFIG_DIR}/user-report-service.json" \
  "${LOG_DIR}/user-report-service.log" \
  "${RUN_DIR}/user-report-service.pid"

write_start_script \
  "${SCRIPT_DIR}/start-node-report.sh" \
  "node-report-service" \
  "${CURRENT_LINK}/node-report-service" \
  "${CONFIG_DIR}/node-report-service.json" \
  "${LOG_DIR}/node-report-service.log" \
  "${RUN_DIR}/node-report-service.pid"

write_start_script \
  "${SCRIPT_DIR}/start-dispatch.sh" \
  "dispatch-service" \
  "${CURRENT_LINK}/dispatch-service" \
  "${CONFIG_DIR}/dispatch-service.json" \
  "${LOG_DIR}/dispatch-service.log" \
  "${RUN_DIR}/dispatch-service.pid"

write_stop_script \
  "${SCRIPT_DIR}/stop-user-report.sh" \
  "user-report-service" \
  "${RUN_DIR}/user-report-service.pid"

write_stop_script \
  "${SCRIPT_DIR}/stop-node-report.sh" \
  "node-report-service" \
  "${RUN_DIR}/node-report-service.pid"

write_stop_script \
  "${SCRIPT_DIR}/stop-dispatch.sh" \
  "dispatch-service" \
  "${RUN_DIR}/dispatch-service.pid"

cat > "${SCRIPT_DIR}/start-all.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"${SCRIPT_DIR}/start-user-report.sh"
"${SCRIPT_DIR}/start-node-report.sh"
"${SCRIPT_DIR}/start-dispatch.sh"
echo "[INFO] all services started"
EOF
chmod +x "${SCRIPT_DIR}/start-all.sh"

cat > "${SCRIPT_DIR}/stop-all.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"${SCRIPT_DIR}/stop-user-report.sh" || true
"${SCRIPT_DIR}/stop-node-report.sh" || true
"${SCRIPT_DIR}/stop-dispatch.sh" || true
echo "[INFO] all services stopped"
EOF
chmod +x "${SCRIPT_DIR}/stop-all.sh"

log "deploy done"
log "release asset: ${ASSET_NAME}"
log "package dir: ${PACKAGE_DIR}"
log "current link: ${CURRENT_LINK}"
log "config dir: ${CONFIG_DIR}"
log "start all: ${SCRIPT_DIR}/start-all.sh"
log "stop all: ${SCRIPT_DIR}/stop-all.sh"