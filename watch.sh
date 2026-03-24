#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-3.10.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
PROCESS_EXPORTER_VERSION="${PROCESS_EXPORTER_VERSION:-0.8.7}"
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
PROCESS_TARGETS_FILE="${FILE_SD_DIR}/process_exporter.json"

PROM_BIN_LINK="/usr/local/bin/prometheus"
PROMTOOL_LINK="/usr/local/bin/promtool"
PROM_SERVICE_FILE="/etc/systemd/system/prometheus.service"

NODE_BIN="/usr/local/bin/node_exporter"
NODE_SERVICE_FILE="/etc/systemd/system/node_exporter.service"
NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

PROCESS_EXPORTER_BIN="/usr/local/bin/process-exporter"
PROCESS_EXPORTER_CONF_DIR="/etc/process-exporter"
PROCESS_EXPORTER_CONF_FILE="${PROCESS_EXPORTER_CONF_DIR}/process-exporter.yml"
PROCESS_EXPORTER_SERVICE_FILE="/etc/systemd/system/process-exporter.service"
PROCESS_EXPORTER_LISTEN_ADDR=":9256"
DEFAULT_PROCESS_NAME="ad2nx"

PROM_PKG_NAME="prometheus-${PROM_VERSION}.${ARCH}"
PROM_PKG_FILE="${PROM_PKG_NAME}.tar.gz"
PROM_DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_PKG_FILE}"

NODE_PKG_NAME="node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}"
NODE_PKG_FILE="${NODE_PKG_NAME}.tar.gz"
NODE_DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_PKG_FILE}"

PROCESS_EXPORTER_PKG_NAME="process-exporter-${PROCESS_EXPORTER_VERSION}.${ARCH}"
PROCESS_EXPORTER_PKG_FILE="${PROCESS_EXPORTER_PKG_NAME}.tar.gz"
PROCESS_EXPORTER_DOWNLOAD_URL="https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PKG_FILE}"

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

normalize_target() {
  local raw="${1:-}"
  printf '%s' "$raw" | sed 's/[[:space:]]//g; s/：/:/g'
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
    cat > "${NODE_TARGETS_FILE}" <<'JSON'
[
  {
    "labels": {
      "job": "node_exporter"
    },
    "targets": []
  }
]
JSON
  fi
}
init_process_targets_file() {
  mkdir -p "${FILE_SD_DIR}"
  if [[ ! -f "${PROCESS_TARGETS_FILE}" ]]; then
    cat > "${PROCESS_TARGETS_FILE}" <<'JSON'
[
  {
    "labels": {
      "job": "process_exporter"
    },
    "targets": []
  }
]
JSON
  fi
}

normalize_process_targets_file() {
  check_python3
  init_process_targets_file
  python3 - <<PY
import json
from pathlib import Path
f = Path("${PROCESS_TARGETS_FILE}")
data = json.loads(f.read_text(encoding="utf-8"))
if not data:
    data = [{"labels": {"job": "process_exporter"}, "targets": []}]
targets = data[0].setdefault("targets", [])
seen = set()
normalized = []
for t in targets:
    nt = str(t).strip().replace("：", ":").replace(" ", "")
    if nt and nt not in seen:
        seen.add(nt)
        normalized.append(nt)
normalized.sort()
data[0]["targets"] = normalized
f.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
PY
}

set_process_exporter_prom_target() {
  check_python3
  init_process_targets_file
  local target="${1:-127.0.0.1:9256}"
  target="$(normalize_target "$target")"
  python3 - <<PY
import json
f = "${PROCESS_TARGETS_FILE}"
target = "${target}"
with open(f, "r", encoding="utf-8") as fp:
    data = json.load(fp)
if not data:
    data = [{"labels": {"job": "process_exporter"}, "targets": []}]
data[0]["targets"] = [target] if target else []
with open(f, "w", encoding="utf-8") as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)
print(f"process-exporter Prometheus 抓取目标已设置为: {target}")
PY
}

clear_process_exporter_prom_target() {
  check_python3
  init_process_targets_file
  cat > "${PROCESS_TARGETS_FILE}" <<'JSON'
[
  {
    "labels": {
      "job": "process_exporter"
    },
    "targets": []
  }
]
JSON
  echo "已移除 process-exporter Prometheus 抓取目标。"
}

normalize_node_targets_file() {
  check_python3
  init_node_targets_file
  python3 - <<PY
import json
from pathlib import Path
f = Path("${NODE_TARGETS_FILE}")
data = json.loads(f.read_text(encoding="utf-8"))
if not data:
    data = [{"labels": {"job": "node_exporter"}, "targets": []}]
targets = data[0].setdefault("targets", [])
seen = set()
normalized = []
for t in targets:
    nt = str(t).strip().replace("：", ":").replace(" ", "")
    if nt and nt not in seen:
        seen.add(nt)
        normalized.append(nt)
normalized.sort()
data[0]["targets"] = normalized
f.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
PY
}

