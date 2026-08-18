#import "DecoratedAppSceneViewController.h"
#import "AppSceneViewController.h"
#import "ResizeHandleView.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

// Let us manage BSServiceConnectionEndpointInjector on our own
@implementation UIScenePresentationContext(LiveContainerHooks)
- (BOOL)_isVisibilityPropagationEnabled {
    return NO;
}
@end

#import <objc/runtime.h> 
#import "LiveContainerSwiftUI-Swift.h"


@interface NSFileManager (GuestHooks)
- (NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
- (BOOL)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error;
@end

@interface DecoratedAppSceneViewController()
@property(nonatomic) BOOL navBarIsOverlay;
@property(nonatomic) BOOL lastConstraintBottomBar;
@property(nonatomic) BOOL lastConstraintHideBar;
@property(nonatomic) BOOL hasBuiltConstraints;
@property(nonatomic) NSLayoutConstraint *navigationBarEdgeConstraint;
@property(nonatomic) UIBarButtonItem *titleBarButtonItem;
@property(nonatomic, copy) UIMenu *(^titleMenuProviderBlock)(NSArray<UIMenuElement *> *);
- (NSArray<UIMenuElement *> *)buildTitleMenuChildren;
@end
@interface MultitaskDockManager (Private)
- (void)refreshMenu;
@end


@protocol _UISceneSettingsDiffAction <NSObject>
@end

static int hook_return_2(void) {
    return 2;
}





@interface DecoratedAppSceneViewController () <AppSceneViewControllerDelegate>
@property (nonatomic, strong) UIStackView *mainStackView;
@property (nonatomic, strong) ResizeHandleView *moveHandle;
@property (nonatomic, strong) UIBarButtonItem *maximizeButton;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@property (nonatomic, assign) CGRect originalFrame;
@property (nonatomic, copy) NSString *dataUUID;
@property (nonatomic, copy) NSString *windowName;
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) BOOL isAppTerminationRequested;

@end

static UIInterfaceOrientation LCCurrentInterfaceOrientation(void) {
    UIWindowScene *windowScene = nil;
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
    return windowScene ? windowScene.interfaceOrientation : UIInterfaceOrientationPortrait;
}

