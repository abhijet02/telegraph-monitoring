#!/usr/bin/env bash
# Ubuntu/Debian with systemd. Run on the Linux VM to be monitored.
# sudo bash install-node-exporter.sh PROMETHEUS_IP [PORT]
set -Eeuo pipefail
export LC_ALL=C
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
PROMETHEUS_IP="${1:-}"
PORT="${2:-9100}"
INSTALL_DIR=/usr/local/bin
SERVICE_USER=node_exporter
WORK_DIR=""
trap 'printf "Installation failed at line %s. Check: journalctl -u node_exporter -n 50\n" "$LINENO" >&2' ERR
trap 'if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi' EXIT

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: sudo bash $0 PROMETHEUS_IP [PORT]"
    echo "Use the NEW monitoring VM IP. Optional: NODE_EXPORTER_VERSION=x.y.z"
    exit 0
fi
[[ $EUID -eq 0 ]] || { echo "Run as root using sudo." >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: sudo bash $0 PROMETHEUS_IP [PORT]" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535)) || { echo "Invalid port." >&2; exit 1; }
PORT=$((10#$PORT))
[[ "$NODE_EXPORTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version." >&2; exit 1; }
# Require a single IPv4 or IPv6 address, not a hostname or subnet.
command -v python3 >/dev/null || { echo "Install python3 first: sudo apt-get install python3" >&2; exit 1; }
python3 - "$PROMETHEUS_IP" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit("PROMETHEUS_IP must be a valid IPv4 or IPv6 address.")
PY
command -v apt-get >/dev/null || { echo "Ubuntu/Debian required." >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "A running systemd host is required." >&2; exit 1; }
case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

echo "[1/7] Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ca-certificates curl tar coreutils passwd >/dev/null

echo "[2/7] Downloading and verifying Node Exporter $NODE_EXPORTER_VERSION"
WORK_DIR=$(mktemp -d)
ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 "$BASE_URL/$ARCHIVE" -o "$WORK_DIR/$ARCHIVE"
curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 "$BASE_URL/sha256sums.txt" -o "$WORK_DIR/sha256sums.txt"
awk -v archive="$ARCHIVE" '$2 == archive || $2 == "*" archive {print}' "$WORK_DIR/sha256sums.txt" > "$WORK_DIR/checksum"
[[ $(wc -l < "$WORK_DIR/checksum") -eq 1 ]] || { echo "Missing or duplicate release checksum." >&2; exit 1; }
(cd "$WORK_DIR" && sha256sum --check checksum)
tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR"
"$WORK_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" --version

echo "[3/7] Preparing service account"
getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_USER" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
[[ $(id -u "$SERVICE_USER") -ne 0 ]] || { echo "Service account must not be root." >&2; exit 1; }

echo "[4/7] Installing binary and service"
# Back up existing files before replacing them.
BACKUP_SUFFIX="$(date -u +%Y%m%dT%H%M%SZ).$$"
for existing in "$INSTALL_DIR/node_exporter" /etc/systemd/system/node_exporter.service; do
    if [[ -f "$existing" ]]; then cp -a -- "$existing" "$existing.backup.$BACKUP_SUFFIX"; fi
done
# Root owns the executable; atomic rename also works when the old binary is running.
STAGED_BINARY=$(mktemp "$INSTALL_DIR/.node_exporter.XXXXXX")
install -o root -g root -m 0755 "$WORK_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" "$STAGED_BINARY"
mv -f -- "$STAGED_BINARY" "$INSTALL_DIR/node_exporter"
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$INSTALL_DIR/node_exporter --web.listen-address=:$PORT
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

echo "[5/7] Configuring available firewall"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow from "$PROMETHEUS_IP" to any port "$PORT" proto tcp
    echo "Added UFW allow rule for $PROMETHEUS_IP. Review existing rules with: ufw status numbered"
    echo "Existing broad allow rules or default-allow policies may still permit other clients."
else
    echo "UFW is absent or inactive. Configure the host/cloud firewall to allow TCP $PORT only from $PROMETHEUS_IP."
fi

echo "[6/7] Enabling and restarting service"
systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo "[7/7] Verifying exported host metrics"
verified=false
for attempt in {1..10}; do
    if curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1:$PORT/metrics" -o "$WORK_DIR/metrics" &&
       grep -q '^node_cpu_seconds_total' "$WORK_DIR/metrics"; then
        verified=true
        break
    fi
    sleep 1
done
if [[ "$verified" != true ]] || ! systemctl is-active --quiet node_exporter; then
    journalctl -u node_exporter --no-pager -n 50
    echo "Node Exporter verification failed." >&2
    exit 1
fi
echo "Node Exporter is running. Add THIS_VM_IP:$PORT to prometheus/targets/linux.json on the monitoring VM."
echo "Verify remote connectivity from that VM: curl http://THIS_VM_IP:$PORT/metrics"
echo "Status: systemctl status node_exporter"
echo "Logs: journalctl -u node_exporter -f"
