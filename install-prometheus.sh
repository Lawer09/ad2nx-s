#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-3.10.0}"
ARCH="${ARCH:-linux-amd64}"

PROM_USER="prometheus"
PROM_GROUP="prometheus"

INSTALL_BASE="/opt/prometheus"
DATA_DIR="/data/prometheus"
ETC_DIR="/etc/prometheus"
BIN_LINK="/usr/local/bin/prometheus"
PROMTOOL_LINK="/usr/local/bin/promtool"
SERVICE_FILE="/etc/systemd/system/prometheus.service"

PKG_NAME="prometheus-${PROM_VERSION}.${ARCH}"
PKG_FILE="${PKG_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PKG_FILE}"

echo "[1/9] 创建用户和目录..."
if ! getent group "${PROM_GROUP}" >/dev/null; then
  groupadd --system "${PROM_GROUP}"
fi

if ! id -u "${PROM_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin -g "${PROM_GROUP}" "${PROM_USER}"
fi

mkdir -p "${INSTALL_BASE}" "${DATA_DIR}" "${ETC_DIR}"
chown -R "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}" "${ETC_DIR}"

echo "[2/9] 下载 Prometheus ${PROM_VERSION} ..."
cd /tmp
rm -rf "${PKG_NAME}" "${PKG_FILE}"
curl -fL -o "${PKG_FILE}" "${DOWNLOAD_URL}"

echo "[3/9] 解压..."
tar -xzf "${PKG_FILE}"

echo "[4/9] 安装到 ${INSTALL_BASE}/${PKG_NAME} ..."
rm -rf "${INSTALL_BASE:?}/${PKG_NAME}"
mv "${PKG_NAME}" "${INSTALL_BASE}/"

echo "[5/9] 创建软链接..."
ln -sfn "${INSTALL_BASE}/${PKG_NAME}/prometheus" "${BIN_LINK}"
ln -sfn "${INSTALL_BASE}/${PKG_NAME}/promtool" "${PROMTOOL_LINK}"

echo "[6/9] 写基础配置..."
cat > "${ETC_DIR}/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]
EOF

echo "[7/9] 写 systemd 服务..."
cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Prometheus Monitoring System
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/data/prometheus \
  --web.listen-address=:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=/data/prometheus

[Install]
WantedBy=multi-user.target
EOF

echo "[8/9] 设置权限..."
chown -R "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}" "${ETC_DIR}"
chown -h "${PROM_USER}:${PROM_GROUP}" "${BIN_LINK}" "${PROMTOOL_LINK}" || true
chown -R "${PROM_USER}:${PROM_GROUP}" "${INSTALL_BASE}/${PKG_NAME}"

echo "[9/9] 校验并启动..."
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

systemctl daemon-reload
systemctl enable --now prometheus

echo
echo "安装完成。"
echo "查看状态: systemctl status prometheus"
echo "本机访问:  http://127.0.0.1:9090"
echo "热重载配置: curl -X POST http://127.0.0.1:9090/-/reload"