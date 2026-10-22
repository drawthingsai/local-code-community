#!/bin/bash
set -euo pipefail

export COPYFILE_DISABLE=1
export LC_ALL=C

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VENDOR_DIR="$REPO_ROOT/Vendors/NodeJS"

NODEJS_VERSION=24.22.1
NODEJS_SOURCE_REPO=https://github.com/nodejs/node
NODEJS_SOURCE_URL=https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.gz
NODEJS_SOURCE_SHA256=001773d9bd53fbd27a25efd42aa6a9693ebfe500998ca9bec635e9b6ee79bc91
NODEJS_MOBILE_PORT_REPO=https://github.com/gmaclennan/nodejs-mobile
NODEJS_MOBILE_PORT_COMMIT=9eec30ebe09e4146bc557740da02baae88051721
NODEJS_MOBILE_PORT_BASE_VERSION=24.19.0
NODEJS_AUDIT_CROSSCHECK_REPO=https://github.com/origami-ltd/nodejs-mobile
NODEJS_AUDIT_CROSSCHECK_COMMIT=6ea1971786a98e3a320e68ed254ecb88c12bdca6
NPM_VERSION=11.19.1
NPM_COMMAND_ARCHIVE="$VENDOR_DIR/Resources/NodeMobile/Commands/npm-$NPM_VERSION.zip"
NPM_COMMAND_ARCHIVE_SHA256=23a3c442e6e165888dc455a0fea799579b19c1b80a8eb071afdc82438efaa18a

IOS_MINIMUM_OS_VERSION=${IOS_MINIMUM_OS_VERSION:-15.4}
MACOS_MINIMUM_OS_VERSION=13.5
BUILD_DIR=${BUILD_DIR:-/private/tmp/nodejs-mobile-$NODEJS_VERSION-build}
SOURCE_DIR="$BUILD_DIR/source"
SOURCE_ARCHIVE=${NODEJS_SOURCE_ARCHIVE:-/private/tmp/node-v$NODEJS_VERSION.tar.gz}
MOBILE_PATCH_FILE="$VENDOR_DIR/Patches/nodejs-mobile-ios.patch"
LOCAL_PATCH_FILE="$VENDOR_DIR/Patches/local-code-ios.patch"
if [[ -z "${JOBS:-}" ]]; then
  JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)
fi

COMMON_ARCHIVES=(
  libabseil.a
  libada.a
  libbrotli.a
  libcares.a
  libhistogram.a
  libllhttp.a
  libmerve.a
  libnbytes.a
  libncrypto.a
  libncrypto_engine.a
  libnghttp2.a
  libnode.a
  libnode_base.a
  libopenssl.a
  libsimdjson.a
  libsimdutf.a
  libuv.a
  libuvwasi.a
  libv8_base_without_compiler.a
  libv8_compiler.a
  libv8_initializers.a
  libv8_libbase.a
  libv8_libplatform.a
  libv8_snapshot.a
  libv8_zlib.a
  libhighway.a
  libzlib.a
  libzstd.a
)

FULL_ARCHIVES=(
  libcrdtp.a
  libsqlite.a
  libicudata.a
  libicui18n.a
  libicustubdata.a
  libicuucx.a
  libv8_initializers_slow.a
)

ARM64_ARCHIVES=(
  libzlib_data_chunk_simd.a
)

MACOS_ARM64_ARCHIVES=(
  libzlib_adler32_simd.a
  libzlib_arm_crc32.a
)

ARCHIVES=(
  "${COMMON_ARCHIVES[@]}"
  "${FULL_ARCHIVES[@]}"
  "${ARM64_ARCHIVES[@]}"
)

