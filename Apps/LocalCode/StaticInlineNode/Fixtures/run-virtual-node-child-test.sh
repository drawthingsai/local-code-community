#!/bin/bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  ROOT="$TEST_SRCDIR/$TEST_WORKSPACE"
else
  ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
fi
FIXTURE_SCRIPT="$ROOT/Apps/LocalCode/StaticInlineNode/Fixtures/virtual-node-child-smoke.js"
if [[ -L "$FIXTURE_SCRIPT" ]]; then
  FIXTURE_SCRIPT=$(readlink "$FIXTURE_SCRIPT")
fi
FIXTURES=$(cd "$(dirname "$FIXTURE_SCRIPT")" && pwd)

export NODE_MOBILE_VIRTUAL_NODE_PRELOAD="$ROOT/Apps/LocalCode/Resources/NodeMobile/Runtime/virtual-node-child-preload.cjs"
export NODE_MOBILE_VIRTUAL_NODE_ROOTS="$FIXTURES"
unset NODE_MOBILE_NPX_CLI

"$ROOT/Apps/LocalCode/StaticInlineNodeMacOS" \
  "$FIXTURE_SCRIPT"
