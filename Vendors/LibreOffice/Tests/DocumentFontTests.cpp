// Generated OOXML/ODF corpus and mutations exercise the actual bounded ZIP/XML
// inspector without invoking the engine. No checked-in investigation artifacts.
#include "Vendors/LibreOffice/OfficeCommand.h"
#include <CoreFoundation/CoreFoundation.h>
#include <expat.h>
#include <algorithm>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include <unistd.h>
namespace fs = std::filesystem;
namespace {
struct ConversionError : std::runtime_error {
    std::string code;
    ConversionError(const char* code, const char* error) : std::runtime_error(error), code(code) {}
};
struct OfficeCancelled : std::runtime_error { OfficeCancelled() : std::runtime_error("cancelled") {} };
#include "Vendors/LibreOffice/font-metadata.hpp"
}
#include "Vendors/LibreOffice/document-validation.hpp"

static void require(bool value, const char* message)
{
    if (!value) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}
static void put(std::string& bytes, uint64_t value, unsigned length)
{
    while (length--) { bytes += static_cast<char>(value & 255); value >>= 8; }
}
static std::string archive(const std::vector<std::pair<std::string, std::string>>& entries, bool streamed)
{
    std::string bytes, directory;
    for (const auto& [name, text] : entries) {
        const auto crc = crc32(0, reinterpret_cast<const Bytef*>(text.data()), text.size());
        const auto offset = bytes.size();
        put(bytes, 0x04034b50, 4); put(bytes, 20, 2); put(bytes, streamed ? 8 : 0, 2); put(bytes, 0, 6);
        put(bytes, streamed ? 0 : crc, 4); put(bytes, streamed ? 0 : text.size(), 4); put(bytes, streamed ? 0 : text.size(), 4);
        put(bytes, name.size(), 2); put(bytes, 0, 2); bytes += name; bytes += text;
        if (streamed) { put(bytes, 0x08074b50, 4); put(bytes, crc, 4); put(bytes, text.size(), 4); put(bytes, text.size(), 4); }
        put(directory, 0x02014b50, 4); put(directory, 20, 2); put(directory, 20, 2); put(directory, streamed ? 8 : 0, 2); put(directory, 0, 6);
        put(directory, crc, 4); put(directory, text.size(), 4); put(directory, text.size(), 4);
        put(directory, name.size(), 2); put(directory, 0, 12); put(directory, offset, 4); directory += name;
    }
    const auto offset = bytes.size(); bytes += directory;
    put(bytes, 0x06054b50, 4); put(bytes, 0, 4); put(bytes, entries.size(), 2); put(bytes, entries.size(), 2);
    put(bytes, directory.size(), 4); put(bytes, offset, 4); put(bytes, 0, 2);
    return bytes;
}
static std::string jsonString(const std::string& text)
{
    std::string result = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { result += '\\'; result += c; }
        else if (c < 32) { char escaped[7]; std::snprintf(escaped, sizeof escaped, "\\u%04x", c); result += escaped; }
        else result += c;
    }
    return result + "\"";
}
int main(int argc, char** argv)
{
    // Read-only differential-test host for the pinned upstream inspector.
    if (argc == 6 && !std::strcmp(argv[1], "--inspect")) {
        OfficeCommandContext context{}; DocumentFonts metadata;
        try {
            validateDocument(argv[2], argv[3], std::stoull(argv[4]), std::stoull(argv[5]), &context, metadata);
            std::printf("{\"ok\":true,\"families\":[");
            for (size_t i = 0; i < metadata.families.size(); ++i)
                std::printf("%s%s", i ? "," : "", jsonString(metadata.families[i]).c_str());
            std::printf("],\"points\":[");
            bool first = true;
            for (auto point : metadata.points) { std::printf("%s%u", first ? "" : ",", point); first = false; }
            std::puts("]}");
        } catch (const ConversionError& error) {
            std::printf("{\"ok\":false,\"code\":%s,\"error\":%s}\n", jsonString(error.code).c_str(), jsonString(error.what()).c_str());
        }
        return 0;
    }
    require(argc == 1, "Usage: DocumentFontTests [--inspect FILE FORMAT MAX_ENTRIES MAX_BYTES]");
    require(normalizedFont("ＨＥＬＶＥＴＩＣＡ_ -") == "helvetica", "NFKC/case/separator normalization");
    require(normalizedFont("微软雅黑") == "微软雅黑", "localized family normalization");
    // Byte-at-a-time XML exercises UTF-8 boundaries and rejects partial metadata
    // from damaged parts. XML entities are never fetched or expanded from DTDs.
    for (const auto& xml : {std::string("<r xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:rFonts w:ascii='Helvetica'/><t>中文😀</t></r>"),
                           std::string("<r xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:rFonts w:ascii='Partial'/></broken>"),
                           std::string("<!DOCTYPE r [<!ENTITY external SYSTEM 'file:///etc/passwd'>]><r>&external;</r>")}) {
        FontMetadataParser parser(false); DocumentFonts fonts;
        for (unsigned char byte : xml) parser.feed(&byte, 1);
        parser.finish(fonts);
        if (xml.find("Helvetica") != std::string::npos)
            require(fonts.families == std::vector<std::string>{"Helvetica"} && fonts.points == std::set<uint32_t>{0x4e2d,0x6587,0x1f600}, "streamed Unicode metadata");
        else require(fonts.families.empty() && fonts.points.empty(), "damaged XML/DTD supplied metadata");
    }
    // Sampling saturates within and across XML parts without rejecting input.
    DocumentFonts bounded;
    for (size_t i = 0; i < DocumentFonts::maxFamilies; ++i) bounded.addFamily("Family" + std::to_string(i));
    require(!bounded.truncated && bounded.families.size() == DocumentFonts::maxFamilies, "exact family budget");
    bounded.addFamily("Overflow");
    require(bounded.truncated && !bounded.names.count("overflow"), "family sampling did not stop");
    DocumentFonts another; another.addFamily("Overflow"); bounded.merge(another);
    require(bounded.families.size() == DocumentFonts::maxFamilies, "merge exceeded family budget");
    another = DocumentFonts{};
    another.addFamily(std::string(DocumentFonts::maxFamilyBytes + 1, 'X') + ";Helvetica");
    require(another.truncated && another.families == std::vector<std::string>{"Helvetica"}, "long family was not skipped independently");
    bounded.truncated = false;
    for (uint32_t i = 0; i < DocumentFonts::maxCodePoints; ++i) bounded.addPoint(0x10000 + i);
    require(!bounded.truncated && bounded.points.size() == DocumentFonts::maxCodePoints, "exact code point budget");
    bounded.addPoint(0x20000);
    require(bounded.truncated && !bounded.points.count(0x20000), "code point sampling did not stop");
    another = DocumentFonts{}; another.addPoint(0x20000); bounded.merge(another);
    require(bounded.points.size() == DocumentFonts::maxCodePoints, "merge exceeded code point budget");
    std::string oversized = "<r xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'>";
    for (size_t i = 0; i <= DocumentFonts::maxFamilies; ++i) oversized += "<w:rFonts w:ascii='Family" + std::to_string(i) + "'/>";
    oversized += "</r>";
    DocumentFonts sampled;
    FontMetadataParser parser(false);
    parser.feed(reinterpret_cast<const unsigned char*>(oversized.data()), oversized.size()); parser.finish(sampled);
    require(sampled.truncated && sampled.families.size() == DocumentFonts::maxFamilies, "XML sampling did not saturate");
    // A later part must not restart collection for categories already full.
    const std::string later = "<r xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:rFonts w:ascii='Later'/>later</r>";
    FontMetadataParser laterParser(false, bounded);
    laterParser.feed(reinterpret_cast<const unsigned char*>(later.data()), later.size()); laterParser.finish(bounded);
    require(bounded.truncated && !bounded.names.count("later") && !bounded.points.count('l'), "later part restarted sampling");
    const std::string broken = oversized + "<broken>";
    FontMetadataParser brokenParser(false); DocumentFonts discarded;
    brokenParser.feed(reinterpret_cast<const unsigned char*>(broken.data()), broken.size()); brokenParser.finish(discarded);
    require(!discarded.truncated && discarded.families.empty(), "malformed part published partial sampling");
    char temporary[] = "/tmp/office-font-inspection-XXXXXX";
    const int fd = mkstemp(temporary); require(fd >= 0, "mkstemp"); close(fd);
    struct Cleanup { const char* path; ~Cleanup() { unlink(path); } } cleanup{temporary};
    OfficeCommandContext context{};
    auto inspect = [&](const std::string& bytes, const std::string& kind, uint64_t budget = 1024 * 1024) {
        { std::ofstream file(temporary, std::ios::binary | std::ios::trunc); file.write(bytes.data(), bytes.size()); }
        DocumentFonts fonts;
        validateDocument(temporary, kind, 20000, budget, &context, fonts);
        for (const auto point : fonts.points) require(point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff), "invalid Unicode scalar");
        require(fonts.families.size() <= 16 && fonts.points.size() <= 128, "unbounded metadata");
        return fonts;
    };
    std::vector<std::pair<std::string, std::string>> corpus;
    for (int index = 0; index < 72; ++index) {
        const std::string kind = index % 3 == 0 ? "docx" : index % 3 == 1 ? "xlsx" : "pptx";
        const std::string prefix = kind == "docx" ? "word" : kind == "xlsx" ? "xl" : "ppt";
        const std::string ns = kind == "docx" ? "wordprocessingml" : kind == "xlsx" ? "spreadsheetml" : "drawingml";
        const std::string mime = "application/vnd.openxmlformats-officedocument." + std::string(kind == "docx" ? "wordprocessingml.document.main+xml" : kind == "xlsx" ? "spreadsheetml.sheet.main+xml" : "presentationml.presentation.main+xml");
        const std::string main = prefix + (kind == "docx" ? "/document.xml" : kind == "xlsx" ? "/workbook.xml" : "/presentation.xml");
        const std::string family = "Declared" + std::to_string(index);
        const std::string attr = kind == "docx" ? "<f:rFonts f:ascii='" + family + "; +mj-lt'/>" : kind == "xlsx" ? "<f:name val='" + family + "'/>" : "<f:latin typeface='" + family + "'/>";
        std::string xml = "<r xmlns:f='http://schemas.openxmlformats.org/" + ns + (index % 2 ? "/main" : "/2006/main") + "'>" + attr + "<t>ABC &#x4e2d; &#x1f600;</t></r>";
        // Half the corpus uses UTF-16LE BOM; scalars remain equivalent.
        if (index % 2) { std::string encoded("\xff\xfe", 2); for (unsigned char c : xml) put(encoded, c, 2); xml = std::move(encoded); }
        const auto bytes = archive({{"[Content_Types].xml", mime}, {"_rels/.rels", "<r/>"}, {main, xml},
            {prefix + "/theme/theme1.xml", "<f:latin xmlns:f='http://schemas.openxmlformats.org/drawingml/2006/main' typeface='ExcludedTheme'/>"},
            {prefix + "/fontTable.xml", "<f:rFonts xmlns:f='http://schemas.openxmlformats.org/wordprocessingml/2006/main' f:ascii='ExcludedTable'/>"}}, index % 2);
        const auto fonts = inspect(bytes, kind);
        require(fonts.families == std::vector<std::string>{family}, "generated family mismatch");
        require(fonts.points == std::set<uint32_t>{'A','B','C',0x4e2d,0x1f600}, "generated glyph mismatch");
        corpus.emplace_back(bytes, kind);
    }
    const auto odf = archive({{"mimetype", "application/vnd.oasis.opendocument.text"}, {"META-INF/manifest.xml", "<r/>"},
        {"content.xml", "<r xmlns:f='urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0' f:font-family='&quot;Songti SC&quot;'>中文</r>"}}, false);
    require(inspect(odf, "odt").families == std::vector<std::string>{"Songti SC"}, "ODF family quoting");
    const auto& original = corpus.front().first;
    const auto expected = inspect(original, "docx");
    auto accepts = [&](const std::string& bytes) {
        const auto result = inspect(bytes, "docx");
        require(result.families == expected.families && result.points == expected.points, "compatible ZIP lost metadata");
    };
    accepts(original + "trailing bytes");
    std::string changed = original;
    const auto central = changed.find(std::string("PK\x01\x02", 4));
    require(central != std::string::npos, "missing fixture directory");
    changed[14] ^= 1; changed[central + 16] ^= 2; // Both CRCs may disagree.
    changed[6] ^= 8; changed[18] ^= 4; changed[22] ^= 4; // Local flags/sizes are not authoritative.
    changed[changed.size() - 22 + 12] ^= 64; // Directory-size metadata is not a validity rule.
    accepts(changed);
    changed = original;
    changed[30] ^= 1; // Local name differs from the central-directory name.
    accepts(changed);
    // Stored metadata must obey the actual budget even if its declared size lies.
    changed = original;
    const uint64_t total = little(reinterpret_cast<const unsigned char*>(changed.data() + central + 24), 4);
    std::fill(changed.begin() + central + 24, changed.begin() + central + 28, 0);
    require(total > 0, "nonempty metadata fixture");
    bool limited = false;
    try { inspect(changed, "docx", total - 1); }
    catch (const ConversionError& error) { limited = std::string(error.what()).find("actual") != std::string::npos; }
    require(limited, "actual metadata expansion escaped its budget");
    std::mt19937 random(0x6f666669);
    size_t rejected = 0;
    for (int index = 0; index < 192; ++index) {
        auto [bytes, kind] = corpus[random() % corpus.size()];
        if (index % 3 == 0) bytes.resize(random() % bytes.size());
        else for (int j = 0; j <= index % 7; ++j) bytes[random() % bytes.size()] ^= static_cast<char>(1 + random() % 255);
        try { inspect(bytes, kind); }
        catch (const ConversionError& error) { require(error.code == "invalid-document", "wrong mutation error code"); ++rejected; }
    }
    require(rejected >= 64 && rejected < 192, "expected both rejected truncations and tolerated mutations");
    std::printf("Passed 72 generated OOXML documents, ODF/streamed Unicode metadata, and 192 deterministic ZIP mutations (%zu rejected).\n", rejected);
}
