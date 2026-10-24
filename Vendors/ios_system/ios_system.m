//
//  ios_system.m
//
//  Created by Nicolas Holzschuch on 17/11/2017.
//  Copyright © 2017 N. Holzschuch. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define IOS_SYSTEM_HAS_UIKIT 1
#else
#define IOS_SYSTEM_HAS_UIKIT 0
#endif
#ifndef IOS_SYSTEM_ENABLE_FILE_COORDINATION
#define IOS_SYSTEM_ENABLE_FILE_COORDINATION 0
#endif

#include "ios_system.h"
#include "ios_system_command_registry.h"
#include "ios_sshpass.h"
#include "Vendors/OSH/osh_ios.h"
#define PYTHON_IOS_RUNTIME_LINKAGE __attribute__((weak_import))
#include "python_runtime.h"
#undef PYTHON_IOS_RUNTIME_LINKAGE

// ios_system(argc, argv): Executes one already-tokenized command.
// ios_system_osh(cmd): Executes shell text in the embedded OSH runtime.
//
// ios_executable(cmd): returns true if the command is one of the commands defined in ios_system, and can be executed.
// This is because mch_can_exe (called by executable()) checks for the existence of binaries with the same name in the
// path. Our commands don't exist in the path.
//
// ios_popen(cmd, type): returns a FILE*, executes cmd, and thread_output into input of cmd (if type=="w") or
// the reverse (if type == "r").

#include <pthread.h>
#include <sys/stat.h>
#include <libgen.h> // for basename_r()
#include <dlfcn.h>  // for dlopen()/dlsym()/dlclose()
#include <glob.h>   // for wildcard expansion
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "python_subprocess_source.h"

// Sideloading: when you compile yourself, as opposed to uploading on the app store
// If true, all commands are enabled + debug messages if dylib not found.
// If false, you get a smaller set, but compliance with AppStore rules.
// *Must* be false in the main branch releases.
// Commands that can be enabled only if sideLoading: chgrp, chown, df, id, w.
bool sideLoading = false;
// Should the main thread be joined (which means it takes priority over other tasks)?
// Default value is true, which makes sense for shell-like applications.
// Should be set to false if significant user interaction is carried by the app and
// the app takes responsibility for waiting for the command to terminate.
bool joinMainThread = true;
bool enableLLVMInterpreter = false;
static NSString* ios_bookmarkDictionaryName = @"bookmarkNames";
NSString * const ios_commandContextKey = @"ios_system.commandContext";
// Include file for getrlimit/setrlimit:
#include <sys/resource.h>
extern void display_alert(NSString* title, NSString* message);

static int ios_system_command_line(const char* inputCmd);
static int ios_python_subprocess_run(int argc, const char *const argv[], int input, int output, int error);
int ios_python_main(int argc, char **argv);
int ios_pip_main(int argc, char **argv);
int ios_ytdlp_main(int argc, char **argv);
int ios_node_main(int argc, char **argv);
int ios_npm_main(int argc, char **argv);
int ios_npx_main(int argc, char **argv);

extern __thread int    __db_getopt_reset;
__thread FILE* thread_stdin;
__thread FILE* thread_stdout;
__thread FILE* thread_stderr;
__thread void* thread_context;
FILE* ios_stdin(void) {
    return thread_stdin;
}

FILE* ios_stdout(void) {
    return thread_stdout;
}

FILE* ios_stderr(void) {
    return thread_stderr;
}

void* ios_context(void) {
    return thread_context;
}

typedef struct _is IOSPyInterpreterState;

// Registered before a Python pthread becomes the session root and retained
// through cleanup, so ios_kill never races into the pthread_cancel fallback.
typedef struct _iosPythonCommandState {
    _Atomic(bool) cancellationRequested;
    bool acceptsInterruption;
    unsigned long threadIdentifier;
    IOSPyInterpreterState *interpreter;
    // Pins this state and its subinterpreter while cancellation acquires its GIL.
    int activeCancellationRequests;
    struct _iosPythonCommandState *next;
} IOSPythonCommandState;

// Parameters for each session. We can have multiple sessions running in parallel.
typedef struct _sessionParameters {
    bool isMainThread;   // are we on the first command?
    char currentDir[MAXPATHLEN];
    char previousDirectory[MAXPATHLEN];
    char localMiniRoot[MAXPATHLEN];
    char workspaceDirectory[MAXPATHLEN];
    char temporaryDirectory[MAXPATHLEN];
    char appBundleDirectory[MAXPATHLEN];
    pthread_t current_command_root_thread; // thread ID of first command
    pthread_t lastThreadId; // thread ID of last command.
    pthread_t mainThreadId; // thread ID of parent command, if any (e.g. vim, which starts "sh -c cd dir && flake8 file")
    FILE* stdin;
    FILE* stdout;
    FILE* stderr;
    FILE* tty;
    const void* context;
    _Atomic(uint64_t) nodeCommandIdentifier;
    _Atomic(bool) nodeCommandRunning;
    // The exact generic root command that ios_kill may cancel.
    _Atomic(pthread_t) pthreadCancelableRootCommand;
    _Atomic(bool) shellCommandRunning;
    _Atomic(bool) cancellationRequested;
    pthread_t shellThread;
    _Atomic(bool) commandCancellationRequested;
    // Set by ios_openSession for a session that runs one job.
    bool keepsCancellationRequests;
    // Protects the Python command list and published CPython thread identities.
    // The condition is used only to wait for activeCancellationRequests.
    pthread_mutex_t pythonCommandsMutex;
    pthread_cond_t pythonCommandsCondition;
    IOSPythonCommandState *pythonCommands;
    pthread_mutex_t sshpassMutex;
    char *sshpassPassword;
    char *sshpassPrompt;
    bool sshpassActive;
    bool sshpassPasswordSent;
    bool sshpassVerbose;
    int sshpassResult;
    int global_errno;
    int numCommandsAllocated;
    int numCommand;
    char** commandName;
    char columns[5];
    char lines[5];
    bool activePager;
} sessionParameters;

static void initSessionParameters(sessionParameters* sp) {
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    sp->isMainThread = TRUE;
    sp->current_command_root_thread = 0;
    sp->lastThreadId = 0;
    sp->mainThreadId = 0;
    NSString* currentDirectory = [NSFileManager.defaultManager currentDirectoryPath];
    // getcwd fails once a command deletes the process working directory. Leave the
    // directory empty; ios_setSystemPaths starts the session in its project.
    const char *startDirectory = currentDirectory != nil ? currentDirectory.UTF8String : "";
    strcpy(sp->currentDir, startDirectory);
    strcpy(sp->previousDirectory, startDirectory);
    sp->localMiniRoot[0] = 0;
    sp->workspaceDirectory[0] = 0;
    sp->temporaryDirectory[0] = 0;
    sp->appBundleDirectory[0] = 0;
    sp->global_errno = 0;
    sp->stdin = stdin;
    sp->stdout = stdout;
    sp->stderr = stderr;
    sp->tty = stdin;
    sp->context = nil;
    atomic_init(&sp->nodeCommandIdentifier, 0);
    atomic_init(&sp->nodeCommandRunning, false);
    atomic_init(&sp->pthreadCancelableRootCommand, NULL);
    atomic_init(&sp->shellCommandRunning, false);
    atomic_init(&sp->cancellationRequested, false);
    atomic_init(&sp->commandCancellationRequested, false);
    sp->keepsCancellationRequests = false;
    sp->shellThread = NULL;
    pthread_mutex_init(&sp->pythonCommandsMutex, NULL);
    pthread_cond_init(&sp->pythonCommandsCondition, NULL);
    sp->pythonCommands = NULL;
    pthread_mutex_init(&sp->sshpassMutex, NULL);
    sp->sshpassPassword = NULL;
    sp->sshpassPrompt = NULL;
    sp->sshpassActive = false;
    sp->sshpassPasswordSent = false;
    sp->sshpassVerbose = false;
    sp->sshpassResult = IOS_SSHPASS_INACTIVE;
    sp->numCommandsAllocated = 10; // 10 slots available to store commands, will realloc if more needed.
    sp->commandName = malloc(sizeof(char*) * sp->numCommandsAllocated);
    for (int i = 0; i < sp->numCommandsAllocated; i++) {
        sp->commandName[i] = malloc(sizeof(char) * NAME_MAX);
    }
    sp->commandName[0][0] = 0;
    sp->numCommand = 0;
    strcpy(sp->columns, "80");
    strcpy(sp->lines, "80");
    sp->activePager = FALSE;
}

void ios_setBookmarkDictionaryName(NSString* name) {
    ios_bookmarkDictionaryName = name;
}

const char* ios_getBookmarkedVersion(const char* p) {
    // p is a directory. Get the bookmarked version to make it shorter:
    NSString* pathString = [NSString stringWithUTF8String:p];
    NSString* privatePrefix = @"/private";
    if ([pathString hasPrefix:privatePrefix]) {
        pathString = [pathString substringFromIndex:[privatePrefix length]];
    }
    NSString *homePath;
    homePath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject] stringByDeletingLastPathComponent];
    if ([homePath hasPrefix:privatePrefix]) {
        homePath = [homePath substringFromIndex:[privatePrefix length]];
    }
    // NSLog(@"ios_getBookmarkedVersion: %s %s", homePath.UTF8String, pathString.UTF8String);
    if ([pathString hasPrefix:homePath]) {
        pathString = [pathString stringByReplacingOccurrencesOfString:homePath withString:@"~"];
        return pathString.UTF8String;
    }
    if (ios_bookmarkDictionaryName == nil) {
        return p;
    }
    NSDictionary *tildeExpansionDictionary = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ios_bookmarkDictionaryName];
    if (tildeExpansionDictionary == nil) {
        return p;
    }
    NSString* foundString = @"";
    for (NSString* bookmark in tildeExpansionDictionary) {
        NSString* bookmarkPath = tildeExpansionDictionary[bookmark];
        if ([bookmarkPath hasPrefix:privatePrefix]) {
            bookmarkPath = [bookmarkPath substringFromIndex:[privatePrefix length]];
        }
        if ([pathString hasPrefix:bookmarkPath]) {
            NSString* testString = [pathString stringByReplacingOccurrencesOfString:bookmarkPath withString:[@"~" stringByAppendingString: bookmark]];
            if ((foundString.length == 0) || (testString.length < foundString.length))
                foundString = testString;
        }
    }
    if (foundString.length > 0)
        return foundString.UTF8String;
    return p;
}

static NSMutableDictionary* sessionList;
static pthread_mutex_t sessionListMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary* aliasDictionary;

static sessionParameters *ios_session_for_key(id sessionKey) {
    pthread_mutex_lock(&sessionListMutex);
    sessionParameters *session = sessionList != nil
        ? (sessionParameters*)[[sessionList objectForKey:sessionKey] pointerValue]
        : NULL;
    pthread_mutex_unlock(&sessionListMutex);
    return session;
}

// pointer to sessionParameters. thread-local variable so the entire system is thread-safe.
// The sessionParameters pointer is shared by all threads in the same session.
static __thread sessionParameters* currentSession = NULL;
static __thread IOSPythonCommandState *currentPythonCommand = NULL;
static __thread uint64_t currentNodeCommandIdentifier = 0;
// Python3 multiple interpreters:
// limit to 6 = 1 kernel, 4 notebooks, one extra.
enum { MaxPythonInterpreters = 6 };
int numPythonInterpreters = MaxPythonInterpreters; // Apps can overwrite this
static bool PythonIsRunning[MaxPythonInterpreters];
static int currentPythonInterpreter = 0;
static bool showPythonInterpreterAlert = true;
// Same with perl:
enum { MaxPerlInterpreters = 4 };
// cpan starts perl Makefile.PL, which starts perl -e print Version, so at least 3.
int numPerlInterpreters = MaxPerlInterpreters; // Apps can overwrite this
static bool PerlIsRunning[MaxPerlInterpreters];
static int currentPerlInterpreter = 0;
// same with TeX, with a twist:
enum { MaxTeXInterpreters = 2 };
// (La)TeX can start another (La)TeX command for TikZ
int numTeXInterpreters = MaxTeXInterpreters; // Apps can overwrite this
static bool TeXIsRunning[MaxTeXInterpreters];
static int currentTeXInterpreter = 0;
NSArray *TeXcommands = nil; // initialized later
// OpenSSH is statically linked once. scp/sftp may use this slot for their
// nested transport, while Local Code serializes top-level shell commands.
enum { MaxSshCommands = 1 };
int numSshCommands = MaxSshCommands; // Apps can overwrite this
static bool sshIsRunning[MaxSshCommands];
static int currentSshCommand = 0;
// we need the ability to run 2 rsync commands for local rsync:
enum { MaxRsyncCommands = 2 };
int numRsyncCommands = MaxRsyncCommands; // Apps can overwrite this
static bool rsyncIsRunning[MaxRsyncCommands];
static int currentRsyncCommand = 0;
// prevent the user from running multiple curl commands too:
// (sessions start commands concurrently, so the slot is claimed atomically)
static atomic_bool curlIsRunning = false;
// prevent the user from running multiple scp commands as well (one is fine):
static atomic_bool scpIsRunning = false;


// replace system-provided exit() by our own:
__attribute__((noreturn)) void ios_exit(int n) {
    if (currentSession != NULL) {
        currentSession->global_errno = n;
    }
    pthread_exit(NULL);
}

void set_session_errno(int n) {
    if (currentSession != NULL) {
        currentSession->global_errno = n;
    }
}

static void ios_sshpass_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = buffer;
    while (length > 0) {
        *bytes++ = 0;
        length--;
    }
}

static void ios_sshpass_clear_locked(sessionParameters *session) {
    if (session->sshpassPassword != NULL) {
        ios_sshpass_zero(
            session->sshpassPassword, strlen(session->sshpassPassword));
        free(session->sshpassPassword);
        session->sshpassPassword = NULL;
    }
    free(session->sshpassPrompt);
    session->sshpassPrompt = NULL;
    session->sshpassActive = false;
    session->sshpassPasswordSent = false;
    session->sshpassVerbose = false;
}

int ios_sshpass_begin(
    const char *password, const char *prompt, int verbose)
{
    if (currentSession == NULL || password == NULL || prompt == NULL) {
        return EINVAL;
    }
    char *passwordCopy = strdup(password);
    char *promptCopy = strdup(prompt);
    if (passwordCopy == NULL || promptCopy == NULL) {
        if (passwordCopy != NULL) {
            ios_sshpass_zero(passwordCopy, strlen(passwordCopy));
        }
        free(passwordCopy);
        free(promptCopy);
        return ENOMEM;
    }

    pthread_mutex_lock(&currentSession->sshpassMutex);
    if (currentSession->sshpassActive) {
        pthread_mutex_unlock(&currentSession->sshpassMutex);
        ios_sshpass_zero(passwordCopy, strlen(passwordCopy));
        free(passwordCopy);
        free(promptCopy);
        return EBUSY;
    }
    currentSession->sshpassPassword = passwordCopy;
    currentSession->sshpassPrompt = promptCopy;
    currentSession->sshpassActive = true;
    currentSession->sshpassPasswordSent = false;
    currentSession->sshpassVerbose = verbose != 0;
    currentSession->sshpassResult = IOS_SSHPASS_INACTIVE;
    pthread_mutex_unlock(&currentSession->sshpassMutex);
    return 0;
}

int ios_sshpass_read_passphrase(
    const char *prompt, char *buffer, size_t buffer_size)
{
    if (currentSession == NULL || prompt == NULL || buffer == NULL ||
        buffer_size == 0) {
        return IOS_SSHPASS_INACTIVE;
    }

    bool verbose = false;
    int result = IOS_SSHPASS_INACTIVE;
    pthread_mutex_lock(&currentSession->sshpassMutex);
    if (!currentSession->sshpassActive) {
        pthread_mutex_unlock(&currentSession->sshpassMutex);
        return IOS_SSHPASS_INACTIVE;
    }
    verbose = currentSession->sshpassVerbose;
    if (strstr(prompt, "The authenticity of host ") != NULL ||
        strstr(prompt, "Are you sure you want to continue connecting") != NULL) {
        currentSession->sshpassResult = IOS_SSHPASS_HOST_KEY_UNKNOWN;
        result = IOS_SSHPASS_HOST_KEY_UNKNOWN;
    } else if (strstr(prompt, currentSession->sshpassPrompt) != NULL) {
        if (currentSession->sshpassPasswordSent) {
            currentSession->sshpassResult = IOS_SSHPASS_INCORRECT_PASSWORD;
            result = IOS_SSHPASS_INCORRECT_PASSWORD;
        } else if (currentSession->sshpassPassword == NULL ||
            strlen(currentSession->sshpassPassword) >= buffer_size) {
            currentSession->sshpassResult = IOS_SSHPASS_RUNTIME_ERROR;
            result = IOS_SSHPASS_RUNTIME_ERROR;
        } else {
            strlcpy(buffer, currentSession->sshpassPassword, buffer_size);
            ios_sshpass_zero(
                currentSession->sshpassPassword,
                strlen(currentSession->sshpassPassword));
            free(currentSession->sshpassPassword);
            currentSession->sshpassPassword = NULL;
            currentSession->sshpassPasswordSent = true;
            result = IOS_SSHPASS_PASSWORD_PROVIDED;
        }
    }
    pthread_mutex_unlock(&currentSession->sshpassMutex);

    if (verbose) {
        if (result == IOS_SSHPASS_PASSWORD_PROVIDED) {
            fprintf(thread_stderr,
                "SSHPASS detected prompt. Sending password.\n");
        } else if (result == IOS_SSHPASS_INCORRECT_PASSWORD) {
            fprintf(thread_stderr,
                "SSHPASS detected prompt again. Wrong password. Exiting.\n");
        } else if (result == IOS_SSHPASS_HOST_KEY_UNKNOWN) {
            fprintf(thread_stderr,
                "SSHPASS detected host authentication prompt. Exiting.\n");
        }
    }
    return result;
}

int ios_sshpass_end(void) {
    if (currentSession == NULL) {
        return IOS_SSHPASS_INACTIVE;
    }
    pthread_mutex_lock(&currentSession->sshpassMutex);
    int result = currentSession->sshpassResult;
    ios_sshpass_clear_locked(currentSession);
    currentSession->sshpassResult = IOS_SSHPASS_INACTIVE;
    pthread_mutex_unlock(&currentSession->sshpassMutex);
    return result;
}

// Replace standard abort and exit functions with ours:
// We also do this using #define, but this is for the unmodified code.
void abort(void) {
    ios_exit(1);
}
void exit(int n) {
    ios_exit(n);
}
void _exit(int n) {
    ios_exit(n);
}
//

int canSetSignal() {
    if ((currentSession == NULL) || (currentSession->context == NULL)) {
        return 1;
    }
    char* sessionId = (char*)currentSession->context;
    if (strcmp(sessionId, "inExtension") == 0) {
        return 0;
    }
    return 1;
}

#undef signal
sig_t ios_signal(int value, sig_t function) {
    // intercept calls to signal, prevent signal from doing anything when running in-extension.
    // So that an in-extension command cannot break the signal handling from an in-app command.
    if (canSetSignal()) {
        return signal(value, function);
    } else {
        return NULL;
    }
}

NSString *ios_getLogicalPWD(const void* sessionId) {
    id sessionKey = @((NSUInteger)sessionId);
    sessionParameters *session = ios_session_for_key(sessionKey);
    if (session == nil) {
        return nil;
    }
    return @(session->currentDir);
}

#undef getenv
void ios_setWindowSize(int width, int height, const void* sessionId) {
    // Set the window size without switching the active session.
    sessionParameters* resizedSession;

    id sessionKey = @((NSUInteger)sessionId);
    resizedSession = ios_session_for_key(sessionKey);
    if (resizedSession == nil) {
        return;
    }

    sprintf(resizedSession->columns, "%d", MIN(width, 9999));
    sprintf(resizedSession->lines, "%d", MIN(height, 9999));
    // Also send SIGWINCH to the main thread of resizedSession:
    if (resizedSession->current_command_root_thread != NULL) {
        pthread_kill(resizedSession->current_command_root_thread, SIGWINCH);
    }
    if (resizedSession->lastThreadId != NULL) {
        pthread_kill(resizedSession->lastThreadId, SIGWINCH);
    }
    if (resizedSession->mainThreadId != NULL) {
        pthread_kill(resizedSession->mainThreadId, SIGWINCH);
    }
}

extern char* libc_getenv(const char* variableName);
static char randomValue[6];
char * ios_getenv(const char *name) {
    // intercept calls to getenv("COLUMNS") / getenv("LINES")
    if (strcmp(name, "COLUMNS") == 0) {
        return currentSession->columns;
    }
    if (strcmp(name, "LINES") == 0) {
        return currentSession->lines;
    }
    if (strcmp(name, "ROWS") == 0) {
        return currentSession->lines;
    }
    if (strcmp(name, "PWD") == 0) {
        return currentSession != NULL ? currentSession->currentDir : NULL;
    }
    if (strcmp(name, "RANDOM") == 0) {
        sprintf(randomValue, "%ld", random() & 0x7FFF);
        return randomValue;
    }
    return libc_getenv(name);
}

void ios_IsMainThread(bool value) {
    currentSession->isMainThread = value;
}

int ios_getCommandStatus(void) {
    if (currentSession != NULL) return currentSession->global_errno;
    else return 0;
}

extern const char* ios_progname(void) {
    if (currentSession != NULL) {
        if (currentSession->numCommand <= 0)
            return currentSession->commandName[0];
        else
            return currentSession->commandName[currentSession->numCommand - 1];
    }
    else return getprogname();
}

int ios_resolveDirectoryAlias(
    const char *path, char *resolvedPath, size_t resolvedPathSize) {
    if (path == NULL || resolvedPath == NULL || resolvedPathSize == 0) {
        errno = EINVAL;
        return -1;
    }
    if (currentSession == NULL) {
        return 0;
    }

    const char *alias = NULL;
    const char *target = NULL;
    int result = 1;
    if (strcmp(path, "/home") == 0 || strncmp(path, "/home/", 6) == 0) {
        alias = "/home";
        target = currentSession->workspaceDirectory;
    } else if (strcmp(path, "/tmp") == 0 || strncmp(path, "/tmp/", 5) == 0) {
        alias = "/tmp";
        target = currentSession->temporaryDirectory;
    } else if (strcmp(path, "/app_bundle") == 0 || strncmp(path, "/app_bundle/", 12) == 0) {
        alias = "/app_bundle";
        target = currentSession->appBundleDirectory;
        result = 2;
    } else {
        return 0;
    }
    if (target[0] == '\0') {
        return 0;
    }

    const char *suffix = path + strlen(alias);
    int length = snprintf(resolvedPath, resolvedPathSize, "%s%s", target, suffix);
    if (length < 0 || (size_t)length >= resolvedPathSize) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return result;
}

typedef struct _functionParameters {
    int argc;
    pid_t processId;
    char** argv;
    char** argv_ref;
    int (*function)(int ac, char** av);
    FILE *stdin, *stdout, *stderr;
    bool ownsStdin;
    bool ownsStdout;
    bool ownsStderr;
    void* context;
    void* dlHandle;
    const void* commandContext; // Retained host thread-dictionary value.
    bool isPipeIn;
    bool isPipeOut;
    bool isPipeErr;
    bool backgroundCommand;
    int  numInterpreter;
    bool storeRootThread;
    sessionParameters* session;
    IOSPythonCommandState pythonCommand;
    uint64_t nodeCommandIdentifier;
    bool nodeCommandPrepared;
} functionParameters;

#define IOS_NODE_WEAK_IMPORT __attribute__((weak_import))

extern int node_mobile_prepare_command(
    uint64_t command_identifier) IOS_NODE_WEAK_IMPORT;
extern int node_mobile_cancel_command(
    uint64_t command_identifier) IOS_NODE_WEAK_IMPORT;
extern int node_mobile_finish_command(
    uint64_t command_identifier,
    int *cancellation_requested) IOS_NODE_WEAK_IMPORT;

static _Atomic(uint64_t) nextNodeCommandIdentifier = 1;

extern pthread_mutex_t pid_mtx;
extern _Atomic(int) cleanup_counter;
extern void ios_releaseBackgroundThread(pthread_t thread);
extern void ios_deferDirectoryRestoration(pid_t pid);
extern void startedPreparingWebAssemblyCommand(void);
static void ios_closePendingChildStreams(void);

static bool ios_function_runs_python(int (*function)(int, char **)) {
    return function == ios_python_main || function == ios_pip_main || function == ios_ytdlp_main;
}

static bool ios_function_runs_node(int (*function)(int, char **)) {
    return function == ios_node_main ||
        function == ios_npm_main ||
        function == ios_npx_main;
}

static void ios_register_python_command(
    sessionParameters *session, IOSPythonCommandState *command)
{
    atomic_init(&command->cancellationRequested, false);
    command->acceptsInterruption = true;
    command->threadIdentifier = 0;
    command->interpreter = NULL;
    command->activeCancellationRequests = 0;
    pthread_mutex_lock(&session->pythonCommandsMutex);
    command->next = session->pythonCommands;
    session->pythonCommands = command;
    if (atomic_load_explicit(
            &session->cancellationRequested,
            memory_order_acquire)) {
        atomic_store_explicit(
            &command->cancellationRequested,
            true,
            memory_order_release);
    }
    pthread_mutex_unlock(&session->pythonCommandsMutex);
}

static void ios_unregister_python_command(
    sessionParameters *session, IOSPythonCommandState *command)
{
    pthread_mutex_lock(&session->pythonCommandsMutex);
    command->acceptsInterruption = false;
    IOSPythonCommandState **entry = &session->pythonCommands;
    while (*entry != NULL && *entry != command) {
        entry = &(*entry)->next;
    }
    if (*entry == command) {
        *entry = command->next;
    }
    while (command->activeCancellationRequests > 0) {
        pthread_cond_wait(
            &session->pythonCommandsCondition, &session->pythonCommandsMutex);
    }
    if (session->pythonCommands == NULL &&
        !atomic_load_explicit(
            &session->shellCommandRunning,
            memory_order_acquire)) {
        atomic_store_explicit(
            &session->cancellationRequested,
            false,
            memory_order_release);
    }
    pthread_mutex_unlock(&session->pythonCommandsMutex);
}

static void ios_disable_root_command_pthread_cancel(functionParameters *parameters) {
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (parameters->storeRootThread && parameters->session != NULL) {
        pthread_t expectedRootCommand = pthread_self();
        atomic_compare_exchange_strong_explicit(
            &parameters->session->pthreadCancelableRootCommand,
            &expectedRootCommand,
            NULL,
            memory_order_acq_rel,
            memory_order_acquire);
    }
}

static void cleanup_function(void* parameters) {
    // This function is called when pthread_exit() or ios_kill() is called
    functionParameters *p = (functionParameters *) parameters;
    // Cleanup calls Foundation and closes shared streams. A concurrent
    // ios_kill must not asynchronously terminate this thread here.
    ios_disable_root_command_pthread_cancel(p);
    pthread_t current_thread = pthread_self();
    bool isPythonCommand = ios_function_runs_python(p->function);
    bool isNodeCommand = ios_function_runs_node(p->function);
    bool backgroundCommand = p->backgroundCommand;
    char* commandName = p->argv[0];
    char* currentSessionCommandName = NULL;
    bool toNonInteractive = false;
    
    if (currentSession->numCommand <= 0)
        currentSessionCommandName = currentSession->commandName[0];
    else
        currentSessionCommandName = currentSession->commandName[currentSession->numCommand - 1];
    NSLog(@"cleanup_function: %s thread_id %p pid: %d stdin %d stdout %d stderr %d isPipeOut %d", commandName, (void *)current_thread, ios_currentPid(), fileno(p->stdin), fileno(p->stdout), fileno(p->stderr), p->isPipeOut);
    NSLog(@"currentSession->commandName: %s root_thread: %p", currentSessionCommandName, (void *)currentSession->current_command_root_thread);
    NSLog(@"Num commands stored: %d", currentSession->numCommand);
    if ((strcmp(commandName, "less") == 0) || (strcmp(commandName, "more") == 0)) {
        if ((strlen(currentSessionCommandName) > 0)
            && (strcmp(currentSessionCommandName, "less") != 0)
            && (strcmp(currentSessionCommandName, "more") != 0)) {
            // Command was "root_command | sthg | less". We need to kill root command.
            // If less itself started another command, then currentSession->commandName is "".
            // Unless less / more was started as a pager, in which case don't kill root command (e.g. for man and ipython help).
            pthread_kill(currentSession->current_command_root_thread, SIGINT);
            while (fgetc(thread_stdin) != EOF) { } // flush input, otherwise previous command gets blocked.
        } else {
            // but for python or ipython help(), flush the content of stdin:
            if ((currentSession->numCommand > 1) &&
                ((strncmp(currentSession->commandName[currentSession->numCommand - 2], "ipython", 7) == 0) ||
                 (strncmp(currentSession->commandName[currentSession->numCommand - 2], "isympy", 6) == 0) ||
                 (strncmp(currentSession->commandName[currentSession->numCommand - 2], "python", 6) == 0))) {
                while (fgetc(thread_stdin) != EOF) { } // flush input to help() command
                if (strncmp(currentSession->commandName[currentSession->numCommand - 2], "python", 6) == 0) {
                    toNonInteractive = true;
                }
            }
        }
        currentSession->activePager = FALSE;
    }
    // If the command was started as a pipe, we wait for the first command to finish sending data
    // There is an exception for ssh, which can be started by scp or sftp. They will wait for it.
    if ((!joinMainThread) && p->isPipeOut
        && (strcmp(commandName, "ssh") != 0)) { // not ssh
        if (currentSession->current_command_root_thread != 0) {
            if (currentSession->current_command_root_thread != current_thread) {
                NSLog(@"Thread %p is waiting for root_thread of currentSession: %p \n", (void *)current_thread, (void *)currentSession->current_command_root_thread);
                while ((currentSession->current_command_root_thread != 0) && (currentSession->current_command_root_thread != current_thread)) {
                    fflush(thread_stdout);
                    fflush(thread_stderr);
                }
                NSLog(@"Thread %p is done waiting for root_thread of currentSession: %p \n", (void *)current_thread, (void *)currentSession->current_command_root_thread);
            } else {
                NSLog(@"Terminating root_thread of currentSession %p \n", (void *)current_thread);
                currentSession->current_command_root_thread = 0;
            }
        }
    }
    fcntl(fileno(thread_stdin), F_SETNOSIGPIPE, 1);
    fcntl(fileno(thread_stdout), F_SETNOSIGPIPE, 1);
    fcntl(fileno(thread_stderr), F_SETNOSIGPIPE, 1);
    fflush(thread_stdin);
    fflush(thread_stdout);
    fflush(thread_stderr);
    ios_closePendingChildStreams();
    // release parameters:
    NSLog(@"Terminating command: %s thread_id %p stdin %d stdout %d stderr %d isPipeOut %d", commandName, (void *)current_thread, fileno(p->stdin), fileno(p->stdout), fileno(p->stderr), p->isPipeOut);
    NSString* commandNameString = [NSString stringWithCString: commandName encoding:NSUTF8StringEncoding];
    // Can we close stdin too?
    bool mustCloseStdin = fileno(p->stdin) != fileno(stdin);
    // Same with multiple perl or TeX interpreters:
    if (strncmp(commandName, "perl", 4) == 0) {
        NSLog(@"Ending a Perl interpreter: %d", p->numInterpreter);
        PerlIsRunning[p->numInterpreter] = false;
    } else if ([TeXcommands containsObject: commandNameString]) {
        NSLog(@"Ending a TeX command: %d", p->numInterpreter);
        TeXIsRunning[p->numInterpreter] = false;
    } else if ((strcmp(commandName, "ssh") == 0)) {
        NSLog(@"Ending a ssh command: %d", p->numInterpreter);
        sshIsRunning[p->numInterpreter] = false;
    } else if (strcmp(commandName, "curl") == 0) {
        NSLog(@"Ending a curl command.");
        curlIsRunning = false;
    } else if ((strcmp(commandName, "scp") == 0) || (strcmp(commandName, "sftp") == 0)) {
        NSLog(@"Ending a scp/sftp command.");
        scpIsRunning = false;
    } else if ((strcmp(commandName, "rsync") == 0) || (strcmp(commandName, "openrsync") == 0)) {
        NSLog(@"Ending a rsync command.");
        rsyncIsRunning[p->numInterpreter] = false;
    }
    if (currentSession->numCommand > 0)
        currentSession->numCommand -= 1;
    else
        currentSession->commandName[0][0] = 0;
    // if (strcmp(currentSession->commandName, commandName) == 0) {
    //     currentSession->commandName[0] = 0;
    // }
    bool isWasm = strcmp(p->argv[0], "wasm") == 0;
    for (int i = 0; i < p->argc; i++) free(p->argv_ref[i]);
    free(p->argv_ref);
    free(p->argv);
    bool isLastThread = (currentSession->lastThreadId == current_thread);
    // sh and bash follow the same rules: under OSH, the caller (the shell's
    // external runner, a pipeline stage, or Python's subprocess adapter) owns
    // the streams it passes and closes them after the command exits.
    bool mustCloseStderr = (fileno(p->stderr) != fileno(stderr)) && (fileno(p->stderr) != fileno(p->stdout))  && (fileno(p->stdout) != fileno(p->stdin));
    mustCloseStderr &= p->isPipeErr;
    if (currentSession != nil) {
        mustCloseStderr &= fileno(p->stderr) != fileno(currentSession->stderr);
        mustCloseStderr &= fileno(p->stderr) != fileno(currentSession->stdout);
    }
    // Some programs stop waiting as soon as stdout/stderr close (which makes sense)
    // This fclose does close the fileno, but I find it re-opened later.
    cleanup_counter++;
    while (pthread_mutex_trylock(&pid_mtx) != 0) { } // Someone else has the lock, so we wait.
    pthread_mutex_unlock(&pid_mtx);
    if (p->ownsStderr || mustCloseStderr) {
        NSLog(@"Closing stderr (mustCloseStderr): %d \n", fileno(p->stderr));
        int res = fclose(p->stderr);
    }
    // In some cases, we find that stdout is equal to stdin after executing the command. We should not close stdin!
    bool mustCloseStdout = (fileno(p->stdout) != fileno(stdout)) && (fileno(p->stdout) != fileno(p->stdin));
    mustCloseStdout &= p->isPipeOut;
    if (currentSession != nil) {
        mustCloseStdout &= fileno(p->stdout) != fileno(currentSession->stdout);
    }
    if (p->ownsStdout || mustCloseStdout) {
        int fd = fileno(p->stdout);
        NSLog(@"Closing stdout (mustCloseStdout): %d \n", fileno(p->stdout));
        int res = fclose(p->stdout);
        // Add close(fd) as well?
        NSLog(@"Result of closing stdout (mustCloseStdout): %d flag: %d\n", res, fcntl(fd, F_GETFD, 0));
    }
    mustCloseStdin &= p->isPipeIn;
    if (currentSession != nil) {
        mustCloseStdin &= fileno(p->stdin) != fileno(currentSession->stdin);
    }
    if (isWasm) {
        // Don't close stdin for Wasm commands piped into others, but do it for files
        char filePath[MAXPATHLEN];
        if (fcntl(fileno(p->stdin), F_GETPATH, filePath) < 0)
            mustCloseStdin &= false;
    }
    // commands started by Python: Python will close stdin (Lua and Perl? not broken, AFAIK)
    if ((currentSession->numCommand > 0) && (strncmp(currentSession->commandName[currentSession->numCommand - 1], "python", 6) == 0)) {
        // NSLog(@"Command started by Python, not closing stdin: %d \n", fileno(p->stdin));
        mustCloseStdin &= false;
    }
    if (p->ownsStdin || mustCloseStdin) {
        NSLog(@"Closing stdin (mustCloseStdin): %d \n", fileno(p->stdin));
        int res = fclose(p->stdin);
    }
    if ((p->dlHandle != RTLD_SELF) && (p->dlHandle != RTLD_MAIN_ONLY)
        && (p->dlHandle != RTLD_DEFAULT) && (p->dlHandle != RTLD_NEXT))
        dlclose(p->dlHandle);
    if (isLastThread) {
        NSLog(@"Terminating lastthread of currentSession %p lastThreadId %p pid: %d\n", (void *)current_thread, (void *)currentSession->lastThreadId, ios_currentPid());
        currentSession->lastThreadId = 0;
    } else {
        NSLog(@"Current thread %p lastthread %p pid: %d\n", (void *)pthread_self(), (void *)currentSession->lastThreadId, ios_currentPid());
    }
    if (backgroundCommand) {
        // If it's a background command, call ios_releaseBackgroundThread:
        // NSLog(@"Releasing a backgroundCommand\n");
        ios_releaseBackgroundThread(current_thread);
    } else {
        if (toNonInteractive) {
            ios_stopInteractive();
        }
        ios_releaseThread(current_thread);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;

    if (currentSession->current_command_root_thread == current_thread) {
        currentSession->current_command_root_thread = 0;
        // Since we ended the root thread for this session, reset SIGWINCH if it was set:
        sigaction (SIGWINCH, &sa, NULL);
    }
    if (currentSession->mainThreadId == current_thread) {
        currentSession->mainThreadId = 0;
        // Since we ended the main thread for this session, reset SIGWINCH if it was set:
        sigaction (SIGWINCH, &sa, NULL);
    }
    if (isNodeCommand) {
        currentNodeCommandIdentifier = 0;
        // The root-thread state above is already clear, so new cancellation
        // requests cannot fall through to pthread_cancel after this store.
        atomic_store_explicit(
            &currentSession->nodeCommandRunning,
            false,
            memory_order_release);
        uint64_t expectedIdentifier = p->nodeCommandIdentifier;
        atomic_compare_exchange_strong_explicit(
            &currentSession->nodeCommandIdentifier,
            &expectedIdentifier,
            0,
            memory_order_acq_rel,
            memory_order_acquire);
        if (p->nodeCommandPrepared &&
            node_mobile_finish_command != NULL) {
            int cancellationRequested = 0;
            int finishStatus =
                node_mobile_finish_command(
                    p->nodeCommandIdentifier, &cancellationRequested);
            if (cancellationRequested) {
                currentSession->global_errno = 130;
            }
            if (finishStatus != 0) {
                NSLog(
                    @"Unable to finish Node command %llu: %s",
                    (unsigned long long)p->nodeCommandIdentifier,
                    strerror(finishStatus));
            }
        }
    }
    if (isPythonCommand) {
        currentPythonCommand = NULL;
        ios_unregister_python_command(currentSession, &p->pythonCommand);
    }
    [NSThread.currentThread.threadDictionary removeObjectForKey:ios_commandContextKey];
    if (p->commandContext) CFRelease(p->commandContext);
    free(parameters); // This was malloc'ed in ios_system
    cleanup_counter--;
    NSLog(@"returning from cleanup_function, session: %s\n", (char*)currentSession->context);
}

static void* run_function(void* parameters) {
    // Signal dispositions are process-wide, so installing handlers here would
    // also affect UIKit, URLSession, and other unrelated threads. SIGSEGV and
    // SIGBUS must retain the host application's dispositions. This mask only
    // blocks SIGPIPE delivery to the command thread; Darwin can deliver a pipe
    // signal to another app thread. Owned pipe descriptors also need
    // F_SETNOSIGPIPE to prevent signal generation at the write.
    sigset_t blockedSignals;
    sigemptyset(&blockedSignals);
    sigaddset(&blockedSignals, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blockedSignals, NULL);

    functionParameters *p = (functionParameters *) parameters;
    ios_setCurrentPid(p->processId);
    bool isPythonCommand = ios_function_runs_python(p->function);
    bool isNodeCommand = ios_function_runs_node(p->function);
    int nodePreparationStatus = 0;
    ios_command_isolation_policy isolation = ios_commandIsExclusiveOrThreadSafe(p->argv[0]);
    bool isFFmpegCommand = isolation == IOS_COMMAND_ISOLATION_EXCLUSIVE_FFMPEG;
    bool isOfficeCommand = isolation == IOS_COMMAND_ISOLATION_EXCLUSIVE_LIBREOFFICE;
    // sh/bash run an OSH evaluator, which is cancelled cooperatively through
    // the session's cancellation flag and must never be pthread-cancelled.
    bool isShellCommand = isolation == IOS_COMMAND_ISOLATION_OSH;
    p->nodeCommandIdentifier = 0;
    p->nodeCommandPrepared = false;
    if (isPythonCommand && p->session != NULL) {
        ios_register_python_command(p->session, &p->pythonCommand);
    }
    if (isNodeCommand && p->session != NULL) {
        if (node_mobile_prepare_command == NULL ||
            node_mobile_cancel_command == NULL ||
            node_mobile_finish_command == NULL) {
            nodePreparationStatus = ENOSYS;
        } else {
            uint64_t commandIdentifier = atomic_fetch_add_explicit(
                &nextNodeCommandIdentifier, 1, memory_order_relaxed);
            if (commandIdentifier == 0) {
                commandIdentifier = atomic_fetch_add_explicit(
                    &nextNodeCommandIdentifier, 1, memory_order_relaxed);
            }
            nodePreparationStatus =
                node_mobile_prepare_command(commandIdentifier);
            if (nodePreparationStatus == 0) {
                p->nodeCommandIdentifier = commandIdentifier;
                p->nodeCommandPrepared = true;
                if (atomic_load_explicit(
                        &p->session->cancellationRequested,
                        memory_order_acquire)) {
                    node_mobile_cancel_command(commandIdentifier);
                }
                atomic_store_explicit(
                    &p->session->nodeCommandIdentifier,
                    commandIdentifier,
                    memory_order_release);
            }
        }
        // For a runnable command, NodeMobile owns stable cancellation state
        // before this publication. A preparation failure never enters Node,
        // but remains marked through cleanup so it cannot reach pthread_cancel.
        atomic_store_explicit(
            &p->session->nodeCommandRunning,
            true,
            memory_order_release);
    }
    NSLog(@"Storing thread_id: %p pid: %d isPipeOut: %d isPipeErr: %d stdin %d stdout %d stderr %d command= %s\n", (void *)pthread_self(), ios_currentPid(), p->isPipeOut, p->isPipeErr,
          (p->stdin == nil) ? -1 : fileno(p->stdin),
          (p->stdout == nil) ? -1 : fileno(p->stdout),
          (p->stderr == nil) ? -1 : fileno(p->stderr), p->argv[0]);
    ios_storeThreadId(pthread_self());
    bool cancelledBeforeStart = false;
    if (p->storeRootThread && (p->session != NULL)) {
        NSLog(@"Storing thread_id: %p as root_thread\n", (void *)pthread_self());
        p->session->current_command_root_thread = pthread_self();
        if (!isPythonCommand && !isNodeCommand && !isFFmpegCommand && !isOfficeCommand &&
            !isShellCommand) {
            atomic_store_explicit(
                &p->session->pthreadCancelableRootCommand,
                pthread_self(),
                memory_order_release);
        }
        // A cancellation requested before this command could be interrupted
        // found nothing to interrupt. Pairs with the fence in ios_kill: either
        // ios_kill sees this command, or this sees its request.
        atomic_thread_fence(memory_order_seq_cst);
        cancelledBeforeStart = atomic_load_explicit(
            &p->session->commandCancellationRequested,
            memory_order_relaxed);
    }
    // NSLog(@"Starting command: %s thread_id %x", p->argv[0], pthread_self());
    // Thread-safe commands use invocation-local parsing (or no getopt).
    // Resetting the legacy globals here would corrupt an overlapping command.
    if (isolation != IOS_COMMAND_ISOLATION_THREAD_SAFE && !isFFmpegCommand && !isOfficeCommand &&
        isolation != IOS_COMMAND_ISOLATION_EXCLUSIVE_DRAW_THINGS) {
        optind = 1;
        opterr = 1;
        optreset = 1;
    }
    __db_getopt_reset = 1;
    thread_stdin  = p->stdin;
    thread_stdout = p->stdout;
    thread_stderr = p->stderr;
    thread_context = p->context;
    currentSession = p->session;
    if (p->commandContext)
        NSThread.currentThread.threadDictionary[ios_commandContextKey] = (__bridge id)p->commandContext;
    currentPythonCommand = isPythonCommand ? &p->pythonCommand : NULL;
    currentNodeCommandIdentifier =
        isNodeCommand ? p->nodeCommandIdentifier : 0;
    if ((strcmp(p->argv[0], "less") == 0) || (strcmp(p->argv[0], "more") == 0)) {
        if (currentSession != nil) currentSession->activePager = TRUE;
    }

    // Because some commands change argv, keep a local copy for release.
    p->argv_ref = (char **)malloc(sizeof(char*) * (p->argc + 1));
    for (int i = 0; i < p->argc; i++) p->argv_ref[i] = p->argv[i];
    pthread_cleanup_push(cleanup_function, parameters);
    @try
    {
        int retval;
        if (nodePreparationStatus != 0) {
            fprintf(
                thread_stderr,
                "node: unable to prepare command cancellation state: %s\n",
                strerror(nodePreparationStatus));
            retval = 1;
        } else if (cancelledBeforeStart) {
            ios_disable_root_command_pthread_cancel(p);
            retval = 130;
        } else {
            retval = p->function(p->argc, p->argv);
            ios_disable_root_command_pthread_cancel(p);
        }
        if (currentSession != nil) currentSession->global_errno = retval;
    }
    @catch (NSException *exception)
    {
        ios_disable_root_command_pthread_cancel(p);
      // Print exception information.
      NSLog( @"NSException caught" );
      NSLog( @"Name: %@", exception.name);
      NSLog( @"Reason: %@", exception.reason );
        fprintf(thread_stderr, "Command %s was interrupted because it triggered a system exception: %s: %s\n", p->argv[0], exception.name.UTF8String, exception.reason.UTF8String);
        // An uncaught exception aborts a real process: report 128 + SIGABRT.
        if (currentSession != nil) {
            currentSession->global_errno = 128 + SIGABRT;
        }
      return NULL;
    }
    @finally
    {
      // Cleanup, in both success and fail cases
        pthread_cleanup_pop(1);
        return NULL;
    }
}

static NSString* miniRoot = nil; // limit operations to below a certain directory (~, usually).
static NSArray<NSString*> *allowedPaths = nil;
static NSDictionary *commandList = nil;
NSArray *backgroundCommandList = nil;
// do recompute directoriesInPath only if $PATH has changed
static NSString* fullCommandPath = @"";
static NSArray *directoriesInPath;
static NSString *systemDocumentsBinPath = nil;
static NSString *systemLibraryBinPath = nil;
static NSString *systemNodeModulesBinPath = nil;
static NSString *systemPythonPathEntry = nil;
// Sessions run concurrently on different threads but share $PATH, $PYTHONPATH and
// the caches above. Replacing a strong global releases the old object, so every
// read and write of them must hold this mutex.
static pthread_mutex_t commandPathMutex = PTHREAD_MUTEX_INITIALIZER;
static NSString *nodeNPMCommandPath = nil;
static NSString *nodeNPXCommandPath = nil;
static int isRealCommand(const char* fileName);
static void initializeCommandList(void);

static NSString * const ios_pythonVersionDirectory = @"python3.14";

static void ios_setEnvironmentVariable(const char *name, const char *value, int overwrite) {
    setenv(name, value, overwrite);
    ios_setenv(name, value, overwrite);
}

static void ios_unsetEnvironmentVariable(const char *name) {
    unsetenv(name);
    ios_unsetenv(name);
}

static NSString *ios_pythonHomePath(NSString *mainBundlePath, NSString *libPath) {
    NSString *bundledPythonHome = [mainBundlePath stringByAppendingPathComponent:@"Library"];
    NSString *bundledPythonLib = [bundledPythonHome stringByAppendingPathComponent:@"lib"];
    BOOL bundledPythonLibIsDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:bundledPythonLib isDirectory:&bundledPythonLibIsDirectory] &&
        bundledPythonLibIsDirectory) {
        return bundledPythonHome;
    }
    return libPath;
}