//⭐️⭐️⭐️
@implementation DecoratedAppSceneViewController
@synthesize mainStackView = _mainStackView;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIStackView alloc] initWithFrame:self.view.frame];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];
    
    _dataUUID = dataUUID;
    _windowName = windowName;
    _scaleRatio = 1.0;
    _isMaximized = [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID hostScene:rootVC.view.window.windowScene delegate:self];
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];
    
    
    NSArray *menuItems = @[
        [UIAction actionWithTitle:@"🐞 Toggle Visibility Grant" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [self.appSceneVC setEnableVisibility:self.appSceneVC.injector==nil];
        }],
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(self.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:self.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:self.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [self scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:self.scaleRatio stepInterval:0.01];
        }]
    ];
    

    __weak typeof(self) weakSelf = self;
    self.titleMenuProviderBlock = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions){
        if(!weakSelf.appSceneVC.isAppRunning) {
            return [UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]];
        } else {
            NSString *pidText = [NSString stringWithFormat:@"PID: %d", weakSelf.pid];
            pidText = [pidText stringByAppendingFormat:@"\n🐞 Visibility Grant: %@", self.appSceneVC.injector!=nil ? @"ON" : @"OFF"];
            return [UIMenu menuWithTitle:pidText children:menuItems];
        }
        return [UIMenu menuWithTitle:@"" children:[weakSelf buildTitleMenuChildren]];
    };
    [self.navigationItem setTitleMenuProvider:self.titleMenuProviderBlock];

    // Title as a bar button item so it gets a background chip in overlay mode.
    UIDeferredMenuElement *deferredTitleMenu = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *_Nonnull)){
        if(!weakSelf.appSceneVC.isAppRunning) {
            completion(@[[UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]]]);
            return;
        }
        completion([weakSelf buildTitleMenuChildren]);
    }];
    UIButtonConfiguration *titleConfig = [UIButtonConfiguration plainButtonConfiguration];
    titleConfig.buttonSize = UIButtonConfigurationSizeSmall;
    titleConfig.title = windowName;
    UIImageSymbolConfiguration *chevronSize = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIImageSymbolConfiguration *chevronPalette = [UIImageSymbolConfiguration configurationWithPaletteColors:@[UIColor.secondaryLabelColor, UIColor.tertiarySystemFillColor]];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.down.circle.fill" withConfiguration:[chevronSize configurationByApplyingConfiguration:chevronPalette]];
    titleConfig.image = chevronImage;
    titleConfig.imagePlacement = NSDirectionalRectEdgeTrailing;
    titleConfig.imagePadding = 4;
    titleConfig.baseForegroundColor = UIColor.labelColor;
    UIButton *titleButton = [UIButton buttonWithConfiguration:titleConfig primaryAction:nil];
    titleButton.menu = [UIMenu menuWithTitle:@"" children:@[deferredTitleMenu]];
    titleButton.showsMenuAsPrimaryAction = YES;
    self.titleBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:titleButton];


    UIImage *minimizeImage = [UIImage systemImageNamed:@"minus.circle"];
    UIImageConfiguration *minimizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    minimizeImage = [minimizeImage imageWithConfiguration:minimizeConfig];
    UIBarButtonItem *minimizeButton = [[UIBarButtonItem alloc] initWithImage:minimizeImage style:UIBarButtonItemStylePlain target:self action:@selector(minimizeWindow)];
    minimizeButton.tintColor = [UIColor systemYellowColor];
    
    NSString *maximizeImageName = _isMaximized ? @"arrow.down.right.and.arrow.up.left.circle" : @"arrow.up.left.and.arrow.down.right.circle";
    UIImage *maximizeImage = [UIImage systemImageNamed:maximizeImageName];
    UIImageConfiguration *maximizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    maximizeImage = [maximizeImage imageWithConfiguration:maximizeConfig];
    self.maximizeButton = [[UIBarButtonItem alloc] initWithImage:maximizeImage style:UIBarButtonItemStylePlain target:self action:@selector(maximizeWindow)];
    self.maximizeButton.tintColor = [UIColor systemGreenColor];
    
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark.circle"];
    UIImageConfiguration *closeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    closeImage = [closeImage imageWithConfiguration:closeConfig];
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:closeImage style:UIBarButtonItemStylePlain target:self action:@selector(closeWindow)];
    closeButton.tintColor = [UIColor systemRedColor];
    
    NSArray *barButtonItems = @[closeButton, self.maximizeButton, minimizeButton];
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        // resize handle overlaps the close button, so put the buttons on the left
        self.navigationItem.leftBarButtonItems = barButtonItems;
    } else {
        self.navigationItem.rightBarButtonItems = barButtonItems;
    }

    // setupDecoratedView ran updateVerticalConstraints further up, back when titleBarButtonItem
    // was still nil, so an app launching straight into maximized overlay mode would come up with
    // no name on the bar at all until something else forced a rebuild. Put it on now. This touches
    // the side opposite the traffic lights, so it won't disturb what we just set above.
    if(self.navBarIsOverlay) {
        self.navigationItem.title = nil;
        [self.navigationItem setTitleMenuProvider:nil];
        [self applyTitleBarItem];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
    });

    return self;
}

// Both the windowed title menu and the overlay title button build from here, so the two can't
// drift apart. Rebuilt on every open, so the PID is current.
- (NSArray<UIMenuElement *> *)buildTitleMenuChildren {
    __weak typeof(self) weakSelf = self;
    NSString *pidText = [NSString stringWithFormat:@"PID: %d", self.pid];
    pidText = [pidText stringByAppendingFormat:@"\n🐞 Visibility Grant: %@", self.appSceneVC.injector!=nil ? @"ON" : @"OFF"];
    // Inline so the actions sit at the top level with the PID as a section header.
    UIMenu *pidHeaderMenu = [UIMenu menuWithTitle:pidText image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:@"🐞 Toggle Visibility Grant" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf.appSceneVC setEnableVisibility:weakSelf.appSceneVC.injector==nil];
        }],
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [weakSelf scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:weakSelf.scaleRatio stepInterval:0.01];
        }]
    ]];
    return @[pidHeaderMenu];
}

