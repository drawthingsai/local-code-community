#ifndef LOCAL_CODE_NODE_MOBILE_H_
#define LOCAL_CODE_NODE_MOBILE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int node_start(int argc, char* argv[]);

typedef struct {
  // Must be nonzero and unique among queued or running commands.
  uint64_t command_identifier;
  const char* working_directory;
  const char* preload_path;
  const char* const* environment;
  int stdin_fd;
  int stdout_fd;
  int stderr_fd;
} node_mobile_command_options;

// Registers stable command state before the command's worker thread becomes
// externally cancellable.
int node_mobile_prepare_command(uint64_t command_identifier);

// Initializes Node and V8 once per process, then runs one disposable Node
// Environment for a prepared command. Calls are serialized by the host.
int node_mobile_run_command(
    int argc,
    char* argv[],
    const node_mobile_command_options* options);

// Cancels one running or queued command without tearing down the
// process-lifetime Node/V8 platform.
int node_mobile_cancel_command(uint64_t command_identifier);

// Releases a prepared command after node_mobile_run_command has returned and
// reports whether cancellation won the command/cleanup race.
int node_mobile_finish_command(
    uint64_t command_identifier, int* cancellation_requested);

#ifdef __cplusplus
}
#endif

#endif  // LOCAL_CODE_NODE_MOBILE_H_
