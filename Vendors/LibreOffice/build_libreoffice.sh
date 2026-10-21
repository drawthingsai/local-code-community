#!/bin/bash
set -euo pipefail
vendor_root="$(cd "$(dirname "$0")" && pwd)"
kit="$vendor_root/.build/kit"
if [[ $# == 2 && "$1" == --kit ]]; then
  mkdir -p "$2"
  kit="$(cd "$2" && pwd)"
elif [[ $# != 0 ]]; then
  echo 'Usage: build_libreoffice.sh [--kit BUILD_CHECKOUT]' >&2
  exit 2
fi
"$vendor_root/build.sh" --kit "$kit"
python3 "$vendor_root/build-ios.py" --kit "$kit"
python3 "$vendor_root/encapsulate-ios.py"
python3 "$vendor_root/package_vendor.py"
