#!/bin/bash
# 仅通过环境变量自动安装脚本（无人工交互）
# 使用示例：
# export API_HOST="api.example.com"
# export API_KEY="your-api-key"
# export NODE_ID="1"
# export CORE_TYPE="sing"  # 1=xray, 2=singbox, 3=hysteria2
# export NODE_TYPE="vless"  # 1=shadowsocks, 2=vless, 3=vmess, 4=hysteria, 5=hysteria2, 6=trojan, 7=tuic, 8=anytls
# bash auto-install.sh

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 必需的环境变量检查
check_required_env() {
    local missing_vars=()
    
    [[ -z "${API_HOST:-}" ]] && missing_vars+=("API_HOST")
    [[ -z "${API_KEY:-}" ]] && missing_vars+=("API_KEY")
    [[ -z "${NODE_ID:-}" ]] && missing_vars+=("NODE_ID")
    [[ -z "${CORE_TYPE:-}" ]] && missing_vars+=("CORE_TYPE")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo -e "${red}错误：缺少必需的环境变量：${missing_vars[*]}${plain}"
        echo -e "${yellow}必需的环境变量：${plain}"
        echo "  API_HOST      - API 服务器地址"
        echo "  API_KEY       - API 密钥"
        echo "  NODE_ID       - 节点 ID（数字）"
        echo "  CORE_TYPE     - 核心类型（1=xray, 2=singbox, 3=hysteria2）"
        exit 1
    fi
}

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
    
    echo -e "${green}系统：${release}${plain}"
}

# 检查架构
check_arch() {
    arch=$(uname -m)
    
    if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
        arch="64"
    elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
        arch="arm64-v8a"
    elif [[ $arch == "s390x" ]]; then
        arch="s390x"
    else
        arch="64"
    fi
    
    echo -e "${green}架构：${arch}${plain}"
}

# 初始化变量
init_variables() {
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
    CORE_TYPE="${CORE_TYPE:-singbox}"  # 默认singbox
    
    # 证书配置
    CERT_MODE="${CERT_MODE:-none}"
    CERT_DOMAIN="${CERT_DOMAIN:-example.com}"
    
    # 其他配置
    CONTINUE_PROMPT="${CONTINUE_PROMPT:-y}"
    IF_GENERATE="${IF_GENERATE:-y}"
    IF_REGISTER="${IF_REGISTER:-n}"
    
    echo -e "${green}环境变量已初始化${plain}"
}

# 卸载现有的ad2nx（如果存在）
uninstall_if_exists() {
    if [[ -f /usr/local/ad2nx/ad2nx ]]; then
        echo -e "${yellow}检测到已安装的 ad2nx，正在卸载...${plain}"
        
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
        
        echo -e "${green}卸载完成${plain}"
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
    echo -e "${green}正在安装基础依赖...${plain}"
    
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
    
    echo -e "${green}基础依赖安装完成${plain}"
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
    echo -e "${green}正在生成完整配置文件...${plain}"
    
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
    
    echo -e "${green}配置文件生成完成${plain}"
}

# 安装ad2nx
install_ad2nx() {
    echo -e "${green}正在安装ad2nx...${plain}"
    
    # 检查并卸载现有版本
    uninstall_if_exists

    mkdir -p /usr/local/ad2nx/
    cd /usr/local/ad2nx/

    # 获取最新版本
    local last_version=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ ! -n "$last_version" ]]; then
        echo -e "${red}获取版本失败${plain}"
        exit 1
    fi
    
    echo -e "${green}检测到最新版本：${last_version}${plain}"
    github_release_download_zip "${last_version}" "/usr/local/ad2nx/ad2nx-linux.zip"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载ad2nx失败${plain}"
        exit 1
    fi

    unzip ad2nx-linux.zip >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${red}解压失败${plain}"
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
    
    echo -e "${green}ad2nx 安装完成${plain}"
}

# 启动服务
start_service() {
    echo -e "${green}正在启动服务...${plain}"
    
    if [[ x"${release}" == x"alpine" ]]; then
        service ad2nx start
    else
        systemctl enable ad2nx
        systemctl start ad2nx
    fi
    
    sleep 2
    
    if [[ x"${release}" == x"alpine" ]]; then
        if service ad2nx status | grep -q "started"; then
            echo -e "${green}服务启动成功${plain}"
            return 0
        fi
    else
        if systemctl is-active --quiet ad2nx; then
            echo -e "${green}服务启动成功${plain}"
            return 0
        fi
    fi
    
    echo -e "${yellow}服务启动可能失败，请使用 ad2nx log 查看日志${plain}"
    return 1
}

# 主流程
main() {
    check_root
    init_variables
    check_required_env
    check_system
    check_arch
    
    echo -e "${green}========== 开始自动安装流程 ==========${plain}"
    echo -e "${green}API_HOST: ${API_HOST}${plain}"
    echo -e "${green}NODE_ID: ${NODE_ID}${plain}"
    echo -e "${green}CORE_TYPE: ${CORE_TYPE}${plain}"
    echo -e "${green}NODE_TYPE: ${NODE_TYPE}${plain}"
    echo -e "${green}IF_REGISTER: ${IF_REGISTER}${plain}"
    echo -e "${green}IF_GENERATE: ${IF_GENERATE}${plain}"
    echo ""
    
    install_base
    install_ad2nx
    
    if [[ "${IF_GENERATE}" == [Yy] ]]; then
        generate_config_file
    fi
    
    start_service
    
    echo -e ""
    echo -e "${green}========== 安装完成 ==========${plain}"
    echo -e "${green}管理命令：ad2nx${plain}"
    echo -e "${green}查看日志：ad2nx log${plain}"
    echo -e "${green}重启服务：ad2nx restart${plain}"
    echo -e "${green}配置文件：/etc/ad2nx/config.json${plain}"
    echo -e "${green}========================================${plain}"
}

main
