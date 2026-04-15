#!/bin/bash
# 更新 ad2nx node_config 配置脚本
# 使用示例：
# export API_HOST="api.example.com"
# export API_KEY="your-api-key"
# export NODE_ID="1"
# export CORE_TYPE="sing"
# export NODE_TYPE="vless"
# bash update-config.sh

set -e

# 错误追踪函数
trap_error() {
    local exit_code=$?
    local line_no=$1
    echo ""
    echo "ERROR: Script failed at line ${line_no}"
    echo "Exit code: ${exit_code}"
    exit $exit_code
}

# 启用错误追踪
trap 'trap_error ${LINENO}' ERR

# 检查root权限
check_root() {
    echo "[1/3] Checking root privileges..."
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root user!"
        echo "Current user ID: $EUID (required: 0)"
        echo "Hint: Please run with sudo bash update-config.sh"
        exit 1
    fi
    echo "[OK] Root privileges check passed"
}

# 检查配置目录
check_config_dir() {
    echo "[2/3] Checking configuration directory..."
    if [[ ! -d /etc/ad2nx ]]; then
        echo "ERROR: Configuration directory /etc/ad2nx does not exist"
        echo "Hint: Please install ad2nx first using auto-install.sh"
        exit 1
    fi
    echo "[OK] Configuration directory exists"
}

# 读取环境变量
load_env_variables() {
    echo "[3/3] Loading environment variables..."
    
    # 从现有配置文件读取默认值（如果存在）
    if [[ -f /etc/ad2nx/config.json ]]; then
        echo "Reading existing configuration..."
    fi
    
    # 节点配置
    API_HOST="${API_HOST:-}"
    API_KEY="${API_KEY:-}"
    NODE_ID="${NODE_ID:-}"
    CORE_TYPE="${CORE_TYPE:-sing}"
    NODE_TYPE="${NODE_TYPE:-vless}"
    
    # 证书配置
    CERT_MODE="${CERT_MODE:-none}"
    CERT_DOMAIN="${CERT_DOMAIN:-example.com}"
    CERT_PROVIDER="${CERT_PROVIDER:-godaddy}"
    CERT_EMAIL="${CERT_EMAIL:-demo@test.com}"
    
    CERT_GODADDY_API_KEY="${CERT_GODADDY_API_KEY:-}"
    CERT_GODADDY_API_SECRET="${CERT_GODADDY_API_SECRET:-}"
    
    CERT_CF_DNS_API_TOKEN="${CERT_CF_DNS_API_TOKEN:-}"
    
    echo "[OK] Environment variables loaded"
}

# 检查IPv6支持
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6" 2>/dev/null; then
        echo "1"
    else
        echo "0"
    fi
}

