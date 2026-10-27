// Only the invocation-local option parser: libc getopt's state is shared by
// every session. (Its system headers, <wchar.h> among them, precede
// ios_error.h's stream macros.)
#define IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#include "ios_system_support.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SSHPASS_DEFAULT_PROMPT "assword:"
#define SSHPASS_MAX_PASSWORD_LENGTH 1023

enum sshpass_password_source {
    SSHPASS_PASSWORD_STDIN,
    SSHPASS_PASSWORD_FILE,
    SSHPASS_PASSWORD_FD,
    SSHPASS_PASSWORD_ARGUMENT,
    SSHPASS_PASSWORD_ENVIRONMENT,
};

typedef struct {
    pid_t childPid;
} sshpass_cleanup_context;

static void sshpass_usage(void) {
    fprintf(thread_stdout,
        "Usage: sshpass [-f|-d|-p|-e] [-hV] command parameters\n"
        "   -f filename   Take password to use from file\n"
        "   -d number     Use number as file descriptor for getting password\n"
        "   -p password   Provide password as argument (security unwise)\n"
        "   -e            Password is passed as env-var \"SSHPASS\"\n"
        "   With no password option, read the password from stdin\n\n"
        "   -P prompt     String used to identify a password prompt\n"
        "   -v            Print diagnostic information\n"
        "   -h            Show help\n"
        "   -V            Print version information\n"
        "At most one of -f, -d, -p, or -e may be used\n");
}

static void sshpass_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = buffer;
    while (length > 0) {
        *bytes++ = 0;
        length--;
    }
}

static void sshpass_clear_password(char **password) {
    if (password == NULL || *password == NULL) {
        return;
    }
    sshpass_zero(*password, strlen(*password));
    free(*password);
    *password = NULL;
}

static int sshpass_read_password(int fd, char **password) {
    char buffer[SSHPASS_MAX_PASSWORD_LENGTH + 1];
    size_t length = 0;
    bool overflow = false;
    for (;;) {
        char byte;
        ssize_t count = read(fd, &byte, 1);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            return errno;
        }
        if (count == 0 || byte == '\n') {
            break;
        }
        if (length < SSHPASS_MAX_PASSWORD_LENGTH) {
            buffer[length++] = byte;
        } else {
            overflow = true;
        }
    }
    if (overflow) {
        sshpass_zero(buffer, sizeof(buffer));
        return E2BIG;
    }
    buffer[length] = '\0';
    *password = strdup(buffer);
    sshpass_zero(buffer, sizeof(buffer));
    return *password != NULL ? 0 : ENOMEM;
}

static const char *sshpass_command_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash != NULL ? slash + 1 : path;
}

static void sshpass_cleanup(void *opaqueContext) {
    sshpass_cleanup_context *context = opaqueContext;
    if (context->childPid > 0) {
        pthread_t childThread = ios_getThreadId(context->childPid);
        if (childThread == (pthread_t)-1) {
            ios_storeThreadId(pthread_self());
        } else if (childThread != NULL) {
            pthread_cancel(childThread);
            ios_waitpid(context->childPid);
        }
        ios_releaseThreadId(context->childPid);
        context->childPid = 0;
    }
    int result = ios_sshpass_end();
    if (result != IOS_SSHPASS_INACTIVE) {
        set_session_errno(result);
    }
}

static int sshpass_run_command(
    int argc, char **argv, sshpass_cleanup_context *context)
{
    context->childPid = ios_fork();
    if (context->childPid < 0) {
        fprintf(thread_stderr, "sshpass: fork: %s\n", strerror(errno));
        context->childPid = 0;
        return 3;
    }
    int status = ios_system(argc, (const char *const *)argv);
    pthread_t childThread = ios_getThreadId(context->childPid);
    if (childThread == (pthread_t)-1) {
        ios_storeThreadId(pthread_self());
    } else if (childThread != NULL) {
        ios_waitpid(context->childPid);
        status = ios_getCommandStatus();
    }
    ios_releaseThreadId(context->childPid);
    context->childPid = 0;
    return status;
}

