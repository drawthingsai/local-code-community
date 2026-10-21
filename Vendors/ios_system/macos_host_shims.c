#include <stdbool.h>
#include <TargetConditionals.h>

#if TARGET_OS_OSX
bool have_openssl(void) {
    return false;
}
#endif
