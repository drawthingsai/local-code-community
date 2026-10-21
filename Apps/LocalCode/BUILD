load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_command_line_application")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary", "swift_library", "swift_test")
load("@rules_xcodeproj//xcodeproj:defs.bzl", "top_level_target", "xcodeproj")

exports_files([
    "Sources/Agent/DeepSeekTextGenerator.swift",
    "Sources/Agent/TextGenerator.swift",
    "Sources/Models/ContextCache.swift",
    "Sources/Models/DeepSeek4_1ContextCache.swift",
    "Sources/Models/DeepSeek4_1TextGenerator.swift",
    "Sources/Models/DeepSeek4_1EngramCache.swift",
    "Sources/Models/DeepSeek4_1Image.swift",
])

xcodeproj(
    name = "xcodeproj",
    # Preserve host CMake and Python discovery for FFmpeg, including Xcode builds.
    bazel_env = {"PATH": None},
    project_name = "LocalCode",
    tags = ["manual"],
    top_level_targets = [
        top_level_target(
            ":LocalCode",
            target_environments = [
                "device",
                "simulator",
            ],
        ),
        top_level_target(":LocalCodeCLI"),
        top_level_target(":QwenAIME25EvalCLI"),
        top_level_target(":ContextCacheProbe"),
        top_level_target(":DeepSeek4ContextCacheProbe"),
        top_level_target(":AgentSchedulerHarness"),
        top_level_target(
            ":StaticInlinePython",
            target_environments = [
                "device",
                "simulator",
            ],
        ),
        top_level_target(
            ":StaticInlineNode",
            target_environments = [
                "device",
                "simulator",
            ],
        ),
        top_level_target(
            ":StaticInlineLean",
            target_environments = [
                "device",
                "simulator",
            ],
        ),
    ],
    xcode_configurations = {
        "Debug": {
            "//command_line_option:copt": ["-O0"],
            "//command_line_option:swiftcopt": ["-Onone"],
        },
        "Debug-Optimized": {
            "//command_line_option:copt": ["-O3"],
            "//command_line_option:swiftcopt": ["-O"],
        },
    },
)

apple_resource_group(
    name = "mathFontsResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(["Resources/mathFonts.bundle/**"]),
)

apple_resource_group(
    name = "NodeMobileRuntimeResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(["Resources/NodeMobile/Runtime/**"]),
)

apple_resource_group(
    name = "BuiltInSkillsResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(["Resources/Skills/**"]),
)

apple_resource_group(
    name = "BrowserRuntimeResources",
    strip_structured_resources_prefixes = ["Resources"],
    structured_resources = glob(["Resources/Browser/**"]),
)

ios_application(
    name = "LocalCode",
    additional_linker_inputs = ["@SwiftCrypto//:CCryptoBoringSSL"],
    app_icons = glob(
        [
            "Resources/AppIcon.icon/**",
            "Resources/AppIcon.xcassets/**",
        ],
        exclude = ["**/.DS_Store"],
    ),
    bundle_id = "com.liuliu.local-code",
    entitlements = "SupportingFiles/LocalCode.entitlements",
    families = [
        "iphone",
        "ipad",
    ],
    include_symbols_in_bundle = True,
    infoplists = ["SupportingFiles/Info.plist"],
    launch_storyboard = "SupportingFiles/LaunchScreen.storyboard",
    # The Swift linking provider omits this C archive when UserAccount is the
    # only consumer. PrivacyPassClient's CryptoExtras module needs its symbols.
    linkopts = [
        "-force_load",
        "$(location @SwiftCrypto//:CCryptoBoringSSL)",
    ],
    minimum_os_version = "16.0",
    provisioning_profile = "ProvisioningFiles/LocalCode_Development.mobileprovision",
    # LocalCode consumes the common committed iOS Python resources on device
    # and simulator; platform-specific native code stays in XCFramework slices.
    # Native command runtimes are linked directly into the app executable.
    # All slices use the same static stdlib extension-module policy.
    resources = glob(
        ["Resources/**"],
        exclude = [
            "Resources/mathFonts.bundle/**",
            "Resources/NodeMobile/Runtime/**",
            "Resources/Skills/**",
            "Resources/Browser/**",
            "Resources/WizAppIcon.xcassets/**",
            "**/.DS_Store",
        ],
    ) + [
        ":BrowserRuntimeResources",
        ":BuiltInSkillsResources",
        ":NodeMobileRuntimeResources",
        ":mathFontsResources",
        "//Vendors/FFmpeg:notices",
        "//Vendors/Lean:LeanRuntimeResources",
        "//Vendors/Madrid:Madrid-LICENSE.txt",
        "//Vendors/NodeJS:NodeCommandResources",
        "//Vendors/PythonIOS:PythonResources",
        "//Vendors/ios_system:native_command_notices",
    ],
    sdk_frameworks = [
        "Accelerate",
        "Metal",
        "MetalPerformanceShaders",
        "MetalPerformanceShadersGraph",
        "Security",
        "UserNotifications",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":LocalCodeFeatures",
        ":LocalCodeLib",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
        "@SwiftCrypto//:CCryptoBoringSSL",
    ],
)

