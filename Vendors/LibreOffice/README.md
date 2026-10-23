# Native Office command

LibreOfficeKit conversion, spreadsheet recalculation, and PNG rendering for `ios_system`. The
runtime is native C++, uses **SVP only**, and keeps **all bundled dependencies
private**, including Cairo, Pixman, FreeType and fontconfig. It does not share the
Cairo packaged by PythonIOS. Node is used only by build tools and the upstream comparison test.

`OfficeCommandRun` is the only exported definition in `libOffice.a`. The packaging
step partially links the engine and dependencies into one object, localizes every
other definition, and checks the resulting archive against `exported_symbols.txt`.
The Aqua plugin, macOS system spellchecker, and upstream worker/main are excluded.
The spellchecker calls `NSApplicationLoad` even under SVP, so excluding it also
removes an independent path into AppKit initialization. A patch makes the static
VCL fallback select SVP too. The standalone CLI and memory probe are separate
hosts linking this exact archive.

## Build

Platforms: **macOS arm64, minimum macOS 13.5**, and **iOS arm64 device, minimum
iOS 15.4**. macOS has conversion/runtime validation. The iOS source build and
final executable link and signed Local Code app build pass; device runtime and
simulator validation are pending.

Like PythonIOS and NodeMobile, the committed `Frameworks/Office.xcframework`
contains only static archives, imported by `apple_static_xcframework_import`.
`Resources/office/` (iOS) and `ResourcesMacOS/office/` contain only runtime data.
`Notices/LibreOffice/` contains bundled license and source-location notices.
`Receipts/` records each archive’s compiled-source hashes and resource size;
receipts and build recipes are not app resources. `LIBREOFFICE_BUILD_INFO` records
provenance; `SHA256SUMS` covers recipes and both payloads. Lean follows the same private-symbol policy but builds its
archive in Bazel rather than checking in a prebuilt XCFramework. Static archives and binary runtime resources use Git LFS;
recipes, patches, receipts, and text resources use ordinary Git. From a fresh
checkout at the repository root:

```sh
git lfs install --local
git lfs pull
Vendors/LibreOffice/verify_libreoffice.sh
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:LocalCodeCLI
```

Mac Catalyst arm64 uses a Bazel-generated object from the iOS archive, following
the PythonIOS Catalyst import pattern. `replatform_office_for_catalyst.sh` uses
the shared Mach-O rewriter to change the platform load command while preserving
private symbols and compact unwind. Catalyst selects the iOS SDK dependencies
and `Resources/office/` layout, including `office/program/`. Its generated
`fundamentalrc` uses direct `lounorc` lookups to avoid recursive aliases when
the iOS engine loads it as the base bootstrap configuration.

To rebuild both payloads from source, use an Apple Silicon Mac and run the
following from the repository root. The macOS step prepares the pinned kit,
LibreOffice checkout, and verified download cache used by the iOS step; there
is no dependency on the earlier `Apps/LocalCode/OfficeShell` experiment.

```sh
brew install node python@3.14 make pkgconf autoconf automake libtool gperf bison flex ninja nasm
export PATH="/opt/homebrew/opt/python@3.14/libexec/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:$PATH"
export OFFICE_BUILD_JOBS=12

# Only needed when the selected Xcode no longer includes ld-classic:
export OFFICE_LD_CLASSIC='/Applications/Xcode 26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld-classic'

Vendors/LibreOffice/build_libreoffice.sh
```

The validated toolchain was Xcode 27.0 (27A266a), Apple Clang 21.0.0
(clang-2100.3.34.2), and Apple SDK 27.0, with `ld-classic` from Xcode 26.6.
Select the desired Xcode with `DEVELOPER_DIR` or `xcode-select` before building.
Adjust the linker path to an installed Xcode that supplies it. The top-level recipe builds both slices, encapsulates them, then calls
`package_vendor.py` and `verify_libreoffice.py`. Review `LIBREOFFICE_BUILD_INFO`,
`SHA256SUMS`, and the per-platform `Receipts/*.json` files
together with the rebuilt payloads. These are
pinned-source rebuild instructions, not a promise of byte-identical output
across different toolchains or absolute build paths.

`build_libreoffice.sh --kit PATH` can reuse or create a different kit directory.
The lower-level `build.sh`, `build-ios.py`, and encapsulation scripts remain
available for rebuilding individual stages. For a clean rebuild after changing
engine patches or configuration, move the ignored `.build/` directory aside
(and any custom kit directory), then rerun the commands. Do not move a build
directory you intend to resume: upstream records absolute paths. Download and
build workspaces can be large; `.build/` is never committed.

