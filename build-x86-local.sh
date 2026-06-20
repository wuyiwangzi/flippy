#!/usr/bin/env bash
set -euo pipefail

# Pure local x86_64 LEDE/OpenWrt build script.
# Mirrors .github/workflows/x86_64.yml build logic without GitHub Actions-only steps.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_NAME="x86_64"
OPENWRT_DIR="${OPENWRT_DIR:-$SCRIPT_DIR/lede}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/x86/.config.x86}"
SHOW_OUTPUTS_PATTERN="( -name '*x86-64*' -o -name 'sha256sums' -o -name 'profiles.json' )"

source "$SCRIPT_DIR/lib-openwrt-local-build.sh"
run_local_build "$@"
