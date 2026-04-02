# Bandwidth Test Script - 使用说明

## 功能增强

脚本现在支持：
- ✅ 自动选择最优服务器
- ✅ 按国家代码筛选服务器
- ✅ 指定特定服务器ID进行测速
- ✅ 列出所有可用服务器

## 命令参数

### 基本用法

```bash
# 自动选择最优服务器进行测速
./bandwidth_test.sh
```

### 指定国家

```bash
# 使用中国服务器测速
./bandwidth_test.sh --country CN

# 使用美国服务器测速
./bandwidth_test.sh --country US

# 使用日本服务器测速
./bandwidth_test.sh --country JP
```

### 指定服务器ID

```bash
# 使用特定服务器（ID: 12345）测速
./bandwidth_test.sh --server 12345
```

### 列出服务器

```bash
# 列出所有可用服务器
./bandwidth_test.sh --list-servers

# 列出指定国家的服务器
./bandwidth_test.sh --list-servers --country CN
```

### 帮助信息

```bash
# 查看帮助
./bandwidth_test.sh --help
```

## 输出格式

所有输出均为 JSON 格式：

```json
{
  "code": 0,
  "data": {
    "download_mbps": 123.45,
    "upload_mbps": 67.89,
    "ping_ms": 12.34,
    "server": {
      "name": "Server Name",
      "sponsor": "ISP Name",
      "location": "City",
      "country": "CN"
    },
    "client": {
      "ip": "1.2.3.4",
      "isp": "Your ISP",
      "country": "CN"
    },
    "timestamp": "2026-04-02T12:00:00.000000Z",
    "share_url": "http://www.speedtest.net/result/..."
  },
  "msg": "success"
}
```

## 常用国家代码

- `CN` - 中国
- `US` - 美国
- `JP` - 日本
- `KR` - 韩国
- `SG` - 新加坡
- `HK` - 香港
- `TW` - 台湾
- `GB` - 英国
- `DE` - 德国
- `FR` - 法国

## 错误处理

如果出现错误，返回格式：

```json
{
  "code": 1,
  "data": null,
  "msg": "错误信息"
}
```

## 示例场景

### 场景1：比较不同国家的网速

```bash
# 测试本地最优服务器
./bandwidth_test.sh

# 测试到中国的速度
./bandwidth_test.sh --country CN

# 测试到美国的速度
./bandwidth_test.sh --country US
```

### 场景2：选择最近的特定国家服务器

```bash
# 先列出中国的所有服务器
./bandwidth_test.sh --list-servers --country CN

# 从列表中选择一个服务器ID进行测试
./bandwidth_test.sh --server 5083
```
