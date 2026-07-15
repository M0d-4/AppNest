@import UIKit;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"
#import "../LiveProcess/LiveProcessHandler.h"
#import "../MultitaskSupport/UIKitPrivate+MultitaskSupport.h"

extern void _objc_msgForward(void);
@interface LCRealIPhoneModeHelper : NSObject
+ (void)repositionAllWindows;
@end
// Shared Real iPhone Mode crop helpers (defined alongside the UIWindow hooks
// further down this file) — forward-declared here so LCRealIPhoneModeHelper,
// which appears earlier in the file, can use them too.
static BOOL LCShouldApplyRealIPhoneModeCrop(UIWindow *window);
static CGRect LCRealIPhoneModeCroppedFrame(CGRect frame);
UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
BOOL strictTestMode = NO;
UIPasteboard *strictPrivatePasteboard = nil;
BOOL launchURLProcessed = NO;

@interface LCNetworkExtensionStrictHookProvider : NSObject
@end

static void LCSwizzleClassIfPresent(Class cls, SEL originalAction, SEL swizzledAction) {
    if(!cls) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, originalAction);
    Method swizzledMethod = class_getClassMethod(cls, swizzledAction);
    if(originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void LCSwizzleIfPresent(Class cls, SEL originalAction, SEL swizzledAction) {
    if(!cls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, originalAction);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledAction);
    if(originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void LCSwizzleClassIfPresentWithSourceClass(Class cls, Class sourceCls, SEL originalAction, SEL swizzledAction) {
    if(!cls || !sourceCls) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, originalAction);
    Method sourceMethod = class_getClassMethod(sourceCls, swizzledAction);
    if(!originalMethod || !sourceMethod) {
        return;
    }
    Class metaClass = object_getClass((id)cls);
    class_addMethod(
        metaClass,
        swizzledAction,
        method_getImplementation(sourceMethod),
        method_getTypeEncoding(sourceMethod)
    );
    Method swizzledMethod = class_getClassMethod(cls, swizzledAction);
    if(swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// Plain method_exchangeImplementations (what `swizzle()` uses) is only safe when
// `cls` directly overrides `originalAction` itself. If `originalAction` is only
// ever inherited (e.g. -layoutSubviews, which UIWindow may not concretely
// override — it could just be UIView's implementation resolved via inheritance),
// exchanging it swaps the implementation at whichever class actually defines
// it, which could be the shared superclass — silently affecting every instance
// of that superclass, not just `cls`. class_addMethod first guarantees `cls`
// gets its own copy of the original implementation before the swap, so the
// exchange is scoped to exactly `cls` regardless of where it was inherited from.
static void LCSwizzleInstanceMethodSafely(Class cls, SEL originalAction, SEL swizzledAction) {
    if (!cls) return;
    Method originalMethod = class_getInstanceMethod(cls, originalAction);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledAction);
    if (!originalMethod || !swizzledMethod) return;

    BOOL didAddOriginal = class_addMethod(cls, originalAction,
                                           method_getImplementation(originalMethod),
                                           method_getTypeEncoding(originalMethod));
    if (didAddOriginal) {
        // cls didn't have its own copy — class_addMethod just gave it one.
        // Re-fetch so we exchange against that new copy, not the inherited one.
        originalMethod = class_getInstanceMethod(cls, originalAction);
    }
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

//⭐️⭐️⭐️⤵️
static void Real_UIKitGuestHooksInit(void);
static NSString *const LCExternalURLBlockBypassDepthKey = @"LCExternalURLBlockBypassDepth";

static BOOL LCIsExternalURLBlockBypassed(void) {
    NSNumber *depth = NSThread.currentThread.threadDictionary[LCExternalURLBlockBypassDepthKey];
    return depth.integerValue > 0;
}

static void LCWithExternalURLBlockBypass(void (^block)(void)) {
    if (!block) {
        return;
    }
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    NSInteger depth = [threadDictionary[LCExternalURLBlockBypassDepthKey] integerValue];
    threadDictionary[LCExternalURLBlockBypassDepthKey] = @(depth + 1);
    block();
    depth = [threadDictionary[LCExternalURLBlockBypassDepthKey] integerValue] - 1;
    if (depth <= 0) {
        [threadDictionary removeObjectForKey:LCExternalURLBlockBypassDepthKey];
    } else {
        threadDictionary[LCExternalURLBlockBypassDepthKey] = @(depth);
    }
}

static NSSet<NSString *> *LCBlockedExternalURLSchemes(void) {
    static NSSet<NSString *> *blockedSchemes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blockedSchemes = [NSSet setWithArray:@[
            @"github",
            @"sidestore",
            @"livecontainer",
            // TODO: Shadowrocket
        ]];
    });
    return blockedSchemes;
}

static BOOL LCShouldBlockExternalURL(NSURL *url) {
    if (!url || LCIsExternalURLBlockBypassed()) {
        return NO;
    }
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme.length == 0) {
        return NO;
    }
    return [LCBlockedExternalURLSchemes() containsObject:scheme];
}