- (void)setupDecoratedView {
    
    NSInteger toolbarMode = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskToolbarMode"];
    CGFloat navBarHeight = (toolbarMode == 2) ? 0 : 44.0; 
    
    UIStackView *stackView = (UIStackView *)self.view;
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.backgroundColor = UIColor.systemBackgroundColor;
    stackView.layer.cornerRadius = 10;
    stackView.layer.masksToBounds = YES;
    self.mainStackView = stackView;
    
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(LCCurrentInterfaceOrientation());
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    
    if(_isMaximized) {
        [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [self updateMaximizedFrameWithSettings:settings];
        }];
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        frame.origin.x /= maxFrame.size.width;
        frame.origin.y /= maxFrame.size.height;
        self.originalFrame = frame;
    } else {
        
        CGPoint rootViewCenter = [MultitaskDockManager.shared.windowHostingView center];
        frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);
        self.view.frame = frame;
    }
    
    
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.windowName];
    navigationBar.items = @[navigationItem];
    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    self.navigationBar.hidden = (toolbarMode == 2);


    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    fixedPositionContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];


    if (toolbarMode == 1) { 
        [self.mainStackView addArrangedSubview:fixedPositionContentView];
        [self.mainStackView addArrangedSubview:self.navigationBar];
    } else { 
        [self.mainStackView addArrangedSubview:self.navigationBar];
        [self.mainStackView addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];


    CGFloat handleSize = 30.0;
    self.moveHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(0, 0, handleSize, handleSize)];
    self.moveHandle.transform = CGAffineTransformMakeRotation(M_PI); 
    self.moveHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.view addSubview:self.moveHandle];
    [self.view bringSubviewToFront:self.moveHandle];
    
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    [self.moveHandle addGestureRecognizer:moveGesture];

    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - handleSize, self.view.frame.size.height - handleSize, handleSize, handleSize)];
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];
    
    self.view.layer.borderWidth = _isMaximized ? 0.0 : 1.0;
    self.view.layer.borderColor = UIColor.secondarySystemBackgroundColor.CGColor;
    
    
    [self addChildViewController:_appSceneVC];
    [self.contentView addSubview:_appSceneVC.view];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    

    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    

    [[NSUserDefaults lcSharedDefaults] addObserver:self forKeyPath:@"LCMultitaskToolbarMode" options:NSKeyValueObservingOptionNew context:NULL];
    [[NSUserDefaults lcSharedDefaults] addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
    [[NSUserDefaults lcSharedDefaults] addObserver:self forKeyPath:@"LCMultitaskOverlayMode" options:NSKeyValueObservingOptionNew context:NULL];
    
    [self updateOriginalFrame];
    [self.view layoutIfNeeded];
}



//⭐️⭐️⭐️

// Stolen from UIKitester
- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    [slider addTarget:self action:@selector(scaleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    
    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    self.scaleRatio = slider.value;
    self.appSceneVC.scaleRatio = _scaleRatio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(_scaleRatio, _scaleRatio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    }
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)closeWindow {
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
    } completion:^(BOOL finished) {
        if (!finished) return;
        self.view.hidden = YES;
        self.view.transform = CGAffineTransformIdentity;
        [self.view.superview sendSubviewToBack:self.view];
    }];
}

- (void)minimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}
//⭐️⭐️⭐️
- (void)maximizeWindow {
    
    if (self.isMaximized) {
        self.isMaximized = NO;
        [MultitaskDockManager.shared refreshMenu];
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            // Clear isMaximized here rather than in the completion so the rebuild below sees it.
            // Overlay mode only applies while maximized, so this is what moves the bar back into
            // the stack view.
            self.isMaximized = NO;
            [self updateVerticalConstraints];
            self.view.frame = newFrame;
            self.view.layer.borderWidth = 1;
            self.resizeHandle.alpha = 1;
            self.moveHandle.alpha = 1;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateWindowedFrameWithSettings:settings];
            }];
        } completion:^(BOOL finished) {
            UIImage *maximizeImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right.circle"];
            UIImageConfiguration *maximizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            self.maximizeButton.image = [maximizeImage imageWithConfiguration:maximizeConfig];
        }];
    } else {
        self.isMaximized = YES;
        [MultitaskDockManager.shared refreshMenu];
        [self updateOriginalFrame];
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.isMaximized = YES;
            [self updateVerticalConstraints];
            
            self.view.layer.borderWidth = 0;
            self.resizeHandle.alpha = 0;
            self.moveHandle.alpha = 0;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateMaximizedFrameWithSettings:settings];
            }];
        } completion:^(BOOL finished) {
            UIImage *restoreImage = [UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left.circle"];
            UIImageConfiguration *restoreConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            self.maximizeButton.image = [restoreImage imageWithConfiguration:restoreConfig];
        }];
    }
}
//⭐️⭐️⭐️
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        self.view.layer.masksToBounds = NO;
        [UIView transitionWithView:self.view duration:0.4 options:UIViewAnimationOptionTransitionCurlUp animations:^{
            self.view.hidden = YES;
        } completion:^(BOOL b){
            [self.view removeFromSuperview];
        }];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}
