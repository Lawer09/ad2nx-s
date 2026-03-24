#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-3.10.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
ARCH="${ARCH:-linux-amd64}"

PROM_USER="prometheus"
PROM_GROUP="prometheus"

NODE_USER="node_exporter"
NODE_GROUP="node_exporter"

INSTALL_BASE="/opt/prometheus"
DATA_DIR="/data/prometheus"
ETC_DIR="/etc/prometheus"
FILE_SD_DIR="${ETC_DIR}/file_sd"
NODE_TARGETS_FILE="${FILE_SD_DIR}/node_exporter.json"

PROM_BIN_LINK="/usr/local/bin/prometheus"
PROMTOOL_LINK="/usr/local/bin/promtool"
PROM_SERVICE_FILE="/etc/systemd/system/prometheus.service"

NODE_BIN="/usr/local/bin/node_exporter"
NODE_SERVICE_FILE="/etc/systemd/system/node_exporter.service"
NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

PROM_PKG_NAME="prometheus-${PROM_VERSION}.${ARCH}"
PROM_PKG_FILE="${PROM_PKG_NAME}.tar.gz"
PROM_DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_PKG_FILE}"

NODE_PKG_NAME="node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}"
NODE_PKG_FILE="${NODE_PKG_NAME}.tar.gz"
NODE_DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_PKG_FILE}"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 或 sudo 运行。"
    exit 1
  fi
}

check_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "未检测到 python3，请先安装 python3。"
    exit 1
  fi
}

check_prometheus_installed() {
  if [[ ! -x "${PROM_BIN_LINK}" ]]; then
    echo "Prometheus 未安装。"
    return 1
  fi
  return 0
}

init_node_targets_file() {
  mkdir -p "${FILE_SD_DIR}"
  if [[ ! -f "${NODE_TARGETS_FILE}" ]]; then
    cat > "${NODE_TARGETS_FILE}" <<'EOF'
[
  {
    "labels": {
      "job": "node_exporter"
    },
    "targets": []
  }
]
EOF
  fi
}

write_prometheus_config() {
  mkdir -p "${ETC_DIR}" "${FILE_SD_DIR}"

  cat > "${ETC_DIR}/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]

  - job_name: "node_exporter"
    file_sd_configs:
      - files:
          - "${NODE_TARGETS_FILE}"
        refresh_interval: 30s
EOF

  init_node_targets_file
}

install_prometheus() {
  need_root
  check_python3

  echo "开始安装 Prometheus..."

  if ! getent group "${PROM_GROUP}" >/dev/null; then
    groupadd --system "${PROM_GROUP}"
  fi

  if ! id -u "${PROM_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g "${PROM_GROUP}" "${PROM_USER}"
  fi

  mkdir -p "${INSTALL_BASE}" "${DATA_DIR}" "${ETC_DIR}" "${FILE_SD_DIR}"
  chown -R "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}" "${ETC_DIR}"

  cd /tmp
  rm -rf "${PROM_PKG_NAME}" "${PROM_PKG_FILE}"

  echo "下载 ${PROM_DOWNLOAD_URL}"
  curl -fL -o "${PROM_PKG_FILE}" "${PROM_DOWNLOAD_URL}"

  echo "解压安装包..."
  tar -xzf "${PROM_PKG_FILE}"

  echo "安装 Prometheus 到 ${INSTALL_BASE}/${PROM_PKG_NAME}"
  rm -rf "${INSTALL_BASE:?}/${PROM_PKG_NAME}"
  mv "${PROM_PKG_NAME}" "${INSTALL_BASE}/"

  ln -sfn "${INSTALL_BASE}/${PROM_PKG_NAME}/prometheus" "${PROM_BIN_LINK}"
  ln -sfn "${INSTALL_BASE}/${PROM_PKG_NAME}/promtool" "${PROMTOOL_LINK}"

  write_prometheus_config

  cat > "${PROM_SERVICE_FILE}" <<'EOF'
[Unit]
Description=Prometheus Monitoring System
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/data/prometheus \
  --web.listen-address=:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=/data/prometheus

[Install]
WantedBy=multi-user.target
EOF

  chown -R "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}" "${ETC_DIR}"
  chown -R "${PROM_USER}:${PROM_GROUP}" "${INSTALL_BASE}/${PROM_PKG_NAME}"
  chown -h "${PROM_USER}:${PROM_GROUP}" "${PROM_BIN_LINK}" "${PROMTOOL_LINK}" || true

  echo "检查 Prometheus 配置..."
  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"

  systemctl daemon-reload
  systemctl enable --now prometheus

  echo
  echo "Prometheus 安装完成。"
  echo "访问地址: http://127.0.0.1:9090"
  echo "查看状态: systemctl status prometheus"
}

reload_prometheus() {
  if systemctl is-active --quiet prometheus; then
    if curl -fsS -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
      echo "Prometheus 已热重载。"
    else
      echo "热重载失败，尝试重启服务..."
      systemctl restart prometheus
      echo "Prometheus 已重启。"
    fi
  else
    echo "Prometheus 未运行，跳过重载。"
  fi
}

list_node_targets() {
  check_python3
  init_node_targets_file

  echo
  echo "当前 node_exporter 监测节点："
  python3 - <<PY
import json
f = "${NODE_TARGETS_FILE}"
with open(f, "r", encoding="utf-8") as fp:
    data = json.load(fp)

targets = []
for item in data:
    targets.extend(item.get("targets", []))

if not targets:
    print("  (空)")
else:
    for i, t in enumerate(sorted(targets), 1):
        print(f"  {i}. {t}")
PY
  echo
}

