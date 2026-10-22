load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

package(default_visibility = ["//visibility:public"])

apple_static_xcframework_import(
    name = "NodeMobile",
    sdk_dylibs = ["c++"],
    sdk_frameworks = [
        "CoreFoundation",
        "Security",
    ],
    xcframework_imports = glob(["Frameworks/NodeMobile.xcframework/**"]),
    alwayslink = True,
)

filegroup(
    name = "NodeCommandArchive",
    srcs = ["Resources/NodeMobile/Commands/npm-11.19.1.zip"],
)

apple_resource_group(
    name = "NodeCommandResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = [":NodeCommandArchive"],
)

sh_test(
    name = "NodeMobileVendorTests",
    size = "small",
    srcs = ["verify_nodejs_mobile.sh"],
    data = glob([
        "Frameworks/NodeMobile.xcframework/**",
        "Patches/**",
        "Resources/**",
        "Sources/**",
    ]) + [
        "BUILD",
        "LICENSE",
        "NODEJS_BUILD_INFO",
        "README.md",
        "SHA256SUMS",
        "UPGRADING.md",
        "build_nodejs_mobile.sh",
    ],
)
