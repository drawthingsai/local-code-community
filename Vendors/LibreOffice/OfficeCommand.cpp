// Adapted from deepseek-ai/dsh-libreoffice-kit worker.cxx (MPL-2.0),
// revision b19bb73c74ed893b8a5d1716d32df32a113ed31b. See LICENSE.dsh.
#include <cassert>
#include <boost/json/src.hpp>
namespace json = boost::json;
#include <fontconfig/fontconfig.h>
#define LOK_USE_UNSTABLE_API
#include <LibreOfficeKit/LibreOfficeKit.h>
extern "C" LibreOfficeKit* libreofficekit_hook_2(const char*, const char*);
#include "document-operations.hpp"
#include <algorithm>
#include <cmath>
#include <climits>
#include <functional>
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <TargetConditionals.h>
#include <expat.h>
#include <map>
#include <set>
#include <tuple>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif

namespace fs = std::filesystem;
namespace {
struct ConversionError : std::runtime_error {
    const char* code;
    ConversionError(const char* code, const std::string& message) : std::runtime_error(message), code(code) {}
};

#include "font-metadata.hpp"

struct Request {
    DocumentFonts documentFonts;
    json::array missingFonts;
    std::string program, input, output, profile, format = "pdf", sheet;
    bool recalculate = false, render = false;
    std::string sourceHash, displayInput, displayOutput, pages = "all", range, fontFallbacks;
    std::vector<std::string> fontDirectories;
    uint64_t maxInput = 64ULL * 1024 * 1024, maxEntries = 20000, maxUncompressed = 512ULL * 1024 * 1024;
    uint64_t maxPages = 100, maxPixels = 16777216, maxDimension = 8192;
    unsigned int dpi = 144;
    unsigned long long maxOutput = 0;
    unsigned int resolution = 0;
};

std::string jsonString(const std::string& value)
{
    std::string result = "\"";
    for (unsigned char ch : value) {
        if (ch == '"' || ch == '\\') { result += '\\'; result += ch; }
        else if (ch < 32) {
            char escaped[7];
            std::snprintf(escaped, sizeof escaped, "\\u%04x", ch);
            result += escaped;
        } else result += ch;
    }
    return result + '"';
}

unsigned long long positiveInteger(const std::string& text)
{
    if (text.empty() || !std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; }))
        throw std::runtime_error("Expected a positive integer");
    unsigned long long value;
    try { value = std::stoull(text); }
    catch (const std::out_of_range&) { throw std::runtime_error("Integer exceeds 18446744073709551615"); }
    if (value == 0) throw std::runtime_error("Expected a positive integer");
    return value;
}

std::string fileUrl(const std::string& path)
{
    const auto normalized = fs::u8path(path).generic_u8string();
    std::string result = normalized.front() == '/' ? "file://" : "file:///";
    for (unsigned char c : normalized) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '/' || c == ':' || c == '-' || c == '_' || c == '.' || c == '~') result += c;
        else {
            char encoded[4];
            std::snprintf(encoded, sizeof encoded, "%%%02X", c);
            result += encoded;
        }
    }
    return result;
}

void environment(const char* name, const std::string& value)
{
#ifdef _WIN32
    if (_putenv_s(name, value.c_str()) != 0) throw std::runtime_error("Failed to set worker environment");
#else
    if (setenv(name, value.c_str(), 1) != 0) throw std::runtime_error("Failed to set worker environment");
#endif
}

std::string officeError(LibreOfficeKit* office)
{
    char* value = office->pClass->getError(office);
    std::string message = value && *value ? value : "LibreOffice operation failed";
    office->pClass->freeError(value);
    return message;
}

void prepareEnvironment(const Request& request)
{
    fs::create_directories(fs::u8path(request.profile));
    environment("SAL_USE_VCLPLUGIN", "svp");
    environment("SAL_LOK_OPTIONS", "unipoll");
    environment("SAL_DISABLE_OPENCL", "1");
    environment("SAL_ACCESSIBILITY_ENABLED", "0");
    environment("LOK_HOST_ALLOWLIST", "^$");

}

using OfficePtr = std::unique_ptr<LibreOfficeKit, void(*)(LibreOfficeKit*)>;
using DocumentPtr = std::unique_ptr<LibreOfficeKitDocument, void(*)(LibreOfficeKitDocument*)>;

