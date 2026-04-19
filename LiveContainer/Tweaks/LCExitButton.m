//
//  LCExitButton.m
//  LiveContainer
//
//  Injects a floating exit button on top of the running guest app (normal mode only).
//  Pass isLiveProcess=YES or isSideStore=YES to skip.
//  Multitask mode is handled separately by MultitaskAppWindow.swift.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/types.h>
#import <unistd.h>
#import "../LCSharedUtils.h"

// Captured at init time, before bundle/defaults swap
extern NSString       *lcAppUrlScheme;
extern NSUserDefaults *lcUserDefaults;
extern NSBundle       *lcMainBundle;
static NSString       *g_lcScheme   = nil;
static NSUserDefaults *g_lcDefaults = nil;

// ─── Process termination ───────────────────────────────────────
// kill(getpid(), SIGKILL) is the safest way to terminate in a hooked environment:
//   • Goes directly to the kernel via libc syscall — no signal handler, no atexit,
//     no C++ destructors, no ObjC dealloc chains that could be hooked/broken.
//   • exit(0) DOES run atexit handlers — some may call into hooked code and crash.
//   • raise(SIGKILL) goes through more libc machinery than kill().
//   • The inline asm approach in LCSharedUtils is also fine but platform-specific.
// We give SpringBoard 350ms to register the open request before killing.
static void lceb_killSelf(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        kill(getpid(), SIGKILL);
    });
}

// ─── Relaunch LC ──────────────────────────────────────────────
//
// Mirrors SideStore's relaunchLC → [LCSharedUtils launchToGuestApp] exactly.
// Priority order:
//   1. TrollStore  → apple-magnifier://enable-jit?bundle-id=…
//   2. StikJIT     → stikjit://enable-jit?bundle-id=…
//   3. Default     → LSApplicationWorkspace.openApplicationWithBundleID: + kill
//
// We skip the SideStore JIT path (sidestore://) because hook_openURL in
// UIKit+GuestHooks has "sidestore" in its blocked-schemes list, so
// canOpenURL("sidestore://") returns NO for guest apps.
//
// We skip livecontainer://livecontainer-relaunch because hook_openURL
// intercepts that scheme and re-wraps it as open-url?url=<base64>,
// causing LC to relaunch to the wrong screen.
//
// LSApplicationWorkspace.openApplicationWithBundleID: goes directly to
// SpringBoard via a Mach port — it is not hooked by TweakLoader.
//
static void lceb_relaunchLC(void) {
    [g_lcDefaults synchronize];

    UIApplication *application = UIApplication.sharedApplication;
    // mainBundle is now the GUEST bundle (swapped by invokeAppMain).
    NSString *guestBundleId = NSBundle.mainBundle.bundleIdentifier;

    // ── Case 1: TrollStore ────────────────────────────────────────────────────
    if (!LCSharedUtils.certificatePassword) {
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore",
                            lcMainBundle.bundlePath];
        if (access(tsPath.UTF8String, F_OK) == 0) {
            NSString *urlStr = [NSString stringWithFormat:
                @"apple-magnifier://enable-jit?bundle-id=%@", guestBundleId];
            NSURL *url = [NSURL URLWithString:urlStr];
            if ([application canOpenURL:url]) {
                [application openURL:url options:@{} completionHandler:^(BOOL ok) {
                    kill(getpid(), SIGKILL);
                }];
                return;
            }
        }

        // ── Case 2: StikJIT ───────────────────────────────────────────────────
        NSURL *stikTest = [NSURL URLWithString:@"stikjit://"];
        if ([application canOpenURL:stikTest]) {
            NSString *urlStr = [NSString stringWithFormat:
                @"stikjit://enable-jit?bundle-id=%@", guestBundleId];
            NSURL *url = [NSURL URLWithString:urlStr];
            [application openURL:url options:@{} completionHandler:^(BOOL ok) {
                kill(getpid(), SIGKILL);
            }];
            return;
        }
    }

    // ── Case 3: Default — open LC via SpringBoard, then kill ─────────────────
    // lcMainBundle was captured before invokeAppMain swapped mainBundle, so it
    // always holds the real LC bundle (not the guest app bundle).
    NSString *lcBundleID = lcMainBundle.bundleIdentifier;
    if (!lcBundleID) {
        lcBundleID = [NSString stringWithFormat:@"com.kdt.%@",
                      g_lcScheme ?: @"livecontainer"];
    }

    // Use NSClassFromString + performSelector to avoid compiler "no known class
    // method" errors on the opaque Class returned by NSClassFromString.
    Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (lsClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id workspace = [(id)lsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (workspace) {
            [workspace performSelector:NSSelectorFromString(@"openApplicationWithBundleID:")
                           withObject:lcBundleID];
        }
#pragma clang diagnostic pop
    }

    // Kill on a high-priority background queue so dispatch_get_main_queue
    // UI teardown doesn't interfere. kill() bypasses all atexit/ObjC teardown.
    lceb_killSelf();
}

