#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <stdio.h>
#include <stdlib.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

#import "Vendors/Lean/LeanBridge.h"
#import "Vendors/Lean/LeanResources-Swift.h"

static LeanRuntimeResources *runtimeResources;

static int StaticInlineLeanPrepareResources(void) {
  NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
  if ([environment[@"STATIC_INLINE_LEAN_BASE_ROOT"] length] > 0) {
    return 0;
  }
  NSString *archivePath = environment[@"STATIC_INLINE_LEAN_ARCHIVE"]
      ?: [NSBundle.mainBundle pathForResource:@"Lean_Init_Std" ofType:@"zip"];
  if (archivePath.length == 0) {
    fprintf(stderr, "[StaticInlineLean] missing bundled Lean archive\n");
    return 1;
  }
  NSURL *archiveURL = [NSURL fileURLWithPath:archivePath];
  NSURL *manifestURL = [[archiveURL URLByDeletingLastPathComponent]
      URLByAppendingPathComponent:@"Lean_Init_Std.json"];
  NSString *cachePath = environment[@"STATIC_INLINE_LEAN_CACHE"];
  NSURL *cacheURL = cachePath.length > 0 ? [NSURL fileURLWithPath:cachePath isDirectory:YES]
      : [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                             inDomains:NSUserDomainMask].firstObject
          URLByAppendingPathComponent:@"Lean" isDirectory:YES];
  NSError *error = nil;
  runtimeResources = [[LeanRuntimeResources alloc] initWithArchiveURL:archiveURL
      manifestURL:manifestURL cacheURL:cacheURL error:&error];
  if (runtimeResources == nil) {
    fprintf(stderr, "[StaticInlineLean] %s\n", error.localizedDescription.UTF8String);
    return 1;
  }
  fprintf(stdout, "[StaticInlineLean] archive: %ld modules; cache: %s\n",
      (long)runtimeResources.archiveModuleCount, runtimeResources.cacheRoot.path.UTF8String);
  return 0;
}

static int StaticInlineLeanCheck(
    NSString *name, NSString *source, NSString *baseRoot,
    NSString *packageRoot, NSString *expectedStatus, NSArray<NSString *> *expectedLines) {
  NSString *result;
  if (runtimeResources != nil) {
    result = [runtimeResources checkWithSource:source packageRoot:packageRoot];
    fprintf(stdout, "[StaticInlineLean] %s: required=%ld extracted=%ld bytes=%llu\n",
        name.UTF8String, (long)runtimeResources.requestedModuleCount,
        (long)runtimeResources.extractedModuleCount,
        (unsigned long long)runtimeResources.extractedByteCount);
  } else {
    char *output = lean_bridge_check(
        source.UTF8String, baseRoot.fileSystemRepresentation,
        packageRoot != nil ? packageRoot.fileSystemRepresentation : "", NULL);
    if (output == NULL) {
      fprintf(stderr, "[StaticInlineLean] %s returned no result\n", name.UTF8String);
      return 1;
    }
    result = [NSString stringWithUTF8String:output] ?: @"";
    lean_bridge_free(output);
  }
  fprintf(stdout, "\n[StaticInlineLean] %s\n%s\n", name.UTF8String, result.UTF8String);
  NSArray<NSString *> *lines = [result componentsSeparatedByString:@"\n"];
  NSString *status = nil;
  for (NSString *line in lines.reverseObjectEnumerator) {
    if ([line hasPrefix:@"status: "]) {
      status = line;
      break;
    }
  }
  NSString *expected = expectedStatus != nil
      ? [NSString stringWithFormat:@"status: %@", expectedStatus] : nil;
  BOOL matches = expected != nil ? [status isEqualToString:expected]
      : ([status isEqualToString:@"status: valid"] ||
         [status isEqualToString:@"status: conditional"]);
  if (!matches) {
    fprintf(
        stderr, "[StaticInlineLean] %s expected %s\n", name.UTF8String,
        expected != nil ? expected.UTF8String : "valid or conditional");
    return 1;
  }
  for (NSString *line in expectedLines) {
    NSUInteger count = 0;
    for (NSString *actual in lines) {
      if ([actual isEqualToString:line]) {
        ++count;
      }
    }
    if (count != 1) {
      fprintf(stderr, "[StaticInlineLean] %s expected exactly one line: %s\n",
              name.UTF8String, line.UTF8String);
      return 1;
    }
  }
  return 0;
}

