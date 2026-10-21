load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Nuke",
    srcs = glob(
        [
            "Sources/Nuke/**/*.swift",
            "Sources/Nuke/*.swift",
        ],
    ),
    module_name = "Nuke",
    visibility = ["//visibility:public"],
)

swift_library(
    name = "NukeExtensions",
    srcs = glob(
        [
            "Sources/NukeExtensions/*.swift",
        ],
    ),
    module_name = "Nuke",
    visibility = ["//visibility:public"],
    deps = [
        ":Nuke",
    ],
)

swift_library(
    name = "NukeUI",
    srcs = glob(
        [
            "Sources/NukeUI/*.swift",
        ],
    ),
    module_name = "NukeUI",
    visibility = ["//visibility:public"],
    deps = [
        ":Nuke",
    ],
)

swift_library(
    name = "NukeVideo",
    srcs = glob(
        [
            "Sources/NukeVideo/**/*.swift",
        ],
    ),
    module_name = "NukeVideo",
    visibility = ["//visibility:public"],
    deps = [
        ":Nuke",
    ],
)
