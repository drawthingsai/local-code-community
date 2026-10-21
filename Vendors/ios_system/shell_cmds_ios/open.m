//
//  openurl.m
//  ios_system
//
//  Created by Nicolas Holzschuch on 11/01/2019.
//  Copyright © 2019 Nicolas Holzschuch. All rights reserved.
//
#include <stdio.h>
#include "ios_system/ios_system.h"
#include "ios_error.h"

#import <Foundation/Foundation.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define IOS_SYSTEM_OPEN_HAS_UIKIT 1
#else
#define IOS_SYSTEM_OPEN_HAS_UIKIT 0
#endif

#if IOS_SYSTEM_OPEN_HAS_UIKIT

static const NSUInteger kMaximumOpenURLLength = 4096;
static UIAlertController *currentOpenURLConfirmation = nil;

static NSURL *validatedOpenURL(const char *argument) {
  if (argument == NULL) {
    return nil;
  }

  NSString *urlString = [NSString stringWithCString:argument encoding:NSUTF8StringEncoding];
  if (urlString.length == 0 || urlString.length > kMaximumOpenURLLength) {
    return nil;
  }

  NSMutableCharacterSet *disallowedCharacters = [NSCharacterSet.controlCharacterSet mutableCopy];
  [disallowedCharacters formUnionWithCharacterSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  [disallowedCharacters addCharactersInString:@"\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069"];
  if ([urlString rangeOfCharacterFromSet:disallowedCharacters].location != NSNotFound) {
    return nil;
  }

  NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
  NSString *scheme = components.scheme.lowercaseString;
  if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
      components.host.length == 0 || components.user.length > 0 || components.password.length > 0) {
    return nil;
  }
  return components.URL;
}

static UIWindow *foregroundWindow(void) {
  UIWindow *fallbackWindow = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (scene.activationState != UISceneActivationStateForegroundActive ||
        ![scene isKindOfClass:UIWindowScene.class]) {
      continue;
    }
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isKeyWindow) {
        return window;
      }
      if (fallbackWindow == nil && !window.isHidden && window.alpha > 0 &&
          window.rootViewController != nil) {
        fallbackWindow = window;
      }
    }
  }
  return fallbackWindow;
}

static UIViewController *topViewController(UIViewController *viewController) {
  if (viewController.presentedViewController != nil &&
      !viewController.presentedViewController.isBeingDismissed) {
    return topViewController(viewController.presentedViewController);
  }
  if ([viewController isKindOfClass:UINavigationController.class]) {
    return topViewController(((UINavigationController *)viewController).visibleViewController);
  }
  if ([viewController isKindOfClass:UITabBarController.class]) {
    return topViewController(((UITabBarController *)viewController).selectedViewController);
  }
  return viewController;
}

static void requestOpenURL(NSURL *locationURL) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIApplication *application = UIApplication.sharedApplication;
    if (![application canOpenURL:locationURL]) {
      return;
    }
    if (currentOpenURLConfirmation != nil) {
      if (currentOpenURLConfirmation.presentingViewController != nil ||
          currentOpenURLConfirmation.isBeingPresented) {
        return;
      }
      currentOpenURLConfirmation = nil;
    }

    UIWindow *window = foregroundWindow();
    UIViewController *viewController = topViewController(window.rootViewController);
    if (viewController == nil || [viewController isKindOfClass:UIAlertController.class]) {
      return;
    }

    NSString *message = [NSString
        stringWithFormat:@"A shell command requested to open %@ in your browser or an associated app.\n\n%@",
                         locationURL.host, locationURL.absoluteString];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Open External URL?"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
                                              currentOpenURLConfirmation = nil;
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
                                              currentOpenURLConfirmation = nil;
                                              // Do not expose the user's choice or UIKit's result to the shell caller.
                                              [application openURL:locationURL
                                                           options:@{}
                                                 completionHandler:nil];
                                            }]];
    currentOpenURLConfirmation = alert;
    [viewController presentViewController:alert animated:YES completion:nil];
  });
}

// MARK: - URL

int openurl_main(int argc, char *argv[]) {
  NSString *usage = @"Usage: openurl https://example.com\nOnly absolute HTTP and HTTPS URLs without credentials are supported.";

  if ((argc == 2) && ((strcmp(argv[1], "-h") == 0) || (strcmp(argv[1], "--help") == 0))) {
    fprintf(thread_stdout, "%s\n", usage.UTF8String);
    return 0;
  }
  if (argc != 2) {
    fprintf(thread_stderr, "openurl: exactly one URL is required\n");
    fprintf(thread_stderr, "%s\n", usage.UTF8String);
    return 1;
  }
  NSURL *locationURL = validatedOpenURL(argv[1]);
  if (locationURL == nil) {
    fprintf(thread_stderr,
            "openurl: only absolute HTTP and HTTPS URLs without credentials are supported\n");
    return 1;
  }

  fprintf(thread_stdout,
          "Open-URL request submitted for user approval. Its outcome is intentionally not reported.\n");
  requestOpenURL(locationURL);
  return 0;
}

void display_alert(NSString* title, NSString* message) {
  dispatch_async(dispatch_get_main_queue(), ^{
    
    UIWindow *window = foregroundWindow();
    
    if (!window) {
      return;
    }
    
    UIViewController *topController = topViewController(window.rootViewController);
    
    if (topController == NULL) {
      return;
    }
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                   message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
     
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
       handler:^(UIAlertAction * action) {}];
     
    [alert addAction:defaultAction];
    [topController presentViewController:alert animated:YES completion:nil];
  });
  return;
}

#else

int openurl_main(int argc, char *argv[]) {
  fprintf(thread_stderr, "openurl: unavailable in this ios_system build\n");
  return 1;
}

void display_alert(NSString* title, NSString* message) {
  fprintf(thread_stderr != NULL ? thread_stderr : stderr, "%s: %s\n",
          title.UTF8String ?: "",
          message.UTF8String ?: "");
}

#endif
