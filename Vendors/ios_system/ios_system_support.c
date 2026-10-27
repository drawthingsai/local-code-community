#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/xattr.h>
#include <unistd.h>

#define IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#include "ios_system_support.h"

static __thread struct {
    locale_t locale, previous_locale;
    char locale_key[256];
    char directory[PATH_MAX];
} context;

/*
 * Locale objects are shared by every invocation with the same settings and
 * kept for the life of the process: creating and freeing one per command on
 * concurrent threads races in libc's shared locale data (localeconv() then
 * finds a numeric category without a decimal point). A locale object may be
 * used by several threads at once.
 */
static pthread_mutex_t shared_locale_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct shared_locale {
    struct shared_locale *next;
    locale_t locale;
    char key[];
} *shared_locales;

static locale_t shared_locale(const char *key, locale_t (*create)(const char *key, void *argument),
    void *argument)
{
    pthread_mutex_lock(&shared_locale_mutex);
    struct shared_locale *entry = shared_locales;
    while (entry != NULL && strcmp(entry->key, key) != 0) entry = entry->next;
    if (entry == NULL) {
        locale_t locale = create(key, argument);
        // localeconv fills its table lazily inside the locale object: fill
        // it now, before threads sharing the object read it.
        if (locale != NULL) (void)localeconv_l(locale);
        size_t length = strlen(key) + 1;
        if (locale != NULL && (entry = malloc(sizeof(*entry) + length)) != NULL) {
            entry->locale = locale;
            memcpy(entry->key, key, length);
            entry->next = shared_locales;
            shared_locales = entry;
        } else if (locale != NULL) {
            freelocale(locale);
        }
    }
    pthread_mutex_unlock(&shared_locale_mutex);
    return entry != NULL ? entry->locale : NULL;
}

static const struct { const char *name; int mask; } locale_categories[] = {
    {"LC_CTYPE", LC_CTYPE_MASK}, {"LC_COLLATE", LC_COLLATE_MASK},
    {"LC_NUMERIC", LC_NUMERIC_MASK}, {"LC_TIME", LC_TIME_MASK},
    {"LC_MONETARY", LC_MONETARY_MASK}, {"LC_MESSAGES", LC_MESSAGES_MASK},
};

/* Applies "name=value" pairs from a key written by ios_system_support_init. */
static locale_t create_session_locale(const char *key, void *argument)
{
    (void)argument;
    char base[128] = "en_US.UTF-8";
    const char *separator = strchr(key, '|');
    size_t length = separator != NULL ? (size_t)(separator - key) : strlen(key);
    if (length > 0 && length < sizeof(base)) {
        memcpy(base, key, length);
        base[length] = '\0';
    }
    locale_t locale = newlocale(LC_ALL_MASK, base, NULL);
    if (locale == NULL) locale = newlocale(LC_ALL_MASK, "C", NULL);
    for (const char *field = separator; locale != NULL && field != NULL; field = strchr(field + 1, '|')) {
        const char *equals = strchr(field, '=');
        const char *end = strchr(field + 1, '|');
        if (equals == NULL || (end != NULL && equals > end)) continue;
        char value[128];
        size_t value_length = (end != NULL ? (size_t)(end - equals) : strlen(equals)) - 1;
        if (value_length == 0 || value_length >= sizeof(value)) continue;
        memcpy(value, equals + 1, value_length);
        value[value_length] = '\0';
        for (size_t index = 0; index < sizeof(locale_categories) / sizeof(locale_categories[0]); ++index) {
            size_t name_length = strlen(locale_categories[index].name);
            if ((size_t)(equals - field - 1) == name_length &&
                strncmp(field + 1, locale_categories[index].name, name_length) == 0) {
                locale_t updated = newlocale(locale_categories[index].mask, value, locale);
                // Darwin returns a new locale and keeps the base allocated.
                if (updated != NULL && updated != locale) freelocale(locale);
                if (updated != NULL) locale = updated;
            }
        }
    }
    return locale;
}

extern const char *ios_currentSessionDirectory(void); /* defined in ios_system.m */

/* Relative FTS operands rewritten from the session directory. */
static __thread struct fts_root {
    char *absolute, *original;
    size_t absolute_length;
} *fts_roots;
static __thread size_t fts_root_count;
static __thread struct {
    char *text;
    size_t size;
} fts_names[3];
static __thread unsigned fts_name_index;

