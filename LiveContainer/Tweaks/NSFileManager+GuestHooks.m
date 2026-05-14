@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>

BOOL isolateAppGroup = NO;
BOOL strictTestMode = NO;
static BOOL readOnlyBundle = NO;
void* webKitHeader = 0;

static BOOL isPathInMainBundle(NSString *path) {
    NSString *mainBundlePath = NSBundle.mainBundle.bundlePath;
    return [path hasPrefix:mainBundlePath];
}

static NSString *LCSanitizedGroupIdentifier(NSString *groupIdentifier) {
    if (![groupIdentifier isKindOfClass:NSString.class] || groupIdentifier.length == 0) {
        return @"lc.unknown.group";
    }

    static NSCharacterSet *allowedCharacters = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    });

    NSMutableString *sanitized = [NSMutableString stringWithCapacity:groupIdentifier.length];
    for (NSUInteger idx = 0; idx < groupIdentifier.length; idx++) {
        unichar ch = [groupIdentifier characterAtIndex:idx];
        if ([allowedCharacters characterIsMember:ch]) {
            [sanitized appendFormat:@"%C", ch];
        } else {
            [sanitized appendString:@"_"];
        }
    }
    return sanitized.length > 0 ? sanitized : @"lc.unknown.group";
}

static NSURL *LCBaseGroupContainerURL(void) {
    if (isolateAppGroup) {
        NSString *homePath = [NSString stringWithUTF8String:getenv("HOME") ?: ""];
        return [NSURL fileURLWithPath:[homePath stringByAppendingPathComponent:@"LCAppGroup"] isDirectory:YES];
    }
    if (NSUserDefaults.lcAppGroupPath.length > 0) {
        return [NSURL fileURLWithPath:[NSUserDefaults.lcAppGroupPath stringByAppendingPathComponent:@"LiveContainer/Data/AppGroup"] isDirectory:YES];
    }
    NSString *lcHomePath = [NSString stringWithUTF8String:getenv("LC_HOME_PATH") ?: ""];
    return [NSURL fileURLWithPath:[lcHomePath stringByAppendingPathComponent:@"Documents/Data/AppGroup"] isDirectory:YES];
}

static void LCEnsureGroupContainerScaffold(NSURL *containerURL) {
    if (!containerURL) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:containerURL withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *libraryURL = [containerURL URLByAppendingPathComponent:@"Library" isDirectory:YES];
    [fm createDirectoryAtURL:libraryURL withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *cachesURL = [libraryURL URLByAppendingPathComponent:@"Caches" isDirectory:YES];
    [fm createDirectoryAtURL:cachesURL withIntermediateDirectories:YES attributes:nil error:nil];
}

void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    strictTestMode = [infoDict[@"strictTestMode"] boolValue];
    isolateAppGroup = strictTestMode || [infoDict[@"isolateAppGroup"] boolValue];
    readOnlyBundle = [infoDict[@"readOnlyBundle"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));

    if (readOnlyBundle) {
        swizzle(NSFileManager.class, @selector(createFileAtPath:contents:attributes:), @selector(hook_createFileAtPath:contents:attributes:));
        swizzle(NSFileManager.class, @selector(removeItemAtPath:error:), @selector(hook_removeItemAtPath:error:));
        swizzle(NSFileManager.class, @selector(moveItemAtPath:toPath:error:), @selector(hook_moveItemAtPath:toPath:error:));
        swizzle(NSFileManager.class, @selector(setAttributes:ofItemAtPath:error:), @selector(hook_setAttributes:ofItemAtPath:error:));
    }
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        saveCachedSymbol(@"webKitHeader", dscPtr, webKitHeader-dscPtr);
    }
    
    swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (BOOL)hook_createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey,id> *)attr {
    if (readOnlyBundle && isPathInMainBundle(path)) {
        NSLog(@"[LC] Denying write to main bundle: %@", path);
        return NO;
    }
    return [self hook_createFileAtPath:path contents:data attributes:attr];
}

- (BOOL)hook_removeItemAtPath:(NSString *)path error:(NSError **)error {
    if (readOnlyBundle && isPathInMainBundle(path)) {
        NSLog(@"[LC] Denying item removal in main bundle: %@", path);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey: @"Operation not permitted"}];
        }
        return NO;
    }
    return [self hook_removeItemAtPath:path error:error];
}

- (BOOL)hook_moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    if (readOnlyBundle && (isPathInMainBundle(srcPath) || isPathInMainBundle(dstPath))) {
        NSLog(@"[LC] Denying item move in main bundle: %@ -> %@", srcPath, dstPath);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey: @"Operation not permitted"}];
        }
        return NO;
    }
    return [self hook_moveItemAtPath:srcPath toPath:dstPath error:error];
}

- (BOOL)hook_setAttributes:(NSDictionary<NSFileAttributeKey,id> *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error {
    if (readOnlyBundle && isPathInMainBundle(path)) {
        NSLog(@"[LC] Denying attribute change in main bundle: %@", path);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey: @"Operation not permitted"}];
        }
        return NO;
    }
    return [self hook_setAttributes:attributes ofItemAtPath:path error:error];
}

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        NSURL *appGroupURL = [NSURL fileURLWithPath:NSUserDefaults.lcAppGroupPath];
        LCEnsureGroupContainerScaffold(appGroupURL);
        return appGroupURL;
    }
    NSString *safeGroupIdentifier = LCSanitizedGroupIdentifier(groupIdentifier);
    NSURL *baseURL = LCBaseGroupContainerURL();
    [NSFileManager.defaultManager createDirectoryAtURL:baseURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *result = [baseURL URLByAppendingPathComponent:safeGroupIdentifier isDirectory:YES];
    LCEnsureGroupContainerScaffold(result);
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    void* callerAddr = __builtin_return_address(0);
    if(callerAddr > webKitHeader && callerAddr < (webKitHeader + (32 << 20) )) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            const char *lcHomePath = getenv(NSUserDefaults.isLiveProcess ? "LP_HOME_PATH" : "LC_HOME_PATH");
            NSString *libraryPath = [@(lcHomePath) stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            NSString* appCookiesPath = [@(getenv("HOME")) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end
