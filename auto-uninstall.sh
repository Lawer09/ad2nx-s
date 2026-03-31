#!/bin/bash
# 节点卸载脚本 - 自动卸载 ad2nx 及其所有配置
# 使用示例：
# sudo bash auto-uninstall.sh
# 或使用环境变量控制行为：
# export KEEP_CONFIG="y"  # 保留配置文件
# export KEEP_LOGS="y"    # 保留日志文件
# sudo bash auto-uninstall.sh

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 检查root权限
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${red}错误：必须使用root用户运行此脚本！${plain}" && exit 1
}

# 检查系统类型
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -Eqi "alpine"; then
        release="alpine"
    elif cat /etc/issue | grep -Eqi "debian"; then
        release="debian"
    elif cat /etc/issue | grep -Eqi "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
        release="centos"
    elif cat /proc/version | grep -Eqi "debian"; then
        release="debian"
    elif cat /proc/version | grep -Eqi "ubuntu"; then
        release="ubuntu"
    elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
        release="centos"
    elif cat /proc/version | grep -Eqi "arch"; then
        release="arch"
    else
        echo -e "${red}未检测到支持的系统版本${plain}"
        exit 1
    fi
    
    echo -e "${green}检测到系统：${release}${plain}"
}

# 初始化变量
init_variables() {
    # 保留选项
    KEEP_CONFIG="${KEEP_CONFIG:-n}"
    KEEP_LOGS="${KEEP_LOGS:-n}"
    BACKUP_CONFIG="${BACKUP_CONFIG:-y}"
    
    echo -e "${green}初始化参数完成${plain}"
}

# 检查ad2nx是否已安装
check_installed() {
    if [[ ! -f /usr/local/ad2nx/ad2nx ]]; then
        echo -e "${yellow}ad2nx 未安装，无需卸载${plain}"
        exit 0
    fi
}

# 停止服务
stop_service() {
    echo -e "${green}正在停止 ad2nx 服务...${plain}"
    
    if [[ x"${release}" == x"alpine" ]]; then
        service ad2nx stop 2>/dev/null || true
    else
        systemctl stop ad2nx 2>/dev/null || true
    fi
    
    # 等待服务完全停止
    sleep 2
    
    # 确保进程已杀死
    pkill -9 ad2nx 2>/dev/null || true
    
    echo -e "${green}服务停止完成${plain}"
}

# 禁用开机自启
disable_autostart() {
    echo -e "${green}正在禁用开机自启...${plain}"
    
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del ad2nx 2>/dev/null || true
        rm /etc/init.d/ad2nx -f 2>/dev/null || true
    else
        systemctl disable ad2nx 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
        rm /etc/systemd/system/ad2nx.service -f 2>/dev/null || true
    fi
    
    echo -e "${green}禁用开机自启完成${plain}"
}

# 备份配置文件
backup_config() {
    if [[ "${BACKUP_CONFIG}" != [Yy] ]]; then
        return 0
    fi
    
    echo -e "${green}正在备份配置文件...${plain}"
    
    if [[ -d /etc/ad2nx ]]; then
        local backup_dir="/tmp/ad2nx-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp -r /etc/ad2nx/* "$backup_dir/" 2>/dev/null || true
        echo -e "${green}配置已备份到：${backup_dir}${plain}"
    fi
}

# 删除二进制文件
remove_binary() {
    echo -e "${green}正在删除二进制文件...${plain}"
    
    # 删除安装目录
    if [[ -d /usr/local/ad2nx ]]; then
        rm -rf /usr/local/ad2nx
        echo -e "${green}已删除 /usr/local/ad2nx${plain}"
    fi
    
    # 删除命令链接
    if [[ -f /usr/bin/ad2nx ]]; then
        rm -f /usr/bin/ad2nx
        echo -e "${green}已删除 /usr/bin/ad2nx${plain}"
    fi
}

# 删除配置文件
remove_config() {
    if [[ "${KEEP_CONFIG}" == [Yy] ]]; then
        echo -e "${yellow}保留配置文件目录：/etc/ad2nx${plain}"
        return 0
    fi
    
    echo -e "${green}正在删除配置文件...${plain}"
    
    if [[ -d /etc/ad2nx ]]; then
        rm -rf /etc/ad2nx
        echo -e "${green}已删除 /etc/ad2nx${plain}"
    fi
}

