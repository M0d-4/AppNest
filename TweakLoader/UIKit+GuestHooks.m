@import UIKit;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"
#include <sys/sysctl.h>
#include <sys/utsname.h>
#import "../LiveProcess/LiveProcessHandler.h"
#import "../MultitaskSupport/UIKitPrivate+MultitaskSupport.h"

extern void _objc_msgForward(void);
@interface LCRealIPhoneModeHelper : NSObject
+ (void)repositionAllWindows;
@end
UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
NSUUID* idForVendorUUID = nil;
BOOL spoofProfileEnabled = NO;
BOOL blockDeviceInfoReads = NO;
BOOL strictTestMode = NO;
UIPasteboard *strictPrivatePasteboard = nil;
NSString *spoofDeviceName = nil;
NSString *spoofDeviceModel = nil;
NSString *spoofSystemName = nil;
NSString *spoofSystemVersion = nil;
NSLocale *spoofLocale = nil;
NSTimeZone *spoofTimeZone = nil;
NSOperatingSystemVersion spoofOperatingSystemVersion;
BOOL spoofOperatingSystemVersionValid = NO;
float spoofBatteryLevel = -1.0f;
NSInteger spoofBatteryState = UIDeviceBatteryStateUnknown;
BOOL spoofLowPowerModeEnabled = NO;
BOOL spoofLowPowerModeEnabledSet = NO;
NSString *spoofRadioAccessTechnology = nil;
NSString *spoofSubscriberIdentifier = nil;
NSData *spoofSubscriberCarrierToken = nil;
BOOL spoofSubscriberSIMInsertedEnabled = NO;
BOOL spoofSubscriberSIMInserted = NO;
NSString *spoofHardwareModel = nil;
BOOL launchURLProcessed = NO;

@interface LCTelephonyNetworkInfoHookProvider : NSObject
@end

@interface LCSubscriberHookProvider : NSObject
@end

@interface LCSubscriberInfoHookProvider : NSObject
@end

@interface LCNetworkExtensionStrictHookProvider : NSObject
@end

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

