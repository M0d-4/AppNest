@import UIKit;
@import QuartzCore;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"
#import "../LiveProcess/LiveProcessHandler.h"
#import "../MultitaskSupport/UIKitPrivate+MultitaskSupport.h"

extern void _objc_msgForward(void);
@interface LCLandscapeLetterboxHelper : NSObject
+ (void)repositionAllWindows;
// Starts (if not already running) a CADisplayLink-driven loop that
// re-asserts the letterbox every frame, for as long as the app is
// foregrounded. Unlike a timed polling burst, this never "expires" — it
// keeps enforcing the invariant for the app's entire foreground lifetime,
// so it cannot miss a geometry change no matter which private API caused
// it or when it fires, including on iOS/iPadOS versions where the exact
// resize mechanism isn't known. Safe to call repeatedly; a no-op if already
// running.
+ (void)startEnforcing;
// Stops the per-frame loop (e.g. when backgrounding) to avoid needless work.
// Safe to call repeatedly; a no-op if not running.
+ (void)stopEnforcing;
@end
// Shared Force Landscape Mode letterbox helpers (defined alongside the
// UIWindow hooks further down this file) — forward-declared here so
// LCLandscapeLetterboxHelper, which appears earlier in the file, can use
// them too.
static BOOL LCShouldApplyLandscapeLetterbox(UIWindow *window);
static BOOL LCShouldApplyLandscapeLetterboxSafetyNet(UIWindow *window);
static BOOL LCIsMultitaskLandscapeLaunch(void);
static CGRect LCLandscapeLetterboxedFrame(CGRect frame);
static CGRect LCLandscapeLetterboxedSize(CGRect frame);
// LCForceLandscapeMode/LCIsMultitaskLaunch were single global keys in the
// shared app-group defaults, not scoped per app. That's fine as long as
// only one guest app is ever relevant at a time, but multitasking exists
// specifically to run several simultaneously (each its own OS
// process/multitask tile). Any app's launch calling syncLandscapeMode()
// overwrites that same global key for every OTHER already-running app too
// — and since the letterbox is enforced continuously (CADisplayLink on the
// guest side, re-checked on every layout pass on the host side), an
// already-running, correctly letterboxed app would pick up a completely
// unrelated app's setting on its very next check and silently stop
// letterboxing. Scoping the key per app id makes each app's setting
// independent of whatever any other app's launch (or exit-triggered
// relaunch) does to the shared suite.
static NSString *LCForceLandscapeModeScopedKey(NSString *baseKey, NSString *appId) {
    return [NSString stringWithFormat:@"%@_%@", baseKey, appId ?: @""];
}
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
    // value of LCForceLandscapeMode itself, so toggling the setting per app
    // takes effect immediately without depending on the flag's value at
    // process start.
    NSString *forceLandscapeAppId = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [forceLandscapeAppId.lowercaseString containsString:@"sidestore"];
    if (!isSideStore) {
        NSLog(@"[ForceLandscapeMode] init for appId=%@ LCForceLandscapeMode=%d LCIsMultitaskLaunch=%d", lcGuestAppId,
              [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCForceLandscapeMode", forceLandscapeAppId)],
              [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCIsMultitaskLaunch", forceLandscapeAppId)]);
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

        // The swizzles above (-setFrame:, -layoutSubviews, -makeKeyAndVisible)
        // catch the overwhelming majority of resizes immediately, with zero
        // visible flicker. But which private mechanism is responsible for
        // any *given* geometry change is an OS-version-specific implementation
        // detail we don't have visibility into (this is exactly what made
        // iPadOS 27 unreliable outside multitask: some resize path there
        // doesn't route through any of the swizzled selectors). Rather than
        // keep chasing individual hook points per OS version, the
        // CADisplayLink loop below re-asserts the crop every frame as a
        // catch-all that is correct by construction: it doesn't matter *how*
        // a window's geometry changed, only that it's checked and corrected
        // before the next frame is presented. A one-frame (~16ms) correction
        // window is imperceptible, and the check itself (a couple of
        // NSUserDefaults reads plus a CGRect compare) is cheap enough to run
        // every frame for as long as the app is in the foreground.
        //
        // Started immediately here (not deferred to a foreground
        // notification) so a cold launch is covered from frame one, and
        // paused/resumed with the app's active state purely to avoid
        // spending a frame callback while backgrounded — eligibility
        // (feature on, not multitask, not SideStore, main window) is still
        // re-checked live on every tick, so toggling the setting or the
        // multitask state still takes effect immediately either way.
        [LCLandscapeLetterboxHelper startEnforcing];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [LCLandscapeLetterboxHelper startEnforcing];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [LCLandscapeLetterboxHelper stopEnforcing];
        }];
    }

    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    NSString *lcGuestAppIdForOrientation = NSUserDefaults.lcGuestAppId;
    BOOL forceLandscapeModeEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCForceLandscapeMode", lcGuestAppIdForOrientation)];
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    // Only the phone-specific manual lock below needs the
    // background/foreground "kick" installed further down (via
    // hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:):
    // that workaround bounces the process through com.apple.springboard and
    // back ~0.5s after launch to make iOS re-read a changed FBSSceneParameters
    // orientation. Force Landscape Mode must NOT set this, since it already
    // gets a correct landscape orientation at scene-connect time via
    // hook_initWithXPCDictionary/hook___supportedInterfaceOrientations below,
    // and stays correct continuously via the setFrame/layoutSubviews/
    // CADisplayLink letterbox enforcement above -- sharing the phone lock's
    // kick with it was causing a spurious didEnterBackground/
    // willEnterForeground cycle a couple seconds into every landscape-mode
    // launch for no benefit.
    BOOL needsOrientationKickWorkaround = NO;
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
        needsOrientationKickWorkaround = (LCOrientationLock != UIInterfaceOrientationUnknown);
    } else if (forceLandscapeModeEnabled) {
        // Force Landscape Mode: a portrait-only iPad app normally just
        // renders "sideways" (unrotated, filling the whole screen) if the
        // device is physically held in landscape, since iOS never actually
        // rotates an app's UI past what it declares support for. Reusing
        // the same orientation-override mechanism as the phone-specific
        // lock above -- for the opposite direction -- actually flips the
        // OS-level scene orientation to landscape, so the status bar/scene
        // chrome genuinely reflects landscape instead of just sitting
        // sideways. The app's own layout still isn't designed for
        // landscape, so LCLandscapeLetterboxedFrame (below) separately
        // confines its rendered window to portrait-shaped proportions,
        // centered with black bars filling the rest -- correctly
        // proportioned portrait UI at a smaller size, rather than a
        // stretched, broken-looking landscape layout.
        LCOrientationLock = UIInterfaceOrientationLandscapeRight;
    }
    if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
        if (needsOrientationKickWorkaround) {
            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
        }
        swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
        swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
        swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
        swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
    }

    if(@available(iOS 17.0, *)) {
        // Previously gated to isLiveProcess (multitask) only. The
        // LiveProcessHandler/XPC visibility calls inside hook_startConnection
        // and hook_focusApplicationWithProcessIdentifier:... safely no-op via
        // message-to-nil when that class isn't linked into a process (true
        // for classic-mode standalone launches, which are LiveContainer.app's
        // own binary, not the separate LiveProcess extension). But the
        // keyboard-focus-arbitration-proxy replacement those methods install
        // is a general iOS mechanism for anything hosting embedded/dlopen'd
        // guest content that needs correct keyboard focus arbitration -- not
        // something inherently specific to the LiveProcess extension
        // architecture. Standalone launches dlopen guest code into a
        // different bundle's process too, so the same arbitration gap could
        // plausibly apply there, and its own comments describe it as fixing
        // a focus-check problem -- exactly the kind of thing that could
        // explain a keyboard that's slow-but-eventually-successful rather
        // than outright missing.
        swizzle(_UIRemoteKeyboards.class, @selector(startConnection), @selector(hook_startConnection));
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
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
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
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
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
            LSApplicationWorkspace* workspace = [objc_lookUpClass("LSApplicationWorkspace") defaultWorkspace];
            [workspace openApplicationWithBundleID:@"com.apple.springboard"];
            [workspace openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
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
    BOOL isMultitaskLaunch = [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCIsMultitaskLaunch", appId)];
    CGRect nativeBounds = [self hook_UIScreen_bounds];
    BOOL forceLandscapeEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCForceLandscapeMode", appId)] && !isSideStore;

    if (isMultitaskLaunch) {
        // Under multitask the window's real frame is whatever tile the host
        // assigns -- not the full native screen, and (when Force Landscape
        // Mode is on) not even the whole tile, since the host further
        // narrows the visible content area to a centered letterboxed
        // sub-rect (see LCLandscapeLetterboxedRect in MultitaskSupport).
        // The guest's own window bounds already correctly track whichever
        // of those two the host has actually assigned (confirmed by
        // hook_setFrame's requestedFrame logs matching each), so basing
        // UIScreen.bounds on nativeBounds (the full device screen) here was
        // still wrong even without the crop below: it previously fixed a
        // blank screen (content sized for a fake crop of the WRONG total
        // area) by reporting an area that also doesn't match what's
        // actually visible, just a less broken one -- the app's content
        // still doesn't know to size itself to the narrower letterboxed
        // area, so it overflows past the right edge instead of fitting it.
        UIWindow *keyWindow = LCKeyWindowForScene(LCForegroundWindowScene());
        CGRect tileBounds = keyWindow ? keyWindow.bounds : nativeBounds;
        if (forceLandscapeEnabled) {
            CGFloat availW = tileBounds.size.width;
            CGFloat availH = tileBounds.size.height;
            CGFloat targetW = (availW > 0 && availH > 0) ? MIN(availW, availH * (3.0 / 4.0)) : availW;
            return CGRectMake(0, 0, targetW, availH);
        }
        return CGRectMake(0, 0, tileBounds.size.width, tileBounds.size.height);
    }

    if (forceLandscapeEnabled) {
        CGFloat screenH = nativeBounds.size.height;
        CGFloat screenW = nativeBounds.size.width;
        // Portrait-aspect crop (roughly a typical iPad portrait proportion)
        // instead of the old 9:16 phone aspect -- this app is a real iPad
        // app being confined to its own natural portrait shape, not made to
        // pretend it's a phone.
        CGFloat targetW = MIN(screenW, screenH * (3.0 / 4.0));
        return CGRectMake(0, 0, targetW, screenH);
    }
    return CGRectMake(0, 0, nativeBounds.size.width, nativeBounds.size.height);
}
@end

// Target for the CADisplayLink below. A plain NSObject can't be a display
// link target/selector pair cleanly across old runtimes, so this tiny class
// just forwards each tick to +repositionAllWindows.
@interface LCLandscapeLetterboxDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation LCLandscapeLetterboxDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    [LCLandscapeLetterboxHelper repositionAllWindows];
}
@end

@implementation LCLandscapeLetterboxHelper
+ (void)repositionAllWindows {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            // Deliberately NOT the same eligibility check as the
            // -setFrame:/-layoutSubviews hooks: those stay deferential to
            // the host under multitask so they don't fight its real-time
            // centering, but this periodic sweep needs to also run under
            // multitask as a backstop against the window drifting back to
            // full size outside the host's own resize flow (confirmed
            // happening a few seconds after launch, with no corresponding
            // host-side relayout to catch it). The early-out just below
            // means this can't fight a legitimate host resize -- it only
            // acts when the current frame has actually drifted from the
            // target.
            if (!LCShouldApplyLandscapeLetterboxSafetyNet(window)) continue;
            BOOL isMultitask = LCIsMultitaskLandscapeLaunch();
            // Width-only under multitask -- the host owns centering there;
            // see LCLandscapeLetterboxedSize.
            CGRect targetFrame = isMultitask ? LCLandscapeLetterboxedSize(window.frame) : LCLandscapeLetterboxedFrame(window.frame);
            // Cheap early-out: on the overwhelming majority of frames
            // nothing has moved the window since the last tick, so avoid
            // touching .frame (and re-entering the -setFrame:/-layoutSubviews
            // swizzles) unless the crop has actually drifted. Origin is only
            // part of the drift check outside multitask, since under
            // multitask this sweep never touches origin in the first place.
            if (fabs(window.frame.size.width - targetFrame.size.width) < 0.5 &&
                (isMultitask || fabs(window.frame.origin.x - targetFrame.origin.x) < 0.5)) {
                continue;
            }
            window.frame = targetFrame;
        }
    }
    [CATransaction commit];
}

