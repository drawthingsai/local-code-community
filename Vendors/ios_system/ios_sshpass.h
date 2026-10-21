#ifndef ios_sshpass_h
#define ios_sshpass_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    IOS_SSHPASS_INACTIVE = 0,
    IOS_SSHPASS_PASSWORD_PROVIDED = 1,
    IOS_SSHPASS_RUNTIME_ERROR = 3,
    IOS_SSHPASS_INCORRECT_PASSWORD = 5,
    IOS_SSHPASS_HOST_KEY_UNKNOWN = 6,
} ios_sshpass_prompt_result;

int ios_sshpass_begin(
    const char *password, const char *prompt, int verbose);
int ios_sshpass_read_passphrase(
    const char *prompt, char *buffer, size_t buffer_size);
int ios_sshpass_end(void);

#ifdef __cplusplus
}
#endif

#endif
