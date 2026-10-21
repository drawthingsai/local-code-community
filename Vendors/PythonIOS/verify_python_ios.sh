#!/bin/bash
set -euo pipefail

export LC_ALL=C

VENDOR_DIR=$(cd "$(dirname "$0")" && pwd)
XCFRAMEWORK="$VENDOR_DIR/Frameworks/Python.xcframework"
HF_XET_HEADER="$VENDOR_DIR/HFXetHeaders/hf_xet.h"
IOS_RESOURCES="$VENDOR_DIR/Resources/Library"
MACOS_RESOURCES="$VENDOR_DIR/ResourcesMacOS/Library"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required command not found: $1"
}

require_command /usr/libexec/PlistBuddy
require_command awk
require_command file
require_command find
require_command grep
require_command lipo
require_command mktemp
require_command plutil
require_command rm
require_command sed
require_command shasum
require_command sort
require_command xcrun

cd "$VENDOR_DIR"

python3 "$VENDOR_DIR/CurlCFFI/verify.py"

symbols_file=$(mktemp "${TMPDIR:-/tmp}/python-ios-symbols.XXXXXX")
visibility_symbols_file=$(mktemp "${TMPDIR:-/tmp}/python-ios-visibility-symbols.XXXXXX")
trap 'rm -f "$symbols_file" "$visibility_symbols_file"' EXIT

[[ -f SHA256SUMS ]] || fail "missing SHA256SUMS"
if ! shasum -a 256 -c SHA256SUMS >/dev/null; then
  fail "SHA256SUMS verification failed"
fi

