//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import <sys/sysctl.h>

#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"


#import "FoundationPrivate.h"
#import "UIKitPrivate+MultitaskSupport.h"


#import "LiveContainerSwiftUI-Swift.h"
#import "LCMultitaskXPCService.h"


@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@property(nonatomic, strong) NSMutableArray *childProcessAssertions;
@property(nonatomic, strong) NSTimer *childProcessMonitorTimer;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
- (void)lc_setupKeyboardEventDeferringWithRetriesRemaining:(int)retriesRemaining;
@end

static UIInterfaceOrientation LCInterfaceOrientationForView(UIView *view) {
    UIWindowScene *windowScene = view.window.windowScene;
    if (!windowScene) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            UIWindowScene *candidateScene = (UIWindowScene *)scene;
            if (candidateScene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = candidateScene;
                break;
            }
            if (!windowScene) {
                windowScene = candidateScene;
            }
        }
    }
    return windowScene ? windowScene.interfaceOrientation : UIInterfaceOrientationPortrait;
}

static NSString *const kLCStrictContainerInfoFileName = @"LCContainerInfo.plist";

static NSString *LCContainerPathForDataUUID(NSString *dataUUID) {
    if(dataUUID.length == 0) {
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docURL = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];
    if(docURL) {
        [candidateURLs addObject:[docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]]];
    }
    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(appGroupPath) {
        [candidateURLs addObject:[appGroupPath URLByAppendingPathComponent:[NSString stringWithFormat:@"LiveContainer/Data/Application/%@", dataUUID]]];
    }

    for(NSURL *candidateURL in candidateURLs) {
        NSString *containerInfoPath = [[candidateURL path] stringByAppendingPathComponent:kLCStrictContainerInfoFileName];
        if([fm fileExistsAtPath:containerInfoPath]) {
            return candidateURL.path;
        }
    }
    return nil;
}

