#!/usr/bin/env bash
# Linux deployment script for nx-node.
#
# Responsibilities:
# - Download the latest GitHub Release asset for the current Linux architecture.
# - Optionally use GIT_TOKEN/GITHUB_TOKEN to download from private repositories.
# - Install the nx-node binary and bundled example files.
# - Create/update a systemd service and start nx-node.manager.
# - Preserve an existing /etc/nx-node/config.json.
# - Generate config from either AGENT_ID/AGENT_SECRET/SERVER or SERVER for asset.config registration.
# - Optionally generate /etc/nx-platform/asset.config from MACHINE_ID/TRUST_TOKEN.
# - Optionally set AGENT_CREDENTIAL_FILE to choose where nx-node stores registered credentials.
#
# Non-responsibilities:
# - Does not call the Agent register API itself; nx-node performs first-start registration.
# - Does not validate backend API connectivity.
# - Does not manage kernel resource state after the service starts.

set -Eeuo pipefail

REPO="${REPO:-Lawer09/nx-node}"
SERVICE_NAME="${SERVICE_NAME:-nx-node.manager}"
BINARY_NAME="${BINARY_NAME:-nx-node}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/nx-node}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
ORIGINAL_CONFIG="${ORIGINAL_CONFIG:-${CONFIG_DIR}/sing_origin.json}"
ASSET_CONFIG_DIR="${ASSET_CONFIG_DIR:-/etc/nx-platform}"
ASSET_CONFIG_FILE="${ASSET_CONFIG_FILE:-${ASSET_CONFIG_DIR}/asset.config}"
START_SERVICE="${START_SERVICE:-1}"
AGENT_ROLE="${AGENT_ROLE:-node}"
PROBE_ENABLE="${PROBE_ENABLE:-1}"
PROBE_INTERVAL="${PROBE_INTERVAL:-60}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
PROBE_TARGET_URL="${PROBE_TARGET_URL:-https://cp.cloudflare.com/generate_204}"
PROBE_CONCURRENCY="${PROBE_CONCURRENCY:-8}"
GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"
SERVER="${SERVER:-${AGENT_SERVER:-${PANEL_URL:-}}}"
TMP_DIR=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "please run as root, for example: sudo bash scripts/install-linux.sh"
  fi
}

install_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v unzip >/dev/null 2>&1 || missing+=("unzip")
  command -v sed >/dev/null 2>&1 || missing+=("sed")
  command -v awk >/dev/null 2>&1 || missing+=("gawk")

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  info "Installing dependencies: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}"
  else
    die "missing dependencies (${missing[*]}) and no supported package manager found"
  fi
}

detect_asset() {
  local arch asset
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | amd64)
      asset="${BINARY_NAME}-linux-amd64.zip"
      ;;
    aarch64 | arm64)
      asset="${BINARY_NAME}-linux-arm64.zip"
      ;;
    *)
      die "unsupported architecture: ${arch}"
      ;;
  esac
  printf '%s' "$asset"
}

github_curl() {
  if [ -n "$GIT_TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer ${GIT_TOKEN}" "$@"
  else
    curl -fsSL "$@"
  fi
}

github_api_curl() {
  if [ -n "$GIT_TOKEN" ]; then
    curl -fsSL \
      -H "Authorization: Bearer ${GIT_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$@"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$@"
  fi
}

github_asset_download() {
  local output="$1"
  local url="$2"

  if [ -n "$GIT_TOKEN" ]; then
    curl -fL \
      -H "Authorization: Bearer ${GIT_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -o "$output" \
      "$url"
  else
    curl -fL -o "$output" "$url"
  fi
}

latest_release_json() {
  github_api_curl "https://api.github.com/repos/${REPO}/releases/latest"
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

download_release() {
  local tmp_dir="$1"
  local asset="$2"
  local release_json tag asset_api_url browser_url

  info "Fetching latest release metadata from ${REPO}"
  release_json="$(latest_release_json)" || die "failed to fetch latest release metadata"
  tag="$(printf '%s' "$release_json" | json_value "tag_name")"
  [ -n "$tag" ] || die "failed to parse latest release tag"

  asset_api_url="$(
    printf '%s' "$release_json" | awk -v target="$asset" '
      /"url"[[:space:]]*:/ && /\/releases\/assets\// {
        line=$0
        sub(/^.*"url"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        url=line
      }
      /"name"[[:space:]]*:/ {
        line=$0
        sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        if (line == target && url != "") {
          print url
          exit
        }
      }
    '
  )"
  browser_url="$(printf '%s' "$release_json" | sed -n "s|.*\"browser_download_url\"[[:space:]]*:[[:space:]]*\"\\([^\"]*/${asset}\\)\".*|\\1|p" | head -n 1)"

  if [ -z "$asset_api_url" ] && [ -z "$browser_url" ]; then
    die "release ${tag} does not contain asset ${asset}"
  fi

  info "Downloading ${asset} from ${tag}"
  if [ -n "$asset_api_url" ]; then
    github_asset_download "${tmp_dir}/${asset}" "$asset_api_url" || die "failed to download ${asset} through GitHub asset API"
  else
    github_curl -o "${tmp_dir}/${asset}" "$browser_url" || die "failed to download ${asset}"
  fi

  if ! unzip -tq "${tmp_dir}/${asset}" >/dev/null; then
    die "downloaded ${asset} is not a valid zip; check GIT_TOKEN permission or release asset access"
  fi
  unzip -q "${tmp_dir}/${asset}" -d "${tmp_dir}/package"
  [ -x "${tmp_dir}/package/${BINARY_NAME}" ] || chmod +x "${tmp_dir}/package/${BINARY_NAME}"
}

