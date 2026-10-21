#ifndef PYTHON_IOS_RUNTIME_H
#define PYTHON_IOS_RUNTIME_H

#include <stddef.h>

#ifndef PYTHON_IOS_RUNTIME_LINKAGE
#define PYTHON_IOS_RUNTIME_LINKAGE
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the process-wide embedded Python runtime. Returns zero on
// success. On failure, error_message contains the non-fatal PyStatus details.
int python_ios_initialize(
    char *error_message,
    size_t error_message_capacity) PYTHON_IOS_RUNTIME_LINKAGE;

#ifdef __cplusplus
}
#endif

#endif
