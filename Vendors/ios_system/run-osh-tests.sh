#!/bin/bash
set -euo pipefail
# Bash 3.2 does not apply errexit to [[ ... ]]; assertions explicitly exit.

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  ROOT="$TEST_SRCDIR/$TEST_WORKSPACE"
else
  ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fi

VALIDATION="$ROOT/Vendors/ios_system/osh_validation"
TEST_ROOT="${TEST_TMPDIR:-/private/tmp}"
STDOUT_FILE="$TEST_ROOT/osh-quoted-paths-stdout"
STDERR_FILE="$TEST_ROOT/osh-quoted-paths-stderr"
export TMPDIR="$TEST_ROOT"
export TEST_TMPDIR="$TEST_ROOT"

"$VALIDATION" \
  'cd "$HOME" && mkdir -p Photos "Screenshots & Screen Recordings" && touch IMG_4946.png "Screenshot 2026-08-31 at 12.12.57 PM.png"' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"

"$VALIDATION" \
  'cd "$HOME" && mv IMG_4946.png "Photos/IMG_4946.png" && mv "Screenshot 2026-08-31 at 12.12.57 PM.png" "Screenshots & Screen Recordings/Screenshot 2026-08-31 at 12.12.57 PM.png" && echo "=== Desktop now ===" && ls -1 && echo && echo "=== Photos ===" && ls -1 Photos && echo && echo "=== Screenshots count ===" && find "Screenshots & Screen Recordings" -maxdepth 1 -type f | wc -l' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"

VALIDATION_ROOT="$TEST_ROOT/local-code-osh-validation"
[[ -f "$VALIDATION_ROOT/Photos/IMG_4946.png" ]] || exit 1
[[ -f "$VALIDATION_ROOT/Screenshots & Screen Recordings/Screenshot 2026-08-31 at 12.12.57 PM.png" ]] || exit 1
[[ ! -e "$VALIDATION_ROOT/IMG_4946.png" ]] || exit 1
[[ ! -e "$VALIDATION_ROOT/Screenshot 2026-08-31 at 12.12.57 PM.png" ]] || exit 1
/usr/bin/grep -q '^IMG_4946\.png$' "$STDOUT_FILE"
/usr/bin/grep -Eq '^[[:space:]]*1[[:space:]]*$' "$STDOUT_FILE"

"$VALIDATION" \
  'runtime-command alpha "two words" && which runtime-command && ls /usr/bin/runtime-command' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '^runtime-command:alpha:two words$' "$STDOUT_FILE"
[[ $(/usr/bin/grep -c '^/usr/bin/runtime-command$' "$STDOUT_FILE") -eq 2 ]] || exit 1

# A command that raises an Objective-C exception exits like an aborted process.
"$VALIDATION" 'runtime-command --raise; echo "status=$?"' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '^status=134$' "$STDOUT_FILE"
/usr/bin/grep -q 'triggered a system exception: NSInvalidArgumentException' "$STDERR_FILE"

"$VALIDATION" \
  'cd "$HOME" && mkdir -p "Redirection Cases" && printf "alpha beta\n" > "Redirection Cases/input file.txt" && cat < "Redirection Cases/input file.txt" > "Redirection Cases/output file.txt" && printf "second line\n" >> "Redirection Cases/output file.txt" && find "Screenshots & Screen Recordings" -maxdepth 1 -type f | wc -l > "Redirection Cases/count file.txt" && ls "definitely missing" 2> "Redirection Cases/error file.txt" || true' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"

[[ $(< "$VALIDATION_ROOT/Redirection Cases/output file.txt") == $'alpha beta\nsecond line' ]] || exit 1
[[ $(tr -d ' ' < "$VALIDATION_ROOT/Redirection Cases/count file.txt") == "1" ]] || exit 1
[[ -s "$VALIDATION_ROOT/Redirection Cases/error file.txt" ]] || exit 1

