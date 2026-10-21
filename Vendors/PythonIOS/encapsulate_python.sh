#!/bin/bash
set -euo pipefail

export LC_ALL=C
export COPYFILE_DISABLE=1

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <sdk> <minimum-os-version> <input-archive> <output-archive>" >&2
  exit 1
fi

sdk=$1
minimum_os_version=$2
input_archive=$3
output_archive=$4
vendor_dir=$(cd "$(dirname "$0")" && pwd)

case "$sdk" in
  iphoneos) platform=ios ;;
  iphonesimulator) platform=ios-simulator ;;
  macosx) platform=macos ;;
  *) echo "unsupported SDK: $sdk" >&2; exit 1 ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/python-encapsulation.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)

xcrun nm -m "$input_archive" > "$work_dir/input-symbols.txt"
# Only retain definitions that were public in the input. The reviewed list is
# shared by all slices; not every platform supplies every Python module.
awk '
  NR == FNR { allowed[$0] = 1; next }
  / external / && !/ private external / && !/\(undefined\)/ && allowed[$NF] { print $NF }
' "$vendor_dir/exported_symbols.txt" "$work_dir/input-symbols.txt" |
  sort -u > "$work_dir/exports.txt"
grep -qx '_Py_InitializeFromConfig' "$work_dir/exports.txt"

# Seed every retained API so archive extraction also preserves entry points
# that are only reached by external callers or dynamic symbol lookup. Select
# archive members normally, rather than force-loading duplicate Rust runtimes.
roots=()
while IFS= read -r symbol; do
  roots+=(-u "$symbol")
done < "$work_dir/exports.txt"
# ld-classic supports allocating common globals with -d during a relocatable
# link. Apply the export boundary again afterward so those newly allocated
# definitions become local too. Strip embedded Rust bitcode from the native
# output so subsequent tools inspect and link the encapsulated machine code.
python_ld_classic=${PYTHON_LD_CLASSIC:-$(xcrun --sdk "$sdk" --find ld-classic)}
"$python_ld_classic" -r -d -arch arm64 \
  -syslibroot "$sdk_root" \
  -platform_version "$platform" "$minimum_os_version" "$sdk_version" \
  -bitcode_process_mode strip \
  -exported_symbols_list "$work_dir/exports.txt" \
  "${roots[@]}" "$input_archive" -o "$work_dir/Python.o"
xcrun nmedit -s "$work_dir/exports.txt" "$work_dir/Python.o"

# Keep one coalescible Rust personality across Python and host Rust archives.
# Localizing it creates a fourth personality beside the host's Rust, C++, and
# Objective-C routines, exceeding compact unwind's three-personality limit.
# A weak definition also lets Python link without a host Rust runtime.
if grep -qx '_rust_eh_personality' "$work_dir/exports.txt"; then
  rust_sysroot=$("${RUSTC:-rustc}" --print sysroot)
  "$rust_sysroot/lib/rustlib/aarch64-apple-darwin/bin/rust-objcopy" \
    --weaken-symbol=_rust_eh_personality "$work_dir/Python.o"
fi

# Strip local symbols only after dependency references have been bound.
xcrun libtool -static -D -o "$work_dir/libpython.a" "$work_dir/Python.o"
xcrun strip -S -x "$work_dir/libpython.a"
xcrun ranlib "$work_dir/libpython.a"
xcrun nm -m "$work_dir/libpython.a" > "$work_dir/output-symbols.txt"
if grep -Eq '\(common\)| private external ' "$work_dir/output-symbols.txt"; then
  echo "Python archive retains common or private-external definitions" >&2
  exit 1
fi
awk '/ external / && !/ private external / && !/\(undefined\)/ { print $NF }' \
  "$work_dir/output-symbols.txt" | sort -u > "$work_dir/actual-exports.txt"
diff -u "$work_dir/exports.txt" "$work_dir/actual-exports.txt"
if grep -qx '_rust_eh_personality' "$work_dir/exports.txt"; then
  grep -Eq ' weak external .*_rust_eh_personality$' "$work_dir/output-symbols.txt"
fi
cp "$work_dir/libpython.a" "$output_archive"
