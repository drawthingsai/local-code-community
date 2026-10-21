/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2022 The FreeBSD Foundation
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
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <getopt.h>
#include <limits.h>
#include <resolv.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ios_system_support.h"

static __thread FILE *input;
static void base64_cleanup(void *unused)
{
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (input != NULL && input != stdin) fclose(input);
    ios_system_support_cleanup(unused);
}

/* The FreeBSD base64 frontend, with invocation-local streaming and strict
 * final-block validation. Resolver codecs are supplied by the Apple SDK. */
static void usage(int status)
{
    fprintf(status == 0 ? stdout : stderr,
        "usage: base64 [-d | --decode] [-i | --ignore-garbage] "
        "[-w columns | --wrap=columns] [file]\n");
    exit(status);
}

static void encode(FILE *input, unsigned long width)
{
    unsigned char bytes[3 * 1024];
    char encoded[4 * 1024 + 1];
    size_t count;
    unsigned long column = 0;
    while ((count = fread(bytes, 1, sizeof(bytes), input)) != 0) {
        int length = b64_ntop(bytes, count, encoded, sizeof(encoded));
        if (length < 0) errx(1, "encoding failed");
        for (int index = 0; index < length; ++index) {
            if (fputc(encoded[index], stdout) == EOF) err(1, "stdout");
            if (width != 0 && ++column == width) {
                if (fputc('\n', stdout) == EOF) err(1, "stdout");
                column = 0;
            }
        }
    }
    if (width != 0 && column != 0 && fputc('\n', stdout) == EOF) err(1, "stdout");
}

static void decode(FILE *input, bool ignore_garbage)
{
    char quartet[5] = {0};
    unsigned char bytes[3];
    unsigned count = 0;
    bool padded = false;
    int byte;
    while ((byte = fgetc(input)) != EOF) {
        if (byte == '\n' || byte == '\r') continue;
        bool alphabet = (byte >= 'A' && byte <= 'Z') ||
            (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
            byte == '+' || byte == '/' || byte == '=';
        if (!alphabet) {
            if (ignore_garbage) continue;
            errx(1, "invalid input");
        }
        if (padded) errx(1, "data after padding");
        quartet[count++] = (char)byte;
        if (count != 4) continue;
        int length = b64_pton(quartet, bytes, sizeof(bytes));
        if (length < 0) errx(1, "invalid input");
        if (fwrite(bytes, 1, (size_t)length, stdout) != (size_t)length) err(1, "stdout");
        padded = quartet[2] == '=' || quartet[3] == '=';
        count = 0;
    }
    if (count != 0) errx(1, "incomplete input");
}

int base64_main(int argc, char **argv)
{
    pthread_cleanup_push(base64_cleanup, NULL);
    ios_system_support_init(argv);

    enum { HELP = CHAR_MAX + 1, VERSION };
    static const struct option options[] = {
        {"decode", no_argument, NULL, 'd'},
        {"ignore-garbage", no_argument, NULL, 'i'},
        {"wrap", required_argument, NULL, 'w'},
        {"help", no_argument, NULL, HELP},
        {"version", no_argument, NULL, VERSION},
        {NULL, 0, NULL, 0},
    };
    bool decoding = false, ignore_garbage = false;
    unsigned long width = 76;
    int option;
    while ((option = getopt_long(argc, argv, "diw:", options, NULL)) != -1) {
        switch (option) {
        case 'd': decoding = true; break;
        case 'i': ignore_garbage = true; break;
        case 'w': {
            char *end;
            errno = 0;
            width = strtoul(optarg, &end, 10);
            if (errno != 0 || *optarg == '\0' || *optarg == '-' || *end != '\0')
                errx(1, "invalid wrap width: %s", optarg);
            break;
        }
        case HELP: usage(0);
        case VERSION: puts("base64 (BSD, Local Code)"); exit(0);
        default: usage(1);
        }
    }
    if (argc - optind > 1) usage(1);
    input = stdin;
    if (optind < argc && strcmp(argv[optind], "-") != 0) {
        input = ios_system_fopen(argv[optind], "rb");
        if (input == NULL) err(1, "%s", argv[optind]);
    }
    if (decoding) decode(input, ignore_garbage);
    else encode(input, width);
    if (ferror(input)) err(1, "input");
    if (input != stdin) {
        FILE *owned = input;
        input = NULL;
        if (fclose(owned) != 0) err(1, "input");
    }
    exit(0);

    pthread_cleanup_pop(1);
    return 0;
}
