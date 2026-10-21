/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 1989, 1993, 1994
 *	The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Chris Newcomb.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <sys/cdefs.h>
#ifndef lint
__used static const char copyright[] =
"@(#) Copyright (c) 1989, 1993, 1994\n\
	The Regents of the University of California.  All rights reserved.\n";
#endif /* not lint */

#ifndef lint
#if 0
static const char sccsid[] = "@(#)du.c	8.5 (Berkeley) 5/4/95";
#endif
#endif /* not lint */

#include <sys/mount.h>
#include <sys/param.h>
#include <sys/queue.h>
#include <sys/stat.h>
#include <sys/attr.h>

#include <err.h>
#include <errno.h>
#include <fnmatch.h>
#include <fts.h>
#include <getopt.h>
#include <libutil.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#ifdef __APPLE__
#define COMPAT_MODE(command, mode) 1
#include <sys/sysctl.h>
#include <TargetConditionals.h>
#else
#define COMPAT_MODE(func, mode) (1)
#endif

#include "ios_system_support.h"

#define SI_OPT	(CHAR_MAX + 1)

#define UNITS_2		1
#define UNITS_SI	2

/* iOS and macOS targets are 64-bit; use the public FTS scratch field. */
_Static_assert(sizeof(((FTSENT *)0)->fts_number) >= sizeof(int64_t), "64-bit FTS required");
#define COMPAT_FTS_BIGNUM(p) ((p)->fts_number)

static __thread SLIST_HEAD(ignhead, ignentry) ignores;
struct ignentry {
	char			*mask;
	SLIST_ENTRY(ignentry)	next;
};

static int	linkchk(FTSENT *);
static int	dirlinkchk(FTSENT *);
static void	usage(void);
static void	prthumanval(int64_t);
static void	ignoreadd(const char *);
static void	ignoreclean(void);
static int	ignorep(FTSENT *);

static __thread int	nodumpflag = 0;
static __thread int	Aflag, hflag;
static __thread long	blocksize, cblocksize;

static const struct option long_options[] =
{
	{ "si", no_argument, NULL, SI_OPT },
	{ NULL, no_argument, NULL, 0 },
};

struct links_entry {
    struct links_entry *next, *previous;
    int links;
    dev_t dev;
    ino_t ino;
};
struct links_table {
    struct links_entry **buckets, *free_list;
    size_t number_buckets;
    unsigned long number_entries;
    char stop_allocating;
};
static __thread struct links_table file_links, directory_links;
static __thread FTS *fts;
static void du_cleanup(void *unused)
{
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (fts != NULL) fts_close(fts);
    ignoreclean();
    struct links_table *tables[] = {&file_links, &directory_links};
    for (int index = 0; index < 2; ++index) {
        struct links_table *table = tables[index];
        for (size_t bucket = 0; table->buckets != NULL && bucket < table->number_buckets; ++bucket) {
            struct links_entry *entry = table->buckets[bucket];
            while (entry != NULL) {
                struct links_entry *next = entry->next;
                free(entry);
                entry = next;
            }
        }
        while (table->free_list != NULL) {
            struct links_entry *next = table->free_list->next;
            free(table->free_list);
            table->free_list = next;
        }
        free(table->buckets);
    }
    ios_system_support_cleanup(unused);
}

