#include "common.h"
#include <errno.h>
#include <limits.h>

typedef struct progress_data {
	git_indexer_progress fetch_progress;
	size_t completed_steps;
	size_t total_steps;
	const char *path;
} progress_data;

static void print_progress(const progress_data *pd)
{
	int network_percent = pd->fetch_progress.total_objects > 0 ?
		(100*pd->fetch_progress.received_objects) / pd->fetch_progress.total_objects :
		0;
	int index_percent = pd->fetch_progress.total_objects > 0 ?
		(100*pd->fetch_progress.indexed_objects) / pd->fetch_progress.total_objects :
		0;

	int checkout_percent = pd->total_steps > 0
		? (int)((100 * pd->completed_steps) / pd->total_steps)
		: 0;
	size_t kbytes = pd->fetch_progress.received_bytes / 1024;

	if (pd->fetch_progress.total_objects &&
		pd->fetch_progress.received_objects == pd->fetch_progress.total_objects) {
		printf("Resolving deltas %u/%u\r",
		       pd->fetch_progress.indexed_deltas,
		       pd->fetch_progress.total_deltas);
	} else {
		printf("net %3d%% (%4" PRIuZ " kb, %5u/%5u)  /  idx %3d%% (%5u/%5u)  /  chk %3d%% (%4" PRIuZ "/%4" PRIuZ")%s\r",
		   network_percent, kbytes,
		   pd->fetch_progress.received_objects, pd->fetch_progress.total_objects,
		   index_percent, pd->fetch_progress.indexed_objects, pd->fetch_progress.total_objects,
		   checkout_percent,
		   pd->completed_steps, pd->total_steps,
		   pd->path ? pd->path : "");
	}
}

static int clone_usage(const char *prog)
{
	fprintf(stderr, "USAGE: %s [options] <url> [path]\n", prog);
	fprintf(stderr, "supported options: --depth, --branch/-b, --bare, --no-checkout/-n, --origin/-o, --tags, --no-tags\n");
	return 1;
}

static int take_value_option(
	const char **out,
	struct args_info *args,
	const char *long_opt,
	const char *short_opt)
{
	const char *arg = ARGS_CURRENT(args);

	if (long_opt) {
		size_t len = strlen(long_opt);

		if (!strncmp(arg, long_opt, len) && (arg[len] == '\0' || arg[len] == '=')) {
			if (arg[len] == '=') {
				*out = arg + len + 1;
				args->pos++;
				return 1;
			}

			if (args->pos + 1 == args->argc) {
				fprintf(stderr, "lg2 clone: expected value after %s\n", arg);
				return -1;
			}

			*out = args->argv[args->pos + 1];
			args->pos += 2;
			return 1;
		}
	}

	if (short_opt) {
		size_t len = strlen(short_opt);

		if (!strncmp(arg, short_opt, len) && arg[0] == '-' && arg[1] != '-') {
			if (arg[len] != '\0') {
				*out = arg + len;
				args->pos++;
				return 1;
			}

			if (args->pos + 1 == args->argc) {
				fprintf(stderr, "lg2 clone: expected value after %s\n", arg);
				return -1;
			}

			*out = args->argv[args->pos + 1];
			args->pos += 2;
			return 1;
		}
	}

	return 0;
}

static int take_int_option(
	int *out,
	struct args_info *args,
	const char *long_opt,
	const char *short_opt,
	int allow_negative)
{
	const char *value = NULL;
	char *endptr = NULL;
	long parsed;
	int matched = take_value_option(&value, args, long_opt, short_opt);

	if (matched <= 0)
		return matched;

	errno = 0;
	parsed = strtol(value, &endptr, 10);
	if (errno == ERANGE || !endptr || *endptr != '\0' ||
	    (!allow_negative && parsed < 0) || parsed > INT_MAX || parsed < INT_MIN) {
		fprintf(stderr, "lg2 clone: expected numeric value after %s\n", long_opt ? long_opt : short_opt);
		return -1;
	}

	*out = (int)parsed;
	return 1;
}

static int take_flag_option(struct args_info *args, const char *opt)
{
	if (strcmp(ARGS_CURRENT(args), opt))
		return 0;

	args->pos++;
	return 1;
}

static int take_optional_value_option(struct args_info *args, const char *opt)
{
	const char *arg = ARGS_CURRENT(args);
	size_t len = strlen(opt);

	if (strncmp(arg, opt, len) || (arg[len] != '\0' && arg[len] != '='))
		return 0;

	args->pos++;
	return 1;
}

static void warn_ignored_option(const char *opt)
{
	fprintf(stderr, "lg2 clone: ignoring unsupported option: %s\n", opt);
}

