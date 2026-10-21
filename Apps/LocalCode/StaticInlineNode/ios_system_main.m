#import <Foundation/Foundation.h>

#import "NodeMobile.h"
#import "ios_system.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <unistd.h>

static int StaticInlineNodeIOSSystemTestBrokenPipe(void) {
  int descriptors[2];
  if (pipe(descriptors) != 0) return 1;
  close(descriptors[0]);
  FILE* output = fdopen(descriptors[1], "w");
  FILE* errors = tmpfile();
  if (output == NULL || errors == NULL) {
    if (output != NULL) fclose(output);
    else close(descriptors[1]);
    if (errors != NULL) fclose(errors);
    return 1;
  }
  FILE* savedInput = ios_stdin();
  FILE* savedOutput = ios_stdout();
  FILE* savedError = ios_stderr();
  ios_setStreams(savedInput, output, errors);
  const char* arguments[] = {
    "node", "-e",
    "try { require('node:fs').writeSync(process.stdout.fd, 'x'); process.exitCode = 2; }"
    "catch (error) { if (error.code !== 'EPIPE') throw error; console.error('node EPIPE survived'); }",
  };
  int status = ios_system(3, arguments);
  ios_setStreams(savedInput, savedOutput, savedError);
  fflush(errors);
  rewind(errors);
  char diagnostic[4096];
  size_t count = fread(diagnostic, 1, sizeof(diagnostic) - 1, errors);
  diagnostic[count] = '\0';
  fclose(output);
  fclose(errors);
  if (status != 0 || strstr(diagnostic, "node EPIPE survived") == NULL) {
    fprintf(stderr, "[StaticInlineNodeIOSSystem] broken pipe failed (%d): %s\n", status, diagnostic);
    return 1;
  }
  fprintf(stderr, "[StaticInlineNodeIOSSystem] broken pipe passed\n");
  return 0;
}

static int StaticInlineNodeIOSSystemTestPreparedCancellation(void) {
  int inputDescriptor = dup(STDIN_FILENO);
  int outputDescriptor = dup(STDOUT_FILENO);
  int errorDescriptor = dup(STDERR_FILENO);
  if (inputDescriptor < 0 || outputDescriptor < 0 || errorDescriptor < 0) {
    if (inputDescriptor >= 0) close(inputDescriptor);
    if (outputDescriptor >= 0) close(outputDescriptor);
    if (errorDescriptor >= 0) close(errorDescriptor);
    return 1;
  }
  char executable[] = "node";
  char evaluate[] = "-e";
  char script[] = "throw new Error('cancelled command executed')";
  char* arguments[] = {executable, evaluate, script};
  node_mobile_command_options options = {
      .command_identifier = UINT64_MAX,
      .stdin_fd = inputDescriptor,
      .stdout_fd = outputDescriptor,
      .stderr_fd = errorDescriptor,
  };
  int prepareStatus = node_mobile_prepare_command(UINT64_MAX);
  int cancellationStatus = prepareStatus == 0
      ? node_mobile_cancel_command(UINT64_MAX)
      : -1;
  int runStatus = prepareStatus == 0 && cancellationStatus == 0
      ? node_mobile_run_command(3, arguments, &options)
      : -1;
  int cancellationWasRequested = 0;
  int finishStatus = prepareStatus == 0
      ? node_mobile_finish_command(
          UINT64_MAX, &cancellationWasRequested)
      : -1;
  close(inputDescriptor);
  close(outputDescriptor);
  close(errorDescriptor);
  if (prepareStatus != 0 || cancellationStatus != 0 ||
      runStatus != 130 || finishStatus != 0 ||
      cancellationWasRequested != 1) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] prepared cancellation returned "
        "prepare=%d cancel=%d run=%d finish=%d observed=%d\n",
        prepareStatus,
        cancellationStatus,
        runStatus,
        finishStatus,
        cancellationWasRequested);
    return 1;
  }
  return 0;
}

static NSString* StaticInlineNodeIOSSystemShellQuote(NSString* value) {
  NSString* escaped =
      [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
  return [NSString stringWithFormat:@"'%@'", escaped];
}

static NSString* StaticInlineNodeIOSSystemReadFile(NSString* path) {
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (data.length == 0) {
    return @"";
  }
  return [[NSString alloc] initWithData:data
                               encoding:NSUTF8StringEncoding] ?: @"";
}

static int StaticInlineNodeIOSSystemRunCommand(
    NSString* command,
    int expectedStatus,
    NSArray<NSString*>* expectedStdout,
    NSArray<NSString*>* expectedStderr,
    NSString* outputDirectory,
    NSUInteger index) {
  NSString* stdoutPath = [outputDirectory
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"command-%03lu.out",
                                                          (unsigned long)index]];
  NSString* stderrPath = [outputDirectory
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"command-%03lu.err",
                                                          (unsigned long)index]];
  NSString* wrappedCommand = [NSString
      stringWithFormat:@"%@ > %@ 2> %@", command,
                       StaticInlineNodeIOSSystemShellQuote(stdoutPath),
                       StaticInlineNodeIOSSystemShellQuote(stderrPath)];
  fprintf(stderr, "[StaticInlineNodeIOSSystem] $ %s\n", command.UTF8String);
  int status = ios_system_osh(wrappedCommand.UTF8String);
  NSString* stdoutText = StaticInlineNodeIOSSystemReadFile(stdoutPath);
  NSString* stderrText = StaticInlineNodeIOSSystemReadFile(stderrPath);
  if (status != expectedStatus) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] expected status %d, received %d\nstdout:\n%s"
        "\nstderr:\n%s\n",
        expectedStatus, status, stdoutText.UTF8String, stderrText.UTF8String);
    return 1;
  }
  for (NSString* fragment in expectedStdout) {
    if ([stdoutText rangeOfString:fragment].location == NSNotFound) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] missing stdout fragment %s in:\n%s\n",
          fragment.UTF8String, stdoutText.UTF8String);
      return 1;
    }
  }
  for (NSString* fragment in expectedStderr) {
    if ([stderrText rangeOfString:fragment].location == NSNotFound) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] missing stderr fragment %s in:\n%s\n",
          fragment.UTF8String, stderrText.UTF8String);
      return 1;
    }
  }
  return 0;
}