write_prometheus_config() {
  mkdir -p "${ETC_DIR}" "${FILE_SD_DIR}"
  cat > "${ETC_DIR}/prometheus.yml" <<EOF2
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

  - job_name: "process_exporter"
    file_sd_configs:
      - files:
          - "${PROCESS_TARGETS_FILE}"
        refresh_interval: 30s
EOF2
  init_node_targets_file
  normalize_node_targets_file
  init_process_targets_file
  normalize_process_targets_file
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
  tar -xzf "${PROM_PKG_FILE}"
  rm -rf "${INSTALL_BASE:?}/${PROM_PKG_NAME}"
  mv "${PROM_PKG_NAME}" "${INSTALL_BASE}/"

  ln -sfn "${INSTALL_BASE}/${PROM_PKG_NAME}/prometheus" "${PROM_BIN_LINK}"
  ln -sfn "${INSTALL_BASE}/${PROM_PKG_NAME}/promtool" "${PROMTOOL_LINK}"

  write_prometheus_config
  if systemctl list-unit-files | grep -q '^process-exporter.service'; then
    if systemctl is-enabled process-exporter >/dev/null 2>&1 || systemctl is-active --quiet process-exporter; then
      set_process_exporter_prom_target "127.0.0.1:9256"
    fi
  fi

  cat > "${PROM_SERVICE_FILE}" <<'SERVICE'
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
SERVICE

  chown -R "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}" "${ETC_DIR}"
  chown -R "${PROM_USER}:${PROM_GROUP}" "${INSTALL_BASE}/${PROM_PKG_NAME}"
  chown -h "${PROM_USER}:${PROM_GROUP}" "${PROM_BIN_LINK}" "${PROMTOOL_LINK}" || true

  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
  systemctl daemon-reload
  systemctl enable --now prometheus
  echo "Prometheus 安装完成。访问: http://127.0.0.1:9090"
}

list_node_targets() {
  check_python3
  normalize_node_targets_file
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
    for i, t in enumerate(targets, 1):
        print(f"  {i}. {t}")
PY
  echo
}

add_node_target() {
  need_root
  check_python3
  check_prometheus_installed || return 1
  normalize_node_targets_file

  read -rp "请输入 node_exporter 目标地址（例如 10.0.0.11:9100）: " target
  target="$(normalize_target "$target")"

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
target = target.strip().replace("：", ":").replace(" ", "")
normalized = []
seen = set()
for t in targets:
    nt = str(t).strip().replace("：", ":").replace(" ", "")
    if nt and nt not in seen:
        seen.add(nt)
        normalized.append(nt)
if target in seen:
    print("节点已存在，无需重复添加。")
    data[0]["targets"] = sorted(normalized)
    with open(f, "w", encoding="utf-8") as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
    sys.exit(0)
normalized.append(target)
data[0]["targets"] = sorted(normalized)
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
  normalize_node_targets_file
  list_node_targets
  read -rp "请输入要删除的序号或目标地址（例如 2 或 10.0.0.11:9100）: " target_input
  target_input="$(normalize_target "$target_input")"

  if [[ -z "${target_input}" ]]; then
    echo "输入不能为空。"
    return 1
  fi

  python3 - <<PY
import json, sys
f = "${NODE_TARGETS_FILE}"
user_input = "${target_input}".strip().replace("：", ":").replace(" ", "")
with open(f, "r", encoding="utf-8") as fp:
    data = json.load(fp)
if not data:
    print("目标文件为空。")
    sys.exit(1)

targets = [str(t).strip().replace("：", ":").replace(" ", "") for t in data[0].setdefault("targets", [])]
targets = sorted(dict.fromkeys([t for t in targets if t]))
if not targets:
    print("当前没有可删除的节点。")
    sys.exit(1)

deleted = None
if user_input.isdigit():
    idx = int(user_input)
    if idx < 1 or idx > len(targets):
        print(f"序号超出范围，当前有效范围: 1-{len(targets)}")
        sys.exit(1)
    deleted = targets.pop(idx - 1)
else:
    if user_input not in targets:
        print("未找到该节点。你可以输入序号，或输入完整地址。")
        sys.exit(1)
    targets.remove(user_input)
    deleted = user_input

data[0]["targets"] = targets
with open(f, "w", encoding="utf-8") as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)
print(f"已删除节点: {deleted}")
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
    curl -fsS http://127.0.0.1:9100/metrics | head -20 || echo "无法访问本地 metrics"
  else
    echo "系统未安装 curl，跳过本地指标检查"
  fi
  echo
}

ensure_process_exporter_config_dir() {
  mkdir -p "${PROCESS_EXPORTER_CONF_DIR}"
}

