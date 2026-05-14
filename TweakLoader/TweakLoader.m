#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <objc/runtime.h>
#include "utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "DeviceCheck+GuestHooks.h"
#import "UIDevice+GuestHooks.h"
#import "CoreTelephony+GuestHooks.h"
#import "Sandbox+GuestHooks.h"

static NSString *const kDisabledTweaksKey = @"disabledItems";
static NSString *const kContainerInfoFileName = @"LCContainerInfo.plist";
static NSString *const kStrictSessionMarkerFileName = @".lc_strict_session_active";
static BOOL strictTestModeEnabled = NO;
static BOOL strictAutoWipeOnExitEnabled = NO;
static BOOL strictAutoWipePerformed = NO;
static NSString *strictContainerHomePath = nil;
static id strictWillTerminateObserver = nil;

static void LCStrictAutoWipeOnExit(void);

static void LCStrictEnsureContainerDirectories(NSString *homePath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *directories = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData", @"tmp"];
    for(NSString *directory in directories) {
        NSString *path = [homePath stringByAppendingPathComponent:directory];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static NSString *LCStrictSessionMarkerPath(NSString *homePath) {
    if(homePath.length == 0) {
        return nil;
    }
    return [homePath stringByAppendingPathComponent:kStrictSessionMarkerFileName];
}

static void LCStrictWriteSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager createFileAtPath:markerPath contents:[NSData data] attributes:nil];
}

static void LCStrictRemoveSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:markerPath error:nil];
}

static BOOL LCStrictSessionMarkerExists(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return NO;
    }
    return [NSFileManager.defaultManager fileExistsAtPath:markerPath];
}

static void LCStrictWipeContainerContentsIfNeeded(void) {
    if(!strictTestModeEnabled || !strictAutoWipeOnExitEnabled) {
        return;
    }
    NSString *homePath = strictContainerHomePath;
    if(homePath.length == 0 || [homePath isEqualToString:@"/"]) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *containerInfoPath = [homePath stringByAppendingPathComponent:kContainerInfoFileName];
    if(![fm fileExistsAtPath:containerInfoPath]) {
        return;
    }

    NSError *listError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:homePath error:&listError];
    if(!entries) {
        NSLog(@"[LC][StrictMode] Failed to enumerate container for auto-wipe: %@", listError.localizedDescription);
        return;
    }

    for(NSString *entry in entries) {
        if([entry isEqualToString:kContainerInfoFileName]) {
            continue;
        }
        NSString *entryPath = [homePath stringByAppendingPathComponent:entry];
        NSError *removeError = nil;
        if(![fm removeItemAtPath:entryPath error:&removeError] && removeError) {
            NSLog(@"[LC][StrictMode] Failed to remove %@ during auto-wipe: %@", entry, removeError.localizedDescription);
        }
    }

    LCStrictEnsureContainerDirectories(homePath);
}

static void LCStrictRecoverStaleSessionIfNeeded(void) {
    if(!strictAutoWipeOnExitEnabled || strictContainerHomePath.length == 0) {
        return;
    }
    if(LCStrictSessionMarkerExists(strictContainerHomePath)) {
        NSLog(@"[LC][StrictMode] Detected stale strict session marker. Applying deferred auto-wipe.");
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static void LCStrictRegisterLifecycleObservers(void) {
    if(!strictAutoWipeOnExitEnabled || strictWillTerminateObserver != nil) {
        return;
    }
    strictWillTerminateObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        LCStrictAutoWipeOnExit();
    }];
}

