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

# Developer ID builds (`--config=direct`) buy through Stripe; App Store builds leave it out.
# Apps/LocalCode reads the same flag; a Swift define only reaches targets above it, not this one.
config_setting(
    name = "direct_distribution",
    define_values = {"distribution": "direct"},
)

swift_library(
    name = "UserAccount",
    srcs = glob(["Sources/**/*.swift"]) + [
        ":account_schema",
        ":privacy_pass_schema",
    ],
    # copts, not defines, so the define doesn't spread to Draw Things and other dependents.
    copts = select({
        ":direct_distribution": ["-DDIRECT_DISTRIBUTION"],
        "//conditions:default": [],
    }),
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
