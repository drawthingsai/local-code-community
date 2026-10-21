#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#import "ios_system/ios_system.h"
#include "ios_system_command_registry.h"
#include "NativeCommandValidation.h"
#include <fcntl.h>
#include <locale.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>

static NSString *root;
static NSMutableArray<NSString *> *failures;
static NSUInteger checks;

static NSData *bytes(NSString *string)
{
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static void check(BOOL condition, NSString *name)
{
    ++checks;
    if (!condition) {
        [failures addObject:name];
        fprintf(stderr, "FAIL: %s\n", name.UTF8String);
    }
}

static NSString *path(NSString *name)
{
    return [root stringByAppendingPathComponent:name];
}

static void writeFixture(NSString *name, NSData *data)
{
    NSError *error = nil;
    check([data writeToFile:path(name) options:0 error:&error],
        [NSString stringWithFormat:@"write fixture %@: %@", name, error]);
}

static NSData *readStream(FILE *stream)
{
    fflush(stream);
    rewind(stream);
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), stream)) != 0)
        [data appendBytes:buffer length:count];
    return data;
}

static NSDictionary *run(NSArray<NSString *> *arguments, NSData *input)
{
    FILE *in = tmpfile(), *out = tmpfile(), *error = tmpfile();
    if (in == NULL || out == NULL || error == NULL) abort();
    if (input != nil) fwrite(input.bytes, 1, input.length, in);
    rewind(in);
    ios_setStreams(in, out, error);
    const char **argv = calloc(arguments.count, sizeof(*argv));
    for (NSUInteger index = 0; index < arguments.count; ++index)
        argv[index] = arguments[index].UTF8String;
    int status = ios_system((int)arguments.count, argv);
    free(argv);
    NSData *output = readStream(out), *diagnostics = readStream(error);
    ios_setStreams(stdin, stdout, stderr);
    fclose(in); fclose(out); fclose(error);
    return @{ @"status": @(status), @"stdout": output, @"stderr": diagnostics };
}

static NSDictionary *expect(NSString *name, NSArray<NSString *> *arguments,
    NSData *input, NSData *output, int status)
{
    NSDictionary *result = run(arguments, input);
    int actualStatus = [result[@"status"] intValue];
    BOOL success = (status < 0 ? actualStatus != 0 : actualStatus == status) &&
        (output == nil || [output isEqual:result[@"stdout"]]);
    if (!success) {
        NSString *actual = [[NSString alloc] initWithData:result[@"stdout"]
            encoding:NSUTF8StringEncoding];
        NSString *diagnostics = [[NSString alloc] initWithData:result[@"stderr"]
            encoding:NSUTF8StringEncoding];
        fprintf(stderr, "  command=%s status=%d output=%s stderr=%s\n",
            [[arguments componentsJoinedByString:@" "] UTF8String], actualStatus,
            (actual ?: @"<binary>").UTF8String, (diagnostics ?: @"<binary>").UTF8String);
    }
    check(success, name);
    return result;
}

static void expectText(NSString *name, NSArray<NSString *> *arguments,
    NSString *input, NSString *output, int status)
{
    expect(name, arguments, bytes(input), output != nil ? bytes(output) : nil, status);
}

static NSUInteger descriptorCount(void)
{
    NSUInteger count = 0;
    for (int fd = 0; fd < 1024; ++fd)
        if (fcntl(fd, F_GETFD) != -1) ++count;
    return count;
}

struct direct_invocation {
    const ios_command_entry *command;
    int argc;
    char **argv;
    FILE *input, *output, *error;
};

static void *invokeEntry(void *opaque)
{
    struct direct_invocation *invocation = opaque;
    thread_stdin = invocation->input;
    thread_stdout = invocation->output;
    thread_stderr = invocation->error;
    int status = invocation->command->function(invocation->argc, invocation->argv);
    return (void *)(intptr_t)status;
}

/* The functional tests use ios_system. These additional tests deliberately
 * overlap registry entries to stress TLS and stream ownership. */
static void validateEntryLifetime(void)
{
    NSUInteger initialDescriptors = descriptorCount();
    NSArray *cases = @[@[@"cut", @"-c", @"2"], @[@"base64", @"-w", @"0"],
        @[@"comm", @"-12", @"left.txt", @"right.txt"]];
    NSArray *outputs = @[@"b\n", @"YWJjCg==", @"a\nd\n"];
    for (int round = 0; round < 12; ++round) {
        struct direct_invocation invocations[3] = {0};
        pthread_t threads[3];
        for (int index = 0; index < 3; ++index) {
            NSArray<NSString *> *arguments = cases[index];
            struct direct_invocation *invocation = &invocations[index];
            invocation->command = ios_command_lookup([arguments[0] UTF8String]);
            invocation->argc = (int)arguments.count;
            invocation->argv = calloc(arguments.count + 1, sizeof(char *));
            for (NSUInteger arg = 0; arg < arguments.count; ++arg)
                invocation->argv[arg] = strdup(arguments[arg].UTF8String);
            invocation->input = tmpfile(); invocation->output = tmpfile(); invocation->error = tmpfile();
            fwrite("abc\n", 1, 4, invocation->input); rewind(invocation->input);
            if (pthread_create(&threads[index], NULL, invokeEntry, invocation) != 0) abort();
        }
        for (int index = 0; index < 3; ++index) {
            void *status;
            pthread_join(threads[index], &status);
            struct direct_invocation *invocation = &invocations[index];
            check((intptr_t)status == 0 && [readStream(invocation->output) isEqual:bytes(outputs[index])],
                @"concurrent entries preserve arguments and streams");
            fclose(invocation->input); fclose(invocation->output); fclose(invocation->error);
            for (int arg = 0; arg < invocation->argc; ++arg) free(invocation->argv[arg]);
            free(invocation->argv);
        }
    }
    check(descriptorCount() == initialDescriptors, @"concurrent entries release descriptors");

}

struct session_validation {
    int index;
    BOOL archives;
    pthread_mutex_t *mutex;
    pthread_cond_t *condition;
    int *arrived;
    int *generation;
    void *result;
};

static void sessionBarrier(struct session_validation *worker)
{
    pthread_mutex_lock(worker->mutex);
    int generation = *worker->generation;
    if (++*worker->arrived == 8) {
        *worker->arrived = 0;
        ++*worker->generation;
        pthread_cond_broadcast(worker->condition);
    } else {
        while (generation == *worker->generation)
            pthread_cond_wait(worker->condition, worker->mutex);
    }
    pthread_mutex_unlock(worker->mutex);
}