static int StaticInlineNodeIOSSystemRunArguments(
    NSArray<NSString*>* arguments,
    int expectedStatus,
    NSArray<NSString*>* expectedStdout,
    NSArray<NSString*>* expectedStderr,
    NSString* outputDirectory,
    NSUInteger index) {
  NSString* stdoutPath = [outputDirectory
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"direct-%03lu.out",
                                                          (unsigned long)index]];
  NSString* stderrPath = [outputDirectory
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"direct-%03lu.err",
                                                          (unsigned long)index]];
  FILE* stdoutFile = fopen(stdoutPath.fileSystemRepresentation, "w");
  FILE* stderrFile = fopen(stderrPath.fileSystemRepresentation, "w");
  if (stdoutFile == NULL || stderrFile == NULL) {
    if (stdoutFile != NULL) fclose(stdoutFile);
    if (stderrFile != NULL) fclose(stderrFile);
    fprintf(stderr, "[StaticInlineNodeIOSSystem] unable to open direct output\n");
    return 1;
  }

  const char** argv =
      calloc(arguments.count, sizeof(char*));
  if (argv == NULL) {
    fclose(stdoutFile);
    fclose(stderrFile);
    return 1;
  }
  NSMutableArray<NSString*>* stableArguments =
      [NSMutableArray arrayWithCapacity:arguments.count];
  for (NSString* argument in arguments) {
    [stableArguments addObject:[argument copy]];
  }
  for (NSUInteger argument = 0; argument < stableArguments.count; ++argument) {
    argv[argument] = stableArguments[argument].UTF8String;
  }

  fprintf(
      stderr, "[StaticInlineNodeIOSSystem] argv: %s\n",
      [stableArguments componentsJoinedByString:@" | "].UTF8String);
  ios_setStreams(stdin, stdoutFile, stderrFile);
  int status = ios_system((int)stableArguments.count, argv);
  fflush(stdoutFile);
  fflush(stderrFile);
  ios_setStreams(stdin, stdout, stderr);
  fclose(stdoutFile);
  fclose(stderrFile);
  free(argv);

  NSString* stdoutText = StaticInlineNodeIOSSystemReadFile(stdoutPath);
  NSString* stderrText = StaticInlineNodeIOSSystemReadFile(stderrPath);
  if (status != expectedStatus) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] direct argv expected status %d, received "
        "%d\nstdout:\n%s\nstderr:\n%s\n",
        expectedStatus, status, stdoutText.UTF8String, stderrText.UTF8String);
    return 1;
  }
  for (NSString* fragment in expectedStdout) {
    if ([stdoutText rangeOfString:fragment].location == NSNotFound) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] missing direct stdout fragment %s "
          "in:\n%s\n",
          fragment.UTF8String, stdoutText.UTF8String);
      return 1;
    }
  }
  for (NSString* fragment in expectedStderr) {
    if ([stderrText rangeOfString:fragment].location == NSNotFound) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] missing direct stderr fragment %s "
          "in:\n%s\n",
          fragment.UTF8String, stderrText.UTF8String);
      return 1;
    }
  }
  return 0;
}

static void StaticInlineNodeIOSSystemConfigureSession(
    const void* session,
    NSString* project,
    NSString* preload) {
  ios_switchSession(session);
  ios_setStreams(stdin, stdout, stderr);
  ios_setMiniRoot(project);
  ios_setDirectoryURL([NSURL fileURLWithPath:project isDirectory:YES]);
  ios_setenv("NODE_MOBILE_VIRTUAL_NODE_ROOTS", project.UTF8String, 1);
  ios_setenv(
      "NODE_MOBILE_VIRTUAL_NODE_PRELOAD", preload.UTF8String, 1);
}

static int StaticInlineNodeIOSSystemTestSleepCancellation(
    NSString* project,
    NSString* preload) {
  static char sleepCancellationSession[] =
      "StaticInlineNodeSleepCancellation";
  StaticInlineNodeIOSSystemConfigureSession(
      sleepCancellationSession, project, preload);

  __block int commandStatus = -1;
  dispatch_group_t group = dispatch_group_create();
  dispatch_group_async(
      group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ios_switchSession(sleepCancellationSession);
        ios_setStreams(stdin, stdout, stderr);
        const char* arguments[] = {"sleep", "inf"};
        commandStatus = ios_system(2, arguments);
      });

  usleep(10000);
  if (dispatch_group_wait(group, DISPATCH_TIME_NOW) == 0) {
    fprintf(
        stderr, "[StaticInlineNodeIOSSystem] sleep ended before cancellation\n");
    return 1;
  }
  for (int attempt = 0; attempt < 200; ++attempt) {
    int cancellationStatus = ios_kill();
    if (cancellationStatus != 0 && cancellationStatus != ESRCH) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] sleep cancellation returned %d\n",
          cancellationStatus);
      return 1;
    }
    if (dispatch_group_wait(group, DISPATCH_TIME_NOW) == 0) {
      break;
    }
    usleep(10000);
  }
  if (dispatch_group_wait(
          group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
    fprintf(
        stderr, "[StaticInlineNodeIOSSystem] sleep cancellation timed out\n");
    return 1;
  }
  // Direct generic-command cancellation currently preserves status 0, while
  // cancellation through OSH reports 130.
  if (commandStatus != 0 && commandStatus != 130) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] unexpected sleep cancellation status %d\n",
        commandStatus);
    return 1;
  }
  return 0;
}

