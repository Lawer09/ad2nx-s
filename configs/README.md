# ad2nx 配置文件模板

本目录包含从 `ad2nx.sh` 脚本中提取的所有配置文件模板。

## 文件说明

| 文件名 | 说明 | 部署路径 |
|--------|------|----------|
| `config.json.template` | 主配置文件模板（包含所有核心类型示例） | `/etc/ad2nx/config.json` |
| `custom_outbound.json` | Xray 自定义出站配置 | `/etc/ad2nx/custom_outbound.json` |
| `route.json` | Xray 路由规则配置（含审计规则） | `/etc/ad2nx/route.json` |
| `sing_origin.json` | sing-box 原始配置 | `/etc/ad2nx/sing_origin.json` |
| `hy2config.yaml` | Hysteria2 配置 | `/etc/ad2nx/hy2config.yaml` |

## 支持的核心类型

- **xray** - Xray 核心
- **sing** - sing-box 核心
- **hysteria2** - Hysteria2 核心

## 支持的节点类型

- `shadowsocks` - Shadowsocks
- `vless` - VLESS (支持 Reality)
- `vmess` - VMess
- `hysteria` - Hysteria (仅 sing-box)
- `hysteria2` - Hysteria2
- `trojan` - Trojan
- `tuic` - TUIC (仅 sing-box)
- `anytls` - AnyTLS (仅 sing-box)

## 证书模式

- `none` - 不使用 TLS
- `http` - HTTP 模式自动申请证书
- `dns` - DNS 模式自动申请证书
- `self` - 自签证书或已有证书

## 使用方法

1. 复制 `config.json.template` 为 `config.json`
2. 修改 `ApiHost`、`ApiKey`、`NodeID` 等参数
3. 根据需要选择核心类型和节点类型
4. 将配置文件部署到 `/etc/ad2nx/` 目录
