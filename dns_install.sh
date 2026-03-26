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

msg() {
  echo "[INFO] $1" >&2
}

warn() {
  echo "[WARN] $1" >&2
}

err() {
  echo "[ERROR] $1" >&2
}

line() {
  echo "=================================================="
}

pause_wait() {
  read -rp "按回车继续..."
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

pkg_installed_apt() {
  dpkg -s "$1" >/dev/null 2>&1
}

pkg_installed_rpm() {
  rpm -q "$1" >/dev/null 2>&1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

mysql_service_name() {
  if systemctl status mysql >/dev/null 2>&1; then
    echo "mysql"
    return
  fi

  if systemctl status mysqld >/dev/null 2>&1; then
    echo "mysqld"
    return
  fi

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "mysql.service"; then
    echo "mysql"
    return
  fi

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "mysqld.service"; then
    echo "mysqld"
    return
  fi

  echo ""
}

mysql_installed() {
  if command_exists mysql; then
    return 0
  fi

  local pm
  pm="$(detect_pm)"
  case "$pm" in
    apt)
      pkg_installed_apt mysql-server || pkg_installed_apt mariadb-server
      ;;
    yum|dnf)
      pkg_installed_rpm mysql-server || pkg_installed_rpm mariadb-server
      ;;
    *)
      return 1
      ;;
  esac
}

mysql_running() {
  local svc
  svc="$(mysql_service_name)"
  if [[ -n "$svc" ]] && systemctl is-active "$svc" >/dev/null 2>&1; then
    return 0
  fi

  if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

service_installed() {
  [[ -f "$SERVICE_FILE" ]]
}

service_running() {
  systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/logs"
  mkdir -p "$TMP_DIR"
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
  set_env_value "MYSQL_DSN" "${user}:${password}@tcp(${host}:${port})/${dbname}?parseTime=true&charset=utf8mb4&loc=Local"

  msg "数据库配置已同步到: $ENV_FILE"
}

install_base_deps() {
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    err "未识别包管理器，请手动安装基础依赖"
    exit 1
  fi

  msg "安装基础依赖..."
  case "$pm" in
    apt)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y curl tar gzip unzip ca-certificates nano
      ;;
    dnf)
      dnf install -y curl tar gzip unzip ca-certificates nano
      ;;
    yum)
      yum install -y curl tar gzip unzip ca-certificates nano
      ;;
  esac
}

install_mysql_if_needed() {
  if mysql_installed; then
    msg "检测到 MySQL/MariaDB 已安装，跳过安装"
    return
  fi

  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    err "未识别包管理器，无法自动安装 MySQL"
    exit 1
  fi

  msg "未检测到 MySQL，开始安装..."
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

ensure_mysql_running() {
  if mysql_running; then
    msg "检测到 MySQL 已运行"
    return
  fi

  local svc
  svc="$(mysql_service_name)"
  if [[ -n "$svc" ]]; then
    msg "启动数据库服务: $svc"
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" || true
    sleep 2
  fi

  if mysql_running; then
    msg "MySQL 服务已启动"
  else
    warn "MySQL 未启动，请检查数据库服务状态"
  fi
}

download_release_package() {
  local asset_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${GITHUB_TAG}/${ASSET_NAME}"
  local download_path="${TMP_DIR}/${ASSET_NAME}"

  msg "下载 GitHub Release: $asset_url"
  curl -fL "$asset_url" -o "$download_path"

  if [[ ! -f "$download_path" ]]; then
    err "下载失败: $download_path 不存在"
    exit 1
  fi

  printf '%s\n' "$download_path"
}

choose_package_source() {
  echo "请选择 Linux 包来源：" >&2
  echo "1. 从 GitHub Release 下载" >&2
  echo "2. 使用本地已有安装包" >&2
  read -rp "请输入选项 (默认 1): " PKG_CHOICE
  PKG_CHOICE="${PKG_CHOICE:-1}"

  if [[ "$PKG_CHOICE" == "2" ]]; then
    read -rp "请输入本地安装包路径: " LOCAL_PACKAGE_PATH
    if [[ -z "${LOCAL_PACKAGE_PATH:-}" || ! -f "${LOCAL_PACKAGE_PATH}" ]]; then
      err "本地安装包不存在"
      exit 1
    fi
    printf '%s\n' "$LOCAL_PACKAGE_PATH"
  else
    download_release_package
  fi
}

extract_package() {
  local pkg_path="$1"

  if [[ -z "${pkg_path:-}" ]]; then
    err "安装包路径为空"
    exit 1
  fi

  if [[ ! -f "$pkg_path" ]]; then
    err "安装包不存在: $pkg_path"
    exit 1
  fi

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
  release_dir="$(find "${TMP_DIR}/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "${release_dir:-}" ]]; then
    err "未找到解压后的目录"
    exit 1
  fi

  printf '%s\n' "$release_dir"
}

