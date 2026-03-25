#!/usr/bin/env bash
set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
ARCH="${ARCH:-linux-amd64}"

NODE_USER="node_exporter"
NODE_GROUP="node_exporter"

NODE_BIN="/usr/local/bin/node_exporter"
NODE_SERVICE_FILE="/etc/systemd/system/node_exporter.service"
NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

NODE_PKG_NAME="node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}"
NODE_PKG_FILE="${NODE_PKG_NAME}.tar.gz"
NODE_DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_PKG_FILE}"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 或 sudo 运行。"
    exit 1
  fi
}

install_node_exporter() {
  need_root
  echo "开始安装 node_exporter..."

  if ! getent group "${NODE_GROUP}" >/dev/null; then
    groupadd --system "${NODE_GROUP}"
  fi
  if ! id -u "${NODE_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g "${NODE_GROUP}" "${NODE_USER}"
  fi

  mkdir -p "${NODE_TEXTFILE_DIR}"
  chown -R "${NODE_USER}:${NODE_GROUP}" /var/lib/node_exporter

  cd /tmp
  rm -rf "${NODE_PKG_NAME}" "${NODE_PKG_FILE}"
  curl -fL -o "${NODE_PKG_FILE}" "${NODE_DOWNLOAD_URL}"
  tar -xzf "${NODE_PKG_FILE}"

  install -m 0755 "${NODE_PKG_NAME}/node_exporter" "${NODE_BIN}"

  cat > "${NODE_SERVICE_FILE}" <<'SERVICE'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --collector.systemd \
  --collector.processes \
  --collector.tcpstat \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
  --collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+|var/lib/containerd/.+|snap)($|/) \
  --collector.netdev.device-exclude=^(lo|docker.*|veth.*|br-.*|virbr.*|flannel.*|cali.*|cilium.*|tun.*)$
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now node_exporter
  echo "node_exporter 安装完成。"
}

uninstall_node_exporter() {
  need_root
  read -rp "是否同时删除 textfile collector 数据目录 /var/lib/node_exporter ? [y/N]: " remove_data

  systemctl stop node_exporter >/dev/null 2>&1 || true
  systemctl disable node_exporter >/dev/null 2>&1 || true
  rm -f "${NODE_SERVICE_FILE}"
  systemctl daemon-reload
  rm -f "${NODE_BIN}"

  if [[ "${remove_data}" =~ ^[Yy]$ ]]; then
    rm -rf /var/lib/node_exporter
    echo "已删除 /var/lib/node_exporter"
  else
    echo "保留 /var/lib/node_exporter"
  fi
}

node_exporter_status() {
  echo
  echo "===== node_exporter 服务状态 ====="
  if systemctl list-unit-files | grep -q '^node_exporter.service'; then
    systemctl status node_exporter --no-pager || true
  else
    echo "node_exporter 未安装。"
  fi

  echo
  echo "===== 监听端口 ====="
  ss -lntp | grep ':9100' || echo "未检测到 9100 监听"

  echo
  echo "===== 本地指标探测 ====="
  if command -v curl >/dev/null 2>&1; then
    local sample
    sample="$(curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | sed -n '1,20p' || true)"
    if [[ -n "$sample" ]]; then
      echo "$sample"
    else
      echo "无法访问本地 metrics"
    fi
  else
    echo "系统未安装 curl，跳过本地指标检查"
  fi
  echo
}

main_menu() {
  while true; do
    echo
    echo "=============================="
    echo " node_exporter 管理"
    echo "=============================="
    echo "1. 安装 node_exporter"
    echo "2. 卸载 node_exporter"
    echo "3. node_exporter 状态"
    echo "0. 退出"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) install_node_exporter ;;
      2) uninstall_node_exporter ;;
      3) node_exporter_status ;;
      0) exit 0 ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu