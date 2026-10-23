load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

package(default_visibility = ["//visibility:public"])

genrule(
    name = "NodeMobileCatalystObject",
    srcs = ["Frameworks/NodeMobile.xcframework/macos-arm64/libNodeMobile.a"],
    outs = ["NodeMobileCatalyst.o"],
    cmd = "$(location :replatform_node_for_catalyst.sh) " +
          "$(location Frameworks/NodeMobile.xcframework/macos-arm64/libNodeMobile.a) " +
          "$@ 16.0 $(location //Vendors/PythonIOS:replatform_macho_for_catalyst.py)",
    tools = [
        ":replatform_node_for_catalyst.sh",
        "//Vendors/PythonIOS:replatform_macho_for_catalyst.py",
    ],
)

exports_files(["replatform_node_for_catalyst.sh"])

objc_library(
    name = "NodeMobileCatalyst",
    srcs = [":NodeMobileCatalystObject"],
    hdrs = ["Frameworks/NodeMobile.xcframework/macos-arm64/Headers/NodeMobile.h"],
    module_name = "NodeMobile",
    sdk_dylibs = ["c++"],
    sdk_frameworks = [
        "CoreFoundation",
        "Security",
    ],
    alwayslink = True,
)

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
        "replatform_node_for_catalyst.sh",
    ],
)