static void *validateSession(void *opaque)
{
    struct session_validation *worker = opaque;
    @autoreleasepool {
        NSMutableArray *errors = [NSMutableArray array];
        NSString *directory = path([NSString stringWithFormat:@"session-%d", worker->index]);
        char session[64];
        snprintf(session, sizeof(session), "native-session-%d", worker->index);
        ios_switchSession(session);
        ios_setContext(session);
        ios_setDirectoryURL([NSURL fileURLWithPath:directory isDirectory:YES]);
        NSString *token = [NSString stringWithFormat:@"%d", worker->index];
        NSString *line = [token stringByAppendingString:@"é\n"];
        NSString *base64 = [bytes(line) base64EncodedStringWithOptions:0];
        NSString *selected = worker->index % 2 ? @"é\n" : [token stringByAppendingString:@"\n"];
        NSString *column = worker->index % 2 ? @"2" : @"1";
        NSString *delimiter = worker->index % 2 ? @"é" : @"|";
        NSString *filename = [@"item" stringByAppendingString:token];
        NSString *absolute = [directory stringByAppendingPathComponent:@"input"];
        NSString *digest = @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        // Each row has argv, stdin, stdout, status. Different sessions use the
        // same relative filenames with distinct content and option values.
        NSArray *cases = @[
            @[@[@"jq", @"-Rr", @"capture(\"(?<n>[0-9]+)\").n", @"input"], @"", [token stringByAppendingString:@"\n"], @0],
            @[@[@"jq", @"-L", @".", @"-nf", @"jq-filter.jq"], @"", [token stringByAppendingString:@"\n"], @0],
            @[@[@"jq", @"-nr", @"env.PWD"], @"", [directory stringByAppendingString:@"\n"], @0],
            @[@[@"jq", @"-ne", worker->index % 2 ? @"false" : @"true"], @"", worker->index % 2 ? @"false\n" : @"true\n", @(worker->index % 2)],
            @[@[@"basename", @"-s", @".txt", [filename stringByAppendingString:@".txt"]], @"", filename, @0],
            @[@[@"dirname", [@"dir/" stringByAppendingString:filename]], @"", @"dir", @0],
            @[@[@"realpath", @"input"], @"", absolute, @0],
            @[@[@"cut", @"-c", column, @"input"], @"", selected, @0],
            @[@[@"cut", @"-f", @"2", @"-d", @"é"], [token stringByAppendingString:@"éyes\n"], @"yes\n", @0],
            @[@[@"comm", @"-12", @"input", @"input"], @"", line, @0],
            @[@[@"paste", @"-d", @"é", @"input", @"input"], @"",
                [NSString stringWithFormat:@"%@éé%@é\n", token, token], @0],
            @[@[@"join", @"-t", delimiter, @"join-input", @"join-input"], @"",
                [NSString stringWithFormat:@"%@%@v%@v\n", token, delimiter, delimiter], @0],
            @[@[@"split", @"-b", @"1", @"input", @"piece"], @"", @"", @0],
            @[@[@"cmp", @"-s", @"input", @"input"], @"", @"", @0],
            @[@[@"diff", @"-r", @"tree", @"copy"], @"", @"", @0],
            @[@[@"diff", @"-I", @"ignored", @"-q", @"tree", @"copy"], @"", @"", @0],
            @[@[@"xxd", @"-p", @"checksum-input"], @"", @"616263\n", @0],
            @[@[@"xxd", @"-r", @"-p", @"-", @"decoded"], @"616263\n", @"", @0],
            @[@[@"base64", @"-w", @"0", @"input"], @"", base64, @0],
            @[@[@"sha256sum", @"checksum-input"], @"", [digest stringByAppendingString:@"  checksum-input\n"], @0],
            @[@[@"sha256sum", @"--status", @"-c"], [digest stringByAppendingString:@"  checksum-input\n"], @"", @0],
            @[@[@"base64", @"-d"], base64, line, @0],
            @[@[@"cut", @"-c", worker->index % 2 ? @"0" : @"1", @"input"], @"",
                worker->index % 2 ? @"" : [token stringByAppendingString:@"\n"], @(worker->index % 2)],
            @[@[@"mktemp", @"temporary.XXXXXXXX"], @"", @"", @0],
            @[@[@"mktemp", @"-d", @"directory.XXXXXXXX"], @"", @"", @0],
            @[@[@"mktemp", @"-du", @"unused.XXXXXXXX"], @"", @"", @0],
            @[@[@"join", @"join-default", @"join-default"], @"",
                [token stringByAppendingString:@" v v\n"], @0],
        ];
        // Overlap creation, extraction, and nested -T verification across
        // independent sessions, including identical relative archive names.
        if (worker->archives) cases = @[
            @[@[@"zip", @"-q", worker->index % 2 ? @"-0" : @"-9", @"session.zip", @"input"], @"", @"", @0],
            @[@[@"zip", @"-q", @"-P", token, @"encrypted.zip", @"input"], @"", @"", @0],
            @[@[@"zip", @"-qT", @"verified.zip", @"input"], @"", @"", @0],
            @[@[@"unzip", @"-p", @"session.zip", @"input"], @"", [token stringByAppendingString:@"é\n"], @0],
            @[@[@"unzip", @"-P", token, @"-p", @"encrypted.zip", @"input"], @"", [token stringByAppendingString:@"é\n"], @0],
            @[@[@"unzip", @"-qo", @"session.zip", @"-d", @"unpacked"], @"", @"", @0],
            @[@[@"unzip", @"-qo", @"dos.zip", @"-d", @"dos-out"], @"", @"", @0],
        ];
        for (int round = 0; round < 4; ++round) {
            for (NSUInteger index = 0; index < cases.count; ++index) {
                sessionBarrier(worker);
                NSArray *test = cases[index];
                NSArray *arguments = test[0];
                NSString *command = arguments[0];
                NSDictionary *result = run(arguments, bytes(test[1]));
                NSData *expected = bytes(test[2]);
                if ([@[@"basename", @"dirname", @"realpath"] containsObject:command]) expected = bytes([test[2] stringByAppendingString:@"\n"]);
                BOOL valid = [result[@"status"] intValue] == [test[3] intValue];
                if ([command isEqualToString:@"mktemp"]) {
                    BOOL isDirectory = [arguments containsObject:@"-d"];
                    BOOL isUnused = [arguments containsObject:@"-du"];
                    NSString *created = [[[NSString alloc] initWithData:result[@"stdout"]
                        encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
                    NSString *createdPath = [directory stringByAppendingPathComponent:created];
                    struct stat info;
                    valid &= created.length > 0 && !created.isAbsolutePath;
                    if (isUnused) valid &= lstat(createdPath.UTF8String, &info) != 0;
                    else {
                        valid &= lstat(createdPath.UTF8String, &info) == 0 &&
                            (info.st_mode & 0777) == (isDirectory ? 0700 : 0600);
                        if (isDirectory) rmdir(createdPath.UTF8String);
                        else unlink(createdPath.UTF8String);
                    }
                } else valid &= [result[@"stdout"] isEqual:expected];
                if ([command isEqualToString:@"split"]) valid &= [[NSData dataWithContentsOfFile:
                    [directory stringByAppendingPathComponent:@"pieceaa"]] isEqual:bytes(token)];
                if ([command isEqualToString:@"xxd"] && [arguments containsObject:@"-r"]) valid &= [[NSData dataWithContentsOfFile:
                    [directory stringByAppendingPathComponent:@"decoded"]] isEqual:bytes(@"abc")];
                if ([test[3] intValue] == 0) valid &= [result[@"stderr"] length] == 0;
                if (!valid) [errors addObject:[NSString stringWithFormat:
                    @"session %d round %d %@: %@", worker->index, round, test[0], result]];
            }
        }
        sessionBarrier(worker);
        ios_closeSession(session);
        worker->result = (__bridge_retained void *)errors;
    }
    return NULL;
}

static void validateConcurrentSessions(void)
{
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
    int arrived = 0, generation = 0;
    struct session_validation workers[8] = {0};
    pthread_t threads[8];
    for (int index = 0; index < 8; ++index) {
        NSString *directory = [NSString stringWithFormat:@"session-%d", index];
        for (NSString *suffix in @[@"tree", @"copy"])
            check([NSFileManager.defaultManager createDirectoryAtPath:path([directory stringByAppendingPathComponent:suffix])
                withIntermediateDirectories:YES attributes:nil error:nil], @"create concurrent session fixture");
        NSString *line = [NSString stringWithFormat:@"%dé\n", index];
        for (NSString *suffix in @[@"input", @"tree/input", @"copy/input"])
            writeFixture([directory stringByAppendingPathComponent:suffix], bytes(line));
        writeFixture([directory stringByAppendingPathComponent:@"checksum-input"], bytes(@"abc"));
        writeFixture([directory stringByAppendingPathComponent:@"join-input"],
            bytes([NSString stringWithFormat:@"%d%@v\n", index, index % 2 ? @"é" : @"|"]));
        writeFixture([directory stringByAppendingPathComponent:@"join-default"],
            bytes([NSString stringWithFormat:@"%d v\n", index]));
        // Stored ZIP with DOS directory/file attributes, not archived Unix modes.
        writeFixture([directory stringByAppendingPathComponent:@"dos.zip"],
            [[NSData alloc] initWithBase64EncodedString:@"UEsDBBQAAAAAAAAAIQAAAAAAAAAAAAAAAAAKAAAAZGlyZWN0b3J5L1BLAwQUAAAAAAAAACEAG7xgHAwAAAAMAAAADgAAAGRpcmVjdG9yeS9kYXRhZG9zIGZpeHR1cmUKUEsBAhQAFAAAAAAAAAAhAAAAAAAAAAAAAAAAAAoAAAAAAAAAAAAQAAAAAAAAAGRpcmVjdG9yeS9QSwECFAAUAAAAAAAAACEAG7xgHAwAAAAMAAAADgAAAAAAAAAAACAAAAAoAAAAZGlyZWN0b3J5L2RhdGFQSwUGAAAAAAIAAgB0AAAAYAAAAAAA" options:0]);
        writeFixture([directory stringByAppendingPathComponent:@"jq-filter.jq"], bytes(@"include \"value\"; value"));
        writeFixture([directory stringByAppendingPathComponent:@"value.jq"],
            bytes([NSString stringWithFormat:@"def value: %d;", index]));
        workers[index] = (struct session_validation){
            .index = index, .mutex = &mutex, .condition = &condition,
            .arrived = &arrived, .generation = &generation,
        };
    }
    NSUInteger initialDescriptors = descriptorCount();
    NSString *processLocale = [NSString stringWithUTF8String:setlocale(LC_ALL, NULL)];
    // A safe invocation must not reset getopt used by another command family.
    optind = 73; opterr = 0; optreset = 0; optopt = 'Q';
    char sentinel[] = "legacy-option";
    optarg = sentinel;
    for (int index = 0; index < 8; ++index)
        if (pthread_create(&threads[index], NULL, validateSession, &workers[index]) != 0) abort();
    for (int index = 0; index < 8; ++index) {
        pthread_join(threads[index], NULL);
        NSArray *errors = (__bridge_transfer NSArray *)workers[index].result;
        check(errors.count == 0, [NSString stringWithFormat:@"concurrent session %d: %@", index, errors]);
    }
    check(optind == 73 && opterr == 0 && optreset == 0 && optopt == 'Q' && optarg == sentinel,
        @"thread-safe entries preserve legacy getopt state");
    for (int index = 0; index < 8; ++index) {
        workers[index].archives = YES;
        if (pthread_create(&threads[index], NULL, validateSession, &workers[index]) != 0) abort();
    }
    for (int index = 0; index < 8; ++index) {
        pthread_join(threads[index], NULL);
        NSArray *errors = (__bridge_transfer NSArray *)workers[index].result;
        check(errors.count == 0, [NSString stringWithFormat:@"concurrent archive session %d: %@", index, errors]);
    }
    check(optind == 73 && opterr == 0 && optreset == 0 && optopt == 'Q' && optarg == sentinel,
        @"concurrent archives and nested verification preserve legacy getopt state");
    optind = 1; opterr = 1; optreset = 1; optopt = 0; optarg = NULL;
    check(descriptorCount() == initialDescriptors, @"concurrent sessions release descriptors");
    check([processLocale isEqualToString:[NSString stringWithUTF8String:setlocale(LC_ALL, NULL)]],
        @"concurrent native commands preserve the process locale");
    pthread_cond_destroy(&condition);
    pthread_mutex_destroy(&mutex);
    ios_setDirectoryURL([NSURL fileURLWithPath:root isDirectory:YES]);
    for (int index = 0; index < 8; ++index) {
        NSString *token = [NSString stringWithFormat:@"%d", index];
        NSString *output = [token stringByAppendingString:@"é\n"];
        NSString *archive = [NSString stringWithFormat:@"session-%d/session.zip", index];
        check([[NSData dataWithContentsOfFile:path([NSString stringWithFormat:@"session-%d/unpacked/input", index])]
            isEqual:bytes(output)], @"concurrent unzip extracted contents");
        check([[NSData dataWithContentsOfFile:path([NSString stringWithFormat:@"session-%d/dos-out/directory/data", index])]
            isEqual:bytes(@"dos fixture\n")], @"concurrent DOS unzip contents");
        expectText(@"concurrent zip contents", @[@"unzip", @"-p", archive, @"input"], @"", output, 0);
        archive = [NSString stringWithFormat:@"session-%d/encrypted.zip", index];
        expectText(@"concurrent zip encryption", @[@"unzip", @"-P", token, @"-p", archive, @"input"], @"", output, 0);
    }
}

struct system_paths_validation {
    int index;
    BOOL configured;
};

static void *configureSystemPaths(void *opaque)
{
    struct system_paths_validation *worker = opaque;
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:root isDirectory:YES];
        worker->configured = YES;
        // Mirror LocalCode's BashJob setup: every job configures the shared
        // $PATH and $PYTHONPATH from its own session thread.
        for (int round = 0; round < 200; ++round) {
            char session[64];
            snprintf(session, sizeof(session), "native-paths-%d", worker->index);
            ios_switchSession(session);
            worker->configured &= ios_setSystemPaths([directory URLByAppendingPathComponent:@".localc"],
                [directory URLByAppendingPathComponent:@"Library"],
                [directory URLByAppendingPathComponent:@"Caches"], directory, directory, directory) != 0;
            ios_setDirectoryURL(directory);
            ios_closeSession(session);
        }
    }
    return NULL;
}