int
main(int argc, char *argv[])
{
    pthread_cleanup_push(du_cleanup, NULL);
    ios_system_support_init(argv);


	FTSENT		*p;
	off_t		savednumber, curblocks;
	uint64_t	threshold;
	int		threshold_sign;
	char		*end;
	long		number;
	int		ftsoptions;
	int		depth;
	int		Hflag, Lflag, aflag, sflag, dflag, cflag;
	int		lflag, ch, notused, rval;
	char 		**save;
	static __thread char	dot[] = ".";

	/* Locale is owned by ios_system_support. */

	Hflag = Lflag = aflag = sflag = dflag = cflag = lflag = hflag = Aflag = 0;

	save = argv;
	ftsoptions = FTS_PHYSICAL;
#ifdef __APPLE__
	// rdar://4924219
	ftsoptions |= FTS_NOCHDIR;
#endif
	savednumber = 0;
	threshold = 0;
	threshold_sign = 1;
	cblocksize = DEV_BSIZE;
	blocksize = 0;
	depth = INT_MAX;
	SLIST_INIT(&ignores);

	while ((ch = getopt_long(argc, argv, "+AB:HI:LPasd:cghklmnrt:x",
	    long_options, NULL)) != -1)
		switch (ch) {
		case 'A':
			Aflag = 1;
			break;
		case 'B':
			errno = 0;
			cblocksize = strtol(optarg, &end, 10);
			if (errno == ERANGE || *end != '\0' || cblocksize <= 0 ||
			    cblocksize > LONG_MAX - DEV_BSIZE) {
				warnx("invalid argument to option B: %s",
				    optarg);
				usage();
			}
			break;
		case 'H':
			Hflag = 1;
			Lflag = 0;
			break;
		case 'I':
			ignoreadd(optarg);
			break;
		case 'L':
			Lflag = 1;
			Hflag = 0;
			break;
		case 'P':
			Hflag = Lflag = 0;
			break;
		case 'a':
			aflag = 1;
			break;
		case 's':
			sflag = 1;
			break;
		case 'd':
			dflag = 1;
			errno = 0;
			number = strtol(optarg, &end, 10);
			if (errno == ERANGE || *optarg == '\0' || *end != '\0' ||
			    number < 0 || number > INT_MAX) {
				warnx("invalid argument to option d: %s",
				    optarg);
				usage();
			}
			depth = (int)number;
			break;
		case 'c':
			cflag = 1;
			break;
		case 'g':
			hflag = 0;
			blocksize = 1073741824;
			break;
		case 'h':
			hflag = UNITS_2;
			break;
		case 'k':
			hflag = 0;
			blocksize = 1024;
			break;
		case 'l':
			lflag = 1;
			break;
		case 'm':
			hflag = 0;
			blocksize = 1048576;
			break;
		case 'n':
			nodumpflag = 1;
			break;
		case 'r':		 /* Compatibility. */
			break;
		case 't' :
			threshold_sign = *optarg == '-' ? -1 : 1;
			if (ios_system_expand_number(optarg + (threshold_sign < 0), &threshold) != 0 ||
			    threshold == 0) {
				warnx("invalid threshold: %s", optarg);
				usage();
			}
			break;
		case 'x':
			ftsoptions |= FTS_XDEV;
			break;
		case SI_OPT:
			hflag = UNITS_SI;
			break;
		case '?':
		default:
			usage();
			/* NOTREACHED */
		}

	argc -= optind;
	argv += optind;

	/*
	 * XXX
	 * Because of the way that fts(3) works, logical walks will not count
	 * the blocks actually used by symbolic links.  We rationalize this by
	 * noting that users computing logical sizes are likely to do logical
	 * copies, so not counting the links is correct.  The real reason is
	 * that we'd have to re-implement the kernel's symbolic link traversing
	 * algorithm to get this right.  If, for example, you have relative
	 * symbolic links referencing other relative symbolic links, it gets
	 * very nasty, very fast.  The bottom line is that it's documented in
	 * the man page, so it's a feature.
	 */

	if (Hflag)
		ftsoptions |= FTS_COMFOLLOW;
	if (Lflag) {
		ftsoptions &= ~FTS_PHYSICAL;
		ftsoptions |= FTS_LOGICAL;
	}

	if (!Aflag && (cblocksize % DEV_BSIZE) != 0)
		cblocksize = howmany(cblocksize, DEV_BSIZE) * DEV_BSIZE;

	if (aflag + dflag + sflag > 1)
		usage();
	if (sflag)
		depth = 0;

	if (!*argv) {
		argv = save;
		argv[0] = dot;
		argv[1] = NULL;
	}

	if (blocksize == 0)
		(void)getbsize(&notused, &blocksize);

	if (!Aflag) {
		cblocksize /= DEV_BSIZE;
		blocksize /= DEV_BSIZE;
	}

	if (threshold != 0) {
		uint64_t unit = Aflag ? blocksize : blocksize * DEV_BSIZE;
		threshold = threshold / unit + (threshold % unit != 0);
	}

	rval = 0;

	/* Cancellation is owned by ios_system; do not install process handlers. */

	if ((fts = fts_open(argv, ftsoptions | FTS_NOCHDIR, NULL)) == NULL)
		err(1, "fts_open");

	while ((void)(errno = 0), (p = fts_read(fts)) != NULL) {
		switch (p->fts_info) {
		case FTS_D:			/* Ignore. */
			if (ignorep(p) || dirlinkchk(p))
				fts_set(fts, p, FTS_SKIP);
			break;
		case FTS_DP:
			if (ignorep(p))
				break;

			curblocks = Aflag ?
			    howmany(p->fts_statp->st_size, cblocksize) :
			    howmany(p->fts_statp->st_blocks, cblocksize);
			COMPAT_FTS_BIGNUM(p->fts_parent) += COMPAT_FTS_BIGNUM(p) += curblocks;

			uint64_t total = howmany(COMPAT_FTS_BIGNUM(p) * cblocksize, blocksize);
			if (p->fts_level <= depth && (threshold_sign > 0 ?
			    total >= threshold : total <= threshold)) {
				if (hflag > 0) {
					prthumanval(COMPAT_FTS_BIGNUM(p));
					(void)printf("\t%s\n", p->fts_path);
				} else {
					(void)printf("%jd\t%s\n",
					    (intmax_t)howmany(COMPAT_FTS_BIGNUM(p) *
					    cblocksize, blocksize),
					    p->fts_path);
				}
			}
			break;
		case FTS_DC:			/* Ignore. */
			if (COMPAT_MODE("bin/du", "unix2003")) {
				errx(1, "Can't follow symlink cycle from %s to %s", p->fts_path, p->fts_cycle->fts_path);
			}
			break;
		case FTS_DNR:			/* Warn, continue. */
		case FTS_ERR:
		case FTS_NS:
			warnx("%s: %s", p->fts_path, strerror(p->fts_errno));
			rval = 1;
			break;
		case FTS_SLNONE:
			if (COMPAT_MODE("bin/du", "unix2003")) {
				struct stat sb;
				int rc = ios_system_stat(p->fts_path, &sb);
				if (rc < 0 && errno == ELOOP) {
					errx(1, "Too many symlinks at %s", p->fts_path);
				}
			}
		default:
			if (ignorep(p))
				break;

			if (lflag == 0 && p->fts_statp->st_nlink > 1 &&
			    linkchk(p))
				break;

			curblocks = Aflag ?
			    howmany(p->fts_statp->st_size, cblocksize) :
			    howmany(p->fts_statp->st_blocks, cblocksize);

			uint64_t size = howmany(curblocks * cblocksize, blocksize);
			if ((aflag || p->fts_level == 0) && (threshold_sign > 0 ?
			    size >= threshold : size <= threshold)) {
				if (hflag > 0) {
					prthumanval(curblocks);
					(void)printf("\t%s\n", p->fts_path);
				} else {
					(void)printf("%jd\t%s\n",
					    (intmax_t)howmany(curblocks *
					    cblocksize, blocksize),
					    p->fts_path);
				}
			}

			COMPAT_FTS_BIGNUM(p->fts_parent) += curblocks;
		}
		savednumber = COMPAT_FTS_BIGNUM(p->fts_parent);
	}

	if (errno)
		err(1, "fts_read");

	if (cflag) {
		if (hflag > 0) {
			prthumanval(savednumber);
			(void)printf("\ttotal\n");
		} else {
			(void)printf("%jd\ttotal\n", (intmax_t)howmany(
			    savednumber * cblocksize, blocksize));
		}
	}

	ignoreclean();
#ifdef __APPLE__
	if (rval == 0 && (ferror(stdout) != 0 || fflush(stdout) != 0))
		err(1, "stdout");
#endif
	exit(rval);

    pthread_cleanup_pop(1);
    return 0;
}

