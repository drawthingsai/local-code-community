# Updating the packaged Node.js runtime

Local Code carries an Apple-platform Node.js port rather than consuming the
obsolete upstream Node.js Mobile release directly. Keep the upstream Node
source, the reusable mobile port, and Local Code's embedding changes as three
separate layers:

1. A checksum-pinned official Node.js source release.
2. `Patches/nodejs-mobile-ios.patch`, rebased from the build-relevant patches
   in the pinned `gmaclennan/nodejs-mobile` recipe.
3. `Patches/local-code-ios.patch`, containing only Local Code's deployment,
   embedding-host, and DrumBrake changes.

Do not replace these layers with an unreviewed full-source fork archive. The
separation makes point-release changes reviewable and preserves a canonical
source for each behavior.

## Point-release workflow

1. Select the target Node.js LTS release and download its official source
   archive and `SHASUMS256.txt` from `nodejs.org/dist`.
2. Update `NODEJS_VERSION`, `NODEJS_SOURCE_URL`, and
   `NODEJS_SOURCE_SHA256` in `build_nodejs_mobile.sh`.
3. Audit the newest `gmaclennan/nodejs-mobile` recipe. Apply its
   build-relevant patches to a pristine target source tree, resolve the Node
   point-release differences, and regenerate `nodejs-mobile-ios.patch`.
   Exclude CI, documentation, tests, and unrelated Android-only payloads from
   the committed baseline patch.
4. Apply `local-code-ios.patch` after the mobile patch. Rebase this patch only
   where the new Node or V8 source changed; do not fold generic mobile-port
   changes into it.
5. Compare the target's generated `node` link inputs with the archive closure
   in `build_nodejs_mobile.sh`. Point releases can split a library (for
   example, Node 24.20.0 introduced `libnode_base.a`) without causing the
   ordinary `node` executable build to fail. Node 24.22.1 also made
   `configure --enable-static` a deprecated no-op: `libnode.a` is always
   produced, and `make node` now links the `node` target as an executable
   instead of a static library.
6. Read `deps/npm/package.json` from the pinned Node source. Update the npm
   version and deterministic archive checksum in the build script, verifier,
   Bazel resource, Local Code resource loader, runtime probes, and docs.
7. Rebuild from the official source archive:

   ```bash
   Vendors/NodeJS/build_nodejs_mobile.sh
   ```

   The recipe must replace obsolete `npm-*.zip` payloads, produce the device,
   simulator, and macOS slices, refresh `NODEJS_BUILD_INFO`, and rewrite
   `SHA256SUMS`.
8. Run the verification matrix below before describing the new version as the
   packaged baseline.

## Verification matrix

```bash
Vendors/NodeJS/verify_nodejs_mobile.sh
bazel test //Vendors/NodeJS:NodeMobileVendorTests
bazel build //Apps/LocalCode:StaticInlineNode --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:StaticInlineNode --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:StaticInlineNodeMacOS
bazel run //Apps/LocalCode:StaticInlineNodeMacOS
bazel test //Apps/LocalCode:StaticInlineNodeIOSSystemTests
bazel test //Apps/LocalCode:StaticInlineNodeVirtualChildTests
bazel test //Apps/LocalCode:StaticInlineNodeProcessPolicyTests
bazel test //Apps/LocalCode:EnvironmentContextTests
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=sim_arm64
```

The runtime probe is the important compatibility test. A clean source build
alone does not establish that CommonJS/ESM loading, crypto, SQLite, ICU, HTTP,
fetch, JITless DrumBrake WebAssembly, cancellation, npm/npx, and virtual child
commands still work through the embedded host.

Every gate remains required for a completed upgrade. If a pre-existing harness
regression blocks one, record the exact last passing assertion and keep the
unreached behavior explicitly unvalidated until the harness is repaired.

## Major-version boundary

Treat a Node major update as a new port review, even when the mobile patch
applies mechanically. Re-audit V8 JITless and DrumBrake integration, GYP
variables and archive closure, OpenSSL/ICU symbol encapsulation, command-line
parsing, the embedding API, and npm behavior. Prefer the latest LTS line for
the packaged runtime unless there is a deliberate product reason to ship a
Current release.