static void *switchSessionInDeletedDirectory(void *opaque)
{
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:root isDirectory:YES];
        char session[] = "native-deleted-directory";
        ios_switchSession(session);
        BOOL configured = ios_setSystemPaths([directory URLByAppendingPathComponent:@".localc"],
            [directory URLByAppendingPathComponent:@"Library"],
            [directory URLByAppendingPathComponent:@"Caches"], directory, directory, directory) != 0;
        const char *current = ios_getenv("PWD");
        *(BOOL *)opaque = configured && current != NULL && strcmp(current, root.UTF8String) == 0;
        ios_closeSession(session);
    }
    return NULL;
}

static void validateConcurrentSystemPaths(void)
{
    struct system_paths_validation workers[8] = {0};
    pthread_t threads[8];
    for (int index = 0; index < 8; ++index) {
        workers[index].index = index;
        if (pthread_create(&threads[index], NULL, configureSystemPaths, &workers[index]) != 0) abort();
    }
    for (int index = 0; index < 8; ++index) {
        pthread_join(threads[index], NULL);
        check(workers[index].configured, [NSString stringWithFormat:@"concurrent system paths %d", index]);
    }

    // A command can delete the process working directory; the next session
    // starts in its project instead.
    NSString *removed = path(@"removed-working-directory");
    check(mkdir(removed.UTF8String, 0700) == 0 && chdir(removed.UTF8String) == 0 &&
        rmdir(removed.UTF8String) == 0, @"remove process working directory");
    BOOL started = NO;
    pthread_t thread;
    if (pthread_create(&thread, NULL, switchSessionInDeletedDirectory, &started) != 0) abort();
    pthread_join(thread, NULL);
    check(started, @"session starts in its project after the working directory is deleted");
    ios_setDirectoryURL([NSURL fileURLWithPath:root isDirectory:YES]);
}