static BOOL ios_pathIsEqualToOrDescendantOfPath(NSString *path, NSString *directory) {
    if ([path isEqualToString:directory]) {
        return YES;
    }
    NSString *prefix = [directory hasSuffix:@"/"]
        ? directory
        : [directory stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

// Returns a snapshot that stays valid after another session replaces the cache.
static NSArray<NSString *> *ios_directoriesInPath(void) {
    pthread_mutex_lock(&commandPathMutex);
    const char *pathValue = getenv("PATH");
    NSString *checkingPath = pathValue != NULL ? [NSString stringWithUTF8String:pathValue] : nil;
    if (checkingPath != nil && ![fullCommandPath isEqualToString:checkingPath]) {
        fullCommandPath = checkingPath;
        directoriesInPath = [fullCommandPath componentsSeparatedByString:@":"];
    }
    NSArray<NSString *> *directories = directoriesInPath ?: @[];
    pthread_mutex_unlock(&commandPathMutex);
    return directories;
}

static void ios_setManagedPathEntries(NSString *documentsPath, NSString *libraryPath, NSString *projectPath) {
    NSString *documentsBinPath = [documentsPath stringByAppendingPathComponent:@"bin"];
    NSString *libraryBinPath = [libraryPath stringByAppendingPathComponent:@"bin"];
    NSString *nodeModulesBinPath =
        projectPath != nil ? [projectPath stringByAppendingPathComponent:@"node_modules/.bin"] : nil;
    NSString *virtualBinPath = [NSString stringWithUTF8String:ios_command_virtual_bin_path()];
    pthread_mutex_lock(&commandPathMutex);
    const char *currentPath = ios_getenv("PATH");
    NSString *checkingPath = currentPath != NULL ? [NSString stringWithCString:currentPath encoding:NSUTF8StringEncoding] : @"";
    if (checkingPath != nil && ![fullCommandPath isEqualToString:checkingPath]) {
        fullCommandPath = checkingPath;
    }
    NSMutableArray<NSString *> *pathComponents = [[fullCommandPath componentsSeparatedByString:@":"] mutableCopy];
    [pathComponents removeObject:@""];
    [pathComponents removeObject:virtualBinPath];
    if (systemDocumentsBinPath != nil) {
        [pathComponents removeObject:systemDocumentsBinPath];
    }
    if (systemLibraryBinPath != nil) {
        [pathComponents removeObject:systemLibraryBinPath];
    }
    if (systemNodeModulesBinPath != nil) {
        [pathComponents removeObject:systemNodeModulesBinPath];
    }
    [pathComponents removeObject:documentsBinPath];
    [pathComponents removeObject:libraryBinPath];
    [pathComponents insertObject:libraryBinPath atIndex:0];
    [pathComponents insertObject:documentsBinPath atIndex:0];
    if (nodeModulesBinPath != nil) {
        [pathComponents removeObject:nodeModulesBinPath];
        [pathComponents insertObject:nodeModulesBinPath atIndex:0];
    }
    [pathComponents insertObject:virtualBinPath atIndex:0];
    fullCommandPath = [pathComponents componentsJoinedByString:@":"];
    directoriesInPath = [fullCommandPath componentsSeparatedByString:@":"];
    ios_setEnvironmentVariable("PATH", fullCommandPath.UTF8String, 1);
    systemDocumentsBinPath = documentsBinPath;
    systemLibraryBinPath = libraryBinPath;
    systemNodeModulesBinPath = nodeModulesBinPath;
    pthread_mutex_unlock(&commandPathMutex);
}

static void ios_setManagedPythonPath(NSString *pythonPathEntry) {
    pthread_mutex_lock(&commandPathMutex);
    const char *currentPythonPath = ios_getenv("PYTHONPATH");
    NSMutableArray<NSString *> *pathComponents;
    if (currentPythonPath != NULL && currentPythonPath[0] != 0) {
        pathComponents = [[[NSString stringWithUTF8String:currentPythonPath] componentsSeparatedByString:@":"] mutableCopy];
    } else {
        pathComponents = [NSMutableArray new];
    }
    [pathComponents removeObject:@""];
    if (systemPythonPathEntry != nil) {
        [pathComponents removeObject:systemPythonPathEntry];
    }
    if (pythonPathEntry != nil) {
        [pathComponents removeObject:pythonPathEntry];
        [pathComponents insertObject:pythonPathEntry atIndex:0];
    }
    if (pathComponents.count > 0) {
        ios_setEnvironmentVariable("PYTHONPATH", [pathComponents componentsJoinedByString:@":"].UTF8String, 1);
    } else {
        ios_unsetEnvironmentVariable("PYTHONPATH");
    }
    systemPythonPathEntry = pythonPathEntry;
    pthread_mutex_unlock(&commandPathMutex);
}

static NSString *ios_systemDirectoryPath(NSURL *url, const char *name, BOOL canonical) {
    NSString *path = url.path;
    if (path.length == 0) {
        fprintf(stderr, "ios_system: missing %s directory\n", name);
        return nil;
    }
    struct stat attributes;
    if (stat(path.fileSystemRepresentation, &attributes) != 0) {
        int failure = errno;
        fprintf(stderr, "ios_system: %s directory %s: %s\n",
                name, path.fileSystemRepresentation, strerror(failure));
        return nil;
    }
    if (!S_ISDIR(attributes.st_mode)) {
        fprintf(stderr, "ios_system: %s directory %s: not a directory\n",
                name, path.fileSystemRepresentation);
        return nil;
    }
    if (!canonical) return path;
    char resolvedPath[MAXPATHLEN];
    if (realpath(path.fileSystemRepresentation, resolvedPath) == NULL) {
        int failure = errno;
        fprintf(stderr, "ios_system: resolve %s directory %s: %s\n",
                name, path.fileSystemRepresentation, strerror(failure));
        return nil;
    }
    return [NSString stringWithUTF8String:resolvedPath];
}

static BOOL ios_createSystemDirectory(NSString *path, NSDictionary *attributes) {
    NSError *error = nil;
    if ([NSFileManager.defaultManager createDirectoryAtPath:path
            withIntermediateDirectories:YES attributes:attributes error:&error]) return YES;
    fprintf(stderr, "ios_system: create directory %s: %s\n",
            path.fileSystemRepresentation, error.localizedDescription.UTF8String);
    return NO;
}

// Python trusts a cached .pyc when the source mtime and size match. Bundled
// sources carry the same fixed archive mtime in every app version, so an
// update that keeps a file's size would otherwise reuse the previous version's
// bytecode (e.g. Pillow 12.2.0 -> 12.3.0 `PIL/_version.py`). Keep the cache per
// bundle version and remove caches from other versions once per process.
// Without a bundle version the "dev" cache cannot be trusted, so it is removed
// too.
static NSString *pythonCacheRootPath;
static NSString *pythonCachePath;
static pthread_mutex_t pythonCachePathMutex = PTHREAD_MUTEX_INITIALIZER;
static NSString *ios_pythonCachePath(NSString *libraryPath) {
    NSString *cacheRoot = [libraryPath stringByAppendingPathComponent:@"__pycache__"];
    pthread_mutex_lock(&pythonCachePathMutex);
    if (![pythonCacheRootPath isEqualToString:cacheRoot]) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        BOOL keepsVersion = [version isKindOfClass:NSString.class] && version.length > 0;
        if (!keepsVersion) version = @"dev";
        NSFileManager *fileManager = NSFileManager.defaultManager;
        for (NSString *entry in [fileManager contentsOfDirectoryAtPath:cacheRoot error:nil]) {
            if (keepsVersion && [entry isEqualToString:version]) continue;
            NSString *entryPath = [cacheRoot stringByAppendingPathComponent:entry];
            NSError *error = nil;
            if (![fileManager removeItemAtPath:entryPath error:&error]) {
                fprintf(stderr, "ios_system: remove Python cache %s: %s\n",
                        entryPath.fileSystemRepresentation, error.localizedDescription.UTF8String);
            }
        }
        pythonCacheRootPath = cacheRoot;
        pythonCachePath = [cacheRoot stringByAppendingPathComponent:version];
    }
    NSString *path = pythonCachePath;
    pthread_mutex_unlock(&pythonCachePathMutex);
    return path;
}

int ios_setSystemPaths(
    NSURL *documentsURL,
    NSURL *libraryURL,
    NSURL *cachesURL,
    NSURL *workspaceURL,
    NSURL *projectURL,
    NSURL *appBundleURL) {
    NSString *documentsPath = ios_systemDirectoryPath(documentsURL, "documents", NO);
    if (documentsPath == nil) return 0;
    NSString *libraryPath = ios_systemDirectoryPath(libraryURL, "library", NO);
    if (libraryPath == nil) return 0;
    // Recreate disposable caches before validating command paths.
    if (cachesURL.path.length > 0 && !ios_createSystemDirectory(cachesURL.path, nil)) return 0;
    NSString *cachesPath = ios_systemDirectoryPath(cachesURL, "caches", NO);
    if (cachesPath == nil) return 0;
    NSString *workspacePath = ios_systemDirectoryPath(workspaceURL, "workspace", YES);
    if (workspacePath == nil) return 0;
    NSString *projectPath =
        projectURL != nil ? ios_systemDirectoryPath(projectURL, "project", YES) : nil;
    if (projectURL != nil && projectPath == nil) return 0;
    NSString *appBundlePath = ios_systemDirectoryPath(appBundleURL, "app bundle", YES);
    if (appBundlePath == nil) return 0;
    if (projectPath != nil && !ios_pathIsEqualToOrDescendantOfPath(projectPath, workspacePath)) {
        fprintf(stderr,
                "ios_system: project %s is outside workspace %s\n",
                projectPath.fileSystemRepresentation, workspacePath.fileSystemRepresentation);
        return 0;
    }

    NSString *tmpPath = [cachesPath stringByAppendingPathComponent:@"tmp"];
    // Keep temporary files accessible while locked. createDirectory does not
    // update protection on existing directories.
    NSDictionary *temporaryAttributes = @{NSFileProtectionKey: NSFileProtectionNone};
    if (!ios_createSystemDirectory(tmpPath, temporaryAttributes)) return 0;
    NSError *temporaryProtectionError = nil;
    if (![NSFileManager.defaultManager setAttributes:temporaryAttributes ofItemAtPath:tmpPath error:&temporaryProtectionError]) {
        fprintf(stderr,
                "ios_system: configure temporary directory protection %s: %s\n",
                tmpPath.fileSystemRepresentation, temporaryProtectionError.localizedDescription.UTF8String);
        return 0;
    }
    tmpPath = ios_systemDirectoryPath([NSURL fileURLWithPath:tmpPath isDirectory:YES], "temporary", YES);
    if (tmpPath == nil) return 0;
    NSString *sshPath = [documentsPath stringByAppendingPathComponent:@".ssh"];
    NSDictionary *sshDirectoryAttributes = @{NSFilePosixPermissions: @0700};
    if (!ios_createSystemDirectory(sshPath, sshDirectoryAttributes)) {
        return 0;
    }
    NSString *pythonUserBase = libraryPath;
    NSString *pythonPathEntry = nil;
    if (projectPath != nil) {
        pythonUserBase = [[projectPath stringByAppendingPathComponent:@".localc"] stringByAppendingPathComponent:@"python"];
        NSString *pythonLibPath = [[pythonUserBase stringByAppendingPathComponent:@"lib"] stringByAppendingPathComponent:ios_pythonVersionDirectory];
        if (!ios_createSystemDirectory(pythonLibPath, nil)) {
            return 0;
        }
        pythonPathEntry = [pythonLibPath stringByAppendingPathComponent:@"site-packages"];
    }

    NSString *nodeCachePath;
    if (projectPath != nil) {
        nodeCachePath = [[[projectPath stringByAppendingPathComponent:@".localc"]
            stringByAppendingPathComponent:@"node"] stringByAppendingPathComponent:@"cache"];
    } else {
        nodeCachePath = [[cachesPath stringByAppendingPathComponent:@"node"]
            stringByAppendingPathComponent:@"npm"];
    }
    if (!ios_createSystemDirectory(nodeCachePath, nil)) {
        return 0;
    }

    if (currentSession != NULL) {
        strlcpy(
            currentSession->workspaceDirectory,
            workspacePath.fileSystemRepresentation,
            sizeof(currentSession->workspaceDirectory));
        strlcpy(
            currentSession->temporaryDirectory,
            tmpPath.fileSystemRepresentation,
            sizeof(currentSession->temporaryDirectory));
        strlcpy(
            currentSession->appBundleDirectory,
            appBundlePath.fileSystemRepresentation,
            sizeof(currentSession->appBundleDirectory));
        if (currentSession->currentDir[0] == 0) {
            NSString *startPath = projectPath ?: workspacePath;
            strlcpy(
                currentSession->currentDir,
                startPath.fileSystemRepresentation,
                sizeof(currentSession->currentDir));
            strlcpy(
                currentSession->previousDirectory,
                startPath.fileSystemRepresentation,
                sizeof(currentSession->previousDirectory));
        }
    }

    ios_setManagedPathEntries(documentsPath, libraryPath, projectPath);
    ios_setManagedPythonPath(pythonPathEntry);
    ios_setEnvironmentVariable("PATH_LOCALE", documentsPath.UTF8String, 1);
    ios_setEnvironmentVariable("SSH_HOME", documentsPath.UTF8String, 1);
    ios_setEnvironmentVariable("DIG_HOME", documentsPath.UTF8String, 1);
    ios_setEnvironmentVariable("CURL_HOME", documentsPath.UTF8String, 1);
    ios_setEnvironmentVariable("CURLOPT_SSH_KNOWNHOSTS", [documentsPath stringByAppendingPathComponent:@".ssh/known_hosts"].UTF8String, 1);
    ios_setEnvironmentVariable("HOME", workspacePath.UTF8String, 1);
    ios_setEnvironmentVariable("TMPDIR", tmpPath.UTF8String, 1);
    ios_setEnvironmentVariable("PYTHONUSERBASE", pythonUserBase.UTF8String, 1);
    ios_setEnvironmentVariable("PYTHONPYCACHEPREFIX", ios_pythonCachePath(libraryPath).UTF8String, 1);
    ios_setEnvironmentVariable("PYTHON_HISTORY", [documentsPath stringByAppendingPathComponent:@".python_history"].UTF8String, 1);
    ios_setEnvironmentVariable("XDG_CACHE_HOME", cachesPath.UTF8String, 1);
    ios_setEnvironmentVariable("XDG_CONFIG_HOME", [libraryPath stringByAppendingPathComponent:@"Preferences"].UTF8String, 1);
    ios_setEnvironmentVariable("XDG_STATE_HOME", libraryPath.UTF8String, 1);
    ios_setEnvironmentVariable("XDG_DATA_HOME", libraryPath.UTF8String, 1);
    ios_setEnvironmentVariable("PIP_CACHE_DIR", [cachesPath stringByAppendingPathComponent:@"pip"].UTF8String, 1);
    ios_setEnvironmentVariable("NPM_CONFIG_CACHE", nodeCachePath.UTF8String, 1);
    ios_setEnvironmentVariable("NPM_CONFIG_IGNORE_SCRIPTS", "true", 1);
    ios_setEnvironmentVariable("NPM_CONFIG_UPDATE_NOTIFIER", "false", 1);
    ios_unsetEnvironmentVariable("PIP_TARGET");
    if (projectPath != nil) {
        ios_setEnvironmentVariable("PIP_PREFIX", pythonUserBase.UTF8String, 1);
    } else {
        ios_unsetEnvironmentVariable("PIP_PREFIX");
    }
    ios_setEnvironmentVariable("JUPYTER_CONFIG_DIR", [documentsPath stringByAppendingPathComponent:@".jupyter"].UTF8String, 1);
    ios_setEnvironmentVariable("IPYTHONDIR", [documentsPath stringByAppendingPathComponent:@".ipython"].UTF8String, 1);
    ios_setEnvironmentVariable("MPLCONFIGDIR", [documentsPath stringByAppendingPathComponent:@".config/matplotlib"].UTF8String, 1);
    ios_setEnvironmentVariable("HGRCPATH", [documentsPath stringByAppendingPathComponent:@".hgrc"].UTF8String, 1);
    return 1;
}

static NSString *officeProgramPath;
static pthread_mutex_t officeProgramPathMutex = PTHREAD_MUTEX_INITIALIZER;
int ios_setOfficeProgramPath(NSString *path) {
    BOOL directory = NO;
    if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) return 0;
    pthread_mutex_lock(&officeProgramPathMutex);
    const BOOL accepted = !officeProgramPath || [officeProgramPath isEqualToString:path];
    if (accepted && !officeProgramPath) officeProgramPath = [path copy];
    pthread_mutex_unlock(&officeProgramPathMutex);
    return accepted;
}
NSString *ios_officeProgramPath(void) {
    pthread_mutex_lock(&officeProgramPathMutex);
    NSString *path = officeProgramPath;
    pthread_mutex_unlock(&officeProgramPathMutex);
    return path;
}

int ios_setNodeCommandPaths(NSString *npmPath, NSString *npxPath) {
    BOOL npmIsDirectory = NO;
    BOOL npxIsDirectory = NO;
    if (npmPath.length == 0 || npxPath.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:npmPath isDirectory:&npmIsDirectory] ||
        ![NSFileManager.defaultManager fileExistsAtPath:npxPath isDirectory:&npxIsDirectory] ||
        npmIsDirectory || npxIsDirectory) {
        return 0;
    }
    nodeNPMCommandPath = [npmPath copy];
    nodeNPXCommandPath = [npxPath copy];
    ios_setEnvironmentVariable(
        "NODE_MOBILE_NPX_CLI", nodeNPXCommandPath.fileSystemRepresentation, 1);
    return 1;
}

void initializeEnvironment(void) {
    // Embedded commands share the app's descriptors. Raise the soft limit
    // before command streams are allocated, without changing the hard limit.
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
        rlim_t target = MIN((rlim_t)4096, limit.rlim_max);
        if (limit.rlim_cur < target) {
            rlim_t previous = limit.rlim_cur;
            limit.rlim_cur = target;
            if (setrlimit(RLIMIT_NOFILE, &limit) == 0) {
                NSLog(@"ios_system: descriptor soft limit increased from %llu to %llu (hard limit unchanged)",
                      (unsigned long long)previous, (unsigned long long)target);
            } else {
                int failure = errno;
                NSLog(@"ios_system: unable to prepare descriptor limit: %s", strerror(failure));
            }
        }
    }

    // setup a few useful environment variables
    // Initialize paths for application files, including history.txt and keys
    NSString *docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    
    // Where bundled executables are stored: $PATH + $APPDIR/bin + $APPDIR/Library/bin.
    // Add content of old PATH to this. PATH *is* defined in iOS, surprising as it may be.
    // I'm not going to erase it, so we just add ourselves.
    // Sometimes, we go through main several times, so make sure we only append to PATH once
    NSString* checkingPath = [NSString stringWithCString:getenv("PATH") encoding:NSUTF8StringEncoding];
    if (! [fullCommandPath isEqualToString:checkingPath]) {
        fullCommandPath = checkingPath;
    }
    NSString *mainBundlePath = [[NSBundle mainBundle] resourcePath];
    if (!sideLoading) {
        // If we're not sideloading, executebles will also be in the Application directory
        NSString *mainBundleLibPath = [mainBundlePath stringByAppendingPathComponent:@"Library"];
        // if we're not sideloading, all "executable" files are in the AppDir:
        // $APPDIR/Library/bin
        NSString *binPath = [mainBundleLibPath stringByAppendingPathComponent:@"bin"];
        if (![fullCommandPath containsString:binPath]) {
            fullCommandPath = [[binPath stringByAppendingString:@":"] stringByAppendingString:fullCommandPath];
        }
        // $APPDIR/bin
        binPath = [mainBundlePath stringByAppendingPathComponent:@"bin"];
        if (![fullCommandPath containsString:binPath]) {
            fullCommandPath = [[binPath stringByAppendingString:@":"] stringByAppendingString:fullCommandPath];
        }
    }
    NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    NSString *virtualBinPath = [NSString stringWithUTF8String:ios_command_virtual_bin_path()];
    NSMutableArray<NSString *> *pathComponents = [[fullCommandPath componentsSeparatedByString:@":"] mutableCopy];
    [pathComponents removeObject:virtualBinPath];
    if (pathComponents.count == 1 && pathComponents[0].length == 0) {
        [pathComponents removeAllObjects];
    }
    [pathComponents insertObject:virtualBinPath atIndex:0];
    fullCommandPath = [pathComponents componentsJoinedByString:@":"];
    directoriesInPath = [fullCommandPath componentsSeparatedByString:@":"];
    setenv("PATH", fullCommandPath.UTF8String, 1); // 1 = override existing value
    setenv("APPDIR", mainBundlePath.UTF8String, 1);

    setenv("TERM", "xterm", 1); // 1 = override existing value
    setenv("CLICOLOR", "1", 1);
    setenv("LSCOLORS", "ExFxBxDxCxegedabagacad", 0); // colors for ls on black background
    // iOS already defines "HOME" as the home dir of the application
    for (int i = 0; i < MaxPythonInterpreters; i++) PythonIsRunning[i] = false;
    for (int i = 0; i < MaxPerlInterpreters; i++) PerlIsRunning[i] = false;
    // Build the command table before any session can run a command, so
    // concurrent first commands only read it. Commands registered later are
    // found through ios_command_lookup.
    initializeCommandList();
    // environment variables for Python:
    NSString *pythonHome = ios_pythonHomePath(mainBundlePath, libPath);
    setenv("PYTHONHOME", pythonHome.UTF8String, 0);  // Bundled Library when available, otherwise ~/Library.
    NSString *pythonVersionPath = [[pythonHome stringByAppendingPathComponent:@"lib"] stringByAppendingPathComponent:ios_pythonVersionDirectory];
    NSString *bundledCertifiCACert = [[[pythonVersionPath stringByAppendingPathComponent:@"site-packages"] stringByAppendingPathComponent:@"certifi"] stringByAppendingPathComponent:@"cacert.pem"];
    BOOL bundledCertifiCACertIsDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:bundledCertifiCACert isDirectory:&bundledCertifiCACertIsDirectory] &&
        !bundledCertifiCACertIsDirectory) {
        setenv("SSL_CERT_FILE", bundledCertifiCACert.UTF8String, 0);
    } else {
        setenv("SSL_CERT_FILE", [docsPath stringByAppendingPathComponent:@"cacert.pem"].UTF8String, 0);
    }
    setenv("PIP_DISABLE_PIP_VERSION_CHECK", "1", 0);
    // if we use Python, we define a few more environment variables:
    setenv("PYTHONEXECUTABLE", "python3", 0);  // Python executable name for python3
    setenv("MPLBACKEND", "Agg", 0);
    NSString *matplotlibDataPath = [[[pythonVersionPath stringByAppendingPathComponent:@"site-packages"] stringByAppendingPathComponent:@"matplotlib"] stringByAppendingPathComponent:@"mpl-data"];
    setenv("MATPLOTLIBDATA", matplotlibDataPath.UTF8String, 0);
    directoriesInPath = [fullCommandPath componentsSeparatedByString:@":"];
    setenv("PATH", fullCommandPath.UTF8String, 1); // 1 = override existing value
    // Initialize the array with the name of TeX commands (this might be too many commands):
    TeXcommands = @[@"amstex", @"cslatex", @"csplain", @"eplain", @"etex", @"jadetex", @"latex", @"mex", @"mllatex", @"mltex", @"pdfsclatex", @"pdfcsplain", @"pdfetex", @"pdfjadetex", @"pdflatex", @"pdfmex", @"pdftex", @"pdfxmltex", @"tex", @"texsis", @"utf8mex", @"xmltex", @"texlua", @"texluac", @"dvilualatex", @"dviluatex", @"lualatex", @"luatex", @"luahbtex", @"mptopdf", @"optex",
                    @"xetex", @"xelatex", @"dvipdfmx", @"xdvipdfmx",
        @"amstexA", @"cslatexA", @"csplainA", @"eplainA", @"etexA", @"jadetexA", @"latexA", @"mexA", @"mllatexA", @"mltexA", @"pdfsclatexA", @"pdfcsplainA", @"pdfetexA", @"pdfjadetexA", @"pdflatexA", @"pdfmexA", @"pdftexA", @"pdfxmltexA", @"texA", @"texsisA", @"utf8mexA", @"xmltexA", @"texluaA", @"texluacA", @"dvilualatexA", @"dviluatexA", @"lualatexA", @"luatexA", @"luahbtexA", @"mptopdfA", @"optexA",
                    @"xetexA", @"xelatexA",  @"dvipdfmxA", @"xdvipdfmxA"];
}

NSString * pathJoin(NSString * segmentA, NSString * segmentB);
static char* unquoteArgument(char* argument);

