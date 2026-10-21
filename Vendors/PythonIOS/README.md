# PythonIOS

This directory contains the generated base CPython payload used by `ios_system`.

Regenerate it with:

```sh
Vendors/PythonIOS/build_base_python.sh
```

This entry point automatically:

1. Installs the pinned Rust toolchain and runs `Tests/encapsulate_python_test.sh`
   before compiling native dependencies to check function/common-global isolation
   and Rust, C++, and Objective-C unwinding with the selected Xcode.
2. Calls `encapsulate_python.sh` while packaging each of the device, simulator,
   and macOS archives, enforcing `exported_symbols.txt` on every slice.
3. Writes `PYTHON_BUILD_INFO` and `SHA256SUMS`, including the packaging helper,
   export list, regression test, and generated archives.
4. Runs `verify_python_ios.sh` against the completed payload before reporting
   success. An export, required-symbol, archive-layout, or checksum failure
   terminates the build.

On toolchains such as Xcode 27 that no longer ship `ld-classic`, set
`PYTHON_LD_CLASSIC` to that executable in an installed older Xcode. The generator
still runs the dependency-isolation regression before compiling. Xcode 27 also
requires `IOS_MINIMUM_OS_VERSION=15.0` or newer for its C++ standard library;
the generated payload records this deployment target in `PYTHON_BUILD_INFO`.
Install the selected Xcode's Metal compiler with
`xcodebuild -downloadComponent MetalToolchain` if it is missing. MLX uses that
compiler, and `MLX_METAL_COMPILER_VERSION` records its version in the payload.
On macOS 27, Rust 1.89's debug stripping can produce unloadable build-time
proc-macro libraries. Set `CARGO_PROFILE_RELEASE_STRIP=none` when regenerating;
the final Python archives are still stripped during encapsulation. For Bazel
validation on that host, pass
`--@rules_rust//rust/settings:extra_exec_rustc_flag=-Cstrip=none` and, when needed,
`--action_env=FFMPEG_LD_CLASSIC=/path/to/ld-classic` for FFmpeg's packaging step
and `--define=LEAN_LD_CLASSIC=/path/to/ld-classic` for Lean's. Keep compact unwind
enabled: arm64 C++ objects can have compact-unwind records without DWARF frame
records, even with `-femit-dwarf-unwind=always`. Discarding compact unwind can
therefore make caught C++ exceptions terminate the process.

