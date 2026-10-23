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

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/node-catalyst.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

# The macOS archive contains one already-encapsulated object. As with Python,
# preserve its private symbols and compact unwind without another relocatable
# link; only its platform load command needs to change for Mac Catalyst.
xcrun ar -x "$input" NodeMobileEncapsulated.o
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
/usr/bin/python3 "$replatform_tool" NodeMobileEncapsulated.o "$output" macos "$minimum_os" "$sdk_version"

if xcrun nm -u "$output" | grep -Eq '^l[0-9]+$'; then
  echo "Replatformed Node object contains an unresolved linker-local symbol" >&2
  exit 1
fi
xcrun size -m "$output" | grep -Eq 'Section \(__LD, __compact_unwind\): [1-9][0-9]*'
xcrun vtool -show-build "$output" | grep -q 'platform MACCATALYST'