//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
       } else {
            self.pid = vc.pid;
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
            self.pidAvailableHandler(@(self.pid), nil);
            }
    
       }

    });
}
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext {
    UIMutableApplicationSceneSettings *newSettings = [vc.presenter.scene.settings mutableCopy];
    newSettings.userInterfaceStyle = baseSettings.userInterfaceStyle;
    newSettings.interfaceOrientation = baseSettings.interfaceOrientation;
    newSettings.deviceOrientation = baseSettings.deviceOrientation;
    newSettings.foreground = YES;
    
    if(self.isMaximized) {
        [self updateMaximizedFrameWithSettings:newSettings];
    } else {
        [self updateWindowedFrameWithSettings:newSettings];
    }
    
    CGFloat viewW = _appSceneVC.view.frame.size.width / self.scaleRatio;
    CGFloat viewH = _appSceneVC.view.frame.size.height / self.scaleRatio;

    //CGFloat viewW = self.view.frame.size.width / self.scaleRatio;
    //CGFloat viewH = (self.view.frame.size.height - self.navigationBar.frame.size.height) / self.scaleRatio;
    if (viewW <= 0 || viewH <= 0) {
    [_appSceneVC.presenter.scene updateSettings:newSettings withTransitionContext:newContext completion:nil];
    return;
    }
    CGFloat offsetX = 0;
    CGFloat constrainedW = viewW;
    BOOL forceLandscapeEnabled = LCForceLandscapeModeEnabled(self.appSceneVC.bundleId);
    NSLog(@"[ForceLandscapeMode] host didUpdateFromSettings bundleId=%@ enabled=%d isMaximized=%d viewW=%f viewH=%f",
          self.appSceneVC.bundleId, forceLandscapeEnabled, self.isMaximized, viewW, viewH);
    if (forceLandscapeEnabled) {
        CGRect constrained = LCLandscapeLetterboxedRect(CGRectMake(0, 0, viewW, viewH));
        constrainedW = constrained.size.width;
        offsetX = constrained.origin.x;
        _appSceneVC.contentView.autoresizingMask = UIViewAutoresizingNone;
        _appSceneVC.contentView.frame = constrained;
    } else {
        _appSceneVC.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _appSceneVC.contentView.frame = CGRectMake(0, 0, viewW, viewH);
    }
    CGRect newFrame = CGRectMake(offsetX, 0, constrainedW, viewH);


    
    if(UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
        newSettings.frame = CGRectMake(0, offsetX, newFrame.size.height, newFrame.size.width);
    } else {
        newSettings.frame = CGRectMake(newFrame.origin.x, 0, newFrame.size.width, newFrame.size.height);
    }
    
    [_appSceneVC.presenter.scene updateSettings:newSettings withTransitionContext:newContext completion:nil];
}



- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}
//⭐️⭐️⭐️
- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
            
                   [(id)subview setSpacing:spacing]; 
                
            }
            
            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            
            return;
        }
        
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}

