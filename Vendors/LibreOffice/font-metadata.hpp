// Native port of dsh entry/ooxml.ts and fonts.ts normalization. Expat consumes
// bounded ZIP chunks; malformed XML parts do not supply font diagnostics.
std::string normalizedFont(const std::string& value)
{
    CFStringRef original = CFStringCreateWithBytes(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(value.data()), value.size(), kCFStringEncodingUTF8, false);
    if (!original) throw std::runtime_error("Font family is not UTF-8");
    CFMutableStringRef text = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, original);
    CFRelease(original);
    if (!text) throw std::bad_alloc();
    struct ReleaseString { CFStringRef value; ~ReleaseString() { CFRelease(value); } } release{text};
    CFStringNormalize(text, kCFStringNormalizationFormKC);
    CFStringLowercase(text, nullptr);
    for (CFIndex i = CFStringGetLength(text); i > 0; --i) {
        const auto c = CFStringGetCharacterAtIndex(text, i - 1);
        if (c == '_' || c == '-' || c == 0xfeff || CFCharacterSetIsCharacterMember(
                CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline), c))
            CFStringDelete(text, CFRangeMake(i - 1, 1));
    }
    std::string result(CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1, '\0');
    const bool success = CFStringGetCString(text, result.data(), result.size(), kCFStringEncodingUTF8);
    if (!success) throw std::runtime_error("Cannot normalize font family");
    result.resize(std::strlen(result.c_str()));
    return result;
}

struct DocumentFonts {
    // Sampling limits bound diagnostics/substitution work, never document validity.
    static constexpr size_t maxFamilies = 4096, maxFamilyBytes = 1024, maxCodePoints = 65536;
    std::vector<std::string> families;
    std::map<std::string, size_t> names;
    std::set<uint32_t> points;
    bool truncated = false;
    void addFamily(std::string_view value)
    {
        if (families.size() == maxFamilies || value.size() > maxFamilies * maxFamilyBytes) {
            truncated = true; return;
        }
        std::istringstream parts{std::string(value)};
        for (std::string name; std::getline(parts, name, ';');) {
            const auto first = name.find_first_not_of(" \t\r\n"), last = name.find_last_not_of(" \t\r\n");
            if (first == std::string::npos) continue;
            name = name.substr(first, last - first + 1);
            if (name == "+mj-lt" || name == "+mj-ea" || name == "+mj-cs"
                || name == "+mn-lt" || name == "+mn-ea" || name == "+mn-cs") continue;
            if (name.size() > maxFamilyBytes) { truncated = true; continue; }
            const auto key = normalizedFont(name);
            if (key.empty()) continue;
            if (families.size() == maxFamilies) { truncated = true; return; }
            auto entry = names.emplace(key, families.size());
            if (entry.second) families.push_back(name);
            else families[entry.first->second] = name;
        }
    }
    void addPoint(uint32_t point)
    {
        if (points.size() == maxCodePoints) { truncated = true; return; }
        points.insert(point);
    }
    void merge(const DocumentFonts& part)
    {
        for (const auto& family : part.families) addFamily(family);
        for (auto point : part.points) addPoint(point);
        truncated |= part.truncated;
    }
};

