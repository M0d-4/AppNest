//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import "LiveProcessHandler.h"
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "../MultitaskSupport/LCMultitaskXPCService.h"
#import "../SideStore/XPCServer.h"

// File-based logging so the launch trace is accessible without Xcode
static FILE *g_logFile = NULL;
static void lcLogToFile(NSString *msg) {
    if (g_logFile) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];
        fprintf(g_logFile, "[%s] %s\n", ts.UTF8String, msg.UTF8String);
        fflush(g_logFile);
    }
}

#define LCLOG(fmt, ...) do { NSString *_m = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; NSLog(@"%@", _m); lcLogToFile(_m); } while(0)

static void initLogFile(void) {
    // Try each known app group prefix until we find a writable container
    NSArray *prefixes = @[
        @"group.com.SideStore.SideStore.",
        @"group.com.rileytestut.AltStore.",
    ];
    NSString *teamID = nil;
    // Extract team ID from the main bundle identifier's provisioning
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    // Try to find the group container by probing known prefixes + any suffix
    NSURL *groupURL = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    // Probe all app groups the process is entitled to
    NSDictionary *entitlements = [NSBundle mainBundle].infoDictionary;
    NSArray *groups = entitlements[@"com.apple.security.application-groups"];
    for (NSString *g in groups) {
        NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:g];
        if (url) { groupURL = url; break; }
    }
    if (!groupURL) groupURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSURL *logsDir = [groupURL URLByAppendingPathComponent:@"Logs"];
    [fm createDirectoryAtURL:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *logURL = [logsDir URLByAppendingPathComponent:@"liveprocess_launch.log"];
    g_logFile = fopen(logURL.fileSystemRepresentation, "w");
    NSLog(@"[LC-LP] Writing launch log to: %@", logURL.path);
}

@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

+ (LiveProcessHandler *)sharedInstance {
    return extensionContext._principalObject;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    LCLOG(@"[LC-LP] beginRequestWithExtensionContext called");
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    LCLOG(@"[LC-LP] retrievedAppInfo keys: %@", retrievedAppInfo.allKeys);
    // Return control to LiveContainerMain
    LCLOG(@"[LC-LP] Calling CFRunLoopStop");
    CFRunLoopStop(CFRunLoopGetMain());
    LCLOG(@"[LC-LP] CFRunLoopStop called");
}

- (void)initializeMultitaskEndpoint:(NSXPCListenerEndpoint *)endpoint {
    NSXPCConnection* connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCMultitaskXPCServiceProtocol)];
    connection.interruptionHandler = ^{
        NSLog(@"LiveProcessHandler+Multitask: interrupted!!!");
    };
    [connection activate];
    self.server = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        NSLog(@"synchronousRemoteObjectProxyWithErrorHandler encountered an error: %@", error.localizedDescription);
    }];
    self.connection = connection;
}
@end

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;
int LiveProcessMain(int argc, char *argv[]) {
    LCLOG(@"[LC-LP] LiveProcessMain started");
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    LCLOG(@"[LC-LP] Waiting for beginRequestWithExtensionContext via CFRunLoopRun...");
    CFRunLoopRun();
    LCLOG(@"[LC-LP] CFRunLoopRun returned");
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    LCLOG(@"[LC-LP] appInfo = %@", appInfo);
    NSCAssert(appInfo, @"Failed to retrieve app info");

    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        NSCAssert(appInfo, @"Failed to load custom payload dylib at path: %@", customPayloadDylib);

        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        NSCAssert(customPayloadEntry, @"Missing customPayloadEntry");
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        return payloadEntry(argc, argv, _envp, _apple);
    }

    NSLog(@"Retrieved app info: %@", appInfo);
    // Set LiveContainer's home path
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // Pass selected app info to user defaults
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults setObject:appInfo[@"hostFBSIdentityToken"] forKey:@"hostFBSIdentityToken"];
    [lcUserDefaults setObject:appInfo[@"hostUrlScheme"] forKey:@"hostUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"launchAppUrlScheme"] forKey:@"launchAppUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"selected"] forKey:@"selected"];
    [lcUserDefaults setObject:appInfo[@"selectedContainer"] forKey:@"selectedContainer"];
    
    bool access = false;
    NSArray* bookmarks = appInfo[@"bookmarks"];
    NSMutableArray<NSURL *>* bookmarkedUrls = [NSMutableArray array];
    for(int i = 0; i < bookmarks.count; i++) {
        bool isStale = false;
        NSError* error = nil;
        bookmarkedUrls[i] = [NSURL URLByResolvingBookmarkData:bookmarks[i] options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];
    }
    
    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        if(access && bookmarkedUrls.count > 0) {
            [lcUserDefaults setObject:bookmarkedUrls.firstObject.path forKey:@"specifiedSideStoreContainerPath"];
        }
        [LiveProcessSideStoreHandler initializeWithEndpoint:appInfo[@"endpoint"]];
    } else {
        [LiveProcessHandler.sharedInstance initializeMultitaskEndpoint:appInfo[@"endpoint"]];
    }

    
    return LiveContainerMain(argc, argv);
}

static uint32_t g_dlopenHookOffset = 0;
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // unhook and let UIKit load via RTLD_MAIN_ONLY so our UIApplicationMain is used
        performHookDyldApi("dlopen", g_dlopenHookOffset, (void**)&orig_dlopen, orig_dlopen);
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Our UIApplicationMain interposes UIKit's - routes to LiveProcessMain.
// This is the fallback path when the dlopen hook fails.
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    LCLOG(@"[LC-LP] UIApplicationMain interpose called - routing to LiveProcessMain");
    return LiveProcessMain(argc, argv);
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
    initLogFile();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    _envp = envp;
    _apple = apple;

    // Try offsets 0-6 to find the correct ADRP pattern for dlopen on this iOS version.
    // On success the hook intercepts UIKit's load and returns RTLD_MAIN_ONLY.
    // On failure UIKit loads normally and calls our interposing UIApplicationMain above.
    BOOL hooked = NO;
    for (uint32_t offset = 0; offset <= 6 && !hooked; offset++) {
        if (performHookDyldApi("dlopen", offset, (void**)&orig_dlopen, hook_dlopen)) {
            g_dlopenHookOffset = offset;
            NSLog(@"[LC] NSExtensionMain: dlopen hooked at adrpOffset=%u", offset);
            hooked = YES;
        }
    }
    if (!hooked) {
        NSLog(@"[LC] NSExtensionMain: dlopen hook failed, relying on UIApplicationMain interpose");
    }

    LCLOG(@"[LC-LP] Calling orig_NSExtensionMain");
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    int ret = orig_NSExtensionMain(argc, argv);
    LCLOG(@"[LC-LP] orig_NSExtensionMain returned: %d", ret);
    return ret;
}
