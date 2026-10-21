load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_application", "macos_command_line_application")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

package(default_visibility = ["//visibility:public"])

config_setting(
    name = "ios_device_arm64",
    constraint_values = [
        "@platforms//os:ios",
        "@platforms//cpu:arm64",
        "@build_bazel_apple_support//constraints:device",
    ],
)

config_setting(
    name = "ios_simulator",
    constraint_values = [
        "@platforms//os:ios",
        "@build_bazel_apple_support//constraints:simulator",
    ],
)

config_setting(
    name = "macos_arm64",
    constraint_values = [
        "@platforms//os:osx",
        "@platforms//cpu:arm64",
    ],
)

apple_static_xcframework_import(
    name = "private_archive",
    xcframework_imports = glob(["Frameworks/Office.xcframework/**"]),
)

objc_library(
    name = "LibreOffice",
    hdrs = ["OfficeCommand.h"],
    sdk_dylibs = select({
        ":ios_device_arm64": [
            "c++",
            "iconv",
            "z",
        ],
        ":macos_arm64": [
            "c++",
            "exslt",
            "iconv",
            "xml2",
            "xslt",
            "z",
        ],
    }),
    sdk_frameworks = select({
        ":ios_device_arm64": [
            "CoreFoundation",
            "CoreGraphics",
            "CoreText",
            "Foundation",
            "ImageIO",
            "Security",
            "UIKit",
        ],
        ":macos_arm64": [
            "AVFoundation",
            "AppKit",
            "ApplicationServices",
            "Carbon",
            "Cocoa",
            "CoreFoundation",
            "CoreGraphics",
            "CoreMedia",
            "CoreServices",
            "CoreText",
            "Foundation",
            "IOKit",
            "ImageIO",
            "Metal",
            "QuartzCore",
            "SystemConfiguration",
        ],
    }),
    deps = [":private_archive"],
)

apple_resource_group(
    name = "resources",
    strip_structured_resources_prefixes = [
        "ResourcesMacOS",
        "Resources",
    ],
    structured_resources = select({
        ":ios_device_arm64": glob(["Resources/**"]),
        ":macos_arm64": glob(["ResourcesMacOS/**"]),
    }),
)

filegroup(
    name = "resources_macos_files",
    srcs = glob(["ResourcesMacOS/**"]),
)

sh_test(
    name = "LibreOfficeVendorTests",
    srcs = ["verify_libreoffice.sh"],
    data = glob([
        "Frameworks/**",
        "Resources/**",
        "ResourcesMacOS/**",
        "Patches/**",
        "Receipts/**",
        "Notices/**",
        "Tests/**",
        "*.py",
        "*.sh",
    ]) + [
        ".gitignore",
        "BUILD",
        "LIBREOFFICE_BUILD_INFO",
        "LICENSE.dsh",
        "OfficeCommand.cpp",
        "OfficeCommand.h",
        "README.md",
        "SHA256SUMS",
        "document-operations.hpp",
        "document-validation.hpp",
        "exported_symbols.txt",
        "font-metadata.hpp",
        "font-operations.hpp",
        "ios.conf",
        "ios_system_office.m",
        "ios_system_office_simulator.m",
        "office_main.cpp",
        "render-operations.hpp",
    ],
)

apple_resource_group(
    name = "notices",
    structured_resources = glob(["Notices/**"]),
)

objc_library(
    name = "command",
    # The archive has no simulator slice; the simulator links a stub that reports that instead.
    srcs = select({
        ":ios_simulator": ["ios_system_office_simulator.m"],
        "//conditions:default": ["ios_system_office.m"],
    }),
    data = select({
        ":ios_simulator": [],
        "//conditions:default": [
            ":notices",
            ":resources",
        ],
    }),
    deps = ["//Vendors/ios_system:api"] + select({
        ":ios_simulator": [],
        "//conditions:default": [":LibreOffice"],
    }),
)

objc_library(
    name = "ios_system_validation_main",
    srcs = ["Tests/IOSSystemOfficeTests.m"],
    sdk_frameworks = ["Foundation"],
    deps = ["//Vendors/ios_system"],
)

macos_command_line_application(
    name = "ios_system_validation",
    bundle_id = "com.liuliu.office-validation",
    minimum_os_version = "13.5",
    deps = [
        ":ios_system_validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

# Exercise the transitive resource packaging used by an actual app bundle.
macos_application(
    name = "bundle_validation",
    bundle_id = "com.liuliu.office-bundle-validation",
    bundle_name = "OfficeValidation",
    infoplists = ["Tests/Info.plist"],
    minimum_os_version = "13.5",
    tags = ["manual"],
    deps = [
        ":ios_system_validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

cc_test(
    name = "OfficeCommandTests",
    size = "small",
    srcs = ["Tests/CommandTests.cpp"],
    copts = ["-std=c++17"],
    target_compatible_with = [
        "@platforms//os:osx",
        "@platforms//cpu:arm64",
    ],
    deps = [":LibreOffice"],
)

objc_library(
    name = "document_font_tests_main",
    testonly = True,
    srcs = ["Tests/DocumentFontTests.cpp"],
    hdrs = [
        "OfficeCommand.h",
        "document-validation.hpp",
        "font-metadata.hpp",
    ],
    copts = ["-std=c++17"],
    sdk_dylibs = [
        "expat",
        "z",
    ],
    sdk_frameworks = ["CoreFoundation"],
)

cc_test(
    name = "DocumentFontTests",
    size = "small",
    target_compatible_with = [
        "@platforms//os:osx",
        "@platforms//cpu:arm64",
    ],
    deps = [":document_font_tests_main"],
)
