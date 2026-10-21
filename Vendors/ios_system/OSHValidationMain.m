#import <Foundation/Foundation.h>

#import "ios_system/ios_system.h"

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/stat.h>

static atomic_bool resolutionValidationFinished;
static atomic_bool resolutionValidationFailed;

static void *validate_command_discovery(void *context)
{
    @autoreleasepool {
        while (!atomic_load(&resolutionValidationFinished)) {
            @autoreleasepool {
                if (!ios_executable("/usr/bin/runtime-command///") ||
                    ios_executable("/usr/bin/missing-runtime-command")) {
                    atomic_store(&resolutionValidationFailed, true);
                    break;
                }
            }
        }
    }
    return NULL;
}

static int runtime_command_main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--until-epipe") == 0) {
        char buffer[8192];
        memset(buffer, 'x', sizeof(buffer));
        // Bound the producer so a consumer that drains forever fails the test
        // instead of hanging it. Success requires the pipe to close first.
        for (size_t sent = 0; sent < 8 * 1024 * 1024;) {
            ssize_t count = write(fileno(thread_stdout), buffer, sizeof(buffer));
            if (count > 0) {
                sent += (size_t)count;
            } else if (count < 0 && errno == EPIPE) {
                return 0;
            } else if (count < 0 && errno == EINTR) {
                continue;
            } else {
                return 1;
            }
        }
        fprintf(thread_stderr, "Producer exhausted its byte limit without receiving EPIPE.\n");
        return 2;
    }
    if (argc == 3 && strcmp(argv[1], "--cwd") == 0) {
        // The FIFO handshake guarantees cmp has started (and captured its
        // launch directory) before this producer changes the process cwd.
        int ready = open("cwd-ready", O_WRONLY);
        if (ready < 0) return 1;
        char expected[PATH_MAX], actual[PATH_MAX];
        if (chdir(argv[2]) != 0 || getcwd(expected, sizeof(expected)) == NULL) {
            close(ready);
            return 1;
        }
        ssize_t written = write(ready, "x", 1);
        close(ready);
        if (written != 1) return 1;
        // cmp exits on the mismatch. EPIPE means its runner has closed the
        // final read endpoint, after native command cleanup has finished.
        while (write(fileno(thread_stdout), "y", 1) > 0) {}
        if (errno != EPIPE || getcwd(actual, sizeof(actual)) == NULL ||
            strcmp(actual, expected) != 0) {
            fprintf(thread_stderr, "Consumer cleanup changed the producer directory.\n");
            return 1;
        }
        FILE *result = fopen("cwd-result", "w");
        if (result == NULL) return 1;
        fputs("producer\n", result);
        return fclose(result) == 0 ? 0 : 1;
    }
    if (argc == 3 && strcmp(argv[1], "--pid") == 0) {
        pid_t pid = ios_currentPid();
        usleep(100000); // Let the two consumer threads start and register.
        const char *marker = ios_getenv("PIPELINE_MARKER");
        if (pid == 0 || ios_currentPid() != pid || marker == NULL || strcmp(marker, argv[2]) != 0) {
            fprintf(thread_stderr, "Pipeline command lost its PID or environment.\n");
            return 1;
        }
    }
    if (argc == 2 && strcmp(argv[1], "--raise") == 0) {
        [NSException raise:NSInvalidArgumentException format:@"runtime-command raised"];
    }
    if (argc > 1 && strcmp(argv[1], "--slow") == 0) usleep(100000);
    fprintf(thread_stdout, "runtime-command");
    for (int i = 1; i < argc; i++) {
        fprintf(thread_stdout, ":%s", argv[i]);
    }
    fprintf(thread_stdout, "\n");
    return 0;
}

extern int sh_main(int argc, char **argv);

// A stop that lands after an `sh` command started but before its shell is
// running finds no shell to flag. Reproduce that ordering deterministically by
// stopping this command's own session before it enters the shell. Thread
// cancellation is disabled so ios_kill's pthread_cancel fallback cannot end
// this command early.
static int stop_then_shell_main(int argc, char **argv)
{
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    ios_kill();
    char *shell[] = {"sh", "-c", "echo should-not-run", NULL};
    return sh_main(3, shell);
}

typedef struct {
    const void *sessionName;
    FILE *input;
} native_caller_case;

// awk runs on a pthread-cancellable command thread, and its system() calls
// ios_system_osh from there.
static void *run_awk_system(void *context)
{
    native_caller_case *awkCase = context;
    ios_switchSession(awkCase->sessionName);
    ios_setStreams(awkCase->input, stdout, stderr);
    const char *command[] = {"awk", "BEGIN { system(\"cat\") }"};
    ios_system(2, command);
    return NULL;
}

