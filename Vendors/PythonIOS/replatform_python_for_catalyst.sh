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

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/python-catalyst.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

# The packaged macOS archive contains one already-encapsulated object. A second
# relocatable link corrupts linker-local symbols with Xcode 27 (for example,
# it leaves an undefined l70138). Only the platform load command needs to
# change because macOS and Mac Catalyst use the same arm64 ABI here.
xcrun ar -x "$input" Python.o
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
/usr/bin/python3 "$replatform_tool" Python.o "$output" macos "$minimum_os" "$sdk_version"

if xcrun nm -u "$output" | grep -Eq '^l[0-9]+$'; then
  echo "Replatformed Python object contains an unresolved linker-local symbol" >&2
  exit 1
fi
xcrun vtool -show-build "$output" | grep -q 'platform MACCATALYST'
