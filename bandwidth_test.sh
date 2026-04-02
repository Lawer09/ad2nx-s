#!/usr/bin/env bash
# 功能：网络测速脚本，所有输出均为 JSON 格式 {code, data, msg}
# 要求：运行用户具有 sudo 权限（静默安装依赖）
# 用法：
#   ./bandwidth_test.sh                    # 自动选择最优服务器
#   ./bandwidth_test.sh --country CN       # 指定国家代码
#   ./bandwidth_test.sh --server 12345     # 指定服务器ID
#   ./bandwidth_test.sh --list-servers     # 列出可用服务器
#   ./bandwidth_test.sh --list-servers --country CN  # 列出指定国家的服务器

set -euo pipefail

# ============================================
# 全局配置
# ============================================
REQUIRED_PACKAGES=("speedtest-cli" "jq" "python3")
NEED_INSTALL=()
COUNTRY_CODE=""
SERVER_ID=""
LIST_SERVERS=false

# ============================================
# 辅助函数：输出 JSON 并退出
# ============================================
output_json() {
    local code="$1"
    local data="$2"
    local msg="$3"
    jq -n --argjson code "$code" --argjson data "$data" --arg msg "$msg" \
        '{code: $code, data: $data, msg: $msg}'
    exit 0
}

output_error() {
    local msg="$1"
    output_json 1 "null" "$msg"
}

output_success() {
    local data="$1"
    output_json 0 "$data" "success"
}

# ============================================
# 参数解析
# ============================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --country)
                COUNTRY_CODE="$2"
                shift 2
                ;;
            --server)
                SERVER_ID="$2"
                shift 2
                ;;
            --list-servers)
                LIST_SERVERS=true
                shift
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
    --country CODE        Filter servers by country code (e.g., CN, US, JP)
    --server ID          Use specific server by ID
    --list-servers       List available servers (JSON format)
    -h, --help           Show this help message

Examples:
    $0                              # Auto select best server
    $0 --country CN                 # Test with China server
    $0 --server 12345               # Test with specific server
    $0 --list-servers               # List all servers
    $0 --list-servers --country CN  # List China servers
EOF
                exit 0
                ;;
            *)
                output_error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

parse_arguments "$@"

# ============================================
# 依赖检查与静默安装
# ============================================

check_package_installed() {
    dpkg -s "$1" &>/dev/null
}

install_missing_packages() {
    if [[ ${#NEED_INSTALL[@]} -eq 0 ]]; then
        return 0
    fi

    if ! sudo apt update -qq 2>/dev/null; then
        output_error "apt update failed, please check network or repository"
    fi

    if ! sudo apt install -y "${NEED_INSTALL[@]}" >/dev/null 2>&1; then
        output_error "Failed to install dependencies: ${NEED_INSTALL[*]}. Please install manually."
    fi
}

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! check_package_installed "$pkg"; then
        NEED_INSTALL+=("$pkg")
    fi
done

if [[ ${#NEED_INSTALL[@]} -gt 0 ]]; then
    install_missing_packages
fi

for cmd in speedtest-cli jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        output_error "Command '$cmd' not available after installation"
    fi
done

# ============================================
# 列出服务器
# ============================================

list_servers() {
    local servers_output
    servers_output=$(speedtest-cli --list 2>/dev/null) || {
        output_error "Failed to retrieve server list"
    }

    local servers_json="[]"
    
    # 解析服务器列表并转换为 JSON
    servers_json=$(echo "$servers_output" | python3 -c '
import sys
import json
import re

servers = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    # 匹配格式: 12345) ServerName (SponsorName, Location, Country) [Distance km]
    match = re.match(r"(\d+)\)\s+(.+?)\s+\((.+?),\s+(.+?),\s+(.+?)\)\s+\[([0-9.]+)\s+km\]", line)
    if match:
        server_id, name, sponsor, location, country, distance = match.groups()
        servers.append({
            "id": int(server_id),
            "name": name.strip(),
            "sponsor": sponsor.strip(),
            "location": location.strip(),
            "country": country.strip(),
            "distance_km": float(distance)
        })

print(json.dumps(servers))
' 2>/dev/null) || {
        output_error "Failed to parse server list"
    }

    # 如果指定了国家，进行过滤
    if [[ -n "$COUNTRY_CODE" ]]; then
        servers_json=$(echo "$servers_json" | jq --arg country "$COUNTRY_CODE" '
            map(select(.country | ascii_upcase | contains($country | ascii_upcase)))
        ' 2>/dev/null) || {
            output_error "Failed to filter servers by country"
        }
    fi

    output_success "$servers_json"
}

if [[ "$LIST_SERVERS" == true ]]; then
    list_servers
fi

# ============================================
# 执行测速
# ============================================

# 构建 speedtest-cli 命令参数
speedtest_args=("--json")

if [[ -n "$SERVER_ID" ]]; then
    speedtest_args+=("--server" "$SERVER_ID")
elif [[ -n "$COUNTRY_CODE" ]]; then
    # 获取指定国家的最近服务器
    servers_list=$(speedtest-cli --list 2>/dev/null) || {
        output_error "Failed to retrieve server list for country filter"
    }
    
    closest_server=$(echo "$servers_list" | python3 -c "
import sys
import re

country_code = '$COUNTRY_CODE'.upper()
min_distance = float('inf')
closest_id = None

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    match = re.match(r'(\d+)\).*?,\s+(.+?),\s+(.+?)\)\s+\[([0-9.]+)\s+km\]', line)
    if match:
        server_id, location, country, distance = match.groups()
        if country_code in country.upper():
            distance = float(distance)
            if distance < min_distance:
                min_distance = distance
                closest_id = server_id

if closest_id:
    print(closest_id)
" 2>/dev/null)

    if [[ -n "$closest_server" ]]; then
        speedtest_args+=("--server" "$closest_server")
    else
        output_error "No servers found for country code: $COUNTRY_CODE"
    fi
fi

raw_json=$(speedtest-cli "${speedtest_args[@]}" 2>/dev/null) || {
    output_error "speedtest-cli execution failed. Check network or server availability."
}

if [[ -z "$raw_json" ]]; then
    output_error "speedtest-cli returned empty output"
fi

# 安全解析：处理 null 值，并抑制 jq 的 stderr 错误信息
data_json=$(echo "$raw_json" | jq -c '
    {
        download_mbps: (if .download != null then .download / 1e6 else null end),
        upload_mbps:   (if .upload != null then .upload / 1e6 else null end),
        ping_ms:       .ping,
        server: {
            name:     .server.name,
            sponsor:  .server.sponsor,
            location: .server.location,
            country:  .server.country
        },
        client: {
            ip:       .client.ip,
            isp:      .client.isp,
            country:  .client.country
        },
        timestamp: .timestamp,
        share_url: .share
    }
' 2>/dev/null) || {
    output_error "Failed to parse speedtest-cli JSON output"
}

output_success "$data_json"