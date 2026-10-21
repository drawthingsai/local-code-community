// Diagnostic host for the encapsulated OfficeCommandRun API.
#include <mach/mach.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <queue>
#include <thread>

namespace {
using ProbeClock = std::chrono::steady_clock;

struct OfficeMemory {
    uint64_t resident, footprint, residentPeak, footprintPeak;
};

OfficeMemory officeMemory()
{
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count)
        != KERN_SUCCESS || count < TASK_VM_INFO_REV3_COUNT)
        throw std::runtime_error("TASK_VM_INFO with footprint peak is unavailable");
    return {info.resident_size, info.phys_footprint, info.resident_size_peak,
        static_cast<uint64_t>(info.ledger_phys_footprint_peak)};
}

std::string memoryJSON(const OfficeMemory& value)
{
    return "{\"rss\":" + std::to_string(value.resident)
        + ",\"footprint\":" + std::to_string(value.footprint)
        + ",\"rssLifetimePeak\":" + std::to_string(value.residentPeak)
        + ",\"footprintLifetimePeak\":" + std::to_string(value.footprintPeak) + "}";
}

struct ProbeInvocation {
    std::string cancelPhase, phases;
    bool cancelled = false;
};

void probePhase(const char* phase, void* opaque)
{
    auto& invocation = *static_cast<ProbeInvocation*>(opaque);
    if (!invocation.phases.empty()) invocation.phases += ",";
    uint64_t thread = 0;
    pthread_threadid_np(nullptr, &thread);
    invocation.phases += "{\"threadID\":" + std::to_string(thread) + ",\"phase\":" + jsonString(phase)
        + ",\"memory\":" + memoryJSON(officeMemory()) + "}";
    if (invocation.cancelPhase == phase) invocation.cancelled = true;
}
}

