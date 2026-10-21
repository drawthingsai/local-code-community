#import <Foundation/Foundation.h>
#include <git2.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int ios_git_lfs_register(void);
extern int ios_git_lfs_push(git_repository *, const char *, const git_strarray *);
extern int lg2_lfs(git_repository *, int, char **);

// The small native harness deliberately avoids loading Python/Node/GPU runtimes.
bool have_openssl(void) { return false; }
FILE *ios_stdout(void) { return stdout; }
char *ios_getenv(const char *name) { return getenv(name); }
const void *ios_getCommandCancellationContext(void) { return NULL; }
int ios_commandCancellationRequested(const void *context) { return getenv("LFS_TEST_CANCELLED") != NULL; }
int lg2_main(int argc, char **argv) { return lg2_lfs(NULL, argc - 1, argv + 1); }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3 || chdir(argv[1]) != 0) return 2;
        git_libgit2_init();
        int result = ios_git_lfs_register();
        git_repository *repo = NULL;
        if (result == 0) result = git_repository_open_ext(&repo, ".", 0, NULL);
        if (result == 0 && !strcmp(argv[2], "clone") && argc == 5) {
            git_repository *clone = NULL;
            result = git_clone(&clone, argv[3], argv[4], NULL);
            git_repository_free(clone);
        } else if (result == 0 && !strcmp(argv[2], "add")) {
            git_index *index = NULL;
            result = git_repository_index(&index, repo);
            for (int i = 3; result == 0 && i < argc; i++) result = git_index_add_bypath(index, argv[i]);
            if (result == 0) result = git_index_write(index);
            git_index_free(index);
        } else if (result == 0 && !strcmp(argv[2], "checkout-head")) {
            git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
            options.checkout_strategy = GIT_CHECKOUT_FORCE;
            result = git_checkout_head(repo, &options);
        } else if (result == 0 && !strcmp(argv[2], "status")) {
            git_status_list *list = NULL;
            git_status_options options = GIT_STATUS_OPTIONS_INIT;
            result = git_status_list_new(&list, repo, &options);
            if (result == 0) printf("%zu\n", git_status_list_entrycount(list));
            git_status_list_free(list);
        } else if (result == 0 && !strcmp(argv[2], "push")) {
            char *ref = "HEAD";
            git_strarray refs = {&ref, 1};
            result = ios_git_lfs_push(repo, "origin", &refs);
        } else if (result == 0) {
            result = lg2_lfs(repo, argc - 2, argv + 2);
        }
        if (result != 0) {
            const git_error *error = git_error_last();
            fprintf(stderr, "%s\n", error ? error->message : "Git LFS validation command failed");
        }
        git_repository_free(repo);
        git_libgit2_shutdown();
        return result == 0 ? 0 : 1;
    }
}
