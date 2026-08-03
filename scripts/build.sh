#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="24.10.6"
TARGET="bcm27xx/bcm2710"
PROFILE="rpi-3"
SDK_FILE="immortalwrt-sdk-24.10.6-bcm27xx-bcm2710_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
IMAGEBUILDER_FILE="immortalwrt-imagebuilder-24.10.6-bcm27xx-bcm2710.Linux-x86_64.tar.zst"
SDK_SHA256="6f6db9fb0f0a72ebb40f3bab4997935187c5e40803bad9e5f376dab719d347af"
IMAGEBUILDER_SHA256="01cabb82c91b1246360532c332fb339e11464273100a1158c032faa5c50c12a8"

PROJECT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_DIR="$PROJECT_DIR/build-work"
DOWNLOAD_DIR="$WORK_DIR/downloads"
SOURCE_DIR="$WORK_DIR/sources"
CUSTOM_FEED_DIR="$WORK_DIR/custom-feed"
SDK_DIR="$WORK_DIR/sdk"
IMAGEBUILDER_DIR="$WORK_DIR/imagebuilder"
OUTPUT_DIR="$PROJECT_DIR/output"

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

download_file() {
  local url="$1"
  local destination="$2"
  wget --tries=5 --timeout=30 --waitretry=5 --continue -O "$destination" "$url"
}

checkout_commit() {
  local url="$1"
  local commit="$2"
  local destination="$3"

  git clone --filter=blob:none --no-checkout "$url" "$destination"
  git -C "$destination" fetch --depth=1 origin "$commit"
  git -C "$destination" checkout --detach FETCH_HEAD
}

prepare_custom_feed() {
  log "Fetching pinned third-party package sources"

  checkout_commit \
    https://github.com/fw876/helloworld.git \
    744f2a4a01e87cfba4cbf973e65525902c39de2a \
    "$SOURCE_DIR/helloworld"

  checkout_commit \
    https://github.com/kenzok78/luci-app-guest-wifi.git \
    58dcd53a04d8790b75e93da2df3876b54a701374 \
    "$SOURCE_DIR/guest-wifi"

  checkout_commit \
    https://github.com/N-wrt/openwrt-ext.git \
    53b06fc4651497ebd6edbf138707dec3c6a13432 \
    "$SOURCE_DIR/openwrt-ext"

  checkout_commit \
    https://github.com/brvphoenix/wrtbwmon.git \
    f82f9b393842d2113c3253a4902af50bfc757e1a \
    "$SOURCE_DIR/wrtbwmon"

  checkout_commit \
    https://github.com/brvphoenix/luci-app-wrtbwmon.git \
    f1b59b2309a0bc45511a1e7432c6c72f080a47d7 \
    "$SOURCE_DIR/luci-app-wrtbwmon"

  mkdir -p "$CUSTOM_FEED_DIR"
  rsync -a --exclude=.git --exclude=.github \
    "$SOURCE_DIR/helloworld/" "$CUSTOM_FEED_DIR/"

  mkdir -p "$CUSTOM_FEED_DIR/luci-app-guest-wifi"
  rsync -a --exclude=.git --exclude=.github \
    "$SOURCE_DIR/guest-wifi/" "$CUSTOM_FEED_DIR/luci-app-guest-wifi/"
  cp -a "$SOURCE_DIR/openwrt-ext/op-webdav/gowebdav" "$CUSTOM_FEED_DIR/"
  cp -a "$SOURCE_DIR/openwrt-ext/op-webdav/luci-app-gowebdav" "$CUSTOM_FEED_DIR/"
  cp -a "$SOURCE_DIR/wrtbwmon/wrtbwmon" "$CUSTOM_FEED_DIR/"
  cp -a "$SOURCE_DIR/luci-app-wrtbwmon/luci-app-wrtbwmon" "$CUSTOM_FEED_DIR/"

  if grep -q '+iptables' "$CUSTOM_FEED_DIR/wrtbwmon/Makefile"; then
    sed -i 's/+iptables/+iptables-nft/g' "$CUSTOM_FEED_DIR/wrtbwmon/Makefile"
  fi
}

configure_custom_packages() {
  log "Installing feeds and selecting custom packages"
  cd "$SDK_DIR"

  printf '\nsrc-link custom %s\n' "$CUSTOM_FEED_DIR" >> feeds.conf.default
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  ./scripts/feeds install -a -f -p custom

  touch .config
  ./scripts/config --module PACKAGE_luci-app-ssr-plus
  ./scripts/config --module PACKAGE_shadowsocksr-libev-ssr-local
  ./scripts/config --module PACKAGE_shadowsocksr-libev-ssr-redir
  ./scripts/config --module PACKAGE_shadowsocksr-libev-ssr-server
  ./scripts/config --module PACKAGE_luci-app-guest-wifi
  ./scripts/config --module PACKAGE_gowebdav
  ./scripts/config --module PACKAGE_luci-app-gowebdav
  ./scripts/config --module PACKAGE_wrtbwmon
  ./scripts/config --module PACKAGE_luci-app-wrtbwmon
  make defconfig
}