add_node_target() {
  need_root
  check_python3
  check_prometheus_installed || return 1
  init_node_targets_file

  read -rp "请输入 node_exporter 目标地址（例如 10.0.0.11:9100）: " target

  if [[ -z "${target}" ]]; then
    echo "目标不能为空。"
    return 1
  fi

  python3 - <<PY
import json, sys
f = "${NODE_TARGETS_FILE}"
target = "${target}"

with open(f, "r", encoding="utf-8") as fp:
    data = json.load(fp)

if not data:
    data = [{"labels": {"job": "node_exporter"}, "targets": []}]

targets = data[0].setdefault("targets", [])
if target in targets:
    print("节点已存在，无需重复添加。")
    sys.exit(0)

targets.append(target)
targets.sort()

with open(f, "w", encoding="utf-8") as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)

print(f"已添加节点: {target}")
PY

  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
  reload_prometheus
}

delete_node_target() {
  need_root
  check_python3
  check_prometheus_installed || return 1
  init_node_targets_file

  list_node_targets
  read -rp "请输入要删除的目标地址（例如 10.0.0.11:9100）: " target

  if [[ -z "${target}" ]]; then
    echo "目标不能为空。"
    return 1
  fi

  python3 - <<PY
import json, sys
f = "${NODE_TARGETS_FILE}"
target = "${target}"

with open(f, "r", encoding="utf-8") as fp:
    data = json.load(fp)

if not data:
    print("目标文件为空。")
    sys.exit(1)

targets = data[0].setdefault("targets", [])
if target not in targets:
    print("未找到该节点。")
    sys.exit(1)

targets.remove(target)

with open(f, "w", encoding="utf-8") as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)

print(f"已删除节点: {target}")
PY

  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
  reload_prometheus
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

  echo "下载 ${NODE_DOWNLOAD_URL}"
  curl -fL -o "${NODE_PKG_FILE}" "${NODE_DOWNLOAD_URL}"

  echo "解压安装包..."
  tar -xzf "${NODE_PKG_FILE}"

  install -m 0755 "${NODE_PKG_NAME}/node_exporter" "${NODE_BIN}"

  cat > "${NODE_SERVICE_FILE}" <<'EOF'
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
EOF

  systemctl daemon-reload
  systemctl enable --now node_exporter

  echo
  echo "node_exporter 安装完成。"
  echo "查看状态: systemctl status node_exporter"
  echo "查看指标: curl http://127.0.0.1:9100/metrics | head"
}

uninstall_node_exporter() {
  need_root

  echo "准备卸载 node_exporter..."
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

  echo "node_exporter 已卸载。"
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
    curl -fsS http://127.0.0.1:9100/metrics | head -20 || echo "无法访问本地 metrics"
  else
    echo "系统未安装 curl，跳过本地指标检查"
  fi
  echo
}

manage_probe_targets_menu() {
  while true; do
    echo
    echo "=============================="
    echo " node_exporter 监测节点管理"
    echo "=============================="
    echo "1. 查看监测节点"
    echo "2. 添加监测节点"
    echo "3. 删除监测节点"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice

    case "${sub_choice}" in
      1) list_node_targets ;;
      2) add_node_target ;;
      3) delete_node_target ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

manage_node_exporter_menu() {
  while true; do
    echo
    echo "=============================="
    echo " node_exporter 管理"
    echo "=============================="
    echo "1. 安装 node_exporter"
    echo "2. 卸载 node_exporter"
    echo "3. node_exporter 状态"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice

    case "${sub_choice}" in
      1) install_node_exporter ;;
      2) uninstall_node_exporter ;;
      3) node_exporter_status ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

uninstall_prometheus() {
  need_root

  echo "准备卸载 Prometheus..."
  read -rp "是否同时删除数据目录 ${DATA_DIR} ? [y/N]: " remove_data
  read -rp "是否同时删除配置目录 ${ETC_DIR} ? [y/N]: " remove_config

  systemctl stop prometheus >/dev/null 2>&1 || true
  systemctl disable prometheus >/dev/null 2>&1 || true

  rm -f "${PROM_SERVICE_FILE}"
  systemctl daemon-reload

  rm -f "${PROM_BIN_LINK}" "${PROMTOOL_LINK}"
  rm -rf "${INSTALL_BASE}"/prometheus-* || true

  if [[ "${remove_data}" =~ ^[Yy]$ ]]; then
    rm -rf "${DATA_DIR}"
    echo "已删除数据目录: ${DATA_DIR}"
  else
    echo "保留数据目录: ${DATA_DIR}"
  fi

  if [[ "${remove_config}" =~ ^[Yy]$ ]]; then
    rm -rf "${ETC_DIR}"
    echo "已删除配置目录: ${ETC_DIR}"
  else
    echo "保留配置目录: ${ETC_DIR}"
  fi

  echo "Prometheus 已卸载。"
}

main_menu() {
  while true; do
    echo
    echo "========================================"
    echo " Prometheus / node_exporter 快捷管理脚本"
    echo "========================================"
    echo "1. node_exporter 管理"
    echo "2. 管理 node_exporter 监测节点（添加/删除/查看）"
    echo "3. 安装 Prometheus"
    echo "4. 卸载 Prometheus"
    echo "5. 查看 Prometheus 服务状态"
    echo "6. 重载 Prometheus 配置"
    echo "0. 退出"
    echo "========================================"
    read -rp "请选择: " choice

    case "${choice}" in
      1) manage_node_exporter_menu ;;
      2) manage_probe_targets_menu ;;
      3) install_prometheus ;;
      4) uninstall_prometheus ;;
      5) systemctl status prometheus --no-pager || true ;;
      6) reload_prometheus ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu