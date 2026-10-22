#!/bin/bash
set -euo pipefail

export LC_ALL=C

VENDOR_DIR=$(cd "$(dirname "$0")" && pwd)
XCFRAMEWORK="$VENDOR_DIR/Frameworks/NodeMobile.xcframework"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required command not found: $1"
}

require_command file
require_command find
require_command grep
require_command awk
require_command cmp
require_command lipo
require_command mktemp
require_command plutil
require_command rm
require_command shasum
require_command sort
require_command tr
require_command unzip
require_command wc
require_command xcrun

cd "$VENDOR_DIR"

symbols_file=$(mktemp "${TMPDIR:-/tmp}/nodejs-mobile-symbols.XXXXXX")
npm_entries_file=$(mktemp "${TMPDIR:-/tmp}/nodejs-mobile-npm-entries.XXXXXX")
npm_package_file=$(mktemp "${TMPDIR:-/tmp}/nodejs-mobile-npm-package.XXXXXX")
trap 'rm -f "$symbols_file" "$npm_entries_file" "$npm_package_file"' EXIT

[[ -f SHA256SUMS ]] || fail "missing SHA256SUMS"
shasum -a 256 -c SHA256SUMS

grep -qx "NODEJS_LINKAGE=static" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare static linkage"
grep -qx "NODEJS_NATIVE_DEPENDENCY_VISIBILITY=private-relocatable-object" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare private native dependencies"
grep -qx "NODEJS_COMMAND_LINE_PARSER=node-options-per-environment" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the Node command-line parser"
grep -qx \
  "NODEJS_EXPORTED_C_API=node_start,node_mobile_prepare_command,node_mobile_run_command,node_mobile_cancel_command,node_mobile_finish_command" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the exact public C API"
grep -qx "NODEJS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected slices"
grep -qx "NODEJS_VERSION=24.22.1" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected Node.js version"
grep -qx "NODEJS_SOURCE_URL=https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.gz" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected Node.js source URL"
grep -qx \
  "NODEJS_SOURCE_SHA256=001773d9bd53fbd27a25efd42aa6a9693ebfe500998ca9bec635e9b6ee79bc91" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected Node.js source checksum"
grep -qx \
  "NODEJS_MOBILE_PORT_COMMIT=9eec30ebe09e4146bc557740da02baae88051721" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected mobile port recipe"
grep -qx "NPM_VERSION=11.19.1" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the expected npm version"
grep -qx \
  "NPM_COMMAND_ARCHIVE_SHA256=23a3c442e6e165888dc455a0fea799579b19c1b80a8eb071afdc82438efaa18a" \
  NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not declare the npm command archive checksum"
mobile_patch_sha256=$(shasum -a 256 Patches/nodejs-mobile-ios.patch | awk '{ print $1 }')
grep -qx "NODEJS_MOBILE_PATCH_SHA256=$mobile_patch_sha256" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not match the mobile patch checksum"
local_patch_sha256=$(shasum -a 256 Patches/local-code-ios.patch | awk '{ print $1 }')
grep -qx "NODEJS_LOCAL_PATCH_SHA256=$local_patch_sha256" NODEJS_BUILD_INFO ||
  fail "NODEJS_BUILD_INFO does not match the Local Code patch checksum"
grep -q "apple_static_xcframework_import(" BUILD ||
  fail "Bazel does not use apple_static_xcframework_import"
if grep -q "apple_dynamic_xcframework_import(" BUILD; then
  fail "Bazel unexpectedly declares a dynamic XCFramework import"
fi

npm_archive="Resources/NodeMobile/Commands/npm-11.19.1.zip"
[[ -f "$npm_archive" ]] || fail "missing npm command archive"
npm_archive_count=$(
  find Resources/NodeMobile/Commands -maxdepth 1 \( -type f -o -type l \) \
    -name "npm-*.zip" |
    wc -l |
    tr -d " "
)
[[ "$npm_archive_count" == "1" ]] || fail "unexpected npm command archives"
unzip -Z1 "$npm_archive" > "$npm_entries_file"
for entry in package.json bin/npm-cli.js bin/npx-cli.js; do
  grep -Fqx "$entry" "$npm_entries_file" ||
    fail "npm command archive is missing $entry"
