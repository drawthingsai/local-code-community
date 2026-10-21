#import <Foundation/Foundation.h>
#include "Vendors/Lean/LeanCommand.h"
#import "ios_system/ios_system.h"

// Manual network validation: uses the same native command path as BashTools'
// directSequence, then a fresh shell session for the installed proof.
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 4 && argc != 6) {
      fprintf(stderr, "usage: MathlibInstallValidation PROJECT RESOURCES LEAN_ARCHIVE [PROOF EXPECTED_STATUS]\n");
      return 2;
    }
    NSString *expectedStatus = argc == 6 ? @(argv[5]) : @"valid";
    if (![expectedStatus isEqualToString:@"valid"] &&
        ![expectedStatus isEqualToString:@"conditional"]) return 2;
    NSURL *project = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSURL *resources = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    initializeEnvironment();
    ios_registerCommand("lean", lean_main);
    ios_registerCommand("check_lean", check_lean_main);
    ios_switchSession("mathlib-install-validation");
    ios_setStreams(stdin, stdout, stderr);
    if (!ios_setSystemPaths(project, project, project, project, project, resources)) return 1;
    ios_setDirectoryURL(project);
    ios_setenv("LEAN_RESOURCE_ARCHIVE", argv[3], 1);
    ios_setenv("LEAN_RESOURCE_CACHE", [[project URLByAppendingPathComponent:@"lean-cache"] fileSystemRepresentation], 1);
    const char *version[] = {"lean", "--short-version"};
    if (ios_system(2, version) != 0) return 1;
    const char *cd[] = {"cd", "/app_bundle"};
    if (ios_system(2, cd) != 0) return 1;
    const char *install[] = {"python3", "Skills/check_lean-and-lean-tools/scripts/install_mathlib.py",
                            "--project-root", argv[1], "--lean-version", "4.34.0"};
    if (ios_system(6, install) != 0) return 1;

    ios_switchSession("mathlib-proof-validation");
    ios_setStreams(stdin, stdout, stderr);
    if (!ios_setSystemPaths(project, project, project, project, project, resources)) return 1;
    ios_setDirectoryURL(project);
    ios_setenv("LEAN_RESOURCE_ARCHIVE", argv[3], 1);
    ios_setenv("LEAN_RESOURCE_CACHE", [[project URLByAppendingPathComponent:@"lean-cache"] fileSystemRepresentation], 1);
    FILE *output = tmpfile();
    if (output == NULL) return 1;
    ios_setStreams(stdin, output, stderr);
    NSString *proof = argc == 6 ? @(argv[4]) : @".localc/lean/packages/mathlib/4.34.0/SmokeTest.lean";
    NSString *command = [NSString stringWithFormat:
        @"LEAN_PATH=.localc/lean/packages/mathlib/4.34.0/lib/lean check_lean --stdin < '%@'",
        [proof stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    int status = ios_system_osh(command.UTF8String);
    fflush(output);
    rewind(output);
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), output)) > 0) {
      [data appendBytes:buffer length:count];
    }
    ios_setStreams(stdin, stdout, stderr);
    fclose(output);
    NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    fputs(result.UTF8String ?: "", stdout);
    NSString *expected = [NSString stringWithFormat:@"status: %@", expectedStatus];
    return status == 0 && [[result componentsSeparatedByString:@"\n"] containsObject:expected] ? 0 : 1;
  }
}
