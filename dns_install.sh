#!/usr/bin/env bash
set -euo pipefail

APP_NAME="adnx_dns"
SERVICE_NAME="adnx_dns"
INSTALL_DIR="/opt/adnx_dns"
BIN_NAME="adnx_dns"
BIN_PATH="$INSTALL_DIR/$BIN_NAME"
ENV_EXAMPLE="$INSTALL_DIR/.env.example"
ENV_FILE="$INSTALL_DIR/.env"
SCHEMA_FILE="$INSTALL_DIR/schema.sql"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 固定 GitHub Release 信息
GITHUB_OWNER="Lawer09"
GITHUB_REPO="adnx-dns"
GITHUB_TAG="v1.0.0"
ASSET_NAME="adnx_dns_v1.0.0_linux_amd64.tar.gz"
TMP_DIR="/tmp/${APP_NAME}_install"

print_line() {
  echo "=================================================="
}

msg() {
  echo "[INFO] $1"
}

err() {
  echo "[ERROR] $1" >&2
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行此脚本"
    exit 1
  fi
}

detect_pm() {
  if command -v apt >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  echo ""
}

install_deps() {
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    err "未识别包管理器，请手动安装: curl tar unzip gzip jq mysql-client"
    exit 1
  fi

  msg "安装依赖中..."
  case "$pm" in
    apt)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y curl jq tar gzip unzip ca-certificates mysql-client
      ;;
    yum)
      yum install -y curl jq tar gzip unzip ca-certificates mysql
      ;;
    dnf)
      dnf install -y curl jq tar gzip unzip ca-certificates mysql
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/logs"
}

download_from_github_release() {
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"

  local asset_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${GITHUB_TAG}/${ASSET_NAME}"
  local download_path="${TMP_DIR}/${ASSET_NAME}"

  msg "下载 GitHub Release: $asset_url"
  curl -fL "$asset_url" -o "$download_path"

  msg "解压安装包..."
  cd "$TMP_DIR"

  if [[ "$ASSET_NAME" =~ \.tar\.gz$ ]]; then
    tar -xzf "$download_path"
  elif [[ "$ASSET_NAME" =~ \.zip$ ]]; then
    unzip -o "$download_path"
  else
    err "不支持的压缩格式: $ASSET_NAME"
    exit 1
  fi

  local release_dir
  release_dir="$(find "$TMP_DIR" -maxdepth 1 -type d -name "${APP_NAME}_*" | head -n 1)"
  if [[ -z "${release_dir:-}" ]]; then
    err "未找到解压后的目录"
    exit 1
  fi

  msg "复制文件到安装目录..."
  cp -rf "${release_dir}/"* "$INSTALL_DIR"/
}

copy_local_files() {
  msg "使用当前目录本地文件安装..."
  cp -f "./$BIN_NAME" "$BIN_PATH"
  chmod +x "$BIN_PATH"

  [[ -f "./.env.example" ]] && cp -f "./.env.example" "$ENV_EXAMPLE"
  [[ -f "./schema.sql" ]] && cp -f "./schema.sql" "$SCHEMA_FILE"
  [[ -f "./README.md" ]] && cp -f "./README.md" "$INSTALL_DIR/README.md"
  [[ -f "./RELEASE.md" ]] && cp -f "./RELEASE.md" "$INSTALL_DIR/RELEASE.md"

  if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
    cp -f "$ENV_EXAMPLE" "$ENV_FILE"
    msg "已生成默认配置文件: $ENV_FILE"
  fi
}

ensure_install_files() {
  if [[ -f "$BIN_PATH" ]]; then
    chmod +x "$BIN_PATH"
  fi

  if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
    cp -f "$ENV_EXAMPLE" "$ENV_FILE"
  fi

  if [[ ! -f "$BIN_PATH" ]]; then
    err "安装目录中缺少二进制文件: $BIN_PATH"
    exit 1
  fi

  chmod +x "$BIN_PATH"
}

