#import "ios_system/ios_system.h"

#include <stdio.h>

// Office.xcframework has no iOS Simulator slice; keep the registry entry linkable there.
int office_main(int argc, char **argv)
{
    fputs("office: not available on the iOS Simulator\n", thread_stderr);
    return 1;
}
