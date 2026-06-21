#!/usr/bin/env bash
set -euo pipefail

# Local repack script for flippy-openwrt-actions targets.
# Mirrors the GitHub Actions packaging flow by invoking
# ophub/flippy-openwrt-actions locally with a configurable `PACKAGE_SOC`
# value (default: `s905d`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="${ACTION_DIR:-$SCRIPT_DIR/flippy-openwrt-actions}"
PACKIT_WORKDIR="${PACKIT_WORKDIR:-$ACTION_DIR/.workdir}"
ACTION_REPO_URL="${ACTION_REPO_URL:-https://github.com/ophub/flippy-openwrt-actions}"
ACTION_REPO_BRANCH="${ACTION_REPO_BRANCH:-main}"
PACKIT_REPO_URL="${PACKIT_REPO_URL:-https://github.com/unifreq/openwrt_packit}"
PACKIT_REPO_BRANCH="${PACKIT_REPO_BRANCH:-master}"

DEFAULT_OPENWRT_DIR="${DEFAULT_OPENWRT_DIR:-$SCRIPT_DIR/lede-arm}"
OPENWRT_ARMVIRT="${OPENWRT_ARMVIRT:-}"
PACKAGE_SOC="${PACKAGE_SOC:-s905d}"
WHOAMI="${WHOAMI:-wuyiwangzi}"
KERNEL_REPO_URL="${KERNEL_REPO_URL:-ophub/kernel}"
KERNEL_VERSION_NAME="${KERNEL_VERSION_NAME:-6.6.y}"
KERNEL_AUTO_LATEST="${KERNEL_AUTO_LATEST:-true}"
ENABLE_WIFI_K504="${ENABLE_WIFI_K504:-1}"
ENABLE_WIFI_K510="${ENABLE_WIFI_K510:-0}"
OPENWRT_IP="${OPENWRT_IP:-192.168.1.1}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$SCRIPT_DIR}"
GITHUB_ENV="${GITHUB_ENV:-$PACKIT_WORKDIR/github.env}"
LOCAL_OUTPUT_DIR="${LOCAL_OUTPUT_DIR:-$ACTION_DIR/output}"
OPT_OPENWRT_PACKIT_DIR="${OPT_OPENWRT_PACKIT_DIR:-/opt/openwrt_packit}"
OPT_KERNEL_DIR="${OPT_KERNEL_DIR:-/opt/kernel}"
FORCE_INIT=0
AUTO_INSTALL_DEPS=1
ARM_BUILD_SCRIPT="${ARM_BUILD_SCRIPT:-$SCRIPT_DIR/build-arm-local.sh}"
AUTO_BUILD_ARM=1

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0")

Options:
  --init               Force re-initialize local cached directories
  --soc <value>        Package target SoC, default: s905d
  --image <path|url>   Rootfs path or URL; if unset, auto-detect local arm build output
  --no-install-deps    Only check dependencies, do not auto-install missing packages
  --no-build-arm       Do not auto-run local arm build when rootfs is missing
  -h, --help           Show this help

Environment overrides:
  DEFAULT_OPENWRT_DIR  Local arm build tree, default: ./lede-arm
  WHOAMI               Packit make.env WHOAMI value
  KERNEL_REPO_URL      Kernel release repo, default: ophub/kernel
  KERNEL_VERSION_NAME  Kernel series, default: 6.6.y
  KERNEL_AUTO_LATEST   Auto-resolve latest patch version, default: true
  ENABLE_WIFI_K504     Wifi flag passed to packit, default: 1
  ENABLE_WIFI_K510     Wifi flag passed to packit, default: 0
  OPENWRT_IP           Default LAN IP, default: 192.168.1.1
  PACKIT_WORKDIR       Local working directory, default: ./flippy-openwrt-actions/.workdir
  ACTION_DIR           flippy-openwrt-actions checkout directory, default: ./flippy-openwrt-actions
  LOCAL_OUTPUT_DIR     Local copied output directory, default: ./flippy-openwrt-actions/output
  OPT_OPENWRT_PACKIT_DIR  Packit work directory, default: /opt/openwrt_packit
  OPT_KERNEL_DIR          Kernel cache directory, default: /opt/kernel
  PACKIT_REPO_URL         openwrt_packit repo URL
  PACKIT_REPO_BRANCH      openwrt_packit branch, default: master
  ARM_BUILD_SCRIPT        Local arm build script, default: ./build-arm-local.sh

Examples:
  ./repack-local.sh
  ./repack-local.sh --init
  ./repack-local.sh --soc s905d --image /path/to/openwrt-armsr-armv8-generic-rootfs.tar.gz
  ./repack-local.sh --soc r68s
  ./repack-local.sh --soc r68s --image https://example.com/rootfs.tar.gz --init
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --init)
        FORCE_INIT=1
        ;;
      --soc)
        [ "$#" -ge 2 ] || die "Missing value for --soc"
        PACKAGE_SOC="$2"
        shift
        ;;
      --image)
        [ "$#" -ge 2 ] || die "Missing value for --image"
        OPENWRT_ARMVIRT="$2"
        shift
        ;;
      --no-install-deps)
        AUTO_INSTALL_DEPS=0
        ;;
      --no-build-arm)
        AUTO_BUILD_ARM=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