OfficePtr createOffice(const Request& request)
{
    const auto profileUrl = fileUrl(request.profile);
    OfficePtr office(libreofficekit_hook_2(request.program.c_str(), profileUrl.c_str()),
        [](LibreOfficeKit* value) { if (value) value->pClass->destroy(value); });
    if (!office) throw ConversionError("unavailable", "LibreOfficeKit initialization failed");

    return office;
}

DocumentPtr loadDocument(const Request& request, LibreOfficeKit* office)
{
    const auto input = fileUrl(request.input);
    DocumentPtr document(office->pClass->documentLoadWithOptions(office, input.c_str(), "Batch=true,EnableMacrosExecution=false"),
        [](LibreOfficeKitDocument* value) { if (value) value->pClass->destroy(value); });
    if (!document) throw std::runtime_error(officeError(office));
    return document;
}

void line(FILE* output, const std::string& value) { std::fprintf(output, "%s\n", value.c_str()); }
}

#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <cctype>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <chrono>
#include <future>
#include <thread>
#include <pthread.h>
#include "OfficeCommand.h"

namespace {
constexpr const char* officeUsage = R"HELP(Usage:
  office convert --input FILE --output FILE [--sheet NAME]
  office recalculate --input FILE --output FILE
  office render --input FILE --output-dir DIRECTORY [render options]
  office capabilities [--json]
  office --help | -h | help | --version
  office convert|recalculate|render --help

Convert: doc/docx/odt -> pdf, docx, odt, txt (UTF-8, LF)
         xls/xlsx/ods -> pdf, xlsx, ods, csv (UTF-8)
         ppt/pptx/odp -> pdf, pptx, odp
Recalculate: xls/xlsx/ods -> xlsx, ods; preserves formulas.
Render: all these inputs plus PDF -> PNG files in a new directory.
  --pages all|1,3           One-based physical pages/slides; not for Calc.
  --sheet NAME             Exact worksheet name. CSV: required for multiple sheets.
                           Render: default is all visible worksheets.
  --range A1:D20           Calc render only; requires --sheet. Default: data area.
  --dpi N                  Render DPI, 24...600; default 144.
  --max-pages N            Maximum PNG count including sheet tiles; default 100, max 10000.
  --max-pixels N           Pixels per PNG; default and maximum 16777216.
  --max-dimension N        PNG width/height limit; default 8192, maximum 16777216.
Limits (positive integers in bytes unless noted):
  --max-input-bytes N       Default 67108864.
  --max-output-bytes N      Default 134217728; total PNG bytes for render.
  --max-archive-entries N   ZIP entry limit; default 20000.
  --max-uncompressed-bytes N  Declared ZIP bytes / actual metadata bytes; default 536870912.
  --max-image-resolution N  PDF export image DPI, 1...600; default 144.
Fonts:
  --font-directory PATH    Font search directory; repeatable. Replaces system search.
  --font-fallbacks JSON     Ordered arrays of font-family names (at least two each).
  All catalogued fonts are available, including fonts referenced only by themes.
  Font metadata samples at most 4096 families and 65536 distinct code points;
  names over 1024 UTF-8 bytes are skipped. Reaching these limits does not reject
  the document. fontMetadataTruncated reports limited sampling/diagnostics.
  Custom fallback lists allow at most 4096 names, each at most 1024 UTF-8 bytes.
  missingFonts reports absent declared OOXML/ODF families, not engine defaults.
  An empty list does not guarantee complete glyph coverage.

Options are strict --name value pairs, except help/version and capabilities [--json].
Only font-directory may repeat. Unknown options, empty
values, numeric overflow and invalid combinations fail. Existing outputs are
never replaced. Macros are disabled. Legacy doc/xls/ppt require valid OLE headers;
ZIP documents must match their content type and archive limits.
Operations emit one JSON result on stdout, or {ok:false,code,error} on stderr.
Exit: 0 success/help/discovery; 1 failure; 130 cancelled (C ABI misuse: 2).
The engine/profile persist; queued cancellation is immediate, running operations
cancel at phase boundaries. No hard timeout or process crash isolation.
)HELP";

bool informational(int argc, char** argv) noexcept
{
    if (argc < 2) return true;
    const char* option = argv[1];
    return (argc == 2 && (!strcmp(option, "--help") || !strcmp(option, "-h") || !strcmp(option, "help") || !strcmp(option, "--version")))
        || (argc == 3 && (!strcmp(option, "convert") || !strcmp(option, "recalculate") || !strcmp(option, "render"))
            && (!strcmp(argv[2], "--help") || !strcmp(argv[2], "-h")))
        || (!strcmp(option, "capabilities") && (argc == 2 || (argc == 3 && !strcmp(argv[2], "--json"))));
}

