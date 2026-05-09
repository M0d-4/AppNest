#import <Foundation/Foundation.h>
#import <DeviceCheck/DeviceCheck.h>
#import <objc/runtime.h>
#import "utils.h"

@interface DCAppAttestService (GuestHooks)
- (void)lc_generateKeyWithCompletionHandler:(void (^)(NSString * _Nullable, NSError * _Nullable))completionHandler;
- (void)lc_attestKey:(NSString *)keyId clientDataHash:(NSData *)clientDataHash completionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler;
- (void)lc_generateAssertion:(NSString *)keyId clientDataHash:(NSData *)clientDataHash completionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler;
@end

@implementation DCAppAttestService (GuestHooks)

- (void)lc_generateKeyWithCompletionHandler:(void (^)(NSString * _Nullable, NSError * _Nullable))completionHandler {
    NSLog(@"[LC] Bypassing AppAttest generateKey");
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(nil, [NSError errorWithDomain:@"com.livecontainer.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"AppAttest is not available in this container."}]);
    });
}

- (void)lc_attestKey:(NSString *)keyId clientDataHash:(NSData *)clientDataHash completionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler {
    NSLog(@"[LC] Bypassing AppAttest attestKey");
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(nil, [NSError errorWithDomain:@"com.livecontainer.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"AppAttest is not available in this container."}]);
    });
}

- (void)lc_generateAssertion:(NSString *)keyId clientDataHash:(NSData *)clientDataHash completionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler {
    NSLog(@"[LC] Bypassing AppAttest generateAssertion");
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(nil, [NSError errorWithDomain:@"com.livecontainer.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"AppAttest is not available in this container."}]);
    });
}

@end

@interface DCDevice (GuestHooks)
- (void)lc_generateTokenWithCompletionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler;
@end

@implementation DCDevice (GuestHooks)

- (void)lc_generateTokenWithCompletionHandler:(void (^)(NSData * _Nullable, NSError * _Nullable))completionHandler {
    NSLog(@"[LC] Bypassing DeviceCheck generateToken");
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(nil, [NSError errorWithDomain:@"com.livecontainer.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"DeviceCheck is not available in this container."}]);
    });
}

@end

void DeviceCheckGuestHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            Class dcAppAttestServiceClass = NSClassFromString(@"DCAppAttestService");
            if (dcAppAttestServiceClass) {
                swizzle(dcAppAttestServiceClass, @selector(generateKeyWithCompletionHandler:), @selector(lc_generateKeyWithCompletionHandler:));
                swizzle(dcAppAttestServiceClass, @selector(attestKey:clientDataHash:completionHandler:), @selector(lc_attestKey:clientDataHash:completionHandler:));
                swizzle(dcAppAttestServiceClass, @selector(generateAssertion:clientDataHash:completionHandler:), @selector(lc_generateAssertion:clientDataHash:completionHandler:));
            }

            Class dcDeviceClass = NSClassFromString(@"DCDevice");
            if (dcDeviceClass) {
                swizzle(dcDeviceClass, @selector(generateTokenWithCompletionHandler:), @selector(lc_generateTokenWithCompletionHandler:));
            }
        } @catch (NSException *exception) {
            NSLog(@"[LC] Error initializing DeviceCheck hooks: %@", exception);
        }
    });
}
