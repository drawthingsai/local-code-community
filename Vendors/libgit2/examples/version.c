/*
 * libgit2 "version" example - shows how to print the libgit2 version
 *
 * Written by the libgit2 contributors
 *
 * To the extent possible under law, the author(s) have dedicated all copyright
 * and related and neighboring rights to this software to the public domain
 * worldwide. This software is distributed without any warranty.
 *
 * You should have received a copy of the CC0 Public Domain Dedication along
 * with this software. If not, see
 * <http://creativecommons.org/publicdomain/zero/1.0/>.
 */

#include "common.h"
#include "git2/version.h"

int lg2_version(git_repository *repo, int argc, char **argv) {
	printf("libgit2 version %s", LIBGIT2_VERSION);
	return 0;
}
