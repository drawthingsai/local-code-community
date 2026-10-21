// Bounded Office-container inspection before handing a document to LibreOffice.
// Policy follows the pinned dsh entry/document.ts and entry/ooxml.ts: count
// every directory entry, but only decode selected XML/metadata. Native reads
// stay in bounds, and actual streamed metadata has its own expansion budget.
#include <array>
#include <limits>
#include <set>
#include <zlib.h>

namespace {
void invalidDocument(const char* message)
{
    throw ConversionError("invalid-document", message);
}

uint64_t little(const unsigned char* p, size_t bytes)
{
    uint64_t value = 0;
    for (size_t i = 0; i < bytes; ++i) value |= uint64_t(p[i]) << (i * 8);
    return value;
}

// Match fflate's Latin-1 names without the UTF-8 flag and TextDecoder's
// replacement behavior with it. Names are not filesystem paths or extracted.
std::string zipEntryName(const unsigned char* bytes, size_t size, bool utf8)
{
    std::string name;
    for (size_t i = 0; i < size;) {
        const unsigned char c = bytes[i];
        if (!utf8 || c < 128) {
            if (c >= 128) { name += static_cast<char>(0xc0 | (c >> 6)); name += static_cast<char>(0x80 | (c & 63)); }
            else name += static_cast<char>(c);
            ++i; continue;
        }
        const size_t length = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
        size_t valid = 1;
        while (length && valid < length && i + valid < size) {
            const auto next = bytes[i + valid];
            if (next < 0x80 || next > 0xbf || (valid == 1 && ((c == 0xe0 && next < 0xa0)
                || (c == 0xed && next > 0x9f) || (c == 0xf0 && next < 0x90) || (c == 0xf4 && next > 0x8f)))) break;
            ++valid;
        }
        if (length && valid == length) name.append(reinterpret_cast<const char*>(bytes + i), length);
        else name += "\xef\xbf\xbd";
        i += valid;
    }
    // TextDecoder removes an initial UTF-8 BOM.
    if (utf8 && name.compare(0, 3, "\xef\xbb\xbf") == 0) name.erase(0, 3);
    return name;
}

void validateDocument(const std::string& path, const std::string& format,
    uint64_t maxEntries, uint64_t maxUncompressed, const OfficeCommandContext* context, DocumentFonts& metadata)
{
    const uint64_t size = fs::file_size(path);
    std::ifstream file(path, std::ios::binary);
    auto read = [&](uint64_t offset, size_t count) {
        if (offset > size || count > size - offset
            || offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())
            || count > static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max())) invalidDocument("Truncated Office container");
        std::vector<unsigned char> data(count);
        file.clear();
        file.seekg(static_cast<std::streamoff>(offset));
        if (!file.read(reinterpret_cast<char*>(data.data()), count)) invalidDocument("Cannot read Office container");
        return data;
    };
    if (format == "doc" || format == "xls" || format == "ppt") {
        const auto h = read(0, 512);
        const unsigned char signature[] = {0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1};
        const auto version = little(h.data() + 26, 2), shift = little(h.data() + 30, 2);
        if (memcmp(h.data(), signature, 8) || little(h.data() + 28, 2) != 0xfffe
            || little(h.data() + 32, 2) != 6
            || !((version == 3 && shift == 9) || (version == 4 && shift == 12))
            || size < (uint64_t(1) << shift) * 2 || size % (uint64_t(1) << shift))
            invalidDocument("Invalid or truncated OLE compound-file header");
        return;
    }
    const bool odf = format == "odt" || format == "ods" || format == "odp";
    const std::string main = odf ? "content.xml" : format == "docx" ? "word/document.xml"
        : format == "xlsx" ? "xl/workbook.xml" : "ppt/presentation.xml";
    const std::string mime = odf ? "application/vnd.oasis.opendocument." + std::string(
        format == "odt" ? "text" : format == "ods" ? "spreadsheet" : "presentation")
        : "application/vnd.openxmlformats-officedocument." + std::string(format == "docx"
            ? "wordprocessingml.document.main+xml" : format == "xlsx"
            ? "spreadsheetml.sheet.main+xml" : "presentationml.presentation.main+xml");
    // fflate searches backwards for EOCD without requiring its comment length
    // to reach EOF. In particular, trailing bytes are not an integrity failure.
    const auto tail = read(size > 65558 ? size - 65558 : 0, static_cast<size_t>(std::min<uint64_t>(size, 65558)));
    if (tail.size() < 22) invalidDocument("Missing ZIP directory");
    size_t end = tail.size() - 22;
    while (little(tail.data() + end, 4) != 0x06054b50) {
        if (!end) invalidDocument("Missing ZIP directory");
        --end;
    }
    const auto* e = tail.data() + end;
    uint64_t count = little(e + 8, 2), directory = little(e + 16, 4);
    const uint64_t endOffset = size - tail.size() + end;
    if ((count == 0xffff || directory == 0xffffffff) && endOffset >= 20) {
        const auto locator = read(endOffset - 20, 20);
        const uint64_t offset = little(locator.data() + 8, 8);
        if (offset <= size && size - offset >= 56) {
            const auto z = read(offset, 56);
            if (little(z.data(), 4) == 0x06064b50) {
                count = little(z.data() + 32, 8);
                directory = little(z.data() + 48, 8);
            }
        }
    }
    if (count > maxEntries) invalidDocument("ZIP exceeds --max-archive-entries");
    std::set<std::string> names;
    uint64_t position = directory, declared = 0, actual = 0;
    bool contentType = false;
    for (uint64_t index = 0; index < count; ++index) {
        if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        // Directory values are authoritative, as in fflate. Signatures, CRCs,
        // disk fields and disagreements with the local header are not policed.
        const auto h = read(position, 46);
        const auto flags = little(h.data() + 8, 2), method = little(h.data() + 10, 2);
        uint64_t compressed = little(h.data() + 20, 4), expanded = little(h.data() + 24, 4), offset = little(h.data() + 42, 4);
        const auto nameSize = little(h.data() + 28, 2), extraSize = little(h.data() + 30, 2), commentSize = little(h.data() + 32, 2);
        const auto fields = read(position + 46, nameSize + extraSize + commentSize);
        const auto name = zipEntryName(fields.data(), nameSize, flags & 2048);
        if (!names.insert(name).second) invalidDocument("ZIP repeats an entry name");
        position += 46 + fields.size();
        const bool xml = odf ? name == "content.xml" || name == "styles.xml" :
            (name.rfind("word/", 0) == 0 || name.rfind("xl/", 0) == 0 || name.rfind("ppt/", 0) == 0)
            && name.size() >= 4 && name.compare(name.size() - 4, 4, ".xml") == 0
            && name.find("/theme/") == std::string::npos
            && !(name.size() >= 14 && name.compare(name.size() - 14, 14, "/fontTable.xml") == 0);
        const bool type = name == (odf ? "mimetype" : "[Content_Types].xml");
        const bool selected = xml || type || (odf && name == "META-INF/manifest.xml");
        if (expanded == 0xffffffff || (selected && (compressed == 0xffffffff || offset == 0xffffffff))) {
            bool found = false;
            for (size_t p = nameSize; p + 4 <= nameSize + extraSize;) {
                const auto tag = little(fields.data() + p, 2), length = little(fields.data() + p + 2, 2);
                p += 4;
                if (length > nameSize + extraSize - p) invalidDocument("Invalid ZIP extra field");
                if (tag == 1) {
                    size_t cursor = p;
                    for (auto* value : {&expanded, &compressed, &offset}) if (*value == 0xffffffff) {
                        if (cursor + 8 > p + length) invalidDocument("Truncated ZIP64 sizes");
                        *value = little(fields.data() + cursor, 8); cursor += 8;
                        if (!selected) break; // Only its declared size matters for an unselected entry.
                    }
                    found = true; break;
                }
                p += length;
            }
            if (!found) invalidDocument("Missing ZIP64 sizes");
        }
        // Upstream also requires the declared sum to be a JS safe integer.
        if (expanded > maxUncompressed - declared || expanded > 9007199254740991ULL - declared)
            invalidDocument("ZIP exceeds --max-uncompressed-bytes");
        declared += expanded;
        if (!selected) continue;
        if (method != 0 && method != 8) invalidDocument("Unsupported ZIP compression for document metadata");
        const auto local = read(offset, 30);
        const uint64_t skip = little(local.data() + 26, 2) + little(local.data() + 28, 2);
        // read(offset, 30) establishes offset + 30 <= size before this addition.
        if (skip > size - offset - 30) invalidDocument("Truncated ZIP local header");
        const uint64_t dataOffset = offset + 30 + skip;
        if (compressed > size - dataOffset) invalidDocument("Truncated ZIP metadata");
        std::unique_ptr<FontMetadataParser> parser(xml ? new FontMetadataParser(odf, metadata) : nullptr);
        uint64_t consumed = 0, produced = 0;
        std::string text;
        bool foundType = false;
        auto consume = [&](const unsigned char* bytes, size_t length) {
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
            if (length > maxUncompressed - actual) invalidDocument("ZIP metadata exceeds actual --max-uncompressed-bytes");
            actual += length;
            // fflate's deflate output is clipped to its declared-size buffer.
            // Still count ALL actual output above, including any clipped bytes.
            const size_t visible = method == 8 ? static_cast<size_t>(std::min<uint64_t>(length, produced < expanded ? expanded - produced : 0)) : length;
            produced += length;
            if (parser && visible) parser->feed(bytes, visible);
            if (type) {
                text.append(reinterpret_cast<const char*>(bytes), visible);
                if (text.find(mime) != std::string::npos) foundType = true;
                if (text.size() > mime.size()) text.erase(0, text.size() - mime.size());
            }
        };
        z_stream stream{};
        if (method == 8 && inflateInit2(&stream, -MAX_WBITS) != Z_OK) invalidDocument("Cannot initialize ZIP decompression");
        struct EndInflate { z_stream* stream; ~EndInflate() { if (stream) inflateEnd(stream); } } endInflate{method == 8 ? &stream : nullptr};
        std::array<unsigned char, 65536> output;
        int status = Z_OK;
        while (consumed < compressed && status != Z_STREAM_END) {
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
            const auto input = read(dataOffset + consumed, static_cast<size_t>(std::min<uint64_t>(65536, compressed - consumed)));
            consumed += input.size();
            if (method == 0) { consume(input.data(), input.size()); continue; }
            stream.next_in = const_cast<Bytef*>(input.data()); stream.avail_in = static_cast<uInt>(input.size());
            do {
                stream.next_out = output.data(); stream.avail_out = output.size();
                status = inflate(&stream, Z_NO_FLUSH);
                if (status == Z_BUF_ERROR && !stream.avail_in && stream.avail_out == output.size()) break;
                if (status != Z_OK && status != Z_STREAM_END) invalidDocument("Corrupt ZIP metadata deflate stream");
                consume(output.data(), output.size() - stream.avail_out);
                if (status == Z_STREAM_END) break;
            } while (stream.avail_in || !stream.avail_out);
        }
        if (method == 8 && compressed && status != Z_STREAM_END) invalidDocument("Truncated ZIP metadata deflate stream");
        if (parser) parser->finish(metadata);
        const uint64_t visible = method == 8 ? std::min(produced, expanded) : produced;
        if (foundType && (!odf || (visible == mime.size() && text == mime))) contentType = true;
    }
    if (!contentType || !names.count(main) || !names.count(odf ? "META-INF/manifest.xml" : "_rels/.rels"))
        invalidDocument("Input does not contain the requested Office document type");
}
}
