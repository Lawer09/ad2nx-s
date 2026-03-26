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

DB_NAME="adnx_dns"
DB_USER_DEFAULT="adnx"

# GitHub Release 配置
GITHUB_OWNER="Lawer09"
GITHUB_REPO="adnx-dns"
GITHUB_TAG="1.0.0"
ASSET_NAME="adnx_dns_linux_amd64.tar.gz"

TMP_DIR="/tmp/${APP_NAME}_install"
PACKAGE_PATH_DEFAULT=""

print_line() {
  echo "=================================================="
}

msg() {
  echo "[INFO] $1"
}

warn() {
  echo "[WARN] $1"
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
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  echo ""
}

install_base_deps() {
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    err "未识别包管理器，请手动安装: curl tar gzip unzip ca-certificates mysql-client"
    exit 1
  fi

  msg "安装基础依赖中..."
  case "$pm" in
    apt)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y curl tar gzip unzip ca-certificates mysql-client nano
      ;;
    dnf)
      dnf install -y curl tar gzip unzip ca-certificates mysql nano
      ;;
    yum)
      yum install -y curl tar gzip unzip ca-certificates mysql nano
      ;;
  esac
}

install_mysql_packages() {
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    err "未识别包管理器，无法自动安装 MySQL"
    exit 1
  fi

  msg "安装 MySQL 服务端和客户端..."
  case "$pm" in
    apt)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y mysql-server mysql-client
      ;;
    dnf)
      dnf install -y mysql-server mysql
      ;;
    yum)
      yum install -y mysql-server mysql
      ;;
  esac
}

mysql_service_name() {
  if systemctl list-unit-files | grep -q "^mysql.service"; then
    echo "mysql"
    return
  fi
  if systemctl list-unit-files | grep -q "^mysqld.service"; then
    echo "mysqld"
    return
  fi
  echo ""
}

ensure_mysql_running() {
  local svc
  svc="$(mysql_service_name)"
  if [[ -z "$svc" ]]; then
    warn "未找到 mysql/mysqld 服务，请确认 MySQL 已正确安装"
    return
  fi
  systemctl enable "$svc" || true
  systemctl restart "$svc" || true
  sleep 2
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/logs"
  mkdir -p "$TMP_DIR"
}

download_release_package() {
  local asset_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${GITHUB_TAG}/${ASSET_NAME}"
  local download_path="${TMP_DIR}/${ASSET_NAME}"

  msg "下载 GitHub Release: $asset_url"
  curl -fL "$asset_url" -o "$download_path"
  echo "$download_path"
}

extract_package() {
  local pkg_path="$1"

  rm -rf "${TMP_DIR}/extract"
  mkdir -p "${TMP_DIR}/extract"
  cd "${TMP_DIR}/extract"

  if [[ "$pkg_path" =~ \.tar\.gz$ ]]; then
    tar -xzf "$pkg_path"
  elif [[ "$pkg_path" =~ \.zip$ ]]; then
    unzip -o "$pkg_path"
  else
    err "不支持的压缩格式: $pkg_path"
    exit 1
  fi

  local release_dir
  release_dir="$(find "${TMP_DIR}/extract" -maxdepth 1 -type d -name "${APP_NAME}_*" | head -n 1)"
  if [[ -z "${release_dir:-}" ]]; then
    err "未找到解压后的目录"
    exit 1
  fi

  echo "$release_dir"
}

copy_release_files() {
  local release_dir="$1"

  msg "复制发布文件到 $INSTALL_DIR ..."
  cp -f "${release_dir}/${BIN_NAME}" "$BIN_PATH"
  chmod +x "$BIN_PATH"

  [[ -f "${release_dir}/.env.example" ]] && cp -f "${release_dir}/.env.example" "$ENV_EXAMPLE"
  [[ -f "${release_dir}/schema.sql" ]] && cp -f "${release_dir}/schema.sql" "$SCHEMA_FILE"
  [[ -f "${release_dir}/README.md" ]] && cp -f "${release_dir}/README.md" "$INSTALL_DIR/README.md"
  [[ -f "${release_dir}/RELEASE.md" ]] && cp -f "${release_dir}/RELEASE.md" "$INSTALL_DIR/RELEASE.md"

  if [[ -d "${release_dir}/configs" ]]; then
    rm -rf "$INSTALL_DIR/configs"
    cp -rf "${release_dir}/configs" "$INSTALL_DIR/configs"
  fi
}

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ENV_EXAMPLE" ]]; then
      cp -f "$ENV_EXAMPLE" "$ENV_FILE"
    else
      touch "$ENV_FILE"
    fi
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"

  ensure_env_file

  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

sync_db_config_to_env() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local dbname="$5"

  set_env_value "MYSQL_HOST" "$host"
  set_env_value "MYSQL_PORT" "$port"
  set_env_value "MYSQL_USER" "$user"
  set_env_value "MYSQL_PASSWORD" "$password"
  set_env_value "MYSQL_DB" "$dbname"

  msg "数据库配置已同步到: $ENV_FILE"
}