fail() {
  echo "error: $*" >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

prepare_source() {
  mkdir -p "$(dirname "$SOURCE_ARCHIVE")" "$BUILD_DIR"
  if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
    local temporary_archive="$SOURCE_ARCHIVE.download"
    rm -f "$temporary_archive"
    curl --fail --location --retry 3 --output "$temporary_archive" "$NODEJS_SOURCE_URL"
    mv "$temporary_archive" "$SOURCE_ARCHIVE"
  fi

  local actual_sha256
  actual_sha256=$(sha256_file "$SOURCE_ARCHIVE")
  if [[ "$actual_sha256" != "$NODEJS_SOURCE_SHA256" ]]; then
    fail "source checksum mismatch: expected $NODEJS_SOURCE_SHA256, got $actual_sha256"
  fi

  rm -rf "$SOURCE_DIR"
  mkdir -p "$SOURCE_DIR"
  tar -xzf "$SOURCE_ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"
  patch -d "$SOURCE_DIR" -p1 < "$MOBILE_PATCH_FILE"
  patch -d "$SOURCE_DIR" -p1 < "$LOCAL_PATCH_FILE"
  cp "$VENDOR_DIR/Sources/NodeMobile.h" "$SOURCE_DIR/src/NodeMobile.h"
  cp \
    "$VENDOR_DIR/Sources/NodeRuntimeHost.cpp" \
    "$SOURCE_DIR/src/node_mobile_runtime_host.cc"

  grep -q '#define NODE_MOBILE_MAJOR_VERSION 24' "$SOURCE_DIR/src/node_mobile_version.h" ||
    fail "source is not the expected Node.js Mobile major version"
  grep -q '#define NODE_MOBILE_MINOR_VERSION 22' "$SOURCE_DIR/src/node_mobile_version.h" ||
    fail "source is not the expected Node.js Mobile minor version"
  grep -q '#define NODE_MOBILE_PATCH_VERSION 1' "$SOURCE_DIR/src/node_mobile_version.h" ||
    fail "source is not the expected Node.js Mobile patch version"
}

package_npm_commands() {
  grep -q "\"version\": \"$NPM_VERSION\"" "$SOURCE_DIR/deps/npm/package.json" ||
    fail "source does not contain npm $NPM_VERSION"
  mkdir -p "$(dirname "$NPM_COMMAND_ARCHIVE")"
  find "$(dirname "$NPM_COMMAND_ARCHIVE")" -maxdepth 1 -type f -name "npm-*.zip" \
    ! -name "npm-$NPM_VERSION.zip" -delete
  rm -f "$NPM_COMMAND_ARCHIVE"
  (
    cd "$SOURCE_DIR/deps/npm"
    find . -type f ! -path "*/test/*" -print |
      sort |
      zip -X -q -9 "$NPM_COMMAND_ARCHIVE" -@
  )
  local actual_sha256
  actual_sha256=$(sha256_file "$NPM_COMMAND_ARCHIVE")
  if [[ "$actual_sha256" != "$NPM_COMMAND_ARCHIVE_SHA256" ]]; then
    fail "npm command archive checksum mismatch: expected $NPM_COMMAND_ARCHIVE_SHA256, got $actual_sha256"
  fi
}

build_slice() {
  local slice=$1
  local sdk min_version_flag minimum_os_version platform target_os
  local cross_compiling=0
  local -a configure_flags slice_archives

  case "$slice" in
    ios-arm64)
      sdk=iphoneos
      min_version_flag="-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION"
      minimum_os_version="$IOS_MINIMUM_OS_VERSION"
      platform=ios
      target_os=ios
      cross_compiling=1
      ;;
    ios-arm64-simulator)
      sdk=iphonesimulator
      min_version_flag="-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION"
      minimum_os_version="$IOS_MINIMUM_OS_VERSION"
      platform=ios-simulator
      target_os=ios
      cross_compiling=1
      ;;
    macos-arm64)
      sdk=macosx
      min_version_flag="-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION"
      minimum_os_version="$MACOS_MINIMUM_OS_VERSION"
      platform=macos
      target_os=mac
      ;;
    *)
      fail "unknown slice: $slice"
      ;;
  esac

  slice_archives=("${ARCHIVES[@]}")
  if [[ "$slice" == "macos-arm64" ]]; then
    slice_archives+=("${MACOS_ARM64_ARCHIVES[@]}")
  fi

  rm -rf "$SOURCE_DIR/out"
  configure_flags=(
    "--dest-os=$target_os"
    --dest-cpu=arm64
    --with-intl=small-icu
    --enable-static
    --openssl-no-asm
    "--v8-options=--jitless --wasm-jitless"
    --without-node-code-cache
    --without-node-snapshot
  )
  if [[ "$cross_compiling" == 1 ]]; then
    configure_flags+=(--cross-compiling)
  fi
  if [[ "$slice" == "ios-arm64-simulator" ]]; then
    configure_flags+=(--ios-simulator)
  fi

  echo "Building Node.js $NODEJS_VERSION for $slice"
  (
    cd "$SOURCE_DIR"
    if [[ "$slice" == "macos-arm64" ]]; then
      export MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION"
    fi
    export GYP_DEFINES="target_arch=arm64 host_os=mac target_os=$target_os v8_enable_drumbrake=1 v8_drumbrake_bounds_checks=1"
    ./configure "${configure_flags[@]}"
    make -j"$JOBS" node
  )

  local release_dir="$SOURCE_DIR/out/Release"
  local archive
  for archive in "${slice_archives[@]}"; do
    [[ -f "$release_dir/$archive" ]] ||
      fail "$slice did not produce required archive $archive"
  done

  local slice_dir="$BUILD_DIR/slices/$slice"
  local sdk_root sdk_version wrapper_object unencapsulated_archive
  local encapsulated_object output_archive symbols_file
  rm -rf "$slice_dir"
  mkdir -p "$slice_dir"
  sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
  sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
  wrapper_object="$slice_dir/NodeMobile.o"
  unencapsulated_archive="$slice_dir/libNodeMobile-unencapsulated.a"
  encapsulated_object="$slice_dir/NodeMobileEncapsulated.o"
  output_archive="$slice_dir/libNodeMobile.a"
  symbols_file="$slice_dir/global-symbols.txt"

  xcrun --sdk "$sdk" clang++ \
    -arch arm64 \
    "$min_version_flag" \
    -isysroot "$sdk_root" \
    -std=gnu++20 \
    -stdlib=libc++ \
    -I"$VENDOR_DIR/Sources" \
    -c "$VENDOR_DIR/Sources/NodeMobile.cpp" \
    -o "$wrapper_object"

  local -a archive_paths=()
  for archive in "${slice_archives[@]}"; do
    archive_paths+=("$release_dir/$archive")
  done
  xcrun libtool -static -o "$unencapsulated_archive" \
    "$wrapper_object" "${archive_paths[@]}"

  # Node and Python intentionally use different OpenSSL releases. Collapse the
  # complete Node runtime into one object so all vendored dependencies stay
  # private to NodeMobile and cannot bind to another static runtime's symbols.
  xcrun --sdk "$sdk" ld \
    -r \
    -arch arm64 \
    -syslibroot "$sdk_root" \
    -platform_version "$platform" "$minimum_os_version" "$sdk_version" \
    -all_load "$unencapsulated_archive" \
    -exported_symbol _node_start \
    -exported_symbol _node_mobile_prepare_command \
    -exported_symbol _node_mobile_run_command \
    -exported_symbol _node_mobile_cancel_command \
    -exported_symbol _node_mobile_finish_command \
    -o "$encapsulated_object"
  xcrun libtool -static -o "$output_archive" "$encapsulated_object"
  xcrun strip -S -x "$output_archive"
  xcrun ranlib "$output_archive"

  lipo -archs "$output_archive" | grep -qw arm64 ||
    fail "$slice aggregate library is not arm64"
  file "$output_archive" | grep -q "current ar archive" ||
    fail "$slice aggregate library is not a static archive"
  xcrun nm -m "$output_archive" |
    awk '$0 ~ / external / && $0 !~ / private external / && $0 !~ /\(undefined\)/ { print $NF }' |
    sort -u > "$symbols_file"
  grep -qx "_node_start" "$symbols_file" ||
    fail "$slice aggregate library does not export node_start"
  grep -qx "_node_mobile_prepare_command" "$symbols_file" ||
    fail "$slice aggregate library does not export node_mobile_prepare_command"
  grep -qx "_node_mobile_run_command" "$symbols_file" ||
    fail "$slice aggregate library does not export node_mobile_run_command"
  grep -qx "_node_mobile_cancel_command" "$symbols_file" ||
    fail "$slice aggregate library does not export node_mobile_cancel_command"
  grep -qx "_node_mobile_finish_command" "$symbols_file" ||
    fail "$slice aggregate library does not export node_mobile_finish_command"
  if grep -vEx "_node_start|_node_mobile_prepare_command|_node_mobile_run_command|_node_mobile_cancel_command|_node_mobile_finish_command" \
    "$symbols_file" | grep -q .; then
    fail "$slice aggregate library exposes symbols outside the NodeMobile C API"
  fi
  if grep -qx "_main" "$symbols_file"; then
    fail "$slice aggregate library unexpectedly exports main"
  fi
  if xcrun ar -t "$output_archive" | grep -E "^(gtest|gmock)" >/dev/null; then
    fail "$slice aggregate library unexpectedly contains test objects"
  fi
  rm -f "$symbols_file"

  rm -rf "$SOURCE_DIR/out"
}