static void LCSwizzleIfPresentWithSourceClass(Class cls, Class sourceCls, SEL originalAction, SEL swizzledAction) {
    if(!cls || !sourceCls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, originalAction);
    Method sourceMethod = class_getInstanceMethod(sourceCls, swizzledAction);
    if(!originalMethod || !sourceMethod) {
        return;
    }
    class_addMethod(
        cls,
        swizzledAction,
        method_getImplementation(sourceMethod),
        method_getTypeEncoding(sourceMethod)
    );
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledAction);
    if(swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

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

static BOOL LCParseVersionPart(NSString *part, NSInteger *outValue) {
    if(![part isKindOfClass:NSString.class] || part.length == 0) {
        return NO;
    }
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if([part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return NO;
    }
    long long parsedValue = part.longLongValue;
    if(parsedValue < 0 || parsedValue > NSIntegerMax) {
        return NO;
    }
    *outValue = (NSInteger)parsedValue;
    return YES;
}

static BOOL LCParseSystemVersion(NSString *versionString, NSOperatingSystemVersion *outVersion) {
    if(![versionString isKindOfClass:NSString.class]) {
        return NO;
    }
    NSArray<NSString*> *parts = [versionString componentsSeparatedByString:@"."];
    if(parts.count == 0 || parts.count > 3) {
        return NO;
    }

    NSInteger major = 0;
    NSInteger minor = 0;
    NSInteger patch = 0;
    if(!LCParseVersionPart(parts[0], &major)) {
        return NO;
    }
    if(parts.count > 1 && !LCParseVersionPart(parts[1], &minor)) {
        return NO;
    }
    if(parts.count > 2 && !LCParseVersionPart(parts[2], &patch)) {
        return NO;
    }
    outVersion->majorVersion = major;
    outVersion->minorVersion = minor;
    outVersion->patchVersion = patch;
    return YES;
}

static NSInteger LCCompareOSVersion(NSOperatingSystemVersion lhs, NSOperatingSystemVersion rhs) {
    if(lhs.majorVersion != rhs.majorVersion) {
        return lhs.majorVersion < rhs.majorVersion ? -1 : 1;
    }
    if(lhs.minorVersion != rhs.minorVersion) {
        return lhs.minorVersion < rhs.minorVersion ? -1 : 1;
    }
    if(lhs.patchVersion != rhs.patchVersion) {
        return lhs.patchVersion < rhs.patchVersion ? -1 : 1;
    }
    return 0;
}

static NSTimeZone *LCBlockedTimeZone(void) {
    return [NSTimeZone timeZoneWithAbbreviation:@"GMT"] ?: [NSTimeZone systemTimeZone];
}

static NSLocale *LCBlockedLocale(void) {
    return [[NSLocale alloc] initWithLocaleIdentifier:@"und"];
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

// MARK: - C-level hardware model spoofing (sysctlbyname / uname)
// Intercept low-level C APIs that analytics SDKs use to read the real hardware
// identifier (e.g. "iPhoneXX,X"). UIDevice.model only returns "iPhone" so apps
// bypass it entirely via these C calls.

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if(ret == 0 && oldp && oldlenp && spoofHardwareModel) {
        if(strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
            const char *spoofed = spoofHardwareModel.UTF8String;
            size_t spoofedLen = strlen(spoofed) + 1;
            if(*oldlenp >= spoofedLen) {
                strlcpy((char *)oldp, spoofed, *oldlenp);
                *oldlenp = spoofedLen;
            }
        }
    }
    return ret;
}

static int hook_uname(struct utsname *uts) {
    int ret = uname(uts);
    if(ret == 0 && spoofHardwareModel) {
        strlcpy(uts->machine, spoofHardwareModel.UTF8String, sizeof(uts->machine));
    }
    return ret;
}

// DYLD_INTERPOSE lets us hook C functions from a loaded dylib without needing litehook or fishhook.
// The linker replaces calls to the original function with our hook at load time.
#define DYLD_INTERPOSE(_hook, _orig) \
    __attribute__((used)) static struct { const void *hook; const void *orig; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&_hook, (const void *)&_orig }

// These interpose entries are conditionally effective — the hook functions
// check spoofHardwareModel at runtime and pass through if NULL.
DYLD_INTERPOSE(hook_sysctlbyname, sysctlbyname);
DYLD_INTERPOSE(hook_uname, uname);

// MARK: - HTTP Header Device Identity Rewriting
// Intercepts ALL outgoing HTTP headers to rewrite User-Agent strings containing
// real device info. This covers native iOS (NSURLSession), Flutter (Dart HTTP),
// React Native (fetch/axios), Expo, and all analytics SDKs (Firebase, PostHog,
// Adjust, AppsFlyer, etc.) since they ALL go through NSMutableURLRequest.

// Helper: Rewrite a User-Agent string, replacing real hw.machine and iOS version
// with spoofed values. Handles all known User-Agent formats:
//
// Format 1 (Custom app UAs):
//   ExampleApp/10.0 iOS/18.2 (Apple;iPhoneXX,X;;;;;1;2024)
//
// Format 2 (WebKit/Safari/WKWebView):
//   Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15
//
// Format 3 (NSURLSession default / CFNetwork):
//   AppName/1.0 CFNetwork/1568.200.51 Darwin/24.1.0
//
// Format 4 (Dart/Flutter):
//   Dart/3.5 (dart:io) MyApp/1.0 (iOS 18.0; iPhoneXX,X)
//
// Also catches any raw occurrence of the hw.machine identifier
// embedded anywhere in the string.

static NSRegularExpression *_uaHwMachineRegex = nil;
static NSRegularExpression *_uaIOSVersionSlashRegex = nil;
static NSRegularExpression *_uaIOSVersionCPURegex = nil;
static NSRegularExpression *_uaIOSVersionParenRegex = nil;

static void LCInitUserAgentRegexes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Match hw.machine identifiers: iPhoneXX,X  iPadXX,X  etc.
        // This is the most important one — catches ALL formats
        _uaHwMachineRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(iPhone|iPad|iPod)\\d+,\\d+"
            options:0 error:nil];

        // Match "iOS/XX.X" or "iOS/XX.X.X" (common custom UA format)
        _uaIOSVersionSlashRegex = [NSRegularExpression
            regularExpressionWithPattern:@"iOS/[\\d.]+"
            options:0 error:nil];

        // Match "CPU iPhone OS 18_0 like Mac OS X" (WebKit/Safari UA)
        _uaIOSVersionCPURegex = [NSRegularExpression
            regularExpressionWithPattern:@"CPU iPhone OS [\\d_]+ like Mac OS X"
            options:0 error:nil];

        // Match "(iOS 18.0;" or "iOS 18.0)" (Dart/Flutter, generic)
        _uaIOSVersionParenRegex = [NSRegularExpression
            regularExpressionWithPattern:@"iOS [\\d.]+"
            options:0 error:nil];
    });
}

static NSString* LCRewriteUserAgent(NSString *ua) {
    if(!ua || ua.length == 0) return ua;

    NSMutableString *result = [ua mutableCopy];
    NSRange fullRange = NSMakeRange(0, result.length);

    // 1. Replace all hw.machine identifiers (iPhoneXX,X → spoofed)
    // This is the primary catch-all — works for ANY format
    if(spoofHardwareModel) {
        [_uaHwMachineRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:spoofHardwareModel];
        fullRange = NSMakeRange(0, result.length);
    }

    // 2. Replace iOS version in various formats
    if(spoofSystemVersion) {
        // "iOS/XX.X" → "iOS/{spoofed}" (custom app UAs, analytics SDKs, etc.)
        [_uaIOSVersionSlashRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"iOS/%@", spoofSystemVersion]];
        fullRange = NSMakeRange(0, result.length);

        // "CPU iPhone OS 18_0 like Mac OS X" → spoofed (WebKit)
        NSString *underscoreVersion = [spoofSystemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        NSString *cpuReplacement = [NSString stringWithFormat:@"CPU iPhone OS %@ like Mac OS X", underscoreVersion];
        [_uaIOSVersionCPURegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:cpuReplacement];
        fullRange = NSMakeRange(0, result.length);

        // "iOS 18.0" → "iOS {spoofed}" (Dart/Flutter, generic)
        [_uaIOSVersionParenRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"iOS %@", spoofSystemVersion]];
    }

    return result;
}

