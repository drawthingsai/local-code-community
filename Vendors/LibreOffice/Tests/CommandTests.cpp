// Exercise the shipped C ABI without initializing LibreOffice or loading files.
#include "Vendors/LibreOffice/OfficeCommand.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <future>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

using namespace std::chrono_literals;

static void require(bool value, const char* message)
{
    if (!value) {
        std::fprintf(stderr, "%s\n", message);
        std::_Exit(1); // A failed check must not wait for a deliberately blocked worker.
    }
}

struct Invocation {
    FILE* output = std::tmpfile();
    OfficeCommandContext context{output, "/", "/", "/", nullptr, nullptr,
                                 nullptr, nullptr, nullptr, 0, nullptr};
    Invocation() { require(output != nullptr, "tmpfile failed"); }
    ~Invocation() { std::fclose(output); }
    int run()
    {
        char command[] = "office", help[] = "convert";
        char* argv[] = {command, help};
        try { return OfficeCommandRun(2, argv, &context); }
        catch (...) { require(false, "C++ exception escaped the C ABI"); return -1; }
    }
    std::string result()
    {
        std::rewind(output);
        char buffer[4096];
        const size_t size = std::fread(buffer, 1, sizeof buffer, output);
        return std::string(buffer, size);
    }
};

struct Gate {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false, released = false;
    static void phase(const char*, void* opaque)
    {
        auto& gate = *static_cast<Gate*>(opaque);
        std::unique_lock<std::mutex> lock(gate.mutex);
        gate.entered = true;
        gate.changed.notify_all();
        gate.changed.wait(lock, [&] { return gate.released; });
    }
    void wait()
    {
        std::unique_lock<std::mutex> lock(mutex);
        require(changed.wait_for(lock, 2s, [&] { return entered; }), "owner never entered gate");
    }
    void release()
    {
        std::lock_guard<std::mutex> lock(mutex);
        released = true;
        changed.notify_all();
    }
};

int main()
{
    // Unknown and standard exceptions on the owner become JSON failures; the
    // same persistent thread must accept the following invocation.
    for (int kind = 0; kind != 2; ++kind) {
        Invocation invocation;
        invocation.context.phaseContext = &kind;
        invocation.context.phase = [](const char*, void* value) {
            if (*static_cast<int*>(value)) throw std::runtime_error("phase failure");
            throw 42;
        };
        require(invocation.run() == 1, "phase exception status");
        require(invocation.result().find(kind ? "phase failure" : "Unknown Office exception")
                    != std::string::npos, "phase exception diagnostic");
    }
    std::atomic<int> unexpectedPhases{0};
    for (int kind = 0; kind != 3; ++kind) {
        Gate gate;
        Invocation active;
        active.context.phase = Gate::phase;
        active.context.phaseContext = &gate;
        auto first = std::async(std::launch::async, [&] { return active.run(); });
        gate.wait();
        // Discovery bypasses both the blocked owner and all resource/session requirements.
        Invocation help;
        help.context.directory = help.context.programDirectory = help.context.temporaryDirectory = nullptr;
        char command[] = "office", option[] = "--help";
        char* args[] = {command, option};
        require(OfficeCommandRun(2, args, &help.context) == 0, "help waited on the owner or needed resources");
        require(help.result().find("office render") != std::string::npos, "help omitted render");
        Invocation capabilities;
        capabilities.context.directory = capabilities.context.programDirectory = capabilities.context.temporaryDirectory = nullptr;
        char discovery[] = "capabilities";
        char* discoveryArgs[] = {command, discovery};
        require(OfficeCommandRun(2, discoveryArgs, &capabilities.context) == 0, "capabilities waited on the owner or needed resources");
        require(capabilities.result().find("imageRendering") != std::string::npos, "capabilities omitted rendering");
        // The queued invocation owns its context, argv and FILE locally. They
        // are destroyed on return while the first request is still blocked.
        std::atomic<bool> polled{false}, cancelled{false};
        auto queued = std::async(std::launch::async, [&] {
            Invocation invocation;
            struct Cancellation {
                std::atomic<bool>& polled;
                std::atomic<bool>& cancelled;
                int kind;
            } state{polled, cancelled, kind};
            invocation.context.cancellation = &state;
            invocation.context.isCancelled = [](const void* opaque) -> int {
                const auto& state = *static_cast<const Cancellation*>(opaque);
                state.polled = true;
                if (state.kind == 1) throw 42;
                if (state.kind == 2) throw std::runtime_error("poll failure");
                return state.cancelled ? 1 : 0;
            };
            invocation.context.phaseContext = &unexpectedPhases;
            invocation.context.phase = [](const char*, void* opaque) {
                ++*static_cast<std::atomic<int>*>(opaque);
            };
            const int status = invocation.run();
            require(invocation.result().find(kind == 0 ? "Office command cancelled" :
                        kind == 1 ? "Unknown Office exception" : "poll failure") != std::string::npos,
                    "queued failure diagnostic");
            return status;
        });
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (!polled && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(1ms);
        require(polled, "queued caller did not poll cancellation");
        cancelled = true;
        require(queued.wait_for(2s) == std::future_status::ready,
                "queued caller remained stuck behind active request");
        require(queued.get() == (kind ? 1 : 130), "queued cancellation/exception status");
        gate.release();
        require(first.wait_for(2s) == std::future_status::ready && first.get() == 1,
                "active request failed after queued cancellation");
        Invocation following;
        require(following.run() == 1, "owner did not recover");
        require(unexpectedPhases == 0, "cancelled request executed after its caller returned");
    }
    // A claimed request still owns its borrowed context until it completes.
    Gate gate;
    Invocation active;
    std::atomic<bool> cancelled{false};
    active.context.phase = Gate::phase;
    active.context.phaseContext = &gate;
    active.context.cancellation = &cancelled;
    active.context.isCancelled = [](const void* value) {
        return static_cast<const std::atomic<bool>*>(value)->load() ? 1 : 0;
    };
    auto running = std::async(std::launch::async, [&] { return active.run(); });
    gate.wait();
    cancelled = true;
    require(running.wait_for(150ms) == std::future_status::timeout,
            "active request released borrowed context prematurely");
    gate.release();
    require(running.wait_for(2s) == std::future_status::ready && running.get() == 130,
            "active request did not cancel at the next phase boundary");
    Invocation following;
    require(following.run() == 1, "owner failed final recovery");
    std::puts("Office C ABI exception and queued cancellation tests passed");
    return 0;
}