# Discovery must consult the same registry as execution, including commands
# registered at runtime and version-suffixed names with no executable file.
"$VALIDATION" '
  set -e
  PATH=/usr/bin
  for c in node npm npx python python3 python3.14 pip pip3 curl git sed awk grep rg jq zip unzip runtime-command; do
    [[ $(command -v "$c") == "/usr/bin/$c" ]]
    [[ $(type -P "$c") == "/usr/bin/$c" ]]
  done
  command -V runtime-command
  type runtime-command
  [[ $(type -t runtime-command) == file ]]
  [[ $(command -v /usr/bin/runtime-command) == /usr/bin/runtime-command ]]
  if command -v /usr/bin/xcrun; then exit 1; fi
  if command -v definitely-not-a-command; then exit 1; fi
  PATH=/does-not-exist
  if command -v runtime-command; then exit 1; fi
  [[ $(command -v /usr/bin/runtime-command) == /usr/bin/runtime-command ]]
  PATH=/usr/bin
  jq() { :; }
  [[ $(command -v jq) == jq && $(type -t jq) == function ]]
  unset -f jq
  alias jq="echo alias"
  [[ $(type -t jq) == alias ]]
  unalias jq
  [[ $(command -v jq) == /usr/bin/jq ]]
  [[ $(command -v printf) == printf && $(type -t printf) == builtin ]]
' > "$STDOUT_FILE" 2> "$STDERR_FILE"
[[ $(/usr/bin/grep -c '^runtime-command is /usr/bin/runtime-command$' "$STDOUT_FILE") -eq 2 ]] || exit 1

"$VALIDATION" '
  set -e
  PATH=/usr/bin
  mkdir -p "$HOME/discovery-bin"
  printf "#!/bin/sh\n" > "$HOME/discovery-bin/runtime-command"
  chmod +x "$HOME/discovery-bin/runtime-command"
  printf "not executable\n" > "$HOME/discovery-bin/not-executable"
  mkdir -p "$HOME/discovery-bin/not-a-file"
  PATH="$HOME/discovery-bin:/usr/bin"
  [[ $(command -v runtime-command) == "$HOME/discovery-bin/runtime-command" ]]
  [[ $(type -ap runtime-command) == "$HOME/discovery-bin/runtime-command
/usr/bin/runtime-command" ]]
  if command -v not-executable; then exit 1; fi
  if command -v not-a-file; then exit 1; fi
  PATH="/usr/bin:$HOME/discovery-bin"
  [[ $(command -v runtime-command) == /usr/bin/runtime-command ]]
  cd "$HOME/discovery-bin"
  PATH=:/usr/bin
  [[ $(command -v runtime-command) == runtime-command ]]
' > "$STDOUT_FILE" 2> "$STDERR_FILE"

# Disk usage must work through the same shell path used by Local Code.
"$VALIDATION" \
  'pwd; echo "---"; df -h . | tail -3; echo "---"; du -sh .localc 2>/dev/null' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '^Filesystem.*Size.*Mounted on' "$STDOUT_FILE"
[[ $(/usr/bin/grep -c '^---$' "$STDOUT_FILE") -eq 2 ]] || exit 1
/usr/bin/grep -q '[[:space:]]\.localc$' "$STDOUT_FILE"
if /usr/bin/grep -q 'not found' "$STDERR_FILE"; then exit 1; fi
"$VALIDATION" 'set -e; set -o pipefail; df -k . | tail -n 1; df -k . >/dev/null' \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"

# Native consumers must stream concurrently and own their files/options per call.
"$VALIDATION" '
  set -e
  set -o pipefail
  printf "first\n" > pipeline-input
  cat pipeline-input | tee pipeline-one | tee pipeline-two
  cat pipeline-input | tee -a pipeline-one > pipeline-copy
  [[ $(cat pipeline-one) == "first
first" ]]
  [[ $(cat pipeline-two) == first && $(cat pipeline-copy) == first ]]
  cat pipeline-input | tee missing-directory/output >/dev/null && exit 1
  [[ $? == 1 && ${PIPESTATUS[1]} == 1 ]]
' > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '^first$' "$STDOUT_FILE"

"$VALIDATION" --validate-streaming-lifecycle > "$STDOUT_FILE" 2> "$STDERR_FILE"
/usr/bin/grep -q '^runtime-command:--slow:alpha$' "$STDOUT_FILE"

"$VALIDATION" --validate-streaming-pids > "$STDOUT_FILE" 2> "$STDERR_FILE"

"$VALIDATION" --validate-streaming-resolution > "$STDOUT_FILE" 2> "$STDERR_FILE"

"$VALIDATION" --validate-streaming-cwd > "$STDOUT_FILE" 2> "$STDERR_FILE"

# Early consumers must close every tee input, allowing the producer to stop.
"$VALIDATION" '
  runtime-command --until-epipe | tee | cmp -s - /dev/null
  [[ $? == 1 && ${PIPESTATUS[*]} == "0 1 1" ]] || exit 1
  set -o pipefail
  runtime-command --until-epipe | tee tee-early-one | tee tee-early-two | /usr/bin/true
  [[ $? == 1 && ${PIPESTATUS[*]} == "0 1 1 0" ]] || exit 1
  [[ -f tee-early-one && -f tee-early-two ]] || exit 1
' > "$STDOUT_FILE" 2> "$STDERR_FILE"
[[ $(/usr/bin/grep -c '^tee: stdout: ' "$STDERR_FILE") -eq 3 ]] || exit 1

"$VALIDATION" --validate-tee-write-error > "$STDOUT_FILE" 2> "$STDERR_FILE"

# Embedded commands must leave the app's process-wide signal dispositions alone.
"$VALIDATION" --validate-signal-isolation > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
  cat "$STDERR_FILE" >&2
  exit 1
}

"$VALIDATION" --validate-stop-before-shell-starts > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
  cat "$STDERR_FILE" >&2
  exit 1
}
if /usr/bin/grep -q 'should-not-run' "$STDOUT_FILE"; then exit 1; fi
/usr/bin/grep -q '^recovered$' "$STDOUT_FILE"

"$VALIDATION" --validate-job-cancellation > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
  cat "$STDERR_FILE" >&2
  exit 1
}
if /usr/bin/grep -q 'should-not-run' "$STDOUT_FILE"; then exit 1; fi

"$VALIDATION" --validate-cancelled-native-caller > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
  cat "$STDERR_FILE" >&2
  exit 1
}
/usr/bin/grep -q '^recovered$' "$STDOUT_FILE"