int officeMemoryProbe(int argc, char** argv)
{
    if (argc != 6) {
        std::fputs("Usage: office --memory-probe MANIFEST.tsv REPORT.jsonl PROGRAM_DIRECTORY main|owner|threads|concurrent|queued\n", stderr);
        return 2;
    }
    try {
        const std::string mode = argv[5];
        if (mode != "main" && mode != "owner" && mode != "threads" && mode != "concurrent" && mode != "queued")
            throw std::runtime_error("Unknown probe mode");
        std::ifstream manifest(argv[2]);
        if (!manifest) throw std::runtime_error("Cannot read manifest");
        std::vector<std::vector<std::string>> rows;
        for (std::string row; std::getline(manifest, row);) {
            std::vector<std::string> fields;
            std::istringstream stream(row);
            for (std::string field; std::getline(stream, field, '\t');) fields.push_back(field);
            if (fields.size() != 7) throw std::runtime_error("Expected 7 manifest columns");
            rows.push_back(std::move(fields));
        }
        const auto reportPath = fs::absolute(argv[3]);
        std::ofstream report(reportPath);
        if (!report) throw std::runtime_error("Cannot write report");
        report << "{\"event\":\"baseline\",\"mode\":" << jsonString(mode)
            << ",\"pid\":" << getpid()
            << ",\"memory\":" << memoryJSON(officeMemory()) << "}\n";
        report.flush();
        const std::string program = fs::canonical(argv[4]).string();
        const std::string directory = reportPath.parent_path().string();
        const std::string temporary = (reportPath.parent_path() / "runtime").string();
        fs::create_directories(temporary);
        std::mutex reportMutex;
        std::atomic<int> failures{0};
        auto run = [&](size_t index) {
            const auto& fields = rows[index];
            ProbeInvocation invocation{fields[6]};
            std::unique_ptr<FILE, decltype(&std::fclose)> output(std::tmpfile(), std::fclose);
            if (!output) { ++failures; return; }
            OfficeCommandContext context{output.get(), directory.c_str(), program.c_str(),
                temporary.c_str(), &invocation,
                [](const void* p) { return static_cast<const ProbeInvocation*>(p)->cancelled ? 1 : 0; },
                probePhase, &invocation, nullptr, 0, std::getenv("FONTCONFIG_FILE")};
            std::vector<std::string> arguments = {"office", fields[1], "--input", fields[2], "--output", fields[3]};
            if (fields[4] != "-") {
                arguments.push_back("--sheet");
                arguments.push_back(fields[4]);
            }
            std::vector<char*> pointers;
            for (auto& value : arguments) pointers.push_back(value.data());
            const auto started = ProbeClock::now();
            uint64_t callerThread = 0;
            pthread_threadid_np(nullptr, &callerThread);
            const auto before = officeMemory();
            std::atomic<bool> finished{false};
            uint64_t peakRSS = before.resident, peakFootprint = before.footprint;
            std::thread sampler([&] {
                while (!finished.load()) {
                    const auto memory = officeMemory();
                    peakRSS = std::max(peakRSS, memory.resident);
                    peakFootprint = std::max(peakFootprint, memory.footprint);
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
            });
            const int status = OfficeCommandRun(static_cast<int>(pointers.size()), pointers.data(), &context);
            const auto after = officeMemory();
            finished = true;
            sampler.join();
            peakRSS = std::max(peakRSS, after.resident);
            peakFootprint = std::max(peakFootprint, after.footprint);
            const double seconds = std::chrono::duration<double>(ProbeClock::now() - started).count();
            std::rewind(output.get());
            std::string result;
            char buffer[4096];
            while (std::fgets(buffer, sizeof buffer, output.get())) result += buffer;
            while (!result.empty() && result.back() == '\n') result.pop_back();
            if (status != std::stoi(fields[5])) ++failures;
            std::lock_guard<std::mutex> lock(reportMutex);
            report << "{\"event\":\"command\",\"index\":" << index << ",\"label\":" << jsonString(fields[0])
                << ",\"status\":" << status << ",\"seconds\":" << seconds
                << ",\"callerThread\":" << callerThread
                << ",\"before\":" << memoryJSON(before) << ",\"after\":" << memoryJSON(after)
                << ",\"sampledPeakRSS\":" << peakRSS << ",\"sampledPeakFootprint\":" << peakFootprint
                << ",\"phases\":[" << invocation.phases << "],\"result\":" << jsonString(result) << "}\n";
            report.flush();
        };
        if (mode == "queued") {
            // Host-level affinity: competing callers submit synchronous requests
            // to one persistent engine-owning thread, as ios_system can do.
            std::mutex queueMutex;
            std::condition_variable ready;
            std::queue<std::packaged_task<void()>> pending;
            bool stopping = false;
            std::thread owner([&] {
                for (;;) {
                    std::packaged_task<void()> task;
                    {
                        std::unique_lock<std::mutex> lock(queueMutex);
                        ready.wait(lock, [&] { return stopping || !pending.empty(); });
                        if (pending.empty()) return;
                        task = std::move(pending.front());
                        pending.pop();
                    }
                    task();
                }
            });
            std::atomic<size_t> next{0};
            std::vector<std::thread> callers;
            for (int i = 0; i < 4; ++i) callers.emplace_back([&] {
                for (size_t index; (index = next.fetch_add(1)) < rows.size();) {
                    std::packaged_task<void()> task([&, index] { run(index); });
                    auto done = task.get_future();
                    {
                        std::lock_guard<std::mutex> lock(queueMutex);
                        pending.push(std::move(task));
                    }
                    ready.notify_one();
                    done.get();
                }
            });
            for (auto& caller : callers) caller.join();
            {
                std::lock_guard<std::mutex> lock(queueMutex);
                stopping = true;
            }
            ready.notify_one();
            owner.join();
        } else if (mode == "concurrent") {
            // Initialize on the main thread first, then contend from four callers.
            if (!rows.empty()) run(0);
            std::atomic<size_t> next{1};
            std::vector<std::thread> callers;
            for (int i = 0; i < 4; ++i) callers.emplace_back([&] {
                for (size_t index; (index = next.fetch_add(1)) < rows.size();) run(index);
            });
            for (auto& caller : callers) caller.join();
        } else if (mode == "owner") {
            std::thread owner([&] {
                for (size_t i = 0; i < rows.size(); ++i) run(i);
            });
            owner.join();
        } else {
            for (size_t i = 0; i < rows.size(); ++i) {
                if (mode == "threads") { std::thread caller([&] { run(i); }); caller.join(); }
                else run(i);
            }
        }
        std::this_thread::sleep_for(std::chrono::seconds(2));
        report << "{\"event\":\"idle\",\"memory\":" << memoryJSON(officeMemory())
            << ",\"failures\":" << failures.load() << "}\n";
        report.close();
        // The Python host removes the profile after this process exits, so
        // engine-owned background threads cannot race profile cleanup.
        return failures.load() ? 1 : 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "memory probe: %s\n", error.what());
        return 1;
    }
}
