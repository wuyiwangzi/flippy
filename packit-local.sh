#!/usr/bin/env bash
set -euo pipefail

# Pure local packit helper that talks directly to unifreq/openwrt_packit,
# without going through ophub/flippy-openwrt-actions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKIT_REPO_URL="${PACKIT_REPO_URL:-https://github.com/unifreq/openwrt_packit}"
PACKIT_REPO_BRANCH="${PACKIT_REPO_BRANCH:-master}"
PACKIT_DIR="${PACKIT_DIR:-/home/well/openwrt_packit}"
KERNEL_STORE="${KERNEL_STORE:-$PACKIT_DIR/kernel}"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKIT_DIR/output}"
OPENWRT_ARMSR="${OPENWRT_ARMSR:-}"
PACKAGE_SOC="${PACKAGE_SOC:-s905d}"
KERNEL_REPO_URL="${KERNEL_REPO_URL:-ophub/kernel}"
KERNEL_VERSION_NAME="${KERNEL_VERSION_NAME:-6.6.y}"
KERNEL_AUTO_LATEST="${KERNEL_AUTO_LATEST:-true}"
OPENWRT_IP="${OPENWRT_IP:-192.168.3.1}"
WHOAMI="${WHOAMI:-wuyiwangzi}"
OPENWRT_VER="${OPENWRT_VER:-auto}"
SW_FLOWOFFLOAD="${SW_FLOWOFFLOAD:-1}"
HW_FLOWOFFLOAD="${HW_FLOWOFFLOAD:-0}"
SFE_FLOW="${SFE_FLOW:-1}"
ENABLE_WIFI_K504="${ENABLE_WIFI_K504:-1}"
ENABLE_WIFI_K510="${ENABLE_WIFI_K510:-0}"
DISTRIB_REVISION="${DISTRIB_REVISION:-R$(date +%Y.%m.%d)}"
DISTRIB_DESCRIPTION="${DISTRIB_DESCRIPTION:-OpenWrt}"
GZIP_IMGS="${GZIP_IMGS:-auto}"
AUTO_BUILD_ARM=0
INSTALL_DEPS=1
FORCE_INIT=0

ALL_SOCS=(
  100ask-dshanpi-a1 vplus cm3 jp-tvbox beikeyun l1pro rock5b rock5c e52c e54c
  r66s r68s e25 photonicat watermelon-pi yixun-rs6pro zcube1-max ht2 e20c e24c
  h28k h66k h68k h69k h69k-max h88k h88k-v3 rk3399 s905 s905d s905x2 s905x3
  s912 s922x s922x-n2 qemu diy
)

RK3588_SOCS=(ak88 e52c e54c h88k h88k-v3 rock5b rock5c)
RK35XX_SOCS=(100ask-dshanpi-a1 e20c e24c h28k h66k h68k h69k h69k-max ht2 jp-tvbox watermelon-pi yixun-rs6pro zcube1-max)

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CURRENT_USER="${USER:-$(id -un)}"
CURRENT_GROUP="$(id -gn)"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: packit-local.sh [options]

Options:
  --force-init         Force re-initialize packit environment before repack
  --soc NAME           Target SoC / device selector, e.g. s905d, r68s
  --rootfs PATH        Path or URL to openwrt-armsr-armv8-generic-rootfs.tar.gz
  --kernel VER         Kernel version name, default: 6.6.y
  --kernel-auto-latest true|false  Auto query same-series latest kernel, default: true
  --output-dir PATH    Final output directory, default: /home/well/openwrt_packit/output
  --build-arm          Build arm rootfs first using build-arm-local.sh --init if missing
  -h, --help           Show this help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-init)
        FORCE_INIT=1 ;;
      --soc)
        shift; [ "$#" -gt 0 ] || die "--soc requires a value"; PACKAGE_SOC="$1" ;;
      --rootfs)
        shift; [ "$#" -gt 0 ] || die "--rootfs requires a value"; OPENWRT_ARMSR="$1" ;;
      --kernel)
        shift; [ "$#" -gt 0 ] || die "--kernel requires a value"; KERNEL_VERSION_NAME="$1" ;;
      --kernel-auto-latest)
        shift; [ "$#" -gt 0 ] || die "--kernel-auto-latest requires a value"; KERNEL_AUTO_LATEST="$1" ;;
      --output-dir)
        shift; [ "$#" -gt 0 ] || die "--output-dir requires a value"; OUTPUT_DIR="$1" ;;
      --build-arm)
        AUTO_BUILD_ARM=1 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
    shift
  done
}