# 生成新的配置文件
generate_new_config() {
    echo "Generating new configuration..."
    
    local ipv6_support=$(check_ipv6_support)
    local listen_ip="0.0.0.0"
    [[ $ipv6_support -eq 1 ]] && listen_ip="::"
    
    # 生成 DNSEnv 内容
    local dsn_env_json=""
    if [[ "$CERT_PROVIDER" == "godaddy" ]]; then
        dsn_env_json="\"GODADDY_API_KEY\": \"$CERT_GODADDY_API_KEY\", \"GODADDY_API_SECRET\": \"$CERT_GODADDY_API_SECRET\""
    elif [[ "$CERT_PROVIDER" == "cloudflare" ]]; then
        dsn_env_json="\"CF_DNS_API_TOKEN\": \"$CERT_CF_DNS_API_TOKEN\""
    else
        dsn_env_json="\"EnvName\": \"env1\""
    fi
    
    # 生成节点配置
    local node_config=""
    if [ "$CORE_TYPE" == "xray" ]; then 
        node_config="{
            \"Core\": \"$CORE_TYPE\",
            \"ApiHost\": \"$API_HOST\",
            \"ApiKey\": \"$API_KEY\",
            \"NodeID\": ${NODE_ID},
            \"NodeType\": \"$NODE_TYPE\",
            \"Timeout\": 30,
            \"ListenIP\": \"0.0.0.0\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"MinReportTraffic\": 0,
            \"EnableProxyProtocol\": false,
            \"EnableUot\": true,
            \"EnableTFO\": true,
            \"DNSType\": \"UseIPv4\",
            \"CertConfig\": {
                \"CertMode\": \"$CERT_MODE\",
                \"RejectUnknownSni\": false,
                \"CertDomain\": \"$CERT_DOMAIN\",
                \"CertFile\": \"/etc/ad2nx/fullchain.cer\",
                \"KeyFile\": \"/etc/ad2nx/cert.key\",
                \"Email\": \"$CERT_EMAIL\",
                \"Provider\": \"$CERT_PROVIDER\",
                \"DNSEnv\": {${dsn_env_json}}
            }
        }"
    elif [ "$CORE_TYPE" == "sing" ]; then
        node_config="{
            \"Core\": \"$CORE_TYPE\",
            \"ApiHost\": \"$API_HOST\",
            \"ApiKey\": \"$API_KEY\",
            \"NodeID\": ${NODE_ID},
            \"NodeType\": \"$NODE_TYPE\",
            \"Timeout\": 30,
            \"ListenIP\": \"$listen_ip\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"MinReportTraffic\": 0,
            \"TCPFastOpen\": true,
            \"SniffEnabled\": true,
            \"CertConfig\": {
                \"CertMode\": \"$CERT_MODE\",
                \"RejectUnknownSni\": false,
                \"CertDomain\": \"$CERT_DOMAIN\",
                \"CertFile\": \"/etc/ad2nx/fullchain.cer\",
                \"KeyFile\": \"/etc/ad2nx/cert.key\",
                \"Email\": \"$CERT_EMAIL\",
                \"Provider\": \"$CERT_PROVIDER\",
                \"DNSEnv\": {${dsn_env_json}}
            }
        }"
    elif [ "$CORE_TYPE" == "hysteria2" ]; then
        node_config="{
            \"Core\": \"$CORE_TYPE\",
            \"ApiHost\": \"$API_HOST\",
            \"ApiKey\": \"$API_KEY\",
            \"NodeID\": ${NODE_ID},
            \"NodeType\": \"$NODE_TYPE\",
            \"Hysteria2ConfigPath\": \"/etc/ad2nx/hy2config.yaml\",
            \"Timeout\": 30,
            \"ListenIP\": \"0.0.0.0\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"MinReportTraffic\": 0,
            \"CertConfig\": {
                \"CertMode\": \"$CERT_MODE\",
                \"RejectUnknownSni\": false,
                \"CertDomain\": \"$CERT_DOMAIN\",
                \"CertFile\": \"/etc/ad2nx/fullchain.cer\",
                \"KeyFile\": \"/etc/ad2nx/cert.key\",
                \"Email\": \"$CERT_EMAIL\",
                \"Provider\": \"$CERT_PROVIDER\",
                \"DNSEnv\": {${dsn_env_json}}
            }
        }"
    fi
    
    # 生成核心配置
    local cores_config="["
    [[ "$CORE_TYPE" == "xray" ]] && cores_config+="{\"Type\":\"xray\",\"Log\":{\"Level\":\"error\"},\"OutboundConfigPath\":\"/etc/ad2nx/custom_outbound.json\",\"RouteConfigPath\":\"/etc/ad2nx/route.json\"},"
    [[ "$CORE_TYPE" == "sing" ]] && cores_config+="{\"Type\":\"sing\",\"Log\":{\"Level\":\"error\"},\"OriginalPath\":\"/etc/ad2nx/sing_origin.json\"},"
    [[ "$CORE_TYPE" == "hysteria2" ]] && cores_config+="{\"Type\":\"hysteria2\",\"Log\":{\"Level\":\"error\"}},"
    cores_config="${cores_config%,}]"
    
    # 备份现有配置
    if [[ -f /etc/ad2nx/config.json ]]; then
        local backup_file="/etc/ad2nx/config.json.backup.$(date +%Y%m%d_%H%M%S)"
        cp /etc/ad2nx/config.json "$backup_file"
        echo "Backup created: $backup_file"
    fi
    
    # 生成新配置文件
    cat > /etc/ad2nx/config.json <<CONFIGEOF
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": $cores_config,
    "Nodes": [$node_config]
}
CONFIGEOF
    
    echo "Configuration file updated successfully"
}

# 重启服务
restart_service() {
    echo "Restarting ad2nx service..."
    
    # 检测系统类型
    if [[ -f /etc/alpine-release ]]; then
        service ad2nx restart || {
            echo "ERROR: Failed to restart service"
            return 1
        }
    else
        systemctl restart ad2nx || {
            echo "ERROR: Failed to restart service"
            return 1
        }
    fi
    
    sleep 2
    
    # 检查服务状态
    if [[ -f /etc/alpine-release ]]; then
        if service ad2nx status 2>/dev/null | grep -q "started"; then
            echo "Service restarted successfully"
            return 0
        fi
    else
        if systemctl is-active --quiet ad2nx 2>/dev/null; then
            echo "Service restarted successfully"
            return 0
        fi
    fi
    
    echo "WARNING: Service may not be running properly"
    echo "Please check logs with: ad2nx log"
    return 1
}

# 显示配置摘要
show_summary() {
    echo ""
    echo "========= Configuration Update Summary ========="
    echo "API_HOST: ${API_HOST:-<not set>}"
    echo "NODE_ID: ${NODE_ID:-<not set>}"
    echo "CORE_TYPE: ${CORE_TYPE}"
    echo "NODE_TYPE: ${NODE_TYPE}"
    echo "CERT_MODE: ${CERT_MODE}"
    echo "CERT_PROVIDER: ${CERT_PROVIDER}"
    echo "CERT_DOMAIN: ${CERT_DOMAIN}"
    echo "================================================"
    echo ""
}

# 主流程
main() {
    echo "========= ad2nx Configuration Update Script ========="
    echo ""
    
    check_root
    check_config_dir
    load_env_variables
    
    # 检查必需的环境变量
    local missing_vars=()
    [[ -z "${API_HOST}" ]] && missing_vars+=("API_HOST")
    [[ -z "${API_KEY}" ]] && missing_vars+=("API_KEY")
    [[ -z "${NODE_ID}" ]] && missing_vars+=("NODE_ID")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "WARNING: Missing environment variables: ${missing_vars[*]}"
        echo "These values will not be updated in the configuration."
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Update cancelled"
            exit 1
        fi
    fi
    
    show_summary
    
    generate_new_config
    
    # 询问是否重启服务
    # read -p "Restart ad2nx service now? (Y/n): " -n 1 -r
    # echo
    # if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    #     restart_service
    # else
    #     echo "Service not restarted. Please restart manually with: systemctl restart ad2nx"
    # fi
    
    echo ""
    echo "========= Update Complete ========="
    echo "Configuration file: /etc/ad2nx/config.json"
    echo "View logs: ad2nx log"
    echo "===================================="
}

main
