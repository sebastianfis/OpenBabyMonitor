#!/usr/bin/env bash
set -euo pipefail

info()    { echo -e "\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
error()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

trap 'error "Failure on line $LINENO"; exit 1' ERR

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

info "User: $(whoami), UID: $(id -u)"

info "Running setup_device.sh..."
sudo env BM_DEVICE_PW="${BM_DEVICE_PW:-}" "$SCRIPT_DIR/setup_device.sh"

info "Running setup_server.sh..."
sudo env BM_SITE_PW="${BM_SITE_PW:-}" "$SCRIPT_DIR/setup_server.sh"

info "Running setup_network.sh..."
sudo env BM_AP_PW="${BM_AP_PW:-}" "$SCRIPT_DIR/setup_network.sh"

success "All setup scripts completed successfully!"

info "Rebooting system..."
sudo reboot
