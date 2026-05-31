#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "utils.h"

@implementation UIDevice (GuestHooks)

- (NSUUID *)hook_identifierForVendor {
    NSString *containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    NSString *key = [NSString stringWithFormat:@"LCIDFV_%@", containerId];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *idfvString = [defaults stringForKey:key];

    if (idfvString) {
        return [[NSUUID alloc] initWithUUIDString:idfvString];
    } else {
        NSUUID *newIDFV = [NSUUID UUID];
        [defaults setObject:newIDFV.UUIDString forKey:key];
        [defaults synchronize];
        return newIDFV;
    }
}

@end

void UIDeviceGuestHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            if (NSUserDefaults.guestAppInfo[@"spoofIDFV"] && [NSUserDefaults.guestAppInfo[@"spoofIDFV"] boolValue]) {
                swizzle(UIDevice.class, @selector(identifierForVendor), @selector(hook_identifierForVendor));
            }
        } @catch (NSException *exception) {
            NSLog(@"[LC] Error initializing UIDevice hooks: %@", exception);
        }
    });
}
