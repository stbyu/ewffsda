#!/usr/bin/env bash
set -Eeuo pipefail
unset DOWNLOAD_MIRROR || true

SCRIPT_VERSION="2.1.1-config-init"
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

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file not found: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "Required directory not found: $1"
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
  local attempt

  for attempt in 1 2 3 4 5; do
    rm -rf "$destination"

    if git clone --filter=blob:none --no-checkout "$url" "$destination" &&
       git -C "$destination" fetch --depth=1 origin "$commit" &&
       git -C "$destination" checkout --detach FETCH_HEAD; then
      return 0
    fi

    printf 'Git download failed; retry %s/5 after %s seconds\n' \
      "$attempt" "$((attempt * 15))" >&2
    sleep "$((attempt * 15))"
  done

  fail "Unable to download $url after 5 attempts"
}

copy_package_from_repo() {
  local repository_root="$1"
  local package_name="$2"
  local source_path=""
  local display_path=""
  local destination="$CUSTOM_FEED_DIR/$package_name"

  require_dir "$repository_root"

  if [[ -f "$repository_root/$package_name/Makefile" ]]; then
    source_path="$repository_root/$package_name"
  else
    source_path="$(find "$repository_root" -mindepth 1 -maxdepth 6 \
      -type f -path "*/$package_name/Makefile" -printf '%h\n' -quit)"
  fi

  if [[ -z "$source_path" && -f "$repository_root/Makefile" ]]; then
    source_path="$repository_root"
  fi

  if [[ -z "$source_path" ]]; then
    printf 'Repository layout under %s:\n' "$repository_root" >&2
    find "$repository_root" -maxdepth 4 -type f -name Makefile -print >&2 || true
    fail "Could not locate package '$package_name' in $repository_root"
  fi

  [[ ! -e "$destination" ]] || fail "Duplicate custom package directory: $destination"
  mkdir -p "$destination"
  rsync -a --exclude=.git --exclude=.github "$source_path/" "$destination/"
  require_file "$destination/Makefile"
  display_path="${source_path#"$repository_root"}"
  display_path="${display_path#/}"
  log "Located $package_name at ${display_path:-repository root}"
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

  require_file "$CUSTOM_FEED_DIR/luci-app-ssr-plus/Makefile"
  require_file "$CUSTOM_FEED_DIR/shadowsocksr-libev/Makefile"

  copy_package_from_repo "$SOURCE_DIR/guest-wifi" luci-app-guest-wifi
  copy_package_from_repo "$SOURCE_DIR/openwrt-ext" gowebdav
  copy_package_from_repo "$SOURCE_DIR/openwrt-ext" luci-app-gowebdav
  copy_package_from_repo "$SOURCE_DIR/wrtbwmon" wrtbwmon
  copy_package_from_repo "$SOURCE_DIR/luci-app-wrtbwmon" luci-app-wrtbwmon

  if grep -q '+iptables' "$CUSTOM_FEED_DIR/wrtbwmon/Makefile"; then
    sed -i 's/+iptables/+iptables-nft/g' "$CUSTOM_FEED_DIR/wrtbwmon/Makefile"
  fi
}

configure_custom_packages() {
  log "Installing feeds and selecting custom packages"
  cd "$SDK_DIR"

  require_file "$SDK_DIR/Makefile"
  require_file "$SDK_DIR/feeds.conf.default"
  [[ -x "$SDK_DIR/scripts/feeds" ]] || fail "SDK scripts/feeds is missing or not executable"

  printf '\nsrc-link custom %s\n' "$CUSTOM_FEED_DIR" >> feeds.conf.default
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  ./scripts/feeds install -a -f -p custom

  if [[ -f config.buildinfo ]]; then
    cp -f config.buildinfo .config
  else
    touch .config
  fi

  sed -i \
    -e '/^CONFIG_PACKAGE_/d' \
    -e '/CONFIG_ALL_KMODS/d' \
    -e '/CONFIG_ALL_NONSHARED/d' \
    -e '/CONFIG_DEVEL/d' \
    .config

  cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-ssr-plus=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-server=m
CONFIG_PACKAGE_luci-app-guest-wifi=m
CONFIG_PACKAGE_gowebdav=m
CONFIG_PACKAGE_luci-app-gowebdav=m
CONFIG_PACKAGE_wrtbwmon=m
CONFIG_PACKAGE_luci-app-wrtbwmon=m
EOF
  make defconfig

  local symbol
  for symbol in \
    luci-app-ssr-plus luci-app-guest-wifi gowebdav luci-app-gowebdav \
    wrtbwmon luci-app-wrtbwmon; do
    grep -Eq "^CONFIG_PACKAGE_${symbol}=[my]$" .config || \
      fail "Package symbol was not accepted by make defconfig: $symbol"
  done
}

