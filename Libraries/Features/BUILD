load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

objc_library(
    name = "LinkTimeFlags",
    hdrs = ["Sources/LinkTimeFlags.h"],
    module_name = "LinkTimeFlags",
)

swift_library(
    name = "Features",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "Features",
    visibility = ["//visibility:public"],
    deps = [
        ":LinkTimeFlags",
    ],
)
