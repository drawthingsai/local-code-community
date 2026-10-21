#!/bin/bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  ROOT="$TEST_SRCDIR/$TEST_WORKSPACE"
else
  ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fi

VALIDATION="$ROOT/Vendors/ios_system/openssh_validation"
TEST_ROOT="${TEST_TMPDIR:-/private/tmp}/libcaca-img2txt-tests"
FIXTURE="$TEST_ROOT/fixture.png"
JPEG_FIXTURE="$TEST_ROOT/fixture.jpg"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"

mkdir -p "$TEST_ROOT"

# A 4x4 RGBA PNG. Keeping the fixture textual makes the vendor import easy to
# audit and still exercises the ImageIO path instead of libcaca's BMP fallback.
PNG_BASE64='iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAABY2lDQ1BrQ0dDb2xvclNwYWNlRGlzcGxheVAzAAAokX2QsUvDUBDGv1aloHUQHRwcMolDlJIKuji0FURxCFXB6pS+pqmQxkeSIgU3/4GC/4EKzm4Whzo6OAiik+jm5KTgouV5L4mkInqP435877vjOCA5bnBu9wOoO75bXMorm6UtJfWMBL0gDObxnK6vSv6uP+P9PvTeTstZv///jcGK6TGqn5QZxl0fSKjE+p7PJe8Tj7m0FHFLshXyieRyyOeBZ71YIL4mVljNqBC/EKvlHt3q4brdYNEOcvu06WysyTmUE1jEDjxw2DDQhAId2T/8s4G/gF1yN+FSn4UafOrJkSInmMTLcMAwA5VYQ4ZSk3eO7ncX3U+NtYMnYKEjhLiItZUOcDZHJ2vH2tQ8MDIEXLW54RqB1EeZrFaB11NguASM3lDPtlfNauH26Tww8CjE2ySQOgS6LSE+joToHlPzA3DpfAEDp2ITpJYOWwAAAARjSUNQDA0AAW4D4+8AAAA4ZVhJZk1NACoAAAAIAAGHaQAEAAAAAQAAABoAAAAAAAKgAgAEAAAAAQAAAASgAwAEAAAAAQAAAAQAAAAA5qTcOAAAAZ1pVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IlhNUCBDb3JlIDYuMC4wIj4KICAgPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4KICAgICAgPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIKICAgICAgICAgICAgeG1sbnM6ZXhpZj0iaHR0cDovL25zLmFkb2JlLmNvbS9leGlmLzEuMC8iPgogICAgICAgICA8ZXhpZjpQaXhlbFhEaW1lbnNpb24+MjU2PC9leGlmOlBpeGVsWERpbWVuc2lvbj4KICAgICAgICAgPGV4aWY6UGl4ZWxZRGltZW5zaW9uPjI1NjwvZXhpZjpQaXhlbFlEaW1lbnNpb24+CiAgICAgIDwvcmRmOkRlc2NyaXB0aW9uPgogICA8L3JkZjpSREY+CjwveDp4bXBtZXRhPgpesB4bAAAARklEQVQIHWP4/v2/4r//fy/9B2IQm+Hf//+Xzuze/f/s3j3/QWyWX3/+MLC++8TAwMjEAGIzvn//XoGbk3M9AxB8/f49EACV3iqWTnTgzQAAAABJRU5ErkJggg=='
JPEG_BASE64='/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMQD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABgEBAQAAAAAAAAAAAAAAAAAABgcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAEAAQDASIAAhEAAxEA/9oADAMBAAIRAxEAPwCLAE1/f//Z'
printf '%s' "$PNG_BASE64" | /usr/bin/base64 -D > "$FIXTURE"
printf '%s' "$JPEG_BASE64" | /usr/bin/base64 -D > "$JPEG_FIXTURE"

"$VALIDATION" which img2txt > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '/usr/bin/img2txt' "$STDOUT_FILE"

"$VALIDATION" img2txt --version > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q 'Version: 0.99.beta20' "$STDOUT_FILE"

"$VALIDATION" img2txt --help > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q 'Usage: img2txt' "$STDERR_FILE"
/usr/bin/grep -q 'svg: SVG vector image' "$STDERR_FILE"
if /usr/bin/grep -q 'Only BMP loading is supported' "$STDERR_FILE"; then
  echo 'img2txt help incorrectly reports BMP-only loading' >&2
  exit 1
fi

"$VALIDATION" img2txt -W 8 -H 4 -d none -f utf8 "$FIXTURE" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
[[ $(/usr/bin/wc -l < "$STDOUT_FILE") -eq 4 ]]
[[ $(/usr/bin/wc -c < "$STDOUT_FILE") -gt 32 ]]
if /usr/bin/grep -q 'libcaca debug' "$STDERR_FILE"; then
  echo 'libcaca debug logging leaked into command output' >&2
  exit 1
fi

"$VALIDATION" img2txt -W 6 -H 3 -d none -f utf8 "$JPEG_FIXTURE" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
[[ $(/usr/bin/wc -l < "$STDOUT_FILE") -eq 3 ]]

# Both commands run inside one ios_system process. This verifies that the
# libcaca-specific getopt state is reset between invocations.
"$VALIDATION" sh -c \
  "cd '$TEST_ROOT'; img2txt -W 8 -H 4 -d none -f utf8 fixture.png; img2txt -W 5 -H 3 -d none -f utf8 fixture.png" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
[[ $(/usr/bin/wc -l < "$STDOUT_FILE") -eq 7 ]]

"$VALIDATION" img2txt -W 8 -H 4 -d none -f svg "$FIXTURE" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '<svg' "$STDOUT_FILE"

if "$VALIDATION" img2txt "$TEST_ROOT/missing.png" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"; then
  echo 'img2txt unexpectedly loaded a missing image' >&2
  exit 1
fi
/usr/bin/grep -q 'unable to load' "$STDERR_FILE"

if "$VALIDATION" img2txt -x 0 "$FIXTURE" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"; then
  echo 'img2txt unexpectedly accepted a zero-width font' >&2
  exit 1
fi
/usr/bin/grep -q 'invalid font size' "$STDERR_FILE"

if "$VALIDATION" img2txt --definitely-invalid \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"; then
  echo 'img2txt unexpectedly accepted an unknown option' >&2
  exit 1
fi
/usr/bin/grep -E -q 'unrecognized option|unknown option|illegal option' "$STDERR_FILE"

echo 'img2txt integration tests passed'
