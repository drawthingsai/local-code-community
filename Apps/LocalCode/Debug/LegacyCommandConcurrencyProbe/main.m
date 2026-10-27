#import <Foundation/Foundation.h>
#import "ios_system/ios_system.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

/* Runs legacy (EXCLUSIVE_BASH) commands from several ios_system sessions at
 * once, the way concurrent OSH bash jobs do, all in one project directory with
 * per-session file names. Usage: probe [workers] [rounds] [only-command].
 * With only-command "split", each session works in its own directory with
 * relative paths instead. */

enum { Sentinels = 30, TreeDirectories = 20, MaxWorkers = 8 };

static NSString *root;
static int workerCount = 4, rounds = 20;
static const char *onlyCommand;
static pthread_mutex_t barrierMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t barrierCondition = PTHREAD_COND_INITIALIZER;
static int arrived, generation;
static NSMutableDictionary<NSString *, NSNumber *> *failureCounts, *runCounts;
static NSMutableDictionary<NSString *, NSString *> *failureSamples;
static pthread_mutex_t resultMutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_int sentinelLosses;

static void barrier(void)
{
    pthread_mutex_lock(&barrierMutex);
    int current = generation;
    if (++arrived == workerCount) {
        arrived = 0;
        ++generation;
        pthread_cond_broadcast(&barrierCondition);
    } else {
        while (current == generation) pthread_cond_wait(&barrierCondition, &barrierMutex);
    }
    pthread_mutex_unlock(&barrierMutex);
}

static NSString *path(NSString *name) { return [root stringByAppendingPathComponent:name]; }

static NSData *readStream(FILE *stream)
{
    fflush(stream);
    rewind(stream);
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), stream)) != 0) [data appendBytes:buffer length:count];
    return data;
}

static NSDictionary *run(NSArray<NSString *> *arguments, NSString *input)
{
    FILE *in = tmpfile(), *out = tmpfile(), *error = tmpfile();
    if (in == NULL || out == NULL || error == NULL) abort();
    if (input != nil) fputs(input.UTF8String, in);
    rewind(in);
    ios_setStreams(in, out, error);
    const char **argv = calloc(arguments.count + 1, sizeof(*argv));
    for (NSUInteger index = 0; index < arguments.count; ++index) argv[index] = arguments[index].UTF8String;
    // Like OSH's external commands: each runs as its own ios_system "process",
    // with its own environment and a working directory restored on exit.
    pid_t pid = ios_fork();
    if (pid < 0) {
        free(argv);
        ios_setStreams(stdin, stdout, stderr);
        fclose(in); fclose(out); fclose(error);
        return @{@"status": @(126), @"stdout": [NSData data], @"stderr": [@"fork failed\n" dataUsingEncoding:NSUTF8StringEncoding]};
    }
    int status = ios_system((int)arguments.count, argv);
    pthread_t thread = ios_getThreadId(pid);
    if (thread == (pthread_t)-1) ios_storeThreadId(pthread_self());
    else if (thread != NULL) ios_waitpid(pid);
    ios_releaseThreadId(pid);
    free(argv);
    NSData *output = readStream(out), *diagnostics = readStream(error);
    ios_setStreams(stdin, stdout, stderr);
    fclose(in); fclose(out); fclose(error);
    return @{@"status": @(status), @"stdout": output, @"stderr": diagnostics};
}