static UIWindowScene *LCForegroundWindowScene(void) {
    UIWindowScene *fallbackScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (!fallbackScene) {
            fallbackScene = windowScene;
        }
    }
    return fallbackScene;
}

static UIWindow *LCKeyWindowForScene(UIWindowScene *scene) {
    if (!scene) {
        return nil;
    }
    UIWindow *keyWindow = scene.keyWindow;
    if (keyWindow) {
        return keyWindow;
    }
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return scene.windows.firstObject;
}

static UIWindowLevel LCOverlayWindowLevel(void) {
    UIWindow *keyWindow = LCKeyWindowForScene(LCForegroundWindowScene());
    return (keyWindow ? keyWindow.windowLevel : UIWindowLevelNormal) + 1;
}

__attribute__((constructor))
static void UIKitGuestHooksInit(void) {
    //NSString *AppId = [NSUserDefaults lcGuestAppId];
    //if ([AppId.lowercaseString containsString:@"sidestore"]) {
        //dispatch_async(dispatch_get_main_queue(), ^{
            //Real_UIKitGuestHooksInit();
        //});
    //} else {
       Real_UIKitGuestHooksInit();
    //}
}

//⭐️⭐️⭐️⤴️

static void Real_UIKitGuestHooksInit(void) {
    NSString *lcGuestAppId = NSUserDefaults.lcGuestAppId;
    if(!NSUserDefaults.lcGuestAppId) return;

    // Always install these hooks (unless SideStore); each hook checks the live
    // value of LCRealIPhoneMode itself, so toggling the setting per app takes
    // effect immediately without depending on the flag's value at process start.
    NSString *forceIPhoneAppId = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [forceIPhoneAppId.lowercaseString containsString:@"sidestore"];
    if (!isSideStore) {
        NSLog(@"[ForceIPhoneMode] init for appId=%@ LCRealIPhoneMode=%d", lcGuestAppId,
              [NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]);
        swizzle(UIWindow.class, @selector(setFrame:), @selector(hook_setFrame:));
        swizzle(UIScreen.class, @selector(bounds), @selector(hook_UIScreen_bounds));
        // Scene-managed windows are sized directly by the window scene (or, in
        // multitask, by the host sending FBSSceneSettings over XPC) and often
        // never call the public -setFrame: setter at all, so the swizzle above
        // alone doesn't reliably fire for them in either single-app or
        // multitask launches. -layoutSubviews fires reliably any time a
        // window's size is touched regardless of how it got there, so
        // re-asserting the constrained frame there catches that case too.
        // Setting .frame from inside it routes back through hook_setFrame
        // above, which is idempotent.
        // Uses the safe variant: UIWindow likely doesn't concretely override
        // -layoutSubviews itself (it'd just resolve to UIView's), and a plain
        // exchange in that case would swap UIView's shared implementation —
        // affecting every view in the app, not just windows.
        LCSwizzleInstanceMethodSafely(UIWindow.class, @selector(layoutSubviews), @selector(hook_layoutSubviews));
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [LCRealIPhoneModeHelper repositionAllWindows];
            });
        }];
        // WillEnterForeground only fires on background->foreground transitions,
        // not on a cold launch — DidBecomeActive fires in both cases, so this
        // is a second chance to apply the crop if the initial -setFrame:/
        // -layoutSubviews pass ran before geometry had settled.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [LCRealIPhoneModeHelper repositionAllWindows];
            });
        }];
        // Extra enforcement point for newer iOS/iPadOS versions that may
        // route a standalone app's own scene geometry through FBScene's
        // private settings-update mechanism (mirroring the merged host-side
        // fix for the same private method, used there for safe area insets
        // on iOS 27). Guarded defensively: only installed if the class and
        // selector actually exist at runtime, so this is a no-op rather than
        // a crash risk on versions where they don't.
        if (@available(iOS 17.0, *)) {
            Class fbSceneClass = PrivClass(FBScene);
            if (fbSceneClass && [fbSceneClass instancesRespondToSelector:@selector(_performUpdateWithoutActivation:)]) {
                swizzle(fbSceneClass, @selector(_performUpdateWithoutActivation:), @selector(hook__performUpdateWithoutActivation:));
            }
        }
    }

    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
            swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }

    }
    if(@available(iOS 17.0, *)) {
        if(NSUserDefaults.isLiveProcess) {
            swizzle(_UIRemoteKeyboards.class, @selector(startConnection), @selector(hook_startConnection));
        }
    }

    NSDictionary* guestContainerInfo = [NSUserDefaults guestContainerInfo];
    strictTestMode = [guestContainerInfo[@"strictTestMode"] boolValue];
    if(strictTestMode) {
        strictPrivatePasteboard = [UIPasteboard pasteboardWithUniqueName];
        LCSwizzleClassIfPresent(UIPasteboard.class, @selector(generalPasteboard), @selector(hook_generalPasteboard));
        LCSwizzleIfPresent(NSURLSessionTask.class, @selector(resume), @selector(hook_resume));
        Class hotspotNetworkClass = NSClassFromString(@"NEHotspotNetwork");
        LCSwizzleClassIfPresentWithSourceClass(
            hotspotNetworkClass,
            LCNetworkExtensionStrictHookProvider.class,
            @selector(fetchCurrentWithCompletionHandler:),
            @selector(hook_fetchCurrentWithCompletionHandler:)
        );
    }
}

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcDocFolder = [[NSString stringWithUTF8String:getenv("LC_HOME_PATH")] stringByAppendingPathComponent:@"Documents"];
        
        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }
    
    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
        __block BOOL isInstalled = NO;
        LCWithExternalURLBlockBypass(^{
            isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://", scheme]]];
        });
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    
    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            LCWithExternalURLBlockBypass(^{
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            });
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }
    
    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    
    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                LCWithExternalURLBlockBypass(^{
                    [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                });
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = LCOverlayWindowLevel();
    window.windowScene = LCForegroundWindowScene();
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = LCOverlayWindowLevel();
    window.windowScene = LCForegroundWindowScene();
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if (LCShouldBlockExternalURL(urlToOpen)) {
        NSLog(@"[LC] Blocked external URL scheme: %@", urlToOpen.scheme);
        return;
    }
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        
        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];
        LCWithExternalURLBlockBypass(^{
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        });
        return;
    }
    
    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };
    
    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }
    
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        LCWithExternalURLBlockBypass(^{
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        });
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }
    
    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            LCWithExternalURLBlockBypass(^{
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            });
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });
    
    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = LCOverlayWindowLevel();
    window.windowScene = LCForegroundWindowScene();
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    

}

