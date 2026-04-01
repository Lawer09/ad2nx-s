#!/bin/bash
# 仅通过环境变量自动安装脚本（无人工交互）
# 使用示例：
# export API_HOST="api.example.com"
# export API_KEY="your-api-key"
# export NODE_ID="1"
# export CORE_TYPE="sing"  # 1=xray, 2=singbox, 3=hysteria2
# export NODE_TYPE="vless"  # 1=shadowsocks, 2=vless, 3=vmess, 4=hysteria, 5=hysteria2, 6=trojan, 7=tuic, 8=anytls
# bash auto-install.sh

# set -euo pipefail  # 已禁用，改用手动错误检查
set -e  # 仅在命令失败时退出，但允许更多容错

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

# Color variables removed for clean output

# 必需的环境变量检查
check_required_env() {
    echo "[2/5] Checking environment variables..."
    local missing_vars=()
    
    [[ -z "${API_HOST:-}" ]] && missing_vars+=("API_HOST")
    [[ -z "${API_KEY:-}" ]] && missing_vars+=("API_KEY")
    [[ -z "${NODE_ID:-}" ]] && missing_vars+=("NODE_ID")
    [[ -z "${CORE_TYPE:-}" ]] && missing_vars+=("CORE_TYPE")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}"
        echo "Required environment variables:"
        echo "  API_HOST      - API 服务器地址"
        echo "  API_KEY       - API 密钥"
        echo "  NODE_ID       - 节点 ID（数字）"
        echo "  CORE_TYPE     - 核心类型（xray, sing, hysteria2）"
        echo ""
        echo "Usage example:"
        echo "  export API_HOST=\"api.example.com\""
        echo "  export API_KEY=\"your-api-key\""
        echo "  export NODE_ID=\"1\""
        echo "  export CORE_TYPE=\"sing\""
        exit 1
    fi
    echo "[OK] Environment variables check passed"
}

# 检查root权限
check_root() {
    echo "[1/5] Checking root privileges..."
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root user!"
        echo "Current user ID: $EUID (required: 0)"
        echo "Hint: Please run with sudo bash auto-install.sh"
        exit 1
    fi
    echo "[OK] Root privileges check passed"
}

# 检查系统类型
check_system() {
    echo "[3/5] Checking system type..."
    
    # 检查关键系统文件是否存在
    if [[ ! -f /etc/issue && ! -f /proc/version ]]; then
        echo "ERROR: Linux system files not detected (/etc/issue or /proc/version)"
        echo "Hint: This script must be run on a Linux system (e.g., Ubuntu, Debian, CentOS)"
        echo "If you are on Windows, please use WSL (Windows Subsystem for Linux)"
        exit 1
    fi
    
    release=""
    
    # 使用 || true 防止 grep 没有匹配时导致退出
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif [[ -f /etc/issue ]] && grep -Eqi "alpine" /etc/issue 2>/dev/null; then
        release="alpine"
    elif [[ -f /etc/issue ]] && grep -Eqi "debian" /etc/issue 2>/dev/null; then
        release="debian"
    elif [[ -f /etc/issue ]] && grep -Eqi "ubuntu" /etc/issue 2>/dev/null; then
        release="ubuntu"
    elif [[ -f /etc/issue ]] && grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /etc/issue 2>/dev/null; then
        release="centos"
    elif [[ -f /proc/version ]] && grep -Eqi "debian" /proc/version 2>/dev/null; then
        release="debian"
    elif [[ -f /proc/version ]] && grep -Eqi "ubuntu" /proc/version 2>/dev/null; then
        release="ubuntu"
    elif [[ -f /proc/version ]] && grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /proc/version 2>/dev/null; then
        release="centos"
    elif [[ -f /proc/version ]] && grep -Eqi "arch" /proc/version 2>/dev/null; then
        release="arch"
    fi
    
    if [[ -z "$release" ]]; then
        echo "ERROR: Unsupported system version not detected"
        echo "Supported systems: Ubuntu, Debian, CentOS, Alpine, Arch Linux"
        if [[ -f /etc/issue ]]; then
            echo "Current system information (/etc/issue):"
            cat /etc/issue 2>/dev/null || true
        fi
        if [[ -f /proc/version ]]; then
            echo "Current system information (/proc/version):"
            cat /proc/version 2>/dev/null || true
        fi
        exit 1
    fi
    
    echo "[OK] System type: ${release}"
}