compile_custom_packages() {
  log "Downloading and compiling selected SDK packages"
  cd "$SDK_DIR"
  make download -j"$(nproc)"

  if ! make package/compile -j"$(nproc)" V=s; then
    log "Parallel build failed; retrying serially for a useful error log"
    make package/compile -j1 V=sc
  fi

  mkdir -p "$OUTPUT_DIR/custom-ipks"
  mapfile -d '' custom_ipks < <(find bin/packages -type f -path '*/custom/*.ipk' -print0)
  if (( ${#custom_ipks[@]} == 0 )); then
    printf 'No custom-feed IPKs were produced.\n' >&2
    exit 1
  fi
  cp -v "${custom_ipks[@]}" "$OUTPUT_DIR/custom-ipks/"
}

prepare_overlay() {
  local software=0
  local hardware=0

  case "${FLOW_OFFLOADING:-disabled}" in
    disabled) ;;
    software) software=1 ;;
    hardware) software=1; hardware=1 ;;
    *) printf 'Unsupported FLOW_OFFLOADING value: %s\n' "$FLOW_OFFLOADING" >&2; exit 2 ;;
  esac

  mkdir -p "$WORK_DIR/files"
  cp -a "$PROJECT_DIR/files/." "$WORK_DIR/files/"
  sed -i \
    -e "s/__FLOW_SOFTWARE__/$software/g" \
    -e "s/__FLOW_HARDWARE__/$hardware/g" \
    "$WORK_DIR/files/etc/uci-defaults/99-upgrade-defaults"
  chmod +x "$WORK_DIR/files/etc/uci-defaults/99-upgrade-defaults"
}

build_firmware() {
  log "Building Raspberry Pi 3 ext4 firmware with ImageBuilder"
  mkdir -p "$IMAGEBUILDER_DIR/packages" "$OUTPUT_DIR/firmware"
  cp -v "$OUTPUT_DIR/custom-ipks/"*.ipk "$IMAGEBUILDER_DIR/packages/"

  if [[ "${DOWNLOAD_MIRROR:-official}" == "zju" ]]; then
    sed -i \
      's#https://downloads.immortalwrt.org/#https://mirrors.zju.edu.cn/immortalwrt/#g' \
      "$IMAGEBUILDER_DIR/repositories.conf"
  fi

  local packages
  packages="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$PROJECT_DIR/packages.txt" | tr '\n' ' ')"

  cd "$IMAGEBUILDER_DIR"
  make image \
    PROFILE="$PROFILE" \
    PACKAGES="$packages" \
    FILES="$WORK_DIR/files" \
    ROOTFS_PARTSIZE=1024 \
    BIN_DIR="$OUTPUT_DIR/firmware"
}

write_build_metadata() {
  log "Writing checksums and build information"
  cd "$OUTPUT_DIR"
  find firmware custom-ipks -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  {
    printf 'ImmortalWrt version: %s\n' "$VERSION"
    printf 'Target: %s\n' "$TARGET"
    printf 'Profile: %s\n' "$PROFILE"
    printf 'Rootfs: ext4, 1024 MiB\n'
    printf 'Download mirror: %s\n' "${DOWNLOAD_MIRROR:-official}"
    printf 'Flow offloading: %s\n' "${FLOW_OFFLOADING:-disabled}"
    printf 'GitHub run: %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  } > build-info.txt

  gzip -t firmware/*rpi-3-ext4-factory.img.gz
  find . -maxdepth 2 -type f -printf '%p %k KiB\n' | sort
}

main() {
  case "${DOWNLOAD_MIRROR:-official}" in
    official) base_url="https://downloads.immortalwrt.org/releases/$VERSION/targets/$TARGET" ;;
    zju) base_url="https://mirrors.zju.edu.cn/immortalwrt/releases/$VERSION/targets/$TARGET" ;;
    *) printf 'Unsupported DOWNLOAD_MIRROR value: %s\n' "$DOWNLOAD_MIRROR" >&2; exit 2 ;;
  esac

  rm -rf "$WORK_DIR" "$OUTPUT_DIR"
  mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$OUTPUT_DIR"

  log "Downloading verified ImmortalWrt SDK and ImageBuilder"
  download_file "$base_url/$SDK_FILE" "$DOWNLOAD_DIR/$SDK_FILE"
  download_file "$base_url/$IMAGEBUILDER_FILE" "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE"
  printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD_DIR/$SDK_FILE" | sha256sum -c -
  printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE" | sha256sum -c -

  tar --zstd -xf "$DOWNLOAD_DIR/$SDK_FILE" -C "$WORK_DIR"
  tar --zstd -xf "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE" -C "$WORK_DIR"
  mv "$WORK_DIR/${SDK_FILE%.tar.zst}" "$SDK_DIR"
  mv "$WORK_DIR/${IMAGEBUILDER_FILE%.tar.zst}" "$IMAGEBUILDER_DIR"

  prepare_custom_feed
  configure_custom_packages
  compile_custom_packages
  prepare_overlay
  build_firmware
  write_build_metadata
}

main "$@"

