#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#import "ios_system/ios_system.h"

static NSString *readOutput(FILE *stream)
{
    fflush(stream);
    rewind(stream);
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), stream)) != 0) {
        [data appendBytes:buffer length:count];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL runCommand(NSArray<NSString *> *arguments, NSString *input,
    int expectedStatus, NSString **output, NSString **errors)
{
    FILE *inputFile = tmpfile(), *outputFile = tmpfile(), *errorFile = tmpfile();
    if (inputFile == NULL || outputFile == NULL || errorFile == NULL) {
        if (inputFile) fclose(inputFile);
        if (outputFile) fclose(outputFile);
        if (errorFile) fclose(errorFile);
        return NO;
    }
    NSData *inputData = [input dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(inputData.bytes, 1, inputData.length, inputFile);
    rewind(inputFile);
    const char *argv[arguments.count];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i] = arguments[i].UTF8String;
    }
    ios_setStreams(inputFile, outputFile, errorFile);
    int status = ios_system((int)arguments.count, argv);
    ios_setStreams(stdin, stdout, stderr);
    NSString *stdoutText = readOutput(outputFile);
    NSString *stderrText = readOutput(errorFile);
    fclose(inputFile);
    fclose(outputFile);
    fclose(errorFile);
    if (output) *output = stdoutText;
    if (errors) *errors = stderrText;
    if (status != expectedStatus) {
        // Do not print arguments, which may contain a key passphrase.
        fprintf(stderr, "%s returned %d, expected %d: %s\n",
            arguments.firstObject.UTF8String, status, expectedStatus, stderrText.UTF8String);
        return NO;
    }
    return YES;
}

// Stop after the client's version string. ssh loads its identity files before
// exchanging protocol banners; no authentication or external server is needed.
static void *acceptSSHConnection(void *arg)
{
    int listener = *(int *)arg;
    struct pollfd descriptor = {.fd = listener, .events = POLLIN};
    if (poll(&descriptor, 1, 10000) > 0) {
        int client = accept(listener, NULL, NULL);
        if (client >= 0) {
            struct timeval timeout = {.tv_sec = 5};
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            char buffer[256];
            recv(client, buffer, sizeof(buffer), 0);
            close(client);
        }
    }
    return NULL;
}

static BOOL validateIdentityDiscovery(NSString *identityPath, NSString *configPath,
    NSString *otherProjectPath)
{
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return NO;
    struct sockaddr_in address = {
        .sin_len = sizeof(address), .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    socklen_t length = sizeof(address);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 1) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &length) != 0) {
        close(listener);
        return NO;
    }
    pthread_t peer;
    if (pthread_create(&peer, NULL, acceptSSHConnection, &listener) != 0) {
        close(listener);
        return NO;
    }
    NSString *errors;
    BOOL success = runCommand(@[@"ssh", @"-vv", @"-o", @"BatchMode=yes",
        @"-o", @"ConnectTimeout=2", @"-o", @"ConnectionAttempts=1",
        @"-p", [NSString stringWithFormat:@"%u", ntohs(address.sin_port)],
        @"keygen-validation"], @"", 255, NULL, &errors);
    pthread_join(peer, NULL);
    close(listener);
    // OpenSSH prints type -1 when an identity did not load.
    NSString *identityLine = [NSString stringWithFormat:@"identity file %@ type ", identityPath];
    success = success && [errors containsString:identityLine] &&
        ![errors containsString:[identityLine stringByAppendingString:@"-1"]] &&
        [errors containsString:[@"Reading configuration data " stringByAppendingString:configPath]] &&
        ![errors containsString:otherProjectPath];
    if (!success) fprintf(stderr, "SSH identity discovery failed: %s\n", errors.UTF8String);
    return success;
}

#define REQUIRE(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "%s\n", message); return 1; } \
} while (0)