//⭐️⭐️⭐️
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"LCMultitaskToolbarMode"]) {
        id newValue = change[NSKeyValueChangeNewKey];
        if (!newValue || [newValue isKindOfClass:[NSNull class]]) return;
        NSInteger newMode = [newValue integerValue];
        
        [UIView animateWithDuration:0.3 animations:^{
            switch (newMode) {
                case 0: {
                    self.navigationBar.hidden = NO;
                    
                    self.navigationItem.rightBarButtonItems = self.navigationItem.leftBarButtonItems ?: self.navigationItem.rightBarButtonItems;
                    self.navigationItem.leftBarButtonItems = nil;
                    
                    
                    [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:0]; 
                    break;
                }
                
                case 1: {
                    self.navigationBar.hidden = NO;
                    
                    self.navigationItem.leftBarButtonItems = self.navigationItem.rightBarButtonItems ?: self.navigationItem.leftBarButtonItems;
                    self.navigationItem.rightBarButtonItems = nil;
                    
                    
                    NSUInteger lastIndex = self.mainStackView.arrangedSubviews.count;
                    [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:lastIndex];
                    break;
                }
                
                case 2: 
                default: {
                    self.navigationBar.hidden = YES;
                
                    [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:self.mainStackView.arrangedSubviews.count];
                    break;
                }
            }
            
            
            [self updateVerticalConstraints];
            [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
            [self.mainStackView layoutIfNeeded]; 
        }];
        return;
    }
    
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        if([keyPath isEqualToString:@"LCMultitaskBottomWindowBar"]) {
            BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
            // Swap the two sides rather than clearing one of them. In overlay mode the side
            // opposite the traffic lights is holding the title item, and nilling it out here
            // would throw the title away.
            NSArray *previousLeft = self.navigationItem.leftBarButtonItems;
            self.navigationItem.leftBarButtonItems = self.navigationItem.rightBarButtonItems;
            self.navigationItem.rightBarButtonItems = previousLeft;
            // Overlay mode keeps the bar out of the stack view entirely, so there's nothing to
            // re-arrange. updateVerticalConstraints moves it with its edge constraint instead.
            if(!self.navBarIsOverlay) {
                if(bottomWindowBar) {
                    [self.mainStackView addArrangedSubview:self.navigationBar];
                } else {
                    [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:0];
                }
            }
        }

        [self updateVerticalConstraints];
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];

        if(_isMaximized) {
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateMaximizedFrameWithSettings:settings];
            }];
        }
        [self.view layoutIfNeeded];
    }];
}



- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
}
//⭐️⭐️⭐️Force Landscape Mode + multitask mode
- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];
    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
    
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[ResizeHandleView class]] && subview != self.resizeHandle) {
            subview.frame = CGRectMake(0, 0, subview.frame.size.width, subview.frame.size.height);
        }
    }
    CGFloat handleSize = self.resizeHandle.frame.size.width;
    self.resizeHandle.frame = CGRectMake(self.view.frame.size.width - handleSize, self.view.frame.size.height - handleSize, handleSize, handleSize);
    CGFloat viewW = self.view.frame.size.width / self.scaleRatio;
    CGFloat viewH = (self.view.frame.size.height - self.navigationBar.frame.size.height) / self.scaleRatio;

    // This call site was tagged as a Force Landscape Mode spot but never actually
    // applied the crop — it always set contentView to the full uncropped
    // rect, so every tick of a live drag-resize flashed uncropped content
    // until the next unrelated layout pass happened to call
    // -viewWillLayoutSubviews and correct it. Route through the same shared
    // helper as every other call site so dragging the resize handle can't
    // desync from windowed/maximized/initial-launch behavior again.
    if (LCForceLandscapeModeEnabled(self.appSceneVC.bundleId)) {
        _appSceneVC.contentView.autoresizingMask = UIViewAutoresizingNone;
        _appSceneVC.contentView.frame = LCLandscapeLetterboxedRect(CGRectMake(0, 0, viewW, viewH));
    } else {
        _appSceneVC.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _appSceneVC.contentView.frame = CGRectMake(0, 0, viewW, viewH);
    }
    [self.appSceneVC updateFrameWithSettingsBlock:nil];
}




- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // FIXME: how to bring view to front when touching the passthrough view?
    [self.view.superview bringSubviewToFront:self.view];
}
- (void)applyTitleBarItem {
    // The title goes on the opposite side from the traffic lights. With the bottom bar the
    // lights sit on the left, so the title takes the right, and the other way around otherwise.
    NSInteger toolbarMode = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskToolbarMode"];
    NSArray *titleItems = (self.navBarIsOverlay && self.titleBarButtonItem) ? @[self.titleBarButtonItem] : nil;
    if(toolbarMode == 1) {
        self.navigationItem.rightBarButtonItems = titleItems;
    } else {
        self.navigationItem.leftBarButtonItems = titleItems;
    }
}