void LCOpenSideStoreURL(NSURL* sidestoreUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }];
    [alert addAction:okAction];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = LCOverlayWindowLevel();
    window.windowScene = LCForegroundWindowScene();
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            LCWithExternalURLBlockBypass(^{
                [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            });
            return;
        }
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }
        
        if(!bundle) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }
    
}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

BOOL strictModeAllowsOpenURL(NSURL *url) {
    if(!strictTestMode) {
        return YES;
    }
    if(!url) {
        return NO;
    }
    if(canAppOpenItself(url)) {
        return YES;
    }
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:NSUserDefaults.lcAppUrlScheme.lowercaseString];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];
    
}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    // pass through sidestore urls
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        return LCControlAppURLHandlingPassThrough;
    }

    if([url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(url);
        return LCControlAppURLHandlingStop;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme]) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;
    
    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }
    
    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }
        
        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"LiveContainer", false);
            return LCControlAppURLHandlingStop;
        }
        
        NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches OR sidestore is running and we are launching builtinSideStore
        if (([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) ||
            (NSUserDefaults.isSideStore && [bundleName isEqualToString:@"builtinSideStore"])) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            if([bundleName isEqualToString:@"builtinSideStore"]) {
                LCShowSwitchAppConfirmation(url, @"SideStore", NO);
                return LCControlAppURLHandlingStop;
            }
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }
        
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;
        
    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme]) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }
    
    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }
        
        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
        context.payload = newDict;
        
        
        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }
        
        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];
        
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;
        
    } while(0);
    
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