install_dependencies() {
  log "Installing packit dependencies"
  sudo apt update -y
  sudo apt install -y curl git coreutils p7zip p7zip-full zip unzip gzip xz-utils pigz zstd jq tar util-linux dosfstools btrfs-progs parted kmod rsync gawk uuid-runtime fdisk qemu-utils mtools
}

check_dependencies() {
  local missing=0
  local cmds=(curl git jq tar losetup truncate parted rsync mkfs.btrfs mkfs.vfat gawk uuidgen lsblk fdisk mcopy)

  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done

  if command -v lsblk >/dev/null 2>&1; then
    local lsblk_version major minor
    lsblk_version="$(lsblk --version 2>/dev/null | awk '{print $NF}')"
    major="$(echo "$lsblk_version" | cut -d '.' -f1 | tr -d '[:alpha:]-')"
    minor="$(echo "$lsblk_version" | cut -d '.' -f2 | tr -d '[:alpha:]-')"
    if [ -z "$major" ] || [ -z "$minor" ]; then
      printf 'Unable to parse lsblk version: %s\n' "$lsblk_version" >&2
      missing=1
    elif [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 33 ]; }; then
      printf 'lsblk version must be >= 2.33, current: %s\n' "$lsblk_version" >&2
      missing=1
    fi
  fi

  if [ "${EFI:-0}" = "1" ] && ! command -v qemu-img >/dev/null 2>&1; then
    printf 'Missing required command for EFI mode: qemu-img\n' >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    die "Missing required tools. Re-run with --install-deps or install packages manually."
  fi
}

ensure_rootfs() {
  if [ -z "$OPENWRT_ARMSR" ]; then
    local candidate
    for candidate in \
      /home/well/lede-arm/bin/targets/*/*/*rootfs.tar.gz \
      /home/well/lede-arm/bin/targets/*/*/*.tar.gz; do
      if [ -f "$candidate" ]; then
        OPENWRT_ARMSR="$candidate"
        break
      fi
    done
  fi

  if [ -z "$OPENWRT_ARMSR" ] && [ "$AUTO_BUILD_ARM" -eq 1 ]; then
    log "No arm rootfs found, running build-arm-local.sh --init"
    "$SCRIPT_DIR/build-arm-local.sh" --init
    ensure_rootfs
    return
  fi

  [ -n "$OPENWRT_ARMSR" ] || die "No arm rootfs tarball found. Use --rootfs or --build-arm."
  if [[ "$OPENWRT_ARMSR" != http* ]]; then
    [ -f "$OPENWRT_ARMSR" ] || die "Rootfs file not found: $OPENWRT_ARMSR"
  fi
  log "Using rootfs: $OPENWRT_ARMSR"
}

ensure_packit_repo() {
  local parent
  parent="$(dirname "$PACKIT_DIR")"
  sudo mkdir -p "$parent"
  sudo chown -R "$CURRENT_USER":"$CURRENT_GROUP" "$parent"

  if [ ! -d "$PACKIT_DIR/.git" ]; then
    log "Cloning openwrt_packit"
    git clone "$PACKIT_REPO_URL" -b "$PACKIT_REPO_BRANCH" "$PACKIT_DIR"
  else
    log "Using existing packit repo: $PACKIT_DIR"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  curl -fsSL "$url" -o "$dest"
}