static CADisplayLink *LCLandscapeLetterboxDisplayLink;
static LCLandscapeLetterboxDisplayLinkTarget *LCLandscapeLetterboxDisplayLinkTargetInstance;

+ (void)startEnforcing {
    if (LCLandscapeLetterboxDisplayLink) return; // already running
    if (!LCLandscapeLetterboxDisplayLinkTargetInstance) {
        LCLandscapeLetterboxDisplayLinkTargetInstance = [LCLandscapeLetterboxDisplayLinkTarget new];
    }
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:LCLandscapeLetterboxDisplayLinkTargetInstance
                                                       selector:@selector(tick:)];
    // Common run loop modes so this keeps ticking during UI tracking (e.g.
    // scroll views, drags) rather than pausing exactly when a gesture might
    // be actively resizing something.
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    LCLandscapeLetterboxDisplayLink = link;
}

+ (void)stopEnforcing {
    if (!LCLandscapeLetterboxDisplayLink) return;
    [LCLandscapeLetterboxDisplayLink invalidate];
    LCLandscapeLetterboxDisplayLink = nil;
}
@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    if (LCShouldApplyLandscapeLetterbox(self)) {
        self.backgroundColor = [UIColor blackColor];
    }
    // Belt-and-suspenders: -layoutSubviews and -setFrame: both depend on
    // something touching the window's geometry after it exists. The very
    // first time a window is shown, especially outside multitask where
    // there's no host-side FBSSceneSettings round-trip to piggyback on,
    // that isn't guaranteed to happen before the window is actually on
    // screen — so also enforce the letterbox right here, at the one point
    // that's called exactly once the window is about to become visible.
    // (This swizzle is only installed for apps whose delegate doesn't
    // implement the modern scene APIs — see hook_setDelegate: below —
    // so -layoutSubviews above remains the primary catch-all for the
    // common, scene-delegate case.)
    if (LCShouldApplyLandscapeLetterbox(self)) {
        CGRect targetFrame = LCLandscapeLetterboxedFrame(self.frame);
        NSLog(@"[ForceLandscapeMode] hook_makeKeyAndVisible currentFrame=%@ targetFrame=%@",
              NSStringFromCGRect(self.frame), NSStringFromCGRect(targetFrame));
        if (fabs(self.frame.size.width - targetFrame.size.width) >= 0.5) {
            self.frame = targetFrame;
        }
    }
    [self hook_makeKeyAndVisible];
}