static int
linkchk(FTSENT *p)
{
    struct links_table *table = &file_links;
	static const size_t links_hash_initial_size = 8192;
	struct links_entry *le, **new_buckets;
	struct stat *st;
	size_t i, new_size;
	int hash;

	st = p->fts_statp;

	/* If necessary, initialize the hash table. */
	if (table->buckets == NULL) {
		table->number_buckets = links_hash_initial_size;
		table->buckets = malloc(table->number_buckets * sizeof(table->buckets[0]));
		if (table->buckets == NULL)
			errx(1, "No memory for hardlink detection");
		for (i = 0; i < table->number_buckets; i++)
			table->buckets[i] = NULL;
	}

	/* If the hash table is getting too full, enlarge it. */
	if (table->number_entries > table->number_buckets * 10 && !table->stop_allocating) {
		new_size = table->number_buckets * 2;
		new_buckets = calloc(new_size, sizeof(struct links_entry *));

		/* Try releasing the free list to see if that helps. */
		if (new_buckets == NULL && table->free_list != NULL) {
			while (table->free_list != NULL) {
				le = table->free_list;
				table->free_list = le->next;
				free(le);
			}
			new_buckets = calloc(new_size, sizeof(new_buckets[0]));
		}

		if (new_buckets == NULL) {
			table->stop_allocating = 1;
			warnx("No more memory for tracking hard links");
		} else {
			for (i = 0; i < table->number_buckets; i++) {
				while (table->buckets[i] != NULL) {
					/* Remove entry from old bucket. */
					le = table->buckets[i];
					table->buckets[i] = le->next;

					/* Add entry to new bucket. */
					hash = (le->dev ^ le->ino) % new_size;

					if (new_buckets[hash] != NULL)
						new_buckets[hash]->previous =
						    le;
					le->next = new_buckets[hash];
					le->previous = NULL;
					new_buckets[hash] = le;
				}
			}
			free(table->buckets);
			table->buckets = new_buckets;
			table->number_buckets = new_size;
		}
	}

	/* Try to locate this entry in the hash table. */
	hash = ( st->st_dev ^ st->st_ino ) % table->number_buckets;
	for (le = table->buckets[hash]; le != NULL; le = le->next) {
		if (le->dev == st->st_dev && le->ino == st->st_ino) {
			/*
			 * Save memory by releasing an entry when we've seen
			 * all of its links.
			 */
			if (--le->links <= 0) {
				if (le->previous != NULL)
					le->previous->next = le->next;
				if (le->next != NULL)
					le->next->previous = le->previous;
				if (table->buckets[hash] == le)
					table->buckets[hash] = le->next;
				table->number_entries--;
				/* Recycle this node through the free list */
				if (table->stop_allocating) {
					free(le);
				} else {
					le->next = table->free_list;
					table->free_list = le;
				}
			}
			return (1);
		}
	}

	if (table->stop_allocating)
		return (0);

	/* Add this entry to the links cache. */
	if (table->free_list != NULL) {
		/* Pull a node from the free list if we can. */
		le = table->free_list;
		table->free_list = le->next;
	} else
		/* Malloc one if we have to. */
		le = malloc(sizeof(struct links_entry));
	if (le == NULL) {
		table->stop_allocating = 1;
		warnx("No more memory for tracking hard links");
		return (0);
	}
	le->dev = st->st_dev;
	le->ino = st->st_ino;
	le->links = st->st_nlink - 1;
	table->number_entries++;
	le->next = table->buckets[hash];
	le->previous = NULL;
	if (table->buckets[hash] != NULL)
		table->buckets[hash]->previous = le;
	table->buckets[hash] = le;
	return (0);
}

