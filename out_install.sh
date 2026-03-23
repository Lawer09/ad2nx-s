#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/8] 安装依赖..."
apt-get update -y
apt-get install -y curl ca-certificates gettext-base jq

echo "[2/8] 安装 sing-box..."
curl -fsSL https://sing-box.app/install.sh | sh

echo "[3/8] 创建目录..."
mkdir -p /etc/sing-box
chmod 755 /etc/sing-box

echo "[4/8] 生成 Reality 密钥对..."
KEY_OUTPUT="$(sing-box generate reality-keypair)"
PRIVATE_KEY="$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')"
PUBLIC_KEY="$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2}')"

if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
  echo "Reality 密钥生成失败"
  exit 1
fi

echo "[5/8] 写入环境文件..."
cat > /etc/sing-box/sb.env <<EOF
# ===== 可改参数 =====
SB_LISTEN=0.0.0.0
SB_LISTEN_PORT=443
SB_UUID_AB=${UUID_AB:-11111111-1111-1111-1111-111111111111}
SB_REALITY_PRIVATE_KEY=${PRIVATE_KEY}
SB_REALITY_PUBLIC_KEY=${PUBLIC_KEY}
SB_SHORT_ID=${SHORT_ID:-3a871f92daeb197f}
SB_HANDSHAKE_SERVER=${REALITY_SERVER_NAME:-www.apple.com}
SB_HANDSHAKE_PORT=443
SB_LOG_LEVEL=info
EOF
chmod 600 /etc/sing-box/sb.env

echo "[6/8] 写入配置模板..."
cat > /etc/sing-box/config.template.json <<'EOF'
{
  "log": {
    "level": "${SB_LOG_LEVEL}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "from-a",
      "listen": "${SB_LISTEN}",
      "listen_port": ${SB_LISTEN_PORT},
      "users": [
        {
          "name": "a-to-b",
          "uuid": "${SB_UUID_AB}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SB_HANDSHAKE_SERVER}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SB_HANDSHAKE_SERVER}",
            "server_port": ${SB_HANDSHAKE_PORT}
          },
          "private_key": "${SB_REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SB_SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
chmod 600 /etc/sing-box/config.template.json

echo "[7/8] 写入工具脚本..."
cat > /usr/local/bin/sb-render <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -a
source /etc/sing-box/sb.env
set +a

envsubst < /etc/sing-box/config.template.json > /etc/sing-box/config.json
chmod 600 /etc/sing-box/config.json

echo "[+] 已生成 /etc/sing-box/config.json"
sing-box check -c /etc/sing-box/config.json
echo "[+] 配置校验通过"
EOF
chmod +x /usr/local/bin/sb-render

cat > /usr/local/bin/sb-show-env <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/sing-box/sb.env

cat <<EOT
当前可改参数如下：

SB_LISTEN               = ${SB_LISTEN}
SB_LISTEN_PORT          = ${SB_LISTEN_PORT}
SB_UUID_AB              = ${SB_UUID_AB}
SB_REALITY_PRIVATE_KEY  = ${SB_REALITY_PRIVATE_KEY}
SB_REALITY_PUBLIC_KEY   = ${SB_REALITY_PUBLIC_KEY}
SB_SHORT_ID             = ${SB_SHORT_ID}
SB_HANDSHAKE_SERVER     = ${SB_HANDSHAKE_SERVER}
SB_HANDSHAKE_PORT       = ${SB_HANDSHAKE_PORT}
SB_LOG_LEVEL            = ${SB_LOG_LEVEL}

说明：
- SB_UUID_AB            A -> B 专用 UUID
- SB_REALITY_PRIVATE_KEY  B 端 Reality 私钥
- SB_REALITY_PUBLIC_KEY   给 A 端 outbound 用的公钥
- SB_SHORT_ID             A/B 要一致
- SB_HANDSHAKE_SERVER     Reality 伪装握手域名
- SB_HANDSHAKE_PORT       Reality 伪装握手端口
EOT
EOF
chmod +x /usr/local/bin/sb-show-env

cat > /usr/local/bin/sb-restart <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/local/bin/sb-render
systemctl restart sing-box
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl --no-pager --full status sing-box
EOF
chmod +x /usr/local/bin/sb-restart

echo "[8/8] 渲染配置并启动服务..."
/usr/local/bin/sb-render
systemctl enable sing-box
systemctl restart sing-box

echo
echo "===== 安装完成 ====="
echo "查看当前参数："
echo "  sb-show-env"
echo
echo "修改参数："
echo "  nano /etc/sing-box/sb.env"
echo
echo "重生成配置："
echo "  sb-render"
echo
echo "重启服务："
echo "  sb-restart"
echo
echo "查看日志："
echo "  journalctl -u sing-box -f"