static NSString *text(NSData *data) { return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<binary>"; }

static void record(NSString *key, BOOL ok, NSString *detail)
{
    pthread_mutex_lock(&resultMutex);
    runCounts[key] = @(runCounts[key].intValue + 1);
    if (!ok) {
        failureCounts[key] = @(failureCounts[key].intValue + 1);
        if (failureSamples[key] == nil) failureSamples[key] = detail;
    }
    pthread_mutex_unlock(&resultMutex);
}

static void makeTree(int index)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    for (int directory = 0; directory < TreeDirectories; ++directory) {
        NSString *parent = path([NSString stringWithFormat:@"tree-%d/d%02d", index, directory]);
        [manager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        for (int file = 0; file < Sentinels; ++file)
            [@"tree\n" writeToFile:[parent stringByAppendingPathComponent:[NSString stringWithFormat:@"file%02d.txt", file]]
                atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

typedef BOOL (^Verifier)(NSDictionary *result, NSString **detail);

static void *worker(void *opaque)
{
    int index = (int)(intptr_t)opaque;
    @autoreleasepool {
        char session[64];
        snprintf(session, sizeof(session), "legacy-probe-%d", index);
        ios_switchSession(session);
        ios_setContext(session);
        ios_setDirectoryURL([NSURL fileURLWithPath:root isDirectory:YES]);
        int lines = 10 + index;
        NSString *inName = [NSString stringWithFormat:@"in-%d.txt", index];
        NSMutableString *inText = [NSMutableString string], *column = [NSMutableString string];
        for (int line = 1; line <= lines; ++line) {
            [inText appendFormat:@"k%d v%d-%d\n", line, index, line];
            [column appendFormat:@"v%d-%d\n", index, line];
        }
        [inText writeToFile:path(inName) atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSString *numName = [NSString stringWithFormat:@"num-%d.txt", index];
        NSMutableString *numbers = [NSMutableString string], *sorted = [NSMutableString string];
        for (int value = 0; value < 200; ++value) [numbers appendFormat:@"%d\n", index * 1000 + (value * 37) % 200];
        for (int value = 0; value < 200; ++value) [sorted appendFormat:@"%d\n", index * 1000 + value];
        [numbers writeToFile:path(numName) atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSString *bigName = [NSString stringWithFormat:@"big-%d.bin", index];
        NSMutableData *big = [NSMutableData dataWithLength:2 * 1024 * 1024];
        memset(big.mutableBytes, 'a' + index, big.length);
        [big writeToFile:path(bigName) atomically:NO];
        NSString *editName = [NSString stringWithFormat:@"edit-%d.txt", index];
        NSString *copyName = [NSString stringWithFormat:@"copy-%d.bin", index];
        NSString *treeName = [NSString stringWithFormat:@"tree-%d", index];
        NSString *token = [NSString stringWithFormat:@"%d", index];

        NSArray *cases = @[
            @[@"sed-print", @[@"sed", @"-n", @"3p", inName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"k3 v%d-3\n", index]]; }],
            @[@"sed-inplace", @[@"sed", @"-i.bak", @"-e", [NSString stringWithFormat:@"s/old/new%d/", index], editName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                NSString *edited = [NSString stringWithContentsOfFile:path(editName) encoding:NSUTF8StringEncoding error:nil];
                NSString *backup = [NSString stringWithContentsOfFile:path([editName stringByAppendingString:@".bak"]) encoding:NSUTF8StringEncoding error:nil];
                *d = [NSString stringWithFormat:@"edited=%@ backup=%@", edited, backup];
                return [edited isEqualToString:[NSString stringWithFormat:@"new%d\n", index]] && [backup isEqualToString:@"old\n"]; }],
            @[@"wc", @[@"wc", @"-l", inName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                NSArray *fields = [[text(r[@"stdout"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                return fields.count >= 2 && [fields.firstObject intValue] == lines && [fields.lastObject isEqualToString:inName]; }],
            @[@"awk", @[@"awk", @"{print $2}", inName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:column]; }],
            // ENVIRON is the session's environment, and awk splits it without writing into it.
            @[@"awk-environ", @[@"sh", @"-c", [NSString stringWithFormat:@"export AWKV=s%d; awk 'BEGIN{print ENVIRON[\"AWKV\"]}'; printenv AWKV", index]], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"s%d\ns%d\n", index, index]]; }],
            @[@"sort", @[@"sort", @"-n", numName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:sorted]; }],
            @[@"tr", @[@"tr", @"a-z", @"A-Z"], [@"abc" stringByAppendingFormat:@"%d\n", index], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"ABC%d\n", index]]; }],
            @[@"grep", @[@"grep", @"-c", [NSString stringWithFormat:@"v%d-", index], inName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) intValue] == lines; }],
            // grep splits GREP_OPTIONS without writing into the environment.
            @[@"grep-options", @[@"sh", @"-c", [NSString stringWithFormat:@"export GREP_OPTIONS='-i -c'; grep V%d- %@; printenv GREP_OPTIONS", index, inName]], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                *d = text(r[@"stdout"]);
                return [*d isEqualToString:[NSString stringWithFormat:@"%d\n-i -c\n", lines]]; }],
            @[@"head", @[@"head", @"-n", @"2", inName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"k1 v%d-1\nk2 v%d-2\n", index, index]]; }],
            @[@"cp", @[@"cp", bigName, copyName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [[NSData dataWithContentsOfFile:path(copyName)] isEqualToData:big]; }],
            @[@"ls-l", @[@"ls", @"-l", [treeName stringByAppendingPathComponent:@"d00"]], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                return [text(r[@"stdout"]) componentsSeparatedByString:@"\n"].count == Sentinels + 2; }],
            @[@"rm-r", @[@"rm", @"-r", treeName], [NSNull null], ^BOOL(NSDictionary *r, NSString **d) {
                BOOL removed = ![NSFileManager.defaultManager fileExistsAtPath:path(treeName)];
                *d = [NSString stringWithFormat:@"tree removed=%d", removed];
                return removed; }],
        ];
        for (int round = 0; round < rounds * 2; ++round) {
            // First half: every session runs the same command together; second
            // half: sessions are offset so different commands overlap.
            BOOL mixed = round >= rounds;
            [@"old\n" writeToFile:path(editName) atomically:NO encoding:NSUTF8StringEncoding error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path(copyName) error:nil];
            makeTree(index);
            // solo-rm: only session 0 removes a tree; the others just run
            // short read-only commands that start and end meanwhile.
            BOOL soloRemove = onlyCommand != NULL && strcmp(onlyCommand, "solo-rm") == 0;
            for (int repeat = 0; soloRemove && repeat < (index == 0 ? 1 : 40); ++repeat) {
                if (repeat == 0) barrier();
                NSArray *test = cases[index == 0 ? cases.count - 1 : 7];
                NSDictionary *result = run(test[1], nil);
                NSString *detail = nil;
                Verifier verify = test[3];
                BOOL ok = [result[@"status"] intValue] == 0 && verify(result, &detail);
                record([@"solo   " stringByAppendingString:test[0]], ok,
                    [NSString stringWithFormat:@"session %d round %d status=%@ stderr=%@ %@", index, round, result[@"status"], text(result[@"stderr"]), detail ?: @""]);
            }
            for (NSUInteger step = 0; !soloRemove && step < cases.count; ++step) {
                NSArray *test = cases[mixed ? (step + index) % cases.count : step];
                NSString *name = test[0];
                if (onlyCommand != NULL && strcmp(onlyCommand, name.UTF8String) != 0 &&
                    !(strcmp(name.UTF8String, "ls-l") == 0 && strcmp(onlyCommand, "rm-r") == 0)) {
                    barrier();
                    continue;
                }
                if ([name isEqualToString:@"rm-r"] && ![NSFileManager.defaultManager fileExistsAtPath:path(treeName)])
                    makeTree(index);
                barrier();
                NSDictionary *result = run(test[1], test[2] == [NSNull null] ? nil : test[2]);
                NSString *detail = nil;
                Verifier verify = test[3];
                BOOL ok = [result[@"status"] intValue] == 0 && verify(result, &detail);
                record([NSString stringWithFormat:@"%@ %@", mixed ? @"mixed  " : @"aligned", name], ok,
                    [NSString stringWithFormat:@"session %d round %d status=%@ stdout=%@ stderr=%@ %@", index, round,
                        result[@"status"], [text(result[@"stdout"]) substringToIndex:MIN(120u, text(result[@"stdout"]).length)],
                        text(result[@"stderr"]), detail ?: @""]);
            }
            barrier();
            if (index == 0) {
                for (int file = 0; file < Sentinels; ++file) {
                    NSString *sentinel = path([NSString stringWithFormat:@"file%02d.txt", file]);
                    if (![NSFileManager.defaultManager fileExistsAtPath:sentinel]) {
                        atomic_fetch_add(&sentinelLosses, 1);
                        [@"sentinel\n" writeToFile:sentinel atomically:NO encoding:NSUTF8StringEncoding error:nil];
                    }
                }
            }
            barrier();
        }
    }
    return NULL;
}

/* Each session runs the same relative-path file commands in its own
 * directory; a command that resolves paths from the process working directory
 * lands in another session's directory or the root. */