// Shared decision: does this window need the Force Landscape Mode letterbox
// applied by *this* (guest) process at all? False for SideStore, non-main
// windows, and — critically — for any window running under the multitask
// host. The multitask host (AppSceneViewController) does its own centering
// using the tile's actual bounds, which the guest process has no way to
// know; letting the guest also letterbox on top of that double-applies the
// offset and is what made the multitask letterbox appear off-center.
static BOOL LCShouldApplyLandscapeLetterbox(UIWindow *window) {
    NSString *lcappid = NSUserDefaults.lcGuestAppId;
    if (![NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCForceLandscapeMode", lcappid)]) return NO;
    if ([NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCIsMultitaskLaunch", lcappid)]) return NO;
    if ([lcappid.lowercaseString containsString:@"sidestore"]) return NO;
    if (window.windowLevel != UIWindowLevelNormal) return NO;
    return YES;
}

// Same eligibility as LCShouldApplyLandscapeLetterbox but WITHOUT the
// multitask exclusion -- used only by the periodic CADisplayLink sweep
// below, never by the real-time -setFrame:/-layoutSubviews hooks. Those
// stay deferential to the host under multitask (so they don't fight its
// real-time centering/resizing), but that leaves nothing to catch it if
// something *else* resets the window's frame outside the host's own
// resize flow -- which is exactly what happened here: the app's own
// window reverted to the full 1080x810 tile a few seconds after launch,
// with no corresponding host-side relayout to correct it, and nothing
// forced it back since the sweep was skipping multitask entirely. This
// sweep's existing early-out (skip touching .frame when nothing has
// actually drifted) means it can't fight the host during a legitimate
// resize -- it only acts when the current frame doesn't match the target,
// which is precisely the drift case this exists to catch.
static BOOL LCShouldApplyLandscapeLetterboxSafetyNet(UIWindow *window) {
    NSString *lcappid = NSUserDefaults.lcGuestAppId;
    if (![NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCForceLandscapeMode", lcappid)]) return NO;
    if ([lcappid.lowercaseString containsString:@"sidestore"]) return NO;
    if (window.windowLevel != UIWindowLevelNormal) return NO;
    return YES;
}

// Computes the centered portrait-aspect letterbox of `frame`. Idempotent:
// feeding an already-letterboxed rect back in returns the same rect
// unchanged. Roughly a typical iPad portrait proportion (3:4) rather than a
// phone aspect (9:16) -- this confines a portrait-only iPad app to its own
// natural portrait shape, smaller and centered, rather than pretending to
// be a phone.
static CGRect LCLandscapeLetterboxedFrame(CGRect frame) {
    CGFloat availW = frame.size.width;
    CGFloat availH = frame.size.height;
    if (availW <= 0 || availH <= 0) return frame;
    CGFloat targetW = MIN(availW, availH * (3.0 / 4.0));
    CGFloat offsetX = frame.origin.x + (availW - targetW) / 2.0;
    return CGRectMake(offsetX, frame.origin.y, targetW, availH);
}

static BOOL LCIsMultitaskLandscapeLaunch(void) {
    return [NSUserDefaults.lcSharedDefaults boolForKey:LCForceLandscapeModeScopedKey(@"LCIsMultitaskLaunch", NSUserDefaults.lcGuestAppId)];
}

// Same crop as LCLandscapeLetterboxedFrame, but leaves origin untouched.
// Under multitask, horizontal centering is the host's job -- it already
// offsets its own contentView by exactly this same margin (see
// AppSceneViewController's viewWillLayoutSubviews). Letting the guest ALSO
// offset its own window's origin double-applies that margin: visually, both
// the left and right margins collapse onto the left, and content ends up
// flush against the right edge with zero margin on that side instead of a
// matching one -- which is exactly the bug this replaces. Constraining
// WIDTH here still prevents the app from baking a too-wide content layout
// (the original overflow-past-the-edge bug this whole mechanism exists to
// fix); the host remains solely responsible for where that narrower window
// actually sits on screen.
static CGRect LCLandscapeLetterboxedSize(CGRect frame) {
    CGFloat availW = frame.size.width;
    CGFloat availH = frame.size.height;
    if (availW <= 0 || availH <= 0) return frame;
    CGFloat targetW = MIN(availW, availH * (3.0 / 4.0));
    return CGRectMake(frame.origin.x, frame.origin.y, targetW, availH);
}

- (void)hook_setFrame:(CGRect)frame {
    // Deliberately the safety-net check (no multitask exclusion), not
    // LCShouldApplyLandscapeLetterbox: the host's own settings-driven
    // resize has a real, if brief, delay before it corrects a window down
    // to the letterboxed width, and during that window the app can already
    // read/act on the wrong (full-tile) frame -- which is exactly what
    // baked a too-wide content layout into a game that only sizes its
    // content once at launch rather than observing later resizes. Applying
    // the same crop synchronously here, immediately, closes that window
    // instead of just correcting it a frame later. Since both sides use
    // the identical crop formula, this can't fight the host's own
    // resize -- it converges to the same target either way.
    BOOL shouldForce = LCShouldApplyLandscapeLetterboxSafetyNet(self);
    NSLog(@"[ForceLandscapeMode] hook_setFrame called requestedFrame=%@ windowLevel=%f shouldForce=%d",
          NSStringFromCGRect(frame), self.windowLevel, shouldForce);

    // Anything that doesn't need the letterbox — feature off, SideStore, or
    // a non-main window (overlays, alerts, multitask chrome, etc.) — must
    // pass through untouched. Previously this branch substituted a
    // hardcoded full-screen rect for *any* unletterboxed case, which
    // stomped on every other window's real geometry (including multitask
    // tile assignments), silently breaking layout well beyond just this
    // feature.
    if (!shouldForce) {
        [self hook_setFrame:frame];
        return;
    }

    // Constrain to a portrait aspect within whatever area was actually
    // being requested. Under multitask, only width is enforced here — the
    // host already centers its own contentView by the same margin, so also
    // centering the guest's window on top of that double-applies it.
    CGRect targetFrame = LCIsMultitaskLandscapeLaunch() ? LCLandscapeLetterboxedSize(frame) : LCLandscapeLetterboxedFrame(frame);
    [self hook_setFrame:targetFrame];
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
    if (!LCShouldApplyLandscapeLetterboxSafetyNet(self)) return;

    CGRect currentFrame = self.frame;
    CGRect targetFrame = LCIsMultitaskLandscapeLaunch() ? LCLandscapeLetterboxedSize(currentFrame) : LCLandscapeLetterboxedFrame(currentFrame);
    NSLog(@"[ForceLandscapeMode] hook_layoutSubviews currentFrame=%@ targetFrame=%@",
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

static id<LCMultitaskXPCServiceProtocol> server;
@implementation _UIRemoteKeyboards(hook)
// from UIKeyboardArbitration proxy
- (void)hook_focusApplicationWithProcessIdentifier:(int)pid context:(UIKBArbiterClientFocusContext *)context stealingKeyboard:(BOOL)steal onCompletion:(void (^)(BOOL success))completion {
    // Fix #524: destroy LiveProcessHandler monitor such that it will pass focus check
    // See https://gist.github.com/khanhduytran0/504b16d86a2091e676c412bd0a517306 for more info
    /// Visibility graph search found root scene (null) and ultimate host <none>
    //
    // Reverted an earlier attempt to move the blocking destroyEndpointInjector
    // call (server is a *synchronous* XPC proxy) off the main thread: that
    // was meant to stop a slow XPC round-trip from freezing the whole app,
    // but deferring the eventual _objc_msgForward call (which is what
    // actually triggers this proxy's own XPC forwarding to the real
    // implementation) across two dispatch_async hops risked breaking
    // whatever synchronous-invocation assumptions that forwarding mechanism
    // depends on — and a keyboard that doesn't appear at all is worse than
    // one that's slow. Back to fully synchronous, matching upstream.
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
        // connectedScenes is an NSSet (unordered) -- .anyObject picks whichever
        // member happens to come out first, which is only guaranteed correct
        // if exactly one scene is connected. If more than one is (plausible
        // for anything hosting a guest scene), this could silently register
        // the visibility fix against the WRONG scene's identity token,
        // leaving the actual foreground scene's keyboard focus unfixed --
        // which would look exactly like "keyboard doesn't load". Prefer the
        // scene that's actually foreground-active; fall back to .anyObject
        // only if none is found, to preserve prior behavior in that case.
        UIScene *activeScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = scene;
                break;
            }
        }
        if (!activeScene) activeScene = UIApplication.sharedApplication.connectedScenes.anyObject;
        if (!activeScene) return; // nothing connected yet; -stringByAppendingString: would throw on nil below
        NSString *selfEnv = [@"UIScene:" stringByAppendingString:activeScene._FBSScene.identityToken.stringRepresentation];
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
