#!/bin/bash
# Build the native Python extension independently of the large Python archive.
set -euo pipefail
export LC_ALL=C COPYFILE_DISABLE=1
vendor_dir=$(cd "$(dirname "$0")/.." && pwd)
work_dir=${CURL_CFFI_BUILD_DIR:-/private/tmp/curl-cffi-ios-build}
build_python=${CFFI_BUILD_PYTHON:-python3}
mkdir -p "$work_dir/downloads"
fetch() {
  local url=$1 name=$2 checksum=$3
  if ! [ -f "$work_dir/downloads/$name" ]; then
    curl -fsSL --retry 3 "$url" -o "$work_dir/downloads/$name.tmp"
    mv "$work_dir/downloads/$name.tmp" "$work_dir/downloads/$name"
  fi
  echo "$checksum  $work_dir/downloads/$name" | shasum -a 256 -c -
}
fetch https://github.com/lexiforest/curl-impersonate/archive/refs/tags/v2.3.2.tar.gz \
  curl-impersonate-2.3.2.tar.gz 027e0cc1efef9ff9587f7cd33da5a6a0df1eb285d860fbfd78bc86c8c45f7f23
fetch https://files.pythonhosted.org/packages/96/4c/69074f9797d83a5401b3c6bc58c5de5aad6d1a085d0497b87a093a152e87/curl_cffi-0.17.0.tar.gz \
  curl_cffi-0.17.0.tar.gz 31ee8500d06d6502ce1ec0b7ded1c5aa8e8f3401bbe37ccd78d6153d859d8f3c
# Re-extract source so local edits cannot silently change the generated vendor.
rm -rf "$work_dir/curl-impersonate-2.3.2" "$work_dir/curl_cffi-0.17.0"
tar -xf "$work_dir/downloads/curl-impersonate-2.3.2.tar.gz" -C "$work_dir"
tar -xf "$work_dir/downloads/curl_cffi-0.17.0.tar.gz" -C "$work_dir"
# Keep upstream fingerprint patches intact. Only adjust build products/optimization.
"$build_python" - "$work_dir/curl-impersonate-2.3.2/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
for old, new in (
    ('-DCMAKE_BUILD_TYPE=Release',
     '-DCMAKE_BUILD_TYPE=MinSizeRel\n  -DCMAKE_C_FLAGS_MINSIZEREL=-Os\n  -DCMAKE_CXX_FLAGS_MINSIZEREL=-Os'),
    ('-DBUILD_SHARED_LIBS=ON', '-DBUILD_SHARED_LIBS=OFF'),
    ('-DBUILD_CURL_EXE=ON', '-DBUILD_CURL_EXE=OFF'),
    ('set(_toolchain_cmake_args)', 'set(_toolchain_cmake_args -DCMAKE_OSX_ARCHITECTURES=arm64)'),
    # c-ares reads Apple's DNS configuration through the private
    # dns_configuration_copy SPI and bypasses the system resolver. Keep curl's
    # threaded getaddrinfo resolver, as upstream does for Android.
    ('if(ANDROID)\n  set(_curl_resolver_flags', 'if(TRUE)\n  set(_curl_resolver_flags'),
    ('ExternalProject_Add(cares\n', 'ExternalProject_Add(cares\n  EXCLUDE_FROM_ALL TRUE\n'),
):
    # A miss would silently keep upstream's shared/Release build after an update.
    if old not in s:
        sys.exit(f'{p}: {old!r} not found; review CurlCFFI/build.sh against this upstream')
    s = s.replace(old, new)
p.write_text(s)
PY
# The emitted C must match the bundled _cffi_backend built by cairosvg_build.sh.
cffi_version=$(sed -n 's/^CFFI_VERSION=//p' "$vendor_dir/cairosvg_build.sh")
"$build_python" "$vendor_dir/CurlCFFI/generate_binding.py" \
  "$work_dir/curl_cffi-0.17.0" "$work_dir/wrapper.c" "$cffi_version"
