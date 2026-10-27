/*-
 * Copyright (C) 2009 Gabor Kovesdan <gabor@FreeBSD.org>
 * Copyright (C) 2012 Oleg Moskalenko <mom040267@gmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <sys/cdefs.h>
__FBSDID("$FreeBSD: head/usr.bin/sort/mem.c 281132 2015-04-06 02:35:55Z pfg $");

#include <err.h>
#include <stdlib.h>
#include <string.h>

#include "mem.h"
#include "ios_system_support.h"

/*
 * iOS: one invocation allocates from its own zone, destroyed when the command
 * ends, so error exits do not leak lists and strings.
 */
__thread malloc_zone_t *sort_zone;

/*
 * malloc() wrapper.
 */
void *
sort_malloc(size_t size)
{
	void *ptr;

	if ((ptr = malloc_zone_malloc(sort_zone, size)) == NULL)
		err(2, NULL);
	return (ptr);
}

/*
 * free() wrapper.
 */
void
sort_free(const void *ptr)
{

	// iOS: free through the zone; plain free() looks the zone up in the
	// process list, which another sort's zone destruction can change.
	if (ptr)
		malloc_zone_free(sort_zone, __DECONST(void *, ptr));
}

/*
 * realloc() wrapper.
 */
void *
sort_realloc(void *ptr, size_t size)
{

	if ((ptr = malloc_zone_realloc(sort_zone, ptr, size)) == NULL)
		err(2, NULL);
	return (ptr);
}

char *
sort_strdup(const char *str)
{
	char *dup;

	size_t length = strlen(str) + 1;

	if ((dup = malloc_zone_malloc(sort_zone, length)) == NULL)
		err(2, NULL);
	return (memcpy(dup, str, length));
}