`ios.conf` and `Patches/ios-svp.patch` enable the FreeType/fontconfig SVP path
that upstream's iOS configuration bypasses. The patch also selects iOS Expat
entropy support, fixes cross-compilation probes and OpenSSL's iOS target, and
keeps Quartz rendering out of the headless path. The separate iOS source/build
directories live under `.build/`; the verified macOS configuration is untouched.
The iOS packaging script checks every input archive's platform, preserves compact
unwind, checks the single exported entry point, and performs a final device link.

Requirements: Xcode, Node 22+, Python 3.11+, GNU make, pkgconf, autoconf, automake,
libtool, gperf, bison, flex, ninja and nasm. `OFFICE_BUILD_JOBS` defaults to 12.
The encapsulation step requires Apple's `ld-classic`; if the active Xcode no
longer supplies it, set `OFFICE_LD_CLASSIC` to that tool from an installed Xcode.

The build pins dsh-libreoffice-kit at
`b19bb73c74ed893b8a5d1716d32df32a113ed31b` and LibreOffice core at
`bce0998afefdbc355585ca324285661a2170ba77`. Patches live in `Patches/`.
`--kit PATH` can reuse an existing checkout at that pin (configured engine paths
are absolute, so do not move its build directory). New builds live in `.build/`.

The final host linker must preserve compact unwind tables. Do not use
`-Wl,-no_compact_unwind`: Apple Clang emits compact-only exception metadata for
many of these arm64 objects, so discarding it makes ordinary caught exceptions
terminate the process. This was reproduced by the full-host missing-file test;
check local Bazel overrides as well as the tracked configuration.

Intermediate payloads under `Artifacts/` and build caches under `.build/` are
ignored. The macOS packager also generates `Artifacts/macos-arm64/bin/office` and
`bin/office-probe` and `bin/office-session`. These standalone diagnostics are ignored and are not needed
to build the app or Local Code CLI; their source and rebuild steps are committed.
If only the wrapper or packaging code changed and the pinned engine is already
built, rerun `python3 Vendors/LibreOffice/encapsulate.py --kit PATH_TO_KIT
--output Vendors/LibreOffice/Artifacts/macos-arm64` and
`python3 Vendors/LibreOffice/encapsulate-ios.py` instead of compiling the engine.
Then run `python3 Vendors/LibreOffice/package_vendor.py` to publish and verify
the updated XCFramework, resources, provenance, and checksums.
The packagers enforce the single exported definition, and the iOS packager
also checks archive platform and final executable linkage. `SHA256SUMS` covers
the committed recipes, patches, tests, metadata, headers, archives, and resources.
It excludes ignored build outputs and itself. Run
`bazel test //Vendors/LibreOffice:LibreOfficeVendorTests` to verify it together
with static archive platforms, exported symbols, headers, and compact unwind.

```sh
Vendors/LibreOffice/Artifacts/macos-arm64/bin/office convert \
  --input document.docx --output document.pdf
Vendors/LibreOffice/Artifacts/macos-arm64/bin/office recalculate \
  --input workbook.xlsx --output calculated.xlsx
bazel build //Vendors/ios_system
```

`ios_system` includes the **direct static dependency and command-table entry**
without a feature flag. Available archives support macOS arm64 and iOS arm64
devices. It does not call `ios_registerCommand`. `office` uses
`EXCLUSIVE_LIBREOFFICE`; Local Code schedules it on its own exclusive queue.
On iOS the native commands link directly into the app executable. Office resources
are packaged under the app's `office/` directory; the adapter resolves
them through `/app_bundle`. The `ios_system` dependency and command registry
include `office` unconditionally, matching the other native commands. Device
arm64 and macOS arm64 select their SDK dependencies and resources explicitly.
The iOS Simulator has no archive slice: there `:command` links
`ios_system_office_simulator.m`, a stub that reports the command as unavailable,
and packages no Office resources. Other platforms require an additional archive
slice and matching SDK/resource configuration before they can build.
The unbundled Local Code CLI resolves its macOS resource path at host startup
and passes it through `ios_setOfficeProgramPath`. The adapter contains no Bazel
runfiles discovery; bundled apps use `/app_bundle/office/` directly. Help, version
and capability discovery work without a session, resources or engine initialization.

## Ownership and limits

