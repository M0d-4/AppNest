//
//  utils.m
//  AppNest
//
//  Created by s s on 2026/1/23.
//
@import Foundation;
@import ObjectiveC;
#import "../AppNest/UIKitPrivate.h"
#import "../AppNest/utils.h"

bool lsApplicationWorkspaceCanOpenURL(NSURL* url) {
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
    NSError* error;
    BOOL success = [workspace isApplicationAvailableToOpenURL:url error:&error];
    return success;
}
