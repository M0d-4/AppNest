//
//  UIKitHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 25/6/26.
//
@import ObjectiveC;
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"

static BOOL LCHasRemoteSheetProviderSelector;

UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIEdgeInsetsMake(insets.left, 0, insets.right, insets.bottom);
        case UIInterfaceOrientationLandscapeRight:
            return UIEdgeInsetsMake(insets.left, insets.bottom, insets.right, 0);
        default:
            return insets;
    }
}

// Fix _UIPrototypingMenuSlider not continually updating its value on iOS 17+
API_AVAILABLE(ios(17.0))
@implementation _UIFluidSliderInteraction(Hook)
- (NSInteger)_state {
    return 2;
}
@end

/// Hook to fix safe area scaling and orientation. We use superview's safeAreaInsets because self one tends to bug out with certain scaling, and also allows us to customize safe area while in PiP mode later on
API_AVAILABLE(ios(17.0))
@implementation _UISceneHostingView(LCFixSafeArea)
- (void)hook__applyOverridesToHostedSceneSettings:(UIMutableApplicationSceneSettings *)settings {
    [self hook__applyOverridesToHostedSceneSettings:settings];
    // We don't wanna mess up system extensions
    if(LCHasRemoteSheetProviderSelector && self._remoteSheetProvider) return;
    
    // overwrite safeAreaInsets with our scaled and orientation-fixed version
    CGAffineTransform transform = self.transform;
    UIEdgeInsets orig = self.superview.safeAreaInsets;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(orig.top / transform.d, orig.left / transform.a, orig.bottom / transform.d, orig.right / transform.a);
}

// fix for 26.x
- (void)hook_applyViewGeometryToSettings:(UIMutableApplicationSceneSettings *)settings API_AVAILABLE(ios(19.0)) {
    [self hook_applyViewGeometryToSettings:settings];
    // We don't wanna mess up system extensions
    if(LCHasRemoteSheetProviderSelector && self._remoteSheetProvider) return;
    
    // same as above, but we have to fix orientation
    CGAffineTransform transform = self.transform;
    UIEdgeInsets orig = self.superview.safeAreaInsets;
    if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
        // apps with glass has an extra top safe area space, so clear it (will it cause inconsistencies?)
        orig.top = 0;
    }
    UIEdgeInsets insets = UIEdgeInsetsMake(orig.top / transform.d, orig.left / transform.a, orig.bottom / transform.d, orig.right / transform.a);
    settings.safeAreaEdgeInsets = insets;
    settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(insets, settings.interfaceOrientation);
}
@end

__attribute__((constructor))
void UIKitFixesInit(void) {
    if (@available(iOS 17.0, *)) {
        if([_UISceneHostingView.class instancesRespondToSelector:@selector(applyViewGeometryToSettings:)]) {
            // iOS 26.x selector name
            swizzle(_UISceneHostingView.class, @selector(applyViewGeometryToSettings:), @selector(hook_applyViewGeometryToSettings:));
        } else {
            // iOS 17-18.x selector name
            swizzle(_UISceneHostingView.class, @selector(_applyOverridesToHostedSceneSettings:), @selector(hook__applyOverridesToHostedSceneSettings:));
        }
        LCHasRemoteSheetProviderSelector = [_UISceneHostingView.class instancesRespondToSelector:@selector(_remoteSheetProvider)];
    }
}