prepare_rootfs_in_packit() {
  cd "$PACKIT_DIR"
  local target_file="openwrt-armsr-armv8-generic-rootfs.tar.gz"
  rm -f "$target_file"

  if [[ "$OPENWRT_ARMSR" == http* ]]; then
    log "Downloading rootfs into packit workspace"
    download_file "$OPENWRT_ARMSR" "$target_file"
  else
    log "Copying rootfs into packit workspace"
    cp -f "$OPENWRT_ARMSR" "$target_file"
  fi
}

kernel_tag_for_soc() {
  case "$1" in
    ak88|e52c|e54c|h88k|h88k-v3|rock5b|rock5c) printf 'rk3588' ;;
    100ask-dshanpi-a1|e20c|e24c|h28k|h66k|h68k|h69k|h69k-max|ht2|jp-tvbox|watermelon-pi|yixun-rs6pro|zcube1-max) printf 'rk35xx' ;;
    *)
      if [ "$KERNEL_REPO_URL" = "ophub/kernel" ]; then
        printf 'flippy'
      else
        printf 'stable'
      fi
      ;;
  esac
}

release_tag_for_kernel_tag() {
  case "$1" in
    flippy) printf 'stable' ;;
    *) printf '%s' "$1" ;;
  esac
}

soc_list() {
  if [ "$PACKAGE_SOC" = "all" ]; then
    printf '%s\n' "${ALL_SOCS[@]}"
    return
  fi

  local old_ifs
  old_ifs="$IFS"
  IFS='_'
  # shellcheck disable=SC2206
  local selected=( $PACKAGE_SOC )
  IFS="$old_ifs"
  printf '%s\n' "${selected[@]}"
}

script_for_soc() {
  case "$1" in
    100ask-dshanpi-a1) printf 'mk_rk3576_100ask-dshanpi-a1.sh' ;;
    ak88) printf 'mk_rk3588_h88k.sh' ;;
    beikeyun) printf 'mk_rk3328_beikeyun.sh' ;;
    cm3) printf 'mk_rk3566_radxa-cm3-rpi-cm4-io.sh' ;;
    diy) printf 'mk_diy.sh' ;;
    e20c) printf 'mk_rk3528_e20c.sh' ;;
    e24c) printf 'mk_rk3528_e24c.sh' ;;
    e25) printf 'mk_rk3568_e25.sh' ;;
    e52c) printf 'mk_rk3588s_e52c.sh' ;;
    e54c) printf 'mk_rk3588s_e54c.sh' ;;
    h28k) printf 'mk_rk3528_h28k.sh' ;;
    h66k) printf 'mk_rk3568_h66k.sh' ;;
    h68k) printf 'mk_rk3568_h68k.sh' ;;
    h69k) printf 'mk_rk3568_h69k.sh' ;;
    h69k-max) printf 'mk_rk3568_h69k.sh' ;;
    h88k-v3) printf 'mk_rk3588_h88k-v3.sh' ;;
    ht2) printf 'mk_rk3528_ht2.sh' ;;
    jp-tvbox) printf 'mk_rk3566_jp-tvbox.sh' ;;
    l1pro) printf 'mk_rk3328_l1pro.sh' ;;
    photonicat) printf 'mk_rk3568_photonicat.sh' ;;
    qemu) printf 'mk_qemu-aarch64_img.sh' ;;
    r66s) printf 'mk_rk3568_r66s.sh' ;;
    r68s) printf 'mk_rk3568_r68s.sh' ;;
    rk3399) printf 'mk_rk3399_generic.sh' ;;
    rock5b) printf 'mk_rk3588_rock5b.sh' ;;
    rock5c) printf 'mk_rk3588s_rock5c.sh' ;;
    s905) printf 'mk_s905_mxqpro+.sh' ;;
    s905d) printf 'mk_s905d_n1.sh' ;;
    s905x2) printf 'mk_s905x2_x96max.sh' ;;
    s905x3) printf 'mk_s905x3_multi.sh' ;;
    s912) printf 'mk_s912_zyxq.sh' ;;
    s922x) printf 'mk_s922x_gtking.sh' ;;
    s922x-n2) printf 'mk_s922x_odroid-n2.sh' ;;
    vplus) printf 'mk_h6_vplus.sh' ;;
    watermelon-pi) printf 'mk_rk3568_watermelon-pi.sh' ;;
    yixun-rs6pro) printf 'mk_rk3528_rs6pro.sh' ;;
    zcube1-max) printf 'mk_rk3399_zcube1-max.sh' ;;
    *) return 1 ;;
  esac
}