static void *splitWorker(void *opaque)
{
    int index = (int)(intptr_t)opaque;
    @autoreleasepool {
        char session[64];
        snprintf(session, sizeof(session), "legacy-split-%d", index);
        ios_switchSession(session);
        ios_setContext(session);
        NSString *home = path([NSString stringWithFormat:@"s-%d", index]);
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
        ios_setDirectoryURL([NSURL fileURLWithPath:home isDirectory:YES]);
        NSString *(^at)(NSString *) = ^NSString *(NSString *name) { return [home stringByAppendingPathComponent:name]; };
        BOOL (^exists)(NSString *) = ^BOOL(NSString *name) {
            struct stat info;
            return lstat(at(name).fileSystemRepresentation, &info) == 0; };
        NSString *token = [NSString stringWithFormat:@"session %d\n", index];
        NSString *tokenWord = [NSString stringWithFormat:@"%d", index];
        NSString *A = [NSString stringWithFormat:@"a%d", index], *M = [NSString stringWithFormat:@"m%d", index];
        NSString *Q = [NSString stringWithFormat:@"q%d", index], *K = [NSString stringWithFormat:@"k%d", index];
        NSString *R = [NSString stringWithFormat:@"r%d", index], *W = [NSString stringWithFormat:@"w%d", index];
        NSString *(^P)(NSString *) = ^NSString *(NSString *name) { return [A stringByAppendingPathComponent:name]; };
        NSArray *cases = @[
            @[@"mkdir-p", @[@"mkdir", @"-p", P(@"b/c")], ^BOOL(NSDictionary *r) { return exists(P(@"b/c")); }],
            @[@"mkdir-m", @[@"mkdir", @"-m", @"700", M], ^BOOL(NSDictionary *r) {
                struct stat info;
                return stat(at(M).fileSystemRepresentation, &info) == 0 && (info.st_mode & 07777) == 0700; }],
            @[@"touch", @[@"touch", @"-t", @"202001021530", P(@"f.txt")], ^BOOL(NSDictionary *r) {
                struct stat info;
                struct tm local = {.tm_year = 120, .tm_mon = 0, .tm_mday = 2, .tm_hour = 15, .tm_min = 30, .tm_isdst = -1};
                return stat(at(P(@"f.txt")).fileSystemRepresentation, &info) == 0 && info.st_mtime == mktime(&local); }],
            @[@"tee", @[@"tee", P(@"t.txt")], ^BOOL(NSDictionary *r) {
                return [[NSString stringWithContentsOfFile:at(P(@"t.txt")) encoding:NSUTF8StringEncoding error:nil] isEqualToString:token]; }],
            @[@"ln-s", @[@"ln", @"-s", @"t.txt", P(@"l.txt")], ^BOOL(NSDictionary *r) {
                return [[manager destinationOfSymbolicLinkAtPath:at(P(@"l.txt")) error:nil] isEqualToString:@"t.txt"]; }],
            @[@"ln", @[@"ln", P(@"t.txt"), P(@"h.txt")], ^BOOL(NSDictionary *r) { return exists(P(@"h.txt")); }],
            @[@"mv", @[@"mv", P(@"h.txt"), P(@"b/h2.txt")], ^BOOL(NSDictionary *r) { return !exists(P(@"h.txt")) && exists(P(@"b/h2.txt")); }],
            // OSH forks a pid for each external command; its directory must
            // come back to this session's, not whichever the process had.
            @[@"osh-cd", @[@"sh", @"-c", [NSString stringWithFormat:@"cd %@ && ls -1 && ls -1 && ls -1 && pwd", P(@"b")]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"c\nh2.txt\nc\nh2.txt\nc\nh2.txt\n%@\n", at(P(@"b"))]]; }],
            // OSH's own redirections, globs, tests and subshell cd use the
            // session's directory too (in q<N>, apart from the a<N> listings).
            @[@"osh-redirect", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %@ && echo osh > %@/o.txt && cat < %@ >> %@/o.txt && cat %@/o.txt", Q, Q, P(@"t.txt"), Q, Q]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[@"osh\n" stringByAppendingString:token]]; }],
            @[@"osh-glob", @[@"sh", @"-c", [NSString stringWithFormat:@"echo %@/*.txt", Q]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%@/o.txt\n", Q]]; }],
            @[@"osh-test", @[@"sh", @"-c", [NSString stringWithFormat:@"[ -f %@ ] && [ -d %@ ] && [ ! -e %@ ] && test -s %@ && [ ! -e \"\" ] && [ ! -d \"\" ] && echo yes", P(@"t.txt"), P(@"b"), P(@"none"), P(@"t.txt")]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:@"yes\n"]; }],
            // OSH's builtin rm unlinks from the session's directory too (and,
            // with -f, ignores an empty operand, which names no file).
            @[@"osh-rm", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@ && echo x > %1$@/rmme && rm -f %1$@/rmme \"\" && [ ! -e %1$@/rmme ] && echo gone", Q]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:@"gone\n"] && !exists([Q stringByAppendingPathComponent:@"rmme"]); }],
            @[@"osh-source", @[@"sh", @"-c", [NSString stringWithFormat:@"echo 'v=sourced' > %@/s.sh && . ./%@/s.sh && echo $v", Q, Q]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:@"sourced\n"]; }],
            @[@"osh-subshell", @[@"sh", @"-c", [NSString stringWithFormat:@"(cd %@ && ls -1) && pwd && cd %@ && echo *.txt > list && cat list && pwd", P(@"b"), Q]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"c\nh2.txt\n%@\no.txt\n%@\n", home, at(Q)]]; }],
            @[@"cp", @[@"cp", P(@"b/h2.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) { return exists(P(@"c.txt")); }],
            @[@"cp-r", @[@"cp", @"-R", P(@"b"), P(@"copy")], ^BOOL(NSDictionary *r) { return exists(P(@"copy/h2.txt")) && exists(P(@"copy/c")); }],
            @[@"cat", @[@"cat", P(@"l.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            @[@"sed", @[@"sed", @"-n", @"1p", P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            @[@"grep", @[@"grep", @"-r", @"session", P(@"b")], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[P(@"b/h2.txt:") stringByAppendingString:token]]; }],
            @[@"stat", @[@"stat", @"-f", @"%z", P(@"f.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"0\n"]; }],
            @[@"readlink", @[@"readlink", P(@"l.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"t.txt\n"]; }],
            @[@"ls", @[@"ls", @"-1", A], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:@"b\nc.txt\ncopy\nf.txt\nl.txt\nt.txt\n"]; }],
            @[@"ls-R", @[@"ls", @"-1R", P(@"b")], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"c\nh2.txt\n\n%@:\n", P(@"b/c")]]; }],
            @[@"find", @[@"find", P(@"b"), @"-name", @"h2.txt"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:P(@"b/h2.txt\n")]; }],
            @[@"du", @[@"du", @"-s", P(@"b")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) hasSuffix:[NSString stringWithFormat:@"\t%@\n", P(@"b")]]; }],
            @[@"chmod", @[@"chmod", @"-R", @"go-rwx", P(@"b")], ^BOOL(NSDictionary *r) {
                struct stat info;
                return stat(at(P(@"b/h2.txt")).fileSystemRepresentation, &info) == 0 && (info.st_mode & 077) == 0; }],
            @[@"wc", @[@"wc", @"-c", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) hasSuffix:[NSString stringWithFormat:@" %@\n", P(@"t.txt")]]; }],
            @[@"pwd", @[@"pwd"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[home stringByAppendingString:@"\n"]]; }],
            @[@"pwd-P", @[@"pwd", @"-P"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[home stringByAppendingString:@"\n"]]; }],
            // Each session's TZ, without changing the process-wide one.
            @[@"date-tz", @[@"env", [NSString stringWithFormat:@"TZ=Etc/GMT-%d", index], @"date", @"-r", @"0", @"+%H %Z %z"], ^BOOL(NSDictionary *r) {
                NSString *name = index == 0 ? @"GMT" : [NSString stringWithFormat:@"+%02d", index];
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%02d %@ +%02d00\n", index, name, index]]; }],
            @[@"date-r", @[@"date", @"-r", P(@"f.txt"), @"+%Y%m%d%H%M"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"202001021530\n"]; }],
            @[@"env", @[@"env", [NSString stringWithFormat:@"SPLIT=%d", index], @"printenv", @"SPLIT"], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%d\n", index]]; }],
            @[@"xargs", @[@"xargs", @"cat"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }, [P(@"t.txt") stringByAppendingString:@"\n"]],
            @[@"xargs-I", @[@"xargs", @"-I{}", @"head", @"-n", @"1", @"{}"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }, [P(@"c.txt") stringByAppendingString:@"\n"]],
            @[@"tail", @[@"tail", @"-n", @"1", P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            @[@"sort", @[@"sort", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[token stringByAppendingString:token]]; }],
            @[@"uniq", @[@"uniq", @"-c", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) hasSuffix:[@" 1 " stringByAppendingString:token]]; }],
            @[@"awk", @[@"awk", @"{print $2}", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%d\n", index]]; }],
            @[@"df", @[@"df", P(@"b")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) hasPrefix:@"Filesystem"]; }],
            @[@"id", @[@"id", @"-u"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) intValue] == (int)getuid(); }],
            @[@"id-G", @[@"id", @"-G"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) length] > 1; }],
            @[@"uname", @[@"uname", @"-s"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) length] > 1; }],
            @[@"uptime", @[@"uptime"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) containsString:@"load average"]; }],
            // sshpass parses its options with the invocation-local getopt.
            @[@"sshpass", @[@"sshpass", @"-d", tokenWord, @"-V"], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) hasPrefix:@"sshpass"] || [text(r[@"stderr"]) hasPrefix:@"sshpass"]; }],
            // ssh parses with the invocation's getopt too (-G prints the
            // resolved configuration without connecting). OpenSSH commands of
            // different sessions take turns; sshpass's own ssh goes through.
            @[@"ssh-G", @[@"ssh", @"-G", @"-p", [NSString stringWithFormat:@"%d", 2200 + index], @"-l", [@"u" stringByAppendingString:tokenWord], @"example.invalid"], ^BOOL(NSDictionary *r) {
                NSString *output = text(r[@"stdout"]);
                return [output containsString:[NSString stringWithFormat:@"\nport %d\n", 2200 + index]] &&
                    [output containsString:[NSString stringWithFormat:@"\nuser u%@\n", tokenWord]]; }],
            @[@"sshpass-ssh", @[@"sshpass", @"-p", @"unused", @"ssh", @"-G", @"-p", [NSString stringWithFormat:@"%d", 2300 + index], @"example.invalid"], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) containsString:[NSString stringWithFormat:@"\nport %d\n", 2300 + index]]; }],
            @[@"echo", @[@"/usr/bin/echo", @"session", tokenWord], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            // OSH runs stages of a pipeline of thread-safe commands concurrently.
            @[@"pipe", @[@"sh", @"-c", [NSString stringWithFormat:@"cat %@ %@ | sed s/session/S/ | sort | uniq -c | awk '{print $1 $3}' | tr -d ' '", P(@"t.txt"), P(@"c.txt")]],
                ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"2%d\n", index]]; }],
            // After a streamed pipeline the shell is still in its own
            // directory, not the one the process had when the pipeline began.
            @[@"pipe-dir", @[@"sh", @"-c", [NSString stringWithFormat:@"cat %@ | cat; pwd; cat %@", P(@"t.txt"), P(@"t.txt")]],
                ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%@%@\n%@", token, home, token]]; }],
            // OpenSSH opens relative paths from the session's directory, not
            // the process working directory.
            @[@"ssh-keygen-relative", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@ && rm -f %1$@/r %1$@/r.pub && ssh-keygen -q -t ed25519 -N '' -C r%2$@ -f %1$@/r && ssh-keygen -y -f %1$@/r | cut -d' ' -f1 && ssh-keygen -l -f %1$@/r.pub | awk '{print $3}'", R, tokenWord]],
                ^BOOL(NSDictionary *r) {
                    return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"ssh-ed25519\nr%@\n", tokenWord]] &&
                        exists([R stringByAppendingPathComponent:@"r.pub"]); }],
            // Two OpenSSH stages of one pipeline take turns (or the second
            // reports OpenSSH busy) instead of sharing OpenSSH's globals.
            @[@"pipe-ssh-keygen", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@ && rm -f %1$@/* && env ssh-keygen -q -t ed25519 -N '' -C k1 -f %1$@/k1 | env ssh-keygen -q -t ed25519 -N '' -C k2 -f %1$@/k2", at(K)]],
                ^BOOL(NSDictionary *r) {
                    NSArray *names = [[manager contentsOfDirectoryAtPath:at(K) error:nil] sortedArrayUsingSelector:@selector(compare:)];
                    BOOL busy = [text(r[@"stderr"]) containsString:@"OpenSSH is in use by another command of this session"];
                    for (NSString *key in @[@"k1", @"k2"]) {
                        NSString *public = [NSString stringWithContentsOfFile:at([K stringByAppendingPathComponent:[key stringByAppendingString:@".pub"]]) encoding:NSUTF8StringEncoding error:nil];
                        BOOL complete = [names containsObject:key] && [public hasSuffix:[NSString stringWithFormat:@" %@\n", key]];
                        BOOL absent = ![names containsObject:key] && public == nil;
                        if (!complete && !(busy && absent)) return NO;
                    }
                    for (NSString *name in names) if (![@[@"k1", @"k1.pub", @"k2", @"k2.pub"] containsObject:name]) return NO;
                    return YES; }],
            // A system() between awk's print | "sort" and close() does not
            // join sort; awk waits for sort when it ends (in any order).
            @[@"awk-popen", @[@"awk", @"BEGIN { print \"b\" | \"sort\"; system(\"ls -d .\"); close(\"sort\"); print \"c\" }"],
                ^BOOL(NSDictionary *r) {
                    NSArray *lines = [[text(r[@"stdout"]) componentsSeparatedByString:@"\n"] sortedArrayUsingSelector:@selector(compare:)];
                    return [lines isEqualToArray:@[@"", @".", @"b", @"c"]]; }],
            // Two shell scripts that awk keeps open at once, each changing
            // directory: each runs in a session of its own, so neither
            // restores the other's directory or trips the re-entry check.
            @[@"popen-scripts", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@/sub && printf '#!/bin/sh\\ncd sub\\necho in $(pwd)\\nsleep 0.02\\n' > %1$@/cdpwd && chmod +x %1$@/cdpwd && cd %1$@ && awk 'BEGIN { for (i = 0; i < 5; i++) { a = \"./cdpwd #\" i; b = \"./cdpwd ##\" i; a | getline x; b | getline y; close(a); close(b); if (x != y || x !~ /sub$/) bad++ } print \"bad=\" bad+0 }'", W]],
                ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"bad=0\n"] && [text(r[@"stderr"]) length] == 0; }],
            // A pipeline in a popen string, reading a relative redirect: its
            // last command owns the pipe's writer (so getline ends), and the
            // redirect opens from the session's directory.
            @[@"popen-pipeline", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@ && printf 'b\\na\\n' > %1$@/p.txt && awk 'BEGIN { while ((\"cat < %1$@/p.txt | sort\" | getline x) > 0) printf \"%%s\", x; print \"\" }'", W]],
                ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"ab\n"]; }],
            // pclose waits for the command it closes: what it wrote is there
            // to read back once close() returns.
            @[@"popen-pclose", @[@"sh", @"-c", [NSString stringWithFormat:@"mkdir -p %1$@ && awk 'BEGIN { c = \"sh -c \\\"sleep 0.05; cat > %1$@/pc.txt\\\"\"; print \"x\" | c; close(c); getline y < \"%1$@/pc.txt\"; print y }'", W]],
                ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"x\n"]; }],
            @[@"pipe-find", @[@"sh", @"-c", [NSString stringWithFormat:@"find %@ -name '*.txt' | sort | xargs cat | grep -c session | wc -l", A]],
                ^BOOL(NSDictionary *r) { return [[text(r[@"stdout"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"1"]; }],
            // Aliases are one table shared by every session.
            @[@"alias", @[@"alias", [NSString stringWithFormat:@"probe%d=ls -1 %@", index, A]], ^BOOL(NSDictionary *r) { return YES; }],
            @[@"alias-list", @[@"alias"], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) containsString:[NSString stringWithFormat:@"probe%d\tls -1 %@\n", index, A]]; }],
            @[@"alias-show", @[@"alias", [NSString stringWithFormat:@"probe%d", index]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"ls -1 %@\n", A]]; }],
            @[@"unalias", @[@"unalias", [NSString stringWithFormat:@"probe%d", index]], ^BOOL(NSDictionary *r) { return YES; }],
            // The remaining commands built from Vendors/ios_system.
            @[@"base64", @[@"base64", @"-i", P(@"t.txt")], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[[[token dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0] stringByAppendingString:@"\n"]]; }],
            @[@"basename", @[@"basename", P(@"b/h2.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"h2.txt\n"]; }],
            @[@"dirname", @[@"dirname", P(@"b/h2.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[P(@"b") stringByAppendingString:@"\n"]]; }],
            @[@"realpath", @[@"realpath", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[at(P(@"t.txt")) stringByAppendingString:@"\n"]]; }],
            @[@"mktemp", @[@"mktemp", P(@"tmp.XXXXXX")], ^BOOL(NSDictionary *r) {
                NSString *made = [text(r[@"stdout"]) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
                return [made hasPrefix:P(@"tmp.")] && exists(made); }],
            @[@"cut", @[@"cut", @"-d", @" ", @"-f2", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[tokenWord stringByAppendingString:@"\n"]]; }],
            @[@"comm", @[@"comm", @"-12", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            @[@"join", @[@"join", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"session %d %d\n", index, index]]; }],
            @[@"paste", @[@"paste", @"-d", @",", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"session %d,session %d\n", index, index]]; }],
            @[@"split", @[@"split", @"-l", @"1", P(@"t.txt"), P(@"sp.")], ^BOOL(NSDictionary *r) { return exists(P(@"sp.aa")); }],
            @[@"cmp", @[@"cmp", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) length] == 0; }],
            @[@"diff", @[@"diff", P(@"t.txt"), P(@"c.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) length] == 0; }],
            @[@"xxd", @[@"xxd", @"-p", P(@"t.txt")], ^BOOL(NSDictionary *r) {
                NSMutableString *hex = [NSMutableString string];
                for (NSUInteger i = 0; i < token.length; ++i) [hex appendFormat:@"%02x", [token characterAtIndex:i]];
                return [text(r[@"stdout"]) isEqualToString:[hex stringByAppendingString:@"\n"]]; }],
            @[@"sha256sum", @[@"sha256sum", P(@"t.txt")], ^BOOL(NSDictionary *r) {
                NSString *out = text(r[@"stdout"]);
                return out.length == 64 + 2 + P(@"t.txt").length + 1 && [out hasSuffix:[NSString stringWithFormat:@"  %@\n", P(@"t.txt")]]; }],
            @[@"egrep", @[@"egrep", @"-c", @"session [0-9]+", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"1\n"]; }],
            @[@"fgrep", @[@"fgrep", @"-l", @"session", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[P(@"t.txt") stringByAppendingString:@"\n"]]; }],
            @[@"tr", @[@"tr", @"a-z", @"A-Z"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token.uppercaseString]; }, token],
            @[@"link", @[@"link", P(@"t.txt"), P(@"lk.txt")], ^BOOL(NSDictionary *r) { return exists(P(@"lk.txt")); }],
            @[@"unlink", @[@"unlink", P(@"lk.txt")], ^BOOL(NSDictionary *r) { return !exists(P(@"lk.txt")); }],
            @[@"sleep", @[@"sleep", @"0.01"], ^BOOL(NSDictionary *r) { return YES; }],
            @[@"true", @[@"true"], ^BOOL(NSDictionary *r) { return YES; }],
            @[@"type", @[@"type", @"ls"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"ls is ls\n"]; }],
            @[@"which", @[@"which", @"ls"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) hasSuffix:@"/ls\n"]; }],
            @[@"whoami", @[@"whoami"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[NSUserName() stringByAppendingString:@"\n"]]; }],
            @[@"w", @[@"w", @"-h"], ^BOOL(NSDictionary *r) { return YES; }],
            // ios_system's own cd moves only this session.
            @[@"cd", @[@"cd", A], ^BOOL(NSDictionary *r) { return YES; }],
            @[@"cd-pwd", @[@"pwd"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[at(A) stringByAppendingString:@"\n"]]; }],
            @[@"cd-back", @[@"cd", home], ^BOOL(NSDictionary *r) { return YES; }],
            @[@"cd-check", @[@"pwd"], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:[home stringByAppendingString:@"\n"]]; }],
            // setenv and unsetenv are ios_system commands under the shell.
            @[@"setenv", @[@"sh", @"-c", [NSString stringWithFormat:@"setenv PROBE_%d v && unsetenv PROBE_%d && export PROBE_%d=e%d && printenv PROBE_%d", index, index, index, index, index]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"e%d\n", index]]; }],
            // Separately vendored commands that run in this harness.
            @[@"jq", @[@"jq", @"-c", @".s"], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:[NSString stringWithFormat:@"%d\n", index]]; }, [NSString stringWithFormat:@"{\"s\":%d}\n", index]],
            @[@"zip", @[@"zip", @"-q", P(@"z.zip"), P(@"t.txt")], ^BOOL(NSDictionary *r) { return exists(P(@"z.zip")); }],
            @[@"unzip", @[@"unzip", @"-p", P(@"z.zip"), P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:token]; }],
            @[@"rg", @[@"rg", @"-c", @"session", P(@"t.txt")], ^BOOL(NSDictionary *r) { return [text(r[@"stdout"]) isEqualToString:@"1\n"]; }],
            // The repository goes again: its objects are read-only, so a plain
            // rm -r of the session directory (rm-r) would prompt on a tty stdin.
            @[@"git", @[@"sh", @"-c", [NSString stringWithFormat:@"git init -q %@ && cd %@ && echo %d > f && git add f && git status --short && cd .. && rm -rf g", P(@"g"), P(@"g"), index]], ^BOOL(NSDictionary *r) {
                return [text(r[@"stdout"]) isEqualToString:@"A  f\n"] && !exists(P(@"g")); }],
            @[@"rm", @[@"rm", P(@"c.txt")], ^BOOL(NSDictionary *r) { return !exists(P(@"c.txt")); }],
            @[@"rmdir", @[@"rmdir", P(@"b/c")], ^BOOL(NSDictionary *r) { return !exists(P(@"b/c")) && exists(P(@"b")); }],
            @[@"rm-r", @[@"rm", @"-r", A], ^BOOL(NSDictionary *r) { return !exists(A); }],
            @[@"rmdir-m", @[@"rmdir", M], ^BOOL(NSDictionary *r) { return !exists(M); }],
        ];
        for (int round = 0; round < rounds * 2; ++round) {
            BOOL mixed = round >= rounds;
            // Mixed rounds stagger sessions by a few steps so different commands overlap.
            for (NSUInteger step = 0; step < cases.count + (mixed ? 3 : 0); ++step) {
                barrier();
                NSInteger position = (NSInteger)step - (mixed ? index % 4 : 0);
                if (position < 0 || position >= (NSInteger)cases.count) continue;
                NSArray *test = cases[position];
                // SPLIT_ONLY=a,b,c runs just those cases (plus their setup when listed).
                const char *only = getenv("SPLIT_ONLY");
                if (only != NULL && ![[@(only) componentsSeparatedByString:@","] containsObject:test[0]])
                    continue;
                NSDictionary *result = run(test[1], [test[0] isEqualToString:@"tee"] ? token : test.count > 3 ? test[3] : nil);
                BOOL (^verify)(NSDictionary *) = test[2];
                BOOL ok = [result[@"status"] intValue] == 0 && verify(result);
                NSArray *left = [manager contentsOfDirectoryAtPath:home error:nil];
                // date must never leave the process-wide TZ changed.
                const char *processTZ = getenv("TZ");
                if (processTZ != NULL ? strcmp(processTZ, "UTC") != 0 : 0)
                    record(@"process TZ", NO, @(processTZ));
                record([NSString stringWithFormat:@"%@ %@", mixed ? @"mixed  " : @"aligned", test[0]], ok,
                    [NSString stringWithFormat:@"session %d round %d status=%@ stdout=%@ stderr=%@ dir=%@", index, round,
                        result[@"status"], text(result[@"stdout"]), text(result[@"stderr"]), [left componentsJoinedByString:@","]]);
            }
            barrier();
            // Start each round clean even after a failure.
            [manager removeItemAtPath:at(A) error:nil];
            [manager removeItemAtPath:at(M) error:nil];
            [manager removeItemAtPath:at(Q) error:nil];
            if (index == 0) {
                for (NSString *name in [manager contentsOfDirectoryAtPath:root error:nil]) {
                    if ([name hasPrefix:@"s-"] || [name hasPrefix:@"file"] || [@[@"Library", @"Caches", @".localc", @"tmp"] containsObject:name])
                        continue;
                    atomic_fetch_add(&sentinelLosses, 1);
                    record(@"stray  root", NO, name);
                    [manager removeItemAtPath:path(name) error:nil];
                }
            }
            barrier();
        }
    }
    return NULL;
}

/* repeat DIRECTORY COUNT COMMAND...: run one command COUNT times in a single
 * session, for leaks --atExit. Output goes to /dev/null; stdin is empty. */
static int repeatCommand(int argc, char **argv)
{
    @autoreleasepool {
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();
        NSURL *directory = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSURL *system = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        for (NSString *name in @[@"Library", @"Caches", @".localc"])
            [NSFileManager.defaultManager createDirectoryAtURL:[system URLByAppendingPathComponent:name]
                withIntermediateDirectories:YES attributes:nil error:nil];
        ios_setSystemPaths([system URLByAppendingPathComponent:@".localc"], [system URLByAppendingPathComponent:@"Library"],
            [system URLByAppendingPathComponent:@"Caches"], directory, directory, directory);
        ios_switchSession("legacy-repeat");
        ios_setDirectoryURL(directory);
        int count = atoi(argv[3]), failures = 0;
        for (int index = 0; index < count; ++index) {
            @autoreleasepool {
                FILE *in = fopen("/dev/null", "r"), *out = fopen("/dev/null", "w"), *error = fopen("/dev/null", "w");
                ios_setStreams(in, out, error);
                failures += ios_system(argc - 4, (const char **)argv + 4) != 0;
                ios_setStreams(stdin, stdout, stderr);
                fclose(in); fclose(out); fclose(error);
            }
        }
        fprintf(stderr, "repeat: %d runs, %d nonzero\n", count, failures);
        [NSFileManager.defaultManager removeItemAtURL:system error:nil];
    }
    return 0;
}

/* sessions DIRECTORY COUNT: open, use and close COUNT sessions the way a bash
 * job does, each starting a command that outlives the close; for leaks
 * --atExit (closed sessions are freed) and the sanitizers. */
static int sessionCycles(int argc, char **argv)
{
    @autoreleasepool {
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();
        NSURL *directory = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        int count = atoi(argv[3]), failures = 0;
        // Keys and streams stay alive: the background commands still use them.
        NSMutableArray<NSData *> *names = [NSMutableArray array];
        FILE **streams = calloc((size_t)count * 3, sizeof(FILE *));
        for (int index = 0; index < count; ++index) {
            @autoreleasepool {
                NSData *name = [[NSString stringWithFormat:@"legacy-sessions-%d", index] dataUsingEncoding:NSUTF8StringEncoding];
                NSMutableData *key = [name mutableCopy];
                [key appendBytes:"" length:1];
                [names addObject:key];
                ios_openSession(key.bytes);
                ios_setContext(key.bytes);
                FILE **files = streams + 3 * index;
                files[0] = fopen("/dev/null", "r"); files[1] = fopen("/dev/null", "w"); files[2] = fopen("/dev/null", "w");
                ios_setStreams(files[0], files[1], files[2]);
                ios_setDirectoryURL(directory);
                const char *command[] = {"sh", "-c", "echo x | cat; (sleep 0.05; true) &", NULL};
                pid_t pid = ios_fork();
                failures += ios_system(3, command) != 0;
                pthread_t thread = ios_getThreadId(pid);
                if (thread == (pthread_t)-1) ios_storeThreadId(pthread_self());
                else if (thread != NULL) ios_waitpid(pid);
                ios_releaseThreadId(pid);
                ios_setStreams(stdin, stdout, stderr);
                ios_closeSession(key.bytes);
            }
        }
        sleep(1); // the background commands end
        for (int index = 0; index < count * 3; ++index) fclose(streams[index]);
        free(streams);
        fprintf(stderr, "sessions: %d cycles, %d nonzero\n", count, failures);
    }
    return 0;
}

/* popen-async: with a host that does not join commands (joinMainThread off),
 * awk's command | getline and close() finish: the background child does not
 * wait for awk, the session's root, while awk waits for it. */
static int popenAsync(void)
{
    BOOL ok = NO;
    @autoreleasepool {
        ios_switchSession("legacy-popen-async");
        FILE *in = tmpfile(), *out = tmpfile(), *error = tmpfile();
        ios_setStreams(in, out, error);
        pid_t pid = ios_fork();
        joinMainThread = false;
        // Through OSH, which waits for awk, so awk is the session's root while
        // it runs and its pipe child's cleanup waits for that root.
        const char *argv[] = {"sh", "-c", "awk 'BEGIN { c = \"echo hi\"; c | getline x; close(c); print x }'"};
        ios_system(3, argv);
        // The command starts asynchronously: wait for it to take its pid, then
        // to end (a deadlock never ends; the caller's timeout reports it). The
        // host stays asynchronous until then, as its commands' cleanup reads it.
        while (ios_getThreadId(pid) == (pthread_t)-1) usleep(1000);
        ios_waitpid(pid);
        ios_releaseThreadId(pid);
        usleep(100000); // the command's last writes follow its pid release
        joinMainThread = true;
        NSData *output = readStream(out);
        ios_setStreams(stdin, stdout, stderr);
        fclose(in); fclose(out); fclose(error);
        ok = [text(output) isEqualToString:@"hi\n"];
        fprintf(stdout, "awk with joinMainThread off: %s\n", ok ? "finished" : text(output).UTF8String);
    }
    return ok ? 0 : 1;
}

/* popen-host ROUNDS: the host itself (no command running) reads pipelines
 * through ios_popen and closes them with ios_pclose, joining its commands
 * and not. The last stage of "echo a | echo b", which starts first, can end
 * and free its launch before the launch returns. ios_pclose returns only
 * once the command ended, also when the host does not join it. */
static int popenHost(int rounds)
{
    int failures = 0;
    @autoreleasepool {
        ios_switchSession("legacy-popen-host");
        for (int round = 0; round < rounds; round++) {
            joinMainThread = round % 2 == 0;
            bool reads = round % 4 < 2;
            FILE *pipe = ios_popen(reads ? "echo a | cat | cat" : "echo a | echo b", "r");
            char line[16] = "";
            if (pipe == NULL || fgets(line, sizeof(line), pipe) == NULL || strcmp(line, reads ? "a\n" : "b\n") != 0) failures++;
            if (pipe != NULL) ios_pclose(pipe);
        }
        for (int join = 1; join >= 0; join--) {
            joinMainThread = join;
            NSDate *start = [NSDate date];
            FILE *pipe = ios_popen("sleep 0.2", "r");
            if (pipe != NULL) ios_pclose(pipe);
            double elapsed = -start.timeIntervalSinceNow;
            if (pipe == NULL || elapsed < 0.15) failures++;
            fprintf(stdout, "host popen, joinMainThread %s: sleep 0.2 closed after %.3f s\n", join ? "on" : "off", elapsed);
        }
        joinMainThread = true;
    }
    fprintf(stdout, "host popen: %d rounds, %d failures\n", rounds, failures);
    return failures == 0 ? 0 : 1;
}

static void *killSessionSoon(void *unused)
{
    usleep(500000);
    ios_switchSession("legacy-popen-kill");
    ios_kill();
    return NULL;
}

/* popen-kill DIRECTORY: stopping the session also stops a shell script that
 * awk's command | getline runs in a session of its own. */
static int popenKill(const char *directory)
{
    NSTimeInterval elapsed;
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill");
        ios_setDirectoryURL([NSURL fileURLWithPath:@(directory) isDirectory:YES]);
        [@"#!/bin/sh\nsleep 30\necho late\n" writeToFile:[@(directory) stringByAppendingPathComponent:@"sleeper"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([@(directory) stringByAppendingPathComponent:@"sleeper"].fileSystemRepresentation, 0755);
        pthread_t killer;
        pthread_create(&killer, NULL, killSessionSoon, NULL);
        NSDate *start = [NSDate date];
        run(@[@"sh", @"-c", @"awk 'BEGIN { \"./sleeper\" | getline x; print \"got\", x }'"], nil);
        elapsed = -start.timeIntervalSinceNow;
        pthread_join(killer, NULL);
        fprintf(stdout, "stopped after %.1f s\n", elapsed);
    }
    return elapsed < 10 ? 0 : 1;
}

static void *runOuterAwk(void *unused)
{
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill-late");
        run(@[@"sh", @"-c", @"awk 'BEGIN { \"awk -f inner.awk\" | getline x; print \"got\", x }'"], nil);
    }
    return NULL;
}

/* popen-kill-late DIRECTORY: a shell that a background child starts after
 * the session was stopped stops too. The inner awk (awk's popen child)
 * waits for a gate that opens only after ios_kill returned, then runs
 * system(); its shell must not run. */
static int popenKillLate(const char *directory)
{
    NSString *base = @(directory);
    NSString *gate = [base stringByAppendingPathComponent:@"gate"];
    NSString *escaped = [base stringByAppendingPathComponent:@"escaped.txt"];
    [NSFileManager.defaultManager removeItemAtPath:gate error:nil];
    [NSFileManager.defaultManager removeItemAtPath:escaped error:nil];
    [@"BEGIN { while ((getline line < \"gate\") <= 0) close(\"gate\"); system(\"echo escaped-cancel > escaped.txt\") }\n"
        writeToFile:[base stringByAppendingPathComponent:@"inner.awk"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill-late");
        ios_setDirectoryURL([NSURL fileURLWithPath:base isDirectory:YES]);
    }
    pthread_t outer;
    pthread_create(&outer, NULL, runOuterAwk, NULL);
    usleep(500000);
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill-late");
        ios_kill();
    }
    [@"open\n" writeToFile:gate atomically:YES encoding:NSUTF8StringEncoding error:nil];
    pthread_join(outer, NULL);
    BOOL ran = [NSFileManager.defaultManager fileExistsAtPath:escaped];
    fprintf(stdout, "shell started after the stop: %s\n", ran ? "ran" : "stopped");
    return ran ? 1 : 0;
}

static void *runRaceAwk(void *unused)
{
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill-race");
        run(@[@"sh", @"-c", @"awk 'BEGIN { \"awk -f inner.awk\" | getline x; print \"got\", x }'"], nil);
    }
    return NULL;
}

