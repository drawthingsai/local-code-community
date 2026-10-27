//
//  ios_system.h
//  ios_system
//
//  Created by Nicolas Holzschuch on 04/12/2017.
//  Copyright © 2017 Nicolas Holzschuch. All rights reserved.
//

#import <Foundation/Foundation.h>

#include "ios_system_command.h"
#include "ios_system_isolation.h"

//! Project version number for ios_system.
FOUNDATION_EXPORT double ios_systemVersionNumber;

//! Project version string for ios_system.
FOUNDATION_EXPORT const unsigned char ios_systemVersionString[];

// Thread-local input and output streams
extern __thread FILE* thread_stdin;
extern __thread FILE* thread_stdout;
extern __thread FILE* thread_stderr;
extern __thread void* thread_context;

// rust doesn't support extern __thread vars yet
// see https://github.com/rust-lang/rust/issues/30795
// so we provide function accessors for them.
extern FILE* ios_stdin(void);
extern FILE* ios_stdout(void);
extern FILE* ios_stderr(void);
extern void* ios_context(void);

// set to true to have more commands available, more debugging information.
extern bool sideLoading;
// set to false to have the main thread run in detached mode (non blocking)
extern bool joinMainThread;

extern int ios_executable(const char* inputCmd); // does this command exist? (executable file or builtin command)
// Execute one command from an already-tokenized argument vector. ios_system
// deep-copies argv before invoking commands because several embedded tools
// mutate their arguments.
extern int ios_system(int argc, const char* const argv[]);
// Execute a command string with the no-process OSH runtime used by Local Code.
extern int ios_system_osh(const char* inputCmd);
extern FILE *ios_popen(const char *command, const char *type); // Execute this command and pipe the result
extern int ios_pclose(FILE *stream); // close a stream ios_popen returned and wait for its commands
extern int ios_kill(void); // kill the current running command
extern int ios_killpid(pid_t pid, int sig); // kill the current running command
extern int chdir(const char* path);

extern int ios_isatty(int fd); // test whether a file descriptor refers to a terminal
extern pthread_t ios_getLastThreadId(void);
extern pthread_t ios_getThreadId(pid_t pid);
extern void ios_storeThreadId(pthread_t thread);
extern void ios_releaseThread(pthread_t thread);
extern void ios_releaseThreadId(pid_t pid);
extern pid_t ios_currentPid(void);
extern void ios_setCurrentPid(pid_t pid);
extern int ios_getCommandStatus(void);
extern const char* ios_progname(void);
extern char * ios_getenv(const char *name);
extern int ios_resolveDirectoryAlias(const char *path, char *destination, size_t size);
extern int ios_setenv(const char* variableName, const char* value, int overwrite);
int ios_unsetenv(const char* variableName);
extern char** environmentVariables(pid_t pid);
extern NSArray* environmentAsArray(void);
extern void storeEnvironment(char* envp[]);
extern pid_t ios_fork(void);
extern void ios_waitpid(pid_t pid);
extern pid_t ios_full_waitpid(pid_t pid, int *stat_loc, int options);
extern NSString *ios_getLogicalPWD(const void* sessionId);
void ios_setWindowSize(int width, int height, const void* sessionId);

extern NSString* commandsAsString(void);
extern NSArray* commandsAsArray(void);      // set of all commands, in an NSArray
extern NSArray* aliasesAsArray(void);       // set of all aliases defined, in an NSArray
extern NSString* aliasedCommand(NSString* command); // if the command is aliased, return the command it points to
// Completion metadata. Runtime registrations default to no options and no file operand.
extern NSString* getoptString(NSString* command);
extern NSString* operatesOn(NSString* command);
extern void initializeEnvironment(void);
// workspaceURL supplies HOME. projectURL supplies the initial working directory
// and project-local Node/Python package paths.
// appBundleURL supplies the read-only /app_bundle directory alias.
extern int ios_setSystemPaths(
    NSURL *documentsURL,
    NSURL *libraryURL,
    NSURL *cachesURL,
    NSURL *workspaceURL,
    NSURL *projectURL,
    NSURL *appBundleURL);
// Optional host resource path, configured before office commands are started.
extern int ios_setOfficeProgramPath(NSString *path);
extern NSString *ios_officeProgramPath(void);
extern int ios_setNodeCommandPaths(NSString *npmPath, NSString *npxPath);
extern int ios_setMiniRoot(NSString*);  // restricts operations to a certain hierarchy
extern int ios_setMiniRootURL(NSURL*);  // restricts operations to a certain hierarchy
extern int ios_setAllowedPaths(NSArray<NSString *> *paths);  // restricts operations to a certain hierarchy
extern void ios_setBookmarkDictionaryName(NSString*);  // name of the dictionary in user preferences, holding the bookmarks.
extern void ios_switchSession(const void* sessionid);
// Switches to a session that runs one job until ios_closeSession: a
// cancellation requested at any point, even before its first command starts,
// cancels every command it then starts. A session that runs more commands
// after a cancellation, such as a terminal, uses ios_switchSession instead.
extern void ios_openSession(const void* sessionid);
extern void ios_closeSession(const void* sessionid);
extern void ios_setStreams(FILE* _stdin, FILE* _stdout, FILE* _stderr);
extern void ios_settty(FILE* _tty);
extern int ios_getstdin(void);
extern int ios_getstdout(void);
extern int ios_getstderr(void);
extern int ios_gettty(void);
extern int ios_activePager(void);
extern void ios_setContext(const void *context);
extern const void* ios_getContext(void);
// Only this thread-dictionary entry is inherited by command pthreads.
// The host owns the object's type; it is unrelated to the session-name context.
extern NSString * const ios_commandContextKey;
extern void ios_setDirectoryURL(NSURL* workingDirectoryURL);
extern void newPreviousDirectory(void);
extern void makeGlobal(void);
extern void makeLocal(void);
extern NSError* addCommandList(NSString* fileLocation);
extern NSArray* backgroundCommandList;
extern int numPythonInterpreters;
extern int numPerlInterpreters;
extern int numTeXInterpreters;
extern int cd_main(int argc, char** argv);
extern const char* ios_getBookmarkedVersion(const char* p);
extern void ios_stopInteractive(void);
extern void finishedPreparingWebAssemblyCommand(void);
extern int webAssemblyCommandOrder(void);