struct OfficeScratch {
    fs::path path;
    int lease = -1;
    explicit OfficeScratch(const fs::path& parent, bool runtime = false)
    {
        struct Descriptor { int fd = -1; ~Descriptor() { if (fd >= 0) close(fd); } } lock;
        if (runtime) {
            lock.fd = open((parent / ".office-runtime.lock").c_str(), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (lock.fd < 0 || flock(lock.fd, LOCK_EX)) throw std::runtime_error("Cannot lock office runtime directory");
            // Only reap our leased profiles. A concurrent live host retains its
            // lease; kernel locks also release after a crash or _Exit.
            for (const auto& entry : fs::directory_iterator(parent)) {
                if (entry.path().filename().string().rfind(".office-runtime-", 0) != 0
                    || !fs::is_directory(entry.symlink_status())) continue;
                Descriptor owner{open((entry.path() / ".owner").c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC)};
                if (owner.fd >= 0 && flock(owner.fd, LOCK_EX | LOCK_NB) == 0) {
                    std::error_code error;
                    fs::remove_all(entry.path(), error);
                }
            }
        }
        auto pattern = (parent / (runtime ? ".office-runtime-XXXXXX" : ".office-XXXXXX")).string();
        if (!mkdtemp(pattern.data())) throw std::runtime_error("Cannot create private working directory");
        path = pattern;
        if (runtime) {
            lease = open((path / ".owner").c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
            if (lease < 0 || flock(lease, LOCK_EX | LOCK_NB)) {
                if (lease >= 0) close(lease);
                std::error_code error; fs::remove_all(path, error);
                throw std::runtime_error("Cannot lease office runtime directory");
            }
        }
    }
    ~OfficeScratch()
    {
        std::error_code error;
        fs::remove_all(path, error);
        if (lease >= 0) close(lease);
    }
};

std::string extension(const fs::path& path)
{
    auto value = path.extension().string();
    if (!value.empty()) value.erase(0, 1);
    std::transform(value.begin(), value.end(), value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

struct OfficeCancelled : std::runtime_error {
    OfficeCancelled() : std::runtime_error("Office command cancelled") {}
};

void officePhase(const OfficeCommandContext* context, const char* phase)
{
    if (context && context->phase) context->phase(phase, context->phaseContext);
    if (context && context->isCancelled && context->isCancelled(context->cancellation))
        throw OfficeCancelled();
}

}
#include "document-validation.hpp"
namespace {
// Intentionally retained until process exit. Destroying a document is supported;
// destroying and recreating the whole engine between requests is not our model.
struct OfficeFonts;
struct OfficeRuntime {
    OfficeFonts* fontState = nullptr; // Owned for the same process lifetime as the engine.
    OfficeScratch scratch;
    std::string program, temporary, fontConfiguration, profile;
    std::vector<std::string> fonts;
    OfficePtr office;
    explicit OfficeRuntime(const OfficeCommandContext& context)
        : scratch(context.temporaryDirectory, true), program(context.programDirectory),
          temporary(context.temporaryDirectory),
          fontConfiguration(context.fontConfiguration ? context.fontConfiguration : ""), office(nullptr, [](LibreOfficeKit* value) {
              if (value) value->pClass->destroy(value);
          })
    {
        Request request;
        request.program = program;
        profile = request.profile = (scratch.path / "profile").string();
        fs::create_directories(fs::path(request.profile) / "user");
        std::ofstream profile(fs::path(request.profile) / "user/registrymodifications.xcu");
        profile << "<?xml version=\"1.0\"?><oor:items xmlns:oor=\"http://openoffice.org/2001/registry\">"
            "<item oor:path=\"/org.openoffice.Office.Calc/Input\"><prop oor:name=\"WarnActiveSheet\" oor:op=\"fuse\">"
            "<value>false</value></prop></item></oor:items>\n";
        profile.close();
        if (!profile) throw std::runtime_error("Cannot write engine profile");
        for (size_t i = 0; i < context.fontFileCount; ++i) {
            fonts.emplace_back(context.fontFiles[i]);
            if (!fs::is_regular_file(fonts.back())) throw std::runtime_error("Font is not a regular file");
        }
        prepareEnvironment(request);
    }
};

OfficeRuntime* officeRuntime = nullptr;
std::exception_ptr officeInitializationFailure;

#include "font-operations.hpp"

json::array convertWithOffice(const Request& request, LibreOfficeKit* office,
    const OfficeCommandContext* context)
{
    auto document = loadDocument(request, office);
    officePhase(context, "loaded");
    if (request.recalculate) {
        dsh::recalculate(office, document.get());
        officePhase(context, "recalculated");
    }
    if (request.format == "csv")
        dsh::selectCsvSheet(office, document.get(), request.sheet.empty() ? nullptr : request.sheet.c_str());
    const auto options = std::string("{\"ReduceImageResolution\":{\"type\":\"boolean\",\"value\":\"true\"},\"MaxImageResolution\":{\"type\":\"long\",\"value\":\"")
        + std::to_string(request.resolution) + "\"},\"ExportBookmarks\":{\"type\":\"boolean\",\"value\":\"true\"}}";
    const auto output = fileUrl(request.output);
    if (!document->pClass->saveAs(document.get(), output.c_str(), request.format.c_str(),
        request.format == "pdf" ? options.c_str() : request.format == "txt" ? "UTF8,LF" : nullptr))
        throw std::runtime_error(officeError(office));
    officePhase(context, "saved");
    if (fs::file_size(request.output) > request.maxOutput)
        throw ConversionError("output-too-large", "Output exceeds maxOutputBytes");
    char header[5] = {};
    std::ifstream(request.output, std::ios::binary).read(header, sizeof header);
    if (request.format == "pdf" && std::memcmp(header, "%PDF-", sizeof header) != 0)
        throw ConversionError("invalid-output", "LibreOffice did not produce PDF bytes");
    if ((request.format == "docx" || request.format == "xlsx" || request.format == "pptx"
        || request.format == "odt" || request.format == "ods" || request.format == "odp")
        && std::memcmp(header, "PK\003\004", 4))
        throw ConversionError("invalid-output", "LibreOffice did not produce an Office ZIP container");
    document.reset();
    officePhase(context, "closed");
    return request.missingFonts;
}

#include "render-operations.hpp"

std::string officeCommand(int argc, char** argv, const OfficeCommandContext* context)
{
    const std::string operation = argv[1];
    if (operation != "convert" && operation != "recalculate" && operation != "render")
        throw std::runtime_error("Expected convert, recalculate or render; use --help");
    Request request;
    request.recalculate = operation == "recalculate";
    request.render = operation == "render";
    request.maxOutput = 128ULL * 1024 * 1024;
    request.resolution = 144;
    std::vector<std::string> seen;
    for (int i = 2; i < argc; i += 2) {
        if (i + 1 == argc) throw std::runtime_error("Missing option value");
        const std::string option = argv[i], value = argv[i + 1];
        if (value.empty()) throw std::runtime_error("Empty option value: " + option);
        if (option != "--font-directory"
            && std::find(seen.begin(), seen.end(), option) != seen.end())
            throw std::runtime_error("Repeated option: " + option);
        seen.push_back(option);
        if (option == "--input") request.input = value;
        else if (option == "--output" && !request.render) request.output = value;
        else if (option == "--sheet") request.sheet = value;
        else if (option == "--output-dir" && request.render) request.output = value;
        else if (option == "--max-input-bytes") request.maxInput = positiveInteger(value);
        else if (option == "--max-archive-entries") request.maxEntries = positiveInteger(value);
        else if (option == "--max-uncompressed-bytes") request.maxUncompressed = positiveInteger(value);
        else if (option == "--font-directory") request.fontDirectories.push_back(value);
        else if (option == "--font-fallbacks") request.fontFallbacks = value;
        else if (option == "--pages" && request.render) request.pages = value;
        else if (option == "--range" && request.render) request.range = value;
        else if (option == "--max-pages" && request.render) request.maxPages = positiveInteger(value);
        else if (option == "--max-pixels" && request.render) request.maxPixels = positiveInteger(value);
        else if (option == "--max-dimension" && request.render) request.maxDimension = positiveInteger(value);
        else if (option == "--dpi" && request.render) {
            auto dpi = positiveInteger(value);
            if (dpi < 24 || dpi > 600) throw std::runtime_error("--dpi must be 24...600");
            request.dpi = static_cast<unsigned int>(dpi);
        }
        else if (option == "--max-output-bytes") request.maxOutput = positiveInteger(value);
        else if (option == "--max-image-resolution") {
            const auto dpi = positiveInteger(value);
            if (dpi > 600) throw std::runtime_error("Image resolution must be 1...600");
            request.resolution = static_cast<unsigned int>(dpi);
        } else throw std::runtime_error("Unknown option: " + option);
    }
    if (request.input.empty() || request.output.empty())
        throw std::runtime_error(request.render ? "--input and --output-dir are required" : "--input and --output are required");
    request.displayInput = context->inputPath ? context->inputPath : request.input;
    request.displayOutput = context->outputPath ? context->outputPath : request.output;
    request.program = context->programDirectory;
    if (fs::path(request.input).is_relative())
        request.input = (fs::path(context->directory) / request.input).string();
    if (fs::path(request.output).is_relative())
        request.output = (fs::path(context->directory) / request.output).string();
    const auto input = fs::canonical(request.input);
    auto output = fs::absolute(request.output).lexically_normal();
    output = fs::canonical(output.parent_path()) / output.filename();
    if (fs::exists(fs::symlink_status(output))) throw std::runtime_error("Output already exists");
    if (!fs::is_regular_file(input) || fs::file_size(input) == 0)
        throw ConversionError("invalid-document", "Input must be a nonempty regular file");
    if (fs::file_size(input) > request.maxInput)
        throw ConversionError("input-too-large", "Input exceeds --max-input-bytes");
    const auto inputFormat = extension(input);
    request.format = extension(output);
    const std::vector<std::pair<std::vector<std::string>, std::vector<std::string>>> formats = {
        {{"doc", "docx", "odt"}, {"pdf", "docx", "odt", "txt"}},
        {{"xls", "xlsx", "ods"}, {"pdf", "xlsx", "ods", "csv"}},
        {{"ppt", "pptx", "odp"}, {"pdf", "pptx", "odp"}},
    };
    bool supported = false;
    for (const auto& family : formats)
        if (std::find(family.first.begin(), family.first.end(), inputFormat) != family.first.end()
            && std::find(family.second.begin(), family.second.end(), request.format) != family.second.end())
            supported = true;
    if (request.render) supported = inputFormat == "pdf" || std::any_of(formats.begin(), formats.end(), [&](const auto& family) {
        return std::find(family.first.begin(), family.first.end(), inputFormat) != family.first.end();
    });
    if (!supported) throw ConversionError("unsupported-format", "Unsupported conversion: " + inputFormat + " -> " + request.format);
    const bool calc = inputFormat == "xls" || inputFormat == "xlsx" || inputFormat == "ods";
    if (request.render && ((calc && std::find(seen.begin(), seen.end(), "--pages") != seen.end())
        || (!calc && (!request.sheet.empty() || !request.range.empty())) || (!request.range.empty() && request.sheet.empty())))
        throw std::runtime_error("Worksheets use --sheet and --range; other inputs use --pages. --range requires --sheet");
    if (request.maxPages > 10000 || request.maxPixels > 16777216 || request.maxDimension > 16777216)
        throw std::runtime_error("Render limits exceed --help bounds");
    if (request.recalculate && ((inputFormat != "xls" && inputFormat != "xlsx" && inputFormat != "ods")
        || (request.format != "xlsx" && request.format != "ods")))
        throw std::runtime_error("Recalculation requires XLS/XLSX/ODS input and XLSX/ODS output");
    if (!request.sheet.empty() && !request.render && (request.recalculate || request.format != "csv"))
        throw std::runtime_error("--sheet is only supported for CSV conversion");
    request.program = fs::canonical(request.program).string();
    if (!fs::is_directory(request.program)) throw std::runtime_error("Program resources must be a directory");

    OfficeScratch scratch(output.parent_path());
    request.input = (scratch.path / ("input." + inputFormat)).string();
    {
        std::ifstream source(input, std::ios::binary);
        std::ofstream copy(request.input, std::ios::binary);
        std::array<char, 65536> buffer;
        uint64_t total = 0;
        CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
        while (source) {
            source.read(buffer.data(), buffer.size());
            const auto count = static_cast<uint64_t>(source.gcount());
            if (count > request.maxInput - total) throw ConversionError("input-too-large", "Input exceeds --max-input-bytes while copying");
            total += count;
            CC_SHA256_Update(&hash, buffer.data(), static_cast<CC_LONG>(count));
            copy.write(buffer.data(), count);
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        }
        if (!source.eof() || !copy || !total) throw ConversionError("invalid-document", "Cannot copy input document");
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &hash);
        const char* hex = "0123456789abcdef";
        for (auto byte : digest) { request.sourceHash += hex[byte >> 4]; request.sourceHash += hex[byte & 15]; }
    }
    if (inputFormat == "pdf") {
        char header[5]{};
        std::ifstream(request.input, std::ios::binary).read(header, sizeof header);
        if (memcmp(header, "%PDF-", 5)) throw ConversionError("invalid-document", "PDF input must start with %PDF-");
    } else validateDocument(request.input, inputFormat, request.maxEntries, request.maxUncompressed, context, request.documentFonts);
    request.output = (scratch.path / ("output." + request.format)).string();
    officePhase(context, "prepared");
    if (officeInitializationFailure) std::rethrow_exception(officeInitializationFailure);
    if (!officeRuntime) {
        try { officeRuntime = new OfficeRuntime(*context); }
        catch (...) {
            // LibreOffice owns a singleton; retrying partial initialization is
            // unsafe. Preserve the failure for this process rather than recreating.
            officeInitializationFailure = std::current_exception();
            throw;
        }
    }
    if (officeRuntime->program != context->programDirectory
        || officeRuntime->temporary != context->temporaryDirectory
        || officeRuntime->fontConfiguration != (context->fontConfiguration ? context->fontConfiguration : ""))
        throw std::runtime_error("Office runtime configuration cannot change after initialization");
    if (officeRuntime->fonts.size() != context->fontFileCount)
        throw std::runtime_error("Office runtime fonts cannot change after initialization");
    for (size_t i = 0; i < context->fontFileCount; ++i)
        if (officeRuntime->fonts[i] != context->fontFiles[i])
            throw std::runtime_error("Office runtime fonts cannot change after initialization");
    officePhase(context, "runtime-ready");
    configureFonts(request, *officeRuntime, context);
    if (request.render) return renderImages(request, output, scratch.path, officeRuntime->office.get(), context);
    const auto missingFonts = convertWithOffice(request, officeRuntime->office.get(), context);
    if (!fs::is_regular_file(request.output) || fs::file_size(request.output) == 0)
        throw std::runtime_error("Engine produced no output");
    if (chmod(request.output.c_str(), 0600) != 0) throw std::runtime_error("Cannot set output permissions");
    // Same-volume, exclusive publication: an intervening output creation cannot be overwritten.
    if (link(request.output.c_str(), output.c_str()) != 0)
        throw std::runtime_error("Cannot publish output (destination may already exist)");
    return "{\"ok\":true,\"backend\":\"native\",\"outputPath\":" + jsonString(request.displayOutput) + ",\"missingFonts\":" + json::serialize(missingFonts)
        + ",\"fontMetadataTruncated\":" + (request.documentFonts.truncated ? "true" : "false") + "}";
}
}

namespace {
// Error reporting must also survive failures while allocating the JSON message.
void reportError(FILE* output, const char* message, const char* code = "failed") noexcept
{
    try {
        line(output, "{\"ok\":false,\"code\":" + jsonString(code) + ",\"error\":" + jsonString(message) + "}");
    } catch (...) {
        std::fputs("{\"ok\":false,\"code\":\"failed\",\"error\":\"Unknown Office exception\"}\n", output);
    }
}

int executeCommand(int argc, char** argv, const OfficeCommandContext* context)
{
    try {
        if (informational(argc, argv)) {
            const std::string command = argc > 1 ? argv[1] : "";
            if (command == "--version") std::fputs("office 26.8.0.3 (native SVP)\n", context->output);
            else if (command == "capabilities") std::fputs(officeCapabilities, context->output);
            else std::fputs(officeUsage, context->output);
        } else {
            for (const char* path : {context->directory, context->programDirectory, context->temporaryDirectory})
                if (!path || !fs::path(path).is_absolute()) throw std::runtime_error("Host paths must be absolute");
            officePhase(context, "admitted");
            line(context->output, officeCommand(argc, argv, context));
        }
        return 0;
    } catch (const OfficeCancelled& error) {
        reportError(context->error ? context->error : context->output, error.what(), "cancelled");
        return 130;
    } catch (const ConversionError& error) {
        reportError(context->error ? context->error : context->output, error.what(), error.code);
        return 1;
    } catch (const std::exception& error) {
        reportError(context->error ? context->error : context->output, error.what());
        return 1;
    } catch (...) {
        reportError(context->error ? context->error : context->output, "Unknown Office exception");
        return 1;
    }
}

// Process-lifetime state, like LibreOffice itself. All engine operations run on
// this one thread: a serial mutex on migrating callers can deadlock SVP DoYield.
class OfficeOwner {
    std::mutex mutex;
    std::condition_variable ready;
    struct Pending {
        std::packaged_task<int()> task;
        bool running = false; // Protected by mutex, together with queue membership.
        explicit Pending(std::packaged_task<int()> task) : task(std::move(task)) {}
    };
    std::deque<std::shared_ptr<Pending>> requests;
    pthread_t thread;

    static void* run(void* opaque)
    {
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, nullptr);
        pthread_setname_np("office");
        auto& owner = *static_cast<OfficeOwner*>(opaque);
        for (;;) {
            std::shared_ptr<Pending> request;
            {
                std::unique_lock<std::mutex> lock(owner.mutex);
                owner.ready.wait(lock, [&] { return !owner.requests.empty(); });
                request = std::move(owner.requests.front());
                owner.requests.pop_front();
                request->running = true;
            }
            request->task();
        }
    }
public:
    OfficeOwner()
    {
        pthread_attr_t attributes;
        int error = pthread_attr_init(&attributes);
        if (error) throw std::runtime_error("Cannot initialize Office thread attributes");
        error = pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
        if (!error) error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (!error) error = pthread_create(&thread, &attributes, run, this);
        pthread_attr_destroy(&attributes);
        if (error) throw std::runtime_error("Cannot create Office owner thread");
    }
    int submit(int argc, char** argv, const OfficeCommandContext* context)
    {
        // Hooks are not allowed to reenter: returning an error avoids waiting on
        // a request queued behind the operation executing that very hook.
        if (pthread_equal(pthread_self(), thread)) return 2;
        auto request = std::make_shared<Pending>(
            std::packaged_task<int()>([=] { return executeCommand(argc, argv, context); }));
        auto result = request->task.get_future();
        {
            std::lock_guard<std::mutex> lock(mutex);
            requests.push_back(request);
        }
        ready.notify_one();
        while (result.wait_for(std::chrono::milliseconds(50)) != std::future_status::ready) {
            std::unique_lock<std::mutex> lock(mutex);
            if (request->running || !context->isCancelled) continue;
            // The owner cannot claim this request while we poll. Removing it
            // before returning (including on callback exceptions) guarantees
            // that no borrowed pointers can be used after the caller returns.
            bool cancelled;
            try {
                cancelled = context->isCancelled(context->cancellation);
            } catch (...) {
                requests.erase(std::find(requests.begin(), requests.end(), request));
                throw;
            }
            if (cancelled) {
                requests.erase(std::find(requests.begin(), requests.end(), request));
                lock.unlock();
                reportError(context->error ? context->error : context->output, "Office command cancelled", "cancelled");
                return 130;
            }
        }
        return result.get();
    }
};
}

extern "C" int OfficeCommandRun(int argc, char** argv, const OfficeCommandContext* context)
{
    if (argc < 0 || (argc && !argv) || !context || !context->output) return 2;
    for (int i = 0; i < argc; ++i) if (!argv[i]) return 2;
    if (informational(argc, argv)) return executeCommand(argc, argv, context);
    if (!context->directory || !context->programDirectory || !context->temporaryDirectory) return 2;
    if (context->fontFileCount && !context->fontFiles) return 2;
    for (size_t i = 0; i < context->fontFileCount; ++i) if (!context->fontFiles[i]) return 2;
    int previousCancellation;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previousCancellation);
    int status = 1;
    try {
        static OfficeOwner* owner = new OfficeOwner;
        status = owner->submit(argc, argv, context);
    } catch (const std::exception& error) {
        reportError(context->error ? context->error : context->output, error.what());
    } catch (...) {
        reportError(context->error ? context->error : context->output, "Unknown Office exception");
    }
    // The caller owns streams, arguments and cancellation state until completion.
    // Never unwind a waiting caller while the engine still uses those pointers.
    pthread_setcancelstate(previousCancellation, nullptr);
    return status;
}
