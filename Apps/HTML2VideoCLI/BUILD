load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary", "swift_library")

swift_library(
    name = "HTML2VideoCLILib",
    srcs = ["HTML2VideoCLI.swift"],
    module_name = "HTML2VideoCLILib",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/HTMLVideoExporter",
        "@SwiftArgumentParser//:ArgumentParser",
    ],
)

swift_library(
    name = "HTML2VideoCommand",
    srcs = ["IOSSystem/HTML2VideoCommand.swift"],
    module_name = "HTML2VideoCommand",
    visibility = ["//visibility:public"],
    deps = [
        ":HTML2VideoCLILib",
        "//Vendors/ios_system:ios_system_api",
    ],
)

swift_binary(
    name = "html2video",
    srcs = ["Executable/Main.swift"],
    visibility = ["//visibility:public"],
    deps = [":HTML2VideoCLILib"],
)