# 检查架构
check_arch() {
    echo "[4/5] Checking system architecture..."
    local raw_arch=$(uname -m)
    
    if [[ $raw_arch == "x86_64" || $raw_arch == "x64" || $raw_arch == "amd64" ]]; then
        arch="64"
    elif [[ $raw_arch == "aarch64" || $raw_arch == "arm64" ]]; then
        arch="arm64-v8a"
    elif [[ $raw_arch == "s390x" ]]; then
        arch="s390x"
    else
        arch="64"
    fi
    
    echo "[OK] System architecture: ${raw_arch} -> ${arch}"
}

# 初始化变量
init_variables() {
    echo "[5/5] Initializing configuration variables..."
    cur_dir=$(pwd)
    
    # 默认值
    RELEASE_REPO="${RELEASE_REPO:-Lawer09/ad2nx}"
    SCRIPT_REPO="${SCRIPT_REPO:-Lawer09/ad2nx-s}"
    SCRIPT_BRANCH="${SCRIPT_BRANCH:-master}"
    GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
    GITHUB_RAW_BASE="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com}"
    
    # 节点配置
    NODE_INOUT_TYPE="${NODE_INOUT_TYPE:-stand}"
    NODE_TYPE="${NODE_TYPE:-vless}"  # 默认vless
    CORE_TYPE="${CORE_TYPE:-sing}"  # 默认sing-box
    
    # 证书配置
    CERT_MODE="${CERT_MODE:-none}"
    CERT_DOMAIN="${CERT_DOMAIN:-example.com}"
    
    echo "[OK] Configuration variables initialization complete"
}

# 卸载现有的ad2nx（如果存在）
uninstall_if_exists() {
    if [[ -f /usr/local/ad2nx/ad2nx ]]; then
        echo "Detected installed ad2nx, uninstalling..."
        
        if [[ x"${release}" == x"alpine" ]]; then
            service ad2nx stop 2>/dev/null || true
            rc-update del ad2nx 2>/dev/null || true
            rm /etc/init.d/ad2nx -f 2>/dev/null || true
        else
            systemctl stop ad2nx 2>/dev/null || true
            systemctl disable ad2nx 2>/dev/null || true
            rm /etc/systemd/system/ad2nx.service -f 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed 2>/dev/null || true
        fi
        
        rm /usr/local/ad2nx -rf
        rm /usr/bin/ad2nx -f 2>/dev/null || true
        rm /etc/ad2nx -rf
        
        echo "Uninstall complete"
    fi
}

# Github API 下载文件
github_api_get() {
    local url="$1"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -Ls -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}"
    else
        curl -Ls "${url}"
    fi
}

github_contents_download() {
    local file_path="$1"
    local output_path="$2"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -Ls \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.raw" \
            "${GITHUB_API_BASE}/repos/${SCRIPT_REPO}/contents/${file_path}?ref=${SCRIPT_BRANCH}" \
            -o "${output_path}"
    else
        curl -Ls "${GITHUB_RAW_BASE}/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${file_path}" -o "${output_path}"
    fi
}

