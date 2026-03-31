#!/bin/bash
# 快速安装脚本 - 修改下面的配置后直接运行此脚本
# 用途：简化配置，直接运行此脚本进行一键安装
# 使用：bash quick-install.sh

# ============ 配置开始 ============

# 必选配置
API_HOST="api.example.com"            # API 服务器地址
API_KEY="your-api-key"                # API 密钥
NODE_ID="1"                           # 节点 ID
CORE_TYPE="2"                         # 核心类型（1=xray, 2=singbox, 3=hysteria2）

# 可选配置
NODE_TYPE="2"                         # 协议类型（1=ss, 2=vless, 3=vmess, 5=hy2, 6=trojan）
CERT_MODE="none"                      # 证书模式（none, http, dns, self）
CERT_DOMAIN="example.com"             # 证书域名
IF_GENERATE="y"                       # 是否生成配置文件（y/n）
IF_REGISTER="n"                       # 是否运行注册脚本（y/n）

# ============ 配置结束 ============

set -euo pipefail

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

echo -e "${yellow}========== ad2nx 快速安装脚本 ==========${plain}"
echo ""
echo -e "${green}当前配置：${plain}"
echo "  API_HOST:    $API_HOST"
echo "  API_KEY:     ${API_KEY:0:10}***"
echo "  NODE_ID:     $NODE_ID"
echo "  CORE_TYPE:   $CORE_TYPE"
echo "  NODE_TYPE:   $NODE_TYPE"
echo ""

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}错误：必须使用 root 用户运行此脚本${plain}"
    exit 1
fi

# 导出环境变量并运行自动安装脚本
export API_HOST
export API_KEY
export NODE_ID
export CORE_TYPE
export NODE_TYPE
export CERT_MODE
export CERT_DOMAIN
export IF_GENERATE
export IF_REGISTER

# 获取当前目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查 auto-install.sh 是否存在
if [[ ! -f "${SCRIPT_DIR}/auto-install.sh" ]]; then
    echo -e "${red}错误：未找到 auto-install.sh，请确保在正确的目录运行此脚本${plain}"
    exit 1
fi

echo -e "${green}开始安装...${plain}"
echo ""

# 运行自动安装脚本
bash "${SCRIPT_DIR}/auto-install.sh"
