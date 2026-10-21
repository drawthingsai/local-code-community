#ifndef IOS_SYSTEM_SUPPORT_H
#define IOS_SYSTEM_SUPPORT_H

#include <dirent.h>
#include <err.h>
#include <getopt.h>
#include <limits.h>
#include <locale.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <utime.h>
#include <xlocale.h>
#include "ios_error.h"

/* Initialize at command entry and clean up at completion.
 * Commands own their resources; support owns only the thread locale. */
void ios_system_support_init(char **argv);
void ios_system_support_cleanup(void *unused);
void ios_system_exit(int status) __dead2;
FILE *ios_system_fopen(const char *path, const char *mode);
int ios_system_open(const char *path, int flags, ...);
int ios_system_mkstemp(char *path);
char *ios_system_mkdtemp(char *path);
char *ios_system_realpath(const char *path, char *resolved);
int ios_system_stat(const char *path, struct stat *info);
int ios_system_statfs(const char *path, struct statfs *info);
int ios_system_lstat(const char *path, struct stat *info);
DIR *ios_system_opendir(const char *path);
int ios_system_mkdir(const char *path, mode_t mode);
int ios_system_chmod(const char *path, mode_t mode);
int ios_system_chown(const char *path, uid_t owner, gid_t group);
int ios_system_utime(const char *path, const struct utimbuf *times);
ssize_t ios_system_readlink(const char *path, char *destination, size_t size);
int ios_system_rename(const char *source, const char *destination);
int ios_system_unlink(const char *path);
int ios_system_rmdir(const char *path);
int ios_system_scandir(const char *path, struct dirent ***entries,
    int (*select_entry)(const struct dirent *),
    int (*compare)(const struct dirent **, const struct dirent **));
void *ios_system_reallocarray(void *pointer, size_t count, size_t size);
int ios_system_expand_number(const char *text, uint64_t *value);
extern __thread int ios_system_optind, ios_system_opterr, ios_system_optopt, ios_system_optreset;
extern __thread char *ios_system_optarg;
int ios_system_getopt(int argc, char *const *argv, const char *options);
int ios_system_getopt_long(int argc, char *const *argv, const char *options,
    const struct option *long_options, int *index);
int ios_system_getopt_long_only(int argc, char *const *argv, const char *options,
    const struct option *long_options, int *index);

#ifndef IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#define optind ios_system_optind
#define opterr ios_system_opterr
#define optopt ios_system_optopt
#define optreset ios_system_optreset
#define optarg ios_system_optarg
#define getopt ios_system_getopt
#define getopt_long ios_system_getopt_long
#define getopt_long_only ios_system_getopt_long_only
#undef stdin
#undef stdout
#undef stderr
#define stdin thread_stdin
#define stdout thread_stdout
#define stderr thread_stderr
#undef STDIN_FILENO
#undef STDOUT_FILENO
#undef STDERR_FILENO
#define STDIN_FILENO fileno(thread_stdin)
#define STDOUT_FILENO fileno(thread_stdout)
#define STDERR_FILENO fileno(thread_stderr)
#undef exit
#define exit ios_system_exit
#undef iswprint
#define wprintf(...) fwprintf(thread_stdout, __VA_ARGS__)
#ifndef __FBSDID
#define __FBSDID(id)
#endif
#ifndef nitems
#define nitems(array) (sizeof(array) / sizeof((array)[0]))
#endif
#ifndef __dead
#define __dead __dead2
#endif
#ifndef COMPAT_MODE
#define COMPAT_MODE(command, mode) 1
#endif
#endif
#endif