static int StaticInlineNodeIOSSystemTestCancellation(
    NSString* project,
    NSString* preload,
    NSString* outputDirectory,
    NSUInteger index) {
  static char cancellationSession[] = "StaticInlineNodeCancellation";
  StaticInlineNodeIOSSystemConfigureSession(
      cancellationSession, project, preload);

  NSString* stdoutPath = [outputDirectory
      stringByAppendingPathComponent:@"cancellation.out"];
  NSString* stderrPath = [outputDirectory
      stringByAppendingPathComponent:@"cancellation.err"];
  NSString* command = [NSString
      stringWithFormat:
          @"node -e \"const { Worker } = require('node:worker_threads'); "
          @"new Worker('setInterval(() => {}, 1000)', {eval: true}); "
          @"setInterval(() => {}, 1000)\" > %@ 2> %@",
          StaticInlineNodeIOSSystemShellQuote(stdoutPath),
          StaticInlineNodeIOSSystemShellQuote(stderrPath)];
  __block int commandStatus = -1;
  dispatch_group_t group = dispatch_group_create();
  dispatch_group_async(
      group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ios_switchSession(cancellationSession);
        commandStatus = ios_system_osh(command.UTF8String);
      });

  int cancellationStatus = ESRCH;
  for (int attempt = 0; attempt < 200 && cancellationStatus == ESRCH;
       ++attempt) {
    usleep(10000);
    cancellationStatus = ios_kill();
  }
  if (cancellationStatus != 0) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] cancellation returned %d\n",
        cancellationStatus);
    return 1;
  }
  if (dispatch_group_wait(
          group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
    fprintf(stderr, "[StaticInlineNodeIOSSystem] cancellation timed out\n");
    return 1;
  }
  if (commandStatus != 130) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] expected cancellation status 130, "
        "received %d\n",
        commandStatus);
    return 1;
  }
  return StaticInlineNodeIOSSystemRunCommand(
      @"node -e \"console.log('after cancellation')\"",
      0,
      @[ @"after cancellation" ],
      @[],
      outputDirectory,
      index);
}

static int StaticInlineNodeIOSSystemTestNodeWrapperCancellation(
    const void* session,
    NSString* commandName,
    NSString* command,
    NSString* expectedOutput,
    NSString* project,
    NSString* preload,
    NSString* outputDirectory,
    NSUInteger index) {
  StaticInlineNodeIOSSystemConfigureSession(session, project, preload);

  NSString* stdoutPath = [outputDirectory
      stringByAppendingPathComponent:
          [commandName stringByAppendingString:@"-cancellation.out"]];
  NSString* stderrPath = [outputDirectory
      stringByAppendingPathComponent:
          [commandName stringByAppendingString:@"-cancellation.err"]];
  NSString* redirectedCommand = [NSString
      stringWithFormat:@"%@ > %@ 2> %@",
                       command,
                       StaticInlineNodeIOSSystemShellQuote(stdoutPath),
                       StaticInlineNodeIOSSystemShellQuote(stderrPath)];
  __block int commandStatus = -1;
  dispatch_group_t group = dispatch_group_create();
  dispatch_group_async(
      group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ios_switchSession(session);
        commandStatus = ios_system_osh(redirectedCommand.UTF8String);
      });

  for (int attempt = 0; attempt < 200; ++attempt) {
    if ([StaticInlineNodeIOSSystemReadFile(stdoutPath)
            containsString:expectedOutput]) {
      break;
    }
    usleep(10000);
  }
  if (![StaticInlineNodeIOSSystemReadFile(stdoutPath)
          containsString:expectedOutput]) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] %s cancellation command did not start\n",
        commandName.UTF8String);
    return 1;
  }
  int cancellationStatus = ios_kill();
  if (cancellationStatus != 0) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] %s cancellation returned %d\n",
        commandName.UTF8String,
        cancellationStatus);
    return 1;
  }
  if (dispatch_group_wait(
          group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] %s cancellation timed out\n",
        commandName.UTF8String);
    return 1;
  }
  if (commandStatus != 130) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] expected %s cancellation status 130, "
        "received %d\n",
        commandName.UTF8String,
        commandStatus);
    return 1;
  }
  NSString* followupOutput =
      [NSString stringWithFormat:@"after %@ cancellation", commandName];
  NSString* followupCommand = [NSString
      stringWithFormat:@"node -e \"console.log('%@')\"", followupOutput];
  return StaticInlineNodeIOSSystemRunCommand(
      followupCommand,
      0,
      @[ followupOutput ],
      @[],
      outputDirectory,
      index);
}

