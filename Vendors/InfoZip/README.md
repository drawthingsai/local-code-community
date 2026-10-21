# Embedded Info-ZIP

Local Code builds Zip 3.0 and UnZip 6.0 from Apple's zip-33 source release,
commit `c8d52ed44169a71e362af3814988685aa39ee7b4`, against the Apple SDK's system
zlib (`libz`). The upstream CLI parsers and archive operations are retained.
`sources.json` records imported paths, original hashes, and modified files.
The original licenses are in `zip/LICENSE` and `unzip/LICENSE`; both are also
included in the app's native-command notices.

## Execution and ownership

`zip_main` and `unzip_main` are ordinary registry entries. `symbols.h` gives
each upstream implementation a private link namespace: Zip and UnZip export
many of the same C names and also overlap other embedded commands.

Mutable globals and function statics use TLS. UnZip additionally uses its
existing `REENTRANT` context. Each invocation runs on a fresh ios_system pthread.
`ios_system_support` owns thread locale selection and resolves relative paths
against the session directory; the imported sources call path helpers explicitly.
Time formatting and multibyte conversion use separate thread state. Traditional
ZIP encryption header randomness uses `arc4random_uniform`.

Both public entries use `IOS_COMMAND_ISOLATION_THREAD_SAFE`. Mutable archive state
is isolated per invocation. Concurrent writes to the same archive or extraction
paths are not coordinated by the engine.

UnZip never reads or changes the process umask. For entries without stored Unix
permissions, it requests the synthesized mode at file creation and retains the
kernel's resulting permissions for the final chmod. For directories it captures
the mode from creation before adding temporary owner access, and restores that
captured mode after extraction. Entries with stored Unix permissions retain
explicit restoration; their files are initially created with mode 0600.

Normal cleanup is explicit. Zip owns duplicated stdin/stdout descriptors, its
stdio buffer, copied arguments/environment options, entry lists, sort indexes,
compression state, and option strings. UnZip releases its existing context and
its environment argument storage. Password prompts and archive comments use command input, and EOF
terminates the prompt. Terminal checks inspect command streams, not host descriptors. No allocator or file-resource tracker is introduced.
Fatal error/allocation exits and pthread cancellation recovery remain follow-up
work, consistent with the other native command ports. In particular, they can
strand partially built archive state, open files, temporary archives, password
buffers, and thread locales; this change does not claim comprehensive recovery.

`zip -T` invokes embedded `unzip` through the argv-based ios_system API.
`-TT` / `--unzip-command` is explicitly rejected: arbitrary verifier dispatch is
not supported. Keeping the parser entry prevents `-TT` from being interpreted as
two `-T` flags; it does not dispatch another command. `-T` always uses embedded
UnZip with separate argv arguments.
Time conversion uses the process timezone, as in the existing jq integration;
a session-only TZ assignment does not create a separate timezone.

## Extraction and format support

Apple's descriptor-relative extraction and containment checks are retained.
On macOS/iOS 26 and later, the kernel's `RESOLVE_BENEATH` flags are used. Older
supported releases use a directory-descriptor walk with `O_NOFOLLOW`; on those
releases extraction refuses directory symlinks, including links whose targets
are inside the destination. It never drops containment flags as a fallback.
Private macOS quarantine APIs are omitted; this port does not propagate quarantine
metadata. Permission and timestamp behavior otherwise follows the imported CLI.

Stored/Deflate ZIP entries, ZIP64, traditional password encryption/decryption,
Unicode paths, selection patterns, update/freshen/delete, listing, checking,
stdout output, comments, and compression levels use the existing implementation.
UnZip also retains its legacy Shrink/Implode readers. Upstream `USE_ZLIB` disables
Deflate64 because standard zlib does not implement it. ZIP64 is separate and
remains enabled. AES encryption, bzip2 entries, and newer ZIPX methods are not
enabled by this build. Unsupported methods report upstream errors.

## Targeted upstream fixes

- Zip's zlib path passed the archive filename to `fseekable`, which takes a
  `FILE *`. It now passes the archive output stream.
- Forced ZIP64 output could write a sentinel without the ZIP64 end records.
  The end-record condition now includes the force flag. This failure reproduced
  with Apple's installed zip as well as the source build.
- Apple's extraction-directory helper now receives UnZip's reentrant context.
- Apple's successful `close_outfile` path now returns `PK_OK` explicitly.
- Environment option unescaping uses `memmove` for overlapping strings.

## Validation

```
bazel test //Vendors/ios_system:NativeCommandTests //Vendors/ios_system:OSHIntegrationTests //Vendors/InfoZip:PortableExtractionTests --test_output=errors
bazel test //Vendors/ios_system:NativeCommandTests //Vendors/ios_system:OSHIntegrationTests //Vendors/InfoZip:PortableExtractionTests --config=asan --test_env=ASAN_OPTIONS=detect_leaks=0 --test_output=errors
bazel build //Vendors/ios_system:ios_system_validation_app --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Native tests exercise repeated invocations, stream/descriptor ownership, locale
and signal preservation, nested archive verification, environment options, and
eight concurrent zip/unzip sessions with different content, levels, passwords,
and nested `-T` verification.
The same native suite runs in the simulator validation app. `validate-infozip.py`
adds system-tool/Python cross-reading, all compression levels, Unicode and binary
fixtures, password interoperability, ZIP64, updates/deletion, filters, overwrite
policies, malformed archives, containment, virtual paths, shell pipelines,
synthesized/stored permissions under different umasks, and `-TT` rejection.
`PortableExtractionTests` forces the older-OS fallback even on a newer host.
