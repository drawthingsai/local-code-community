#ifndef HF_XET_H
#define HF_XET_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  HF_XET_DOWNLOAD_SUCCESS = 0,
  HF_XET_DOWNLOAD_FAILURE = 1,
  HF_XET_DOWNLOAD_CANCELLED = 2,
};

typedef void (*HFXetProgressCallback)(void *context, uint64_t completed_bytes,
                                      uint64_t transferred_bytes,
                                      uint64_t total_bytes);
typedef void (*HFXetCompletionCallback)(void *download_handle, void *context,
                                       int32_t status,
                                       const char *error_message);

// Starts an asynchronous download. All string inputs are copied before this
// function returns. The completion callback fires exactly once. Release the
// handle from or after that callback with hf_xet_download_release.
//
// Downloads write the file in order. If destination_path already holds the
// start of the file from an earlier attempt, the download continues after it,
// and progress counts those bytes. A file that fails SHA-256 verification is
// removed.
void *hf_xet_download_start(const char *refresh_url, const char *file_hash,
                            uint64_t file_size,
                            const char *expected_sha256,
                            const char *destination_path, void *context,
                            HFXetProgressCallback progress_callback,
                            HFXetCompletionCallback completion_callback);

// Cancellation is idempotent. Completion is still reported exactly once.
void hf_xet_download_cancel(void *download_handle);

// The handle must be released exactly once, after completion.
void hf_xet_download_release(void *download_handle);

#ifdef __cplusplus
}
#endif

#endif
