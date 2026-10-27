/*-
 * Copyright (c) 1989, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Kevin Fall.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
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

#if 0
#ifndef lint
static char const copyright[] =
"@(#) Copyright (c) 1989, 1993\n\
	The Regents of the University of California.  All rights reserved.\n";
#endif /* not lint */
#endif

#ifndef lint
#if 0
static char sccsid[] = "@(#)cat.c	8.2 (Berkeley) 4/27/95";
#endif
#endif /* not lint */
#include <sys/cdefs.h>
__FBSDID("$FreeBSD: src/bin/cat/cat.c,v 1.32 2005/01/10 08:39:20 imp Exp $");

#include <sys/param.h>
#include <sys/stat.h>
#ifndef NO_UDOM_SUPPORT
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#endif

#include <ctype.h>
#include <err.h>
#include <fcntl.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stddef.h>
#include "ios_system_support.h"

static __thread int bflag, eflag, nflag, sflag, tflag, vflag;
static __thread int rval;
const __thread char *filename;
static __thread char *buf;	/* raw_cat buffer */
static __thread int open_fd = -1;	/* iOS: closed by cat_cleanup on early exit */
static __thread FILE *open_fp;

static void cat_cleanup(void *unused)
{
	pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
	if (open_fp != NULL)
		fclose(open_fp);
	else if (open_fd >= 0)
		close(open_fd);
	open_fp = NULL;
	open_fd = -1;
	free(buf);
	buf = NULL;
	ios_system_support_cleanup(unused);
}

static void usage(void);
static void scanfiles(char *argv[], int cooked);
static void cook_cat(FILE *);
static void raw_cat(int);

#ifndef NO_UDOM_SUPPORT
static int udom_open(const char *path, int flags);
#endif

int
cat_main(int argc, char *argv[])
{
	int ch;

	pthread_cleanup_push(cat_cleanup, NULL);
	ios_system_support_init(argv);
	/* Locale is owned by ios_system_support. */

	while ((ch = getopt(argc, argv, "benstuv")) != -1)
		switch (ch) {
		case 'b':
			bflag = nflag = 1;	/* -b implies -n */
			break;
		case 'e':
			eflag = vflag = 1;	/* -e implies -v */
			break;
		case 'n':
			nflag = 1;
			break;
		case 's':
			sflag = 1;
			break;
		case 't':
			tflag = vflag = 1;	/* -t implies -v */
			break;
		case 'u':
			setbuf(thread_stdout, NULL);
			break;
		case 'v':
			vflag = 1;
			break;
		default:
			usage();
		}
	argv += optind;

	if (bflag || eflag || nflag || sflag || tflag || vflag)
		scanfiles(argv, 1);
	else
		scanfiles(argv, 0);
	// if (fclose(stdout)) err(1, "stdout");
    exit(rval);
	pthread_cleanup_pop(1);
	return 0;
}

static void
usage(void)
{
	fprintf(thread_stderr, "usage: cat [-benstuv] [file ...]\n");
	exit(1);
	/* NOTREACHED */
}

static void
scanfiles(char *argv[], int cooked)
{
	int i = 0;
	char *path;
	FILE *fp;

	while ((path = argv[i]) != NULL || i == 0) {
		int fd;

		if (path == NULL || strcmp(path, "-") == 0) {
			filename = "stdin";
			fd = fileno(thread_stdin);
		} else {
			filename = path;
			fd = ios_system_open(path, O_RDONLY);
#ifndef NO_UDOM_SUPPORT
			if (fd < 0 && errno == EOPNOTSUPP)
				fd = udom_open(path, O_RDONLY);
#endif
		}
		if (fd < 0) {
            warn("%s", path);
			rval = 1;
		} else if (cooked) {
			if (fd == fileno(thread_stdin))
				cook_cat(thread_stdin);
			else {
				fp = open_fp = fdopen(fd, "r");
				cook_cat(fp);
				fclose(fp);
				open_fp = NULL;
			}
		} else {
			if (fd != fileno(thread_stdin))
				open_fd = fd;
			raw_cat(fd);
			if (fd != fileno(thread_stdin))
				close(fd);
			open_fd = -1;
		}
		if (path == NULL)
			break;
		++i;
	}
}