/* popen-kill-race DIRECTORY ROUNDS: as popen-kill-late, but the stop comes
 * at a random point up to 2 ms after the gate opens, so it also lands while
 * the system() shell is registering and starting. The shell then waits for a
 * second gate, which opens only once ios_kill returned, so its write can come
 * only from a shell that ignored the stop. */
static int popenKillRace(const char *directory, int rounds)
{
    NSString *base = @(directory);
    NSString *gate = [base stringByAppendingPathComponent:@"gate"];
    NSString *after = [base stringByAppendingPathComponent:@"after"];
    NSString *escaped = [base stringByAppendingPathComponent:@"escaped.txt"];
    [@"BEGIN { while ((getline line < \"gate\") <= 0) close(\"gate\"); system(\"while [ ! -e after ]; do :; done; echo escaped-cancel > escaped.txt\") }\n"
        writeToFile:[base stringByAppendingPathComponent:@"inner.awk"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    @autoreleasepool {
        ios_switchSession("legacy-popen-kill-race");
        ios_setDirectoryURL([NSURL fileURLWithPath:base isDirectory:YES]);
    }
    int ran = 0;
    for (int round = 0; round < rounds; round++) {
        [NSFileManager.defaultManager removeItemAtPath:gate error:nil];
        [NSFileManager.defaultManager removeItemAtPath:after error:nil];
        [NSFileManager.defaultManager removeItemAtPath:escaped error:nil];
        pthread_t outer;
        pthread_create(&outer, NULL, runRaceAwk, NULL);
        usleep(20000);
        [@"open\n" writeToFile:gate atomically:YES encoding:NSUTF8StringEncoding error:nil];
        usleep(arc4random_uniform(2000));
        @autoreleasepool {
            ios_switchSession("legacy-popen-kill-race");
            ios_kill();
        }
        [@"open\n" writeToFile:after atomically:YES encoding:NSUTF8StringEncoding error:nil];
        pthread_join(outer, NULL);
        if ([NSFileManager.defaultManager fileExistsAtPath:escaped]) ran++;
    }
    fprintf(stdout, "shells that ran after the stop: %d of %d\n", ran, rounds);
    return ran == 0 ? 0 : 1;
}

extern int ios_execv(const char *path, char *const argv[]);

static void *waitForPid(void *opaque)
{
    ios_waitpid((pid_t)(intptr_t)opaque);
    return NULL;
}

/* pid-wait: a waitpid already asleep on a forked pid wakes when the launch
 * gives the pid up (ios_storeThreadId(0)), and execv outside a command reports
 * a command that ran and exited 22 as started, not as EINVAL. */
static int pidWait(void)
{
    int failures = 0;
    @autoreleasepool {
        ios_switchSession("legacy-pid-wait");
        pid_t pid = ios_fork();
        pthread_t waiter;
        pthread_create(&waiter, NULL, waitForPid, (void *)(intptr_t)pid);
        usleep(200000);
        ios_storeThreadId(0); // a launch that failed: the pid ends without running
        BOOL woke = NO;
        for (int attempt = 0; attempt < 200 && !woke; attempt++) {
            woke = pthread_kill(waiter, 0) != 0;
            if (!woke) usleep(10000);
        }
        if (woke) pthread_join(waiter, NULL); else pthread_detach(waiter);
        ios_releaseThreadId(pid);
        fprintf(stdout, "pending pid released: waiter %s\n", woke ? "woke" : "still asleep after 2 s");
        failures += !woke;

        FILE *in = tmpfile(), *out = tmpfile(), *error = tmpfile();
        ios_setStreams(in, out, error);
        pid = ios_fork();
        char *const arguments[] = {"sh", "-c", "exit 22", NULL};
        errno = 0;
        int result = ios_execv("sh", arguments);
        int execvErrno = errno;
        int status = 0;
        waitpid(pid, &status, 0);
        ios_setStreams(stdin, stdout, stderr);
        fclose(in); fclose(out); fclose(error);
        BOOL started = result == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 22;
        fprintf(stdout, "execv outside a command, exit 22: returned %d (errno %d), waitpid status %d\n",
            result, execvErrno, WEXITSTATUS(status));
        failures += !started;
    }
    return failures == 0 ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "pid-wait") == 0) return pidWait();
    if (argc > 1 && strcmp(argv[1], "popen-async") == 0) return popenAsync();
    if (argc > 2 && strcmp(argv[1], "popen-kill") == 0) return popenKill(argv[2]);
    if (argc > 2 && strcmp(argv[1], "popen-kill-late") == 0) return popenKillLate(argv[2]);
    if (argc > 2 && strcmp(argv[1], "popen-host") == 0) return popenHost(atoi(argv[2]));
    if (argc > 3 && strcmp(argv[1], "popen-kill-race") == 0) return popenKillRace(argv[2], atoi(argv[3]));
    if (argc > 4 && strcmp(argv[1], "repeat") == 0) return repeatCommand(argc, argv);
    if (argc > 3 && strcmp(argv[1], "sessions") == 0) return sessionCycles(argc, argv);
    @autoreleasepool {
        if (argc > 1) workerCount = MAX(1, MIN(MaxWorkers, atoi(argv[1])));
        if (argc > 2) rounds = MAX(1, atoi(argv[2]));
        if (argc > 3) onlyCommand = argv[3];
        failureCounts = [NSMutableDictionary dictionary];
        runCounts = [NSMutableDictionary dictionary];
        failureSamples = [NSMutableDictionary dictionary];
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        for (NSString *name in @[@"", @"Library", @"Caches", @".localc", @"tmp"])
            [NSFileManager.defaultManager createDirectoryAtURL:[directory URLByAppendingPathComponent:name]
                withIntermediateDirectories:YES attributes:nil error:nil];
        char resolved[PATH_MAX];
        root = realpath(directory.path.UTF8String, resolved) ? @(resolved) : directory.path;
        ios_setSystemPaths([directory URLByAppendingPathComponent:@".localc"], [directory URLByAppendingPathComponent:@"Library"],
            [directory URLByAppendingPathComponent:@"Caches"], directory, directory, directory);
        ios_setDirectoryURL(directory);
        ios_setenv("TMPDIR", path(@"tmp").UTF8String, 1);
        ios_setenv("LC_ALL", "en_US.UTF-8", 1);
        ios_unsetenv("CLICOLOR");
        // Project-root files that share names with the files inside tree-N/dNN.
        for (int file = 0; file < Sentinels; ++file)
            [@"sentinel\n" writeToFile:path([NSString stringWithFormat:@"file%02d.txt", file]) atomically:NO encoding:NSUTF8StringEncoding error:nil];
        pthread_t threads[MaxWorkers];
        BOOL split = onlyCommand != NULL && strcmp(onlyCommand, "split") == 0;
        for (int index = 0; index < workerCount; ++index)
            if (pthread_create(&threads[index], NULL, split ? splitWorker : worker, (void *)(intptr_t)index) != 0) abort();
        for (int index = 0; index < workerCount; ++index) pthread_join(threads[index], NULL);
        printf("workers=%d rounds=%d root=%s\n", workerCount, rounds, root.UTF8String);
        for (NSString *key in [runCounts.allKeys sortedArrayUsingSelector:@selector(compare:)])
            printf("%-20s %4d/%-4d failed%s%s\n", key.UTF8String, failureCounts[key].intValue, runCounts[key].intValue,
                failureSamples[key] ? "  e.g. " : "", failureSamples[key] ? [failureSamples[key] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String : "");
        printf(split ? "stray root entries: %d\n" : "project-root sentinel files lost: %d\n", atomic_load(&sentinelLosses));
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    }
    return 0;
}
