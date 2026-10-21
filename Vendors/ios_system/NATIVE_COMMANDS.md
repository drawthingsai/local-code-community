# Native command additions

These commands are compiled from vendored C sources and exposed through the
same registry used by Local Code's shell, `which`, completion, and virtual
`/usr/bin` paths. `gzip`, `gunzip`, `tar`, and `7z` are outside this change.

| Commands | Source and command-line contract |
| --- | --- |
| `ffmpeg`, `ffprobe` | Pinned FFmpeg 9.0.2 source build. Uses upstream option parsers and formatters, with shared serialized in-process execution, command streams, session paths and cooperative cancellation. See [FFmpeg integration](../FFmpeg/README.md). |
| `readlink` | Existing BSD `stat` implementation. Supports `-n`; use `realpath` to resolve a complete path. |
| `basename`, `dirname`, `realpath` | Checked-in ios_system BSD ports. `basename` supports `-a` and `-s`; `realpath` supports `-q`. |
| `mktemp` | Apple/BSD implementation, including files, directories, templates, `-p`, and `-t`. Uses the session's `TMPDIR`. |
| `cut`, `comm`, `paste`, `join`, `split` | Apple text_cmds. Includes multibyte character selection, unlimited-length `comm` lines, duplicate-key joins, byte/line/regex splits, and decimal suffixes. |
| `df` | Upstream ios_system BSD port using native filesystem statistics. Includes human-readable/numeric units, inode output, type/local filters, and mount enumeration. See [upstream comparison](UPSTREAM_COMMANDS.md) for scope and remaining commands. |
| `du` | Apple file_cmds, with public 64-bit FTS scratch storage. Includes allocated/apparent size, hard-link accounting, depth, exclusions, and human-readable output. |
| `chmod` | ios_system's Apple/BSD port, including symbolic modes, recursion, and Darwin ACL operations supported by the filesystem. |
| `cmp` | OpenBSD implementation. Exit status 0 means equal, 1 means different, and 2 means trouble. |
| `diff` | Local Code frontend over the existing libgit2/xdiff engine. Normal, unified, context, ed, forward-ed, RCS, and conditional output; recursive directories, labels, stdin, binary detection, exclusions, and whitespace/case/pattern filtering. |
| `xxd` | Vim's standalone implementation, including plain/reverse, offsets, binary, and C include output. |
| `base64` | FreeBSD frontend adapted to streaming with Apple resolver codecs. Default encoding wraps at 76 columns; `-w 0` disables wrapping. Supports `-d`, `-i`, and their long forms. |
| `jq` | jq 1.8.2 CLI with bundled Oniguruma regex support and decNumber precision. JSON/raw/slurp/stream/sequence input, files/modules, variables, formatting, and upstream exit statuses. |
| `zip`, `unzip` | Apple zip-33 / Info-ZIP frontends using system zlib. CLI selection, update, deletion, extraction, listing, testing, traditional passwords, Unicode, and ZIP64. See `../InfoZip/README.md` for format and platform details. |
| `sha256sum` | Apple digest frontend with public CommonCrypto. GNU-style output, binary/text markers, checksum verification, escaped filenames, `--quiet`, `--status`, `--strict`, and `--zero` output. |
| `ssh-keygen` | The same pinned OpenSSH source as `ssh`, sharing BoringSSL and the ios_system compatibility layer. Key generation and management use the project's SSH home. |
| `office` | LibreOfficeKit 26.8.0.3 conversion, spreadsheet recalculation and PNG rendering (including PDFium for PDF), using the static SVP engine. Registered unconditionally; packaged archives support iOS arm64 devices and macOS arm64. See [`../LibreOffice/README.md`](../LibreOffice/README.md) for formats, limits and build instructions. |

Exact repository revisions and original paths are recorded in
`native_command_sources.json`; jq provenance and embedding details are in
[`../jq/README.md`](../jq/README.md) and `../jq/sources.json`; Info-ZIP provenance is in `../InfoZip/sources.json`. Source copyright notices are retained. The Vim
license is included in `text_cmds/xxd/LICENSE`; modifications are maintained with
this repository's ios_system vendor sources.

## Embedded execution

Each registry invocation runs on a fresh pthread. Mutable command statics and
the text/file commands' option parser state are thread-local, including for pipeline
stages. The following entries use `IOS_COMMAND_ISOLATION_THREAD_SAFE`:
`basename`, `dirname`, `realpath`, `mktemp`, `cut`, `comm`, `paste`, `join`,
`split`, `cmp`, `diff`, `xxd`, `base64`, `sha256sum`, and `jq`. Virtual `/usr/bin`
paths receive the same classification. Starting these commands does not reset
the legacy parser's process-wide getopt variables.

FFmpeg and FFprobe share `IOS_COMMAND_ISOLATION_EXCLUSIVE_FFMPEG` and use their
original option parsers. Their command library serializes initialization through
worker teardown and resets mutable frontend state between invocations. Neither
uses or resets the process-wide getopt variables. OSH's existing buffered pipeline
stages can invoke either command within the shell's 16 MiB intermediate-output limit.

Office uses `IOS_COMMAND_ISOLATION_EXCLUSIVE_LIBREOFFICE` and a persistent engine
owner thread. Queued requests can cancel with status 130; active conversions
cancel cooperatively at operation boundaries. A stuck engine call cannot be
forcibly timed out in-process. Private engine symbols prevent link collisions,
but do not isolate process-global state or crashes. Runtime files live under
`office/`; the dedicated notices group ships `Notices/LibreOffice/`.

Relative filesystem operations in the native adapter resolve against a snapshot
of the session's directory. Operands and displayed filenames remain unchanged;
`..` is resolved by the filesystem, preserving symlink semantics. Session setup
records the requested directory without re-reading the shared process cwd.
This does not replace the runtime's process-wide cwd/environment model for
legacy commands or provide filesystem conflict protection when two commands
intentionally write the same file.

Four entries remain `IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH` pending further work:

| Commands | Remaining isolation work |
| --- | --- |
| `readlink` | Shares the existing stat implementation's mutable globals and legacy getopt. |
| `df` | libc `getmntinfo` returns a shared mount buffer. Session paths and command option/formatting state are isolated. |
| `du` | libc `getbsize` writes a static buffer; its FTS traversal still depends on process cwd. |
| `chmod` | libc `setmode` temporarily changes the process umask; FTS/ACL path operations still depend on process cwd. |

Apple's checked libc sources confirm the helper issues in
[`getbsize`](https://github.com/apple-oss-distributions/Libc/blob/main/gen/FreeBSD/getbsize.c)
and [`setmode`](https://github.com/apple-oss-distributions/Libc/blob/main/gen/FreeBSD/setmode.c).

Each command has an ordinary entry function, declared and registered like the
existing commands. `ios_system_support.h` routes standard streams and getopt to
the invocation. `ios_system_support.c` supplies thread locale setup, session
path operations, and Darwin compatibility helpers (`reallocarray` and number
suffix parsing). Relative file operations call the named `ios_system_*`
functions explicitly. Allocations, descriptors, stdio, and other resources use
their ordinary libc APIs and command-owned cleanup; there is no allocation
tracker or generated entry wrapper.

Locale selection uses `newlocale`/`uselocale`, honors the session's `LC_ALL`,
category overrides, and `LANG`, and restores the previous thread locale. The
commands do not install process-wide signal handlers. FTS traversals use
`FTS_NOCHDIR`.

The private option parser is compiled from the existing `getopt_long.c` with
`IOS_SYSTEM_GETOPT`, preserving the ordinary parser instance for other commands.
This keeps one parser source without sharing mutable option state across the
new command entries.

## diff frontend

`text_cmds/diff/diff.c` follows the public `git_patch_from_buffers()` /
`git_patch_free()` pattern in the existing CC0 libgit2 example. It passes byte
lengths rather than `strlen`, retains the patch directly, and formats its hunks
without serializing and reparsing a patch. Original buffers are retained for
output when case-insensitive comparison uses folded copies. Normal completion
releases each comparison's patch, buffers, line indexes, and directory entries,
then the command's regexes, exclusions, and libgit2 initialization reference.
No changes to libgit2 or its diff algorithm are needed.

The frontend supports the options listed by `diff --help`, their corresponding
long names, and `--normal`, `--strip-trailing-cr`, `--tabsize`, and filename-case
options. `-uN` / `-cN` accept attached context counts. `-H` / `-h` are accepted
compatibility hints. Pagination (`-l`) and arbitrary group-format strings are
not supported; unknown options report status 2. This is not full GNU diffutils
option parity. xdiff may choose different valid hunks from BSD diff. Text inputs
are limited to xdiff's size bound (1 GiB minus 1 MiB); directory recursion is
limited to 128 levels and rejects ancestor cycles.

## Follow-up: errors and cancellation

Comprehensive resource recovery after fatal errors or `pthread_cancel` is
intentionally deferred. Some imported commands already register explicit
pthread cleanup handlers, but this change does not promise complete coverage.
Normal completion and ordinary reported failures are validated; allocator
failure injection and cancellation cleanup are not acceptance criteria here.

Future work should audit partial ownership at each command's fatal exits:

- `zip`, `unzip`: partial archive/entry state, temporary archives, descriptors,
  argument/password buffers, compression state, and locale cleanup on fatal exits
  or cancellation. Keep cleanup explicit in the owning command.
- `jq`: fatal argument/allocation exits or cancellation can strand jq/input
  state, open files, arguments, module paths, colors, and the thread locale.
- `diff`: option parsing/allocation failures can bypass command cleanup;
  cancellation during file I/O, directory traversal, libgit2 computation, or
  output can strand buffers, directory entries, a patch, or an initialization
  reference. Keep cancellation from unwinding through xdiff before its own
  cleanup finishes.
- `chmod`: partially built/reallocated ACLs and file security objects; `du`:
  partial FTS traversals and hard-link accounting tables.
- `cut`, `comm`, `paste`, `join`, `split`, `sha256sum`: growing line/field/list
  buffers, regexes, and opened input/output streams. `cmp` also owns mappings
  and duplicated stdio descriptors. `xxd` and `base64` own opened files.
- Shared support: restoring/freeing thread locales on early exits. Define how
  pending cancellation and interrupted Darwin stdio reads map to command status
  before adding cancellation regressions.

Keep cleanup explicit in the owning command when addressing these paths; do not
reintroduce automatic interception of malloc, fopen, or other resource APIs.

## Validation

Run the command suite and existing shell regression suite:

```sh
bazel test //Vendors/ios_system:NativeCommandTests //Vendors/ios_system:OSHIntegrationTests --test_output=errors
```

The command suite invokes every new command through `ios_system`, checking
stdout, status, and filesystem results. It covers invalid input, Unicode, long
lines, checksum vectors and filenames, binary round trips, repeated invocations,
descriptor ownership, locale selection, and unchanged signal handlers. Eight
concurrent sessions each execute 108 thread-safe commands using identical relative filenames
with distinct contents. These exercise every thread-safe entry, differing
options/statuses, recursive diff, Unicode delimiters, relative output creation,
legacy getopt preservation, and unchanged process locale. jq adds CLI, regex, module, numeric, stream-ownership,
exit-status and concurrent relative-path checks, plus seven upstream suites. Direct registry-entry
checks also overlap commands. Shell tests exercise text and binary pipelines
and failure propagation with `pipefail`. A host-side diff suite compares fixed
BSD output fixtures and applies randomized unified/context patches to verify
that they reconstruct the expected files, including missing final newlines.

AddressSanitizer:

```sh
bazel test //Vendors/ios_system:NativeCommandTests //Vendors/ios_system:OSHIntegrationTests --config=asan --test_env=ASAN_OPTIONS=detect_leaks=0 --test_output=errors
```

The same command suite runs at launch in the simulator validation app:

```sh
bazel build //Vendors/ios_system:ios_system_validation_app --ios_multi_cpus=sim_arm64
```

Install and launch the app with `simctl`; its Documents directory contains
`native-command-results.json`. The macOS runner writes the same report in its
temporary fixture directory. Build macOS and iOS validation targets separately.

Shipping integration:

```sh
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Info-ZIP entries are thread-safe: `-TT` is unsupported and UnZip preserves
kernel-masked creation permissions without changing umask. Validation adds
embedded lifetime/stream checks and concurrent zip/unzip sessions, plus
`validate-infozip.py` interoperability and pipeline checks. The separate
`//Vendors/InfoZip:PortableExtractionTests` target exercises containment on the
older-OS filesystem path.

## ssh-keygen and project SSH paths

`ssh-keygen` is built from `ssh-keygen.c` and `sshsig.c` in the OpenSSH revision
pinned in `WORKSPACE.darwin`. It shares `libssh`, the prefixed SwiftCrypto
BoringSSL, and the compatibility patch in `Vendors/OpenSSH/ios.patch` with
`ssh`, `scp`, and `sftp`. No additional crypto runtime is bundled.

Local Code passes `<project>/.localc` to `ios_setSystemPaths` as the documents
path. This sets `SSH_HOME=<project>/.localc` and creates its `.ssh` directory
with mode 0700. `HOME` remains the workspace. Both OpenSSH command entry points
use `SSH_HOME` for the user home, giving this layout:

- Configuration: `<project>/.localc/.ssh/config`
- Default Ed25519 key pair: `<project>/.localc/.ssh/id_ed25519` and `id_ed25519.pub`
- Host trust: `<project>/.localc/.ssh/known_hosts`

Embedded SSH defaults to `StrictHostKeyChecking=accept-new`: first connections
automatically save the host key, and later connections reject changed keys.
This also applies to the embedded SSH used by `scp` and `sftp`. Explicit
`StrictHostKeyChecking` options in SSH configuration or on the command line
override this default.

`ssh-keygen -t ed25519` prompts with that default destination. For an explicit
noninteractive destination, use
`ssh-keygen -t ed25519 -f "$SSH_HOME/.ssh/id_ed25519" -N ''`.
`-N ''` creates an unencrypted private key; omit it for the passphrase prompt.
A custom key can be selected by `IdentityFile ~/.ssh/custom` in the project's
SSH config. OpenSSH's internal `~` expansion uses `SSH_HOME`; shell expansion
of an unquoted `~` uses the shell's `HOME`. `ssh-keygen` does not read host
`IdentityFile` settings to choose its output filename; use `-f` for custom keys.

The command uses `IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH`, resets its options
at entry, and installs pthread cleanup for generated keys, passphrases, copied
passwd, and option state, including on `ios_exit`/fatal errors. Known-hosts updates
rely on `mkstemp` permissions without leaving the process umask changed. FIDO enrollment
and resident-key download return an unsupported error because the app does not
bundle a security-key provider or `ssh-sk-helper`; PKCS#11 remains disabled in
the existing OpenSSH configuration.

Validation:

```sh
bazel run //Vendors/ios_system:openssh_validation -- --validate-ssh-keygen
bazel run //Vendors/ios_system:openssh_validation -- --validate-sshpass
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

The keygen checks use disposable projects and loopback-only connections to
verify that embedded `ssh` loads generated default keys and custom identities
from each project's config. They also cover file permissions, encrypted RSA
keys, public-key extraction, fingerprints, passphrase changes, overwrite
refusal, known-hosts lookup/removal, certificate option isolation, SSH signatures,
and repeated invocations across projects.
