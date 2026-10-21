# Local Code Community

This repository contains the source code of the Local Code app, along with the libraries and vendored dependencies it builds from.

# License

Local Code Community is licensed under the GNU General Public License v3.0. See [LICENSE.md](LICENSE.md). Third-party code under `Vendors/` keeps its own license.

# Repository Sync

Local Code is developed in the private Draw Things mono-repository. We sync commits with this repository in both directions: each commit that touches a path listed in [SYNCLIST](SYNCLIST) is applied here, and commits made here are applied back. A `SYNCLIST` line is either a path with the same name in both repositories, or `private path -> path here` when the name differs.

Files that are not listed in `SYNCLIST`, such as this README, `LICENSE.md`, `Apps/BUILD` and `.github/`, are maintained in this repository only.

# Building

Prebuilt frameworks and resources under `Vendors/` (Python, Node.js and LibreOffice) are stored with Git LFS. Install Git LFS before cloning, or fetch the files after cloning:

```bash
git lfs install
git lfs pull
```

Local Code builds with Bazel (the version in `.bazelversion`) and Xcode on macOS. Set up the workspace once:

```bash
cp WORKSPACE.darwin WORKSPACE
echo 'try-import %workspace%/.bazelrc.darwin' > .bazelrc
```

Machine-specific flags go in `.bazelrc.local`, which `.bazelrc.darwin` imports. For example, Xcode releases without `ld-classic` need `--action_env=FFMPEG_LD_CLASSIC=/path/to/ld-classic` and `--define=LEAN_LD_CLASSIC=/path/to/ld-classic` from an earlier Xcode (see `Vendors/FFmpeg/README.md`).

Then build the app:

```bash
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```