write_service() {
  msg "写入 systemd 服务..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=adnx_dns service
After=network.target mysql.service mysqld.service

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

prompt_db_config() {
  read -rp "MySQL Host (默认 127.0.0.1): " MYSQL_HOST
  MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"

  read -rp "MySQL Port (默认 3306): " MYSQL_PORT
  MYSQL_PORT="${MYSQL_PORT:-3306}"

  read -rp "数据库用户名 (默认 ${DB_USER_DEFAULT}): " MYSQL_APP_USER
  MYSQL_APP_USER="${MYSQL_APP_USER:-$DB_USER_DEFAULT}"

  while true; do
    read -rsp "数据库密码: " MYSQL_APP_PASSWORD
    echo
    if [[ -z "$MYSQL_APP_PASSWORD" ]]; then
      warn "密码不能为空"
      continue
    fi

    read -rsp "再次输入数据库密码: " MYSQL_APP_PASSWORD2
    echo
    if [[ "$MYSQL_APP_PASSWORD" != "$MYSQL_APP_PASSWORD2" ]]; then
      warn "两次输入密码不一致，请重新输入"
      continue
    fi
    break
  done

  read -rp "MySQL root 用户名 (默认 root): " MYSQL_ROOT_USER
  MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"

  read -rsp "MySQL root 密码(如无密码可直接回车): " MYSQL_ROOT_PASSWORD
  echo
}

mysql_exec_root() {
  local sql="$1"

  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" "-p${MYSQL_ROOT_PASSWORD}" -e "$sql"
  else
    mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" -e "$sql"
  fi
}

create_db_and_user() {
  msg "创建数据库和业务用户..."
  mysql_exec_root "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_exec_root "CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';"
  mysql_exec_root "ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';"
  mysql_exec_root "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${MYSQL_APP_USER}'@'%';"
  mysql_exec_root "FLUSH PRIVILEGES;"
}

import_schema_with_app_user() {
  local schema_path="$1"
  mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_APP_USER}" "-p${MYSQL_APP_PASSWORD}" "${DB_NAME}" < "$schema_path"
}

choose_package_source() {
  echo "请选择 Linux 包来源："
  echo "1. 从 GitHub Release 下载"
  echo "2. 使用本地已有安装包"
  read -rp "请输入选项 (默认 1): " PKG_CHOICE
  PKG_CHOICE="${PKG_CHOICE:-1}"

  if [[ "$PKG_CHOICE" == "2" ]]; then
    read -rp "请输入本地安装包路径: " LOCAL_PACKAGE_PATH
    if [[ -z "${LOCAL_PACKAGE_PATH:-}" || ! -f "${LOCAL_PACKAGE_PATH}" ]]; then
      err "本地安装包不存在"
      exit 1
    fi
    echo "$LOCAL_PACKAGE_PATH"
  else
    download_release_package
  fi
}

install_app() {
  print_line
  echo "开始安装 $APP_NAME"
  print_line

  install_base_deps
  install_mysql_packages
  ensure_mysql_running
  ensure_dirs

  local pkg_path
  pkg_path="$(choose_package_source)"

  local release_dir
  release_dir="$(extract_package "$pkg_path")"

  copy_release_files "$release_dir"
  ensure_env_file

  prompt_db_config
  create_db_and_user

  if [[ ! -f "$SCHEMA_FILE" ]]; then
    err "未找到 schema.sql: $SCHEMA_FILE"
    exit 1
  fi

  msg "导入 schema.sql ..."
  import_schema_with_app_user "$SCHEMA_FILE"

  sync_db_config_to_env "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_APP_USER" "$MYSQL_APP_PASSWORD" "$DB_NAME"

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

init_db() {
  print_line
  echo "初始化数据库 $DB_NAME"
  print_line

  local schema_path="$SCHEMA_FILE"
  if [[ ! -f "$schema_path" ]]; then
    err "未找到 schema.sql: $schema_path"
    exit 1
  fi

  ensure_mysql_running
  prompt_db_config

  read -rp "如果数据库 ${DB_NAME} 已存在，是否删除并重建？(y/n): " REINIT
  REINIT="${REINIT:-n}"

  if [[ "$REINIT" == "y" || "$REINIT" == "Y" ]]; then
    msg "删除并重建数据库 ${DB_NAME} ..."
    mysql_exec_root "DROP DATABASE IF EXISTS ${DB_NAME};"
  fi

  create_db_and_user

  msg "导入 schema.sql ..."
  import_schema_with_app_user "$schema_path"

  sync_db_config_to_env "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_APP_USER" "$MYSQL_APP_PASSWORD" "$DB_NAME"

  print_line
  echo "数据库初始化完成"
  print_line
}

edit_config_file() {
  print_line
  echo "修改配置文件"
  print_line

  ensure_env_file

  if command -v nano >/dev/null 2>&1; then
    nano "$ENV_FILE"
  elif command -v vim >/dev/null 2>&1; then
    vim "$ENV_FILE"
  elif command -v vi >/dev/null 2>&1; then
    vi "$ENV_FILE"
  else
    warn "未找到 nano/vim/vi，请手动编辑: $ENV_FILE"
    cat "$ENV_FILE"
  fi

  read -rp "是否重启服务使配置生效？(y/n): " RESTART_APP
  RESTART_APP="${RESTART_APP:-y}"
  if [[ "$RESTART_APP" == "y" || "$RESTART_APP" == "Y" ]]; then
    systemctl restart "$SERVICE_NAME" || true
    systemctl status "$SERVICE_NAME" --no-pager || true
  fi
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
  echo "           adnx_dns 部署脚本"
  print_line
  echo "1. 安装"
  echo "2. 初始化数据库"
  echo "3. 修改配置文件"
  echo "4. 卸载"
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
        edit_config_file
        read -rp "按回车返回菜单..."
        ;;
      4)
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