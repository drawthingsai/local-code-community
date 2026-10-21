#ifndef LIBCACA_IOS_SYSTEM_IMG2TXT_PREINCLUDE_H
#define LIBCACA_IOS_SYSTEM_IMG2TXT_PREINCLUDE_H

#include "ios_error.h"

#undef stdout
#undef stderr
#define stdout thread_stdout
#define stderr thread_stderr

#undef printf
#define printf(...) fprintf(thread_stdout, __VA_ARGS__)

#define main libcaca_img2txt_main

#endif