static char* parseArgument(char* argument, char* command) {
    // expand all environment variables, convert "~" to $HOME (only if localFile)
    // we also pass the shell command for some specific behaviour (don't do this for that command)
    NSString* argumentString = [NSString stringWithCString:argument encoding:NSUTF8StringEncoding];
    // NSLog(@"parsing argument, argumentString= %s", argumentString.UTF8String);
    // If command == "export", first extract the value string here.
    NSString* variableName;
    if (strcmp(command, "export") == 0) {
        char* equalSign=strchr(argument,'=');
        if (equalSign && (strlen(equalSign) > 0)) {
            char* argumentCString=equalSign+1;
            argumentCString = unquoteArgument(argumentCString);
            variableName = [argumentString substringToIndex:(equalSign - argument)];
            argumentString = [NSString stringWithCString:argumentCString encoding:NSUTF8StringEncoding];
            // NSLog(@"parsing argument, variable name= %s argument= %s", variableName.UTF8String, argumentString.UTF8String);
        } else {
            // No equal sign, or nothing after. export_main will take care of this.
            return argument;
        }
    }
    // 1) expand environment variables, + "~" (not wildcards ? and *)
    bool cannotExpand = false;
    while ([argumentString containsString:@"$"] && !cannotExpand) {
        // It has environment variables inside. Work on them one by one.
        // position of first "$" sign:
        NSRange r1 = [argumentString rangeOfString:@"$"];
        // position of first "/" after this $ sign:
        NSRange r2 = [argumentString rangeOfString:@"/" options:NULL range:NSMakeRange(r1.location + r1.length, [argumentString length] - r1.location - r1.length)];
        // position of first ":" after this $ sign:
        NSRange r3 = [argumentString rangeOfString:@":" options:NULL range:NSMakeRange(r1.location + r1.length, [argumentString length] - r1.location - r1.length)];
        if ((r2.location == NSNotFound) && (r3.location == NSNotFound)) r2.location = [argumentString length];
        else if ((r2.location == NSNotFound) || (r3.location < r2.location)) r2.location = r3.location;
        
        NSRange  rSub = NSMakeRange(r1.location + r1.length, r2.location - r1.location - r1.length);
        NSString *variable_string = [argumentString substringWithRange:rSub];
        const char* variable = ios_getenv([variable_string UTF8String]);
        if (variable) {
            // Okay, so this one exists.
            variable_string = [[NSString stringWithCString:"$" encoding:NSUTF8StringEncoding] stringByAppendingString:variable_string];
            NSString* replacement_string = [NSString stringWithCString:variable encoding:NSUTF8StringEncoding];
            argumentString = [argumentString stringByReplacingOccurrencesOfString:variable_string withString:replacement_string];
            if ([replacement_string containsString:variable_string]) // avoid an infinite loop here
                cannotExpand = true;
        } else cannotExpand = true; // found a variable we can't expand. stop trying for this argument
    }
    // 2) Tilde conversion: replace "~" with $HOME
    // If there are multiple users on iOS, this code will need to be changed.
    // We also expand ~bookmarkName to the path for that bookmark.
    // 2a) ~ expansion. (old behaviour, kept as is for compatibility)
    if([argumentString hasPrefix:@"~"]) {
        // So it begins with "~". We can't use stringByExpandingTildeInPath because apps redefine HOME
        NSString* replacement_string;
        if (miniRoot == nil)
            replacement_string = [NSString stringWithCString:(getenv("HOME")) encoding:NSUTF8StringEncoding];
        else replacement_string = miniRoot;
        if (([argumentString hasPrefix:@"~/"]) || ([argumentString hasPrefix:@"~:"]) || ([argumentString length] == 1)) {
            NSString* test_string = @"~";
            argumentString = [argumentString stringByReplacingOccurrencesOfString:test_string withString:replacement_string options:NULL range:NSMakeRange(0, 1)];
        } else {
            // 2b) expand "~something" with the content of userPreference dictionary (to be set by each app)
            NSDictionary *tildeExpansionDictionary = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ios_bookmarkDictionaryName];
            if (tildeExpansionDictionary != nil) {
                NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@":/"];
                NSArray<NSString*>* components = [argumentString componentsSeparatedByCharactersInSet:separators];
                NSString* name = [components[0] substringFromIndex:1]; // remove the "~"
                NSString* expandedPath = tildeExpansionDictionary[name];
                if (expandedPath != nil) {
                    argumentString = [argumentString stringByReplacingOccurrencesOfString:components[0] withString:expandedPath options:NULL range:NSMakeRange(0, [components[0] length])];
                }
            }
        }
    }
    // Also convert ":~something" in PATH style variables
    // We don't use these yet, but we could.
    // We do this expansion only for setenv and export
    if ((strcmp(command, "setenv") == 0) || (strcmp(command, "export") == 0)) {
        // This is something we need to avoid if the command is "scp" or "sftp"
        if ([argumentString containsString:@":~"]) {
            NSString* homeDir;
            if (miniRoot == nil) homeDir = [NSString stringWithCString:(getenv("HOME")) encoding:NSUTF8StringEncoding];
            else homeDir = miniRoot;
            // Only 1 possibility: ":~" (same as $HOME)
            if (homeDir.length > 0) {
                NSString* replacement_string = [@":" stringByAppendingString:homeDir];
                if ([argumentString containsString:@":~/"]) {
                    NSString* test_string = @":~/";
                    replacement_string = [replacement_string stringByAppendingString:[NSString stringWithCString:"/" encoding:NSUTF8StringEncoding]];
                    argumentString = [argumentString stringByReplacingOccurrencesOfString:test_string withString:replacement_string];
                } else if ([argumentString hasSuffix:@":~"]) {
                    NSString* test_string = @":~";
                    argumentString = [argumentString stringByReplacingOccurrencesOfString:test_string withString:replacement_string options:NULL range:NSMakeRange([argumentString length] - 2, 2)];
                } else if ([argumentString hasSuffix:@":"]) {
                    NSString* test_string = @":";
                    argumentString = [argumentString stringByReplacingOccurrencesOfString:test_string withString:replacement_string options:NULL range:NSMakeRange([argumentString length] - 2, 2)];
                }
            }
            NSDictionary *tildeExpansionDictionary = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ios_bookmarkDictionaryName];
            if (tildeExpansionDictionary != nil) {
                // TODO: add :~bookmarkName/ :~bookmarkName
                NSArray<NSString*>* components = [argumentString componentsSeparatedByString:@":~"];
                NSString* result = components[0];
                for (int i = 1; i < components.count; i++) {
                    NSString* stringToAdd = components[i];
                    NSArray<NSString*>* names = [components[i] componentsSeparatedByString:@"/"];
                    NSString* test_string = names[0];
                    NSString* replacement_string = tildeExpansionDictionary[names[0]];
                    if (replacement_string != nil) {
                        // we found a name to expand
                        stringToAdd = [stringToAdd stringByReplacingOccurrencesOfString:test_string withString:replacement_string];
                        result = [[result stringByAppendingString:@":"] stringByAppendingString:stringToAdd];
                    } else {
                        result = [[result stringByAppendingString:@":~"] stringByAppendingString:stringToAdd];
                    }
                }
                argumentString = result;
            }
        }
    }
    if ([argumentString hasPrefix:@"../"] || [argumentString hasPrefix:@"./.."] || [argumentString isEqualToString:@".."]) {
        argumentString = pathJoin(@(currentSession->currentDir), argumentString);
    }
    if (strcmp(command, "export") == 0) {
        argumentString = [[variableName stringByAppendingString:@"="] stringByAppendingString:argumentString];
    }
    const char* newArgument = [argumentString UTF8String];
    // NSLog(@"After parsing: %s", newArgument);
    if (strcmp(argument, newArgument) == 0) return argument; // nothing changed
    // Make sure the argument is reallocated, so it can be free-ed
    char* returnValue = realloc(argument, strlen(newArgument) + 1);
    strcpy(returnValue, newArgument);
    return returnValue;
}

static const char* ios_expandFilename(const char *filename) {
    // expand a filename for opening if it begins with "~" or contains an environment variable
    if (strlen(filename) == 0) return filename;
    NSString* nameString = [NSString stringWithUTF8String:filename];
    if([nameString hasPrefix:@"~"]) {
        // So it begins with "~". We can't use stringByExpandingTildeInPath because apps redefine HOME
        NSString* replacement_string;
        if (miniRoot == nil)
            replacement_string = [NSString stringWithCString:(getenv("HOME")) encoding:NSUTF8StringEncoding];
        else replacement_string = miniRoot;
        if (([nameString hasPrefix:@"~/"]) || ([nameString length] == 1)) {
            NSString* test_string = @"~";
            nameString = [nameString stringByReplacingOccurrencesOfString:test_string withString:replacement_string options:NULL range:NSMakeRange(0, 1)];
        } else {
            // 2b) expand "~something" with the content of userPreference dictionary (to be set by each app)
            NSDictionary *tildeExpansionDictionary = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ios_bookmarkDictionaryName];
            if (tildeExpansionDictionary != nil) {
                NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@":/"];
                NSArray<NSString*>* components = [nameString componentsSeparatedByCharactersInSet:separators];
                NSString* name = [components[0] substringFromIndex:1]; // remove the "~"
                NSString* expandedPath = tildeExpansionDictionary[name];
                if (expandedPath != nil) {
                    nameString = [nameString stringByReplacingOccurrencesOfString:components[0] withString:expandedPath options:NULL range:NSMakeRange(0, [components[0] length])];
                }
            }
        }
    }
    bool cannotExpand = false;
    while ([nameString containsString:@"$"] && !cannotExpand) {
        // It has environment variables inside. Work on them one by one.
        // position of first "$" sign:
        NSRange r1 = [nameString rangeOfString:@"$"];
        // position of first "/" after this $ sign:
        NSRange r2 = [nameString rangeOfString:@"/" options:NULL range:NSMakeRange(r1.location + r1.length, [nameString length] - r1.location - r1.length)];
        if (r2.location == NSNotFound)  r2.location = [nameString length];
        
        NSRange  rSub = NSMakeRange(r1.location + r1.length, r2.location - r1.location - r1.length);
        NSString *variable_string = [nameString substringWithRange:rSub];
        const char* variable = ios_getenv([variable_string UTF8String]);
        if (variable) {
            // Okay, so this one exists.
            NSString* replacement_string = [NSString stringWithCString:variable encoding:NSUTF8StringEncoding];
            variable_string = [[NSString stringWithCString:"$" encoding:NSUTF8StringEncoding] stringByAppendingString:variable_string];
            nameString = [nameString stringByReplacingOccurrencesOfString:variable_string withString:replacement_string];
        } else cannotExpand = true; // found a variable we can't expand. stop trying for this fileName
    }
    return [nameString UTF8String];
}



static void initializeCommandList(void)
{
    if (commandList != nil) return;

    NSMutableDictionary *mutableDict = [NSMutableDictionary dictionaryWithCapacity:ios_command_count()];
    for (int i = 0; i < ios_command_count(); ++i) {
        const ios_command_entry *entry = ios_command_at_index(i);
        if (entry == NULL) {
            continue;
        }
        NSString *libraryName = entry->library_name != NULL ? @(entry->library_name) : @"STATIC";
        mutableDict[@(entry->name)] = @[
            libraryName,
            @(entry->function_name),
            @(entry->getopt_string),
            @(entry->operates_on),
        ];
    }
    commandList = [mutableDict copy];
}

int ios_setMiniRoot(NSString* mRoot) {
    BOOL isDir;
    // NSFileManager *fileManager = [[NSFileManager alloc] init];

    if (![NSFileManager.defaultManager fileExistsAtPath:mRoot isDirectory:&isDir]) {
      return 0;
    }

    if (!isDir) {
      return 0;
    }

    // fileManager has different ways of expressing the same directory.
    // We need to actually change to the directory to get its "real name".
    NSString* currentDir = [NSFileManager.defaultManager currentDirectoryPath];

    if (![NSFileManager.defaultManager changeCurrentDirectoryPath:mRoot]) {
      return 0;
    }
    // also don't set the miniRoot if we can't go in there
    // get the real name for miniRoot:
    miniRoot = [NSFileManager.defaultManager currentDirectoryPath];
    // Back to where we we before:
    [NSFileManager.defaultManager changeCurrentDirectoryPath:currentDir];
    if (currentSession != nil) {
        strcpy(currentSession->currentDir, [miniRoot UTF8String]);
        strcpy(currentSession->previousDirectory, [miniRoot UTF8String]);
    }
    return 1; // mission accomplished
}

// Called when
int ios_setMiniRootURL(NSURL* mRoot) {
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (currentSession == NULL) {
        currentSession = malloc(sizeof(sessionParameters));
        initSessionParameters(currentSession);
    }
    strcpy(currentSession->localMiniRoot, [mRoot.path UTF8String]);
    strcpy(currentSession->previousDirectory, currentSession->currentDir);
    strcpy(currentSession->currentDir, [[mRoot path] UTF8String]);
    [NSFileManager.defaultManager changeCurrentDirectoryPath:[mRoot path]];
    return 1; // mission accomplished
}

int ios_setAllowedPaths(NSArray<NSString *> *paths) {
  allowedPaths = paths;
  return 1;
}

BOOL __allowed_cd_to_path(NSString *path) {
    // NSLog(@"__allowed_cd_to_path: %@ miniRoot: %@\n", path, miniRoot);
    if (miniRoot == nil) {
        return YES;
    }
    if ([path hasPrefix:miniRoot]) {
        return YES;
    }
    if (strlen(currentSession->localMiniRoot) != 0) {
        NSString *localMiniRootPath = [NSString stringWithCString:currentSession->localMiniRoot encoding:NSUTF8StringEncoding];
        // NSLog(@"__allowed_cd_to_path: localMiniRoot: %s\n", localMiniRootPath);
        if (localMiniRootPath && [path hasPrefix:localMiniRootPath]) {
            return YES;
        }
    }
    
    for (NSString *dir in allowedPaths) {
        if ([path hasPrefix:dir]) {
            return YES;
        }
    }
    // NSLog(@"__allowed_cd_to_path: failure, returning NO\n");
    
    return NO;
}

BOOL __cd_to_dir(NSString *newDir, NSFileManager *fileManager) {
  BOOL isDir;
  // Check for permission and existence:
  if (![fileManager fileExistsAtPath:newDir isDirectory:&isDir]) {
    fprintf(thread_stderr, "cd: %s: no such file or directory\n", [newDir UTF8String]);
    return NO;
  }
  if (!isDir) {
    fprintf(thread_stderr, "cd: %s: not a directory\n", [newDir UTF8String]);
    return NO;
  }

  if (![fileManager isReadableFileAtPath:newDir] ||
      ![fileManager changeCurrentDirectoryPath:newDir]) {
    fprintf(thread_stderr, "cd: %s: permission denied\n", [newDir UTF8String]);
    return NO;
  }

  // We managed to change the directory.
  // Was that allowed?
  // Allowed "cd" = below miniRoot *or* below localMiniRoot
  NSString* resultDir = [fileManager currentDirectoryPath];

  if (__allowed_cd_to_path(resultDir)) {
    strcpy(currentSession->previousDirectory, currentSession->currentDir);
    strcpy(currentSession->currentDir, [newDir UTF8String]);
    return YES;
  }
  
  fprintf(thread_stderr, "cd: %s: permission denied\n", [newDir UTF8String]);
  // If the user tried to go above the miniRoot, set it to miniRoot
  if ([miniRoot hasPrefix:resultDir]) {
    [fileManager changeCurrentDirectoryPath:miniRoot];
    strcpy(currentSession->currentDir, [miniRoot UTF8String]);
    strcpy(currentSession->previousDirectory, currentSession->currentDir);
  } else {
    // go back to where we were before:
    [fileManager changeCurrentDirectoryPath:[NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding]];
  }
  return NO;
}

// For some Unix commands that call fchdir (including vim):
#undef fchdir
int ios_fchdir(const int fd) {
    // NSLog(@"Locking for thread %x in ios_fchdir\n", pthread_self());
    while (cleanup_counter > 0) { } // Don't chdir while a command is ending.
    // We cannot have someone change the current directory while a command is starting or terminating.
    // hence the mutex_lock here.
    pthread_mutex_lock(&pid_mtx);
    int result = fchdir(fd);
    if (result < 0) {
        // NSLog(@"Unlocking for thread %x in ios_fchdir\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        return result;
    }
    // We managed to change the directory. Update currentSession as well:
    // Was that allowed?
    // Allowed "cd" = below miniRoot *or* below localMiniRoot
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSString* resultDir = [NSFileManager.defaultManager currentDirectoryPath];
    // NSLog(@"Inside fchdir, path: %s for session: %s\n", resultDir.UTF8String, (char*)currentSession->context);

    if (__allowed_cd_to_path(resultDir)) {
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
        strcpy(currentSession->currentDir, [resultDir UTF8String]);
        errno = 0;
        // NSLog(@"Unlocking for thread %x in ios_fchdir\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        return 0;
    }
    
    errno = EACCES; // Permission denied
    // If the user tried to go above the miniRoot, set it to miniRoot
    if ([miniRoot hasPrefix:resultDir]) {
        [NSFileManager.defaultManager changeCurrentDirectoryPath:miniRoot];
        strcpy(currentSession->currentDir, [miniRoot UTF8String]);
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
    } else {
        // go back to where we were before:
        [NSFileManager.defaultManager changeCurrentDirectoryPath:[NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding]];
    }
    // NSLog(@"Unlocking for thread %x in ios_fchdir\n", pthread_self());
    pthread_mutex_unlock(&pid_mtx);
    return -1;
}

int ios_fchdir_nolock(const int fd) {
    // NSLog(@"fchdir_nolock: %x thread %x\n", fd, pthread_self());
    // Same function as fchdir, except it does not lock. To be called when resetting directory after fork().
    while (cleanup_counter > 0) { } // Don't chdir while a command is ending.
    int result = fchdir(fd);
    if (result < 0) {
        return result;
    }
    // We managed to change the directory. Update currentSession as well:
    // Was that allowed?
    // Allowed "cd" = below miniRoot *or* below localMiniRoot
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSString* resultDir = [NSFileManager.defaultManager currentDirectoryPath];
    // NSLog(@"fchdir_nolock, success: %s\n", resultDir.UTF8String);

    if (__allowed_cd_to_path(resultDir)) {
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
        strcpy(currentSession->currentDir, [resultDir UTF8String]);
        errno = 0;
        return 0;
    }
    
    errno = EACCES; // Permission denied
    // If the user tried to go above the miniRoot, set it to miniRoot
    if ([miniRoot hasPrefix:resultDir]) {
        [NSFileManager.defaultManager changeCurrentDirectoryPath:miniRoot];
        strcpy(currentSession->currentDir, [miniRoot UTF8String]);
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
    } else {
        // go back to where we were before:
        [NSFileManager.defaultManager changeCurrentDirectoryPath:[NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding]];
    }
    // NSLog(@"fchdir_nolock, failure\n");
    return -1;
}

int chdir_nolock(const char* path) {
    // NSLog(@"chdir_nolock: %s thread %x\n", path, pthread_self());
    // Same function as chdir, except it does not lock. To be called from ios_releaseThread*()
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSString* newDir = @(path);
    BOOL isDir;
    // Check for permission and existence:
    if (![NSFileManager.defaultManager fileExistsAtPath:newDir isDirectory:&isDir]) {
        errno = ENOENT; // No such file or directory
        return -1;
    }
    if (!isDir) {
        errno = ENOTDIR; // Not a directory
        return -1;
    }
    if (![NSFileManager.defaultManager isReadableFileAtPath:newDir] ||
        ![NSFileManager.defaultManager changeCurrentDirectoryPath:newDir]) {
        errno = EACCES; // Permission denied
        return -1;
    }
    
    // We managed to change the directory.
    // Was that allowed?
    // Allowed "cd" = below miniRoot *or* below localMiniRoot
    NSString* resultDir = [NSFileManager.defaultManager currentDirectoryPath];
    if (resultDir == nil) {
        resultDir = newDir;
    }

    if (__allowed_cd_to_path(resultDir)) {
        if (currentSession != NULL) {
            strcpy(currentSession->currentDir, [resultDir UTF8String]);
        }
        NSLog(@"allowed directory change, returning\n");
        errno = 0;
        return 0;
    }
    
    errno = EACCES; // Permission denied
    // If the user tried to go above the miniRoot, set it to miniRoot
    if ([miniRoot hasPrefix:resultDir]) {
        [NSFileManager.defaultManager changeCurrentDirectoryPath:miniRoot];
        strcpy(currentSession->currentDir, [miniRoot UTF8String]);
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
    } else {
        // go back to where we were before:
        [NSFileManager.defaultManager changeCurrentDirectoryPath:[NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding]];
    }
    return -1;
}

// For some Unix commands that call chdir:
// Is also called at the end of the execution of each command
int chdir(const char* path) {
    while (cleanup_counter > 0) { } // Don't chdir while a command is ending.
    // NSLog(@"Locking for thread %x in chdir, cd %s\n", pthread_self(), path);
    // We cannot have someone change the current directory while a command is starting or terminating.
    // hence the mutex_lock here.
    pthread_mutex_lock(&pid_mtx);
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSString* newDir = @(path);
    BOOL isDir;
    // Check for permission and existence:
    if (![NSFileManager.defaultManager fileExistsAtPath:newDir isDirectory:&isDir]) {
        errno = ENOENT; // No such file or directory
        // NSLog(@"Unlocking for thread %x in chdir (no such directory)\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        return -1;
    }
    if (!isDir) {
        errno = ENOTDIR; // Not a directory
        // NSLog(@"Unlocking for thread %x in chdir (not a directory)\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        return -1;
    }
    if (![NSFileManager.defaultManager isReadableFileAtPath:newDir] ||
        ![NSFileManager.defaultManager changeCurrentDirectoryPath:newDir]) {
        errno = EACCES; // Permission denied
        // NSLog(@"Unlocking for thread %x in chdir (not readable)\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        return -1;
    }
    
    // We managed to change the directory.
    // Was that allowed?
    // Allowed "cd" = below miniRoot *or* below localMiniRoot
    NSString* resultDir = [NSFileManager.defaultManager currentDirectoryPath];
    // NSLog(@"After changing directory, result= %s\n", resultDir.UTF8String);

    if (__allowed_cd_to_path(resultDir)) {
        if (currentSession != NULL) {
            strcpy(currentSession->currentDir, [resultDir UTF8String]);
        }
        // NSLog(@"Unlocking for thread %x in chdir (allowed)\n", pthread_self());
        pthread_mutex_unlock(&pid_mtx);
        errno = 0;
        return 0;
    }
    
    errno = EACCES; // Permission denied
    if (currentSession == NULL) {
        return -1   ;
    }
    // If the user tried to go above the miniRoot, set it to miniRoot
    if ([miniRoot hasPrefix:resultDir]) {
        [NSFileManager.defaultManager changeCurrentDirectoryPath:miniRoot];
        strcpy(currentSession->currentDir, [miniRoot UTF8String]);
        strcpy(currentSession->previousDirectory, currentSession->currentDir);
    } else {
        // go back to where we were before:
        [NSFileManager.defaultManager changeCurrentDirectoryPath:[NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding]];
    }
    // NSLog(@"Unlocking for thread %lx in chdir (not allowed)\n", (unsigned long)pthread_self());
    pthread_mutex_unlock(&pid_mtx);
    return -1;
}

int too_many_scripts(int argc, char** argv) {
    // Call an actual command in order to go through run_function / cleanup_function
    // But not something as hardcore as causing a "Command not found" error:
    if (currentSession->global_errno == 0) {
        return 0; // show the warning only once for PythonNum commands stored:
    }
    fprintf(thread_stderr, "Too many instances of this command are already running. Please quit some of them or wait for them to end.\n");
    NSLog(@"%s: command not found\n", argv[0]);
    return currentSession->global_errno;
}

int command_not_found(int argc, char** argv) {
    // Call an actual command in order to go through run_function / cleanup_function
    fprintf(thread_stderr, "%s: command not found\n", argv[0]);
    NSLog(@"%s: command not found\n", argv[0]);
    currentSession->global_errno = 127;
    return 127;
    // TODO: this should also raise an exception, for python scripts
}

int xcode_select(int argc, char** argv) {
    // Replacement for xcode-select so config.guess scripts work
    currentSession->global_errno = 1;
    errno = 1;
    return 1;
}

int sw_vers(int argc, char** argv) {
    // Small command to make tlmgr happy
    // tlmgr calls "sw_vers -productVersion". We return the latest OSX version, for simplicity
    fprintf(thread_stdout, "11.5.2");
    fflush(thread_stdout);
    return 0;
}

extern void newPreviousDirectory(void);

int cd_main(int argc, char** argv) {
    if (currentSession == NULL) {
      return 1;
    }
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
  
    if (argc > 1) {
        NSString* newDir = @(argv[1]);
        int directoryAlias = 0;
        if (strcmp(argv[1], "-") == 0) {
            // "cd -" option to pop back to previous directory
            newDir = @(currentSession->previousDirectory);
        }
        char resolvedAlias[MAXPATHLEN];
        directoryAlias = ios_resolveDirectoryAlias(
            newDir.UTF8String, resolvedAlias, sizeof(resolvedAlias));
        if (directoryAlias < 0) {
            return 1;
        }
        if (directoryAlias > 0) {
            newDir = @(resolvedAlias);
        }
        newDir = pathJoin(@(currentSession->currentDir), newDir);
        // Store directory usage for autocomplete:
        // It should not be a dictionary. NSArray? NSMutableArray?
        // Need to store directoryname + number of times = sounds a lot like a Swift dictionary.
        // But not Objective-C? Weird.
        // Do it in Swift (new dictionary each time), then store it, then move to Objective-C?
        void (*function)(NSString*) = NULL;
        function = dlsym(RTLD_MAIN_ONLY, "storeDirectoryUsed");
        if (function == NULL) {
            // more extensive search, but more expensive too.
            function = dlsym(RTLD_DEFAULT, "storeDirectoryUsed");
        }
        if (function != NULL) {
            NSString *key = @(ios_getBookmarkedVersion(newDir.UTF8String));
            function(key);
        }
        BOOL changedDirectory = __cd_to_dir(newDir, NSFileManager.defaultManager);
        if (changedDirectory && directoryAlias == 2) {
            fprintf(thread_stdout, "Warning: this directory is read-only.\n");
        }
    } else {
        const char *home = ios_getenv("HOME");
        if (home == NULL) {
            fprintf(thread_stderr, "cd: HOME not set\n");
            return 1;
        }
        NSString *newDir = pathJoin(@(currentSession->currentDir), @(home));
        if (!__cd_to_dir(newDir, NSFileManager.defaultManager)) {
            return 1;
        }
    }

    newPreviousDirectory(); // If a command is running, this changes the directory it goes back to.
    return 0;
}

NSString* getoptString(NSString* commandName) {
    if (commandList == nil) initializeCommandList();
    NSArray* commandStructure = [commandList objectForKey: commandName];
    if (commandStructure != nil) return commandStructure[2];
    const ios_command_entry *entry = ios_command_lookup(commandName.UTF8String);
    if (entry != NULL) return @(entry->getopt_string);
    return @"";
}

NSString* operatesOn(NSString* commandName) {
    if (commandList == nil) initializeCommandList();
    NSArray* commandStructure = [commandList objectForKey: commandName];
    if (commandStructure != nil) return commandStructure[3];
    const ios_command_entry *entry = ios_command_lookup(commandName.UTF8String);
    if (entry != NULL) return @(entry->operates_on);
    return @"";
}

int ios_executable(const char* inputCmd) {
    // returns 1 if this is one of the commands we define in ios_system, 0 otherwise
    if (commandList == nil) initializeCommandList();
    // Take basename in case someone put a path before:
    char commandName[PATH_MAX];
    if (basename_r(inputCmd, commandName) == NULL) return 0;
    if (ios_command_lookup(commandName) != NULL) return 1;
    NSArray* valuesFromDict = [commandList objectForKey: [NSString stringWithCString:commandName encoding:NSUTF8StringEncoding]];
    // we could dlopen() here, but that would defeat the purpose
    if (valuesFromDict == nil) return 0;
    else return 1;
}

// Where to direct input/output of the next thread:
static __thread FILE* child_stdin = NULL;
static __thread FILE* child_stdout = NULL;
static __thread FILE* child_stderr = NULL;

static bool ios_isOwnedChildStream(FILE *stream) {
    return stream != NULL &&
        stream != thread_stdin &&
        stream != thread_stdout &&
        stream != thread_stderr &&
        stream != stdin &&
        stream != stdout &&
        stream != stderr;
}

static void ios_closePendingChildStreams(void) {
    FILE *streams[] = {child_stdin, child_stdout, child_stderr};
    child_stdin = NULL;
    child_stdout = NULL;
    child_stderr = NULL;
    for (int index = 0; index < 3; index++) {
        FILE *stream = streams[index];
        if (!ios_isOwnedChildStream(stream)) {
            continue;
        }
        bool alreadyClosed = false;
        for (int previous = 0; previous < index; previous++) {
            if (streams[previous] == stream) {
                alreadyClosed = true;
                break;
            }
        }
        if (!alreadyClosed) {
            fclose(stream);
        }
    }
}

// Pending redirections can alias one another. Release an old owned stream
// only when the last pending binding is replaced.
static void ios_replaceChildStream(FILE **slot, FILE *replacement) {
    FILE *previous = *slot;
    *slot = replacement;
    if (ios_isOwnedChildStream(previous) &&
        previous != child_stdin && previous != child_stdout && previous != child_stderr) {
        fclose(previous);
    }
}

static int ios_duplicateChildStream(int descriptor, const char *mode, FILE **slot) {
    int duplicated = dup(descriptor);
    if (duplicated < 0) return -1;
    FILE *stream = fdopen(duplicated, mode);
    if (stream == NULL) {
        int failure = errno;
        close(duplicated);
        errno = failure;
        return -1;
    }
    ios_replaceChildStream(slot, stream);
    return 0;
}

FILE* ios_popen(const char* inputCmd, const char* type) {
    if (inputCmd == NULL || type == NULL ||
        (strcmp(type, "r") != 0 && strcmp(type, "w") != 0)) {
        errno = EINVAL;
        return NULL;
    }
    NSLog(@"ios_popen: %s mode %s", inputCmd, type);
    const char *command = inputCmd;
    while (*command == ' ') command++;
    int descriptors[2];
    if (pipe(descriptors) < 0) return NULL;
    fcntl(descriptors[0], F_SETNOSIGPIPE, 1);
    fcntl(descriptors[1], F_SETNOSIGPIPE, 1);
    FILE *reader = fdopen(descriptors[0], "r");
    if (reader == NULL) {
        int failure = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = failure;
        return NULL;
    }
    FILE *writer = fdopen(descriptors[1], "w");
    if (writer == NULL) {
        int failure = errno;
        fclose(reader);
        close(descriptors[1]);
        errno = failure;
        return NULL;
    }
    FILE **slot = type[0] == 'w' ? &child_stdin : &child_stdout;
    FILE *child = type[0] == 'w' ? reader : writer;
    FILE *caller = type[0] == 'w' ? writer : reader;
    ios_replaceChildStream(slot, child);
    int status = ios_system_command_line(command);
    // Normally dispatch consumes the child stream; early allocation failure
    // can leave it pending on this thread instead.
    if (*slot == child) ios_replaceChildStream(slot, NULL);
    if (status != 0) {
        fclose(caller);
        return NULL;
    }
    return caller;
}

// small function, behaves like strstr but skips quotes (Yury Korolev)
char *strstrquoted(char* str1, char* str2) {
    
    if (str1 == NULL || str2 == NULL) {
        return NULL;
    }
    size_t len1 = strlen(str1);
    size_t len2 = strlen(str2);
    
    if (len1 < len2) {
        return NULL;
    }
    
    if (strcmp(str1, str2) == 0) {
        return str1;
    }
    
    char quotechar = 0;
    int esclen = 0;
    int matchlen = 0;
    
    for (int i = 0; i < len1; i++) {
        char ch = str1[i];
        if (quotechar) {
            if (ch == '\\') {
                esclen++;
                continue;
            }
            
            if (ch == quotechar) {
                if (esclen % 2 == 1) {
                    esclen = 0;
                    continue;
                }
                quotechar = 0;
                esclen = 0;
                continue;
            }
            
            esclen = 0;
            continue;
        }
        
        if (ch == '"' || ch == '\'') {
            if (esclen % 2 == 0) {
                quotechar = ch;
            }
            matchlen = 0;
            esclen = 0;
            continue;
        }
        
        if (ch == '\\') {
            esclen++;
        }
        
        if (str2[matchlen] == ch) {
            matchlen++;
            if (matchlen == len2) {
                return str1 + i - matchlen + 1;
            }
            continue;
        }
        
        matchlen = 0;
    }
    return NULL;
}

static char* concatenateArgv(char* const argv[]) {
    int argc = 0;
    int cmdLength = 0;
    // concatenate all arguments into a big command.
    // We need this because some programs call execv() with a single string: "ssh hg@bitbucket.org 'hg -R ... --stdio'"
    // So we rely on ios_system to break them into chunks.
    while(argv[argc] != NULL) { cmdLength += strlen(argv[argc]) + 1; argc++;}
    if (argc == 0) return NULL; // safeguard check
    char* cmd = malloc((cmdLength  + 3 * argc + 1) * sizeof(char)); // space for quotes
    strcpy(cmd, argv[0]);
    argc = 1;
    char recordSeparator = 0x1e;
    while (argv[argc] != NULL) {
        // Always enclose the arguments into something (either "...", '...' or recordSeparator...recordSeparator
        // if (strstrquoted(argv[argc], " ") || strstrquoted(argv[argc], "\\"))
        {
            // argument contains spaces or escaped characters. Enclose it into quotes:
            if (strstr(argv[argc], "\"") == NULL) { // We're looking for quotes, so strstr, not strstrquoted
                // argument does not contain ". Enclose with "
                strcat(cmd, " \"");
                strcat(cmd, argv[argc]);
                strcat(cmd, "\"");
                argc++;
                continue;
            } else if (strstr(argv[argc], "'") == NULL) { // We're looking for quotes, so strstr, not strstrquoted
                // argument does not contain '. Enclose with '
                strcat(cmd, " '");
                strcat(cmd, argv[argc]);
                strcat(cmd, "'");
                argc++;
                continue;
            } else if (strchr(argv[argc], recordSeparator) == NULL) {
                // Argument contains spaces and double and single quotes. We use recordSeparator to mark begin and end:
                strcat(cmd, " ");
                strncat(cmd, &recordSeparator, 1);
                strcat(cmd, argv[argc]);
                strncat(cmd, &recordSeparator, 1);
                argc++;
                continue;
            }
            if (strstrquoted(argv[argc], " "))
                NSLog(@"Argument contains spaces, double quotes, single quotes and recordSeparator");
        }
        strcat(cmd, " ");
        strcat(cmd, argv[argc]);
        argc++;
    }
    return cmd;
}

int pbpaste(int argc, char** argv) {
#if IOS_SYSTEM_HAS_UIKIT
    if (argc == 1) {
        // We can paste strings and URLs.
        if ([UIPasteboard generalPasteboard].hasStrings) {
            fprintf(thread_stdout, "%s", [[UIPasteboard generalPasteboard].string UTF8String]);
            if (![[UIPasteboard generalPasteboard].string hasSuffix:@"\n"]) fprintf(thread_stdout, "\n");
            return 0;
        }
        if ([UIPasteboard generalPasteboard].hasURLs) {
            fprintf(thread_stdout, "%s\n", [[[UIPasteboard generalPasteboard].URL absoluteString] UTF8String]);
            return 0;
        }
    } else {
        fprintf(thread_stderr, "Usage: pbpaste\nPastes the content of the copy buffer (strings or urls).");
    }
    return 1;
#else
    fprintf(thread_stderr, "pbpaste: unavailable in this ios_system build\n");
    return 1;
#endif
}


int pbcopy(int argc, char** argv) {
#if IOS_SYSTEM_HAS_UIKIT
    if (argc == 1) {
        // no arguments, listen to stdin
        enum { bufsize = 1024 };
        char buffer[bufsize];
        NSMutableData* data = [[NSMutableData alloc] init];
        
        ssize_t count = 0;
        while ((count = read(fileno(thread_stdin), buffer, bufsize-1)) != 0) {
            if (count < 0) {
                if (errno == EINTR) continue;
                fprintf(thread_stderr, "pbcopy: %s\n", strerror(errno));
                return 1;
            }
            [data appendBytes:buffer length:count];
        }
        
        NSString* result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        if (!result) {
            return 1;
        }
        
        [UIPasteboard generalPasteboard].string = result;
    } else {
        if ((argv[1][0] == '-') && ((strcmp(argv[1], "-h") == 0) || (strcmp(argv[1], "--help") == 0))) {
            fprintf(thread_stderr, "Usage: pbcopy arguments\ncommand > pbcopy\nCopies either its arguments or input to the copy buffer.");
            return 0;
        }
        // threre are arguments, concatenate and paste:
        char* cmd = concatenateArgv(argv + 1);
        [UIPasteboard generalPasteboard].string = @(cmd);
        free(cmd);
    }
    return 0;
#else
    fprintf(thread_stderr, "pbcopy: unavailable in this ios_system build\n");
    return 1;
#endif
}

int true_main(int argc, char** argv) {
    return 0;
}

int sleep_main(int argc, char** argv) {
    FILE* errorStream = thread_stderr != NULL ? thread_stderr : stderr;
    int firstInterval = 1;
    if (argc > 1 && strcmp(argv[1], "--") == 0) {
        firstInterval = 2;
    } else if (argc > 1 && argv[1][0] == '-' && argv[1][1] != '\0') {
        fprintf(errorStream, "sleep: illegal option -- %c\n", argv[1][1]);
        fprintf(errorStream, "usage: sleep number[unit] [...]\n");
        return 1;
    }
    if (firstInterval >= argc) {
        fprintf(errorStream, "usage: sleep number[unit] [...]\n");
        return 1;
    }

    long double totalSeconds = 0;
    for (int i = firstInterval; i < argc; ++i) {
        errno = 0;
        char* end = NULL;
        long double interval = strtold(argv[i], &end);
        bool parsedInfinity = isinf(interval);
        bool validInterval = end != argv[i] && !isnan(interval) &&
            !(errno == ERANGE && parsedInfinity);
        long double multiplier = 1;
        if (validInterval && *end != '\0') {
            if (end[1] != '\0') {
                validInterval = false;
            } else {
                switch (*end) {
                    case 's':
                        break;
                    case 'm':
                        multiplier = 60;
                        break;
                    case 'h':
                        multiplier = 60 * 60;
                        break;
                    case 'd':
                        multiplier = 24 * 60 * 60;
                        break;
                    default:
                        validInterval = false;
                        break;
                }
            }
        }
        if (validInterval) {
            interval *= multiplier;
            validInterval = !isnan(interval) &&
                (!isinf(interval) || parsedInfinity);
        }
        if (!validInterval) {
            fprintf(errorStream, "sleep: invalid time interval: %s\n", argv[i]);
            fprintf(errorStream, "usage: sleep number[unit] [...]\n");
            return 1;
        }
        totalSeconds += interval;
        if (isnan(totalSeconds)) {
            fprintf(errorStream, "sleep: invalid time interval: %s\n", argv[i]);
            fprintf(errorStream, "usage: sleep number[unit] [...]\n");
            return 1;
        }
    }

    while (totalSeconds > 0) {
        // Keep each request representable on every supported platform. This
        // also lets positive infinity remain cancellable through ios_kill.
        long double chunkSeconds =
            isinf(totalSeconds) || totalSeconds > 24 * 60 * 60
            ? 24 * 60 * 60
            : totalSeconds;
        long double wholeSeconds = 0;
        long double fractionalSeconds = modfl(chunkSeconds, &wholeSeconds);
        long nanoseconds = (long)ceill(fractionalSeconds * 1000000000.0L);
        if (nanoseconds == 1000000000L) {
            ++wholeSeconds;
            nanoseconds = 0;
        }
        struct timespec requested = {
            .tv_sec = (time_t)wholeSeconds,
            .tv_nsec = nanoseconds,
        };
        struct timespec remaining;
        while (nanosleep(&requested, &remaining) != 0) {
            if (errno == EINTR) {
                requested = remaining;
                continue;
            }
            fprintf(errorStream, "sleep: nanosleep failed: %s\n", strerror(errno));
            return 1;
        }
        if (!isinf(totalSeconds)) {
            totalSeconds -= chunkSeconds;
        }
    }
    return 0;
}