int sshpass_main(int argc, char **argv) {
    enum sshpass_password_source passwordSource = SSHPASS_PASSWORD_STDIN;
    const char *passwordFilename = NULL;
    const char *passwordArgument = NULL;
    const char *prompt = SSHPASS_DEFAULT_PROMPT;
    int passwordFD = -1;
    int verbose = 0;
    bool explicitPasswordSource = false;
    int option;

    while ((option = ios_system_getopt(argc, argv, "+f:d:p:P:heVv")) != -1) {
        switch (option) {
        case 'f':
        case 'd':
        case 'p':
        case 'e':
            if (explicitPasswordSource) {
                fprintf(thread_stderr,
                    "sshpass: conflicting password sources\n");
                return 2;
            }
            explicitPasswordSource = true;
            if (option == 'f') {
                passwordSource = SSHPASS_PASSWORD_FILE;
                passwordFilename = ios_system_optarg;
            } else if (option == 'd') {
                char *end = NULL;
                errno = 0;
                long value = strtol(ios_system_optarg, &end, 10);
                if (errno != 0 || end == ios_system_optarg || *end != '\0' || value < 0 ||
                    value > INT_MAX) {
                    fprintf(thread_stderr,
                        "sshpass: invalid file descriptor: %s\n", ios_system_optarg);
                    return 1;
                }
                passwordSource = SSHPASS_PASSWORD_FD;
                passwordFD = (int)value;
            } else if (option == 'p') {
                passwordSource = SSHPASS_PASSWORD_ARGUMENT;
                passwordArgument = ios_system_optarg;
            } else {
                passwordSource = SSHPASS_PASSWORD_ENVIRONMENT;
            }
            break;
        case 'P':
            prompt = ios_system_optarg;
            break;
        case 'v':
            verbose++;
            break;
        case 'h':
            sshpass_usage();
            return 0;
        case 'V':
            fprintf(thread_stdout,
                "sshpass (ios_system) 1.0\n"
                "Using \"%s\" as the default password prompt indicator.\n",
                SSHPASS_DEFAULT_PROMPT);
            return 0;
        default:
            sshpass_usage();
            return 1;
        }
    }

    if (ios_system_optind >= argc) {
        sshpass_usage();
        return 0;
    }
    const char *commandName = sshpass_command_name(argv[ios_system_optind]);
    if (strcmp(commandName, "ssh") != 0 && strcmp(commandName, "scp") != 0 &&
        strcmp(commandName, "sftp") != 0) {
        fprintf(thread_stderr,
            "sshpass: unsupported embedded command: %s\n", argv[ios_system_optind]);
        return 1;
    }

    char *password = NULL;
    int passwordError = 0;
    if (passwordSource == SSHPASS_PASSWORD_ARGUMENT) {
        password = strdup(passwordArgument);
        if (password == NULL) {
            passwordError = ENOMEM;
        } else {
            sshpass_zero((char *)passwordArgument, strlen(passwordArgument));
        }
    } else if (passwordSource == SSHPASS_PASSWORD_ENVIRONMENT) {
        const char *environmentPassword = getenv("SSHPASS");
        if (environmentPassword == NULL) {
            fprintf(thread_stderr,
                "sshpass: -e given but SSHPASS is not set\n");
            return 1;
        }
        password = strdup(environmentPassword);
        if (password == NULL) {
            passwordError = ENOMEM;
        }
    } else if (passwordSource == SSHPASS_PASSWORD_FILE) {
        int fd = open(passwordFilename, O_RDONLY);
        if (fd < 0) {
            passwordError = errno;
        } else {
            passwordError = sshpass_read_password(fd, &password);
            close(fd);
        }
    } else {
        int fd = passwordSource == SSHPASS_PASSWORD_FD
            ? passwordFD : ios_getstdin();
        if (fd < 0) {
            passwordError = EBADF;
        } else {
            passwordError = sshpass_read_password(fd, &password);
        }
    }
    if (passwordError != 0) {
        fprintf(thread_stderr,
            "sshpass: unable to read password: %s\n",
            strerror(passwordError));
        sshpass_clear_password(&password);
        return 3;
    }
    if (strlen(password) > SSHPASS_MAX_PASSWORD_LENGTH) {
        fprintf(thread_stderr,
            "sshpass: password exceeds OpenSSH's input limit\n");
        sshpass_clear_password(&password);
        return 3;
    }

    int beginStatus = ios_sshpass_begin(password, prompt, verbose);
    sshpass_clear_password(&password);
    if (beginStatus != 0) {
        fprintf(thread_stderr,
            "sshpass: unable to prepare password input: %s\n",
            strerror(beginStatus));
        return 3;
    }
    if (verbose) {
        fprintf(thread_stderr,
            "SSHPASS searching for password prompt using match \"%s\"\n",
            prompt);
    }

    sshpass_cleanup_context cleanupContext = {.childPid = 0};
    int status;
    int sshpassResult;
    pthread_cleanup_push(sshpass_cleanup, &cleanupContext);
    status = sshpass_run_command(
        argc - ios_system_optind, argv + ios_system_optind, &cleanupContext);
    sshpassResult = ios_sshpass_end();
    pthread_cleanup_pop(0);
    return sshpassResult != IOS_SSHPASS_INACTIVE ? sshpassResult : status;
}
