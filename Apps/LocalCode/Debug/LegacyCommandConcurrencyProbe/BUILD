load("@build_bazel_rules_apple//apple:macos.bzl", "macos_command_line_application")

objc_library(
    name = "probe_main",
    srcs = ["main.m"],
    sdk_frameworks = ["Foundation"],
    deps = [
        "//Vendors/ios_system",
        "//Vendors/ios_system:registry_api",
    ],
)

macos_command_line_application(
    name = "LegacyCommandConcurrencyProbe",
    bundle_id = "com.liuliu.legacy-command-concurrency-probe",
    minimum_os_version = "13.5",
    deps = [
        ":probe_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)