-(BOOL)hook__handleDelegateCallbacksWithOptions:(id)arg1 isSuspended:(BOOL)arg2 restoreState:(BOOL)arg3 {
    BOOL ans = [self hook__handleDelegateCallbacksWithOptions:arg1 isSuspended:arg2 restoreState:arg3];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:@"com.apple.springboard"];
            [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
        });

    });


    return ans;
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    if(strictTestMode) {
        BOOL allowed = strictModeAllowsOpenURL(url);
        if(!allowed) {
            if(completion) {
                completion(NO);
            }
            return;
        }
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }

    // When running as built-in SideStore, pass ALL URLs straight through — including
    // livecontainer:// which is otherwise in the blocked list. relaunchLC needs it.
    // This check must come BEFORE LCShouldBlockExternalURL.
    if(NSUserDefaults.isSideStore) {
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }
    if (LCShouldBlockExternalURL(url)) {
        NSLog(@"[LC] Blocked external URL scheme: %@", url.scheme);
        if (completion) {
            completion(NO);
        }
        return;
    }
    
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    if(strictTestMode) {
        return strictModeAllowsOpenURL(url);
    }
    // When running as built-in SideStore pass through directly — livecontainer://
    // is in the blocked list but SideStore needs it for relaunchLC.
    // This check must come BEFORE LCShouldBlockExternalURL.
    if (NSUserDefaults.isSideStore) {
        return [self hook_canOpenURL:url];
    }
    if (LCShouldBlockExternalURL(url)) {
        return NO;
    }
    return canAppOpenItself(url) || shouldRedirectOpenURLToHost(url) || [self hook_canOpenURL:url];
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
        swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
        swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
        // Fix apps that do not support UISceneDelegate getting 0 status bar frame
        swizzle(UIApplication.class, @selector(statusBarFrame), @selector(hook_statusBarFrame));
    }
    [self hook_setDelegate:delegate];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame {
    UIStatusBarManager* manager = [(UIWindowScene*)(UIApplication.sharedApplication.connectedScenes.anyObject) statusBarManager];
    if(manager) {
        return manager.statusBarFrame;
    } else {
        return [self hook_statusBarFrame];
    }
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    if(strictTestMode) {
        BOOL allowed = strictModeAllowsOpenURL(url);
        if(!allowed) {
            if(completion) {
                completion(NO);
            }
            return;
        }
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }

    if (LCShouldBlockExternalURL(url)) {
        NSLog(@"[LC] Blocked external URL scheme: %@", url.scheme);
        if (completion) {
            completion(NO);
        }
        return;
    }
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations {
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }

}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation {
    return YES;
}

