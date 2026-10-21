#import "OfficeCommand.h"
#import "ios_system/ios_system.h"

#include <limits.h>
#include <pthread.h>
#include <TargetConditionals.h>

int office_main(int argc, char **argv)
{
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    int status = 1;
    @autoreleasepool {
        BOOL information = argc < 2
            || (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h")
                || !strcmp(argv[1], "help") || !strcmp(argv[1], "--version") || !strcmp(argv[1], "capabilities")))
            || (argc == 3 && ((!strcmp(argv[1], "capabilities") && !strcmp(argv[2], "--json"))
                || ((!strcmp(argv[1], "convert") || !strcmp(argv[1], "recalculate") || !strcmp(argv[1], "render"))
                    && (!strcmp(argv[2], "--help") || !strcmp(argv[2], "-h")))));
        if (information) {
            const OfficeCommandContext context = {.output = thread_stdout, .error = thread_stderr};
            status = OfficeCommandRun(argc, argv, &context);
        } else {
            char directory[PATH_MAX], bundle[PATH_MAX] = "";
            const char *pwd = ios_getenv("PWD");
            ios_resolveDirectoryAlias("/app_bundle", bundle, sizeof(bundle));
            __attribute__((objc_precise_lifetime)) NSString *program = ios_officeProgramPath();
            if (!program && bundle[0]) {
                program = [[NSString stringWithUTF8String:bundle] stringByAppendingPathComponent:
#if TARGET_OS_IPHONE
                    @"office/program"];
#else
                    @"office/Frameworks"];
#endif
            }
            if (pwd && strlcpy(directory, pwd, sizeof(directory)) < sizeof(directory) && program) {
                __attribute__((objc_precise_lifetime)) NSString *runtime =
                    [NSTemporaryDirectory() stringByAppendingPathComponent:@"office"];
                __attribute__((objc_precise_lifetime)) NSString *cache =
                    [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]
                        stringByAppendingPathComponent:@"office/fonts"];
                NSError *error = nil;
                if ([NSFileManager.defaultManager createDirectoryAtPath:runtime withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
                    OfficeCommandContext context = {
                        .output = thread_stdout, .directory = directory,
                        .programDirectory = program.UTF8String, .temporaryDirectory = runtime.UTF8String,
                        .cancellation = ios_getCommandCancellationContext(), .isCancelled = ios_commandCancellationRequested,
                        .error = thread_stderr, .cacheDirectory = cache.UTF8String,
                    };
                    // Alias resolution needs caller TLS. Keep original virtual
                    // paths separately for agent-visible result metadata.
                    __attribute__((objc_precise_lifetime)) NSMutableArray<NSString *> *arguments =
                        [NSMutableArray arrayWithCapacity:argc];
                    char **pointers = calloc((size_t)argc + 1, sizeof(char *));
                    BOOL valid = pointers != NULL;
                    for (int i = 0; valid && i < argc; ++i) {
                        const char *value = argv[i];
                        char resolved[PATH_MAX];
                        if (i >= 3 && (i % 2) == 1) {
                            BOOL input = !strcmp(argv[i - 1], "--input");
                            BOOL output = !strcmp(argv[i - 1], "--output") || !strcmp(argv[i - 1], "--output-dir");
                            if (input) context.inputPath = value;
                            if (output) context.outputPath = value;
                            if (input || output || !strcmp(argv[i - 1], "--font-directory")) {
                                int result = ios_resolveDirectoryAlias(value, resolved, sizeof(resolved));
                                if (result < 0 || (result == 2 && output)) {
                                    fprintf(thread_stderr, "{\"ok\":false,\"code\":\"failed\",\"error\":\"Invalid or read-only output path\"}\n");
                                    valid = NO; break;
                                }
                                if (result > 0) value = resolved;
                            }
                        }
                        NSString *argument = [NSString stringWithUTF8String:value];
                        if (!argument) { valid = NO; break; }
                        [arguments addObject:argument]; pointers[i] = (char *)argument.UTF8String;
                    }
                    if (valid) status = OfficeCommandRun(argc, pointers, &context);
                    free(pointers);
                } else {
                    fprintf(thread_stderr, "{\"ok\":false,\"code\":\"failed\",\"error\":\"Cannot create office runtime directory\"}\n");
                }
            } else {
                fprintf(thread_stderr, "{\"ok\":false,\"code\":\"unavailable\",\"error\":\"Missing host working directory or bundle resources\"}\n");
            }
        }
    }
    pthread_setcancelstate(previous, NULL);
    return status;
}