// ─── Floating container view ───────────────────────────────────
@interface LCExitButtonView : UIView
+ (void)installInWindow:(UIWindow *)window;
@end

@implementation LCExitButtonView

+ (void)installInWindow:(UIWindow *)window {
    if (!window || !g_lcDefaults) return;

    // Only attach to real app windows with a rootViewController and a UIWindowScene.
    // System overlay windows (keyboard, permission dialogs, etc.) have no
    // rootViewController — presentViewController: on nil crashes immediately.
    if (!window.rootViewController) return;
    if (![window.windowScene isKindOfClass:[UIWindowScene class]]) return;

    id stored = [g_lcDefaults objectForKey:@"LCShowExitButton"];
    BOOL showButton = stored ? [g_lcDefaults boolForKey:@"LCShowExitButton"] : NO;
    if (!showButton) return;

    // Remove any existing button before re-adding.
    for (UIView *sub in [window.subviews copy]) {
        if ([sub isKindOfClass:[LCExitButtonView class]]) {
            [sub removeFromSuperview];
        }
    }

    CGFloat winW = window.bounds.size.width;
    if (winW <= 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [LCExitButtonView installInWindow:window];
        });
        return;
    }

    BOOL onRight    = [g_lcDefaults boolForKey:@"LCExitButtonPosition"];
    CGFloat size    = 44.0f;
    CGFloat safeTop = window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : 44.0f;
    CGFloat x       = onRight ? (winW - size - 12.0f) : 12.0f;
    CGFloat y       = safeTop + 8.0f;

    LCExitButtonView *v = [[LCExitButtonView alloc]
                           initWithFrame:CGRectMake(x, y, size, size)];
    v.backgroundColor        = [UIColor clearColor];
    v.userInteractionEnabled = YES;
    v.layer.zPosition        = 9999.0f;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, size, size);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
        [btn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"
                               withConfiguration:cfg]
             forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
    } else {
        [btn setTitle:@"✕" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    }
    btn.layer.shadowColor   = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset  = CGSizeMake(0, 2);
    btn.layer.shadowRadius  = 4.0f;
    btn.layer.shadowOpacity = 0.55f;

    [btn addTarget:v action:@selector(exitButtonTapped)
  forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:btn];
    [window addSubview:v];
    [window bringSubviewToFront:v];
}

- (void)exitButtonTapped {
    UIWindow *win = self.window;
    if (!win) return;

    // Walk to the topmost VC that is actually in the window hierarchy.
    // A VC whose view.window is nil is not in the hierarchy — presenting on it
    // causes "Trying to present on a view that is not in a window" crash.
    UIViewController *rootVC = win.rootViewController;
    if (!rootVC || rootVC.view.window == nil) return;

    NSInteger safetyCounter = 0;
    while (rootVC.presentedViewController
           && !rootVC.presentedViewController.isBeingDismissed
           && safetyCounter < 20) {
        rootVC = rootVC.presentedViewController;
        safetyCounter++;
    }

    if (rootVC.isBeingDismissed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self exitButtonTapped];
        });
        return;
    }

    if (rootVC.view.window == nil) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Return to AppNest?"
        message:@"Any unsaved data in the running app may be lost."
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Leave App"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *_) {
            lceb_relaunchLC();
        }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel
        handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

// ─── Notification-based window observer ───────────────────────
// UIWindowDidBecomeKeyNotification instead of swizzling UIWindow.makeKeyAndVisible.
//
// UIKit+GuestHooks already swizzles makeKeyAndVisible with
// method_exchangeImplementations. Inserting our own IMP before that with
// method_setImplementation corrupts both hook chains → crash on first tap.
// The notification fires after the window is fully set up, same trigger with
// no swizzle interaction.
//
// installInWindow: filters to real app windows only (rootViewController present,
// windowScene is UIWindowScene), so transient OS overlay windows are ignored.
static id g_windowObserver = nil;

// ─── Entry point ───────────────────────────────────────────────
// Called before NUDGuestHooksInit() so g_lcDefaults captures the real LC
// NSUserDefaults before it is redirected to the guest container.
void LCExitButtonGuestHooksInit(BOOL isLiveProcess, BOOL isSideStore) {
    if (isLiveProcess || isSideStore) return;

    g_lcScheme   = [lcAppUrlScheme copy];
    g_lcDefaults = lcUserDefaults;

    id stored = [g_lcDefaults objectForKey:@"LCShowExitButton"];
    BOOL showButton = stored ? [g_lcDefaults boolForKey:@"LCShowExitButton"] : NO;
    if (!showButton) return;

    g_windowObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            UIWindow *window = note.object;
            // Short delay so rootViewController and safeAreaInsets are populated.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [LCExitButtonView installInWindow:window];
            });
        }];
}
