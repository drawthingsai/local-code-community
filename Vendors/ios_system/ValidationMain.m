#import <UIKit/UIKit.h>

#include "NativeCommandValidation.h"

@interface IOSSystemValidationAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation IOSSystemValidationAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = ios_validateNativeCommands();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.window.rootViewController.view.backgroundColor =
                status == 0 ? UIColor.systemGreenColor : UIColor.systemRedColor;
        });
    });
    return YES;
}

@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([IOSSystemValidationAppDelegate class]));
    }
}
