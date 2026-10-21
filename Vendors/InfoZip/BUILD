package(default_visibility = ["//visibility:public"])

objc_library(
    name = "support",
    srcs = ["support.c"],
    hdrs = ["support.h"],
    deps = ["//Vendors/ios_system:ios_system_support"],
)

objc_library(
    name = "zip",
    srcs = [
        "zip/crc32.c",
        "zip/crypt.c",
        "zip/fileio.c",
        "zip/globals.c",
        "zip/ttyio.c",
        "zip/unix/unix.c",
        "zip/util.c",
        "zip/zbz2err.c",
        "zip/zip.c",
        "zip/zipfile.c",
        "zip/zipup.c",
    ],
    hdrs = glob([
        "zip/*.h",
        "zip/unix/*.h",
    ]),
    copts = [
        "-std=gnu17",
        "-DUNIX",
        "-DLARGE_FILE_SUPPORT",
        "-DUNICODE_SUPPORT",
        "-DUSE_ZLIB",
        "-Wno-deprecated-non-prototype",
        "-Wno-pointer-sign",
        "-Wno-shorten-64-to-32",
        "-Wno-deprecated-declarations",
        "-Wno-unused-function",
        "-Wno-unused-variable",
        "-include",
        "Vendors/InfoZip/zip/config.h",
        "-IVendors/InfoZip/zip",
    ],
    sdk_dylibs = ["z"],
    deps = [":support"],
)

objc_library(
    name = "unzip",
    srcs = [
        "unzip/crc32.c",
        "unzip/crypt.c",
        "unzip/envargs.c",
        "unzip/explode.c",
        "unzip/extract.c",
        "unzip/fileio.c",
        "unzip/globals.c",
        "unzip/inflate.c",
        "unzip/list.c",
        "unzip/match.c",
        "unzip/process.c",
        "unzip/ttyio.c",
        "unzip/ubz2err.c",
        "unzip/unix/unix.c",
        "unzip/unreduce.c",
        "unzip/unshrink.c",
        "unzip/unzip.c",
        "unzip/zipinfo.c",
    ],
    hdrs = glob([
        "unzip/*.h",
        "unzip/unix/*.h",
    ]),
    copts = [
        "-std=gnu17",
        "-DUNIX",
        "-DLARGE_FILE_SUPPORT",
        "-DUNICODE_SUPPORT",
        "-DUSE_ZLIB",
        "-Wno-deprecated-non-prototype",
        "-Wno-pointer-sign",
        "-Wno-shorten-64-to-32",
        "-Wno-deprecated-declarations",
        "-Wno-unused-function",
        "-Wno-unused-variable",
        "-include",
        "Vendors/InfoZip/unzip/config.h",
        "-IVendors/InfoZip/unzip",
        "-DREENTRANT",
        "-DNO_EXCEPT_SIGNALS",
    ],
    sdk_dylibs = ["z"],
    deps = [":support"],
)

exports_files([
    "zip/LICENSE",
    "unzip/LICENSE",
])

cc_test(
    name = "PortableExtractionTests",
    srcs = [
        "support.c",
        "support.h",
        "support_tests.c",
    ],
    copts = [
        "-DINFOZIP_TEST_PORTABLE_EXTRACTION",
        "-UNDEBUG",
    ],
    deps = ["//Vendors/ios_system:ios_system_support"],
)
