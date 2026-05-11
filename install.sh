#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-Miaocchi/Latest-Kernel-BBR3-UCP}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/latest-kernel-bbr3-ucp}"
KEEP_DEBS="${KEEP_DEBS:-0}"
RELEASE_OFFSET="${RELEASE_OFFSET:-0}"

log() {
  printf '[INFO] %s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: sudo bash install.sh"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq wget
  else
    for cmd in curl jq wget; do
      command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
    done
  fi
}

latest_release_for_arch() {
  local arch="$1"
  curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=50" |
    jq -r --arg arch "${arch}-" --argjson offset "$RELEASE_OFFSET" '[.[] | select(.tag_name | startswith($arch))][$offset].tag_name // empty'
}

asset_urls_for_tag() {
  local tag="$1"
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${tag}" |
    jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url'
}

download_assets() {
  local tag="$1"
  local urls
  urls="$(asset_urls_for_tag "$tag")"
  [ -n "$urls" ] || die "No .deb assets found in release ${tag}"

  rm -rf "$DOWNLOAD_DIR"
  mkdir -p "$DOWNLOAD_DIR"

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    log "Downloading $(basename "$url")"
    wget -q --show-progress -P "$DOWNLOAD_DIR" "$url"
  done <<< "$urls"
}

install_kernel() {
  local deb_count
  deb_count="$(find "$DOWNLOAD_DIR" -maxdepth 1 -name '*.deb' | wc -l)"
  [ "$deb_count" -gt 0 ] || die "No .deb files downloaded"

  log "Installing kernel packages"
  dpkg -i "$DOWNLOAD_DIR"/*.deb || apt-get -f install -y
}

show_post_install() {
  cat <<'EOF'

Installation finished.

Reboot to use the new kernel:
  sudo reboot

After reboot, check:
  uname -r
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.core.default_qdisc

Expected defaults:
  net.ipv4.tcp_congestion_control = ucp
  net.core.default_qdisc = fq
EOF
}

main() {
  require_root
  install_dependencies

  local arch tag
  arch="$(detect_arch)"
  log "Detected architecture: ${arch}"

  tag="$(latest_release_for_arch "$arch")"
  [ -n "$tag" ] || die "No release found for architecture ${arch} in ${REPO} at offset ${RELEASE_OFFSET}"
  log "Using release: ${tag}"

  download_assets "$tag"
  install_kernel

  if [ "$KEEP_DEBS" != "1" ]; then
    rm -rf "$DOWNLOAD_DIR"
  else
    log "Keeping downloaded packages in ${DOWNLOAD_DIR}"
  fi

  show_post_install
}

main "$@"
