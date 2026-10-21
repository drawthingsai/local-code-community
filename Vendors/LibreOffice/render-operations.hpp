// Native port of dsh rendering.ts, sheet-geometry.ts and native-image-renderer.ts.
extern "C" void* dsh_native_pdf_open(const unsigned char*, int, const char*) noexcept;
extern "C" int dsh_native_pdf_page_count(void*) noexcept;
extern "C" int dsh_native_pdf_page_size(void*, int, int*, int*) noexcept;
extern "C" int dsh_native_pdf_paint(void*, unsigned char*, int, int, int, int, int, int, int) noexcept;
extern "C" int dsh_native_pdf_destroy(void*) noexcept;

constexpr const char* officeCapabilities = R"JSON({"schemaVersion":1,"backend":"native","version":"26.8.0.3","conversions":{"doc":["pdf","docx","odt","txt"],"docx":["pdf","docx","odt","txt"],"odt":["pdf","docx","odt","txt"],"xls":["pdf","xlsx","ods","csv"],"xlsx":["pdf","xlsx","ods","csv"],"ods":["pdf","xlsx","ods","csv"],"ppt":["pdf","pptx","odp"],"pptx":["pdf","pptx","odp"],"odp":["pdf","pptx","odp"]},"recalculation":{"inputs":["xls","xlsx","ods"],"outputs":["xlsx","ods"],"preservesFormulas":true},"imageRendering":{"inputs":["doc","docx","odt","xls","xlsx","ods","ppt","pptx","odp","pdf"],"output":"png","officeBackend":"libreoffice","pdfBackend":"pdfium","maxPages":100,"maxPixels":16777216,"maxDimension":8192,"dpi":144},"csv":{"sheet":"exact name; required for multiple sheets","encoding":"UTF-8","delimiter":","},"limits":{"maxInputBytes":67108864,"maxOutputBytes":134217728,"maxArchiveEntries":20000,"maxUncompressedBytes":536870912,"maxImageResolution":144,"maximumImageResolution":600},"fonts":{"allCatalogFontsAvailable":true,"metadataSampling":{"maxFamilies":4096,"maxCodePoints":65536,"maxFamilyBytes":1024,"overflow":"truncate","resultFlag":"fontMetadataTruncated"},"maxFallbackNames":4096,"options":["font-directory","font-fallbacks"],"missingFonts":"Sampled declared document families absent from the font catalog; not a glyph-coverage guarantee"},"execution":{"persistentEngine":true,"hardTimeout":false,"macros":false,"errorStream":"stderr","exitCodes":[0,1,130]}}
)JSON";

int64_t jsonInteger(const json::value& value)
{
    if (value.is_int64()) return value.as_int64();
    if (value.is_uint64() && value.as_uint64() <= INT64_MAX) return value.as_uint64();
    throw ConversionError("invalid-document", "Engine returned invalid numeric geometry");
}

std::string engineString(LibreOfficeKit* office, char* value)
{
    if (!value) throw ConversionError("invalid-document", "Engine returned no geometry");
    std::unique_ptr<char, std::function<void(char*)>> owned(value, [office](char* p) { office->pClass->freeError(p); });
    const size_t length = strnlen(value, 32 * 1024 * 1024 + 1);
    if (length > 32 * 1024 * 1024) throw ConversionError("invalid-document", "Engine geometry exceeds 32 MiB");
    return std::string(value, length);
}