typedef struct _object IOSPyObject;
typedef struct _ts IOSPyThreadState;

typedef struct {
    int _type;
    const char *func;
    const char *err_msg;
    int exitcode;
} IOSPyStatus;

typedef struct {
    int use_main_obmalloc;
    int allow_fork;
    int allow_exec;
    int allow_threads;
    int allow_daemon_threads;
    int check_multi_interp_extensions;
    int gil;
} IOSPyInterpreterConfig;

typedef int (*IOSPy_IsInitialized)(void);
typedef int (*IOSPython_Initialize)(char *, size_t);
typedef IOSPyThreadState *(*IOSPyEval_SaveThread)(void);
typedef void (*IOSPyEval_AcquireThread)(IOSPyThreadState *);
typedef int (*IOSPyGILState_Ensure)(void);
typedef void (*IOSPyGILState_Release)(int);
typedef unsigned long (*IOSPyThread_get_thread_ident)(void);
typedef IOSPyThreadState *(*IOSPyThreadState_New)(IOSPyInterpreterState *);
typedef void (*IOSPyThreadState_Clear)(IOSPyThreadState *);
typedef void (*IOSPyThreadState_DeleteCurrent)(void);
typedef IOSPyThreadState *(*IOSPyThreadState_Get)(void);
typedef IOSPyThreadState *(*IOSPyThreadState_Swap)(IOSPyThreadState *);
typedef IOSPyInterpreterState *(*IOSPyThreadState_GetInterpreter)(IOSPyThreadState *);
typedef int (*IOSPyThreadState_SetAsyncExc)(unsigned long, IOSPyObject *);
typedef IOSPyStatus (*IOSPy_NewInterpreterFromConfig)(IOSPyThreadState **, const IOSPyInterpreterConfig *);
typedef void (*IOSPy_EndInterpreter)(IOSPyThreadState *);
typedef int (*IOSPyRun_SimpleStringFlags)(const char *, void *);
typedef IOSPyObject *(*IOSPyImport_AddModule)(const char *);
typedef IOSPyObject *(*IOSPyObject_GetAttrString)(IOSPyObject *, const char *);
typedef int (*IOSPyObject_DelAttrString)(IOSPyObject *, const char *);
typedef long (*IOSPyLong_AsLong)(IOSPyObject *);
typedef void (*IOSPy_DecRef)(IOSPyObject *);
typedef void (*IOSPyErr_Clear)(void);
typedef void (*IOSPyErr_Print)(void);

typedef struct {
    IOSPy_IsInitialized Py_IsInitialized;
    IOSPython_Initialize Initialize;
    IOSPyEval_SaveThread PyEval_SaveThread;
    IOSPyEval_AcquireThread PyEval_AcquireThread;
    IOSPyGILState_Ensure PyGILState_Ensure;
    IOSPyGILState_Release PyGILState_Release;
    IOSPyThread_get_thread_ident PyThread_get_thread_ident;
    IOSPyThreadState_New PyThreadState_New;
    IOSPyThreadState_Clear PyThreadState_Clear;
    IOSPyThreadState_DeleteCurrent PyThreadState_DeleteCurrent;
    IOSPyThreadState_Get PyThreadState_Get;
    IOSPyThreadState_Swap PyThreadState_Swap;
    IOSPyThreadState_GetInterpreter PyThreadState_GetInterpreter;
    IOSPyThreadState_SetAsyncExc PyThreadState_SetAsyncExc;
    IOSPy_NewInterpreterFromConfig Py_NewInterpreterFromConfig;
    IOSPy_EndInterpreter Py_EndInterpreter;
    IOSPyRun_SimpleStringFlags PyRun_SimpleStringFlags;
    IOSPyImport_AddModule PyImport_AddModule;
    IOSPyObject_GetAttrString PyObject_GetAttrString;
    IOSPyObject_DelAttrString PyObject_DelAttrString;
    IOSPyLong_AsLong PyLong_AsLong;
    IOSPy_DecRef Py_DecRef;
    IOSPyErr_Clear PyErr_Clear;
    IOSPyErr_Print PyErr_Print;
    bool loaded;
    bool initialized_here;
} IOSPythonAPI;

static IOSPythonAPI ios_python_api;
static pthread_mutex_t ios_python_runtime_mutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_int currentPythonInstances = 0;

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} IOSPythonBuffer;

static bool ios_python_buffer_reserve(IOSPythonBuffer *buffer, size_t extra) {
    if (extra > SIZE_MAX - buffer->length - 1) {
        return false;
    }
    size_t needed = buffer->length + extra + 1;
    if (needed <= buffer->capacity) {
        return true;
    }
    size_t capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
    while (capacity < needed) {
        if (capacity > SIZE_MAX / 2) {
            capacity = needed;
            break;
        }
        capacity *= 2;
    }
    char *bytes = realloc(buffer->bytes, capacity);
    if (bytes == NULL) {
        return false;
    }
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return true;
}

static bool ios_python_append_n(IOSPythonBuffer *buffer, const char *value, size_t length) {
    if (!ios_python_buffer_reserve(buffer, length)) {
        return false;
    }
    memcpy(buffer->bytes + buffer->length, value, length);
    buffer->length += length;
    buffer->bytes[buffer->length] = 0;
    return true;
}

static bool ios_python_append(IOSPythonBuffer *buffer, const char *value) {
    return ios_python_append_n(buffer, value, strlen(value));
}

static bool ios_python_appendf(IOSPythonBuffer *buffer, const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list args_copy;
    va_copy(args_copy, args);
    int length = vsnprintf(NULL, 0, format, args);
    va_end(args);
    if (length < 0) {
        va_end(args_copy);
        return false;
    }
    if (!ios_python_buffer_reserve(buffer, (size_t)length)) {
        va_end(args_copy);
        return false;
    }
    vsnprintf(buffer->bytes + buffer->length, buffer->capacity - buffer->length, format, args_copy);
    va_end(args_copy);
    buffer->length += (size_t)length;
    return true;
}

static bool ios_python_append_bytes_literal(IOSPythonBuffer *buffer, const char *value) {
    static const char hex[] = "0123456789abcdef";
    if (!ios_python_append(buffer, "b'")) {
        return false;
    }
    const unsigned char *bytes = (const unsigned char *)value;
    while (*bytes != 0) {
        char escaped[4] = {'\\', 'x', hex[*bytes >> 4], hex[*bytes & 0x0f]};
        if (!ios_python_append_n(buffer, escaped, sizeof(escaped))) {
            return false;
        }
        bytes++;
    }
    return ios_python_append(buffer, "'");
}

static bool ios_python_append_argv_tail(IOSPythonBuffer *buffer, int argc, char **argv, int start) {
    for (int i = start; i < argc; i++) {
        if (!ios_python_append(buffer, ", ") ||
            !ios_python_append_bytes_literal(buffer, argv[i])) {
            return false;
        }
    }
    return true;
}

#define IOS_PYTHON_WEAK_IMPORT __attribute__((weak_import))

extern int Py_IsInitialized(void) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyThreadState *PyEval_SaveThread(void) IOS_PYTHON_WEAK_IMPORT;
extern void PyEval_AcquireThread(IOSPyThreadState *) IOS_PYTHON_WEAK_IMPORT;
extern int PyGILState_Ensure(void) IOS_PYTHON_WEAK_IMPORT;
extern void PyGILState_Release(int) IOS_PYTHON_WEAK_IMPORT;
extern unsigned long PyThread_get_thread_ident(void) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyThreadState *PyThreadState_New(IOSPyInterpreterState *) IOS_PYTHON_WEAK_IMPORT;
extern void PyThreadState_Clear(IOSPyThreadState *) IOS_PYTHON_WEAK_IMPORT;
extern void PyThreadState_DeleteCurrent(void) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyThreadState *PyThreadState_Get(void) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyThreadState *PyThreadState_Swap(IOSPyThreadState *) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyInterpreterState *PyThreadState_GetInterpreter(IOSPyThreadState *) IOS_PYTHON_WEAK_IMPORT;
extern int PyThreadState_SetAsyncExc(unsigned long, IOSPyObject *) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyStatus Py_NewInterpreterFromConfig(IOSPyThreadState **, const IOSPyInterpreterConfig *) IOS_PYTHON_WEAK_IMPORT;
extern void Py_EndInterpreter(IOSPyThreadState *) IOS_PYTHON_WEAK_IMPORT;
extern int PyRun_SimpleStringFlags(const char *, void *) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyObject *PyImport_AddModule(const char *) IOS_PYTHON_WEAK_IMPORT;
extern IOSPyObject *PyObject_GetAttrString(IOSPyObject *, const char *) IOS_PYTHON_WEAK_IMPORT;
extern int PyObject_DelAttrString(IOSPyObject *, const char *) IOS_PYTHON_WEAK_IMPORT;
extern long PyLong_AsLong(IOSPyObject *) IOS_PYTHON_WEAK_IMPORT;
extern void Py_DecRef(IOSPyObject *) IOS_PYTHON_WEAK_IMPORT;
extern void PyErr_Clear(void) IOS_PYTHON_WEAK_IMPORT;
extern void PyErr_Print(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_numpy(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_pandas(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_pillow(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_cairosvg(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_lxml(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_matplotlib(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_psd_tools(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_hf_xet(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_safetensors(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_regex(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_tokenizers(void) IOS_PYTHON_WEAK_IMPORT;
extern int ios_python_register_sentencepiece(void) IOS_PYTHON_WEAK_IMPORT;
#if !TARGET_OS_SIMULATOR
extern int ios_python_register_mlx(void) IOS_PYTHON_WEAK_IMPORT;
#endif

#define IOS_PYTHON_LOAD_SYMBOL(field, symbol) \
    do { \
        if ((symbol) == NULL) { \
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: CPython is not linked into this ios_system process\n"); \
            return false; \
        } \
        ios_python_api.field = (symbol); \
    } while (0)

static bool ios_python_load_api(void) {
    if (ios_python_api.loaded) {
        return true;
    }

    IOS_PYTHON_LOAD_SYMBOL(Py_IsInitialized, Py_IsInitialized);
    IOS_PYTHON_LOAD_SYMBOL(Initialize, python_ios_initialize);
    IOS_PYTHON_LOAD_SYMBOL(PyEval_SaveThread, PyEval_SaveThread);
    IOS_PYTHON_LOAD_SYMBOL(PyEval_AcquireThread, PyEval_AcquireThread);
    IOS_PYTHON_LOAD_SYMBOL(PyGILState_Ensure, PyGILState_Ensure);
    IOS_PYTHON_LOAD_SYMBOL(PyGILState_Release, PyGILState_Release);
    IOS_PYTHON_LOAD_SYMBOL(PyThread_get_thread_ident, PyThread_get_thread_ident);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_New, PyThreadState_New);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_Clear, PyThreadState_Clear);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_DeleteCurrent, PyThreadState_DeleteCurrent);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_Get, PyThreadState_Get);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_Swap, PyThreadState_Swap);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_GetInterpreter, PyThreadState_GetInterpreter);
    IOS_PYTHON_LOAD_SYMBOL(PyThreadState_SetAsyncExc, PyThreadState_SetAsyncExc);
    IOS_PYTHON_LOAD_SYMBOL(Py_NewInterpreterFromConfig, Py_NewInterpreterFromConfig);
    IOS_PYTHON_LOAD_SYMBOL(Py_EndInterpreter, Py_EndInterpreter);
    IOS_PYTHON_LOAD_SYMBOL(PyRun_SimpleStringFlags, PyRun_SimpleStringFlags);
    IOS_PYTHON_LOAD_SYMBOL(PyImport_AddModule, PyImport_AddModule);
    IOS_PYTHON_LOAD_SYMBOL(PyObject_GetAttrString, PyObject_GetAttrString);
    IOS_PYTHON_LOAD_SYMBOL(PyObject_DelAttrString, PyObject_DelAttrString);
    IOS_PYTHON_LOAD_SYMBOL(PyLong_AsLong, PyLong_AsLong);
    IOS_PYTHON_LOAD_SYMBOL(Py_DecRef, Py_DecRef);
    IOS_PYTHON_LOAD_SYMBOL(PyErr_Clear, PyErr_Clear);
    IOS_PYTHON_LOAD_SYMBOL(PyErr_Print, PyErr_Print);

    ios_python_api.loaded = true;
    return true;
}

#undef IOS_PYTHON_WEAK_IMPORT
#undef IOS_PYTHON_LOAD_SYMBOL

static bool ios_python_ensure_runtime(void) {
    pthread_mutex_lock(&ios_python_runtime_mutex);
    bool loaded = ios_python_load_api();
    if (loaded && !ios_python_api.Py_IsInitialized()) {
        if (ios_python_register_numpy != NULL && ios_python_register_numpy() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static NumPy modules\n");
            loaded = false;
        } else if (ios_python_register_pandas != NULL && ios_python_register_pandas() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static pandas modules\n");
            loaded = false;
        } else if (ios_python_register_pillow != NULL && ios_python_register_pillow() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static Pillow modules\n");
            loaded = false;
        } else if (ios_python_register_cairosvg != NULL && ios_python_register_cairosvg() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static CairoSVG modules\n");
            loaded = false;
        } else if (ios_python_register_lxml != NULL && ios_python_register_lxml() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static lxml modules\n");
            loaded = false;
        } else if (ios_python_register_matplotlib != NULL && ios_python_register_matplotlib() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static matplotlib modules\n");
            loaded = false;
        } else if (ios_python_register_psd_tools != NULL && ios_python_register_psd_tools() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static psd-tools modules\n");
            loaded = false;
        } else if (ios_python_register_hf_xet != NULL && ios_python_register_hf_xet() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static hf-xet module\n");
            loaded = false;
        } else if (ios_python_register_safetensors != NULL && ios_python_register_safetensors() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static safetensors module\n");
            loaded = false;
        } else if (ios_python_register_regex != NULL && ios_python_register_regex() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static regex module\n");
            loaded = false;
        } else if (ios_python_register_tokenizers != NULL && ios_python_register_tokenizers() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static tokenizers module\n");
            loaded = false;
        } else if (ios_python_register_sentencepiece != NULL && ios_python_register_sentencepiece() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static SentencePiece module\n");
            loaded = false;
#if !TARGET_OS_SIMULATOR
        } else if (ios_python_register_mlx != NULL && ios_python_register_mlx() != 0) {
            fprintf(thread_stderr != NULL ? thread_stderr : stderr, "python: failed registering static MLX modules\n");
            loaded = false;
#endif
        } else {
            char errorMessage[1024];
            if (ios_python_api.Initialize(errorMessage, sizeof(errorMessage)) != 0) {
                FILE *errorStream = thread_stderr != NULL ? thread_stderr : stderr;
                fprintf(errorStream, "python: failed to initialize embedded runtime");
                if (errorMessage[0] != '\0') {
                    fprintf(errorStream, ": %s", errorMessage);
                }
                fprintf(errorStream, "\n");
                fflush(errorStream);
                loaded = false;
            } else {
                ios_python_api.initialized_here = true;
                ios_python_api.PyEval_SaveThread();
            }
        }
    }
    pthread_mutex_unlock(&ios_python_runtime_mutex);
    return loaded;
}

static bool ios_python_command_was_cancelled(void) {
    return currentPythonCommand != NULL &&
        atomic_load_explicit(
            &currentPythonCommand->cancellationRequested,
            memory_order_acquire);
}

static bool ios_python_activate_command_target(
    IOSPyThreadState *threadState)
{
    if (currentSession == NULL || currentPythonCommand == NULL) {
        return true;
    }
    pthread_mutex_lock(&currentSession->pythonCommandsMutex);
    currentPythonCommand->threadIdentifier =
        ios_python_api.PyThread_get_thread_ident();
    currentPythonCommand->interpreter =
        ios_python_api.PyThreadState_GetInterpreter(threadState);
    bool shouldRun = !atomic_load_explicit(
        &currentPythonCommand->cancellationRequested,
        memory_order_acquire);
    pthread_mutex_unlock(&currentSession->pythonCommandsMutex);
    return shouldRun;
}

static void ios_python_deactivate_command_target(void) {
    if (currentSession == NULL || currentPythonCommand == NULL) {
        return;
    }
    pthread_mutex_lock(&currentSession->pythonCommandsMutex);
    currentPythonCommand->acceptsInterruption = false;
    currentPythonCommand->threadIdentifier = 0;
    currentPythonCommand->interpreter = NULL;
    pthread_mutex_unlock(&currentSession->pythonCommandsMutex);
}

static int ios_python_raise_keyboard_interrupt(unsigned long threadIdentifier) {
    IOSPyObject *builtins = ios_python_api.PyImport_AddModule("builtins");
    if (builtins == NULL) {
        ios_python_api.PyErr_Clear();
        return 0;
    }
    IOSPyObject *keyboardInterrupt =
        ios_python_api.PyObject_GetAttrString(builtins, "KeyboardInterrupt");
    if (keyboardInterrupt == NULL) {
        ios_python_api.PyErr_Clear();
        return 0;
    }
    int changed = ios_python_api.PyThreadState_SetAsyncExc(
        threadIdentifier, keyboardInterrupt);
    if (changed > 1) {
        ios_python_api.PyThreadState_SetAsyncExc(
            threadIdentifier, NULL);
        changed = 0;
    }
    ios_python_api.Py_DecRef(keyboardInterrupt);
    return changed;
}

static int ios_python_request_cancel(sessionParameters *session) {
    IOSPythonCommandState *command = NULL;
    unsigned long threadIdentifier = 0;
    IOSPyInterpreterState *interpreter = NULL;

    pthread_mutex_lock(&session->pythonCommandsMutex);
    bool hasPythonCommand = session->pythonCommands != NULL;
    command = session->pythonCommands;
    while (command != NULL && !command->acceptsInterruption) {
        command = command->next;
    }
    if (command != NULL) {
        bool wasAlreadyRequested = atomic_exchange_explicit(
            &command->cancellationRequested,
            true,
            memory_order_acq_rel);
        if (!wasAlreadyRequested &&
            command->threadIdentifier != 0 &&
            command->interpreter != NULL) {
            command->activeCancellationRequests += 1;
            threadIdentifier = command->threadIdentifier;
            interpreter = command->interpreter;
        }
    }
    pthread_mutex_unlock(&session->pythonCommandsMutex);

    if (!hasPythonCommand) {
        return ESRCH;
    }
    atomic_store_explicit(
        &session->cancellationRequested,
        true,
        memory_order_release);
    session->global_errno = 130;
    if (threadIdentifier == 0 || interpreter == NULL) {
        return 0;
    }

    // Never wait for the GIL while holding pythonCommandsMutex. The target
    // Python thread publishes and clears this state while it owns that GIL.
    IOSPyThreadState *cancellationThreadState =
        ios_python_api.PyThreadState_New(interpreter);
    if (cancellationThreadState != NULL) {
        ios_python_api.PyEval_AcquireThread(
            cancellationThreadState);
        pthread_mutex_lock(&session->pythonCommandsMutex);
        if (command->acceptsInterruption &&
            command->threadIdentifier == threadIdentifier &&
            command->interpreter == interpreter) {
            ios_python_raise_keyboard_interrupt(
                threadIdentifier);
        }
        pthread_mutex_unlock(&session->pythonCommandsMutex);
        ios_python_api.PyThreadState_Clear(
            cancellationThreadState);
        ios_python_api.PyThreadState_DeleteCurrent();
    }

    pthread_mutex_lock(&session->pythonCommandsMutex);
    command->activeCancellationRequests -= 1;
    pthread_cond_broadcast(
        &session->pythonCommandsCondition);
    pthread_mutex_unlock(&session->pythonCommandsMutex);
    return 0;
}

typedef enum {
    IOS_PYTHON_MODE_STDIN,
    IOS_PYTHON_MODE_COMMAND,
    IOS_PYTHON_MODE_MODULE,
    IOS_PYTHON_MODE_SCRIPT,
    IOS_PYTHON_MODE_VERSION,
    IOS_PYTHON_MODE_HELP,
    IOS_PYTHON_MODE_ERROR,
} IOSPythonMode;

typedef struct {
    IOSPythonMode mode;
    int target_index;
    int args_start;
    bool explicit_stdin;
    bool dont_write_bytecode;
    const char *error;
} IOSPythonInvocation;

static bool ios_python_option_is_noarg(const char *arg) {
    return strcmp(arg, "-B") == 0 ||
           strcmp(arg, "-E") == 0 ||
           strcmp(arg, "-I") == 0 ||
           strcmp(arg, "-s") == 0 ||
           strcmp(arg, "-S") == 0 ||
           strcmp(arg, "-u") == 0 ||
           strcmp(arg, "-v") == 0 ||
           strcmp(arg, "-q") == 0 ||
           strcmp(arg, "-b") == 0 ||
           strcmp(arg, "-bb") == 0 ||
           strcmp(arg, "-O") == 0 ||
           strcmp(arg, "-OO") == 0 ||
           strcmp(arg, "-P") == 0;
}

static IOSPythonInvocation ios_python_parse_invocation(int argc, char **argv) {
    IOSPythonInvocation invocation = {
        .mode = IOS_PYTHON_MODE_STDIN,
        .target_index = -1,
        .args_start = argc,
        .explicit_stdin = false,
        .dont_write_bytecode = false,
        .error = NULL,
    };

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--") == 0) {
            if (i + 1 < argc) {
                invocation.mode = IOS_PYTHON_MODE_SCRIPT;
                invocation.target_index = i + 1;
                invocation.args_start = i + 2;
            }
            return invocation;
        }
        if (strcmp(arg, "-") == 0) {
            invocation.mode = IOS_PYTHON_MODE_STDIN;
            invocation.target_index = i;
            invocation.args_start = i + 1;
            invocation.explicit_stdin = true;
            return invocation;
        }
        if (arg[0] != '-' || arg[1] == 0) {
            invocation.mode = IOS_PYTHON_MODE_SCRIPT;
            invocation.target_index = i;
            invocation.args_start = i + 1;
            return invocation;
        }
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            invocation.mode = IOS_PYTHON_MODE_HELP;
            return invocation;
        }
        if (strcmp(arg, "-V") == 0 || strcmp(arg, "--version") == 0) {
            invocation.mode = IOS_PYTHON_MODE_VERSION;
            return invocation;
        }
        if (strcmp(arg, "-B") == 0) {
            invocation.dont_write_bytecode = true;
            continue;
        }
        if (strncmp(arg, "-c", 2) == 0) {
            if (arg[2] != 0) {
                invocation.mode = IOS_PYTHON_MODE_COMMAND;
                invocation.target_index = i;
                invocation.args_start = i + 1;
                memmove(argv[i], argv[i] + 2, strlen(argv[i] + 2) + 1);
                return invocation;
            }
            if (i + 1 >= argc) {
                invocation.mode = IOS_PYTHON_MODE_ERROR;
                invocation.error = "argument expected for the -c option";
                return invocation;
            }
            invocation.mode = IOS_PYTHON_MODE_COMMAND;
            invocation.target_index = i + 1;
            invocation.args_start = i + 2;
            return invocation;
        }
        if (strncmp(arg, "-m", 2) == 0) {
            if (arg[2] != 0) {
                invocation.mode = IOS_PYTHON_MODE_MODULE;
                invocation.target_index = i;
                invocation.args_start = i + 1;
                memmove(argv[i], argv[i] + 2, strlen(argv[i] + 2) + 1);
                return invocation;
            }
            if (i + 1 >= argc) {
                invocation.mode = IOS_PYTHON_MODE_ERROR;
                invocation.error = "argument expected for the -m option";
                return invocation;
            }
            invocation.mode = IOS_PYTHON_MODE_MODULE;
            invocation.target_index = i + 1;
            invocation.args_start = i + 2;
            return invocation;
        }
        if (strcmp(arg, "-W") == 0 || strcmp(arg, "-X") == 0 || strcmp(arg, "--check-hash-based-pycs") == 0) {
            if (i + 1 >= argc) {
                invocation.mode = IOS_PYTHON_MODE_ERROR;
                invocation.error = "argument expected for option";
                return invocation;
            }
            i++;
            continue;
        }
        if (strncmp(arg, "-W", 2) == 0 || strncmp(arg, "-X", 2) == 0) {
            continue;
        }
        if (ios_python_option_is_noarg(arg)) {
            continue;
        }
        invocation.mode = IOS_PYTHON_MODE_ERROR;
        invocation.error = arg;
        return invocation;
    }
    return invocation;
}

static bool ios_python_append_sys_argv(IOSPythonBuffer *script, int argc, char **argv, const IOSPythonInvocation *invocation) {
    if (!ios_python_append(script, "_ios_argv = [")) {
        return false;
    }
    switch (invocation->mode) {
    case IOS_PYTHON_MODE_COMMAND:
        if (!ios_python_append_bytes_literal(script, "-c") ||
            !ios_python_append_argv_tail(script, argc, argv, invocation->args_start)) {
            return false;
        }
        break;
    case IOS_PYTHON_MODE_MODULE:
    case IOS_PYTHON_MODE_SCRIPT:
        if (!ios_python_append_bytes_literal(script, argv[invocation->target_index]) ||
            !ios_python_append_argv_tail(script, argc, argv, invocation->args_start)) {
            return false;
        }
        break;
    case IOS_PYTHON_MODE_STDIN:
        if (!ios_python_append_bytes_literal(script, invocation->explicit_stdin ? "-" : "") ||
            !ios_python_append_argv_tail(script, argc, argv, invocation->args_start)) {
            return false;
        }
        break;
    default:
        if (!ios_python_append_bytes_literal(script, argv[0])) {
            return false;
        }
        break;
    }
    return ios_python_append(script, "]\n");
}

static const char *ios_python_environment_names[] = {
    "APPDIR",
    "CLICOLOR",
    "CURL_HOME",
    "CURLOPT_SSH_KNOWNHOSTS",
    "DIG_HOME",
    "HGRCPATH",
    "HOME",
    "IPYTHONDIR",
    "JUPYTER_CONFIG_DIR",
    "LSCOLORS",
    "MATPLOTLIBDATA",
    "MPLBACKEND",
    "MPLCONFIGDIR",
    "PATH",
    "PATH_LOCALE",
    "PIP_CACHE_DIR",
    "PIP_DISABLE_PIP_VERSION_CHECK",
    "PIP_PREFIX",
    "PIP_TARGET",
    "PYTHONEXECUTABLE",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONPYCACHEPREFIX",
    "PYTHONUSERBASE",
    "PYTHON_HISTORY",
    "PWD",
    "SSH_HOME",
    "SSL_CERT_FILE",
    "TERM",
    "TMPDIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    NULL,
};

static bool ios_python_append_environment_sync(IOSPythonBuffer *script) {
    if (!ios_python_append(script, "    _ios_env_updates = {\n")) {
        return false;
    }
    for (const char **name = ios_python_environment_names; *name != NULL; name++) {
        const char *value = ios_getenv(*name);
        if (value == NULL) {
            continue;
        }
        if (!ios_python_append(script, "        _ios_decode(") ||
            !ios_python_append_bytes_literal(script, *name) ||
            !ios_python_append(script, "): _ios_decode(") ||
            !ios_python_append_bytes_literal(script, value) ||
            !ios_python_append(script, "),\n")) {
            return false;
        }
    }
    if (!ios_python_append(script, "    }\n    for _ios_env_name in [\n")) {
        return false;
    }
    for (const char **name = ios_python_environment_names; *name != NULL; name++) {
        if (!ios_python_append(script, "        _ios_decode(") ||
            !ios_python_append_bytes_literal(script, *name) ||
            !ios_python_append(script, "),\n")) {
            return false;
        }
    }
    return ios_python_append(script,
        "    ]:\n"
        "        if _ios_env_name in _ios_env_updates:\n"
        "            _ios_os.environ[_ios_env_name] = _ios_env_updates[_ios_env_name]\n"
        "        else:\n"
        "            _ios_os.environ.pop(_ios_env_name, None)\n");
}

static char *ios_python_build_script(int argc, char **argv, const IOSPythonInvocation *invocation) {
    IOSPythonBuffer script = {0};
    int stdin_fd = thread_stdin != NULL ? fileno(thread_stdin) : -1;
    int stdout_fd = thread_stdout != NULL ? fileno(thread_stdout) : -1;
    int stderr_fd = thread_stderr != NULL ? fileno(thread_stderr) : -1;

    if (!ios_python_append(&script,
        "def _ios_run(\n"
        "    _ios_builtins=__import__('builtins'),\n"
        "    _ios_importlib=__import__('importlib'),\n"
        "    _ios_importlib_util=__import__('importlib.util', fromlist=['util']),\n"
        "    _ios_io=__import__('io'),\n"
        "    _ios_os=__import__('os'),\n"
        "    _ios_runpy=__import__('runpy'),\n"
        "    _ios_sys=__import__('sys'),\n"
        "    _ios_traceback=__import__('traceback'),\n"
        "    _ios_saved_main=dict(__import__('sys').modules['__main__'].__dict__)):\n") ||
        !ios_python_append(&script, "    ") ||
        !ios_python_append_sys_argv(&script, argc, argv, invocation) ||
        !ios_python_appendf(&script,
        "    _ios_stdin_fd = %d\n"
        "    _ios_stdout_fd = %d\n"
        "    _ios_stderr_fd = %d\n",
        stdin_fd,
        stdout_fd,
        stderr_fd) ||
        !ios_python_append(&script,
        "    _ios_exit_code = 0\n"
        "    _ios_any = any\n"
        "    _ios_base_exception = BaseException\n"
        "    _ios_keyboard_interrupt = KeyboardInterrupt\n"
        "    _ios_system_exit = SystemExit\n"
        "    _ios_exception = Exception\n"
        "    _ios_bytes = bytes\n"
        "    _ios_compile = compile\n"
        "    _ios_dict = dict\n"
        "    _ios_getattr = getattr\n"
        "    _ios_int = int\n"
        "    _ios_isinstance = isinstance\n"
        "    _ios_list = list\n"
        "    _ios_print = print\n"
        "    _ios_str = str\n"
        "    _ios_main_module = _ios_sys.modules.get('__main__')\n"
        "    _ios_main_dict = _ios_main_module.__dict__ if _ios_main_module is not None else globals()\n"
        "    _ios_saved_main = _ios_dict(_ios_saved_main)\n"
        "    _ios_saved_builtins = _ios_dict(_ios_builtins.__dict__)\n"
        "    _ios_saved_argv = _ios_list(_ios_sys.argv)\n"
        "    _ios_saved_path = _ios_list(_ios_sys.path)\n"
        "    _ios_saved_stdin = _ios_sys.stdin\n"
        "    _ios_saved_stdout = _ios_sys.stdout\n"
        "    _ios_saved_stderr = _ios_sys.stderr\n"
        "    _ios_saved_modules = _ios_sys.modules\n"
        "    _ios_saved_dont_write_bytecode = _ios_sys.dont_write_bytecode\n"
        "    _ios_saved_system = _ios_getattr(_ios_os, 'system', None)\n"
        "    def _ios_decode(value):\n"
        "        return value.decode(_ios_sys.getfilesystemencoding() or 'utf-8', 'surrogateescape')\n"
        "    def _ios_restore_dict(target, saved):\n"
        "        for key in _ios_list(target.keys()):\n"
        "            if key not in saved:\n"
        "                del target[key]\n"
        "        target.update(saved)\n"
        "    def _ios_reopen(fd, mode, fallback):\n"
        "        if fd < 0:\n"
        "            return fallback\n"
        "        try:\n"
        "            raw = _ios_os.fdopen(_ios_os.dup(fd), mode + 'b', buffering=0)\n"
        "            encoding = _ios_getattr(fallback, 'encoding', None) or 'utf-8'\n"
        "            errors = 'surrogateescape' if mode == 'r' else 'backslashreplace'\n"
        "            return _ios_io.TextIOWrapper(raw, encoding=encoding, errors=errors, line_buffering=(mode != 'r'))\n"
        "        except _ios_exception:\n"
        "            return fallback\n"
        "    def _ios_set_path0(value):\n"
        "        if _ios_sys.path:\n"
        "            _ios_sys.path[0] = value\n"
        "        else:\n"
        "            _ios_sys.path.insert(0, value)\n"
        "    def _ios_apply_pythonpath():\n"
        "        pythonpath = _ios_os.environ.get('PYTHONPATH')\n"
        "        entries = [] if not pythonpath else [entry for entry in pythonpath.split(_ios_os.pathsep) if entry]\n"
        "        managed_suffix = _ios_os.path.join('.localc', 'python', 'lib', 'python3.14', 'site-packages')\n"
        "        current_managed_paths = [_ios_os.path.normpath(entry) for entry in entries if _ios_os.path.normpath(entry).endswith(_ios_os.path.sep + managed_suffix)]\n"
        "        cleaned_path = []\n"
        "        for entry in _ios_sys.path:\n"
        "            if entry and _ios_os.path.normpath(entry).endswith(_ios_os.path.sep + managed_suffix) and entry not in entries:\n"
        "                continue\n"
        "            cleaned_path.append(entry)\n"
        "        _ios_sys.path[:] = cleaned_path\n"
        "        for module_name, module in _ios_list(_ios_sys.modules.items()):\n"
        "            module_file = _ios_getattr(module, '__file__', None)\n"
        "            if not module_file:\n"
        "                continue\n"
        "            module_file = _ios_os.path.normpath(module_file)\n"
        "            if _ios_os.path.sep + managed_suffix + _ios_os.path.sep not in module_file:\n"
        "                continue\n"
        "            _ios_sys.modules.pop(module_name, None)\n"
        "        for cache_path in _ios_list(_ios_sys.path_importer_cache.keys()):\n"
        "            normalized_cache_path = _ios_os.path.normpath(cache_path)\n"
        "            if _ios_os.path.sep + managed_suffix in normalized_cache_path:\n"
        "                _ios_sys.path_importer_cache.pop(cache_path, None)\n"
        "            elif any(normalized_cache_path == path or normalized_cache_path.startswith(path + _ios_os.path.sep) for path in current_managed_paths):\n"
        "                _ios_sys.path_importer_cache.pop(cache_path, None)\n"
        "        for entry in reversed(entries):\n"
        "            while entry in _ios_sys.path:\n"
        "                _ios_sys.path.remove(entry)\n"
        "            insert_at = 1 if _ios_sys.path else 0\n"
        "            _ios_sys.path.insert(insert_at, entry)\n"
        "        _ios_importlib.invalidate_caches()\n"
        "    def _ios_apply_embedded_runtime_policy():\n"
        "        try:\n"
        "            import mimetypes as _ios_mimetypes\n"
        "            _ios_mimetypes.knownfiles = []\n"
        "        except _ios_exception:\n"
        "            pass\n"
        // iOS's browser messages UIApplication with any URL and macOS's needs osascript. openurl
        // opens only web URLs, after the user approves. webbrowser.open would try every
        // registered browser after a refusal, and macOS registers four, so it asks once.
        "        try:\n"
        "            import webbrowser as _ios_webbrowser\n"
        "            def _ios_open_with_openurl(url, new=0, autoraise=True):\n"
        "                _ios_sys.audit('webbrowser.open', url)\n"
        "                _ios_webbrowser.BaseBrowser._check_url(url)\n"
        "                import subprocess\n"
        "                return subprocess.run(['openurl', url]).returncode == 0\n"
        "            _ios_webbrowser.open = _ios_open_with_openurl\n"
        "            for _ios_browser_name in ('IOSBrowser', 'MacOSXOSAScript'):\n"
        "                _ios_browser = _ios_getattr(_ios_webbrowser, _ios_browser_name, None)\n"
        "                if _ios_browser is not None:\n"
        "                    _ios_browser.open = lambda browser, url, new=0, autoraise=True: _ios_open_with_openurl(url, new, autoraise)\n"
        "        except _ios_exception:\n"
        "            pass\n"
        "    def _ios_exit_status(value):\n"
        "        if value is None:\n"
        "            return 0\n"
        "        if _ios_isinstance(value, _ios_int):\n"
        "            return value\n"
        "        _ios_print(value, file=_ios_sys.stderr)\n"
        "        return 1\n"
        "    def _ios_prepare_module(module_name):\n"
        "        if module_name != 'pip' or _ios_importlib_util.find_spec('pip') is not None:\n"
        "            return None\n"
        "        import ensurepip\n"
        "        pip_wheel_context = ensurepip._get_pip_whl_path_ctx()\n"
        "        pip_wheel_path = pip_wheel_context.__enter__()\n"
        "        _ios_sys.path.insert(0, _ios_str(pip_wheel_path))\n"
        "        return pip_wheel_context\n"
        "    def _ios_pip_install_requested(module_name):\n"
        "        if module_name != 'pip':\n"
        "            return False\n"
        "        options_with_values = {\n"
        "            '--cache-dir', '--cert', '--client-cert', '--exists-action', '--keyring-provider',\n"
        "            '--log', '--proxy', '--python', '--retries', '--timeout', '--trusted-host',\n"
        "            '--use-deprecated', '--use-feature'\n"
        "        }\n"
        "        args = _ios_sys.argv[1:]\n"
        "        index = 0\n"
        "        while index < len(args):\n"
        "            arg = args[index]\n"
        "            if arg == 'install':\n"
        "                return True\n"
        "            if arg == '--':\n"
        "                return False\n"
        "            if arg.startswith('--'):\n"
        "                option = arg.split('=', 1)[0]\n"
        "                index += 2 if option in options_with_values and '=' not in arg else 1\n"
        "                continue\n"
        "            if arg.startswith('-') and arg != '-':\n"
        "                index += 1\n"
        "                continue\n"
        "            return False\n"
        "        return False\n"
        "    def _ios_install_pip_pure_python_guard(module_name):\n"
        "        if not _ios_pip_install_requested(module_name):\n"
        "            return\n"
        "        import pip._internal.index.package_finder as package_finder\n"
        "        import pip._internal.resolution.resolvelib.candidates as candidates\n"
        "        import pip._internal.resolution.resolvelib.factory as factory\n"
        "        if _ios_getattr(package_finder, '_ios_pure_python_guard_installed', False):\n"
        "            return\n"
        "        message = (\n"
        "            'pip install is restricted in this embedded Python environment. '\n"
        "            'Only pure-Python wheels can be installed at runtime. '\n"
        "            'The package \"{name}\" requires native code or a source build, so it must be bundled with the app instead.'\n"
        "        )\n"
        "        original_evaluate_link = package_finder.LinkEvaluator.evaluate_link\n"
        "        original_find_requirement = package_finder.PackageFinder.find_requirement\n"
        "        original_prepare_distribution = candidates.LinkCandidate._prepare_distribution\n"
        "        original_get_dist_to_uninstall = factory.Factory.get_dist_to_uninstall\n"
        "        def wheel_is_pure_python(wheel):\n"
        "            return any(tag.abi == 'none' and tag.platform == 'any' for tag in wheel.file_tags)\n"
        "        def link_is_pure_python_wheel(link):\n"
        "            if not _ios_getattr(link, 'is_wheel', False):\n"
        "                return False\n"
        "            return wheel_is_pure_python(package_finder.Wheel(link.filename))\n"
        "        def guarded_evaluate_link(self, link):\n"
        "            result, detail = original_evaluate_link(self, link)\n"
        "            if result != package_finder.LinkType.candidate:\n"
        "                return result, detail\n"
        "            if not link_is_pure_python_wheel(link):\n"
        "                return (package_finder.LinkType.platform_mismatch, 'not a pure-Python wheel')\n"
        "            return result, detail\n"
        "        def guarded_find_requirement(self, req, upgrade):\n"
        "            try:\n"
        "                return original_find_requirement(self, req, upgrade)\n"
        "            except package_finder.DistributionNotFound as exc:\n"
        "                name = _ios_getattr(req, 'name', None) or 'the requested package'\n"
        "                raise package_finder.DistributionNotFound(message.format(name=name)) from exc\n"
        "        def guarded_prepare_distribution(self):\n"
        "            if not link_is_pure_python_wheel(self._link):\n"
        "                name = self._name or self._ireq.name or self._link.filename\n"
        "                raise package_finder.InstallationError(message.format(name=name))\n"
        "            return original_prepare_distribution(self)\n"
        "        def guarded_get_dist_to_uninstall(self, candidate):\n"
        "            dist = self._installed_dists.get(candidate.project_name)\n"
        "            prefix = _ios_os.environ.get('PIP_PREFIX')\n"
        "            location = _ios_getattr(dist, 'location', None) if dist is not None else None\n"
        "            if prefix and location:\n"
        "                try:\n"
        "                    prefix = _ios_os.path.realpath(prefix)\n"
        "                    location = _ios_os.path.realpath(location)\n"
        "                    if _ios_os.path.commonpath((prefix, location)) != prefix:\n"
        "                        return None\n"
        "                except _ios_exception:\n"
        "                    return None\n"
        "            return original_get_dist_to_uninstall(self, candidate)\n"
        "        package_finder.LinkEvaluator.evaluate_link = guarded_evaluate_link\n"
        "        package_finder.PackageFinder.find_requirement = guarded_find_requirement\n"
        "        candidates.LinkCandidate._prepare_distribution = guarded_prepare_distribution\n"
        "        factory.Factory.get_dist_to_uninstall = guarded_get_dist_to_uninstall\n"
        "        package_finder._ios_pure_python_guard_installed = True\n"
        "    def _ios_install_system_bridge():\n"
        "        try:\n"
        "            import ctypes\n"
        "            c_lib = ctypes.CDLL(None)\n"
        "            c_shell = _ios_getattr(c_lib, 'ios_system_osh', None)\n"
        "            if c_shell is None:\n"
        "                return\n"
        "            c_shell.argtypes = [ctypes.c_char_p]\n"
        "            c_shell.restype = ctypes.c_int\n"
        "        except _ios_exception:\n"
        "            return\n"
        "        def bridged_system(command):\n"
        "            encoded = command if _ios_isinstance(command, _ios_bytes) else _ios_os.fsencode(command)\n"
        "            return c_shell(encoded)\n"
        "        _ios_os.system = bridged_system\n"
        "    _ios_sys.argv = [_ios_decode(value) for value in _ios_argv]\n"
        "    _ios_sys.stdin = _ios_reopen(_ios_stdin_fd, 'r', _ios_sys.stdin)\n"
        "    _ios_sys.stdout = _ios_reopen(_ios_stdout_fd, 'w', _ios_sys.stdout)\n"
        "    _ios_sys.stderr = _ios_reopen(_ios_stderr_fd, 'w', _ios_sys.stderr)\n"
        "    _ios_reopened_stdin = _ios_sys.stdin\n"
        "    _ios_reopened_stdout = _ios_sys.stdout\n"
        "    _ios_reopened_stderr = _ios_sys.stderr\n"
        "    _ios_apply_embedded_runtime_policy()\n"
        "    _ios_install_system_bridge()\n"
        "    _ios_restore_dict(_ios_main_dict, _ios_saved_main)\n")) {
        free(script.bytes);
        return NULL;
    }

    if (!ios_python_append_environment_sync(&script)) {
        free(script.bytes);
        return NULL;
    }

    if (invocation->dont_write_bytecode &&
        !ios_python_append(&script, "    _ios_sys.dont_write_bytecode = True\n")) {
        free(script.bytes);
        return NULL;
    }

    if (!ios_python_append(&script, "    _ios_subprocess_namespace = {}\n    exec(") ||
        !ios_python_append_bytes_literal(&script, ios_python_subprocess_source) ||
        !ios_python_append(&script, ", _ios_subprocess_namespace)\n") ||
        // Pass a native reference so linking and symbol visibility cannot break
        // the bridge's installation through a name-only ctypes lookup.
        !ios_python_appendf(&script,
            "    _ios_restore_subprocess = _ios_subprocess_namespace['install'](%llu)\n",
            (unsigned long long)(uintptr_t)&ios_python_subprocess_run) ||
        !ios_python_append(&script, "    try:\n")) {
        free(script.bytes);
        return NULL;
    }

    switch (invocation->mode) {
    case IOS_PYTHON_MODE_VERSION:
        if (!ios_python_append(&script, "        _ios_print('Python ' + _ios_sys.version.split()[0])\n")) {
            free(script.bytes);
            return NULL;
        }
        break;
    case IOS_PYTHON_MODE_COMMAND:
        if (!ios_python_append(&script, "        _ios_set_path0('')\n        _ios_apply_pythonpath()\n        _ios_code = _ios_decode(") ||
            !ios_python_append_bytes_literal(&script, argv[invocation->target_index]) ||
            !ios_python_append(&script,
                ")\n"
                "        _ios_main = _ios_sys.modules['__main__'].__dict__\n"
                "        _ios_main.setdefault('__name__', '__main__')\n"
                "        exec(_ios_compile(_ios_code, '<string>', 'exec'), _ios_main)\n")) {
            free(script.bytes);
            return NULL;
        }
        break;
    case IOS_PYTHON_MODE_MODULE:
        if (!ios_python_append(&script, "        _ios_set_path0('')\n        _ios_apply_pythonpath()\n        _ios_module = _ios_decode(") ||
            !ios_python_append_bytes_literal(&script, argv[invocation->target_index]) ||
            !ios_python_append(&script,
                ")\n"
                "        _ios_module_context = _ios_prepare_module(_ios_module)\n"
                "        try:\n"
                "            _ios_install_pip_pure_python_guard(_ios_module)\n"
                "            _ios_runpy.run_module(_ios_module, run_name='__main__', alter_sys=True)\n"
                "        finally:\n"
                "            if _ios_module_context is not None:\n"
                "                _ios_module_context.__exit__(None, None, None)\n")) {
            free(script.bytes);
            return NULL;
        }
        break;
    case IOS_PYTHON_MODE_SCRIPT:
        if (!ios_python_append(&script, "        _ios_script = _ios_decode(") ||
            !ios_python_append_bytes_literal(&script, argv[invocation->target_index]) ||
            !ios_python_append(&script,
                ")\n"
                "        _ios_script_dir = _ios_os.path.dirname(_ios_os.path.abspath(_ios_script))\n"
                "        _ios_set_path0(_ios_script_dir)\n"
                "        _ios_apply_pythonpath()\n"
                "        _ios_runpy.run_path(_ios_script, run_name='__main__')\n")) {
            free(script.bytes);
            return NULL;
        }
        break;
    case IOS_PYTHON_MODE_STDIN:
        if (!ios_python_append(&script,
            "        _ios_set_path0('')\n"
            "        _ios_apply_pythonpath()\n"
            "        _ios_code = _ios_sys.stdin.read()\n"
            "        _ios_main = _ios_sys.modules['__main__'].__dict__\n"
            "        _ios_main.setdefault('__name__', '__main__')\n"
            "        exec(_ios_compile(_ios_code, '<stdin>', 'exec'), _ios_main)\n")) {
            free(script.bytes);
            return NULL;
        }
        break;
    default:
        break;
    }

    if (!ios_python_append(&script,
        "    except _ios_system_exit as exc:\n"
        "        _ios_exit_code = _ios_exit_status(exc.code)\n"
        "    except _ios_keyboard_interrupt:\n"
        "        _ios_exit_code = 130\n"
        "    except _ios_base_exception:\n"
        "        _ios_traceback.print_exc()\n"
        "        _ios_exit_code = 1\n"
        "    finally:\n"
        "        _ios_restore_subprocess()\n"
        "        try:\n"
        "            _ios_sys.stdout.flush()\n"
        "        except _ios_base_exception:\n"
        "            pass\n"
        "        try:\n"
        "            _ios_sys.stderr.flush()\n"
        "        except _ios_base_exception:\n"
        "            pass\n"
        "        _ios_sys.argv = _ios_saved_argv\n"
        "        try:\n"
        "            _ios_sys.path[:] = _ios_saved_path\n"
        "        except _ios_base_exception:\n"
        "            _ios_sys.path = _ios_saved_path\n"
        "        _ios_sys.stdin = _ios_saved_stdin\n"
        "        _ios_sys.stdout = _ios_saved_stdout\n"
        "        _ios_sys.stderr = _ios_saved_stderr\n"
        "        for _ios_stream, _ios_saved_stream in (\n"
        "            (_ios_reopened_stdin, _ios_saved_stdin),\n"
        "            (_ios_reopened_stdout, _ios_saved_stdout),\n"
        "            (_ios_reopened_stderr, _ios_saved_stderr),\n"
        "        ):\n"
        "            if _ios_stream is _ios_saved_stream:\n"
        "                continue\n"
        "            try:\n"
        "                _ios_stream.close()\n"
        "            except _ios_base_exception:\n"
        "                pass\n"
        "        _ios_sys.modules = _ios_saved_modules\n"
        "        if _ios_main_module is not None:\n"
        "            _ios_saved_modules['__main__'] = _ios_main_module\n"
        "        _ios_sys.dont_write_bytecode = _ios_saved_dont_write_bytecode\n"
        "        if _ios_saved_system is None:\n"
        "            try:\n"
        "                del _ios_os.system\n"
        "            except _ios_base_exception:\n"
        "                pass\n"
        "        else:\n"
        "            _ios_os.system = _ios_saved_system\n"
        "        _ios_restore_dict(_ios_builtins.__dict__, _ios_saved_builtins)\n"
        "        _ios_restore_dict(_ios_main_dict, _ios_saved_main)\n"
        "    return _ios_exit_code\n"
        "_ios_exit_code = _ios_run()\n")) {
        free(script.bytes);
        return NULL;
    }
    return script.bytes;
}

static int ios_python_read_exit_code(int fallback) {
    IOSPyObject *main_module = ios_python_api.PyImport_AddModule("__main__");
    if (main_module == NULL) {
        ios_python_api.PyErr_Clear();
        return fallback;
    }
    IOSPyObject *value = ios_python_api.PyObject_GetAttrString(main_module, "_ios_exit_code");
    if (value == NULL) {
        ios_python_api.PyErr_Clear();
        return fallback;
    }
    long exit_code = ios_python_api.PyLong_AsLong(value);
    ios_python_api.Py_DecRef(value);
    return (int)exit_code;
}

static void ios_python_delete_exit_code(void) {
    IOSPyObject *main_module = ios_python_api.PyImport_AddModule("__main__");
    if (main_module == NULL) {
        ios_python_api.PyErr_Clear();
        return;
    }
    if (ios_python_api.PyObject_DelAttrString(main_module, "_ios_exit_code") != 0) {
        ios_python_api.PyErr_Clear();
    }
}

static int ios_python_run_main_interpreter(const char *script) {
    int gil_state = ios_python_api.PyGILState_Ensure();
    IOSPyThreadState *threadState =
        ios_python_api.PyThreadState_Get();
    bool shouldRun =
        ios_python_activate_command_target(threadState);
    int exit_code = 130;
    if (shouldRun) {
        int run_result =
            ios_python_api.PyRun_SimpleStringFlags(script, NULL);
        exit_code =
            ios_python_read_exit_code(run_result == 0 ? 0 : 1);
        ios_python_delete_exit_code();
        if (run_result != 0) {
            ios_python_api.PyErr_Print();
            exit_code = exit_code == 0 ? 1 : exit_code;
        }
    }
    if (ios_python_command_was_cancelled()) {
        exit_code = 130;
    }
    ios_python_deactivate_command_target();
    ios_python_api.PyGILState_Release(gil_state);
    return exit_code;
}

static int ios_python_run_subinterpreter(const char *script) {
    int gil_state = ios_python_api.PyGILState_Ensure();
    IOSPyThreadState *main_tstate = ios_python_api.PyThreadState_Get();
    IOSPyThreadState *sub_tstate = NULL;
    IOSPyInterpreterConfig config = {
        .use_main_obmalloc = 0,
        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 1,
        .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1,
        .gil = 2,
    };
    IOSPyStatus status = ios_python_api.Py_NewInterpreterFromConfig(&sub_tstate, &config);
    if (status._type != 0 || sub_tstate == NULL) {
        ios_python_deactivate_command_target();
        ios_python_api.PyThreadState_Swap(main_tstate);
        ios_python_api.PyGILState_Release(gil_state);
        fprintf(thread_stderr, "python: failed creating subinterpreter");
        if (status.err_msg != NULL) {
            fprintf(thread_stderr, ": %s", status.err_msg);
        }
        fprintf(thread_stderr, "\n");
        return status.exitcode != 0 ? status.exitcode : 1;
    }

    bool shouldRun =
        ios_python_activate_command_target(sub_tstate);
    int exit_code = 130;
    if (shouldRun) {
        int run_result =
            ios_python_api.PyRun_SimpleStringFlags(script, NULL);
        exit_code =
            ios_python_read_exit_code(run_result == 0 ? 0 : 1);
        ios_python_delete_exit_code();
        if (run_result != 0) {
            ios_python_api.PyErr_Print();
            exit_code = exit_code == 0 ? 1 : exit_code;
        }
    }
    if (ios_python_command_was_cancelled()) {
        exit_code = 130;
    }
    ios_python_deactivate_command_target();
    sub_tstate = ios_python_api.PyEval_SaveThread();
    // A synchronous ios_kill may have pinned this interpreter before it could
    // acquire the GIL. Wait without the GIL before destroying the interpreter.
    pthread_mutex_lock(&currentSession->pythonCommandsMutex);
    while (currentPythonCommand->activeCancellationRequests > 0) {
        pthread_cond_wait(
            &currentSession->pythonCommandsCondition,
            &currentSession->pythonCommandsMutex);
    }
    pthread_mutex_unlock(&currentSession->pythonCommandsMutex);
    ios_python_api.PyEval_AcquireThread(sub_tstate);
    ios_python_api.Py_EndInterpreter(sub_tstate);
    ios_python_api.PyThreadState_Swap(main_tstate);
    ios_python_api.PyGILState_Release(gil_state);
    return exit_code;
}

int ios_python_main(int argc, char **argv) {
    IOSPythonInvocation invocation = ios_python_parse_invocation(argc, argv);
    if (invocation.mode == IOS_PYTHON_MODE_HELP) {
        fprintf(thread_stdout,
                "usage: python [option] ... [-c cmd | -m mod | file | -] [arg] ...\n"
                "Supported by ios_system: -c, -m, script files, stdin, --version, -B, -E, -I, -s, -S, -u, -v, -q, -b, -O, -W, -X.\n");
        return 0;
    }
    if (invocation.mode == IOS_PYTHON_MODE_ERROR) {
        if (invocation.error != NULL && invocation.error[0] == '-') {
            fprintf(thread_stderr, "python: unsupported option %s\n", invocation.error);
        } else {
            fprintf(thread_stderr, "python: %s\n", invocation.error != NULL ? invocation.error : "invalid arguments");
        }
        return 2;
    }
    bool uses_default_stdin = thread_stdin == NULL || fileno(thread_stdin) == fileno(stdin);
    if (invocation.mode == IOS_PYTHON_MODE_STDIN &&
        !invocation.explicit_stdin &&
        (uses_default_stdin || ios_isatty(fileno(thread_stdin)))) {
        fprintf(thread_stderr, "python: interactive mode is not supported by ios_system yet; use -c, -m, a script, or pipe stdin.\n");
        return 0;
    }

    if (!ios_python_ensure_runtime()) {
        return 1;
    }
    if (ios_python_command_was_cancelled()) {
        return 130;
    }

    char *script = ios_python_build_script(argc, argv, &invocation);
    if (script == NULL) {
        fprintf(thread_stderr, "python: failed building ios_system bootstrap script\n");
        return 1;
    }

    int previousPythonInstances = atomic_fetch_add_explicit(&currentPythonInstances, 1, memory_order_acq_rel);
    int exit_code;
    if (previousPythonInstances == 0) {
        exit_code = ios_python_run_main_interpreter(script);
    } else {
        exit_code = ios_python_run_subinterpreter(script);
    }
    atomic_fetch_sub_explicit(&currentPythonInstances, 1, memory_order_acq_rel);
    free(script);
    if (ios_python_command_was_cancelled()) {
        return 130;
    }
    return exit_code;
}

typedef struct {
    uint64_t command_identifier;
    const char *working_directory;
    const char *preload_path;
    const char *const *environment;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
} IOSNodeMobileCommandOptions;

extern int node_mobile_run_command(
    int argc,
    char *argv[],
    const IOSNodeMobileCommandOptions *options) IOS_NODE_WEAK_IMPORT;

static int ios_node_request_cancel(sessionParameters *session) {
    if (!atomic_load_explicit(
            &session->nodeCommandRunning,
            memory_order_acquire)) {
        return ESRCH;
    }
    if (node_mobile_cancel_command == NULL) {
        // This is still a Node command, so do not let ios_kill fall back to
        // asynchronously terminating its pthread.
        return ENOSYS;
    }

    session->global_errno = 130;
    uint64_t commandIdentifier = atomic_load_explicit(
        &session->nodeCommandIdentifier,
        memory_order_acquire);
    if (commandIdentifier == 0) {
        return 0;
    }
    int cancellationStatus =
        node_mobile_cancel_command(commandIdentifier);
    if (cancellationStatus == 0 || cancellationStatus == ESRCH) {
        // ESRCH only means cleanup won the race after this caller observed
        // nodeCommandRunning. The Node pthread is no longer a cancellation
        // target at that point.
        return 0;
    }
    return cancellationStatus;
}

static int ios_managed_runtime_request_cancel(sessionParameters *session) {
    int cancellationStatus = ios_node_request_cancel(session);
    return cancellationStatus != ESRCH
        ? cancellationStatus
        : ios_python_request_cancel(session);
}

int ios_node_main(int argc, char **argv) {
    if (node_mobile_run_command == NULL) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "node: NodeMobile is not linked into this ios_system process\n");
        return 1;
    }
    if (currentNodeCommandIdentifier == 0) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "node: command cancellation state was not prepared\n");
        return 1;
    }

    char working_directory[PATH_MAX];
    if (getcwd(working_directory, sizeof(working_directory)) == NULL) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "node: unable to resolve the working directory: %s\n",
                strerror(errno));
        return 1;
    }
    if (ios_setenv("PWD", working_directory, 1) != 0) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "node: unable to synchronize PWD: %s\n",
                strerror(errno));
        return 1;
    }

    FILE *input = thread_stdin != NULL ? thread_stdin : stdin;
    FILE *output = thread_stdout != NULL ? thread_stdout : stdout;
    FILE *error = thread_stderr != NULL ? thread_stderr : stderr;
    int inputDescriptor = dup(fileno(input));
    int outputDescriptor = dup(fileno(output));
    int errorDescriptor = dup(fileno(error));
    // The command-thread signal mask does not protect other app threads from
    // Darwin's SIGPIPE delivery. Suppress it on the owned output descriptors.
    if (inputDescriptor < 0 || outputDescriptor < 0 || errorDescriptor < 0 ||
        fcntl(outputDescriptor, F_SETNOSIGPIPE, 1) < 0 ||
        fcntl(errorDescriptor, F_SETNOSIGPIPE, 1) < 0) {
        int streamError = errno;
        if (inputDescriptor >= 0) close(inputDescriptor);
        if (outputDescriptor >= 0) close(outputDescriptor);
        if (errorDescriptor >= 0) close(errorDescriptor);
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "node: unable to duplicate command streams: %s\n",
                strerror(streamError));
        return 1;
    }
    IOSNodeMobileCommandOptions options = {
        .command_identifier = currentNodeCommandIdentifier,
        .working_directory = working_directory,
        .preload_path = ios_getenv("NODE_MOBILE_VIRTUAL_NODE_PRELOAD"),
        .environment = (const char *const *)environmentVariables(ios_currentPid()),
        .stdin_fd = inputDescriptor,
        .stdout_fd = outputDescriptor,
        .stderr_fd = errorDescriptor,
    };
    int status = node_mobile_run_command(argc, argv, &options);
    close(inputDescriptor);
    close(outputDescriptor);
    close(errorDescriptor);
    return status;
}