static void validateJQ(void)
{
    expectText(@"jq version", @[@"jq", @"--version"], @"", @"jq-1.8.2\n", 0);
    NSDictionary *help = expect(@"jq help", @[@"jq", @"--help"], bytes(@""), nil, 0);
    check([[[NSString alloc] initWithData:help[@"stdout"] encoding:NSUTF8StringEncoding]
        containsString:@"--slurpfile"], @"jq exposes upstream CLI help");
    expectText(@"jq compact sorted objects", @[@"jq", @"-Sc", @"."], @"{\"z\":1,\"a\":2}", @"{\"a\":2,\"z\":1}\n", 0);
    expectText(@"jq filtering and updates", @[@"jq", @"-c", @"map(select(.n > 1) | .n *= 2)"],
        @"[{\"n\":1},{\"n\":3}]", @"[{\"n\":6}]\n", 0);
    expectText(@"jq raw Unicode", @[@"jq", @"-r", @".[]"], @"[\"é中🙂\",\"ok\"]", @"é中🙂\nok\n", 0);
    expectText(@"jq ASCII escaping", @[@"jq", @"-a", @"."], @"\"é\"", @"\"\\u00e9\"\n", 0);
    expectText(@"jq raw slurp", @[@"jq", @"-Rsc", @"split(\"\\n\")"], @"a\nb\n", @"[\"a\",\"b\",\"\"]\n", 0);
    expectText(@"jq JSON slurp", @[@"jq", @"-s", @"add"], @"1\n2\n3", @"6\n", 0);
    expectText(@"jq join output", @[@"jq", @"-j", @".[]"], @"[\"a\",\"b\"]", @"ab", 0);
    expect(@"jq NUL output", @[@"jq", @"--raw-output0", @".[]"], bytes(@"[\"a\",\"b\"]"),
        [NSData dataWithBytes:"a\0b\0" length:4], 0);
    expectText(@"jq embedded NUL rejected in output0", @[@"jq", @"--raw-output0", @"."], @"\"a\\u0000b\"", @"", 5);
    expectText(@"jq named arguments", @[@"jq", @"-nc", @"--arg", @"x", @"é", @"--argjson", @"n", @"2", @"[$x,$n,$ARGS.named.x]"],
        @"", @"[\"é\",2,\"é\"]\n", 0);
    expectText(@"jq positional strings", @[@"jq", @"-nc", @"--args", @"$ARGS.positional", @"a", @"--", @"-b"], @"", @"[\"a\",\"-b\"]\n", 0);
    expectText(@"jq positional JSON", @[@"jq", @"-nc", @"--jsonargs", @"$ARGS.positional", @"1", @"true"], @"", @"[1,true]\n", 0);
    expectText(@"jq literal number precision", @[@"jq", @"-c", @"."], @"[123456789012345678901,1.0000000000000000001]", @"[123456789012345678901,1.0000000000000000001]\n", 0);
    expectText(@"jq regex named capture", @[@"jq", @"-c", @"capture(\"(?<word>\\\\p{L}+)\")"], @"\"é中 42\"", @"{\"word\":\"é中\"}\n", 0);
    expectText(@"jq regex substitution", @[@"jq", @"-r", @"gsub(\"[0-9]+\"; \"X\")"], @"\"a12b3\"", @"aXbX\n", 0);
    expectText(@"jq streaming", @[@"jq", @"--stream", @"-c", @"."], @"[1,2]", @"[[0],1]\n[[1],2]\n[[1]]\n", 0);
    expectText(@"jq sequence", @[@"jq", @"--seq", @"-c", @"."], @"\0361\n\0362\n", @"\0361\n\0362\n", 0);
    expectText(@"jq input iterator", @[@"jq", @"-nc", @"[inputs]"], @"1\n2\n", @"[1,2]\n", 0);
    expectText(@"jq UTC date format", @[@"jq", @"-nr", @"0 | strftime(\"%Y-%m-%d %H:%M:%S %z %%z %Ez %Oz\")"],
        @"", @"1970-01-01 00:00:00 +0000 %z +0000 +0000\n", 0);
    expectText(@"jq depth limit on command stack", @[@"jq", @"-n", @"reduce range(10001) as $_ ([];[.]) | tojson | contains(\"<skipped: too deep>\")"], @"", @"true\n", 0);
    expectText(@"jq UTC parsing", @[@"jq", @"-n", @"\"2020-01-02T03:04:05Z\" | fromdateiso8601"], @"", @"1577934245\n", 0);
    expectText(@"jq reentrant gamma", @[@"jq", @"-n", @"1 | lgamma"], @"", @"0\n", 0);
    for (NSArray *row in @[@[@"true", @0], @[@"false", @1], @[@"null", @1], @[@"empty", @4],
        @[@"error(\"stop\")", @5], @[@"halt_error(7)", @7], @[@"halt", @0], @[@"[", @3]])
        expectText(@"jq exit status", @[@"jq", @"-ne", row[0]], @"", nil, [row[1] intValue]);
    expectText(@"jq invalid option", @[@"jq", @"--no-such-option"], @"", @"", 2);
    expectText(@"jq invalid JSON arg", @[@"jq", @"--argjson", @"x", @"bad", @"$x"], @"", @"", 2);
    expectText(@"jq malformed JSON input", @[@"jq", @"."], @"{bad", @"", 5);
    expectText(@"jq invalid regex", @[@"jq", @"-n", @"\"x\" | test(\"[\")"], @"", @"", 5);
    expectText(@"jq tab indentation", @[@"jq", @"--tab", @"."], @"[1]", @"[\n\t1\n]\n", 0);
    expectText(@"jq explicit indentation", @[@"jq", @"--indent", @"1", @"."], @"[1]", @"[\n 1\n]\n", 0);
    expectText(@"jq missing input", @[@"jq", @".", @"missing.json"], @"", @"", 2);
    writeFixture(@"jq-data.json", bytes(@"1\n2\n"));
    writeFixture(@"jq-raw.txt", bytes(@"é\n"));
    writeFixture(@"sub/jq-filter.jq", bytes(@"include \"jq-module\"; twice"));
    writeFixture(@"sub/jq-module.jq", bytes(@"def twice: . * 2;"));
    expectText(@"jq relative input files", @[@"jq", @".", @"jq-data.json"], @"", @"1\n2\n", 0);
    expectText(@"jq filename and line", @[@"jq", @"-c", @"[input_filename,input_line_number]", @"jq-data.json"], @"",
        @"[\"jq-data.json\",1]\n[\"jq-data.json\",2]\n", 0);
    expectText(@"jq relative module next to filter", @[@"jq", @"-L", @"sub", @"-f", @"sub/jq-filter.jq", @"jq-data.json"], @"", @"2\n4\n", 0);
    expectText(@"jq raw and slurp files", @[@"jq", @"-nc", @"--rawfile", @"r", @"jq-raw.txt", @"--slurpfile", @"s", @"jq-data.json", @"[$r,$s]"],
        @"", @"[\"é\\n\",[1,2]]\n", 0);
    expectText(@"jq session PWD", @[@"jq", @"-nr", @"env.PWD"], @"", [root stringByAppendingString:@"\n"], 0);
    ios_setenv("JQ_COLORS", "31:32:33:34:35:36:37:38", 1);
    expectText(@"jq custom colors", @[@"jq", @"-nC", @"null"], @"", @"\033[31mnull\033[0m\n", 0);
    ios_unsetenv("JQ_COLORS");
    expectText(@"jq colors reset between invocations", @[@"jq", @"-nC", @"null"], @"", @"\033[0;90mnull\033[0m\n", 0);
    NSUInteger descriptors = descriptorCount();
    for (int i = 0; i < 8; ++i) {
        expectText(@"jq repeated input ownership", @[@"jq", @"-s", @"add", @"jq-data.json"], @"", @"3\n", 0);
        expectText(@"jq halt closes partially consumed file", @[@"jq", @"halt", @"jq-data.json"], @"", @"", 0);
        expectText(@"jq repeated help ownership", @[@"jq", @"--help"], @"", nil, 0);
    }
    check(descriptorCount() == descriptors, @"jq releases input descriptors and preserves host streams");
}

static void validateInfoZip(void)
{
    writeFixture(@"archive-input.txt", bytes(@"archive café\n"));
    NSUInteger descriptors = descriptorCount();
    for (int round = 0; round < 10; ++round) {
        expectText(@"zip create/update", @[@"zip", @"-q", @"archive.zip", @"archive-input.txt"], @"", @"", 0);
        expectText(@"unzip test", @[@"unzip", @"-tqq", @"archive.zip"], @"", @"", 0);
        expectText(@"unzip stdout", @[@"unzip", @"-p", @"archive.zip", @"archive-input.txt"], @"", @"archive café\n", 0);
        expectText(@"zip help lifetime", @[@"zip", @"-h"], @"", nil, 0);
        expectText(@"unzip help lifetime", @[@"unzip", @"-h"], @"", nil, 0);
    }
    expectText(@"zip archive verification", @[@"zip", @"-qT", @"verified.zip", @"archive-input.txt"], @"", @"", 0);
    expectText(@"unzip output directory", @[@"unzip", @"-qo", @"archive.zip", @"-d", @"unpacked"], @"", @"", 0);
    check([[NSData dataWithContentsOfFile:path(@"unpacked/archive-input.txt")] isEqual:bytes(@"archive café\n")], @"unzip extracted bytes");
    NSDictionary *stream = expect(@"zip borrowed stdin/stdout", @[@"zip", @"-qfz", @"-", @"-"], bytes(@"stream bytes"), nil, 0);
    writeFixture(@"stream.zip", stream[@"stdout"]);
    expectText(@"unzip forced ZIP64", @[@"unzip", @"-p", @"stream.zip", @"-"], @"", @"stream bytes", 0);
    ios_setenv("ZIPOPT", "-q -0", 1);
    expectText(@"zip environment options", @[@"zip", @"environment.zip", @"archive-input.txt"], @"", @"", 0);
    ios_unsetenv("ZIPOPT");
    ios_setenv("UNZIPOPT", "-p", 1);
    expectText(@"unzip environment options", @[@"unzip", @"environment.zip", @"archive-input.txt"], @"", @"archive café\n", 0);
    ios_unsetenv("UNZIPOPT");
    expectText(@"zip password prompt EOF", @[@"zip", @"-qe", @"prompt.zip", @"archive-input.txt"], @"", nil, -1);
    expectText(@"unzip missing archive", @[@"unzip", @"missing-archive.zip"], @"", nil, 9);
    check(descriptorCount() == descriptors, @"Info-ZIP releases descriptors and preserves shell streams");
}