void ios_system_support_init(char **argv)
{
    char *name = strrchr(argv[0], '/');
    if (name != NULL) argv[0] = name + 1;
    const char *locale = ios_getenv("LC_ALL");
    bool use_categories = locale == NULL || *locale == '\0';
    if (use_categories) locale = ios_getenv("LANG");
    if (locale == NULL || *locale == '\0') locale = "en_US.UTF-8";
    // The key names the settings: base locale, then "|LC_X=value" overrides.
    strlcpy(context.locale_key, locale, sizeof(context.locale_key));
    for (size_t index = 0; use_categories && index < sizeof(locale_categories) / sizeof(locale_categories[0]); ++index) {
        const char *name = ios_getenv(locale_categories[index].name);
        if (name != NULL && *name != '\0') {
            strlcat(context.locale_key, "|", sizeof(context.locale_key));
            strlcat(context.locale_key, locale_categories[index].name, sizeof(context.locale_key));
            strlcat(context.locale_key, "=", sizeof(context.locale_key));
            strlcat(context.locale_key, name, sizeof(context.locale_key));
        }
    }
    context.locale = shared_locale(context.locale_key, create_session_locale, NULL);
    if (context.locale != NULL) context.previous_locale = uselocale(context.locale);
    ios_system_support_init_directory();
}

void ios_system_support_init_directory(void)
{
    // Without PWD, the session's directory: the process's may be another
    // session's.
    const char *directory = ios_getenv("PWD");
    if (directory == NULL) directory = ios_currentSessionDirectory();
    if (directory != NULL) {
        if (strlcpy(context.directory, directory, sizeof(context.directory)) >= sizeof(context.directory))
            errx(1, "working directory is too long");
    } else if (getcwd(context.directory, sizeof(context.directory)) == NULL) {
        err(1, "working directory");
    }
}

/* Per-thread results of the lookups libc keeps process-wide. */
static __thread struct passwd user_entry;
static __thread struct group group_entry;
static __thread struct {
    char *bytes;
    size_t size;
} user_storage, group_storage;
static __thread char login_name[MAXLOGNAME];
static __thread char base_name[MAXPATHLEN];
static __thread mbstate_t mbtowc_state, mblen_state, wctomb_state, mbrtowc_state, mbrlen_state,
    wcrtomb_state, mbsrtowcs_state, wcsrtombs_state;

/* The first size to try, then double while a lookup reports ERANGE. */
static bool grow_storage(char **bytes, size_t *size, bool retry)
{
    if (*size != 0 && !retry) return true;
    size_t wanted = *size == 0 ? 1024 : *size * 2;
    if (wanted > (1 << 20)) return false;
    char *grown = realloc(*bytes, wanted);
    if (grown == NULL) return false;
    *bytes = grown;
    *size = wanted;
    return true;
}

#define LOOKUP(storage, call) \
    do { \
        int error = ERANGE; \
        for (bool retry = false; error == ERANGE; retry = true) { \
            if (!grow_storage(&storage.bytes, &storage.size, retry)) return NULL; \
            error = (call); \
        } \
        if (error != 0) errno = error; \
        return error == 0 ? result : NULL; \
    } while (0)

struct passwd *ios_system_getpwuid(uid_t uid)
{
    struct passwd *result = NULL;
    LOOKUP(user_storage, getpwuid_r(uid, &user_entry, user_storage.bytes, user_storage.size, &result));
}

struct passwd *ios_system_getpwnam(const char *name)
{
    struct passwd *result = NULL;
    LOOKUP(user_storage, getpwnam_r(name, &user_entry, user_storage.bytes, user_storage.size, &result));
}

struct group *ios_system_getgrgid(gid_t gid)
{
    struct group *result = NULL;
    LOOKUP(group_storage, getgrgid_r(gid, &group_entry, group_storage.bytes, group_storage.size, &result));
}

struct group *ios_system_getgrnam(const char *name)
{
    struct group *result = NULL;
    LOOKUP(group_storage, getgrnam_r(name, &group_entry, group_storage.bytes, group_storage.size, &result));
}

#undef LOOKUP

char *ios_system_getlogin(void)
{
    return getlogin_r(login_name, sizeof(login_name)) == 0 ? login_name : NULL;
}

char *ios_system_basename(char *path)
{
    return basename_r(path, base_name);
}

