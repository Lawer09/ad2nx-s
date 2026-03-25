#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-2.55.1}"
ARCH="${ARCH:-linux-amd64}"

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

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    apt update -y
    apt install -y jq
  fi
}

init_targets_file() {
  local file="$1"
  local job="$2"
  mkdir -p "${FILE_SD_DIR}"
  if [[ ! -f "${file}" ]]; then
    printf '[{"labels":{"job":"%s"},"targets":[]}]' "${job}" > "${file}"
  fi
}

normalize_targets_file() {
  local file="$1"
  local job="$2"
  mkdir -p "${FILE_SD_DIR}"

  if [[ ! -f "${file}" ]]; then
    init_targets_file "${file}" "${job}"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg job "${job}" '
    if type != "array" or length == 0 then
      [{"labels":{"job":$job},"targets":[]}]
    else
      [.[0] | {
        labels: (.labels // {job:$job}) + {job:$job},
        targets: ((.targets // []) | map(select(type=="string")) | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0)) | unique)
      }]
    end
  ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

list_targets() {
  local file="$1"
  local job="$2"
  local title="$3"

  normalize_targets_file "${file}" "${job}"

  local count
  count="$(jq '.[0].targets | length' "${file}")"

  echo
  echo "${title}"
  if [[ "${count}" -eq 0 ]]; then
    echo "  （空）"
    return
  fi

  jq -r '.[0].targets[]' "${file}" | nl -w2 -s'. '
}

add_target() {
  local file="$1"
  local job="$2"
  local prompt="$3"

  normalize_targets_file "${file}" "${job}"
  read -rp "${prompt}" target
  target="$(echo "${target}" | xargs)"

  if [[ -z "${target}" ]]; then
    echo "目标地址不能为空。"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg t "${target}" '
    .[0].targets |= ((. + [$t]) | unique)
  ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"

  echo "已添加目标: ${target}"
}

delete_target() {
  local file="$1"
  local job="$2"
  local title="$3"

  normalize_targets_file "${file}" "${job}"
  local count
  count="$(jq '.[0].targets | length' "${file}")"

  if [[ "${count}" -eq 0 ]]; then
    echo "当前没有可删除的目标。"
    return
  fi

  list_targets "${file}" "${job}" "${title}"
  read -rp "请输入要删除的序号: " idx

  if ! [[ "${idx}" =~ ^[0-9]+$ ]]; then
    echo "请输入有效数字。"
    return
  fi
  if (( idx < 1 || idx > count )); then
    echo "序号超出范围。"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "$((idx-1))" '
    .[0].targets |= [ to_entries[] | select(.key != $idx) | .value ]
  ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"

  echo "已删除序号 ${idx} 的目标。"
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
  ensure_jq

  mkdir -p "${INSTALL_DIR}" "${ETC_DIR}" "${DATA_DIR}" "${FILE_SD_DIR}"

  cd /tmp
  rm -rf "${PKG_NAME}" "${PKG_FILE}"
  curl -fL -o "${PKG_FILE}" "${DOWNLOAD_URL}"
  tar -xzf "${PKG_FILE}"

  install -m 0755 "${PKG_NAME}/prometheus" "${PROM_BIN}"
  install -m 0755 "${PKG_NAME}/promtool" "${PROMTOOL_BIN}"

  write_prometheus_config

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PROM_BIN} \
  --config.file=${ETC_DIR}/prometheus.yml \
  --storage.tsdb.path=${DATA_DIR} \
  --web.listen-address=:9090 \
  --storage.tsdb.retention.time=15d
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now prometheus
  echo "Prometheus 安装完成。"
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
  need_root
  if [[ -x "${PROMTOOL_BIN}" ]]; then
    "${PROMTOOL_BIN}" check config "${ETC_DIR}/prometheus.yml"
  fi
  systemctl reload prometheus 2>/dev/null || systemctl restart prometheus
  echo "Prometheus 配置已重载。"
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