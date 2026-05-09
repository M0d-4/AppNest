#import <Foundation/Foundation.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import "utils.h"

@implementation CTCarrier (GuestHooks)

- (NSString *)hook_carrierName {
    return NSUserDefaults.guestAppInfo[@"sim_carrierName"] ?: [self hook_carrierName];
}

- (NSString *)hook_mobileCountryCode {
    return NSUserDefaults.guestAppInfo[@"sim_mobileCountryCode"] ?: [self hook_mobileCountryCode];
}

- (NSString *)hook_mobileNetworkCode {
    return NSUserDefaults.guestAppInfo[@"sim_mobileNetworkCode"] ?: [self hook_mobileNetworkCode];
}

- (NSString *)hook_isoCountryCode {
    return NSUserDefaults.guestAppInfo[@"sim_isoCountryCode"] ?: [self hook_isoCountryCode];
}

- (BOOL)hook_allowsVOIP {
    return [NSUserDefaults.guestAppInfo[@"sim_allowsVOIP"] boolValue];
}

@end

@implementation CTTelephonyNetworkInfo (GuestHooks)

- (CTCarrier *)hook_subscriberCellularProvider {
    return (CTCarrier *)self;
}

@end

void CoreTelephonyGuestHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            if (NSUserDefaults.guestAppInfo[@"spoofSIM"] && [NSUserDefaults.guestAppInfo[@"spoofSIM"] boolValue]) {
                swizzle(CTCarrier.class, @selector(carrierName), @selector(hook_carrierName));
                swizzle(CTCarrier.class, @selector(mobileCountryCode), @selector(hook_mobileCountryCode));
                swizzle(CTCarrier.class, @selector(mobileNetworkCode), @selector(hook_mobileNetworkCode));
                swizzle(CTCarrier.class, @selector(isoCountryCode), @selector(hook_isoCountryCode));
                swizzle(CTCarrier.class, @selector(allowsVOIP), @selector(hook_allowsVOIP));
                swizzle(CTTelephonyNetworkInfo.class, @selector(subscriberCellularProvider), @selector(hook_subscriberCellularProvider));
            }
        } @catch (NSException *exception) {
            NSLog(@"[LC] Error initializing CoreTelephony hooks: %@", exception);
        }
    });
}
