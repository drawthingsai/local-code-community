#include <stddef.h>

extern __thread int caca_optind;
extern __thread char *caca_optarg;
extern int libcaca_img2txt_main(int, char **);

int img2txt_main(int argc, char **argv)
{
    caca_optind = 1;
    caca_optarg = NULL;
    return libcaca_img2txt_main(argc, argv);
}
