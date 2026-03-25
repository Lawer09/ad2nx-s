#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/Lawer09/ad2nx-s/master"
WORK_DIR="/opt/monitoring-scripts"

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    red "请使用 root 或 sudo 运行。"
    exit 1
  fi
}

ensure_deps() {
  if ! command -v wget >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      apt update -y
      apt install -y wget
    else
      red "未检测到 wget，且当前系统不支持 apt 自动安装，请手动安装 wget。"
      exit 1
    fi
  fi
}

prepare_env() {
  mkdir -p "${WORK_DIR}"
}

download_and_run() {
  local script_name="$1"
  local script_path="${WORK_DIR}/${script_name}"

  ensure_deps
  prepare_env

  green "正在同步脚本: ${script_name}"
  wget -N -P "${WORK_DIR}" "${BASE_URL}/${script_name}"

  if [[ ! -f "${script_path}" ]]; then
    red "脚本下载失败: ${script_name}"
    exit 1
  fi

  chmod +x "${script_path}"
  bash "${script_path}"
}

show_menu() {
  clear
  echo "========================================"
  echo " Monitoring 快捷管理脚本"
  echo "========================================"
  echo "1. Prometheus 管理"
  echo "2. node_exporter 管理"
  echo "3. process_exporter 管理"
  echo "4. node_agent 管理"
  echo "0. 退出"
  echo "========================================"
}

main() {
  need_root

  while true; do
    show_menu
    read -rp "请选择: " choice
    case "${choice}" in
      1)
        download_and_run "prometheus.sh"
        ;;
      2)
        download_and_run "node_exporter.sh"
        ;;
      3)
        download_and_run "process_exporter.sh"
        ;;
      4)
        download_and_run "node-agent.sh"
        ;;
      0)
        echo "退出。"
        exit 0
        ;;
      *)
        yellow "无效选项，请重新输入。"
        read -rp "按回车继续..." _
        ;;
    esac
  done
}

main