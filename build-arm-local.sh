#!/usr/bin/env bash
set -euo pipefail

# Pure local armv8 LEDE/OpenWrt build script.
# Mirrors .github/workflows/arm.yml build logic without GitHub Actions-only steps.
# This builds the armvirt/armsr rootfs from LEDE. Device-specific flippy packaging
# from ophub/flippy-openwrt-actions is intentionally not included here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_NAME="armv8"
OPENWRT_DIR="${OPENWRT_DIR:-/home/well/lede-arm}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/armv8/.config.arm}"
SHOW_OUTPUTS_PATTERN="\\( -name '*rootfs*' -o -name '*.img*' -o -name '*.tar.gz' -o -name 'sha256sums' -o -name 'profiles.json' \\)"

source "$SCRIPT_DIR/lib-openwrt-local-build.sh"
run_local_build "$@"