download_kernel_bundle() {
  local kernel_tag kernel_ver url archive
  kernel_tag="$1"
  kernel_ver="$2"
  local release_tag
  release_tag="$(release_tag_for_kernel_tag "$kernel_tag")"
  mkdir -p "$KERNEL_STORE/$kernel_tag/$kernel_ver"

  if [ -f "$KERNEL_STORE/$kernel_tag/$kernel_ver/sha256sums" ]; then
    log "Using existing kernel bundle: $kernel_tag/$kernel_ver"
    return
  fi

  archive="$KERNEL_STORE/$kernel_tag/$kernel_ver.tar.gz"
  url="https://github.com/${KERNEL_REPO_URL}/releases/download/kernel_${release_tag}/${kernel_ver}.tar.gz"
  log "Downloading kernel bundle: $url"
  download_file "$url" "$archive"
  tar -mxf "$archive" -C "$KERNEL_STORE/$kernel_tag"
  rm -f "$archive"
}

resolve_latest_kernel_version() {
  local kernel_tag="$1"
  local kernel_series="$2"
  local kernel_verpatch latest_version release_tag

  release_tag="$(release_tag_for_kernel_tag "$kernel_tag")"

  kernel_verpatch="$(echo "$kernel_series" | awk -F '.' '{print $1"."$2}')"
  latest_version="$({ curl -fsSL "https://github.com/${KERNEL_REPO_URL}/releases/expanded_assets/kernel_${release_tag}" || true; } \
    | grep -oP "${kernel_verpatch}\\.[0-9]+.*?(?=\\.tar\\.gz)" \
    | sort -urV | head -n 1)"

  if [ -n "$latest_version" ]; then
    printf '%s\n' "$latest_version"
  else
    printf '%s\n' "$kernel_series"
  fi
}

effective_kernel_version() {
  local kernel_tag="$1"
  local kernel_version="$KERNEL_VERSION_NAME"

  if [[ "$KERNEL_AUTO_LATEST" =~ ^(true|yes)$ ]]; then
    kernel_version="$(resolve_latest_kernel_version "$kernel_tag" "$kernel_version")"
  fi

  printf '%s\n' "$kernel_version"
}

resolve_kernel_version() {
  local boot_file
  boot_file="$(ls "$KERNEL_STORE"/*/*/boot-* 2>/dev/null | grep "/$(kernel_tag_for_soc "$PACKAGE_SOC")/" | head -n 1 || true)"
  [ -n "$boot_file" ] || die "Unable to locate downloaded kernel files"
  basename "$boot_file" | sed -E 's/^boot-(.*)\.tar\.gz$/\1/'
}