github_release_download_zip() {
    local version_tag="$1"
    local output_path="$2"
    local asset_name="${ASSET_NAME:-ad2nx-linux-${arch}.zip}"

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        local release_json asset_api_url
        release_json=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/tags/${version_tag}")
        if echo "${release_json}" | grep -q '"message": "Not Found"'; then
            if [[ "${version_tag}" != v* ]]; then
                release_json=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/tags/v${version_tag}")
            fi
        fi

        if echo "${release_json}" | grep -q '"message": "Not Found"'; then
            echo -e "${red}下载失败：未找到 Release tag ${version_tag}${plain}"
            exit 1
        fi

        asset_api_url=$(
            echo "${release_json}" | awk -F'"' -v name="${asset_name}" '
                $0 ~ /"url": "https:\/\/api\.github\.com\/repos\/.*\/releases\/assets\// { current_api_url=$4 }
                $0 ~ /"name":/ { current_name=$4 }
                $0 ~ /"browser_download_url":/ {
                    if (current_name==name && current_api_url!="") { print current_api_url; exit }
                    current_api_url=""
                    current_name=""
                }
            '
        )
        
        if [[ -z "${asset_api_url}" ]]; then
            echo -e "${red}下载失败：未找到发行版附件 ${asset_name}${plain}"
            exit 1
        fi

        curl -fL --retry 3 --retry-delay 1 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/octet-stream" \
            "${asset_api_url}" \
            -o "${output_path}"
        return $?
    fi

    # 无Token时使用wget
    wget --no-check-certificate -N --progress=bar -O "${output_path}" \
        "https://github.com/${RELEASE_REPO}/releases/download/${version_tag}/${asset_name}" 2>/dev/null || \
    {
        if [[ "${version_tag}" != v* ]]; then
            wget --no-check-certificate -N --progress=bar -O "${output_path}" \
                "https://github.com/${RELEASE_REPO}/releases/download/v${version_tag}/${asset_name}"
        else
            wget --no-check-certificate -N --progress=bar -O "${output_path}" \
                "https://github.com/${RELEASE_REPO}/releases/download/${version_tag#v}/${asset_name}"
        fi
    }
}

# 安装基础依赖
install_base() {
    echo "Installing base dependencies..."
    
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
    
    echo "Base dependencies installation complete"
}

# 检查IPv6支持
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

