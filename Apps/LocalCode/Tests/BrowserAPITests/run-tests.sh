#!/bin/bash
set -euo pipefail
exec "$1" "$(dirname "$2")" "$3" "${TEST_TMPDIR:?}"