static void
cook_cat(FILE *fp)
{
	int ch, gobble, line, prev;

	/* Reset EOF condition on stdin. */
	if (fp == thread_stdin && feof(thread_stdin))
		clearerr(thread_stdin);

	line = gobble = 0;
	for (prev = '\n'; (ch = getc(fp)) != EOF; prev = ch) {
		if (prev == '\n') {
			if (sflag) {
				if (ch == '\n') {
					if (gobble)
						continue;
					gobble = 1;
				} else
					gobble = 0;
			}
			if (nflag && (!bflag || ch != '\n')) {
				(void)fprintf(thread_stdout, "%6d\t", ++line);
				if (ferror(thread_stdout))
					break;
			}
		}
		if (ch == '\n') {
			if (eflag && putchar('$') == EOF)
				break;
		} else if (ch == '\t') {
			if (tflag) {
				if (putchar('^') == EOF || putchar('I') == EOF)
					break;
				continue;
			}
		} else if (vflag) {
			if (!isascii(ch) && !isprint(ch)) {
				if (putchar('M') == EOF || putchar('-') == EOF)
					break;
				ch = toascii(ch);
			}
			if (iscntrl(ch)) {
				if (putchar('^') == EOF ||
				    putchar(ch == '\177' ? '?' :
				    ch | 0100) == EOF)
					break;
				continue;
			}
		}
		if (putchar(ch) == EOF)
			break;
	}
	if (ferror(fp)) {
        warn("%s", filename);
		rval = 1;
		clearerr(fp);
	}
    if (ferror(thread_stdout)) {
		ios_system_stop_on_broken_pipe(thread_stdout);
		err(1, "stdout");
    }
}

static void
raw_cat(int rfd)
{
	int wfd;
	ssize_t nr;
	static __thread size_t bsize;
	// struct stat sbuf;

	wfd = fileno(thread_stdout);
	if (buf == NULL) {
        // if (fstat(wfd, &sbuf))
			// err(1, "%s", filename);
        bsize = 1024; // MAX(sbuf.st_blksize, 1024);
        if ((buf = malloc(bsize)) == NULL) {
            err(1, "buffer");
        }
	}
	// We can't write to the fd of stdout, so we write to stdout
	while ((nr = read(rfd, buf, bsize)) > 0)
		if (fwrite(buf, 1, (size_t)nr, thread_stdout) != (size_t)nr) {
			ios_system_stop_on_broken_pipe(thread_stdout);
			err(1, "stdout");
		}
	if (nr < 0) {
        warn("%s", filename);
		rval = 1;
	}
    free(buf);
    buf = NULL;
}

#ifndef NO_UDOM_SUPPORT

static int
udom_open(const char *path, int flags)
{
	struct sockaddr_un sou;
	int fd;
	unsigned int len;

	char resolved[PATH_MAX];

	bzero(&sou, sizeof(sou));
	if ((path = ios_system_session_path(path, resolved)) == NULL)
		return (-1);

	/*
	 * Construct the unix domain socket address and attempt to connect
	 */
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd >= 0) {
		sou.sun_family = AF_UNIX;
		if ((len = strlcpy(sou.sun_path, path,
		    sizeof(sou.sun_path))) >= sizeof(sou.sun_path)) {
			errno = ENAMETOOLONG;
			return (-1);
		}
		len = offsetof(struct sockaddr_un, sun_path[len+1]);

		if (connect(fd, (void *)&sou, len) < 0) {
			close(fd);
			fd = -1;
		}
	}

	/*
	 * handle the open flags by shutting down appropriate directions
	 */
	if (fd >= 0) {
		switch(flags & O_ACCMODE) {
		case O_RDONLY:
			if (shutdown(fd, SHUT_WR) == -1)
                warn(NULL);
			break;
		case O_WRONLY:
			if (shutdown(fd, SHUT_RD) == -1)
                warn(NULL);
			break;
		default:
			break;
		}
	}
	return(fd);
}

#endif
