//
//  CodeSigner.h
//  codesign
//
//  Created by s s on 1/15/26.
//

#import <Foundation/Foundation.h>


@interface SecuritySigner : NSObject
+ (NSProgress*)signWithAppURL:(NSURL *)appURL key:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSProgress*)signWithAppURL:(NSURL *)appURL key:(NSData *)key pass:(NSString *)pass entitlements:(NSDictionary *)entitlements completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (BOOL)adhocSignMachOAtPath:(NSURL *)fileURL bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData;
/// Sign an array of individual MachO files (dylibs / framework executables) concurrently.
/// Equivalent to ZSigner's signMachOPathArr:bundleId:cert:pass:completionHandler:
+ (NSProgress*)signMachOURLArray:(NSArray<NSURL *> *)urls key:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;

@end

@interface LCCertWrapper : NSObject
@property(readonly) NSString* organizationalUnit;
@property(readonly) NSDate* notValidAfter;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)initWithCertData:(NSData*)certData password:(NSString*)password error:(NSError**)error;
- (NSString*)checkValidityWithError:(NSError**)error;

@end

@interface LCMobileProvisionWarpepr : NSObject
@property NSDictionary* mpContent;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)initWithMPData:(NSData*)mpData error:(NSError**)error;
- (NSString*)getTeamId;
- (NSDictionary*)getEntitlements;
@end

