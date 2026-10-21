#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

#define IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#include "ios_system_support.h"

static __thread struct {
    locale_t locale, previous_locale;
    char directory[PATH_MAX];
} context;

void ios_system_support_init(char **argv)
{
    char *name = strrchr(argv[0], '/');
    if (name != NULL) argv[0] = name + 1;
    const char *locale = ios_getenv("LC_ALL");
    bool use_categories = locale == NULL || *locale == '\0';
    if (use_categories) locale = ios_getenv("LANG");
    if (locale == NULL || *locale == '\0') locale = "en_US.UTF-8";
    context.locale = newlocale(LC_ALL_MASK, locale, NULL);
    if (context.locale == NULL) context.locale = newlocale(LC_ALL_MASK, "C", NULL);
    if (use_categories && context.locale != NULL) {
        static const struct { const char *name; int mask; } categories[] = {
            {"LC_CTYPE", LC_CTYPE_MASK}, {"LC_COLLATE", LC_COLLATE_MASK},
            {"LC_NUMERIC", LC_NUMERIC_MASK}, {"LC_TIME", LC_TIME_MASK},
            {"LC_MONETARY", LC_MONETARY_MASK}, {"LC_MESSAGES", LC_MESSAGES_MASK},
        };
        for (size_t index = 0; index < sizeof(categories) / sizeof(categories[0]); ++index) {
            const char *name = ios_getenv(categories[index].name);
            if (name != NULL && *name != '\0') {
                locale_t updated = newlocale(categories[index].mask, name, context.locale);
                if (updated != NULL) context.locale = updated;
            }
        }
    }
    if (context.locale != NULL) context.previous_locale = uselocale(context.locale);
    const char *directory = ios_getenv("PWD");
    if (directory != NULL) {
        if (strlcpy(context.directory, directory, sizeof(context.directory)) >= sizeof(context.directory))
            errx(1, "working directory is too long");
    } else if (getcwd(context.directory, sizeof(context.directory)) == NULL) {
        err(1, "working directory");
    }
}

void ios_system_support_cleanup(void *unused)
{
    (void)unused;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (context.locale != NULL) {
        uselocale(context.previous_locale);
        freelocale(context.locale);
        context.locale = NULL;
    }
}

void ios_system_exit(int status)
{
    pthread_testcancel();
    if (fflush(thread_stdout) != 0 || ferror(thread_stdout)) {
        if (status == 0) status = 1;
    }
    ios_exit(status);
}

static const char *session_path(const char *path, char buffer[PATH_MAX])
{
    if (path[0] == '/' || path[0] == '\0') return path;
    if (snprintf(buffer, PATH_MAX, "%s/%s", context.directory, path) >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    return buffer;
}

int ios_system_stat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? stat(path, info) : -1;
}

int ios_system_statfs(const char *path, struct statfs *info)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? statfs(path, info) : -1;
}

int ios_system_unlink(const char *path)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? unlink(path) : -1;
}

int ios_system_rmdir(const char *path)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? rmdir(path) : -1;
}

char *ios_system_realpath(const char *path, char *resolved)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    if (path == NULL) return NULL;
    return realpath(path, resolved);
}

char *ios_system_mkdtemp(char *path)
{
    char buffer[PATH_MAX];
    const char *absolute = session_path(path, buffer);
    if (absolute == NULL || mkdtemp((char *)absolute) == NULL) return NULL;
    if (absolute != path) strcpy(path, absolute + strlen(context.directory) + 1);
    return path;
}

FILE *ios_system_fopen(const char *path, const char *mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    if (path == NULL) return NULL;
    return fopen(path, mode);
}

int ios_system_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    if (path == NULL) return -1;
    return open(path, flags, mode);
}

int ios_system_mkstemp(char *path)
{
    char buffer[PATH_MAX];
    const char *absolute = session_path(path, buffer);
    if (absolute == NULL) return -1;
    int fd = mkstemp((char *)absolute);
    if (fd >= 0 && absolute != path) strcpy(path, absolute + strlen(context.directory) + 1);
    return fd;
}

int ios_system_scandir(const char *path, struct dirent ***entries,
    int (*select_entry)(const struct dirent *),
    int (*compare)(const struct dirent **, const struct dirent **))
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    if (path == NULL) return -1;
    return scandir(path, entries, select_entry, compare);
}

int ios_system_expand_number(const char *text, uint64_t *value)
{
    char *end;
    errno = 0;
    if (*text < '0' || *text > '9') { errno = EINVAL; return -1; }
    uint64_t result = strtoull(text, &end, 10);
    if (errno != 0) return -1;
    if (*end != '\0') {
        const char *suffixes = "bkmgtpe";
        int suffix = *end;
        if (suffix >= 'A' && suffix <= 'Z') suffix += 'a' - 'A';
        const char *position = strchr(suffixes, suffix);
        if (position == NULL || end[1] != '\0') { errno = EINVAL; return -1; }
        for (ptrdiff_t power = position - suffixes; power > 0; --power) {
            if (result > UINT64_MAX / 1024) { errno = ERANGE; return -1; }
            result *= 1024;
        }
    }
    *value = result;
    return 0;
}

void *ios_system_reallocarray(void *pointer, size_t count, size_t size)
{
    if (size != 0 && count > SIZE_MAX / size) {
        errno = ENOMEM;
        return NULL;
    }
    return realloc(pointer, count * size);
}

int ios_system_lstat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? lstat(path, info) : -1;
}

DIR *ios_system_opendir(const char *path)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? opendir(path) : NULL;
}

int ios_system_mkdir(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? mkdir(path, mode) : -1;
}

int ios_system_chmod(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? chmod(path, mode) : -1;
}

int ios_system_chown(const char *path, uid_t owner, gid_t group)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? chown(path, owner, group) : -1;
}

int ios_system_utime(const char *path, const struct utimbuf *times)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? utime(path, times) : -1;
}

ssize_t ios_system_readlink(const char *path, char *destination, size_t size)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? readlink(path, destination, size) : -1;
}

int ios_system_rename(const char *source, const char *destination)
{
    char source_buffer[PATH_MAX], destination_buffer[PATH_MAX];
    source = session_path(source, source_buffer);
    destination = session_path(destination, destination_buffer);
    return source != NULL && destination != NULL ? rename(source, destination) : -1;
}
