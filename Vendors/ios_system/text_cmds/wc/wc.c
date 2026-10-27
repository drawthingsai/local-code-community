/*
 * Copyright (c) 1980, 1987, 1991, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *	This product includes software developed by the University of
 *	California, Berkeley and its contributors.
 * 4. Neither the name of the University nor the names of its contributors
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

#ifndef lint
static const char copyright[] =
"@(#) Copyright (c) 1980, 1987, 1991, 1993\n\
	The Regents of the University of California.  All rights reserved.\n";
#endif /* not lint */

#if 0
#ifndef lint
static char sccsid[] = "@(#)wc.c	8.1 (Berkeley) 6/6/93";
#endif /* not lint */
#endif

#include <sys/cdefs.h>
__FBSDID("$FreeBSD: src/usr.bin/wc/wc.c,v 1.21 2004/12/27 22:27:56 josef Exp $");

#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wchar.h>
#include <wctype.h>
#include "ios_system_support.h"

/* We allocte this much memory statically, and use it as a fallback for
  malloc failure, or statfs failure.  So it should be small, but not
  "too small" */
#define SMALL_BUF_SIZE (1024 * 8)

static __thread uintmax_t tlinect, twordct, tcharct;
static __thread int doline, doword, dochar, domulti;

/* iOS: the read buffer and open file belong to the invocation. */
static __thread u_char *wc_buf;
static __thread off_t wc_buf_size;
static __thread int open_fd = -1;

static int	cnt(const char *);
static void	usage(void);

/* iOS: the invocation's stdin belongs to the caller. */
static void close_input(int fd)
{
	if (fd != fileno(thread_stdin))
		close(fd);
	open_fd = -1;
}

static void wc_cleanup(void *unused)
{
	pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
	if (open_fd >= 0)
		close(open_fd);
	open_fd = -1;
	free(wc_buf);
	wc_buf = NULL;
	ios_system_support_cleanup(unused);
}

int
wc_main(int argc, char *argv[])
{
	int ch, errors, total;

	pthread_cleanup_push(wc_cleanup, NULL);
	ios_system_support_init(argv);
	/* Locale is owned by ios_system_support. */

	while ((ch = getopt(argc, argv, "clmw")) != -1)
		switch((char)ch) {
		case 'l':
			doline = 1;
			break;
		case 'w':
			doword = 1;
			break;
		case 'c':
			dochar = 1;
			domulti = 0;
			break;
		case 'm':
			domulti = 1;
			dochar = 0;
			break;
		case '?':
		default:
			usage();
		}
	argv += optind;
	argc -= optind;

	/* Wc's flags are on by default. */
	if (doline + doword + dochar + domulti == 0)
		doline = doword = dochar = 1;

	errors = 0;
	total = 0;
	if (!*argv) {
		if (cnt((char *)NULL) != 0)
			++errors;
		else
			(void)fprintf(thread_stdout, "\n");
	}
	else do {
		if (cnt(*argv) != 0)
			++errors;
		else
			(void)fprintf(thread_stdout, " %s\n", *argv);
		++total;
	} while(*++argv);

	if (total > 1) {
		if (doline)
			(void)fprintf(thread_stdout, " %7ju", tlinect);
		if (doword)
			(void)fprintf(thread_stdout, " %7ju", twordct);
		if (dochar || domulti)
			(void)fprintf(thread_stdout, " %7ju", tcharct);
		(void)fprintf(thread_stdout, " total\n");
	}
	exit(errors == 0 ? 0 : 1);
	pthread_cleanup_pop(1);
	return 0;
}

