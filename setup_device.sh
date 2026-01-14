#!/bin/bash
set -e

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root"
    exit 1
fi

BM_DIR="$(dirname "$(readlink -f "$0")")"
source "$BM_DIR/config/setup_config.env"

if [[ "${BM_USER:-}" != "pi" ]]; then
    echo "Warning: Only the pi user (and root) can use ALSA/VideoCore features"
fi

BM_LOCALE="en_GB.UTF-8"

# Ensure raspi-config exists
if [[ ! -x /usr/bin/raspi-config ]]; then
    echo "Error: raspi-config not found"
    exit 1
fi

# ----------------------------
# Hostname
# ----------------------------
raspi-config nonint do_hostname "$BM_HOSTNAME"

# ----------------------------
# WiFi country
# ----------------------------
raspi-config nonint do_wifi_country "$BM_COUNTRY_CODE"

# ----------------------------
# Locale
# ----------------------------
raspi-config nonint do_change_locale "$BM_LOCALE"
locale-gen "$BM_LOCALE"
update-locale LANG="$BM_LOCALE" LC_ALL="$BM_LOCALE"

# ----------------------------
# Timezone
# ----------------------------
raspi-config nonint do_change_timezone "$BM_TIMEZONE"

# ----------------------------
# Camera (no-op on Trixie, safe)
# ----------------------------
raspi-config nonint do_camera 0 || true

echo "setup_device.sh completed successfully"