static int
dirlinkchk(FTSENT *p)
{
    struct links_table *table = &directory_links;
	static const size_t links_hash_initial_size = 8192;
	struct links_entry *le, **new_buckets;
	struct stat *st;
	size_t i, new_size;
	int hash;
	struct attrbuf {
		int size;
		int linkcount;
	} buf;
	struct attrlist attrList;

	memset(&attrList, 0, sizeof(attrList));
	attrList.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrList.dirattr = ATTR_DIR_LINKCOUNT;
	if (-1 == getattrlist(p->fts_path, &attrList, &buf, sizeof(buf), 0))
		return 0;
	if (buf.linkcount == 1)
		return 0;
	st = p->fts_statp;

	/* If necessary, initialize the hash table. */
	if (table->buckets == NULL) {
		table->number_buckets = links_hash_initial_size;
		table->buckets = malloc(table->number_buckets * sizeof(table->buckets[0]));
		if (table->buckets == NULL)
			errx(1, "No memory for directory hardlink detection");
		for (i = 0; i < table->number_buckets; i++)
			table->buckets[i] = NULL;
	}

	/* If the hash table is getting too full, enlarge it. */
	if (table->number_entries > table->number_buckets * 10 && !table->stop_allocating) {
		new_size = table->number_buckets * 2;
		new_buckets = calloc(new_size, sizeof(struct links_entry *));

		/* Try releasing the free list to see if that helps. */
		if (new_buckets == NULL && table->free_list != NULL) {
			while (table->free_list != NULL) {
				le = table->free_list;
				table->free_list = le->next;
				free(le);
			}
			new_buckets = calloc(new_size, sizeof(new_buckets[0]));
		}

		if (new_buckets == NULL) {
			table->stop_allocating = 1;
			warnx("No more memory for tracking directory hard links");
		} else {
			for (i = 0; i < table->number_buckets; i++) {
				while (table->buckets[i] != NULL) {
					/* Remove entry from old bucket. */
					le = table->buckets[i];
					table->buckets[i] = le->next;

					/* Add entry to new bucket. */
					hash = (le->dev ^ le->ino) % new_size;

					if (new_buckets[hash] != NULL)
						new_buckets[hash]->previous =
						    le;
					le->next = new_buckets[hash];
					le->previous = NULL;
					new_buckets[hash] = le;
				}
			}
			free(table->buckets);
			table->buckets = new_buckets;
			table->number_buckets = new_size;
		}
	}

	/* Try to locate this entry in the hash table. */
	hash = ( st->st_dev ^ st->st_ino ) % table->number_buckets;
	for (le = table->buckets[hash]; le != NULL; le = le->next) {
		if (le->dev == st->st_dev && le->ino == st->st_ino) {
			/*
			 * Save memory by releasing an entry when we've seen
			 * all of its links.
			 */
			if (--le->links <= 0) {
				if (le->previous != NULL)
					le->previous->next = le->next;
				if (le->next != NULL)
					le->next->previous = le->previous;
				if (table->buckets[hash] == le)
					table->buckets[hash] = le->next;
				table->number_entries--;
				/* Recycle this node through the free list */
				if (table->stop_allocating) {
					free(le);
				} else {
					le->next = table->free_list;
					table->free_list = le;
				}
			}
			return (1);
		}
	}

	if (table->stop_allocating)
		return (0);

	/* Add this entry to the links cache. */
	if (table->free_list != NULL) {
		/* Pull a node from the free list if we can. */
		le = table->free_list;
		table->free_list = le->next;
	} else
		/* Malloc one if we have to. */
		le = malloc(sizeof(struct links_entry));
	if (le == NULL) {
		table->stop_allocating = 1;
		warnx("No more memory for tracking hard links");
		return (0);
	}
	le->dev = st->st_dev;
	le->ino = st->st_ino;
	le->links = buf.linkcount - 1;
	table->number_entries++;
	le->next = table->buckets[hash];
	le->previous = NULL;
	if (table->buckets[hash] != NULL)
		table->buckets[hash]->previous = le;
	table->buckets[hash] = le;
	return (0);
}

