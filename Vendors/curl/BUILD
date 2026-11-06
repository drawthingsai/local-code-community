package(default_visibility = ["//visibility:public"])

exports_files(["ios.patch"])

cc_library(
    name = "config",
    hdrs = ["Config/curl_config.h"],
    includes = ["Config"],
)

# curl's OpenSSL backend includes <openssl/...>; these map it to swift-nio-ssl's
# prefixed BoringSSL, the same copy OpenSSH's shims use.
cc_library(
    name = "boringssl_headers",
    hdrs = glob(["BoringSSL/openssl/*.h"]),
    includes = ["BoringSSL"],
    deps = ["@SwiftNIOSSL//:CNIOBoringSSL"],
)

cc_library(
    name = "port",
    hdrs = ["CurlPort.h"],
    includes = ["."],
    deps = ["//Vendors/ios_system:api"],
)

# The ios_system curl command (curl_main).
objc_library(
    name = "curl",
    srcs = ["CurlMain.c"],
    deps = [
        "//Vendors/ios_system:ios_system_support",
        "@curl//:tool",
    ],
)
