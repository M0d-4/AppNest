#import <Foundation/Foundation.h>
#import "utils.h"

static BOOL shouldEnableSandboxExtensions(void) {
    return [NSUserDefaults.guestAppInfo[@"enableSandboxExtensions"] boolValue];
}

@implementation NSURL (GuestHooks)

+ (instancetype)hook_URLByResolvingBookmarkData:(NSData *)bookmarkData options:(NSURLBookmarkResolutionOptions)options relativeToURL:(NSURL *)relativeURL bookmarkDataIsStale:(BOOL *)isStale error:(NSError **)error {
    if (shouldEnableSandboxExtensions()) {
        return [self hook_URLByResolvingBookmarkData:bookmarkData options:options relativeToURL:relativeURL bookmarkDataIsStale:isStale error:error];
    } else {
        return [self hook_URLByResolvingBookmarkData:bookmarkData options:options relativeToURL:relativeURL bookmarkDataIsStale:isStale error:error];
    }
}

- (NSData *)hook_bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)options includingResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys relativeToURL:(NSURL *)relativeURL error:(NSError **)error {
    if (shouldEnableSandboxExtensions()) {
        return nil;
    } else {
        return [self hook_bookmarkDataWithOptions:options includingResourceValuesForKeys:keys relativeToURL:relativeURL error:error];
    }
}

@end

void SandboxGuestHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            if (shouldEnableSandboxExtensions()) {
                swizzle(NSURL.class, @selector(URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:), @selector(hook_URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:));
                swizzle(NSURL.class, @selector(bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:), @selector(hook_bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:));
            }
        } @catch (NSException *exception) {
            NSLog(@"[LC] Error initializing Sandbox hooks: %@", exception);
        }
    });
}
