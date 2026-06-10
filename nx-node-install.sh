#!/usr/bin/env bash
# Linux deployment script for nx-node.
#
# Responsibilities:
# - Download the latest GitHub Release asset for the current Linux architecture.
# - Optionally use GIT_TOKEN/GITHUB_TOKEN to download from private repositories.
# - Install the nx-node binary and bundled example files.
# - Create/update a systemd service and start nx-node.manager.
# - Preserve an existing /etc/nx-node/config.json.
#
# Non-responsibilities:
# - Does not register an Agent on the panel.
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
START_SERVICE="${START_SERVICE:-1}"
GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
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

latest_release_json() {
  github_curl "https://api.github.com/repos/${REPO}/releases/latest"
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

download_release() {
  local tmp_dir="$1"
  local asset="$2"
  local release_json tag url

  info "Fetching latest release metadata from ${REPO}"
  release_json="$(latest_release_json)" || die "failed to fetch latest release metadata"
  tag="$(printf '%s' "$release_json" | json_value "tag_name")"
  [ -n "$tag" ] || die "failed to parse latest release tag"

  url="$(printf '%s' "$release_json" | sed -n "s|.*\"browser_download_url\"[[:space:]]*:[[:space:]]*\"\\([^\"]*/${asset}\\)\".*|\\1|p" | head -n 1)"
  [ -n "$url" ] || die "release ${tag} does not contain asset ${asset}"

  info "Downloading ${asset} from ${tag}"
  github_curl -o "${tmp_dir}/${asset}" "$url" || die "failed to download ${asset}"
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
  local agent_id agent_secret panel_url
  agent_id="$(json_escape "${AGENT_ID:-}")"
  agent_secret="$(json_escape "${AGENT_SECRET:-}")"
  panel_url="$(json_escape "${PANEL_URL:-}")"

  cat >"$CONFIG_FILE" <<EOF
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Agent": {
    "ID": "${agent_id}",
    "Secret": "${agent_secret}",
    "Server": "${panel_url}",
    "SendIP": "",
    "Timeout": 30
  },
  "Sync": {
    "PullInterval": 30,
    "ReportInterval": 30,
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
  "Defaults": {
    "ListenIP": "0.0.0.0",
    "SendIP": "0.0.0.0",
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
    "strategy": "prefer_ipv4 "
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "prefer_ipv4 "
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
  if [ -f "$CONFIG_FILE" ]; then
    info "Keeping existing config: ${CONFIG_FILE}"
  elif [ -n "${CONFIG_URL:-}" ]; then
    info "Downloading config from CONFIG_URL"
    github_curl -o "$CONFIG_FILE" "$CONFIG_URL" || die "failed to download config"
    chmod 0600 "$CONFIG_FILE"
  elif [ -n "${AGENT_ID:-}" ] && [ -n "${AGENT_SECRET:-}" ] && [ -n "${PANEL_URL:-}" ]; then
    info "Generating config from AGENT_ID/AGENT_SECRET/PANEL_URL"
    write_generated_config
  else
    if [ -f "${CONFIG_DIR}/config.json.example" ]; then
      cp "${CONFIG_DIR}/config.json.example" "$CONFIG_FILE"
      chmod 0600 "$CONFIG_FILE"
    fi
    die "config is not ready. Set CONFIG_URL or AGENT_ID/AGENT_SECRET/PANEL_URL, or edit ${CONFIG_FILE} and rerun."
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
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${CONFIG_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} server -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
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

  local asset tmp_dir
  asset="$(detect_asset)"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  download_release "$tmp_dir" "$asset"
  install_files "$tmp_dir"
  prepare_config
  install_service
  start_service

  info "Installed ${BINARY_NAME}: $(${INSTALL_DIR}/${BINARY_NAME} version 2>/dev/null || true)"
  info "Config: ${CONFIG_FILE}"
  info "Logs: journalctl -u ${SERVICE_NAME} -e --no-pager -f"
}

main "$@"