int ios_system_mbtowc(wchar_t *wc, const char *s, size_t n)
{
    if (s == NULL) {
        memset(&mbtowc_state, 0, sizeof(mbtowc_state));
        return 0;
    }
    size_t length = mbrtowc(wc, s, n, &mbtowc_state);
    return length == (size_t)-1 || length == (size_t)-2 ? -1 : (int)length;
}

int ios_system_mblen(const char *s, size_t n)
{
    if (s == NULL) {
        memset(&mblen_state, 0, sizeof(mblen_state));
        return 0;
    }
    size_t length = mbrlen(s, n, &mblen_state);
    return length == (size_t)-1 || length == (size_t)-2 ? -1 : (int)length;
}

int ios_system_wctomb(char *s, wchar_t wc)
{
    if (s == NULL) {
        memset(&wctomb_state, 0, sizeof(wctomb_state));
        return 0;
    }
    size_t length = wcrtomb(s, wc, &wctomb_state);
    return length == (size_t)-1 ? -1 : (int)length;
}

size_t ios_system_mbrtowc(wchar_t *wc, const char *s, size_t n, mbstate_t *state)
{
    return mbrtowc(wc, s, n, state != NULL ? state : &mbrtowc_state);
}

size_t ios_system_mbrlen(const char *s, size_t n, mbstate_t *state)
{
    return mbrlen(s, n, state != NULL ? state : &mbrlen_state);
}

size_t ios_system_wcrtomb(char *s, wchar_t wc, mbstate_t *state)
{
    return wcrtomb(s, wc, state != NULL ? state : &wcrtomb_state);
}

size_t ios_system_mbsrtowcs(wchar_t *destination, const char **source, size_t n, mbstate_t *state)
{
    return mbsrtowcs(destination, source, n, state != NULL ? state : &mbsrtowcs_state);
}

size_t ios_system_wcsrtombs(char *destination, const wchar_t **source, size_t n, mbstate_t *state)
{
    return wcsrtombs(destination, source, n, state != NULL ? state : &wcsrtombs_state);
}

void ios_system_support_cleanup(void *unused)
{
    (void)unused;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    free(user_storage.bytes);
    free(group_storage.bytes);
    user_storage.bytes = group_storage.bytes = NULL;
    user_storage.size = group_storage.size = 0;
    if (context.locale != NULL) {
        uselocale(context.previous_locale);
        context.locale = NULL;
    }
    for (size_t index = 0; index < fts_root_count; ++index) {
        free(fts_roots[index].absolute);
        free(fts_roots[index].original);
    }
    free(fts_roots);
    fts_roots = NULL;
    fts_root_count = 0;
    for (size_t index = 0; index < sizeof(fts_names) / sizeof(fts_names[0]); ++index) {
        free(fts_names[index].text);
        fts_names[index].text = NULL;
        fts_names[index].size = 0;
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

void ios_system_stop_on_broken_pipe(FILE *stream)
{
    if (ferror(stream) && errno == EPIPE) ios_system_exit(128 + SIGPIPE);
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

int ios_system_chdir(const char *path)
{
    char buffer[PATH_MAX], resolved[PATH_MAX];
    struct stat info;
    path = session_path(path, buffer);
    if (path == NULL || stat(path, &info) != 0 || access(path, X_OK) != 0) return -1;
    if (!S_ISDIR(info.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }
    // Like chdir and then getcwd: the physical path. PWD carries it to the
    // commands this invocation starts.
    if (realpath(path, resolved) == NULL) return -1;
    strlcpy(context.directory, resolved, sizeof(context.directory));
    ios_setenv("PWD", resolved, 1);
    return 0;
}

char *ios_system_getcwd(char *buffer, size_t size)
{
    size_t length = strlen(context.directory);
    if (buffer != NULL && size == 0) {
        errno = EINVAL;
        return NULL;
    }
    if (size != 0 && length >= size) {
        errno = ERANGE;
        return NULL;
    }
    if (buffer == NULL) return strdup(context.directory);
    memcpy(buffer, context.directory, length + 1);
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

const char *ios_system_session_path(const char *path, char buffer[PATH_MAX])
{
    return session_path(path, buffer);
}

int ios_system_access(const char *path, int mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? access(path, mode) : -1;
}

int ios_system_link(const char *source, const char *destination)
{
    char source_buffer[PATH_MAX], destination_buffer[PATH_MAX];
    source = session_path(source, source_buffer);
    destination = session_path(destination, destination_buffer);
    return source != NULL && destination != NULL ? link(source, destination) : -1;
}

int ios_system_symlink(const char *target, const char *path)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? symlink(target, path) : -1;
}

int ios_system_utimes(const char *path, const struct timeval times[2])
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? utimes(path, times) : -1;
}

int ios_system_lutimes(const char *path, const struct timeval times[2])
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? lutimes(path, times) : -1;
}

int ios_system_chflags(const char *path, unsigned int flags)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? chflags(path, flags) : -1;
}

int ios_system_lchflags(const char *path, unsigned int flags)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? lchflags(path, flags) : -1;
}

