// Standalone host. The embedded library has no main, process exit, or fd redirection.
#include "OfficeCommand.h"
#include <mach-o/dyld.h>
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

int main(int argc, char** argv)
{
    int status = 1;
    try {
        uint32_t size = 0;
        _NSGetExecutablePath(nullptr, &size);
        std::vector<char> executable(size);
        if (_NSGetExecutablePath(executable.data(), &size)) return 2;
        namespace fs = std::filesystem;
        std::string program = (fs::canonical(executable.data()).parent_path().parent_path()
            / "office/Frameworks").string();
        std::vector<char*> arguments{argv[0]};
        std::vector<const char*> fonts;
        for (int i = 1; i < argc; ++i) {
            const std::string option = argv[i];
            if (option == "--program-directory" || option == "--font-file") {
                if (++i == argc) throw std::runtime_error("Missing host option value");
                if (option == "--program-directory") program = fs::canonical(argv[i]).string();
                else fonts.push_back(argv[i]);
            } else arguments.push_back(argv[i]);
        }
        const std::string directory = fs::current_path().string();
        const std::string temporary = fs::temp_directory_path().string();
        // Only the standalone process owns its descriptors; engine diagnostics
        // must never cause process-wide redirection in the embedded host.
        int fd = dup(STDOUT_FILENO);
        if (fd < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
        FILE* output = fdopen(fd, "w");
        if (!output) return 2;
        OfficeCommandContext context{output, directory.c_str(), program.c_str(),
            temporary.c_str(), nullptr, nullptr, nullptr, nullptr, fonts.data(), fonts.size(), std::getenv("FONTCONFIG_FILE")};
        context.error = stderr;
        status = OfficeCommandRun(static_cast<int>(arguments.size()), arguments.data(), &context);
        if (status == 0 && (arguments.size() == 1 || (arguments.size() == 2 &&
            (std::string(arguments[1]) == "--help" || std::string(arguments[1]) == "-h" || std::string(arguments[1]) == "help"))))
            std::fprintf(output, "Standalone host options: --program-directory PATH; --font-file FILE (repeatable).\n");
        std::fclose(output);
        std::fflush(stderr);
    } catch (const std::exception& error) {
        std::fprintf(stderr, "office: %s\n", error.what());
    }
    // The process owns teardown. LibreOffice's lifetime is intentionally process-wide.
    std::_Exit(status);
}