static BOOL LCStrictShouldAutoWipeContainerAtPath(NSString *containerPath) {
    if(containerPath.length == 0) {
        return NO;
    }
    NSString *containerInfoPath = [containerPath stringByAppendingPathComponent:kLCStrictContainerInfoFileName];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    if(![info isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    return [info[@"strictTestMode"] boolValue] && [info[@"strictAutoWipeOnExit"] boolValue];
}

static void LCStrictEnsureContainerDirectoriesAtPath(NSString *containerPath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *directories = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData", @"tmp"];
    for(NSString *directory in directories) {
        NSString *path = [containerPath stringByAppendingPathComponent:directory];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static void LCStrictAutoWipeContainerForDataUUIDIfNeeded(NSString *dataUUID) {
    NSString *containerPath = LCContainerPathForDataUUID(dataUUID);
    if(containerPath.length == 0 || !LCStrictShouldAutoWipeContainerAtPath(containerPath)) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:containerPath error:&listError];
    if(!entries) {
        NSLog(@"[LC][StrictMode] Failed to enumerate container %@ for auto-wipe: %@", dataUUID, listError.localizedDescription);
        return;
    }

    for(NSString *entry in entries) {
        if([entry isEqualToString:kLCStrictContainerInfoFileName]) {
            continue;
        }
        NSError *removeError = nil;
        NSString *entryPath = [containerPath stringByAppendingPathComponent:entry];
        if(![fm removeItemAtPath:entryPath error:&removeError] && removeError) {
            NSLog(@"[LC][StrictMode] Failed to remove %@ in container %@: %@", entry, dataUUID, removeError.localizedDescription);
        }
    }
    LCStrictEnsureContainerDirectoriesAtPath(containerPath);
}

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID hostScene:(UIWindowScene *)hostScene delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSLog(@"DELEGATE %@", delegate);
    NSMutableDictionary *userInfo = @{
        @"hostFBSIdentityToken": [@"UIScene:" stringByAppendingString:hostScene._FBSScene.identityToken.stringRepresentation],
        @"endpoint": LCMultitaskXPCService.sharedInstance.listener.endpoint,
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        [bookmarks addObject:bookmarkData];
    } else {
        bool isSharedApp = false;
        NSBundle* bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
        // when mutlitask with private app, we can restrict its sandbox to only its own container
        if (!isSharedApp) {
            NSURL *dataURL = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
            NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
            [bookmarks addObject:[bundle.bundleURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
            NSData* containerBookmark = [dataURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(containerBookmark) {
                [bookmarks addObject:containerBookmark];
            }
            [bookmarks addObject:[tweaksURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
    
    return self;
}
//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (BOOL)usesHostingControllerAPI {
    return self.hostingController != nil;
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];

    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];

    __weak typeof(self) weakSelf = self;
    void (^updateSceneSettings)(UIMutableApplicationSceneSettings *) = ^void(UIMutableApplicationSceneSettings *settings) {
        AppSceneViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:strongSelf.view.layer.cornerRadius bottomLeft:strongSelf.view.layer.cornerRadius bottomRight:strongSelf.view.layer.cornerRadius topRight:strongSelf.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;

        settings.deviceOrientation = UIDevice.currentDevice.orientation;
        settings.interfaceOrientation = LCInterfaceOrientationForView(strongSelf.view);
        {
            // Scene frame always starts at (0,0). Centering is done by contentView.frame
            // in viewWillLayoutSubviews / DecoratedAppSceneViewController. The scene's
            // own coordinate space does not need an offset — that would shift the guest
            // app's coordinate system rather than centering the visual.
            CGFloat vW = strongSelf.view.frame.size.width;
            CGFloat vH = strongSelf.view.frame.size.height;
            CGFloat fW = vW, fH = vH;
            if (UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                settings.frame = CGRectMake(0, 0, fH, fW);
            } else {
                settings.frame = CGRectMake(0, 0, fW, fH);
            }
        }
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = nil;
        if(strongSelf.isNativeWindow) {
            UIEdgeInsets defaultInsets = strongSelf.view.window.safeAreaInsets;
            settings.peripheryInsets = defaultInsets;
            settings.safeAreaInsetsPortrait = defaultInsets;
        }

        settings.statusBarDisabled = !strongSelf.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;

    };
    void (^updateSceneClientSettings)(UIMutableApplicationSceneClientSettings *) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not needed, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        //
        // This used to read _eventDeferringComponent synchronously, right here,
        // immediately after allocating _UISceneHostingController. Two separate
        // things could make that come back nil: Apple moved _scenePresenter
        // (right above this) from a real property (iOS 26) to ivar-only (iOS
        // 27), and _eventDeferringComponent is read the same "old" way that
        // just broke for its neighbor -- but scene connection to a hosted
        // process is also inherently asynchronous (cross-process XPC to
        // FrontBoard), so this component may simply not exist *yet* at this
        // exact point in the call stack, regardless of naming. Rather than
        // assume which of the two is responsible, -lc_setupKeyboardEventDeferringWithRetriesRemaining:
        // handles both: it tries the KVC fallback, and if still nil, retries
        // on a short delay instead of giving up after one synchronous check.
        [self lc_setupKeyboardEventDeferringWithRetriesRemaining:20]; // 20 * 50ms = up to ~1s

        [self addChildViewController:self.hostingController.sceneViewController];
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.hostingController.sceneView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;

        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];

        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
        self.presenter.presentationView.autoresizingMask = UIViewAutoresizingNone;
        self.presenter.presentationView.translatesAutoresizingMaskIntoConstraints = YES;
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];

    // Size and center contentView immediately so the guest scene renders in the
    // right place from the very first frame. viewWillLayoutSubviews keeps it
    // updated whenever the parent view changes size.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self updateFrameWithSettingsBlock:nil];
        });
    });

    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];

    // Disable background notifications so WebKit doesn't pause media in multitasking
    [self setBackgroundNotificationEnabled:false];

    // Acquire foreground assertions for WebKit child processes (WebContent, GPU)
    // to prevent iOS 17+ from throttling their display link / rendering pipeline
    [self acquireForegroundAssertionForChildProcesses];
}