grep -qx "PYTHON_LINKAGE=static" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare static linkage"
grep -qx "PYTHON_SYMBOL_VISIBILITY=export-list" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare export-list encapsulation"
grep -qx "PYTHON_RUST_PERSONALITY=shared-weak" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare a shared Rust personality"
[[ -s exported_symbols.txt ]] || fail "missing Python export list"
sort -cu exported_symbols.txt || fail "Python export list must be sorted and unique"
grep -qx "PYTHON_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected slices"
grep -q "mlx-0.32.2" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare MLX 0.32.2"
grep -qx "MLX_SLICES=ios-arm64 macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected MLX slices"
grep -qx "MLX_METAL_LANGUAGE_STANDARD=metal3.1" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected MLX Metal language standard"
grep -qx "PYYAML_FEATURE_POLICY=pure-python libyaml=disabled wheel=py3-none-any" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected PyYAML feature policy"
grep -qx "PYYAML_SOURCE_SHA256=d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected PyYAML source"
grep -qx "PYYAML_WHEEL_SHA256=717a12e2e669ac5ab431f9d59c8574eec76182378c7ef3aa958cb5962b14d254" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected pure-Python PyYAML wheel"
grep -qx "PILLOW_FEATURE_POLICY=zlib=enabled jpeg=libjpeg-turbo freetype=matplotlib raqm=matplotlib tiff=disabled lcms=disabled webp=disabled jpeg2000=disabled imagequant=disabled xcb=disabled avif=disabled" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected Pillow feature policy"
grep -qx "LIBJPEG_TURBO_SOURCE_SHA256=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected libjpeg-turbo source"
grep -qx "LIBJPEG_TURBO_FEATURE_POLICY=library=static api=jpeg8 simd=required turbojpeg=disabled tools=disabled" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected libjpeg-turbo feature policy"
grep -qx "TQDM_FEATURE_POLICY=monitor-thread=disabled multiprocessing-lock=disabled" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tqdm thread policy"
grep -q "hf-xet-1.5.2" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare hf-xet 1.5.2"
grep -qx "HF_XET_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected hf-xet slices"
grep -qx "HF_XET_RUST_VERSION=1.89.0" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected hf-xet Rust toolchain"
grep -qx "HF_XET_SOURCE_SHA256=73044bd31bae33c984af832d19c752a0dffb67518fee9ddbd91d616e1101cf47" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected hf-xet source"
grep -qx "HF_XET_CARGO_LOCK_SHA256=65e35c92eb55cfcac983851fb0768ad09dbb04cbaacbc349ad3f8ca8cbb8dc4c" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected hf-xet Cargo lock"
grep -qx "HF_XET_FEATURE_POLICY=pyo3=0.29.0 abi3=py38 tls=rustls lto=disabled sysinfo=disabled system-monitor=disabled log-cleanup=disabled interpreter=main-only c-api=download-in-python-archive" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected hf-xet interpreter policy"
grep -q "safetensors-0.8.0" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare safetensors 0.8.0"
grep -qx "SAFETENSORS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected safetensors slices"
grep -qx "SAFETENSORS_RUST_VERSION=1.89.0" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected safetensors Rust toolchain"
grep -qx "SAFETENSORS_SOURCE_SHA256=fabaf3e0f18a6618d9b36560682562157f77c2b71fcffc7b432be2baed9d753d" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected safetensors source"
grep -qx "SAFETENSORS_CARGO_LOCK_SHA256=f7d484a57bc394042b3424d57dab0a17d6a343f5e57e30870b9dd72dfb90f6b7" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected safetensors Cargo lock"
grep -qx "SAFETENSORS_FEATURE_POLICY=pyo3=0.28.3 abi3=py310 host-python=disabled mmap=enabled pread=enabled lto=disabled interpreter=main-only" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected safetensors interpreter policy"
grep -q "regex-2026.7.19" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare regex 2026.7.19"
grep -qx "REGEX_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected regex slices"
grep -qx "REGEX_SOURCE_SHA256=7e77b324909c1617cbb4c668677e2c6ae13f44d7c1de0d4f15f2e3c10f3315b5" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected regex source"
grep -qx "REGEX_FEATURE_POLICY=python=3.14 c-extension=static external-libraries=none interpreter=main-only" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected regex interpreter policy"
grep -q "tokenizers-0.22.2" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare tokenizers 0.22.2"
grep -qx "TOKENIZERS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tokenizers slices"
grep -qx "TOKENIZERS_RUST_VERSION=1.89.0" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tokenizers Rust toolchain"
grep -qx "TOKENIZERS_SOURCE_SHA256=473b83b915e547aa366d1eee11806deaf419e17be16310ac0a14077f1e28f917" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tokenizers source"
grep -qx "TOKENIZERS_CARGO_LOCK_SHA256=a3ff2022b3790e2f5863fe59732ab76da81dd75bc3a94905127206e87125170d" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tokenizers Cargo lock"
grep -qx "TOKENIZERS_FEATURE_POLICY=pyo3=0.26.0 abi3=py39 onig=vendored esaxx=cpp progressbar=enabled rust-http=disabled lto=disabled interpreter=main-only" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected tokenizers feature policy"
grep -q "sentencepiece-0.2.2" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare SentencePiece 0.2.2"
grep -qx "SENTENCEPIECE_SLICES=ios-arm64 ios-arm64-simulator macos-arm64" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected SentencePiece slices"
grep -qx "SENTENCEPIECE_SOURCE_SHA256=3d2b5e824b5622038dc7b490897efe05ebbbb9e7350fc142f3ecc8789ef9bdf6" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected SentencePiece source"
grep -qx "SENTENCEPIECE_ABSEIL_COMMIT=5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the workspace SentencePiece Abseil ABI"
grep -qx "SENTENCEPIECE_ABSEIL_ABI=lts_20260526" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected SentencePiece Abseil namespace"
grep -Fqx "SENTENCEPIECE_FEATURE_POLICY=pybind11=3.0.1 extension=static core=@sentencepiece//:sentencepiece_train core-in-python-archive=none abseil=lts_20260526 interpreter=main-only" PYTHON_BUILD_INFO ||
  fail "PYTHON_BUILD_INFO does not declare the expected SentencePiece link policy"
grep -q "apple_static_xcframework_import(" BUILD ||
  fail "Bazel does not use apple_static_xcframework_import"
grep -Fq '"@sentencepiece//:sentencepiece_train"' BUILD ||
  fail "Bazel does not link PythonIOS against the canonical SentencePiece target"
if grep -q "apple_dynamic_xcframework_import(" BUILD; then
  fail "Bazel unexpectedly declares a dynamic XCFramework import"
fi

[[ -d "$XCFRAMEWORK" ]] || fail "missing Python.xcframework"
plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null
[[ -f "$HF_XET_HEADER" ]] || fail "missing hf_xet.h"

