// Repeated invocations of the shipped ABI in one process, for state-isolation tests.
#include "../OfficeCommand.h"
#include <cstdio>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <unistd.h>
int main(int argc, char** argv)
{
    if (argc != 3 && !(argc == 4 && !strcmp(argv[3], "--timings"))) return 2;
    const auto directory = std::filesystem::current_path().string();
    FILE* output = fdopen(dup(STDOUT_FILENO), "w");
    if (!output || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
    OfficeCommandContext context{};
    context.output = output; context.error = output;
    context.directory = directory.c_str(); context.programDirectory = argv[1]; context.temporaryDirectory = argv[2];
    struct Timing { std::chrono::steady_clock::time_point start; std::vector<std::pair<std::string, double>> phases; } timing;
    if (argc == 4) {
        context.phaseContext = &timing;
        context.phase = [](const char* phase, void* opaque) {
            auto& value = *static_cast<Timing*>(opaque);
            value.phases.emplace_back(phase, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - value.start).count());
        };
    }
    for (std::string line; std::getline(std::cin, line);) {
        std::vector<std::string> words{"office"};
        std::istringstream input(line);
        for (std::string word; std::getline(input, word, '\t');) words.push_back(word);
        std::vector<char*> args;
        for (auto& word : words) args.push_back(word.data());
        timing.start = std::chrono::steady_clock::now(); timing.phases.clear();
        OfficeCommandRun(args.size(), args.data(), &context);
        if (argc == 4) {
            std::fprintf(stderr, "OFFICE_PHASES {");
            for (size_t i = 0; i < timing.phases.size(); ++i)
                std::fprintf(stderr, "%s\"%s\":%.3f", i ? "," : "", timing.phases[i].first.c_str(), timing.phases[i].second);
            std::fprintf(stderr, "}\n"); std::fflush(stderr);
        }
        std::fflush(output);
    }
    std::_Exit(0);
}
