/*      $OpenBSD: special.c,v 1.8 2018/03/05 16:53:39 cheloha Exp $      */
/*      $NetBSD: special.c,v 1.2 1995/09/08 03:23:00 tls Exp $      */

/*-
 * Copyright (c) 1991, 1993, 1994
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

#include <sys/types.h>

#include <err.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "ios_system_support.h"
#include "extern.h"

struct cmp_streams { FILE *first, *second; };
static void close_inputs(void *opaque)
{
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    struct cmp_streams *streams = opaque;
    if (streams->first != NULL) fclose(streams->first);
    if (streams->second != NULL) fclose(streams->second);
    pthread_setcancelstate(previous, NULL);
}

void
c_special(int fd1, char *file1, off_t skip1, int fd2, char *file2, off_t skip2)
{
	int ch1, ch2;
	off_t byte, line;
	FILE *fp1, *fp2;
	int dfound;

    struct cmp_streams streams = {0};
    pthread_cleanup_push(close_inputs, &streams);
    int copy = dup(fd1);
    if (copy < 0) fatal("%s", file1);
    streams.first = fp1 = fdopen(copy, "r");
    if (fp1 == NULL) {
        close(copy);
        fatal("%s", file1);
    }
    copy = dup(fd2);
    if (copy < 0) fatal("%s", file2);
    streams.second = fp2 = fdopen(copy, "r");
    if (fp2 == NULL) {
        close(copy);
        fatal("%s", file2);
    }

	dfound = 0;
	while (skip1--)
		if (getc(fp1) == EOF)
			goto eof;
	while (skip2--)
		if (getc(fp2) == EOF)
			goto eof;

	for (byte = line = 1;; ++byte) {
		ch1 = getc(fp1);
		ch2 = getc(fp2);
		if (ch1 == EOF || ch2 == EOF)
			break;
		if (ch1 != ch2) {
			if (lflag) {
				dfound = 1;
				(void)printf("%6lld %3o %3o\n", (long long)byte,
				    ch1, ch2);
			} else
				diffmsg(file1, file2, byte, line);
				/* NOTREACHED */
		}
		if (ch1 == '\n')
			++line;
	}

eof:	if (ferror(fp1))
		fatal("%s", file1);
	if (ferror(fp2))
		fatal("%s", file2);
	if (feof(fp1)) {
		if (!feof(fp2))
			eofmsg(file1);
	} else
		if (feof(fp2))
			eofmsg(file2);
	if (dfound)
		exit(DIFF_EXIT);
    pthread_cleanup_pop(1);
}
