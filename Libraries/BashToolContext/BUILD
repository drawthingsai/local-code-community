load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "BashToolContext",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "BashToolContext",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/CLICloudAuth",
        "//Libraries/Downloader",
        "//Libraries/ImageGenerator",
        "//Vendors/ios_system:ios_system_api",
    ],
)

swift_test(
    name = "BashUserInteractionTests",
    srcs = ["Sources/BashUserInteraction.swift"] + glob(["Tests/**/*.swift"]),
)
