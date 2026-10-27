package(default_visibility = ["//visibility:public"])

LIBCACA_COPTS = [
    "-D__LIBCACA__",
    "-UDEBUG",
    "-Wno-absolute-value",
    "-Wno-deprecated-declarations",
    "-Wno-format",
    "-Wno-sign-compare",
    "-Wno-unused-function",
    "-Wno-unused-but-set-variable",
    "-Wno-unused-parameter",
    "-Wno-unused-variable",
]

objc_library(
    name = "libcaca",
    srcs = [
        "caca/attr.c",
        "caca/box.c",
        "caca/caca.c",
        "caca/caca0.c",
        "caca/caca_conio.c",
        "caca/canvas.c",
        "caca/charset.c",
        "caca/codec/export.c",
        "caca/codec/import.c",
        "caca/codec/text.c",
        "caca/conic.c",
        "caca/dirty.c",
        "caca/dither.c",
        "caca/driver/null.c",
        "caca/driver/raw.c",
        "caca/event.c",
        "caca/figfont.c",
        "caca/file.c",
        "caca/font.c",
        "caca/frame.c",
        "caca/getopt.c",
        "caca/graphics.c",
        "caca/line.c",
        "caca/prof.c",
        "caca/string.c",
        "caca/time.c",
        "caca/transform.c",
        "caca/triangle.c",
    ],
    hdrs = glob([
        "caca/**/*.h",
    ]) + [
        "caca/mono9.data",
        "caca/monobold12.data",
        "config.h",
    ],
    copts = LIBCACA_COPTS,
    includes = [
        ".",
        "caca",
    ],
    deps = ["//Vendors/ios_system:ios_system_support"],
)

objc_library(
    name = "imageio_loader",
    srcs = ["common-image-apple.m"],
    hdrs = ["src/common-image.h"],
    includes = [
        "caca",
        "src",
    ],
    sdk_frameworks = [
        "CoreGraphics",
        "Foundation",
        "ImageIO",
    ],
    deps = [":libcaca"],
)

objc_library(
    name = "img2txt",
    srcs = [
        "ios_system_img2txt_entry.c",
        "src/img2txt.c",
    ],
    hdrs = [
        "ios_system_img2txt_preinclude.h",
        "src/common-image.h",
    ],
    copts = LIBCACA_COPTS + [
        "-DUSE_IMLIB2",
        "-includeios_system_img2txt_preinclude.h",
    ],
    includes = [
        ".",
        "caca",
        "src",
    ],
    deps = [
        ":imageio_loader",
        ":libcaca",
        "//Vendors/ios_system:api",
    ],
    alwayslink = True,
)

sh_test(
    name = "img2txt_tests",
    size = "small",
    srcs = ["run-img2txt-tests.sh"],
    data = ["//Vendors/ios_system:openssh_validation"],
)
