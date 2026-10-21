/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 1989, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Adam S. Moskowitz of Menlo Consulting.
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
__COPYRIGHT(
"@(#) Copyright (c) 1989, 1993\n\
	The Regents of the University of California.  All rights reserved.\n");
#endif /* not lint */

#if 0
#ifndef lint
static char sccsid[] = "@(#)paste.c	8.1 (Berkeley) 6/6/93";
#endif /* not lint */
#endif

/* Upstream: "$FreeBSD$" */

#include <sys/types.h>

#include <err.h>
#include <errno.h>
#include <limits.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wchar.h>
#include <sysexits.h>

#include "ios_system_support.h"

static __thread wchar_t *delim;
static __thread int delimcnt;

static int parallel(char **);
static int sequential(char **);
static int tr(wchar_t *);
static void usage(void);

static wchar_t tab[] = L"\t";

static void paste_cleanup(void *unused);

int
main(int argc, char *argv[])
{
    pthread_cleanup_push(paste_cleanup, NULL);
    ios_system_support_init(argv);

	int ch, rval, seq;
	wchar_t *warg;
	const char *arg;
	size_t len;

	mbstate_t state;
	/* Locale is owned by ios_system_support. */

	seq = 0;
	while ((ch = getopt(argc, argv, "d:s")) != -1)
		switch(ch) {
		case 'd':
			memset(&state, 0, sizeof(state));
			arg = optarg;
			len = mbsrtowcs(NULL, &arg, 0, &state);
			if (len == (size_t)-1)
				err(1, "delimiters");
			if (delim != NULL && delim != tab) free(delim);
            delim = NULL;
			warg = malloc((len + 1) * sizeof(*warg));
			if (warg == NULL)
				err(1, NULL);
			memset(&state, 0, sizeof(state));
			delim = warg;
			arg = optarg;
			len = mbsrtowcs(warg, &arg, len + 1, &state);
			if (len == (size_t)-1)
				err(1, "delimiters");
			delimcnt = tr(delim = warg);
			break;
		case 's':
			seq = 1;
			break;
		case '?':
		default:
			usage();
		}
	argc -= optind;
	argv += optind;

	if (*argv == NULL)
		usage();
	if (!delim) {
		delimcnt = 1;
		delim = tab;
	}

	if (seq)
		rval = sequential(argv);
	else
		rval = parallel(argv);
#ifdef __APPLE__
	if (ferror(stdout) != 0 || fflush(stdout) != 0)
		err(2, "stdout");
#endif
	exit(rval);

    pthread_cleanup_pop(1);
    return 0;
}

typedef struct _list {
	struct _list *next;
	FILE *fp;
	int cnt;
	char *name;
} LIST;

static __thread LIST *head;
static __thread FILE *sequential_input;
static void paste_cleanup(void *unused)
{
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    while (head != NULL) {
        LIST *next = head->next;
        if (head->fp != NULL && head->fp != stdin) fclose(head->fp);
        free(head);
        head = next;
    }
    if (sequential_input != NULL && sequential_input != stdin) fclose(sequential_input);
    if (delim != NULL && delim != tab) free(delim);
    ios_system_support_cleanup(unused);
}

static int
parallel(char **argv)
{
	LIST *lp;
	int cnt;
	wint_t ich;
	wchar_t ch;
	char *p;
	LIST *tmp;
	int opencnt, output;

	for (cnt = 0, head = tmp = NULL; (p = *argv); ++argv, ++cnt) {
		if ((lp = calloc(1, sizeof(LIST))) == NULL)
			err(1, NULL);
		lp->next = NULL;
		lp->cnt = cnt;
		lp->name = p;
		if (!head)
			head = tmp = lp;
		else {
			tmp->next = lp;
			tmp = lp;
		}
		if (p[0] == '-' && !p[1])
			lp->fp = stdin;
		else if (!(lp->fp = ios_system_fopen(p, "r")))
			err(1, "%s", p);
	}

	for (opencnt = cnt; opencnt;) {
		for (output = 0, lp = head; lp; lp = lp->next) {
			if (!lp->fp) {
				if (output && lp->cnt &&
				    (ch = delim[(lp->cnt - 1) % delimcnt]))
					putwchar(ch);
				continue;
			}
			if ((ich = getwc(lp->fp)) == WEOF) {
				if (!--opencnt)
					break;
				if (lp->fp != stdin) fclose(lp->fp);
				lp->fp = NULL;
				if (output && lp->cnt &&
				    (ch = delim[(lp->cnt - 1) % delimcnt]))
					putwchar(ch);
				continue;
			}
			/*
			 * make sure that we don't print any delimiters
			 * unless there's a non-empty file.
			 */
			if (!output) {
				output = 1;
				for (cnt = 0; cnt < lp->cnt; ++cnt)
					if ((ch = delim[cnt % delimcnt]))
						putwchar(ch);
			} else if ((ch = delim[(lp->cnt - 1) % delimcnt]))
				putwchar(ch);
			if (ich == '\n')
				continue;
			do {
				putwchar(ich);
			} while ((ich = getwc(lp->fp)) != WEOF && ich != '\n');
			if (ferror(lp->fp)) {
				errx(EX_IOERR, "Error reading %s", lp->name);
			}
		}
		if (output)
			putwchar('\n');
	}

	return (0);
}

static int
sequential(char **argv)
{

	int cnt, failed, needdelim;
	wint_t ch;
	char *p;

	failed = 0;
	for (; (p = *argv); ++argv) {
		if (p[0] == '-' && !p[1])
			sequential_input = stdin;
		else if (!(sequential_input = ios_system_fopen(p, "r"))) {
			warn("%s", p);
			failed = 1;
			continue;
		}
		cnt = needdelim = 0;
		while ((ch = getwc(sequential_input)) != WEOF) {
			if (needdelim) {
				needdelim = 0;
				if (delim[cnt] != '\0')
					putwchar(delim[cnt]);
				if (++cnt == delimcnt)
					cnt = 0;
			}
			if (ch != '\n')
				putwchar(ch);
			else
				needdelim = 1;
		}
		if (needdelim)
			putwchar('\n');
		if (sequential_input != stdin)
			(void)fclose(sequential_input);
        sequential_input = NULL;
	}

	return (failed != 0);
}

static int
tr(wchar_t *arg)
{
	int cnt;
	wchar_t ch, *p;

	for (p = arg, cnt = 0; (ch = *p++); ++arg, ++cnt)
		if (ch == '\\')
			switch(ch = *p++) {
			case 'n':
				*arg = '\n';
				break;
			case 't':
				*arg = '\t';
				break;
			case '0':
				*arg = '\0';
				break;
			default:
				*arg = ch;
				break;
		} else
			*arg = ch;

	if (!cnt)
		errx(1, "no delimiters specified");
	return(cnt);
}

static void
usage(void)
{
	(void)fprintf(stderr, "usage: paste [-s] [-d delimiters] file ...\n");
	exit(1);
}
