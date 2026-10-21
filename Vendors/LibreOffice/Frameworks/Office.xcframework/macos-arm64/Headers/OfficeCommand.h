#pragma once
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Synchronous C ABI. Pointers are borrowed until return. Callbacks must not
// reenter this API. Concurrent callers are queued; queued cancellation removes
// the request and returns 130 without waiting for the engine owner thread.
// The host keeps the program resources and temp root alive for the process lifetime. Configuration is immutable after the first conversion.
// After execution starts, cancellation is cooperative at operation boundaries;
// it cannot abort a stuck LibreOffice call. Never pthread_cancel the engine owner thread.
typedef struct {
    FILE* output;
    const char* directory;
    const char* programDirectory;
    const char* temporaryDirectory;
    const void* cancellation;
    // Must return promptly. Polled on the caller while queued and on the engine
    // owner while running; these callbacks never overlap for one invocation.
    int (*isCancelled)(const void*);
    // Optional diagnostic hook, called on the engine owner thread.
    void (*phase)(const char*, void*);
    void* phaseContext;
    const char* const* fontFiles;
    size_t fontFileCount;
    // Optional fontconfig file. NULL selects private system-font discovery.
    const char* fontConfiguration;
    // Error stream; NULL uses output for native diagnostic hosts.
    FILE* error;
    // Optional caller-visible paths, preserved in JSON after host alias resolution.
    const char* inputPath;
    const char* outputPath;
    // Reusable fontconfig cache, independent of the per-process profile.
    const char* cacheDirectory;
} OfficeCommandContext;

__attribute__((visibility("default")))
int OfficeCommandRun(int argc, char** argv, const OfficeCommandContext* context);

#ifdef __cplusplus
}
#endif
