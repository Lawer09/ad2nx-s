#!/usr/bin/env bash

set -euo pipefail

APP_NAME="singbox-node-agent"
APP_VERSION="${APP_VERSION:-0.1.0}"
GITHUB_REPO="${GITHUB_REPO:-Lawer09/node-agent}"

INSTALL_DIR="/opt/${APP_NAME}"
BIN_PATH="${INSTALL_DIR}/node-agent"
CONFIG_PATH="${INSTALL_DIR}/config.yaml"
LOG_DIR="${INSTALL_DIR}/logs"
SERVICE_PATH="/etc/systemd/system/${APP_NAME}.service"

SINGBOX_BIN_PATH="/usr/local/bin/sing-box"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.0}"

TMP_DIR="/tmp/${APP_NAME}-$$"

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
blue() { echo -e "\033[36m$1\033[0m"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    red "请使用 root 运行该脚本"
    exit 1
  fi
}

ensure_deps() {
  if ! command -v apt >/dev/null 2>&1; then
    red "当前脚本仅支持 Debian/Ubuntu 系统（需要 apt）"
    exit 1
  fi

  apt update -y
  apt install -y curl unzip tar grep sed ca-certificates

  if ! command -v yq >/dev/null 2>&1; then
    yellow "未检测到 yq，开始安装..."
    install_yq
  fi
}

install_yq() {
  local arch yq_arch yq_url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) yq_arch="amd64" ;;
    aarch64|arm64) yq_arch="arm64" ;;
    *)
      red "不支持的 yq 架构: ${arch}"
      exit 1
      ;;
  esac

  yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"
  curl -L --fail "$yq_url" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq

  if ! yq --version >/dev/null 2>&1; then
    red "yq 安装失败"
    exit 1
  fi

  green "yq 安装完成"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64)
      AGENT_ARCH="arm64"
      SINGBOX_ARCH="linux-arm64"
      ;;
    x86_64|amd64)
      AGENT_ARCH="amd64"
      SINGBOX_ARCH="linux-amd64"
      ;;
    *)
      red "不支持的架构: ${arch}"
      exit 1
      ;;
  esac
}

set_urls() {
  AGENT_URL="https://github.com/${GITHUB_REPO}/releases/download/${APP_VERSION}/node-agent-linux-${AGENT_ARCH}.zip"
  SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-${SINGBOX_ARCH}.tar.gz"
}

prepare_env() {
  detect_arch
  set_urls
  mkdir -p "${TMP_DIR}"
}

download_file() {
  local url="$1"
  local output="$2"
  green "下载: ${url}"
  curl -L --fail "$url" -o "$output"
}

create_service() {
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Singbox Node Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${APP_NAME}" >/dev/null 2>&1 || true
}

install_config_from_unzipped_if_missing() {
  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"

  if [[ -f "${CONFIG_PATH}" ]]; then
    yellow "检测到已有配置文件，跳过覆盖: ${CONFIG_PATH}"
    return
  fi

  local found_config
  found_config="$(find "${TMP_DIR}" -type f -name 'config.yaml' | head -n 1)"

  if [[ -z "${found_config}" ]]; then
    red "在当前 zip 中未找到 config.yaml"
    exit 1
  fi

  cp "${found_config}" "${CONFIG_PATH}"
  green "默认配置已安装: ${CONFIG_PATH}"
}

install_node_agent() {
  check_root
  ensure_deps
  prepare_env

  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"

  local zip_file="${TMP_DIR}/node-agent.zip"
  download_file "${AGENT_URL}" "${zip_file}"
  unzip -o "${zip_file}" -d "${TMP_DIR}" >/dev/null

  local found_bin
  found_bin="$(find "${TMP_DIR}" -type f -name 'node-agent' | head -n 1)"
  if [[ -z "${found_bin}" ]]; then
    red "未找到 node-agent 二进制"
    exit 1
  fi

  cp "${found_bin}" "${BIN_PATH}"
  chmod +x "${BIN_PATH}"

  install_config_from_unzipped_if_missing
  create_service

  if [[ ! -x "${SINGBOX_BIN_PATH}" ]]; then
    yellow "未检测到 sing-box: ${SINGBOX_BIN_PATH}"
    yellow "请在菜单中执行“安装 sing-box”"
  fi

  systemctl restart "${APP_NAME}" || true
  green "node-agent 安装完成"
}

uninstall_node_agent() {
  check_root
  systemctl stop "${APP_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${APP_NAME}" >/dev/null 2>&1 || true
  rm -f "${SERVICE_PATH}"
  systemctl daemon-reload
  rm -rf "${INSTALL_DIR}"
  green "node-agent 已卸载"
}

restart_node_agent() {
  check_root
  if [[ ! -f "${SERVICE_PATH}" ]]; then
    red "未安装 ${APP_NAME}"
    exit 1
  fi
  systemctl restart "${APP_NAME}"
  sleep 1
  systemctl status "${APP_NAME}" --no-pager || true
}