resolve_local_rootfs() {
  local search_dir="${DEFAULT_OPENWRT_DIR}/bin/targets"
  local rootfs_path

  [ -d "$search_dir" ] || return 1

  rootfs_path="$(find "$search_dir" -maxdepth 4 -type f -name 'openwrt-armsr-armv8-generic-rootfs.tar.gz' | sort | tail -n 1)"
  if [ -z "$rootfs_path" ]; then
    rootfs_path="$(find "$search_dir" -maxdepth 4 -type f -name '*rootfs.tar.gz' | sort | tail -n 1)"
  fi
  [ -n "$rootfs_path" ] || return 1

  printf '%s\n' "$rootfs_path"
}

ensure_requirements() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v bash >/dev/null 2>&1 || die "bash is required"
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  command -v curl >/dev/null 2>&1 || log "curl not found locally; pack script will install it if needed"
}

check_sudo_ready() {
  sudo -n true >/dev/null 2>&1 || die "passwordless sudo is required for local repack"
}

check_command() {
  local cmd="$1"
  local package_hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '  - %s (install package: %s)\n' "$cmd" "$package_hint"
    return 1
  fi

  return 0
}

append_missing_package() {
  local package_name="$1"
  case " ${MISSING_PACKAGES:-} " in
    *" $package_name "*) ;;
    *) MISSING_PACKAGES="${MISSING_PACKAGES:-} $package_name" ;;
  esac
}

require_command() {
  local cmd="$1"
  local package_hint="$2"

  if ! check_command "$cmd" "$package_hint"; then
    append_missing_package "$package_hint"
    return 1
  fi

  return 0
}

install_missing_prerequisites() {
  [ -n "${MISSING_PACKAGES:-}" ] || return 0

  if [ "$AUTO_INSTALL_DEPS" -ne 1 ]; then
    die "install the missing dependencies listed above"
  fi

  log "Installing missing packages:$(printf ' %s' $MISSING_PACKAGES)"
  sudo apt-get update
  sudo apt-get install -y $MISSING_PACKAGES
}

check_prerequisites() {
  local missing=0
  local lsblk_version
  local major minor

  log "Checking local repack prerequisites"
  check_sudo_ready

  printf 'Missing commands:\n'
  MISSING_PACKAGES=""
  require_command mkfs.btrfs btrfs-progs || missing=1
  require_command mkfs.vfat dosfstools || missing=1
  require_command gawk gawk || missing=1
  require_command uuidgen uuid-runtime || missing=1
  require_command losetup mount || missing=1
  require_command lsblk util-linux || missing=1
  require_command fdisk fdisk || missing=1
  require_command parted parted || missing=1
  require_command pigz pigz || missing=1
  require_command zstd zstd || missing=1
  require_command xz xz-utils || missing=1
  require_command zip zip || missing=1
  require_command 7z p7zip-full || missing=1
  require_command jq jq || missing=1
  require_command tar tar || missing=1

  if [ "$missing" -eq 1 ]; then
    install_missing_prerequisites

    printf 'Re-checking commands after installation:\n'
    check_command mkfs.btrfs btrfs-progs || die "mkfs.btrfs is still unavailable after installation"
    check_command mkfs.vfat dosfstools || die "mkfs.vfat is still unavailable after installation"
    check_command gawk gawk || die "gawk is still unavailable after installation"
    check_command uuidgen uuid-runtime || die "uuidgen is still unavailable after installation"
    check_command losetup mount || die "losetup is still unavailable after installation"
    check_command lsblk util-linux || die "lsblk is still unavailable after installation"
    check_command fdisk fdisk || die "fdisk is still unavailable after installation"
    check_command parted parted || die "parted is still unavailable after installation"
    check_command pigz pigz || die "pigz is still unavailable after installation"
    check_command zstd zstd || die "zstd is still unavailable after installation"
    check_command xz xz-utils || die "xz is still unavailable after installation"
    check_command zip zip || die "zip is still unavailable after installation"
    check_command 7z p7zip-full || die "7z is still unavailable after installation"
    check_command jq jq || die "jq is still unavailable after installation"
    check_command tar tar || die "tar is still unavailable after installation"
  fi

  lsblk_version="$(lsblk --version 2>/dev/null | awk '{print $NF}')"
  [ -n "$lsblk_version" ] || die "failed to detect lsblk version"

  major="$(printf '%s' "$lsblk_version" | cut -d '.' -f1)"
  minor="$(printf '%s' "$lsblk_version" | cut -d '.' -f2 | tr -cd '0-9')"
  [ -n "$major" ] || die "failed to parse lsblk major version: $lsblk_version"
  [ -n "$minor" ] || die "failed to parse lsblk minor version: $lsblk_version"

  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 33 ]; }; then
    die "lsblk 2.33 or newer is required; found $lsblk_version"
  fi
}

