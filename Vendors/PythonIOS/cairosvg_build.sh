# Sourced by build_base_python.sh. CairoSVG uses the same static archive and
# resource installation pipeline as the other bundled Python extensions.
CFFI_VERSION=2.1.1
CFFI_SOURCE_URL=https://files.pythonhosted.org/packages/9e/ef/008a1939e372c06329a3fce4279c02f328488f3526744906eeec3da7ad5f/cffi-2.1.1.tar.gz
CFFI_SOURCE_SHA256=dd31f52ea1086513bb9df30f8fcee9b8918323ae067a3d5b78bc826a000712be
CAIRO_VERSION=1.18.6
CAIRO_SOURCE_URL=https://cairographics.org/releases/cairo-1.18.6.tar.xz
CAIRO_SOURCE_SHA256=1c767308174337a74694da0f3ec069c271452163a1ef4540964c50c301f157d4
PIXMAN_VERSION=0.46.4
PIXMAN_SOURCE_URL=https://cairographics.org/releases/pixman-0.46.4.tar.xz
PIXMAN_SOURCE_SHA256=a098c33924754ad43f981b740f6d576c70f9ed1006e12221b1845431ebce1239
LIBPNG_VERSION=1.6.58
LIBPNG_SOURCE_URL=https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz
LIBPNG_SOURCE_SHA256=28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775
CAIRO_PKGCONF_VERSION=2.5.1
CAIRO_PKGCONF_SOURCE_URL=https://distfiles.ariadne.space/pkgconf/pkgconf-2.5.1.tar.xz
CAIRO_PKGCONF_SOURCE_SHA256=cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243
CAIRO_BUILD_ROOT=$BUILD_DIR/cairosvg
CAIRO_SOURCE_DIR=$CAIRO_BUILD_ROOT/cairo-$CAIRO_VERSION
CFFI_SOURCE_DIR=$CAIRO_BUILD_ROOT/cffi-$CFFI_VERSION
CAIRO_FEATURE_POLICY="binding=static-cffi-api callbacks=compiled font=CoreText png=enabled pdf=enabled ps=enabled svg=enabled xlib=disabled xcb=disabled freetype=disabled fontconfig=disabled"

prepare_cairosvg_source() {
    mkdir -p "$CAIRO_BUILD_ROOT"
    for entry in \
        "$CFFI_SOURCE_URL|$CFFI_SOURCE_SHA256" \
        "$CAIRO_SOURCE_URL|$CAIRO_SOURCE_SHA256" \
        "$PIXMAN_SOURCE_URL|$PIXMAN_SOURCE_SHA256" \
        "$LIBPNG_SOURCE_URL|$LIBPNG_SOURCE_SHA256" \
        "$CAIRO_PKGCONF_SOURCE_URL|$CAIRO_PKGCONF_SOURCE_SHA256"; do
        source_url=${entry%|*}
        source_sha256=${entry#*|}
        archive=$(download_macos_dependency "$source_url" "${source_url##*/}" "$source_sha256")
        tar -xf "$archive" -C "$CAIRO_BUILD_ROOT"
    done
    patch -d "$CAIRO_SOURCE_DIR" -p1 < "$REPO_ROOT/Vendors/PythonIOS/Patches/cairo-coretext.patch"
    (
        cd "$CAIRO_BUILD_ROOT/pkgconf-$CAIRO_PKGCONF_VERSION"
        ./configure --prefix="$CAIRO_BUILD_ROOT/tools" --disable-shared --disable-dependency-tracking
        make -j "$HOST_CPU_COUNT"
        make install
    ) > "$CAIRO_BUILD_ROOT/pkgconf.log" 2>&1 || {
        tail -120 "$CAIRO_BUILD_ROOT/pkgconf.log"
        return 1
    }
    DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$NUMPY_BUILD_TOOLS_PYTHON" \
        "$REPO_ROOT/Vendors/PythonIOS/generate_cairo_binding.py" \
        "$NUMPY_BUILD_TOOLS_VENV/lib/python$PYTHON_VERSION_TAG/site-packages/cairocffi/constants.py" \
        "$CAIRO_BUILD_ROOT/cairocffi.c"
}

build_cairosvg_slice() (
    sdk=$1
    minimum_os=$2
    python_headers=$3
    ffi_headers=$4
    slice_root="$CAIRO_BUILD_ROOT/$sdk"
    prefix="$slice_root/prefix"
    sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
    case "$sdk" in
        iphoneos) minimum_flag=-miphoneos-version-min=$minimum_os ;;
        iphonesimulator) minimum_flag=-mios-simulator-version-min=$minimum_os ;;
        macosx) minimum_flag=-mmacosx-version-min=$minimum_os ;;
    esac
    mkdir -p "$prefix/lib/pkgconfig" "$slice_root/png"
    trap 'result=$?; if [ "$result" -ne 0 ]; then tail -80 "$slice_root"/*.log; fi' EXIT
    # Use SDK zlib explicitly; never discover a host Homebrew library in a
    # cross-build. Pixman and libpng install their own .pc files here.
    cat > "$prefix/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: Apple SDK zlib
