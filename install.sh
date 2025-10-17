#!/usr/bin/env bash
set -euo pipefail

# Usage: install.sh [INTERVAL]
# INTERVAL    - optional systemd OnUnitActiveSec value (e.g. 30m, 1h, 6h). Default: 1h
SCRIPT_URL="https://raw.githubusercontent.com/vgdh/proxmox-ipset-auto-dns/refs/heads/main/proxmox-ipset-auto-dns.sh"
INSTALL_PATH=/usr/local/bin/proxmox-ipset-auto-dns.sh
SERVICE_NAME=proxmox-ipset-auto-dns
SERVICE_PATH=/etc/systemd/system/${SERVICE_NAME}.service
TIMER_PATH=/etc/systemd/system/${SERVICE_NAME}.timer

INTERVAL=${1:-1h}

if [ "$(id -u)" -ne 0 ]; then
  echo "must be run as root"
  exit 1
fi

# Check and install required commands: pvesh, jq, dig (dnsutils)
check_and_install_requirements() {
  declare -A pkg_map=( ["pvesh"]="pve-manager" ["jq"]="jq" ["dig"]="dnsutils" )
  missing_pkgs=()
  for cmd in pvesh jq dig; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      pkg=${pkg_map[$cmd]}
      missing_pkgs+=("$pkg")
    fi
  done

  if [ "${#missing_pkgs[@]}" -eq 0 ]; then
    echo "All required commands present: pvesh, jq, dig"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Required packages missing (${missing_pkgs[*]}) but apt-get not found. Please install them manually."
    return 1
  fi

  echo "Installing missing packages: ${missing_pkgs[*]}"
  apt-get update -y
  apt-get install "${missing_pkgs[@]}"
}

check_and_install_requirements || true


echo "Downloading script from: $SCRIPT_URL"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$INSTALL_PATH" "$SCRIPT_URL"
else
  echo "curl or wget required to download the script."
  exit 1
fi

chmod +x "$INSTALL_PATH"
echo "Installed script to $INSTALL_PATH"

# Write systemd service
cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Run proxmox ipset auto dns script
Wants=${SERVICE_NAME}.timer

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH}
User=root
Group=root
# grant network/capabilities if needed (optional)
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
EOF

# Write systemd timer
cat > "${TIMER_PATH}" <<EOF
[Unit]
Description=Timer for proxmox ipset auto dns

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.timer"

echo "Enabled and started ${SERVICE_NAME}.timer (interval=${INTERVAL})."
echo "Check status: systemctl status ${SERVICE_NAME}.timer"