// Helper: check if a header name is User-Agent (case-insensitive per HTTP spec)
static BOOL LCIsUserAgentHeader(NSString *field) {
    return [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame;
}

// Helper: rewrite a User-Agent value in a dictionary (for HTTPAdditionalHeaders)
static NSDictionary* LCRewriteHeaderDict(NSDictionary *headers) {
    if(!headers) return headers;
    NSMutableDictionary *result = nil;
    for(NSString *key in headers) {
        if(LCIsUserAgentHeader(key)) {
            NSString *val = headers[key];
            if([val isKindOfClass:NSString.class]) {
                NSString *rewritten = LCRewriteUserAgent(val);
                if(![rewritten isEqualToString:val]) {
                    if(!result) result = [headers mutableCopy];
                    result[key] = rewritten;
                }
            }
        }
    }
    return result ?: headers;
}

// --- NSMutableURLRequest hooks ---
// These intercept User-Agent being set on ANY outgoing HTTP request.
// Covers: NSURLSession (native iOS, React Native, Expo),
//         CFNetwork (Flutter dart:io), Firebase, PostHog, Adjust, AppsFlyer, etc.

@interface NSMutableURLRequest(LCDeviceSpoof)
@end

@implementation NSMutableURLRequest(LCDeviceSpoof)

- (void)hook_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if(value && LCIsUserAgentHeader(field)) {
        value = LCRewriteUserAgent(value);
    }
    [self hook_setValue:value forHTTPHeaderField:field];
}

- (void)hook_addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if(value && LCIsUserAgentHeader(field)) {
        value = LCRewriteUserAgent(value);
    }
    [self hook_addValue:value forHTTPHeaderField:field];
}

- (void)hook_setAllHTTPHeaderFields:(NSDictionary *)headerFields {
    [self hook_setAllHTTPHeaderFields:LCRewriteHeaderDict(headerFields)];
}

@end

// --- NSURLSessionConfiguration hooks ---
// Catches apps that set User-Agent at the session level via HTTPAdditionalHeaders.
// This is the recommended Apple API for setting global headers, used by:
// - React Native (RCTSetCustomNSURLSessionConfigurationProvider)
// - Firebase SDK
// - Alamofire (Swift networking library)
// - Any app following Apple best practices

@interface NSURLSessionConfiguration(LCDeviceSpoof)
@end

@implementation NSURLSessionConfiguration(LCDeviceSpoof)

- (void)hook_setHTTPAdditionalHeaders:(NSDictionary *)headers {
    [self hook_setHTTPAdditionalHeaders:LCRewriteHeaderDict(headers)];
}

@end

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
    if (!([lcGuestAppId isEqualToString:@"com.SideStore.SideStore"] || 
          [lcGuestAppId.lowercaseString containsString:@"sidestore"] ||
          NSUserDefaults.isSideStore)) { 
        //⭐️⭐️⭐️Real iPhone mode 9:16 hook(swizzle)
          swizzle(UIWindow.class, @selector(setFrame:), @selector(hook_setFrame:));
          swizzle(UIScreen.class, @selector(bounds), @selector(hook_UIScreen_bounds));

    }



