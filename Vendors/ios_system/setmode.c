/*
 * setmode(3) and getmode(3) from Apple Libc (gen/FreeBSD/setmode.c, the
 * non-legacy variant), taking the umask from ios_system_umask() instead of
 * setting the process-wide umask(2) to read it.
 *
 * Copyright (c) 1989, 1993, 1994
 *	The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Dave Borman at Cray Research, Inc.
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

#include <ctype.h>
#include <stdlib.h>
#include <sys/stat.h>

#define IOS_SYSTEM_SUPPORT_IMPLEMENTATION
#include "ios_system_support.h"

typedef struct bitcmd {
    char cmd;
    char cmd2;
    mode_t bits;
} BITCMD;

#define CMD2_CLR 0x01
#define CMD2_SET 0x02
#define CMD2_GBITS 0x04
#define CMD2_OBITS 0x08
#define CMD2_UBITS 0x10
#define SET_LEN 6
#define SET_LEN_INCR 4
#define STANDARD_BITS (S_ISUID | S_ISGID | S_IRWXU | S_IRWXG | S_IRWXO | S_ISTXT)

mode_t ios_system_getmode(const void *bbox, mode_t omode)
{
    const BITCMD *set = bbox;
    mode_t clrval, newmode = omode, value = 0;
    for (;; set++) {
        switch (set->cmd) {
        case 'u': value = (newmode & S_IRWXU) >> 6; goto common;
        case 'g': value = (newmode & S_IRWXG) >> 3; goto common;
        case 'o':
            value = newmode & S_IRWXO;
        common:
            if (set->cmd2 & CMD2_CLR) {
                clrval = (set->cmd2 & CMD2_SET) ? S_IRWXO : value;
                if (set->cmd2 & CMD2_UBITS) newmode &= ~((clrval << 6) & set->bits);
                if (set->cmd2 & CMD2_GBITS) newmode &= ~((clrval << 3) & set->bits);
                if (set->cmd2 & CMD2_OBITS) newmode &= ~(clrval & set->bits);
            }
            if (set->cmd2 & CMD2_SET) {
                if (set->cmd2 & CMD2_UBITS) newmode |= (value << 6) & set->bits;
                if (set->cmd2 & CMD2_GBITS) newmode |= (value << 3) & set->bits;
                if (set->cmd2 & CMD2_OBITS) newmode |= value & set->bits;
            }
            break;
        case '+': newmode |= set->bits; break;
        case '-': newmode &= ~set->bits; break;
        case 'X':
            if (omode & (S_IFDIR | S_IXUSR | S_IXGRP | S_IXOTH)) newmode |= set->bits;
            break;
        case '\0':
        default:
            return newmode;
        }
    }
}

static BITCMD *addcmd(BITCMD *set, mode_t op, mode_t who, mode_t oparg, mode_t mask)
{
    switch (op) {
    case '=':
        set->cmd = '-';
        set->bits = who ? who : STANDARD_BITS;
        set++;
        op = '+';
        /* FALLTHROUGH */
    case '+':
    case '-':
    case 'X':
        set->cmd = op;
        set->bits = (who ? who : mask) & oparg;
        break;
    case 'u':
    case 'g':
    case 'o':
        set->cmd = op;
        if (who) {
            set->cmd2 = ((who & S_IRUSR) ? CMD2_UBITS : 0) | ((who & S_IRGRP) ? CMD2_GBITS : 0) |
                ((who & S_IROTH) ? CMD2_OBITS : 0);
            set->bits = (mode_t)~0;
        } else {
            set->cmd2 = CMD2_UBITS | CMD2_GBITS | CMD2_OBITS;
            set->bits = mask;
        }
        if (oparg == '+') set->cmd2 |= CMD2_SET;
        else if (oparg == '-') set->cmd2 |= CMD2_CLR;
        else if (oparg == '=') set->cmd2 |= CMD2_SET | CMD2_CLR;
        break;
    }
    return set + 1;
}