static int unsupported_option(const char *opt)
{
	fprintf(stderr, "lg2 clone: unsupported option: %s\n", opt);
	return 1;
}

static int create_remote_with_name(
	git_remote **out,
	git_repository *repo,
	const char *name,
	const char *url,
	void *payload)
{
	const char *remote_name = payload ? (const char *)payload : name;
	return git_remote_create(out, repo, remote_name, url);
}

static int derive_default_path(char **out, const char *url, int bare)
{
	const char *end = url + strlen(url);
	const char *start;
	size_t len;
	int append_dot_git = 0;

	while (end > url && (end[-1] == '/' || end[-1] == '\\'))
		end--;

	start = end;
	while (start > url && start[-1] != '/' && start[-1] != '\\' && start[-1] != ':')
		start--;

	len = (size_t)(end - start);

	if (len > 4 && !memcmp(start + len - 4, ".git", 4)) {
		if (!bare)
			len -= 4;
	} else if (bare) {
		append_dot_git = 1;
	}

	if (!len) {
		fprintf(stderr, "lg2 clone: could not derive local path from url: %s\n", url);
		return -1;
	}

	*out = malloc(len + (append_dot_git ? 4 : 0) + 1);
	if (!*out) {
		fprintf(stderr, "lg2 clone: could not allocate clone path\n");
		return -1;
	}

	memcpy(*out, start, len);
	if (append_dot_git)
		memcpy(*out + len, ".git", 4);
	(*out)[len + (append_dot_git ? 4 : 0)] = '\0';

	return 0;
}

static int sideband_progress(const char *str, int len, void *payload)
{
	(void)payload; /* unused */

	printf("remote: %.*s", len, str);
#if TARGET_OS_IPHONE
	fflush(thread_stdout);
#endif
	return 0;
}

static int fetch_progress(const git_indexer_progress *stats, void *payload)
{
	progress_data *pd = (progress_data*)payload;
	pd->fetch_progress = *stats;
	print_progress(pd);
	return 0;
}

static void checkout_progress(const char *path, size_t cur, size_t tot, void *payload)
{
	progress_data *pd = (progress_data*)payload;
	pd->completed_steps = cur;
	pd->total_steps = tot;
	pd->path = path;
	print_progress(pd);
}

