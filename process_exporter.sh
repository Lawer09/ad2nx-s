#!/usr/bin/env bash
set -euo pipefail

PROCESS_EXPORTER_VERSION="${PROCESS_EXPORTER_VERSION:-0.8.7}"
ARCH="${ARCH:-linux-amd64}"

PROCESS_EXPORTER_BIN="/usr/local/bin/process-exporter"
PROCESS_EXPORTER_CONF_DIR="/etc/process-exporter"
PROCESS_EXPORTER_CONF_FILE="${PROCESS_EXPORTER_CONF_DIR}/process-exporter.yml"
PROCESS_EXPORTER_SERVICE_FILE="/etc/systemd/system/process-exporter.service"
PROCESS_EXPORTER_LISTEN_ADDR=":9256"
DEFAULT_PROCESS_NAME="${DEFAULT_PROCESS_NAME:-ad2nx}"

PROCESS_EXPORTER_PKG_NAME="process-exporter-${PROCESS_EXPORTER_VERSION}.${ARCH}"
PROCESS_EXPORTER_PKG_FILE="${PROCESS_EXPORTER_PKG_NAME}.tar.gz"
PROCESS_EXPORTER_DOWNLOAD_URL="https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PKG_FILE}"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 或 sudo 运行。"
    exit 1
  fi
}

ensure_process_exporter_config_dir() {
  mkdir -p "${PROCESS_EXPORTER_CONF_DIR}"
}

write_process_exporter_config() {
  local proc_name="${1:-$DEFAULT_PROCESS_NAME}"
  ensure_process_exporter_config_dir
  cat > "${PROCESS_EXPORTER_CONF_FILE}" <<EOF
process_names:
  - name: "${proc_name}"
    comm:
      - ${proc_name}
EOF
}

install_process_exporter() {
  need_root
  echo "开始安装 process-exporter..."

  cd /tmp
  rm -rf "${PROCESS_EXPORTER_PKG_NAME}" "${PROCESS_EXPORTER_PKG_FILE}"
  curl -fL -o "${PROCESS_EXPORTER_PKG_FILE}" "${PROCESS_EXPORTER_DOWNLOAD_URL}"
  tar -xzf "${PROCESS_EXPORTER_PKG_FILE}"

  install -m 0755 "${PROCESS_EXPORTER_PKG_NAME}/process-exporter" "${PROCESS_EXPORTER_BIN}"

  if [[ ! -f "${PROCESS_EXPORTER_CONF_FILE}" ]]; then
    write_process_exporter_config "${DEFAULT_PROCESS_NAME}"
  fi

  cat > "${PROCESS_EXPORTER_SERVICE_FILE}" <<EOF
[Unit]
Description=Prometheus Process Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PROCESS_EXPORTER_BIN} \
  -config.path ${PROCESS_EXPORTER_CONF_FILE} \
  -web.listen-address=${PROCESS_EXPORTER_LISTEN_ADDR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now process-exporter
  echo "process-exporter 安装完成。"
}

uninstall_process_exporter() {
  need_root
  read -rp "是否同时删除配置目录 ${PROCESS_EXPORTER_CONF_DIR} ? [y/N]: " remove_config

  systemctl stop process-exporter >/dev/null 2>&1 || true
  systemctl disable process-exporter >/dev/null 2>&1 || true
  rm -f "${PROCESS_EXPORTER_SERVICE_FILE}"
  systemctl daemon-reload
  rm -f "${PROCESS_EXPORTER_BIN}"

  if [[ "${remove_config}" =~ ^[Yy]$ ]]; then
    rm -rf "${PROCESS_EXPORTER_CONF_DIR}"
    echo "已删除配置目录: ${PROCESS_EXPORTER_CONF_DIR}"
  else
    echo "保留配置目录: ${PROCESS_EXPORTER_CONF_DIR}"
  fi
}

process_exporter_status() {
  echo
  echo "===== process-exporter 服务状态 ====="
  if systemctl list-unit-files | grep -q '^process-exporter.service'; then
    systemctl status process-exporter --no-pager || true
  else
    echo "process-exporter 未安装。"
  fi

  echo
  echo "===== 监听端口 ====="
  ss -lntp | grep ':9256' || echo "未检测到 9256 监听"

  echo
  echo "===== 本地指标抽样 ====="
  if command -v curl >/dev/null 2>&1; then
    local sample
    sample="$(curl -fsS http://127.0.0.1:9256/metrics 2>/dev/null | grep 'namedprocess_namegroup' | sed -n '1,20p' || true)"
    if [[ -n "$sample" ]]; then
      echo "$sample"
    else
      echo "未匹配到进程指标，或 metrics 中没有 namedprocess_namegroup 数据"
    fi
  else
    echo "系统未安装 curl，跳过本地指标检查"
  fi
  echo
}

configure_process_name() {
  need_root
  read -rp "请输入要监控的进程名（默认 ${DEFAULT_PROCESS_NAME}）: " proc_name
  proc_name="${proc_name:-$DEFAULT_PROCESS_NAME}"
  write_process_exporter_config "${proc_name}"
  echo "已更新进程配置: ${proc_name}"

  if systemctl list-unit-files | grep -q '^process-exporter.service'; then
    systemctl restart process-exporter || true
    echo "process-exporter 已重启"
  fi
}

main_menu() {
  while true; do
    echo
    echo "=============================="
    echo " process_exporter 管理"
    echo "=============================="
    echo "1. 安装 process-exporter"
    echo "2. 卸载 process-exporter"
    echo "3. process-exporter 状态"
    echo "4. 配置监控进程名"
    echo "0. 退出"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) install_process_exporter ;;
      2) uninstall_process_exporter ;;
      3) process_exporter_status ;;
      4) configure_process_name ;;
      0) exit 0 ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu