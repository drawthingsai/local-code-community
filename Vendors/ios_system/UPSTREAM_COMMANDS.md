# Upstream command comparison

Compared the local static registry with holzschu/ios_system revision
[`7658fcf551935b42d6bb5bedc9315d8f53f760c4`](https://github.com/holzschu/ios_system/tree/7658fcf551935b42d6bb5bedc9315d8f53f760c4),
which also supplies our `df` port. This compares registered names, not flag or
behavior parity. Upstream's optional dictionary references separately packaged
runtimes; presence there does not imply we can enable a command just by adding
its name. App-registered commands and OSH builtins are outside this comparison.

## Missing from the default dictionary (24 names)

`bc`, `chflags`, `cksum`, `compress`, `dc`, `dig`, `ed`, `gunzip`, `gzip`, `host`, `ifconfig`, `md5`, `nc`, `nslookup`, `open`, `ping`, `rlogin`, `say`, `sum`, `tar`, `telnet`, `uncompress`, `whois`, `wol`.

The most useful follow-ups for general project work are `tar`, `gzip`/`gunzip`,
and `nc`; each needs a separate embedding and validation pass.
`ssh-keygen` now uses our existing OpenSSH build and project-local SSH home;
see [native command integration](NATIVE_COMMANDS.md#ssh-keygen-and-project-ssh-paths).
`openurl` already exists locally, but is not counted as upstream `open` parity.

## Missing optional commands, excluding names above (46 names)

`amstex`, `bibtex`, `chgrp`, `chown`, `clang`, `clang++`, `cslatex`, `csplain`, `ctags`, `dvilualatex`, `dviluatex`, `eplain`, `etex`, `jadetex`, `latex`, `lli`, `llvm-dis`, `llvm-link`, `lua`, `luac`, `lualatex`, `luatex`, `mex`, `mllatex`, `mltex`, `nm`, `opt`, `pdfcslatex`, `pdfcsplain`, `pdfetex`, `pdfjadetex`, `pdflatex`, `pdfmex`, `pdftex`, `pdfxmltex`, `pythonA`, `pythonB`, `pythonC`, `pythonD`, `pythonE`, `readtags`, `texlua`, `texluac`, `texsis`, `utf8mex`, `xmltex`.

This group includes ownership commands, tag tools, LLVM/Clang, Lua, TeX, and
upstream's alternate Python runtime names. Our canonical `python`, `python3`,
and `python3.14` commands do not require those alternate Python names.

## df integration

`df` was in the optional upstream dictionary and is now in our static registry.
It preserves the older port's `statfs` accounting. In particular, it does not
include current macOS df's APFS volume-used-space refinement, so the Used and
Capacity columns can differ from current macOS `/bin/df` on shared APFS volumes.

The port uses session-relative path resolution, invocation-local option and
formatting state, session `BLOCKSIZE` without environment mutation, and
`MNT_LOCAL` filtering instead of a sandbox-restricted VFS `sysctl` query.
Numeric unit headers explicitly report their byte count (for example,
`1048576-blocks`). Raw device operands retain upstream's unsupported error.

## App Store privacy requirements

Apple lists `statfs` and `fstatfs` under `NSPrivacyAccessedAPICategoryDiskSpace`.
These APIs are permitted for approved uses, but the required-reason policy
requires a matching privacy manifest for covered app/platform distributions.
Reason `85F4.1` covers displaying disk-space information to the user; it does
not allow sending that information or derived information over the Internet.
`E174.1` covers user-observable storage checks before writing or deleting files,
and also restricts sending the information off-device. A generic cloud-agent
tool response is not covered by either reason simply because the user requested
the command. Local display is the intended use of this port; distribution must
verify the manifest and the actual tool-output data flow.

The port does not add a privacy declaration on behalf of every consuming app.
Apple's current policy overview explicitly lists iOS, iPadOS, tvOS, visionOS,
and watchOS; it does not list native macOS. This is separate from runtime
sandbox permissions and does not explain the original missing registry entry.

The bundled iOS Python archive already imports `statfs`, `fstatfs`, and
`fstatvfs` (verified with `nm -u`), and its `shutil.disk_usage()` calls
`os.statvfs()`. Python therefore already exposes disk-space queries; moving a
query into Python does not avoid this API category or its usage restrictions.
Imported symbols establish capability, not that every script executes a query.

Sources checked September 9, 2026:
[required-reason policy](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