install_files() {
  local tmp_dir="$1"

  install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
  install -m 0755 "${tmp_dir}/package/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"

  if [ -f "${tmp_dir}/package/config.json" ]; then
    install -m 0644 "${tmp_dir}/package/config.json" "${CONFIG_DIR}/config.json.example"
  fi
  if [ -f "${tmp_dir}/package/probe-config.json" ]; then
    install -m 0644 "${tmp_dir}/package/probe-config.json" "${CONFIG_DIR}/probe-config.json.example"
  fi
  for name in dns.json route.json custom_inbound.json custom_outbound.json geoip.dat geoip.db geosite.dat geosite.db; do
    if [ -f "${tmp_dir}/package/${name}" ]; then
      install -m 0644 "${tmp_dir}/package/${name}" "${CONFIG_DIR}/${name}.example"
    fi
  done
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_generated_config() {
  local agent_id agent_secret server_url credential_file
  agent_id="$(json_escape "${AGENT_ID:-}")"
  agent_secret="$(json_escape "${AGENT_SECRET:-}")"
  server_url="$(json_escape "${SERVER}")"
  credential_file="$(json_escape "${AGENT_CREDENTIAL_FILE:-${CONFIG_DIR}/agent-credentials.json}")"
  local role probe_enable probe_target_url
  role="$(json_escape "${AGENT_ROLE}")"
  probe_target_url="$(json_escape "${PROBE_TARGET_URL}")"
  probe_enable="false"
  if [ "$PROBE_ENABLE" = "1" ] || [ "$PROBE_ENABLE" = "true" ]; then
    probe_enable="true"
  fi

  cat >"$CONFIG_FILE" <<EOF
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Agent": {
    "ID": "${agent_id}",
    "Secret": "${agent_secret}",
    "Server": "${server_url}",
    "BindIP": "",
    "Timeout": 30,
    "Role": "${role}",
    "CredentialFile": "${credential_file}",
    "PullInterval": 60,
    "ReportInterval": 60,
    "FullSyncOnStart": true
  },
  "Core": {
    "Log": {
      "Level": "info",
      "Timestamp": true
    },
    "NTP": {
      "Enable": false,
      "Server": "time.apple.com",
      "ServerPort": 0
    },
    "OriginalPath": "${ORIGINAL_CONFIG}"
  },
  "Probe": {
    "Enable": ${probe_enable},
    "Interval": ${PROBE_INTERVAL},
    "Timeout": ${PROBE_TIMEOUT},
    "TargetURL": "${probe_target_url}",
    "Concurrency": ${PROBE_CONCURRENCY}
  },
  "Defaults": {
    "ListenIP": "0.0.0.0",
    "IPOnlineMinTraffic": 200,
    "ReportMinTraffic": 0,
    "EnableTFO": false,
    "EnableSniff": true,
    "CertConfig": {
      "CertMode": "none"
    },
    "LimitConfig": {
      "EnableRealtime": true,
      "SpeedLimit": 0,
      "IPLimit": 0
    }
  }
}
EOF
  chmod 0600 "$CONFIG_FILE"
}