struct CellRange { int firstColumn, firstRow, lastColumn, lastRow; };
CellRange cellRange(const std::string& text)
{
    size_t offset = 0;
    auto cell = [&]() {
        if (offset < text.size() && text[offset] == '$') ++offset;
        int column = 0, letters = 0;
        while (offset < text.size() && std::isalpha(static_cast<unsigned char>(text[offset]))) {
            if (++letters > 3) throw std::runtime_error("Invalid A1 range");
            column = column * 26 + std::toupper(static_cast<unsigned char>(text[offset++])) - 'A' + 1;
        }
        if (offset < text.size() && text[offset] == '$') ++offset;
        int row = 0, digits = 0;
        if (offset < text.size() && text[offset] == '0') throw std::runtime_error("Invalid A1 row");
        while (offset < text.size() && std::isdigit(static_cast<unsigned char>(text[offset]))) {
            if (++digits > 7) throw std::runtime_error("Invalid A1 row");
            row = row * 10 + text[offset++] - '0';
        }
        if (!letters || !digits || column > 16384 || row < 1 || row > 1048576) throw std::runtime_error("A1 range exceeds worksheet bounds");
        return std::pair<int,int>{column - 1, row - 1};
    };
    const auto first = cell(); auto last = first;
    if (offset < text.size() && text[offset] == ':') { ++offset; last = cell(); }
    if (offset != text.size() || last.first < first.first || last.second < first.second) throw std::runtime_error("Invalid or reversed A1 range");
    return {first.first, first.second, last.first, last.second};
}
std::string rangeName(const CellRange& range)
{
    auto cell = [](int column, int row) {
        std::string name;
        for (++column; column; column = (column - 1) / 26) name.insert(name.begin(), 'A' + (column - 1) % 26);
        return name + std::to_string(row + 1);
    };
    return cell(range.firstColumn, range.firstRow) + ":" + cell(range.lastColumn, range.lastRow);
}
std::pair<double,double> sheetDimension(const json::object& data, int first, int last, int maximum, double scale)
{
    struct Span { int end, value; };
    auto parse = [&](const char* field, bool flags) {
        std::vector<Span> spans;
        std::istringstream encoded(std::string(data.at(field).as_string()));
        int previous = -1, flag = 0;
        for (std::string token; encoded >> token;) {
            const auto colon = token.find(':');
            int value, end;
            auto number = [](const std::string& text) {
                if (text.empty() || !std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; })) throw std::runtime_error("Invalid geometry span");
                const auto n = std::stoull(text);
                if (n > INT_MAX) throw std::runtime_error("Geometry span overflow");
                return static_cast<int>(n);
            };
            if (flags && !spans.empty()) { value = flag = 1 - flag; end = number(token); }
            else {
                if (colon == std::string::npos) throw std::runtime_error("Invalid geometry span");
                value = flag = number(token.substr(0, colon)); end = number(token.substr(colon + 1));
            }
            if (value > (flags ? 1 : 65535) || end <= previous || end > maximum) throw std::runtime_error("Invalid geometry span bounds");
            previous = end; spans.push_back({end, value});
        }
        if (previous != maximum) throw std::runtime_error("Incomplete worksheet geometry");
        return spans;
    };
    const auto sizes = parse("sizes", false), hidden = parse("hidden", true), filtered = parse("filtered", true);
    size_t si = 0, hi = 0, fi = 0;
    double position = 0, start = 0;
    for (int index = 0; index <= last;) {
        const auto size = sizes.at(si), hide = hidden.at(hi), filter = filtered.at(fi);
        const int end = std::min({size.end, hide.end, filter.end, last, index < first ? first - 1 : last});
        const double pixels = hide.value || filter.value || !size.value ? 0 : std::max(1.0, std::floor(size.value * scale / 15));
        if (index == first) start = position;
        position += (end - index + 1) * pixels; index = end + 1;
        if (index > size.end) ++si;
        if (index > hide.end) ++hi;
        if (index > filter.end) ++fi;
    }
    return {start / scale, (position - start) / scale};
}

uint64_t writePng(const fs::path& path, int width, int height, const std::vector<unsigned char>& pixels,
    uint64_t limit, const OfficeCommandContext* context)
{
    std::ofstream file(path, std::ios::binary);
    uint64_t total = 0;
    auto write = [&](const void* data, size_t length) {
        if (length > limit - total) throw ConversionError("output-too-large", "PNG batch exceeds --max-output-bytes");
        file.write(static_cast<const char*>(data), length); total += length;
        if (!file) throw std::runtime_error("Cannot write PNG");
    };
    auto big = [](uint32_t n) { return std::array<unsigned char,4>{static_cast<unsigned char>(n >> 24), static_cast<unsigned char>(n >> 16), static_cast<unsigned char>(n >> 8), static_cast<unsigned char>(n)}; };
    auto chunk = [&](const char* type, const unsigned char* data, size_t length) {
        const auto size = big(static_cast<uint32_t>(length)); write(size.data(), 4); write(type, 4);
        if (length) write(data, length);
        auto checksum = crc32(0, reinterpret_cast<const Bytef*>(type), 4);
        if (length) checksum = crc32(checksum, data, static_cast<uInt>(length));
        const auto crc = big(static_cast<uint32_t>(checksum));
        write(crc.data(), 4);
    };
    const unsigned char signature[] = {137,80,78,71,13,10,26,10}; write(signature, 8);
    std::array<unsigned char,13> header{};
    const auto w = big(width), h = big(height);
    std::copy(w.begin(), w.end(), header.begin()); std::copy(h.begin(), h.end(), header.begin() + 4);
    header[8] = 8; header[9] = 6; chunk("IHDR", header.data(), header.size());
    z_stream stream{};
    if (deflateInit(&stream, 6) != Z_OK) throw std::runtime_error("Cannot initialize PNG compression");
    struct End { z_stream* s; ~End() { deflateEnd(s); } } end{&stream};
    std::array<unsigned char,65536> compressed;
    auto encode = [&](const unsigned char* data, size_t size, int flush) {
        stream.next_in = const_cast<Bytef*>(data); stream.avail_in = static_cast<uInt>(size);
        int status;
        do {
            stream.next_out = compressed.data(); stream.avail_out = compressed.size();
            status = deflate(&stream, flush);
            if (status != Z_OK && status != Z_STREAM_END) throw std::runtime_error("PNG compression failed");
            const size_t count = compressed.size() - stream.avail_out;
            if (count) chunk("IDAT", compressed.data(), count);
        } while (stream.avail_in || !stream.avail_out || (flush == Z_FINISH && status != Z_STREAM_END));
    };
    const unsigned char filter = 0;
    for (int row = 0; row < height; ++row) {
        if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        encode(&filter, 1, Z_NO_FLUSH);
        encode(pixels.data() + static_cast<size_t>(row) * width * 4, static_cast<size_t>(width) * 4, Z_NO_FLUSH);
    }
    encode(nullptr, 0, Z_FINISH); chunk("IEND", nullptr, 0);
    file.close(); if (!file || chmod(path.c_str(), 0600)) throw std::runtime_error("Cannot finalize PNG");
    return total;
}

