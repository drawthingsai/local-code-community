#include <stddef.h>

extern int caca_optind;
extern char *caca_optarg;
extern int libcaca_img2txt_main(int, char **);

int img2txt_main(int argc, char **argv)
{
    caca_optind = 1;
    caca_optarg = NULL;
    return libcaca_img2txt_main(argc, argv);
}