int ios_system_lchown(const char *path, uid_t owner, gid_t group)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? lchown(path, owner, group) : -1;
}

int ios_system_lchmod(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? lchmod(path, mode) : -1;
}

long ios_system_pathconf(const char *path, int name)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? pathconf(path, name) : -1;
}

int ios_system_mkfifo(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? mkfifo(path, mode) : -1;
}

int ios_system_mknod(const char *path, mode_t mode, dev_t device)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? mknod(path, mode, device) : -1;
}

ssize_t ios_system_listxattr(const char *path, char *names, size_t size, int options)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? listxattr(path, names, size, options) : -1;
}

ssize_t ios_system_getxattr(const char *path, const char *name, void *value, size_t size,
    u_int32_t position, int options)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? getxattr(path, name, value, size, position, options) : -1;
}

acl_t ios_system_acl_get_link_np(const char *path, acl_type_t type)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? acl_get_link_np(path, type) : NULL;
}

int ios_system_copyfile(const char *from, const char *to, copyfile_state_t state, copyfile_flags_t flags)
{
    char from_buffer[PATH_MAX], to_buffer[PATH_MAX];
    from = session_path(from, from_buffer);
    to = session_path(to, to_buffer);
    return from != NULL && to != NULL ? copyfile(from, to, state, flags) : -1;
}

int ios_system_removefile(const char *path, removefile_state_t state, removefile_flags_t flags)
{
    char buffer[PATH_MAX];
    path = session_path(path, buffer);
    return path != NULL ? removefile(path, state, flags) : -1;
}

/* Whether spelling would name a root ambiguously: it is one of the operands,
 * or the root of another operand already opened in this invocation. */
static bool fts_spelling_taken(char * const *paths, size_t count, const char *spelling, const char *operand)
{
    for (size_t index = 0; index < count; ++index)
        if (strcmp(paths[index], spelling) == 0) return true;
    for (size_t index = 0; index < fts_root_count; ++index)
        if (strcmp(fts_roots[index].absolute, spelling) == 0 && strcmp(fts_roots[index].original, operand) != 0)
            return true;
    return false;
}

FTS *ios_system_fts_open(char * const *paths, int options,
    int (*compare)(const FTSENT **, const FTSENT **))
{
    size_t count = 0;
    while (paths[count] != NULL) ++count;
    char **resolved = calloc(count + 1, sizeof(*resolved));
    struct fts_root *roots = realloc(fts_roots, (fts_root_count + count) * sizeof(*roots));
    if (resolved == NULL || (roots == NULL && count > 0)) {
        free(resolved);
        errno = ENOMEM;
        return NULL;
    }
    fts_roots = roots;
    for (size_t index = 0; index < count; ++index) {
        resolved[index] = paths[index];
        if (paths[index][0] == '/' || paths[index][0] == '\0') continue;
        struct fts_root *root = &fts_roots[fts_root_count];
        // Opened as <directory>/./<operand>, with more "./" while that
        // spelling is taken, so each root maps back to its own operand even
        // when dir, ./dir and "$PWD/./dir" name the same directory.
        root->absolute = root->original = NULL;
        bool failed = asprintf(&root->absolute, "%s/./%s", context.directory, paths[index]) < 0 ||
            (root->original = strdup(paths[index])) == NULL;
        while (!failed && fts_spelling_taken(paths, count, root->absolute, paths[index])) {
            char *longer = NULL;
            failed = asprintf(&longer, "%s/./%s", context.directory, root->absolute + strlen(context.directory) + 1) < 0;
            free(root->absolute);
            root->absolute = longer;
        }
        if (failed) {
            free(root->absolute);
            free(root->original);
            free(resolved);
            errno = ENOMEM;
            return NULL;
        }
        root->absolute_length = strlen(root->absolute);
        resolved[index] = root->absolute;
        ++fts_root_count;
    }
    // fts_open copies each operand, so only the lookup table keeps them.
    FTS *fts = fts_open(resolved, options, compare);
    free(resolved);
    return fts;
}