The synchronous C API queues requests onto one persistent background pthread,
with a 16 MiB stack. Initialization and every document operation run on that
thread, regardless of the caller. A serial mutex alone is insufficient: SVP can
wait for its initializing thread during `Application::Reschedule`. The engine,
profile and host configuration remain process-owned. Commands share a private font catalog. File/directory fingerprints invalidate it
when font sources change. Only catalog changes refresh LibreOffice's
font manager and FreeType/VCL caches under the Solar mutex; changes to mappings
replace the substitution table without rebuilding the catalog. Resolved
missing-family mappings also replace VCL's direct substitution table; fontconfig
aliases alone can lose to VCL's built-in metric matching. The
`headless-font-refresh.patch` supplies this private hook; ordinary `addfont` does
not remove earlier font selections. The catalog and active configuration are
reused within the process, with a stable host cache directory; the first request
in a new process still indexes its font sources. This does not change the host’s
`FONTCONFIG_FILE`. Documents and per-command
scratch are released after each operation. Runtime resource and temporary roots,
and the host font list, cannot change after initialization.

The adapter captures session output, working directory and cancellation context
before enqueueing. It uses a process-owned temporary directory for the engine
profile, because a session's `/tmp` can disappear before the engine. Runtime
profiles have advisory file-lock leases. A later process reaps stale profiles,
including after crashes, while leaving another live host's profile alone. The
font cache lives separately under the host cache directory and survives launches. The bridge
never changes cwd, redirects process descriptors or exits the process. Cooperative
cancellation removes a queued request and returns 130 within a 50 ms polling
interval (plus scheduling and callback time), even if the owner is blocked. The
queue removal and owner claim are synchronized, so the caller can immediately
release its arguments, streams and context. Cancellation callbacks must return
promptly; they run on the caller while queued and on the owner after admission,
with no overlap for one invocation. Once running, cancellation returns 130 at
document-operation boundaries; a synchronous engine call cannot be interrupted
safely. `ios_system` excludes Office from pthread
cancellation and global getopt resets.

## Command contract