static void LCStrictAutoWipeOnExit(void) {
    @autoreleasepool {
        if(strictAutoWipePerformed) {
            return;
        }
        strictAutoWipePerformed = YES;
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static NSSet<NSString *> *disabledItemsForFolder(NSURL *folderURL) {
    if (!folderURL || !folderURL.isFileURL) {
        return [NSSet set];
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[folderURL URLByAppendingPathComponent:@"TweakInfo.plist"]];
    NSArray<NSString *> *disabled = info[kDisabledTweaksKey];
    if (![disabled isKindOfClass:NSArray.class]) {
        return [NSSet set];
    }
    return [NSSet setWithArray:disabled];
}

static BOOL isTweakURLDisabled(NSURL *url, NSURL *rootFolderURL) {
    if (!url || !rootFolderURL) {
        return NO;
    }
    NSURL *cursor = url;
    NSString *rootPath = [rootFolderURL.path stringByStandardizingPath];
    while (cursor && [[cursor.path stringByStandardizingPath] hasPrefix:rootPath]) {
        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        NSSet<NSString *> *disabled = disabledItemsForFolder(parent);
        if ([disabled containsObject:cursor.lastPathComponent]) {
            return YES;
        }
        if ([[cursor.path stringByStandardizingPath] isEqualToString:rootPath]) {
            break;
        }
        cursor = parent;
    }
    return NO;
}

void DeviceCheckGuestHooksInit(void);
void UIDeviceGuestHooksInit(void);
void CoreTelephonyGuestHooksInit(void);
void SandboxGuestHooksInit(void);

static NSString *const kDisabledTweaksKey = @"disabledItems";

static NSSet<NSString *> *disabledItemsForFolder(NSURL *folderURL) {
    if (!folderURL || !folderURL.isFileURL) {
        return [NSSet set];
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[folderURL URLByAppendingPathComponent:@"TweakInfo.plist"]];
    NSArray<NSString *> *disabled = info[kDisabledTweaksKey];
    if (![disabled isKindOfClass:NSArray.class]) {
        return [NSSet set];
    }
    return [NSSet setWithArray:disabled];
}

static BOOL isTweakURLDisabled(NSURL *url, NSURL *rootFolderURL) {
    if (!url || !rootFolderURL) {
        return NO;
    }
    NSURL *cursor = url;
    NSString *rootPath = [rootFolderURL.path stringByStandardizingPath];
    while (cursor && [[cursor.path stringByStandardizingPath] hasPrefix:rootPath]) {
        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        NSSet<NSString *> *disabled = disabledItemsForFolder(parent);
        if ([disabled containsObject:cursor.lastPathComponent]) {
            return YES;
        }
        if ([[cursor.path stringByStandardizingPath] isEqualToString:rootPath]) {
            break;
        }
        cursor = parent;
    }
    return NO;
}

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;

    // Accept .dylib, .framework, and .bundle
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"] && ![tweakPath hasSuffix:@".bundle"]) {
        return nil;
    }
    
    // If it's a .bundle file, register it in the bundle registry but don't load it as dylib.
    if ([tweakPath hasSuffix:@".bundle"]) {
        registerTweakBundle(tweak, tweakPath);
        return nil;
    }

    // If it's a .framework file, extract the executable.
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }
    
    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    NSDictionary *guestContainerInfo = [NSUserDefaults guestContainerInfo];
    strictTestModeEnabled = [guestContainerInfo[@"strictTestMode"] boolValue];
    strictAutoWipeOnExitEnabled = strictTestModeEnabled && [guestContainerInfo[@"strictAutoWipeOnExit"] boolValue];
    if(strictAutoWipeOnExitEnabled) {
        const char *homeEnv = getenv("HOME");
        if(homeEnv) {
            strictContainerHomePath = [NSString stringWithUTF8String:homeEnv];
            LCStrictRecoverStaleSessionIfNeeded();
            LCStrictWriteSessionMarker(strictContainerHomePath);
            LCStrictRegisterLifecycleObservers();
            atexit(LCStrictAutoWipeOnExit);
        }
    }

    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");

    // NULL check to prevent *** +[NSString stringWithUTF8String:]: NULL cString
    // if (!tweakFolderC) {
    //     NSLog(@"[LC] TweakLoader: LC_GLOBAL_TWEAKS_FOLDER not set, skipping tweak loading");
    //     return;
    // }
    NSString *globalTweakFolder = @(tweakFolderC); // This crashes if tweakFolderC is NULL
    // We do NOT remove LC_GLOBAL_TWEAKS_FOLDER because later hooks need it.
    // unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        if ([fileURL.lastPathComponent isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if (isTweakURLDisabled(fileURL, [NSURL fileURLWithPath:globalTweakFolder])) {
            NSLog(@"Skipped disabled tweak %@", fileURL.lastPathComponent);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL);
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSString *tweakFolder = [globalTweakFolder stringByAppendingPathComponent:tweakFolderName];
        NSURL *tweakFolderURL = [NSURL fileURLWithPath:tweakFolder];
        NSDirectoryEnumerator *directoryEnumerator = [NSFileManager.defaultManager enumeratorAtURL:tweakFolderURL includingPropertiesForKeys:@[] options:0 errorHandler:^BOOL(NSURL *url, NSError *error) {
            NSLog(@"Error while enumerating tweak directory: %@", error);
            return YES;
        }];
        for (NSURL *fileURL in directoryEnumerator) {
            if (isTweakURLDisabled(fileURL, tweakFolderURL)) {
                NSLog(@"Skipped disabled tweak %@", fileURL.lastPathComponent);
                continue;
            }
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }

    // DeviceCheck/AppAttest Hooks
    if (NSUserDefaults.guestAppInfo[@"bypassDeviceCheck"] && [NSUserDefaults.guestAppInfo[@"bypassDeviceCheck"] boolValue]) {
        DeviceCheckGuestHooksInit();
    }

    // UIDevice Hooks
    UIDeviceGuestHooksInit();

    // CoreTelephony Hooks
    CoreTelephonyGuestHooksInit();

    // Sandbox Hooks
    SandboxGuestHooksInit();

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