class FontMetadataParser {
    XML_Parser parser = nullptr;
    DocumentFonts part;
    std::exception_ptr failure;
    bool odf, collectFamilies, collectPoints, valid = true;
    void family(std::string_view value)
    {
        if (collectFamilies) part.addFamily(value);
        else part.truncated = true;
    }
    static std::pair<std::string, std::string> name(const char* value)
    {
        const char* separator = strrchr(value, '\x1f');
        return separator ? std::make_pair(std::string(value, separator), std::string(separator + 1))
                         : std::make_pair(std::string(), std::string(value));
    }
    static bool ns(const std::string& uri, const char* kind)
    {
        for (const auto& suffix : {std::string(kind) + "/2006/main", std::string(kind) + "/main"})
            if (uri.size() >= suffix.size() && uri.compare(uri.size() - suffix.size(), suffix.size(), suffix) == 0) return true;
        return false;
    }
    static void start(void* opaque, const char* tag, const char** attrs) noexcept
    {
        auto& self = *static_cast<FontMetadataParser*>(opaque);
        try {
            const auto element = name(tag);
            const bool word = ns(element.first, "wordprocessingml") && element.second == "rFonts";
            const bool drawing = ns(element.first, "drawingml");
            const bool sheet = ns(element.first, "spreadsheetml") && element.second == "name";
            for (; *attrs; attrs += 2) {
                const auto attribute = name(attrs[0]).second;
                if (self.odf && attribute == "font-family") {
                    std::string_view value = attrs[1];
                    if (!value.empty() && (value.front() == '\'' || value.front() == '"')) value.remove_prefix(1);
                    if (!value.empty() && (value.back() == '\'' || value.back() == '"')) value.remove_suffix(1);
                    self.family(value);
                }
                if ((word && (attribute == "ascii" || attribute == "hAnsi" || attribute == "eastAsia" || attribute == "cs"))
                    || (drawing && attribute == "typeface") || (sheet && attribute == "val")) self.family(attrs[1]);
            }
        } catch (...) { self.failure = std::current_exception(); XML_StopParser(self.parser, XML_FALSE); }
    }
    static void characters(void* opaque, const char* text, int length) noexcept
    {
        auto& self = *static_cast<FontMetadataParser*>(opaque);
        try {
            // Expat supplies complete UTF-8 scalar sequences, also for UTF-16 XML.
            for (int i = 0; i < length;) {
                if (!self.collectPoints || self.part.points.size() == DocumentFonts::maxCodePoints) {
                    self.part.truncated = true; return;
                }
                uint32_t point = static_cast<unsigned char>(text[i++]);
                int extra = point < 0x80 ? 0 : point < 0xe0 ? 1 : point < 0xf0 ? 2 : 3;
                if (extra) point &= (1U << (6 - extra)) - 1;
                while (extra--) point = (point << 6) | (static_cast<unsigned char>(text[i++]) & 63);
                if (point != 0xfeff && !CFCharacterSetIsLongCharacterMember(
                        CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline), point)) self.part.addPoint(point);
            }
        } catch (...) { self.failure = std::current_exception(); XML_StopParser(self.parser, XML_FALSE); }
    }
public:
    explicit FontMetadataParser(bool odf, const DocumentFonts& collected = {}) : odf(odf),
        collectFamilies(collected.families.size() < DocumentFonts::maxFamilies),
        collectPoints(collected.points.size() < DocumentFonts::maxCodePoints)
    {
        parser = XML_ParserCreateNS(nullptr, '\x1f');
        if (!parser) throw std::bad_alloc();
        XML_SetUserData(parser, this);
        XML_SetElementHandler(parser, start, nullptr);
        XML_SetCharacterDataHandler(parser, characters);
        // Documents with DTDs still reach LibreOffice; do not expand entities in
        // the preliminary metadata scan or resolve any external resources.
        XML_SetStartDoctypeDeclHandler(parser, [](void* opaque, const char*, const char*, const char*, int) {
            auto& self = *static_cast<FontMetadataParser*>(opaque);
            XML_StopParser(self.parser, XML_FALSE);
        });
    }
    ~FontMetadataParser() { XML_ParserFree(parser); }
    void feed(const unsigned char* bytes, size_t count)
    {
        if (valid) valid = XML_Parse(parser, reinterpret_cast<const char*>(bytes), static_cast<int>(count), XML_FALSE) == XML_STATUS_OK;
        if (failure) std::rethrow_exception(failure);
    }
    void finish(DocumentFonts& result)
    {
        if (valid && XML_Parse(parser, "", 0, XML_TRUE) == XML_STATUS_OK) result.merge(part);
        if (failure) std::rethrow_exception(failure);
    }
};