objc_library(
    name = "StaticInlinePythonMain",
    srcs = ["StaticInlinePython/main.m"],
    deps = [
        "//Vendors/ios_system:ios_system_api",
    ],
)

ios_application(
    name = "StaticInlinePython",
    bundle_id = "com.liuliu.local-code",
    families = [
        "iphone",
        "ipad",
    ],
    include_symbols_in_bundle = True,
    infoplists = ["StaticInlinePython/Info.plist"],
    minimum_os_version = "16.0",
    provisioning_profile = "ProvisioningFiles/LocalCode_Development.mobileprovision",
    resources = [
        "//Vendors/FFmpeg:notices",
        "//Vendors/Madrid:Madrid-LICENSE.txt",
        "//Vendors/PythonIOS:PythonResources",
        "//Vendors/PythonIOS:YTDLP/Tests/embedded.py",
        "//Vendors/ios_system:native_command_notices",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":StaticInlinePythonMain",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
    ],
)

objc_library(
    name = "StaticInlineNodeMain",
    srcs = ["StaticInlineNode/main.m"],
    deps = ["//Vendors/NodeJS:NodeMobile"],
)

objc_library(
    name = "StaticInlineNodeIOSSystemMain",
    srcs = ["StaticInlineNode/ios_system_main.m"],
    deps = [
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/ios_system:ios_system_api",
    ],
)

ios_application(
    name = "StaticInlineNode",
    bundle_id = "com.liuliu.local-code",
    families = [
        "iphone",
        "ipad",
    ],
    include_symbols_in_bundle = True,
    infoplists = ["StaticInlineNode/Info.plist"],
    minimum_os_version = "16.0",
    provisioning_profile = "ProvisioningFiles/LocalCode_Development.mobileprovision",
    resources = [":NodeMobileRuntimeResources"],
    visibility = ["//visibility:public"],
    deps = [":StaticInlineNodeMain"],
)

objc_library(
    name = "StaticInlineLeanMain",
    srcs = ["StaticInlineLean/main.m"],
    deps = [
        "//Vendors/Lean:LeanBridge",
        "//Vendors/Lean:LeanResources",
    ],
)

ios_application(
    name = "StaticInlineLean",
    bundle_id = "com.liuliu.local-code",
    families = [
        "iphone",
        "ipad",
    ],
    include_symbols_in_bundle = True,
    infoplists = ["StaticInlineLean/Info.plist"],
    minimum_os_version = "16.0",
    provisioning_profile = "ProvisioningFiles/LocalCode_Development.mobileprovision",
    resources = ["//Vendors/Lean:LeanRuntimeResources"],
    visibility = ["//visibility:public"],
    deps = [":StaticInlineLeanMain"],
)

macos_command_line_application(
    name = "StaticInlineLeanMacOS",
    bundle_id = "com.liuliu.local-code.static-inline-lean",
    minimum_os_version = "13.5",
    visibility = ["//visibility:public"],
    deps = [":StaticInlineLeanMain"],
)

macos_command_line_application(
    name = "StaticInlineNodeMacOS",
    bundle_id = "com.liuliu.local-code.static-inline-node",
    minimum_os_version = "13.5",
    visibility = ["//visibility:public"],
    deps = [":StaticInlineNodeMain"],
)