static int StaticInlineNodeIOSSystemTestQueuedCancellation(
    NSString* project,
    NSString* preload,
    NSString* outputDirectory) {
  static char activeSession[] = "StaticInlineNodeActive";
  static char queuedSession[] = "StaticInlineNodeQueued";
  StaticInlineNodeIOSSystemConfigureSession(activeSession, project, preload);
  StaticInlineNodeIOSSystemConfigureSession(queuedSession, project, preload);

  NSString* activeOutput =
      [outputDirectory stringByAppendingPathComponent:@"active.out"];
  NSString* queuedOutput =
      [outputDirectory stringByAppendingPathComponent:@"queued.out"];
  FILE* activeOutputFile = fopen(activeOutput.fileSystemRepresentation, "w");
  FILE* queuedOutputFile = fopen(queuedOutput.fileSystemRepresentation, "w");
  if (activeOutputFile == NULL || queuedOutputFile == NULL) {
    if (activeOutputFile != NULL) fclose(activeOutputFile);
    if (queuedOutputFile != NULL) fclose(queuedOutputFile);
    return 1;
  }

  __block int activeStatus = -1;
  __block int queuedStatus = -1;
  dispatch_group_t group = dispatch_group_create();
  dispatch_group_async(
      group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ios_switchSession(activeSession);
        ios_setStreams(stdin, activeOutputFile, stderr);
        const char* arguments[] = {
            "node",
            "-e",
            "console.log('active started'); "
            "setTimeout(() => console.log('active done'), 400)",
        };
        activeStatus = ios_system(3, arguments);
        fflush(activeOutputFile);
      });
  for (int attempt = 0; attempt < 200; ++attempt) {
    if ([StaticInlineNodeIOSSystemReadFile(activeOutput)
            containsString:@"active started"]) {
      break;
    }
    usleep(10000);
  }
  if (![StaticInlineNodeIOSSystemReadFile(activeOutput)
          containsString:@"active started"]) {
    fprintf(stderr, "[StaticInlineNodeIOSSystem] active command did not start\n");
    return 1;
  }

  dispatch_group_async(
      group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ios_switchSession(queuedSession);
        ios_setStreams(stdin, queuedOutputFile, stderr);
        const char* arguments[] = {
            "node", "-e", "console.log('queued ran')",
        };
        queuedStatus = ios_system(3, arguments);
        fflush(queuedOutputFile);
      });
  ios_switchSession(queuedSession);
  int cancellationStatus = ESRCH;
  for (int attempt = 0; attempt < 200 && cancellationStatus == ESRCH;
       ++attempt) {
    usleep(10000);
    cancellationStatus = ios_kill();
  }
  if (cancellationStatus != 0) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] queued cancellation returned %d\n",
        cancellationStatus);
    return 1;
  }
  if (dispatch_group_wait(
          group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
    fprintf(
        stderr, "[StaticInlineNodeIOSSystem] queued cancellation timed out\n");
    return 1;
  }
  fclose(activeOutputFile);
  fclose(queuedOutputFile);
  NSString* activeText = StaticInlineNodeIOSSystemReadFile(activeOutput);
  NSString* queuedText = StaticInlineNodeIOSSystemReadFile(queuedOutput);
  if (activeStatus != 0 ||
      [activeText rangeOfString:@"active done"].location == NSNotFound) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] cancelling the queued command affected "
        "the active command (status=%d, output=%s)\n",
        activeStatus,
        activeText.UTF8String);
    return 1;
  }
  if (queuedStatus != 130 || queuedText.length != 0) {
    fprintf(
        stderr,
        "[StaticInlineNodeIOSSystem] queued command was not isolated "
        "(status=%d, output=%s)\n",
        queuedStatus,
        queuedText.UTF8String);
    return 1;
  }
  return 0;
}

static NSString* StaticInlineNodeIOSSystemRuntimePreload(void) {
  NSMutableArray<NSString*>* candidates = [NSMutableArray array];
  NSString* configured =
      NSProcessInfo.processInfo.environment[@"NODE_MOBILE_VIRTUAL_NODE_PRELOAD"];
  if (configured.length > 0) {
    [candidates addObject:configured];
  }
  NSString* workspace =
      NSProcessInfo.processInfo.environment[@"BUILD_WORKSPACE_DIRECTORY"];
  if (workspace.length > 0) {
    [candidates
        addObject:[workspace
                      stringByAppendingPathComponent:
                          @"Apps/LocalCode/Resources/NodeMobile/Runtime/"
                           "virtual-node-child-preload.cjs"]];
  }
  char currentDirectory[PATH_MAX];
  if (getcwd(currentDirectory, sizeof(currentDirectory)) != NULL) {
    [candidates
        addObject:[@(currentDirectory)
                      stringByAppendingPathComponent:
                          @"Apps/LocalCode/Resources/NodeMobile/Runtime/"
                           "virtual-node-child-preload.cjs"]];
  }
  for (NSString* candidate in candidates) {
    if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
      return candidate;
    }
  }
  return nil;
}

static NSString* StaticInlineNodeIOSSystemNPMRoot(void) {
  NSString* configured =
      NSProcessInfo.processInfo.environment[@"NODE_MOBILE_NPM_ROOT"];
  if (configured.length == 0) {
    return nil;
  }
  NSString* npmCLI = [configured stringByAppendingPathComponent:@"bin/npm-cli.js"];
  NSString* npxCLI = [configured stringByAppendingPathComponent:@"bin/npx-cli.js"];
  if (ios_setNodeCommandPaths(npmCLI, npxCLI) == 0) {
    return nil;
  }
  return configured;
}

