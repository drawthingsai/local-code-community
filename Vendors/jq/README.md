# jq for ios_system

Checked-in jq 1.8.2 release sources, with its bundled Oniguruma 6.9.10 and
IBM decNumber. `sources.json` records the release archive checksum and individual
upstream file checksums. `COPYING` includes jq, dtoa, and decNumber notices;
Oniguruma's notice is in `vendor/oniguruma/COPYING`. These notices also ship in
Local Code's `NativeCommandLicenses.txt` resource.

Bazel builds the upstream CLI and library together as `//Vendors/jq`. The release
includes generated Flex/Bison sources; no generator or configure step runs in
an app build. `builtin.inc` comes from the release's `builtin.jq` using upstream's
octal-byte generator. `jq_config.h` records the configure feature probes for
64-bit Apple platforms, with global setlocale/atexit disabled. `src/config_opts.inc`
describes this embedded build. Regexes and precise decimal literals are enabled.

## Embedding changes

- `main.c` exports the ordinary `jq_main` entry. It initializes/restores the
  thread locale through `ios_system_support`, flushes the borrowed stdout
  instead of closing it, and explicitly tears down jq, input state, arguments,
  module paths, and colors. Help/version follow this cleanup path.
- Files and modules explicitly call the support layer's session-relative
  `fopen`, `open`, `stat`, and `realpath` operations. Darwin `dirname_r` avoids
  static path buffers. `$ORIGIN` is `/usr/bin`, matching the virtual executable.
- `env` / `$ENV` read ios_system's command environment; `PWD` comes from the
  session directory. They share the runtime's existing environment semantics.
  No new process-global environment snapshot or override is introduced.
- Colors use thread-local storage and release their buffer at completion.
  Oniguruma's UTF-8 initialization and parse-depth setting run under
  `pthread_once`; immutable tables remain available for the application lifetime.
  Regex objects/regions remain owned and freed by each invocation.
- Decimal/dtoa caches retain their upstream pthread-key destructors. Their
  process-exit handlers are unnecessary for command pthreads and are omitted.
- UTC `strftime` expands `%z` (including `%Ez`/`%Oz`, respecting `%%`) locally,
  avoiding upstream's Apple workaround that temporarily mutates process `TZ`.
  Local date functions use Darwin's timezone and reentrant time APIs; a shell
  `TZ` assignment does not establish an independent per-session timezone.
  `lgamma` uses `lgamma_r` to avoid the process-global `signgam` output.
- Parser symbols and `expand_path` are namespaced to coexist with awk and Git.
  Parser/lexer specification changes match the checked-in generated sources.
- The registry classifies jq as thread-safe and requests a 16 MiB stack for its
  recursive algorithms and upstream 10,000-level depth limits. Sanitizer builds
  reserve four times that size for instrumented stack frames. Other commands
  retain the pthread default. Stack reservation does not eagerly commit RAM.

Fatal allocation/argument exits and pthread cancellation can still bypass normal
cleanup. Recovery of partial jq state, open files, colors, and locales on those
paths is follow-up work, consistent with the other native commands. No automatic
resource tracker or cancellation interception is used.

## Validation

`//Vendors/ios_system:NativeCommandTests` runs embedded CLI/ownership/concurrency
checks and the checked-in upstream jq, optional, regex, manual, base64, and URI
suites through `jq --run-tests`. It also checks shell pipelines, pipefail,
command environments, halt status, and virtual `/usr/bin/jq`. The same native
suite runs in the iOS simulator validation app. See
`../ios_system/NATIVE_COMMANDS.md` for build/test commands.