# 删除日志文件
remove_logs() {
    if [[ "${KEEP_LOGS}" == [Yy] ]]; then
        echo -e "${yellow}保留日志文件${plain}"
        return 0
    fi
    
    echo -e "${green}正在删除日志文件...${plain}"
    
    # 删除systemd日志
    if journalctl -u ad2nx 2>/dev/null | grep -q "ad2nx"; then
        journalctl --flush 2>/dev/null || true
        journalctl -u ad2nx --delete 2>/dev/null || true
        echo -e "${green}已清理系统日志${plain}"
    fi
    
    # 删除应用日志目录
    if [[ -d /var/log/ad2nx ]]; then
        rm -rf /var/log/ad2nx
        echo -e "${green}已删除 /var/log/ad2nx${plain}"
    fi
}

# 删除定时任务
remove_cron() {
    echo -e "${green}正在检查并删除定时任务...${plain}"
    
    if crontab -l 2>/dev/null | grep -q "ad2nx"; then
        crontab -l 2>/dev/null | grep -v "ad2nx" | crontab - 2>/dev/null || true
        echo -e "${green}已删除相关定时任务${plain}"
    fi
}

# 清理系统链接
cleanup_symlinks() {
    echo -e "${green}正在清理系统链接...${plain}"
    
    local symlinks=(
        "/usr/bin/ad2nx"
        "/usr/local/bin/ad2nx"
        "/opt/ad2nx"
    )
    
    for link in "${symlinks[@]}"; do
        if [[ -L "$link" || -f "$link" ]]; then
            rm -f "$link" 2>/dev/null || true
        fi
    done
    
    echo -e "${green}系统链接清理完成${plain}"
}

# 删除systemd单位文件
cleanup_systemd() {
    echo -e "${green}正在清理 systemd 配置...${plain}"
    
    rm -f /etc/systemd/system/ad2nx.service 2>/dev/null || true
    rm -f /etc/systemd/system/ad2nx@*.service 2>/dev/null || true
    rm -f /etc/systemd/system/multi-user.target.wants/ad2nx.service 2>/dev/null || true
    
    systemctl daemon-reload 2>/dev/null || true
    
    echo -e "${green}systemd 配置清理完成${plain}"
}

