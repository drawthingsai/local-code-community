#!/bin/bash
set -euo pipefail
ROOT="$TEST_SRCDIR/$TEST_WORKSPACE"
FIXTURE="$ROOT/Apps/LocalCode/StaticInlineNode/Fixtures/process-policy.js"
if [[ -L "$FIXTURE" ]]; then
  FIXTURE=$(readlink "$FIXTURE")
fi
export NODE_MOBILE_VIRTUAL_NODE_ROOTS
NODE_MOBILE_VIRTUAL_NODE_ROOTS=$(dirname "$FIXTURE")
unset NODE_MOBILE_VIRTUAL_NODE_PRELOAD
"$ROOT/Apps/LocalCode/StaticInlineNodeMacOS" "$FIXTURE"
"$ROOT/Apps/LocalCode/StaticInlinePythonMacOS" node "$FIXTURE"
export NODE_MOBILE_VIRTUAL_NODE_PRELOAD="$ROOT/Apps/LocalCode/Resources/NodeMobile/Runtime/virtual-node-child-preload.cjs"
"$ROOT/Apps/LocalCode/StaticInlineNodeMacOS" "$FIXTURE"
"$ROOT/Apps/LocalCode/StaticInlinePythonMacOS" node "$FIXTURE"
