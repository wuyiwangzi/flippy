#!/usr/bin/env bash

# Shared helpers for local LEDE/OpenWrt builds.
# Entrypoint scripts must define TARGET_NAME, OPENWRT_DIR, CONFIG_FILE, and SHOW_OUTPUTS_PATTERN before sourcing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/coolsnowwolf/lede}"
REPO_BRANCH="${REPO_BRANCH:-master}"
WORKDIR="${WORKDIR:-$(dirname "$OPENWRT_DIR")}"
FEEDS_CONF="${FEEDS_CONF:-$SCRIPT_DIR/feeds.conf.default}"
DIY_P1_SH="${DIY_P1_SH:-$SCRIPT_DIR/diy-part1.sh}"
DIY_P2_SH="${DIY_P2_SH:-$SCRIPT_DIR/diy-part2.sh}"
JOBS="${JOBS:-$(nproc)}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-8}"
TZ="${TZ:-Asia/Shanghai}"
GO_BOOTSTRAP_ROOT="${GO_BOOTSTRAP_ROOT:-}"
INSTALL_DEPS=1
FORCE_INIT=0

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --force-init     Force re-initialize source, feeds, config, DIY scripts, and downloads
  -h, --help       Show this help

Environment overrides:
  OPENWRT_DIR      OpenWrt source/build directory, default: $OPENWRT_DIR
  JOBS             Compile jobs, default: nproc
  DOWNLOAD_JOBS    Download jobs, default: 8
  GO_BOOTSTRAP_ROOT External bootstrap Go root directory
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-init)
        FORCE_INIT=1
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

install_dependencies() {
  log "Installing build dependencies"
  sudo apt update -y
  sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache clang cmake cpio curl device-tree-compiler flex gawk gettext genisoimage git gperf \
    haveged help2man intltool libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev libltdl-dev \
    libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev libpython3-dev libreadline-dev \
    libssl-dev libtool llvm lld lrzsz libnsl-dev ninja-build p7zip p7zip-full patch pkgconf \
    python3 python3-pyelftools python3-setuptools python3-setuptools-whl python3-distutils-extra \
    qemu-utils rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim \
    wget xmlto xxd zlib1g-dev golang-go
}

check_dependencies() {
  local missing=0
  local cmds=(git make gcc g++ gawk curl rsync unzip bzip2 wget python3 file patch diff find xargs grep gzip realpath stat tar)

  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done

  if ! printf '#include <ncurses.h>\nint main(void){return 0;}\n' | gcc -x c - -o /tmp/opencode/ncurses-check >/dev/null 2>&1; then
    printf 'Missing required development header: ncurses.h\n' >&2
    missing=1
  else
    rm -f /tmp/opencode/ncurses-check
  fi

  if ! python3 - <<'PY' >/dev/null 2>&1
try:
    from distutils import util
except Exception:
    from setuptools._distutils import util  # noqa: F401
PY
  then
    printf 'Missing required Python distutils support\n' >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    die "Missing required build tools. Install packages first or check apt setup."
  fi
}

detect_go_bootstrap() {
  if [ -n "$GO_BOOTSTRAP_ROOT" ]; then
    return
  fi

  if command -v go >/dev/null 2>&1; then
    GO_BOOTSTRAP_ROOT="$(go env GOROOT 2>/dev/null || true)"
  fi

  if [ -z "$GO_BOOTSTRAP_ROOT" ]; then
    for candidate in /usr/lib/go /usr/lib/go-*; do
      if [ -x "$candidate/bin/go" ]; then
        GO_BOOTSTRAP_ROOT="$candidate"
        break
      fi
    done
  fi
}

clone_or_update_source() {
  mkdir -p "$WORKDIR"

  if [ ! -d "$OPENWRT_DIR/.git" ]; then
    log "Cloning source: $REPO_URL -b $REPO_BRANCH"
    git clone "$REPO_URL" -b "$REPO_BRANCH" "$OPENWRT_DIR"
  else
    log "Using existing source directory: $OPENWRT_DIR"
  fi
}

reset_diy_touched_files() {
  log "Resetting files touched by DIY scripts"
  cd "$OPENWRT_DIR"

  git checkout -- \
    package/base-files/files/etc/passwd \
    package/base-files/files/etc/profile \
    package/base-files/files/etc/shells \
    package/lean/autocore/Makefile \
    target/linux/x86/image/grub-efi.cfg \
    2>/dev/null || true

  rm -rf files/root package/custom
}

