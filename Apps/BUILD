load("@build_bazel_rules_apple//apple:macos.bzl", "macos_command_line_application")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary", "swift_library", "swift_test")

swift_library(
    name = "DrawThingsCLILib",
    srcs = glob(["DrawThingsCLI/*.swift"]),
    module_name = "DrawThingsCLILib",
    visibility = ["//Apps:__subpackages__"],
    deps = [
        "//Libraries/AudioConverter",
        "//Libraries/BinaryResources",
        "//Libraries/CLICloudAuth",
        "//Libraries/ConfigurationZoo",
        "//Libraries/DataModels",
        "//Libraries/Downloader",
        "//Libraries/GRPC:GRPCServer",
        "//Libraries/ImageGenerator",
        "//Libraries/LocalImageGenerator",
        "//Libraries/ModelOp",
        "//Libraries/ModelZoo",
        "//Libraries/RemoteImageGenerator",
        "//Libraries/Scripting:ScriptDataModels",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftDiffusion:SwiftDiffusionCoreMLModelManager",
        "//Libraries/Tokenizer",
        "//Libraries/Trainer",
        "@SwiftArgumentParser//:ArgumentParser",
        "@SwiftPNG//:PNG",
        "@dflat//:SQLiteDflat",
    ],
)

swift_binary(
    name = "DrawThingsCLI",
    srcs = ["DrawThingsCLI/Executable/Main.swift"],
    visibility = ["//visibility:public"],
    deps = [
        ":DrawThingsCLILib",
    ],
)

swift_library(
    name = "DrawThingsCLICommand",
    srcs = ["DrawThingsCLI/IOSSystem/DrawThingsCLICommand.swift"],
    module_name = "DrawThingsCLICommand",
    visibility = ["//Apps:__subpackages__"],
    deps = [
        ":DrawThingsCLILib",
        "//Libraries/BashToolContext",
        "//Vendors/ios_system:ios_system_api",
    ],
)

swift_library(
    name = "DrawThingsCLICommandTestsLib",
    testonly = True,
    srcs = ["DrawThingsCLI/Tests/DrawThingsCLICommandTests.swift"],
    deps = [
        ":DrawThingsCLICommand",
        ":DrawThingsCLILib",
        "//Libraries/BashToolContext",
        "//Libraries/CLICloudAuth",
        "//Libraries/Downloader",
        "//Libraries/ModelZoo",
        "//Vendors/ios_system:ios_system_api",
    ],
)

macos_command_line_application(
    name = "DrawThingsCLICommandTestRunner",
    testonly = True,
    bundle_id = "com.liuliu.draw-things-cli-tests",
    minimum_os_version = "13.5",
    deps = [
        ":DrawThingsCLICommandTestsLib",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
    ],
)

sh_test(
    name = "DrawThingsCLICommandTests",
    size = "small",
    srcs = ["DrawThingsCLI/Tests/run-tests.sh"],
    args = ["$(location :DrawThingsCLICommandTestRunner)"],
    data = [":DrawThingsCLICommandTestRunner"],
)

swift_test(
    name = "DrawThingsCLIInvocationTests",
    size = "small",
    srcs = ["DrawThingsCLI/Tests/DrawThingsCLIInvocationTests.swift"],
    deps = [
        ":DrawThingsCLILib",
        "//Libraries/CLICloudAuth",
        "//Libraries/Downloader",
        "//Libraries/ImageGenerator",
        "//Libraries/ModelZoo",
        "//Libraries/SwiftDiffusion",
        "@SwiftArgumentParser//:ArgumentParser",
        "@s4nnc//nnc",
    ],
)