macos_command_line_application(
    name = "StaticInlineNodeIOSSystemMacOS",
    bundle_id = "com.liuliu.local-code.static-inline-node-ios-system",
    minimum_os_version = "13.5",
    visibility = ["//visibility:public"],
    deps = [
        ":StaticInlineNodeIOSSystemMain",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
    ],
)

sh_test(
    name = "StaticInlineNodeIOSSystemTests",
    size = "small",
    srcs = ["StaticInlineNode/Fixtures/run-ios-system-node-test.sh"],
    data = glob(["Resources/NodeMobile/Runtime/*.cjs"]) + [
        ":StaticInlineNodeIOSSystemMacOS",
        "//Vendors/NodeJS:NodeCommandArchive",
    ],
)

sh_test(
    name = "StaticInlineNodeVirtualChildTests",
    size = "small",
    srcs = ["StaticInlineNode/Fixtures/run-virtual-node-child-test.sh"],
    data = glob([
        "Resources/NodeMobile/Runtime/*.cjs",
        "StaticInlineNode/Fixtures/virtual-node-child-*.js",
    ]) + [
        ":StaticInlineNodeMacOS",
    ],
)

macos_command_line_application(
    name = "StaticInlinePythonMacOS",
    bundle_id = "com.liuliu.local-code.static-inline-python",
    minimum_os_version = "13.5",
    visibility = ["//visibility:public"],
    deps = [
        ":StaticInlinePythonMain",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
    ],
)

sh_test(
    name = "StaticInlineNodeProcessPolicyTests",
    size = "small",
    srcs = ["StaticInlineNode/Fixtures/run-process-policy-test.sh"],
    data = glob(["Resources/NodeMobile/Runtime/*.cjs"]) + [
        "StaticInlineNode/Fixtures/process-policy.js",
        ":StaticInlineNodeMacOS",
        ":StaticInlinePythonMacOS",
    ],
)

objc_library(
    name = "LocalCodeFeatures",
    srcs = ["Sources/Features/main.m"],
)