write_asset_config() {
  local machine_id trust_token
  machine_id="$(json_escape "${MACHINE_ID:-}")"
  trust_token="$(json_escape "${TRUST_TOKEN:-}")"

  install -d -m 0700 "$ASSET_CONFIG_DIR"
  cat >"$ASSET_CONFIG_FILE" <<EOF
{
  "machine_id": "${machine_id}",
  "trust_token": "${trust_token}"
}
EOF
  chmod 0600 "$ASSET_CONFIG_FILE"
}

write_original_config() {
  cat >"$ORIGINAL_CONFIG" <<'EOF'
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "prefer_ipv4"
      }
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "domain_regex": [
          "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
          "(.+.|^)(360|so).(cn|com)",
          "(Subject|HELO|SMTP)",
          "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
          "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
          "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
          "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
          "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
          "(.+.|^)(360).(cn|com|net)",
          "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
          "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
          "(.*.||)(netvigator|torproject).(com|cn|net|org)",
          "(..||)(visa|mycard|gash|beanfun|bank).",
          "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
          "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
          "(.*.||)(mycard).(com|tw)",
          "(.*.||)(gash).(com|tw)",
          "(.bank.)",
          "(.*.||)(pincong).(rocks)",
          "(.*.||)(taobao).(com)",
          "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
          "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp",
          "tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF
  chmod 0644 "$ORIGINAL_CONFIG"
}

prepare_config() {
  if [ -n "${MACHINE_ID:-}" ] || [ -n "${TRUST_TOKEN:-}" ]; then
    if [ -z "${MACHINE_ID:-}" ] || [ -z "${TRUST_TOKEN:-}" ]; then
      die "MACHINE_ID and TRUST_TOKEN must be set together when generating ${ASSET_CONFIG_FILE}"
    fi
    if [ -f "$ASSET_CONFIG_FILE" ]; then
      info "Keeping existing asset config: ${ASSET_CONFIG_FILE}"
    else
      info "Generating asset config: ${ASSET_CONFIG_FILE}"
      write_asset_config
    fi
  fi

  if [ -f "$CONFIG_FILE" ]; then
    info "Keeping existing config: ${CONFIG_FILE}"
  elif [ -n "${CONFIG_URL:-}" ]; then
    info "Downloading config from CONFIG_URL"
    github_curl -o "$CONFIG_FILE" "$CONFIG_URL" || die "failed to download config"
    chmod 0600 "$CONFIG_FILE"
  elif [ -n "${SERVER:-}" ] && { { [ -z "${AGENT_ID:-}" ] && [ -z "${AGENT_SECRET:-}" ]; } || { [ -n "${AGENT_ID:-}" ] && [ -n "${AGENT_SECRET:-}" ]; }; }; then
    info "Generating config from provided Agent credentials"
    write_generated_config
  else
    if [ -f "${CONFIG_DIR}/config.json.example" ]; then
      cp "${CONFIG_DIR}/config.json.example" "$CONFIG_FILE"
      chmod 0600 "$CONFIG_FILE"
    fi
    die "config is not ready. Set CONFIG_URL, SERVER, AGENT_SERVER, PANEL_URL, or AGENT_ID/AGENT_SECRET/SERVER; or edit ${CONFIG_FILE} and rerun."
  fi

  if [ "$AGENT_ROLE" = "probe" ]; then
    return
  fi

  if [ ! -f "$ORIGINAL_CONFIG" ]; then
    info "Creating sing-box original config: ${ORIGINAL_CONFIG}"
    write_original_config
  fi
}

install_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=nx-node manager
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
User=root
Group=root
Type=simple
WorkingDirectory=${CONFIG_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} server -c ${CONFIG_FILE}
Restart=always
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

start_service() {
  if [ "$START_SERVICE" = "1" ]; then
    info "Starting ${SERVICE_NAME}"
    systemctl restart "$SERVICE_NAME"
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  else
    info "START_SERVICE=0, service was installed but not started"
  fi
}

main() {
  need_root
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  install_deps

  local asset
  asset="$(detect_asset)"
  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT

  download_release "$TMP_DIR" "$asset"
  install_files "$TMP_DIR"
  prepare_config
  install_service
  start_service

  info "Installed ${BINARY_NAME}: $(${INSTALL_DIR}/${BINARY_NAME} version 2>/dev/null || true)"
  info "Config: ${CONFIG_FILE}"
  info "Logs: journalctl -u ${SERVICE_NAME} -e --no-pager -f"
}

main "$@"