write_process_exporter_config() {
  local proc_name="${1:-$DEFAULT_PROCESS_NAME}"
  ensure_process_exporter_config_dir
  cat > "${PROCESS_EXPORTER_CONF_FILE}" <<EOF2
process_names:
  - name: "${proc_name}"
    comm:
      - ${proc_name}
EOF2
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
  cat > "${PROCESS_EXPORTER_SERVICE_FILE}" <<EOF2
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
EOF2
  systemctl daemon-reload
  systemctl enable --now process-exporter
  if [[ -x "${PROM_BIN_LINK}" ]]; then
    set_process_exporter_prom_target "127.0.0.1:9256"
    "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
    reload_prometheus
  fi
  echo "process-exporter 安装完成。"
  if [[ -x "${PROM_BIN_LINK}" ]]; then
    echo "已自动加入 Prometheus 抓取配置: 127.0.0.1:9256"
  fi
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
  if [[ -x "${PROM_BIN_LINK}" ]]; then
    read -rp "是否同时从 Prometheus 抓取配置中移除 process-exporter 目标? [Y/n]: " remove_prom_target
    if [[ ! "${remove_prom_target:-Y}" =~ ^[Nn]$ ]]; then
      clear_process_exporter_prom_target
      "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
      reload_prometheus
    fi
  fi
}

configure_process_exporter_name() {
  need_root
  local current_name=""
  if [[ -f "${PROCESS_EXPORTER_CONF_FILE}" ]]; then
    current_name="$(awk -F'"' '/name: "/ {print $2; exit}' "${PROCESS_EXPORTER_CONF_FILE}" || true)"
  fi
  echo "当前进程名: ${current_name:-未配置}"
  read -rp "请输入要监控的进程名 [默认 ${DEFAULT_PROCESS_NAME}]: " proc_name
  proc_name="${proc_name:-$DEFAULT_PROCESS_NAME}"
  write_process_exporter_config "$proc_name"
  echo "已更新配置: ${PROCESS_EXPORTER_CONF_FILE}"
  if systemctl is-active --quiet process-exporter; then
    systemctl restart process-exporter
    echo "process-exporter 已重启并应用新配置。"
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
  echo "===== Prometheus 抓取目标 ====="
  if [[ -f "${PROCESS_TARGETS_FILE}" ]]; then
    cat "${PROCESS_TARGETS_FILE}"
  else
    echo "Prometheus 抓取目标文件不存在"
  fi
  echo
  echo "===== 本地指标抽样 ====="
  if command -v curl >/dev/null 2>&1; then
    curl -fsS http://127.0.0.1:9256/metrics | grep namedprocess_namegroup | head -20 || echo "无法访问本地 metrics 或暂未匹配到进程"
  else
    echo "系统未安装 curl，跳过本地指标检查"
  fi
  echo
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

manage_process_exporter_menu() {
  while true; do
    echo
    echo "=============================="
    echo " process-exporter 管理"
    echo "=============================="
    echo "1. 安装 process-exporter"
    echo "2. 卸载 process-exporter"
    echo "3. 配置进程名（默认 ad2nx）"
    echo "4. process-exporter 状态"
    echo "5. 手动设置 Prometheus 抓取目标"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) install_process_exporter ;;
      2) uninstall_process_exporter ;;
      3) configure_process_exporter_name ;;
      4) process_exporter_status ;;
      5) need_root; check_prometheus_installed || break; read -rp "请输入 process-exporter Prometheus 抓取目标 [默认 127.0.0.1:9256]: " pe_target; pe_target="${pe_target:-127.0.0.1:9256}"; set_process_exporter_prom_target "$pe_target"; "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"; reload_prometheus ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
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
    echo "4. 规范化并去重节点列表"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) list_node_targets ;;
      2) add_node_target ;;
      3) delete_node_target ;;
      4) normalize_node_targets_file; echo "已完成规范化和去重。"; list_node_targets ;;
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
    echo " Prometheus / Exporter 快捷管理脚本"
    echo "========================================"
    echo "1. node_exporter 管理"
    echo "2. process-exporter 管理"
    echo "3. 管理 node_exporter 监测节点（添加/删除/查看）"
    echo "4. 安装 Prometheus"
    echo "5. 卸载 Prometheus"
    echo "6. 查看 Prometheus 服务状态"
    echo "7. 重载 Prometheus 配置"
    echo "0. 退出"
    echo "========================================"
    read -rp "请选择: " choice
    case "${choice}" in
      1) manage_node_exporter_menu ;;
      2) manage_process_exporter_menu ;;
      3) manage_probe_targets_menu ;;
      4) install_prometheus ;;
      5) uninstall_prometheus ;;
      6) systemctl status prometheus --no-pager || true ;;
      7) reload_prometheus ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu
