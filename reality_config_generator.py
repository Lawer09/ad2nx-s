#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VLESS + Reality 配置生成工具
自动生成 UUID、Reality 密钥和完整配置文件
"""

import json
import subprocess
import sys
import os
import argparse
from datetime import datetime
import uuid as uuid_module
import re


class VlessRealityGenerator:
    """VLESS + Reality 配置生成器"""
    
    def __init__(self, output_dir="/etc/ad2nx"):
        self.output_dir = output_dir
        self.config = {}
        self.reality_keys = {}
        self.vless_uuid = ""
    
    def generate_uuid(self):
        """生成 VLESS UUID"""
        try:
            # 尝试使用 xray uuid 命令
            result = subprocess.run(['xray', 'uuid'], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                self.vless_uuid = result.stdout.strip()
                return self.vless_uuid
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        
        # 使用 Python 内置的 uuid
        self.vless_uuid = str(uuid_module.uuid4())
        return self.vless_uuid
    
    def generate_reality_keys(self):
        """生成 Reality 密钥对"""
        try:
            result = subprocess.run(['xray', 'x25519'], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                output = result.stdout.strip()
                
                # 解析输出
                lines = output.split('\n')
                for line in lines:
                    if 'Private key:' in line:
                        self.reality_keys['private'] = line.split(':')[1].strip()
                    elif 'Public key:' in line:
                        self.reality_keys['public'] = line.split(':')[1].strip()
                
                if 'private' in self.reality_keys and 'public' in self.reality_keys:
                    return True
        except (subprocess.TimeoutExpired, FileNotFoundError):
            print("警告: 未找到 xray 命令，无法生成 Reality 密钥")
            print("请手动运行: xray x25519")
        
        return False
    
    def generate_config(self, template_file=None, **kwargs):
        """根据模板生成配置"""
        
        # 读取模板
        if template_file and os.path.exists(template_file):
            with open(template_file, 'r', encoding='utf-8') as f:
                self.config = json.load(f)
        else:
            self.config = self._get_default_template()
        
        # 替换参数
        self._replace_config_values(**kwargs)
        
        return self.config
    
    def _replace_config_values(self, **kwargs):
        """替换配置中的值"""
        
        # 替换 UUID
        uuid_val = kwargs.get('uuid') or self.vless_uuid
        if uuid_val and 'inbounds' in self.config:
            for inbound in self.config['inbounds']:
                if inbound.get('protocol') == 'vless' and 'settings' in inbound:
                    for client in inbound['settings'].get('clients', []):
                        if 'uuid' in kwargs or not client['id'] or 'here' in client['id']:
                            client['id'] = uuid_val
        
        # 替换 Reality 私钥
        private_key = kwargs.get('private_key') or self.reality_keys.get('private')
        if private_key and 'inbounds' in self.config:
            for inbound in self.config['inbounds']:
                if 'streamSettings' in inbound:
                    reality_settings = inbound['streamSettings'].get('realitySettings', {})
                    if 'privateKey' in reality_settings:
                        reality_settings['privateKey'] = private_key
        
        # 替换其他参数
        if 'dest' in kwargs:
            for inbound in self.config.get('inbounds', []):
                if 'streamSettings' in inbound:
                    reality_settings = inbound['streamSettings'].get('realitySettings', {})
                    if 'dest' in reality_settings:
                        reality_settings['dest'] = kwargs['dest']
        
        if 'server_names' in kwargs:
            for inbound in self.config.get('inbounds', []):
                if 'streamSettings' in inbound:
                    reality_settings = inbound['streamSettings'].get('realitySettings', {})
                    if 'serverNames' in reality_settings:
                        reality_settings['serverNames'] = kwargs['server_names']
        
        if 'fingerprint' in kwargs:
            for inbound in self.config.get('inbounds', []):
                if 'streamSettings' in inbound:
                    reality_settings = inbound['streamSettings'].get('realitySettings', {})
                    if 'fingerprint' in reality_settings:
                        reality_settings['fingerprint'] = kwargs['fingerprint']
        
        if 'port' in kwargs:
            for inbound in self.config.get('inbounds', []):
                if 'port' in inbound:
                    inbound['port'] = kwargs['port']
    
    def _get_default_template(self):
        """获取默认模板"""
        return {
            "log": {
                "level": "error",
                "output": ""
            },
            "inbounds": [
                {
                    "port": 443,
                    "protocol": "vless",
                    "settings": {
                        "clients": [
                            {
                                "id": self.vless_uuid,
                                "email": "user@example.com"
                            }
                        ],
                        "decryption": "none"
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": {
                            "show": False,
                            "dest": "www.google.com:443",
                            "xver": 0,
                            "serverNames": ["www.google.com", "google.com"],
                            "privateKey": self.reality_keys.get('private', ''),
                            "fingerprint": "chrome"
                        }
                    }
                }
            ],
            "outbounds": [
                {
                    "protocol": "freedom",
                    "tag": "direct"
                },
                {
                    "protocol": "blackhole",
                    "tag": "blocked"
                }
            ]
        }
    
    def save_config(self, filename=None):
        """保存配置文件"""
        if not filename:
            filename = os.path.join(self.output_dir, 'config.json')
        
        # 确保目录存在
        os.makedirs(os.path.dirname(filename), exist_ok=True)
        
        # 备份旧配置
        if os.path.exists(filename):
            backup_file = f"{filename}.bak.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            os.rename(filename, backup_file)
            print(f"✓ 已备份旧配置: {backup_file}")
        
        # 保存新配置
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(self.config, f, indent=2, ensure_ascii=False)
        
        print(f"✓ 配置已保存: {filename}")
        return filename
    
    def print_info(self):
        """打印生成的信息"""
        print("\n" + "="*50)
        print("VLESS + Reality 配置信息")
        print("="*50)
        
        print(f"\n【VLESS UUID】")
        print(f"  {self.vless_uuid}")
        
        if self.reality_keys.get('private'):
            print(f"\n【Reality 私钥 (服务器)】")
            print(f"  {self.reality_keys['private']}")
        
        if self.reality_keys.get('public'):
            print(f"\n【Reality 公钥 (客户端)】")
            print(f"  {self.reality_keys['public']}")
        
        if self.config and 'inbounds' in self.config:
            inbound = self.config['inbounds'][0]
            print(f"\n【配置详情】")
            print(f"  端口: {inbound.get('port', 443)}")
            print(f"  协议: {inbound.get('protocol', 'vless')}")
            
            if 'streamSettings' in inbound:
                reality = inbound['streamSettings'].get('realitySettings', {})
                print(f"  伪装目标: {reality.get('dest', 'N/A')}")
                print(f"  服务器名单: {', '.join(reality.get('serverNames', []))}")
                print(f"  指纹: {reality.get('fingerprint', 'N/A')}")
        
        print("\n" + "="*50 + "\n")
    
    def export_client_config(self, filename=None):
        """导出客户端配置"""
        if not filename:
            filename = os.path.join(self.output_dir, 'client-config.json')
        
        client_config = {
            "uuid": self.vless_uuid,
            "reality_public_key": self.reality_keys.get('public', ''),
            "server_ip": "YOUR_SERVER_IP",
            "port": 443,
            "fingerprint": "chrome",
            "server_names": ["www.google.com"],
            "short_id": ""
        }
        
        os.makedirs(os.path.dirname(filename), exist_ok=True)
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(client_config, f, indent=2, ensure_ascii=False)
        
        print(f"✓ 客户端配置已导出: {filename}")
        return filename


def main():
    parser = argparse.ArgumentParser(
        description='VLESS + Reality 配置生成工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
示例:
  # 生成所有配置
  python3 reality_config_generator.py

  # 指定输出目录
  python3 reality_config_generator.py -o /tmp/ad2nx

  # 指定伪装目标
  python3 reality_config_generator.py --dest "www.cloudflare.com:443"

  # 指定服务器名单
  python3 reality_config_generator.py --server-names "google.com" "youtube.com"

  # 指定指纹
  python3 reality_config_generator.py --fingerprint firefox

  # 完整例子
  python3 reality_config_generator.py \\
    -o /etc/ad2nx \\
    --dest "www.google.com:443" \\
    --server-names "google.com" "www.google.com" \\
    --fingerprint chrome \\
    --port 443
        '''
    )
    
    parser.add_argument('-o', '--output-dir', default='/etc/ad2nx',
                        help='输出目录 (默认: /etc/ad2nx)')
    parser.add_argument('--dest', default='www.google.com:443',
                        help='Reality 伪装目标 (默认: www.google.com:443)')
    parser.add_argument('--server-names', nargs='+', 
                        default=['www.google.com', 'google.com'],
                        help='服务器名单')
    parser.add_argument('--fingerprint', default='chrome',
                        choices=['chrome', 'firefox', 'safari', 'edge', 'qq', 'ios', 'android'],
                        help='TLS 指纹 (默认: chrome)')
    parser.add_argument('--port', type=int, default=443,
                        help='监听端口 (默认: 443)')
    parser.add_argument('--uuid', help='指定 UUID (默认: 自动生成)')
    parser.add_argument('--private-key', help='指定 Reality 私钥')
    parser.add_argument('--template', help='指定配置模板文件')
    parser.add_argument('--export-client', action='store_true',
                        help='导出客户端配置')
    parser.add_argument('--print-info', action='store_true', default=True,
                        help='打印配置信息')
    
    args = parser.parse_args()
    
    try:
        print("正在生成 VLESS + Reality 配置...\n")
        
        # 创建生成器
        gen = VlessRealityGenerator(output_dir=args.output_dir)
        
        # 生成 UUID
        print("1. 生成 VLESS UUID...")
        gen.generate_uuid()
        print(f"   ✓ UUID: {gen.vless_uuid}")
        
        # 生成 Reality 密钥
        print("2. 生成 Reality 密钥对...")
        if gen.generate_reality_keys():
            print(f"   ✓ 私钥已生成")
            print(f"   ✓ 公钥已生成")
        else:
            print("   ⚠ 未生成 Reality 密钥，请手动运行: xray x25519")
        
        # 生成配置
        print("3. 生成配置文件...")
        gen.generate_config(
            template_file=args.template,
            uuid=args.uuid,
            private_key=args.private_key,
            dest=args.dest,
            server_names=args.server_names,
            fingerprint=args.fingerprint,
            port=args.port
        )
        print("   ✓ 配置已生成")
        
        # 保存配置
        print("4. 保存配置文件...")
        config_file = gen.save_config()
        
        # 导出客户端配置
        if args.export_client:
            print("5. 导出客户端配置...")
            gen.export_client_config()
        
        # 打印信息
        if args.print_info:
            gen.print_info()
        
        print("✅ 配置生成完成！")
        print(f"\n配置文件位置: {config_file}")
        print(f"\n提示:")
        print(f"  1. 将配置复制到: /etc/ad2nx/config.json")
        print(f"  2. 重启服务: sudo systemctl restart ad2nx")
        print(f"  3. 将公钥和 UUID 提供给客户端")
        
        return 0
        
    except Exception as e:
        print(f"\n❌ 错误: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