- (void)animateNavigationBarHidden:(BOOL)hidden bottomBar:(BOOL)bottomBar {
    // Slide the bar with its safe area edge constraint instead of a transform. An interrupted
    // transform animation leaves stale state sitting on the view, and going through layout keeps
    // the change scoped to the bar, so appSceneVC.view next to it doesn't get pushed around.
    if(!self.navigationBarEdgeConstraint) {
        self.navigationBar.alpha = hidden ? 0 : 1;
        self.navigationBar.hidden = hidden;
        return;
    }
    if(!hidden) {
        self.navigationBar.hidden = NO;
    }
    self.navigationBarEdgeConstraint.constant = hidden ? (bottomBar ? 44 : -44) : 0;
    self.navigationBar.userInteractionEnabled = !hidden;
    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.navigationBar.alpha = hidden ? 0 : 1;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if(hidden && finished) self.navigationBar.hidden = YES;
    }];
}

- (void)updateVerticalConstraints {
    NSInteger toolbarMode = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskToolbarMode"];
    BOOL bottomWindowBar = (toolbarMode == 1);
    BOOL overlayEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskOverlayMode"];
    BOOL overlayMode = overlayEnabled && self.isMaximized && toolbarMode != 2;
    BOOL forceHideInMaximized = (MultitaskDockManager.shared.isCollapsed && _isMaximized);
    BOOL hideWindowBar = (toolbarMode == 2) || (!overlayMode && forceHideInMaximized);
    BOOL wasOverlay = self.navBarIsOverlay;

    // Collapsing or expanding the dock in overlay mode doesn't change any of the bar's
    // constraints or its items. All that changes is whether the bar is visible. If we tear the
    // constraints down and rebuild them anyway, the embedded scene gets a new frame for one
    // layout pass and the app visibly zooms. Slide the bar instead and leave the rest alone.
    BOOL configChanged = !self.hasBuiltConstraints
                      || (wasOverlay != overlayMode)
                      || (self.lastConstraintBottomBar != bottomWindowBar)
                      || (!overlayMode && self.lastConstraintHideBar != hideWindowBar);
    if(!configChanged) {
        [self animateNavigationBarHidden:(overlayMode ? forceHideInMaximized : hideWindowBar) bottomBar:bottomWindowBar];
        return;
    }

    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        CGFloat navBarHeight = hideWindowBar ? 0 : 44;
        BOOL barHiddenNow = overlayMode ? forceHideInMaximized : hideWindowBar;
        self.navigationBar.alpha = barHiddenNow ? 0 : 1;
        self.navigationBar.hidden = barHiddenNow;
        self.navigationBar.userInteractionEnabled = !barHiddenNow;

        // Update safe area insets
        if(self.isMaximized) {
            self.appSceneVC.shouldSkipDebounceOnce = YES;
            __weak typeof(self) weakSelf = self;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }

        self.hasBuiltConstraints = YES;
        self.lastConstraintBottomBar = bottomWindowBar;
        self.lastConstraintHideBar = hideWindowBar;
        self.navBarIsOverlay = overlayMode;

        // Hand the window name over to the button in overlay mode and take it back afterwards,
        // so we never show both at once.
        self.navigationItem.title = overlayMode ? nil : self.title;
        [self.navigationItem setTitleMenuProvider:overlayMode ? nil : self.titleMenuProviderBlock];
        [self applyTitleBarItem];

        [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];

        if(overlayMode) {
            // Pull the bar out of the stack view so it stops taking up a row of its own and
            // floats over the app instead, then pin it to the safe area.
            if(!wasOverlay) {
                if([self.mainStackView.arrangedSubviews containsObject:self.navigationBar]) {
                    [self.mainStackView removeArrangedSubview:self.navigationBar];
                }
                [self.navigationBar removeFromSuperview];
                self.navigationBar.translatesAutoresizingMaskIntoConstraints = NO;
                self.navigationBar.autoresizingMask = UIViewAutoresizingNone;
                [self.view addSubview:self.navigationBar];
            }
            [self.view bringSubviewToFront:self.navigationBar];

            UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
            self.navigationBarEdgeConstraint = bottomWindowBar
                ? [self.navigationBar.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor]
                : [self.navigationBar.topAnchor constraintEqualToAnchor:safeArea.topAnchor];
            self.navigationBarEdgeConstraint.constant = forceHideInMaximized ? (bottomWindowBar ? 44 : -44) : 0;
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [self.navigationBar.heightAnchor constraintEqualToConstant:44],
                [self.navigationBar.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
                [self.navigationBar.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
                self.navigationBarEdgeConstraint
            ];
        } else {
            if(wasOverlay) {
                [self.navigationBar removeFromSuperview];
                self.navigationBar.translatesAutoresizingMaskIntoConstraints = YES;
                self.navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                if(toolbarMode == 1) {
                    [self.mainStackView addArrangedSubview:self.navigationBar];
                } else {
                    [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:0];
                }
            }
            self.navigationBarEdgeConstraint = nil;

            UIView *appView = _appSceneVC.view;
            if(hideWindowBar) {
                [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:0];
                self.activatedVerticalConstraints = @[
                    [self.navigationBar.heightAnchor constraintEqualToConstant:0],
                    [appView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                    [appView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
                ];
            } else if(toolbarMode == 1) {
                [self.mainStackView addArrangedSubview:self.navigationBar];
                self.activatedVerticalConstraints = @[
                    [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight],
                    [appView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                    [appView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-navBarHeight]
                ];
            } else {
                [self.mainStackView insertArrangedSubview:self.navigationBar atIndex:0];
                self.activatedVerticalConstraints = @[
                    [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight],
                    [appView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:navBarHeight],
                    [appView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
                ];
            }
        }
        [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];

        [self.view bringSubviewToFront:self.resizeHandle];

        [self.view layoutIfNeeded];
    }];
}



//⭐️⭐️⭐️
- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    NSInteger toolbarMode = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskToolbarMode"];
    BOOL overlayEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskOverlayMode"];
    // Work out the overlay state from the pref and _isMaximized rather than reading
    // navBarIsOverlay. setupDecoratedView calls updateMaximizedFrameWithSettings before
    // updateVerticalConstraints has had a chance to set that property, so it would still be NO
    // here and we'd inset self.view.frame when we shouldn't. That leaves gaps around the app
    // until something triggers the next scene push.
    BOOL overlayMode = overlayEnabled && _isMaximized && toolbarMode != 2;

    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;

    if (toolbarMode == 2 || self.navigationBar.hidden || overlayMode) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
        
    } else if (toolbarMode == 1) {
    
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
        
    } else {
        
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }
    

    settings.peripheryInsets = UIEdgeInsetsMake(
        settings.peripheryInsets.top / _scaleRatio,
        settings.peripheryInsets.left / _scaleRatio,
        settings.peripheryInsets.bottom / _scaleRatio,
        settings.peripheryInsets.right / _scaleRatio
    );

    
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation currentOrientation = LCCurrentInterfaceOrientation();
        if (UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        
        switch (currentOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.left, 0, settings.peripheryInsets.right, settings.peripheryInsets.bottom);
                break;
            case UIInterfaceOrientationLandscapeRight:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right, 0);
                break;
            default:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
                break;
        }
    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }

    
    
    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}


- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    self.view.frame = maxFrame;
}
//⭐️⭐️⭐️
- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    

    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, 
                                 self.originalFrame.origin.y * maxFrame.size.height, 
                                 self.originalFrame.size.width, 
                                 self.originalFrame.size.height);
    
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    
    
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    
   
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    
   
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, 
                         MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, 
                         center.x - frame.size.width / 2));
                         
   
    frame.origin.y = MAX(maxFrame.origin.y, 
                         MIN(center.y - frame.size.height / 2, 
                         CGRectGetMaxY(maxFrame) - frame.size.height));
    
   
    [UIView animateWithDuration:0.3 animations:^{
        self.view.frame = frame;
        self.view.layer.borderWidth = 1.0; 
        self.resizeHandle.alpha = 1.0;     
        self.moveHandle.alpha = 1.0;       
    }];
}


- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(self.view.frame.origin.x / maxFrame.size.width, self.view.frame.origin.y / maxFrame.size.height, self.view.frame.size.width, self.view.frame.size.height);
}

@end
