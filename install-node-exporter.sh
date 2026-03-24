#!/usr/bin/env bash
set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
ARCH="${ARCH:-linux-amd64}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/node_exporter"
SERVICE_FILE="/etc/systemd/system/node_exporter.service"
USER_NAME="node_exporter"
GROUP_NAME="node_exporter"

echo "[1/8] Create user/group..."
if ! getent group "${GROUP_NAME}" >/dev/null; then
  groupadd --system "${GROUP_NAME}"
fi

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin -g "${GROUP_NAME}" "${USER_NAME}"
fi

echo "[2/8] Create directories..."
mkdir -p "${CONFIG_DIR}"

echo "[3/8] Download node_exporter v${NODE_EXPORTER_VERSION} ..."
cd /tmp
curl -fL -o "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz" \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"

echo "[4/8] Extract..."
tar -xzf "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"

echo "[5/8] Install binary..."
install -m 0755 "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" "${INSTALL_DIR}/node_exporter"

echo "[6/8] Write textfile collector dir..."
mkdir -p /var/lib/node_exporter/textfile_collector
chown -R "${USER_NAME}:${GROUP_NAME}" /var/lib/node_exporter

echo "[7/8] Write systemd service..."
cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --collector.systemd \
  --collector.processes \
  --collector.tcpstat \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
  --collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+|var/lib/containerd/.+|snap)($|/) \
  --collector.netdev.device-exclude=^(lo|docker.*|veth.*|br-.*|virbr.*|flannel.*|cali.*|cilium.*|tun.*)$
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[8/8] Start service..."
systemctl daemon-reload
systemctl enable --now node_exporter

echo
echo "node_exporter installed."
echo "Check: systemctl status node_exporter"
echo "Metrics: curl http://127.0.0.1:9100/metrics | head"