#include "../OfficeCommand.h"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <stdexcept>
#include <unistd.h>
#include <pthread.h>
namespace fs = std::filesystem;
namespace {
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
}
#include "memory_probe.cpp"
int main(int argc, char** argv)
{
    const int status = officeMemoryProbe(argc, argv);
    std::fflush(nullptr);
    std::_Exit(status);
}