update_node_agent() {
  check_root
  ensure_deps
  prepare_env

  local zip_file="${TMP_DIR}/node-agent-update.zip"
  download_file "${AGENT_URL}" "${zip_file}"
  unzip -o "${zip_file}" -d "${TMP_DIR}" >/dev/null

  local found_bin
  found_bin="$(find "${TMP_DIR}" -type f -name 'node-agent' | head -n 1)"
  if [[ -z "${found_bin}" ]]; then
    red "未找到 node-agent 二进制"
    exit 1
  fi

  cp "${found_bin}" "${BIN_PATH}"
  chmod +x "${BIN_PATH}"

  yellow "当前配置文件保留不覆盖: ${CONFIG_PATH}"
  systemctl restart "${APP_NAME}" || true
  green "node-agent 更新完成"
}

install_singbox() {
  check_root
  ensure_deps
  prepare_env

  if [[ -x "${SINGBOX_BIN_PATH}" ]]; then
    yellow "检测到 sing-box 已安装: ${SINGBOX_BIN_PATH}"
    "${SINGBOX_BIN_PATH}" version || true
    read -rp "是否卸载后重新安装 sing-box？[y/N]: " answer
    case "$answer" in
      y|Y|yes|YES)
        uninstall_singbox
        ;;
      *)
        yellow "已取消重新安装"
        return
        ;;
    esac
  fi

  local tar_file="${TMP_DIR}/sing-box.tar.gz"
  download_file "${SINGBOX_URL}" "${tar_file}"
  tar -xzf "${tar_file}" -C "${TMP_DIR}"

  local found_bin
  found_bin="$(find "${TMP_DIR}" -type f -name 'sing-box' | head -n 1)"
  if [[ -z "${found_bin}" ]]; then
    red "未找到 sing-box 可执行文件"
    exit 1
  fi

  cp "${found_bin}" "${SINGBOX_BIN_PATH}"
  chmod +x "${SINGBOX_BIN_PATH}"

  green "sing-box 安装完成"
  "${SINGBOX_BIN_PATH}" version || true

  if systemctl list-unit-files | grep -q "^${APP_NAME}.service"; then
    systemctl restart "${APP_NAME}" || true
  fi
}

uninstall_singbox() {
  check_root
  if [[ ! -f "${SINGBOX_BIN_PATH}" ]]; then
    yellow "未检测到 sing-box，无需卸载"
    return
  fi
  rm -f "${SINGBOX_BIN_PATH}"
  green "sing-box 已卸载"
}

ensure_config_exists() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    red "配置文件不存在，请先安装 node-agent"
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    red "未检测到 yq"
    exit 1
  fi
}