prepare_kernel_runtime_dir() {
  local kernel_tag="$1"
  local kernel_ver="$2"
  local source_dir runtime_dir

  source_dir="$KERNEL_STORE/$kernel_tag/$kernel_ver"
  runtime_dir="$KERNEL_STORE/runtime/$kernel_tag/$kernel_ver"
  mkdir -p "$runtime_dir"
  rm -f "$runtime_dir"/*
  cp -f "$source_dir"/* "$runtime_dir"/

  printf '%s\n' "$runtime_dir"
}

resolve_effective_kernel_version() {
  local runtime_dir="$1"
  local kernel_ver="$2"
  local boot_file

  boot_file="$(find "$runtime_dir" -maxdepth 1 -type f -name "boot-${kernel_ver}*.tar.gz" | head -n 1 || true)"
  [ -n "$boot_file" ] || die "Unable to locate boot archive in $runtime_dir"
  basename "$boot_file" | sed -E 's/^boot-(.*)\.tar\.gz$/\1/'
}

write_make_env() {
  local kernel_version kernel_pkg_home
  kernel_version="$1"
  kernel_pkg_home="$2"
  cd "$PACKIT_DIR"

  if [ "$OPENWRT_VER" = "auto" ] && [ -f make.env ]; then
    OPENWRT_VER="$(grep 'OPENWRT_VER=' make.env | head -n1 | cut -d '"' -f2)"
  fi

  cat > make.env <<EOF
WHOAMI="${WHOAMI}"
OPENWRT_VER="${OPENWRT_VER}"
KERNEL_VERSION="${kernel_version}"
KERNEL_PKG_HOME="${kernel_pkg_home}"
SW_FLOWOFFLOAD="${SW_FLOWOFFLOAD}"
HW_FLOWOFFLOAD="${HW_FLOWOFFLOAD}"
SFE_FLOW="${SFE_FLOW}"
ENABLE_WIFI_K504="${ENABLE_WIFI_K504}"
ENABLE_WIFI_K510="${ENABLE_WIFI_K510}"
DISTRIB_REVISION="${DISTRIB_REVISION}"
DISTRIB_DESCRIPTION="${DISTRIB_DESCRIPTION}"
EOF
}

run_packit() {
  local script kernel_version kernel_tag kernel_home target_output runtime_kernel_dir effective_kernel_version
  script="$(script_for_soc "$PACKAGE_SOC")" || die "Unsupported SOC: $PACKAGE_SOC"
  kernel_tag="$(kernel_tag_for_soc "$PACKAGE_SOC")"
  kernel_version="$(effective_kernel_version "$kernel_tag")"
  log "Using kernel tag/version: $kernel_tag / $kernel_version"

  ensure_packit_repo
  prepare_rootfs_in_packit
  download_kernel_bundle "$kernel_tag" "$kernel_version"

  kernel_home="$KERNEL_STORE/$kernel_tag/$kernel_version"
  [ -d "$kernel_home" ] || die "Kernel directory not found: $kernel_home"

  runtime_kernel_dir="$(prepare_kernel_runtime_dir "$kernel_tag" "$kernel_version")"
  effective_kernel_version="$(resolve_effective_kernel_version "$runtime_kernel_dir" "$kernel_version")"
  log "Using effective kernel version: $effective_kernel_version"

  write_make_env "$effective_kernel_version" "$runtime_kernel_dir"

  target_output="$OUTPUT_DIR"
  mkdir -p "$target_output"

  log "Running packit script: $script"
  cd "$PACKIT_DIR"
  sudo bash "./$script"

  if [ -d "$PACKIT_DIR/output" ] && [ "$PACKIT_DIR/output" != "$target_output" ]; then
    log "Copying packit output to requested directory"
    mkdir -p "$target_output"
    cp -f "$PACKIT_DIR"/output/* "$target_output"/
  fi

  log "Packit output directory: $target_output"
  ls -l "$target_output"
}

run_packit_batch() {
  local soc
  while IFS= read -r soc; do
    [ -n "$soc" ] || continue
    PACKAGE_SOC="$soc"
    log "Starting batch repack for SOC: $PACKAGE_SOC"
    run_packit
  done < <(soc_list)
}

main() {
  parse_args "$@"

  if [ "$FORCE_INIT" -eq 1 ] || [ ! -d "$PACKIT_DIR" ] || [ ! -f "$PACKIT_DIR/public_funcs" ]; then
    log "Initializing packit environment"
    install_dependencies
    check_dependencies
    ensure_rootfs
    run_packit_batch
  else
    log "Skipping initialization; using existing packit environment"
    ensure_rootfs
    run_packit_batch
  fi
}

main "$@"