create_xcframework() {
  local headers_dir="$BUILD_DIR/headers"
  local staged_xcframework="$BUILD_DIR/NodeMobile.xcframework"
  rm -rf "$headers_dir" "$staged_xcframework"
  mkdir -p "$headers_dir"
  cp "$VENDOR_DIR/Sources/NodeMobile.h" "$headers_dir/"

  xcodebuild -create-xcframework \
    -library "$BUILD_DIR/slices/ios-arm64/libNodeMobile.a" \
    -headers "$headers_dir" \
    -library "$BUILD_DIR/slices/ios-arm64-simulator/libNodeMobile.a" \
    -headers "$headers_dir" \
    -library "$BUILD_DIR/slices/macos-arm64/libNodeMobile.a" \
    -headers "$headers_dir" \
    -output "$staged_xcframework"

  rm -rf "$VENDOR_DIR/Frameworks"
  mkdir -p "$VENDOR_DIR/Frameworks"
  cp -R "$staged_xcframework" "$VENDOR_DIR/Frameworks/"
  cp "$SOURCE_DIR/LICENSE" "$VENDOR_DIR/LICENSE"
}

write_build_metadata() {
  local local_patch_sha256 mobile_patch_sha256
  mobile_patch_sha256=$(sha256_file "$MOBILE_PATCH_FILE")
  local_patch_sha256=$(sha256_file "$LOCAL_PATCH_FILE")
  {
    echo "NODEJS_VERSION=$NODEJS_VERSION"
    echo "NODEJS_SOURCE_REPO=$NODEJS_SOURCE_REPO"
    echo "NODEJS_SOURCE_URL=$NODEJS_SOURCE_URL"
    echo "NODEJS_SOURCE_SHA256=$NODEJS_SOURCE_SHA256"
    echo "NODEJS_MOBILE_PORT_REPO=$NODEJS_MOBILE_PORT_REPO"
    echo "NODEJS_MOBILE_PORT_COMMIT=$NODEJS_MOBILE_PORT_COMMIT"
    echo "NODEJS_MOBILE_PORT_BASE_VERSION=$NODEJS_MOBILE_PORT_BASE_VERSION"
    echo "NODEJS_AUDIT_CROSSCHECK_REPO=$NODEJS_AUDIT_CROSSCHECK_REPO"
    echo "NODEJS_AUDIT_CROSSCHECK_COMMIT=$NODEJS_AUDIT_CROSSCHECK_COMMIT"
    echo "NPM_VERSION=$NPM_VERSION"
    echo "NPM_COMMAND_ARCHIVE=Resources/NodeMobile/Commands/npm-$NPM_VERSION.zip"
    echo "NPM_COMMAND_ARCHIVE_SHA256=$NPM_COMMAND_ARCHIVE_SHA256"
    echo "NODEJS_MOBILE_PATCH_SHA256=$mobile_patch_sha256"
    echo "NODEJS_LOCAL_PATCH_SHA256=$local_patch_sha256"
    echo "NODEJS_BUILD_FLAVOR=full"
    echo "NODEJS_INTL=small-icu"
    echo "NODEJS_LINKAGE=static"
    echo "NODEJS_NATIVE_DEPENDENCY_VISIBILITY=private-relocatable-object"
    echo "NODEJS_EMBEDDING_HOST=process-lifetime-platform-disposable-environment"
    echo "NODEJS_COMMAND_CONCURRENCY=serialized"
    echo "NODEJS_COMMAND_LINE_PARSER=node-options-per-environment"
    echo "NODEJS_EXPORTED_C_API=node_start,node_mobile_prepare_command,node_mobile_run_command,node_mobile_cancel_command,node_mobile_finish_command"
    echo "NODEJS_TEST_ARCHIVES=excluded"
    echo "NODEJS_STATIC_ARCHIVE_STRIP=debug-and-local-symbols"
    echo "NODEJS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "IOS_MINIMUM_OS_VERSION=$IOS_MINIMUM_OS_VERSION"
    echo "MACOS_MINIMUM_OS_VERSION=$MACOS_MINIMUM_OS_VERSION"
    echo "V8_RUNTIME_MODE=jitless"
    echo "V8_WASM_RUNTIME_MODE=wasm-jitless-drumbrake"
    echo "V8_DRUMBRAKE_BOUNDS_CHECKS=enabled"
    echo "NODEJS_STARTUP_SNAPSHOT=disabled"
    echo "NODEJS_CODE_CACHE=disabled"
    echo "XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "BAZEL_VERSION=$(cd "$REPO_ROOT" && bazel --version)"
  } > "$VENDOR_DIR/NODEJS_BUILD_INFO"

  (
    cd "$VENDOR_DIR"
    find \
      BUILD \
      Frameworks \
      LICENSE \
      NODEJS_BUILD_INFO \
      Patches \
      README.md \
      Resources \
      Sources \
      UPGRADING.md \
      build_nodejs_mobile.sh \
      verify_nodejs_mobile.sh \
      -type f -print |
      sort |
      while IFS= read -r file; do
        shasum -a 256 "$file"
      done
  ) > "$VENDOR_DIR/SHA256SUMS"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Node.js Apple platform builds require macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "this vendor recipe currently requires an Apple Silicon host"
require_command awk
require_command curl
require_command file
require_command find
require_command grep
require_command lipo
require_command make
require_command patch
require_command shasum
require_command sort
require_command tar
require_command tr
require_command wc
require_command xcodebuild
require_command xcrun
require_command zip

prepare_source
package_npm_commands
build_slice ios-arm64
build_slice ios-arm64-simulator
build_slice macos-arm64
create_xcframework
write_build_metadata
"$VENDOR_DIR/verify_nodejs_mobile.sh"

echo "Updated Vendors/NodeJS with Node.js Mobile $NODEJS_VERSION"
