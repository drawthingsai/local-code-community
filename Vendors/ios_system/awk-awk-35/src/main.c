/****************************************************************
Copyright (C) Lucent Technologies 1997
All Rights Reserved

Permission to use, copy, modify, and distribute this software and
its documentation for any purpose and without fee is hereby
granted, provided that the above copyright notice appear in all
copies and that both that the copyright notice and this
permission notice and warranty disclaimer appear in supporting
documentation, and that the name Lucent Technologies or any of
its entities not be used in advertising or publicity pertaining
to distribution of the software without specific, written prior
permission.

LUCENT DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
IN NO EVENT SHALL LUCENT OR ANY OF ITS ENTITIES BE LIABLE FOR ANY
SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
****************************************************************/

static const char version[] = "version 20200816";

#define DEBUG
#include <stdio.h>
#include <ctype.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <wchar.h>
#include "awk.h"

// #ifdef __APPLE__
// #include "get_compat.h"
// #else
#define COMPAT_MODE(func, mode) 1
// #endif
#include <TargetConditionals.h>
#include "ios_system_support.h"

extern	char	**environ;
extern	__thread int	nfields;

__thread int	dbg	= 0;
__thread Awkfloat	srand_seed = 1;
__thread char	*cmdname;	/* gets argv[0] for error messages */
extern	__thread FILE	*yyin;	/* lex input file */
__thread char	*lexprog;	/* points to program argument if it exists */
extern	__thread int errorflag;	/* non-zero if any syntax errors; set by yyerror */
__thread enum compile_states	compile_time = ERROR_PRINTING;

static __thread char	**pfile;	/* program filenames from -f's */
static __thread size_t	maxpfile;	/* max program filename */
static __thread size_t	npfile;		/* number of filenames */
static __thread size_t	curpfile;	/* current filename */

__thread bool	safe = false;	/* true => "safe" mode */
__thread int	Unix2003_compat;

__thread malloc_zone_t *awk_zone;

char *awk_strdup(const char *string)
{
	size_t length = strlen(string) + 1;
	char *copy = malloc(length);
	return copy != NULL ? memcpy(copy, string, length) : NULL;
}

wchar_t *awk_wcsdup(const wchar_t *string)
{
	size_t length = (wcslen(string) + 1) * sizeof(wchar_t);
	wchar_t *copy = malloc(length);
	return copy != NULL ? memcpy(copy, string, length) : NULL;
}

void awk_free(void *pointer)
{
	if (pointer != NULL)
		malloc_zone_free(awk_zone, pointer);
}

/* iOS: SIGFPE is not caught (process-wide); awk's arithmetic is floating point. */
static void awk_cleanup(void *unused)
{
	extern __thread FILE *infile;
	pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
	awk_close_files();
	if (infile != NULL && infile != thread_stdin)
		fclose(infile);
	infile = NULL;
	if (yyin != NULL && yyin != thread_stdin)
		fclose(yyin);
	yyin = NULL;
	ios_system_support_cleanup(unused);
	if (awk_zone != NULL)
		malloc_destroy_zone(awk_zone);
	awk_zone = NULL;
}

/* Can this work with recursive calls?  I don't think so.
void segvcatch(int n)
{
	FATAL("segfault.  Do you have an unbounded recursive call?", n);
}
*/

static const char *
setfs(char *p)
{
	/* wart: t=>\t */
	if (p[0] == 't' && p[1] == '\0')
		return "\t";
	else if (p[0] != '\0')
		return p;
	return NULL;
}

static char *
getarg(int *argc, char ***argv, const char *msg)
{
	if ((*argv)[1][2] != '\0') {	/* arg is -fsomething */
		return &(*argv)[1][2];
	} else {			/* arg is -f something */
		(*argc)--; (*argv)++;
		if (*argc <= 1)
			FATAL("%s", msg);
		return (*argv)[1];
	}
}