static int
cnt(const char *file)
{
	struct stat sb;
	struct statfs fsb;
	uintmax_t linect, wordct, charct;
	int fd, len, warned;
	int stat_ret;
	size_t clen;
	short gotsp;
	u_char *p;
	u_char small_buf[SMALL_BUF_SIZE];
	u_char *buf;
	off_t buf_size;
	wchar_t wch;
	mbstate_t mbs;

	linect = wordct = charct = 0;
	if (file == NULL) {
		file = "stdin";
		fd = fileno(thread_stdin);
	} else {
		if ((fd = open_fd = ios_system_open(file, O_RDONLY, 0)) < 0) {
            warn("%s: open", file);
			return (1);
		}
	}

	if (fstatfs(fd, &fsb)) {
	    fsb.f_iosize = SMALL_BUF_SIZE;
	}
	if (fsb.f_iosize != wc_buf_size) {
	    free(wc_buf);
	    wc_buf = NULL;
	    wc_buf_size = 0;
	    if (fsb.f_iosize != SMALL_BUF_SIZE && (wc_buf = malloc(fsb.f_iosize)) != NULL)
		wc_buf_size = fsb.f_iosize;
	}
	if (wc_buf != NULL) {
		buf = wc_buf;
		buf_size = wc_buf_size;
	} else {
		buf = small_buf;
		buf_size = SMALL_BUF_SIZE;
	}

	if (doword || (domulti && MB_CUR_MAX != 1))
		goto word;
	/*
	 * Line counting is split out because it's a lot faster to get
	 * lines than to get words, since the word count requires some
	 * logic.
	 */
	if (doline) {
        while ((len = read(fd, buf, buf_size))) {
			if (len == -1) {
                warn("%s: read", file);
				close_input(fd);
				return (1);
			}
			charct += len;
			for (p = buf; len--; ++p)
                if (*p == '\n')
					++linect;
		}
		tlinect += linect;
		(void)fprintf(thread_stdout, " %7ju", linect);
		if (dochar) {
			tcharct += charct;
			(void)fprintf(thread_stdout, " %7ju", charct);
		}
		close_input(fd);
		return (0);
	}
	/*
	 * If all we need is the number of characters and it's a
	 * regular file, just stat the puppy.
	 */
	if (dochar || domulti) {
		if (fstat(fd, &sb)) {
            warn("%s: fstat", file);
			close_input(fd);
			return (1);
		}
		if (S_ISREG(sb.st_mode)) {
			(void)fprintf(thread_stdout, " %7lld", (long long)sb.st_size);
			tcharct += sb.st_size;
			close_input(fd);
			return (0);
		}
	}

	/* Do it the hard way... */
word:	gotsp = 1;
	warned = 0;
	memset(&mbs, 0, sizeof(mbs));
	while ((len = read(fd, buf, buf_size)) != 0) {
		if (len == -1) {
            warn("%s: read", file);
			close_input(fd);
			return (1);
		}
		p = buf;
		while (len > 0) {
			if (!domulti || MB_CUR_MAX == 1) {
				clen = 1;
				wch = (unsigned char)*p;
			} else if ((clen = mbrtowc(&wch, p, len, &mbs)) ==
			    (size_t)-1) {
				if (!warned) {
					errno = EILSEQ;
                    warn("%s", file);
					warned = 1;
				}
				memset(&mbs, 0, sizeof(mbs));
				clen = 1;
				wch = (unsigned char)*p;
			} else if (clen == (size_t)-2)
				break;
			else if (clen == 0)
				clen = 1;
			charct++;
			len -= clen;
			p += clen;
			if (wch == L'\n')
				++linect;
			if (iswspace(wch))
				gotsp = 1;
			else if (gotsp) {
				gotsp = 0;
				++wordct;
			}
		}
	}
	if (domulti && MB_CUR_MAX > 1)
		if (mbrtowc(NULL, NULL, 0, &mbs) == (size_t)-1 && !warned)
            warn("%s", file);
	if (doline) {
		tlinect += linect;
		(void)fprintf(thread_stdout, " %7ju", linect);
	}
	if (doword) {
		twordct += wordct;
		(void)fprintf(thread_stdout, " %7ju", wordct);
	}
	if (dochar || domulti) {
		tcharct += charct;
		(void)fprintf(thread_stdout, " %7ju", charct);
	}
	close_input(fd);
	return (0);
}

static void
usage()
{
	(void)fprintf(thread_stderr, "usage: wc [-clmw] [file ...]\n");
	exit(1);
}