configure_subscription() {
  check_root
  ensure_config_exists

  read -rp "请输入订阅链接: " SUB_URL
  if [[ -z "${SUB_URL}" ]]; then
    red "订阅链接不能为空"
    exit 1
  fi

  yq -i '
    .subscription.enabled = true |
    .subscription.url = strenv(SUB_URL) |
    .subscription.refresh_interval_seconds = (.subscription.refresh_interval_seconds // 300) |
    .subscription.enable_base64_decode = (.subscription.enable_base64_decode // true) |
    .subscription.include_protocols = (.subscription.include_protocols // ["vless"]) |
    .subscription.reality_only = (.subscription.reality_only // true)
  ' "${CONFIG_PATH}"

  green "订阅链接已更新"
  systemctl restart "${APP_NAME}" || true
}

configure_probe_meta() {
  check_root
  ensure_config_exists

  read -rp "probe_agent.name: " PA_NAME
  read -rp "probe_agent.region: " PA_REGION
  read -rp "probe_agent.country: " PA_COUNTRY
  read -rp "probe_agent.city: " PA_CITY
  read -rp "probe_agent.provider: " PA_PROVIDER
  read -rp "probe_agent.asn: " PA_ASN
  read -rp "probe_agent.env [prod/test]: " PA_ENV
  read -rp "probe_agent.cluster: " PA_CLUSTER

  yq -i '
    .probe_agent.name = strenv(PA_NAME) |
    .probe_agent.region = strenv(PA_REGION) |
    .probe_agent.country = strenv(PA_COUNTRY) |
    .probe_agent.city = strenv(PA_CITY) |
    .probe_agent.provider = strenv(PA_PROVIDER) |
    .probe_agent.asn = strenv(PA_ASN) |
    .probe_agent.env = strenv(PA_ENV) |
    .probe_agent.cluster = strenv(PA_CLUSTER)
  ' "${CONFIG_PATH}"

  green "探测机元信息已更新"
  systemctl restart "${APP_NAME}" || true
}

configure_probe_mode() {
  check_root
  ensure_config_exists

  echo "可选模式:"
  echo "1. standard"
  echo "2. business"
  echo "3. both"
  read -rp "请选择 probe_mode [1-3]: " mode_choice

  case "$mode_choice" in
    1) MODE="standard" ;;
    2) MODE="business" ;;
    3) MODE="both" ;;
    *) red "无效选项"; exit 1 ;;
  esac

  yq -i '
    .default_probe.interval_seconds = (.default_probe.interval_seconds // 60) |
    .default_probe.timeout_seconds = (.default_probe.timeout_seconds // 8) |
    .default_probe.utls_fingerprint = (.default_probe.utls_fingerprint // "chrome") |
    .default_probe.probe_mode = strenv(MODE) |
    .default_probe.probe_targets.standard = (.default_probe.probe_targets.standard // ["https://cp.cloudflare.com/generate_204","https://www.gstatic.com/generate_204"]) |
    .default_probe.probe_targets.business = (.default_probe.probe_targets.business // [])
  ' "${CONFIG_PATH}"

  green "probe_mode 已更新为: ${MODE}"
  systemctl restart "${APP_NAME}" || true
}

configure_business_url() {
  check_root
  ensure_config_exists

  read -rp "请输入 business probe URL: " BIZ_URL
  if [[ -z "${BIZ_URL}" ]]; then
    red "business URL 不能为空"
    exit 1
  fi

  yq -i '
    .default_probe.interval_seconds = (.default_probe.interval_seconds // 60) |
    .default_probe.timeout_seconds = (.default_probe.timeout_seconds // 8) |
    .default_probe.utls_fingerprint = (.default_probe.utls_fingerprint // "chrome") |
    .default_probe.probe_targets.standard = (.default_probe.probe_targets.standard // ["https://cp.cloudflare.com/generate_204","https://www.gstatic.com/generate_204"]) |
    .default_probe.probe_targets.business = [strenv(BIZ_URL)]
  ' "${CONFIG_PATH}"

  green "business probe URL 已更新"
  systemctl restart "${APP_NAME}" || true
}

show_status() {
  clear
  echo "=============================="
  echo " 状态信息"
  echo "=============================="

  if [[ -x "${BIN_PATH}" ]]; then
    green "node-agent: 已安装"
  else
    red "node-agent: 未安装"
  fi

  if [[ -x "${SINGBOX_BIN_PATH}" ]]; then
    green "sing-box: 已安装"
    "${SINGBOX_BIN_PATH}" version || true
  else
    red "sing-box: 未安装"
  fi

  echo
  if systemctl list-unit-files | grep -q "^${APP_NAME}.service"; then
    blue "服务状态："
    systemctl status "${APP_NAME}" --no-pager || true
  else
    yellow "systemd 服务不存在"
  fi

  echo
  if [[ -f "${CONFIG_PATH}" ]]; then
    blue "订阅配置："
    yq '.subscription' "${CONFIG_PATH}" || true
    echo
    blue "探测机元信息："
    yq '.probe_agent' "${CONFIG_PATH}" || true
    echo
    blue "探测模式："
    yq '.default_probe' "${CONFIG_PATH}" || true
  else
    yellow "配置文件不存在"
  fi
}

show_logs() {
  check_root
  journalctl -u "${APP_NAME}" -n 100 --no-pager || true
}

follow_logs() {
  check_root
  journalctl -u "${APP_NAME}" -f
}

show_menu() {
  clear
  echo "======================================"
  echo " singbox-node-agent 管理菜单（yq版）"
  echo "======================================"
  echo "1. 安装 node-agent"
  echo "2. 卸载 node-agent"
  echo "3. 重启 node-agent"
  echo "4. 更新 node-agent"
  echo "5. 安装 sing-box"
  echo "6. 卸载 sing-box"
  echo "7. 配置订阅链接"
  echo "8. 配置探测机元信息"
  echo "9. 配置 probe mode"
  echo "10. 配置 business URL"
  echo "11. 查看状态"
  echo "12. 查看日志"
  echo "13. 实时日志"
  echo "0. 退出"
  echo "======================================"
}

main() {
  while true; do
    show_menu
    read -rp "请输入选项: " choice
    case "$choice" in
      1) install_node_agent ;;
      2) uninstall_node_agent ;;
      3) restart_node_agent ;;
      4) update_node_agent ;;
      5) install_singbox ;;
      6) uninstall_singbox ;;
      7) configure_subscription ;;
      8) configure_probe_meta ;;
      9) configure_probe_mode ;;
      10) configure_business_url ;;
      11) show_status ;;
      12) show_logs ;;
      13) follow_logs ;;
      0) exit 0 ;;
      *) yellow "无效选项，请重新输入" ;;
    esac
    echo
    read -rp "按回车继续..." _
  done
}

main