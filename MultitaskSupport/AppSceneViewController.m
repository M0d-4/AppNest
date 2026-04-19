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


@interface AppSceneViewController()
@property int resizeDebounceToken;
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

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIView alloc] init];
    self.contentView = [[UIView alloc] init];
    [self.view addSubview:_contentView];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.settings = [UIMutableApplicationSceneSettings new];
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
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    
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
    
    

    _isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;

    return self;
}
//⭐️⭐️⭐️Real iPhone mode + multitask mode
- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    // NSString *identifier = [NSString stringWithFormat:@"sceneID:%@-%@", bundleID, @"default"];
    self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
    
    FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
    definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
    definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
    definition.specification = [UIApplicationSceneSpecification specification];
    FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:definition.specification];
    
    UIMutableApplicationSceneSettings *settings = self.settings;
    settings.canShowAlerts = YES;
    settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
    settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
    settings.foreground = YES;
    
    settings.deviceOrientation = UIDevice.currentDevice.orientation;
    settings.interfaceOrientation = LCInterfaceOrientationForView(self.view);
    {
        // Scene frame always starts at (0,0). Centering is done by contentView.frame
        // in viewWillLayoutSubviews / DecoratedAppSceneViewController. The scene's
        // own coordinate space does not need an offset — that would shift the guest
        // app's coordinate system rather than centering the visual.
        CGFloat vW = self.view.frame.size.width;
        CGFloat vH = self.view.frame.size.height;
        CGFloat fW = vW, fH = vH;
        if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) {
            fW = MIN(vH * (9.0 / 16.0), vW);
        }
        if (UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, fH, fW);
        } else {
            settings.frame = CGRectMake(0, 0, fW, fH);
        }
    }
    //settings.interruptionPolicy = 2; // reconnect
    settings.level = 1;
    settings.persistenceIdentifier = nil;
    if(self.isNativeWindow) {
        UIEdgeInsets defaultInsets = self.view.window.safeAreaInsets;
        settings.peripheryInsets = defaultInsets;
        settings.safeAreaInsetsPortrait = defaultInsets;
    }
    
    settings.statusBarDisabled = !self.isNativeWindow;
    //settings.previewMaximumSize =
    //settings.deviceOrientationEventsEnabled = YES;
    parameters.settings = settings;
    
    UIMutableApplicationSceneClientSettings *clientSettings = [UIMutableApplicationSceneClientSettings new];
    clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
    clientSettings.statusBarStyle = 0;
    parameters.clientSettings = clientSettings;
    
    FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
    
    self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
    [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
        context.appearanceStyle = 2;
    }];
    [self.presenter activate];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    
    [self.contentView addSubview:self.presenter.presentationView];
    self.presenter.presentationView.autoresizingMask = UIViewAutoresizingNone;
    self.presenter.presentationView.translatesAutoresizingMaskIntoConstraints = YES;

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



//if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) {
    //CGFloat viewW = self.view.bounds.size.width;
    //CGFloat viewH = self.view.bounds.size.height;
    //CGFloat targetW = MIN(viewH * (9.0 / 16.0), viewW);
    //CGFloat offsetX = (viewW - targetW) / 2.0;
    //self.contentView.layer.position = CGPointMake(offsetX, 0);
    //self.contentView.bounds = CGRectMake(0, 0, targetW, viewH);
//}


    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];

    // Disable background notifications so WebKit doesn't pause media in multitasking
    [self setBackgroundNotificationEnabled:false];

    // Acquire foreground assertions for WebKit child processes (WebContent, GPU)
    // to prevent iOS 17+ from throttling their display link / rendering pipeline
    [self acquireForegroundAssertionForChildProcesses];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    }    
}
//⭐️⭐️⭐️Real iPhone mode + multitask mode
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
   } else {
        [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext];

}
}



//⭐️⭐️⭐️Real iPhone mode + multitask mode
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat viewW = self.view.bounds.size.width;
    CGFloat viewH = self.view.bounds.size.height;
    if (self.presenter.presentationView) {
        if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) {
            CGFloat targetW = MIN(viewH * (9.0 / 16.0), viewW);
            CGFloat offsetX = (viewW - targetW) / 2.0;
            self.contentView.autoresizingMask = UIViewAutoresizingNone;
            self.contentView.frame = CGRectMake(offsetX, 0, targetW, viewH);
        } else {
            self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.contentView.frame = CGRectMake(0, 0, viewW, viewH);
        }
    }
    [self updateFrameWithSettingsBlock:self.nextUpdateSettingsBlock];
    self.nextUpdateSettingsBlock = nil;
}


//⭐️⭐️⭐️Real iPhone mode + multitask mode
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
        if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCRealIPhoneMode"]) {
            CGFloat targetW = MIN(h * (9.0 / 16.0), w);
            // In native-window (fullscreen) mode the scene frame is in screen
            // coordinates, so we offset to center. In virtual-window (windowed)
            // mode the frame origin is always (0,0) — centering is purely a
            // contentView.frame concern handled by viewWillLayoutSubviews and
            // DecoratedAppSceneViewController.
            if (self.isNativeWindow) {
                // no-op: native window uses full-screen coords — center offset
                // is not needed here because the scene fills the whole display.
            }
            w = targetW;
        }
        CGRect frame = CGRectMake(0, 0, w, h);

        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGRect frame2 = CGRectMake(0, 0, frame.size.height, frame.size.width);
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
        if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
            self.presenter = nil;
        }
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
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
 
