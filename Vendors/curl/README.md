# curl

The `curl` command in `ios_system`, and the libcurl that git-lfs uses. The pinned
release tarball is downloaded by Bazel (`@curl` in `WORKSPACE.darwin`, built by
`external/curl.BUILD`); this directory holds what is ours:

- `ios.patch`: source changes, all under `IOS_SYSTEM_CURL`:
  - `.netrc` is looked up in `CURL_HOME` first, which ios_system sets per
    project, as for `.curlrc`.
  - The tool ignores `SSL_CERT_FILE` and `SSL_CERT_DIR`, which ios_system sets
    for Python's OpenSSL: curl verifies certificates with Apple's trust store,
    and a CA file would replace it. `--cacert` and `CURL_CA_BUNDLE` still select
    one.
  - The tool keeps its state in statics, written for a new process per run.
    `ios_curl_reset_*` functions restore that state; `CurlMain.c` calls them
    before every run, so a run never sees an earlier or cancelled run's options,
    lists or counters. When upgrading, list the tool's writable data
    (`nm -m` on `@curl//:tool`, the `__DATA` and `(common)` symbols) and check
    each against these resets; `NativeCommandTests` runs curl repeatedly in one
    process.
  - The tool does not ignore SIGPIPE for the whole app: ios_system already
    blocks it on command threads.
- `CurlPort.h`, forced into every source: the invoking command's streams and
  environment (`ios_getenv`), and file paths relative to the invocation's
  directory (ios_system_support), not the process's, which another session may
  have moved. The tool also gets `ios_error.h`, like ios_system's other commands.
- `CurlMain.c`: `curl_main`, which sets up that directory and runs the tool.
- `BoringSSL/openssl/`: headers mapping curl's OpenSSL backend to
  swift-nio-ssl's prefixed BoringSSL, which the app already links.
- `Config/curl_config.h`, generated as below.

ios_system runs one curl job at a time (`curlRuntime`, like OpenSSH): the tool
keeps process-wide state, and OSH sessions can start curl concurrently.

Protocols are `file`, `http` and `https`. Features: alt-svc, AppleSecTrust,
AsynchDNS, HSTS, HTTPS-proxy, IPv6, Largefile, libz (SDK zlib), NTLM, SSL,
threadsafe and UnixSockets. There is no HTTP/2 (no nghttp2), IDN, PSL, c-ares,
SSH, WebSockets or IPFS.

## Regenerating `curl_config.h`

Configure the pinned release with its CMake for iOS arm64 against an OpenSSL
root made from swift-nio-ssl's BoringSSL: `include/` holds its
`CNIOBoringSSL_*.h` headers plus an `openssl/<name>.h` shim for each, and
`lib/libssl.a` and `lib/libcrypto.a` are both its iOS `libCNIOBoringSSL.a`
from a Bazel build of the app. Hide Homebrew's `pkg-config` first.

```sh
cmake -S curl-<version> -B build -G Ninja -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF \
  -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DBUILD_EXAMPLES=OFF \
  -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$ROOT" \
  -DOPENSSL_INCLUDE_DIR="$ROOT/include" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_SSL_LIBRARY="$ROOT/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$ROOT/lib/libcrypto.a" -DHAVE_SSL_SET0_WBIO=1 \
  -DUSE_APPLE_SECTRUST=ON -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none \
  -DCURL_CA_FALLBACK=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
  -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF -DUSE_NGHTTP2=OFF \
  -DUSE_NGTCP2=OFF -DUSE_QUICHE=OFF -DUSE_LIBIDN2=OFF -DUSE_APPLE_IDN=OFF \
  -DUSE_LIBRTMP=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_ZLIB=ON \
  -DENABLE_ARES=OFF -DENABLE_THREADED_RESOLVER=ON -DENABLE_UNIX_SOCKETS=ON \
  -DCURL_ENABLE_NTLM=ON -DCURL_DISABLE_IPFS=ON -DCURL_DISABLE_LDAP=ON \
  -DCURL_DISABLE_LDAPS=ON -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_FTP=ON \
  -DCURL_DISABLE_GOPHER=ON -DCURL_DISABLE_IMAP=ON -DCURL_DISABLE_MQTT=ON \
  -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_SMB=ON \
  -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_TELNET=ON -DCURL_DISABLE_TFTP=ON \
  -DCURL_DISABLE_WEBSOCKETS=ON
```

`HAVE_SSL_SET0_WBIO` is set by hand because the prefixed BoringSSL fails
CMake's link check for it. Copy `build/lib/curl_config.h`, keep the note at its
top, and choose `CURL_OS` by `TARGET_OS_IPHONE` (`"iOS"` or `"Darwin"`). A
macOS configuration (`-DCMAKE_OSX_DEPLOYMENT_TARGET=13.5`, the macOS SDK and
archive) should differ only there; check that, and that the configure summary
lists the protocols and features above.

## Upgrading

Update the version, URLs and `sha256` in `WORKSPACE.darwin` (verify the
release's GPG signature), rebase `ios.patch`, regenerate the config, and add a
shim if curl includes another `<openssl/...>` header. Then run:

```sh
bazel test //Vendors/ios_system:GitLFSTests //Vendors/ios_system:NativeCommandTests
bazel test //Apps/LocalCode:BashUserInteractionTests
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```
