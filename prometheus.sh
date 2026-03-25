#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-2.55.1}"
ARCH="${ARCH:-linux-amd64}"

PROM_BIN_LINK="/usr/local/bin/prometheus"
PROMTOOL_LINK="/usr/local/bin/promtool"
PROM_SERVICE_FILE="/etc/systemd/system/prometheus.service"

INSTALL_DIR="/opt/prometheus"
ETC_DIR="/etc/prometheus"
DATA_DIR="/var/lib/prometheus"
SERVICE_FILE="/etc/systemd/system/prometheus.service"
PROM_BIN="/usr/local/bin/prometheus"
PROMTOOL_BIN="/usr/local/bin/promtool"

FILE_SD_DIR="${ETC_DIR}/file_sd"
NODE_TARGETS_FILE="${FILE_SD_DIR}/node_exporter.json"
PROCESS_TARGETS_FILE="${FILE_SD_DIR}/process_exporter.json"
NODE_AGENT_TARGETS_FILE="${FILE_SD_DIR}/node_agent.json"

PKG_NAME="prometheus-${PROM_VERSION}.${ARCH}"
PKG_FILE="${PKG_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PKG_FILE}"

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

init_targets_file() {
  local file_path="$1"
  local job_name="$2"
  mkdir -p "${FILE_SD_DIR}"
  if [[ ! -f "$file_path" ]]; then
    cat > "$file_path" <<JSON
[
  {
    "labels": {
      "job": "$job_name"
    },
    "targets": []
  }
]
JSON
  fi
}

normalize_targets_file() {
  check_python3
  local file_path="$1"
  local job_name="$2"
  init_targets_file "$file_path" "$job_name"
  python3 - <<PY
import json
from pathlib import Path
f = Path(${file_path@Q})
job_name = ${job_name@Q}
data = json.loads(f.read_text(encoding='utf-8'))
if not data or not isinstance(data, list):
    data = [{"labels": {"job": job_name}, "targets": []}]
entry = data[0]
entry.setdefault('labels', {}).setdefault('job', job_name)
targets = entry.setdefault('targets', [])
seen = set()
normalized = []
for t in targets:
    nt = str(t).strip().replace('：', ':').replace(' ', '')
    if nt and nt not in seen:
        seen.add(nt)
        normalized.append(nt)
normalized.sort()
entry['targets'] = normalized
f.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
PY
}

list_targets() {
  check_python3
  local file_path="$1"
  local job_name="$2"
  local title="$3"
  normalize_targets_file "$file_path" "$job_name"
  echo
  echo "$title"
  python3 - <<PY
import json
f = ${file_path@Q}
with open(f, 'r', encoding='utf-8') as fp:
    data = json.load(fp)
targets = []
for item in data:
    targets.extend(item.get('targets', []))
if not targets:
    print('  (空)')
else:
    for i, t in enumerate(targets, 1):
        print(f'  {i}. {t}')
PY
  echo
}

add_target() {
  need_root
  check_python3
  check_prometheus_installed || return 1
  local file_path="$1"
  local job_name="$2"
  local prompt="$3"
  normalize_targets_file "$file_path" "$job_name"
  read -rp "$prompt" target
  target="$(normalize_target "$target")"
  if [[ -z "$target" ]]; then
    echo "目标不能为空。"
    return 1
  fi
  python3 - <<PY
import json, sys
f = ${file_path@Q}
job_name = ${job_name@Q}
target = ${target@Q}
with open(f, 'r', encoding='utf-8') as fp:
    data = json.load(fp)
if not data:
    data = [{"labels": {"job": job_name}, "targets": []}]
entry = data[0]
entry.setdefault('labels', {}).setdefault('job', job_name)
targets = entry.setdefault('targets', [])
normalized = []
seen = set()
for t in targets:
    nt = str(t).strip().replace('：', ':').replace(' ', '')
    if nt and nt not in seen:
        seen.add(nt)
        normalized.append(nt)
if target in seen:
    entry['targets'] = sorted(normalized)
    with open(f, 'w', encoding='utf-8') as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
    print('节点已存在，无需重复添加。')
    sys.exit(0)
normalized.append(target)
entry['targets'] = sorted(normalized)
with open(f, 'w', encoding='utf-8') as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)
print(f'已添加节点: {target}')
PY
  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
  reload_prometheus
}