typedef struct {
    const void *sessionName;
    int status;
} job_case;

// Starts a job the way the Bash tool does: its own opened session, which
// keeps cancellation requests, then a long command.
static void *run_sleep_job(void *context)
{
    job_case *job = context;
    ios_openSession(job->sessionName);
    ios_setStreams(stdin, stdout, stderr);
    const char *command[] = {"sleep", "10"};
    job->status = ios_system(2, command);
    return NULL;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();
        commandsAsArray();
        if (!ios_registerCommand("runtime-command", runtime_command_main) ||
            ios_registerCommand("runtime-command", runtime_command_main) ||
            ios_registerCommand("echo", runtime_command_main) ||
            !ios_executable("runtime-command") ||
            ![commandsAsArray() containsObject:@"runtime-command"] ||
            ![getoptString(@"runtime-command") isEqualToString:@""] ||
            ![operatesOn(@"runtime-command") isEqualToString:@"no"] ||
            ios_commandIsExclusiveOrThreadSafe("runtime-command") !=
                IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH ||
            ios_commandIsExclusiveOrThreadSafe("echo") !=
                IOS_COMMAND_ISOLATION_THREAD_SAFE) {
            fprintf(stderr, "Unable to register the runtime validation command.\n");
            return 1;
        }

        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *temporaryDirectory = NSProcessInfo.processInfo.environment[@"TEST_TMPDIR"]
            ?: NSTemporaryDirectory();
        NSURL *root = [NSURL fileURLWithPath:
            [temporaryDirectory stringByAppendingPathComponent:@"local-code-osh-validation"]
            isDirectory:YES];
        NSURL *documents = [root URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        NSURL *library = [root URLByAppendingPathComponent:@"Library" isDirectory:YES];
        NSURL *caches = [root URLByAppendingPathComponent:@"Caches" isDirectory:YES];
        NSURL *project = [root URLByAppendingPathComponent:@"Project" isDirectory:YES];
        NSURL *localCode = [project URLByAppendingPathComponent:@".localc" isDirectory:YES];
        for (NSURL *url in @[documents, library, caches, project, localCode]) {
            if (![fileManager createDirectoryAtURL:url
                       withIntermediateDirectories:YES attributes:nil error:nil]) {
                fprintf(stderr, "Unable to create validation directory: %s\n",
                    url.path.UTF8String);
                return 1;
            }
        }
        if (!ios_setSystemPaths(localCode, library, caches, root, project, root)) {
            fprintf(stderr, "Unable to configure ios_system paths.\n");
            return 1;
        }
        ios_setDirectoryURL(project);

        if (argc == 2 && strcmp(argv[1], "--validate-tee-write-error") == 0) {
            FILE *input = tmpfile(), *output = fopen("/dev/null", "r"), *error = tmpfile();
            if (input == NULL || output == NULL || error == NULL) {
                if (input != NULL) fclose(input);
                if (output != NULL) fclose(output);
                if (error != NULL) fclose(error);
                return 1;
            }
            char bytes[32768];
            memset(bytes, 'x', sizeof(bytes));
            fwrite(bytes, 1, sizeof(bytes), input);
            rewind(input);
            // The read-only stdout fails with EBADF. This ordinary write error
            // must not prevent tee from completing its healthy file output.
            ios_setStreams(input, output, error);
            int status = ios_system_osh("tee tee-surviving-output");
            ios_setStreams(stdin, stdout, stderr);
            fclose(input);
            fclose(output);
            fclose(error);
            NSData *contents = [NSData dataWithContentsOfURL:
                [project URLByAppendingPathComponent:@"tee-surviving-output"]];
            if (status != 1 || ![contents isEqualToData:[NSData dataWithBytes:bytes length:sizeof(bytes)]]) {
                fprintf(stderr, "tee did not complete its healthy output after a non-pipe write error.\n");
                return 1;
            }
            return 0;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-streaming-cwd") == 0) {
            NSURL *directory = [project URLByAppendingPathComponent:@"cwd-shell"];
            NSURL *nested = [directory URLByAppendingPathComponent:@"nested"];
            if (![fileManager createDirectoryAtURL:nested
                        withIntermediateDirectories:YES attributes:nil error:nil]) return 1;
            NSString *ready = [directory.path stringByAppendingPathComponent:@"cwd-ready"];
            unlink(ready.fileSystemRepresentation);
            if (mkfifo(ready.fileSystemRepresentation, 0600) != 0) return 1;
            int status = ios_system_osh(
                "cd cwd-shell; runtime-command --cwd nested | cmp -s - cwd-ready; "
                "[[ $? == 1 && ${PIPESTATUS[*]} == '0 1' ]] || exit 1; "
                "printf 'parent\\n' > cwd-parent; "
                "[[ -f nested/cwd-result && ! -e cwd-result && -f cwd-parent ]] ");
            unlink(ready.fileSystemRepresentation);
            NSString *parentOutput = [NSString stringWithContentsOfURL:
                [directory URLByAppendingPathComponent:@"cwd-parent"]
                encoding:NSUTF8StringEncoding error:nil];
            if (status != 0 || ![parentOutput isEqualToString:@"parent\n"] ||
                ![fileManager.currentDirectoryPath isEqualToString:project.path]) {
                fprintf(stderr, "Streaming pipeline did not preserve producer/shell directories.\n");
                return 1;
            }
            return 0;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-streaming-resolution") == 0) {
            // Discovery and dispatch must not overwrite each other's command
            // names. Check every pipeline's output, including both consumers.
            atomic_store(&resolutionValidationFinished, false);
            atomic_store(&resolutionValidationFailed, false);
            pthread_t discoveryThread;
            if (pthread_create(&discoveryThread, NULL, validate_command_discovery, NULL) != 0) {
                return 1;
            }
            int status = ios_system_osh(
                "set -e; set -o pipefail; "
                ": > resolution-first; : > resolution-second; "
                "for i in {1..32}; do "
                "runtime-command alpha beta gamma | tee -a resolution-first | tee -a resolution-second >/dev/null; done");
            atomic_store(&resolutionValidationFinished, true);
            pthread_join(discoveryThread, NULL);
            NSMutableString *expected = [NSMutableString string];
            for (int i = 0; i < 32; i++) {
                [expected appendString:@"runtime-command:alpha:beta:gamma\n"];
            }
            BOOL valid = status == 0 && !atomic_load(&resolutionValidationFailed);
            for (NSString *name in @[@"resolution-first", @"resolution-second"]) {
                NSString *output = [NSString stringWithContentsOfURL:
                    [project URLByAppendingPathComponent:name]
                    encoding:NSUTF8StringEncoding error:nil];
                valid = valid && [output isEqualToString:expected];
            }
            if (!valid) {
                fprintf(stderr, "Concurrent discovery/pipeline dispatch changed command resolution or output.\n");
            }
            return valid ? 0 : 1;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-streaming-pids") == 0) {
            pid_t parent = ios_currentPid();
            // Cross the 128-slot PID table boundary while stages overlap.
            int status = ios_system_osh(
                "set -e; set -o pipefail; export PIPELINE_MARKER=marker; "
                "for i in {1..44}; do "
                "runtime-command --pid marker | tee pid-first | tee pid-second >/dev/null; done");
            if (status != 0 || ios_currentPid() != parent) {
                fprintf(stderr, "Streaming pipeline corrupted virtual process state.\n");
                return 1;
            }
            NSString *output = [NSString stringWithContentsOfURL:
                [project URLByAppendingPathComponent:@"pid-second"]
                encoding:NSUTF8StringEncoding error:nil];
            return [output isEqualToString:@"runtime-command:--pid:marker\n"] ? 0 : 1;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-streaming-lifecycle") == 0) {
            // The host can start commands asynchronously; the shell pipeline
            // must still wait for each stage before releasing streams/session.
            joinMainThread = false;
            int status = ios_system_osh("runtime-command --slow alpha | tee lifecycle.out");
            joinMainThread = true;
            NSString *output = [NSString stringWithContentsOfURL:
                [project URLByAppendingPathComponent:@"lifecycle.out"]
                encoding:NSUTF8StringEncoding error:nil];
            if (status != 0 || ![output isEqualToString:@"runtime-command:--slow:alpha\n"]) {
                fprintf(stderr, "Streaming pipeline released its stage before completion.\n");
                return 1;
            }
            joinMainThread = false;
            status = ios_system_osh("set -o pipefail; runtime-command --slow beta | tee missing-directory/output >/dev/null");
            joinMainThread = true;
            if (status != 1) {
                fprintf(stderr, "Streaming pipeline lost its asynchronous exit status: %d.\n", status);
                return 1;
            }
            return 0;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-stop-before-shell-starts") == 0) {
            if (!ios_registerCommand("stop-then-shell", stop_then_shell_main)) return 1;
            const char *command[] = {"stop-then-shell"};
            int status = ios_system(1, command);
            if (status != 130) {
                fprintf(stderr, "A stop before the shell started was lost: status %d.\n", status);
                return 1;
            }
            // The next command on this session starts without the old stop.
            return ios_system_osh("echo recovered");
        }

        if (argc == 2 && strcmp(argv[1], "--validate-cancelled-native-caller") == 0) {
            // Stop awk while its system() shell blocks reading a pipe, then let
            // the shell finish. awk must not unwind while its shell still runs.
            int descriptors[2];
            if (pipe(descriptors) != 0) return 1;
            static char sessionName[] = "osh-validation-cancelled-native-caller";
            native_caller_case awkCase = {
                .sessionName = sessionName,
                .input = fdopen(descriptors[0], "r"),
            };
            pthread_t thread;
            if (awkCase.input == NULL ||
                pthread_create(&thread, NULL, run_awk_system, &awkCase) != 0) return 1;
            usleep(300000);
            ios_switchSession(sessionName);
            ios_kill();
            usleep(100000);
            close(descriptors[1]);
            pthread_join(thread, NULL);
            usleep(300000); // Any shell still running on borrowed state finishes here.
            ios_setStreams(stdin, stdout, stderr);
            return ios_system_osh("echo recovered");
        }

        if (argc == 2 && strcmp(argv[1], "--validate-job-cancellation") == 0) {
            // A job session stopped before its first command starts nothing,
            // through either entry point.
            static char stoppedJob[] = "osh-validation-stopped-job";
            ios_openSession(stoppedJob);
            ios_kill();
            const char *command[] = {"runtime-command", "should-not-run"};
            int direct = ios_system(2, command);
            int shell = ios_system_osh("runtime-command should-not-run");
            if (direct != 130 || shell != 130) {
                fprintf(stderr, "Stopped job ran commands: %d %d.\n", direct, shell);
                return 1;
            }
            // A reused session still drops a stop from before its command.
            static char reusedSession[] = "osh-validation-reused-session";
            ios_switchSession(reusedSession);
            ios_kill();
            if (ios_system_osh("runtime-command reused") != 0) return 1;

            // Stop jobs at increasing delays while they start, covering the
            // window before each command can be interrupted. A lost stop
            // leaves `sleep 10` running.
            static char sessions[200][48];
            for (int i = 0; i < 200; i++) {
                snprintf(sessions[i], sizeof(sessions[i]), "osh-validation-job-%d", i);
                job_case job = {.sessionName = sessions[i], .status = -1};
                pthread_t thread;
                if (pthread_create(&thread, NULL, run_sleep_job, &job) != 0) return 1;
                usleep(i * 10);
                ios_switchSession(sessions[i]);
                ios_kill();
                NSDate *stopped = [NSDate date];
                pthread_join(thread, NULL);
                NSTimeInterval elapsed = -stopped.timeIntervalSinceNow;
                if (elapsed > 3) {
                    fprintf(stderr, "Job stopped after %d us kept running for %.1f s (status %d).\n",
                            i * 10, elapsed, job.status);
                    return 1;
                }
            }
            return 0;
        }

        if (argc == 2 && strcmp(argv[1], "--validate-signal-isolation") == 0) {
            // Commands run on host threads. A returning SIGSEGV handler, as sort
            // once installed, re-runs any faulting app thread's instruction forever.
            const int signals[] = {
                SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGPIPE,
                SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2,
            };
            const int count = sizeof(signals) / sizeof(signals[0]);
            struct sigaction dispositions[sizeof(signals) / sizeof(signals[0])];
            for (int i = 0; i < count; i++) {
                if (sigaction(signals[i], NULL, &dispositions[i]) != 0) {
                    perror("Unable to read signal disposition");
                    return 1;
                }
            }
            // A 1-byte buffer spills every line to a temporary file before merging.
            // A missing second input then fails sort after spilling, so only the
            // thread cleanup handler can remove those temporary files.
            int status = ios_system_osh(
                "uname >/dev/null && mkdir -p sort-tmp && "
                "printf 'c\\nb\\na\\n' | sort -S 1b -T sort-tmp > sorted && "
                "[[ $(cat sorted) == $'a\\nb\\nc' && -z $(ls -A sort-tmp) ]] && "
                "! printf 'c\\nb\\na\\n' | sort -S 1b -T sort-tmp - missing-input 2>/dev/null && "
                "[[ -z $(ls -A sort-tmp) ]]");
            if (status != 0) {
                fprintf(stderr, "Signal-isolation command failed with status %d.\n", status);
                return status;
            }
            for (int i = 0; i < count; i++) {
                struct sigaction currentDisposition;
                if (sigaction(signals[i], NULL, &currentDisposition) != 0) {
                    perror("Unable to read signal disposition");
                    return 1;
                }
                if (currentDisposition.sa_handler != dispositions[i].sa_handler) {
                    fprintf(stderr, "Command changed disposition for signal %d.\n", signals[i]);
                    return 1;
                }
            }
            return 0;
        }

        const char *command = argc > 1 ? argv[1] :
            "x=parent; y=$(x=child; echo \"$x\"); "
            "printf '%s %s\\n' \"$x\" \"$y\"";
        return ios_system_osh(command);
    }
}