//if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) {
            [LCRealIPhoneModeHelper repositionAllWindows];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) {
            [LCRealIPhoneModeHelper repositionAllWindows];
        }];
    //}






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
    blockDeviceInfoReads = strictTestMode || [guestContainerInfo[@"blockDeviceInfoReads"] boolValue];

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

    BOOL shouldEnableSpoofProfile = [guestContainerInfo[@"spoofProfileEnabled"] boolValue];
    BOOL shouldSpoofIdentifierForVendor = shouldEnableSpoofProfile && [guestContainerInfo[@"spoofIdentifierForVendor"] boolValue];
    if(shouldSpoofIdentifierForVendor) {
        NSString* idForVendorStr = guestContainerInfo[@"spoofedIdentifierForVendor"];
        if([idForVendorStr isKindOfClass:NSString.class]) {
            idForVendorUUID = [[NSUUID UUID] initWithUUIDString:idForVendorStr];
        }
    }
    if(blockDeviceInfoReads || (shouldSpoofIdentifierForVendor && idForVendorUUID != nil)) {
        swizzle(UIDevice.class, @selector(identifierForVendor), @selector(hook_identifierForVendor));
    }

    if(shouldEnableSpoofProfile) {
        spoofProfileEnabled = YES;
        NSString *deviceName = guestContainerInfo[@"spoofDeviceName"];
        NSString *deviceModel = guestContainerInfo[@"spoofDeviceModel"];
        NSString *systemName = guestContainerInfo[@"spoofSystemName"];
        NSString *systemVersion = guestContainerInfo[@"spoofSystemVersion"];
        NSString *localeIdentifier = guestContainerInfo[@"spoofLocaleIdentifier"];
        NSString *timeZoneIdentifier = guestContainerInfo[@"spoofTimeZoneIdentifier"];
        NSNumber *batteryLevelNumber = guestContainerInfo[@"spoofBatteryLevel"];
        NSNumber *batteryStateNumber = guestContainerInfo[@"spoofBatteryState"];
        NSNumber *lowPowerModeNumber = guestContainerInfo[@"spoofLowPowerModeEnabled"];
        NSString *radioAccessTechnology = guestContainerInfo[@"spoofRadioAccessTechnology"];
        NSString *subscriberIdentifier = guestContainerInfo[@"spoofSubscriberIdentifier"];
        NSString *subscriberCarrierTokenBase64 = guestContainerInfo[@"spoofSubscriberCarrierTokenBase64"];
        NSNumber *subscriberSIMInsertedEnabledNumber = guestContainerInfo[@"spoofSubscriberSIMInsertedEnabled"];
        NSNumber *subscriberSIMInsertedNumber = guestContainerInfo[@"spoofSubscriberSIMInserted"];

        if([deviceName isKindOfClass:NSString.class] && deviceName.length > 0) {
            spoofDeviceName = deviceName;
        }
        if([deviceModel isKindOfClass:NSString.class] && deviceModel.length > 0) {
            spoofDeviceModel = deviceModel;
        }
        if([systemName isKindOfClass:NSString.class] && systemName.length > 0) {
            spoofSystemName = systemName;
        }
        if([systemVersion isKindOfClass:NSString.class] && systemVersion.length > 0) {
            spoofSystemVersion = systemVersion;
            spoofOperatingSystemVersionValid = LCParseSystemVersion(systemVersion, &spoofOperatingSystemVersion);
        }

        if([localeIdentifier isKindOfClass:NSString.class] && localeIdentifier.length > 0) {
            NSLocale *candidateLocale = [[NSLocale alloc] initWithLocaleIdentifier:localeIdentifier];
            if(candidateLocale.localeIdentifier.length > 0) {
                spoofLocale = candidateLocale;
            }
        }

        if([timeZoneIdentifier isKindOfClass:NSString.class] && timeZoneIdentifier.length > 0) {
            NSTimeZone *candidateTimeZone = [NSTimeZone timeZoneWithName:timeZoneIdentifier];
            if(candidateTimeZone) {
                spoofTimeZone = candidateTimeZone;
                if(!blockDeviceInfoReads) {
                    [NSTimeZone setDefaultTimeZone:candidateTimeZone];
                }
            }
        }
        if([batteryLevelNumber isKindOfClass:NSNumber.class]) {
            float level = batteryLevelNumber.floatValue;
            if(level >= 0.0f && level <= 1.0f) {
                spoofBatteryLevel = level;
            }
        }
        if([batteryStateNumber isKindOfClass:NSNumber.class]) {
            NSInteger value = batteryStateNumber.integerValue;
            if(value >= UIDeviceBatteryStateUnknown && value <= UIDeviceBatteryStateFull) {
                spoofBatteryState = value;
            }
        }
        if([lowPowerModeNumber isKindOfClass:NSNumber.class]) {
            spoofLowPowerModeEnabled = lowPowerModeNumber.boolValue;
            spoofLowPowerModeEnabledSet = YES;
        }
        if([radioAccessTechnology isKindOfClass:NSString.class] && radioAccessTechnology.length > 0) {
            spoofRadioAccessTechnology = radioAccessTechnology;
        }
        if([subscriberIdentifier isKindOfClass:NSString.class] && subscriberIdentifier.length > 0) {
            spoofSubscriberIdentifier = subscriberIdentifier;
        }
        if([subscriberCarrierTokenBase64 isKindOfClass:NSString.class] && subscriberCarrierTokenBase64.length > 0) {
            NSData *decodedToken = [[NSData alloc] initWithBase64EncodedString:subscriberCarrierTokenBase64 options:0];
            if(decodedToken.length > 0) {
                spoofSubscriberCarrierToken = decodedToken;
            }
        }
        if([subscriberSIMInsertedEnabledNumber isKindOfClass:NSNumber.class]) {
            spoofSubscriberSIMInsertedEnabled = subscriberSIMInsertedEnabledNumber.boolValue;
        }
        if([subscriberSIMInsertedNumber isKindOfClass:NSNumber.class]) {
            spoofSubscriberSIMInserted = subscriberSIMInsertedNumber.boolValue;
        }

    }

    if(blockDeviceInfoReads || spoofDeviceName || spoofDeviceModel || spoofSystemName || spoofSystemVersion) {
        swizzle(UIDevice.class, @selector(name), @selector(hook_name));
        swizzle(UIDevice.class, @selector(model), @selector(hook_model));
        swizzle(UIDevice.class, @selector(localizedModel), @selector(hook_localizedModel));
        swizzle(UIDevice.class, @selector(systemName), @selector(hook_systemName));
        swizzle(UIDevice.class, @selector(systemVersion), @selector(hook_systemVersion));
    }
    if(blockDeviceInfoReads || spoofBatteryLevel >= 0.0f || spoofBatteryState != UIDeviceBatteryStateUnknown) {
        swizzle(UIDevice.class, @selector(batteryLevel), @selector(hook_batteryLevel));
        swizzle(UIDevice.class, @selector(batteryState), @selector(hook_batteryState));
        swizzle(UIDevice.class, @selector(isBatteryMonitoringEnabled), @selector(hook_isBatteryMonitoringEnabled));
    }
    if(blockDeviceInfoReads || spoofOperatingSystemVersionValid || spoofSystemVersion) {
        swizzle(NSProcessInfo.class, @selector(operatingSystemVersion), @selector(hook_operatingSystemVersion));
        swizzle(NSProcessInfo.class, @selector(operatingSystemVersionString), @selector(hook_operatingSystemVersionString));
        swizzle(NSProcessInfo.class, @selector(isOperatingSystemAtLeastVersion:), @selector(hook_isOperatingSystemAtLeastVersion:));
    }
    if(blockDeviceInfoReads || spoofLowPowerModeEnabledSet) {
        swizzle(NSProcessInfo.class, @selector(isLowPowerModeEnabled), @selector(hook_isLowPowerModeEnabled));
    }
    if(blockDeviceInfoReads || spoofLocale) {
        LCSwizzleClassIfPresent(NSLocale.class, @selector(currentLocale), @selector(hook_currentLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(autoupdatingCurrentLocale), @selector(hook_autoupdatingCurrentLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(systemLocale), @selector(hook_systemLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(preferredLanguages), @selector(hook_preferredLanguages));
    }
    if(blockDeviceInfoReads || spoofTimeZone) {
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(localTimeZone), @selector(hook_localTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(systemTimeZone), @selector(hook_systemTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(defaultTimeZone), @selector(hook_defaultTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(autoupdatingCurrentTimeZone), @selector(hook_autoupdatingCurrentTimeZone));
        LCSwizzleClassIfPresent(NSCalendar.class, @selector(currentCalendar), @selector(hook_currentCalendar));
        LCSwizzleClassIfPresent(NSCalendar.class, @selector(autoupdatingCurrentCalendar), @selector(hook_autoupdatingCurrentCalendar));
    }
    if(blockDeviceInfoReads || spoofRadioAccessTechnology) {
        Class telephonyClass = NSClassFromString(@"CTTelephonyNetworkInfo");
        LCSwizzleIfPresentWithSourceClass(telephonyClass, LCTelephonyNetworkInfoHookProvider.class, @selector(serviceCurrentRadioAccessTechnology), @selector(hook_serviceCurrentRadioAccessTechnology));
    }
    if(blockDeviceInfoReads || spoofSubscriberIdentifier || spoofSubscriberCarrierToken || spoofSubscriberSIMInsertedEnabled) {
        Class subscriberClass = NSClassFromString(@"CTSubscriber");
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"identifier"), @selector(hook_identifier));
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"carrierToken"), @selector(hook_carrierToken));
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"isSIMInserted"), @selector(hook_isSIMInserted));

        Class subscriberInfoClass = NSClassFromString(@"CTSubscriberInfo");
        LCSwizzleClassIfPresentWithSourceClass(subscriberInfoClass, LCSubscriberInfoHookProvider.class, @selector(subscribers), @selector(hook_subscribers));
    }

    // Hardware model spoofing (hw.machine via sysctlbyname / uname)
    // The DYLD_INTERPOSE hooks above are always active but check this variable at runtime.
    NSString *hardwareModel = guestContainerInfo[@"spoofHardwareModel"];
    if([hardwareModel isKindOfClass:NSString.class] && hardwareModel.length > 0) {
        spoofHardwareModel = hardwareModel;
    } else if(blockDeviceInfoReads) {
        // When blocking all device info, return a generic model
        spoofHardwareModel = @"iPhone";
    }

    // HTTP header device identity rewriting
    // Hook NSMutableURLRequest to rewrite User-Agent in ALL outgoing HTTP requests.
    // This catches native iOS, Flutter, React Native, Expo, Firebase, PostHog,
    // Adjust, AppsFlyer, and any analytics SDK — they all go through NSMutableURLRequest.
    if(spoofHardwareModel || spoofSystemVersion) {
        LCInitUserAgentRegexes();
        swizzle(NSMutableURLRequest.class,
            @selector(setValue:forHTTPHeaderField:),
            @selector(hook_setValue:forHTTPHeaderField:));
        swizzle(NSMutableURLRequest.class,
            @selector(addValue:forHTTPHeaderField:),
            @selector(hook_addValue:forHTTPHeaderField:));
        swizzle(NSMutableURLRequest.class,
            @selector(setAllHTTPHeaderFields:),
            @selector(hook_setAllHTTPHeaderFields:));
        swizzle(NSURLSessionConfiguration.class,
            @selector(setHTTPAdditionalHeaders:),
            @selector(hook_setHTTPAdditionalHeaders:));
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

void handleLiveContainerLaunch(NSURL* url) {
    // If it's not current app, then switch
    // check if there are other LCs is running this app
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
        return;
    }
    
    NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    if(!containerFolderName) {
        containerFolderName = findDefaultContainerWithBundleId(bundleName);
    }
    if ([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) {
        if(openUrl) {
            openUniversalLink(openUrl);
        }
    } else {
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
}

void handleCustomSchemeLaunch(NSURL* url) {
    NSString *scheme = url.scheme.lowercaseString;
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    NSString *appsPath = [docPath stringByAppendingPathComponent:@"Applications"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *apps = [fm contentsOfDirectoryAtPath:appsPath error:nil];
    
    NSString* targetBundleName = nil;
    for (NSString *appFolder in apps) {
        NSString *infoPath = [NSString stringWithFormat:@"%@/%@/LCAppInfo.plist", appsPath, appFolder];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSArray *customSchemes = appInfo[@"LCCustomUrlSchemes"];
        if (customSchemes && [customSchemes containsObject:scheme]) {
            targetBundleName = appFolder;
            break;
        }
    }
    
    if (targetBundleName) {
        // Construct livecontainer-launch URL required by launchToGuestAppWithURL
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString *lcUrlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&open-url=%@",
                              NSUserDefaults.lcAppUrlScheme, targetBundleName, encodedUrl];
        NSURL *lcUrl = [NSURL URLWithString:lcUrlStr];
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId:targetBundleName isSharedAppOut:&isSharedApp];
        if (bundle) {
            LCShowSwitchAppConfirmation(lcUrl, targetBundleName, isSharedApp);
        } else {
            LCShowAppNotFoundAlert(targetBundleName);
        }
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
    }); // It now correctly checks all CFBundleURLSchemes, including our injected ones!
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

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSString *url = payload[UIApplicationLaunchOptionsURLKey];
    if ([url hasPrefix:@"file:"]) {
        [[NSURL URLWithString:url] startAccessingSecurityScopedResource];
        [self hook__applicationOpenURLAction:action payload:payload origin:origin];
        return;
    }
    
    if([url hasPrefix:@"sidestore:"]) {
        LCOpenSideStoreURL([NSURL URLWithString:url]);
        return;
    }
    
    if ([url hasPrefix:[NSString stringWithFormat: @"%@://livecontainer-relaunch", NSUserDefaults.lcAppUrlScheme]]) {
        // Ignore
        return;
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://open-web-page?", NSUserDefaults.lcAppUrlScheme]]) {
        // launch to UI and open web page
        NSURLComponents* lcUrl = [NSURLComponents componentsWithString:url];
        NSString* realUrlEncoded = lcUrl.queryItems[0].value;
        if(!realUrlEncoded) return;
        // Convert the base64 encoded url into String
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
        NSString *decodedUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        LCOpenWebPage(decodedUrl, url);
        return;
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
        // pass url to guest app
        NSURLComponents* lcUrl = [NSURLComponents componentsWithString:url];
        NSString* realUrlEncoded = lcUrl.queryItems[0].value;
        if(!realUrlEncoded) return;
        realUrlEncoded = [realUrlEncoded stringByReplacingOccurrencesOfString:@" " withString:@"+"];
        // Convert the base64 encoded url into String
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
        NSString *decodedUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
        } else {
            NSURL *decodedUrlObj = [NSURL URLWithString:decodedUrl];
            NSMutableDictionary* newPayload = [payload mutableCopy];
            newPayload[UIApplicationLaunchOptionsURLKey] = decodedUrlObj ? [decodedUrlObj absoluteString] : decodedUrl;
            [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        }
        
        return;
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://livecontainer-launch?bundle-name=", NSUserDefaults.lcAppUrlScheme]]) {
        handleLiveContainerLaunch([NSURL URLWithString:url]);
        // Not what we're looking for, pass it
        
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://install", NSUserDefaults.lcAppUrlScheme]]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return;
    }
    
    // Intercept URLs belonging to other guest apps running in LiveContainer
    NSURL *parsedUrl = [NSURL URLWithString:url];
    if (parsedUrl && ![NSBundle.mainBundle.bundlePath.lastPathComponent isEqualToString:@"LiveContainer"]) {
        NSString *scheme = parsedUrl.scheme.lowercaseString;
        BOOL isStandardLC = [scheme hasPrefix:@"livecontainer"] || [scheme isEqualToString:@"sidestore"] || [scheme isEqualToString:@"file"] || [scheme hasPrefix:@"http"];
        
        if (!isStandardLC && !canAppOpenItself(parsedUrl)) {
            // It's not standard LC, and it doesn't belong to the current guest app
            handleCustomSchemeLaunch(parsedUrl);
            return;
        }
    }
    
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
    return;
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
                realUrlEncoded = [realUrlEncoded stringByReplacingOccurrencesOfString:@" " withString:@"+"];
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

- (BOOL)hook_openURL:(NSURL*)url {
    [self hook_openURL:url options:@{} completionHandler:nil];
    return YES;
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

    // Don't have UIOpenURLAction or is passing a file to app? pass it
    if (!urlAction || urlAction.url.isFileURL || (NSUserDefaults.isSideStore && ![urlAction.url.scheme isEqualToString:@"livecontainer"])) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    
    if (urlAction.url.isFileURL) {
        [urlAction.url startAccessingSecurityScopedResource];
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    
    if([urlAction.url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(urlAction.url);
        return;
    }

    NSString *url = urlAction.url.absoluteString;
    if ([url hasPrefix:[NSString stringWithFormat: @"%@://livecontainer-relaunch", NSUserDefaults.lcAppUrlScheme]]) {
        // Ignore
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://open-web-page?", NSUserDefaults.lcAppUrlScheme]]) {
        NSURLComponents* lcUrl = [NSURLComponents componentsWithString:url];
        NSString* realUrlEncoded = lcUrl.queryItems[0].value;
        if(!realUrlEncoded) return;
        // launch to UI and open web page
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
        NSString *decodedUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        LCOpenWebPage(decodedUrl, url);
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
        // Open guest app's URL scheme
        NSURLComponents* lcUrl = [NSURLComponents componentsWithString:url];
        NSString* realUrlEncoded = lcUrl.queryItems[0].value;
        if(!realUrlEncoded) return;
        // Convert the base64 encoded url into String
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
        NSString *decodedUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
        } else {
            NSMutableSet *newActions = actions.mutableCopy;
            [newActions removeObject:urlAction];
            NSURL* finalURL = [NSURL URLWithString:decodedUrl];
            if(finalURL) {
                UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
                [newActions addObject:newUrlAction];
                [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
            }
        }

    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://livecontainer-launch?bundle-name=", NSUserDefaults.lcAppUrlScheme]]){
        handleLiveContainerLaunch(urlAction.url);
        
    } else if ([url hasPrefix:[NSString stringWithFormat: @"%@://install", NSUserDefaults.lcAppUrlScheme]]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return;
    }
    
    if ([urlAction.url.scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        actions = newActions;
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
//⭐️⭐️⭐️Real iPhone mode 9:16 hook
@implementation UIScreen (LiveContainerHook)
- (CGRect)hook_UIScreen_bounds {
    NSString *appId = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [appId.lowercaseString containsString:@"sidestore"];
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"] && !isSideStore
) {
        CGRect nativeBounds = [self hook_UIScreen_bounds];
        CGFloat screenH = nativeBounds.size.height;
        CGFloat screenW = nativeBounds.size.width;
        CGFloat targetW = MIN(screenW, screenH * (9.0 / 16.0));
        return CGRectMake(0, 0, targetW, screenH);
    }

    CGRect nativeBounds = [self hook_UIScreen_bounds];
        CGFloat screenH = nativeBounds.size.height;
        CGFloat targetW = nativeBounds.size.width; 
        return CGRectMake(0, 0, targetW, screenH);
}
@end



@implementation LCRealIPhoneModeHelper
//⭐️⭐️⭐️Real iPhone mode 9:16 hook
+ (void)repositionAllWindows {
    //if (![NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) return;

    UIWindowScene *scene = nil;
    for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            scene = s;
            break;
        }
    }
    if (!scene) return;

    CGRect realBounds = scene.coordinateSpace.bounds;
    CGFloat realH = realBounds.size.height;
    CGFloat realW = realBounds.size.width;


NSString *lcappId = NSUserDefaults.lcGuestAppId;
BOOL isSideStore = [lcappId.lowercaseString containsString:@"sidestore"]; 
BOOL isReal = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"];
CGFloat targetW, offsetX;
if (isReal && !isSideStore) {

        targetW = MIN(realH * (9.0/16.0), realW);
        offsetX = (realW - targetW) / 2.0;

    } else {
        targetW = realW;
        offsetX = 0;
    }
    CGRect targetFrame = CGRectMake(offsetX, 0, targetW, realH);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIWindow *window in scene.windows) {
        window.layer.frame = targetFrame;
    }
    [CATransaction commit];
}

@end

//⭐️⭐️⭐️Real iPhone Mode 9:16 hook(black background)

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    NSString *appid = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [appid.lowercaseString containsString:@"sidestore"];
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"] && !isSideStore) {
        self.backgroundColor = [UIColor blackColor];
    }
    [self hook_makeKeyAndVisible];
}