Version: 1.2.12
Libs: -lz
EOF
    cat > "$slice_root/cross.ini" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$sdk', 'clang']
cpp = ['xcrun', '--sdk', '$sdk', 'clang++']
ar = ['xcrun', 'ar']
strip = ['xcrun', 'strip']
pkg-config = '$CAIRO_BUILD_ROOT/tools/bin/pkgconf'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$prefix/lib/pkgconfig']
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$sdk_root', '$minimum_flag']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sdk_root', '$minimum_flag']
cpp_args = ['-arch', 'arm64', '-isysroot', '$sdk_root', '$minimum_flag']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$sdk_root', '$minimum_flag']
EOF
    export PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH"
    export DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH=
    (
        cd "$slice_root/png"
        CC="xcrun --sdk $sdk clang -arch arm64 -isysroot $sdk_root $minimum_flag" \
            CFLAGS=-O2 "$CAIRO_BUILD_ROOT/libpng-$LIBPNG_VERSION/configure" \
            --host=aarch64-apple-darwin --prefix="$prefix" \
            --disable-shared --enable-static --disable-dependency-tracking
        make -j "$HOST_CPU_COUNT"
        make install
    ) > "$slice_root/png.log" 2>&1
    meson setup "$slice_root/pixman" "$CAIRO_BUILD_ROOT/pixman-$PIXMAN_VERSION" \
        --cross-file "$slice_root/cross.ini" --prefix "$prefix" \
        --default-library static --buildtype release --wrap-mode nofallback \
        -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled \
        > "$slice_root/pixman.log" 2>&1
    meson compile -C "$slice_root/pixman" -j "$HOST_CPU_COUNT" >> "$slice_root/pixman.log" 2>&1
    meson install -C "$slice_root/pixman" >> "$slice_root/pixman.log" 2>&1
    meson setup "$slice_root/cairo" "$CAIRO_SOURCE_DIR" \
        --cross-file "$slice_root/cross.ini" --prefix "$prefix" \
        --default-library static --buildtype release --wrap-mode nofallback \
        -Dquartz=enabled -Dpng=enabled -Dzlib=enabled -Dfontconfig=disabled \
        -Dfreetype=disabled -Ddwrite=disabled -Dxcb=disabled -Dxlib=disabled \
        -Dtests=disabled -Dglib=disabled -Dspectre=disabled -Dlzo=disabled \
        -Dsymbol-lookup=disabled -Dgtk_doc=false \
        > "$slice_root/cairo.log" 2>&1
    meson compile -C "$slice_root/cairo" -j "$HOST_CPU_COUNT" >> "$slice_root/cairo.log" 2>&1
    meson install -C "$slice_root/cairo" >> "$slice_root/cairo.log" 2>&1
    xcrun --sdk "$sdk" clang -O2 -arch arm64 -isysroot "$sdk_root" "$minimum_flag" \
        -I "$python_headers" -I "$ffi_headers" -DUSE__THREAD -DHAVE_SYNC_SYNCHRONIZE -DFFI_BUILDING=1 \
        -c "$CFFI_SOURCE_DIR/src/c/_cffi_backend.c" -o "$slice_root/cffi_backend.o"
    xcrun --sdk "$sdk" clang -O2 -arch arm64 -isysroot "$sdk_root" "$minimum_flag" \
        -I "$python_headers" -I "$prefix/include/cairo" \
        -c "$CAIRO_BUILD_ROOT/cairocffi.c" -o "$slice_root/cairocffi.o"
    xcrun --sdk "$sdk" clang -O2 -arch arm64 -isysroot "$sdk_root" "$minimum_flag" \
        -I "$python_headers" -c "$REPO_ROOT/Vendors/PythonIOS/cairosvg_inittab.c" \
        -o "$slice_root/cairosvg_inittab.o"
)