@end

@implementation UIScreen (LiveContainerHook)
- (CGRect)hook_UIScreen_bounds {
    NSString *appId = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [appId.lowercaseString containsString:@"sidestore"];
    CGRect nativeBounds = [self hook_UIScreen_bounds];
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"] && !isSideStore) {
        CGFloat screenH = nativeBounds.size.height;
        CGFloat screenW = nativeBounds.size.width;
        CGFloat targetW = MIN(screenW, screenH * (9.0 / 16.0));
        return CGRectMake(0, 0, targetW, screenH);
    }
    return CGRectMake(0, 0, nativeBounds.size.width, nativeBounds.size.height);
}
@end

@implementation LCRealIPhoneModeHelper
+ (void)repositionAllWindows {
    UIWindowScene *scene = nil;
    for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            scene = s;
            break;
        }
    }
    if (!scene) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIWindow *window in scene.windows) {
        // Reuses the exact same eligibility check (feature on, not
        // SideStore, main window only, and — importantly — skipped
        // entirely under multitask, where the host does its own
        // centering) as the -setFrame:/-layoutSubviews hooks, so
        // foregrounding can't apply different logic than everyday
        // resizes do.
        if (!LCShouldApplyRealIPhoneModeCrop(window)) continue;
        CGRect targetFrame = LCRealIPhoneModeCroppedFrame(window.frame);
        window.layer.frame = targetFrame;
    }
    [CATransaction commit];
}
@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    NSString *appid = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [appid.lowercaseString containsString:@"sidestore"];
    BOOL isMainAppWindow = (self.windowLevel == UIWindowLevelNormal);
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"] && !isSideStore && isMainAppWindow) {
        self.backgroundColor = [UIColor blackColor];
    }
    // Belt-and-suspenders: -layoutSubviews and -setFrame: both depend on
    // something touching the window's geometry after it exists. The very
    // first time a window is shown, especially outside multitask where
    // there's no host-side FBSSceneSettings round-trip to piggyback on,
    // that isn't guaranteed to happen before the window is actually on
    // screen — so also enforce the crop right here, at the one point
    // that's called exactly once the window is about to become visible.
    // (This swizzle is only installed for apps whose delegate doesn't
    // implement the modern scene APIs — see hook_setDelegate: below —
    // so -layoutSubviews above remains the primary catch-all for the
    // common, scene-delegate case.)
    if (LCShouldApplyRealIPhoneModeCrop(self)) {
        CGRect targetFrame = LCRealIPhoneModeCroppedFrame(self.frame);
        NSLog(@"[ForceIPhoneMode] hook_makeKeyAndVisible currentFrame=%@ targetFrame=%@",
              NSStringFromCGRect(self.frame), NSStringFromCGRect(targetFrame));
        if (fabs(self.frame.size.width - targetFrame.size.width) >= 0.5) {
            self.frame = targetFrame;
        }
    }
    [self hook_makeKeyAndVisible];
}