for index in 0 1 2; do
  identifier=$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:$index:LibraryIdentifier" \
      "$XCFRAMEWORK/Info.plist"
  )
  architecture=$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:$index:SupportedArchitectures:0" \
      "$XCFRAMEWORK/Info.plist"
  )
  [[ "$architecture" == "arm64" ]] ||
    fail "$identifier metadata does not declare arm64"

  case "$identifier" in
    ios-arm64)
      expected_platform=ios
      expected_library=libpython3.14-ios.a
      if /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" \
        "$XCFRAMEWORK/Info.plist" >/dev/null 2>&1; then
        fail "$identifier unexpectedly declares a platform variant"
      fi
      ;;
    ios-arm64-simulator)
      expected_platform=ios
      expected_library=libpython3.14-ios-simulator.a
      variant=$(
        /usr/libexec/PlistBuddy \
          -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" \
          "$XCFRAMEWORK/Info.plist"
      )
      [[ "$variant" == "simulator" ]] ||
        fail "$identifier metadata does not declare the simulator variant"
      ;;
    macos-arm64)
      expected_platform=macos
      expected_library=libpython3.14-macos.a
      if /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" \
        "$XCFRAMEWORK/Info.plist" >/dev/null 2>&1; then
        fail "$identifier unexpectedly declares a platform variant"
      fi
      ;;
    *)
      fail "unexpected XCFramework slice: $identifier"
      ;;
  esac

  platform=$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:$index:SupportedPlatform" \
      "$XCFRAMEWORK/Info.plist"
  )
  library=$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:$index:LibraryPath" \
      "$XCFRAMEWORK/Info.plist"
  )
  [[ "$platform" == "$expected_platform" ]] ||
    fail "$identifier metadata declares the wrong platform"
  [[ "$library" == "$expected_library" ]] ||
    fail "$identifier metadata declares the wrong library"
done

if /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:3" \
  "$XCFRAMEWORK/Info.plist" >/dev/null 2>&1; then
  fail "Python.xcframework contains unexpected slices"
fi