//⭐️⭐️⭐️Real iPhone mode 9:16 hook
- (void)hook_setFrame:(CGRect)frame {
    NSString *lcappid = NSUserDefaults.lcGuestAppId;
    BOOL isSideStore = [lcappid.lowercaseString containsString:@"sidestore"];
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"] && !isSideStore) {

        UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
        CGRect screenBounds = scene ? scene.coordinateSpace.bounds : frame;

        CGFloat realH = screenBounds.size.height;
        CGFloat realW = screenBounds.size.width;
        if (realH == 0 || realW == 0) {
            [self hook_setFrame:frame];
            return;
        }

        CGFloat targetW = MIN(realW, realH * (9.0 / 16.0));
        CGFloat offsetX = (realW - targetW) / 2.0;

        [self hook_setFrame:CGRectMake(offsetX, 0, targetW, realH)];
    } else {
        UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
        CGRect screenBounds = scene ? scene.coordinateSpace.bounds : frame;
        CGFloat realH = screenBounds.size.height;
        CGFloat realW = screenBounds.size.width;
        if (realH == 0 || realW == 0) {
            [self hook_setFrame:frame];
            return;
        }
        [self hook_setFrame:CGRectMake(0, 0, realW, realH)];
        //frame];
    }
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

@implementation UIDevice(hook)

