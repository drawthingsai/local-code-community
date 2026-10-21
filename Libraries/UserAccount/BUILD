load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@dflat//:dflat.bzl", "dflatc")

dflatc(
    name = "account_schema",
    srcs = [
        "Sources/account.fbs",
        "Sources/local_consumable_metadata.fbs",
    ],
)

dflatc(
    name = "privacy_pass_schema",
    srcs = ["Sources/privacy_pass.fbs"],
)

swift_library(
    name = "UserAccount",
    srcs = glob(["Sources/**/*.swift"]) + [
        ":account_schema",
        ":privacy_pass_schema",
    ],
    module_name = "UserAccount",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/DeviceAttestation",
        "//Libraries/Features",
        "//Libraries/Localization",
        "//Libraries/PrivacyPassClient",
        "@SwiftLog//:Logging",
        "@dflat//:SQLiteDflat",
    ],
)

objc_library(
    name = "TestFeatureFlags",
    srcs = ["Tests/FeatureFlagsForTests.m"],
)

swift_test(
    name = "UserAccountTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":TestFeatureFlags",
        ":UserAccount",
    ],
)
