//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;
#include <dlfcn.h>


NSUUID* idForVendorUUID = nil;

NSUUID* getIDFV_hook(NSObject* cur) {
    return idForVendorUUID;
}

void IDFVHookInit(NSUUID* uuid) {
    idForVendorUUID = uuid;
    // it should be ok to dlopen UIKit here since we preload MetalANGLE in main.c
    dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_GLOBAL);
    Method getIDFVOrig = class_getInstanceMethod(objc_getClass("UIDevice"), @selector(identifierForVendor));
    method_setImplementation(getIDFVOrig, (IMP)getIDFV_hook);
}