done
unzip -p "$npm_archive" package.json > "$npm_package_file"
grep -q '"version": "11.19.1"' "$npm_package_file" ||
  fail "npm command archive has an unexpected package version"
if grep -E "(^|/)test/" "$npm_entries_file" >/dev/null; then
  fail "npm command archive unexpectedly contains test payloads"
fi

[[ -d "$XCFRAMEWORK" ]] || fail "missing NodeMobile.xcframework"
plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null

expected_files=(
  "Info.plist"
  "ios-arm64/Headers/NodeMobile.h"
  "ios-arm64/libNodeMobile.a"
  "ios-arm64-simulator/Headers/NodeMobile.h"
  "ios-arm64-simulator/libNodeMobile.a"
  "macos-arm64/Headers/NodeMobile.h"
  "macos-arm64/libNodeMobile.a"
)

actual_file_count=$(
  find "$XCFRAMEWORK" \( -type f -o -type l \) -print | wc -l | tr -d " "
)
[[ "$actual_file_count" == "${#expected_files[@]}" ]] ||
  fail "NodeMobile.xcframework contains unexpected files"

for relative_path in "${expected_files[@]}"; do
  [[ -f "$XCFRAMEWORK/$relative_path" ]] ||
    fail "missing XCFramework file: $relative_path"
done

for slice in ios-arm64 ios-arm64-simulator macos-arm64; do
  archive="$XCFRAMEWORK/$slice/libNodeMobile.a"
  cmp -s Sources/NodeMobile.h "$XCFRAMEWORK/$slice/Headers/NodeMobile.h" ||
    fail "$slice public header differs from Sources/NodeMobile.h"

  file "$archive" | grep -q "current ar archive" ||
    fail "$slice is not a static archive"
  [[ "$(lipo -archs "$archive")" == "arm64" ]] ||
    fail "$slice does not contain exactly the arm64 architecture"
  xcrun nm -m "$archive" |
    awk '$0 ~ / external / && $0 !~ / private external / && $0 !~ /\(undefined\)/ { print $NF }' |
    sort -u > "$symbols_file"
  grep -qx "_node_start" "$symbols_file" ||
    fail "$slice does not export node_start"
  grep -qx "_node_mobile_prepare_command" "$symbols_file" ||
    fail "$slice does not export node_mobile_prepare_command"
  grep -qx "_node_mobile_run_command" "$symbols_file" ||
    fail "$slice does not export node_mobile_run_command"
  grep -qx "_node_mobile_cancel_command" "$symbols_file" ||
    fail "$slice does not export node_mobile_cancel_command"
  grep -qx "_node_mobile_finish_command" "$symbols_file" ||
    fail "$slice does not export node_mobile_finish_command"
  if grep -vEx "_node_start|_node_mobile_prepare_command|_node_mobile_run_command|_node_mobile_cancel_command|_node_mobile_finish_command" \
    "$symbols_file" | grep -q .; then
    fail "$slice exposes symbols outside the NodeMobile C API"
  fi
  object_count=$(
    xcrun ar -t "$archive" | grep -v "^__.SYMDEF" | wc -l | tr -d " "
  )
  if [[ "$object_count" != 1 ]]; then
    fail "$slice does not encapsulate the runtime in one object"
  fi
done

dynamic_framework=$(
  find "$XCFRAMEWORK" -type d -name "*.framework" -print -quit
)
if [[ -n "$dynamic_framework" ]]; then
  fail "NodeMobile.xcframework unexpectedly contains a dynamic framework"
fi
dynamic_library=$(
  find "$XCFRAMEWORK" \( -type f -o -type l \) \
    \( -name "*.dylib" -o -name "*.so" \) -print -quit
)
if [[ -n "$dynamic_library" ]]; then
  fail "NodeMobile.xcframework unexpectedly contains a dynamic library"
fi

echo "NodeJS vendor verification passed"
