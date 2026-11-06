#ifndef CURL_PORT_H
#define CURL_PORT_H

// Forced into every curl source (-include CurlPort.h). curl runs as an
// ios_system command: sessions run commands concurrently in one process.

// Declare the libc calls first, so the mappings below cannot rewrite the Apple
// SDK declarations when a later include would otherwise reach them.
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <utime.h>
#include <wchar.h>
#include <wctype.h>

#ifdef CURL_PORT_TOOL
// The command itself: exit, signals and the standard streams go through
// ios_system, as in its other commands.
#include "ios_error.h"
#else
// libcurl reads the invoking session's environment (proxies, CURL_HOME).
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;
char *ios_getenv(const char *name);
#define getenv ios_getenv
#endif

// Default and diagnostic streams are the invoking command's.
#undef stdin
#define stdin thread_stdin
#undef stdout
#define stdout thread_stdout
#undef stderr
#define stderr thread_stderr
#undef STDIN_FILENO
#define STDIN_FILENO fileno(thread_stdin)
#undef STDOUT_FILENO
#define STDOUT_FILENO fileno(thread_stdout)
#undef STDERR_FILENO
#define STDERR_FILENO fileno(thread_stderr)

// Relative paths resolve against the invocation's directory, not the process
// working directory another session may have moved (as in OpenSSH). curl_main
// sets that directory up before the tool runs.
void ios_system_support_init_directory(void);
int ios_system_open(const char *path, int flags, ...);
FILE *ios_system_fopen(const char *path, const char *mode);
int ios_system_stat(const char *path, struct stat *info);
int ios_system_unlink(const char *path);
int ios_system_rename(const char *source, const char *destination);
int ios_system_mkdir(const char *path, mode_t mode);
int ios_system_utime(const char *path, const struct utimbuf *times);
int ios_system_utimes(const char *path, const struct timeval times[2]);
DIR *ios_system_opendir(const char *path);
char *ios_system_realpath(const char *path, char *resolved);
#define open(...) ios_system_open(__VA_ARGS__)
#define fopen(path, mode) ios_system_fopen(path, mode)
#define stat(path, info) ios_system_stat(path, info)
#define unlink(path) ios_system_unlink(path)
#define rename(source, destination) ios_system_rename(source, destination)
#define mkdir(path, mode) ios_system_mkdir(path, mode)
#define utime(path, times) ios_system_utime(path, times)
#define utimes(path, times) ios_system_utimes(path, times)
#define opendir(path) ios_system_opendir(path)
#define realpath(path, resolved) ios_system_realpath(path, resolved)

#endif
