load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

package(default_visibility = ["//visibility:public"])

exports_files(["YTDLP/Tests/embedded.py"])

config_setting(
    name = "macos_build",
    constraint_values = [
        "@platforms//os:osx",
    ],
)

config_setting(
    name = "catalyst_build",
    constraint_values = [
        "@build_bazel_apple_support//constraints:catalyst",
    ],
)

config_setting(
    name = "ios_simulator_arm64",
    # Apple rules can select Simulator without an explicit ios_multi_cpus flag.
    constraint_values = [
        "@platforms//os:ios",
        "@platforms//cpu:arm64",
        "@build_bazel_apple_support//constraints:simulator",
    ],
)

objc_library(
    name = "HFXet",
    hdrs = ["HFXetHeaders/hf_xet.h"],
    includes = ["HFXetHeaders"],
    module_name = "HFXet",
)

apple_static_xcframework_import(
    name = "PythonFramework",
    linkopts = [
        "-Wl,-u,_ios_python_register_numpy",
        "-Wl,-u,_ios_python_register_pandas",
        "-Wl,-u,_ios_python_register_pillow",
        "-Wl,-u,_ios_python_register_cairosvg",
        "-Wl,-u,_ios_python_register_lxml",
        "-Wl,-u,_ios_python_register_matplotlib",
        "-Wl,-u,_ios_python_register_psd_tools",
        "-Wl,-u,_ios_python_register_hf_xet",
        "-Wl,-u,_hf_xet_download_start",
        "-Wl,-u,_hf_xet_download_cancel",
        "-Wl,-u,_hf_xet_download_release",
        "-Wl,-u,_ios_python_register_safetensors",
        "-Wl,-u,_ios_python_register_regex",
        "-Wl,-u,_ios_python_register_tokenizers",
        "-Wl,-u,_ios_python_register_sentencepiece",
    ] + select({
        ":ios_simulator_arm64": [],
        "//conditions:default": [
            "-Wl,-u,_ios_python_register_mlx",
        ],
    }),
    sdk_dylibs = [
        "c++",
        "iconv",
        "sqlite3",
        "z",
    ] + select({
        ":macos_build": [
            "bz2",
            "edit",
            "ffi",
            "ncurses",
            "panel",
        ],
        "//conditions:default": [],
    }),
    sdk_frameworks = [
        "Accelerate",
        "CoreFoundation",
        "CoreGraphics",
        "CoreText",
        "Security",
        "SystemConfiguration",
    ] + select({
        ":ios_simulator_arm64": [],
        "//conditions:default": [
            "Foundation",
            "Metal",
            "QuartzCore",
        ],
    }),
    xcframework_imports = glob(["Frameworks/Python.xcframework/**"]),
    deps = [
        "@sentencepiece//:sentencepiece_train",
    ],
)

apple_static_xcframework_import(
    name = "CurlCFFI",
    sdk_dylibs = [
        "c++",
        "icucore",
        "z",
    ],
    sdk_frameworks = [
        "Security",
        "SystemConfiguration",
    ],
    xcframework_imports = glob(["Frameworks/CurlCFFI.xcframework/**"]),
)

genrule(
    name = "CurlCFFICatalystObject",
    srcs = ["Frameworks/CurlCFFI.xcframework/macos-arm64/libCurlCFFI.a"],
    outs = ["CurlCFFICatalyst.o"],
    cmd = "$(location :replatform_curl_cffi_for_catalyst.sh) " +
          "$(location Frameworks/CurlCFFI.xcframework/macos-arm64/libCurlCFFI.a) " +
          "$@ 16.0 $(location :replatform_macho_for_catalyst.py)",
    tools = [
        ":replatform_curl_cffi_for_catalyst.sh",
        ":replatform_macho_for_catalyst.py",
    ],
)

objc_library(
    name = "CurlCFFICatalyst",
    srcs = [":CurlCFFICatalystObject"],
    sdk_dylibs = [
        "c++",
        "icucore",
        "z",
    ],
    sdk_frameworks = [
        "Security",
        "SystemConfiguration",
    ],
)

