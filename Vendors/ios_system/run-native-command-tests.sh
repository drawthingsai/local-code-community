#!/bin/bash
set -euo pipefail
# Bash 3.2 does not apply errexit to [[ ... ]]; assertions explicitly exit.

NATIVE_TEST_ROOT="$TEST_SRCDIR/$TEST_WORKSPACE/Vendors/ios_system"
NATIVE_TEST_LOG="$TEST_TMPDIR/native-commands.log"
trap 'tail -40 "$TEST_TMPDIR"/native*.log "$TEST_TMPDIR"/native-error.stderr 2>/dev/null || true' ERR
if ! "$NATIVE_TEST_ROOT/native_command_validation" > "$NATIVE_TEST_LOG" 2>&1; then
  cat "$NATIVE_TEST_LOG"
  exit 1
fi

NATIVE_PIPELINE_RESULT=$("$NATIVE_TEST_ROOT/osh_validation" \
  'set -o pipefail; printf abc | base64 | base64 -d | sha256sum' \
  2> "$TEST_TMPDIR/native-pipeline.log")
[[ "$NATIVE_PIPELINE_RESULT" == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -' ]] || exit 1

NATIVE_TEXT_RESULT=$("$NATIVE_TEST_ROOT/osh_validation" \
  'set -o pipefail; printf "alpha,beta\ngamma,delta\n" | cut -d , -f 2 | paste -s -d : - | xxd -p | xxd -r -p' \
  2> "$TEST_TMPDIR/native-text-pipeline.log")
[[ "$NATIVE_TEXT_RESULT" == 'beta:delta' ]] || exit 1

NATIVE_ERROR_STATUS=0
"$NATIVE_TEST_ROOT/osh_validation" \
  'set -o pipefail; printf invalid | base64 -d | cat' \
  > "$TEST_TMPDIR/native-error.stdout" 2> "$TEST_TMPDIR/native-error.stderr" || NATIVE_ERROR_STATUS=$?
[[ "$NATIVE_ERROR_STATUS" != 0 ]] || exit 1

/usr/bin/python3 "$NATIVE_TEST_ROOT/validate-diff.py" "$NATIVE_TEST_ROOT/osh_validation"

/usr/bin/python3 "$NATIVE_TEST_ROOT/validate-jq.py" "$NATIVE_TEST_ROOT/osh_validation" "$TEST_SRCDIR/$TEST_WORKSPACE/Vendors/jq"

/usr/bin/python3 "$NATIVE_TEST_ROOT/validate-infozip.py" "$NATIVE_TEST_ROOT/osh_validation"

echo 'Native command and shell pipeline tests passed.'
