#!/bin/bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  ROOT="$TEST_SRCDIR/$TEST_WORKSPACE"
else
  ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
fi

export NODE_MOBILE_VIRTUAL_NODE_PRELOAD="$ROOT/Apps/LocalCode/Resources/NodeMobile/Runtime/virtual-node-child-preload.cjs"

NPM_ROOT="${TEST_TMPDIR:-/private/tmp}/localcode-npm-11.19.1"
rm -rf "$NPM_ROOT"
mkdir -p "$NPM_ROOT"
unzip -q \
  "$ROOT/Vendors/NodeJS/Resources/NodeMobile/Commands/npm-11.19.1.zip" \
  -d "$NPM_ROOT"
export NODE_MOBILE_NPM_ROOT="$NPM_ROOT"

"$ROOT/Apps/LocalCode/StaticInlineNodeIOSSystemMacOS"
