// Selection policy ported from dsh entry/fonts.ts and font-loader.ts. Native
// fontconfig supplies face metadata/coverage; no Node runtime or fontkit needed.
extern "C" void office_refresh_fonts(const char* const*, const char* const*, size_t, int);
extern "C" char* office_font_search_name(const char*);

std::string xmlText(const std::string& value)
{
    std::string result;
    for (char c : value) {
        if (c == '&') result += "&amp;";
        else if (c == '<') result += "&lt;";
        else if (c == '>') result += "&gt;";
        else if (c == '"') result += "&quot;";
        else result += c;
    }
    return result;
}
std::vector<std::vector<std::string>> defaultFontFallbacks()
{
    // Pinned dsh packages/entry/src/options.ts.
    return {
        {"Calibri", "Carlito"}, {"Calibri Light", "Carlito", "Calibri"}, {"Cambria", "Caladea"},
        {"宋体", "SimSun", "NSimSun", "Songti SC", "STSong", "Noto Serif CJK SC", "Noto Serif SC", "Source Han Serif SC"},
        {"黑体", "SimHei", "Heiti SC", "STHeiti", "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC"},
        {"微软雅黑", "Microsoft YaHei", "Microsoft YaHei UI", "PingFang SC", "Noto Sans CJK SC", "Noto Sans SC"},
        {"楷体", "KaiTi", "Kaiti SC", "STKaiti", "LXGW WenKai"},
        {"仿宋", "FangSong", "STFangsong", "Songti SC", "Noto Serif CJK SC"},
        {"sans-serif", "Arial", "Liberation Sans", "Helvetica", "DejaVu Sans", "Calibri", "Calibri Light", "Carlito",
         "Microsoft YaHei", "Microsoft YaHei UI", "微软雅黑", "PingFang SC", "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "SimHei", "黑体", "Heiti SC", "STHeiti"},
        {"serif", "Times New Roman", "Liberation Serif", "Times", "DejaVu Serif", "Cambria", "Caladea",
         "SimSun", "NSimSun", "宋体", "Songti SC", "STSong", "Noto Serif CJK SC", "Noto Serif SC", "Source Han Serif SC"},
        {"monospace", "Courier New", "Liberation Mono", "DejaVu Sans Mono", "Menlo", "Monaco", "Courier", "NSimSun", "Noto Sans Mono CJK SC",
         "Microsoft YaHei", "Microsoft YaHei UI", "微软雅黑", "PingFang SC", "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "SimHei", "黑体", "Heiti SC", "STHeiti"},
        {"Symbol", "Standard Symbols PS", "Symbola", "Segoe UI Symbol", "Apple Symbols", "FreeSerif", "DejaVu Sans"},
    };
}

std::vector<std::string> fontFamilyPriority(const std::string& family, const std::vector<std::vector<std::string>>& groups, bool symbols)
{
    const auto original = normalizedFont(family);
    std::vector<std::string> priority{family};
    std::string generic = original == "monospace" ? "monospace" : original == "serif" ? "serif" : "";
    for (const auto& group : groups) {
        if (std::none_of(group.begin(), group.end(), [&](const auto& name) { return normalizedFont(name) == original; })) continue;
        for (const auto& name : group) {
            priority.push_back(name);
            const auto key = normalizedFont(name);
            if (generic.empty() && (key == "serif" || key == "sansserif" || key == "monospace")) generic = key;
        }
    }
    if (generic.empty()) generic = "sansserif";
    for (const auto& kind : symbols ? std::vector<std::string>{"symbol", generic} : std::vector<std::string>{generic})
        for (const auto& group : groups)
            if (std::any_of(group.begin(), group.end(), [&](const auto& name) { return normalizedFont(name) == kind; }))
                priority.insert(priority.end(), group.begin(), group.end());
    std::vector<std::string> unique;
    std::set<std::string> seen;
    for (const auto& name : priority) if (seen.insert(normalizedFont(name)).second) unique.push_back(name);
    return unique;
}

struct FontFileStamp {
    std::string path;
    struct stat value{};
    bool exists;
    explicit FontFileStamp(const fs::path& path) : path(path.string()), exists(stat(this->path.c_str(), &value) == 0) {}
    bool unchanged() const {
        const FontFileStamp now(path);
        return exists == now.exists && (!exists || (value.st_dev == now.value.st_dev && value.st_ino == now.value.st_ino
            && value.st_size == now.value.st_size && value.st_mode == now.value.st_mode
            && value.st_mtimespec.tv_sec == now.value.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == now.value.st_mtimespec.tv_nsec
            && value.st_ctimespec.tv_sec == now.value.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == now.value.st_ctimespec.tv_nsec));
    }
};
struct OfficeFonts {
    using Config = std::unique_ptr<FcConfig, decltype(&FcConfigDestroy)>;
    struct Face {
        FcPattern* pattern;
        std::string family, path;
        std::set<std::string> aliases;
        int index, weight, width, slant;
        FcCharSet* coverage;
    };
    Config catalog{nullptr, FcConfigDestroy};
    std::string catalogKey, activeKey;
    std::vector<FontFileStamp> stamps;
    std::vector<Face> faces;
    size_t generation = 0, activeGeneration = 0;
};

void configureFonts(Request& request, OfficeRuntime& runtime, const OfficeCommandContext* context)
{
    if (!runtime.fontState) runtime.fontState = new OfficeFonts;
    auto& state = *runtime.fontState;
    auto groups = defaultFontFallbacks();
    if (!request.fontFallbacks.empty()) {
        boost::system::error_code error;
        const auto parsed = json::parse(request.fontFallbacks, error);
        if (error || !parsed.is_array()) throw std::runtime_error("--font-fallbacks must be an array of family arrays");
        groups.clear();
        size_t fallbackNames = 0;
        for (const auto& group : parsed.as_array()) {
            if (!group.is_array() || group.as_array().size() < 2) throw std::runtime_error("Each font fallback group needs at least two names");
            groups.emplace_back();
            for (const auto& family : group.as_array()) {
                if (++fallbackNames > DocumentFonts::maxFamilies) throw std::runtime_error("Font fallbacks exceed 4096 names");
                if (!family.is_string() || family.as_string().find('\0') != json::string::npos) throw std::runtime_error("Font fallback names must not be blank or contain NUL");
                if (family.as_string().size() > DocumentFonts::maxFamilyBytes) throw std::runtime_error("Font fallback family exceeds 1024 UTF-8 bytes");
                if (normalizedFont(std::string(family.as_string())).empty()) throw std::runtime_error("Font fallback names must not be blank");
                groups.back().emplace_back(family.as_string());
            }
        }
    }
    std::vector<std::string> directories;
    for (const auto& name : request.fontDirectories) {
        const fs::path path = fs::path(name).is_absolute() ? fs::path(name) : fs::path(context->directory) / name;
        if (!fs::is_directory(path)) throw std::runtime_error("Font directory does not exist");
        directories.push_back(fs::canonical(path).string());
    }
    if (directories.empty() && runtime.fontConfiguration.empty()) {
        directories = {"/System/Library/Fonts", "/Library/Fonts"};
        if (const char* home = getenv("HOME")) directories.push_back((fs::path(home) / "Library/Fonts").string());
        const fs::path assets = "/System/Library/AssetsV2";
        std::error_code error;
        std::vector<std::string> assetDirectories;
        for (const auto& entry : fs::directory_iterator(assets, fs::directory_options::skip_permission_denied, error)) {
            const auto name = entry.path().filename().string(), prefix = std::string("com_apple_MobileAsset_Font");
            if (name.rfind(prefix, 0) == 0 && std::all_of(name.begin() + prefix.size(), name.end(), [](char c) { return c >= '0' && c <= '9'; }))
                assetDirectories.push_back(entry.path().string());
        }
        std::sort(assetDirectories.begin(), assetDirectories.end());
        directories.insert(directories.end(), assetDirectories.begin(), assetDirectories.end());
        directories.push_back((fs::path(runtime.program).parent_path() / "Resources/fonts").string());
        directories.push_back((fs::path(runtime.program).parent_path() / "share/fonts").string());
        directories.push_back((fs::path(runtime.program) / "resource/common/fonts").string());
    }
    const fs::path cache = context->cacheDirectory ? context->cacheDirectory : (fs::path(context->temporaryDirectory) / "font-cache");
    fs::create_directories(cache);
    json::array roots, hostFonts;
    for (const auto& path : directories) roots.emplace_back(path);
    for (const auto& path : runtime.fonts) hostFonts.emplace_back(path);
    const std::string catalogKey = json::serialize(json::array{roots, hostFonts, runtime.fontConfiguration, cache.string()});
    if (!state.catalog || state.catalogKey != catalogKey
        || std::any_of(state.stamps.begin(), state.stamps.end(), [](const auto& stamp) { return !stamp.unchanged(); })) {
        OfficeFonts::Config catalog(FcConfigCreate(), FcConfigDestroy);
        if (!catalog) throw std::bad_alloc();
        if (!runtime.fontConfiguration.empty() && !FcConfigParseAndLoad(catalog.get(),
                reinterpret_cast<const FcChar8*>(runtime.fontConfiguration.c_str()), FcTrue)) throw std::runtime_error("Cannot read host font configuration");
        std::vector<FontFileStamp> stamps;
        if (!runtime.fontConfiguration.empty()) stamps.emplace_back(runtime.fontConfiguration);
        std::set<std::string> visited, files;
        std::vector<fs::path> pending(directories.begin(), directories.end());
        while (!pending.empty()) {
            fs::path path = pending.back(); pending.pop_back();
            stamps.emplace_back(path);
            std::error_code error;
            path = fs::canonical(path, error);
            if (error || !visited.insert(path.string()).second) continue;
            if (visited.size() > 100000) throw std::runtime_error("Font search exceeds 100000 entries");
            if (fs::is_directory(path)) {
                for (const auto& entry : fs::directory_iterator(path, fs::directory_options::skip_permission_denied, error)) pending.push_back(entry.path());
            } else if (fs::is_regular_file(path)) {
                const auto ext = extension(path);
                if (ext == "ttf" || ext == "otf" || ext == "ttc" || ext == "otc" || ext == "dfont") files.insert(path.string());
            }
            if (files.size() > 20000) throw std::runtime_error("Font search exceeds 20000 files");
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        }
        for (const auto& path : runtime.fonts) { files.insert(path); stamps.emplace_back(path); }
#if TARGET_OS_IPHONE
        // Ask the platform for readable font URLs instead of assuming all iOS
        // fonts live at macOS paths. No UIKit or window is involved.
        if (request.fontDirectories.empty() && runtime.fontConfiguration.empty()) {
            CTFontCollectionRef collection = CTFontCollectionCreateFromAvailableFonts(nullptr);
            CFArrayRef descriptors = collection ? CTFontCollectionCreateMatchingFontDescriptors(collection) : nullptr;
            if (descriptors) {
                for (CFIndex i = 0; i < CFArrayGetCount(descriptors); ++i) {
                    auto descriptor = static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(descriptors, i));
                    CFTypeRef value = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute);
                    if (value) {
                        UInt8 path[PATH_MAX];
                        if (CFGetTypeID(value) == CFURLGetTypeID() && CFURLGetFileSystemRepresentation(static_cast<CFURLRef>(value), true, path, sizeof path)) {
                            const std::string file(reinterpret_cast<char*>(path));
                            if (files.insert(file).second) stamps.emplace_back(file);
                        }
                        CFRelease(value);
                    }
                }
                CFRelease(descriptors);
            }
            if (collection) CFRelease(collection);
        }
#endif
        if (files.size() > 20000) throw std::runtime_error("Font search exceeds 20000 files");
        // Index original files once. Fontconfig provides localized/full/PostScript
        // aliases and cmap coverage without retaining full font-file byte copies.
        const std::string xml = "<fontconfig><cachedir>" + xmlText(cache.string()) + "</cachedir></fontconfig>";
        if (!FcConfigParseAndLoadFromMemory(catalog.get(), reinterpret_cast<const FcChar8*>(xml.c_str()), FcTrue)) throw std::runtime_error("Cannot create font catalog");
        for (const auto& file : files) {
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
            std::error_code error;
            const auto bytes = fs::file_size(file, error);
            if (!error && bytes <= 256ULL * 1024 * 1024)
                FcConfigAppFontAddFile(catalog.get(), reinterpret_cast<const FcChar8*>(file.c_str()));
        }
        if (!FcConfigBuildFonts(catalog.get())) throw std::runtime_error("Cannot index fonts");
        std::vector<OfficeFonts::Face> faces;
        for (auto kind : {FcSetSystem, FcSetApplication}) {
            const auto* set = FcConfigGetFonts(catalog.get(), kind);
            if (!set) continue;
            for (int i = 0; i < set->nfont; ++i) {
                if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
                FcPattern* pattern = set->fonts[i]; FcChar8 *file = nullptr, *family = nullptr; FcCharSet* coverage = nullptr;
                if (FcPatternGetString(pattern, FC_FILE, 0, &file) != FcResultMatch
                    || FcPatternGetString(pattern, FC_FAMILY, 0, &family) != FcResultMatch
                    || FcPatternGetCharSet(pattern, FC_CHARSET, 0, &coverage) != FcResultMatch) continue;
                OfficeFonts::Face face{pattern, reinterpret_cast<const char*>(family), reinterpret_cast<const char*>(file), {}, 0, FC_WEIGHT_REGULAR, FC_WIDTH_NORMAL, FC_SLANT_ROMAN, coverage};
                FcPatternGetInteger(pattern, FC_INDEX, 0, &face.index);
                FcPatternGetInteger(pattern, FC_WEIGHT, 0, &face.weight);
                FcPatternGetInteger(pattern, FC_WIDTH, 0, &face.width);
                FcPatternGetInteger(pattern, FC_SLANT, 0, &face.slant);
                for (const char* field : {FC_FAMILY, FC_FULLNAME, FC_POSTSCRIPT_NAME}) {
                    FcChar8* name;
                    for (int j = 0; FcPatternGetString(pattern, field, j, &name) == FcResultMatch; ++j)
                        face.aliases.insert(normalizedFont(reinterpret_cast<const char*>(name)));
                }
                faces.push_back(std::move(face));
                if (files.insert(reinterpret_cast<const char*>(file)).second) stamps.emplace_back(reinterpret_cast<const char*>(file));
            }
        }
        if (faces.empty()) throw ConversionError("unavailable", "No usable fonts found");
        if (std::any_of(stamps.begin(), stamps.end(), [](const auto& stamp) { return !stamp.unchanged(); }))
            throw std::runtime_error("Font files changed during indexing; retry the command");
        state.catalog = std::move(catalog); state.faces = std::move(faces); state.stamps = std::move(stamps);
        state.catalogKey = catalogKey; ++state.generation;
        officePhase(context, "font-catalog-rebuilt");
    }
    officePhase(context, "font-indexed");
    // All catalog files stay available to VCL, including fonts only referenced
    // by themes, embedded objects, or binary formats. Inspection controls missing
    // family substitutions and diagnostics, never the engine's font visibility.
    std::set<std::string> aliases;
    std::vector<std::pair<std::string, std::string>> mappings;
    const std::set<std::string> generic{"serif", "sansserif", "monospace", "cursive", "fantasy", "systemui", "symbol"};
    const bool symbols = std::any_of(request.documentFonts.points.begin(), request.documentFonts.points.end(), [](auto point) {
        return CFCharacterSetIsLongCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetSymbol), point);
    });
    std::unique_ptr<FcCharSet, decltype(&FcCharSetDestroy)> points(FcCharSetCreate(), FcCharSetDestroy);
    if (!points) throw std::bad_alloc();
    for (auto point : request.documentFonts.points) {
        if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        if (!FcCharSetAddChar(points.get(), point)) throw std::bad_alloc();
    }
    // Precompute the best regular face for each alias once per document. The
    // first face in upstream's ranked covering set is all a substitution needs;
    // remaining glyph fallback is handled by VCL over the complete catalog.
    struct Candidate { const OfficeFonts::Face* face = nullptr; double style = 0; };
    std::map<std::string, Candidate> candidates;
    Candidate fallback;
    auto better = [](const Candidate& a, const Candidate& b) {
        return !b.face || std::tie(a.style, a.face->path, a.face->index) < std::tie(b.style, b.face->path, b.face->index);
    };
    const std::array<int, 9> widths{FC_WIDTH_ULTRACONDENSED, FC_WIDTH_EXTRACONDENSED, FC_WIDTH_CONDENSED,
        FC_WIDTH_SEMICONDENSED, FC_WIDTH_NORMAL, FC_WIDTH_SEMIEXPANDED, FC_WIDTH_EXPANDED, FC_WIDTH_EXTRAEXPANDED, FC_WIDTH_ULTRAEXPANDED};
    for (const auto& face : state.faces) {
        if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        aliases.insert(face.aliases.begin(), face.aliases.end());
        if (!request.documentFonts.points.empty() && !FcCharSetIntersectCount(face.coverage, points.get())) continue;
        const auto width = std::min_element(widths.begin(), widths.end(), [&](int a, int b) { return std::abs(a - face.width) < std::abs(b - face.width); }) - widths.begin() + 1;
        Candidate candidate{&face, (face.slant != FC_SLANT_ROMAN ? 100 : 0)
            + std::abs(FcWeightToOpenType(face.weight) - 400) / 100.0 + std::abs(width - 5)};
        if (better(candidate, fallback)) fallback = candidate;
        for (const auto& alias : face.aliases) if (better(candidate, candidates[alias])) candidates[alias] = candidate;
    }
    for (const auto& family : request.documentFonts.families) {
        if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
        const auto key = normalizedFont(family);
        if (generic.count(key) || aliases.count(key)) continue;
        const auto* first = fallback.face;
        for (const auto& name : fontFamilyPriority(family, groups, symbols)) {
            const auto found = candidates.find(normalizedFont(name));
            if (found != candidates.end()) { first = found->second.face; break; }
        }
        request.missingFonts.emplace_back(family);
        if (first) mappings.emplace_back(family, first->family);
    }
    officePhase(context, "fonts-resolved");
    // Use the engine's own localized search-name dictionary, then include the
    // metric aliases used by the pinned dsh native profile.
    std::map<std::string, std::string> substitutions;
    for (const auto& mapping : mappings) {
        std::unique_ptr<char, decltype(&free)> name(office_font_search_name(mapping.first.c_str()), free);
        if (!name) throw std::bad_alloc();
        substitutions[name.get()] = mapping.second;
    }
    const std::map<std::string, std::string> metric{
        {"timesnewroman", "liberationserif"}, {"arial", "liberationsans"}, {"arialnarrow", "liberationsansnarrow"},
        {"couriernew", "liberationmono"}, {"cambria", "caladea"}, {"calibri", "carlito"},
        {"bundessans", "calibri"}, {"bundessansoffice", "calibri"}, {"bundessansregular", "calibri"},
        {"bundesserif", "cambria"}, {"bundesserifoffice", "cambria"}, {"bundesserifregular", "cambria"},
    };
    for (const auto& item : std::map<std::string, std::string>(substitutions)) {
        auto found = metric.find(item.first);
        while (found != metric.end()) {
            if (!aliases.count(found->second)) substitutions.emplace(found->second, item.second);
            found = metric.find(found->second);
        }
    }
    json::array pairs;
    for (const auto& entry : substitutions) pairs.push_back(json::array{entry.first, entry.second});
    const auto key = json::serialize(pairs);
    const bool reload = state.activeGeneration != state.generation;
    if (reload) {
        OfficeFonts::Config active(FcConfigCreate(), FcConfigDestroy);
        if (!active) throw std::bad_alloc();
        const auto xml = "<fontconfig><cachedir>" + xmlText(cache.string()) + "</cachedir></fontconfig>";
        if (!FcConfigParseAndLoadFromMemory(active.get(), reinterpret_cast<const FcChar8*>(xml.c_str()), FcTrue)) throw std::runtime_error("Cannot create active font configuration");
        std::set<std::string> files;
        for (const auto& face : state.faces) files.insert(face.path);
        for (const auto& path : files) {
            if (context->isCancelled && context->isCancelled(context->cancellation)) throw OfficeCancelled();
            if (!FcConfigAppFontAddFile(active.get(), reinterpret_cast<const FcChar8*>(path.c_str()))) throw std::runtime_error("Catalog font changed or became unreadable");
        }
        state.activeGeneration = 0; // A failed activation must force the next caller to reload.
        if (!FcConfigBuildFonts(active.get()) || !FcConfigSetCurrent(active.get())) throw std::runtime_error("Cannot activate fonts");
    }
    if (!runtime.office) {
        Request initial; initial.program = runtime.program; initial.profile = runtime.profile;
        try { runtime.office = createOffice(initial); }
        catch (...) { officeInitializationFailure = std::current_exception(); throw; }
    }
    officePhase(context, "initialized");
    if (reload || state.activeKey != key) {
        std::vector<const char*> families, substitutes;
        for (const auto& entry : substitutions) { families.push_back(entry.first.c_str()); substitutes.push_back(entry.second.c_str()); }
        state.activeGeneration = 0; // Recover even if the private hook throws after a partial change.
        office_refresh_fonts(families.data(), substitutes.data(), families.size(), reload);
        state.activeGeneration = state.generation; state.activeKey = key;
        officePhase(context, reload ? "fonts-reloaded" : "font-substitutions-updated");
    }
    officePhase(context, "fonts-configured");
}