delete_target() {
  need_root
  check_python3
  check_prometheus_installed || return 1
  local file_path="$1"
  local job_name="$2"
  local title="$3"
  normalize_targets_file "$file_path" "$job_name"
  list_targets "$file_path" "$job_name" "$title"
  read -rp "请输入要删除的序号或目标地址（例如 2 或 10.0.0.11:9100）: " target_input
  target_input="$(normalize_target "$target_input")"
  if [[ -z "$target_input" ]]; then
    echo "输入不能为空。"
    return 1
  fi
  python3 - <<PY
import json, sys
f = ${file_path@Q}
user_input = ${target_input@Q}
with open(f, 'r', encoding='utf-8') as fp:
    data = json.load(fp)
if not data:
    print('目标文件为空。')
    sys.exit(1)
entry = data[0]
targets = [str(t).strip().replace('：', ':').replace(' ', '') for t in entry.setdefault('targets', [])]
targets = sorted(dict.fromkeys([t for t in targets if t]))
if not targets:
    print('当前没有可删除的节点。')
    sys.exit(1)
if user_input.isdigit():
    idx = int(user_input)
    if idx < 1 or idx > len(targets):
        print(f'序号超出范围，当前有效范围: 1-{len(targets)}')
        sys.exit(1)
    deleted = targets.pop(idx - 1)
else:
    if user_input not in targets:
        print('未找到该节点。你可以输入序号，或输入完整地址。')
        sys.exit(1)
    targets.remove(user_input)
    deleted = user_input
entry['targets'] = targets
with open(f, 'w', encoding='utf-8') as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)
print(f'已删除节点: {deleted}')
PY
  "${PROMTOOL_LINK}" check config "${ETC_DIR}/prometheus.yml"
  reload_prometheus
}

list_node_targets() { list_targets "${NODE_TARGETS_FILE}" "node_exporter" "当前 node_exporter 监测节点："; }
add_node_target() { add_target "${NODE_TARGETS_FILE}" "node_exporter" "请输入 node_exporter 目标地址（例如 10.0.0.11:9100）: "; }
delete_node_target() { delete_target "${NODE_TARGETS_FILE}" "node_exporter" "当前 node_exporter 监测节点："; }

list_process_targets() { list_targets "${PROCESS_TARGETS_FILE}" "process_exporter" "当前 process_exporter 监测节点："; }
add_process_target() { add_target "${PROCESS_TARGETS_FILE}" "process_exporter" "请输入 process_exporter 目标地址（例如 10.0.0.11:9256）: "; }
delete_process_target() { delete_target "${PROCESS_TARGETS_FILE}" "process_exporter" "当前 process_exporter 监测节点："; }

list_node_agent_targets() { list_targets "${NODE_AGENT_TARGETS_FILE}" "node_agent" "当前 node_agent 监测节点："; }
add_node_agent_target() { add_target "${NODE_AGENT_TARGETS_FILE}" "node_agent" "请输入 node_agent 目标地址（例如 10.0.0.11:2112）: "; }
delete_node_agent_target() { delete_target "${NODE_AGENT_TARGETS_FILE}" "node_agent" "当前 node_agent 监测节点："; }

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

  - job_name: "process_exporter"
    file_sd_configs:
      - files:
          - "${PROCESS_TARGETS_FILE}"
        refresh_interval: 30s

  - job_name: "node_agent"
    file_sd_configs:
      - files:
          - "${NODE_AGENT_TARGETS_FILE}"
        refresh_interval: 30s
EOF

  init_targets_file "${NODE_TARGETS_FILE}" "node_exporter"
  init_targets_file "${PROCESS_TARGETS_FILE}" "process_exporter"
  init_targets_file "${NODE_AGENT_TARGETS_FILE}" "node_agent"

  normalize_targets_file "${NODE_TARGETS_FILE}" "node_exporter"
  normalize_targets_file "${PROCESS_TARGETS_FILE}" "process_exporter"
  normalize_targets_file "${NODE_AGENT_TARGETS_FILE}" "node_agent"
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

