# libcaca

This directory contains the libcaca sources needed by the `img2txt` command.
The upstream spelling is intentionally retained for the vendor directory and
Bazel target.

The snapshot is pinned to
[`7c8e3338a1bda8a34297d16ac546c43548e4864d`](https://github.com/cacalabs/libcaca/commit/7c8e3338a1bda8a34297d16ac546c43548e4864d).
The checked-in upstream files are:

- `caca/`
- `src/img2txt.c`
- `src/common-image.h`
- `COPYING`

The remaining files in this directory are the Draw Things Bazel build,
Apple configuration, ImageIO image loader, `ios_system` adapter, and tests.
The ImageIO loader replaces img2txt's optional Imlib2 loader and decodes the
first frame of any format supported by ImageIO.