cairosvg_runtime_objects() {
    echo "$CAIRO_BUILD_ROOT/$1/cffi_backend.o"
    echo "$CAIRO_BUILD_ROOT/$1/cairocffi.o"
    echo "$CAIRO_BUILD_ROOT/$1/cairosvg_inittab.o"
    echo "$CAIRO_BUILD_ROOT/$1/prefix/lib/libcairo.a"
    echo "$CAIRO_BUILD_ROOT/$1/prefix/lib/libpixman-1.a"
    echo "$CAIRO_BUILD_ROOT/$1/prefix/lib/libpng16.a"
}

install_cairosvg_resources() {
    site_packages="$1/lib/python$PYTHON_VERSION_TAG/site-packages"
    rm -rf "$site_packages/cffi" "$site_packages"/cffi-*.dist-info
    cp -R "$CFFI_SOURCE_DIR/src/cffi" "$site_packages/"
    dist_info="$site_packages/cffi-$CFFI_VERSION.dist-info"
    mkdir -p "$dist_info/licenses"
    cp "$CFFI_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$CFFI_SOURCE_DIR/LICENSE" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    patch -d "$site_packages" -p1 < "$REPO_ROOT/Vendors/PythonIOS/Patches/cairocffi-static.patch"
    # Refresh wheel records for the two patched files.
    python3 - "$site_packages" <<'PY'
import base64
import csv
import hashlib
import sys
from pathlib import Path
root = Path(sys.argv[1])
record = root / 'cairocffi-1.7.1.dist-info/RECORD'
with record.open(newline='') as stream:
    rows = list(csv.reader(stream))
for row in rows:
    if row[0] in ('cairocffi/__init__.py', 'cairocffi/surfaces.py'):
        data = (root / row[0]).read_bytes()
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
        row[1:] = ['sha256=' + digest, str(len(data))]
with record.open('w', newline='') as stream:
    csv.writer(stream).writerows(rows)
PY
    licenses="$site_packages/cairocffi-1.7.1.dist-info/licenses/native"
    mkdir -p "$licenses"
    cp "$CAIRO_SOURCE_DIR/COPYING" "$licenses/cairo-COPYING"
    cp "$CAIRO_SOURCE_DIR/COPYING-LGPL-2.1" "$licenses/cairo-LGPL-2.1"
    cp "$CAIRO_SOURCE_DIR/COPYING-MPL-1.1" "$licenses/cairo-MPL-1.1"
    cp "$CAIRO_BUILD_ROOT/pixman-$PIXMAN_VERSION/COPYING" "$licenses/pixman-COPYING"
    cp "$CAIRO_BUILD_ROOT/libpng-$LIBPNG_VERSION/LICENSE" "$licenses/libpng-LICENSE"
}