int ios_validateNativeCommands(void)
{
    @autoreleasepool {
        checks = 0;
        failures = [NSMutableArray array];
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        root = directory.URLByResolvingSymlinksInPath.path;
        for (NSString *name in @[@"", @"Library", @"Caches", @".localc", @"tmp", @"sub"])
            check([manager createDirectoryAtPath:path(name) withIntermediateDirectories:YES
                attributes:nil error:nil], @"create validation directory");
        char resolved[PATH_MAX];
        if (realpath(root.UTF8String, resolved) != NULL)
            root = [NSString stringWithUTF8String:resolved];
        check(ios_setSystemPaths([directory URLByAppendingPathComponent:@".localc"],
            [directory URLByAppendingPathComponent:@"Library"],
            [directory URLByAppendingPathComponent:@"Caches"], directory, directory, directory),
            @"configure embedded paths");
        ios_setDirectoryURL(directory);
        ios_setenv("TMPDIR", path(@"tmp").UTF8String, 1);
        ios_setenv("LC_ALL", "en_US.UTF-8", 1);
        ios_unsetenv("BLOCKSIZE");
        ios_unsetenv("GZIP");

        expectText(@"cd enters configured HOME", @[@"cd"], @"", @"", 0);
        expectText(@"pwd after cd HOME", @[@"pwd"], @"", [root stringByAppendingString:@"\n"], 0);
        ios_setenv("HOME", path(@"sub").UTF8String, 1);
        expectText(@"cd follows changed HOME", @[@"cd"], @"", @"", 0);
        expectText(@"pwd after changed HOME", @[@"pwd"], @"", [path(@"sub") stringByAppendingString:@"\n"], 0);
        expectText(@"cd preserves previous directory", @[@"cd", @"-"], @"", nil, 0);
        expectText(@"pwd after cd previous directory", @[@"pwd"], @"", [root stringByAppendingString:@"\n"], 0);
        ios_unsetenv("HOME");
        expectText(@"cd rejects unset HOME", @[@"cd"], @"", @"", 1);
        ios_setenv("HOME", path(@"missing-home").UTF8String, 1);
        expectText(@"cd rejects missing HOME directory", @[@"cd"], @"", @"", 1);
        expectText(@"failed cd preserves directory", @[@"pwd"], @"", [root stringByAppendingString:@"\n"], 0);
        ios_setenv("HOME", root.UTF8String, 1);

        const int signals[] = {SIGINT, SIGINFO, SIGPIPE, SIGSEGV, SIGBUS};
        struct sigaction before[5];
        for (int i = 0; i < 5; ++i) sigaction(signals[i], NULL, &before[i]);
        NSArray<NSString *> *commands = @[@"readlink", @"basename", @"dirname", @"realpath",
            @"mktemp", @"cut", @"comm", @"paste", @"join", @"split", @"df", @"du", @"chmod",
            @"cmp", @"diff", @"xxd", @"base64", @"sha256sum", @"jq", @"zip", @"unzip"];
        for (NSString *command in commands) {
            check(ios_command_lookup(command.UTF8String) != NULL && ios_executable(command.UTF8String),
                [@"registered " stringByAppendingString:command]);
            BOOL exclusive = [@[@"readlink", @"df", @"du", @"chmod"] containsObject:command];
            ios_command_isolation_policy policy = exclusive ? IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH :
                IOS_COMMAND_ISOLATION_THREAD_SAFE;
            check(ios_commandIsExclusiveOrThreadSafe(command.UTF8String) == policy,
                [@"isolation " stringByAppendingString:command]);
            check(ios_commandIsExclusiveOrThreadSafe([@"/usr/bin/" stringByAppendingString:command].UTF8String) == policy,
                [@"virtual path isolation " stringByAppendingString:command]);
        }

        writeFixture(@"alpha.txt", bytes(@"abc"));
        writeFixture(@"left.txt", bytes(@"a\nb\nd\n"));
        writeFixture(@"right.txt", bytes(@"a\nc\nd\n"));
        writeFixture(@"join1", bytes(@"a 1\na 2\nb 3\n"));
        writeFixture(@"join2", bytes(@"a X\na Y\nc Z\n"));
        check(symlink("alpha.txt", path(@"link").UTF8String) == 0, @"create symlink");
        expectText(@"readlink", @[@"readlink", @"link"], @"", @"alpha.txt\n", 0);
        expectText(@"readlink no newline", @[@"readlink", @"-n", @"link"], @"", @"alpha.txt", 0);
        expectText(@"readlink virtual path", @[@"/usr/bin/readlink", @"link"], @"", @"alpha.txt\n", 0);
        expectText(@"readlink regular file", @[@"readlink", @"alpha.txt"], @"", @"", 1);
        expectText(@"stat after readlink", @[@"stat", @"-f", @"%z", @"alpha.txt"], @"", @"3\n", 0);
        expectText(@"basename suffix", @[@"basename", @"/a/file.txt", @".txt"], @"", @"file\n", 0);
        expectText(@"basename empty operand", @[@"basename", @"-a", @"", @"/a/b"], @"", @"\nb\n", 0);
        expectText(@"basename long suffix", @[@"basename", @"a", @"long-suffix"], @"", @"a\n", 0);
        expectText(@"basename multiple suffixes", @[@"basename", @"-s", @".gz", @"a.gz", @"b.gz"], @"", @"a\nb\n", 0);
        expectText(@"basename missing operand", @[@"basename"], @"", nil, 1);
        expectText(@"dirname", @[@"dirname", @"/a/b"], @"", @"/a\n", 0);
        expectText(@"dirname bare name", @[@"dirname", @"foo"], @"", @".\n", 0);
        expectText(@"realpath", @[@"realpath", @"sub/../link"], @"", [path(@"alpha.txt") stringByAppendingString:@"\n"], 0);
        NSDictionary *quiet = expect(@"realpath quiet failure", @[@"realpath", @"-q", @"missing"], bytes(@""), bytes(@""), 1);
        check([quiet[@"stderr"] length] == 0, @"realpath -q suppresses diagnostic");

        for (NSArray *arguments in @[@[@"mktemp"], @[@"mktemp", @"-d"],
                @[@"mktemp", @"-t", @"local-code"], @[@"mktemp", @"-p", path(@"tmp"), @"item.XXXXXXXX"]]) {
            NSDictionary *result = expect(@"mktemp create", arguments, bytes(@""), nil, 0);
            NSString *created = [[[NSString alloc] initWithData:result[@"stdout"] encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
            struct stat info;
            BOOL isDirectory = [arguments containsObject:@"-d"];
            check([created hasPrefix:[path(@"tmp") stringByAppendingString:@"/"]] &&
                stat(created.UTF8String, &info) == 0 && (info.st_mode & 0777) == (isDirectory ? 0700 : 0600),
                @"mktemp uses session TMPDIR and private permissions");
        }
        expectText(@"mktemp invalid directory", @[@"mktemp", @"missing/XXXXXXXX"], @"", nil, 1);
        expectText(@"cut bytes", @[@"cut", @"-b", @"2-4"], @"abcdef\n", @"bcd\n", 0);
        expectText(@"cut UTF-8 characters", @[@"cut", @"-c", @"2"], @"é中🙂\n", @"中\n", 0);
        ios_unsetenv("LC_ALL"); ios_setenv("LANG", "C", 1); ios_setenv("LC_CTYPE", "en_US.UTF-8", 1);
        expectText(@"cut honors LC_CTYPE", @[@"cut", @"-c", @"2"], @"é中🙂\n", @"中\n", 0);
        ios_setenv("LC_ALL", "en_US.UTF-8", 1); ios_unsetenv("LC_CTYPE");
        expectText(@"cut fields", @[@"cut", @"-d", @":", @"-f", @"2", @"-s"], @"a:b:c\nplain\n", @"b\n", 0);
        expectText(@"cut whitespace fields", @[@"cut", @"-w", @"-f", @"2"], @"a \t b c\n", @"b\n", 0);
        expectText(@"cut reversed autostart range", @[@"cut", @"-b", @"-100-1"], @"abcdef\n", @"abcdef\n", 0);
        expectText(@"cut zero field", @[@"cut", @"-f", @"0"], @"a\tb\n", nil, 1);
        expectText(@"comm common", @[@"comm", @"-12", @"left.txt", @"right.txt"], @"", @"a\nd\n", 0);
        expectText(@"comm unique columns", @[@"comm", @"-3", @"left.txt", @"right.txt"], @"", @"b\n\tc\n", 0);
        NSString *longPrefix = [@"" stringByPaddingToLength:3000 withString:@"a" startingAtIndex:0];
        writeFixture(@"long1", bytes([longPrefix stringByAppendingString:@"X\n"]));
        writeFixture(@"long2", bytes([longPrefix stringByAppendingString:@"Y\n"]));
        expectText(@"comm long lines", @[@"comm", @"-12", @"long1", @"long2"], @"", @"", 0);
        expectText(@"paste", @[@"paste", @"left.txt", @"right.txt"], @"", @"a\ta\nb\tc\nd\td\n", 0);
        expectText(@"paste serial", @[@"paste", @"-s", @"-d", @",", @"left.txt"], @"", @"a,b,d\n", 0);
        expectText(@"paste stdin", @[@"paste", @"-", @"-"], @"1\n2\n3\n4\n", @"1\t2\n3\t4\n", 0);
        expectText(@"join duplicate keys", @[@"join", @"join1", @"join2"], @"", @"a 1 X\na 1 Y\na 2 X\na 2 Y\n", 0);
        expectText(@"join unmatched and output fields", @[@"join", @"-a", @"1", @"-e", @"NA", @"-o", @"1.1,1.2,2.2", @"join1", @"join2"], @"", @"a 1 X\na 1 Y\na 2 X\na 2 Y\nb 3 NA\n", 0);
        expectText(@"split byte chunks", @[@"split", @"-b", @"3", @"-", @"chunk"], @"abcdefgh", @"", 0);
        check([[NSData dataWithContentsOfFile:path(@"chunkaa")] isEqual:bytes(@"abc")] &&
            [[NSData dataWithContentsOfFile:path(@"chunkab")] isEqual:bytes(@"def")] &&
            [[NSData dataWithContentsOfFile:path(@"chunkac")] isEqual:bytes(@"gh")], @"split chunk contents");
        expectText(@"split decimal line chunks", @[@"split", @"-d", @"-l", @"2", @"left.txt", @"lines"], @"", @"", 0);
        check([[NSData dataWithContentsOfFile:path(@"lines00")] isEqual:bytes(@"a\nb\n")] &&
            [[NSData dataWithContentsOfFile:path(@"lines01")] isEqual:bytes(@"d\n")], @"split line contents");
        expectText(@"split zero bytes rejected", @[@"split", @"-b", @"0"], @"x", nil, 64);

        NSMutableData *binary = [NSMutableData dataWithLength:65536];
        for (NSUInteger i = 0; i < binary.length; ++i) ((unsigned char *)binary.mutableBytes)[i] = (i * 31 + i / 251) & 255;
        writeFixture(@"hardlink-data", binary);
        check(link(path(@"hardlink-data").UTF8String, path(@"hardlink-other").UTF8String) == 0, @"create hard link");
        struct stat fileInfo;
        stat(path(@"hardlink-data").UTF8String, &fileInfo);
        NSString *duOutput = [NSString stringWithFormat:@"%lld\thardlink-data\n", (fileInfo.st_blocks + 1) / 2];
        for (int i = 0; i < 3; ++i)
            expectText(@"du repeated hard-link counting", @[@"du", @"-k", @"hardlink-data"], @"", duOutput, 0);
        expectText(@"du apparent size", @[@"du", @"-A", @"-k", @"alpha.txt"], @"", @"1\talpha.txt\n", 0);
        expectText(@"du rejects invalid depth", @[@"du", @"-d", @"garbage"], @"", nil, 64);
        expectText(@"du rejects invalid block size", @[@"du", @"-B", @"512x"], @"", nil, 64);
        expectText(@"du negative threshold", @[@"du", @"-s", @"-k", @"-t", @"-1M", @"sub"], @"", nil, 0);
        expectText(@"du positive threshold", @[@"du", @"-s", @"-k", @"-t", @"1M", @"sub"], @"", @"", 0);
        expectText(@"du applies threshold to files", @[@"du", @"-A", @"-k", @"-t", @"1M", @"alpha.txt"], @"", @"", 0);
        expectText(@"du negative file threshold", @[@"du", @"-A", @"-k", @"-t", @"-1M", @"alpha.txt"], @"", @"1\talpha.txt\n", 0);
        struct statfs filesystemInfo;
        check(statfs(root.UTF8String, &filesystemInfo) == 0, @"df reference filesystem statistics");
        // Change units between calls to catch cached block sizes and missing headers.
        for (NSArray *unit in @[@[@"-k", @1024], @[@"-m", @1048576], @[@"-P", @512], @[@"-k", @1024]]) {
            NSDictionary *result = expect(@"df numeric units", @[@"df", unit[0], @"."], nil, nil, 0);
            NSString *output = [[NSString alloc] initWithData:result[@"stdout"] encoding:NSUTF8StringEncoding];
            NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
            check(lines.count == 3 && [lines[0] hasPrefix:@"Filesystem"] &&
                [lines[0] containsString:[NSString stringWithFormat:@"%@-blocks", unit[1]]], @"df header and one row");
            unsigned long long total = 0, used = 0, available = 0;
            int capacity = -1;
            int fields = lines.count > 1 ? sscanf(lines[1].UTF8String, "%*s %llu %llu %llu %d%%",
                &total, &used, &available, &capacity) : 0;
            unsigned long long expectedTotal = filesystemInfo.f_blocks *
                (unsigned long long)filesystemInfo.f_bsize / [unit[1] unsignedLongLongValue];
            check(fields == 4 && total == expectedTotal && used <= total && available <= total &&
                capacity >= 0 && capacity <= 100, @"df numeric statistics match filesystem size");
            check([output containsString:[NSString stringWithUTF8String:filesystemInfo.f_mntonname]], @"df mount point");
            check([result[@"stderr"] length] == 0, @"df no diagnostics");
            check(ios_getenv("BLOCKSIZE") == NULL, @"df unit option leaves BLOCKSIZE unchanged");
        }
        for (NSString *operand in @[@".", @"alpha.txt", @"link", path(@"sub")]) {
            NSDictionary *result = expect(@"df human-readable operand", @[@"df", @"-h", operand], nil, nil, 0);
            NSString *output = [[NSString alloc] initWithData:result[@"stdout"] encoding:NSUTF8StringEncoding];
            check([output containsString:@"Size"] && [output containsString:@"Mounted on"], @"df human-readable header");
        }
        NSDictionary *inodeResult = expect(@"df inodes", @[@"df", @"-i", @"."], nil, nil, 0);
        check([[[NSString alloc] initWithData:inodeResult[@"stdout"] encoding:NSUTF8StringEncoding]
            containsString:@"iused"], @"df inode columns");
        expectText(@"df virtual path", @[@"/usr/bin/df", @"-H", @"."], @"", nil, 0);
        expectText(@"df mount enumeration", @[@"df", @"-n", @"-h"], @"", nil, 0);
        NSDictionary *localResult = expect(@"df local filesystems", @[@"df", @"-l", @"-h"], nil, nil, 0);
        check([localResult[@"stderr"] length] == 0, @"df local selection needs no privileged sysctl");
        ios_setenv("BLOCKSIZE", "2048", 1);
        NSDictionary *blocksizeResult = expect(@"df session BLOCKSIZE", @[@"df", @"."], nil, nil, 0);
        check([[[NSString alloc] initWithData:blocksizeResult[@"stdout"] encoding:NSUTF8StringEncoding]
            containsString:@"2048-blocks"], @"df uses session block size");
        expectText(@"df overrides session BLOCKSIZE", @[@"df", @"-k", @"."], @"", nil, 0);
        check(strcmp(ios_getenv("BLOCKSIZE"), "2048") == 0, @"df preserves explicit session BLOCKSIZE");
        ios_unsetenv("BLOCKSIZE");
        expectText(@"df missing operand", @[@"df", @"missing"], @"", @"", 1);
        expectText(@"df invalid option", @[@"df", @"-z"], @"", @"", 64);
        NSDictionary *partialResult = expect(@"df continues after missing operand",
            @[@"df", @"-k", @"missing", @"alpha.txt", @"sub"], nil, nil, 1);
        NSString *partialOutput = [[NSString alloc] initWithData:partialResult[@"stdout"] encoding:NSUTF8StringEncoding];
        check([partialOutput componentsSeparatedByString:@"\n"].count == 4, @"df retains valid operand rows");
        NSString *filesystemType = [NSString stringWithUTF8String:filesystemInfo.f_fstypename];
        expectText(@"df excluded filesystem type", @[@"df", @"-T", [@"no" stringByAppendingString:filesystemType], @"."], @"", @"", 1);
        expectText(@"df included filesystem type after exclusion", @[@"df", @"-T", filesystemType, @"."], @"", nil, 0);

        expectText(@"chmod numeric", @[@"chmod", @"640", @"alpha.txt"], @"", @"", 0);
        stat(path(@"alpha.txt").UTF8String, &fileInfo);
        check((fileInfo.st_mode & 0777) == 0640, @"chmod numeric mode persisted");
        expectText(@"chmod symbolic", @[@"chmod", @"u+x", @"alpha.txt"], @"", @"", 0);
        stat(path(@"alpha.txt").UTF8String, &fileInfo);
        check((fileInfo.st_mode & 0777) == 0740, @"chmod symbolic mode persisted");
        expectText(@"chmod missing file", @[@"chmod", @"600", @"missing"], @"", nil, 1);
        expectText(@"cmp equal", @[@"cmp", @"alpha.txt", @"alpha.txt"], @"", @"", 0);
        expectText(@"cmp different silent", @[@"cmp", @"-s", @"left.txt", @"right.txt"], @"", @"", 1);
        expectText(@"cmp stdin offsets", @[@"cmp", @"-", @"alpha.txt", @"1", @"0"], @"Xabc", @"", 0);
        expectText(@"cmp missing file", @[@"cmp", @"missing", @"alpha.txt"], @"", nil, 2);
        writeFixture(@"diff1", bytes(@"one\n")); writeFixture(@"diff2", bytes(@"two\n"));
        expectText(@"diff unified", @[@"diff", @"-u", @"-L", @"left", @"-L", @"right", @"diff1", @"diff2"], @"",
            @"--- left\n+++ right\n@@ -1 +1 @@\n-one\n+two\n", 1);
        expectText(@"diff equal", @[@"diff", @"diff1", @"diff1"], @"", @"", 0);
        expectText(@"diff missing file", @[@"diff", @"diff1", @"missing"], @"", nil, 2);
        expectText(@"diff missing tabsize", @[@"diff", @"--tabsize"], @"", nil, 2);
        expectText(@"diff invalid tabsize", @[@"diff", @"--tabsize=0", @"diff1", @"diff2"], @"", nil, 2);
        expectText(@"diff unsupported pagination", @[@"diff", @"-l", @"diff1", @"diff2"], @"", nil, 2);
        expectText(@"diff regex suppresses changed lines", @[@"diff", @"-I", @"one|two", @"diff1", @"diff2"], @"", @"", 0);
        expectText(@"diff regex does not persist", @[@"diff", @"diff1", @"diff2"], @"", nil, 1);
        expectText(@"diff stdin", @[@"diff", @"-", @"diff1"], @"one\n", @"", 0);
        // Fixed BSD-compatible output fixtures; the host suite also applies
        // randomized patches because xdiff can choose different valid hunks.
        NSArray *diffCases = @[
            @[@"normal", @"one\n", @"two\n", @[], @"1c1\n< one\n---\n> two\n", @1],
            @[@"context", @"one\n", @"two\n", @[@"-c"], @"*** left\n--- right\n***************\n*** 1 ****\n! one\n--- 1 ----\n! two\n", @1],
            @[@"attached context", @"a\none\nc\n", @"a\ntwo\nc\n", @[@"-u0"], @"--- left\n+++ right\n@@ -2 +2 @@\n-one\n+two\n", @1],
            @[@"ed", @"a\nb\nc\n", @".\nx\n.\n", @[@"-e"], @"1,3c\n..\n.\n1s/.//\n1a\nx\n..\n.\n3s/.//\n", @1],
            @[@"forward ed", @"a\nb\nc\n", @"d\n", @[@"-f"], @"c1 3\nd\n.\n", @1],
            @[@"rcs", @"a\nb\nc\n", @"d\n", @[@"-n"], @"d1 3\na3 1\nd\n", @1],
            @[@"conditional", @"a\nb\nc\n", @"d\n", @[@"-D", @"FEATURE"], @"#ifndef FEATURE\na\nb\nc\n#else /* FEATURE */\nd\n#endif /* FEATURE */\n", @1],
            @[@"empty input", @"", @"new\n", @[@"-u"], @"--- left\n+++ right\n@@ -0,0 +1 @@\n+new\n", @1],
            @[@"missing newline", @"a", @"b", @[@"-u"], @"--- left\n+++ right\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n", @1],
            @[@"space changes", @"a\tb\n", @"a  b\n", @[@"-b"], @"", @0],
            @[@"all spaces", @"a b\n", @"ab\n", @[@"-w"], @"", @0],
            @[@"blank lines", @"a\nb\n", @"a\n\nb\n", @[@"-B"], @"", @0],
            @[@"case fold", @"Hello\n", @"hello\n", @[@"-i"], @"", @0],
            @[@"strip CR", @"a\r\n", @"a\n", @[@"--strip-trailing-cr"], @"", @0],
            @[@"brief labels", @"a\n", @"b\n", @[@"-q"], @"Files left and right differ\n", @1],
            @[@"tabs", @"a\tb\n", @"a\tc\n", @[@"-t"], @"1c1\n< a       b\n---\n> a       c\n", @1],
        ];
        for (NSArray *test in diffCases) {
            writeFixture(@"diff-left", bytes(test[1]));
            writeFixture(@"diff-right", bytes(test[2]));
            NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"diff"];
            [arguments addObjectsFromArray:test[3]];
            [arguments addObjectsFromArray:@[@"-L", @"left", @"-L", @"right", @"diff-left", @"diff-right"]];
            expectText([@"diff " stringByAppendingString:test[0]], arguments, @"", test[4], [test[5] intValue]);
        }
        writeFixture(@"diff-left", bytes(@"ÉCOLE\n"));
        writeFixture(@"diff-right", bytes(@"école\n"));
        expectText(@"diff Unicode case", @[@"diff", @"-i", @"diff-left", @"diff-right"], @"", @"", 0);
        writeFixture(@"diff-left", bytes(@"one\n"));
        writeFixture(@"diff-right", bytes(@"two\n"));
        expectText(@"diff initial tabs", @[@"diff", @"-T", @"diff-left", @"diff-right"], @"", @"1c1\n<\tone\n---\n>\ttwo\n", 1);
        expectText(@"diff shared stdin", @[@"diff", @"-s", @"-", @"-"], @"abc\n", @"Files - and - are identical\n", 0);
        expectText(@"diff conditional shared stdin", @[@"diff", @"-D", @"FEATURE", @"-", @"-"], @"abc\n", @"abc\n", 0);
        const char diffBinaryLeft[] = {'a', 0, 'b'}, diffBinaryRight[] = {'a', 0, 'c'};
        writeFixture(@"diff-left", [NSData dataWithBytes:diffBinaryLeft length:sizeof(diffBinaryLeft)]);
        writeFixture(@"diff-right", [NSData dataWithBytes:diffBinaryRight length:sizeof(diffBinaryRight)]);
        expectText(@"diff detects changes after NUL", @[@"diff", @"-q", @"diff-left", @"diff-right"], @"", @"Files diff-left and diff-right differ\n", 1);
        expectText(@"diff equal binary", @[@"diff", @"diff-left", @"diff-left"], @"", @"", 0);
        expectText(@"diff missing left as empty", @[@"diff", @"-N", @"missing", @"diff1"], @"", @"0a1\n> one\n", 1);
        [NSFileManager.defaultManager createDirectoryAtPath:path(@"diff-tree") withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:path(@"diff-empty") withIntermediateDirectories:YES attributes:nil error:nil];
        writeFixture(@"diff-tree/only", bytes(@"one\n"));
        expectText(@"diff excludes directories", @[@"diff", @"-r", @"-x", @"*", @"diff-tree", @"diff-empty"], @"", @"", 0);
        check(ios_command_lookup("gzip") == NULL && ios_command_lookup("gunzip") == NULL,
            @"gzip and gunzip are outside the supported command set");
        writeFixture(@"sub/file", bytes(@"abc"));
        expectText(@"chmod recursive", @[@"chmod", @"-R", @"u+rwX,go-rwx", @"sub"], @"", @"", 0);
        stat(path(@"sub/file").UTF8String, &fileInfo);
        check((fileInfo.st_mode & 0777) == 0600, @"chmod recursive file mode");

        unsigned char shortBytes[] = {0, 255, 65, 66};
        NSData *shortBinary = [NSData dataWithBytes:shortBytes length:sizeof(shortBytes)];
        expect(@"xxd plain", @[@"xxd", @"-p"], shortBinary, bytes(@"00ff4142\n"), 0);
        expect(@"xxd reverse", @[@"xxd", @"-r", @"-p"], bytes(@"00 ff 41 42\n"), shortBinary, 0);
        expectText(@"xxd offset and length", @[@"xxd", @"-p", @"-s", @"1", @"-l", @"2"], @"abcd", @"6263\n", 0);
        expectText(@"base64 default", @[@"base64"], @"abc", @"YWJj\n", 0);
        expectText(@"base64 zero wrap", @[@"base64", @"-w", @"0"], @"abc", @"YWJj", 0);
        expectText(@"base64 custom wrap", @[@"base64", @"-w", @"2"], @"abc", @"YW\nJj\n", 0);
        expectText(@"base64 decode", @[@"base64", @"-d"], @"YQ==\n", @"a", 0);
        expectText(@"base64 reject garbage", @[@"base64", @"-d"], @"!!!", nil, 1);
        expectText(@"base64 ignore garbage", @[@"base64", @"-d", @"-i"], @"!Y!Q!==\n", @"a", 0);
        expectText(@"base64 reject truncated block", @[@"base64", @"-d"], @"YQ", nil, 1);
        expectText(@"base64 reject trailing data", @[@"base64", @"-d"], @"YQ==Yg==", nil, 1);
        NSDictionary *encoded = expect(@"base64 binary encode", @[@"base64", @"-w", @"0"], binary, nil, 0);
        expect(@"base64 binary round trip", @[@"base64", @"-d"], encoded[@"stdout"], binary, 0);
        expectText(@"base64 rejects invalid width", @[@"base64", @"-w", @"garbage"], @"", nil, 1);
        expectText(@"base64 file", @[@"base64", @"alpha.txt"], @"", @"YWJj\n", 0);
        expectText(@"base64 empty input", @[@"base64"], @"", @"", 0);
        NSString *hash = @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        NSString *sum = [hash stringByAppendingString:@"  alpha.txt\n"];
        expectText(@"sha256sum file", @[@"sha256sum", @"alpha.txt"], @"", sum, 0);
        expectText(@"sha256sum stdin", @[@"sha256sum"], @"abc", [hash stringByAppendingString:@"  -\n"], 0);
        writeFixture(@"checksums", bytes(sum));
        expectText(@"sha256sum check", @[@"sha256sum", @"-c", @"checksums"], @"", @"alpha.txt: OK\n", 0);
        expectText(@"sha256sum quiet check", @[@"sha256sum", @"--quiet", @"-c", @"checksums"], @"", @"", 0);
        writeFixture(@"wrong-checksums", bytes([@"0" stringByAppendingString:[sum substringFromIndex:1]]));
        expectText(@"sha256sum mismatch status", @[@"sha256sum", @"--status", @"-c", @"wrong-checksums"], @"", @"", 1);
        expectText(@"sha256sum strict invalid input", @[@"sha256sum", @"--strict", @"-c", @"-"], @"bad\n", nil, 1);
        expectText(@"sha256sum checks stdin by default", @[@"sha256sum", @"-c"], sum, @"alpha.txt: OK\n", 0);
        expectText(@"sha256sum rejects empty checksum list", @[@"sha256sum", @"-c"], @"", nil, 1);
        expectText(@"sha256sum rejects malformed checksum list", @[@"sha256sum", @"-c"], @"bad\n", nil, 1);
        expectText(@"sha256sum binary marker", @[@"sha256sum", @"-b", @"alpha.txt"], @"",
            [hash stringByAppendingString:@" *alpha.txt\n"], 0);
        writeFixture(@" alpha.txt", bytes(@"different"));
        expectText(@"sha256sum does not guess filenames", @[@"sha256sum", @"-c"], sum, @"alpha.txt: OK\n", 0);
        for (NSString *name in @[@"back\\slash", @"line\nbreak", @"carriage\rreturn"]) {
            writeFixture(name, bytes(@"abc"));
            NSString *escaped = [[[name stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
                stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
            NSString *line = [NSString stringWithFormat:@"\\%@  %@\n", hash, escaped];
            expectText(@"sha256sum escapes filename", @[@"sha256sum", name], @"", line, 0);
            expectText(@"sha256sum checks escaped filename", @[@"sha256sum", @"--status", @"-c"], line, @"", 0);
        }
        for (NSArray *arguments in @[@[@"cut", @"-c", @"1", @"missing"],
                @[@"comm", @"missing", @"left.txt"], @[@"paste", @"missing"],
                @[@"join", @"missing", @"join2"], @[@"split", @"missing"], @[@"du", @"missing"],
                @[@"xxd", @"missing"],
                @[@"base64", @"missing"], @[@"sha256sum", @"missing"]])
            expect(@"missing input reports failure", arguments, bytes(@""), nil, -1);

        NSUInteger initialDescriptors = descriptorCount();
        for (int repeat = 0; repeat < 12; ++repeat) {
            expectText(@"repeat cut error", @[@"cut", @"-b", @"0"], @"", nil, 1);
            expectText(@"repeat cut resets selection", @[@"cut", @"-b", @"1"], @"xyz\n", @"x\n", 0);
            expectText(@"repeat comm", @[@"comm", @"-12", @"left.txt", @"right.txt"], @"", @"a\nd\n", 0);
            expectText(@"repeat join", @[@"join", @"join1", @"join2"], @"", @"a 1 X\na 1 Y\na 2 X\na 2 Y\n", 0);
            expectText(@"repeat paste delimiter reset", @[@"paste", @"-s", @"left.txt"], @"", @"a\tb\td\n", 0);
            expectText(@"repeat split suffix reset", @[@"split", @"-b", @"2", @"-", @"repeat"], @"xyz", @"", 0);
            check([[NSData dataWithContentsOfFile:path(@"repeataa")] isEqual:bytes(@"xy")], @"repeat split starts at aa");
            expectText(@"repeat du", @[@"du", @"-k", @"hardlink-data"], @"", duOutput, 0);
            expectText(@"repeat chmod", @[@"chmod", @"640", @"alpha.txt"], @"", @"", 0);
            expectText(@"repeat diff", @[@"diff", @"diff1", @"diff1"], @"", @"", 0);
            expect(@"repeat xxd", @[@"xxd", @"-p"], shortBinary, bytes(@"00ff4142\n"), 0);
            expectText(@"repeat sha256sum flags", @[@"sha256sum", @"alpha.txt"], @"", sum, 0);
        }
        check(descriptorCount() == initialDescriptors, @"repeated commands do not leak descriptors");
        // Exercise the app's shell-text entry point, rather than a nested sh
        // invocation whose command cleanup owns its standard streams.
        {
            FILE *in = tmpfile(), *out = tmpfile(), *error = tmpfile();
            if (in == NULL || out == NULL || error == NULL) abort();
            ios_setStreams(in, out, error);
            int status = ios_system_osh(
                "PATH=/usr/bin; for c in node npm npx python python3 python3.14 pip pip3 curl git sed awk grep rg jq zip unzip; do "
                "p=$(command -v \"$c\") || exit 1; [[ $p == /usr/bin/$c ]] || exit 1; done; echo discovered");
            check(status == 0 && [readStream(out) isEqual:bytes(@"discovered\n")],
                @"shell discovers embedded commands");
            ios_setStreams(stdin, stdout, stderr);
            fclose(in); fclose(out); fclose(error);
        }
        validateJQ();
        validateInfoZip();
        validateEntryLifetime();
        validateConcurrentSessions();
        validateConcurrentSystemPaths();
        for (int i = 0; i < 5; ++i) {
            struct sigaction after;
            sigaction(signals[i], NULL, &after);
            check(before[i].sa_handler == after.sa_handler,
                [NSString stringWithFormat:@"preserve process signal %d", signals[i]]);
        }
        NSDictionary *report = @{ @"checks": @(checks), @"failures": failures,
            @"commands": commands, @"passed": @(failures.count == 0), @"fixtureRoot": root };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        NSString *reportPath = path(@"native-command-results.json");
#if TARGET_OS_IOS
        reportPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-command-results.json"];
#endif
        [json writeToFile:reportPath atomically:YES];
        fprintf(stderr, "Native commands: %lu checks, %lu failures. Fixtures: %s\n",
            (unsigned long)checks, (unsigned long)failures.count, root.UTF8String);
        return failures.count == 0 ? 0 : 1;
    }
}