static const char *fts_display(const char *original, const char *suffix)
{
    size_t length = strlen(original) + strlen(suffix) + 1;
    unsigned index = fts_name_index++ % (sizeof(fts_names) / sizeof(fts_names[0]));
    if (fts_names[index].size < length) {
        char *text = realloc(fts_names[index].text, length);
        if (text == NULL) return NULL;
        fts_names[index].text = text;
        fts_names[index].size = length;
    }
    snprintf(fts_names[index].text, length, "%s%s", original, suffix);
    return fts_names[index].text;
}

/* A root's fts_name holds the operand until fts_read loads it, then its last
 * component; once loaded, its fts_path is the operand and descendants extend it. */
const char *ios_system_fts_path(const FTSENT *entry)
{
    const FTSENT *root = entry;
    while (root->fts_level > FTS_ROOTLEVEL && root->fts_parent != NULL) root = root->fts_parent;
    for (size_t index = 0; index < fts_root_count; ++index) {
        const struct fts_root *operand = &fts_roots[index];
        if (strcmp(root->fts_name, operand->absolute) == 0)
            return entry == root ? operand->original : entry->fts_path;
    }
    if (strchr(root->fts_name, '/') != NULL) return entry == root ? root->fts_name : entry->fts_path;
    for (size_t index = 0; index < fts_root_count; ++index) {
        const struct fts_root *operand = &fts_roots[index];
        if (root->fts_pathlen == operand->absolute_length &&
            strncmp(entry->fts_path, operand->absolute, operand->absolute_length) == 0) {
            const char *display = fts_display(operand->original, entry->fts_path + operand->absolute_length);
            return display != NULL ? display : entry->fts_path;
        }
    }
    return entry->fts_path;
}

const char *ios_system_fts_name(const FTSENT *entry)
{
    if (entry->fts_level != FTS_ROOTLEVEL) return entry->fts_name;
    for (size_t index = 0; index < fts_root_count; ++index)
        if (strcmp(entry->fts_name, fts_roots[index].absolute) == 0) return fts_roots[index].original;
    return entry->fts_name;
}

static __thread char user_name[MAXLOGNAME + 1], group_name[MAXLOGNAME + 1];

char *ios_system_user_from_uid(uid_t uid, int nouser)
{
    struct passwd entry, *result = NULL;
    char storage[4096];
    if (getpwuid_r(uid, &entry, storage, sizeof(storage), &result) != 0 || result == NULL) {
        if (nouser) return NULL;
        snprintf(user_name, sizeof(user_name), "%u", uid);
    } else {
        strlcpy(user_name, result->pw_name, sizeof(user_name));
    }
    return user_name;
}

char *ios_system_group_from_gid(gid_t gid, int nogroup)
{
    struct group entry, *result = NULL;
    char storage[4096];
    if (getgrgid_r(gid, &entry, storage, sizeof(storage), &result) != 0 || result == NULL) {
        if (nogroup) return NULL;
        snprintf(group_name, sizeof(group_name), "%u", gid);
    } else {
        strlcpy(group_name, result->gr_name, sizeof(group_name));
    }
    return group_name;
}

/* libc getbsize(3) formats into a shared buffer. */
char *ios_system_getbsize(int *header_length, long *block_size)
{
    static __thread char header[32];
    enum { KB = 1024, MB = 1024 * 1024, GB = 1024 * 1024 * 1024, MAXB = GB };
    const char *form = "";
    long n = 512, max = MAXB, multiplier = 1;
    const char *value = ios_getenv("BLOCKSIZE");
    if (value != NULL && *value != '\0') {
        char *end;
        n = strtol(value, &end, 10);
        if (n < 0) {
            warnx("minimum blocksize is 512");
            n = 512;
        } else {
            if (n == 0) n = 1;
            switch (*end != '\0' && end[1] != '\0' ? '?' : *end) {
            case 'G': case 'g': form = "G"; max = MAXB / GB; multiplier = GB; break;
            case 'K': case 'k': form = "K"; max = MAXB / KB; multiplier = KB; break;
            case 'M': case 'm': form = "M"; max = MAXB / MB; multiplier = MB; break;
            case '\0': break;
            default:
                warnx("%s: unknown blocksize", value);
                n = 512;
                break;
            }
            if (n > max) {
                warnx("maximum blocksize is %ldG", (long)(MAXB / GB));
                n = max;
            }
            if (n * multiplier < 512) {
                warnx("minimum blocksize is 512");
                form = "";
                n = 512;
                multiplier = 1;
            }
        }
    }
    *block_size = n * multiplier;
    snprintf(header, sizeof(header), "%ld%s-blocks", n, form);
    *header_length = (int)strlen(header);
    return header;
}