- (NSUUID*)hook_identifierForVendor {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(idForVendorUUID) {
        return idForVendorUUID;
    }
    return [self hook_identifierForVendor];
}

- (NSString *)hook_name {
    if(blockDeviceInfoReads) {
        return @"Unknown";
    }
    if(spoofProfileEnabled && spoofDeviceName.length > 0) {
        return spoofDeviceName;
    }
    return [self hook_name];
}

- (NSString *)hook_model {
    if(blockDeviceInfoReads) {
        return @"Unknown";
    }
    if(spoofProfileEnabled && spoofDeviceModel.length > 0) {
        return spoofDeviceModel;
    }
    return [self hook_model];
}

- (NSString *)hook_localizedModel {
    if(blockDeviceInfoReads) {
        return @"Unknown";
    }
    if(spoofProfileEnabled && spoofDeviceModel.length > 0) {
        return spoofDeviceModel;
    }
    return [self hook_localizedModel];
}

- (NSString *)hook_systemName {
    if(blockDeviceInfoReads) {
        return @"Unknown";
    }
    if(spoofProfileEnabled && spoofSystemName.length > 0) {
        return spoofSystemName;
    }
    return [self hook_systemName];
}

- (NSString *)hook_systemVersion {
    if(blockDeviceInfoReads) {
        return @"0.0";
    }
    if(spoofProfileEnabled && spoofSystemVersion.length > 0) {
        return spoofSystemVersion;
    }
    return [self hook_systemVersion];
}