int main(int argc, char* argv[]) {
  @autoreleasepool {
    if (ios_commandIsExclusiveOrThreadSafe("echo") !=
            IOS_COMMAND_ISOLATION_THREAD_SAFE ||
        ios_commandIsExclusiveOrThreadSafe("pbcopy") !=
            IOS_COMMAND_ISOLATION_THREAD_SAFE ||
        ios_commandIsExclusiveOrThreadSafe("pbpaste") !=
            IOS_COMMAND_ISOLATION_THREAD_SAFE ||
        ios_commandIsExclusiveOrThreadSafe("sleep") !=
            IOS_COMMAND_ISOLATION_THREAD_SAFE ||
        ios_commandIsExclusiveOrThreadSafe("/usr/bin/sleep") !=
            IOS_COMMAND_ISOLATION_THREAD_SAFE ||
        ios_commandIsExclusiveOrThreadSafe("python") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_PYTHON ||
        ios_commandIsExclusiveOrThreadSafe("/usr/bin/python") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_PYTHON ||
        ios_commandIsExclusiveOrThreadSafe("node") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_NODE ||
        ios_commandIsExclusiveOrThreadSafe("curl") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_CURL ||
        ios_commandIsExclusiveOrThreadSafe("img2txt") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_IMG2TXT ||
        ios_commandIsExclusiveOrThreadSafe("ssh") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH ||
        ios_commandIsExclusiveOrThreadSafe("scp") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH ||
        ios_commandIsExclusiveOrThreadSafe("sftp") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH ||
        ios_commandIsExclusiveOrThreadSafe("sshpass") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH ||
        ios_commandIsExclusiveOrThreadSafe("sh") !=
            IOS_COMMAND_ISOLATION_OSH ||
        ios_commandIsExclusiveOrThreadSafe("/usr/bin/sh") !=
            IOS_COMMAND_ISOLATION_OSH ||
        ios_commandIsExclusiveOrThreadSafe("rg") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH ||
        ios_commandIsExclusiveOrThreadSafe("unknown") !=
            IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH) {
      fprintf(stderr,
              "[StaticInlineNodeIOSSystem] invalid command execution policy\n");
      return 1;
    }
    ios_setStreams(stdin, stdout, stderr);
    initializeEnvironment();
    // Both runtimes encapsulate OpenSSL; the harness must not require either
    // runtime's private dependency to become an exported application symbol.
    // System frameworks may independently expose their own OpenSSL symbols.
    if (dlsym(RTLD_MAIN_ONLY, "OpenSSL_version") != NULL) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] OpenSSL escaped runtime encapsulation\n");
      return 1;
    }

    NSString* directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:
                                               @"StaticInlineNodeIOSSystem-%d",
                                               getpid()]];
    NSString* project = [directory stringByAppendingPathComponent:@"project"];
    NSString* documents =
        [directory stringByAppendingPathComponent:@"documents"];
    NSString* library = [directory stringByAppendingPathComponent:@"library"];
    NSString* caches = [directory stringByAppendingPathComponent:@"caches"];
    NSString* appBundle =
        [directory stringByAppendingPathComponent:@"app-bundle"];
    for (NSString* path in @[ project, documents, library, caches, appBundle ]) {
      if (![NSFileManager.defaultManager
              createDirectoryAtPath:path
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil]) {
        fprintf(
            stderr, "[StaticInlineNodeIOSSystem] unable to create %s\n",
            path.UTF8String);
        return 1;
      }
    }
    if (ios_setSystemPaths(
            [NSURL fileURLWithPath:documents isDirectory:YES],
            [NSURL fileURLWithPath:library isDirectory:YES],
            [NSURL fileURLWithPath:caches isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES],
            [NSURL fileURLWithPath:project isDirectory:YES],
            [NSURL fileURLWithPath:appBundle isDirectory:YES]) == 0) {
      fprintf(stderr, "[StaticInlineNodeIOSSystem] system path setup failed\n");
      return 1;
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:project isDirectory:YES]);
    ios_setenv(
        "NODE_MOBILE_VIRTUAL_NODE_ROOTS", directory.UTF8String, 1);
    NSString* preload = StaticInlineNodeIOSSystemRuntimePreload();
    if (preload == nil) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] virtual-child preload is unavailable\n");
      return 1;
    }
    ios_setenv(
        "NODE_MOBILE_VIRTUAL_NODE_PRELOAD", preload.UTF8String, 1);
    if (argc == 2 && strcmp(argv[1], "--validate-sleep") == 0) {
      return StaticInlineNodeIOSSystemTestSleepCancellation(project, preload);
    }
    ios_setenv("NODE_IOS_SYSTEM_TEST", "session value", 1);
    if (StaticInlineNodeIOSSystemNPMRoot() == nil) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] npm command payload is unavailable\n");
      return 1;
    }
    if (StaticInlineNodeIOSSystemTestPreparedCancellation() != 0) {
      return 1;
    }
    if (![@"bundled fixture\n"
            writeToFile:[appBundle
                            stringByAppendingPathComponent:@"bundled-fixture.txt"]
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil]) {
      fprintf(stderr, "[StaticInlineNodeIOSSystem] app bundle fixture failed\n");
      return 1;
    }

    NSString* commonJSPath =
        [project stringByAppendingPathComponent:@"command.cjs"];
    NSString* modulePath =
        [project stringByAppendingPathComponent:@"module.mjs"];
    NSString* evalModuleValuePath =
        [project stringByAppendingPathComponent:@"eval-value.mjs"];
    NSString* moduleStdinPath =
        [project stringByAppendingPathComponent:@"stdin.mjs"];
    NSString* childPath =
        [project stringByAppendingPathComponent:@"child.cjs"];
    NSString* parentPath =
        [project stringByAppendingPathComponent:@"parent.cjs"];
    NSString* nestedNPXPath =
        [project stringByAppendingPathComponent:@"nested-npx.cjs"];
    NSString* stdinPath =
        [project stringByAppendingPathComponent:@"stdin.cjs"];
    NSString* shellProjectPath =
        [project stringByAppendingPathComponent:@"shell-project"];
    NSString* fixturePackagePath =
        [project stringByAppendingPathComponent:@"fixture-package"];
    NSString* npxCachePackagePath =
        [project stringByAppendingPathComponent:@"npx-cache-package"];
    NSString* esmPackagePath =
        [project stringByAppendingPathComponent:@"esm-package"];
    if (![NSFileManager.defaultManager
            createDirectoryAtPath:fixturePackagePath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil] ||
        ![NSFileManager.defaultManager
            createDirectoryAtPath:npxCachePackagePath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil] ||
        ![NSFileManager.defaultManager
            createDirectoryAtPath:esmPackagePath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil] ||
        ![NSFileManager.defaultManager
            createDirectoryAtPath:shellProjectPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil]) {
      fprintf(
          stderr, "[StaticInlineNodeIOSSystem] unable to create npm fixture\n");
      return 1;
    }
    char* resolvedShellProjectPath =
        realpath(shellProjectPath.fileSystemRepresentation, NULL);
    NSString* canonicalShellProjectPath = resolvedShellProjectPath != NULL
        ? [NSString stringWithUTF8String:resolvedShellProjectPath]
        : shellProjectPath;
    free(resolvedShellProjectPath);
    [@"console.log('script', process.argv.slice(2).join(','), process.cwd());\n"
       writeToFile:commonJSPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"await Promise.resolve(); console.log('esm ok');\n"
       writeToFile:modulePath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"export const value = 'module input';\n"
       writeToFile:evalModuleValuePath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"import { value } from './eval-value.mjs';\n"
      @"await Promise.resolve();\n"
      @"console.log('esm stdin', value);\n"
       writeToFile:moduleStdinPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"{\"name\":\"esm-package\",\"private\":true,\"type\":\"module\"}\n"
       writeToFile:[esmPackagePath stringByAppendingPathComponent:@"package.json"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"export const value = 'package type module';\n"
       writeToFile:[esmPackagePath stringByAppendingPathComponent:@"value.js"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"import { value } from './value.js';\n"
      @"await Promise.resolve();\n"
      @"console.log('esm project', value);\n"
       writeToFile:[esmPackagePath stringByAppendingPathComponent:@"main.js"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"process.stdout.write(`child ${process.argv[2]}`);\n"
       writeToFile:childPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"console.log('stdin ok');\n"
       writeToFile:stdinPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"const { spawn } = require('node:child_process');\n"
      @"const path = require('node:path');\n"
      @"const child = spawn(process.execPath, "
       "[path.join(__dirname, 'child.cjs'), 'ok'], "
       "{stdio: ['ignore', 'pipe', 'pipe']});\n"
      @"let output = '';\n"
      @"child.stdout.on('data', (chunk) => output += chunk);\n"
      @"child.stderr.pipe(process.stderr);\n"
      @"child.on('close', (code) => {\n"
      @"  console.log('virtual', code, output);\n"
      @"  process.exitCode = code;\n"
      @"});\n"
       writeToFile:parentPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"const { spawn } = require('node:child_process');\n"
      @"const child = spawn('npx', process.argv.slice(2), "
       "{stdio: ['ignore', 'pipe', 'pipe']});\n"
      @"child.stdout.pipe(process.stdout);\n"
      @"child.stderr.pipe(process.stderr);\n"
      @"child.on('error', (error) => {\n"
      @"  console.error(error);\n"
      @"  process.exitCode = 1;\n"
      @"});\n"
      @"child.on('close', (code, signal) => {\n"
      @"  if (code !== 0 || signal !== null) {\n"
      @"    console.error(`nested npx failed: code=${code} signal=${signal}`);\n"
      @"    process.exitCode = code || 1;\n"
      @"  }\n"
      @"});\n"
       writeToFile:nestedNPXPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"{\"name\":\"node-mobile-bin-probe\",\"version\":\"1.0.0\","
      @"\"main\":\"index.js\","
      @"\"bin\":{\"node-mobile-bin-probe\":\"cli.js\"}}\n"
       writeToFile:[fixturePackagePath stringByAppendingPathComponent:@"package.json"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"module.exports = 'ordinary node_modules resolution';\n"
       writeToFile:[fixturePackagePath stringByAppendingPathComponent:@"index.js"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"#!/usr/bin/env node\n"
      @"const arguments = process.argv.slice(2);\n"
      @"console.log('node mobile bin', arguments.join(','));\n"
      @"if (arguments.includes('hang')) setInterval(() => {}, 1000);\n"
       writeToFile:[fixturePackagePath stringByAppendingPathComponent:@"cli.js"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"{\"name\":\"node-mobile-npx-cache-probe\",\"version\":\"1.0.0\","
      @"\"bin\":{\"node-mobile-npx-cache-probe\":\"cli.js\"}}\n"
       writeToFile:[npxCachePackagePath
                       stringByAppendingPathComponent:@"package.json"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"#!/usr/bin/env node\n"
      @"const path = require('node:path');\n"
      @"console.log('node mobile npx cache', "
       "__dirname.includes(`${path.sep}_npx${path.sep}`), "
       "process.argv.slice(2).join(','));\n"
       writeToFile:[npxCachePackagePath stringByAppendingPathComponent:@"cli.js"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    [@"{\"name\":\"node-mobile-project\",\"version\":\"1.0.0\","
      @"\"private\":true,"
      @"\"scripts\":{\"probe\":\"node-mobile-bin-probe through-npm-run\","
      @"\"hang\":\"node-mobile-bin-probe hang\"}}\n"
       writeToFile:[project stringByAppendingPathComponent:@"package.json"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];

    if (StaticInlineNodeIOSSystemRunArguments(
            @[
              @"node",
              @"-e",
              @"console.log(JSON.stringify(process.argv.slice(1))); console.log('direct pwd cwd', process.env.PWD === process.cwd())",
              @"two words",
              @">",
              @"$HOME",
              @"~",
              @"*",
              @"",
            ],
            0,
            @[
              @"[\"two words\",\">\",\"$HOME\",\"~\",\"*\",\"\"]",
              @"direct pwd cwd true",
            ],
            @[],
            directory,
            0) != 0) {
      return 1;
    }
    if (StaticInlineNodeIOSSystemRunArguments(
            @[ @"cd", @"/app_bundle" ],
            0,
            @[ @"Warning: this directory is read-only.\n" ],
            @[],
            directory,
            1) != 0) {
      return 1;
    }
    if (StaticInlineNodeIOSSystemRunArguments(
            @[
              @"sleep",
              @"0.001s",
              @"0.0000166667m",
              @"0.0000002778h",
              @"0.0000000116d",
            ],
            0,
            @[],
            @[],
            directory,
            2) != 0) {
      return 1;
    }
    if (StaticInlineNodeIOSSystemRunArguments(
            @[ @"sleep", @"not-a-duration" ],
            1,
            @[],
            @[ @"invalid time interval" ],
            directory,
            3) != 0) {
      return 1;
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:project isDirectory:YES]);

    if (StaticInlineNodeIOSSystemTestBrokenPipe() != 0) return 1;

    NSArray<NSArray*>* commands = @[
      @[ @"which node", @0, @[ @"/usr/bin/node" ], @[] ],
      @[ @"which npm", @0, @[ @"/usr/bin/npm" ], @[] ],
      @[ @"which npx", @0, @[ @"/usr/bin/npx" ], @[] ],
      @[ @"node --version", @0, @[ @"v24.20.0" ], @[] ],
      @[ @"npm --version", @0, @[ @"11.19.0" ], @[] ],
      @[ @"npx --version", @0, @[ @"11.19.0" ], @[] ],
      @[
        @"node -e \"const path = require('node:path'); console.log('project cwd', path.basename(process.cwd()) === 'project'); console.log('workspace home', process.env.HOME === path.dirname(process.cwd()))\"",
        @0, @[ @"project cwd true", @"workspace home true" ], @[]
      ],
      @[
        @"cd ~ && node -e \"console.log('home cwd', process.env.HOME === process.cwd())\"",
        @0, @[ @"home cwd true" ], @[]
      ],
      @[
        @"cd \"$HOME/project\" && node -e \"console.log('home project cwd', process.cwd().endsWith('/project'))\"",
        @0, @[ @"home project cwd true" ], @[]
      ],
      @[
        @"cd \"$TMPDIR\" && node -e \"console.log('tmp cwd', process.env.TMPDIR === process.cwd())\"",
        @0, @[ @"tmp cwd true" ], @[]
      ],
      @[
        // OSH builtins use physical paths; direct argv alias handling is
        // covered by the cd /app_bundle invocation above.
        [NSString stringWithFormat:@"{ cd %@ && cat bundled-fixture.txt; }",
            StaticInlineNodeIOSSystemShellQuote(appBundle)],
        @0,
        @[
          @"bundled fixture",
        ],
        @[]
      ],
      @[ @"echo /home /tmp", @0, @[ @"/home /tmp" ], @[] ],
      @[
        @"npm install --ignore-scripts --no-audit --no-fund ./fixture-package",
        @0, @[ @"added 1 package" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:
                @"cd %@ && node -e \"require('node:fs').writeFileSync("
                @"'cwd.txt', process.cwd()); console.log('shell cwd', "
                @"process.cwd())\"",
                StaticInlineNodeIOSSystemShellQuote(shellProjectPath)],
        @0, @[ @"shell cwd", canonicalShellProjectPath ], @[]
      ],
      @[
        [NSString
            stringWithFormat:
                @"cd %@ && npx --yes=false node-mobile-bin-probe shell-cwd",
                StaticInlineNodeIOSSystemShellQuote(shellProjectPath)],
        @0, @[ @"node mobile bin shell-cwd" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:
                @"cd %@ && node -e \"console.error('combined output')\" "
                 @"> combined.log 2>&1 && cat combined.log",
                StaticInlineNodeIOSSystemShellQuote(shellProjectPath)],
        @0, @[ @"combined output" ], @[]
      ],
      @[
        @"node-mobile-bin-probe direct", @0,
        @[ @"node mobile bin direct" ], @[]
      ],
      @[
        @"node -e \"console.log('node module', require('node-mobile-bin-probe'))\"",
        @0, @[ @"node module ordinary node_modules resolution" ], @[]
      ],
      @[
        @"npx --yes=false node-mobile-bin-probe through-npx", @0,
        @[ @"node mobile bin through-npx" ], @[]
      ],
      @[
        @"node nested-npx.cjs --yes=false node-mobile-bin-probe nested-npx",
        @0, @[ @"node mobile bin nested-npx" ], @[]
      ],
      @[
        @"npm pack ./npx-cache-package --pack-destination .",
        @0, @[ @"node-mobile-npx-cache-probe-1.0.0.tgz" ], @[]
      ],
      @[
        @"node nested-npx.cjs --yes --package ./node-mobile-npx-cache-probe-1.0.0.tgz node-mobile-npx-cache-probe nested-cache",
        @0, @[ @"node mobile npx cache true nested-cache" ], @[]
      ],
      @[
        @"npm exec -- node-mobile-bin-probe through-npm-exec", @0,
        @[ @"node mobile bin through-npm-exec" ], @[]
      ],
      @[
        @"npm run probe", @0, @[ @"node mobile bin through-npm-run" ], @[]
      ],
      @[ @"node --help", @0, @[ @"Usage: node" ], @[] ],
      @[
        @"node -e \"const crypto = require('node:crypto'); console.log('node openssl', process.versions.openssl, crypto.createHash('sha256').update('node').digest('hex').length)\"",
        @0, @[ @"node openssl 3.5.7 64" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node -e %@ alpha beta",
                             StaticInlineNodeIOSSystemShellQuote(
                                 @"console.log('eval', "
                                  "process.argv.slice(1).join(','))")],
        @0, @[ @"eval alpha,beta" ], @[]
      ],
      @[ @"node -p \"6 * 7\"", @0, @[ @"42" ], @[] ],
      @[
        [NSString
            stringWithFormat:@"node --check %@",
                             StaticInlineNodeIOSSystemShellQuote(
                                 commonJSPath)],
        @0, @[], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node %@ left right",
                             StaticInlineNodeIOSSystemShellQuote(
                                 commonJSPath)],
        @0, @[ @"script left,right", project ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node %@",
                             StaticInlineNodeIOSSystemShellQuote(modulePath)],
        @0, @[ @"esm ok" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:
                @"node --input-type=module -e %@",
                StaticInlineNodeIOSSystemShellQuote(
                    @"import { value } from './eval-value.mjs'; "
                    @"await Promise.resolve(); "
                    @"console.log('esm eval', value);")],
        @0, @[ @"esm eval module input" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node --input-type=module - < %@",
                             StaticInlineNodeIOSSystemShellQuote(
                                 moduleStdinPath)],
        @0, @[ @"esm stdin module input" ], @[]
      ],
      @[
        @"node --input-type=commonjs -e \"console.log('input commonjs', typeof require)\"",
        @0, @[ @"input commonjs function" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node %@",
                             StaticInlineNodeIOSSystemShellQuote(
                                 [esmPackagePath
                                     stringByAppendingPathComponent:@"main.js"])],
        @0, @[ @"esm project package type module" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node %@",
                             StaticInlineNodeIOSSystemShellQuote(parentPath)],
        @0, @[ @"virtual 0 child ok" ], @[]
      ],
      @[
        [NSString
            stringWithFormat:@"node - < %@",
                             StaticInlineNodeIOSSystemShellQuote(stdinPath)],
        @0,
        @[ @"stdin ok" ], @[]
      ],
      @[
        @"node -e \"globalThis.__node_host_leak = true; console.log('marker set')\"",
        @0, @[ @"marker set" ], @[]
      ],
      @[
        @"node -e \"console.log('marker exists', '__node_host_leak' in globalThis)\"",
        @0, @[ @"marker exists false" ], @[]
      ],
      @[
        @"node -e \"process.env.NODE_IOS_SYSTEM_TEST = 'mutated'; process.env.NODE_IOS_SYSTEM_NUMBER = 7; console.log('env first', process.env.NODE_IOS_SYSTEM_TEST, typeof process.env.NODE_IOS_SYSTEM_NUMBER, process.env.hasOwnProperty('NODE_IOS_SYSTEM_NUMBER'), process.env instanceof Object)\"",
        @0, @[ @"env first mutated string true true" ], @[]
      ],
      @[
        @"node -e \"console.log('env reset', process.env.NODE_IOS_SYSTEM_TEST)\"",
        @0, @[ @"env reset session value" ], @[]
      ],
      @[
        @"node -e \"console.log('stdout before exit'); console.error('stderr before exit'); process.exit(7)\"",
        @7, @[ @"stdout before exit" ], @[ @"stderr before exit" ]
      ],
      @[
        @"node -e \"console.log('after exit')\"", @0,
        @[ @"after exit" ], @[]
      ],
      @[
        @"node -e \"throw new Error('expected failure')\"", @1, @[],
        @[ @"expected failure" ]
      ],
      @[
        @"node --definitely-unsupported --expose-gc -e \"console.log('ignored v8 flags', typeof gc)\"",
        @0, @[ @"ignored v8 flags undefined" ], @[]
      ],
      @[ @"echo pipeline | cat", @125, @[], @[] ],
    ];

    NSUInteger index = 0;
    for (NSArray* command in commands) {
      int status = StaticInlineNodeIOSSystemRunCommand(
          command[0], [command[1] intValue], command[2], command[3], directory,
          index++);
      if (status != 0) {
        return status;
      }
    }
    NSString* recordedWorkingDirectory = [NSString
        stringWithContentsOfFile:
            [shellProjectPath stringByAppendingPathComponent:@"cwd.txt"]
                     encoding:NSUTF8StringEncoding
                        error:nil];
    if (![recordedWorkingDirectory
            isEqualToString:canonicalShellProjectPath]) {
      fprintf(
          stderr,
          "[StaticInlineNodeIOSSystem] OSH did not preserve command cwd: %s\n",
          recordedWorkingDirectory.UTF8String ?: "(null)");
      return 1;
    }
    if (StaticInlineNodeIOSSystemTestSleepCancellation(project, preload) != 0) {
      return 1;
    }
    if (StaticInlineNodeIOSSystemTestCancellation(
            project, preload, directory, index++) != 0) {
      return 1;
    }
    static char npmCancellationSession[] =
        "StaticInlineNodeNPMCancellation";
    if (StaticInlineNodeIOSSystemTestNodeWrapperCancellation(
            npmCancellationSession,
            @"npm",
            @"npm run hang",
            @"node mobile bin hang",
            project,
            preload,
            directory,
            index++) != 0) {
      return 1;
    }
    static char npxCancellationSession[] =
        "StaticInlineNodeNPXCancellation";
    if (StaticInlineNodeIOSSystemTestNodeWrapperCancellation(
            npxCancellationSession,
            @"npx",
            @"npx --yes=false node-mobile-bin-probe hang",
            @"node mobile bin hang",
            project,
            preload,
            directory,
            index++) != 0) {
      return 1;
    }
    if (StaticInlineNodeIOSSystemTestQueuedCancellation(
            project, preload, directory) != 0) {
      return 1;
    }
    fprintf(stderr, "[StaticInlineNodeIOSSystem] suite passed\n");
    return 0;
  }
}