copy_release_files() {
  local release_dir="$1"

  if [[ ! -f "${release_dir}/${BIN_NAME}" ]]; then
    err "安装包中缺少二进制文件: ${BIN_NAME}"
    exit 1
  fi

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

mysql_root_access_mode() {
  if mysql --protocol=socket -u"${MYSQL_ROOT_USER}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "socket"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    if sudo mysql -u"${MYSQL_ROOT_USER}" -e "SELECT 1;" >/dev/null 2>&1; then
      echo "sudo"
      return
    fi
  fi

  if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "nopass"
    return
  fi

  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" "-p${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
      echo "password"
      return
    fi
  fi

  echo "none"
}

mysql_exec_root() {
  local sql="$1"
  local mode
  mode="$(mysql_root_access_mode)"

  case "$mode" in
    socket)
      mysql --protocol=socket -u"${MYSQL_ROOT_USER}" -e "$sql"
      ;;
    sudo)
      sudo mysql -u"${MYSQL_ROOT_USER}" -e "$sql"
      ;;
    nopass)
      mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" -e "$sql"
      ;;
    password)
      mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_ROOT_USER}" "-p${MYSQL_ROOT_PASSWORD}" -e "$sql"
      ;;
    *)
      err "无法以 root 身份连接 MySQL。"
      warn "Ubuntu/Debian 常见原因是 root 使用 auth_socket/unix_socket 登录。"
      echo
      echo "建议先手动测试：" >&2
      echo "  sudo mysql" >&2
      echo
      echo "如果可以进入，重新运行本脚本即可。" >&2
      echo "如果仍然不行，可使用菜单 [7] 卸载 MySQL 并重新安装。" >&2
      exit 1
      ;;
  esac
}

create_db_and_user() {
  msg "创建数据库和业务用户..."
  mysql_exec_root "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_exec_root "CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';"
  mysql_exec_root "ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';"
  mysql_exec_root "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${MYSQL_APP_USER}'@'%';"
  mysql_exec_root "FLUSH PRIVILEGES;"
}

import_schema_with_app_user() {
  local schema_path="$1"
  mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_APP_USER}" "-p${MYSQL_APP_PASSWORD}" "${DB_NAME}" < "$schema_path"
}

show_environment_status() {
  line
  echo "环境检查结果"
  line

  echo "安装目录: $INSTALL_DIR"
  [[ -d "$INSTALL_DIR" ]] && echo "  状态: 已存在" || echo "  状态: 不存在"

  echo "二进制文件: $BIN_PATH"
  [[ -f "$BIN_PATH" ]] && echo "  状态: 已存在" || echo "  状态: 不存在"

  echo "配置文件: $ENV_FILE"
  [[ -f "$ENV_FILE" ]] && echo "  状态: 已存在" || echo "  状态: 不存在"

  echo "Schema 文件: $SCHEMA_FILE"
  [[ -f "$SCHEMA_FILE" ]] && echo "  状态: 已存在" || echo "  状态: 不存在"

  echo "MySQL:"
  if mysql_installed; then
    echo "  状态: 已安装"
  else
    echo "  状态: 未安装"
  fi

  echo "MySQL 运行状态:"
  if mysql_running; then
    echo "  状态: 运行中"
  else
    echo "  状态: 未运行"
  fi

  echo "服务文件: $SERVICE_FILE"
  if service_installed; then
    echo "  状态: 已存在"
  else
    echo "  状态: 不存在"
  fi

  echo "应用服务运行状态:"
  if service_running; then
    echo "  状态: 运行中"
  else
    echo "  状态: 未运行"
  fi

  line
}

install_or_update_app() {
  line
  echo "安装 / 更新 $APP_NAME"
  line

  install_base_deps
  install_mysql_if_needed
  ensure_mysql_running
  ensure_dirs

  local pkg_path
  pkg_path="$(choose_package_source)"

  local release_dir
  release_dir="$(extract_package "$pkg_path")"

  copy_release_files "$release_dir"
  ensure_env_file
  write_service

  echo "是否现在初始化数据库并写入 .env ?"
  echo "1. 是"
  echo "2. 否"
  read -rp "请输入选项 (默认 1): " INIT_NOW
  INIT_NOW="${INIT_NOW:-1}"

  if [[ "$INIT_NOW" == "1" ]]; then
    prompt_db_config
    create_db_and_user

    if [[ ! -f "$SCHEMA_FILE" ]]; then
      err "未找到 schema.sql: $SCHEMA_FILE"
      exit 1
    fi

    msg "导入 schema.sql ..."
    import_schema_with_app_user "$SCHEMA_FILE"
    sync_db_config_to_env "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_APP_USER" "$MYSQL_APP_PASSWORD" "$DB_NAME"
  else
    warn "已跳过数据库初始化，请稍后使用菜单 [3] 初始化数据库"
  fi

  echo "是否启动/重启服务？"
  echo "1. 是"
  echo "2. 否"
  read -rp "请输入选项 (默认 1): " START_NOW
  START_NOW="${START_NOW:-1}"

  if [[ "$START_NOW" == "1" ]]; then
    systemctl restart "$SERVICE_NAME" || true
    sleep 1
    systemctl status "$SERVICE_NAME" --no-pager || true
  fi

  line
  echo "安装 / 更新完成"
  echo "安装目录: $INSTALL_DIR"
  echo "配置文件: $ENV_FILE"
  line
}

