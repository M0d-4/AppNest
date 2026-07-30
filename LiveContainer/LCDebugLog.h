//
//  LCDebugLog.h
//  AppNest
//
//  On-device debug logging, no Mac/Console.app required.
//
//  NSLog() output goes to stdout/stderr; without a debugger or Console.app
//  attached (the normal situation for a sideloaded app running on its own),
//  that output goes nowhere you can read. This redirects stdout+stderr to a
//  plain text file inside the shared app-group container, one file per
//  process ("host", "guest", "liveprocess"), so every NSLog(...) call
//  already in this codebase gets captured for free -- nothing else needs to
//  change. In particular this captures the existing
//  "[ForceLandscapeMode] ..." and "[AppNest] _UISceneEventDeferringHostComponent ..."
//  diagnostic lines already left in UIKit+GuestHooks.m and
//  AppSceneViewController.m.
//
//  Call LCDebugLogInstall(tag) once, as early as possible, in each process
//  entry point -- before tweak loading / hook installation, so nothing gets
//  missed. Safe to call more than once for the same tag (no-op after the
//  first call within a process).
//
//  To read the logs on-device: Settings > Debug Log in the app lists these
//  files and lets you view/share/AirDrop them -- see LCDebugLogView.swift.
//
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "LCSharedUtils.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const kLCDebugLogDirectoryName = @"AppNestDebugLogs";

static inline NSURL *LCDebugLogDirectory(void) {
    NSURL *base = [LCSharedUtils appGroupPath];
    NSURL *dir = [base URLByAppendingPathComponent:kLCDebugLogDirectoryName isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static inline NSURL *LCDebugLogFileURL(NSString *tag) {
    return [LCDebugLogDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.log", tag]];
}

// Caps each log file at ~4MB so a chatty run (e.g. the per-frame
// CADisplayLink letterbox enforcement logging) can't quietly eat device
// storage. Keeps the most recent tail; only takes effect on the next
// LCDebugLogInstall call for that tag (i.e. next process launch), since we
// can't safely truncate a file the process is actively appending to.
static inline void LCDebugLogTruncateIfNeeded(NSURL *fileURL) {
    static const unsigned long long kMaxBytes = 4 * 1024 * 1024;
    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue <= kMaxBytes) return;
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data || data.length <= kMaxBytes) return;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - kMaxBytes, kMaxBytes)];
    [tail writeToURL:fileURL atomically:YES];
}

static inline void LCDebugLogInstall(NSString *tag) {
    static NSMutableSet<NSString *> *installed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installed = [NSMutableSet set];
    });
    @synchronized (installed) {
        if ([installed containsObject:tag]) {
            return;
        }
        [installed addObject:tag];
    }

    NSURL *fileURL = LCDebugLogFileURL(tag);
    LCDebugLogTruncateIfNeeded(fileURL);

    const char *path = fileURL.path.UTF8String;
    if (!path) return;

    // Redirect both -- some NSLog configurations favor one or the other.
    if (!freopen(path, "a+", stdout)) return;
    if (!freopen(path, "a+", stderr)) return;
    // Line-buffered so a crash immediately after a log line doesn't lose it
    // sitting in an unflushed buffer.
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    time_t now = time(NULL);
    fprintf(stderr, "\n----- LCDebugLog: \"%s\" process started %s-----\n", tag.UTF8String, ctime(&now));
}

NS_ASSUME_NONNULL_END
