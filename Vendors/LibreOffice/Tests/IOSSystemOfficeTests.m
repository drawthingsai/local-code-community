#import <Foundation/Foundation.h>
#import "ios_system/ios_system.h"
#include <TargetConditionals.h>

extern int office_main(int, char **);

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; \
} } while (0)

int main(int argc, const char **argv)
{
    @autoreleasepool {
        CHECK(argc == 2 || argc == 3); // [resource root] fixture directory
        ios_setStreams(stdin, stdout, stderr);
        char *help[] = {"office", "--help"};
        CHECK(office_main(2, help) == 0); // No session or resource path needed.
        char *capabilities[] = {"office", "capabilities"};
        CHECK(office_main(2, capabilities) == 0);
        initializeEnvironment();
        CHECK(ios_executable("office"));
        CHECK(ios_commandIsExclusiveOrThreadSafe("/usr/bin/office") ==
            IOS_COMMAND_ISOLATION_EXCLUSIVE_LIBREOFFICE);
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        CHECK([fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *bundle = argc == 2 ? NSBundle.mainBundle.resourceURL
            : [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *fixtures = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[argc - 1]] isDirectory:YES];
        CHECK([fm fileExistsAtPath:[bundle URLByAppendingPathComponent:
#if TARGET_OS_IPHONE
            @"office/share/registry/main.xcd"].path]);
#else
            @"office/Resources/registry/main.xcd"].path]);
#endif
        for (NSString *name in @[@"input document.docx", @"input workbook.xlsx", @"input slides.pptx"]) {
            CHECK([fm copyItemAtURL:[fixtures URLByAppendingPathComponent:name]
                toURL:[root URLByAppendingPathComponent:name] error:nil]);
        }
        ios_setStreams(stdin, stdout, stderr);
        CHECK(ios_setSystemPaths(root, root, root, root, root, bundle));
        ios_setDirectoryURL(root);
        // Registry dispatch, session path aliases, output redirection, failure
        // recovery, and a second invocation on a different command pthread.
        CHECK(ios_system_osh("office --help > help.txt") == 0);
        CHECK(ios_system_osh("office convert --input missing.docx --output missing.pdf 2> early-failure.json") != 0);
        CHECK(ios_system_osh("office convert --input '/home/input document.docx' "
            "--output /tmp/result.pdf > result.json") == 0);
        NSData *pdf = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"tmp/result.pdf"]];
        CHECK(pdf.length > 5 && !memcmp(pdf.bytes, "%PDF-", 5));
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"result.json"]]
            options:0 error:nil];
        CHECK([result[@"ok"] boolValue]);
        CHECK([result[@"outputPath"] isEqualToString:@"/tmp/result.pdf"]);
        CHECK(ios_system_osh("office render --input '/home/input document.docx' --output-dir /tmp/pages --pages 2,1 > rendered.json") == 0);
        NSDictionary *rendered = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"rendered.json"]] options:0 error:nil];
        CHECK([rendered[@"inputPath"] isEqualToString:@"/home/input document.docx"]);
        CHECK([rendered[@"images"][0][@"path"] isEqualToString:@"/tmp/pages/page-0001.png"]);
        CHECK([rendered[@"images"][0][@"page"] intValue] == 2);
        NSData *png = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"tmp/pages/page-0001.png"]];
        CHECK(png.length > 8 && !memcmp(png.bytes, "\211PNG\r\n\032\n", 8));
        CHECK(ios_system_osh("office convert --input missing.docx --output missing.pdf 2> failure.json") != 0);
        CHECK(ios_system_osh("office convert --input 'input document.docx' --output second.pdf > second.json") == 0);
        CHECK([fm fileExistsAtPath:[root URLByAppendingPathComponent:@"second.pdf"].path]);
        CHECK(ios_system_osh("office convert --input 'input workbook.xlsx' --output workbook.pdf > workbook.json") == 0);
        CHECK(ios_system_osh("office convert --input 'input slides.pptx' --output slides.pdf > slides.json") == 0);
        for (NSString *name in @[@"workbook.pdf", @"slides.pdf"]) {
            NSData *data = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:name]];
            CHECK(data.length > 5 && !memcmp(data.bytes, "%PDF-", 5));
        }
        CHECK([fm removeItemAtURL:root error:nil]);
        fprintf(stderr, "Office static registry, path aliases, redirection and repeated calls passed.\n");
        fflush(NULL);
        _Exit(0); // The engine is process-owned; the test host terminates here.
    }
}
