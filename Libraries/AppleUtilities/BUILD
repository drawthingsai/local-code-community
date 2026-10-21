load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "AppleUtilities",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "AppleUtilities",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BashToolContext",
        "//Vendors/Madrid:TypedStream",
        "//Vendors/ios_system:ios_system_api",
        "@SwiftArgumentParser//:ArgumentParser",
    ],
)

swift_test(
    name = "AppleUtilitiesTests",
    srcs = glob(["Tests/**/*.swift"]),
    discover_tests = False,
    deps = [
        ":AppleUtilities",
        "//Libraries/BashToolContext",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
        "@SwiftArgumentParser//:ArgumentParser",
        "@build_bazel_rules_swift//tools/test_observer",
    ],
)