static int StaticInlineLeanRunSuite(void) {
  NSString *baseRoot = NSProcessInfo.processInfo.environment[@"STATIC_INLINE_LEAN_BASE_ROOT"];
  if (baseRoot.length == 0) {
    baseRoot = NSBundle.mainBundle.resourcePath;
  }
  if (runtimeResources == nil &&
      ![NSFileManager.defaultManager fileExistsAtPath:[baseRoot stringByAppendingPathComponent:@"Init.olean"]]) {
    fprintf(stderr, "[StaticInlineLean] missing Lean artifacts under %s\n", baseRoot.UTF8String);
    return 1;
  }

  int status = 0;
  if (runtimeResources != nil) {
    NSString *minimal = @"/- import Lake /- import Lean -/ -/\n"
        "module\nprelude\npublic import Init.Prelude\n"
        "public theorem minimal : True := True.intro\n";
    status |= StaticInlineLeanCheck(@"minimal-import", minimal, baseRoot, nil, @"valid", nil);
    if (runtimeResources.requestedModuleCount != 1) {
      fprintf(stderr, "[StaticInlineLean] minimal import did not stay focused\n");
      status = 1;
    }
    status |= StaticInlineLeanCheck(@"warm-minimal-import", minimal, baseRoot, nil, @"valid", nil);
    if (runtimeResources.extractedModuleCount != 0) {
      fprintf(stderr, "[StaticInlineLean] warm import extracted files again\n");
      status = 1;
    }
    status |= StaticInlineLeanCheck(@"implicit-init",
        @"theorem implicit_init : True := True.intro\n", baseRoot, nil, @"valid", nil);
  }
  status |= StaticInlineLeanCheck(
      @"valid-structural-proof",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public import Std.Data\n"
       "public theorem reverse_reverse (xs : List Nat) : "
       "List.reverse (List.reverse xs) = xs := by\n"
       "  simpa using List.reverse_reverse xs\n",
      baseRoot, nil, @"valid", nil);

  if (runtimeResources != nil) {
    status |= StaticInlineLeanCheck(
        @"later-import-expansion",
        @"module\nprelude\npublic import Lean.Parser\n"
         "public theorem later : True := True.intro\n",
        baseRoot, nil, @"valid", nil);
  }
  status |= StaticInlineLeanCheck(
      @"invalid-proof",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public import Std.Data\n"
       "public theorem bad : 1 = 2 := by\n"
       "  rfl\n",
      baseRoot, nil, @"invalid", nil);
  status |= StaticInlineLeanCheck(
      @"conditional-proof",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public import Std.Data\n"
       "public axiom bad : False\n"
       "public theorem impossible : 1 = 2 := by\n"
       "  exact False.elim bad\n",
      baseRoot, nil, @"conditional", @[@"assumptions:", @"  bad"]);
  status |= StaticInlineLeanCheck(
      @"transitive-assumptions",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public axiom hypothesis : ∀ n : Nat, n = 0\n"
       "public theorem intermediate : (1 : Nat) = 0 := hypothesis 1\n"
       "public theorem conclusion : (1 : Nat) = 0 := intermediate\n",
      baseRoot, nil, @"conditional", @[@"assumptions:", @"  hypothesis"]);
  status |= StaticInlineLeanCheck(
      @"explicit-parameters",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public theorem implication (P Q : Prop) (h : P → Q) (p : P) : Q := h p\n",
      baseRoot, nil, @"valid", nil);
  status |= StaticInlineLeanCheck(
      @"proof-hole",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public theorem unfinished : False := by sorry\n"
       "public theorem downstream : False := unfinished\n",
      baseRoot, nil, @"invalid", @[@"policy: unsupported proof axiom: sorryAx"]);
  status |= StaticInlineLeanCheck(
      @"mixed-assumptions-and-proof-hole",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public axiom hypothesis : True\n"
       "public theorem unfinished : False := by sorry\n",
      baseRoot, nil, @"invalid",
      @[@"policy: unsupported proof axiom: sorryAx", @"assumptions:", @"  hypothesis"]);
  status |= StaticInlineLeanCheck(
      @"compiler-proof-shortcut",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "set_option linter.deprecated false\n"
       "public def shortcut := @Lean.ofReduceBool\n",
      baseRoot, nil, @"invalid", @[@"policy: unsupported proof axiom: Lean.ofReduceBool"]);
  status |= StaticInlineLeanCheck(
      @"fresh-environment",
      @"module\n"
       "prelude\n"
       "public import Init\n"
       "public import Std.Data\n"
       "public theorem second_run (n : Nat) : n ≤ n + 2 := by\n"
       "  omega\n"
       "public theorem big_natural : "
       "(18446744073709551616 : Nat) + 1 = 18446744073709551617 := by\n"
       "  omega\n",
      baseRoot, nil, @"valid", nil);

  NSString *packageRoot = NSProcessInfo.processInfo.environment[@"STATIC_INLINE_LEAN_PACKAGE_ROOT"];
#if TARGET_OS_IOS
  if (packageRoot.length == 0) {
    NSURL *documentsURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                                inDomains:NSUserDomainMask].firstObject;
    packageRoot = [documentsURL.path stringByAppendingPathComponent:
        @".localc/lean/packages/mathlib/4.34.0/lib/lean"];
  }
