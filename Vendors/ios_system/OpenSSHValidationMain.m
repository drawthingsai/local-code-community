#import <Foundation/Foundation.h>

#import "ios_sshpass.h"
#import "ios_system/ios_system.h"

extern int ios_validateSSHKeygen(void);

static int validateSSHpass(void)
{
    if (!ios_executable("sshpass")) {
        fprintf(stderr, "sshpass is not registered.\n");
        return 1;
    }
    if (ios_commandIsExclusiveOrThreadSafe("sshpass") !=
        IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH) {
        fprintf(stderr, "sshpass does not use OpenSSH isolation.\n");
        return 1;
    }

    char password[64] = {0};
    if (ios_sshpass_begin("correct horse", "assword:", 0) != 0 ||
        ios_sshpass_read_passphrase(
            "Unrelated prompt", password, sizeof(password)) !=
            IOS_SSHPASS_INACTIVE ||
        ios_sshpass_read_passphrase(
            "user@example password:", password, sizeof(password)) !=
            IOS_SSHPASS_PASSWORD_PROVIDED ||
        strcmp(password, "correct horse") != 0 ||
        ios_sshpass_read_passphrase(
            "user@example password:", password, sizeof(password)) !=
            IOS_SSHPASS_INCORRECT_PASSWORD ||
        ios_sshpass_end() != IOS_SSHPASS_INCORRECT_PASSWORD) {
        fprintf(stderr, "sshpass password prompt handling failed.\n");
        ios_sshpass_end();
        return 1;
    }
    memset(password, 0, sizeof(password));

    if (ios_sshpass_begin("custom secret", "Token please:", 0) != 0 ||
        ios_sshpass_read_passphrase(
            "Password:", password, sizeof(password)) != IOS_SSHPASS_INACTIVE ||
        ios_sshpass_read_passphrase(
            "Token please:", password, sizeof(password)) !=
            IOS_SSHPASS_PASSWORD_PROVIDED ||
        strcmp(password, "custom secret") != 0 ||
        ios_sshpass_end() != IOS_SSHPASS_INACTIVE) {
        fprintf(stderr, "sshpass custom prompt handling failed.\n");
        ios_sshpass_end();
        return 1;
    }
    memset(password, 0, sizeof(password));

    if (ios_sshpass_begin("unused", "assword:", 0) != 0 ||
        ios_sshpass_read_passphrase(
            "The authenticity of host 'example' cannot be established. "
            "Are you sure you want to continue connecting?",
            password, sizeof(password)) != IOS_SSHPASS_HOST_KEY_UNKNOWN ||
        ios_sshpass_end() != IOS_SSHPASS_HOST_KEY_UNKNOWN) {
        fprintf(stderr, "sshpass host-key prompt handling failed.\n");
        ios_sshpass_end();
        return 1;
    }

    const char *versionArguments[] = {
        "sshpass", "-p", "unused", "ssh", "-V",
    };
    if (ios_system(5, versionArguments) != 0) {
        fprintf(stderr, "sshpass could not invoke embedded ssh.\n");
        return 1;
    }
    const char *conflictArguments[] = {
        "sshpass", "-p", "unused", "-e", "ssh", "-V",
    };
    if (ios_system(6, conflictArguments) != 2) {
        fprintf(stderr, "sshpass did not reject conflicting password sources.\n");
        return 1;
    }
    const char *unsupportedArguments[] = {
        "sshpass", "-p", "unused", "true",
    };
    if (ios_system(4, unsupportedArguments) != 1) {
        fprintf(stderr, "sshpass did not reject an unsupported command.\n");
        return 1;
    }
    fprintf(stdout, "sshpass validation passed.\n");
    return 0;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        ios_setStreams(stdin, stdout, stderr);
        initializeEnvironment();

        if (argc == 2 && strcmp(argv[1], "--validate-ssh-keygen") == 0) {
            return ios_validateSSHKeygen();
        }

        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"local-code-openssh-validation"]
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

        if (argc == 2 && strcmp(argv[1], "--validate-sshpass") == 0) {
            return validateSSHpass();
        }
        if (argc > 1) {
            return ios_system(argc - 1, (const char *const *)(argv + 1));
        }
        const char *arguments[] = {"ssh", "-V"};
        return ios_system(2, arguments);
    }
}