# A redirect error fails that stage, not the whole pipeline setup.
"$VALIDATION" '
  cat < missing-pipeline-input | tee empty-pipeline-output
  [[ $? == 0 && ${PIPESTATUS[*]} == "1 0" ]] || exit 1
  [[ -f empty-pipeline-output && ! -s empty-pipeline-output ]] || exit 1
  set -o pipefail
  cat < missing-pipeline-input | tee empty-pipeline-output
  [[ $? == 1 && ${PIPESTATUS[*]} == "1 0" ]] || exit 1
  cat /dev/null | tee < missing-pipeline-input | tee empty-pipeline-output
  [[ $? == 1 && ${PIPESTATUS[*]} == "0 1 0" ]] || exit 1
  cat /dev/null | tee > missing-pipeline-directory/output
  [[ $? == 1 && ${PIPESTATUS[*]} == "0 1" ]] || exit 1
' > "$STDOUT_FILE" 2> "$STDERR_FILE"

# sh and bash hand their invocation to OSH. Each case runs inside a shell job,
# so every sh/bash/script invocation here is a nested shell.
SHELL_INVOCATIONS=$(cat <<'EOF'
set -e
set -o pipefail
cat > sh-script <<'SCRIPT'
#!/bin/sh
printf '%s|%s|%s\n' "$0" "$#" "$1"
SCRIPT
cat > bash-script <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ -n $BASH_VERSION ]]
printf 'bash|%s\n' "$*"
SCRIPT
chmod +x sh-script bash-script
[[ $(sh -c 'printf "%s|%s|%s\n" "$#" "$0" "$1"' probe hello) == '1|probe|hello' ]]
[[ $(sh -c 'printf "[%s]" "$@"' name '' 'a b') == '[][a b]' ]]
[[ $(sh -eu -c 'echo ok') == ok ]]
[[ -z $(sh -c 'echo "${BASH_VERSION:-}"') ]]
[[ -n $(bash -lc 'echo "$BASH_VERSION"') ]]
[[ $(/bin/sh -c 'echo abs') == abs && $(/bin/bash -c 'echo abs') == abs ]]
[[ $(sh sh-script 'a b' c) == 'sh-script|2|a b' ]]
[[ $(./sh-script x) == './sh-script|1|x' ]]
[[ $(./bash-script x y) == 'bash|x y' ]]
[[ $(./sh-script x | tr a-z A-Z) == './SH-SCRIPT|1|X' ]]
[[ $(echo 'echo from-input' | sh) == from-input ]]
[[ $(echo hello | sh -c 'cat; echo done' | tr '\n' ' ') == 'hello done ' ]]
status=0; sh -c 'exit 3' || status=$?; [[ $status == 3 ]]
status=0; sh -e -c 'false; echo no' || status=$?; [[ $status == 1 ]]
status=0; sh -i -c 'echo no' 2>/dev/null || status=$?; [[ $status == 125 ]]
here=$PWD
mkdir -p nested-dir
[[ $(sh -c 'cd nested-dir && pwd') == "$here/nested-dir" && $PWD == "$here" ]]
export NESTED_MARKER=outer
[[ $(bash -c 'echo "$NESTED_MARKER"') == outer ]]
[[ $(sh -c 'echo out; echo err >&2' 2>&1 | sort | tr '\n' ' ') == 'err out ' ]]
[[ $(sh -c 'sh -c "bash -c \"echo depth3\""') == depth3 ]]
[[ $(for i in 1 2 3; do sh -c 'printf "%s" "$0"' "$i"; done) == 123 ]]
status=0; env FOO=bar sh -c 'echo "$FOO"; exit 4' > env-output || status=$?
[[ $status == 4 && $(cat env-output) == bar ]]
[[ $(printf 'read word\nhello\necho "word=$word"\n' | sh) == word=hello ]]
[[ $(printf 'touch stdin-marker\necho after-touch\n' | sh) == after-touch && -f stdin-marker ]]
[[ $(printf 'cat\nhello\n' | sh) == hello ]]
# Nested shells consume only what they read from a script piped into a shell.
[[ $(printf 'sh -c true\necho after-shell\n' | sh) == after-shell ]]
[[ $(printf 'bash -c true\necho after-bash\n' | sh) == after-bash ]]
[[ $(printf 'env sh -c true\necho after-env\n' | sh) == after-env ]]
[[ $(printf 'sh -c "read x; echo got-\\$x"\nline\necho after-read\n' | sh | tr '\n' ' ') == 'got-line after-read ' ]]
[[ $(printf 'sh -c cat\nhello\n' | sh) == hello ]]
# Shell recursion runs on the C stack in this process: deep recursion works in
# both evaluators, and runaway recursion fails the shell instead of the host.
f() { if (( $1 > 0 )); then f $(($1-1)); fi; }
f 1000
[[ $(bash -c 'f() { if (( $1 > 0 )); then f $(($1-1)); fi; }; f 1000; echo deep') == deep ]]
status=0; bash -c 'f() { f; }; f' 2> recursion-error || status=$?
[[ $status == 2 ]] && /usr/bin/grep -q 'maximum recursion depth exceeded' recursion-error
echo shell-invocations-ok
EOF
)
"$VALIDATION" "$SHELL_INVOCATIONS" > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
  cat "$STDERR_FILE" >&2
  exit 1
}
/usr/bin/grep -q '^shell-invocations-ok$' "$STDOUT_FILE"

echo 'OSH integration tests passed'