load_custom_feeds() {
  log "Loading custom feeds and running diy-part1.sh"
  cd "$OPENWRT_DIR"

  if [ -f "$FEEDS_CONF" ]; then
    cp -f "$FEEDS_CONF" feeds.conf.default
  fi

  chmod +x "$DIY_P1_SH"
  "$DIY_P1_SH"
}

update_and_install_feeds() {
  log "Updating feeds"
  cd "$OPENWRT_DIR"
  ./scripts/feeds update -a

  log "Installing feeds"
  ./scripts/feeds install -a
}

load_custom_config() {
  log "Loading $TARGET_NAME config and running diy-part2.sh"
  cd "$OPENWRT_DIR"

  if [ -d "$SCRIPT_DIR/files" ]; then
    rm -rf files
    cp -a "$SCRIPT_DIR/files" files
  fi

  [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
  cp -f "$CONFIG_FILE" .config

  chmod +x "$DIY_P2_SH"
  "$DIY_P2_SH"
}

apply_local_config_fixes() {
  log "Applying local-only config fixes"
  cd "$OPENWRT_DIR"

  case "$(uname -m)" in
    arm64|aarch64)
      detect_go_bootstrap
      if [ -n "$GO_BOOTSTRAP_ROOT" ] && [ -x "$GO_BOOTSTRAP_ROOT/bin/go" ]; then
        if grep -q '^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=' .config; then
          sed -i "s|^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=.*|CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"$GO_BOOTSTRAP_ROOT\"|" .config
        else
          printf 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_BOOTSTRAP_ROOT" >> .config
        fi
        log "Using external Go bootstrap: $GO_BOOTSTRAP_ROOT"
      else
        log "No external Go bootstrap found; golang/host may fail on arm64 hosts"
      fi

      # If staging_dir recorded a Homebrew Python without distutils, force OpenWrt to re-detect system Python.
      if [ -L staging_dir/host/bin/python3 ]; then
        case "$(readlink staging_dir/host/bin/python3)" in
          *linuxbrew*|*homebrew*) rm -f staging_dir/host/bin/python3 ;;
        esac
      fi
      ;;
    *)
      log "Skipping ARM-specific host fixes on non-ARM host"
      ;;
  esac
}

download_sources() {
  log "Generating config and downloading source archives"
  cd "$OPENWRT_DIR"
  make defconfig
  make download -j"$DOWNLOAD_JOBS"

  log "Removing incomplete downloads smaller than 1024 bytes"
  find dl -size -1024c -exec ls -l {} \;
  find dl -size -1024c -exec rm -f {} \;
}

compile_firmware() {
  log "Compiling firmware with $JOBS jobs"
  cd "$OPENWRT_DIR"
  make -j"$JOBS" || make -j1 || make -j1 V=s
}

show_outputs() {
  log "Build outputs"
  cd "$OPENWRT_DIR"
  if [ -d bin/targets ]; then
    # shellcheck disable=SC2086
    find bin/targets -maxdepth 4 -type f $SHOW_OUTPUTS_PATTERN
  else
    log "No bin/targets directory found"
  fi
}

ensure_existing_source() {
  [ -d "$OPENWRT_DIR" ] || die "OpenWrt directory not found: $OPENWRT_DIR. Run with --init first."
  [ -f "$OPENWRT_DIR/Makefile" ] || die "Not an OpenWrt source directory: $OPENWRT_DIR. Run with --init first."
}

run_local_build() {
  parse_args "$@"

  log "Local $TARGET_NAME build started"
  log "Workspace: $WORKDIR"
  log "Source: $OPENWRT_DIR"

  if [ "$FORCE_INIT" -eq 1 ] || [ ! -d "$OPENWRT_DIR" ] || [ ! -f "$OPENWRT_DIR/Makefile" ]; then
    log "Initializing OpenWrt build environment"
    install_dependencies
    check_dependencies
    clone_or_update_source
    reset_diy_touched_files
    load_custom_feeds
    update_and_install_feeds
    load_custom_config
    apply_local_config_fixes
    download_sources
  else
    log "Skipping initialization; using existing build environment"
    ensure_existing_source
  fi

  compile_firmware
  show_outputs
}