# 删除openrc单位文件
cleanup_openrc() {
    echo -e "${green}正在清理 openrc 配置...${plain}"
    
    rm -f /etc/init.d/ad2nx 2>/dev/null || true
    rm -f /etc/runlevels/*/ad2nx 2>/dev/null || true
    
    echo -e "${green}openrc 配置清理完成${plain}"
}

# 验证卸载
verify_uninstall() {
    echo -e "${green}正在验证卸载完成情况...${plain}"
    
    local uninstall_ok=true
    
    # 检查二进制
    if [[ -f /usr/local/ad2nx/ad2nx ]]; then
        echo -e "${red}✗ 二进制文件仍然存在${plain}"
        uninstall_ok=false
    else
        echo -e "${green}✓ 二进制文件已删除${plain}"
    fi
    
    # 检查命令
    if command -v ad2nx >/dev/null 2>&1; then
        echo -e "${red}✗ 命令链接仍然存在${plain}"
        uninstall_ok=false
    else
        echo -e "${green}✓ 命令链接已删除${plain}"
    fi
    
    # 检查服务
    if [[ x"${release}" != x"alpine" ]]; then
        if systemctl list-unit-files | grep -q "ad2nx.service"; then
            echo -e "${yellow}⚠ systemd 单位文件未完全删除${plain}"
        else
            echo -e "${green}✓ systemd 单位文件已删除${plain}"
        fi
    fi
    
    # 检查进程
    if pgrep ad2nx >/dev/null 2>&1; then
        echo -e "${red}✗ ad2nx 进程仍在运行${plain}"
        pkill -9 ad2nx 2>/dev/null || true
        uninstall_ok=false
    else
        echo -e "${green}✓ ad2nx 进程已停止${plain}"
    fi
    
    if [[ "${uninstall_ok}" == "true" ]]; then
        echo -e "${green}卸载验证通过${plain}"
        return 0
    else
        echo -e "${yellow}卸载验证失败，但继续卸载流程${plain}"
        return 1
    fi
}

# 显示卸载摘要
show_summary() {
    echo -e ""
    echo -e "${green}========== 卸载摘要 ==========${plain}"
    echo -e "${green}✓ 已删除二进制文件${plain}"
    echo -e "${green}✓ 已停止服务${plain}"
    echo -e "${green}✓ 已禁用开机自启${plain}"
    
    if [[ "${KEEP_CONFIG}" == [Yy] ]]; then
        echo -e "${yellow}⚠ 保留配置文件：/etc/ad2nx${plain}"
    else
        echo -e "${green}✓ 已删除配置文件${plain}"
    fi
    
    if [[ "${KEEP_LOGS}" == [Yy] ]]; then
        echo -e "${yellow}⚠ 保留日志文件${plain}"
    else
        echo -e "${green}✓ 已删除日志文件${plain}"
    fi
    
    echo -e "${green}✓ 已清理定时任务${plain}"
    echo -e "${green}✓ 已清理系统链接${plain}"
    echo -e "${green}========== 卸载完成 ==========${plain}"
    echo -e ""
}

# 选项处理
show_help() {
    cat <<EOF
用法: sudo bash auto-uninstall.sh [选项]

选项:
    -h, --help              显示帮助信息
    -k, --keep-config       保留配置文件 (/etc/ad2nx)
    -l, --keep-logs         保留日志文件
    -nb, --no-backup        不备份配置文件
    -y, --yes               跳过确认提示

环境变量:
    KEEP_CONFIG="y"         保留配置文件
    KEEP_LOGS="y"           保留日志文件
    BACKUP_CONFIG="n"       不备份配置文件

示例:
    # 完整卸载（删除所有文件）
    sudo bash auto-uninstall.sh

    # 卸载但保留配置（用于升级）
    sudo bash auto-uninstall.sh --keep-config

    # 卸载但不备份配置
    sudo bash auto-uninstall.sh --no-backup

    # 自动确认，无提示
    sudo bash auto-uninstall.sh -y

    # 使用环境变量
    export KEEP_CONFIG="y"
    sudo bash auto-uninstall.sh

EOF
}

# 确认卸载
confirm_uninstall() {
    if [[ "${CONFIRM:-n}" == [Yy] ]]; then
        return 0
    fi
    
    cat <<EOF

${yellow}========== 卸载确认 ==========${plain}
${red}警告：此操作将卸载 ad2nx 节点${plain}

配置：
  - 二进制文件: 将被删除
  - 配置文件: $([ "${KEEP_CONFIG}" == [Yy] ] && echo "保留" || echo "将被删除")
  - 日志文件: $([ "${KEEP_LOGS}" == [Yy] ] && echo "保留" || echo "将被删除")
  - 备份: $([ "${BACKUP_CONFIG}" == [Yy] ] && echo "已启用" || echo "已禁用")

${yellow}确定要继续卸载吗？(y/n)${plain}

EOF
    
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${yellow}卸载已取消${plain}"
        exit 0
    fi
}

# 主卸载流程
main() {
    # 处理命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -k|--keep-config)
                KEEP_CONFIG="y"
                shift
                ;;
            -l|--keep-logs)
                KEEP_LOGS="y"
                shift
                ;;
            -nb|--no-backup)
                BACKUP_CONFIG="n"
                shift
                ;;
            -y|--yes)
                CONFIRM="y"
                shift
                ;;
            *)
                echo -e "${red}未知选项: $1${plain}"
                show_help
                exit 1
                ;;
        esac
    done
    
    check_root
    init_variables
    check_system
    check_installed
    
    echo -e "${green}========== ad2nx 卸载脚本 ==========${plain}"
    echo ""
    
    confirm_uninstall
    
    echo -e "${green}开始卸载流程...${plain}"
    echo ""
    
    # 执行卸载步骤
    stop_service
    disable_autostart
    backup_config
    remove_binary
    remove_config
    remove_logs
    remove_cron
    cleanup_symlinks
    
    if [[ x"${release}" != x"alpine" ]]; then
        cleanup_systemd
    else
        cleanup_openrc
    fi
    
    verify_uninstall
    show_summary
    
    echo -e "${green}如需重新安装，请使用：${plain}"
    echo -e "${yellow}  sudo bash auto-install.sh${plain}"
    echo ""
}

main "$@"
