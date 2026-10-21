load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

package(default_visibility = ["//visibility:public"])

swift_library(
    name = "PDFTextExtractor",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "PDFTextExtractor",
    deps = ["//Vendors/PDFInspector:api"],
)