# 生成配置文件
generate_config_file() {
    echo "Generating complete configuration file..."
    
    if [[ ! -d /etc/ad2nx ]]; then
        mkdir -p /etc/ad2nx
    fi
    
    local ipv6_support=$(check_ipv6_support)
    local listen_ip="0.0.0.0"
    [[ $ipv6_support -eq 1 ]] && listen_ip="::"
    
    # 生成节点配置（根据核心类型）
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
                \"Email\": \"ad2nx@github.com\",
                \"Provider\": \"cloudflare\",
                \"DNSEnv\": {\"EnvName\": \"env1\"}
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
                \"Email\": \"ad2nx@github.com\",
                \"Provider\": \"cloudflare\",
                \"DNSEnv\": {\"EnvName\": \"env1\"}
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
            \"ListenIP\": \"\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"MinReportTraffic\": 0,
            \"CertConfig\": {
                \"CertMode\": \"$CERT_MODE\",
                \"RejectUnknownSni\": false,
                \"CertDomain\": \"$CERT_DOMAIN\",
                \"CertFile\": \"/etc/ad2nx/fullchain.cer\",
                \"KeyFile\": \"/etc/ad2nx/cert.key\",
                \"Email\": \"ad2nx@github.com\",
                \"Provider\": \"cloudflare\",
                \"DNSEnv\": {\"EnvName\": \"env1\"}
            }
        }"
    fi
    
    # 初始化核心配置
    local cores_config="["
    [[ "$CORE_TYPE" == "xray" ]] && cores_config+="{\"Type\":\"xray\",\"Log\":{\"Level\":\"error\"},\"OutboundConfigPath\":\"/etc/ad2nx/custom_outbound.json\",\"RouteConfigPath\":\"/etc/ad2nx/route.json\"},"
    [[ "$CORE_TYPE" == "sing" ]] && cores_config+="{\"Type\":\"sing\",\"Log\":{\"Level\":\"error\"},\"OriginalPath\":\"/etc/ad2nx/sing_origin.json\"},"
    [[ "$CORE_TYPE" == "hysteria2" ]] && cores_config+="{\"Type\":\"hysteria2\",\"Log\":{\"Level\":\"error\"}},"
    cores_config="${cores_config%,}]"
    
    cd /etc/ad2nx
    [[ -f config.json ]] && mv config.json config.json.bak
    
    # 生成config.json
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
    
    # 生成route.json
    cat > /etc/ad2nx/route.json <<'ROUTEEOF'
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": ["geoip:private"]
        },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap)(.baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
ROUTEEOF
    
    # 生成custom_outbound.json
    cat > /etc/ad2nx/custom_outbound.json <<'CUSTOMEOF'
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {"domainStrategy": "UseIPv4v6"}
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {"domainStrategy": "UseIPv6"}
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
CUSTOMEOF
    
    # singbox特定配置
    if [ "$CORE_TYPE" = "sing" ]; then
        local dnsstrategy="ipv4_only"
        [[ $ipv6_support -eq 1 ]] && dnsstrategy="prefer_ipv4"
        cat > /etc/ad2nx/sing_origin.json <<'SINGEOF'
{
    "dns": {
        "servers": [
            {
                "tag": "cf",
                "address": "1.1.1.1"
            }
        ],
        "strategy": "prefer_ipv4"
    },
    "outbounds": [
        {
            "tag": "direct",
            "type": "direct",
            "domain_resolver": {
                "server": "cf",
                "strategy": "prefer_ipv4"
            }
        },
        {
            "type": "block",
            "tag": "block"
        }
    ],
    "route": {
        "rules": [
            {
                "ip_is_private": true,
                "outbound": "block"
            },
            {
                "domain_regex": [
                    "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                    "(.+.|^)(360|so).(cn|com)",
                    "(Subject|HELO|SMTP)",
                    "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                    "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                    "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                    "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                    "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                    "(.+.|^)(360).(cn|com|net)",
                    "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                    "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                    "(.*.||)(netvigator|torproject).(com|cn|net|org)",
                    "(..||)(visa|mycard|gash|beanfun|bank).",
                    "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                    "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                    "(.*.||)(mycard).(com|tw)",
                    "(.*.||)(gash).(com|tw)",
                    "(.bank.)",
                    "(.*.||)(pincong).(rocks)",
                    "(.*.||)(taobao).(com)",
                    "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                    "(flows|miaoko).(pages).(dev)"
                ],
                "outbound": "block"
            },
            {
                "outbound": "direct",
                "network": [
                    "udp",
                    "tcp"
                ]
            }
        ]
    },
    "experimental": {
        "cache_file": {
            "enabled": true
        }
    }
}
SINGEOF
    fi
    
    # Hysteria2配置
    [[ "$CORE_TYPE" == "hysteria2" ]] && cat > /etc/ad2nx/hy2config.yaml <<'HY2EOF'
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
masquerade:
  type: 404
HY2EOF
    
    echo "Configuration file generation complete"
}