#endif
  BOOL isDirectory = NO;
  if (packageRoot.length > 0 &&
      [NSFileManager.defaultManager fileExistsAtPath:packageRoot isDirectory:&isDirectory] &&
      isDirectory) {
    status |= StaticInlineLeanCheck(
        @"project-local-mathlib",
        @"module\n"
         "prelude\n"
         "public import Init\n"
         "public import Mathlib\n"
         "public theorem square (x : ℚ) : "
         "(x + 1) ^ 2 = x ^ 2 + 2 * x + 1 := by\n"
         "  ring\n",
        baseRoot, packageRoot, @"valid", nil);
  } else {
    fprintf(stdout, "[StaticInlineLean] project-local Mathlib package not installed; skipping\n");
  }
  return status == 0 ? 0 : 1;
}

#if TARGET_OS_IOS

@interface StaticInlineLeanAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation StaticInlineLeanAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  self.window.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
  [self.window makeKeyAndVisible];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSURL *documentsURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                                inDomains:NSUserDomainMask].firstObject;
    NSURL *logURL = [documentsURL URLByAppendingPathComponent:@"runtime.log"];
    freopen(logURL.fileSystemRepresentation, "w", stdout);
    freopen(logURL.fileSystemRepresentation, "a", stderr);
    int status = StaticInlineLeanPrepareResources();
    if (status == 0) status = StaticInlineLeanRunSuite();
    NSString *result = [NSString stringWithFormat:@"status=%d\n", status];
    [result writeToURL:[documentsURL URLByAppendingPathComponent:@"result.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    fprintf(stderr, "\n[StaticInlineLean] suite %s\n", status == 0 ? "passed" : "failed");
    fflush(stdout);
    fflush(stderr);
    exit(status);
  });
  return YES;
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(StaticInlineLeanAppDelegate.class));
  }
}

#else

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (StaticInlineLeanPrepareResources() != 0) return 1;
    if (argc == 2) {
      NSString *sourcePath = [NSString stringWithUTF8String:argv[1]];
      NSError *error = nil;
      NSString *source = [NSString stringWithContentsOfFile:sourcePath
                                                    encoding:NSUTF8StringEncoding
                                                       error:&error];
      if (source == nil) {
        fprintf(stderr, "[StaticInlineLean] failed to read %s: %s\n",
                sourcePath.UTF8String, error.localizedDescription.UTF8String);
        return 1;
      }
      NSDictionary<NSString *, NSString *> *environment =
          NSProcessInfo.processInfo.environment;
      NSString *baseRoot = environment[@"STATIC_INLINE_LEAN_BASE_ROOT"];
      NSString *packageRoot = environment[@"STATIC_INLINE_LEAN_PACKAGE_ROOT"];
      return StaticInlineLeanCheck(sourcePath.lastPathComponent, source, baseRoot,
                                   packageRoot, nil, nil);
    }
    int status = StaticInlineLeanRunSuite();
    fprintf(stderr, "\n[StaticInlineLean] suite %s\n", status == 0 ? "passed" : "failed");
    return status;
  }
}

#endif
