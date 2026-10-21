#ifndef INFOZIP_SUPPORT_H
#define INFOZIP_SUPPORT_H
#include <time.h>
#include <wchar.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "ios_system_support.h"

struct tm *infozip_localtime(const time_t *clock);
struct tm *infozip_gmtime(const time_t *clock);
char *infozip_asctime(const struct tm *time);
int infozip_mblen(const char *text, size_t size);
int infozip_wctomb(char *text, wchar_t value);
const char *infozip_strerror(int error);
void infozip_perror(const char *message);
int infozip_openat(int directory, const char *path, int flags, ...);
int infozip_fstatat(int directory, const char *path, struct stat *info, int flags);
int infozip_unlinkat(int directory, const char *path, int flags);
#endif