- (float)hook_batteryLevel {
    if(blockDeviceInfoReads) {
        return -1.0f;
    }
    if(spoofProfileEnabled && spoofBatteryLevel >= 0.0f) {
        return spoofBatteryLevel;
    }
    return [self hook_batteryLevel];
}

- (UIDeviceBatteryState)hook_batteryState {
    if(blockDeviceInfoReads) {
        return UIDeviceBatteryStateUnknown;
    }
    if(spoofProfileEnabled && spoofBatteryState >= UIDeviceBatteryStateUnknown && spoofBatteryState <= UIDeviceBatteryStateFull) {
        return (UIDeviceBatteryState)spoofBatteryState;
    }
    return [self hook_batteryState];
}

- (BOOL)hook_isBatteryMonitoringEnabled {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && (spoofBatteryLevel >= 0.0f || spoofBatteryState != UIDeviceBatteryStateUnknown)) {
        return YES;
    }
    return [self hook_isBatteryMonitoringEnabled];
}

@end

@implementation NSProcessInfo(hook)

- (NSOperatingSystemVersion)hook_operatingSystemVersion {
    if(blockDeviceInfoReads) {
        return (NSOperatingSystemVersion){ .majorVersion = 0, .minorVersion = 0, .patchVersion = 0 };
    }
    if(spoofProfileEnabled && spoofOperatingSystemVersionValid) {
        return spoofOperatingSystemVersion;
    }
    return [self hook_operatingSystemVersion];
}