static int ios_node_command_main(
    int argc, char **argv, NSString *scriptPath, const char *commandName) {
    if (scriptPath.length == 0) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "%s: bundled JavaScript command is not configured\n",
                commandName);
        return 1;
    }
    int nodeArgc = argc + 1;
    char **nodeArgv = (char **)calloc((size_t)nodeArgc + 1, sizeof(char *));
    if (nodeArgv == NULL) {
        fprintf(thread_stderr != NULL ? thread_stderr : stderr,
                "%s: unable to allocate command arguments\n",
                commandName);
        return 1;
    }
    nodeArgv[0] = "node";
    nodeArgv[1] = (char *)scriptPath.fileSystemRepresentation;
    for (int index = 1; index < argc; ++index) {
        nodeArgv[index + 1] = argv[index];
    }
    int status = ios_node_main(nodeArgc, nodeArgv);
    free(nodeArgv);
    return status;
}

int ios_npm_main(int argc, char **argv) {
    return ios_node_command_main(argc, argv, nodeNPMCommandPath, "npm");
}

int ios_npx_main(int argc, char **argv) {
    return ios_node_command_main(argc, argv, nodeNPXCommandPath, "npx");
}

#undef IOS_NODE_WEAK_IMPORT

static int ios_python_module_main(int argc, char **argv, char *module) {
    int python_argc = argc + 2;
    char **python_argv = (char **)malloc(sizeof(char *) * (python_argc + 1));
    if (python_argv == NULL) {
        return 1;
    }
    python_argv[0] = argv[0];
    python_argv[1] = "-m";
    python_argv[2] = module;
    for (int i = 1; i < argc; i++) {
        python_argv[i + 2] = argv[i];
    }
    python_argv[python_argc] = NULL;
    int status = ios_python_main(python_argc, python_argv);
    free(python_argv);
    return status;
}

int ios_pip_main(int argc, char **argv) {
    return ios_python_module_main(argc, argv, "pip");
}

int ios_ytdlp_main(int argc, char **argv) {
    return ios_python_module_main(argc, argv, "yt_dlp");
}

int type_main(int argc, char** argv) {
    // Minimalist implementation of type to keep make happy
    if (argc < 2) { return 1; }
    fprintf(thread_stdout, "%s is %s\n", argv[1], argv[1]);
    return 0;
}

int which_main(int argc, char** argv) {
    int showAll = 0;
    int silent = 0;
    int ch;
    int status = 0;

    optind = 1; opterr = 1; optreset = 1;
    while ((ch = getopt(argc, argv, "as")) != -1) {
        switch (ch) {
        case 'a':
            showAll = 1;
            break;
        case 's':
            silent = 1;
            break;
        default:
            return 1;
        }
    }
    if (optind >= argc) {
        return 1;
    }

    NSArray<NSString *> *directories = ios_directoriesInPath();

    for (int i = optind; i < argc; i++) {
        const char *command = argv[i];
        int found = 0;

        if (strchr(command, '/') != NULL) {
            const ios_command_entry *entry = ios_command_lookup_virtual_path(command);
            if (entry != NULL) {
                if (!silent) {
                    fprintf(thread_stdout, "%s/%s\n", ios_command_virtual_bin_path(), entry->name);
                }
                found = 1;
            } else if (isRealCommand(command)) {
                if (!silent) {
                    fprintf(thread_stdout, "%s\n", command);
                }
                found = 1;
            }
        } else {
            NSString *commandName = [NSString stringWithCString:command encoding:NSUTF8StringEncoding];
            if (commandName != nil) {
                for (NSString *path in directories) {
                    if (ios_command_is_virtual_bin_path(path.UTF8String)) {
                        const ios_command_entry *entry = ios_command_lookup(command);
                        if (entry != NULL) {
                            if (!silent) {
                                fprintf(thread_stdout, "%s/%s\n", ios_command_virtual_bin_path(), entry->name);
                            }
                            found = 1;
                            if (!showAll) {
                                break;
                            }
                        }
                        continue;
                    }

                    NSString *candidate = [path stringByAppendingPathComponent:commandName];
                    if (isRealCommand(candidate.UTF8String)) {
                        if (!silent) {
                            fprintf(thread_stdout, "%s\n", candidate.UTF8String);
                        }
                        found = 1;
                        if (!showAll) {
                            break;
                        }
                    }
                }
            }
        }

        if (!found) {
            status = 1;
        }
    }
    return status;
}