write_service() {
  msg "写入 systemd 服务..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=adnx_dns service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN_PATH
Restart=always
RestartSec=3
StandardOutput=append:$INSTALL_DIR/logs/stdout.log
StandardError=append:$INSTALL_DIR/logs/stderr.log
EnvironmentFile=-$ENV_FILE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

install_app() {
  print_line
  echo "开始安装 $APP_NAME"
  print_line

  install_deps
  ensure_dirs

  if [[ -f "./$BIN_NAME" ]]; then
    copy_local_files
  else
    msg "当前目录未发现本地二进制，改为从 GitHub Release 拉取 ${GITHUB_TAG} ..."
    download_from_github_release
  fi

  ensure_install_files
  write_service

  msg "启动服务..."
  systemctl restart "$SERVICE_NAME" || true
  sleep 1
  systemctl status "$SERVICE_NAME" --no-pager || true

  print_line
  echo "安装完成"
  echo "安装目录: $INSTALL_DIR"
  echo "配置文件: $ENV_FILE"
  echo "服务名称: $SERVICE_NAME"
  print_line
}

input_db_params() {
  read -rp "MySQL Host (默认 127.0.0.1): " MYSQL_HOST
  MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"

  read -rp "MySQL Port (默认 3306): " MYSQL_PORT
  MYSQL_PORT="${MYSQL_PORT:-3306}"

  read -rp "MySQL User (默认 root): " MYSQL_USER
  MYSQL_USER="${MYSQL_USER:-root}"

  read -rsp "MySQL Password: " MYSQL_PASSWORD
  echo

  MYSQL_CMD=(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" "-p${MYSQL_PASSWORD}")
}

init_db() {
  print_line
  echo "初始化数据库 adnx_dns"
  print_line

  local schema_path="./schema.sql"
  if [[ -f "$SCHEMA_FILE" ]]; then
    schema_path="$SCHEMA_FILE"
  fi

  if [[ ! -f "$schema_path" ]]; then
    err "未找到 schema.sql"
    exit 1
  fi

  input_db_params

  read -rp "如果数据库 adnx_dns 已存在，是否删除并重建？(y/n): " REINIT
  REINIT="${REINIT:-n}"

  if [[ "$REINIT" == "y" || "$REINIT" == "Y" ]]; then
    msg "删除并重建数据库 adnx_dns ..."
    "${MYSQL_CMD[@]}" -e "DROP DATABASE IF EXISTS adnx_dns; CREATE DATABASE adnx_dns CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  else
    msg "确保数据库 adnx_dns 存在..."
    "${MYSQL_CMD[@]}" -e "CREATE DATABASE IF NOT EXISTS adnx_dns CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  fi

  msg "导入 schema.sql ..."
  "${MYSQL_CMD[@]}" adnx_dns < "$schema_path"

  print_line
  echo "数据库初始化完成"
  print_line
}

uninstall_app() {
  print_line
  echo "卸载 $APP_NAME"
  print_line

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true
  fi

  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true

  read -rp "是否删除安装目录 $INSTALL_DIR ? (y/n): " REMOVE_DIR
  REMOVE_DIR="${REMOVE_DIR:-n}"
  if [[ "$REMOVE_DIR" == "y" || "$REMOVE_DIR" == "Y" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "已删除安装目录"
  else
    echo "保留安装目录: $INSTALL_DIR"
  fi

  print_line
  echo "卸载完成"
  print_line
}

show_menu() {
  clear
  print_line
  echo "           adnx_dns 安装脚本"
  print_line
  echo "1. 安装"
  echo "2. 初始化数据库"
  echo "3. 卸载"
  echo "0. 退出"
  print_line
}

main() {
  check_root

  while true; do
    show_menu
    read -rp "请输入选项: " choice
    case "$choice" in
      1)
        install_app
        read -rp "按回车返回菜单..."
        ;;
      2)
        init_db
        read -rp "按回车返回菜单..."
        ;;
      3)
        uninstall_app
        read -rp "按回车返回菜单..."
        ;;
      0)
        exit 0
        ;;
      *)
        echo "无效选项"
        sleep 1
        ;;
    esac
  done
}

main "$@"