uninstall_prometheus() {
  need_root
  read -rp "是否同时删除数据目录 ${DATA_DIR} ? [y/N]: " remove_data

  systemctl stop prometheus >/dev/null 2>&1 || true
  systemctl disable prometheus >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  rm -f "${PROM_BIN}" "${PROMTOOL_BIN}"
  rm -rf "${ETC_DIR}"

  if [[ "${remove_data}" =~ ^[Yy]$ ]]; then
    rm -rf "${DATA_DIR}"
    echo "已删除数据目录: ${DATA_DIR}"
  else
    echo "保留数据目录: ${DATA_DIR}"
  fi
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

prometheus_status() {
  echo
  echo "===== Prometheus 服务状态 ====="
  if systemctl list-unit-files | grep -q '^prometheus.service'; then
    systemctl status prometheus --no-pager || true
  else
    echo "Prometheus 未安装。"
  fi

  echo
  echo "===== 本地配置校验 ====="
  if [[ -x "${PROMTOOL_BIN}" && -f "${ETC_DIR}/prometheus.yml" ]]; then
    "${PROMTOOL_BIN}" check config "${ETC_DIR}/prometheus.yml" || true
  else
    echo "未找到 promtool 或配置文件"
  fi

  echo
  echo "===== 监听端口 ====="
  ss -lntp | grep ':9090' || echo "未检测到 9090 监听"
}

manage_prometheus_node_targets_menu() {
  while true; do
    echo
    echo "=============================="
    echo " node_exporter 管理"
    echo "=============================="
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看节点"
    echo "4. 规范化并去重节点列表"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) add_node_target ;;
      2) delete_node_target ;;
      3) list_node_targets ;;
      4) normalize_targets_file "${NODE_TARGETS_FILE}" "node_exporter"; echo "已完成规范化和去重。"; list_node_targets ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

manage_prometheus_process_targets_menu() {
  while true; do
    echo
    echo "=============================="
    echo " process_exporter 管理"
    echo "=============================="
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看节点"
    echo "4. 规范化并去重节点列表"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) add_process_target ;;
      2) delete_process_target ;;
      3) list_process_targets ;;
      4) normalize_targets_file "${PROCESS_TARGETS_FILE}" "process_exporter"; echo "已完成规范化和去重。"; list_process_targets ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

manage_prometheus_node_agent_targets_menu() {
  while true; do
    echo
    echo "=============================="
    echo " node_agent 管理"
    echo "=============================="
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看节点"
    echo "4. 规范化并去重节点列表"
    echo "0. 返回上级菜单"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) add_node_agent_target ;;
      2) delete_node_agent_target ;;
      3) list_node_agent_targets ;;
      4) normalize_targets_file "${NODE_AGENT_TARGETS_FILE}" "node_agent"; echo "已完成规范化和去重。"; list_node_agent_targets ;;
      0) break ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu() {
  while true; do
    echo
    echo "=============================="
    echo " Prometheus 管理"
    echo "=============================="
    echo "1. 安装 Prometheus"
    echo "2. 卸载 Prometheus"
    echo "3. Prometheus 状态"
    echo "4. node_exporter 管理"
    echo "5. process_exporter 管理"
    echo "6. node_agent 管理"
    echo "7. 重载 Prometheus 配置"
    echo "0. 退出"
    echo "=============================="
    read -rp "请选择: " sub_choice
    case "${sub_choice}" in
      1) install_prometheus ;;
      2) uninstall_prometheus ;;
      3) prometheus_status ;;
      4) manage_prometheus_node_targets_menu ;;
      5) manage_prometheus_process_targets_menu ;;
      6) manage_prometheus_node_agent_targets_menu ;;
      7) reload_prometheus ;;
      0) exit 0 ;;
      *) echo "无效选项，请重新输入。" ;;
    esac
  done
}

main_menu