int alias_main(int argc, char** argv) {
    // Syntax: alias command="new command" or alias command "new command" (both must work)
    // alias -h or alias --help: print help
    // alias (no arguments): print list of aliases
    // alias (single argument): print corresponding alias
    NSString* usage = @"usage: alias command new command\n\talias command=new command\n\t!^ = first argument\n\t!* = all arguments";
    if (aliasDictionary == nil) {
        aliasDictionary = [NSMutableDictionary new];
    }
    if (argc <= 1) {
        // no arguments: print list of aliases
        for (NSString* command in aliasDictionary) {
            NSArray<NSString*>* aliasArray = aliasDictionary[command];
            fprintf(thread_stdout, "%s\t", command.UTF8String);
            fprintf(thread_stdout, "%s", aliasArray[0].UTF8String);
            if ([aliasArray[2] isEqualToString: @"afterFirst"]) {
                fprintf(thread_stdout, " !^ %s", aliasArray[1].UTF8String);
            } else if ([aliasArray[2] isEqualToString: @"afterLast"]) {
                fprintf(thread_stdout, " !* %s", aliasArray[1].UTF8String);
            }
            fprintf(thread_stdout, "\n");
        }
        return 0;
    }
    if (argv[1][0] == '-') {
        if ((strncmp(argv[1], "-h", 2) != 0) && (strncmp(argv[1], "--help", 6) != 0)) {
            fprintf(thread_stderr, "alias: unrecognized option %s\n", argv[1]);
        }
        fprintf(thread_stderr, "%s\n", usage.UTF8String);
        return 0;
    }
    char* equalSign = strchr(argv[1], '=');
    NSString* command = nil;
    if ((equalSign == NULL) && (argc == 2)) {
        // single command, show alias:
        command =  [NSString stringWithCString:argv[1] encoding:NSUTF8StringEncoding];
        NSLog(@"Extracting alias for command %s = %@.", argv[1], command);
        NSArray<NSString*>* aliasArray = aliasDictionary[command];
        if (aliasArray == nil) { return 0; }
        fprintf(thread_stdout, "%s", aliasArray[0].UTF8String);
        if ([aliasArray[2] isEqualToString: @"afterFirst"]) {
            fprintf(thread_stdout, " !^ %s", aliasArray[1].UTF8String);
        } else if ([aliasArray[2] isEqualToString: @"afterLast"]) {
            fprintf(thread_stdout, " !* %s  ", aliasArray[1].UTF8String);
        }
        fprintf(thread_stdout, "\n");
        return 0;
    }
    NSMutableArray<NSString *> *commandArray = [[NSMutableArray alloc] init];
    if (equalSign != NULL) {
        // There is an equal sign in the second argument. Split into alias / command:
        equalSign[0] = 0;
        char* alias = equalSign + 1;
        command =  [NSString stringWithCString:argv[1] encoding:NSUTF8StringEncoding];
        commandArray[0] = [NSString stringWithCString:alias encoding:NSUTF8StringEncoding];;
    } else {
        command =  [NSString stringWithCString:argv[1] encoding:NSUTF8StringEncoding];
    }
    if (argc >= 3) {
        // We keep the benefit of the parsing that was already done:
        for (int i = 0; i < argc - 2; i++) {
            [commandArray addObject: [NSString stringWithCString:argv[i + 2] encoding:NSUTF8StringEncoding]];
        }
    }
    if ((command == nil) || (commandArray == nil) || (commandArray.count == 0)) {
        // Something went wrong
        return 1;
    }
    if ((equalSign != NULL) || (commandArray.count == 1)) {
        // If there was an equal sign, so there might be some extra quotes:
        // Observed decomposition with equal sign: "ll=\"ls" + "-l\""
        // If there is a single command, we separate it as well: alias ls "ls -l"
        if ([commandArray[0] hasPrefix:@"\""] && [[commandArray lastObject] hasSuffix:@"\""]) {
            commandArray[0] = [commandArray[0] substringFromIndex:1];
            commandArray[commandArray.count - 1] = [[commandArray lastObject] substringToIndex:[[commandArray lastObject] length] -1];
        } else if ([commandArray[0] hasPrefix:@"'"] && [[commandArray lastObject] hasSuffix:@"'"]) {
            commandArray[0] = [commandArray[0] substringFromIndex:1];
            commandArray[commandArray.count - 1] = [[commandArray lastObject] substringToIndex:[[commandArray lastObject] length] -1];
        }
    }
    if (commandArray.count == 1) {
        char* aliasCommandCString = strdup(commandArray[0].UTF8String);
        char* pointerToFree = aliasCommandCString;
        char* nextSpace = strstrquoted(aliasCommandCString, " ");
        int i = 0;
        while (nextSpace != NULL) {
            *nextSpace = 0;
            commandArray[i] = [NSString stringWithCString:aliasCommandCString encoding:NSUTF8StringEncoding];
            // NSLog(@"Adding %s to array.", aliasCommandCString);
            aliasCommandCString = nextSpace + 1;
            if (*aliasCommandCString == 0) {
                break;
            }
            nextSpace = strstrquoted(aliasCommandCString, " ");
            i += 1;
        }
        if (*aliasCommandCString != 0) {
            // NSLog(@"Adding %s to array.", aliasCommandCString);
            commandArray[i] = [NSString stringWithCString:aliasCommandCString encoding:NSUTF8StringEncoding];
        }
        free(pointerToFree);
    }
    NSString* before = @"";
    NSString* after = @"";
    NSString* position = @"";
    if (([commandArray containsObject:@"!^"]) && ([commandArray containsObject:@"!*"])) {
        fprintf(thread_stderr, "alias: can't specify both !^ and !*, sorry.\n");
        return 1;
    } else if ([commandArray containsObject:@"!^"]) {
        position = @"afterFirst";
        bool foundMarker = false;
        for (NSString* component in commandArray) {
            if ([component isEqualToString: @"!^"]) { foundMarker = true; continue; }
            if (!foundMarker) {
                before = [before stringByAppendingString: component];
                before = [before stringByAppendingString: @" "];
            } else {
                after = [after stringByAppendingString: component];
                after = [after stringByAppendingString: @" "];
            }
        }
    } else if ([commandArray containsObject:@"!*"]) {
        position = @"afterLast";
        bool foundMarker = false;
        for (NSString* component in commandArray) {
            if ([component isEqualToString:@"!*"]) {
                foundMarker = true;
                continue;
            }
            if (!foundMarker) {
                before = [before stringByAppendingString: component];
                before = [before stringByAppendingString: @" "];
            } else {
                after = [after stringByAppendingString: component];
                after = [after stringByAppendingString: @" "];
            }
        }
    } else {
        for (NSString* component in commandArray) {
            before = [before stringByAppendingString: component];
            before = [before stringByAppendingString: @" "];
        }
    }
    before = [before stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    after = [after stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    NSArray<NSString *> *result = @[before, after, position];
    aliasDictionary[command] = result;
    return 0;
}

NSString* aliasedCommand(NSString* command) {
    if ([command hasPrefix:@"\\"]) {
        // \command = cancel aliasing
        return [command substringFromIndex:1];
    }
    if (aliasDictionary == nil) {
        return command;
    }
    NSArray<NSString*>* aliasArray = aliasDictionary[command];
    if (aliasArray == nil) {
        return command;
    }
    NSString* result = aliasArray[0];
    if ([aliasArray[2] isEqualToString: @"afterFirst"]) {
        result = [[result stringByAppendingString:@" !^ "] stringByAppendingString: aliasArray[1]];
    } else if ([aliasArray[2] isEqualToString: @"afterLast"]) {
        result = [[result stringByAppendingString:@" !* "] stringByAppendingString: aliasArray[1]];
    }
    return result;
}

int unalias_main(int argc, char** argv) {
    NSString* usage = @"usage: unalias [command|-a]";
    if (aliasDictionary == nil) {
        aliasDictionary = [NSMutableDictionary new];
    }
    if ((argc == 1) || ((argv[1][0] == '-') && (strncmp(argv[1], "-a", 2) != 0))) {
        fprintf(thread_stderr, "%s\n", usage.UTF8String);
        return 0;
    }
    if (strncmp(argv[1], "-a", 2) == 0) {
        [aliasDictionary removeAllObjects];
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        NSString* command =  [NSString stringWithCString:argv[i] encoding:NSUTF8StringEncoding];
        [aliasDictionary removeObjectForKey: command];
    }
    return 0;
}

static int ios_system_osh_invocation(
    int argc, const char *const argv[], bool startsCommand);
static int ios_system_osh_evaluate(
    int argc, const char *const argv[], bool startsCommand);

// sh and bash hand their complete invocation to OSH, which parses options,
// -c and its $0, a script operand, and positional parameters itself. They run
// as a command that ios_system already started, so the shell keeps any stop
// requested since then.
int sh_main(int argc, char** argv) {
    return ios_system_osh_invocation(argc, (const char *const *)argv, false);
}


int ios_execv(const char *path, char* const argv[]) {
    if (argv == NULL || argv[0] == NULL) {
        errno = EINVAL;
        return EINVAL;
    }
    int argc = 0;
    while (argv[argc] != NULL) argc++;

    // execv's path is authoritative even when argv[0] is only a display name.
    // The resolver needs that path to recognize project-local shebang and Wasm
    // executables, so substitute it for dispatch without mutating the caller.
    const char **dispatchArgv = malloc(sizeof(char *) * argc);
    if (dispatchArgv == NULL) {
        errno = ENOMEM;
        return ENOMEM;
    }
    for (int i = 0; i < argc; i++) dispatchArgv[i] = argv[i];
    if (path != NULL && path[0] != 0) dispatchArgv[0] = path;
    int returnValue = ios_system(argc, dispatchArgv);
    free(dispatchArgv);
    return returnValue;
}

int ios_execve(const char *path, char* const argv[], char* envp[]) {
    // save the environment (done) and current dir (TODO)
    storeEnvironment(envp);
    int returnValue = ios_execv(path, argv);
    // The environment will be restored to previous value when the thread Id is released.
    return returnValue;
}

extern char** environmentVariables(pid_t pid);
NSArray* environmentAsArray(void) {
    char** env_pid = environmentVariables(ios_currentPid());
    NSMutableArray<NSString*> *dictionary = [[NSMutableArray alloc]init];
    int i = 0;
    while (env_pid[i] != NULL) {
        NSString* variable =  [NSString stringWithCString:env_pid[i] encoding:NSUTF8StringEncoding];
        [dictionary addObject:variable];
        i++;
    }
    // Add our own variables: ROWS, PWD (COLUMNS and LINES are already set).
    // Decode as UTF-8: stringWithCString: uses the system encoding, which on a
    // Simplified Chinese Mac rejects UTF-8 paths and returns nil.
    NSString* rowVariable = @"ROWS=";
    rowVariable = [rowVariable stringByAppendingString: [NSString stringWithUTF8String: currentSession->columns]];
    [dictionary addObject: rowVariable];
    NSString* pwdVariable = @"PWD=";
    pwdVariable = [pwdVariable stringByAppendingString: [NSString stringWithUTF8String: currentSession->currentDir]];
    [dictionary addObject: pwdVariable];
    NSString* randomVariable = @"RANDOM=";
    sprintf(randomValue, "%ld", random() & 0x7FFF);
    randomVariable = [randomVariable stringByAppendingString: [NSString stringWithUTF8String: randomValue]];
    return [dictionary copy];
}

pthread_t ios_getLastThreadId(void) {
    if (!currentSession) return nil;
    return (currentSession->lastThreadId);
}

/*
 * Public domain dup2() lookalike
 * by Curtis Jackson @ AT&T Technologies, Burlington, NC
 * electronic address:  burl!rcj
 * Edited for iOS by N. Holzschuch.
 * The idea is that dup2(fd, [012]) is usually called between fork and exec.
 *
 * dup2 performs the following functions:
 *
 * Check to make sure that fd1 is a valid open file descriptor.
 * Check to see if fd2 is already open; if so, close it.
 * Duplicate fd1 onto fd2; checking to make sure fd2 is a valid fd.
 * Return fd2 if all went well; return BADEXIT otherwise.
 */

int ios_dup2(int fd1, int fd2)
{
    NSLog(@"ios_dup2: %d %d", fd1, fd2);
    // iOS specifics: trying to access stdin/stdout/stderr?
    if (fd1 < 3) {
        // specific cases like dup2(STDOUT_FILENO, STDERR_FILENO)
        FILE* stream1 = NULL;
        switch (fd1) {
            case 0: stream1 = child_stdin; break;
            case 1: stream1 = child_stdout; break;
            case 2: stream1 = child_stderr; break;
        }
        switch (fd2) {
            case 0:
                if (stream1 != NULL) {
                    ios_replaceChildStream(&child_stdin, stream1); return fd2;
                } else break;
            case 1:
                if (stream1 != NULL) {
                    ios_replaceChildStream(&child_stdout, stream1); return fd2;
                } else break;
            case 2:
                if (stream1 != NULL) {
                    ios_replaceChildStream(&child_stderr, stream1); return fd2;
                } else break;
        }
    }
    // We can have fileno(thread_stdin) == 1. Most likely fd2 == 1 means stdout in that case.
    if (fd2 == 0) {
        if (ios_duplicateChildStream(fd1, "rb", &child_stdin) != 0) return -1;
    } else if (fd2 == 1) {
        if (ios_duplicateChildStream(fd1, "wb", &child_stdout) != 0) return -1;
    } else if (fd2 == 2) {
        if ((child_stdout != NULL) && (fileno(child_stdout) == fd1)) ios_replaceChildStream(&child_stderr, child_stdout);
        else if ((thread_stdout != NULL) && (fileno(thread_stdout) == fd1)) ios_replaceChildStream(&child_stderr, thread_stdout);
        else if (fd1 == 1) {
            ios_replaceChildStream(&child_stderr, thread_stdout);
        } else {
            if (ios_duplicateChildStream(fd1, "wb", &child_stderr) != 0) return -1;
        }
    } else if (thread_stdin != NULL && fd2 == fileno(thread_stdin)) {
        if (ios_duplicateChildStream(fd1, "rb", &child_stdin) != 0) return -1;
    } else if (thread_stdout != NULL && fd2 == fileno(thread_stdout)) {
        if (ios_duplicateChildStream(fd1, "wb", &child_stdout) != 0) return -1;
    } else if (thread_stderr != NULL && fd2 == fileno(thread_stderr)) {
        if ((child_stdout != NULL) && (fileno(child_stdout) == fd1)) ios_replaceChildStream(&child_stderr, child_stdout);
        else {
            if (ios_duplicateChildStream(fd1, "wb", &child_stderr) != 0) return -1;
        }
    }
    else if (fd1 != fd2) {
        if (fcntl(fd1, F_GETFL) < 0)
            return -1;
        if (fcntl(fd2, F_GETFL) >= 0)
            close(fd2);
        if (fcntl(fd1, F_DUPFD, fd2) < 0)
            return -1;
    }
    return fd2;
}

int ios_kill(void)
{
    if (currentSession == NULL) return ESRCH;
    // Sequentially consistent with a shell starting up: either this sees the
    // shell running, or the shell sees this stop (ios_system_osh_invocation).
    atomic_store_explicit(&currentSession->commandCancellationRequested, true, memory_order_seq_cst);
    // Pairs with the fence in run_function: either the code below sees a
    // command registering now, or that command sees this request before it runs.
    atomic_thread_fence(memory_order_seq_cst);
    if (atomic_load_explicit(
            &currentSession->shellCommandRunning,
            memory_order_seq_cst)) {
        // Stopping a shell job stops the whole job. Every evaluator in it,
        // including nested shells, checks this flag before its next command;
        // the code below only interrupts the command that is running now.
        atomic_store_explicit(
            &currentSession->cancellationRequested,
            true,
            memory_order_release);
    }
    int cancellationStatus =
        ios_managed_runtime_request_cancel(currentSession);
    if (cancellationStatus != ESRCH) {
        return cancellationStatus;
    }
    if (atomic_load_explicit(
            &currentSession->shellCommandRunning,
            memory_order_acquire)) {
        pthread_t rootThread = currentSession->current_command_root_thread;
        if (rootThread == NULL || rootThread == currentSession->shellThread) {
            cancellationStatus =
                ios_managed_runtime_request_cancel(currentSession);
            if (cancellationStatus != ESRCH) {
                return cancellationStatus;
            }
            rootThread = currentSession->current_command_root_thread;
            if (rootThread == NULL || rootThread == currentSession->shellThread) {
                return 0;
            }
        }
        cancellationStatus =
            ios_managed_runtime_request_cancel(currentSession);
        if (cancellationStatus != ESRCH) {
            return cancellationStatus;
        }
        currentSession->global_errno = 130;
        if (atomic_load_explicit(
                &currentSession->pthreadCancelableRootCommand,
                memory_order_acquire) != rootThread) {
            return 0;
        }
        return pthread_cancel(rootThread);
    }
    cancellationStatus =
        ios_managed_runtime_request_cancel(currentSession);
    if (cancellationStatus != ESRCH) {
        return cancellationStatus;
    }
    pthread_t rootThread = currentSession->current_command_root_thread;
    if (rootThread > 0) {
        if (atomic_load_explicit(
                &currentSession->pthreadCancelableRootCommand,
                memory_order_acquire) != rootThread) {
            return 0;
        }
        const char *commandName = ios_progname();
        struct sigaction query_action;
        if ((sigaction (SIGINT, NULL, &query_action) >= 0) &&
            (query_action.sa_handler != SIG_DFL) &&
            (query_action.sa_handler != SIG_IGN)) {
            /* A programmer-defined signal handler is in effect. */
            // This might be problematic with multiple commands running at the same time that all define SIGINT
            // ...such as ls.
            // !! this is called from the main thread. So make sure the signal handler does *not* call phtread_exit();
            // For the same reason, thread_stdout is not defined!
            FILE* main_stdin = thread_stdin;
            FILE* main_stdout = thread_stdout;
            FILE* main_stderr = thread_stderr;
            thread_stdin = currentSession->stdin;
            thread_stdout = currentSession->stdout;
            thread_stderr = currentSession->stderr;
            query_action.sa_handler(SIGINT);
            thread_stdin = main_stdin;
            thread_stdout = main_stdout;
            thread_stderr = main_stderr;
            // kill(getpid(), SIGINT); // infinite loop?
            // This kills the process after we ran the cleanup function (if it's still running):
            if (pthread_kill(rootThread, 0) == 0) {
                pthread_cancel(rootThread);
            }
        } else {
            // Send pthread_cancel with the given signal to the current main thread, if there is one.
            if (rootThread != NULL) {
                // pthread_kill for lua, bc, dc:
                if ((strcmp(commandName, "lua") == 0) ||
                    (strcmp(commandName, "bc") == 0) ||
                    (strcmp(commandName, "dc") == 0)) {
                    // Send a SIGINT interrupt to the command:
                    // This works better than pthread_cancel with lua, bc and dc. #858
                    return pthread_kill(rootThread, SIGINT);
                } else {
                    // For the other commands, we use pthread_cancel, otherwise they don't stop. #900
                    return pthread_cancel(rootThread);
                }
            }
        }
    }
    // No process running
    return ESRCH;
}

const void *ios_getCommandCancellationContext(void) {
    return currentSession != NULL ? &currentSession->commandCancellationRequested : NULL;
}

int ios_commandCancellationRequested(const void *context) {
    return context != NULL && atomic_load_explicit(
        (const _Atomic(bool) *)context, memory_order_acquire);
}

extern pthread_t ios_getThreadId(pid_t pid);
int ios_killpid(pid_t pid, int sig) {
    if (ios_getThreadId(pid) > 0) {
        return pthread_kill(ios_getThreadId(pid), sig);
    }
    return 0;
}

void ios_switchSession(const void* sessionId) {
    char* sessionName = (char*) sessionId;
    // NSLog(@"Switching to session: %s\n", sessionName);
    if ((currentSession != nil) && (currentSession->context != NULL) && (strcmp(currentSession->context, sessionName) == 0)) {
        // Already inside this session: do nothing
        return;
    }

    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    id sessionKey = @((NSUInteger)sessionId);
    bool createdSession = false;
    pthread_mutex_lock(&sessionListMutex);
    if (sessionList == nil) {
        sessionList = [NSMutableDictionary new];
        if (currentSession != NULL) [sessionList setObject: [NSValue valueWithPointer:currentSession] forKey: sessionKey];
    }
    sessionParameters *selectedSession =
        (sessionParameters*)[[sessionList objectForKey: sessionKey] pointerValue];
    
    if (selectedSession == NULL) {
        sessionParameters* newSession =  malloc(sizeof(sessionParameters));
        initSessionParameters(newSession);
        [sessionList setObject: [NSValue valueWithPointer:newSession] forKey: sessionKey];
        selectedSession = newSession;
        createdSession = true;
    }
    pthread_mutex_unlock(&sessionListMutex);
    currentSession = selectedSession;
    if (!createdSession && currentSession != NULL) {
        NSString* currentSessionDir = [NSString stringWithCString:currentSession->currentDir encoding:NSUTF8StringEncoding];
        if (![currentSessionDir isEqualToString:[NSFileManager.defaultManager currentDirectoryPath]]) {
            [NSFileManager.defaultManager changeCurrentDirectoryPath:currentSessionDir];
        }
        // Da fuck???? Yeah, that would hurt. Why is it there?
        currentSession->stdin = stdin;
        currentSession->stdout = stdout;
        currentSession->stderr = stderr;
    }
}

void ios_setDirectoryURL(NSURL* workingDirectoryURL) {
    char resolvedDirectory[PATH_MAX];
    if (workingDirectoryURL == nil ||
        realpath(workingDirectoryURL.path.fileSystemRepresentation, resolvedDirectory) == NULL ||
        ![NSFileManager.defaultManager changeCurrentDirectoryPath:
            [NSString stringWithUTF8String:resolvedDirectory]]) {
        return;
    }
    if (currentSession == NULL) {
        return;
    }
    // Another session can change the process cwd immediately after chdir.
    // Record the requested directory, not a subsequent read of process state.
    NSString *currentDirectoryPath = [NSString stringWithUTF8String:resolvedDirectory];
    NSString *currentSessionDir =
        [NSString stringWithUTF8String:currentSession->currentDir];
    if ([currentSessionDir isEqualToString:currentDirectoryPath]) {
        return;
    }
    strlcpy(
        currentSession->previousDirectory,
        currentSession->currentDir,
        sizeof(currentSession->previousDirectory));
    strlcpy(
        currentSession->currentDir,
        currentDirectoryPath.fileSystemRepresentation,
        sizeof(currentSession->currentDir));
}

void ios_openSession(const void* sessionId) {
    ios_switchSession(sessionId);
    if (currentSession != NULL) currentSession->keepsCancellationRequests = true;
}

void ios_closeSession(const void* sessionId) {
    // delete information associated with current session:
    id sessionKey = @((NSUInteger)sessionId);
    pthread_mutex_lock(&sessionListMutex);
    if (sessionList != nil) {
        [sessionList removeObjectForKey: sessionKey];
    }
    pthread_mutex_unlock(&sessionListMutex);
    currentSession = NULL;
}

int ios_isatty(int fd) {
    // NSLog(@"Entering ios_isatty, fd= %d", fd);
    if (currentSession == NULL) return 0;
    // 2 possibilities: 0, 1, 2 (classical) or fileno(thread_stdout)
    if (thread_stdin != NULL) {
        if ((fd == STDIN_FILENO) || (fd == fileno(currentSession->stdin)) || (fd == fileno(thread_stdin)))
            return (fileno(thread_stdin) == fileno(currentSession->stdin));
    }
    if (thread_stdout != NULL) {
        if ((fd == STDOUT_FILENO) || (fd == fileno(currentSession->stdout)) || (fd == fileno(thread_stdout))) {
            return (fileno(thread_stdout) == fileno(currentSession->stdout));
        }
    }
    if (thread_stderr != NULL) {
        if ((fd == STDERR_FILENO) || (fd == fileno(currentSession->stderr)) || (fd == fileno(thread_stderr)))
            return (fileno(thread_stderr) == fileno(currentSession->stderr));
    }
    return 0;
}

void ios_setStreams(FILE* _stdin, FILE* _stdout, FILE* _stderr) {
    if (currentSession == NULL) {
        currentSession = malloc(sizeof(sessionParameters));
        initSessionParameters(currentSession);
    }
    currentSession->stdin = _stdin;
    currentSession->stdout = _stdout;
    currentSession->stderr = _stderr;
    thread_stdin = _stdin;
    thread_stdout = _stdout;
    thread_stderr = _stderr;
}

void ios_settty(FILE* _tty) {
    if (currentSession == NULL) return;
    currentSession->tty = _tty;
}

int ios_gettty(void) {
    if (currentSession == NULL) return -1;
    if (currentSession->tty == NULL) return -1;
    return fileno(currentSession->tty);
}

int ios_getstdin(void) {
    if (thread_stdin != NULL) return fileno(thread_stdin);
    if (currentSession != NULL && currentSession->stdin != NULL) return fileno(currentSession->stdin);
    return -1;
}

int ios_getstdout(void) {
    if (thread_stdout != NULL) return fileno(thread_stdout);
    if (currentSession != NULL && currentSession->stdout != NULL) return fileno(currentSession->stdout);
    return -1;
}

int ios_getstderr(void) {
    if (thread_stderr != NULL) return fileno(thread_stderr);
    if (currentSession != NULL && currentSession->stderr != NULL) return fileno(currentSession->stderr);
    return -1;
}

// Allows commands that are not usually tty-based to get the tty (for password input in ssh/scp/sftp):
int ios_opentty(void) {
    if (currentSession == nil) { return -1; }
    if (currentSession->tty == NULL) return -1;
    currentSession->activePager = true;
    return fileno(currentSession->tty);
}

void ios_closetty(void) {
    if (currentSession == nil) { return; }
    currentSession->activePager = false;
}

int ios_activePager(void) {
    // All commands that read from tty instead of stdin:
    if (currentSession == nil) { return 0; }
    char* currentSessionCommandName;
    if (currentSession->numCommand <= 0)
        currentSessionCommandName = currentSession->commandName[0];
    else
        currentSessionCommandName = currentSession->commandName[currentSession->numCommand - 1];
    if ((strcmp(currentSessionCommandName, "less") == 0) ||
        (strcmp(currentSessionCommandName, "more") == 0)) {
        return 1;
    }
    if (currentSession->activePager) { return 1; }
    return 0;
}

void ios_stopInteractive(void) {
    // Some commands, like sftp, start as "interactive" (they handle all input), then become non-interactive (they let the shell handle input)
    // This could be merged with opentty / closetty above, but stopInteractive involves one more trip to WKWebView->evaluateJS, so it's better not to call it too often.
    void (*function)(void) = NULL;
    function = dlsym(RTLD_MAIN_ONLY, "stopInteractive");
    if (function == NULL) {
        // more extensive search, but more expensive too.
        function = dlsym(RTLD_DEFAULT, "stopInteractive");
    }
    if (function != NULL) {
        function();
    } else {
        NSLog(@"Could not find function stopInteractive");
    }
}

int ios_storeInteractive(void) {
    // Commands started from interactive or non-interactive contexts need to
    // restore the status afterwards.
    int (*function)(void) = NULL;
    function = dlsym(RTLD_MAIN_ONLY, "storeInteractive");
    if (function == NULL) {
        // more extensive search, but more expensive too.
        function = dlsym(RTLD_DEFAULT, "storeInteractive");
    }
    if (function != NULL) {
        return function();
    } else {
        NSLog(@"Could not find function storeInteractive");
        return 0;
    }
}

void ios_startInteractive(void) {
    // With aliasing, we can have commands that are interactive and not detected by the command-line interpreter.
    void (*function)() = NULL;
    function = dlsym(RTLD_MAIN_ONLY, "startInteractive");
    if (function == NULL) {
        // more extensive search, but more expensive too.
        function = dlsym(RTLD_DEFAULT, "startInteractive");
    }
    if (function != NULL) {
        function();
    } else {
        NSLog(@"Could not find function startInteractive.");
    }
}

static int isInteractive(const char* command) {
    // let interactiveRegexp = /^vim|^ipython|^less|^more|^ssh|^scp|^sftp|^jump|\|&? *less|\|&? *more|^man|^pico/;
    if (strncmp(command, "vim", 3) == 0) return true;
    if (strncmp(command, "pico", 4) == 0) return true;
    if (strncmp(command, "ipython", 7) == 0) return true;
    if (strncmp(command, "isympy", 6) == 0) return true;
    if (strncmp(command, "less", 4) == 0) return true;
    if (strncmp(command, "more", 4) == 0) return true;
    if (strncmp(command, "ssh", 3) == 0) return true;
    if (strncmp(command, "scp", 3) == 0) return true;
    if (strncmp(command, "man", 3) == 0) return true;
    if (strncmp(command, "sftp", 4) == 0) return true;
    if (strncmp(command, "jump", 4) == 0) return true;
    return false;
}

void ios_setContext(const void *context) {
    if (currentSession == NULL) return;
    // NSLog(@"Setting session context to: %s\n", (char*)context);
    currentSession->context = context;
}

const void* ios_getContext(void) {
    if (currentSession == NULL) return NULL;
    // NSLog(@"getting session context, %x currentSession->context: %s\n", currentSession, (char*)currentSession->context);
    return currentSession->context;
}

// For customization:
// Add an entire plist file defining multiple commands. Commands follow the same syntax as initializeCommandList:
//
// key = command name, followed by an array of 4 components:
// 1st component: name of digital library (can be "MAIN" if command is defined inside program)
// 2nd component: name of function to be called
// 3rd component: chain sent to getopt (for arguments in autocomplete)
// 4th component: takes a file/directory as argument
//
// Example:
//    <key>rlogin</key>
// <array>
// <string>libnetwork_ios.dylib</string>
// <string>rlogin_main</string>
// <string>468EKLNS:X:acde:fFk:l:n:rs:uxy</string>
// <string>no</string>
// </array>
NSError* addCommandList(NSString* fileLocation) {
    if (commandList == nil) initializeCommandList();
    NSError* error;
    
    NSURL *locationURL = [NSURL fileURLWithPath:fileLocation isDirectory:NO];
    if ([locationURL checkResourceIsReachableAndReturnError:&error] == NO) {
        fprintf(stderr, "Resource dictionary %s not found", fileLocation.UTF8String);
        return error;
    }

    NSData* dataLoadedFromFile = [NSData dataWithContentsOfFile:fileLocation  options:0 error:&error];
    if (!dataLoadedFromFile) return error;
    NSDictionary* newCommandList = [NSPropertyListSerialization propertyListWithData:dataLoadedFromFile options:NSPropertyListImmutable format:NULL error:&error];
    if (!newCommandList) return error;
    // merge the two dictionaries:
    NSMutableDictionary *mutableDict = [commandList mutableCopy];
    [mutableDict addEntriesFromDictionary:newCommandList];
    commandList = [mutableDict copy];
    return NULL;
}


NSString* commandsAsString(void) {
    NSError * err;
    NSData * jsonData = [NSJSONSerialization dataWithJSONObject:commandsAsArray() options:0 error:&err];
    NSString * myString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    return myString;
}

NSArray* commandsAsArray(void) {
    if (commandList == nil) initializeCommandList();
    NSMutableArray<NSString *> *commands = [commandList.allKeys mutableCopy];
    for (int i = 0; i < ios_command_count(); ++i) {
        const ios_command_entry *entry = ios_command_at_index(i);
        if (entry == NULL) continue;
        NSString *command = [NSString stringWithUTF8String:entry->name];
        if (command != nil && ![commands containsObject:command]) {
            [commands addObject:command];
        }
    }
    return [commands copy];
}

NSArray* aliasesAsArray(void) {
    if (aliasDictionary == nil) {
        aliasDictionary = [NSMutableDictionary new];
    }
    return aliasDictionary.allKeys;
}

// for output file names, arguments: returns a pointer to
// immediately after the end of the argument, or NULL.
// Method:
//   - if argument begins with ", go to next unescaped "
//   - if argument begins with ', go to next unescaped '
//   - otherwise, move to next unescaped space
//
// Must be combined with another function to remove backslash.

// Aux function:
static void* nextUnescapedCharacter(const char* str, const char c) {
    char* nextOccurence = strchr(str, c);
    if ((str[0] == '\\') && (str[1] == c)) {
        // str *starts* with the escaped character, no need to search before that '\'
        nextOccurence = strchr(str + 2, c);
    }
    while (nextOccurence != NULL) {
        if ((nextOccurence > str + 1) && (*(nextOccurence - 1) == '\\')) {
            // There is a backlash before the character.
            int numBackslash = 0;
            char* countBack = nextOccurence - 1;
            while ((countBack > str) && (*countBack == '\\')) { numBackslash++; countBack--; }
            if (numBackslash % 2 == 0) return nextOccurence; // even number of backslash
        } else return nextOccurence;
        nextOccurence = strchr(nextOccurence + 1, c);
    }
    return nextOccurence;
}

static char* getLastCharacterOfArgument(const char* argument) {
    // Problem: perl -e 'install([ from_to => {@ARGV}, verbose => '\''0'\'', uninstall_shadows => '\''0'\'', dir_mode => '\''755'\'' ]);'
    // Should become: "perl", "-e", "install([ from_to => {@ARGV}, verbose => '0', uninstall_shadows => '0', dir_mode => '755' ]);"
    // If there is no space after the end quote, keep concatenating the argument.
    char recordSeparator = 0x1e;
    if (strlen(argument) == 0) return NULL; // be safe
    if (argument[0] == '"') {
        char* endquote = nextUnescapedCharacter(argument + 1, '"');
        if (endquote != NULL) {
            // Is there a space after the endquote?
            if (strlen(endquote) <= 1) { return endquote + 1; } // last character
            if (endquote[1] == ' ') { return endquote + 1; } // space after endquote, we're good
            if (strncmp(endquote, "\"\\\"\"", 3) == 0 ) {
                // Perl (for example) wrote here: "\"" and if the substitution works we get " inside the argument
                // We rewrite the argument here (it gets shorter):
                char* write = endquote;
                for (char* read = endquote + 3; *read != 0; read++, write++) {
                    *write = *read;
                }
                write[0] = 0;
                return getLastCharacterOfArgument(endquote + 1);
            }
            // After quote non space character, we should continue till space:
            // `ssh "user name"@localhost`
            return nextUnescapedCharacter(endquote + 1, ' ');
        }
        return NULL;
    } else if (argument[0] == '\'') {
        char* endquote = nextUnescapedCharacter(argument + 1, '\'');
        if (endquote != NULL) {
            // Is there a space after the endquote?
            if (strlen(endquote) <= 1) { return endquote + 1; } // last character
            if (endquote[1] == ' ') { return endquote + 1; } // space after endquote, we're good
            if (strncmp(endquote, "'\\''", 3) == 0 ) {
                // Perl (for example) wrote here: '\'' and if the substitution works we get ' inside the argument
                // We rewrite the argument here (it gets shorter):
                // /!\ There could be other cases, e.g. '"', but why would they do that?
                char* write = endquote;
                for (char* read = endquote + 3; *read != 0; read++, write++) {
                    *write = *read;
                }
                write[0] = 0;
                return getLastCharacterOfArgument(endquote);
            }
            // After quote non space character, we should continue till space
            // `ssh "user name"@localhost`
            return nextUnescapedCharacter(endquote + 1, ' ');
        }
        return NULL;
    } else if (argument[0] == recordSeparator) {
        char* endquote = strchr(argument + 1, recordSeparator);
        if (endquote == NULL) return NULL; // be safe (see #153)
        return endquote + 1;
    }
    // TODO: the last character of the argument could also be '<' or '>' (vim does that, with no space after file name)
    else return nextUnescapedCharacter(argument + 1, ' ');
}

// remove quotes at the beginning of argument if there's a balancing one at the end
static char* unquoteArgument(char* argument) {
    if (argument[0] == '"') {
        if (argument[strlen(argument) - 1] == '"') {
            argument[strlen(argument) - 1] = 0x0;
            return argument + 1;
        }
    }
    if (argument[0] == '\'') {
        if (argument[strlen(argument) - 1] == '\'') {
            argument[strlen(argument) - 1] = 0x0;
            return argument + 1;
        }
    }
    char recordSeparator = 0x1e;
    if (argument[0] == recordSeparator) {
        if (argument[strlen(argument) - 1] == recordSeparator) {
            argument[strlen(argument) - 1] = 0x0;
            return argument + 1;
        }
    }
    // no quotes at the beginning: replace all escaped characters:
    // '\x' -> x
    char* nextOccurence = strchr(argument, '\\');
    while ((nextOccurence != NULL) && (strlen(nextOccurence) > 0)) {
        memmove(nextOccurence, nextOccurence + 1, strlen(nextOccurence + 1) + 1);
        // strcpy(nextOccurence, nextOccurence + 1);
        nextOccurence = strchr(nextOccurence + 1, '\\');
    }
    return argument;
}


static int isRealCommand(const char* fileName) {
    // File exists, is executable, not a directory.
    // We check whether: a) its size is > 0 and b) it is not a Mach-O binary
    int returnValue = false;
    struct stat sb;
    if (stat(fileName, &sb) == 0) {
        // We can have an empty file with the same name in the path, to fool which():
        if (sb.st_size == 0) {
            return false;
        }
        // Not an empty file, so let's check its magic number:
        int fd = open(fileName, O_RDONLY);
        if (fd > 0) {
            char res[4];
            ssize_t retval = read(fd, &res, 4);
            if (retval == 4) {
                // MH_MAGIC_64 = 0xfeedfacf
                if ((res[0] != '\xcf') || (res[1] != '\xfa') || (res[2] != '\xed') || (res[3] != '\xfe')) {
                    // it's not a Mach-O binary:
                    returnValue = true;
                }
            }
            close (fd);
        }
    }
    return returnValue;
}

static bool isBackgroundCommand(char* command) {
    if (backgroundCommandList == nil) {
        return false;
    }
    if (command == NULL) {
        return false;
    }
    NSString *commandAsString = [NSString stringWithUTF8String: command];
    for (NSString* commandInList in backgroundCommandList) {
        if ([commandInList isEqualToString: commandAsString]) {
            // NSLog(@"%s is a backgroundCommand\n", command);
            return true;
        }
        if ([commandInList hasSuffix:@"*"]) {
            NSString* shortCommand = commandInList;
            shortCommand = [shortCommand substringToIndex:[shortCommand length] - 1];
            while ([shortCommand hasSuffix:@" "]) {
                shortCommand = [shortCommand substringToIndex:[shortCommand length] - 1];
            }
            if ([commandAsString hasPrefix: shortCommand]) {
                // NSLog(@"%s is a backgroundCommand\n", command);
                return true;
            }
        }
    }
    return false;
}

NSString* beforeScriptCommandName(NSString* scriptName) {
    // scans the PATH for a binary that has the name script and non-null size,
    // checks whether it has wasm signature, if so insert "wasm" before script name.
    BOOL isDir = false;
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    for (NSString* path in ios_directoriesInPath()) {
        // If we don't have access to the path component, there's no point in continuing:
        if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) continue;
        if (!isDir) continue; // same in the (unlikely) event the path component is not a directory
        // search for 3 possibilities: name, name.wasm3 and name.wasm
        NSString* locationName;
        NSString* locationNameBasis = [path stringByAppendingPathComponent:scriptName];
        bool fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationNameBasis isDirectory:&isDir];
        fileFound = fileFound && !isDir;
        if (fileFound) locationName = locationNameBasis;
        if (!fileFound) {
            locationName = [locationNameBasis stringByAppendingString:@".wasm3"];
            fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
            fileFound = fileFound && !isDir;
        }
        if (!fileFound) {
            locationName = [locationNameBasis stringByAppendingString:@".wasm"];
            fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
            fileFound = fileFound && !isDir;
        }
        if (!fileFound) continue;
        // isExecutableFileAtPath replies "NO" even if file has x-bit set.
        // if (![fileManager  isExecutableFileAtPath:cmdname]) continue;
        struct stat sb;
        // Files inside the Application Bundle will always have "x" removed. Don't check.
        if (!([path containsString: [[NSBundle mainBundle] resourcePath]]) // Not inside the App Bundle
            && !((stat(locationName.UTF8String, &sb) == 0))) // file exists, is not a directory
            continue;
        // At this point the file exists, is a file.
        if (!isRealCommand(locationName.UTF8String)) // if it's one of our fake commands, search is over.
            return NULL;
        NSData *data = [NSData dataWithContentsOfFile:locationName]; // You have the data. Conversion to String probably failed.
        NSString *fileContent = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
        if ((fileContent == nil) && (data.length > 0)) {
            // Conversion to string failed with UTF8. Try with Ascii as a backup:
            fileContent =  [[NSString alloc]initWithData:data encoding:NSASCIIStringEncoding];
        }
        NSString* signature;
        // Detect WebAssembly file signature: '\0asm' (begins with 0, so not a string)
        if ((data.length >0) && (((char*)data.bytes)[0] == 0)) {
            // fileContent = [[NSString alloc]initWithData:data encoding:NSASCIIStringEncoding];
            NSRange signatureRange = NSMakeRange(1, 3);
            signature = [fileContent substringWithRange:signatureRange];
        }
        if ([signature isEqualToString:@"asm"]) {
            return [@"wasm " stringByAppendingString:locationName];
        }
    }
    // We didn't find anything, no change to scriptName
    return NULL;
}


// ios_system_command_line retains the historical command resolver. Public
// callers enter it through ios_system(argc, argv), which supplies an explicit
// argument vector and bypasses all command-line tokenization and expansion.
// ios_system_osh is the only public API that accepts shell text.
static __thread int ios_direct_argc = 0;
static __thread const char *const *ios_direct_argv = NULL;

int ios_system(int argc, const char* const argv[]) {
    if (argc <= 0 || argv == NULL || argv[0] == NULL || argv[0][0] == 0) {
        errno = EINVAL;
        return EINVAL;
    }
    for (int i = 0; i < argc; i++) {
        if (argv[i] == NULL) {
            errno = EINVAL;
            return EINVAL;
        }
    }
    // A cancelled shell job starts no further commands. The flag stays set
    // until the outermost shell exits, so a nested shell starting here cannot
    // consume it and let the enclosing shell continue.
    if (currentSession != NULL &&
        atomic_load_explicit(
            &currentSession->shellCommandRunning,
            memory_order_acquire) &&
        atomic_load_explicit(
            &currentSession->cancellationRequested,
            memory_order_acquire)) {
        currentSession->global_errno = 130;
        return 130;
    }

    int previousArgc = ios_direct_argc;
    if (currentSession != NULL && !atomic_load_explicit(
            &currentSession->shellCommandRunning, memory_order_acquire)) {
        // A new top-level command. On a reused session, earlier cancellation
        // requests were for earlier commands. A session that runs one job keeps
        // them, so a job cancelled at any point starts no further commands.
        if (!currentSession->keepsCancellationRequests) {
            atomic_store_explicit(&currentSession->commandCancellationRequested, false, memory_order_seq_cst);
        } else if (atomic_load_explicit(
                       &currentSession->commandCancellationRequested,
                       memory_order_seq_cst)) {
            currentSession->global_errno = 130;
            return 130;
        }
    }
    const char *const *previousArgv = ios_direct_argv;
    bool previousIsMainThread = currentSession != NULL ? currentSession->isMainThread : true;
    pthread_t previousRootThread =
        currentSession != NULL ? currentSession->current_command_root_thread : NULL;
    pthread_t previousPthreadCancelableRootCommand = currentSession != NULL
        ? atomic_load_explicit(
            &currentSession->pthreadCancelableRootCommand,
            memory_order_acquire)
        : NULL;
    if (currentSession != NULL) currentSession->isMainThread = true;
    ios_direct_argc = argc;
    ios_direct_argv = argv;
    int status = ios_system_command_line(argv[0]);
    ios_direct_argc = previousArgc;
    ios_direct_argv = previousArgv;
    if (currentSession != NULL) {
        currentSession->isMainThread = previousIsMainThread;
        atomic_store_explicit(
            &currentSession->pthreadCancelableRootCommand,
            previousPthreadCancelableRootCommand,
            memory_order_release);
        currentSession->current_command_root_thread = previousRootThread;
    }
    return status;
}