# 安装ad2nx
install_ad2nx() {
    echo "Installing ad2nx..."
    
    # 检查并卸载现有版本
    uninstall_if_exists

    mkdir -p /usr/local/ad2nx/
    cd /usr/local/ad2nx/

    # 获取最新版本
    echo "Fetching latest version information..."
    local release_info=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/latest")
    
    if [[ -z "$release_info" ]]; then
        echo "ERROR: Failed to fetch version information: Cannot connect to GitHub API"
        echo "Please check network connection or GitHub API access"
        exit 1
    fi
    
    local last_version=$(echo "$release_info" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$last_version" ]]; then
        echo "ERROR: Failed to get version: Cannot parse version number"
        echo "API response:"
        echo "$release_info" | head -n 20
        exit 1
    fi
    
    echo "Detected latest version: ${last_version}"
    
    echo "Downloading ad2nx..."
    github_release_download_zip "${last_version}" "/usr/local/ad2nx/ad2nx-linux.zip"
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to download ad2nx"
        exit 1
    fi

    unzip ad2nx-linux.zip >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Extraction failed"
        exit 1
    fi

    rm ad2nx-linux.zip -f
    chmod +x ad2nx
    mkdir -p /etc/ad2nx/
    cp geoip.dat /etc/ad2nx/
    cp geosite.dat /etc/ad2nx/

    # 安装systemd服务
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/ad2nx -f
        cat <<'INITRC' > /etc/init.d/ad2nx
#!/sbin/openrc-run

name="ad2nx"
description="ad2nx"

command="/usr/local/ad2nx/ad2nx"
command_args="server"
command_user="root"

pidfile="/run/ad2nx.pid"
command_background="yes"

depend() {
        need net
}
INITRC
        chmod +x /etc/init.d/ad2nx
        rc-update add ad2nx default
    else
        rm /etc/systemd/system/ad2nx.service -f
        cat <<'SYSTEMD' > /etc/systemd/system/ad2nx.service
[Unit]
Description=ad2nx Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/ad2nx/
ExecStart=/usr/local/ad2nx/ad2nx server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
    fi

    # 复制配置文件（如果不存在）
    if [[ ! -f /etc/ad2nx/config.json ]]; then
        cp config.json /etc/ad2nx/ 2>/dev/null || true
    fi
    
    if [[ ! -f /etc/ad2nx/dns.json ]]; then
        cp dns.json /etc/ad2nx/ 2>/dev/null || true
    fi
    
    if [[ ! -f /etc/ad2nx/route.json ]]; then
        cp route.json /etc/ad2nx/ 2>/dev/null || true
    fi

    # 下载管理脚本
    github_contents_download "ad2nx.sh" "/usr/bin/ad2nx"
    chmod +x /usr/bin/ad2nx

    cd "$cur_dir"
    
    echo "ad2nx installation complete"
}

# 启动服务
start_service() {
    echo "Starting service..."
    
    if [[ x"${release}" == x"alpine" ]]; then
        service ad2nx start || {
            echo "ERROR: Service startup failed"
            return 1
        }
    else
        systemctl enable ad2nx || echo "WARNING: Unable to set auto-start on boot"
        systemctl start ad2nx || {
            echo "ERROR: Service startup failed"
            return 1
        }
    fi
    
    sleep 2
    
    if [[ x"${release}" == x"alpine" ]]; then
        if service ad2nx status 2>/dev/null | grep -q "started"; then
            echo "Service startup successful"
            return 0
        fi
    else
        if systemctl is-active --quiet ad2nx 2>/dev/null; then
            echo "Service startup successful"
            return 0
        fi
    fi
    
    echo "Service startup may have failed. Please use 'ad2nx log' to check logs"
    return 1
}

# 主流程
main() {
    echo "========= ad2nx Auto-installation Script ========="
    echo "Performing environment checks..."
    echo ""
    
    check_root
    init_variables
    check_required_env
    check_system
    check_arch
    
    echo "========= Starting auto-installation process ========="
    echo "API_HOST: ${API_HOST}"
    echo "NODE_ID: ${NODE_ID}"
    echo "CORE_TYPE: ${CORE_TYPE}"
    echo "NODE_TYPE: ${NODE_TYPE}"
    echo "IF_REGISTER: ${IF_REGISTER}"
    echo "IF_GENERATE: ${IF_GENERATE}"
    echo ""
    
    install_base
    install_ad2nx
    
    if [[ "${IF_GENERATE}" == [Yy] ]]; then
        generate_config_file
    fi
    
    start_service
    
    echo ""
    echo "========= Installation Complete ========="
    echo "Management command: ad2nx"
    echo "View logs: ad2nx log"
    echo "Restart service: ad2nx restart"
    echo "Configuration file: /etc/ad2nx/config.json"
    echo "========================================"
}

main