int lg2_clone(git_repository *repo, int argc, char **argv)
{
	progress_data pd = {{0}};
	git_repository *cloned_repo = NULL;
	git_clone_options clone_opts = GIT_CLONE_OPTIONS_INIT;
	git_checkout_options checkout_opts = GIT_CHECKOUT_OPTIONS_INIT;
	git_remote_autotag_option_t download_tags = GIT_REMOTE_DOWNLOAD_TAGS_UNSPECIFIED;
	struct args_info args = ARGS_INFO_INIT;
	char *allocated_path = NULL;
	const char *path = NULL;
	const char *url = NULL;
	const char *checkout_branch = NULL;
	const char *remote_name = NULL;
	const char *ignored_value = NULL;
	int bare = 0;
	int depth = 0;
	int force_progress = 0;
	int quiet = 0;
	int no_checkout = 0;
	int error, matched, show_progress;

	(void)repo; /* unused */

	for (args.pos = 1; args.pos < args.argc;) {
		const char *arg = args.argv[args.pos];

		if (match_arg_separator(&args))
			break;
		if (arg[0] != '-')
			break;

		matched = take_int_option(&depth, &args, "--depth", NULL, 0);
		if (matched < 0)
			return 1;
		if (matched) {
			if (depth <= 0) {
				fprintf(stderr, "lg2 clone: --depth expects a positive number\n");
				return 1;
			}
			continue;
		}

		matched = take_value_option(&checkout_branch, &args, "--branch", "-b");
		if (matched < 0)
			return 1;
		if (matched)
			continue;

		matched = take_value_option(&remote_name, &args, "--origin", "-o");
		if (matched < 0)
			return 1;
		if (matched)
			continue;

		if (take_flag_option(&args, "--bare")) {
			bare = 1;
			continue;
		}

		if (take_flag_option(&args, "--no-checkout") || take_flag_option(&args, "-n")) {
			no_checkout = 1;
			continue;
		}

		if (take_flag_option(&args, "--no-tags")) {
			download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
			continue;
		}

		if (take_flag_option(&args, "--tags")) {
			download_tags = GIT_REMOTE_DOWNLOAD_TAGS_ALL;
			continue;
		}

		if (take_flag_option(&args, "--quiet") || take_flag_option(&args, "-q")) {
			quiet = 1;
			continue;
		}

		if (take_flag_option(&args, "--progress")) {
			force_progress = 1;
			continue;
		}

		if (take_flag_option(&args, "--verbose") ||
		    take_flag_option(&args, "-v")) {
			continue;
		}

		if (take_flag_option(&args, "--single-branch") ||
		    take_flag_option(&args, "--no-single-branch") ||
		    take_flag_option(&args, "--dissociate") ||
		    take_flag_option(&args, "--reject-shallow") ||
		    take_flag_option(&args, "--ipv4") ||
		    take_flag_option(&args, "-4") ||
		    take_flag_option(&args, "--ipv6") ||
		    take_flag_option(&args, "-6")) {
			warn_ignored_option(arg);
			continue;
		}

		if (take_optional_value_option(&args, "--recurse-submodules") ||
		    take_flag_option(&args, "--recursive") ||
		    take_optional_value_option(&args, "--shallow-submodules") ||
		    take_optional_value_option(&args, "--remote-submodules") ||
		    take_optional_value_option(&args, "--also-filter-submodules") ||
		    take_flag_option(&args, "--sparse")) {
			return unsupported_option(arg);
		}

		matched = take_value_option(&ignored_value, &args, "--filter", NULL);
		if (matched < 0)
			return 1;
		if (matched)
			return unsupported_option(arg);

		matched = take_value_option(&ignored_value, &args, "--shallow-since", NULL);
		if (matched < 0)
			return 1;
		if (matched)
			return unsupported_option(arg);

		matched = take_value_option(&ignored_value, &args, "--shallow-exclude", NULL);
		if (matched < 0)
			return 1;
		if (matched)
			return unsupported_option(arg);

		matched = take_value_option(&ignored_value, &args, "--separate-git-dir", NULL);
		if (matched < 0)
			return 1;
		if (matched)
			return unsupported_option(arg);

		matched = take_value_option(&ignored_value, &args, "--template", NULL);
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--reference", NULL);
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--reference-if-able", NULL);
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--upload-pack", "-u");
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--jobs", "-j");
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--server-option", NULL);
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		matched = take_value_option(&ignored_value, &args, "--config", "-c");
		if (matched < 0)
			return 1;
		if (matched) {
			warn_ignored_option(arg);
			continue;
		}

		if (!strcmp(arg, "-h") || !strcmp(arg, "--help"))
			return clone_usage(argv[0]);

		fprintf(stderr, "lg2 clone: unknown option: %s\n", arg);
		return clone_usage(argv[0]);
	}

	if (args.argc - args.pos == 1) {
		url = args.argv[args.pos];
		if (derive_default_path(&allocated_path, url, bare) < 0)
			return 1;
		path = allocated_path;
		printf("Cloning into ./%s\n", path);
	} else if (args.argc - args.pos == 2) {
		url = args.argv[args.pos];
		path = args.argv[args.pos + 1];
	} else {
		return clone_usage(argv[0]);
	}

	/* Set up options */
	show_progress = !quiet &&
		(force_progress ||
		 (stdout && isatty(fileno(stdout))) ||
		 (stderr && isatty(fileno(stderr))));

	checkout_opts.checkout_strategy = (bare || no_checkout) ? GIT_CHECKOUT_NONE : GIT_CHECKOUT_SAFE;
	if (show_progress) {
		checkout_opts.progress_cb = checkout_progress;
		checkout_opts.progress_payload = &pd;
	}
	clone_opts.checkout_opts = checkout_opts;
	clone_opts.bare = bare;
	clone_opts.checkout_branch = checkout_branch;
	clone_opts.fetch_opts.depth = depth;
	clone_opts.fetch_opts.download_tags = download_tags;

	if (remote_name) {
		clone_opts.remote_cb = create_remote_with_name;
		clone_opts.remote_cb_payload = (void *)remote_name;
	}

	if (show_progress) {
		// 'Counting objects' output:
		clone_opts.fetch_opts.callbacks.sideband_progress = sideband_progress;

		// Download progress.
		clone_opts.fetch_opts.callbacks.transfer_progress = fetch_progress;
		clone_opts.fetch_opts.callbacks.payload = &pd;
	}

	// We're cloning, so shouldn't rely on repo-specific configurations.
	clone_opts.fetch_opts.callbacks.credentials = repoless_cred_acquire_cb;

	/* Do the clone */
	error = git_clone(&cloned_repo, url, path, &clone_opts);
	if (show_progress)
		printf("\n");
	if (error != 0) {
		const git_error *err = git_error_last();
		if (err) printf("ERROR %d: %s\n", err->klass, err->message);
		else printf("ERROR %d: no detailed info\n", error);
	}
	if (cloned_repo) git_repository_free(cloned_repo);
	free(allocated_path);
	return error;
}
