#!/bin/zsh
# build.sh OUT_DIR: build the harnesses and copy them to OUT_DIR (bazel-bin
# follows the configuration of the last build, so copies are stable).
set -e
cd ${0:A:h}/../../../..
out=$1
if ! bazel build //Vendors/ios_system:osh_validation //Vendors/ios_system:native_command_validation \
    //Apps/LocalCode/Debug/LegacyCommandConcurrencyProbe > $out/build.log 2>&1; then
  /usr/bin/grep -E "error:|FAILED" $out/build.log | head -20
  exit 1
fi
for target in Vendors/ios_system/osh_validation Vendors/ios_system/native_command_validation \
    Apps/LocalCode/Debug/LegacyCommandConcurrencyProbe/LegacyCommandConcurrencyProbe; do
  file=$(bazel cquery --output=files //${target:h}:${target:t} 2>/dev/null | /usr/bin/grep -v '\.zip$' | head -1)
  cp -f "$file" "$out/${target:t}"
done
ls -la $out | /usr/bin/grep -v total