static void
prthumanval(int64_t bytes)
{
	char buf[5];
	int flags;

	bytes *= cblocksize;
	flags = HN_B | HN_NOSPACE | HN_DECIMAL;
	if (!Aflag)
		bytes *= DEV_BSIZE;
	if (hflag == UNITS_SI)
		flags |= HN_DIVISOR_1000;

	humanize_number(buf, sizeof(buf), bytes, "", HN_AUTOSCALE, flags);

	(void)printf("%4s", buf);
}

static void
usage(void)
{
	(void)fprintf(stderr,
		"usage: du [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] "
		"[-a | -s | -d depth] [-B blocksize] [-I mask] "
		"[-t threshold] [file ...]\n");
	exit(EX_USAGE);
}

static void
ignoreadd(const char *mask)
{
	struct ignentry *ign;

	ign = calloc(1, sizeof(*ign));
	if (ign == NULL)
		errx(1, "cannot allocate memory");
    SLIST_INSERT_HEAD(&ignores, ign, next);
	ign->mask = strdup(mask);
	if (ign->mask == NULL)
		errx(1, "cannot allocate memory");
}

static void
ignoreclean(void)
{
	struct ignentry *ign;

	while (!SLIST_EMPTY(&ignores)) {
		ign = SLIST_FIRST(&ignores);
		SLIST_REMOVE_HEAD(&ignores, next);
		free(ign->mask);
		free(ign);
	}
}

static int
ignorep(FTSENT *ent)
{
	struct ignentry *ign;

#ifdef __APPLE__
	if (S_ISDIR(ent->fts_statp->st_mode) && !strcmp("fd", ent->fts_name)) {
		struct statfs sfsb;
		int rc = statfs(ent->fts_accpath, &sfsb);
		if (rc >= 0 && !strcmp("devfs", sfsb.f_fstypename)) {
			/* Don't cd into /dev/fd/N since one of those is likely to be
			  the cwd as of the start of du which causes all manner of
			  unpleasant surprises */
			return 1;
		}
	}
#endif /* __APPLE__ */
	if (nodumpflag && (ent->fts_statp->st_flags & UF_NODUMP))
		return 1;
	SLIST_FOREACH(ign, &ignores, next)
		if (fnmatch(ign->mask, ent->fts_name, 0) != FNM_NOMATCH)
			return 1;
	return 0;
}
