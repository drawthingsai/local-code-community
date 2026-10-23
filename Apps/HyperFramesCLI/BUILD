load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary", "swift_library")

config_setting(
    name = "catalyst_build",
    constraint_values = [
        "@build_bazel_apple_support//constraints:catalyst",
    ],
)

apple_resource_group(
    name = "Resources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(["Resources/HyperFrames/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "HyperFramesCLILib",
    srcs = [
        "HyperFramesCLI.swift",
        "HyperFramesServer.swift",
    ],
    # Every app linking this library needs the worker and browser assets.
    data = [":Resources"],
    module_name = "HyperFramesCLILib",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/HTMLVideoExporter",
    ] + select({
        ":catalyst_build": ["//Vendors/NodeJS:NodeMobileCatalyst"],
        "//conditions:default": ["//Vendors/NodeJS:NodeMobile"],
    }),
)

swift_library(
    name = "HyperFramesCommand",
    srcs = ["IOSSystem/HyperFramesCommand.swift"],
    module_name = "HyperFramesCommand",
    visibility = ["//visibility:public"],
    deps = [
        ":HyperFramesCLILib",
        "//Vendors/ios_system:ios_system_api",
    ],
)

swift_binary(
    name = "hyperframes",
    srcs = ["Executable/Main.swift"],
    data = glob(["Resources/HyperFrames/**"]),
    visibility = ["//visibility:public"],
    deps = [":HyperFramesCLILib"],
)

filegroup(
    name = "RuntimeFiles",
    srcs = glob(["Resources/HyperFrames/**"]),
    visibility = ["//visibility:public"],
)