std::string renderImages(const Request& request, const fs::path& destination, const fs::path& scratch,
    LibreOfficeKit* office, const OfficeCommandContext* context)
{
    struct Region { int part = -1, number = 0; double x = 0, y = 0, width = 0, height = 0, originX = 0, originY = 0; std::string sheet, range; bool rtl = false; };
    const auto& missingFonts = request.missingFonts;
    DocumentPtr document(nullptr, [](LibreOfficeKitDocument* p) { if (p) p->pClass->destroy(p); });
    std::vector<unsigned char> pdfBytes;
    std::unique_ptr<void, decltype(&dsh_native_pdf_destroy)> pdf(nullptr, dsh_native_pdf_destroy);
    const bool isPdf = extension(request.input) == "pdf";
    int type = -1, tileMode = LOK_TILEMODE_RGBA, count = 0;
    std::vector<Region> regions;
    if (isPdf) {
        const auto size = fs::file_size(request.input);
        if (size > INT_MAX) throw ConversionError("input-too-large", "PDFium input exceeds 2147483647 bytes");
        pdfBytes.resize(size);
        if (!std::ifstream(request.input, std::ios::binary).read(reinterpret_cast<char*>(pdfBytes.data()), size)) throw std::runtime_error("Cannot read PDF");
        pdf.reset(dsh_native_pdf_open(pdfBytes.data(), static_cast<int>(size), ""));
        if (!pdf) throw ConversionError("invalid-document", "PDFium could not open PDF");
        count = dsh_native_pdf_page_count(pdf.get());
        if (count < 1 || count > 100000) throw ConversionError("invalid-document", "Invalid PDF page count");
        for (int i = 0; i < count; ++i) {
            int w = 0, h = 0;
            if (!dsh_native_pdf_page_size(pdf.get(), i, &w, &h) || w < 1 || h < 1) throw ConversionError("invalid-document", "Invalid PDF dimensions");
            regions.push_back({i, i + 1, 0, 0, w / 15.0, h / 15.0});
        }
    } else {
        document = loadDocument(request, office);
        officePhase(context, "loaded");
        document->pClass->initializeForRendering(document.get(), "{\".uno:ShowBorderShadow\":{\"type\":\"boolean\",\"value\":\"false\"}}");
        type = document->pClass->getDocumentType(document.get()); tileMode = document->pClass->getTileMode(document.get());
        if (type == LOK_DOCTYPE_TEXT) {
            std::istringstream rectangles(engineString(office, document->pClass->getPartPageRectangles(document.get())));
            for (std::string rectangle; std::getline(rectangles, rectangle, ';');) {
                if (rectangle.find_first_not_of(" \t\r\n") == std::string::npos) continue;
                std::replace(rectangle.begin(), rectangle.end(), ',', ' ');
                std::istringstream fields(rectangle); int64_t x, y, w, h; std::string extra;
                if (!(fields >> x >> y >> w >> h) || (fields >> extra) || x < 0 || y < 0 || w < 0 || h < 0
                    || x > INT_MAX || y > INT_MAX || w > INT_MAX - x || h > INT_MAX - y || (!w != !h))
                    throw ConversionError("invalid-document", "Invalid Writer page rectangles");
                if (w) regions.push_back({-1, static_cast<int>(regions.size()) + 1, 0, 0, w / 15.0, h / 15.0, x / 15.0, y / 15.0});
                if (regions.size() > 100000) throw ConversionError("invalid-document", "Too many Writer pages");
            }
            count = regions.size();
        } else if (type == LOK_DOCTYPE_PRESENTATION) {
            count = document->pClass->getParts(document.get());
            if (count < 1 || count > 100000) throw ConversionError("invalid-document", "Invalid slide count");
            document->pClass->setPartMode(document.get(), LOK_PARTMODE_SLIDES);
            for (int i = 0; i < count; ++i) {
                long w = 0, h = 0; document->pClass->setPart(document.get(), i); document->pClass->getDocumentSize(document.get(), &w, &h);
                regions.push_back({i, i + 1, 0, 0, w / 15.0, h / 15.0});
            }
        } else if (type == LOK_DOCTYPE_SPREADSHEET) {
            const int parts = document->pClass->getParts(document.get());
            if (parts < 1 || parts > 100000) throw ConversionError("invalid-document", "Invalid worksheet count");
            for (int i = 0; i < parts; ++i) {
                const auto infoValue = json::parse(engineString(office, document->pClass->getPartInfo(document.get(), i)));
                const auto& info = infoValue.as_object();
                const auto name = std::string(info.at("name").as_string());
                const auto visible = jsonInteger(info.at("visible"));
                if (visible) ++count;
                if (request.sheet.empty() ? !visible : request.sheet != name) continue;
                document->pClass->setPart(document.get(), i);
                const auto lastColumn = jsonInteger(info.at("lastcolumn")), lastRow = jsonInteger(info.at("lastrow"));
                if (lastColumn < 0 || lastColumn > 16383 || lastRow < 0 || lastRow > 1048575) throw ConversionError("invalid-document", "Invalid worksheet data area");
                const auto range = request.range.empty() ? CellRange{0, 0, static_cast<int>(lastColumn), static_cast<int>(lastRow)} : cellRange(request.range);
                const auto geometry = json::parse(engineString(office, document->pClass->getCommandValues(document.get(), ".uno:SheetGeometryData")));
                const auto x = sheetDimension(geometry.as_object().at("columns").as_object(), range.firstColumn, range.lastColumn, 16383, request.dpi / 96.0);
                const auto y = sheetDimension(geometry.as_object().at("rows").as_object(), range.firstRow, range.lastRow, 1048575, request.dpi / 96.0);
                Region r{i, 0, x.first, y.first, x.second, y.second};
                r.sheet = name; r.range = rangeName(range); r.rtl = jsonInteger(info.at("rtllayout")) != 0; regions.push_back(r);
            }
        } else throw ConversionError("invalid-document", "Unsupported document type for rendering");
    }
    if (regions.empty()) throw ConversionError("invalid-document", "No renderable pages or exact worksheet name not found");
    if (type != LOK_DOCTYPE_SPREADSHEET && request.pages != "all") {
        std::vector<Region> selected; std::set<uint64_t> used;
        std::istringstream pages(request.pages);
        if (request.pages.empty() || request.pages.back() == ',') throw std::runtime_error("Invalid --pages list");
        for (std::string text; std::getline(pages, text, ',');) {
            const auto page = positiveInteger(text);
            if (page > regions.size() || !used.insert(page).second) throw std::runtime_error("Repeated page or page outside document");
            selected.push_back(regions[page - 1]);
        }
        regions = std::move(selected);
    }
    const double scale = request.dpi / 96.0;
    std::vector<Region> selected;
    for (const auto& r : regions) {
        if (!std::isfinite(r.x + r.y + r.width + r.height) || r.x < 0 || r.y < 0 || r.width <= 0 || r.height <= 0
            || (r.originX + r.x + r.width) * 15 > INT_MAX || (r.originY + r.y + r.height) * 15 > INT_MAX)
            throw ConversionError("invalid-document", "Invalid render dimensions or hidden worksheet range");
        const auto width = static_cast<uint64_t>(std::ceil(r.width * scale - 1e-9)), height = static_cast<uint64_t>(std::ceil(r.height * scale - 1e-9));
        if (type != LOK_DOCTYPE_SPREADSHEET) {
            if (width > request.maxDimension || height > request.maxDimension || width * height > request.maxPixels)
                throw ConversionError("output-too-large", "Page exceeds --max-pixels or --max-dimension; reduce --dpi");
            selected.push_back(r);
        } else {
            uint64_t w = std::min(width, request.maxDimension), h = std::min(height, request.maxDimension);
            if (w * h > request.maxPixels) {
                const auto side = static_cast<uint64_t>(std::sqrt(request.maxPixels));
                if (w <= side) h = request.maxPixels / w;
                else if (h <= side) w = request.maxPixels / h;
                else { w = side; h = std::min(h, request.maxPixels / w); }
            }
            const auto columns = (width + w - 1) / w, rows = (height + h - 1) / h;
            if (columns * rows > request.maxPages - selected.size()) throw ConversionError("output-too-large", "Worksheet tile count exceeds --max-pages");
            for (uint64_t y = 0; y < height; y += h) for (uint64_t x = 0; x < width; x += w) {
                Region tile = r; tile.x += x / scale; tile.y += y / scale;
                tile.width = std::min(w / scale, r.width - x / scale); tile.height = std::min(h / scale, r.height - y / scale);
                selected.push_back(tile);
            }
        }
        if (selected.size() > request.maxPages) throw ConversionError("output-too-large", "Image count exceeds --max-pages");
    }
    const auto staging = scratch / "images"; fs::create_directory(staging);
    json::array images; uint64_t bytes = 0;
    for (const auto& r : selected) {
        officePhase(context, "rendering");
        const int w = static_cast<int>(std::ceil(r.width * scale - 1e-9)), h = static_cast<int>(std::ceil(r.height * scale - 1e-9));
        if (w < 1 || h < 1 || uint64_t(w) * h > request.maxPixels) throw ConversionError("output-too-large", "Invalid tile dimensions");
        std::vector<unsigned char> pixels(static_cast<size_t>(w) * h * 4);
        const int x = std::lround((r.originX + r.x) * 15), y = std::lround((r.originY + r.y) * 15);
        const int tw = std::max(1L, std::lround(r.width * 15)), th = std::max(1L, std::lround(r.height * 15));
        if (isPdf) {
            if (!dsh_native_pdf_paint(pdf.get(), pixels.data(), r.part, w, h, x, y, tw, th)) throw ConversionError("failed", "PDFium tile paint failed");
        } else {
            if (r.part >= 0) document->pClass->setPart(document.get(), r.part);
            if (type == LOK_DOCTYPE_SPREADSHEET) {
                document->pClass->setClientZoom(document.get(), request.dpi * 15, request.dpi * 15, 21600, 21600);
                document->pClass->setClientVisibleArea(document.get(), x, y, tw, th);
            }
            if (r.part < 0) document->pClass->paintTile(document.get(), pixels.data(), w, h, x, y, tw, th);
            else document->pClass->paintPartTile(document.get(), pixels.data(), r.part, LOK_PARTMODE_SLIDES, w, h, x, y, tw, th);
            if (tileMode != LOK_TILEMODE_RGBA && tileMode != LOK_TILEMODE_BGRA) throw ConversionError("invalid-output", "Unsupported tile pixel format");
            for (size_t i = 0; i < pixels.size(); i += 4) {
                if (tileMode == LOK_TILEMODE_BGRA) std::swap(pixels[i], pixels[i + 2]);
                for (size_t c = 0; c < 3; ++c) pixels[i + c] = pixels[i + 3] ? std::min(255U, (pixels[i + c] * 255U + pixels[i + 3] / 2) / pixels[i + 3]) : 0;
            }
        }
        char filename[32]; std::snprintf(filename, sizeof filename, "page-%04zu.png", images.size() + 1);
        const auto size = writePng(staging / filename, w, h, pixels, request.maxOutput - bytes, context); bytes += size;
        json::object image{{"index", images.size() + 1}, {"path", (fs::path(request.displayOutput) / filename).string()},
            {"width", w}, {"height", h}, {"byteLength", size}, {"rectangle", json::object{{"x", r.x}, {"y", r.y}, {"width", r.width}, {"height", r.height}}}};
        if (r.number) image["page"] = r.number;
        if (!r.sheet.empty()) { image["sheet"] = r.sheet; image["range"] = r.range; image["rtl"] = r.rtl; }
        images.push_back(image);
    }
    document.reset(); pdf.reset(); officePhase(context, "closed");
    const std::string result = json::serialize(json::object{{"ok", true}, {"schemaVersion", 1}, {"backend", "native"},
        {"rasterEngine", isPdf ? "pdfium" : "libreoffice"}, {"source", "saved"}, {"inputPath", request.displayInput},
        {"sourceSha256", request.sourceHash}, {"dpi", request.dpi}, {"pageCount", count}, {"images", images}, {"missingFonts", missingFonts}, {"fontMetadataTruncated", request.documentFonts.truncated}});
    if (renamex_np(staging.c_str(), destination.c_str(), RENAME_EXCL)) throw std::runtime_error("Cannot publish output directory (destination may already exist)");
    return result;
}
