load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@dflat//:dflat.bzl", "dflatc")

swift_library(
    name = "Components",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "Components",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/DataModels",
        "//Libraries/Features",
        "//Libraries/Localization",
        "//Libraries/Style",
        "//Vendors/ExceptionCatcher",
        "//Vendors/MultiSlider",
        "//Vendors/Nantes",
        "//Vendors/Nuke:NukeUI",
        "//Vendors/SnapKit",
        "@dflat//:SQLiteDflat",
    ],
)
