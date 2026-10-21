# Vendored libgit2

Base release: **v1.9.7** (updated from v1.9.1).

- Source: https://github.com/libgit2/libgit2/releases/tag/v1.9.7
- Archive: https://codeload.github.com/libgit2/libgit2/tar.gz/refs/tags/v1.9.7
- Archive SHA-256: `1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7`

This directory contains the subset of upstream sources used by our Bazel build,
plus the ios_system Git frontend. `BUILD.bazel` is maintained locally. The build
uses Apple Secure Transport, system regcomp, and system zlib; upstream's optional
bundled PCRE2 sources are not needed by this configuration.

The frontend under `examples/` contains local commands and adaptations for
in-process iOS execution, command output, cloning, and Git LFS. Preserve these
when updating upstream. LFS is implemented in `Vendors/ios_system/git_lfs.m` and
connected through the `IOS_SYSTEM_GIT_LFS` build definition.

`src/libgit2/attr_file.c` retains our quoted-attribute parsing patch. Upstream
v1.9.7 still does not parse C-quoted attribute patterns, which are needed for LFS
tracking patterns containing spaces. All other vendored upstream library source
files match v1.9.7.

For future updates, compare against this upstream tag and apply upstream changes
with a three-way merge, preserving local frontend files and patches. Check new
or removed source files against `BUILD.bazel`, then validate:

```sh
bazel test //Vendors/ios_system:GitLFSTests //Apps/LocalCode:BashUserInteractionTests //Apps:DrawThingsCLICommandTests --test_output=errors
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```