compile_custom_packages() {
  log "Compiling only selected custom packages"
  cd "$SDK_DIR"

  local targets=(
    package/feeds/custom/luci-app-ssr-plus/compile
    package/feeds/custom/shadowsocksr-libev/compile
    package/feeds/custom/luci-app-guest-wifi/compile
    package/feeds/custom/gowebdav/compile
    package/feeds/custom/luci-app-gowebdav/compile
    package/feeds/custom/wrtbwmon/compile
    package/feeds/custom/luci-app-wrtbwmon/compile
  )

  if ! make -j"$(nproc)" "${targets[@]}" V=s; then
    log "Parallel build failed; retrying selected packages serially"
    make -j1 "${targets[@]}" V=sc
  fi

  mkdir -p "$OUTPUT_DIR/custom-ipks"
  require_dir "$SDK_DIR/bin/packages"
  mapfile -d '' custom_ipks < <(find bin/packages -type f -path '*/custom/*.ipk' -print0)
  if (( ${#custom_ipks[@]} == 0 )); then
    find bin/packages -type f -name '*.ipk' -print >&2 || true
    fail "No IPKs were produced under the custom feed output directory"
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
  require_dir "$PROJECT_DIR/files"
  require_file "$PROJECT_DIR/files/etc/uci-defaults/99-upgrade-defaults"
  cp -a "$PROJECT_DIR/files/." "$WORK_DIR/files/"
  sed -i \
    -e "s/__FLOW_SOFTWARE__/$software/g" \
    -e "s/__FLOW_HARDWARE__/$hardware/g" \
    "$WORK_DIR/files/etc/uci-defaults/99-upgrade-defaults"
  chmod +x "$WORK_DIR/files/etc/uci-defaults/99-upgrade-defaults"
  if grep -R -q '__FLOW_' "$WORK_DIR/files"; then
    fail "An unresolved flow-offloading placeholder remains in the overlay"
  fi
}

build_firmware() {
  log "Building Raspberry Pi 3 ext4 firmware with ImageBuilder"
  require_file "$IMAGEBUILDER_DIR/Makefile"
  require_file "$IMAGEBUILDER_DIR/repositories.conf"
  require_file "$PROJECT_DIR/packages.txt"
  mkdir -p "$IMAGEBUILDER_DIR/packages" "$OUTPUT_DIR/firmware"
  mapfile -d '' imagebuilder_ipks < <(find "$OUTPUT_DIR/custom-ipks" -maxdepth 1 -type f -name '*.ipk' -print0)
  (( ${#imagebuilder_ipks[@]} > 0 )) || fail "No custom IPKs are available for ImageBuilder"
  cp -v "${imagebuilder_ipks[@]}" "$IMAGEBUILDER_DIR/packages/"

  if [[ "${IWRT_SOURCE_MIRROR:-official}" == "zju" ]]; then
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
  mapfile -d '' factory_images < <(find firmware -maxdepth 1 -type f -name '*rpi-3-ext4-factory.img.gz' -print0)
  (( ${#factory_images[@]} > 0 )) || fail "ImageBuilder completed without an ext4 factory image"

  find firmware custom-ipks -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  {
    printf 'ImmortalWrt version: %s\n' "$VERSION"
    printf 'Build script: %s\n' "$SCRIPT_VERSION"
    printf 'Target: %s\n' "$TARGET"
    printf 'Profile: %s\n' "$PROFILE"
    printf 'Rootfs: ext4, 1024 MiB\n'
    printf 'Download mirror: %s\n' "${IWRT_SOURCE_MIRROR:-official}"
    printf 'Flow offloading: %s\n' "${FLOW_OFFLOADING:-disabled}"
    printf 'GitHub run: %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  } > build-info.txt

  gzip -t "${factory_images[@]}"
  find . -maxdepth 2 -type f -printf '%p %k KiB\n' | sort
}

main() {
  case "${IWRT_SOURCE_MIRROR:-official}" in
    official) base_url="https://downloads.immortalwrt.org/releases/$VERSION/targets/$TARGET" ;;
    zju) base_url="https://mirrors.zju.edu.cn/immortalwrt/releases/$VERSION/targets/$TARGET" ;;
    *) printf 'Unsupported IWRT_SOURCE_MIRROR value: %s\n' "$IWRT_SOURCE_MIRROR" >&2; exit 2 ;;
  esac

  [[ "$WORK_DIR" == "$PROJECT_DIR/"* && "$OUTPUT_DIR" == "$PROJECT_DIR/"* ]] || \
    fail "Refusing to clean paths outside the project directory"
  rm -rf "$WORK_DIR" "$OUTPUT_DIR"
  mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$OUTPUT_DIR"

  log "Downloading verified ImmortalWrt SDK and ImageBuilder"
  download_file "$base_url/$SDK_FILE" "$DOWNLOAD_DIR/$SDK_FILE"
  download_file "$base_url/$IMAGEBUILDER_FILE" "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE"
  printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD_DIR/$SDK_FILE" | sha256sum -c -
  printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE" | sha256sum -c -

  mkdir -p "$SDK_DIR" "$IMAGEBUILDER_DIR"
  tar --zstd -xf "$DOWNLOAD_DIR/$SDK_FILE" -C "$SDK_DIR" --strip-components=1
  tar --zstd -xf "$DOWNLOAD_DIR/$IMAGEBUILDER_FILE" -C "$IMAGEBUILDER_DIR" --strip-components=1
  require_file "$SDK_DIR/Makefile"
  require_file "$IMAGEBUILDER_DIR/Makefile"

  prepare_custom_feed
  configure_custom_packages
  compile_custom_packages
  prepare_overlay
  build_firmware
  write_build_metadata
}

main "$@"
