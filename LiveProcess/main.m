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
    if (!g_logFile) return;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"hh:mm:ss.SSS a";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg];
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(data.bytes, 1, data.length, g_logFile);
    fflush(g_logFile);
}
#define LCLOG(fmt, ...) do { NSString *_m = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; NSLog(@"%@", _m); lcLogToFile(_m); } while(0)

static void initLogFile(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *logsDir = [docs stringByAppendingPathComponent:@"Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *logPath = [logsDir stringByAppendingPathComponent:@"liveprocess_launch.log"];
    g_logFile = fopen(logPath.fileSystemRepresentation, "w");
}

extern int LiveContainerMain(int argc, char *argv[]);
static int g_savedArgc;
static char **g_savedArgv;

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
    // Launch LiveContainerMain on a background thread so UIKit's main thread stays free
    LCLOG(@"[LC-LP] Launching LiveContainerMain on background thread");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        LCLOG(@"[LC-LP] Background thread: calling LiveContainerMain");
        (void)LiveContainerMain(g_savedArgc, g_savedArgv);
        LCLOG(@"[LC-LP] Background thread: LiveContainerMain returned");
    });
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
    LCLOG(@"[LC-LP] LiveProcessMain started - saving args, returning immediately");
    // Save args for use in beginRequestWithExtensionContext callback
    g_savedArgc = argc;
    g_savedArgv = argv;
    // Return immediately - don't block the main thread.
    // LiveContainerMain will be called from beginRequestWithExtensionContext.
    return 0;
    // The code below is kept for reference but runs in the background thread instead:
    if (0) {
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    LCLOG(@"[LC-LP] appInfo=%@", appInfo);
    if (!appInfo) { return 0; }

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

    
    return 0;
    } // end if(0)
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
// Renamed to lc_UIApplicationMain; the public symbol UIApplicationMain is declared
// via DYLD_INTERPOSE below so dyld always routes calls to our version.
static int lc_UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    LCLOG(@"[LC-LP] UIApplicationMain called - routing to LiveProcessMain");
    return LiveProcessMain(argc, argv);
}

// Guarantee that ALL calls to UIApplicationMain (including those from UIKit loaded
// dynamically by NSExtensionMain) resolve to our version, regardless of whether
// the dlopen vtable hook succeeds.  dyld processes this table at image-load time.
typedef int (*UIApplicationMain_t)(int, char * _Nonnull * _Nonnull, NSString * _Nullable, NSString * _Nullable);
__attribute__((used, section("__DATA,__interpose")))
static struct { UIApplicationMain_t replacement; UIApplicationMain_t original; }
lc_UIApplicationMain_interpose = {
    (UIApplicationMain_t)lc_UIApplicationMain,
    (UIApplicationMain_t)UIApplicationMain
};

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
// Track the adrpOffset at which the dlopen vtable hook was installed,
// so we can unhook from the exact same slot.
static uint32_t g_dlopenHookAdrpOffset = 2;
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    // Accept any path containing UIKit.framework to handle iOS 26 path variants
    if(path && strstr(path, "UIKit.framework")) {
        // Unhook using the same offset we installed at, to patch the right vtable slot
        performHookDyldApi("dlopen", g_dlopenHookAdrpOffset, (void**)&orig_dlopen, orig_dlopen);
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
    Method xpcDecoderMethod = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:));
    if (xpcDecoderMethod) {
        method_setImplementation(xpcDecoderMethod, (IMP)hook_do_nothing);
    }
#pragma clang diagnostic pop
    // Try offsets 0-30 to find the correct ADRP pattern for dlopen on this iOS version.
    // iOS 26 / dyld 1000+ may use offsets beyond 20 (internally +20 is also tried per call).
    // The DYLD_INTERPOSE above is the primary guarantee; this hook is a belt-and-suspenders
    // optimization that lets orig_UIApplicationMain also resolve to our version via dlsym.
    BOOL hooked = NO;
    for (uint32_t offset = 0; offset <= 30 && !hooked; offset++) {
        if (performHookDyldApi("dlopen", offset, (void**)&orig_dlopen, hook_dlopen)) {
            g_dlopenHookAdrpOffset = offset;
            LCLOG(@"[LC-LP] dlopen hooked at adrpOffset=%u", offset);
            hooked = YES;
        }
    }
    if (!hooked) {
        LCLOG(@"[LC-LP] dlopen hook failed for all offsets - falling back to DYLD_INTERPOSE (UIApplicationMain already redirected at load time)");
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
