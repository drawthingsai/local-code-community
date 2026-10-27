#ifndef IOS_SYSTEM_SUPPORT_H
#define IOS_SYSTEM_SUPPORT_H

#include <copyfile.h>
#include <dirent.h>
#include <err.h>
#include <fts.h>
#include <getopt.h>
#include <grp.h>
#include <libgen.h>
#include <limits.h>
#include <locale.h>
#include <pwd.h>
#include <removefile.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/time.h>
#include <unistd.h>
#include <utime.h>
#include <wchar.h>
#include <xlocale.h>
#include "ios_error.h"

/* Initialize at command entry and clean up at completion.
 * Commands own their resources; support owns only the thread locale. */
void ios_system_support_init(char **argv);
/* Only the invocation's directory (PWD, else the session's), for code that
 * calls the path functions below without the rest of ios_system_support_init.
 * ios_system_chdir and ios_system_getcwd change and report it, not the
 * process's working directory. */
void ios_system_support_init_directory(void);
int ios_system_chdir(const char *path);
char *ios_system_getcwd(char *buffer, size_t size);
void ios_system_support_cleanup(void *unused);
void ios_system_exit(int status) __dead2;
/* The host blocks SIGPIPE, so a write into a closed pipeline fails with
 * EPIPE instead. Stop quietly with the status the signal would give. */
void ios_system_stop_on_broken_pipe(FILE *stream);
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
/* A relative path resolved from the session directory, for system calls
 * without a wrapper here. Returns path itself when it is absolute. */
const char *ios_system_session_path(const char *path, char buffer[PATH_MAX]);
int ios_system_access(const char *path, int mode);
int ios_system_link(const char *source, const char *destination);
/* The target is stored verbatim; only the new link's path is resolved. */
int ios_system_symlink(const char *target, const char *path);
int ios_system_utimes(const char *path, const struct timeval times[2]);
int ios_system_lutimes(const char *path, const struct timeval times[2]);
int ios_system_chflags(const char *path, unsigned int flags);
int ios_system_lchflags(const char *path, unsigned int flags);
int ios_system_lchown(const char *path, uid_t owner, gid_t group);
int ios_system_lchmod(const char *path, mode_t mode);
long ios_system_pathconf(const char *path, int name);
int ios_system_mkfifo(const char *path, mode_t mode);
int ios_system_mknod(const char *path, mode_t mode, dev_t device);
ssize_t ios_system_listxattr(const char *path, char *names, size_t size, int options);
ssize_t ios_system_getxattr(const char *path, const char *name, void *value, size_t size,
    u_int32_t position, int options);
acl_t ios_system_acl_get_link_np(const char *path, acl_type_t type);
int ios_system_copyfile(const char *from, const char *to, copyfile_state_t state, copyfile_flags_t flags);
int ios_system_removefile(const char *path, removefile_state_t state, removefile_flags_t flags);
int ios_system_clonefile(const char *source, const char *destination, uint32_t flags);
/* umask(2) is process-wide and only readable by setting it, which other
 * sessions' file creation would observe. Read it without changing it. */
mode_t ios_system_umask(void);
/* setmode(3) and getmode(3) without touching the process umask. Free the
 * result of ios_system_setmode with free(). */
void *ios_system_setmode(const char *mode);
mode_t ios_system_getmode(const void *set, mode_t mode);
/* Walks relative operands from the session directory. Entries keep absolute
 * paths for system calls; ios_system_fts_path and ios_system_fts_name return
 * them as the user wrote the operand. Returned names stay valid for the next
 * three calls. */
FTS *ios_system_fts_open(char * const *paths, int options,
    int (*compare)(const FTSENT **, const FTSENT **));
const char *ios_system_fts_path(const FTSENT *entry);
const char *ios_system_fts_name(const FTSENT *entry);
/* Thread-safe replacements for libc's shared caches and buffers. */
char *ios_system_user_from_uid(uid_t uid, int nouser);
char *ios_system_group_from_gid(gid_t gid, int nogroup);
char *ios_system_getbsize(int *header_length, long *block_size);
/* The invocation's locale with the categories in mask set to name, for code
 * that needs, say, numbers in "C" for a while. Shared; never free it. */
locale_t ios_system_locale_with(int mask, const char *name);
/* A shared locale whose character type is name, "" taking it from the
 * session's LC_ALL, LC_CTYPE or LANG: for code that would call setlocale. */
locale_t ios_system_ctype_locale(const char *name);
/* libc keeps these results in storage the whole process shares: the user and
 * group databases' (which another thread's lookup frees), getlogin's and
 * basename's buffers, and the conversion state of mbtowc, mblen, wctomb and of
 * the restartable functions given no state, which sits in the locale object
 * that invocations share. These keep it per thread, valid like libc's until
 * the next call of the same kind or the end of the invocation. */
struct passwd *ios_system_getpwuid(uid_t uid);
struct passwd *ios_system_getpwnam(const char *name);
struct group *ios_system_getgrgid(gid_t gid);
struct group *ios_system_getgrnam(const char *name);
char *ios_system_getlogin(void);
char *ios_system_basename(char *path);
int ios_system_mbtowc(wchar_t *wc, const char *s, size_t n);
int ios_system_mblen(const char *s, size_t n);
int ios_system_wctomb(char *s, wchar_t wc);
size_t ios_system_mbrtowc(wchar_t *wc, const char *s, size_t n, mbstate_t *state);
size_t ios_system_mbrlen(const char *s, size_t n, mbstate_t *state);
size_t ios_system_wcrtomb(char *s, wchar_t wc, mbstate_t *state);
size_t ios_system_mbsrtowcs(wchar_t *destination, const char **source, size_t n, mbstate_t *state);
size_t ios_system_wcsrtombs(char *destination, const wchar_t **source, size_t n, mbstate_t *state);
/* random(3) with per-thread state: the same generator, so seeded sequences match. */
long ios_system_random(void);
void ios_system_srandom(unsigned int seed);
void *ios_system_reallocarray(void *pointer, size_t count, size_t size);
int ios_system_expand_number(const char *text, uint64_t *value);
extern __thread int ios_system_optind, ios_system_opterr, ios_system_optopt, ios_system_optreset;
extern __thread char *ios_system_optarg;
int *ios_system_optind_location(void);
int *ios_system_opterr_location(void);
int *ios_system_optopt_location(void);
int *ios_system_optreset_location(void);
char **ios_system_optarg_location(void);
int ios_system_getopt(int argc, char *const *argv, const char *options);
int ios_system_getopt_long(int argc, char *const *argv, const char *options,
    const struct option *long_options, int *index);
int ios_system_getopt_long_only(int argc, char *const *argv, const char *options,
    const struct option *long_options, int *index);

#ifndef IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#define getpwuid ios_system_getpwuid
#define getpwnam ios_system_getpwnam
#define getgrgid ios_system_getgrgid
#define getgrnam ios_system_getgrnam
#define getlogin ios_system_getlogin
#define basename ios_system_basename
#define mbtowc ios_system_mbtowc
#define mblen ios_system_mblen
#define wctomb ios_system_wctomb
#define mbrtowc ios_system_mbrtowc
#define mbrlen ios_system_mbrlen
#define wcrtomb ios_system_wcrtomb
#define mbsrtowcs ios_system_mbsrtowcs
#define wcsrtombs ios_system_wcsrtombs
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
