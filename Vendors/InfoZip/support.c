#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "support.h"

struct tm *infozip_localtime(const time_t *clock)
{
    static __thread struct tm result;
    return localtime_r(clock, &result);
}

struct tm *infozip_gmtime(const time_t *clock)
{
    static __thread struct tm result;
    return gmtime_r(clock, &result);
}

char *infozip_asctime(const struct tm *time)
{
    static __thread char result[26];
    return asctime_r(time, result);
}

void infozip_perror(const char *message)
{
    int error = errno;
    char buffer[256];
    if (strerror_r(error, buffer, sizeof(buffer)) != 0)
        snprintf(buffer, sizeof(buffer), "Error %d", error);
    fprintf(stderr, "%s%s%s\n", message, *message ? ": " : "", buffer);
}

/* Older supported OS releases lack RESOLVE_BENEATH. Walk directory descriptors
 * there, refusing directory symlinks instead of silently dropping containment.
 * The final component remains in buffer until the caller finishes its operation. */
static int parent_directory(int directory, const char *path, char buffer[PATH_MAX], char **name)
{
    if (*path == '/' || strlcpy(buffer, path, PATH_MAX) >= PATH_MAX) {
        errno = *path == '/' ? EPERM : ENAMETOOLONG;
        return -1;
    }
    int parent = dup(directory);
    if (parent < 0) return -1;
    char *cursor = buffer, *component;
    while ((component = strsep(&cursor, "/")) != NULL) {
        if (!strcmp(component, "..")) { close(parent); errno = EPERM; return -1; }
        if (cursor == NULL) { *name = component; return parent; }
        if (*component == '\0' || !strcmp(component, ".")) continue;
        int next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int error = errno;
        close(parent);
        if (next < 0) { errno = error; return -1; }
        parent = next;
    }
    close(parent);
    errno = EINVAL;
    return -1;
}

int infozip_openat(int directory, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
#ifndef INFOZIP_TEST_PORTABLE_EXTRACTION
    if (__builtin_available(macOS 26.0, iOS 26.0, *))
        return openat(directory, path, flags, mode);
#endif
    if (!(flags & O_RESOLVE_BENEATH)) return openat(directory, path, flags, mode);
    char buffer[PATH_MAX], *name;
    int parent = parent_directory(directory, path, buffer, &name);
    if (parent < 0) return -1;
    flags = (flags & ~O_RESOLVE_BENEATH) | O_NOFOLLOW;
    if ((flags & O_SEARCH) == O_SEARCH) flags = (flags & ~O_SEARCH) | O_RDONLY | O_DIRECTORY;
    int result = openat(parent, name, flags, mode), error = errno;
    close(parent);
    errno = error;
    return result;
}

int infozip_fstatat(int directory, const char *path, struct stat *info, int flags)
{
#ifndef INFOZIP_TEST_PORTABLE_EXTRACTION
    if (__builtin_available(macOS 26.0, iOS 26.0, *))
        return fstatat(directory, path, info, flags);
#endif
    if (!(flags & AT_RESOLVE_BENEATH)) return fstatat(directory, path, info, flags);
    char buffer[PATH_MAX], *name;
    int parent = parent_directory(directory, path, buffer, &name);
    if (parent < 0) return -1;
    int result = fstatat(parent, name, info, (flags & ~AT_RESOLVE_BENEATH) | AT_SYMLINK_NOFOLLOW);
    int error = errno;
    close(parent);
    errno = error;
    return result;
}

int infozip_unlinkat(int directory, const char *path, int flags)
{
#ifndef INFOZIP_TEST_PORTABLE_EXTRACTION
    if (__builtin_available(macOS 26.0, iOS 26.0, *))
        return unlinkat(directory, path, flags);
#endif
    char buffer[PATH_MAX], *name;
    int parent = parent_directory(directory, path, buffer, &name);
    if (parent < 0) return -1;
    int result = unlinkat(parent, name, flags & AT_REMOVEDIR), error = errno;
    close(parent);
    errno = error;
    return result;
}

int infozip_mblen(const char *text, size_t size)
{
    static __thread mbstate_t state;
    if (text == NULL) { memset(&state, 0, sizeof(state)); return 0; }
    size_t result = mbrlen(text, size, &state);
    return result == (size_t)-1 || result == (size_t)-2 ? -1 : (int)result;
}

int infozip_wctomb(char *text, wchar_t value)
{
    static __thread mbstate_t state;
    if (text == NULL) { memset(&state, 0, sizeof(state)); return 0; }
    size_t result = wcrtomb(text, value, &state);
    return result == (size_t)-1 ? -1 : (int)result;
}

const char *infozip_strerror(int error)
{
    static __thread char buffer[256];
    if (strerror_r(error, buffer, sizeof(buffer)) != 0)
        snprintf(buffer, sizeof(buffer), "Error %d", error);
    return buffer;
}
