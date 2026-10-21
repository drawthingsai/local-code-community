#!/bin/bash
set -euo pipefail

vendor_root="$(cd "$(dirname "$0")" && pwd)"
kit="$vendor_root/.build/kit"
if [[ $# == 2 && "$1" == --kit ]]; then
  mkdir -p "$2"
  kit="$(cd "$2" && pwd)"
elif [[ $# != 0 ]]; then
  echo 'Usage: build.sh [--kit EXISTING_OR_NEW_BUILD_CHECKOUT]' >&2
  exit 2
fi
revision=b19bb73c74ed893b8a5d1716d32df32a113ed31b
jobs="${OFFICE_BUILD_JOBS:-12}"
if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
  echo 'Only macOS arm64 is currently supported; iOS needs a separate source build.' >&2
  exit 1
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]]
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:$PATH"
if [[ ! -d "$kit/.git" ]]; then
  git init "$kit"
  git -C "$kit" remote add origin https://github.com/deepseek-ai/dsh-libreoffice-kit.git
  git -C "$kit" fetch --depth=1 origin "$revision"
  git -C "$kit" checkout --detach "$revision"
fi
[[ "$(git -C "$kit" rev-parse HEAD)" == "$revision" ]]
cp "$vendor_root/Patches/headless-static.patch" "$kit/engine/native/patches/0090-headless-static.patch"
cp "$vendor_root/Patches/headless-fonts.patch" "$kit/engine/native/patches/0091-headless-fonts.patch"
cp "$vendor_root/Patches/headless-factory.patch" "$kit/engine/native/patches/0092-headless-factory.patch"
cp "$vendor_root/Patches/headless-spellcheck.patch" "$kit/engine/native/patches/0093-headless-spellcheck.patch"
cp "$vendor_root/Patches/headless-font-refresh.patch" "$kit/engine/native/patches/0094-headless-font-refresh.patch"
python3 - "$kit" <<'PY'
import pathlib, subprocess, sys
kit = pathlib.Path(sys.argv[1])
name = 'engine/native/configure.mjs'
source = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=kit, text=True)
old = "if (platform.startsWith('darwin-')) flags.push('--enable-bogus-pkg-config');"
assert source.count(old) == 1
source = source.replace(old, "if (platform.startsWith('darwin-')) flags.push('--enable-bogus-pkg-config', "
    "'--enable-headless', '--without-system-cairo', '--without-system-fontconfig', '--without-system-freetype');")
(kit / name).write_text(source)
# The upstream executable is only a build/link-closure input. Its worker object
# is discarded when encapsulate.py replaces it with OfficeCommand.o.
name = 'engine/native/worker.cxx'
worker = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=kit, text=True)
worker = '#define OFFICE_HEADLESS_SVP 1\n' + worker
worker = worker.replace('#ifdef __APPLE__\n    CFURLRef',
    '#if defined(__APPLE__) && !defined(OFFICE_HEADLESS_SVP)\n    CFURLRef')
worker = worker.replace('#if defined(__APPLE__) || defined(_WIN32)\n    for (const auto& font',
    '#if defined(_WIN32)\n    for (const auto& font')
worker = worker.replace('#if !defined(__APPLE__) && !defined(_WIN32)\n    for (const auto& font',
    '#if !defined(_WIN32)\n    for (const auto& font')
if (kit / name).read_text() != worker:
    (kit / name).write_text(worker)
PY
cd "$kit"
node scripts/checkout-core.mjs
args=(--platform darwin-arm64 --jobs "$jobs" --no-lto --optimization O2)
if [[ ! -f .build/native-darwin-arm64/dsh-build-identity.json ]]; then
  node scripts/build-native.mjs "${args[@]}" --configure-only
fi
python3 "$vendor_root/prefetch.py" "$kit/.build/native-darwin-arm64"
node scripts/build-native.mjs "${args[@]}" --resume
python3 "$vendor_root/encapsulate.py" --kit "$kit" --output "$vendor_root/Artifacts/macos-arm64"
"$vendor_root/Artifacts/macos-arm64/bin/office" --help