// See the call site's comment above for why this retries instead of checking
// once. iOS-27-only: pre-27 doesn't need _eventDeferringComponent at all (see
// the additionalExtensions branch above), so there's nothing to retry there.
- (void)lc_setupKeyboardEventDeferringWithRetriesRemaining:(int)retriesRemaining {
    if (@available(iOS 27.0, *)) {} else { return; }
    if (!self.hostingController) return; // torn down already; nothing to do

    _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
    if (!deferringComponent) {
        // _scenePresenter needed valueForKey: instead of a direct property
        // access because Apple moved it from a real property (iOS 26) to
        // ivar-only (iOS 27) — same class of change this accessor could have
        // gone through too.
        deferringComponent = [self.hostingController valueForKey:@"_eventDeferringComponent"];
    }
    if (!deferringComponent) {
        if (retriesRemaining > 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf lc_setupKeyboardEventDeferringWithRetriesRemaining:retriesRemaining - 1];
            });
            return;
        }
        // NSAssert here previously would have been a no-op in Release builds
        // (NS_BLOCK_ASSERTIONS) even on total failure, matching "keyboard
        // doesn't load" exactly: no crash, no log, every line below just a
        // silent no-op message-to-nil. Logging explicitly instead.
        NSLog(@"[AppNest] _UISceneEventDeferringHostComponent stayed nil after ~1s of retrying — keyboard focus setup skipped entirely.");
        return;
    }

    /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
    /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work

    /// Replicate these methods since they are made private
    /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
    [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
    // if (!deferringComponent->_flags.clientIsInChain) return;
    /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
    // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)

    deferringComponent.grantBehavior = 2;
    deferringComponent.selectionRequestBehavior = 2;
}

- (void)setEnableVisibility:(BOOL)visible {
    if (!visible && self.injector) {
        [self.injector invalidate];
        self.injector = nil;
        return;
    }
    // else
    self.injector = [PrivClass(BSServiceConnectionEndpointInjector) injectorWithConfigurator:^(id<BSServiceConnectionEndpointInjectorConfiguring> config) {
        NSString *selfEnv = [@"UIScene:" stringByAppendingString:self.presenter.scene.identityToken.stringRepresentation];
        NSString *sourceEnv = [@"UIScene:" stringByAppendingString:self.view.window.windowScene._FBSScene.identityToken.stringRepresentation];
        [config setTarget:[RBSTarget targetWithPid:self.pid environmentIdentifier:selfEnv]];
        [config setInheritingEnvironment:sourceEnv];
        [config setAdditionalAttributes:@[
            [PrivClass(RBSHereditaryGrant) grantWithNamespace:@"com.apple.frontboard.visibility" sourceEnvironment:sourceEnv attributes:nil]
        ]];
    }];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    }
}
//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    if(self.isNativeWindow) {
        baseSettings.interruptionPolicy = 0;
        baseSettings.peripheryInsets = self.view.window.safeAreaInsets;
        [self.presenter.scene updateSettings:baseSettings withTransitionContext:newContext completion:nil];
        
        // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
        if(actionType == 2) {
            NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
            if(launchUrl) {
                [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
                [self openURLScheme:launchUrl];
            }
        }
   } else {
        if([self.delegate respondsToSelector:@selector(appSceneVC:didUpdateFromSettings:transitionContext:lifecycleActionType:)]) {
            [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
        }
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(!self.hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18.0 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Keep contentView's horizontal position consistent with Real iPhone
        // Mode's centered crop (same formula as viewWillLayoutSubviews),
        // instead of always discarding position to (0,0). This method is
        // called from many places for unrelated setting changes — always
        // zeroing origin here meant ANY of those (not just our own resize
        // handler) could silently overwrite the correctly-centered content
        // view back to flush-left, which is what made it drift left instead
        // of staying centered in multitask.
        CGFloat originX = 0;
        if (LCForceLandscapeModeEnabled(self.bundleId) && self.presenter.presentationView) {
            originX = LCLandscapeLetterboxedRect(self.view.bounds).origin.x;
        }
        frame.origin = CGPointMake(originX, 0);
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}



//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (self.presenter.presentationView) {
        if (LCForceLandscapeModeEnabled(self.bundleId)) {
            self.contentView.autoresizingMask = UIViewAutoresizingNone;
            self.contentView.frame = LCLandscapeLetterboxedRect(self.view.bounds);
        } else {
            self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.contentView.frame = self.view.bounds;
        }
    }
    [self updateFrameWithSettingsBlock:self.nextUpdateSettingsBlock];
    self.nextUpdateSettingsBlock = nil;
}


//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = self.resizeDebounceToken + 1;
    _resizeDebounceToken = currentDebounceToken;
    dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
    dispatch_after(delay, dispatch_get_main_queue(), ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        CGFloat w = self.view.frame.size.width / self.scaleRatio;
        CGFloat h = self.view.frame.size.height / self.scaleRatio;
        CGFloat offsetX = 0;
        if (LCForceLandscapeModeEnabled(self.bundleId)) {
            CGRect constrained = LCLandscapeLetterboxedRect(CGRectMake(0, 0, w, h));
            offsetX = constrained.origin.x;
            w = constrained.size.width;
        }
        CGRect frame = CGRectMake(offsetX, 0, w, h);

        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGRect frame2 = CGRectMake(0, offsetX, frame.size.height, frame.size.width);
                settings.frame = frame2;
            } else {
                settings.frame = frame;
            }
            if(block) {
                block(settings);
            }
        }];
    });
}


- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    [self invalidateChildProcessAssertions];
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        LCStrictAutoWipeContainerForDataUUIDIfNeeded(self.dataUUID);
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

#pragma mark - WebKit child process foreground assertions (iOS 17+ media fix)

- (void)acquireForegroundAssertionForChildProcesses {
    if (@available(iOS 17.0, *)) {} else return; // Only needed on iOS 17+

    self.childProcessAssertions = [NSMutableArray array];

    // 1. Take a foreground assertion for the guest app process itself
    [self acquireAssertionForPid:self.pid explanation:@"LiveContainer guest app foreground"];

    // 2. Monitor for WebKit child processes (WebContent, GPU) spawned by the guest app
    //    They appear shortly after the guest app creates a WKWebView
    __weak typeof(self) weakSelf = self;
    NSMutableSet *knownPids = [NSMutableSet set];
    self.childProcessMonitorTimer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        if (!weakSelf || !weakSelf.isAppRunning) {
            [timer invalidate];
            return;
        }
        NSArray *childPids = [weakSelf findChildProcessesOfPid:weakSelf.pid];
        for (NSNumber *childPid in childPids) {
            if (![knownPids containsObject:childPid]) {
                [knownPids addObject:childPid];
                NSString *explanation = [NSString stringWithFormat:@"LiveContainer WebKit child (pid %@)", childPid];
                [weakSelf acquireAssertionForPid:childPid.intValue explanation:explanation];
                NSLog(@"[LiveContainer] Acquired foreground assertion for child process %@", childPid);
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.childProcessMonitorTimer forMode:NSRunLoopCommonModes];
}

- (void)acquireAssertionForPid:(pid_t)pid explanation:(NSString *)explanation {
    Class RBSAssertionClass = NSClassFromString(@"RBSAssertion");
    Class RBSDomainAttributeClass = NSClassFromString(@"RBSDomainAttribute");
    Class RBSTargetClass = NSClassFromString(@"RBSTarget");
    if (!RBSAssertionClass || !RBSDomainAttributeClass || !RBSTargetClass) return;

    RBSTarget *target = [RBSTargetClass targetWithPid:pid];

    // Request foreground visibility — this grants rendering/display link access
    NSMutableArray *attributes = [NSMutableArray array];

    // Try various domain attributes that grant rendering access
    id fgAttr = [RBSDomainAttributeClass attributeWithDomain:@"com.apple.frontboard.visibility"
                                                        name:@"Foreground"];
    if (fgAttr) [attributes addObject:fgAttr];

    id gpuAttr = [RBSDomainAttributeClass attributeWithDomain:@"com.apple.common"
                                                         name:@"UserInteractiveNonFocal"];
    if (gpuAttr) [attributes addObject:gpuAttr];

    if (attributes.count == 0) return;

    RBSAssertion *assertion = [[RBSAssertionClass alloc] initWithExplanation:explanation
                                                                     target:target
                                                                 attributes:attributes];
    NSError *error = nil;
    BOOL acquired = [assertion acquireWithError:&error];
    if (acquired) {
        [self.childProcessAssertions addObject:assertion];
        NSLog(@"[LiveContainer] Foreground assertion acquired for pid %d", pid);
    } else {
        NSLog(@"[LiveContainer] Failed to acquire assertion for pid %d: %@", pid, error);
    }
}

- (NSArray<NSNumber *> *)findChildProcessesOfPid:(pid_t)parentPid {
    // Use sysctl to find all processes, then filter by parent pid
    NSMutableArray *children = [NSMutableArray array];

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return children;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return children;

    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            pid_t ppid = procs[i].kp_eproc.e_ppid;
            pid_t pid = procs[i].kp_proc.p_pid;
            if (ppid == parentPid && pid != parentPid) {
                [children addObject:@(pid)];
            }
        }
    }
    free(procs);
    return children;
}

- (void)invalidateChildProcessAssertions {
    [self.childProcessMonitorTimer invalidate];
    self.childProcessMonitorTimer = nil;
    for (RBSAssertion *assertion in self.childProcessAssertions) {
        [assertion invalidate];
    }
    [self.childProcessAssertions removeAllObjects];
}

@end