- (NSString *)hook_operatingSystemVersionString {
    if(blockDeviceInfoReads) {
        return @"Unknown";
    }
    if(spoofProfileEnabled && spoofSystemVersion.length > 0) {
        NSString *name = spoofSystemName.length > 0 ? spoofSystemName : @"iOS";
        return [NSString stringWithFormat:@"%@ %@", name, spoofSystemVersion];
    }
    return [self hook_operatingSystemVersionString];
}

- (BOOL)hook_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofOperatingSystemVersionValid) {
        return LCCompareOSVersion(spoofOperatingSystemVersion, version) >= 0;
    }
    return [self hook_isOperatingSystemAtLeastVersion:version];
}

- (BOOL)hook_isLowPowerModeEnabled {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofLowPowerModeEnabledSet) {
        return spoofLowPowerModeEnabled;
    }
    return [self hook_isLowPowerModeEnabled];
}

@end

@implementation NSLocale(hook)

+ (NSLocale *)hook_currentLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_currentLocale];
}

+ (NSLocale *)hook_autoupdatingCurrentLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_autoupdatingCurrentLocale];
}

+ (NSLocale *)hook_systemLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_systemLocale];
}

+ (NSArray<NSString *> *)hook_preferredLanguages {
    if(blockDeviceInfoReads) {
        return @[@"und"];
    }
    if(spoofProfileEnabled && spoofLocale) {
        NSString *languageIdentifier = [spoofLocale objectForKey:NSLocaleIdentifier];
        if(languageIdentifier.length > 0) {
            return @[languageIdentifier];
        }
    }
    return [self hook_preferredLanguages];
}

@end

@implementation NSTimeZone(hook)

+ (NSTimeZone *)hook_localTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_localTimeZone];
}

+ (NSTimeZone *)hook_systemTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_systemTimeZone];
}

+ (NSTimeZone *)hook_defaultTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_defaultTimeZone];
}

+ (NSTimeZone *)hook_autoupdatingCurrentTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_autoupdatingCurrentTimeZone];
}

@end

@implementation NSCalendar(hook)

+ (NSCalendar *)hook_currentCalendar {
    if(blockDeviceInfoReads) {
        NSCalendar *calendar = [self hook_currentCalendar];
        calendar.timeZone = LCBlockedTimeZone();
        return calendar;
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        NSCalendar *calendar = [self hook_currentCalendar];
        calendar.timeZone = spoofTimeZone;
        return calendar;
    }
    return [self hook_currentCalendar];
}

+ (NSCalendar *)hook_autoupdatingCurrentCalendar {
    if(blockDeviceInfoReads) {
        NSCalendar *calendar = [self hook_autoupdatingCurrentCalendar];
        calendar.timeZone = LCBlockedTimeZone();
        return calendar;
    }
    if(spoofProfileEnabled && spoofTimeZone) {
        NSCalendar *calendar = [self hook_autoupdatingCurrentCalendar];
        calendar.timeZone = spoofTimeZone;
        return calendar;
    }
    return [self hook_autoupdatingCurrentCalendar];
}

@end

@implementation LCTelephonyNetworkInfoHookProvider

- (id)hook_serviceCurrentRadioAccessTechnology {
    if(blockDeviceInfoReads) {
        return @{};
    }
    if(spoofProfileEnabled && spoofRadioAccessTechnology.length > 0) {
        return @{
            @"0000000100000001": spoofRadioAccessTechnology
        };
    }
    return [self hook_serviceCurrentRadioAccessTechnology];
}

@end

@implementation LCSubscriberHookProvider

- (id)hook_identifier {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(spoofProfileEnabled && spoofSubscriberIdentifier.length > 0) {
        return spoofSubscriberIdentifier;
    }
    return [self hook_identifier];
}

- (id)hook_carrierToken {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(spoofProfileEnabled && spoofSubscriberCarrierToken) {
        return spoofSubscriberCarrierToken;
    }
    return [self hook_carrierToken];
}

- (BOOL)hook_isSIMInserted {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofSubscriberSIMInsertedEnabled) {
        return spoofSubscriberSIMInserted;
    }
    return [self hook_isSIMInserted];
}

@end

@implementation LCSubscriberInfoHookProvider

+ (id)hook_subscribers {
    if(blockDeviceInfoReads) {
        return @[];
    }
    return [self hook_subscribers];
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