// Shared decision: does this window need the Real iPhone Mode crop applied
// by *this* (guest) process at all? False for SideStore, non-main windows,
// and — critically — for any window running under the multitask host. The
// multitask host (AppSceneViewController) does its own centering using the
// tile's actual bounds, which the guest process has no way to know; letting
// the guest also crop on top of that double-applies the offset and is what
// made the multitask crop appear off-center.
static BOOL LCShouldApplyRealIPhoneModeCrop(UIWindow *window) {
    if (![NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) return NO;
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCIsMultitaskLaunch"]) return NO;
    NSString *lcappid = NSUserDefaults.lcGuestAppId;
    if ([lcappid.lowercaseString containsString:@"sidestore"]) return NO;
    if (window.windowLevel != UIWindowLevelNormal) return NO;
    return YES;
}

// Computes the centered 9:16 crop of `frame`. Idempotent: feeding an
// already-cropped rect back in returns the same rect unchanged.
static CGRect LCRealIPhoneModeCroppedFrame(CGRect frame) {
    CGFloat availW = frame.size.width;
    CGFloat availH = frame.size.height;
    if (availW <= 0 || availH <= 0) return frame;
    CGFloat targetW = MIN(availW, availH * (9.0 / 16.0));
    CGFloat offsetX = frame.origin.x + (availW - targetW) / 2.0;
    return CGRectMake(offsetX, frame.origin.y, targetW, availH);
}

- (void)hook_setFrame:(CGRect)frame {
    BOOL shouldForce = LCShouldApplyRealIPhoneModeCrop(self);
    NSLog(@"[ForceIPhoneMode] hook_setFrame called requestedFrame=%@ windowLevel=%f shouldForce=%d",
          NSStringFromCGRect(frame), self.windowLevel, shouldForce);

    // Anything that doesn't need the crop — feature off, SideStore, a
    // non-main window (overlays, alerts, multitask chrome, etc.), or a
    // window the multitask host is already cropping itself — must pass
    // through untouched. Previously this branch substituted a hardcoded
    // full-screen rect for *any* uncropped case, which stomped on every
    // other window's real geometry (including multitask tile assignments),
    // silently breaking layout well beyond just this feature.
    if (!shouldForce) {
        [self hook_setFrame:frame];
        return;
    }

    // Constrain to a 9:16 aspect within whatever area was actually being
    // requested (the full screen for a normal launch — multitask windows
    // are excluded above, since the host handles those itself).
    [self hook_setFrame:LCRealIPhoneModeCroppedFrame(frame)];
}

// Scene-managed windows are often never explicitly sent -setFrame: at all —
// the scene sizes them directly — so hook_setFrame above never fires for
// them. -layoutSubviews IS called reliably any time the window's size is
// touched (initial presentation, rotation, scene geometry changes), so
// re-assert the constrained frame here too. Setting .frame routes back
// through the hook_setFrame swizzle above, which is idempotent, so this
// can't loop.
- (void)hook_layoutSubviews {
    [self hook_layoutSubviews];
    if (!LCShouldApplyRealIPhoneModeCrop(self)) return;

    CGRect currentFrame = self.frame;
    CGRect targetFrame = LCRealIPhoneModeCroppedFrame(currentFrame);
    NSLog(@"[ForceIPhoneMode] hook_layoutSubviews currentFrame=%@ targetFrame=%@",
          NSStringFromCGRect(currentFrame), NSStringFromCGRect(targetFrame));
    // Already constrained (or converged to) the target — nothing to do.
    // Guards against re-triggering ourselves via the .frame set below.
    if (fabs(currentFrame.size.width - targetFrame.size.width) < 0.5) return;

    self.frame = targetFrame;
}

- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_resignKeyWindow {
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    for(UIWindowScene *windowScene in UIApplication.sharedApplication.connectedScenes) {
        if(!self.windowScene && self.screen == windowScene.screen) {
            self.windowScene = windowScene;
            break;
        }
    }
}
@end

// Newer iOS/iPadOS versions have been progressively moving window geometry
// updates through FBScene's private settings-update mechanism instead of the
// public -setFrame:/-layoutSubviews path (the merged upstream fix for safe
// area insets on iOS 27 hooks the exact same method, host-side, for the
// same reason). If a standalone app's own primary scene is *also* now
// funneled through here on some iPadOS versions — rather than only
// multitask-hosted ones — hooking it here too re-asserts the crop at a
// point that isn't dependent on -setFrame:/-layoutSubviews firing at all.
// Purely additive and defensively guarded: does nothing if the selector
// isn't present, and LCShouldApplyRealIPhoneModeCrop already excludes
// multitask launches (the host handles those), SideStore, and non-main
// windows, same as every other enforcement point above.
@implementation FBScene(LCForceIPhoneMode)
- (void)hook__performUpdateWithoutActivation:(void (^)(UIMutableApplicationSceneSettings *, FBSSceneTransitionContext *))updateBlock API_AVAILABLE(ios(17.0)) {
    id wrappedBlock = ^(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context) {
        updateBlock(settings, context);
        UIWindow *mainWindow = LCKeyWindowForScene(LCForegroundWindowScene());
        if (mainWindow && LCShouldApplyRealIPhoneModeCrop(mainWindow)) {
            CGRect cropped = LCRealIPhoneModeCroppedFrame(settings.frame);
            NSLog(@"[ForceIPhoneMode] hook__performUpdateWithoutActivation currentFrame=%@ croppedFrame=%@",
                  NSStringFromCGRect(settings.frame), NSStringFromCGRect(cropped));
            settings.frame = cropped;
        }
    };
    [self hook__performUpdateWithoutActivation:wrappedBlock];
}
@end

static id<LCMultitaskXPCServiceProtocol> server;
@implementation _UIRemoteKeyboards(hook)
// from UIKeyboardArbitration proxy
- (void)hook_focusApplicationWithProcessIdentifier:(int)pid context:(UIKBArbiterClientFocusContext *)context stealingKeyboard:(BOOL)steal onCompletion:(void (^)(BOOL success))completion {
    // Fix #524: destroy LiveProcessHandler monitor such that it will pass focus check
    // See https://gist.github.com/khanhduytran0/504b16d86a2091e676c412bd0a517306 for more info
    /// Visibility graph search found root scene (null) and ultimate host <none>
    [server destroyEndpointInjector];

    void(*orig)(id, SEL, int, id, BOOL, void (^)(BOOL)) = (void *)_objc_msgForward;
    orig(self, _cmd, pid, context, steal, ^(BOOL success){
        completion(success);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            // Fix #844, #870: re-init "com.apple.frontboard.visibility" monitor back otherwise things will break because runningboardd falsely see us as background process
            NSString *selfEnv = [@"UIScene:" stringByAppendingString:context.sceneIdentity.stringRepresentation];
            [server createEndpointInjectorWithSelfToken:selfEnv sourceToken:NSUserDefaults.lcAppIdentityToken];
        });
    });
}

