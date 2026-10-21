#include <sys/param.h>
#include <sys/utsname.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <utime.h>
#include <dirent.h>
#include <time.h>
#include <locale.h>
#include <langinfo.h>
#include <wchar.h>
#include <wctype.h>
#include <zlib.h>
#undef OF
#include "../support.h"
#include "symbols.h"
void infozip_zip_free_envargs(void);

/* Info-ZIP tests macro presence; Bazel may define DEBUG as 0. */
#undef DEBUG