genrule(
    name = "PythonCatalystObject",
    srcs = ["Frameworks/Python.xcframework/macos-arm64/libpython3.14-macos.a"],
    outs = ["PythonCatalyst.o"],
    cmd = "$(location :replatform_python_for_catalyst.sh) " +
          "$(location Frameworks/Python.xcframework/macos-arm64/libpython3.14-macos.a) " +
          "$@ 16.0 $(location :replatform_macho_for_catalyst.py)",
    tools = [
        ":replatform_macho_for_catalyst.py",
        ":replatform_python_for_catalyst.sh",
    ],
)

exports_files([
    "replatform_curl_cffi_for_catalyst.sh",
    "replatform_macho_for_catalyst.py",
    "replatform_python_for_catalyst.sh",
])

objc_library(
    name = "PythonCatalyst",
    srcs = [":PythonCatalystObject"],
    hdrs = glob(["Frameworks/Python.xcframework/macos-arm64/Headers/**"]),
    includes = ["Frameworks/Python.xcframework/macos-arm64/Headers"],
    linkopts = [
        "-Wl,-u,_ios_python_register_numpy",
        "-Wl,-u,_ios_python_register_pandas",
        "-Wl,-u,_ios_python_register_pillow",
        "-Wl,-u,_ios_python_register_cairosvg",
        "-Wl,-u,_ios_python_register_lxml",
        "-Wl,-u,_ios_python_register_matplotlib",
        "-Wl,-u,_ios_python_register_psd_tools",
        "-Wl,-u,_ios_python_register_hf_xet",
        "-Wl,-u,_ios_python_register_safetensors",
        "-Wl,-u,_ios_python_register_regex",
        "-Wl,-u,_ios_python_register_tokenizers",
        "-Wl,-u,_ios_python_register_sentencepiece",
        "-Wl,-u,_ios_python_register_mlx",
    ],
    sdk_dylibs = [
        "bz2",
        "c++",
        "edit",
        "ffi",
        "iconv",
        "ncurses",
        "panel",
        "sqlite3",
        "z",
    ],
    sdk_frameworks = [
        "Accelerate",
        "CoreFoundation",
        "CoreGraphics",
        "CoreText",
        "Foundation",
        "Metal",
        "QuartzCore",
        "Security",
        "SystemConfiguration",
    ],
    deps = [
        "@sentencepiece//:sentencepiece_train",
    ],
)

objc_library(
    name = "PythonRuntimeAPI",
    hdrs = ["python_runtime.h"],
    includes = ["."],
)

objc_library(
    name = "PythonRuntime",
    srcs = ["python_runtime.c"],
    deps = [":PythonRuntimeAPI"] + select({
        ":catalyst_build": [
            ":CurlCFFICatalyst",
            ":PythonCatalyst",
        ],
        "//conditions:default": [
            ":CurlCFFI",
            ":PythonFramework",
        ],
    }),
    alwayslink = True,
)

apple_resource_group(
    name = "PythonResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(
        ["Resources/Library/**"],
        exclude = [
            "Resources/Library/lib/python3.14/site-packages/mlx/**",
            "Resources/Library/lib/python3.14/site-packages/mlx-*.dist-info/**",
        ],
    ) + select({
        ":ios_simulator_arm64": [],
        "//conditions:default": glob([
            "Resources/Library/lib/python3.14/site-packages/mlx/**",
            "Resources/Library/lib/python3.14/site-packages/mlx-*.dist-info/**",
        ]),
    }),
)

apple_resource_group(
    name = "PythonResourcesMacOS",
    strip_structured_resources_prefixes = ["ResourcesMacOS"],
    structured_resources = glob(["ResourcesMacOS/Library/**"]),
)

filegroup(
    name = "PythonResourcesMacOSFiles",
    srcs = glob(["ResourcesMacOS/Library/**"]),
    visibility = ["//visibility:public"],
)
