load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "RemoteAPI",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "RemoteAPI",
    visibility = ["//visibility:public"],
)

swift_test(
    name = "RemoteAPITests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":RemoteAPI",
    ],
)