/* random(3)'s additive feedback generator (TYPE_3: x**31 + x**3 + 1, Park-Miller
 * seeding), with the state per thread instead of per process. */
static __thread struct {
    uint32_t state[31], *front, *rear;
} random_context;

static uint32_t random_seed_step(uint32_t value)
{
    int32_t x = (int32_t)value, high, low;
    if (x == 0) x = 123459876;
    high = x / 127773;
    low = x % 127773;
    x = 16807 * low - 2836 * high;
    if (x < 0) x += 0x7fffffff;
    return (uint32_t)x;
}

long ios_system_random(void)
{
    uint32_t *state = random_context.state, *end = state + 31;
    if (random_context.front == NULL) ios_system_srandom(1);
    uint32_t *front = random_context.front, *rear = random_context.rear;
    *front += *rear;
    uint32_t result = *front >> 1;
    if (++front >= end) {
        front = state;
        ++rear;
    } else if (++rear >= end) {
        rear = state;
    }
    random_context.front = front;
    random_context.rear = rear;
    return (long)result;
}

void ios_system_srandom(unsigned int seed)
{
    random_context.state[0] = seed;
    for (int index = 1; index < 31; ++index)
        random_context.state[index] = random_seed_step(random_context.state[index - 1]);
    random_context.front = &random_context.state[3];
    random_context.rear = &random_context.state[0];
    for (int index = 0; index < 310; ++index) (void)ios_system_random();
}

int ios_system_clonefile(const char *source, const char *destination, uint32_t flags)
{
    char source_buffer[PATH_MAX], destination_buffer[PATH_MAX];
    source = session_path(source, source_buffer);
    destination = session_path(destination, destination_buffer);
    return source != NULL && destination != NULL ? clonefile(source, destination, flags) : -1;
}

/* A new file's mode is 0777 masked by the umask. */
mode_t ios_system_umask(void)
{
    char directory[PATH_MAX], path[PATH_MAX];
    uint64_t thread;
    pthread_threadid_np(NULL, &thread);
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory)) == 0) strlcpy(directory, "/tmp/", sizeof(directory));
    snprintf(path, sizeof(path), "%s.umask.%d.%llu", directory, getpid(), (unsigned long long)thread);
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0777);
    if (fd < 0) return 022;
    struct stat info;
    int status = fstat(fd, &info);
    close(fd);
    unlink(path);
    return status == 0 ? ~info.st_mode & 0777 : 022;
}

static locale_t create_derived_locale(const char *key, void *argument)
{
    (void)key;
    const struct { int mask; const char *name; locale_t base; } *derived = argument;
    locale_t base = duplocale(derived->base);
    if (base == NULL) return NULL;
    locale_t locale = newlocale(derived->mask, derived->name, base);
    // Darwin returns a new locale and keeps the base allocated.
    if (locale != base) freelocale(base);
    return locale;
}

static locale_t create_ctype_locale(const char *key, void *argument)
{
    (void)key;
    return newlocale(LC_CTYPE_MASK, argument, NULL);
}

locale_t ios_system_ctype_locale(const char *name)
{
    static const char *const variables[] = {"LC_ALL", "LC_CTYPE", "LANG"};
    for (size_t index = 0; name[0] == '\0' && index < sizeof(variables) / sizeof(variables[0]); ++index) {
        const char *value = ios_getenv(variables[index]);
        if (value != NULL && *value != '\0') name = value;
    }
    if (name[0] == '\0') name = "C";
    char key[192];
    snprintf(key, sizeof(key), "LC_CTYPE=%s", name);
    return shared_locale(key, create_ctype_locale, (void *)name);
}

locale_t ios_system_locale_with(int mask, const char *name)
{
    if (context.locale == NULL) return NULL;
    char key[sizeof(context.locale_key) + 64];
    snprintf(key, sizeof(key), "%s#%d=%s", context.locale_key, mask, name);
    struct { int mask; const char *name; locale_t base; } derived = {mask, name, context.locale};
    return shared_locale(key, create_derived_locale, &derived);
}
