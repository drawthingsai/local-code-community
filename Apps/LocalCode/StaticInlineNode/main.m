#import <TargetConditionals.h>

#include <stdio.h>
#include <stdlib.h>

#if TARGET_OS_IOS
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#else
#include <unistd.h>
#endif

#import "NodeMobile.h"

static int StaticInlineNodeRunSuite(void) {
  char executable[] = "node";
  char jitless[] = "--jitless";
  char wasmJitless[] = "--wasm-jitless";
  char evaluate[] = "-e";
  char script[] =
      "const assert = require('node:assert/strict');"
      "const crypto = require('node:crypto');"
      "const fs = require('node:fs');"
      "const http = require('node:http');"
      "const os = require('node:os');"
      "const path = require('node:path');"
      "const stream = require('node:stream');"
      "const zlib = require('node:zlib');"
      "const resultPath = process.env.STATIC_INLINE_NODE_RESULT;"
      "const mark = (stage) => fs.writeFileSync(resultPath, `${stage}\\n`);"
      "mark('javascript-started');"
      "assert.equal(process.versions.node, '24.22.1');"
#if TARGET_OS_IOS
      "assert.equal(process.platform, 'ios');"
#else
      "assert.equal(process.platform, 'darwin');"
#endif
      "assert.equal(process.arch, 'arm64');"
      "assert.equal(typeof WebAssembly, 'object');"
      "const wasmBytes = Uint8Array.from(["
      "  0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,"
      "  7,10,1,6,97,110,115,119,101,114,0,0,10,6,1,4,0,65,42,11"
      "]);"
      "const wasmModule = new WebAssembly.Module(wasmBytes);"
      "mark('wasm-module');"
      "const wasmInstance = new WebAssembly.Instance(wasmModule);"
      "mark('wasm-instance');"
      "assert.equal(wasmInstance.exports.answer(), 42);"
      "mark('wasm-answer');"
      "const multiExportModule = new WebAssembly.Module(Uint8Array.from(["
      "  0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,3,2,0,0,"
      "  7,18,2,5,102,105,114,115,116,0,0,6,115,101,99,111,110,100,0,1,"
      "  10,11,2,4,0,65,11,11,4,0,65,22,11"
      "]));"
      "const multiExportInstance = new WebAssembly.Instance(multiExportModule);"
      "assert.equal(multiExportInstance.exports.second(), 22);"
      "mark('wasm-nonzero-export');"
      "let callbackCalls = 0;"
      "const importedFirstModule = new WebAssembly.Module(Uint8Array.from(["
      "  0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,"
      "  2,16,1,3,101,110,118,8,99,97,108,108,98,97,99,107,0,0,"
      "  3,3,2,0,0,7,9,1,5,116,104,105,114,100,0,2,"
      "  10,11,2,4,0,65,55,11,4,0,16,1,11"
      "]));"
      "const importedFirstInstance = new WebAssembly.Instance(importedFirstModule, {"
      "  env: {callback: () => { callbackCalls += 1; return -1; }}"
      "});"
      "assert.equal(importedFirstInstance.exports.third(), 55);"
      "assert.equal(callbackCalls, 0);"
      "mark('wasm-nonzero-call');"
      "assert.equal(Buffer.from('local code').toString('hex'), '6c6f63616c20636f6465');"
      "assert.equal(crypto.createHash('sha256').update('node').digest('hex').length, 64);"
      "assert.equal(zlib.gunzipSync(zlib.gzipSync('node 24')).toString(), 'node 24');"
      "assert.equal(typeof stream.Readable.from, 'function');"
      "const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'local-code-node-'));"
      "const filename = path.join(directory, 'probe.json');"
      "fs.writeFileSync(filename, JSON.stringify({runtime: 'node'}));"
      "assert.deepEqual(JSON.parse(fs.readFileSync(filename, 'utf8')), {runtime: 'node'});"
      "const {DatabaseSync} = require('node:sqlite');"
      "const database = new DatabaseSync(':memory:');"
      "assert.equal(database.prepare('select 24 as value').get().value, 24);"
      "database.close();"
      "assert.equal(new Intl.NumberFormat('en-US').format(2418), '2,418');"
      "mark('sync-builtins');"
      "(async () => {"
      "  const url = await import('node:url');"
      "  assert.equal(url.pathToFileURL('/tmp').protocol, 'file:');"
      "  const server = http.createServer((request, response) => response.end('node 24'));"
      "  await new Promise((resolve, reject) => {"
      "    server.once('error', reject);"
      "    server.listen(0, '127.0.0.1', resolve);"
      "  });"
      "  const endpoint = `http://127.0.0.1:${server.address().port}/`;"
      "  const responseBody = await new Promise((resolve, reject) => {"
      "    http.get(endpoint, (response) => {"
      "      let body = '';"
      "      response.setEncoding('utf8');"
      "      response.on('data', (chunk) => body += chunk);"
      "      response.on('end', () => resolve(body));"
      "    }).on('error', reject);"
      "  });"
      "  assert.equal(responseBody, 'node 24');"
      "  mark('http-response');"
      "  const response = await fetch(endpoint);"
      "  mark('fetch-response');"
      "  const fetchStatus = `available:${await response.text()}`;"
      "  assert.equal(fetchStatus, 'available:node 24');"
      "  mark('fetch-body');"
      "  await new Promise((resolve) => server.close(resolve));"
      "  fs.rmSync(directory, {recursive: true, force: true});"
      "  console.log('[StaticInlineNode] runtime', JSON.stringify({"
      "    node: process.versions.node,"
      "    platform: process.platform,"
      "    arch: process.arch,"
      "    intl: process.versions.icu,"
      "    wasm: typeof WebAssembly,"
      "    fetch: fetchStatus"
      "  }));"
      "})().catch((error) => {"
      "  console.error(error);"
      "  process.exitCode = 1;"
      "});";
  char* arguments[] = {executable, jitless, wasmJitless, evaluate, script};
  return node_start(5, arguments);
}