Keep `pkg-config` (such as Homebrew's `pkgconf`) off `PATH` when regenerating,
for example with a directory earlier on `PATH` whose `pkg-config` and `pkgconf`
exit 1. With it, the macOS CPython build links `_decimal` against the host's
libmpdec instead of the bundled copy, leaving `_mpd_*` undefined in
`libpython3.14-macos.a`; `verify_python_ios.sh` does not catch this.

Logs are saved under `BUILD_DIR`: `encapsulation_test.log`,
`encapsulate_iphoneos.log`, `encapsulate_iphonesimulator.log`,
`encapsulate_macosx.log`, and `verify_python_ios.log`. A failed step prints the
last 120 lines of its log. The default build directory is
`/private/tmp/python-3.14-ios-build`.

The script pins official CPython by tag and commit and builds the regular-GIL
Python payload:

- `Frameworks/Python.xcframework` (static `libpython3.14-ios.a`,
  `libpython3.14-ios-simulator.a`, and `libpython3.14-macos.a` slices)
  - `ios-arm64`
  - `ios-arm64-simulator`
  - `macos-arm64`
- `Resources/Library` for iOS device and simulator app bundles
- `ResourcesMacOS/Library` for macOS usage

The iOS build uses CPython's upstream Apple build support with
`MODULE_BUILDTYPE=static` so base stdlib extension modules are linked into
`libpython3.14.a`. The macOS build uses the same static-module policy. Bundled
iOS device and simulator third-party dependency archives are folded into their
respective Python static libraries; SDK libraries remain Bazel link
dependencies. The common iOS resource tree carries both device and simulator
sysconfig data, while pure-Python standard-library and package resources are
shared. The macOS build uses
pinned source tarballs for OpenSSL, XZ, and Zstandard so `ssl`, `hashlib`,
`lzma`, and `compression.zstd` are available without relying on Homebrew-built
archives. SDK libraries such as SQLite, zlib, bzip2, libffi, and ncurses remain
Bazel link dependencies. Final static archives are stripped of debug and local
symbols. `encapsulate_python.sh` links each complete slice into one relocatable
object before creating its final archive. This step uses Xcode's `ld-classic`
with `-d` to allocate common globals, then `nmedit` to localize dependency
definitions, including those globals. The reviewed `exported_symbols.txt`
retains the CPython C API, static extension initializers, package registrars,
and the three HFXet download entry points. `_rust_eh_personality` is also retained
as a weak public definition, using `rust-objcopy` from the pinned Rust compiler's
sysroot. This lets the host and Python share one Rust personality while retaining
a fallback when Python is linked alone. Localizing it would introduce a fourth
personality beside host Rust, C++, and Objective-C, exceeding compact unwind's
three-personality limit. All other definitions, including
OpenSSL, libxml2, compression, font libraries, and bundled Rust/C++ runtimes,
are resolved within that object and hidden from later consumers. Embedded Rust
bitcode metadata is stripped from the native output. SDK libraries and the
canonical SentencePiece dependency remain external.

The export list contains the union of the supported slices' interfaces; the
packager retains only symbols already public in its input slice and checks
that the output exports exactly that set. Review additions to this list when
updating CPython or adding an externally consumed entry point. Do not generate
it from all globals in the combined dependency archive. The verifier rejects
any final archive export outside the list and checks required runtime entry
points. This is dependency encapsulation cleanup, not a fix for the intermittent
CFNetwork request-destruction crash.

For a standalone packaging regression, set `RUSTC` to the pinned Rust compiler
and run `bash Vendors/PythonIOS/Tests/encapsulate_python_test.sh` (also setting
`PYTHON_LD_CLASSIC` when required). The test checks Rust panic recovery and Drop
cleanup within both Python's private runtime and the host runtime, C++ destructor
cleanup, and Objective-C exception handling. It links Python alone and alongside
host Rust in both archive orders, and requires three compact-unwind personalities.

NumPy, pandas, Pillow, lxml, contourpy, kiwisolver, matplotlib, psd-tools,
regex, hf-xet, safetensors, tokenizers, SentencePiece, and MLX are built from pinned source
tarballs in `build_base_python.sh`. The common packages, including regex,
hf-xet, safetensors, tokenizers, and SentencePiece, target `ios-arm64`,
`ios-arm64-simulator`, and `macos-arm64`; MLX targets `ios-arm64` and
`macos-arm64` only. NumPy uses Accelerate for
BLAS/LAPACK. Native extension objects are folded into their supported static
Python archive slices and registered as built-in modules at Python runtime
initialization. The committed resources carry the Python packages and metadata,
not `.so` extension modules. The macOS NumPy build targets
macOS 13.3 or newer because NumPy's Accelerate BLAS backend requires Apple's
newer Accelerate LAPACK interface. Pillow is built against SDK zlib and a
static libjpeg-turbo 3.2.0 (jpeg8 API, Neon SIMD). `ImageFont` uses FreeType
and Raqm layout from Matplotlib's bundled static FreeType, HarfBuzz, SheenBidi,
and libraqm, so Pillow builds after Matplotlib and the archive carries one copy
of each library. TIFF, LCMS, WebP, JPEG2000, imagequant, XCB, and AVIF support
remain disabled. `ImageFont.truetype` searches the macOS font directories only
on macOS; on iOS pass a font path, or use `ImageFont.load_default(size=...)`
for Pillow's embedded font. lxml is built
against static libxml2, libxslt, and libexslt with SDK zlib/iconv; libxslt
debugger, crypto, and plugin support are disabled. Matplotlib is packaged for
non-interactive Agg rendering with bundled FreeType and Qhull; Tk/Cocoa GUI
backends, LaTeX rendering, and ffmpeg/ImageMagick writers are not part of the
current payload; raster output uses Pillow's PNG and JPEG codecs. On iOS
devices and macOS, MLX includes its Accelerate CPU backend and Metal backend. `mlx.core` is registered
statically, Metal JIT is disabled, and each supported platform slice uses a
precompiled Metal library stored beside the MLX Python package. MLX is not
linked or bundled for the iOS simulator.

regex 2026.7.19 is compiled directly from its two upstream C sources and does
not add an external native library. Its legacy single-phase extension uses
process-global state, so normal commands use it through ios_system's persistent
main interpreter while recursive own-GIL interpreters reject it through
CPython's native-extension compatibility check.

hf-xet uses the upstream PyO3 binding and Rust 1.89.0, matching the toolchain
used by the embedded ripgrep libraries. Its release build explicitly disables
LTO so Rust's standard-library objects stay separate; the relocatable link
selects one matching Rust runtime for the bundled Python extensions and keeps
it private to Python. Other Rust consumers link their own runtime. The Apple
build also disables xet-runtime's optional `sysinfo`-based system monitor and
log cleanup, avoiding platform process inspection and the macOS IOKit
dependency; file transfer behavior is unchanged. Normal and sequential Python
commands use hf-xet through ios_system's persistent main interpreter. PyO3 0.29
does not advertise support for an extension module in own-GIL subinterpreters,
so recursive or overlapping Python commands reject `hf_xet` cleanly through
CPython's enabled extension-compatibility check. This matches the support
boundary of other native extensions such as NumPy without weakening the
recursive interpreter configuration.

The generator also applies a feature-gated download C API to the same hf-xet
archive used by the Python extension. The C entry points are folded into
`Python.xcframework`, and `HFXetHeaders/hf_xet.h` exposes them to LocalCode
through a header-only Bazel module. This keeps one hf-xet implementation in the
process while preserving the Python extension for embedded Python callers.

safetensors 0.8.0 uses its upstream PyO3 0.28 binding and the same Rust 1.89.0
toolchain as hf-xet. Its release build also disables LTO before the static
archive is folded into Python. PyO3 uses its pinned `abi3-py310` configuration
without inspecting a host Python installation. The upstream Python package is
bundled so its NumPy adapter is available on every slice and its MLX adapter is
available where MLX is bundled. As with hf-xet, normal commands use safetensors
through the persistent main interpreter, while recursive own-GIL interpreters
retain CPython's native-extension compatibility check and reject it cleanly.

tokenizers 0.22.2 uses its upstream PyO3 0.26 binding and the same Rust 1.89.0
toolchain. Its default native features retain vendored Oniguruma, the C++ ESAXX
implementation, and progress reporting, while the optional Rust HTTP client is
disabled. The upstream Python metadata still declares `huggingface_hub`, so pip
installs that pure-Python dependency into the active project when a package
needs it; it is not folded into the native payload. As with the other PyO3
extensions, normal commands use tokenizers through the persistent main
interpreter, while recursive own-GIL interpreters reject it through CPython's
native-extension compatibility check.

SentencePiece 0.2.2 uses its upstream pybind11 3.0.1 Python binding and package
resources. Only the binding object is folded into the Python XCFramework; the
SentencePiece processor and trainer stay in the canonical
`@sentencepiece//:sentencepiece_train` Bazel dependency supplied by
swift-sentencepiece, so Python and Swift use the same C++ implementation rather
than embedding another copy in PythonIOS. The binding uses the Abseil headers
already bundled in the SentencePiece sdist; they are the same `lts_20260526`
revision used by that Bazel target. No separate Abseil build is embedded in
PythonIOS. pybind11 marks the module as unsupported in subinterpreters by
default, so recursive own-GIL interpreters reject it while normal commands reuse
it in the persistent main interpreter.

CairoSVG 2.9.1 uses Cairo 1.18.6, Pixman 0.46.4, libpng 1.6.58, and CFFI
2.1.1 on all three slices. `cairosvg_build.sh` supplies its native build steps;
`generate_cairo_binding.py` generates a CFFI API binding compiled and registered
as `cairocffi._ffi` alongside `_cffi_backend`. The binding directly links Cairo
inside the encapsulated Python object. Cairo dependency symbols remain private.
The iOS slices reuse CPython's bundled libffi; macOS uses SDK libffi.

The cairocffi patch replaces shared-library discovery and dynamic stream
callbacks with compiled CFFI `extern "Python"` entry points and retained handles.
Cairo uses its Core Text font backend with image, PNG, PDF, PS, and SVG output.
The Cairo patch builds the font backend independently of desktop Quartz surface
code and removes legacy ATS font lookup. X11, XCB, GDK-PixBuf, Fontconfig, and
FreeType are not enabled for Cairo. Embedded raster image support follows
Pillow's codec policy, so PNG and JPEG work.
Recursive own-GIL interpreters retain CPython's extension compatibility checks;
normal sequential commands use the persistent main interpreter.

Use `python -m cairosvg input.svg -o output.png`, or convert before opening with
Pillow:

```python
import io
import cairosvg
from PIL import Image

image = Image.open(io.BytesIO(cairosvg.svg2png(url="input.svg"))).convert("RGBA")
```

Pure-Python convenience packages are pinned in `pure_python_requirements.txt`
and installed into both resource trees with hash checking. The current base set
is `requests`, pandas runtime dependencies (`python-dateutil`, `six`,
`tzdata`), matplotlib runtime dependencies (`cycler`, `fonttools`, `pyparsing`),
PDF support (`pypdf`), spreadsheet support (`openpyxl`, `et_xmlfile`,
`XlsxWriter`), Word/PowerPoint support (`python-docx`, `python-pptx`,
`typing_extensions`), YAML support (`PyYAML`), progress reporting (`tqdm`), and
`packaging`. PyYAML is built reproducibly from its pinned source archive as a
`py3-none-any` wheel with LibYAML disabled, so it uses the upstream pure-Python
loaders and dumpers without adding a native extension.
The optional tqdm monitor thread and multiprocessing lock are disabled because
they can outlive or deadlock an in-process Python command. Normal iterable and
manually updated progress bars, including their thread lock, remain available.

The committed resources intentionally contain no `.so`, `.dylib`, `.a`, `.exe`,
or `.fwork` files and do not need an app-build script to rewrite extension
modules into frameworks. MLX's `.metallib` files are data resources loaded by
the statically linked MLX runtime.

The generated `PYTHON_BUILD_INFO` records the pinned source and toolchain
versions. `SHA256SUMS` records checksums for the committed payload and helper
files.

Validate the integration with:

```sh
Vendors/PythonIOS/verify_python_ios.sh
bash Vendors/PythonIOS/Tests/encapsulate_python_test.sh
bazel build //Apps/LocalCode:StaticInlinePython --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:StaticInlinePython --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:StaticInlinePythonMacOS
bazel-bin/Apps/LocalCode/StaticInlinePythonMacOS
```

The encapsulation regression links a host with deliberately conflicting
dependency function and common-global names, and checks that the packaged
runtime still resolves its own definitions while preserving the host's state.

The focused runtime suite exercises CPython reuse and isolation plus functional
operations in PyYAML, NumPy, pandas, Pillow, CairoSVG, lxml, contourpy, kiwisolver,
matplotlib, psd-tools, regex, hf-xet, tokenizers, and SentencePiece. Native
package coverage includes pip dependency discovery and expected
recursive-interpreter rejection. On macOS and physical iOS
devices it also exercises both MLX CPU and Metal execution. Run the iOS target
on a simulator or physical device and require
`[StaticInlinePython] suite passed`.

Commit this directory as generated vendor output. Do not commit the external
build checkout, CPython cross-build directories, Bazel output directories, or
build logs from `/private/tmp`.

## curl_cffi and yt-dlp

`curl_cffi` 0.16.0 is available to every embedded Python command. Its matching
curl-impersonate v2.0.0 is a separate, size-optimized static
`Frameworks/CurlCFFI.xcframework` (iOS arm64, simulator arm64, macOS arm64).
`python_runtime.c` registers `curl_cffi._wrapper` before Python initialization.
The binding uses upstream compiled CFFI callbacks and the existing `_cffi_backend`;
there is no new libffi or executable-memory callback trampoline.

The app already links prefixed BoringSSL through SwiftCrypto and SwiftNIOSSL.
Those copies cannot directly satisfy curl-impersonate's patched TLS API, including
`SSL_CTX_set_extension_order`. This build keeps the upstream fingerprint patches
and locally binds its BoringSSL, curl, HTTP/2, HTTP/3, Brotli and Zstandard symbols
before final app linking. Only `PyInit__wrapper` is exported. SDK zlib and ICU are
reused. Neither existing BoringSSL copy nor the ordinary `curl` command changes.
Python's existing certifi bundle supplies curl_cffi's default CA certificates.

`yt-dlp` 2026.08.19, `yt-dlp-ejs` 0.8.0 and Mutagen 1.48.1 are Python resources
in both resource trees. The registered `yt-dlp` command runs `python -m yt_dlp`
with the same isolation and cancellation ownership as `python` and `pip`.
`Patches/yt-dlp-ios-system.patch` adapts subprocess execution to the existing
synchronous ios_system bridge, selects embedded Node by default, routes EJS and
FFmpeg through registered commands, and disables standalone self-updates.
The bundled EJS scripts work without a runtime component download.

App Store review delists apps whose binary links to U.S.-embargoed territories,
so the installer also removes the Iranian Aparat, PressTV, Telewebion and
Varzesh3 extractors and the `nitter.ir` Nitter instance, including their lazy
extractor entries. It fails if a host on an embargoed ccTLD (`.ir`, `.cu`, `.kp`,
`.sy`) remains, and `verify_python_ios.sh` applies the same check to the
committed resources. Review any new match when updating yt-dlp.

Normal file downloads, impersonated requests, FFmpeg merging/postprocessing,
and FFmpeg URL inputs are supported. Streaming child-process APIs, FFmpeg pipe
inputs, custom subprocess environments/timeouts and unregistered external tools
remain unsupported. Live-download cancellation uses ios_system cancellation;
the desktop FFmpeg `q`-on-stdin finalization path is unavailable. Other JavaScript
runtimes are not bundled. Native CFFI remains subject to CPython's existing
subinterpreter compatibility checks.

Regenerate these packages independently of the large CPython build:

```sh
# Use a host Python with the bundled CFFI version (CFFI_VERSION in
# cairosvg_build.sh, currently 2.1.1); build.sh checks it. On newer Xcode, set
# PYTHON_LD_CLASSIC to ld-classic from an installed older Xcode.
CFFI_BUILD_PYTHON=/path/to/host/python bash Vendors/PythonIOS/CurlCFFI/build.sh
python3 Vendors/PythonIOS/YTDLP/install.py
```

The full `build_base_python.sh` runs both steps. Source archives/wheels and all
native transitive dependencies are SHA-256 pinned; the installer applies the
patch with zero fuzz and refreshes wheel RECORD hashes. Native license notices
are copied into the bundled curl_cffi metadata. `CurlCFFI/BUILD_INFO` and
`CurlCFFI/dependencies.cmake` record the native versions. `YTDLP/resources.json`
pins the wheels, and the installer writes `YTDLP/BUILD_INFO` from it.
When updating, review curl_cffi's required curl-impersonate version and yt-dlp's
EJS/curl_cffi constraints together, rebase the small patch, regenerate both trees,
rerun validation, and refresh `SHA256SUMS`. App releases deliver these updates.

Measured with Xcode 27.0 / Bazel release configuration on arm64:

| Increment | Size |
| --- | ---: |
| Linked macOS harness executable (before test-harness changes) | 2,491,520 bytes / 2.38 MiB |
| iOS native static archive | 4,403,144 bytes / 4.20 MiB |
| Python resources per app platform | 11,492,643 bytes / 10.96 MiB |
| Same new resources in a deflate-9 ZIP | 3,409,997 bytes / 3.25 MiB |

The linked harness grew from 399,257,280 to 401,748,800 bytes. This is a
controlled native-size comparison, not an App Store download-size claim. The
archive includes symbols/relocations and code removed by final dead stripping;
the app embeds one platform slice, not all three. The original Python archives
are unchanged. Resource sizes include notices and distribution metadata; the
ZIP measurement is an estimate of resource compression, not an IPA measurement.
`CurlCFFI/verify.py` checks platform slices, symbol isolation and a 5 MiB per-slice
archive budget so future growth requires review.

The integration fixture is included in the iOS Python test app and runs in its
normal suite. It also runs directly on macOS:

```sh
bazel build //Apps/LocalCode:StaticInlinePythonMacOS --config=release
bazel-bin/Apps/LocalCode/StaticInlinePythonMacOS python3 Vendors/PythonIOS/YTDLP/Tests/embedded.py
bazel-bin/Apps/LocalCode/StaticInlinePythonMacOS yt-dlp --list-impersonate-targets
```

It covers synchronous/asynchronous curl requests, redirects/cookies, complete
and early-closed streams, an impersonated yt-dlp download, the bundled EJS
provider on Node, AAC postprocessing, and FFmpeg URL downloading. These local
fixtures do not depend on changing video sites or account credentials.