- (void)hook_startConnection {
    if (!server) server = [[NSClassFromString(@"LiveProcessHandler") sharedInstance] server];
    [server destroyEndpointInjector];

    [self hook_startConnection];

    // Initialize LiveProcessHandler XPC and perform first init of "com.apple.frontboard.visibility" monitor
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSString *selfEnv = [@"UIScene:" stringByAppendingString:UIApplication.sharedApplication.connectedScenes.anyObject._FBSScene.identityToken.stringRepresentation];
        [server createEndpointInjectorWithSelfToken:selfEnv sourceToken:NSUserDefaults.lcAppIdentityToken];
    });

    Method method = class_getInstanceMethod(self.class, @selector(hook_focusApplicationWithProcessIdentifier:context:stealingKeyboard:onCompletion:));
    Class proxyClass = self.proxy.class;
    class_replaceMethod(proxyClass, @selector(focusApplicationWithProcessIdentifier:context:stealingKeyboard:onCompletion:),
                        method_getImplementation(method), method_getTypeEncoding(method));
}
@end

@implementation UIPasteboard(hook)

+ (UIPasteboard *)hook_generalPasteboard {
    if(strictTestMode) {
        return strictPrivatePasteboard ?: [self hook_generalPasteboard];
    }
    return [self hook_generalPasteboard];
}

@end

@implementation NSURLSessionTask(hook)

- (void)hook_resume {
    if(strictTestMode) {
        [self cancel];
        return;
    }
    [self hook_resume];
}

@end

@implementation LCNetworkExtensionStrictHookProvider

+ (void)hook_fetchCurrentWithCompletionHandler:(void (^)(id currentNetwork))completionHandler {
    if(strictTestMode) {
        if(completionHandler) {
            completionHandler(nil);
        }
        return;
    }
    [self hook_fetchCurrentWithCompletionHandler:completionHandler];
}

@end