for slice in ios-arm64 ios-arm64-simulator macos-arm64; do
  case "$slice" in
    ios-arm64)
      archive_name=libpython3.14-ios.a
      ;;
    ios-arm64-simulator)
      archive_name=libpython3.14-ios-simulator.a
      ;;
    macos-arm64)
      archive_name=libpython3.14-macos.a
      ;;
  esac

  archive="$XCFRAMEWORK/$slice/$archive_name"
  [[ -f "$archive" ]] || fail "missing XCFramework archive: $slice/$archive_name"
  [[ -f "$XCFRAMEWORK/$slice/Headers/Python.h" ]] ||
    fail "missing Python.h for $slice"
  [[ -f "$XCFRAMEWORK/$slice/Headers/pyconfig.h" ]] ||
    fail "missing pyconfig.h for $slice"

  file "$archive" | grep -q "current ar archive" ||
    fail "$slice is not a static archive"
  [[ "$(lipo -archs "$archive")" == "arm64" ]] ||
    fail "$slice does not contain exactly the arm64 architecture"

  [[ "$(xcrun ar -t "$archive" | grep -v '^__\.SYMDEF')" == "Python.o" ]] ||
    fail "$slice is not encapsulated in one Python object"
  xcrun nm -m "$archive" > "$visibility_symbols_file" ||
    fail "nm could not inspect symbol visibility for $slice"
  if grep -Eq '\(common\)| private external ' "$visibility_symbols_file"; then
    fail "$slice retains common or private-external definitions"
  fi
  grep -Eq ' weak external .*_rust_eh_personality$' "$visibility_symbols_file" ||
    fail "$slice must export a weak Rust personality for host coalescing"
  awk '/ external / && !/ private external / && !/\(undefined\)/ { print $NF }' \
    "$visibility_symbols_file" | sort -u > "$symbols_file"
  unexpected_symbol=$(grep -Fvx -f exported_symbols.txt "$symbols_file" | sed -n '1p' || true)
  [[ -z "$unexpected_symbol" ]] ||
    fail "$slice exports a symbol outside the Python interface: $unexpected_symbol"
  grep -qx "_Py_Initialize" "$symbols_file" ||
    fail "$slice does not export Py_Initialize"
  for package in numpy pandas pillow cairosvg lxml matplotlib psd_tools hf_xet safetensors regex tokenizers sentencepiece; do
    grep -qx "_ios_python_register_$package" "$symbols_file" ||
      fail "$slice does not export the $package registrar"
  done
  for symbol in _PyInit__cffi_backend _PyInit__ffi; do
    grep -qx "$symbol" "$symbols_file" || fail "$slice is missing $symbol"
  done
  if grep -Eq '^_(cairo_|pixman_|png_|ffi_)' "$symbols_file"; then
    fail "$slice exposes a CairoSVG native dependency outside the Python interface"
  fi
  for symbol in _PyInit__imaging _PyInit__imagingft; do
    grep -qx "$symbol" "$symbols_file" || fail "$slice is missing $symbol"
  done
  if grep -Eq '^_(jpeg_|jinit_|jsimd_|FT_|raqm_|hb_)' "$symbols_file"; then
    fail "$slice exposes a Pillow native dependency outside the Python interface"
  fi
  grep -qx "_PyInit_hf_xet" "$symbols_file" ||
    fail "$slice does not export the static hf_xet initializer"
  for symbol in hf_xet_download_start hf_xet_download_cancel hf_xet_download_release; do
    grep -qx "_$symbol" "$symbols_file" ||
      fail "$slice does not export $symbol"
  done
  grep -qx "_PyInit__safetensors_rust" "$symbols_file" ||
    fail "$slice does not export the static safetensors initializer"
  grep -qx "_PyInit__regex" "$symbols_file" ||
    fail "$slice does not export the static regex initializer"
  grep -qx "_PyInit_tokenizers" "$symbols_file" ||
    fail "$slice does not export the static tokenizers initializer"
  grep -qx "_PyInit__sentencepiece" "$symbols_file" ||
    fail "$slice does not export the static SentencePiece initializer"
  grep -Eq '\(undefined\) external __ZN13sentencepiece22SentencePieceProcessorC1Ev$' \
    "$visibility_symbols_file" ||
    fail "$slice does not reference the external SentencePiece C++ runtime"
  if [[ "$slice" == "ios-arm64-simulator" ]]; then
    if grep -qx "_ios_python_register_mlx" "$symbols_file"; then
      fail "$slice unexpectedly exports the MLX registrar"
    fi
    if grep -qx "_PyInit_core" "$symbols_file"; then
      fail "$slice unexpectedly exports the static mlx.core initializer"
    fi
  else
    grep -qx "_ios_python_register_mlx" "$symbols_file" ||
      fail "$slice does not export the MLX registrar"
    grep -qx "_PyInit_core" "$symbols_file" ||
      fail "$slice does not export the static mlx.core initializer"
  fi
done

dynamic_framework=$(
  find "$XCFRAMEWORK" -type d -name "*.framework" -print -quit
)
if [[ -n "$dynamic_framework" ]]; then
  fail "Python.xcframework unexpectedly contains a dynamic framework"
fi
dynamic_library=$(
  find "$XCFRAMEWORK" \( -type f -o -type l \) \
    \( -name "*.dylib" -o -name "*.so" \) -print -quit
)
if [[ -n "$dynamic_library" ]]; then
  fail "Python.xcframework unexpectedly contains a dynamic library"
fi

for root in "$IOS_RESOURCES" "$MACOS_RESOURCES"; do
  binary_resource=$(
    find "$root" \( -type f -o -type l \) \
      \( -name "*.a" -o -name "*.dylib" -o -name "*.so" -o \
         -name "*.exe" -o -name "*.fwork" \) -print -quit
  )
  if [[ -n "$binary_resource" ]]; then
    fail "Python resources unexpectedly contain a native binary: $binary_resource"
  fi

  host_path=$(
    find "$root" -type f -exec grep -IlE "/Users/|/private/tmp/" {} + |
      sed -n "1p" ||
      true
  )
  if [[ -n "$host_path" ]]; then
    fail "Python resources contain a builder-specific path: $host_path"
  fi

  # App Store review delists apps linking to U.S.-embargoed territories;
  # YTDLP/install.py removes the known ones, so any match needs review.
  embargoed_host=$(
    find "$root" -type f -exec grep -IoiE \
      "[[:alnum:]-]+\\\\*\\.(ir|cu|kp|sy)(['\"/:|\\\\]|\$)" {} + |
      sed -n "1p" ||
      true
  )
  if [[ -n "$embargoed_host" ]]; then
    fail "Python resources reference an embargoed-territory host: $embargoed_host"
  fi
done