static void compress_mode(BITCMD *set)
{
    BITCMD *nset;
    int setbits, clrbits, Xbits, op;
    for (nset = set;;) {
        while ((op = nset->cmd) != '+' && op != '-' && op != 'X') {
            *set++ = *nset++;
            if (!op) return;
        }
        for (setbits = clrbits = Xbits = 0;; nset++) {
            if ((op = nset->cmd) == '-') {
                clrbits |= nset->bits;
                setbits &= ~nset->bits;
                Xbits &= ~nset->bits;
            } else if (op == '+') {
                setbits |= nset->bits;
                clrbits &= ~nset->bits;
                Xbits &= ~nset->bits;
            } else if (op == 'X') {
                Xbits |= nset->bits & ~setbits;
            } else {
                break;
            }
        }
        if (clrbits) { set->cmd = '-'; set->cmd2 = 0; set->bits = clrbits; set++; }
        if (setbits) { set->cmd = '+'; set->cmd2 = 0; set->bits = setbits; set++; }
        if (Xbits) { set->cmd = 'X'; set->cmd2 = 0; set->bits = Xbits; set++; }
    }
}

#define ADDCMD(a, b, c, d) \
    if (set >= endset) { \
        BITCMD *newset; \
        setlen += SET_LEN_INCR; \
        newset = realloc(saveset, sizeof(BITCMD) * setlen); \
        if (newset == NULL) goto out; \
        set = newset + (set - saveset); \
        saveset = newset; \
        endset = newset + (setlen - 2); \
    } \
    set = addcmd(set, (mode_t)(a), (mode_t)(b), (mode_t)(c), (d))

void *ios_system_setmode(const char *p)
{
    int equalopdone, setlen;
    char op, *ep;
    BITCMD *set, *saveset, *endset;
    mode_t mask = ~ios_system_umask(), perm, permXbits, who;
    long perml;

    if (!*p) return NULL;
    setlen = SET_LEN + 2;
    if ((set = malloc(setlen * sizeof(BITCMD))) == NULL) return NULL;
    saveset = set;
    endset = set + (setlen - 2);
    if (isdigit((unsigned char)*p)) {
        perml = strtol(p, &ep, 8);
        if (*ep || perml < 0 || perml & ~STANDARD_BITS) goto out;
        perm = (mode_t)perml;
        ADDCMD('=', STANDARD_BITS, perm, mask);
        set->cmd = 0;
        return saveset;
    }
    equalopdone = 0;
    for (;;) {
        for (who = 0;; ++p) {
            switch (*p) {
            case 'a': who |= STANDARD_BITS; break;
            case 'u': who |= S_ISUID | S_IRWXU; break;
            case 'g': who |= S_ISGID | S_IRWXG; break;
            case 'o': who |= S_IRWXO; break;
            default: goto getop;
            }
        }
    getop:
        if ((op = *p++) != '+' && op != '-' && op != '=') goto out;
        if (op == '=') equalopdone = 0;
        for (perm = 0, permXbits = 0;; ++p) {
            switch (*p) {
            case 'r': perm |= S_IRUSR | S_IRGRP | S_IROTH; break;
            case 's':
                if (!who || who & ~S_IRWXO) perm |= S_ISUID | S_ISGID;
                break;
            case 't':
                if (!who || who & ~S_IRWXO) perm |= S_ISTXT;
                break;
            case 'w': perm |= S_IWUSR | S_IWGRP | S_IWOTH; break;
            case 'X': permXbits = S_IXUSR | S_IXGRP | S_IXOTH; break;
            case 'x': perm |= S_IXUSR | S_IXGRP | S_IXOTH; break;
            case 'u':
            case 'g':
            case 'o':
                if (perm) { ADDCMD(op, who, perm, mask); perm = 0; }
                if (op == '=') equalopdone = 1;
                if (op == '+' && permXbits) { ADDCMD('X', who, permXbits, mask); permXbits = 0; }
                ADDCMD(*p, who, op, mask);
                break;
            default:
                if (perm || (op == '=' && !equalopdone)) {
                    if (op == '=') equalopdone = 1;
                    ADDCMD(op, who, perm, mask);
                    perm = 0;
                }
                if (permXbits) { ADDCMD('X', who, permXbits, mask); permXbits = 0; }
                goto apply;
            }
        }
    apply:
        if (!*p) break;
        if (*p != ',') goto getop;
        ++p;
    }
    set->cmd = 0;
    compress_mode(saveset);
    return saveset;
out:
    free(saveset);
    return NULL;
}
