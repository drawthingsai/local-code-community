load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@dflat//:dflat.bzl", "dflatc")

dflatc(
    name = "project_history_schema",
    srcs = [
        "Sources/project_history.fbs",
        "Sources/project_queued_item.fbs",
        "Sources/project_thread.fbs",
    ],
    includes = ["Sources/project_history.fbs"],
)

swift_library(
    name = "ProjectHistoryManager",
    srcs = glob(["Sources/**/*.swift"]) + [
        ":project_history_schema",
    ],
    module_name = "ProjectHistoryManager",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftAlgorithms//:Algorithms",
        "@dflat//:SQLiteDflat",
    ],
)

swift_test(
    name = "ProjectHistoryManagerTests",
    srcs = ["Tests/ProjectHistoryManagerTests.swift"],
    deps = [
        ":ProjectHistoryManager",
        "@dflat//:SQLiteDflat",
    ],
)
