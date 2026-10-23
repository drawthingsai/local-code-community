#!/bin/bash
set -euo pipefail

input=$1
output=$2
minimum_os=$3
replatform_tool=$4
input=$(cd "$(dirname "$input")" && pwd)/$(basename "$input")
replatform_tool=$(cd "$(dirname "$replatform_tool")" && pwd)/$(basename "$replatform_tool")
output="$PWD/$output"
[[ "$2" = /* ]] && output=$2

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/curl-cffi-catalyst.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

# Preserve the encapsulated object and its private native dependencies, as in
# the Python Catalyst import. Only the platform load command needs to change.
xcrun ar -x "$input" CurlCFFI.o
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
/usr/bin/python3 "$replatform_tool" CurlCFFI.o "$output" macos "$minimum_os" "$sdk_version"

if xcrun nm -u "$output" | grep -Eq '^l[0-9]+$'; then
  echo "Replatformed CurlCFFI object contains an unresolved linker-local symbol" >&2
  exit 1
fi
xcrun size -m "$output" | grep -Eq 'Section \(__LD, __compact_unwind\): [1-9][0-9]*'
xcrun vtool -show-build "$output" | grep -q 'platform MACCATALYST'
