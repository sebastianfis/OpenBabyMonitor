#!/bin/bash
set -euo pipefail

# ----------------------------------------
# Babymonitor network setup (non-invasive)
# ----------------------------------------

BM_DIR="$(dirname "$(readlink -f "$0")")"
source "$BM_DIR/config/setup_config.env"

BM_ENV_EXPORTS_PATH="$BM_DIR/env/envvar_exports"
BM_ENV_PATH="$BM_DIR/env/envvars"

if [[ ! -f "$BM_ENV_EXPORTS_PATH" ]]; then
    echo "Error: setup_server.sh must be run before setup_network.sh"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root"
    exit 1
fi

source "$BM_ENV_EXPORTS_PATH"

# ----------------------------------------
# Hostname
# ----------------------------------------

CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "$BM_HOSTNAME" ]]; then
    echo "Setting hostname to $BM_HOSTNAME"
    hostnamectl set-hostname "$BM_HOSTNAME"
fi

# Ensure hosts entry exists
grep -q "127.0.1.1.*$BM_HOSTNAME" /etc/hosts || \
echo "127.0.1.1    $BM_HOSTNAME" >> /etc/hosts

# ----------------------------------------
# Detect active Wi-Fi interface
# ----------------------------------------

BM_NW_INTERFACE="$(iw dev | awk '$1=="Interface"{print $2; exit}')"

if [[ -z "$BM_NW_INTERFACE" ]]; then
    echo "Error: no wireless interface detected"
    exit 1
fi

# Wait for IP
for _ in {1..10}; do
    BM_NW_IP="$(ip -o -4 addr show "$BM_NW_INTERFACE" | awk '{print $4}' | cut -d/ -f1)"
    [[ -n "$BM_NW_IP" ]] && break
    sleep 1
done

if [[ -z "$BM_NW_IP" ]]; then
    echo "Error: Wi-Fi interface has no IPv4 address"
    exit 1
fi

# ----------------------------------------
# Avahi (mDNS)
# ----------------------------------------

apt -y install avahi-daemon
systemctl enable avahi-daemon --now

# ----------------------------------------
# Export environment variables
# ----------------------------------------

{
    echo "export BM_HOSTNAME=$BM_HOSTNAME"
    echo "export BM_NW_INTERFACE=$BM_NW_INTERFACE"
    echo "export BM_NW_IP=$BM_NW_IP"
} >> "$BM_ENV_EXPORTS_PATH"

sed 's/^export //' "$BM_ENV_EXPORTS_PATH" > "$BM_ENV_PATH"

echo "Network detected:"
echo "  Interface : $BM_NW_INTERFACE"
echo "  IP        : $BM_NW_IP"
echo "  Hostname  : $BM_HOSTNAME.local"

echo "setup_network.sh completed successfully"