init_db() {
  line
  echo "初始化数据库 $DB_NAME"
  line

  install_mysql_if_needed
  ensure_mysql_running

  local schema_path="$SCHEMA_FILE"
  if [[ ! -f "$schema_path" ]]; then
    err "未找到 schema.sql: $schema_path"
    exit 1
  fi

  prompt_db_config

  read -rp "如果数据库 ${DB_NAME} 已存在，是否删除并重建？(y/n): " REINIT
  REINIT="${REINIT:-n}"

  if [[ "$REINIT" == "y" || "$REINIT" == "Y" ]]; then
    msg "删除并重建数据库 ${DB_NAME} ..."
    mysql_exec_root "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
  fi

  create_db_and_user

  msg "导入 schema.sql ..."
  import_schema_with_app_user "$schema_path"

  sync_db_config_to_env "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_APP_USER" "$MYSQL_APP_PASSWORD" "$DB_NAME"

  line
  echo "数据库初始化完成"
  line
}

edit_config_file() {
  line
  echo "修改配置文件"
  line

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

service_manage() {
  while true; do
    line
    echo "服务管理"
    line
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看状态"
    echo "0. 返回"
    line
    read -rp "请输入选项: " svc_choice

    case "$svc_choice" in
      1)
        systemctl start "$SERVICE_NAME" || true
        systemctl status "$SERVICE_NAME" --no-pager || true
        pause_wait
        ;;
      2)
        systemctl stop "$SERVICE_NAME" || true
        systemctl status "$SERVICE_NAME" --no-pager || true
        pause_wait
        ;;
      3)
        systemctl restart "$SERVICE_NAME" || true
        systemctl status "$SERVICE_NAME" --no-pager || true
        pause_wait
        ;;
      4)
        systemctl status "$SERVICE_NAME" --no-pager || true
        pause_wait
        ;;
      0)
        break
        ;;
      *)
        echo "无效选项"
        ;;
    esac
  done
}

uninstall_app() {
  line
  echo "卸载应用 $APP_NAME"
  line

  if service_installed; then
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

  read -rp "是否删除临时目录 $TMP_DIR ? (y/n): " REMOVE_TMP
  REMOVE_TMP="${REMOVE_TMP:-y}"
  if [[ "$REMOVE_TMP" == "y" || "$REMOVE_TMP" == "Y" ]]; then
    rm -rf "$TMP_DIR"
  fi

  line
  echo "应用卸载完成"
  line
}

remove_mysql_completely() {
  local pm
  pm="$(detect_pm)"

  warn "即将卸载 MySQL/MariaDB，可能会删除现有数据库数据。"
  read -rp "确认继续？(y/n): " CONFIRM_REMOVE
  CONFIRM_REMOVE="${CONFIRM_REMOVE:-n}"

  if [[ "$CONFIRM_REMOVE" != "y" && "$CONFIRM_REMOVE" != "Y" ]]; then
    msg "已取消"
    return
  fi

  case "$pm" in
    apt)
      systemctl stop mysql >/dev/null 2>&1 || true
      systemctl stop mysqld >/dev/null 2>&1 || true
      apt purge -y mysql-server mysql-client mysql-common mariadb-server mariadb-client || true
      apt autoremove -y || true
      rm -rf /etc/mysql /var/lib/mysql /var/log/mysql
      ;;
    yum)
      systemctl stop mysqld >/dev/null 2>&1 || true
      yum remove -y mysql-server mysql mysql-libs mariadb-server mariadb || true
      rm -rf /etc/my.cnf /etc/my.cnf.d /var/lib/mysql /var/log/mysqld.log
      ;;
    dnf)
      systemctl stop mysqld >/dev/null 2>&1 || true
      dnf remove -y mysql-server mysql mysql-libs mariadb-server mariadb || true
      rm -rf /etc/my.cnf /etc/my.cnf.d /var/lib/mysql /var/log/mysqld.log
      ;;
    *)
      err "不支持的包管理器，无法自动卸载 MySQL"
      return
      ;;
  esac

  msg "MySQL/MariaDB 已卸载完成"
}

show_menu() {
  clear
  line
  echo "           adnx_dns 部署脚本"
  line
  echo "1. 检查环境"
  echo "2. 安装 / 更新"
  echo "3. 初始化数据库"
  echo "4. 修改配置文件"
  echo "5. 服务管理"
  echo "6. 卸载应用"
  echo "7. 卸载 MySQL 并重新安装"
  echo "0. 退出"
  line
}

main() {
  check_root

  while true; do
    show_menu
    read -rp "请输入选项: " choice
    case "$choice" in
      1)
        show_environment_status
        pause_wait
        ;;
      2)
        install_or_update_app
        pause_wait
        ;;
      3)
        init_db
        pause_wait
        ;;
      4)
        edit_config_file
        pause_wait
        ;;
      5)
        service_manage
        ;;
      6)
        uninstall_app
        pause_wait
        ;;
      7)
        remove_mysql_completely
        pause_wait
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