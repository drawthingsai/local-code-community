/* Exercise the fallback used before the kernel RESOLVE_BENEATH flags. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern int infozip_openat(int, const char *, int, ...);
extern int infozip_fstatat(int, const char *, struct stat *, int);
extern int infozip_unlinkat(int, const char *, int);
__thread FILE *thread_stderr;

int main(void)
{
    thread_stderr = stderr;
    char directory[] = "/tmp/infozip-containment.XXXXXX";
    assert(mkdtemp(directory) != NULL);
    int root = open(directory, O_RDONLY | O_DIRECTORY);
    assert(root >= 0);
    assert(mkdirat(root, "inside", 0700) == 0);
    assert(symlinkat("/tmp", root, "escape") == 0);
    int fd = infozip_openat(root, "inside/data", O_CREAT | O_RDWR | O_RESOLVE_BENEATH, 0600);
    assert(fd >= 0);
    assert(write(fd, "safe", 4) == 4);
    close(fd);
    struct stat info;
    assert(infozip_fstatat(root, "inside/data", &info, AT_RESOLVE_BENEATH) == 0);
    assert(info.st_size == 4);
    assert(infozip_openat(root, "escape/infozip-must-not-exist", O_CREAT | O_WRONLY | O_RESOLVE_BENEATH, 0600) == -1);
    assert(infozip_openat(root, "../infozip-must-not-exist", O_CREAT | O_WRONLY | O_RESOLVE_BENEATH, 0600) == -1);
    assert(infozip_openat(root, "/tmp/infozip-must-not-exist", O_CREAT | O_WRONLY | O_RESOLVE_BENEATH, 0600) == -1);
    assert(infozip_fstatat(root, "escape", &info, AT_RESOLVE_BENEATH) == 0 && S_ISLNK(info.st_mode));
    assert(infozip_fstatat(root, "escape/nonexistent", &info, AT_RESOLVE_BENEATH) == -1);
    assert(infozip_unlinkat(root, "../infozip-must-not-exist", AT_RESOLVE_BENEATH) == -1);
    // Final symlinks must never become writable targets.
    assert(symlinkat("data", root, "inside/link") == 0);
    assert(infozip_openat(root, "inside/link", O_WRONLY | O_RESOLVE_BENEATH) == -1);
    assert(infozip_unlinkat(root, "inside/link", AT_RESOLVE_BENEATH) == 0);
    assert(infozip_unlinkat(root, "inside/data", AT_RESOLVE_BENEATH) == 0);
    assert(infozip_unlinkat(root, "inside", AT_RESOLVE_BENEATH | AT_REMOVEDIR) == 0);
    assert(infozip_unlinkat(root, "escape", AT_RESOLVE_BENEATH) == 0);
    close(root);
    assert(rmdir(directory) == 0);
    puts("Info-ZIP portable extraction checks passed.");
    return 0;
}