static int StaticInlineNodeRunCommand(int argc, char* argv[]) {
  char executable[] = "node";
  char jitless[] = "--jitless";
  char wasmJitless[] = "--wasm-jitless";
  char require[] = "--require";
  const char* preloadPath = getenv("NODE_MOBILE_VIRTUAL_NODE_PRELOAD");
  int preloadArgumentCount =
      preloadPath != NULL && preloadPath[0] != '\0' ? 2 : 0;
  int nodeArgumentCount = argc + 2 + preloadArgumentCount;
  char** nodeArguments =
      (char**)calloc((size_t)nodeArgumentCount, sizeof(char*));
  if (nodeArguments == NULL) {
    perror("calloc");
    return 1;
  }
  nodeArguments[0] = executable;
  nodeArguments[1] = jitless;
  nodeArguments[2] = wasmJitless;
  int argumentOffset = 3;
  if (preloadArgumentCount != 0) {
    nodeArguments[argumentOffset++] = require;
    nodeArguments[argumentOffset++] = (char*)preloadPath;
  }
  for (int i = 1; i < argc; ++i) {
    nodeArguments[argumentOffset + i - 1] = argv[i];
  }
  int status = node_start(nodeArgumentCount, nodeArguments);
  free(nodeArguments);
  return status;
}

#if TARGET_OS_IOS

static void StaticInlineNodeConfigureVirtualChildren(NSURL* documentsURL) {
  NSURL* preloadURL = [NSBundle.mainBundle
      URLForResource:@"virtual-node-child-preload"
        withExtension:@"cjs"
         subdirectory:@"NodeMobile/Runtime"];
  if (preloadURL != nil) {
    setenv(
        "NODE_MOBILE_VIRTUAL_NODE_PRELOAD",
        preloadURL.fileSystemRepresentation,
        1);
  }
  if (getenv("NODE_MOBILE_VIRTUAL_NODE_ROOTS") == NULL) {
    NSString* roots = [NSString
        stringWithFormat:@"%@:%@", NSBundle.mainBundle.bundleURL.path,
                         documentsURL.path];
    setenv("NODE_MOBILE_VIRTUAL_NODE_ROOTS", roots.UTF8String, 1);
  }
}

@interface StaticInlineNodeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation StaticInlineNodeAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  self.window.rootViewController.view.backgroundColor =
      UIColor.systemBackgroundColor;
  [self.window makeKeyAndVisible];

  dispatch_async(
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL* documentsURL =
            [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                 inDomains:NSUserDomainMask]
                .firstObject;
        NSURL* resultURL =
            [documentsURL URLByAppendingPathComponent:@"result.txt"];
        [@"started\n" writeToURL:resultURL
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
        NSURL* logURL =
            [documentsURL URLByAppendingPathComponent:@"runtime.log"];
        freopen(logURL.fileSystemRepresentation, "w", stdout);
        freopen(logURL.fileSystemRepresentation, "a", stderr);
        setenv(
            "STATIC_INLINE_NODE_RESULT",
            resultURL.fileSystemRepresentation,
            1);

        StaticInlineNodeConfigureVirtualChildren(documentsURL);

        int status;
        const char* scriptPath = getenv("STATIC_INLINE_NODE_SCRIPT");
        BOOL isExternalCommand = scriptPath != NULL && scriptPath[0] != '\0';
        if (isExternalCommand) {
          char executable[] = "StaticInlineNode";
          char* arguments[] = {executable, (char*)scriptPath};
          status = StaticInlineNodeRunCommand(2, arguments);
        } else {
          status = StaticInlineNodeRunSuite();
        }
        NSString* result =
            [NSString stringWithFormat:@"status=%d\n", status];
        [result writeToURL:resultURL
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:nil];
        fprintf(
            stderr, "\n[StaticInlineNode] %s %s (status=%d)\n",
            isExternalCommand ? "command" : "suite",
            status == 0 ? "passed" : "failed", status);
        fflush(stdout);
        fflush(stderr);
        exit(status == 0 ? 0 : 1);
      });
  return YES;
}

@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    if (argc > 1) {
      NSURL* documentsURL =
          [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                               inDomains:NSUserDomainMask]
              .firstObject;
      StaticInlineNodeConfigureVirtualChildren(documentsURL);
      return StaticInlineNodeRunCommand(argc, argv);
    }
    return UIApplicationMain(
        argc, argv, nil, NSStringFromClass(StaticInlineNodeAppDelegate.class));
  }
}

#else

int main(int argc, char* argv[]) {
  if (argc > 1) {
    return StaticInlineNodeRunCommand(argc, argv);
  }

  char resultPath[] = "/tmp/static-inline-node-result.XXXXXX";
  int resultDescriptor = mkstemp(resultPath);
  if (resultDescriptor == -1) {
    perror("mkstemp");
    return 1;
  }
  close(resultDescriptor);
  setenv("STATIC_INLINE_NODE_RESULT", resultPath, 1);

  int status = StaticInlineNodeRunSuite();
  unlink(resultPath);
  fprintf(
      stderr, "\n[StaticInlineNode] suite %s (status=%d)\n",
      status == 0 ? "passed" : "failed", status);
  return status;
}

#endif