prepare_opt_dirs() {
  log "Preparing local /opt work directories"
  sudo mkdir -p "$OPT_KERNEL_DIR"
  sudo chown -R "$(id -un)":"$(id -gn)" "$OPT_KERNEL_DIR"

  if [ "$FORCE_INIT" -eq 1 ]; then
    log "Removing existing packit and kernel cache due to --init"
    sudo rm -rf "$OPT_OPENWRT_PACKIT_DIR" "$OPT_KERNEL_DIR"
    sudo mkdir -p "$OPT_KERNEL_DIR"
    sudo chown -R "$(id -un)":"$(id -gn)" "$OPT_KERNEL_DIR"
    return
  fi
}

prepare_packit_repo() {
  if [ "$FORCE_INIT" -eq 1 ] || [ ! -d "$OPT_OPENWRT_PACKIT_DIR/.git" ]; then
    log "Preparing openwrt_packit repository"
    sudo rm -rf "$OPT_OPENWRT_PACKIT_DIR"
    sudo git clone --depth 1 --branch "$PACKIT_REPO_BRANCH" "$PACKIT_REPO_URL" "$OPT_OPENWRT_PACKIT_DIR"
    sudo chown -R "$(id -un)":"$(id -gn)" "$OPT_OPENWRT_PACKIT_DIR"
  fi
}

prepare_action_repo() {
  if [ "$FORCE_INIT" -eq 1 ] && [ -d "$ACTION_DIR" ]; then
    log "Removing existing action checkout due to --init"
    rm -rf "$ACTION_DIR"
  fi

  if [ ! -d "$ACTION_DIR/.git" ]; then
    if [ -n "$(ls -A "$ACTION_DIR" 2>/dev/null)" ]; then
      die "Action directory exists but is not a git checkout: $ACTION_DIR"
    fi
    log "Cloning flippy-openwrt-actions"
    git clone --depth 1 --branch "$ACTION_REPO_BRANCH" "$ACTION_REPO_URL" "$ACTION_DIR"
  else
    log "Using existing flippy-openwrt-actions checkout: $ACTION_DIR"
  fi

  mkdir -p "$PACKIT_WORKDIR"
}

validate_inputs() {
  if [ -z "$OPENWRT_ARMVIRT" ]; then
    OPENWRT_ARMVIRT="$(resolve_local_rootfs || true)"
    if [ -z "$OPENWRT_ARMVIRT" ] && [ "$AUTO_BUILD_ARM" -eq 1 ]; then
      [ -f "$ARM_BUILD_SCRIPT" ] || die "Arm build script not found: $ARM_BUILD_SCRIPT"
      log "Local arm rootfs not found; running $ARM_BUILD_SCRIPT"
      bash "$ARM_BUILD_SCRIPT"
      OPENWRT_ARMVIRT="$(resolve_local_rootfs || true)"
    fi
    [ -n "$OPENWRT_ARMVIRT" ] || die "OPENWRT_ARMVIRT is not set and no local arm rootfs was found under $DEFAULT_OPENWRT_DIR/bin/targets"
    log "Using local arm rootfs: $OPENWRT_ARMVIRT"
  fi

  case "$OPENWRT_ARMVIRT" in
    http://*|https://*) ;;
    *)
      [ -f "$OPENWRT_ARMVIRT" ] || die "Rootfs not found: $OPENWRT_ARMVIRT"
      ;;
  esac
}

run_repack() {
  log "Starting local repack for PACKAGE_SOC=$PACKAGE_SOC"
  mkdir -p "$(dirname "$GITHUB_ENV")"
  : > "$GITHUB_ENV"

  export OPENWRT_ARMVIRT
  export PACKAGE_SOC
  export WHOAMI
  export KERNEL_REPO_URL
  export KERNEL_VERSION_NAME
  export KERNEL_AUTO_LATEST
  export ENABLE_WIFI_K504
  export ENABLE_WIFI_K510
  export OPENWRT_IP
  export GITHUB_WORKSPACE
  export GITHUB_ENV

  bash "$ACTION_DIR/openwrt_flippy.sh"
}

show_outputs() {
  if [ -f "$GITHUB_ENV" ]; then
    # shellcheck disable=SC1090
    source "$GITHUB_ENV"
  fi

  if [ "${PACKAGED_STATUS:-}" = "success" ] && [ -n "${PACKAGED_OUTPUTPATH:-}" ]; then
    mkdir -p "$LOCAL_OUTPUT_DIR"
    cp -af "$PACKAGED_OUTPUTPATH"/. "$LOCAL_OUTPUT_DIR"/

    log "Repack completed successfully"
    printf 'Output directory: %s\n' "$PACKAGED_OUTPUTPATH"
    printf 'Copied to: %s\n' "$LOCAL_OUTPUT_DIR"
    printf 'Packaged at: %s\n' "${PACKAGED_OUTPUTDATE:-unknown}"
  else
    die "Repack failed; PACKAGED_STATUS=${PACKAGED_STATUS:-unset}"
  fi
}

main() {
  parse_args "$@"
  ensure_requirements
  check_prerequisites
  validate_inputs
  prepare_action_repo
  prepare_opt_dirs
  prepare_packit_repo
  run_repack
  show_outputs
}

main "$@"