printf '_PyInit__wrapper\n' > "$work_dir/exports.txt"
ld_classic=${PYTHON_LD_CLASSIC:-$(xcrun --find ld-classic)}
for sdk in macosx iphoneos iphonesimulator; do
  case "$sdk" in
    macosx) slice=macos-arm64; platform=macos; minimum=13.0; system=Darwin ;;
    iphoneos) slice=ios-arm64; platform=ios; minimum=16.0; system=iOS ;;
    iphonesimulator) slice=ios-arm64-simulator; platform=ios-simulator; minimum=16.0; system=iOS ;;
  esac
  build="$work_dir/$sdk"
  sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
  mkdir -p "$build"
  cmake -S "$work_dir/curl-impersonate-2.3.2" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$sdk_root" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
    -DCMAKE_INSTALL_PREFIX="$build/install" -DSUBJOBS=6 \
    -DCURL_IMPERSONATE_VERSION=2.3.2 -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none \
    > "$work_dir/configure-$sdk.log" 2>&1 || {
    tail -100 "$work_dir/configure-$sdk.log"; exit 1;
  }
  cmake --build "$build" --parallel 3 > "$work_dir/build-$sdk.log" 2>&1 || {
    tail -100 "$work_dir/build-$sdk.log"; exit 1;
  }
  case "$sdk" in
    macosx) target=arm64-apple-macos13.0 ;;
    iphoneos) target=arm64-apple-ios16.0 ;;
    iphonesimulator) target=arm64-apple-ios16.0-simulator ;;
  esac
  for source in "$work_dir/wrapper.c" "$work_dir/curl_cffi-0.17.0/ffi/shim.c"; do
    object="$build/$(basename "${source%.c}").o"
    xcrun --sdk "$sdk" clang -Os -target "$target" -isysroot "$sdk_root" \
      -I "$vendor_dir/Frameworks/Python.xcframework/$slice/Headers" \
      -I "$work_dir/curl_cffi-0.17.0/ffi" -I "$build/deps/src/curl/include" \
      -c "$source" -o "$object"
  done
  # Bind curl's patched TLS stack BEFORE combining it with Python/OpenSSL or
  # SwiftNIO/SwiftCrypto. Only the Python module initializer remains public.
  # Normal archive extraction excludes unused dependency objects (no force_load).
  "$ld_classic" -r -arch arm64 -syslibroot "$sdk_root" \
    -platform_version "$platform" "$minimum" "$(xcrun --sdk "$sdk" --show-sdk-version)" \
    -exported_symbols_list "$work_dir/exports.txt" \
    "$build/wrapper.o" "$build/shim.o" \
    "$build/deps/build/curl/lib/libcurl-impersonate.a" \
    "$build/deps/install/lib/libngtcp2_crypto_boringssl.a" \
    "$build/deps/install/lib/libngtcp2.a" "$build/deps/install/lib/libnghttp3.a" \
    "$build/deps/install/lib/libnghttp2.a" \
    "$build/deps/install/lib/libssl.a" "$build/deps/install/lib/libcrypto.a" \
    "$build/deps/install/lib/libbrotlidec.a" "$build/deps/install/lib/libbrotlicommon.a" \
    "$build/deps/install/lib/libzstd.a" \
    -o "$build/CurlCFFI.o"
  xcrun nmedit -s "$work_dir/exports.txt" "$build/CurlCFFI.o"
  xcrun libtool -static -D -o "$build/libCurlCFFI.a" "$build/CurlCFFI.o"
  xcrun strip -S -x "$build/libCurlCFFI.a"
  xcrun ranlib "$build/libCurlCFFI.a"
done
rm -rf "$work_dir/CurlCFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$work_dir/iphoneos/libCurlCFFI.a" \
  -library "$work_dir/iphonesimulator/libCurlCFFI.a" \
  -library "$work_dir/macosx/libCurlCFFI.a" \
  -output "$work_dir/CurlCFFI.xcframework"
rm -rf "$vendor_dir/Frameworks/CurlCFFI.xcframework"
cp -R "$work_dir/CurlCFFI.xcframework" "$vendor_dir/Frameworks/"
mkdir -p "$vendor_dir/CurlCFFI/Licenses"
cp "$work_dir/curl-impersonate-2.3.2/LICENSE" "$vendor_dir/CurlCFFI/Licenses/curl-impersonate.txt"
for entry in boringssl/LICENSE boringssl/third_party/fiat/LICENSE curl/COPYING \
  ngtcp2/COPYING nghttp3/COPYING nghttp3/lib/sfparse/COPYING nghttp2/COPYING \
  brotli/LICENSE zstd/LICENSE; do
  cp "$work_dir/macosx/deps/src/$entry" "$vendor_dir/CurlCFFI/Licenses/${entry//\//-}.txt"
done
# Preserve the upstream transitive version/hash manifest alongside our recipe.
sed -n '/# Versions and URLs/,/set(_disable_boringssl_asm_default/{ /set(_disable_boringssl_asm_default/!p; }' \
  "$work_dir/curl-impersonate-2.3.2/CMakeLists.txt" \
  | sed '/^set(CURL_IMPERSONATE_VERSION/,/^message(STATUS "curl-impersonate version/d' \
  > "$vendor_dir/CurlCFFI/dependencies.cmake"
for resources in Resources ResourcesMacOS; do
  packages="$vendor_dir/$resources/Library/lib/python3.14/site-packages"
  rm -rf "$packages/curl_cffi" "$packages"/curl_cffi-*.dist-info
  cp -R "$work_dir/curl_cffi-0.17.0/curl_cffi" "$packages/"
  mkdir -p "$packages/curl_cffi-0.17.0.dist-info"
  cp "$work_dir/curl_cffi-0.17.0/PKG-INFO" "$packages/curl_cffi-0.17.0.dist-info/METADATA"
  cp "$work_dir/curl_cffi-0.17.0/LICENSE" "$packages/curl_cffi-0.17.0.dist-info/"
  cp -R "$vendor_dir/CurlCFFI/Licenses" "$packages/curl_cffi-0.17.0.dist-info/licenses"
  printf 'Vendors/PythonIOS/CurlCFFI/build.sh\n' > "$packages/curl_cffi-0.17.0.dist-info/INSTALLER"
done
