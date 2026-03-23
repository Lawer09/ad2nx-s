#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
节点管理工具 - 添加/更新 VLess Reality 节点
依赖: requests, cryptography
自动安装依赖（需用户确认）
"""

import sys
import json
import base64
import secrets
import subprocess
import socket
import os
import getpass
from typing import Dict, List, Any, Optional, Tuple

# 尝试导入依赖，缺失则提示安装
try:
    import requests
except ImportError:
    print("缺少 requests 库，是否安装？(y/n)")
    if input().lower() == 'y':
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--user', 'requests'])
        import requests
    else:
        sys.exit(1)

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption
except ImportError:
    print("缺少 cryptography 库，是否安装？(y/n)")
    if input().lower() == 'y':
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--user', 'cryptography'])
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption
    else:
        sys.exit(1)


def get_local_ip() -> str:
    """获取本机内网 IP（默认路由出口）"""
    try:
        # 使用 socket 连接外部地址获取本地 IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        # 回退到 hostname -I
        try:
            output = subprocess.check_output(['hostname', '-I'], text=True)
            ip = output.split()[0]
            return ip
        except Exception:
            return '127.0.0.1'


def get_public_ip() -> str:
    """通过 ifconfig.me 获取公网 IP"""
    try:
        resp = requests.get('https://ifconfig.me', timeout=5)
        if resp.status_code == 200:
            return resp.text.strip()
    except Exception:
        pass
    return ''


def select_ip() -> str:
    """交互式选择 IP 地址"""
    print("\n请选择本机地址类型：")
    print("1) 内网IP")
    print("2) 公网IP")
    print("3) 手动输入")
    choice = input("请输入选项 (1/2/3): ").strip()
    if choice == '1':
        ip = get_local_ip()
        if ip:
            print(f"使用内网IP: {ip}")
            return ip
        else:
            print("无法获取内网IP，请手动输入")
            return input("请输入本机地址: ").strip()
    elif choice == '2':
        ip = get_public_ip()
        if ip:
            print(f"使用公网IP: {ip}")
            return ip
        else:
            print("无法获取公网IP，请检查网络")
            return input("请手动输入本机地址: ").strip()
    elif choice == '3':
        return input("请输入本机地址: ").strip()
    else:
        print("无效选项，请重新选择")
        return select_ip()


def generate_keys() -> Tuple[str, str]:
    """生成 X25519 密钥对，返回 (私钥 base64, 公钥 base64)"""
    priv_key = X25519PrivateKey.generate()
    priv_bytes = priv_key.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption()
    )
    pub_bytes = priv_key.public_key().public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw
    )
    return (base64.b64encode(priv_bytes).decode(),
            base64.b64encode(pub_bytes).decode())


def generate_shortid() -> str:
    """生成 8 位十六进制 shortid"""
    return secrets.token_hex(4)


def login(base_url: str, email: str, password: str) -> Optional[str]:
    """登录并返回 auth_data (Bearer token)"""
    url = f"{base_url}/api/v2/passport/auth/login"
    payload = {"email": email, "password": password}
    try:
        resp = requests.post(url, json=payload, timeout=10)
        data = resp.json()
        if data.get('status') == 'success':
            auth_data = data['data']['auth_data']
            is_admin = data['data'].get('is_admin', False)
            if not is_admin:
                print("错误：非管理员账号")
                return None
            return auth_data
        else:
            print(f"登录失败：{data.get('message')}")
            return None
    except Exception as e:
        print(f"登录请求异常：{e}")
        return None


def get_nodes(base_url: str, site_id: str, token: str) -> List[Dict[str, Any]]:
    """获取所有节点列表"""
    url = f"{base_url}/api/v2/{site_id}/server/manage/getNodes"
    headers = {"authorization": f"Bearer {token}"}
    try:
        resp = requests.get(url, headers=headers, timeout=10)
        data = resp.json()
        if data.get('status') == 'success':
            return data.get('data', [])
        else:
            print(f"获取节点列表失败：{data.get('message')}")
            return []
    except Exception as e:
        print(f"请求节点列表异常：{e}")
        return []


def save_node(base_url: str, site_id: str, token: str, node_data: Dict[str, Any]) -> bool:
    """保存节点（创建或更新）"""
    url = f"{base_url}/api/v2/{site_id}/server/manage/save"
    headers = {
        "Content-Type": "application/json",
        "authorization": f"Bearer {token}"
    }
    try:
        resp = requests.post(url, json=node_data, headers=headers, timeout=10)
        result = resp.json()
        if result.get('status') == 'success':
            print("节点保存成功")
            print(json.dumps(result, indent=2, ensure_ascii=False))
            return True
        else:
            print(f"保存节点失败：{result.get('message')}")
            return False
    except Exception as e:
        print(f"保存节点请求异常：{e}")
        return False


def merge_node_config(existing: Dict[str, Any], new_fields: Dict[str, Any]) -> Dict[str, Any]:
    """合并现有节点配置和新字段，深度合并 protocol_settings"""
    merged = existing.copy()
    # 更新顶层字段
    for key, value in new_fields.items():
        if key == 'protocol_settings':
            # 深度合并 protocol_settings
            if 'protocol_settings' not in merged:
                merged['protocol_settings'] = {}
            merged['protocol_settings'] = merge_deep(merged['protocol_settings'], value)
        else:
            merged[key] = value
    return merged


def merge_deep(base: Dict, update: Dict) -> Dict:
    """递归合并两个字典"""
    for key, value in update.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            base[key] = merge_deep(base[key], value)
        else:
            base[key] = value
    return base


def _update_env_file(file_path: str, env_vars: Dict[str, str]) -> bool:
    try:
        existing_lines: List[str] = []
        if os.path.exists(file_path):
            with open(file_path, "r", encoding="utf-8") as f:
                existing_lines = f.read().splitlines()

        keys = set(env_vars.keys())
        kept_lines: List[str] = []
        for line in existing_lines:
            stripped = line.strip()
            if stripped.startswith("export "):
                for k in keys:
                    if stripped.startswith(f"export {k}="):
                        break
                else:
                    kept_lines.append(line)
            else:
                kept_lines.append(line)

        for k, v in env_vars.items():
            safe_v = v.replace("\\", "\\\\").replace('"', '\\"')
            kept_lines.append(f'export {k}="{safe_v}"')

        content = "\n".join(kept_lines).rstrip("\n") + "\n"
        parent = os.path.dirname(file_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    except Exception:
        return False


def persist_env_vars(env_vars: Dict[str, str]) -> None:
    for k, v in env_vars.items():
        os.environ[k] = v

    if os.name == "nt":
        for k, v in env_vars.items():
            try:
                subprocess.run(["setx", k, v], check=False, capture_output=True, text=True)
            except Exception:
                pass
        print("已尝试写入 Windows 用户环境变量（setx）。")
        for k, v in env_vars.items():
            print(f"{k}={v}")
        return

    targets: List[str] = []
    try:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            targets.append("/etc/profile.d/ad2nx_env.sh")
    except Exception:
        pass
    targets.append("/etc/ad2nx/ad2nx_env.sh")
    targets.append(os.path.expanduser("~/.bashrc"))

    written = False
    for path in targets:
        if _update_env_file(path, env_vars):
            print(f"已写入环境变量文件: {path}")
            written = True
            break

    if not written:
        print("写入环境变量文件失败，可手动执行以下命令：")
        for k, v in env_vars.items():
            print(f'export {k}="{v}"')


def _get_env_value(keys: List[str]) -> Tuple[Optional[str], Optional[str]]:
    for k in keys:
        v = os.environ.get(k)
        if v is not None:
            v = v.strip()
        if v:
            return k, v
    return None, None


def _prompt_or_env(prompt: str, env_keys: List[str], secret: bool = False) -> str:
    key, value = _get_env_value(env_keys)
    if value is not None:
        if secret:
            print(f"使用环境变量{key}")
        else:
            print(f"使用环境变量{key}: {value}")
        return value
    while True:
        if secret:
            v = getpass.getpass(prompt).strip()
        else:
            v = input(prompt).strip()
        if v:
            return v


def main():
    print("=== 节点注册 ===\n")

    # 1. 输入站点信息
    base_url = _prompt_or_env("请输入中心站点（例如 https://example.com）: ", ["API_HOST", "BASE_URL"])
    site_id = _prompt_or_env("请输入站点标识（例如 2d2d21）: ", ["SITE_ID"])
    base_url = base_url.rstrip("/")

    # 2. 输入管理员账户和密码
    email = _prompt_or_env("请输入管理员邮箱: ", ["ADMIN_EMAIL", "EMAIL"])
    password = _prompt_or_env("请输入管理员密码: ", ["ADMIN_PASSWORD", "PASSWORD"], secret=True)

    # 3. 登录
    print("\n正在登录...")
    token = login(base_url, email, password)
    if not token:
        sys.exit(1)
    print("登录成功\n")

    # 4. 输入节点参数
    node_name = _prompt_or_env("请输入节点名称: ", ["NODE_NAME"])
    port = _prompt_or_env("请输入连接端口（port）: ", ["NODE_PORT", "PORT"])
    server_port = _prompt_or_env("请输入服务端口（server_port）: ", ["NODE_SERVER_PORT", "SERVER_PORT"])
    server_name = _prompt_or_env("请输入伪装站点（server_name）: ", ["NODE_SERVER_NAME", "SERVER_NAME"])

    # 5. 选择 IP
    env_host_key, env_host_value = _get_env_value(["NODE_HOST", "HOST"])
    if env_host_value is not None:
        print(f"\n使用环境变量{env_host_key}: {env_host_value}")
        host = env_host_value
    else:
        host = select_ip()
    print()

    # 6. 生成密钥和 shortid
    print("正在生成 Reality 密钥对和 shortid...")
    private_key, public_key = generate_keys()
    shortid = generate_shortid()
    print(f"私钥: {private_key}")
    print(f"公钥: {public_key}")
    print(f"shortid: {shortid}\n")

    # 7. 获取现有节点列表
    nodes = get_nodes(base_url, site_id, token)
    print(f"获取到 {len(nodes)} 个节点\n")

    # 8. 查找与所选 IP 匹配的节点
    matched_node = None
    for node in nodes:
        if node.get('host') == host:
            matched_node = node
            break

    # 9. 构造新配置
    # 新字段（要更新的部分）
    new_fields = {
        'name': node_name,
        'host': host,
        'port': port,
        'server_port': server_port,
        'protocol_settings': {
            'reality_settings': {
                'server_name': server_name,
                'public_key': public_key,
                'private_key': private_key,
                'short_id': shortid
            }
        }
    }

    if matched_node:
        print(f"找到 host 为 {host} 的现有节点（ID: {matched_node.get('id')}），将基于此配置更新。")
        # 基于现有节点配置进行合并
        final_config = merge_node_config(matched_node, new_fields)
    else:
        print(f"未找到 host 为 {host} 的节点，将创建新节点。")
        # 创建新节点，使用默认值
        final_config = {
            "id": None,
            "specific_key": None,
            "code": "",
            "show": False,
            "name": node_name,
            "rate": "1",
            "rate_time_enable": False,
            "rate_time_ranges": [],
            "tags": [],
            "excludes": [],
            "ips": [],
            "group_ids": [],
            "host": host,
            "port": port,
            "server_port": server_port,
            "parent_id": "0",
            "route_ids": [],
            "protocol_settings": {
                "tls": 2,
                "tls_settings": {
                    "server_name": "",
                    "allow_insecure": False,
                    "cert_mode": "http",
                    "cert_file": "",
                    "key_file": "",
                    "dns_provider": "",
                    "dns_env": ""
                },
                "reality_settings": {
                    "server_port": 443,
                    "server_name": server_name,
                    "allow_insecure": False,
                    "public_key": public_key,
                    "private_key": private_key,
                    "short_id": shortid
                },
                "network": "tcp",
                "network_settings": {},
                "flow": "xtls-rprx-vision"
            },
            "listen_address": "",
            "type": "vless"
        }

    # 10. 保存节点
    print("\n正在保存节点...")
    if save_node(base_url, site_id, token, final_config):
        print("\n正在重新拉取节点信息...")
        refreshed_nodes = get_nodes(base_url, site_id, token)
        matched_after_save = None
        for node in refreshed_nodes:
            if node.get("host") == host:
                matched_after_save = node
                break
        node_id_value = ""
        if matched_after_save is not None:
            node_id_value = str(matched_after_save.get("id") or "")
        if node_id_value:
            persist_env_vars(
                {
                    "NODE_ID": node_id_value,
                    "API_HOST": base_url,
                    "NODE_TYPE": "vless",
                    "NODE_TYPE2": "reality",
                }
            )
        else:
            print(f"未在 data 中找到 host={host} 的节点，无法写入 NODE_ID。")
        print("操作完成")
    else:
        print("保存失败")
        sys.exit(1)


if __name__ == "__main__":
    main()