static int ios_system_command_line(const char* inputCmd) {
    bool hasDirectArguments = ios_direct_argv != NULL;
    NSLog(@"command = %s pid= %d\n", inputCmd, ios_currentPid());

    char* command;
    // The names of the files for stdin, stdout, stderr
    char* inputFileName = 0;
    char* outputFileName = 0;
    char* errorFileName = 0;
    // Where the symbols "<", ">" or "2>" were.
    // to be replaced by 0x0 later.
    char* outputFileMarker = 0;
    char* inputFileMarker = 0;
    char* errorFileMarker = 0;
    char* scriptName = 0; // interpreted commands
    bool  sharedErrorOutput = false;
    // NSFileManager *fileManager = [[NSFileManager alloc] init];
    // if (fileManager == NULL) return 0; // for stability, early commands don't have it.
    // NSLog(@"ios_system, stdout %d \n", thread_stdout == NULL ? 0 : fileno(thread_stdout));
    // NSLog(@"ios_system, stderr %d \n", thread_stderr == NULL ? 0 : fileno(thread_stderr));
    if (currentSession == NULL) {
        currentSession = malloc(sizeof(sessionParameters));
        initSessionParameters(currentSession);
    }
    currentSession->global_errno = 0;
    NSLog(@"Starting command: %s currentSession->isMainThread: %d", inputCmd, currentSession->isMainThread);
    // Don't start if the command is NULL:
    if (inputCmd == NULL) {
        ios_storeThreadId(0);
        return 0;
    }

    // initialize:
    if (thread_stdin == 0) thread_stdin = currentSession->stdin;
    if (thread_stdout == 0) thread_stdout = currentSession->stdout;
    if (thread_stderr == 0) thread_stderr = currentSession->stderr;
    if (thread_context == 0) thread_context = currentSession->context;

    char* cmd = strdup(inputCmd);
    char* maxPointer = cmd + strlen(cmd);
    char* originalCommand = cmd;
    // fprintf(thread_stderr, "Command sent: %s \n", cmd); fflush(stderr);
    if (!hasDirectArguments && cmd[0] == '"') {
        // Command was enclosed in quotes (almost always with Vim)
        // It can also be the executable enclose in quotes
        char* endCmd = strstr(cmd + 1, "\""); // find closing quote
        if (endCmd) {
            cmd = cmd + 1; // remove starting quote
            endCmd[0] = ' ';
            assert(endCmd < maxPointer);
        }
        // assert(cmd + strlen(cmd) < maxPointer);
    }
    if (!hasDirectArguments && cmd[0] == '(') {
        // Standard vim encoding: command between parentheses
        command = cmd + 1;
        char* endCmd = strstrquoted(command, ")"); // remove closing parenthesis
        if (endCmd) {
            endCmd[0] = ' ';
            assert(endCmd < maxPointer);
            // inputFileMarker = endCmd + 1;
        }
    } else command = cmd;
    // fprintf(thread_stderr, "Command sent: %s \n", command);
    // Environment variables before alias expansion:
    if (!hasDirectArguments) {
        char* commandForParsing = strdup(command);
        char* commandForParsingFree = commandForParsing;
        char* firstSpace = strstrquoted(commandForParsing, " ");
        while (firstSpace != NULL) {
            *firstSpace = 0;
            char* equalSign = strchr(commandForParsing, '=');
            if (equalSign == NULL) break;
            *equalSign = 0;
            ios_setenv(commandForParsing, equalSign+1, 1);
            command += (firstSpace - commandForParsing) + 1;
            commandForParsing = firstSpace + 1;
            firstSpace = strstrquoted(commandForParsing, " ");
        }
        free(commandForParsingFree);
    }
    // Is the command an environment variable?
    if (!hasDirectArguments && command[0] == '$') {
        const char* newName = ios_getenv(command + 1);
        if (newName != NULL) {
            free(originalCommand);
            originalCommand = strdup(newName);
            cmd = originalCommand;
            command = originalCommand;
        }
    }
    // alias expansion *before* input, output and error redirection.
    if (!hasDirectArguments && (command[0] != '\\') && (aliasDictionary != nil)) {
        // \command = cancel aliasing, get the original command
        char* commandForParsing = strdup(command);
        char* firstSpace = strstrquoted(commandForParsing, " ");
        if (firstSpace != NULL) { *firstSpace = 0; }
        NSString* commandAsString = [NSString stringWithCString:commandForParsing encoding:NSUTF8StringEncoding];
        NSArray<NSString*>* aliasedCommand = aliasDictionary[commandAsString];
        if (aliasedCommand != nil) {
            NSLog(@"%s %s %s", aliasedCommand[0].UTF8String, aliasedCommand[1].UTF8String, aliasedCommand[2].UTF8String);
            char* newCommand = NULL;
            if (aliasedCommand[2].length == 0) {
                // all the alias, then all the arguments:
                if (firstSpace == NULL) {
                    newCommand = strdup(aliasedCommand[0].UTF8String);
                } else {
                    unsigned long newCommandLength = aliasedCommand[0].length + 2 + strlen(firstSpace+1);
                    // + 2: 1 for space, 1 for NULL termination
                    newCommand = malloc(newCommandLength * sizeof(char));
                    sprintf(newCommand, "%s %s", aliasedCommand[0].UTF8String, firstSpace+1);
                }
            } else if ([aliasedCommand[2] isEqualToString: @"afterLast"]) {
                unsigned long newCommandLength = aliasedCommand[0].length + 2 + aliasedCommand[1].length;
                // + 2: 1 for space, 1 for NULL termination
                if (firstSpace == NULL) { // no arguments
                    newCommand = malloc(newCommandLength * sizeof(char));
                    sprintf(newCommand, "%s %s", aliasedCommand[0].UTF8String, aliasedCommand[1].UTF8String);
                } else {
                    newCommandLength += strlen(firstSpace+1) + 1; // 1 more space
                    newCommand = malloc(newCommandLength * sizeof(char));
                    sprintf(newCommand, "%s %s %s", aliasedCommand[0].UTF8String, firstSpace+1, aliasedCommand[1].UTF8String);
                }
            } else if ([aliasedCommand[2] isEqualToString: @"afterFirst"]) {
                unsigned long newCommandLength = aliasedCommand[0].length + 2 + aliasedCommand[1].length;
                // + 2: 1 for space, 1 for NULL termination
                if (firstSpace == NULL) { // no arguments
                    newCommand = malloc(newCommandLength * sizeof(char));
                    sprintf(newCommand, "%s %s", aliasedCommand[0].UTF8String, aliasedCommand[1].UTF8String);
                } else {
                    char* arguments = firstSpace + 1;
                    char* secondSpace = strstrquoted(arguments, " ");
                    if (secondSpace == NULL) {
                        // only 1 argument, nothing after that:
                        newCommandLength += strlen(arguments) + 1; // 1 more space
                        newCommand = malloc(newCommandLength * sizeof(char));
                        sprintf(newCommand, "%s %s %s", aliasedCommand[0].UTF8String, arguments, aliasedCommand[1].UTF8String);
                    } else {
                        *secondSpace = 0;
                        char* otherArguments = secondSpace + 1;
                        newCommandLength += strlen(arguments) + strlen(otherArguments) + 2; // 2 more spaces
                        newCommand = malloc(newCommandLength * sizeof(char));
                        sprintf(newCommand, "%s %s %s %s", aliasedCommand[0].UTF8String, arguments, aliasedCommand[1].UTF8String, otherArguments);
                    }
                }
            }
            if (newCommand != NULL) {
                free(originalCommand);
                // After alias expansion, the new command replaces the old one:
                originalCommand = newCommand;
                cmd = newCommand;
                command = newCommand;
            }
        }
        free(commandForParsing);
    }
    // Maybe we aliased to an interactive command (vim, ssh, less, more, man, scp, sftp)
    // We need to tell the command line editor:
    if (isInteractive(command)) {
        ios_startInteractive();
    }
    // NSLog(@"command after alias expansion= %s\n", command);
    // Search for input, output and error redirection
    // They can be in any order, although the usual are:
    // command < input > output 2> error, command < input > output 2>&1 or command < input >& output
    // The last two are equivalent. Vim prefers the second.
    // Search for input file "< " and output file " >"
    if (!inputFileMarker) inputFileMarker = command;
    outputFileMarker = inputFileMarker;
    functionParameters *params = (functionParameters*) malloc(sizeof(functionParameters));
    if (params == NULL) {
        NSLog(@"Unable to allocate params in ios_system");
        return -1;
    }
    // If child_streams have been defined (in dup2 or popen), the new thread takes them.
    params->stdin = child_stdin;
    params->stdout = child_stdout;
    params->stderr = child_stderr;
    params->ownsStdin = ios_isOwnedChildStream(params->stdin);
    params->ownsStdout =
        ios_isOwnedChildStream(params->stdout) &&
        params->stdout != params->stdin;
    params->ownsStderr =
        ios_isOwnedChildStream(params->stderr) &&
        params->stderr != params->stdin &&
        params->stderr != params->stdout;
    params->session = currentSession;
    params->processId = ios_currentPid();
    NSLog(@"After params creation, stdout %p stderr %p \n", (void *)params->stdout,  (void *)params->stderr);
    params->backgroundCommand = isBackgroundCommand(command);
    params->numInterpreter = 0;

    params->context = thread_context;
    params->commandContext = NULL;
  
    child_stdin = child_stdout = child_stderr = NULL;
    params->argc = 0; params->argv = 0; params->argv_ref = 0;
    params->function = NULL; params->isPipeOut = false; params->isPipeErr = false;
    // Only scan for input / output if there is no argument marker
    char recordSeparator = 0x1e;
    char* recordSeparatorPosition =
        hasDirectArguments ? inputFileMarker : strchr(inputFileMarker, recordSeparator);
    if (recordSeparatorPosition == NULL) {
        // scan until first "<" (input file)
        inputFileMarker = strstrquoted(inputFileMarker, "<");
        // scan until first non-space character:
        if (inputFileMarker) {
            if ((strlen(inputFileMarker) > 1) && (inputFileMarker[1] == '=')) {
                // >= (used by pip install, e.g. "setuptools<=56"
                // This is very specific. pip needs it, other commands act differently.
                char* doubleDashMarker = strstrquoted(command, " -- ");
                // Is there a double dash before the ">="? If not keep going.
                if (!doubleDashMarker || (doubleDashMarker > inputFileMarker)) {
                    inputFileName = inputFileMarker + 1; // skip past '<'
                }
            } else {
                inputFileName = inputFileMarker + 1; // skip past '<'
            }
            if (inputFileName) {
                // skip past all spaces
                while ((inputFileName[0] == ' ') && strlen(inputFileName) > 0) inputFileName++;
            }
        }
        // is there a pipe ("|", "&|" or "|&")
        // We assume here a logical command order: < before pipe, pipe before >.
        // TODO: check what happens for unlogical commands. Refuse them, but gently.
        // TODO: implement tee, because that has been removed
        char* pipeMarker = strstrquoted(outputFileMarker,"&|");
        if (!pipeMarker) pipeMarker = strstrquoted(outputFileMarker,"|&"); // both seem to work
        if (pipeMarker) {
            bool pushMainThread = currentSession->isMainThread;
            currentSession->isMainThread = false;
            if (params->stdout != 0) thread_stdout = params->stdout;
            if (params->stderr != 0) thread_stderr = params->stderr;
            // if popen fails, don't start the command
            params->stdout = ios_popen(pipeMarker+2, "w");
            params->stderr = params->stdout;
            currentSession->isMainThread = pushMainThread;
            pipeMarker[0] = 0x0;
            sharedErrorOutput = true;
            if (params->stdout == NULL) { // pipe open failed, return before we start a command
                NSLog(@"Failed launching pipe for %s\n", pipeMarker+2);
                ios_storeThreadId(0);
                free(params);
                free(originalCommand); // releases cmd, which was a strdup of inputCommand
                return currentSession->global_errno;
            }
        } else {
            pipeMarker = strstrquoted(outputFileMarker,"|");
            if (pipeMarker) {
                bool pushMainThread = currentSession->isMainThread;
                currentSession->isMainThread = false;
                if (params->stdout != 0) thread_stdout = params->stdout;
                if (params->stderr != 0) thread_stderr = params->stderr; // ?????
                // if popen fails, don't start the command
                params->stdout = ios_popen(pipeMarker+1, "w");
                currentSession->isMainThread = pushMainThread;
                pipeMarker[0] = 0x0;
                if (params->stdout == NULL) { // pipe open failed, return before we start a command
                    NSLog(@"Failed launching pipe for %s\n", pipeMarker+1);
                    ios_storeThreadId(0);
                    free(params);
                    free(originalCommand); // releases cmd, which was a strdup of inputCommand
                    return currentSession->global_errno;
                }
            }
        }
        // We have removed the pipe part. Still need to parse the rest of the command
        // Must scan in strstr by reverse order of inclusion. So "2>&1" before "2>" before ">"
        errorFileMarker = strstrquoted(outputFileMarker,"&>"); // both stderr/stdout sent to same file
        // output file name will be after "&>"
        if (errorFileMarker) { outputFileName = errorFileMarker + 2; outputFileMarker = errorFileMarker; }
        if (!errorFileMarker) {
            // TODO: 2>&1 before > means redirect stderr to (current) stdout, then redirects stdout
            // ...except with a pipe.
            // Currently, we don't check for that.
            errorFileMarker = strstrquoted(outputFileMarker,"2>&1"); // both stderr/stdout sent to same file
            if (errorFileMarker) {
                outputFileName = NULL;
                if (params->stdout) params->stderr = params->stdout;
                outputFileMarker = strstrquoted(outputFileMarker, ">");
                if (outputFileMarker - errorFileMarker == 1) // the first '>' was the one from '2>&1'
                    outputFileMarker = strstrquoted(outputFileMarker + 2, ">"); // is there one after that?
                if (outputFileMarker)
                    outputFileName = outputFileMarker + 1; // skip past '>'
            }
        }
        if (errorFileMarker) { sharedErrorOutput = true; }
        else {
            // specific name for error file?
            errorFileMarker = strstrquoted(outputFileMarker,"2>");
            if (errorFileMarker) {
                errorFileName = errorFileMarker + 2; // skip past "2>"
                // skip past all spaces:
                while ((errorFileName[0] == ' ') && strlen(errorFileName) > 0) errorFileName++;
            }
        }
        // scan until first ">"
        bool appendToFileName = false;
        if (!sharedErrorOutput) {
            // output and append.
            outputFileMarker = strstrquoted(outputFileMarker, ">");
            if (outputFileMarker) {
                if ((strlen(outputFileMarker) > 1) && (outputFileMarker[1] == '>')) { // >>
                    outputFileName = outputFileMarker + 2; // skip past ">>"
                    appendToFileName = true;
                } else if ((strlen(outputFileMarker) > 1) && (outputFileMarker[1] == '=')) {
                    // >= (used by pip install, e.g. "setuptools>=56,!=61.0.0"
                    // This is very specific. pip needs it, other commands act differently.
                    char* doubleDashMarker = strstrquoted(command, " -- ");
                    // Is there a double dash before the ">="? If not keep going.
                    if (!doubleDashMarker || (doubleDashMarker > outputFileMarker)) {
                        outputFileName = outputFileMarker + 1; // skip past '>'
                    } // Otherwise do nothing
                } else {
                    outputFileName = outputFileMarker + 1; // skip past '>'
                }
            }
        } else {
            if (outputFileName == NULL)
                outputFileMarker = NULL;
        }
        if (outputFileName) {
            while ((outputFileName[0] == ' ') && strlen(outputFileName) > 0) outputFileName++;
        }
        if (errorFileName && (outputFileName == errorFileName)) {
            // we got the same ">" twice, pick the next one ("2>" was before ">")
            outputFileMarker = errorFileName;
            outputFileMarker = strstrquoted(outputFileMarker, ">");
            if (outputFileMarker) {
                if ((strlen(outputFileMarker) > 1) && (outputFileMarker[1] == '>')) { // >>
                    outputFileName = outputFileMarker + 2; // skip past ">>"
                    appendToFileName = true;
                } else {
                    outputFileName = outputFileMarker + 1; // skip past '>'
                }
                while ((outputFileName[0] == ' ') && strlen(outputFileName) > 0) outputFileName++;
            } else outputFileName = NULL; // Only "2>", but no ">". It happens.
        }
        if (outputFileName) {
            char* endFile = getLastCharacterOfArgument(outputFileName);
            if (endFile) endFile[0] = 0x00; // end output file name at first space
            assert(endFile <= maxPointer);
        }
        if (inputFileName) {
            char* endFile = getLastCharacterOfArgument(inputFileName);
            if (endFile) endFile[0] = 0x00; // end input file name at first space
            assert(endFile <= maxPointer);
        }
        if (errorFileName) {
            char* endFile = getLastCharacterOfArgument(errorFileName);
            if (endFile) endFile[0] = 0x00; // end error file name at first space
            assert(endFile <= maxPointer);
        }
        // insert chain termination elements at the beginning of each filename.
        // Must be done after the parsing.
        if (inputFileMarker) inputFileMarker[0] = 0x0;
        // There was a test " && (params->stdout == NULL)" below. Why?
        if (outputFileMarker) outputFileMarker[0] = 0x0; // There
        if (errorFileMarker) errorFileMarker[0] = 0x0;
        // strip filenames of quotes, if any:
        if (outputFileName) outputFileName = unquoteArgument(outputFileName);
        if (inputFileName) inputFileName = unquoteArgument(inputFileName);
        if (errorFileName) errorFileName = unquoteArgument(errorFileName);
        //
        FILE* newStream;
        if (inputFileName) {
            newStream = fopen(ios_expandFilename(inputFileName), "r");
            if (newStream) params->stdin = newStream;
        }
        if (params->stdin == NULL) params->stdin = thread_stdin;
        if (outputFileName) {
            if (appendToFileName) {
                newStream = fopen(ios_expandFilename(outputFileName), "a"); // append
            } else {
                newStream = fopen(ios_expandFilename(outputFileName), "w");
            }
            NSLog(@"Opened %s as output file: %p", outputFileName, (void *)newStream);
            if (newStream) {
                if (params->stdout != NULL) {
                    if (fileno(params->stdout) != fileno(currentSession->stdout)) fclose(params->stdout);
                }
                params->stdout = newStream;
            }
        }
        if (params->stdout == NULL) params->stdout = thread_stdout;
        if (sharedErrorOutput && (params->stderr != params->stdout)) {
            if (params->stderr != NULL) {
                if (fileno(params->stderr) != fileno(currentSession->stderr)) fclose(params->stderr);
            }
            params->stderr = params->stdout;
        }
        else if (errorFileName) {
            newStream = NULL;
            newStream = fopen(ios_expandFilename(errorFileName), "w");
            if (newStream) {
                if (params->stderr != NULL) {
                    if (fileno(params->stderr) != fileno(currentSession->stderr)) fclose(params->stderr);
                }
                params->stderr = newStream;
            }
        }
        if (params->stderr == NULL) params->stderr = thread_stderr;
    } // recordSeparator != NULL
    if (params->stdin == NULL) params->stdin = thread_stdin;
    if (params->stdout == NULL) params->stdout = thread_stdout;
    if (params->stderr == NULL) params->stderr = thread_stderr;
    NSLog(@"After files parsing, stdout %p stderr %p \n", (void *)params->stdout,  (void *)params->stderr);
    int argc = 0;
    char** argv = NULL;
    bool* dontExpand = NULL;
    if (hasDirectArguments) {
        argc = ios_direct_argc;
        argv = (char **)malloc(sizeof(char*) * (argc + 1));
        if (argv != NULL) {
            for (int i = 0; i < argc; i++) {
                argv[i] = strdup(ios_direct_argv[i]);
                if (argv[i] == NULL) {
                    for (int j = 0; j < i; j++) free(argv[j]);
                    free(argv);
                    argv = NULL;
                    break;
                }
            }
            if (argv != NULL) argv[argc] = NULL;
        }
        if (argv == NULL) {
            free(params);
            free(originalCommand);
            currentSession->global_errno = ENOMEM;
            return ENOMEM;
        }
    } else {
        size_t numSpaces = 0;
        // the number of arguments is *at most* the number of spaces plus one
        char* str = command;
        while(*str) if (*str++ == ' ') ++numSpaces;
        argv = (char **)malloc(sizeof(char*) * (numSpaces + 2));
        dontExpand = malloc(sizeof(bool) * (numSpaces + 2));
        // n spaces = n+1 arguments, plus null at the end
        str = command;
        while (*str) {
            argv[argc] = str;
            dontExpand[argc] = false;
            argc += 1;
            if ((argc == 2) && (strcmp(argv[0], "export") == 0)) break; // don't try to unquote the argument of export.
            if ((argc == 2) && (strcmp(argv[0], "alias") == 0)) {
                // avoid issues with the syntax alias thing="other ~stuff", where ~stuff gets expanded.
                // We do that by changing it into alias thing "other ~stuff"
                char* equalSignPosition = strchr(str, '=');
                char* spacePosition = strchr(str, ' ');
                if ((spacePosition != NULL) && (equalSignPosition != NULL)) {
                    // There is both a space and an equal sign
                    if (spacePosition > equalSignPosition) {
                        // the space happens after the equal sign
                        *equalSignPosition = ' ';
                    }
                }
            }
            char* end = getLastCharacterOfArgument(str);
            bool mustBreak = (end == NULL) || (strlen(end) == 0);
            if (!mustBreak) end[0] = 0x0;
            if ((str[0] == '\'') || (str[0] == '"') || (str[0] == recordSeparator)) {
                dontExpand[argc-1] = true; // don't expand arguments in quotes
            }
            argv[argc-1] = unquoteArgument(argv[argc-1]);
            if (mustBreak) break;
            str = end + 1;
            assert(argc < numSpaces + 2);
            while (str && (str[0] == ' ')) str++; // skip multiple spaces
        }
        argv[argc] = NULL;
    }
    if (argc != 0) {
        if (!hasDirectArguments) {
            // So far, all arguments are pointers into originalCommand.
            // Duplicate them before the resolver or embedded commands mutate argv.
            char** argv_copy = (char **)malloc(sizeof(char*) * (argc + 1));
            for (int i = 0; i < argc; i++) argv_copy[i] = strdup(argv[i]);
            argv_copy[argc] = NULL;
            free(argv);
            argv = argv_copy;
            // Legacy command-line callers expand variables, tildes, and globs here.
            for (int i = 1; i < argc; i++) if (!dontExpand[i]) {  argv[i] = parseArgument(argv[i], argv[0]); }
            for (int i = 1; i < argc; i++) if (!dontExpand[i]) {
                if (strstrquoted (argv[i],"*") || strstrquoted (argv[i],"?") || strstrquoted (argv[i],"[")) {
                    glob_t gt;
                    if (glob(argv[i], 0, NULL, &gt) == 0) {
                        argc += gt.gl_matchc - 1;
                        argv = (char **)realloc(argv, sizeof(char*) * (argc + 1));
                        dontExpand = (bool *)realloc(dontExpand, sizeof(bool) * (argc + 1));
                        // Move everything after i by gt.gl_matchc - 1 steps up:
                        for (int j = argc; j - gt.gl_matchc + 1 > i; j--) {
                            argv[j] = argv[j - gt.gl_matchc + 1];
                            dontExpand[j] = dontExpand[j - gt.gl_matchc + 1];
                        }
                        for (int j = 0; j < gt.gl_matchc; j++) {
                            argv[i + j] = strdup(gt.gl_pathv[j]);
                        }
                        i += gt.gl_matchc - 1;
                        globfree(&gt);
                    } else {
                        // If there is no match, leave parameter as is.
                        globfree(&gt);
                    }
                }
            }
            free(dontExpand);
        }
        //
        // NH, TODO: this is probably the place where we separate between parsing the command (above) and execv (below)
        // ios_execv(argv[0], argv);
        // Now call the actual command:
        // - is argv[0] a command that refers to a file? (either absolute path, or in $PATH)
        //   if so, does it exist, does it have +x bit set, does it have #! python or #! lua on the first line?
        //   if yes to all, call the relevant interpreter. Works for hg, for example.
        if (argv[0][0] == '\\') {
            // Just remove the \ at the beginning
            // There can be several versions of a command (e.g. ls as precompiled and ls written in Python)
            // The executable file has precedence, unless the user has specified they want the original
            // version, by prefixing it with \. So "\ls" == always "our" ls. "ls" == maybe ~/Library/bin/ls
            // (if it exists).
            // It also cancels aliases.
            size_t len_with_terminator = strlen(argv[0] + 1) + 1;
            memmove(argv[0], argv[0] + 1, len_with_terminator);
        } else  {
            NSString* commandName = [NSString stringWithCString:argv[0]  encoding:NSUTF8StringEncoding];
            const ios_command_entry *virtualCommand = ios_command_lookup_virtual_path(argv[0]);
            if (virtualCommand != NULL) {
                argv[0] = realloc(argv[0], strlen(virtualCommand->name) + 1);
                strcpy(argv[0], virtualCommand->name);
                commandName = [NSString stringWithUTF8String:virtualCommand->name];
            }
            // strcpy(currentSession->commandName, argv[0]);
            // store into heap:
            if ((currentSession->numCommand <= 0) && (strlen(currentSession->commandName[0]) == 0)) {
                strcpy(currentSession->commandName[0], argv[0]);
                currentSession->numCommand = 1;
            } else {
                if (currentSession->numCommand >= currentSession->numCommandsAllocated) {
                    int oldCommandsAllocated = currentSession->numCommandsAllocated;
                    currentSession->numCommandsAllocated += 10;
                    currentSession->commandName = realloc(currentSession->commandName, sizeof(char*) * currentSession->numCommandsAllocated);
                    for (int i = oldCommandsAllocated; i < currentSession->numCommandsAllocated; i++) {
                        currentSession->commandName[i] = malloc(sizeof(char) * NAME_MAX);
                    }
                }
                strcpy(currentSession->commandName[currentSession->numCommand], argv[0]);
                currentSession->numCommand += 1;
            }
            BOOL isDir = false;
            bool cmdIsAFile = false;
            bool cmdIsReal = false;
            bool cmdIsAPath = false;
            if ([commandName hasPrefix:@"~/"]) {
                NSString* replacement_string = [NSString stringWithCString:(getenv("HOME")) encoding:NSUTF8StringEncoding];
                NSString* test_string = @"~";
                commandName = [commandName stringByReplacingOccurrencesOfString:test_string withString:replacement_string options:NULL range:NSMakeRange(0, 1)];
            }
            if ([NSFileManager.defaultManager fileExistsAtPath:commandName isDirectory:&isDir]  && (!isDir)) {
                // File exists, is a file.
                struct stat sb;
                if (stat(commandName.UTF8String, &sb) == 0) {
                    // File exists, is executable, not a directory.
                    cmdIsAFile = true;
                    // We can hexitexitave an empty file with the same name in the path, to fool which():
                    // We can also have a Mach-O binary with the same name in the path (in simulator, mostly)
                    cmdIsReal = isRealCommand(commandName.UTF8String);
                }
            }
            // if commandName contains "/", then it's a path, and we don't search for it in PATH.
            cmdIsAPath = ([commandName rangeOfString:@"/"].location != NSNotFound);
            if (!cmdIsAPath || cmdIsAFile) {
                // We go through the path, because that command may be a file in the path
                for (NSString* path in ios_directoriesInPath()) {
                    if (!cmdIsAFile && ios_command_is_virtual_bin_path(path.UTF8String)) {
                        const ios_command_entry *entry = ios_command_lookup(commandName.UTF8String);
                        if (entry != NULL) {
                            break;
                        }
                        continue;
                    }
                    // If we don't have access to the path component, there's no point in continuing:
                    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) continue;
                    if (!isDir) continue; // same in the (unlikely) event the path component is not a directory
                    NSString* locationName;
                    if (!cmdIsAFile) {
                        // search for 4 possibilities: name, name.bc, name.ll and name.wasm
                        NSString* locationNameBasis = [path stringByAppendingPathComponent:commandName];
                        bool fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationNameBasis isDirectory:&isDir];
                        fileFound = fileFound && !isDir;
                        if (fileFound) locationName = locationNameBasis;
                        if (enableLLVMInterpreter) {
                            if (!fileFound) {
                                locationName = [locationNameBasis stringByAppendingString:@".bc"];
                                fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
                                fileFound = fileFound && !isDir;
                            }
                            if (!fileFound) {
                                locationName = [locationNameBasis stringByAppendingString:@".ll"];
                                fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
                                fileFound = fileFound && !isDir;
                            }
                        }
                        if (!fileFound) {
                            locationName = [locationNameBasis stringByAppendingString:@".wasm3"];
                            fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
                            fileFound = fileFound && !isDir;
                        }
                        if (!fileFound) {
                            locationName = [locationNameBasis stringByAppendingString:@".wasm"];
                            fileFound = [NSFileManager.defaultManager fileExistsAtPath:locationName isDirectory:&isDir];
                            fileFound = fileFound && !isDir;
                        }
                        if (!fileFound) continue;
                        // isExecutableFileAtPath replies "NO" even if file has x-bit set.
                        // if (![fileManager  isExecutableFileAtPath:cmdname]) continue;
                        struct stat sb;
                        // Files inside the Application Bundle will always have "x" removed. Don't check.
                        if (!([path containsString: [[NSBundle mainBundle] resourcePath]]) // Not inside the App Bundle
                            && !((stat(locationName.UTF8String, &sb) == 0))) // file exists, is not a directory
                            continue;
                    } else
                        // if (cmdIsAFile) we are now ready to execute this file:
                        locationName = commandName;
                    if (enableLLVMInterpreter && (([locationName hasSuffix:@".bc"]) || ([locationName hasSuffix:@".ll"]))) {
                        // CLANG bitcode. insert lli in front of argument list:
                        argc += 1;
                        argv = (char **)realloc(argv, sizeof(char*) * argc);
                        // Move everything one step up
                        for (int i = argc; i >= 1; i--) { argv[i] = argv[i-1]; }
                        argv[1] = realloc(argv[1], locationName.length + 1);
                        strcpy(argv[1], locationName.UTF8String);
                        argv[0] = strdup("lli"); // this argument is new
                        break;
                    } else if ([locationName hasSuffix:@".wasm"]) {
                        // insert wasm in front of argument list:
                        argc += 1;
                        argv = (char **)realloc(argv, sizeof(char*) * (argc + 1));
                        // Move everything one step up
                        for (int i = argc-1; i >= 1; i--) { argv[i] = argv[i-1]; }
                        argv[1] = realloc(argv[1], locationName.length + 1);
                        strcpy(argv[1], locationName.UTF8String);
                        argv[0] = strdup("wasm"); // this argument is new
                        break;
                    } else if ([locationName hasSuffix:@".wasm3"]) {
                        // insert wasm3 in front of argument list:
                        // wasm3 is a WebAssembly interpreter that is faster than wasm, but does not handle exceptions or setjmp.
                        argc += 1;
                        argv = (char **)realloc(argv, sizeof(char*) * (argc + 1));
                        // Move everything one step up
                        for (int i = argc-1; i >= 1; i--) { argv[i] = argv[i-1]; }
                        argv[1] = realloc(argv[1], locationName.length + 1);
                        strcpy(argv[1], locationName.UTF8String);
                        argv[0] = strdup("wasm3"); // this argument is new
                        break;
                    } else {
                        if (isRealCommand(locationName.UTF8String)) {
                            cmdIsReal = true;
                            NSData *data = [NSData dataWithContentsOfFile:locationName]; // You have the data. Conversion to String probably failed.
                            NSString *fileContent = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
                            if ((fileContent == nil) && (data.length > 0)) {
                                // Conversion to string failed with UTF8. Try with Ascii as a backup:
                                fileContent =  [[NSString alloc]initWithData:data encoding:NSASCIIStringEncoding];
                            }
                            NSString* firstLine;
                            if (fileContent != nil) {
                                NSRange firstLineRange = [fileContent rangeOfString:@"\n"];
                                if (firstLineRange.length > 0) {
                                    firstLineRange.length = firstLineRange.location;
                                } else {
                                    firstLineRange.length = fileContent.length;
                                }
                                firstLineRange.location = 0;
                                firstLine = [fileContent substringWithRange:firstLineRange];
                            }
                            if ([firstLine hasPrefix:@"#!"]) {
                                // 1) get script language name
                                // The last word of the line is the command. This covers all of the cases encountered:
                                // "#! /usr/bin/python", "#! /usr/local/bin/python" and "#! /usr/bin/myStrangePath/python" are all OK.
                                // We also accept "#! /usr/bin/env python" because it is used.
                                // And we want to accept "#! bc -l" too, so we can have multiple arguments.
                                // Take alphanumericCharacterSet and invert it.
                                firstLine = [firstLine substringFromIndex:2]; // remove "#!" at the beginning
                                firstLine = [firstLine stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]; // remove any extra space
                                
                                NSArray<NSString*> *firstLineComponents = [firstLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                NSMutableArray<NSString*> *components = [firstLineComponents mutableCopy];
                                if ([components.firstObject hasSuffix:@"env"]) {
                                    // /usr/bin/env <command>
                                    [components removeObjectAtIndex:0];
                                }
                                // Extract stript name by removing the path:
                                NSString* scriptNameString = components[0];
                                NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@"/"];
                                NSArray<NSString*> *scriptComponents = [scriptNameString componentsSeparatedByCharactersInSet:separators];
                                scriptNameString = scriptComponents.lastObject;
                                // If scriptNameString is a file that exists in PATH and has webAssembly signature, then insert "wasm script". Other cases?
                                components[0] = scriptNameString;
                                NSString* beforeCommand = beforeScriptCommandName(scriptNameString);
                                if (beforeCommand != NULL) {
                                    [components removeObjectAtIndex:0];
                                    NSArray<NSString*> *newComponents = [beforeCommand componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                    [components insertObjects:newComponents atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newComponents.count)]];
                                }
                                unsigned long numComponents = components.count;
                                if (numComponents > 0) {
                                    // 2) insert all arguments at beginning of argument list:
                                    argc += numComponents;
                                    argv = (char **)realloc(argv, sizeof(char*) * (argc + 1));
                                    // Move everything numComponents step up
                                    for (int i = argc; i >= numComponents; i--) { argv[i] = argv[i-numComponents]; }
                                    // Change the location of the file (from "command" to "/actual/full/path/command"):
                                    // This pointer existed before
                                    argv[numComponents] = realloc(argv[numComponents], locationName.length + 1);
                                    strcpy(argv[numComponents], locationName.UTF8String);
                                    // Copy all arguments without change (except the first):
                                    for (int i = 0; i < numComponents; i++) {
                                        argv[i] = strdup(components[i].UTF8String); // creates new pointers
                                    }
                                    break;
                                }
                            } else {
                                // Detect WebAssembly file signature: '\0asm' (begins with 0, so not a string)
                                if ((data.length >0) && (((char*)data.bytes)[0] == 0)) {
                                    // fileContent = [[NSString alloc]initWithData:data encoding:NSASCIIStringEncoding];
                                    NSRange signatureRange = NSMakeRange(1, 3);
                                    firstLine = [fileContent substringWithRange:signatureRange];
                                }
                                if ([firstLine isEqualToString:@"asm"]) {
                                    // WebAssembly file, identified by signature:
                                    // Same code as above, but single command:
                                    argc += 1;
                                    argv = (char **)realloc(argv, sizeof(char*) * (argc + 1));
                                    // Move everything numComponents step up
                                    for (int i = argc; i >= 1; i--) { argv[i] = argv[i-1]; }
                                    // Change the location of the file (from "command" to "/actual/full/path/command"):
                                    // This pointer existed before
                                    argv[1] = realloc(argv[1], locationName.length + 1);
                                    strcpy(argv[1], locationName.UTF8String);
                                    // Copy all arguments without change (except the first):
                                    argv[0] = strdup("wasm"); // creates new pointer
                                    break;
                                }
                            }
                        } else {
                            cmdIsReal = false;
                        }
                    }
                    if (cmdIsAFile) break; // else keep going through the path elements.
                }
            }
            if (!cmdIsReal || (cmdIsAPath && !cmdIsAFile)) {
                // argv[0] is a file that doesn't exist, or has size 0. Probably one of our commands.
                // Replace with its name:
                // Darwin's basename() shares storage across threads. Keep the
                // resolved name local while pipeline stages resolve in parallel.
                char newName[PATH_MAX];
                if (basename_r(argv[0], newName) != NULL) {
                    // A path component fits in the existing argument allocation.
                    strcpy(argv[0], newName);
                }
            }
        }
        NSLog(@"After command parsing, stdout %p stderr %p \n", (void *)params->stdout,  (void *)params->stderr);
        // This line causes an error, and the previous one is not executed. Recompile.
        // NSLog(@"After command parsing, stdout %d stderr %d \n", fileno(params->stdout),  fileno(params->stderr));
        // fprintf(thread_stderr, "Command after parsing: ");
        // for (int i = 0; i < argc; i++)
        //    fprintf(thread_stderr, "[%s] ", argv[i]);
        // We've reached this point: either the command is a file, from a script we support,
        // and we have inserted the name of the script at the beginning, or it is a builtin command
        int (*function)(int ac, char** av) = NULL;
        if (commandList == nil) initializeCommandList();
        NSString* commandName = [NSString stringWithCString:argv[0] encoding:NSUTF8StringEncoding];
        NSArray* commandStructure = [commandList objectForKey: commandName];
        const ios_command_entry *registeredCommand = ios_command_lookup(argv[0]);
        void* handle = NULL;
        if (registeredCommand != NULL || commandStructure != nil) {
            NSString* libraryName = commandStructure != nil ? commandStructure[0] : @"RUNTIME";
            NSString* functionName = commandStructure != nil ? commandStructure[1] : @"";
            if (registeredCommand != NULL &&
                registeredCommand->library_name != NULL &&
                strcmp(registeredCommand->library_name, "RUNTIME") == 0) {
                function = registeredCommand->function;
            }
            // Python, Perl and TeX can have multiple commands calling themselves:
            // hasPrefix covers python, python3, python3.9.
            if (function != NULL) {
                // Runtime commands are already resolved from their registered function pointer.
            } else if ([commandName hasPrefix: @"python"]) {
                params->numInterpreter = 0;
            } else if ([commandName hasPrefix: @"perl"]) {
                // Ability to start multiple perl scripts (required for cpan):
                // start by increasing the number of the interpreter, until we're out.
                int numInterpreter = 0;
                if (currentPerlInterpreter < numPerlInterpreters) {
                    numInterpreter = currentPerlInterpreter;
                    currentPerlInterpreter++;
                } else {
                    while  (numInterpreter < numPerlInterpreters) {
                        if (PerlIsRunning[numInterpreter] == false) break;
                        numInterpreter++;
                    }
                    if (numInterpreter >= numPerlInterpreters) {
                        display_alert(@"Too many Perl scripts", @"There are too many Perl interpreters running at the same time. Try closing some of them.");
                        NSLog(@"%@", @"Too many perl scripts running simultaneously.\n");
                        function = &too_many_scripts;
                        functionName = @"notAValidCommand";
                        currentSession->global_errno = ENOENT;
                        argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                    }
                }
                if ((numInterpreter >= 0) && (numInterpreter < numPerlInterpreters)) {
                    params->numInterpreter = numInterpreter;
                    PerlIsRunning[numInterpreter] = true;
                    NSLog(@"Starting a Perl interpreter: %d", params->numInterpreter);
                    if (numInterpreter > 0) {
                        char suffix[2];
                        suffix[0] = 'A' + (numInterpreter - 1);
                        suffix[1] = 0;
                        commandName = [@"perl" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                        libraryName = [libraryName stringByReplacingOccurrencesOfString:@"perl" withString:commandName];
                    }
                }
            } else if ([TeXcommands containsObject: commandName]) {
                // It's a TeX command. Ability to start multiple TeX commands (required for Tikz)
                // start by increasing the number of the interpreter, until we're out.
                int numInterpreter = 0;
                if (currentTeXInterpreter < numTeXInterpreters) {
                    numInterpreter = currentTeXInterpreter;
                    currentTeXInterpreter++;
                } else {
                    while  (numInterpreter < numTeXInterpreters) {
                        if (TeXIsRunning[numInterpreter] == false) break;
                        numInterpreter++;
                    }
                    if (numInterpreter >= numTeXInterpreters) {
                        display_alert(@"Too many TeX scripts", @"There are too many TeX interpreters running at the same time. Try closing some of them.");
                        NSLog(@"%@", @"Too many TeX scripts running simultaneously.\n");
                        function = &too_many_scripts;
                        functionName = @"notAValidCommand";
                        currentSession->global_errno = ENOENT;
                        argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                    }
                }
                if ((numInterpreter >= 0) && (numInterpreter < numTeXInterpreters)) {
                    params->numInterpreter = numInterpreter;
                    TeXIsRunning[numInterpreter] = true;
                    if (numInterpreter > 0) {
                        // There are multiple TeX commands, and they can start each other.
                        char suffix[2];
                        suffix[0] = 'A' + (numInterpreter - 1);
                        suffix[1] = 0;
                        // libraryName can be pdftex, luatex or luahbtex:
                        if ([libraryName hasPrefix: @"pdftex"]) {
                            NSString* newName = [@"pdftex" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                            libraryName = [libraryName stringByReplacingOccurrencesOfString:@"pdftex" withString:newName];
                        } else if ([libraryName hasPrefix: @"luatex"]) {
                            NSString* newName = [@"luatex" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                            libraryName = [libraryName stringByReplacingOccurrencesOfString:@"luatex" withString:newName];
                        } else if ([libraryName hasPrefix: @"luahbtex"]) {
                            NSString* newName = [@"luahbtex" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                            libraryName = [libraryName stringByReplacingOccurrencesOfString:@"luahbtex" withString:newName];
                        } else if ([libraryName hasPrefix: @"xetex"]) {
                            NSString* newName = [@"xetex" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                            libraryName = [libraryName stringByReplacingOccurrencesOfString:@"xetex" withString:newName];
                        } else if ([libraryName hasPrefix: @"xdvipdfmx"]) {
                            NSString* newName = [@"xdvipdfmx" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                            libraryName = [libraryName stringByReplacingOccurrencesOfString:@"xdvipdfmx" withString:newName];
                        }
                    }
                }
            } else if ([commandName isEqualToString: @"ssh"]) {
                // Ability to start multiple ssh commands:
                // start by increasing the number of the interpreter, until we're out.
                int numInterpreter = 0;
                if (currentSshCommand < numSshCommands) {
                    numInterpreter = currentSshCommand;
                    currentSshCommand++;
                } else {
                    NSDate *start = [NSDate date];
                    NSDate *now = [NSDate date];
                    NSTimeInterval timeInterval = [now timeIntervalSinceDate:start];
                    bool timeout = true;
                    while (timeInterval < 1) { // keep trying for 1 second
                        while  (numInterpreter < numSshCommands) {
                            if (sshIsRunning[numInterpreter] == false) {
                                timeout = false;
                                break;
                            }
                            numInterpreter++;
                        }
                        if (!timeout) break; // need to break twice!
                        numInterpreter = 0;
                        now = [NSDate date];
                        timeInterval = [now timeIntervalSinceDate:start];
                    }
                    if (timeout) {
                        display_alert(@"Too many ssh commands", @"There are too many ssh commands running at the same time. Try closing some of them.");
                        NSLog(@"%@", @"Too many ssh scripts running simultaneously.\n");
                        function = &too_many_scripts;
                        functionName = @"notAValidCommand";
                        currentSession->global_errno = ENOENT;
                        argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                    }
                }
                if ((numInterpreter >= 0) && (numInterpreter < numSshCommands)) {
                    params->numInterpreter = numInterpreter;
                    sshIsRunning[numInterpreter] = true;
                    NSLog(@"Starting a ssh command: %d", params->numInterpreter);
                    if (numInterpreter > 0) {
                        char suffix[2];
                        suffix[0] = 'A' + (numInterpreter - 1);
                        suffix[1] = 0;
                        commandName = [@"ssh_cmd" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                        libraryName = [libraryName stringByReplacingOccurrencesOfString:@"ssh_cmd" withString:commandName];
                    }
                }
            } else if ([commandName isEqualToString: @"curl"]) {
                bool idle = false;
                if (!atomic_compare_exchange_strong(&curlIsRunning, &idle, true)) {
                    display_alert(@"Only one curl command at a time", @"Please wait for the other one to end.");
                    NSLog(@"%@", @"Too many curl commands running simultaneously.\n");
                    function = &too_many_scripts;
                    functionName = @"notAValidCommand";
                    currentSession->global_errno = ENOENT;
                    argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                }
            } else if ([commandName isEqualToString: @"scp"] || [commandName isEqualToString: @"sftp"]) {
                bool idle = false;
                if (!atomic_compare_exchange_strong(&scpIsRunning, &idle, true)) {
                    display_alert(@"Only one scp or sftp command at a time", @"Please wait for the other one to end.");
                    NSLog(@"%@", @"Too many scp/sftp commands running simultaneously.\n");
                    function = &too_many_scripts;
                    functionName = @"notAValidCommand";
                    currentSession->global_errno = ENOENT;
                    argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                }
            } else if ([commandName isEqualToString: @"rsync"] || [commandName isEqualToString: @"openrsync"]) {
                // It's a rsync command. rsync between local directories requires two different commands.
                // start by increasing the number of the interpreter, until we're out.
                int numInterpreter = 0;
                if (currentRsyncCommand < numRsyncCommands) {
                    numInterpreter = currentRsyncCommand;
                    currentRsyncCommand++;
                } else {
                    while  (numInterpreter < numRsyncCommands) {
                        if (rsyncIsRunning[numInterpreter] == false) break;
                        numInterpreter++;
                    }
                    if (numInterpreter >= numRsyncCommands) {
                        display_alert(@"Too many rsync commands", @"There are too many rsync commands running at the same time. Try closing some of them.");
                        NSLog(@"%@", @"Too many rsync running simultaneously.\n");
                        function = &too_many_scripts;
                        functionName = @"notAValidCommand";
                        currentSession->global_errno = ENOENT;
                        argv[0][0] = 'x'; // prevent reinitialization in cleanup_function
                    }
                }
                if ((numInterpreter >= 0) && (numInterpreter < numRsyncCommands)) {
                    params->numInterpreter = numInterpreter;
                    rsyncIsRunning[numInterpreter] = true;
                    NSLog(@"Starting a rsync command: %d", params->numInterpreter);
                    if (numInterpreter > 0) {
                        char suffix[2];
                        suffix[0] = 'A' + (numInterpreter - 1);
                        suffix[1] = 0;
                        commandName = [@"openrsync" stringByAppendingString: [NSString stringWithCString: suffix encoding:NSUTF8StringEncoding]];
                        libraryName = [libraryName stringByReplacingOccurrencesOfString:@"openrsync" withString:commandName];
                    }
                }
            }
            // Don't load the function if we already set it to &too_many_scripts.
            if (function == NULL) {
                if ([libraryName isEqualToString: @"STATIC"]) {
                    // commandName may have been changed to select a duplicate
                    // dynamic ssh framework. Static commands always use their
                    // canonical argv[0] registry name.
                    const ios_command_entry *entry = ios_command_lookup(argv[0]);
                    if (entry != NULL) {
                        function = entry->function;
                    }
                } else if ([libraryName isEqualToString: @"SELF"]) handle = RTLD_SELF;  // commands defined in the image containing ios_system
                else if ([libraryName isEqualToString: @"MAIN"]) handle = RTLD_MAIN_ONLY; // commands defined in main program
                else handle = dlopen(libraryName.UTF8String, RTLD_LAZY | RTLD_GLOBAL); // commands defined in dynamic library
                if ((function == NULL) && (handle == NULL) && ![libraryName isEqualToString: @"STATIC"]) {
                    char* errorLoading = strdup(dlerror());
                    fprintf(thread_stderr, "Failed loading %s from %s, cause = %s\n", commandName.UTF8String, libraryName.UTF8String, errorLoading);
                    NSLog(@"Failed loading %s from %s, cause = %s\n", commandName.UTF8String, libraryName.UTF8String, errorLoading);
                    NSString* fileLocation = [[NSBundle mainBundle] pathForResource:libraryName ofType:nil];
                    free(errorLoading);
                } else if (function == NULL) {
                    function = dlsym(handle, functionName.UTF8String);
                    // RTLD_MAIN_ONLY fail in some cases (iOS 18?), but RTLD_DEFAULT works:
                    if ((function == NULL) && (handle == RTLD_MAIN_ONLY))
                        function = dlsym(RTLD_DEFAULT, functionName.UTF8String);
                    // NSLog(@"Loading %s from %s", functionName.UTF8String, libraryName.UTF8String);
                    if (function == NULL) {
                        char* errorLoading = strdup(dlerror());
                        fprintf(thread_stderr, "Failed loading %s from %s, cause = %s\n", functionName.UTF8String, libraryName.UTF8String, errorLoading);
                        NSLog(@"Failed loading %s from %s, cause = %s\n", commandName.UTF8String, libraryName.UTF8String, errorLoading);
                        free(errorLoading);
                    }
                }
            }
        }
        if (function == NULL) {
            function = &command_not_found;
            currentSession->global_errno = ENOENT;
            // function = dlsym(RTLD_SELF, "command_not_found");
        }
        if (function) {
            // We run the function in a thread because there are several
            // points where we can exit from a shell function.
            // Commands call pthread_exit instead of exit
            // thread is attached, could also be un-attached
            params->argc = argc;
            params->argv = argv;
            params->function = function;
            params->dlHandle = handle;
            params->isPipeIn = (params->stdin != thread_stdin);
            params->isPipeOut = (params->stdout != thread_stdout);
            if (params->stdout != NULL)
                NSLog(@"params->stdout: %d thread_stdout: %d \n", fileno(params->stdout), fileno(thread_stdout));
            if (params->stdin != NULL)
                NSLog(@"params->stdin: %d thread_stdin: %d \n", fileno(params->stdin), fileno(thread_stdin));
            params->isPipeErr = (params->stderr != thread_stderr) && (params->stderr != params->stdout);
            params->storeRootThread = false;
            // params->session = currentSession;
            NSLog(@"Starting command: %s, currentSession->isMainThread: %d", commandName.UTF8String, currentSession->isMainThread);
            if ([commandName isEqualToString:@"wasm"])
                startedPreparingWebAssemblyCommand();
            // Recursive engines such as jq need a CLI-sized stack rather than
            // Darwin's 512 KiB pthread default. Registry metadata applies to
            // ordinary invocations, virtual paths, and pipeline stages alike.
            pthread_attr_t commandAttributes;
            pthread_attr_init(&commandAttributes);
            // Capture only the host command context, never unrelated TLS such
            // as an active database transaction. Children inherit this value too.
            params->commandContext = CFBridgingRetain(NSThread.currentThread.threadDictionary[ios_commandContextKey]);
            // OSH foreground commands own their streams until full pthread
            // cleanup, even when the host normally launches commands asynchronously.
            bool joinCommand = joinMainThread || atomic_load_explicit(
                &currentSession->shellCommandRunning, memory_order_acquire);
            if (registeredCommand != NULL && registeredCommand->stack_size != 0) {
                size_t stackSize = registeredCommand->stack_size;
#if __has_feature(address_sanitizer)
                stackSize *= 4; // Instrumented recursive frames are larger.
#endif
                pthread_attr_setstacksize(&commandAttributes, stackSize);
            }
            if (currentSession->isMainThread) {
                params->storeRootThread = true;
                bool commandOperatesOnFiles = ([commandStructure[3] isEqualToString:@"file"] ||
                                               [commandStructure[3] isEqualToString:@"directory"] ||
                                               params->isPipeOut || params->isPipeErr);
#if !IOS_SYSTEM_HAS_UIKIT || !IOS_SYSTEM_ENABLE_FILE_COORDINATION
                commandOperatesOnFiles = false;
#endif
                NSString* currentPath = [NSFileManager.defaultManager currentDirectoryPath];
                commandOperatesOnFiles &= (currentPath != nil);
                if (commandOperatesOnFiles) {
                    // Send a signal to the system that we're going to change the current directory:
                    NSURL* currentURL = [NSURL fileURLWithPath:currentPath];
                    NSFileCoordinator *fileCoordinator =  [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                    [fileCoordinator coordinateWritingItemAtURL:currentURL options:0 error:NULL byAccessor:^(NSURL *currentURL) {
                        currentSession->isMainThread = false;
                        volatile pthread_t _tid = NULL;
                        pthread_create(&_tid, &commandAttributes, run_function, params);
                        while (_tid == NULL) { }
                        // ios_storeThreadId(_tid);
                        if (currentSession->mainThreadId == NULL) currentSession->mainThreadId = _tid;
                        // Wait for this process to finish:
						if (joinCommand) {
							pthread_join(_tid, NULL);
							// If there are auxiliary process, also wait for them:
							if (currentSession->lastThreadId > 0) pthread_join(currentSession->lastThreadId, NULL);
							currentSession->lastThreadId = 0;
							currentSession->current_command_root_thread = 0;
						} else {
							pthread_detach(_tid); // a thread must be either joined or detached
						}
                        currentSession->isMainThread = true;
                    }];
                } else {
                    currentSession->isMainThread = false;
                    volatile pthread_t _tid = NULL;
                    pthread_create(&_tid, &commandAttributes, run_function, params);
                    while (_tid == NULL) { }
                    // ios_storeThreadId(_tid);
                    if (currentSession->mainThreadId == NULL) currentSession->mainThreadId = _tid;
                    // Wait for this process to finish:
					if (joinCommand) {
						pthread_join(_tid, NULL);
						// If there are auxiliary process, also wait for them:
						if (currentSession->lastThreadId > 0) pthread_join(currentSession->lastThreadId, NULL);
						currentSession->lastThreadId = 0;
						currentSession->current_command_root_thread = 0;
					} else {
						pthread_detach(_tid); // a thread must be either joined or detached
					}
                    currentSession->isMainThread = true;
                }
            } else {
                NSLog(@"Starting command %s, global_errno= %d\n", command, currentSession->global_errno);
                // Don't send signal if not in main thread. Also, don't join threads.
                volatile pthread_t _tid_local = NULL;
                pthread_create(&_tid_local, &commandAttributes, run_function, params);
                // The last command on the command line (with multiple pipes) will be created first
                while (_tid_local == NULL) { }; // Wait until thread has actually started
                // fprintf(stderr, "Started thread = %x\n", _tid_local);
                if (currentSession->lastThreadId == 0) currentSession->lastThreadId = _tid_local; // will be joined later
                else pthread_detach(_tid_local); // a thread must be either joined or detached.
            }
            pthread_attr_destroy(&commandAttributes);
        } else {
            fprintf(params->stderr, "%s: command not found\n", argv[0]);
            NSLog(@"%s: command not found\n", argv[0]);
            free(argv);
            // If command output was redirected to a pipe, we still need to close it.
            // (to warn the other command that it can stop waiting)
            // We still need this step because there can be multiple pipes.
            if (params->stdout != currentSession->stdout) {
                fclose(params->stdout);
            }
            if ((params->stderr != currentSession->stderr) && (params->stderr != params->stdout)) {
                fclose(params->stderr);
            }
            if ((handle != NULL) && (handle != RTLD_SELF)
                && (handle != RTLD_MAIN_ONLY)
                && (handle != RTLD_DEFAULT) && (handle != RTLD_NEXT))
                dlclose(handle);
            free(params); // This was malloc'ed in ios_system
            ios_storeThreadId(0);
            currentSession->global_errno = 127;
            // TODO: this should also raise an exception, for python scripts
        } // if (function)
    } else { // argc != 0
        ios_storeThreadId(0);
        free(argv); // argv is otherwise freed in cleanup_function
        free(dontExpand);
        free(params);
    }
    NSLog(@"returning from ios_system, global_errno= %d\n", currentSession->global_errno);
    free(originalCommand); // releases cmd, which was a strdup of inputCommand
    fflush(thread_stdin);
    fflush(thread_stdout);
    fflush(thread_stderr);
    return currentSession->global_errno;
}

static char **osh_ios_copy_environment(char *const environment[]) {
    int count = 0;
    while (environment != NULL && environment[count] != NULL) count++;
    char **copy = calloc((size_t)count + 1, sizeof(char *));
    if (copy == NULL) return NULL;
    for (int i = 0; i < count; i++) {
        copy[i] = strdup(environment[i]);
        if (copy[i] == NULL) {
            for (int j = 0; j < i; j++) free(copy[j]);
            free(copy);
            return NULL;
        }
    }
    return copy;
}

static void osh_ios_free_environment(char **environment) {
    if (environment == NULL) return;
    for (int i = 0; environment[i] != NULL; i++) free(environment[i]);
    free(environment);
}

typedef struct {
    sessionParameters *session;
    pid_t processId;
    osh_ios_signal_handler signalHandlers[NSIG];
} osh_ios_context;

static int osh_ios_lookup_virtual_path_callback(const char *path, void *context) {
    if (ios_command_lookup_virtual_path(path) != NULL) return 1;
    const char *directory = ios_command_virtual_bin_path();
    size_t length = strlen(directory);
    if (strncmp(path, directory, length) != 0 || path[length] != '/') {
        return -1;
    }
    return 0;
}

static int osh_ios_run_external(
    int argc, const char *const argv[], int envc,
    const char *const environment[], FILE *input, FILE *output, FILE *error,
    bool deferDirectoryRestoration) {
    char **commandEnvironment = calloc((size_t)envc + 1, sizeof(char *));
    if (commandEnvironment == NULL) {
        fprintf(error, "osh: unable to allocate the command environment\n");
        return 1;
    }
    for (int i = 0; i < envc; i++) {
        commandEnvironment[i] = (char *)environment[i];
    }

    pid_t externalPid = ios_fork();
    if (deferDirectoryRestoration) {
        // Only concurrent stage roots defer restoration. Ordinary commands and
        // nested Python subprocess calls still restore their own directory.
        ios_deferDirectoryRestoration(externalPid);
    }
    storeEnvironment(commandEnvironment);
    free(commandEnvironment);

    FILE *savedInput = ios_stdin();
    FILE *savedOutput = ios_stdout();
    FILE *savedError = ios_stderr();
    ios_setStreams(input, output, error);
    int status = ios_system(argc, argv);
    ios_setStreams(savedInput, savedOutput, savedError);
    pthread_t externalThread = ios_getThreadId(externalPid);
    if (externalThread == (pthread_t)-1) {
        // ios_system can return before starting a child when cancellation races
        // this call. Complete ios_fork's pending registration before release.
        ios_storeThreadId(pthread_self());
    } else if (externalThread != NULL) {
        // Commands marked asynchronous by ios_system are still foreground OSH
        // commands unless OSH itself requested a background job.
        ios_waitpid(externalPid);
    }
    ios_releaseThreadId(externalPid);
    return status;
}

static int osh_ios_run_external_callback(
    int argc, const char *const argv[], int envc,
    const char *const environment[], FILE *input, FILE *output, FILE *error,
    void *context) {
    return osh_ios_run_external(argc, argv, envc, environment, input, output, error, false);
}

static int osh_ios_can_run_pipeline_callback(
    int count, const char *const names[], void *context) {
    for (int i = 0; i < count; i++) {
        const ios_command_entry *entry = ios_command_lookup(names[i]);
        if (entry == NULL) entry = ios_command_lookup_virtual_path(names[i]);
        if (entry == NULL) return 0;
        ios_command_isolation_policy policy = ios_commandIsExclusiveOrThreadSafe(names[i]);
        // A producer may own an exclusive runtime. Concurrent consumers must
        // have invocation-local state, including option parsing.
        if (policy == IOS_COMMAND_ISOLATION_OSH ||
            (i > 0 && policy != IOS_COMMAND_ISOLATION_THREAD_SAFE)) return 0;
    }
    return 1;
}

// Pipeline stages need independent cancellation/runtime state, but retain the
// parent Bash command context and filesystem aliases. The evaluator owns argv;
// no OSH heap objects cross these native command threads.
static void osh_ios_run_pipeline_callback(
    int count, const osh_ios_pipeline_command commands[], int envc,
    const char *const environment[], int statuses[], void *context) {
    osh_ios_context *shell = context;
    char directory[MAXPATHLEN];
    sessionParameters *sessions = calloc((size_t)count, sizeof(sessionParameters));
    if (sessions == NULL || getcwd(directory, sizeof(directory)) == NULL) {
        free(sessions);
        for (int i = 0; i < count; i++) {
            fclose(commands[i].input);
            fclose(commands[i].output);
            fclose(commands[i].error);
            statuses[i] = 125;
        }
        return;
    }
    id commandContext = NSThread.currentThread.threadDictionary[ios_commandContextKey];
    dispatch_group_t group = dispatch_group_create();
    for (int i = 0; i < count; i++) {
        sessionParameters *stage = &sessions[i];
        initSessionParameters(stage);
        strlcpy(stage->currentDir, shell->session->currentDir, sizeof(stage->currentDir));
        strlcpy(stage->previousDirectory, shell->session->previousDirectory, sizeof(stage->previousDirectory));
        strlcpy(stage->localMiniRoot, shell->session->localMiniRoot, sizeof(stage->localMiniRoot));
        strlcpy(stage->workspaceDirectory, shell->session->workspaceDirectory, sizeof(stage->workspaceDirectory));
        strlcpy(stage->temporaryDirectory, shell->session->temporaryDirectory, sizeof(stage->temporaryDirectory));
        strlcpy(stage->appBundleDirectory, shell->session->appBundleDirectory, sizeof(stage->appBundleDirectory));
        stage->context = shell->session->context;
        stage->stdin = commands[i].input;
        stage->stdout = commands[i].output;
        stage->stderr = commands[i].error;
        // Use shell cancellation semantics (never process-wide SIGINT handlers).
        atomic_store_explicit(&stage->shellCommandRunning, true, memory_order_release);
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                sessionParameters *savedSession = currentSession;
                FILE *savedInput = thread_stdin, *savedOutput = thread_stdout, *savedError = thread_stderr;
                void *savedContext = thread_context;
                id savedCommandContext = NSThread.currentThread.threadDictionary[ios_commandContextKey];
                currentSession = stage;
                thread_stdin = stage->stdin;
                thread_stdout = stage->stdout;
                thread_stderr = stage->stderr;
                thread_context = (void *)stage->context;
                if (commandContext) {
                    NSThread.currentThread.threadDictionary[ios_commandContextKey] = commandContext;
                } else {
                    [NSThread.currentThread.threadDictionary removeObjectForKey:ios_commandContextKey];
                }
                // Reuse foreground dispatch, including its wait for commands
                // started asynchronously by the host, before closing pipes.
                if (commands[i].redirect_error != NULL) {
                    fputs(commands[i].redirect_error, stage->stderr);
                    statuses[i] = 1;
                } else {
                    statuses[i] = osh_ios_run_external(
                        commands[i].argc, commands[i].argv, envc, environment,
                        stage->stdin, stage->stdout, stage->stderr, true);
                }
                fclose(stage->stdin);
                fclose(stage->stdout);
                fclose(stage->stderr);
                if (savedCommandContext) {
                    NSThread.currentThread.threadDictionary[ios_commandContextKey] = savedCommandContext;
                } else {
                    [NSThread.currentThread.threadDictionary removeObjectForKey:ios_commandContextKey];
                }
                currentSession = savedSession;
                thread_stdin = savedInput;
                thread_stdout = savedOutput;
                thread_stderr = savedError;
                thread_context = savedContext;
            }
        });
    }
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0) {
        if (atomic_load_explicit(&shell->session->cancellationRequested, memory_order_acquire)) {
            for (int i = 0; i < count; i++) {
                currentSession = &sessions[i];
                ios_kill();
            }
            currentSession = shell->session;
        }
    }
    // Native commands share the process cwd. Wait for every stage before
    // restoring the shell's directory for its next command.
    chdir_nolock(directory);
    for (int i = 0; i < count; i++) {
        sessionParameters *stage = &sessions[i];
        for (int j = 0; j < stage->numCommandsAllocated; j++) free(stage->commandName[j]);
        free(stage->commandName);
        free(stage->sshpassPassword);
        free(stage->sshpassPrompt);
        pthread_mutex_destroy(&stage->sshpassMutex);
        pthread_mutex_destroy(&stage->pythonCommandsMutex);
        pthread_cond_destroy(&stage->pythonCommandsCondition);
    }
    free(sessions);
}

// Synchronous Python bridge: reuse foreground command dispatch and its existing
// cancellation lifecycle. The caller supplies temporary files for input/capture,
// so no child handles, pipe pumping, or additional worker lifetime is needed.
static int ios_python_subprocess_run(int argc, const char *const argv[], int input, int output, int error) {
    if (currentSession == NULL || currentPythonCommand == NULL) {
        errno = ENOTSUP; // Python-created threads do not own a command session.
        return -1;
    }
    if (argc <= 0 || argv == NULL || argv[0] == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (ios_command_lookup(argv[0]) == NULL && ios_command_lookup_virtual_path(argv[0]) == NULL) {
        errno = ENOENT;
        return -1;
    }
    int supplied[3] = {
        input == -1 ? fileno(thread_stdin) : input,
        output == -1 ? fileno(thread_stdout) : output,
        error == -1 ? fileno(thread_stderr) : error,
    };
    if (error == -2) supplied[2] = supplied[1];
    FILE *streams[3] = {NULL, NULL, NULL};
    int status = -1;
    int failure = 0;
    for (int i = 0; i < 3; i++) {
        int fd = dup(supplied[i]);
        if (fd < 0) { failure = errno; break; }
        if (fcntl(fd, F_SETNOSIGPIPE, 1) < 0 ||
            (streams[i] = fdopen(fd, i == 0 ? "r" : "w")) == NULL) {
            failure = errno;
            close(fd);
            break;
        }
        setbuf(streams[i], NULL);
    }
    if (!failure) {
        char **environment = environmentVariables(ios_currentPid());
        int count = 0;
        while (environment != NULL && environment[count] != NULL) count++;
        status = osh_ios_run_external(argc, argv, count,
            (const char *const *)environment, streams[0], streams[1], streams[2], false);
    }
    for (int i = 0; i < 3; i++) {
        if (streams[i] != NULL) fclose(streams[i]);
    }
    if (failure) errno = failure;
    return status;
}

static int osh_ios_is_cancelled_callback(void *context) {
    osh_ios_context *oshContext = (osh_ios_context *)context;
    sessionParameters *session = oshContext != NULL ? oshContext->session : NULL;
    return session != NULL && atomic_load_explicit(
        &session->cancellationRequested, memory_order_acquire);
}

static int osh_ios_send_signal_callback(
    int identifier, int signalNumber, int processGroup, void *context) {
    (void)processGroup;
    osh_ios_context *oshContext = (osh_ios_context *)context;
    if (oshContext != NULL && identifier == oshContext->processId &&
        signalNumber > 0 && signalNumber < NSIG &&
        oshContext->signalHandlers[signalNumber] != NULL) {
        oshContext->signalHandlers[signalNumber](signalNumber);
        return 0;
    }
    return ios_killpid(identifier, signalNumber);
}

static int osh_ios_set_signal_handler_callback(
    int signalNumber, osh_ios_signal_handler handler, void *context) {
    osh_ios_context *oshContext = (osh_ios_context *)context;
    if (oshContext == NULL || signalNumber <= 0 || signalNumber >= NSIG) {
        return EINVAL;
    }
    oshContext->signalHandlers[signalNumber] = handler;
    return 0;
}

static int osh_ios_get_process_id_callback(void *context) {
    osh_ios_context *oshContext = (osh_ios_context *)context;
    return oshContext != NULL ? oshContext->processId : ios_currentPid();
}

// The calling thread's state that a shell evaluated on a helper thread uses,
// as run_function provides it to command threads.
typedef struct {
    sessionParameters *session;
    FILE *stdin;
    FILE *stdout;
    FILE *stderr;
    void *context;
    pid_t processId;
    CFTypeRef commandContext;
    int argc;
    const char *const *argv;
    bool startsCommand;
    int status;
} osh_ios_invocation;

static void *osh_ios_invocation_thread(void *parameters) {
    @autoreleasepool {
        osh_ios_invocation *invocation = parameters;
        currentSession = invocation->session;
        thread_stdin = invocation->stdin;
        thread_stdout = invocation->stdout;
        thread_stderr = invocation->stderr;
        thread_context = invocation->context;
        ios_setCurrentPid(invocation->processId);
        if (invocation->commandContext != NULL) {
            NSThread.currentThread.threadDictionary[ios_commandContextKey] =
                (__bridge id)invocation->commandContext;
        }
        invocation->status = ios_system_osh_evaluate(
            invocation->argc, invocation->argv, invocation->startsCommand);
    }
    return NULL;
}

// Runs one shell invocation (argv such as {"sh", "-c", "...", "name", "arg"}).
// startsCommand is true when this call is itself a new top-level command, which
// clears earlier stop requests the way ios_system does when it starts one.
static int ios_system_osh_invocation(
    int argc, const char *const argv[], bool startsCommand) {
    if (currentSession == NULL) {
        currentSession = malloc(sizeof(sessionParameters));
        if (currentSession == NULL) return ENOMEM;
        initSessionParameters(currentSession);
    }
    if (argc <= 0) return 0;
    if (thread_stdin == NULL) thread_stdin = currentSession->stdin;
    if (thread_stdout == NULL) thread_stdout = currentSession->stdout;
    if (thread_stderr == NULL) thread_stderr = currentSession->stderr;
    if (thread_context == NULL) thread_context = currentSession->context;

    // An OSH evaluator must never be pthread-cancelled, and a helper thread
    // borrows this frame until it finishes. Native callers such as awk's
    // system() run on pthread-cancellable command threads, so defer any cancel
    // until the shell has finished; ios_kill stops the shell cooperatively.
    int cancelState;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cancelState);
    int status;

    // OSH evaluates shell recursion on the C stack. Callers such as the Bash
    // tool's queue threads and Python have 512 KiB stacks, so evaluate on a
    // thread with the sh command's stack instead. sh/bash command threads
    // already have it and run inline.
    size_t stackSize = ios_command_lookup("sh")->stack_size;
#if __has_feature(address_sanitizer)
    stackSize *= 4; // Instrumented recursive frames are larger.
#endif
    if (pthread_get_stacksize_np(pthread_self()) < stackSize) {
        osh_ios_invocation invocation = {
            .session = currentSession,
            .stdin = thread_stdin,
            .stdout = thread_stdout,
            .stderr = thread_stderr,
            .context = thread_context,
            .processId = ios_currentPid(),
            // Borrowed: this thread keeps it alive while it waits below.
            .commandContext = (__bridge CFTypeRef)
                NSThread.currentThread.threadDictionary[ios_commandContextKey],
            .argc = argc,
            .argv = argv,
            .startsCommand = startsCommand,
        };
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, stackSize);
        pthread_t thread;
        int failure = pthread_create(
            &thread, &attributes, osh_ios_invocation_thread, &invocation);
        pthread_attr_destroy(&attributes);
        if (failure != 0) {
            fprintf(thread_stderr, "osh: unable to start the shell thread: %s\n",
                    strerror(failure));
            status = failure;
        } else {
            pthread_join(thread, NULL);
            status = invocation.status;
        }
    } else {
        status = ios_system_osh_evaluate(argc, argv, startsCommand);
    }
    pthread_setcancelstate(cancelState, NULL);
    pthread_testcancel();
    return status;
}

// Evaluates one shell invocation on the current thread, which has the shell
// stack and the caller's thread state (see ios_system_osh_invocation).
static int ios_system_osh_evaluate(
    int argc, const char *const argv[], bool startsCommand) {
    // A nested shell (`sh script`, `$(bash -c ...)`, Python's os.system) runs
    // on its own command thread while the enclosing evaluator waits for it.
    // Each OSH evaluator's runtime is thread-local, so only this session's
    // shell bookkeeping is shared. It is saved and restored like a stack, and
    // a pending cancellation is left for the enclosing evaluator to observe.
    bool nested = atomic_load_explicit(
        &currentSession->shellCommandRunning,
        memory_order_acquire);
    if (nested && pthread_equal(currentSession->shellThread, pthread_self())) {
        fprintf(thread_stderr, "osh: a shell cannot re-enter itself on the same thread\n");
        return EBUSY;
    }
    if (nested && atomic_load_explicit(
            &currentSession->cancellationRequested,
            memory_order_acquire)) {
        return OSH_IOS_STATUS_CANCELLED;
    }

    char savedCurrentDirectory[MAXPATHLEN];
    char savedPreviousDirectory[MAXPATHLEN];
    strlcpy(savedCurrentDirectory, currentSession->currentDir,
            sizeof(savedCurrentDirectory));
    strlcpy(savedPreviousDirectory, currentSession->previousDirectory,
            sizeof(savedPreviousDirectory));
    pthread_t savedRootThread = currentSession->current_command_root_thread;
    pthread_t savedPthreadCancelableRootCommand = atomic_load_explicit(
        &currentSession->pthreadCancelableRootCommand,
        memory_order_acquire);
    pthread_t savedShellThread = currentSession->shellThread;
    bool savedIsMainThread = currentSession->isMainThread;

    pid_t shellPid = ios_fork();
    ios_storeThreadId(pthread_self());

    char **shellEnvironment =
        osh_ios_copy_environment(environmentVariables(ios_currentPid()));
    if (shellEnvironment == NULL) {
        fprintf(thread_stderr, "osh: unable to allocate the shell environment\n");
        ios_releaseThreadId(shellPid);
        return ENOMEM;
    }
    int environmentCount = 0;
    while (shellEnvironment[environmentCount] != NULL) environmentCount++;

    if (!nested) {
        atomic_store_explicit(
            &currentSession->cancellationRequested, false, memory_order_release);
        if (startsCommand && !currentSession->keepsCancellationRequests) {
            atomic_store_explicit(
                &currentSession->commandCancellationRequested, false, memory_order_seq_cst);
        }
        atomic_store_explicit(
            &currentSession->shellCommandRunning, true, memory_order_seq_cst);
        // A stop that arrived before the shell was running found no shell to
        // flag in ios_kill; take it over now so the job still stops.
        if (atomic_load_explicit(
                &currentSession->commandCancellationRequested, memory_order_seq_cst)) {
            atomic_store_explicit(
                &currentSession->cancellationRequested, true, memory_order_release);
        }
    }
    currentSession->shellThread = pthread_self();
    currentSession->isMainThread = false;

    osh_ios_context context = {
        .session = currentSession,
        .processId = shellPid,
    };

    osh_ios_config config = {
        .run_external = osh_ios_run_external_callback,
        .is_cancelled = osh_ios_is_cancelled_callback,
        .send_signal = osh_ios_send_signal_callback,
        .set_signal_handler = osh_ios_set_signal_handler_callback,
        .get_process_id = osh_ios_get_process_id_callback,
        .lookup_virtual_path = osh_ios_lookup_virtual_path_callback,
        .environment_count = environmentCount,
        .environment = (const char *const *)shellEnvironment,
        .context = &context,
        .run_pipeline = osh_ios_run_pipeline_callback,
        .can_run_pipeline = osh_ios_can_run_pipeline_callback,
    };
    int status = osh_ios_run(
        argc, argv, thread_stdin, thread_stdout, thread_stderr, &config);

    osh_ios_free_environment(shellEnvironment);
    ios_releaseThreadId(shellPid);
    [NSFileManager.defaultManager
        changeCurrentDirectoryPath:
            [NSString stringWithUTF8String:savedCurrentDirectory]];
    strlcpy(currentSession->currentDir, savedCurrentDirectory,
            sizeof(currentSession->currentDir));
    strlcpy(currentSession->previousDirectory, savedPreviousDirectory,
            sizeof(currentSession->previousDirectory));
    atomic_store_explicit(
        &currentSession->pthreadCancelableRootCommand,
        savedPthreadCancelableRootCommand,
        memory_order_release);
    currentSession->current_command_root_thread = savedRootThread;
    currentSession->shellThread = savedShellThread;
    currentSession->isMainThread = savedIsMainThread;
    currentSession->global_errno = status;
    if (!nested) {
        atomic_store_explicit(
            &currentSession->shellCommandRunning, false, memory_order_release);
        atomic_store_explicit(
            &currentSession->cancellationRequested, false, memory_order_release);
    }
    return status;
}

int ios_system_osh(const char* inputCmd) {
    if (inputCmd == NULL) return ios_system_osh_invocation(0, NULL, true);
    const char *argv[] = {"osh", "-c", inputCmd};
    return ios_system_osh_invocation(3, argv, true);
}

NSArray<NSString *> * pathNormalizeArray(NSArray<NSString *> * parts, BOOL allowAboveRoot) {
  NSMutableArray<NSString *> * res = [[NSMutableArray alloc] init];
  for (NSString * p in parts) {
    // ignore empty parts
    if (p.length == 0 || [p isEqualToString:@"."] || [p isEqualToString:@"/"]) {
      continue;
    }
    
    if ([p isEqualToString: @".."]) {
      if (res.count && ![@".." isEqualToString: [res lastObject]]) {
        [res removeLastObject];
      } else if (allowAboveRoot) {
        [res addObject: p];
      }
     } else {
      [res addObject: p];
    }
  }
  
  return res;
}

NSString * pathNormalize(NSString *path) {
  BOOL isAbsolute = [path hasPrefix:@"/"];
  BOOL trailingSlash = [path hasSuffix:@"/"];
  
  NSString * result = [pathNormalizeArray([path pathComponents], !isAbsolute) componentsJoinedByString: @"/"];
  
  if (!result.length && !isAbsolute) {
    result = @".";
  }
  
  if (result.length && trailingSlash) {
    result = [result stringByAppendingString:@"/"];
  }
  
  return [(isAbsolute ? @"/" : @"") stringByAppendingString:result];
}


NSString * pathJoin(NSString * segmentA, NSString * segmentB) {
  NSMutableString *path = [[NSMutableString alloc] init];
  NSString * a = segmentA ?: @"";
  NSString * b = segmentB ?: @"";
  
  if ([b hasPrefix:@"/"]) {
    return pathNormalize(b);
  }
  
  if (a.length) {
    [path appendString: a];
    if (b.length) {
      [path appendString:@"/"];
      [path appendString:b];
    }
  } else if (b.length) {
    [path appendString: b];
  }
  
  return pathNormalize(path);
}

//
char* ios_getPythonLibraryName(void) {
    char* libraryName = strdup("Python");
    NSLog(@"ios_getPythonLibraryName: returning %s\n", libraryName);
    return libraryName;
}

void ios_releasePythonLibraryName(char* name) {
    NSLog(@"ios_releasePythonLibraryName: releasing %s\n", name);
    free(name);
}