int awk_main(int argc, char *argv[])
{
	const char *fs = NULL;
	char *fn, *vn;
	pthread_cleanup_push(awk_cleanup, NULL);
	ios_system_support_init(argv);
	if ((awk_zone = malloc_create_zone(0, 0)) == NULL)
		FATAL("out of memory");
	malloc_set_zone_name(awk_zone, "awk");
	/* Locale is owned by ios_system_support; numbers parse in "C". */
	locale_t locale = uselocale(NULL),
	    parse_locale = ios_system_locale_with(LC_NUMERIC_MASK, "C");
	if (parse_locale != NULL)
		uselocale(parse_locale);
	cmdname = argv[0];
	if (argc == 1) {
		fprintf(thread_stderr,
		  "usage: %s [-F fs] [-v var=value] [-f progfile | 'prog'] [file ...]\n",
		  cmdname);
		exit(1);
	}
	Unix2003_compat = COMPAT_MODE("bin/awk", "unix2003");
	/*signal(SIGSEGV, segvcatch); experiment */

	/* Set and keep track of the random seed */
	srand_seed = 1;
	ios_system_srandom((unsigned long) srand_seed);
	lex_init();

	yyin = NULL;
	symtab = makesymtab(NSYMTAB/NSYMTAB);
	while (argc > 1 && argv[1][0] == '-' && argv[1][1] != '\0') {
		if (strcmp(argv[1], "-version") == 0 || strcmp(argv[1], "--version") == 0) {
			fprintf(thread_stdout, "awk %s\n", version);
			exit(0);
		}
		if (strcmp(argv[1], "--") == 0) {	/* explicit end of args */
			argc--;
			argv++;
			break;
		}
		switch (argv[1][1]) {
		case 's':
			if (strcmp(argv[1], "-safe") == 0)
				safe = true;
			break;
		case 'f':	/* next argument is program filename */
			fn = getarg(&argc, &argv, "no program filename");
			if (npfile >= maxpfile) {
				maxpfile += 20;
				pfile = realloc(pfile, maxpfile * sizeof(*pfile));
				if (pfile == NULL)
					FATAL("error allocating space for -f options");
 			}
			pfile[npfile++] = fn;
 			break;
		case 'F':	/* set field separator */
			fs = setfs(getarg(&argc, &argv, "no field separator"));
			if (fs == NULL)
				WARNING("field separator FS is empty");
			break;
		case 'v':	/* -v a=1 to be done NOW.  one -v for each */
			vn = getarg(&argc, &argv, "no variable name");
			if (isclvar(vn))
				setclvar(vn);
			else
				FATAL("invalid -v option argument: %s", vn);
			break;
		case 'd':
			dbg = atoi(&argv[1][2]);
			if (dbg == 0)
				dbg = 1;
			fprintf(thread_stdout, "awk %s\n", version);
			break;
		default:
			WARNING("unknown option %s ignored", argv[1]);
			break;
		}
		argc--;
		argv++;
	}
	/* argv[1] is now the first argument */
	if (npfile == 0) {	/* no -f; first argument is program */
		if (argc <= 1) {
			if (dbg)
				exit(0);
			FATAL("no program given");
		}
		DPRINTF("program = |%s|\n", argv[1]);
		lexprog = argv[1];
		argc--;
		argv++;
	}
	recinit(recsize);
	syminit();
	compile_time = COMPILING;
	argv[0] = cmdname;	/* put prog name at front of arglist */
	DPRINTF("argc=%d, argv[0]=%s\n", argc, argv[0]);
	arginit(argc, argv);
	if (!safe)
		/* ios_system (on every platform): the session's environment, as getenv sees it. */
		envinit(environmentVariables(ios_currentPid()));
	yyparse();
	uselocale(locale); /* back to whatever it is locally */
	if (fs)
		*FS = qstring(fs, '\0');
	DPRINTF("errorflag=%d\n", errorflag);
	if (errorflag == 0) {
		compile_time = RUNNING;
		run(winner);
        winner = NULL;
	} else
		bracecheck();
	exit(errorflag);
	pthread_cleanup_pop(1);
	return 0;
}

int pgetc(void)		/* get 1 character from awk program */
{
	int c;

	for (;;) {
		if (yyin == NULL) {
			if (curpfile >= npfile)
				return EOF;
			if (strcmp(pfile[curpfile], "-") == 0)
				yyin = thread_stdin;
			else if ((yyin = ios_system_fopen(pfile[curpfile], "r")) == NULL)
				FATAL("can't open file %s", pfile[curpfile]);
			lineno = 1;
		}
		if ((c = getc(yyin)) != EOF)
			return c;
		if (yyin != thread_stdin)
			fclose(yyin);
		yyin = NULL;
		curpfile++;
	}
}

char *cursource(void)	/* current source file name */
{
	if (npfile > 0)
		return pfile[curpfile < npfile ? curpfile : curpfile - 1];
	else
		return NULL;
}
