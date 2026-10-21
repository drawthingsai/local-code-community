#!/bin/bash
set -euo pipefail
LFS_TEST_ROOT="$TEST_SRCDIR/$TEST_WORKSPACE/Vendors/ios_system"
exec /usr/bin/python3 "$LFS_TEST_ROOT/validate-git-lfs.py" "$LFS_TEST_ROOT/GitLFSValidation"