swift_library(
    name = "LocalCodeCore",
    srcs = glob(["Shared/**/*.swift"]),
    module_name = "LocalCodeCore",
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_test(
    name = "ChatAttachmentTests",
    srcs = ["Sources/Chat/Input/ChatAttachment.swift"] + glob(["Tests/ChatAttachmentTests/**/*.swift"]),
)

swift_test(
    name = "ModelIdleTimerTests",
    srcs = ["Sources/Agent/ModelIdleTimer.swift"] + glob(["Tests/ModelIdleTimerTests/**/*.swift"]),
)

swift_test(
    name = "OnboardingStateTests",
    srcs = ["Sources/Onboarding/OnboardingState.swift"] + glob(["Tests/OnboardingStateTests/**/*.swift"]),
    deps = ["//Libraries/RemoteAPI"],
)

swift_test(
    name = "RemoteCredentialStoreTests",
    srcs = ["Sources/RemoteAPI/RemoteCredentialStore.swift"] + glob(["Tests/RemoteCredentialStoreTests/**/*.swift"]),
    deps = [
        "//Libraries/Localization",
        "//Libraries/RemoteAPI",
    ],
)

swift_test(
    name = "LocalPathResolverTests",
    srcs = [
        "Sources/LocalPathResolver.swift",
        "Sources/Resources.swift",
    ] + glob(["Tests/LocalPathResolverTests/**/*.swift"]),
)

swift_test(
    name = "ContainerProtectionTests",
    srcs = ["Sources/ContainerProtection.swift"] + glob(["Tests/ContainerProtectionTests/**/*.swift"]),
)

swift_test(
    name = "PermittedDirectoriesTests",
    srcs = ["Sources/PermittedDirectories.swift"] + glob(["Tests/PermittedDirectoriesTests/**/*.swift"]),
    deps = ["@dflat//:SQLiteDflat"],
)

swift_test(
    name = "HuggingFaceXetMetadataTests",
    srcs = [
        "Sources/Downloader/HuggingFaceXetMetadata.swift",
    ] + glob(["Tests/HuggingFaceXetMetadataTests/**/*.swift"]),
)

swift_test(
    name = "SkillCatalogTests",
    srcs = [
        "Sources/Agent/SkillCatalog.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
    ] + glob(["Tests/SkillCatalogTests/**/*.swift"]),
    data = glob(["Resources/Skills/**"]),
    deps = ["@Yams"],
)

py_test(
    name = "MathlibInstallerTests",
    srcs = ["Tests/SkillCatalogTests/test_mathlib_installer.py"],
    data = ["Resources/Skills/check_lean-and-lean-tools/scripts/install_mathlib.py"],
    main = "Tests/SkillCatalogTests/test_mathlib_installer.py",
)

objc_library(
    name = "MathlibInstallValidationMain",
    srcs = ["Tests/SkillCatalogTests/MathlibInstallValidation.m"],
    deps = [
        "//Vendors/Lean:LeanCommand",
        "//Vendors/ios_system",
    ],
)

macos_command_line_application(
    name = "MathlibInstallValidation",
    bundle_id = "com.liuliu.local-code.mathlib-install-validation",
    minimum_os_version = "13.5",
    tags = ["manual"],
    deps = [
        ":MathlibInstallValidationMain",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

sh_test(
    name = "LeanSkillExamplesTests",
    timeout = "long",
    srcs = ["//Vendors/Lean:Tests/run-command-tests.sh"],
    args = [
        "$(location //Vendors/Lean:LeanCommandValidation)",
        "$(location //Vendors/Lean:Lean_Init_Std.zip)",
        "$(location //Vendors/Lean:lean-symbols.txt)",
        "$(location Resources/Skills/check_lean-and-lean-tools/SKILL.md)",
    ],
    data = [
        "Resources/Skills/check_lean-and-lean-tools/SKILL.md",
        "//Vendors/Lean:LeanCommandValidation",
        "//Vendors/Lean:Lean_Init_Std.json",
        "//Vendors/Lean:Lean_Init_Std.zip",
        "//Vendors/Lean:lean-symbols.txt",
    ],
)

swift_test(
    name = "SystemPromptTemplateTests",
    srcs = [
        "Sources/Agent/SystemPromptTemplate.swift",
    ] + glob(["Tests/SystemPromptTemplateTests/**/*.swift"]),
    deps = ["@Yams"],
)

swift_test(
    name = "AccountClientTests",
    srcs = [
        "Sources/Account/AccountClient.swift",
    ] + glob(["Tests/AccountClientTests/**/*.swift"]),
    deps = ["//Libraries/Localization"],
)

swift_test(
    name = "EnvironmentContextTests",
    srcs = [
        "Sources/Agent/EnvironmentContext.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
    ] + glob(["Tests/EnvironmentContextTests/**/*.swift"]),
)

swift_test(
    name = "ProjectMemoryTests",
    srcs = [
        "Sources/Agent/MemoryContext.swift",
        "Sources/Agent/MemoryTool.swift",
        "Sources/Agent/ProjectContext.swift",
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
    ] + glob(["Tests/ProjectMemoryTests/**/*.swift"]),
    deps = [
        "//Libraries/Localization",
        "//Libraries/ProjectHistoryManager",
    ],
)

swift_test(
    name = "TemplateZooTests",
    srcs = [
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Settings/TemplateZoo.swift",
    ] + glob(["Tests/TemplateZooTests/**/*.swift"]),
    deps = ["//Vendors/ZIPFoundation"],
)

swift_test(
    name = "ProjectContextTests",
    srcs = [
        "Sources/Agent/EnvironmentContext.swift",
        "Sources/Agent/MemoryContext.swift",
        "Sources/Agent/ProjectContext.swift",
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Agent/SkillCatalog.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/RemoteAPI/RemoteSystemPrompt.swift",
    ] + glob(["Tests/ProjectContextTests/**/*.swift"]),
    deps = [
        "//Libraries/ProjectHistoryManager",
        "@Yams",
    ],
)

swift_test(
    name = "SystemPromptSectionTests",
    srcs = [
        "Sources/Agent/MemoryContext.swift",
        "Sources/Agent/ProjectContext.swift",
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Agent/SystemPromptSection.swift",
        "Sources/Agent/SystemPromptTokenization.swift",
        "Sources/Agent/ToolCallParser.swift",
    ] + glob(["Tests/SystemPromptSectionTests/**/*.swift"]),
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/Tokenizer",
    ],
)

swift_test(
    name = "ShellCommandParserTests",
    srcs = [
        "Sources/Agent/ShellCommandParser.swift",
    ] + glob(["Tests/ShellCommandParserTests/**/*.swift"]),
)

swift_test(
    name = "ToolCallParserTests",
    srcs = [
        "Sources/Agent/DeepSeek4ToolCallParser.swift",
        "Sources/Agent/Qwen3_5ToolCallParser.swift",
        "Sources/Agent/ToolCallParser.swift",
    ] + glob(["Tests/ToolCallParserTests/**/*.swift"]),
    deps = ["//Libraries/SwiftLLM"],
)

swift_test(
    name = "CheckSmtToolTests",
    srcs = [
        "Sources/Agent/CheckSmtTool.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
    ] + glob(["Tests/CheckSmtToolTests/**/*.swift"]),
    deps = [
        "//Libraries/Localization",
        "//Vendors/Z3:Z3Bridge",
    ],
)

swift_test(
    name = "DeepSeek4TranscriptTests",
    srcs = [
        "Sources/Agent/AgentTranscript.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Compact.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Parse.swift",
        "Sources/Agent/DeepSeek4ToolCallParser.swift",
        "Sources/Agent/ToolCallParser.swift",
    ] + glob(["Tests/DeepSeek4TranscriptTests/**/*.swift"]),
    deps = [
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
    ],
)

swift_test(
    name = "DeepSeek4ContextCacheTests",
    srcs = [
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
    ] + glob(["Tests/DeepSeek4ContextCacheTests/**/*.swift"]),
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_test(
    name = "FileToolsTests",
    srcs = [
        "Sources/Agent/DeepSeek4ToolCallParser.swift",
        "Sources/Agent/FileTools.swift",
        "Sources/Agent/Qwen3_5ToolCallParser.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
        "Sources/LocalPathResolver.swift",
        "Sources/Resources.swift",
    ] + glob(["Tests/FileToolsTests/**/*.swift"]),
    deps = [
        "//Libraries/BashToolContext",
        "//Libraries/Localization",
        "//Libraries/PDFTextExtractor",
        "//Libraries/SwiftLLM",
        "//Vendors/Ripgrep:api",
        "//Vendors/Ripgrep:search",
    ],
)

swift_library(
    name = "LocalCodeLib",
    srcs = glob(
        ["Sources/**/*.swift"],
    ),
    module_name = "LocalCode",
    deps = [
        "//Apps:DrawThingsCLICommand",
        "//Apps/HTML2VideoCLI:HTML2VideoCommand",
        "//Apps/HyperFramesCLI:HyperFramesCommand",
        "//Libraries/AppleUtilities",
        "//Libraries/BashToolContext",
        "//Libraries/BinaryResources",
        "//Libraries/CLICloudAuth",
        "//Libraries/Components",
        "//Libraries/DataModels",
        "//Libraries/Downloader",
        "//Libraries/History:TextHistory",
        "//Libraries/ImageGenerator",
        "//Libraries/LocalImageGenerator",
        "//Libraries/Localization",
        "//Libraries/ModelZoo",
        "//Libraries/PDFTextExtractor",
        "//Libraries/PrivacyPassClient",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/RemoteAPI",
        "//Libraries/SFMT",
        "//Libraries/Style",
        "//Libraries/UserAccount",
        "//Libraries/WebSearch",
        "//Vendors/Advance",
        "//Vendors/ExceptionCatcher",
        "//Vendors/FBShimmer",
        "//Vendors/Lean:LeanCommand",
        "//Vendors/Nuke",
        "//Vendors/PythonIOS:HFXet",
        "//Vendors/Ripgrep:api",
        "//Vendors/Ripgrep:search",
        "//Vendors/SnapKit",
        "//Vendors/SwiftMarkdownEngine:MarkdownEngine",
        "//Vendors/SwiftMarkdownEngine:MarkdownEngineCodeBlocks",
        "//Vendors/SwiftMarkdownEngine:MarkdownEngineLatex",
        "//Vendors/Z3:Z3Bridge",
        "//Vendors/Z3:Z3Command",
        "//Vendors/ZIPFoundation",
        "//Vendors/ios_system:ios_system_api",
        "@Lottie",
        "@SwiftArgumentParser//:ArgumentParser",
        "@Yams",
        "@dflat//:SQLiteDflat",
        "@swift-atomics//:SwiftAtomics",
    ],
)

swift_binary(
    name = "BrowserAPIProbe",
    srcs = [
        "Sources/Agent/BashTools.swift",
        "Sources/Agent/ShellCommandParser.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
        "Sources/Browser/BrowserCommand.swift",
        "Sources/Browser/BrowserSession.swift",
        "Sources/Browser/BrowserTab.swift",
        "Sources/LocalPathResolver.swift",
        "Sources/Resources.swift",
        "Tests/BrowserAPITests/BrowserAPITests.swift",
        "Tests/BrowserAPITests/BrowserBashTests.swift",
    ],
    deps = [
        "//Libraries/BashToolContext",
        "//Libraries/Localization",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/WebSearch",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
        "@SwiftArgumentParser//:ArgumentParser",
        "@swift-atomics//:SwiftAtomics",
    ],
)

sh_test(
    name = "BrowserAPITests",
    size = "small",
    srcs = ["Tests/BrowserAPITests/run-tests.sh"],
    args = [
        "$(location :BrowserAPIProbe)",
        "$(location Resources/Browser/browser-client.js)",
        "$(location Tests/BrowserAPITests/fixture.html)",
    ],
    data = glob(["Resources/Browser/**"]) + [
        "Tests/BrowserAPITests/archive.zip",
        "Tests/BrowserAPITests/fixture.html",
        "Tests/BrowserAPITests/popup.html",
        ":BrowserAPIProbe",
    ],
    # WKWebView needs the host's WebKit and LaunchServices processes.
    tags = [
        "local",
        "no-sandbox",
        "requires-darwin",
    ],
)

swift_binary(
    name = "MonkeyAnimationTests",
    srcs = [
        "Sources/Downloader/MonkeyAnimation.swift",
        "Tests/MonkeyAnimationTests.swift",
    ],
)

swift_test(
    name = "BashUserInteractionTests",
    srcs = [
        "Sources/Agent/BashTools.swift",
        "Sources/Agent/ShellCommandParser.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
        "Sources/LocalPathResolver.swift",
        "Sources/Resources.swift",
    ] + glob(["Tests/BashUserInteractionTests/**/*.swift"]),
    discover_tests = False,
    deps = [
        "//Libraries/BashToolContext",
        "//Libraries/Localization",
        "//Libraries/ProjectHistoryManager",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/ios_system",
        "@build_bazel_rules_swift//tools/test_observer",
        "@swift-atomics//:SwiftAtomics",
    ],
)

swift_library(
    name = "LocalCodeCLILib",
    srcs = glob(
        ["CLI/**/*.swift"],
        exclude = ["CLI/LocalCodeMain.swift"],
    ) + [
        "Sources/Agent/AgentTranscript.swift",
        "Sources/Agent/BashTools.swift",
        "Sources/Agent/CheckSmtTool.swift",
        "Sources/Agent/CodeAgent.swift",
        "Sources/Agent/DeepSeek4CodeAgent.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Compact.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Parse.swift",
        "Sources/Agent/DeepSeek4ToolCallParser.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/EnvironmentContext.swift",
        "Sources/Agent/EnvironmentContext+Detection.swift",
        "Sources/Agent/FileTools.swift",
        "Sources/Agent/MemoryContext.swift",
        "Sources/Agent/MemoryTool.swift",
        "Sources/Agent/ProjectContext.swift",
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Agent/Qwen3_5CodeAgent.swift",
        "Sources/Agent/Qwen3_5CodeAgent+Compact.swift",
        "Sources/Agent/Qwen3_5CodeAgent+Parse.swift",
        "Sources/Agent/Qwen3_5ToolCallParser.swift",
        "Sources/Agent/ShellCommandParser.swift",
        "Sources/Agent/SkillCatalog.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
        "Sources/Agent/SystemPromptTemplate.swift",
        "Sources/Agent/SystemPromptTokenization.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
        "Sources/Agent/ToolsRegistry.swift",
        "Sources/Agent/ViewTool.swift",
        "Sources/LocalPathResolver.swift",
        "Sources/ModelSpeed/DeepSeek4Speedometer.swift",
        "Sources/ModelSpeed/Qwen3_5Speedometer.swift",
        "Sources/ModelSpeed/Speedometer.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
        "Sources/Models/DeepSeek4_1ContextCache.swift",
        "Sources/Models/DeepSeek4_1EngramCache.swift",
        "Sources/Models/DeepSeek4_1Image.swift",
        "Sources/Models/DeepSeek4_1TextGenerator.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
        "Sources/NodeMobileCommandResources.swift",
        "Sources/RemoteAPI/RemoteCredentialStore.swift",
        "Sources/RemoteAPI/RemoteSystemPrompt.swift",
        "Sources/RemoteAPI/RemoteToolSchema.swift",
        "Sources/RemoteAPI/RemoteToolsBridge.swift",
        "Sources/Resources.swift",
    ],
    module_name = "LocalCodeCLI",
    visibility = ["//Apps/LocalCode:__subpackages__"],
    deps = [
        ":LocalCodeCore",
        "//Apps:DrawThingsCLICommand",
        "//Apps/HTML2VideoCLI:HTML2VideoCommand",
        "//Apps/HyperFramesCLI:HyperFramesCommand",
        "//Libraries/AppleUtilities",
        "//Libraries/BashToolContext",
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/Downloader",
        "//Libraries/ImageGenerator",
        "//Libraries/Localization",
        "//Libraries/ModelZoo",
        "//Libraries/PDFTextExtractor",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/RemoteAPI",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "//Libraries/WebSearch",
        "//Vendors/Lean:LeanCommand",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/Ripgrep:api",
        "//Vendors/Ripgrep:search",
        "//Vendors/Z3:Z3Bridge",
        "//Vendors/Z3:Z3Command",
        "//Vendors/ZIPFoundation",
        "//Vendors/ios_system",
        "@SwiftArgumentParser//:ArgumentParser",
        "@Yams",
        "@s4nnc//nnc",
        "@swift-atomics//:SwiftAtomics",
    ],
)

swift_library(
    name = "LocalCodeCLIEntryPoint",
    srcs = ["CLI/LocalCodeMain.swift"],
    deps = [
        ":LocalCodeCLILib",
        "@SwiftArgumentParser//:ArgumentParser",
    ],
)

swift_binary(
    name = "LocalCodeCLI",
    srcs = [],
    data = glob([
        "Resources/Skills/**",
        "Resources/NodeMobile/Runtime/**",
    ]) + [
        "//Apps/HyperFramesCLI:RuntimeFiles",
        "//Vendors/Lean:LeanRuntimeArchive",
        "//Vendors/LibreOffice:resources_macos_files",
        "//Vendors/NodeJS:NodeCommandArchive",
        "//Vendors/PythonIOS:PythonResourcesMacOSFiles",
    ],
    visibility = ["//visibility:public"],
    deps = [":LocalCodeCLIEntryPoint"],
)

swift_test(
    name = "CLIParityTests",
    srcs = glob(["Tests/CLIParityTests/**/*.swift"]),
    data = glob([
        "Resources/Skills/**",
        "Resources/NodeMobile/Runtime/**",
    ]) + [
        "//Apps/HyperFramesCLI:RuntimeFiles",
        "//Vendors/Lean:LeanRuntimeArchive",
        "//Vendors/LibreOffice:resources_macos_files",
        "//Vendors/NodeJS:NodeCommandArchive",
        "//Vendors/PythonIOS:PythonResourcesMacOSFiles",
    ],
    discover_tests = False,
    # Authentication tests use an isolated Keychain account through securityd.
    tags = ["no-sandbox"],
    deps = [
        ":LocalCodeCLILib",
        "//Libraries/ModelZoo",
        "//Libraries/RemoteAPI",
        "//Vendors/ios_system:ios_system_api",
        "@SwiftArgumentParser//:ArgumentParser",
        "@build_bazel_rules_swift//tools/test_observer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "QwenAIME25EvalCLI",
    srcs = [
        "Eval/QwenAIME25EvalCLI.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "QwenLongBenchV2EvalCLI",
    srcs = [
        "Eval/QwenLongBenchV2EvalCLI.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "TextGeneratorUnloadProbe",
    testonly = True,
    srcs = [
        "Debug/TextGeneratorUnloadProbe.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "ContextCacheProbe",
    srcs = [
        "Debug/ContextCacheProbe.swift",
        "Sources/Agent/Qwen3_5ToolCallParser.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "DeepSeek4ContextCacheProbe",
    srcs = [
        "Debug/DeepSeek4ContextCacheProbe.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "QwenPrefillSpeedProbe",
    srcs = [
        "Debug/QwenPrefillSpeedProbe.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/ModelSpeed/Qwen3_5Speedometer.swift",
        "Sources/ModelSpeed/Speedometer.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
        "@swift-atomics//:SwiftAtomics",
    ],
)

swift_binary(
    name = "PrefillWarmupProbe",
    srcs = [
        "Debug/PrefillWarmupProbe.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ModelZoo",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "DeepSeek4GeneratorProbe",
    srcs = [
        "Debug/DeepSeek4GeneratorProbe.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Apps:DrawThingsCLILib",
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "AgentSchedulerHarness",
    srcs = [
        "Debug/AgentSchedulerHarness.swift",
        "Sources/Agent/AgentScheduler.swift",
        "Sources/Agent/AgentTranscript.swift",
        "Sources/Agent/BashTools.swift",
        "Sources/Agent/CheckSmtTool.swift",
        "Sources/Agent/CodeAgent.swift",
        "Sources/Agent/DeepSeek4CodeAgent.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Compact.swift",
        "Sources/Agent/DeepSeek4CodeAgent+Parse.swift",
        "Sources/Agent/DeepSeek4ToolCallParser.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/EnvironmentContext.swift",
        "Sources/Agent/FileTools.swift",
        "Sources/Agent/MemoryContext.swift",
        "Sources/Agent/MemoryTool.swift",
        "Sources/Agent/ProjectContext.swift",
        "Sources/Agent/ProjectMemory.swift",
        "Sources/Agent/ShellCommandParser.swift",
        "Sources/Agent/SkillCatalog.swift",
        "Sources/Agent/SystemPrompt.swift",
        "Sources/Agent/SystemPromptSection.swift",
        "Sources/Agent/SystemPromptTokenization.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Agent/ToolCallParser.swift",
        "Sources/Agent/ToolSubtitleMoment.swift",
        "Sources/Agent/ToolsRegistry.swift",
        "Sources/Agent/ViewTool.swift",
        "Sources/LocalPathResolver.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
        "Sources/Models/Qwen3_5ContextCache.swift",
        "Sources/Models/Qwen3_5Image.swift",
        "Sources/Models/Qwen3_5TextGenerator.swift",
        "Sources/Resources.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/AppleUtilities",
        "//Libraries/BashToolContext",
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/Downloader",
        "//Libraries/ImageGenerator",
        "//Libraries/Localization",
        "//Libraries/ModelZoo",
        "//Libraries/PDFTextExtractor",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SFMT",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "//Libraries/WebSearch",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
        "//Vendors/Ripgrep:api",
        "//Vendors/Ripgrep:search",
        "//Vendors/Z3:Z3Bridge",
        "//Vendors/ios_system",
        "@Yams",
        "@dflat//:SQLiteDflat",
        "@s4nnc//nnc",
        "@swift-atomics//:SwiftAtomics",
    ],
)

swift_binary(
    name = "DeepSeek4AIME25EvalCLI",
    srcs = [
        "Debug/DeepSeek4AIME25EvalCLI.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_binary(
    name = "DeepSeek4LiveCodeBenchV6EvalCLI",
    srcs = [
        "Debug/DeepSeek4LiveCodeBenchV6EvalCLI.swift",
        "Sources/Agent/DeepSeekTextGenerator.swift",
        "Sources/Agent/TextGenerator.swift",
        "Sources/Models/ContextCache.swift",
        "Sources/Models/DeepSeek4ContextCache.swift",
        "Sources/Models/DeepSeek4TextGenerator.swift",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "//Libraries/BinaryResources",
        "//Libraries/DataModels",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftDiffusion",
        "//Libraries/SwiftLLM",
        "//Libraries/Tokenizer",
        "@s4nnc//nnc",
    ],
)

swift_test(
    name = "Qwen3_5MultimodalTests",
    srcs = glob(["Tests/Qwen3_5MultimodalTests/**/*.swift"]),
    discover_tests = False,
    tags = [
        "manual",
        "requires-gpu",
    ],
    deps = [
        ":LocalCodeCLILib",
        "//Libraries/BashToolContext",
        "//Libraries/ProjectHistoryManager",
        "//Libraries/SwiftLLM",
        "@build_bazel_rules_swift//tools/test_observer",
        "@s4nnc//nnc",
    ],
)