The pinned dsoffice behavior forms the contract for the conversion matrix, PDF
filter options, UTF-8/LF text output, exact CSV worksheet selection, formula
recalculation, and native page/tile rendering. `office capabilities --json`
describes the native command; `office --help`, `-h`, `help`, subcommand help and
`--version` need no runtime installation. The canonical raster command is
`office render` (dsoffice's public `render` / internal `render-images` operation).

| Input | Conversion outputs |
| --- | --- |
| doc, docx, odt | pdf, docx, odt, txt |
| xls, xlsx, ods | pdf, xlsx, ods, csv |
| ppt, pptx, odp | pdf, pptx, odp |

`recalculate` accepts xls/xlsx/ods and writes xlsx/ods with formulas preserved.
CSV requires `--sheet` with an exact worksheet name for multi-sheet workbooks.
`render` accepts the nine Office formats plus PDF, writing a new PNG directory:

```sh
office render --input report.docx --output-dir pages --pages 2,1 --dpi 144
office render --input workbook.xlsx --output-dir cells --sheet Summary --range A1:D20
office render --input report.pdf --output-dir pdf-pages
```

Office documents use LibreOfficeKit tiles; PDFs use the pinned engine's PDFium.
Writer uses physical page rectangles, Impress uses slides, and Calc uses worksheet
geometry including hidden/filtered rows and columns. Calc defaults to visible
sheets and their data areas, splitting large ranges into bounded tiles.
`--pages all|1,3` is one-based, preserves requested order, and rejects repeats;
Calc uses `--sheet`/`--range` instead. Ranges use A1 notation and require a sheet.
Results include page/sheet metadata, CSS-pixel rectangles, raster dimensions,
byte lengths, the SHA-256 of the copied input, and caller-visible image paths.

Our explicit choices are strict `--name value` pairs with no repeated options
except repeatable `--font-directory`, a 600 DPI cap, and exit codes 0 (success,
help/discovery), 1 (failure), and 130 (cancellation). Results are one JSON line on
stdout; failures are `{ok:false,code,error}` on stderr, preserving engine error
codes. Invalid C ABI usage returns 2. Native engine logging still uses process
diagnostics. Virtual input/output paths are preserved in result metadata.

| Limit | Default | Behavior |
| --- | --- | --- |
| `--max-input-bytes` | 67108864 | Configurable; checked during bounded input copy |
| `--max-output-bytes` | 134217728 | Conversion file or total encoded PNG bytes |
| `--max-archive-entries` | 20000 | ZIP entry count |
| `--max-uncompressed-bytes` | 536870912 | Total declared ZIP bytes; actual bytes decoded from selected metadata |
| `--max-image-resolution` | 144 | PDF export images, maximum 600 DPI |
| `--dpi` | 144 | Render resolution, 24–600 DPI |
| `--max-pages` | 100 | Output PNG count, including Calc tiles; maximum 10000 |
| `--max-pixels` | 16777216 | Per PNG; maximum 16777216 |
| `--max-dimension` | 8192 | PNG width/height; maximum 16777216 |

All limits are positive integers; overflow gets an explicit diagnostic. OLE
inputs require consistent version, byte order, sector size and file alignment.
ZIP32/ZIP64 inspection follows the pinned dsh policy: count all entries and
declared expanded sizes, reject duplicate names, and check required parts and
document content type. Only selected XML/metadata is decoded. CRCs, local/central
header disagreements, data descriptors, overlaps and trailing bytes are not
additional integrity checks. Native reads remain bounds/overflow checked, and
actual streamed metadata bytes share an independent cap equal to
`--max-uncompressed-bytes`, even when an entry understates its size. Macros are
disabled. LibreOffice may still reject a document during import after it passes
this preflight. Office ZIP and PDF outputs have signature checks.
Existing destinations are never replaced: conversions publish with an exclusive
hard link, and image batches publish with an exclusive same-volume directory
rename only after every PNG succeeds. These limits do not bound the engine's
peak memory while importing or exporting a document.

### Fonts

`--font-directory PATH` is repeatable and replaces default system discovery for
that command. `--font-fallbacks JSON` replaces the default ordered groups,
for example `'[["Calibri","Carlito"],["Cambria","Caladea"]]'`. The default groups
include the pinned dsh table's Latin, CJK, generic and symbol alternatives.
Selection follows the pinned dsh `fonts.ts`/`font-loader.ts` native path:

- Inspect declared families and Unicode scalars in OOXML/ODF XML. Ignore theme
  and font-table catalogs, theme placeholders, and malformed XML parts.
- Prefer the requested family, then flatten all groups containing that family
  in table order, then symbol/generic alternatives; deduplicate normalized names.
  Membership is not limited to the first name in a group. Families match using
  Unicode NFKC, case and separator normalization, including localized aliases.
- Keep every catalogued font available to the engine for all Office formats.
  Theme fonts and fonts inside embedded objects need no inspector-visible
  declaration or preload hint. Custom font directories still replace default
  system discovery.
- Choose missing-family substitutes in family priority and
  regular/upright/normal-width style order, considering glyph coverage.
  Compute the best covering face for each alias once per document instead of
  sorting the catalog for every requested family. VCL handles remaining glyph
  fallback using the complete catalog. Fontconfig supplies native metadata and
  cmap coverage; no Node or fontkit runtime is needed.
- Map missing declared families to the chosen family in VCL, including
  dsh's metric aliases and LibreOffice's own localized search-name normalization.
  Installed originals remain preferred. Generic engine defaults do not produce
  diagnostics unless the document explicitly declares that missing family.

Default macOS discovery includes `/System/Library/Fonts`, `/Library/Fonts`,
`~/Library/Fonts`, downloaded fonts under
`/System/Library/AssetsV2/com_apple_MobileAsset_Font*`, and bundled fonts. On iOS,
CoreText's available font URLs supplement readable directories; this path builds
and links but still needs physical-device font/runtime validation. Custom search
roots replace this default discovery. Search is bounded to 100000 entries and
20000 files; files larger than 256 MiB are skipped. Font files are registered by
path rather than copied into a per-document import heap. The complete catalog
remains active until its sources change; changing documents updates only the
substitution table.

`office --help` and `office capabilities` describe the font visibility and limits.
Metadata collection samples at most 4096 families and 65536 distinct Unicode
code points; family names over 1024 UTF-8 bytes are skipped. Reaching a sampling
limit never rejects the document. Collection stops for that category while the
engine continues to receive the complete document and font catalog. Results set
`fontMetadataTruncated: true` if collection was limited or a name was skipped;
`missingFonts` and explicit substitutions then describe only the retained sample.
The flag is false when these limits did not constrain collection; it does not
make diagnostics for ignored themes or malformed XML parts complete.

Custom fallback options still validate names (at most 1024 UTF-8 bytes each) and
allow at most 4096 names. Cancellation is polled while indexing files/faces and
resolving glyph coverage and families. These are native sampling/work limits:
upstream's `maxFontResolutionEntries = 4096` bounds its LRU cache, not per-document
work. Input size, ZIP entry/expansion limits and output limits remain enforced.

`missingFonts` lists sampled declared OOXML/ODF families absent from the catalog,
in declaration order. Every successful conversion/recalculation/render result
also includes `fontMetadataTruncated`. This follows upstream's document-based
diagnostics and is not a glyph-coverage promise. Legacy binary documents and PDF
return an empty list and `fontMetadataTruncated: false`. PDF rendering uses
embedded fonts and PDFium's own fallbacks; Office font flags do not configure
PDFium. A family explicitly declared as Liberation Sans can still be reported;
unrequested engine defaults no longer add it to every result.

The standalone host also documents `--program-directory PATH` and repeatable
`--font-file FILE`; embedded host resources/font files belong to the C context.
Per-command options do not change the host configuration. An A → B → A test
checks both directory changes and fallback changes against the fonts actually
embedded in PDFs by the same persistent engine.

## Validation and remaining production work

After rebuilding the macOS standalone hosts, generate fixtures and verify the
conversion, font, and persistent-runtime behavior:

```sh
python3 -m venv Vendors/LibreOffice/.build/test-venv
Vendors/LibreOffice/.build/test-venv/bin/pip install python-docx python-pptx openpyxl pypdf Pillow
brew install poppler
Vendors/LibreOffice/.build/test-venv/bin/python Vendors/LibreOffice/Tests/verify_runtime.py \
  --office Vendors/LibreOffice/Artifacts/macos-arm64/bin/office \
  --output Vendors/LibreOffice/.build/runtime-verification
Vendors/LibreOffice/.build/test-venv/bin/python Vendors/LibreOffice/Tests/verify_command.py \
  --office Vendors/LibreOffice/Artifacts/macos-arm64/bin/office \
  --fixtures Vendors/LibreOffice/.build/runtime-verification/conversions \
  --output Vendors/LibreOffice/.build/command-verification
Vendors/LibreOffice/.build/test-venv/bin/python Vendors/LibreOffice/Tests/verify_fonts.py \
  --office Vendors/LibreOffice/Artifacts/macos-arm64/bin/office \
  --output Vendors/LibreOffice/.build/font-verification
bazel test //Vendors/LibreOffice:OfficeCommandTests //Vendors/LibreOffice:DocumentFontTests
bazel test //Apps/LocalCode:CLIParityTests \
  --test_filter=CLIParityTests.testOfficeResourcesThroughTheActualBashTool
```

Choose a new output directory for each `verify_runtime.py` run. That suite needs
the system Arial font at `/System/Library/Fonts/Supplemental/Arial.ttf` for its
explicit-font check. The CLI parity test works directly from committed artifacts
and verifies Python DOCX creation followed by Office PDF/ODT conversion and PNG rendering.

`Tests/verify.py` checks Writer/Calc/Impress conversions, PDF contents/page counts,
formula recalculation, CSV sheet selection and failures.
`Tests/verify_runtime.py` runs the conversion suite, verifies explicit font
registration, and runs the owner/thread/concurrent/queued probes.
`Tests/verify_command.py` covers native PNG/PDFium rendering, page order, worksheet
geometry/tiling, malformed containers, configurable limits, errors/help, font
configuration transitions, declared-family diagnostics and stale-profile cleanup.
`Tests/verify_fonts.py` checks Latin and CJK PDF spans for YaHei/PingFang/SimSun,
localized names, installed originals and Word/PowerPoint theme fonts, metadata
sampling saturation (including 70000-character DOCX round trips), group-member
ordering, font-file replacement,
new descendants, and warm catalog/configuration reuse. Run it with the same
`--office` and a fresh `--output` directory; it requires installed PingFang/Songti
and Poppler. It reports measured warm conversion and font-setup time.
`//Vendors/LibreOffice:DocumentFontTests` covers streamed UTF-8/UTF-16 metadata,
malformed XML, DTD handling, 72 generated OOXML containers, ODF, and 192 seeded
ZIP mutations. `Tests/verify_zip_parity.py` compares the native inspector with
unmodified sources from the pinned upstream revision using fflate 0.8.2. It covers
that project's OOXML family/script matrix, ZIP32/ZIP64, metadata selection,
permissive integrity behavior, decoded duplicate names, limits and seeded
mutations. Native bounds checks and the actual metadata byte cap are recorded as
intentional differences; the test does not claim compatibility with every damaged
archive. Its Node dependencies are test-only:

```sh
npm install --prefix Vendors/LibreOffice/.build/zip-parity \
  --ignore-scripts --no-audit --no-fund fflate@0.8.2 saxes@6.0.0 fontkit@2.0.4
bazel build //Vendors/LibreOffice:DocumentFontTests
python3 Vendors/LibreOffice/Tests/verify_zip_parity.py \
  --kit Vendors/LibreOffice/.build/kit \
  --dependencies Vendors/LibreOffice/.build/zip-parity \
  --inspector bazel-bin/Vendors/LibreOffice/DocumentFontTests \
  --output Vendors/LibreOffice/.build/zip-verification
```

Use Node 22.19+ and the kit directory used for the source build; choose a fresh
output directory each run. The test verifies the upstream Git revision and
reference dependency versions and records source hashes with its results.

`Tests/probe.py` checks
repeated calls, competing callers, cancellation boundaries, recovery and memory
using `bin/office-probe` and `bin/office-session`. Reports are generated in the ignored output directory;
old experiment reports are not part of the vendored library.

The macOS archive is verified through conversions, exception/cancellation tests,
and signed app-bundle execution. The iOS archive is verified through a final
executable link and signed Local Code and StaticInlinePython app builds. No
physical iPhone or iPad was reachable for device runtime or memory validation.
The runtime pruning policy is exercised on macOS; iOS runtime validation remains
required before release. Archive and resource byte counts are recorded in
`Receipts/*.json`; these are not an incremental app-size measurement.

The runtime trees omit unused UI layouts, gallery, Basic, wizards, tip-of-the-day,
autocorrect/autotext/templates, splash artwork, credits documents, shell helpers,
and duplicated licenses. The six UI layouts from the pinned dsh headless allowlist, plus the mirrored
tab-button layout required by RTL worksheets,
and adjacent XML configuration remain: SVP still creates document-view controls,
and deleting all UI configuration breaks document loading. The trees also retain
conversion registry, filters, fonts, language tables, palettes, Calc data,
bootstrap files and type/service registries.
The macOS tree has ordinary `office/Frameworks` and `office/Resources` directories;
it contains no nested `.app`, `Info.plist`, or `PkgInfo`. A small
`static-runtime.txt` preserves the otherwise-empty engine installation anchor.

Recipes, patches, tests and receipts exist once at the vendor root. Bazel bundles
only the selected runtime tree and the dedicated `notices` resource group, so
build scripts and generic `sources/`, `licenses/`, or `program/` directories no
longer appear at the bundle root. C++ sources use `.cpp`/`.hpp`; the shell verifier
entry point invokes Python for structured checksum, plist and archive inspection.

Remaining release work includes iOS runtime and device memory testing,
adding an Office simulator slice, font-fallback fidelity on real documents, engine logging and process-global
bootstrap/signal-state auditing. Symbol hiding prevents link collisions; it does
not isolate libc environment variables, signal handlers or a fatal engine crash.
The current macOS closure still links public desktop frameworks. Native engine
logs go to process diagnostics rather than the requesting session's stderr.

To check the statically integrated command after generating fixtures:

```sh
bazel build //Vendors/LibreOffice:ios_system_validation
bazel-bin/Vendors/LibreOffice/ios_system_validation \
  "$PWD/Vendors/LibreOffice/ResourcesMacOS" \
  "$PWD/Vendors/LibreOffice/.build/final-conversions"
```

The test links the full `ios_system` host (including Python, Node and FFmpeg),
checks the static command category, and exercises OSH path aliases, output
redirection, repeated conversions and recovery after a bad input.

`//Vendors/LibreOffice:bundle_validation` builds the same test as a signed macOS
app, carrying resources transitively through `ios_system`. After extracting its
zip, run `OfficeValidation.app/Contents/MacOS/OfficeValidation` with only the
fixture-directory argument to verify conversion against bundled resources.

The C ABI catches both standard and unknown C++ exceptions, including exceptions
from host callbacks, and returns JSON with status 1. `OfficeCommandTests` verifies
owner-thread exceptions, queued cancellation behind a blocked owner, exceptions
from the waiting caller's cancellation callback, context lifetime, active
cooperative cancellation, and recovery on the persistent owner thread.

There is no hard timeout for an active in-process LibreOffice call. Returning
from an active call would release borrowed host state while the engine still
uses it, and forcibly stopping that thread could corrupt the process. A stuck
load/save can still block later conversions; queued callers can cancel and
return, but restarting the engine safely requires process isolation (or an app
restart). The upstream helper's 120-second SIGKILL policy does not transfer to
this static in-process integration.