for multiarch in arm64-iphoneos arm64-iphonesimulator; do
  [[ -f "$IOS_RESOURCES/lib/python3.14/_sysconfigdata__ios_$multiarch.py" ]] ||
    fail "missing iOS sysconfig data for $multiarch"
  [[ -f "$IOS_RESOURCES/lib/python3.14/_sysconfig_vars__ios_$multiarch.json" ]] ||
    fail "missing iOS sysconfig variables for $multiarch"
done
[[ -f "$MACOS_RESOURCES/lib/python3.14/_sysconfigdata__darwin_darwin.py" ]] ||
  fail "missing macOS sysconfig data"
[[ -f "$MACOS_RESOURCES/lib/python3.14/_sysconfig_vars__darwin_darwin.json" ]] ||
  fail "missing macOS sysconfig variables"

IOS_MLX="$IOS_RESOURCES/lib/python3.14/site-packages/mlx"
MACOS_MLX="$MACOS_RESOURCES/lib/python3.14/site-packages/mlx"
for root in "$IOS_MLX" "$MACOS_MLX"; do
  [[ -f "$root/nn/__init__.py" ]] ||
    fail "missing MLX Python package resources under $root"
done

for root in "$IOS_RESOURCES" "$MACOS_RESOURCES"; do
  site_packages="$root/lib/python3.14/site-packages"
  for package in cairosvg cairocffi cffi cssselect2 defusedxml pycparser tinycss2 webencodings; do
    [[ -f "$site_packages/$package/__init__.py" ]] ||
      fail "missing $package resources under $root"
  done
  grep -qx 'from ._ffi import ffi, lib as cairo' "$site_packages/cairocffi/__init__.py" ||
    fail "cairocffi does not use its static binding under $root"
  grep -q '@ffi.def_extern(name="_pythonios_cairo_write"' "$site_packages/cairocffi/surfaces.py" ||
    fail "cairocffi is missing compiled stream callbacks under $root"
  grep -qx 'Version: 2.1.1' "$site_packages/cffi-2.1.1.dist-info/METADATA" ||
    fail "missing CFFI native package metadata under $root"
  grep -qx 'Version: 2.9.1' "$site_packages/cairosvg-2.9.1.dist-info/METADATA" ||
    fail "missing CairoSVG package metadata under $root"
  for license in libjpeg-turbo-LICENSE.md libjpeg-turbo-README.ijg; do
    [[ -f "$site_packages/pillow-12.3.0.dist-info/licenses/native/$license" ]] ||
      fail "missing Pillow native license $license under $root"
  done
  [[ -f "$site_packages/yaml/__init__.py" ]] ||
    fail "missing PyYAML package resources under $root"
  [[ -f "$site_packages/_yaml/__init__.py" ]] ||
    fail "missing PyYAML compatibility package resources under $root"
  grep -qx "Version: 6.0.3" \
    "$site_packages/pyyaml-6.0.3.dist-info/METADATA" ||
    fail "missing PyYAML 6.0.3 metadata under $root"
  grep -qx "Root-Is-Purelib: true" \
    "$site_packages/pyyaml-6.0.3.dist-info/WHEEL" ||
    fail "PyYAML wheel is not marked as pure Python under $root"
  grep -qx "Tag: py3-none-any" \
    "$site_packages/pyyaml-6.0.3.dist-info/WHEEL" ||
    fail "PyYAML wheel is not universal under $root"
  [[ ! -e "$site_packages/pyyaml-6.0.3.dist-info/direct_url.json" ]] ||
    fail "PyYAML metadata unexpectedly records a builder-local source under $root"
  grep -q "^    mp_lock = None  # embedded commands do not support process-fork locks$" \
    "$site_packages/tqdm/std.py" ||
    fail "tqdm multiprocessing lock is not disabled under $root"
  grep -q "^    monitor_interval = 0  # embedded commands must not leave background threads$" \
    "$site_packages/tqdm/std.py" ||
    fail "tqdm monitor thread is not disabled under $root"
  grep -qF "tqdm/std.py,sha256=hszFPDhpsf0t7ldMTlu1aYAtxrjJ5M6WQoZmZohN3Z8,58168" \
    "$site_packages/tqdm-4.70.0.dist-info/RECORD" ||
    fail "tqdm wheel record does not match the embedded runtime patch under $root"
  [[ -f "$site_packages/hf_xet/__init__.py" ]] ||
    fail "missing hf_xet package resources under $root"
  grep -qx "Version: 1.5.2" \
    "$site_packages/hf_xet-1.5.2.dist-info/METADATA" ||
    fail "missing hf-xet 1.5.2 metadata under $root"
  [[ -f "$site_packages/hf_xet-1.5.2.dist-info/licenses/LICENSE" ]] ||
    fail "missing hf-xet license under $root"
  [[ -f "$site_packages/safetensors/__init__.py" ]] ||
    fail "missing safetensors package resources under $root"
  [[ -f "$site_packages/safetensors/numpy.py" ]] ||
    fail "missing safetensors NumPy adapter under $root"
  grep -qx "Version: 0.8.0" \
    "$site_packages/safetensors-0.8.0.dist-info/METADATA" ||
    fail "missing safetensors 0.8.0 metadata under $root"
  [[ -f "$site_packages/safetensors-0.8.0.dist-info/licenses/LICENSE" ]] ||
    fail "missing safetensors license under $root"
  [[ -f "$site_packages/regex/__init__.py" ]] ||
    fail "missing regex package resources under $root"
  [[ -f "$site_packages/regex/_regex_core.py" ]] ||
    fail "missing regex Python implementation resources under $root"
  grep -qx "Version: 2026.7.19" \
    "$site_packages/regex-2026.7.19.dist-info/METADATA" ||
    fail "missing regex 2026.7.19 metadata under $root"
  [[ -f "$site_packages/regex-2026.7.19.dist-info/licenses/LICENSE.txt" ]] ||
    fail "missing regex license under $root"
  [[ -f "$site_packages/tokenizers/__init__.py" ]] ||
    fail "missing tokenizers package resources under $root"
  [[ -f "$site_packages/tokenizers/models/__init__.py" ]] ||
    fail "missing tokenizers model resources under $root"
  grep -qx "Version: 0.22.2" \
    "$site_packages/tokenizers-0.22.2.dist-info/METADATA" ||
    fail "missing tokenizers 0.22.2 metadata under $root"
  grep -qx "Requires-Dist: huggingface-hub>=0.16.4,<2.0" \
    "$site_packages/tokenizers-0.22.2.dist-info/METADATA" ||
    fail "tokenizers metadata does not retain its Python hub dependency under $root"
  [[ -f "$site_packages/tokenizers-0.22.2.dist-info/licenses/LICENSE" ]] ||
    fail "missing tokenizers license under $root"
  [[ -f "$site_packages/sentencepiece/__init__.py" ]] ||
    fail "missing SentencePiece package resources under $root"
  [[ -f "$site_packages/sentencepiece/package_data/nfkc.bin" ]] ||
    fail "missing SentencePiece normalization data under $root"
  [[ ! -e "$site_packages/sentencepiece/sentencepiece_pybind.cc" ]] ||
    fail "SentencePiece C++ binding source unexpectedly remains under $root"
  grep -qx "Version: 0.2.2" \
    "$site_packages/sentencepiece-0.2.2.dist-info/METADATA" ||
    fail "missing SentencePiece 0.2.2 metadata under $root"
  [[ -f "$site_packages/sentencepiece-0.2.2.dist-info/licenses/LICENSE" ]] ||
    fail "missing SentencePiece license under $root"
done

grep -qx "Version: 0.32.2" \
  "$IOS_RESOURCES/lib/python3.14/site-packages/mlx-0.32.2.dist-info/METADATA" ||
  fail "missing iOS MLX 0.32.2 metadata"
grep -qx "Version: 0.32.2" \
  "$MACOS_RESOURCES/lib/python3.14/site-packages/mlx-0.32.2.dist-info/METADATA" ||
  fail "missing macOS MLX 0.32.2 metadata"

for metallib in \
  "$IOS_MLX/mlx-ios.metallib" \
  "$MACOS_MLX/mlx-macos.metallib"; do
  [[ -f "$metallib" ]] || fail "missing MLX Metal library: $metallib"
  file "$metallib" | grep -q "MetalLib executable" ||
    fail "invalid MLX Metal library: $metallib"
done
[[ ! -e "$IOS_MLX/mlx-ios-simulator.metallib" ]] ||
  fail "iOS resources unexpectedly contain a simulator MLX Metal library"

echo "PythonIOS vendor verification passed"