int ios_validateSSHKeygen(void)
{
    REQUIRE(ios_executable("ssh-keygen") && ios_executable("/usr/bin/ssh-keygen"),
        "ssh-keygen is not registered.");
    REQUIRE(ios_commandIsExclusiveOrThreadSafe("ssh-keygen") ==
        IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH &&
        ios_commandIsExclusiveOrThreadSafe("/usr/bin/ssh-keygen") ==
        IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH, "ssh-keygen isolation is incorrect.");

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByResolvingSymlinksInPath]
        URLByAppendingPathComponent:[@"ssh-keygen-validation-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSURL *library = [root URLByAppendingPathComponent:@"Library"];
    NSURL *caches = [root URLByAppendingPathComponent:@"Caches"];
    NSArray<NSURL *> *projects = @[[root URLByAppendingPathComponent:@"ProjectA"],
        [root URLByAppendingPathComponent:@"ProjectB"]];
    NSMutableArray<NSString *> *publicKeys = [NSMutableArray array];
    @try {
        for (NSURL *directory in @[library, caches]) {
            REQUIRE([manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                attributes:nil error:nil], "Cannot create test directories.");
        }
        for (NSUInteger i = 0; i < projects.count; i++) {
            NSURL *project = projects[i];
            NSURL *localCode = [project URLByAppendingPathComponent:@".localc"];
            REQUIRE([manager createDirectoryAtURL:localCode withIntermediateDirectories:YES
                attributes:nil error:nil], "Cannot create project home.");
            REQUIRE(ios_setSystemPaths(localCode, library, caches, root, project, root),
                "Cannot configure project paths.");
            ios_setDirectoryURL(project);
            char workspacePath[PATH_MAX];
            REQUIRE(realpath(root.path.fileSystemRepresentation, workspacePath) != NULL,
                "Cannot canonicalize workspace path.");
            REQUIRE(strcmp(ios_getenv("SSH_HOME"), localCode.path.UTF8String) == 0 &&
                strcmp(ios_getenv("HOME"), workspacePath) == 0,
                "SSH_HOME and HOME must be distinct.");

            NSString *sshDirectory = [localCode.path stringByAppendingPathComponent:@".ssh"];
            NSString *key = [sshDirectory stringByAppendingPathComponent:@"id_ed25519"];
            NSString *publicKey = [key stringByAppendingString:@".pub"];
            NSString *output;
            REQUIRE(runCommand(@[@"ssh-keygen", @"-q", @"-N", @"", @"-C",
                project.lastPathComponent], @"\n", 0, &output, NULL), "Default key generation failed.");
            REQUIRE([output containsString:key], "Default key prompt uses the wrong home.");
            struct stat st;
            REQUIRE(stat(key.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0600,
                "Private key permissions must be 0600.");
            REQUIRE(stat(sshDirectory.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0700,
                "SSH directory permissions must be 0700.");
            NSString *publicText = [NSString stringWithContentsOfFile:publicKey
                encoding:NSUTF8StringEncoding error:nil];
            REQUIRE([publicText hasPrefix:@"ssh-ed25519 "], "Missing Ed25519 public key.");
            [publicKeys addObject:publicText];
            REQUIRE(![manager fileExistsAtPath:[root.path stringByAppendingPathComponent:@".ssh/id_ed25519"]],
                "Key was written under workspace HOME.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-y", @"-f", key], @"", 0, &output, NULL) &&
                [output isEqualToString:publicText], "Public key derivation failed.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-l", @"-f", key], @"", 0, &output, NULL) &&
                [output containsString:@"SHA256:"] && [output containsString:@"(ED25519)"],
                "Fingerprint failed.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-t", @"invalid"], @"", 255, NULL, NULL),
                "Invalid key type was not rejected.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-q", @"-N", @"", @"-f", key], @"n\n", 1, NULL, NULL) &&
                [[NSString stringWithContentsOfFile:publicKey encoding:NSUTF8StringEncoding error:nil]
                    isEqualToString:publicText], "Overwrite refusal changed the key.");

            NSString *config = [sshDirectory stringByAppendingPathComponent:@"config"];
            NSString *configText = @"Host keygen-validation\n  HostName 127.0.0.1\n  User keygen-test\n";
            REQUIRE([configText writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:nil],
                "Cannot write SSH config.");
            REQUIRE(validateIdentityDiscovery(key, config, projects[1 - i].path),
                "ssh did not discover the generated default key.");

            NSString *customKey = [sshDirectory stringByAppendingPathComponent:@"custom"];
            REQUIRE(runCommand(@[@"ssh-keygen", @"-q", @"-t", @"rsa", @"-b", @"2048",
                @"-a", @"4", @"-N", @"test passphrase", @"-f", customKey], @"", 0, NULL, NULL),
                "Encrypted RSA key generation failed after prior invocations.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-y", @"-P", @"test passphrase", @"-f", customKey],
                @"", 0, &output, NULL) && [output hasPrefix:@"ssh-rsa "], "Encrypted key cannot be read.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-p", @"-P", @"test passphrase", @"-N", @"changed",
                @"-a", @"4", @"-f", customKey], @"", 0, NULL, NULL), "Passphrase change failed.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-y", @"-P", @"wrong", @"-f", customKey],
                @"", 255, NULL, NULL), "Incorrect passphrase was accepted.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-y", @"-P", @"changed", @"-f", customKey],
                @"", 0, &output, NULL) && [output hasPrefix:@"ssh-rsa "], "Changed passphrase failed.");
            configText = [configText stringByAppendingString:
                @"  IdentityFile ~/.ssh/custom\n  IdentitiesOnly yes\n"];
            REQUIRE([configText writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
                validateIdentityDiscovery(customKey, config, projects[1 - i].path),
                "Custom IdentityFile did not use the project's SSH_HOME.");

            NSString *customPublicKey = [customKey stringByAppendingString:@".pub"];
            NSString *certificate = [customKey stringByAppendingString:@"-cert.pub"];
            REQUIRE(runCommand(@[@"ssh-keygen", @"-s", key, @"-I", @"restricted", @"-n", @"tester",
                @"-O", @"force-command=echo validation", customPublicKey], @"", 0, NULL, NULL) &&
                runCommand(@[@"ssh-keygen", @"-L", @"-f", certificate], @"", 0, &output, NULL) &&
                [output containsString:@"force-command"], "Certificate signing failed.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-s", key, @"-I", @"ordinary", @"-n", @"tester",
                customPublicKey], @"", 0, NULL, NULL) &&
                runCommand(@[@"ssh-keygen", @"-L", @"-f", certificate], @"", 0, &output, NULL) &&
                ![output containsString:@"force-command"], "Certificate options leaked across invocations.");

            REQUIRE(runCommand(@[@"ssh-keygen", @"-Y", @"sign", @"-n", @"validation", @"-f", key],
                @"signed fixture\n", 0, &output, NULL), "SSH signature generation failed.");
            NSString *signature = [project.path stringByAppendingPathComponent:@"fixture.sig"];
            REQUIRE([output writeToFile:signature atomically:YES encoding:NSUTF8StringEncoding error:nil],
                "Cannot write signature fixture.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-Y", @"check-novalidate", @"-n", @"validation",
                @"-s", signature], @"signed fixture\n", 0, NULL, NULL), "SSH signature verification failed.");

            NSString *knownHosts = [sshDirectory stringByAppendingPathComponent:@"known_hosts"];
            REQUIRE([[@"keygen-validation " stringByAppendingString:publicText] writeToFile:knownHosts
                atomically:YES encoding:NSUTF8StringEncoding error:nil], "Cannot prepare known_hosts.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-F", @"keygen-validation"], @"", 0, &output, NULL) &&
                [output containsString:publicText], "known_hosts lookup uses the wrong home.");
            mode_t originalMask = umask(022);
            BOOL removed = runCommand(@[@"ssh-keygen", @"-R", @"keygen-validation"], @"", 0, NULL, NULL);
            mode_t resultingMask = umask(originalMask);
            REQUIRE(removed && resultingMask == 022, "known_hosts removal changed the process umask.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-F", @"keygen-validation"], @"", 1, NULL, NULL),
                "known_hosts entry was not removed.");
            REQUIRE(runCommand(@[@"ssh-keygen", @"-t", @"ed25519-sk", @"-N", @""],
                @"", 255, NULL, NULL), "Unsupported FIDO enrollment was not rejected.");
        }
        REQUIRE(![publicKeys[0] isEqualToString:publicKeys[1]], "Projects share a generated key.");
        NSURL *project = projects[0];
        NSURL *localCode = [project URLByAppendingPathComponent:@".localc"];
        REQUIRE(ios_setSystemPaths(localCode, library, caches, root, project, root),
            "Cannot return to first project.");
        ios_setDirectoryURL(project);
        NSString *output;
        REQUIRE(runCommand(@[@"ssh-keygen", @"-y"], @"\n", 0, &output, NULL) &&
            [output containsString:publicKeys[0]] && ![output containsString:publicKeys[1]],
            "Returning to the first project retained another command's key or flags.");
        fprintf(stdout, "ssh-keygen validation passed (project homes, SSH identity discovery, encryption, repeated runs).\n");
        return 0;
    } @finally {
        ios_setStreams(stdin, stdout, stderr);
        ios_setDirectoryURL([NSURL fileURLWithPath:NSTemporaryDirectory()]);
        [manager removeItemAtURL:root error:nil];
    }
}
