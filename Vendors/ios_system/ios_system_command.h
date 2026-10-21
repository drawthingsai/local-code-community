#ifndef ios_system_command_h
#define ios_system_command_h

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*ios_command_main)(int argc, char **argv);

// Registers a command implemented by a conventional C main function.
// Returns 1 on success and 0 when the name or function is invalid, allocation
// fails, or the name is already registered.
int ios_registerCommand(const char *commandName, ios_command_main commandMain);

// For commands that disable pthread cancellation and unwind cooperatively.
// The context can be read from worker threads; it is valid until the owning
// ios_system session is closed. A NULL context is never cancelled.
const void *ios_getCommandCancellationContext(void);
int ios_commandCancellationRequested(const void *context);

#ifdef __cplusplus
}
#endif

#endif
