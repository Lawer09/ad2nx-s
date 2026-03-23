#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/8] 安装依赖..."
apt-get update -y
apt-get install -y curl ca-certificates python3 jq

echo "[2/8] 安装 sing-box..."
curl -fsSL https://sing-box.app/install.sh | sh

echo "[3/8] 创建目录..."
mkdir -p /etc/sing-box
chmod 755 /etc/sing-box

echo "[4/8] 生成 Reality 密钥对..."
KEY_JSON="$(python3 - <<'PY'
import json
import os
import secrets
import subprocess
import uuid

def parse_keypair(output: str) -> tuple[str, str]:
    priv = ""
    pub = ""
    for line in output.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k = k.strip().lower()
        v = v.strip()
        if k == "privatekey":
            priv = v
        elif k == "publickey":
            pub = v
    return priv, pub

out = subprocess.check_output(["sing-box", "generate", "reality-keypair"], text=True)
priv, pub = parse_keypair(out)
if not priv or not pub:
    raise SystemExit("Reality 密钥生成失败")

uuid_ab = (os.environ.get("UUID_AB") or "").strip() or str(uuid.uuid4())
short_id = (os.environ.get("SHORT_ID") or "").strip() or secrets.token_hex(8)
handshake_server = (os.environ.get("REALITY_SERVER_NAME") or "").strip() or "www.apple.com"

print(json.dumps({
    "uuid_ab": uuid_ab,
    "short_id": short_id,
    "handshake_server": handshake_server,
    "private_key": priv,
    "public_key": pub,
}, ensure_ascii=False))
PY
)"

echo "[5/8] 写入环境文件..."
python3 - <<PY
import json
data = json.loads(r'''${KEY_JSON}''')
content = f"""# ===== 可改参数 =====
SB_LISTEN=0.0.0.0
SB_LISTEN_PORT=443
SB_UUID_AB={data["uuid_ab"]}
SB_REALITY_PRIVATE_KEY={data["private_key"]}
SB_REALITY_PUBLIC_KEY={data["public_key"]}
SB_SHORT_ID={data["short_id"]}
SB_HANDSHAKE_SERVER={data["handshake_server"]}
SB_HANDSHAKE_PORT=443
SB_LOG_LEVEL=info
"""
with open("/etc/sing-box/sb.env", "w", encoding="utf-8") as f:
    f.write(content)
PY
chmod 600 /etc/sing-box/sb.env

echo "[6/8] 生成配置文件..."
python3 - <<'PY'
import json
import os
import re

def load_env(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f.read().splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

env = load_env("/etc/sing-box/sb.env")
listen = env.get("SB_LISTEN", "0.0.0.0")
listen_port = int(env.get("SB_LISTEN_PORT", "443"))
uuid_ab = env["SB_UUID_AB"]
private_key = env["SB_REALITY_PRIVATE_KEY"]
public_key = env["SB_REALITY_PUBLIC_KEY"]
short_id = env["SB_SHORT_ID"]
handshake_server = env.get("SB_HANDSHAKE_SERVER", "www.apple.com")
handshake_port = int(env.get("SB_HANDSHAKE_PORT", "443"))
log_level = env.get("SB_LOG_LEVEL", "info")

config = {
    "log": {"level": log_level, "timestamp": True},
    "inbounds": [
        {
            "type": "vless",
            "tag": "from-a",
            "listen": listen,
            "listen_port": listen_port,
            "users": [{"name": "a-to-b", "uuid": uuid_ab}],
            "tls": {
                "enabled": True,
                "server_name": handshake_server,
                "reality": {
                    "enabled": True,
                    "handshake": {"server": handshake_server, "server_port": handshake_port},
                    "private_key": private_key,
                    "short_id": [short_id],
                },
            },
        }
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
    "route": {"final": "direct", "auto_detect_interface": True},
}

with open("/etc/sing-box/config.json", "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod("/etc/sing-box/config.json", 0o600)

print("[+] 已生成 /etc/sing-box/config.json")
print("[+] Reality 公钥（给入口节点 outbound 用）:", public_key)
print("[+] Reality short_id:", short_id)
print("[+] A->B UUID:", uuid_ab)
PY

echo "[7/8] 写入工具脚本..."
cat > /usr/local/bin/sb-render <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import os

def load_env(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f.read().splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

env = load_env("/etc/sing-box/sb.env")
listen = env.get("SB_LISTEN", "0.0.0.0")
listen_port = int(env.get("SB_LISTEN_PORT", "443"))
uuid_ab = env["SB_UUID_AB"]
private_key = env["SB_REALITY_PRIVATE_KEY"]
short_id = env["SB_SHORT_ID"]
handshake_server = env.get("SB_HANDSHAKE_SERVER", "www.apple.com")
handshake_port = int(env.get("SB_HANDSHAKE_PORT", "443"))
log_level = env.get("SB_LOG_LEVEL", "info")

config = {
    "log": {"level": log_level, "timestamp": True},
    "inbounds": [
        {
            "type": "vless",
            "tag": "from-a",
            "listen": listen,
            "listen_port": listen_port,
            "users": [{"name": "a-to-b", "uuid": uuid_ab}],
            "tls": {
                "enabled": True,
                "server_name": handshake_server,
                "reality": {
                    "enabled": True,
                    "handshake": {"server": handshake_server, "server_port": handshake_port},
                    "private_key": private_key,
                    "short_id": [short_id],
                },
            },
        }
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
    "route": {"final": "direct", "auto_detect_interface": True},
}

with open("/etc/sing-box/config.json", "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod("/etc/sing-box/config.json", 0o600)
print("[+] 已生成 /etc/sing-box/config.json")
PY
chmod 600 /etc/sing-box/config.json
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
rm -f /etc/sing-box/config.template.json
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
