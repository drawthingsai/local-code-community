load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

objc_library(
    name = "Internal",
    srcs = ["Sources/Internal/ExceptionCatcher.m"],
    hdrs = ["Sources/Internal/include/ExceptionCatcher.h"],
    includes = ["Sources/Internal/include"],
    module_name = "Internal",
)

swift_library(
    name = "ExceptionCatcher",
    srcs = glob([
        "Sources/ExceptionCatcher/**/*.swift",
    ]),
    module_name = "ExceptionCatcher",
    visibility = ["//visibility:public"],
    deps = [
        ":Internal",
    ],
)
