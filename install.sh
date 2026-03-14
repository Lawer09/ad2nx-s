#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

RELEASE_REPO="${RELEASE_REPO:-Lawer09/ad2nx}"
SCRIPT_REPO="${SCRIPT_REPO:-Lawer09/ad2nx-s}"
SCRIPT_BRANCH="${SCRIPT_BRANCH:-master}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
GITHUB_RAW_BASE="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com}"

github_api_get() {
    local url="$1"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
        curl -Ls -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}"
    else
        curl -Ls "${url}"
    fi
}

github_contents_download() {
    local file_path="$1"
    local output_path="$2"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
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

    if [[ -n "${GITHUB_TOKEN}" ]]; then
        local release_json asset_api_url assets_list
        release_json=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/tags/${version_tag}")
        if echo "${release_json}" | grep -q '"message": "Not Found"'; then
            if [[ "${version_tag}" != v* ]]; then
                release_json=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/tags/v${version_tag}")
            else
                release_json=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/tags/${version_tag#v}")
            fi
        fi

        if echo "${release_json}" | grep -q '"message": "Not Found"'; then
            echo -e "${red}下载 ad2nx 失败：未找到 Release tag ${version_tag}（仓库：${RELEASE_REPO}）${plain}"
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
            assets_list=$(echo "${release_json}" | awk -F'"' '$0 ~ /"name":/ {print $4}' | tr '\n' ' ')
            echo -e "${red}下载 ad2nx 失败：未找到发行版附件 ${asset_name}${plain}"
            if [[ -n "${assets_list}" ]]; then
                echo -e "${yellow}该 Release 当前包含附件：${assets_list}${plain}"
            fi
            exit 1
        fi

        curl -fL --retry 3 --retry-delay 1 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/octet-stream" \
            "${asset_api_url}" \
            -o "${output_path}"
        return $?
    fi

    wget --no-check-certificate -N --progress=bar -O "${output_path}" "https://github.com/${RELEASE_REPO}/releases/download/${version_tag}/${asset_name}"
    if [[ $? -ne 0 ]]; then
        if [[ "${version_tag}" != v* ]]; then
            wget --no-check-certificate -N --progress=bar -O "${output_path}" "https://github.com/${RELEASE_REPO}/releases/download/v${version_tag}/${asset_name}"
        else
            wget --no-check-certificate -N --progress=bar -O "${output_path}" "https://github.com/${RELEASE_REPO}/releases/download/${version_tag#v}/${asset_name}"
        fi
        return $?
    fi
}

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
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
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
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
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/ad2nx/ad2nx ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service ad2nx status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status ad2nx | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

install_ad2nx() {
    if [[ -e /usr/local/ad2nx/ ]]; then
        rm -rf /usr/local/ad2nx/
    fi

    mkdir /usr/local/ad2nx/ -p
    cd /usr/local/ad2nx/

    if  [ $# == 0 ] ;then
        last_version=$(github_api_get "${GITHUB_API_BASE}/repos/${RELEASE_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 ad2nx 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 ad2nx 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 ad2nx 最新版本：${last_version}，开始安装"
        github_release_download_zip "${last_version}" "/usr/local/ad2nx/ad2nx-linux.zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 ad2nx 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        echo -e "开始安装 ad2nx $1"
        github_release_download_zip "${last_version}" "/usr/local/ad2nx/ad2nx-linux.zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 ad2nx $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip ad2nx-linux.zip >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${red}解压失败：/usr/local/ad2nx/ad2nx-linux.zip${plain}"
        exit 1
    fi

    rm ad2nx-linux.zip -f
    chmod +x ad2nx
    mkdir /etc/ad2nx/ -p
    cp geoip.dat /etc/ad2nx/
    cp geosite.dat /etc/ad2nx/

    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/ad2nx -f
        cat <<EOF > /etc/init.d/ad2nx
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
EOF
        chmod +x /etc/init.d/ad2nx
        rc-update add ad2nx default
        echo -e "${green}ad2nx ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/ad2nx.service -f
        cat <<EOF > /etc/systemd/system/ad2nx.service
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
EOF
        systemctl daemon-reload
        systemctl stop ad2nx
        systemctl enable ad2nx
        echo -e "${green}ad2nx ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/ad2nx/config.json ]]; then
        cp config.json /etc/ad2nx/
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service ad2nx start
        else
            systemctl start ad2nx
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}ad2nx 重启成功${plain}"
        else
            echo -e "${red}ad2nx 可能启动失败，请稍后使用 ad2nx log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/ad2nx-project/ad2nx/wiki${plain}"
        fi
        first_install=false
    fi

    if [[ ! -f /etc/ad2nx/dns.json ]]; then
        cp dns.json /etc/ad2nx/
    fi
    if [[ ! -f /etc/ad2nx/route.json ]]; then
        cp route.json /etc/ad2nx/
    fi
    if [[ ! -f /etc/ad2nx/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/ad2nx/
    fi
    if [[ ! -f /etc/ad2nx/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/ad2nx/
    fi
    github_contents_download "ad2nx.sh" "/usr/bin/ad2nx"
    chmod +x /usr/bin/ad2nx
    if [ ! -L /usr/bin/ad2nx ]; then
        ln -s /usr/bin/ad2nx /usr/bin/ad2nx
        chmod +x /usr/bin/ad2nx
    fi
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "ad2nx 管理脚本使用方法 (大小写不敏感): "
    echo "------------------------------------------"
    echo "ad2nx              - 显示管理菜单 (功能更多)"
    echo "ad2nx start        - 启动 ad2nx"
    echo "ad2nx stop         - 停止 ad2nx"
    echo "ad2nx restart      - 重启 ad2nx"
    echo "ad2nx status       - 查看 ad2nx 状态"
    echo "ad2nx enable       - 设置 ad2nx 开机自启"
    echo "ad2nx disable      - 取消 ad2nx 开机自启"
    echo "ad2nx log          - 查看 ad2nx 日志"
    echo "ad2nx x25519       - 生成 x25519 密钥"
    echo "ad2nx generate     - 生成 ad2nx 配置文件"
    echo "ad2nx update       - 更新 ad2nx"
    echo "ad2nx update x.x.x - 更新 ad2nx 指定版本"
    echo "ad2nx install      - 安装 ad2nx"
    echo "ad2nx uninstall    - 卸载 ad2nx"
    echo "ad2nx version      - 查看 ad2nx 版本"
    echo "------------------------------------------"
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装ad2nx,是否自动直接生成配置文件？(y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            github_contents_download "initconfig.sh" "./initconfig.sh"
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_ad2nx $1
