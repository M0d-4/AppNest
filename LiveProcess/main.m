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

// File-based logging
static FILE *g_logFile = NULL;
static void lcLogToFile(NSString *msg) {
    if (g_logFile) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"hh:mm:ss.SSS a";
        NSString *_line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg]; fputs(_line.UTF8String, g_logFile);
        fflush(g_logFile);
    }
}
#define LCLOG(fmt, ...) do { NSString *_m = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; NSLog(@"%@", _m); lcLogToFile(_m); } while(0)

static void initLogFile(void) {
    // Try to write to app group container (accessible to main app)
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *logPath = nil;
    // Try each possible app group
    // Enumerate all app groups from the process entitlements
    // Use SecTaskCopyValueForEntitlement to read at runtime
    NSArray *bundleGroups = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"com.apple.security.application-groups"];
    // Also try common patterns with the team ID extracted from bundle ID
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *teamID = parts.count >= 3 ? parts[2] : @"";
    NSMutableArray *groupsToTry = [NSMutableArray array];
    if (bundleGroups) [groupsToTry addObjectsFromArray:bundleGroups];
    if (teamID.length) {
        [groupsToTry addObject:[@"group.com.SideStore.SideStore." stringByAppendingString:teamID]];
        [groupsToTry addObject:[@"group.com.rileytestut.AltStore." stringByAppendingString:teamID]];
    }
    for (NSString *gid in groupsToTry) {
        NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        if (url) {
            NSString *logsDir = [url.path stringByAppendingPathComponent:@"Logs"];
            [fm createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
            logPath = [logsDir stringByAppendingPathComponent:@"liveprocess_ext.log"];
            break;
        }
    }
    if (!logPath) logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"liveprocess_ext.log"];
    g_logFile = fopen(logPath.fileSystemRepresentation, "w");
    NSLog(@"[LC-LP] Extension log: %@", logPath);
}

static dispatch_semaphore_t g_appInfoSemaphore;

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
    // Signal the background thread to proceed with LiveContainerMain
    LCLOG(@"[LC-LP] Signaling semaphore to unblock LiveContainerMain thread");
    if (g_appInfoSemaphore) {
        dispatch_semaphore_signal(g_appInfoSemaphore);
    }
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
static dispatch_semaphore_t g_appInfoSemaphore;

int LiveProcessMain(int argc, char *argv[]) {
    LCLOG(@"[LC-LP] LiveProcessMain started - ServiceType=Application, using semaphore approach");
    if (!g_appInfoSemaphore) g_appInfoSemaphore = dispatch_semaphore_create(0);

    // Run LiveContainerMain on a background thread so we don't block the main thread.
    // UIKit needs the main thread free to call beginRequestWithExtensionContext.
    int capturedArgc = argc;
    char **capturedArgv = argv;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        LCLOG(@"[LC-LP] Background thread: waiting for beginRequestWithExtensionContext");
        dispatch_semaphore_wait(g_appInfoSemaphore, DISPATCH_TIME_FOREVER);
        LCLOG(@"[LC-LP] Background thread: semaphore signaled, running LiveContainerMain");

        NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
        LCLOG(@"[LC-LP] appInfo=%@", appInfo);
        NSCAssert(appInfo, @"Failed to retrieve app info");

    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        NSCAssert(appInfo, @"Failed to load custom payload dylib at path: %@", customPayloadDylib);

        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        NSCAssert(customPayloadEntry, @"Missing customPayloadEntry");
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        (void)payloadEntry(capturedArgc, capturedArgv, _envp, _apple);
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

    
        (void)LiveContainerMain(capturedArgc, capturedArgv);
        LCLOG(@"[LC-LP] Background thread: LiveContainerMain returned");
    });

    // Return 0 immediately - let UIKit's run loop take over the main thread.
    // beginRequestWithExtensionContext will be called by UIKit and will signal the semaphore.
    LCLOG(@"[LC-LP] LiveProcessMain returning 0 - main thread free for UIKit");
    return 0;
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    LCLOG(@"[LC-LP] UIApplicationMain called - routing to LiveProcessMain");
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
    initLogFile();
    LCLOG(@"[LC-LP] NSExtensionMain called");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // Try offsets 0-8 to find the correct ADRP pattern for dlopen on this iOS version
    BOOL hooked = NO;
    for (uint32_t offset = 0; offset <= 8 && !hooked; offset++) {
        if (performHookDyldApi("dlopen", offset, (void**)&orig_dlopen, hook_dlopen)) {
            LCLOG(@"[LC-LP] dlopen hooked at adrpOffset=%u", offset);
            hooked = YES;
        }
    }
    if (!hooked) {
        LCLOG(@"[LC-LP] WARNING: dlopen hook failed for all offsets - UIApplicationMain may not be called");
    }
    // call the real one
    _envp = envp;
    _apple = apple;
    LCLOG(@"[LC-LP] Calling orig_NSExtensionMain");
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    int ret = orig_NSExtensionMain(argc, argv);
    LCLOG(@"[LC-LP] orig_NSExtensionMain returned %d", ret);
    return ret;
}
