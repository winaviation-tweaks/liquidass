#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <string.h>
#import "../LiquidAssPrefs/LGPrefsLiquidSlider.h"
#import "../LiquidAssPrefs/LGPrefsLiquidSwitch.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLiquidMotion.h"
#import "../Shared/LGLensRectState.h"

static void *kLGSettingsSwitchOverlayKey = &kLGSettingsSwitchOverlayKey;
static void *kLGSettingsSliderOverlayKey = &kLGSettingsSliderOverlayKey;
static void *kLGSettingsSliderVisualHostKey = &kLGSettingsSliderVisualHostKey;
static void *kLGSettingsSegmentGlassKey = &kLGSettingsSegmentGlassKey;
static void *kLGSettingsTopFadeKey = &kLGSettingsTopFadeKey;
static void *kLGSettingsBackButtonKey = &kLGSettingsBackButtonKey;
static void *kLGLiquidAssEntryFooterKey = &kLGLiquidAssEntryFooterKey;
static void *kLGSettingsBarBackgroundStateKey =
    &kLGSettingsBarBackgroundStateKey;
static void *kLGSettingsStockBackStateKey = &kLGSettingsStockBackStateKey;
static BOOL gLGSettingsControlsEnabled = NO;
static BOOL gLGSwitchControlsEnabled = NO;
static BOOL gLGSliderControlsEnabled = NO;
static BOOL gLGSegmentControlsEnabled = NO;
static BOOL gLGControlsDiagnosticsEnabled = NO;

static id LGPreferenceSpecifierProperty(id specifier, NSString *key) {
    SEL selector = NSSelectorFromString(@"propertyForKey:");
    if (!specifier || ![specifier respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(specifier, selector, key);
}

static BOOL LGIsLiquidAssPreferenceLoaderCell(UITableViewCell *cell) {
    id specifier = nil;
    if ([cell respondsToSelector:NSSelectorFromString(@"specifier")]) {
        specifier = ((id (*)(id, SEL))objc_msgSend)(cell,
                                                    NSSelectorFromString(@"specifier"));
    }
    for (NSString *key in @[@"lazy-bundle", @"bundle", @"bundlePath"]) {
        id value = LGPreferenceSpecifierProperty(specifier, key);
        if ([[value description] containsString:@"LiquidAssPrefs"]) return YES;
    }

    NSString *title = cell.textLabel.text ?: LGPreferenceSpecifierProperty(specifier, @"label");
    id detail = LGPreferenceSpecifierProperty(specifier, @"detail");
    return [title isEqualToString:@"Liquid (Gl)ass"] &&
           [[detail description] containsString:@"LGPRootListController"];
}

static void LGUpdateLiquidAssEntryFooter(UITableViewCell *cell) {
    UILabel *footer = objc_getAssociatedObject(cell, kLGLiquidAssEntryFooterKey);
    if (!gLGSettingsControlsEnabled) {
        footer.hidden = YES;
        return;
    }
    if (!LGIsLiquidAssPreferenceLoaderCell(cell)) {
        footer.hidden = YES;
        return;
    }
    if (!footer) {
        footer = [[UILabel alloc] initWithFrame:CGRectZero];
        footer.text = @"dylv";
        footer.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        footer.textColor = UIColor.tertiaryLabelColor;
        footer.textAlignment = NSTextAlignmentRight;
        footer.userInteractionEnabled = NO;
        footer.accessibilityElementsHidden = YES;
        [cell.contentView addSubview:footer];
        objc_setAssociatedObject(cell, kLGLiquidAssEntryFooterKey, footer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    footer.hidden = NO;
    [cell.contentView bringSubviewToFront:footer];
    CGFloat width = MIN(120.0, CGRectGetWidth(cell.contentView.bounds) * 0.42);
    footer.frame = CGRectMake(CGRectGetWidth(cell.contentView.bounds) - width - 8.0,
                              CGRectGetHeight(cell.contentView.bounds) - 14.0,
                              width, 12.0);
}

typedef NS_ENUM(NSUInteger, LGControlsDiagnosticKind) {
    LGControlsDiagnosticSwitch,
    LGControlsDiagnosticSlider,
    LGControlsDiagnosticKindCount,
};

typedef struct {
    NSUInteger calls;
    NSUInteger created;
    double totalMilliseconds;
    double maximumMilliseconds;
} LGControlsDiagnosticBucket;

static LGControlsDiagnosticBucket gLGControlsDiagnosticBuckets[LGControlsDiagnosticKindCount];
static CFTimeInterval gLGControlsDiagnosticWindowStart = 0.0;
static NSUInteger gLGControlsSliderTrackingCalls = 0;
static NSUInteger gLGControlsSliderOwnerMoves = 0;
static NSUInteger gLGControlsSliderOwnerLayouts = 0;
static NSUInteger gLGControlsSliderOverlayMoves = 0;
static NSUInteger gLGControlsSliderOverlayLayouts = 0;
static NSUInteger gLGControlsSliderVisualMoves = 0;
static NSUInteger gLGControlsSliderVisualLayouts = 0;
static NSUInteger gLGControlsSliderSetters = 0;
static NSUInteger gLGControlsSwitchMoves = 0;
static NSUInteger gLGControlsSwitchLayouts = 0;
static NSUInteger gLGControlsModernSwitchMoves = 0;
static NSUInteger gLGControlsModernSwitchLayouts = 0;
static NSUInteger gLGControlsModernSwitchAlphaSets = 0;

static void LGRecordControlsDiagnostic(LGControlsDiagnosticKind kind,
                                       CFTimeInterval started,
                                       BOOL created) {
    if (!gLGControlsDiagnosticsEnabled) return;
    double milliseconds = (CACurrentMediaTime() - started) * 1000.0;
    LGControlsDiagnosticBucket *bucket = &gLGControlsDiagnosticBuckets[kind];
    bucket->calls++;
    bucket->created += created ? 1 : 0;
    bucket->totalMilliseconds += milliseconds;
    bucket->maximumMilliseconds = MAX(bucket->maximumMilliseconds, milliseconds);
    CFTimeInterval now = CACurrentMediaTime();
    if (gLGControlsDiagnosticWindowStart == 0.0) gLGControlsDiagnosticWindowStart = now;
    if (now - gLGControlsDiagnosticWindowStart < 1.0) return;
    LGControlsDiagnosticBucket *sw = &gLGControlsDiagnosticBuckets[LGControlsDiagnosticSwitch];
    LGControlsDiagnosticBucket *sl = &gLGControlsDiagnosticBuckets[LGControlsDiagnosticSlider];
    LGLog(@"[GlobalControlsPerf] switch calls=%lu created=%lu total=%.2fms max=%.2fms; slider calls=%lu created=%lu total=%.2fms max=%.2fms tracking=%lu",
               (unsigned long)sw->calls, (unsigned long)sw->created,
               sw->totalMilliseconds, sw->maximumMilliseconds,
               (unsigned long)sl->calls, (unsigned long)sl->created,
               sl->totalMilliseconds, sl->maximumMilliseconds,
               (unsigned long)gLGControlsSliderTrackingCalls);
    LGLog(@"[GlobalControlsSources] switch move=%lu layout=%lu modernMove=%lu modernLayout=%lu modernAlpha=%lu; slider ownerMove=%lu ownerLayout=%lu overlayMove=%lu overlayLayout=%lu visualMove=%lu visualLayout=%lu setters=%lu",
               (unsigned long)gLGControlsSwitchMoves,
               (unsigned long)gLGControlsSwitchLayouts,
               (unsigned long)gLGControlsModernSwitchMoves,
               (unsigned long)gLGControlsModernSwitchLayouts,
               (unsigned long)gLGControlsModernSwitchAlphaSets,
               (unsigned long)gLGControlsSliderOwnerMoves,
               (unsigned long)gLGControlsSliderOwnerLayouts,
               (unsigned long)gLGControlsSliderOverlayMoves,
               (unsigned long)gLGControlsSliderOverlayLayouts,
               (unsigned long)gLGControlsSliderVisualMoves,
               (unsigned long)gLGControlsSliderVisualLayouts,
               (unsigned long)gLGControlsSliderSetters);
    memset(gLGControlsDiagnosticBuckets, 0, sizeof(gLGControlsDiagnosticBuckets));
    gLGControlsSliderTrackingCalls = 0;
    gLGControlsSliderOwnerMoves = gLGControlsSliderOwnerLayouts = 0;
    gLGControlsSliderOverlayMoves = gLGControlsSliderOverlayLayouts = 0;
    gLGControlsSliderVisualMoves = gLGControlsSliderVisualLayouts = 0;
    gLGControlsSliderSetters = 0;
    gLGControlsSwitchMoves = gLGControlsSwitchLayouts = 0;
    gLGControlsModernSwitchMoves = gLGControlsModernSwitchLayouts = 0;
    gLGControlsModernSwitchAlphaSets = 0;
    gLGControlsDiagnosticWindowStart = now;
}

@interface LGSettingsLowBlurView : UIView
@property (nonatomic) CGFloat lgBlurRadius;
@end

@implementation LGSettingsLowBlurView
+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: CALayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    _lgBlurRadius = 3.0;
    [self lg_configure];
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self lg_configure]; }
- (void)layoutSubviews { [super layoutSubviews]; [self lg_configure]; }
- (void)setLgBlurRadius:(CGFloat)radius {
    if (fabs(_lgBlurRadius - radius) < 0.01) return;
    _lgBlurRadius = radius;
    [self lg_configure];
}

- (void)lg_configure {
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    if (!backdrop || ![self.layer isKindOfClass:backdrop]) return;
    @try {
        [self.layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [self.layer setValue:@YES forKey:@"windowServerAware"];
        if (![self.layer valueForKey:@"groupName"])
            [self.layer setValue:NSUUID.UUID.UUIDString forKey:@"groupName"];
        Class filterClass = NSClassFromString(@"CAFilter");
        SEL selector = NSSelectorFromString(@"filterWithName:");
        id filter = filterClass && [filterClass respondsToSelector:selector]
            ? ((id (*)(Class, SEL, NSString *))objc_msgSend)
                (filterClass, selector, @"gaussianBlur") : nil;
        if (filter) {
            [filter setValue:@(_lgBlurRadius) forKey:@"inputRadius"];
            [filter setValue:@YES forKey:@"inputNormalizeEdges"];
            self.layer.filters = @[ filter ];
        }
    } @catch (__unused NSException *exception) {}
}
@end

static const CGFloat kLGSettingsTopFadeBlurRadius = 14.0;
static const CGFloat kLGSidebarBorderWidth = 2.0;
static const CGFloat kLGSidebarBorderAlpha = 0.65;
static const CGFloat kLGSidebarBorderWhiteDark = 0.32;
static const CGFloat kLGSidebarTintAlpha = 0.80;

#define LG_FADE_RAMP_STOPS 6
static const CGFloat kLGFadeRampAlpha[LG_FADE_RAMP_STOPS] =
    { 1.0, 0.896, 0.648, 0.352, 0.104, 0.0 };
static NSArray *LGFadeRampLocations(void) {
    return @[ @0.0, @0.2, @0.4, @0.6, @0.8, @1.0 ];
}

static UIColor *LGSidebarBorderColor(UIView *view) {
    BOOL dark = view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return dark ? [UIColor colorWithWhite:kLGSidebarBorderWhiteDark
                                    alpha:kLGSidebarBorderAlpha]
                : [UIColor.whiteColor colorWithAlphaComponent:kLGSidebarBorderAlpha];
}

static UIColor *LGSidebarTintBaseColor(void) {
    UIColor *base = nil;
    SEL selector = NSSelectorFromString(@"tableCellGroupedBackgroundColor");
    if ([UIColor respondsToSelector:selector]) {
        base = ((UIColor *(*)(Class, SEL))objc_msgSend)(UIColor.class, selector);
    }
    if (!base) {
        if (@available(iOS 13.0, *)) base = UIColor.secondarySystemGroupedBackgroundColor;
    }
    return base ?: UIColor.whiteColor;
}

@interface LGSettingsTopFadeView : UIView
@property (nonatomic) BOOL lgTintEnabled;
@end

@implementation LGSettingsTopFadeView {
    LGSettingsLowBlurView *_blur;
    CAGradientLayer *_mask;
    CAGradientLayer *_tint;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _blur = [[LGSettingsLowBlurView alloc] initWithFrame:self.bounds];
    _blur.lgBlurRadius = kLGSettingsTopFadeBlurRadius;
    _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blur];
    _mask = [CAGradientLayer layer];
    _mask.startPoint = CGPointMake(0.5, 0.0);
    _mask.endPoint = CGPointMake(0.5, 1.0);
    NSMutableArray *maskColors = [NSMutableArray array];
    for (NSUInteger i = 0; i < LG_FADE_RAMP_STOPS; i++) {
        [maskColors addObject:(__bridge id)
            [UIColor.blackColor colorWithAlphaComponent:kLGFadeRampAlpha[i]].CGColor];
    }
    _mask.colors = maskColors;
    _mask.locations = LGFadeRampLocations();
    _blur.layer.mask = _mask;

    _tint = [CAGradientLayer layer];
    _tint.startPoint = _mask.startPoint;
    _tint.endPoint = _mask.endPoint;
    _tint.locations = LGFadeRampLocations();
    _tint.hidden = YES;
    [self.layer addSublayer:_tint];
    return self;
}

- (void)setLgTintEnabled:(BOOL)enabled {
    if (_lgTintEnabled == enabled) return;
    _lgTintEnabled = enabled;
    _tint.hidden = !enabled;
    [self lg_updateTint];
}

- (void)lg_updateTint {
    if (!_lgTintEnabled) return;
    UIColor *tint = LGSidebarTintBaseColor();
    if (@available(iOS 13.0, *))
        tint = [tint resolvedColorWithTraitCollection:self.traitCollection];
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger i = 0; i < LG_FADE_RAMP_STOPS; i++) {
        [colors addObject:(__bridge id)
            [tint colorWithAlphaComponent:kLGSidebarTintAlpha *
                                          kLGFadeRampAlpha[i]].CGColor];
    }
    _tint.colors = colors;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!previous || previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        [self lg_updateTint];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    _mask.frame = self.bounds;
    _tint.frame = self.bounds;
}
@end

@interface LGSettingsBackButton : UIControl
@property (nonatomic, strong) LGLiveBackdropView *glass;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, weak) UIView *stockButton;
@property (nonatomic, strong) UIViewPropertyAnimator *pressAnimator;
@end

static void LGSettingsPerformSoftHaptic(void) {
    if (@available(iOS 13.0, *)) {
        UIImpactFeedbackGenerator *generator =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        [generator prepare];
        [generator impactOccurred];
    }
}

@implementation LGSettingsBackButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    _glass = LGCreateRegisteredGlass(self.bounds, nil, @"PrefsButton");
    _glass.userInteractionEnabled = NO;
    [self addSubview:_glass];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:24
                                                        weight:UIImageSymbolWeightRegular];
    _glyph = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.left" withConfiguration:configuration]];
    _glyph.tintColor = UIColor.labelColor;
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    [self addTarget:self action:@selector(lg_touchDown)
        forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(lg_pop) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.glass.frame = self.bounds;
    CGFloat radius = CGRectGetHeight(self.bounds) * 0.5;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.glass.layer.cornerRadius = radius;
    self.glass.layer.cornerCurve = kCACornerCurveContinuous;
    self.glass.layer.masksToBounds = YES;
    self.glyph.frame = self.bounds;
}
- (void)lg_touchDown {
    LGSettingsPerformSoftHaptic();
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    CALayer *presentation = self.layer.presentationLayer;
    if (presentation) self.transform = CATransform3DGetAffineTransform(presentation.transform);
    [self.pressAnimator stopAnimation:YES];
    CGFloat mass = 0.8;
    CGFloat stiffness = 300.0;
    CGFloat damping = highlighted ? 18.0 : 12.0;
    CGFloat velocity = highlighted ? 0.5 : 1.0;
    CGFloat duration = highlighted ? 0.3 : 0.5;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass stiffness:stiffness damping:damping
        initialVelocity:CGVectorMake(velocity, velocity)];
    self.pressAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:duration timingParameters:timing];
    __weak typeof(self) weakSelf = self;
    [self.pressAnimator addAnimations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;

        strongSelf.transform = highlighted ? CGAffineTransformMakeScale(1.16, 1.16)
                                            : CGAffineTransformIdentity;
    }];
    [self.pressAnimator startAnimation];
}
- (BOOL)lg_invokeView:(UIView *)view {
    if ([view isKindOfClass:UIControl.class] &&
        ((UIControl *)view).allTargets.count > 0) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        NSArray *targets = nil;
        @try { targets = [recognizer valueForKey:@"_targets"]; }
        @catch (__unused NSException *exception) {}
        for (id targetAction in targets) {
            id target = nil;
            NSString *actionName = nil;
            @try {
                target = [targetAction valueForKey:@"target"];
                actionName = [targetAction valueForKey:@"action"];
            } @catch (__unused NSException *exception) {}
            SEL action = NSSelectorFromString(actionName);
            if (target && action && [target respondsToSelector:action]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
                return YES;
            }
        }
    }
    for (UIView *subview in view.subviews)
        if ([self lg_invokeView:subview]) return YES;
    return NO;
}
- (void)lg_pop {
    if (![self lg_invokeView:self.stockButton])
        [self.navigationController popViewControllerAnimated:YES];
}
@end

static BOOL LGSettingsFeatureEnabled(void) {
    id settings = LGGlassPreferenceValue(@"SettingsControls.Enabled");

    return ![settings respondsToSelector:@selector(boolValue)] ||
           [settings boolValue];
}

static BOOL LGGlobalControlPreferenceEnabled(NSString *key, BOOL fallback) {
    id value = LGGlassPreferenceValue(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static BOOL LGProcessIsExcludedFromGlobalControls(void) {
    id stored = LGGlassPreferenceValue(@"GlobalControls.Exclusions");
    NSString *exclusions = [stored isKindOfClass:NSString.class]
        ? (NSString *)stored : @"NewTerm\nFilza\nTikTok\nDiscord\ncom.spotify.client";
    return LGProcessMatchesExclusionList(exclusions);
}

static void LGRefreshGlobalControlEnablement(void) {
    gLGSettingsControlsEnabled = LGSettingsFeatureEnabled();
    BOOL allowed = gLGSettingsControlsEnabled && !LGProcessIsExcludedFromGlobalControls();
    gLGSwitchControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Switches.Enabled", YES);
    gLGSliderControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Sliders.Enabled", NO);
    gLGSegmentControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Segmented.Enabled", NO);
}

static BOOL LGInsideLiquidAssPrefs(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        NSBundle *bundle = [NSBundle bundleForClass:r.class];
        if ([bundle.bundleIdentifier isEqualToString:@"dylv.liquidassprefs"] ||
            [NSStringFromClass(r.class) hasPrefix:@"LG"]) return YES;
    }
    return NO;
}

static BOOL LGControllerContainsLiquidAssPrefs(UIViewController *controller) {
    if (!controller) return NO;
    if ([[NSBundle bundleForClass:controller.class].bundleIdentifier
         isEqualToString:@"dylv.liquidassprefs"] ||
        [NSStringFromClass(controller.class) hasPrefix:@"LG"]) return YES;
    for (UIViewController *child in controller.childViewControllers)
        if (LGControllerContainsLiquidAssPrefs(child)) return YES;
    return controller.presentedViewController &&
           LGControllerContainsLiquidAssPrefs(controller.presentedViewController);
}

static BOOL LGSettingsChromeEnabledForView(UIView *view) {
    if (gLGSettingsControlsEnabled) return YES;
    if (LGInsideLiquidAssPrefs(view)) return YES;
    return LGControllerContainsLiquidAssPrefs(view.window.rootViewController);
}

static BOOL LGViewIsInsideSidebar(UIView *view);

static BOOL LGSettingsWrapperIsFullHeightColumn(UIView *wrapper) {
    UIWindow *window = wrapper.window;
    if (!window || CGRectIsEmpty(wrapper.bounds)) return NO;
    if (LGViewIsInsideSidebar(wrapper)) return YES;
    CGRect frame = [wrapper convertRect:wrapper.bounds toView:window];
    CGRect screen = window.bounds;
    if (fabs(CGRectGetHeight(frame) - CGRectGetHeight(screen)) > 1.0) return NO;
    if (fabs(CGRectGetMinY(frame) - CGRectGetMinY(screen)) > 1.0) return NO;
    return CGRectGetWidth(frame) >= 240.0;
}

static BOOL LGSettingsWrapperIsClosestToWindow(UIView *wrapper) {
    Class wrapperClass = NSClassFromString(@"UIViewControllerWrapperView");
    if (!wrapper.window || !wrapperClass) return NO;
    for (UIView *ancestor = wrapper.superview; ancestor && ancestor != wrapper.window;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:wrapperClass]) return NO;
    }
    return YES;
}

static UINavigationBar *LGSearchForNavigationBar(UIView *root, UIView *skip) {
    for (UIView *sub in root.subviews) {
        if (sub == skip) continue;
        if ([sub isKindOfClass:UINavigationBar.class]) return (UINavigationBar *)sub;
        UINavigationBar *found = LGSearchForNavigationBar(sub, skip);
        if (found) return found;
    }
    return nil;
}

static UINavigationBar *LGFindSettingsNavigationBar(UIView *wrapper) {
    UIView *child = wrapper;
    for (UIView *node = wrapper; node; child = node, node = node.superview) {
        UINavigationBar *found = LGSearchForNavigationBar(node, child);
        if (found && found.window == wrapper.window) return found;
    }
    return nil;
}

static const CGFloat kLGSettingsFadeTaper = 10.0;

static void LGUpdateSettingsTopFade(UIView *wrapper) {
    if (!LGSettingsChromeEnabledForView(wrapper) ||
        !LGSettingsWrapperIsFullHeightColumn(wrapper) ||
        !LGSettingsWrapperIsClosestToWindow(wrapper)) {
        [objc_getAssociatedObject(wrapper, kLGSettingsTopFadeKey) removeFromSuperview];
        objc_setAssociatedObject(wrapper, kLGSettingsTopFadeKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    LGSettingsTopFadeView *fade =
        objc_getAssociatedObject(wrapper, kLGSettingsTopFadeKey);
    if (!fade) {
        fade = [[LGSettingsTopFadeView alloc] initWithFrame:CGRectZero];
        [wrapper addSubview:fade];
        objc_setAssociatedObject(wrapper, kLGSettingsTopFadeKey, fade,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UINavigationBar *navigationBar = LGFindSettingsNavigationBar(wrapper);
    CGFloat solid = 0.0;
    if (navigationBar && navigationBar.window && !navigationBar.hidden) {
        UIView *measured = nil;
        for (NSString *name in @[@"_UINavigationBarContentView", @"_UIBarBackground"]) {
            Class cls = NSClassFromString(name);
            if (!cls) continue;
            for (UIView *sub in navigationBar.subviews) {
                if ([sub isKindOfClass:cls]) { measured = sub; break; }
            }
            if (measured) break;
        }
        if (!measured) measured = navigationBar;
        solid = CGRectGetMaxY([measured convertRect:measured.bounds toView:wrapper]);
    }

    CGFloat height = solid > 1.0 ? solid + kLGSettingsFadeTaper
                                 : MAX(60.0, wrapper.safeAreaInsets.top + 16.0);
    fade.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(wrapper.bounds), height);
    fade.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleBottomMargin;
    fade.lgTintEnabled = LGViewIsInsideSidebar(wrapper);
    [wrapper bringSubviewToFront:fade];
}

static void LGHideSettingsNavigationBarBackground(UINavigationBar *bar) {
    Class backgroundClass = NSClassFromString(@"_UIBarBackground");
    if (!backgroundClass) return;
    BOOL chromeEnabled = LGSettingsChromeEnabledForView(bar);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:bar.subviews];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:backgroundClass]) {
            NSDictionary *original = objc_getAssociatedObject(
                view, kLGSettingsBarBackgroundStateKey);
            if (!chromeEnabled) {
                if (original) {
                    view.hidden = [original[@"hidden"] boolValue];
                    view.alpha = [original[@"alpha"] doubleValue];
                    view.userInteractionEnabled =
                        [original[@"interaction"] boolValue];
                    objc_setAssociatedObject(
                        view, kLGSettingsBarBackgroundStateKey, nil,
                        OBJC_ASSOCIATION_ASSIGN);
                }
                continue;
            }
            if (!original) {
                objc_setAssociatedObject(
                    view, kLGSettingsBarBackgroundStateKey,
                    @{@"hidden": @(view.hidden),
                      @"alpha": @(view.alpha),
                      @"interaction": @(view.userInteractionEnabled)},
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
            continue;
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void LGHideStockControlContents(UIView *control, UIView *except) {
    for (UIView *subview in control.subviews)
        if (subview != except) subview.alpha = 0.0;
}

static BOOL LGViewTreeHasSpeechRateEndpoints(UIView *root);

static UISlider *LGSettingsSliderOwnerForVisualElement(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview)
        if ([candidate isKindOfClass:UISlider.class]) return (UISlider *)candidate;
    return nil;
}

static void LGSetNativeSliderTreeSuppressed(UIView *view, BOOL preserve) {
    if (!view) return;
    view.hidden = NO;
    view.userInteractionEnabled = NO;
    view.alpha = preserve ? 1.0 : 0.0;
    for (UIView *subview in view.subviews) {
        BOOL preserveSubview = preserve || [subview isKindOfClass:UILabel.class];
        LGSetNativeSliderTreeSuppressed(subview, preserveSubview);
    }
}

static void LGSuppressNativeSliderContents(UISlider *owner,
                                           LGPrefsLiquidSlider *overlay) {
    UIView *visualHost = objc_getAssociatedObject(owner,
                                                   kLGSettingsSliderVisualHostKey);
    UIView *root = visualHost ?: owner;
    for (UIView *subview in root.subviews) {
        if (subview == overlay) continue;
        LGSetNativeSliderTreeSuppressed(subview,
            [subview isKindOfClass:UILabel.class]);
    }
}

static UIView *LGSettingsSliderOverlayContainer(UISlider *owner) {
    // mount outside the stock slider so value labels stay untouched
    UIView *start = owner.superview ?: owner;
    UIView *container = start;
    for (UIView *candidate = start; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) break;
        container = candidate;
    }
    return container;
}

static CGRect LGSettingsSliderOverlayFrame(UISlider *owner, UIView *container) {
    UIView *host = objc_getAssociatedObject(owner, kLGSettingsSliderVisualHostKey);
    CGRect contentFrame = CGRectNull;
    CGRect labelFrame = CGRectNull;
    for (UIView *subview in host.subviews) {
        if (CGRectIsEmpty(subview.bounds)) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:container];
        if ([subview isKindOfClass:UILabel.class]) {
            labelFrame = CGRectIsNull(labelFrame) ? frame : CGRectUnion(labelFrame, frame);
        } else {
            contentFrame = CGRectIsNull(contentFrame) ? frame : CGRectUnion(contentFrame, frame);
        }
    }
    if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame))
        contentFrame = [owner convertRect:owner.bounds toView:container];
    if (!CGRectIsNull(labelFrame) &&
        CGRectGetMinX(labelFrame) > CGRectGetMinX(contentFrame)) {
        CGFloat maximumX = CGRectGetMinX(labelFrame) - 6.0;
        if (maximumX > CGRectGetMinX(contentFrame))
            contentFrame.size.width = maximumX - CGRectGetMinX(contentFrame);
    }
    return contentFrame;
}

static void LGInstallSettingsSwitch(UISwitch *owner) {
    if (!gLGSwitchControlsEnabled || !owner.window ||
        [owner isKindOfClass:LGPrefsLiquidSwitch.class] ||
        LGInsideLiquidAssPrefs(owner)) return;

    LGPrefsLiquidSwitch *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey);
    if (!overlay) {
        overlay = [[LGPrefsLiquidSwitch alloc] initWithFrame:owner.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
        __weak UISwitch *weakOwner = owner;
        [overlay addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UISwitch *strongOwner = weakOwner;
            LGPrefsLiquidSwitch *sender = (LGPrefsLiquidSwitch *)action.sender;
            if (!strongOwner) return;
            [strongOwner setOn:sender.isOn animated:NO];
            [strongOwner sendActionsForControlEvents:UIControlEventValueChanged];
        }] forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(owner, kLGSettingsSwitchOverlayKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [owner addSubview:overlay];
    }

    owner.clipsToBounds = NO;
    owner.layer.masksToBounds = NO;
    overlay.frame = CGRectMake(-8.0, 0.0,
                               CGRectGetWidth(owner.bounds) + 8.0,
                               CGRectGetHeight(owner.bounds));
    if (overlay.isOn != owner.isOn) [overlay setOn:owner.isOn animated:NO];
    overlay.enabled = owner.enabled;
    LGHideStockControlContents(owner, overlay);
    [owner bringSubviewToFront:overlay];
}

static BOOL LGSliderUsesStockArtwork(UISlider *slider) {
    static Class resizableImageClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        resizableImageClass = NSClassFromString(@"_UIResizableImage");
    });
    if (!resizableImageClass) return YES;
    UIImage *images[] = { slider.currentThumbImage,
                          slider.currentMinimumTrackImage,
                          slider.currentMaximumTrackImage };
    for (size_t i = 0; i < sizeof(images) / sizeof(images[0]); i++) {
        if (images[i] && ![images[i] isKindOfClass:resizableImageClass]) return NO;
    }
    UIColor *tints[] = { slider.thumbTintColor,
                         slider.minimumTrackTintColor,
                         slider.maximumTrackTintColor };
    for (size_t i = 0; i < sizeof(tints) / sizeof(tints[0]); i++) {
        if (tints[i] && CGColorGetAlpha(tints[i].CGColor) < 0.01) return NO;
    }
    return YES;
}

static void LGRemoveSettingsSliderOverlay(UISlider *owner) {
    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    if (!overlay) return;
    objc_setAssociatedObject(owner, kLGSettingsSliderOverlayKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    [overlay removeFromSuperview];
    UIView *visualHost = objc_getAssociatedObject(owner,
                                                  kLGSettingsSliderVisualHostKey);
    UIView *root = visualHost ?: owner;
    for (UIView *subview in root.subviews) {
        if (subview == overlay) continue;
        LGSetNativeSliderTreeSuppressed(subview, YES);
    }
}

static UIImageView *LGSegmentSelectionIndicator(UISegmentedControl *control) {
    CGFloat height = CGRectGetHeight(control.bounds);
    if (!(height > 0.0)) return nil;
    for (UIView *subview in control.subviews) {
        if (![subview isKindOfClass:UIImageView.class]) continue;
        if (subview.subviews.count) continue;
        if (CGRectGetHeight(subview.frame) <= height) continue;
        return (UIImageView *)subview;
    }
    return nil;
}

static const CGFloat kLGSegmentGlassOverheight = 5.0;
static CGFloat LGSegmentGlassHeight(UISegmentedControl *control) {
    return CGRectGetHeight(control.bounds) + kLGSegmentGlassOverheight;
}
static const NSTimeInterval kLGSegmentMorphDuration = 0.18;

@class LGSegmentMotionState;
static void LGSegmentSetGestureClipping(LGSegmentMotionState *state,
                                        UISegmentedControl *control,
                                        BOOL clipping);


static const CGFloat kLGSegmentShapeScale = 0.70;
static NSArray<UIView *> *LGSegmentViews(UISegmentedControl *control) {
    NSMutableArray<UIView *> *segments = [NSMutableArray array];
    for (UIView *subview in control.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"UISegment"])
            [segments addObject:subview];
    }
    [segments sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = CGRectGetMinX(a.frame), bx = CGRectGetMinX(b.frame);
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    return segments;
}

static NSInteger LGSegmentIndexNearest(UISegmentedControl *control, CGFloat x) {
    NSArray<UIView *> *segments = LGSegmentViews(control);
    NSInteger best = NSNotFound;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < segments.count; i++) {
        CGFloat distance = fabs(CGRectGetMidX(segments[i].frame) - x);
        if (distance < bestDistance) { bestDistance = distance; best = (NSInteger)i; }
    }
    return best;
}

static CGFloat LGSegmentSpringStep(CGFloat current, CGFloat target,
                                   CGFloat *velocity, CGFloat response,
                                   CGFloat damping, CGFloat dt) {
    CGFloat remaining = fmin(fmax(dt, 0.0), 1.0 / 30.0);
    while (remaining > 0.0) {
        CGFloat step = fmin(remaining, 1.0 / 240.0);
        CGFloat omega = 2.0 * M_PI / response;
        CGFloat acceleration = (target - current) * omega * omega -
                               2.0 * damping * omega * (*velocity);
        *velocity += acceleration * step;
        current += *velocity * step;
        remaining -= step;
    }
    return current;
}

static const CGFloat kLGSegmentSpringResponse = 0.34;
static const CGFloat kLGSegmentSpringDamping  = 0.78;
static const CFTimeInterval kLGSegmentSpringEaseIn = 0.13;
static const CGFloat kLGSegmentSpringEaseFloor = 0.45;

@interface LGSegmentMotionState : NSObject
@property (nonatomic, weak) UISegmentedControl *control;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) CGFloat targetCenterX, targetWidth, targetHeight;
@property (nonatomic, assign) CGFloat renderedCenterX, renderedWidth, renderedHeight;
@property (nonatomic, assign) CGFloat velocityX, lastTouchX, gestureStartX;
@property (nonatomic, assign) BOOL dragged;
@property (nonatomic, assign) CGFloat centreVelocity, widthVelocity, heightVelocity;
@property (nonatomic, assign) CFTimeInterval settleStart;
@property (nonatomic, assign) CFTimeInterval lastTouchTime, lastFrameTime;
@property (nonatomic, strong) NSMutableArray<NSArray *> *clipState;
- (void)start;
- (void)stop;
@end

static void LGSegmentApplyRendered(LGSegmentMotionState *state);

@implementation LGSegmentMotionState
- (void)start {
    if (_displayLink) return;
    _lastFrameTime = CACurrentMediaTime();
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stop { [_displayLink invalidate]; _displayLink = nil; }
- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (CGFloat)MAX(now - _lastFrameTime, 1.0 / 120.0);
    _lastFrameTime = now;
    LGLiquidRenderedState current =
        LGLiquidRenderedStateMake(_renderedCenterX,
                                  CGSizeMake(_renderedWidth, _renderedHeight));
    LGLiquidRenderedState target =
        LGLiquidRenderedStateMake(_targetCenterX,
                                  CGSizeMake(_targetWidth, _targetHeight));
    if (_active) {
        current = LGLiquidRenderedStateStep(current, target, YES, dt);
        _centreVelocity = _widthVelocity = _heightVelocity = 0.0;
        _settleStart = 0.0;
    } else {
        if (_settleStart <= 0.0) _settleStart = now;
        CGFloat elapsed = (CGFloat)(now - _settleStart);
        CGFloat t = kLGSegmentSpringEaseIn > 0.0
            ? fmin(1.0, elapsed / kLGSegmentSpringEaseIn) : 1.0;
        CGFloat eased = t * t * (3.0 - 2.0 * t);            // smoothstep
        CGFloat ease = kLGSegmentSpringEaseFloor +
                       (1.0 - kLGSegmentSpringEaseFloor) * eased;
        CGFloat response = kLGSegmentSpringResponse / ease;

        current.centerX = LGSegmentSpringStep(current.centerX, target.centerX,
                                              &_centreVelocity, response,
                                              kLGSegmentSpringDamping, dt);
        current.width = LGSegmentSpringStep(current.width, target.width,
                                            &_widthVelocity, response,
                                            kLGSegmentSpringDamping, dt);
        current.height = LGSegmentSpringStep(current.height, target.height,
                                             &_heightVelocity, response,
                                             kLGSegmentSpringDamping, dt);
    }
    _renderedCenterX = current.centerX;
    _renderedWidth = current.width;
    _renderedHeight = current.height;
    LGSegmentApplyRendered(self);

    if (!_active &&
        fabs(_renderedCenterX - _targetCenterX) < 0.5 &&
        fabs(_renderedWidth - _targetWidth) < 0.5 &&
        fabs(_centreVelocity) < 12.0 && fabs(_widthVelocity) < 12.0) {
        UISegmentedControl *control = _control;
        UIView *glass =
            objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
        UIImageView *indicator = LGSegmentSelectionIndicator(control);
        [self stop];
        [UIView animateWithDuration:kLGSegmentMorphDuration delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseIn
                         animations:^{
            glass.alpha = 0.0;
            indicator.alpha = 1.0;
        } completion:^(BOOL finished) {
            if (finished) glass.hidden = YES;
            LGSegmentSetGestureClipping(self, control, YES);
        }];
    }
}
@end

static const CGFloat kLGSegmentOverhang = 26.0;
static const CGFloat kLGSegmentOverhangSoftness = 48.0;

static CGFloat LGSegmentRubberBandedCenterX(CGFloat touchX, CGFloat minX, CGFloat maxX) {
    if (touchX < minX) {
        CGFloat over = minX - touchX;
        return minX - kLGSegmentOverhang * (1.0 - exp(-over / kLGSegmentOverhangSoftness));
    }
    if (touchX > maxX) {
        CGFloat over = touchX - maxX;
        return maxX + kLGSegmentOverhang * (1.0 - exp(-over / kLGSegmentOverhangSoftness));
    }
    return touchX;
}

static void LGSegmentSetGestureClipping(LGSegmentMotionState *state,
                                        UISegmentedControl *control,
                                        BOOL clipping) {
    if (!clipping) {
        state.clipState = [NSMutableArray array];
        for (UIView *ancestor = control; ancestor; ancestor = ancestor.superview) {
            BOOL clips = ancestor.clipsToBounds;
            BOOL masks = ancestor.layer.masksToBounds;
            if (clips || masks) {
                [state.clipState addObject:@[ancestor, @(clips), @(masks)]];
                ancestor.clipsToBounds = NO;
                ancestor.layer.masksToBounds = NO;
            }
            if ([ancestor isKindOfClass:UITableViewCell.class]) break;
        }
        return;
    }
    for (NSArray *entry in state.clipState) {
        UIView *ancestor = entry[0];
        ancestor.clipsToBounds = [entry[1] boolValue];
        ancestor.layer.masksToBounds = [entry[2] boolValue];
    }
    state.clipState = nil;
}

static void LGSegmentApplyRendered(LGSegmentMotionState *state) {
    UISegmentedControl *control = state.control;
    UIView *glass =
        objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    if (!control || !glass) return;

    CGRect frame = CGRectMake(state.renderedCenterX - state.renderedWidth * 0.5,
                              CGRectGetMidY(control.bounds) - state.renderedHeight * 0.5,
                              state.renderedWidth, state.renderedHeight);

    CGSize captureSize = CGSizeMake(CGRectGetWidth(frame) / kLGSegmentShapeScale,
                                    CGRectGetHeight(frame) / kLGSegmentShapeScale);

    CGPoint captureCentre = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    UIWindow *captureWindow = control.window;
    if (captureWindow) {
        CGPoint inWindow = [control convertPoint:captureCentre toView:captureWindow];
        CGFloat half = captureSize.width * 0.5;
        CGFloat minCentre = half;
        CGFloat maxCentre = CGRectGetWidth(captureWindow.bounds) - half;
        if (minCentre <= maxCentre) {
            CGFloat clamped = MAX(minCentre, MIN(maxCentre, inWindow.x));
            if (clamped != inWindow.x) {
                CGPoint back = [control convertPoint:CGPointMake(clamped, inWindow.y)
                                            fromView:captureWindow];
                captureCentre.x = back.x;
            }
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glass.transform = CGAffineTransformIdentity;
    glass.bounds = CGRectMake(0.0, 0.0, captureSize.width, captureSize.height);
    glass.center = captureCentre;
    glass.layer.cornerRadius = MIN(captureSize.width, captureSize.height) * 0.5;
    glass.layer.masksToBounds = NO;
    glass.clipsToBounds = NO;
    {
        CGRect pillNow = [control convertRect:frame toView:glass];
        if ([glass isKindOfClass:LGLiveBackdropView.class]) {
            LGLiveBackdropView *backdrop = (LGLiveBackdropView *)glass;
            backdrop.lgShapeRect = pillNow;
            backdrop.lgShapeCornerRadius = CGRectGetHeight(pillNow) * 0.5;
        }
    }
    [CATransaction commit];

    CGRect pillInGlass = [control convertRect:frame toView:glass];
    LGLensRectWrite(LGLensRectSlotPrefsSegment, YES,
                    CGRectGetMinX(pillInGlass) / captureSize.width,
                    CGRectGetMinY(pillInGlass) / captureSize.height,
                    CGRectGetWidth(pillInGlass) / captureSize.width,
                    CGRectGetHeight(pillInGlass) / captureSize.height);
}

static LGSegmentMotionState *LGSegmentMotionStateFor(UISegmentedControl *control,
                                                     BOOL create) {
    static void *key = &key;
    LGSegmentMotionState *state = objc_getAssociatedObject(control, key);
    if (!state && create) {
        state = [LGSegmentMotionState new];
        state.control = control;
        objc_setAssociatedObject(control, key, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void LGSegmentAttachGesture(UISegmentedControl *control);
@class LGSegmentMotionState;
static void LGSegmentPresentGlass(UISegmentedControl *control,
                                  LGSegmentMotionState *state);

static void LGInstallSettingsSegment(UISegmentedControl *control) {
    if (!gLGSegmentControlsEnabled || !control.window ||
        LGInsideLiquidAssPrefs(control)) return;

    UIImageView *indicator = LGSegmentSelectionIndicator(control);
    if (!indicator) return;

    UIView *glass = objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    if (!glass) {
        LGLiveBackdropView *backdrop =
            LGCreateRegisteredGlass(CGRectZero, nil, @"PrefsSegment");
        if (!backdrop) return;
        backdrop.lgSpecularEnabledOverride = @NO;
        glass = backdrop;
        glass.userInteractionEnabled = NO;
        objc_setAssociatedObject(control, kLGSettingsSegmentGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (glass.superview != control || control.subviews.lastObject != glass) {
        [glass removeFromSuperview];
        [control addSubview:glass];
    }

    control.clipsToBounds = NO;
    control.layer.masksToBounds = NO;


    if (@available(iOS 13.0, *))
        glass.layer.cornerCurve = kCACornerCurveContinuous;

    LGSegmentAttachGesture(control);

    LGSegmentMotionState *state = LGSegmentMotionStateFor(control, YES);
    if (!state.displayLink) {
        CGRect frame = indicator.frame;
        frame = CGRectInset(frame, 0.0,
                            (CGRectGetHeight(frame) - LGSegmentGlassHeight(control)) * 0.5);
        glass.transform = CGAffineTransformIdentity;
        glass.bounds = CGRectMake(0.0, 0.0,
                                  CGRectGetWidth(frame) / kLGSegmentShapeScale,
                                  CGRectGetHeight(frame) / kLGSegmentShapeScale);
        glass.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        glass.layer.cornerRadius =
            MIN(CGRectGetWidth(glass.bounds), CGRectGetHeight(glass.bounds)) * 0.5;
        glass.hidden = YES;
        indicator.alpha = 1.0;
        LGLensRectWrite(LGLensRectSlotPrefsSegment, NO, 0.f, 0.f, 0.f, 0.f);
    }
}

static void LGSegmentBeginTracking(UISegmentedControl *control, CGPoint point) {
    LGInstallSettingsSegment(control);
    UIView *glass =
        objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    UIImageView *indicator = LGSegmentSelectionIndicator(control);
    if (!glass || !indicator) return;

    LGSegmentMotionState *state = LGSegmentMotionStateFor(control, YES);
    CGRect start = CGRectInset(indicator.frame, 0.0,
        (CGRectGetHeight(indicator.frame) - LGSegmentGlassHeight(control)) * 0.5);
    state.renderedCenterX = CGRectGetMidX(start);
    state.renderedWidth = CGRectGetWidth(start);
    state.renderedHeight = LGSegmentGlassHeight(control);
    state.targetCenterX = state.renderedCenterX;
    state.targetWidth = state.renderedWidth;
    state.targetHeight = LGSegmentGlassHeight(control);
    state.gestureStartX = point.x;
    state.lastTouchX = point.x;
    state.dragged = NO;
    state.lastTouchTime = CACurrentMediaTime();
    state.velocityX = 0.0;
    state.active = YES;

}

static void LGSegmentPresentGlass(UISegmentedControl *control,
                                  LGSegmentMotionState *state) {
    UIView *glass = objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    UIImageView *indicator = LGSegmentSelectionIndicator(control);
    if (!glass || !indicator || !glass.hidden) return;

    LGSegmentApplyRendered(state);
    LGSegmentSetGestureClipping(state, control, NO);
    [glass.layer removeAllAnimations];
    glass.hidden = NO;
    glass.alpha = 0.0;
    [UIView animateWithDuration:kLGSegmentMorphDuration delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        glass.alpha = 1.0;
        indicator.alpha = 0.0;
    } completion:nil];
    [state start];
}

static void LGSegmentContinueTracking(UISegmentedControl *control, CGPoint point) {
    LGSegmentMotionState *state = LGSegmentMotionStateFor(control, NO);
    if (!state.active) return;
    NSArray<UIView *> *segments = LGSegmentViews(control);
    if (!segments.count) return;

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = MAX(now - state.lastTouchTime, 0.001);
    if (!state.dragged && fabs(point.x - state.gestureStartX) > 4.0) {
        state.dragged = YES;
        LGSegmentPresentGlass(control, state);
    }
    if (!state.dragged) return;   // still a tap, leave it to the stock control
    state.velocityX = LGLiquidFilteredVelocity(state.velocityX,
                                               (point.x - state.lastTouchX) / dt);
    state.lastTouchX = point.x;
    state.lastTouchTime = now;

    CGFloat minimum = CGRectGetMidX(segments.firstObject.frame);
    CGFloat maximum = CGRectGetMidX(segments.lastObject.frame);
    CGFloat width = CGRectGetWidth(segments.firstObject.frame);

    CGFloat allowance = kLGSegmentOverhang;
    UIWindow *window = control.window;
    if (window) {
        CGRect restLeft  = [control convertRect:CGRectMake(minimum - width * 0.5, 0.0,
                                                           width, 1.0) toView:window];
        CGRect restRight = [control convertRect:CGRectMake(maximum - width * 0.5, 0.0,
                                                           width, 1.0) toView:window];
        CGFloat roomLeft  = CGRectGetMinX(restLeft);
        CGFloat roomRight = CGRectGetWidth(window.bounds) - CGRectGetMaxX(restRight);
        allowance = MIN(allowance, MAX(0.0, MIN(roomLeft, roomRight)));
    }
    LGLiquidDragState drag = LGLiquidDragStateMake(
        point.x, minimum, maximum,
        CGSizeMake(width, LGSegmentGlassHeight(control)),
        state.velocityX, LGSegmentGlassHeight(control) * 0.8);
    CGFloat sharedBand = LGLiquidRubberBandedCenterX(point.x, minimum, maximum, 1.24);
    CGFloat banded = LGSegmentRubberBandedCenterX(point.x, minimum, maximum)
                   + (drag.centerX - sharedBand);
    state.targetCenterX = MAX(minimum - allowance,
                              MIN(maximum + allowance, banded));
    state.targetWidth = drag.width;
    state.targetHeight = drag.height;
    [state start];
}

static void LGSegmentEndTracking(UISegmentedControl *control, BOOL commit) {
    LGSegmentMotionState *state = LGSegmentMotionStateFor(control, NO);
    if (!state.active) return;
    NSArray<UIView *> *segments = LGSegmentViews(control);
    if (!segments.count) { state.active = NO; return; }

    if (!state.dragged) {
        state.active = NO;
        return;
    }

    NSInteger index = LGSegmentIndexNearest(control, state.renderedCenterX);
    if (index == NSNotFound) index = control.selectedSegmentIndex;
    if (commit && index != control.selectedSegmentIndex) {
        control.selectedSegmentIndex = index;
        [control sendActionsForControlEvents:UIControlEventValueChanged];
    }

    UIView *destination = segments[(NSUInteger)MAX(0, MIN(index, (NSInteger)segments.count - 1))];
    state.active = NO;
    state.targetCenterX = CGRectGetMidX(destination.frame);
    state.targetWidth = CGRectGetWidth(destination.frame);
    state.targetHeight = LGSegmentGlassHeight(control);
    [state start];
}

@interface LGSegmentGesture : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UISegmentedControl *control;
@end

@implementation LGSegmentGesture
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)lg_handle:(UILongPressGestureRecognizer *)recognizer {
    UISegmentedControl *control = self.control;
    if (!control || !gLGSegmentControlsEnabled) return;
    CGPoint point = [recognizer locationInView:control];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            LGSegmentBeginTracking(control, point);
            break;
        case UIGestureRecognizerStateChanged:
            LGSegmentContinueTracking(control, point);
            break;
        case UIGestureRecognizerStateEnded:
            LGSegmentEndTracking(control, YES);
            break;
        default:
            LGSegmentEndTracking(control, NO);
            break;
    }
}
@end

static void LGSegmentAttachGesture(UISegmentedControl *control) {
    static void *key = &key;
    if (objc_getAssociatedObject(control, key)) return;
    LGSegmentGesture *handler = [LGSegmentGesture new];
    handler.control = control;
    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                      action:@selector(lg_handle:)];
    recognizer.minimumPressDuration = 0.0;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = handler;
    [control addGestureRecognizer:recognizer];
    objc_setAssociatedObject(control, key, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGInstallSettingsSlider(UISlider *owner) {
    if (!gLGSliderControlsEnabled || !owner.window ||
        [owner isKindOfClass:LGPrefsLiquidSlider.class] ||
        LGInsideLiquidAssPrefs(owner)) return;
    if (!LGSliderUsesStockArtwork(owner)) {
        LGRemoveSettingsSliderOverlay(owner);
        return;
    }
    for (UIView *candidate = owner; candidate; candidate = candidate.superview) {
        if (LGViewTreeHasSpeechRateEndpoints(candidate)) return;
        if ([candidate isKindOfClass:UITableViewCell.class]) break;
    }

    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    if (!overlay) {
        overlay = [[LGPrefsLiquidSlider alloc] initWithFrame:CGRectZero];
        __weak UISlider *weakOwner = owner;
        [overlay addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UISlider *strongOwner = weakOwner;
            LGPrefsLiquidSlider *sender = (LGPrefsLiquidSlider *)action.sender;
            if (!strongOwner) return;
            [strongOwner setValue:sender.value animated:NO];
            [strongOwner sendActionsForControlEvents:UIControlEventValueChanged];
        }] forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(owner, kLGSettingsSliderOverlayKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *container = LGSettingsSliderOverlayContainer(owner);
    if (overlay.superview != container) {
        [overlay removeFromSuperview];
        [container addSubview:overlay];
    }
    CGRect overlayFrame = LGSettingsSliderOverlayFrame(owner, container);
    if (!CGRectEqualToRect(overlay.frame, overlayFrame)) overlay.frame = overlayFrame;
    if (fabsf(overlay.minimumValue - owner.minimumValue) > FLT_EPSILON)
        overlay.minimumValue = owner.minimumValue;
    if (fabsf(overlay.maximumValue - owner.maximumValue) > FLT_EPSILON)
        overlay.maximumValue = owner.maximumValue;
    if (overlay.enabled != owner.enabled) overlay.enabled = owner.enabled;

    id specifier = nil;
    for (UIView *candidate = owner; candidate && !specifier;
         candidate = candidate.superview) {
        @try {
            if ([candidate respondsToSelector:NSSelectorFromString(@"specifier")])
                specifier = [candidate valueForKey:@"specifier"];
        } @catch (__unused NSException *exception) {}
    }
    BOOL segmented = NO;
    NSInteger segmentCount = 0;
    if (specifier) {
        @try {
            segmented = [[specifier propertyForKey:@"isSegmented"] boolValue] ||
                        [[specifier propertyForKey:@"locksToSegment"] boolValue] ||
                        [[specifier propertyForKey:@"snapsToSegment"] boolValue];
            segmentCount = [[specifier propertyForKey:@"segmentCount"] integerValue];
        } @catch (__unused NSException *exception) {}
    }
    float range = owner.maximumValue - owner.minimumValue;
    float roundedRange = roundf(range);
    if (segmented && segmentCount <= 0 &&
        fabsf(range - roundedRange) <= 0.001f &&
        roundedRange >= 1.0f && roundedRange <= 24.0f)
        segmentCount = (NSInteger)roundedRange;
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentedKey, @(segmented),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey,
                             @(segmentCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *minimumTint = segmented ? UIColor.clearColor :
        (owner.minimumTrackTintColor ?: owner.tintColor ?: UIColor.systemBlueColor);
    UIColor *maximumTint = segmented ? UIColor.clearColor : owner.maximumTrackTintColor;
    if (![overlay.minimumTrackTintColor isEqual:minimumTint])
        overlay.minimumTrackTintColor = minimumTint;
    if ((overlay.maximumTrackTintColor || maximumTint) &&
        ![overlay.maximumTrackTintColor isEqual:maximumTint])
        overlay.maximumTrackTintColor = maximumTint;

    CGRect track = [owner trackRectForBounds:owner.bounds];
    CGRect minThumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                          value:owner.minimumValue];
    CGRect maxThumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                          value:owner.maximumValue];
    CGPoint minimumCenter = [owner convertPoint:
        CGPointMake(CGRectGetMidX(minThumb), CGRectGetMidY(minThumb)) toView:container];
    CGPoint maximumCenter = [owner convertPoint:
        CGPointMake(CGRectGetMidX(maxThumb), CGRectGetMidY(maxThumb)) toView:container];
    minimumCenter = [overlay convertPoint:minimumCenter fromView:container];
    maximumCenter = [overlay convertPoint:maximumCenter fromView:container];
    NSArray *endpoints = @[ @(minimumCenter.x), @(maximumCenter.x) ];
    objc_setAssociatedObject(overlay, kLGPrefsSliderEndpointCentersKey, endpoints,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (segmented && segmentCount > 0) {
        NSMutableArray *centers = [NSMutableArray arrayWithCapacity:segmentCount + 1];
        for (NSInteger index = 0; index <= segmentCount; index++) {
            float value = owner.minimumValue +
                ((float)index / (float)segmentCount) * range;
            CGRect thumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                               value:value];
            CGPoint center = [owner convertPoint:
                CGPointMake(CGRectGetMidX(thumb), CGRectGetMidY(thumb)) toView:container];
            center = [overlay convertPoint:center fromView:container];
            [centers addObject:@(center.x)];
        }
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, centers,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (fabsf(overlay.value - owner.value) > FLT_EPSILON)
        [overlay setValue:owner.value animated:NO];
    LGSuppressNativeSliderContents(owner, overlay);
    [container bringSubviewToFront:overlay];
}

static UIView *LGDescendantNamed(UIView *root, NSString *name) {
    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:name]) return subview;
        UIView *found = LGDescendantNamed(subview, name);
        if (found) return found;
    }
    return nil;
}

static void LGUpdateSettingsBackButton(UINavigationBar *bar) {
    if (!bar.window) return;
    BOOL insideLiquidAssPrefs = LGInsideLiquidAssPrefs(bar);
    UIView *content = nil;
    for (UIView *subview in bar.subviews)
        if ([NSStringFromClass(subview.class) isEqualToString:@"_UINavigationBarContentView"]) {
            content = subview;
            break;
        }
    if (!content) return;
    LGSettingsBackButton *installed =
        objc_getAssociatedObject(content, kLGSettingsBackButtonKey);
    if (!gLGSettingsControlsEnabled) {
        UIView *stock = installed.stockButton;
        NSDictionary *original = stock
            ? objc_getAssociatedObject(stock, kLGSettingsStockBackStateKey)
            : nil;
        if (stock && original) {
            stock.hidden = [original[@"hidden"] boolValue];
            stock.alpha = [original[@"alpha"] doubleValue];
            stock.userInteractionEnabled = [original[@"interaction"] boolValue];
            objc_setAssociatedObject(stock, kLGSettingsStockBackStateKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        [installed removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    UINavigationController *navigation = nil;
    for (UIResponder *r = bar; r; r = r.nextResponder)
        if ([r isKindOfClass:UINavigationController.class]) {
            navigation = (UINavigationController *)r;
            break;
        }
    if (!navigation || navigation.viewControllers.count <= 1 || !bar.backItem) {
        [objc_getAssociatedObject(content, kLGSettingsBackButtonKey) removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *navigationClass = NSStringFromClass(navigation.class);
    if (insideLiquidAssPrefs || LGControllerContainsLiquidAssPrefs(navigation) ||
        [[NSBundle bundleForClass:navigation.class].bundleIdentifier
            isEqualToString:@"dylv.liquidassprefs"] ||
        [navigationClass hasPrefix:@"LG"]) {
        [objc_getAssociatedObject(content, kLGSettingsBackButtonKey) removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIView *stock = nil;
    for (UIView *candidate in content.subviews)
        if ([NSStringFromClass(candidate.class) isEqualToString:@"_UIButtonBarButton"] &&
            LGDescendantNamed(candidate, @"_UIBackButtonMaskView")) {
            stock = candidate;
            break;
        }
    if (!stock) return;
    LGSettingsBackButton *button =
        objc_getAssociatedObject(content, kLGSettingsBackButtonKey);
    if (!button) {
        button = [[LGSettingsBackButton alloc] initWithFrame:CGRectMake(16, 0, 44, 44)];
        [content addSubview:button];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.navigationController = navigation;
    button.stockButton = stock;
    if (!objc_getAssociatedObject(stock, kLGSettingsStockBackStateKey)) {
        objc_setAssociatedObject(
            stock, kLGSettingsStockBackStateKey,
            @{@"hidden": @(stock.hidden),
              @"alpha": @(stock.alpha),
              @"interaction": @(stock.userInteractionEnabled)},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat leading = MAX(16.0, bar.safeAreaInsets.left + 8.0);
    CGFloat y = floor(CGRectGetMidY(content.bounds) - 22.0);
    button.frame = CGRectMake(floor(leading), y, 44.0, 44.0);
    stock.hidden = YES;
    stock.alpha = 0.0;
    stock.userInteractionEnabled = NO;
    [content bringSubviewToFront:button];
}

static BOOL LGViewTreeHasSpeechRateEndpoints(UIView *root) {
    NSInteger matches = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        if ([label isEqualToString:@"increase speed"] ||
            [label isEqualToString:@"decrease speed"]) {
            matches++;
            if (matches >= 2) return YES;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return NO;
}

static void LGProfiledInstallSettingsSwitch(UISwitch *owner) {
    if (!gLGControlsDiagnosticsEnabled) {
        LGInstallSettingsSwitch(owner);
        return;
    }
    BOOL existed = objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
    CFTimeInterval started = CACurrentMediaTime();
    LGInstallSettingsSwitch(owner);
    BOOL created = !existed && objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
    LGRecordControlsDiagnostic(LGControlsDiagnosticSwitch, started, created);
    if (created)
        LGLog(@"[GlobalControlsCreate] switch owner=%s super=%s frame=%s",
                   NSStringFromClass(owner.class).UTF8String,
                   NSStringFromClass(owner.superview.class).UTF8String,
                   NSStringFromCGRect(owner.frame).UTF8String);
}

static void LGProfiledInstallSettingsSlider(UISlider *owner) {
    if (!gLGControlsDiagnosticsEnabled) {
        LGInstallSettingsSlider(owner);
        return;
    }
    BOOL existed = objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey) != nil;
    CFTimeInterval started = CACurrentMediaTime();
    LGInstallSettingsSlider(owner);
    LGPrefsLiquidSlider *overlay = objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    BOOL created = !existed && overlay != nil;
    LGRecordControlsDiagnostic(LGControlsDiagnosticSlider, started, created);
    if (created)
        LGLog(@"[GlobalControlsCreate] slider owner=%s visual=%s super=%s frame=%s segmented=%d count=%ld",
                   NSStringFromClass(owner.class).UTF8String,
                   NSStringFromClass(((UIView *)objc_getAssociatedObject(owner, kLGSettingsSliderVisualHostKey)).class).UTF8String,
                   NSStringFromClass(owner.superview.class).UTF8String,
                   NSStringFromCGRect(owner.frame).UTF8String,
                   [objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentedKey) boolValue],
                   (long)[objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey) integerValue]);
}

static void LGProfiledLayoutSettingsSlider(UISlider *owner) {
    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    if (!overlay) {
        LGProfiledInstallSettingsSlider(owner);
        return;
    }
    CFTimeInterval started = gLGControlsDiagnosticsEnabled ? CACurrentMediaTime() : 0.0;

    if (gLGControlsDiagnosticsEnabled)
        LGRecordControlsDiagnostic(LGControlsDiagnosticSlider, started, NO);
}

static BOOL LGSettingsShouldModifyCell(UIView *cell) {
    Class segmentCell = NSClassFromString(@"PSSegmentTableCell");
    Class sliderCell = NSClassFromString(@"PSSliderTableCell");
    return !(segmentCell && [cell isKindOfClass:segmentCell]) &&
           !(sliderCell && [cell isKindOfClass:sliderCell]);
}

static void LGUpdateSettingsCell(UITableViewCell *cell) {
    if (!gLGSettingsControlsEnabled) return;
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    cell.separatorInset = inset;
    cell.layoutMargins = inset;
    cell.preservesSuperviewLayoutMargins = NO;
    if (!LGSettingsShouldModifyCell(cell)) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (fabs(view.layer.cornerRadius - 10.0) <= 0.25 &&
            CGRectGetHeight(view.bounds) > 0.0)
            view.layer.cornerRadius = 27.0;
        [stack addObjectsFromArray:view.subviews];
    }
}

%group LiquidAssGlobalControls

static UISwitch *LGSettingsOwnerForModernSwitchElement(UIView *element) {
    for (UIView *candidate = element.superview; candidate;
         candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISwitch.class])
            return (UISwitch *)candidate;
    }
    return nil;
}

static BOOL LGSettingsShouldSuppressModernSwitchElement(UIView *element) {
    UISwitch *owner = LGSettingsOwnerForModernSwitchElement(element);
    if (!owner || !gLGSwitchControlsEnabled) return NO;
    return [owner isKindOfClass:LGPrefsLiquidSwitch.class] ||
        objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
}

static void LGSettingsSuppressModernSwitchElementIfNeeded(UIView *element) {
    if (LGSettingsShouldSuppressModernSwitchElement(element) && element.alpha != 0.0)
        element.alpha = 0.0;
}


#pragma mark - iPad floating sidebar

static const CGFloat kLGSidebarInset = 12.0;
static const CGFloat kLGSearchBarHeightScale = 1.25;
static const CGFloat kLGSearchFieldHeightScale = 1.30;
static const CGFloat kLGSearchFieldIconInset = 8.0;
static const CGFloat kLGSearchBarWidthScale = 0.9635;
static const CGFloat kLGSidebarCornerRadiusFallback = 24.0;
static const CGFloat kLGSidebarWidth = 340.0;
static const CGFloat kLGSettingsCellHeight = 52.0;

static CGFloat LGSidebarCornerRadius(UIView *view) {
    static CGFloat cached = -1.0;
    if (cached < 0.0) {
        cached = 0.0;
        UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
        @try {
            id value = [screen valueForKey:@"_displayCornerRadius"];
            if ([value respondsToSelector:@selector(doubleValue)])
                cached = [value doubleValue];
        } @catch (__unused NSException *exception) {}
    }
    return cached > 0.5 ? cached : kLGSidebarCornerRadiusFallback;
}
static const CGFloat kLGSidebarTopGap = 0.0;
static const CGFloat kLGSidebarBlurRadius = 24.0;
static const CGFloat kLGSidebarShadowOpacity = 0.12;
static const CGFloat kLGSidebarShadowRadius = 12.0;
static const CGFloat kLGSidebarShadowOffsetX = 3.0;
static void *kLGSidebarPanelKey = &kLGSidebarPanelKey;
static void *kLGSidebarLargeTitleKey = &kLGSidebarLargeTitleKey;

static void LGClearBackground(UIView *view) {
    if (!view) return;
    UIColor *clear = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.0];
    if (![view.backgroundColor isEqual:clear]) view.backgroundColor = clear;
}

static UITableView *LGSidebarTableView(UIView *transitionView, BOOL clearing) {
    if (clearing) LGClearBackground(transitionView);
    for (UIView *wrapper in transitionView.subviews) {
        if (!isExactClass(wrapper, @"UIViewControllerWrapperView")) continue;
        if (clearing) LGClearBackground(wrapper);
        for (UIView *controllerView in wrapper.subviews) {
            if (clearing) LGClearBackground(controllerView);
            for (UIView *sub in controllerView.subviews) {
                if ([sub isKindOfClass:UITableView.class]) return (UITableView *)sub;
            }
        }
    }
    return nil;
}

static BOOL LGViewIsColumnContainer(UIView *view) {
    if (!isExactClass(view, @"UILayoutContainerView")) return NO;
    for (UIView *sub in view.subviews) {
        if (isExactClass(sub, @"UINavigationTransitionView")) return YES;
    }
    return NO;
}

static BOOL LGIsSettingsSidebarContainer(UIView *view) {
    if (!LGViewIsColumnContainer(view)) return NO;
    UIView *parent = view.superview;
    if (!isExactClass(parent, @"UILayoutContainerView")) return NO;

    BOOL sawOtherColumn = NO;
    for (UIView *sibling in parent.subviews) {
        if (sibling == view || !LGViewIsColumnContainer(sibling)) continue;
        sawOtherColumn = YES;
        if (CGRectGetWidth(sibling.bounds) <= CGRectGetWidth(view.bounds)) return NO;
    }
    return sawOtherColumn;
}

static void *kLGSidebarAppliedKey = &kLGSidebarAppliedKey;


static const CGFloat kLGSidebarPressScale = 1.01;
static const CGFloat kLGSidebarGlowDiameterScale = 2.2;
static const CGFloat kLGSidebarGlowAlpha = 0.05;
static const NSInteger kLGSidebarGlowTag = 3;
static void *kLGSidebarPressHandlerKey = &kLGSidebarPressHandlerKey;

@interface LGSidebarPressHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *panel;
@end

@implementation LGSidebarPressHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)lg_handlePress:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self.panel];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            [self lg_setGlowVisible:YES at:location];
            [self lg_setPressed:YES];
            break;
        case UIGestureRecognizerStateChanged:
            [self lg_moveGlowTo:location];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self lg_setGlowVisible:NO at:location];
            [self lg_setPressed:NO];
            break;
        default:
            break;
    }
}

- (void)lg_moveGlowTo:(CGPoint)point {
    UIView *container = self.panel;
    UIView *panel = objc_getAssociatedObject(container, kLGSidebarPanelKey);
    if (!panel) return;
    UIView *host = nil;
    for (UIView *sub in panel.subviews) {
        if (sub.tag == kLGSidebarGlowTag) { host = sub; break; }
    }
    CALayer *glow = host.layer.sublayers.firstObject;
    if (![glow isKindOfClass:CAGradientLayer.class]) return;

    CGPoint centre = [host convertPoint:point fromView:container];
    CGFloat diameter = CGRectGetWidth(panel.bounds) * kLGSidebarGlowDiameterScale;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glow.frame = CGRectMake(centre.x - diameter * 0.5, centre.y - diameter * 0.5,
                            diameter, diameter);
    [CATransaction commit];
}

- (void)lg_setGlowVisible:(BOOL)visible at:(CGPoint)point {
    UIView *container = self.panel;
    UIView *panel = objc_getAssociatedObject(container, kLGSidebarPanelKey);
    if (!panel) return;
    UIView *host = nil;
    for (UIView *sub in panel.subviews) {
        if (sub.tag == kLGSidebarGlowTag) { host = sub; break; }
    }
    CAGradientLayer *glow = (CAGradientLayer *)host.layer.sublayers.firstObject;
    if (![glow isKindOfClass:CAGradientLayer.class]) return;

    if (visible) [self lg_moveGlowTo:point];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    CALayer *presentation = glow.presentationLayer;
    fade.fromValue = @(presentation ? presentation.opacity : glow.opacity);
    fade.toValue = @(visible ? 1.0 : 0.0);
    fade.duration = visible ? 0.16 : 0.34;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:
        visible ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glow.opacity = visible ? 1.0f : 0.0f;
    [CATransaction commit];
    [glow addAnimation:fade forKey:@"lgSidebarGlow"];
}

- (void)lg_setPressed:(BOOL)pressed {
    UIView *panel = self.panel;
    if (!panel) return;
    CALayer *layer = panel.layer;

    CGFloat scale = pressed ? kLGSidebarPressScale : 1.0;
    CATransform3D target = CATransform3DMakeScale(scale, scale, 1.0);

    CALayer *presentation = layer.presentationLayer;
    CATransform3D from = presentation ? presentation.sublayerTransform
                                      : layer.sublayerTransform;

    CASpringAnimation *spring =
        [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    spring.mass = pressed ? 0.7 : 0.9;
    spring.stiffness = pressed ? 420.0 : 300.0;
    spring.damping = pressed ? 26.0 : 13.0;
    spring.initialVelocity = pressed ? 0.4 : 0.0;
    spring.fromValue = [NSValue valueWithCATransform3D:from];
    spring.toValue = [NSValue valueWithCATransform3D:target];
    spring.duration = spring.settlingDuration;
    spring.removedOnCompletion = YES;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = target;
    [CATransaction commit];
    [layer addAnimation:spring forKey:@"lgSidebarPress"];
}

@end

static void LGEnsureSidebarPressGesture(UIView *container) {
    if (objc_getAssociatedObject(container, kLGSidebarPressHandlerKey)) return;
    LGSidebarPressHandler *handler = [LGSidebarPressHandler new];
    handler.panel = container;
    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                      action:@selector(lg_handlePress:)];
    gesture.minimumPressDuration = 0.0;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    gesture.delegate = handler;
    [container addGestureRecognizer:gesture];
    objc_setAssociatedObject(container, kLGSidebarPressHandlerKey, handler,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *LGEnsureSidebarPanel(UIView *container) {
    UIView *panel = objc_getAssociatedObject(container, kLGSidebarPanelKey);
    if (panel) return panel;

    panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.userInteractionEnabled = NO;
    panel.backgroundColor = UIColor.clearColor;
    panel.layer.masksToBounds = NO;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = (float)kLGSidebarShadowOpacity;
    panel.layer.shadowRadius = kLGSidebarShadowRadius;
    panel.layer.shadowOffset = CGSizeMake(kLGSidebarShadowOffsetX, 0.0);

    LGSettingsLowBlurView *blur =
        [[LGSettingsLowBlurView alloc] initWithFrame:CGRectZero];
    blur.lgBlurRadius = kLGSidebarBlurRadius;
    blur.tag = 1;
    [panel addSubview:blur];

    UIView *tint = [[UIView alloc] initWithFrame:CGRectZero];
    tint.userInteractionEnabled = NO;
    tint.backgroundColor =
        [LGSidebarTintBaseColor() colorWithAlphaComponent:kLGSidebarTintAlpha];
    tint.tag = 2;
    [panel addSubview:tint];

    UIView *glowHost = [[UIView alloc] initWithFrame:CGRectZero];
    glowHost.userInteractionEnabled = NO;
    glowHost.backgroundColor = UIColor.clearColor;
    glowHost.tag = kLGSidebarGlowTag;
    CAGradientLayer *glow = [CAGradientLayer layer];
    glow.type = kCAGradientLayerRadial;
    glow.startPoint = CGPointMake(0.5, 0.5);
    glow.endPoint = CGPointMake(1.0, 1.0);
    glow.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:kLGSidebarGlowAlpha].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:kLGSidebarGlowAlpha * 0.45].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
    ];
    glow.locations = @[ @0.0, @0.45, @1.0 ];
    glow.opacity = 0.0f;
    [glowHost.layer addSublayer:glow];
    [panel addSubview:glowHost];

    [container insertSubview:panel atIndex:0];
    objc_setAssociatedObject(container, kLGSidebarPanelKey, panel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return panel;
}

static void LGLayoutSidebarPanel(UIView *panel, CGRect frame) {
    if (!CGRectEqualToRect(panel.frame, frame)) panel.frame = frame;
    CGFloat radius = LGSidebarCornerRadius(panel);
    CGRect bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    panel.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:bounds
                                   cornerRadius:radius].CGPath;
    for (UIView *sub in panel.subviews) {
        if (!CGRectEqualToRect(sub.frame, bounds)) sub.frame = bounds;

        if (fabs(sub.layer.cornerRadius - radius) > 0.01) {
            sub.layer.cornerRadius = radius;
            if (@available(iOS 13.0, *))
                sub.layer.cornerCurve = kCACornerCurveContinuous;
        }
        if (!sub.layer.masksToBounds) sub.layer.masksToBounds = YES;
    }
}

static BOOL LGViewIsInsideSidebar(UIView *view) {
    for (UIView *node = view; node; node = node.superview) {
        if ([objc_getAssociatedObject(node, kLGSidebarAppliedKey) boolValue]) return YES;
    }
    return NO;
}

@interface LGSidebarPillView : UIView
@end
@implementation LGSidebarPillView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat radius = CGRectGetHeight(self.bounds) * 0.5;
    if (fabs(self.layer.cornerRadius - radius) > 0.01) {
        self.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *))
            self.layer.cornerCurve = kCACornerCurveContinuous;
    }
}
@end

static void *kLGSidebarLabelColorKey = &kLGSidebarLabelColorKey;

static CGFloat LGSettingsCellHeightFor(__unused UIView *cell) {
    return kLGSettingsCellHeight;
}

static void LGClearSidebarCellBackground(UITableViewCell *cell) {
    if (!gLGSettingsControlsEnabled) return;
    if (!LGViewIsInsideSidebar((UIView *)cell)) return;
    UIColor *clear = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.0];
    if (![cell.backgroundColor isEqual:clear]) cell.backgroundColor = clear;
    if (![cell.contentView.backgroundColor isEqual:clear])
        cell.contentView.backgroundColor = clear;
    if (cell.backgroundView && ![cell.backgroundView.backgroundColor isEqual:clear])
        cell.backgroundView.backgroundColor = clear;

    for (UIView *sub in cell.subviews) {
        if (![NSStringFromClass(sub.class)
                isEqualToString:@"_UITableViewCellSeparatorView"]) continue;
        if (!sub.hidden) sub.hidden = YES;
    }

    if (@available(iOS 13.0, *)) {
        if (![cell.selectedBackgroundView isKindOfClass:LGSidebarPillView.class]) {
            LGSidebarPillView *pill =
                [[LGSidebarPillView alloc] initWithFrame:cell.bounds];
            pill.backgroundColor = UIColor.systemGray5Color;
            cell.selectedBackgroundView = pill;
        }

    }

    UITableView *table = nil;
    for (UIView *node = cell.superview; node; node = node.superview) {
        if ([node isKindOfClass:UITableView.class]) { table = (UITableView *)node; break; }
    }
    NSIndexPath *indexPath = table ? [table indexPathForCell:cell] : nil;
    BOOL active = cell.selected || cell.highlighted ||
        (indexPath && [indexPath isEqual:table.indexPathForSelectedRow]);
    UIColor *labelColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.7];
    for (UIView *sub in cell.contentView.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"UITableViewLabel"]) continue;
        UILabel *label = (UILabel *)sub;
        if (active) {
            if (!objc_getAssociatedObject(label, kLGSidebarLabelColorKey)) {
                objc_setAssociatedObject(label, kLGSidebarLabelColorKey,
                                         label.textColor ?: NSNull.null,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (![label.textColor isEqual:labelColor]) label.textColor = labelColor;
            if (![label.highlightedTextColor isEqual:labelColor])
                label.highlightedTextColor = labelColor;
        } else {
            id original = objc_getAssociatedObject(label, kLGSidebarLabelColorKey);
            if (original) {
                label.textColor = original == NSNull.null ? nil : original;
                objc_setAssociatedObject(label, kLGSidebarLabelColorKey, nil,
                                         OBJC_ASSOCIATION_ASSIGN);
            }
        }
    }
}

static void LGResetSettingsSidebar(UIView *container) {
    if (![objc_getAssociatedObject(container, kLGSidebarAppliedKey) boolValue]) return;
    objc_setAssociatedObject(container, kLGSidebarAppliedKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    for (UIView *sub in container.subviews) {
        if (!isExactClass(sub, @"UINavigationTransitionView")) continue;
        sub.layer.cornerRadius = 0.0;
        sub.layer.masksToBounds = NO;
        sub.layer.borderWidth = 0.0;
        sub.frame = container.bounds;
        UITableView *table = LGSidebarTableView(sub, NO);
        if (table) {
            table.backgroundColor = nil;
            table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        }
    }
    for (UIView *sub in container.subviews) {
        if (![sub isKindOfClass:UINavigationBar.class]) continue;
        UINavigationBar *bar = (UINavigationBar *)sub;
        NSNumber *original = objc_getAssociatedObject(bar, kLGSidebarLargeTitleKey);
        if (original) {
            if (@available(iOS 11.0, *)) bar.prefersLargeTitles = original.boolValue;
            objc_setAssociatedObject(bar, kLGSidebarLargeTitleKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        for (UIView *child in sub.subviews) {
            if ([NSStringFromClass(child.class)
                    isEqualToString:@"_UINavigationBarLargeTitleView"]) child.hidden = NO;
        }
    }
    LGSidebarPressHandler *pressHandler =
        objc_getAssociatedObject(container, kLGSidebarPressHandlerKey);
    if (pressHandler) {
        for (UIGestureRecognizer *gesture in [container.gestureRecognizers copy]) {
            if (gesture.delegate == (id)pressHandler)
                [container removeGestureRecognizer:gesture];
        }
        objc_setAssociatedObject(container, kLGSidebarPressHandlerKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        [container.layer removeAnimationForKey:@"lgSidebarPress"];
        container.layer.sublayerTransform = CATransform3DIdentity;
    }
    [(UIView *)objc_getAssociatedObject(container, kLGSidebarPanelKey)
        removeFromSuperview];
    objc_setAssociatedObject(container, kLGSidebarPanelKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}


#pragma mark - sidebar probe

static void *kLGSidebarProbeKey = &kLGSidebarProbeKey;

static void LGProbeAppend(NSMutableString *out, UIView *view, NSUInteger depth,
                          NSUInteger maxDepth) {
    if (depth > maxDepth) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2
                                      withString:@" " startingAtIndex:0];
    [out appendFormat:@"\n%@%@ f=%@ hidden=%d alpha=%.2f clips=%d radius=%.1f bg=%@",
        pad, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
        view.hidden, view.alpha, view.clipsToBounds, view.layer.cornerRadius,
        view.backgroundColor ? @"set" : @"nil"];
    if ([view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)view;
        [out appendFormat:@" | contentInset=%@ contentSize=%@ header=%@%@ separator=%ld",
            NSStringFromUIEdgeInsets(table.contentInset),
            NSStringFromCGSize(table.contentSize),
            table.tableHeaderView ? NSStringFromClass(table.tableHeaderView.class) : @"(nil)",
            table.tableHeaderView ? NSStringFromCGRect(table.tableHeaderView.frame) : @"",
            (long)table.separatorStyle];
    }
    if ([view isKindOfClass:UINavigationBar.class]) {
        UINavigationBar *bar = (UINavigationBar *)view;
        BOOL prefersLarge = NO;
        id searchController = nil;
        UINavigationItemLargeTitleDisplayMode mode = 0;
        if (@available(iOS 11.0, *)) {
            prefersLarge = bar.prefersLargeTitles;
            searchController = bar.topItem.searchController;
            mode = bar.topItem.largeTitleDisplayMode;
        }
        [out appendFormat:@" | title=%@ prefersLargeTitles=%d largeTitleMode=%ld searchController=%@",
            bar.topItem.title, prefersLarge, (long)mode,
            searchController ? NSStringFromClass([searchController class]) : @"(nil)"];
    }
    for (UIView *sub in view.subviews) LGProbeAppend(out, sub, depth + 1, maxDepth);
}

static void LGProbeSidebar(UIView *container) {
    if (!LGDebugLoggingEnabled() || !container.window) return;

    NSMutableString *signature = [NSMutableString string];
    [signature appendFormat:@"%.0fx%.0f|", CGRectGetWidth(container.bounds),
                                           CGRectGetHeight(container.bounds)];
    for (UIView *child in container.subviews) {
        [signature appendFormat:@"%@(%lu)", NSStringFromClass(child.class),
                                (unsigned long)child.subviews.count];
    }
    NSString *previous = objc_getAssociatedObject(container, kLGSidebarProbeKey);
    if ([previous isEqualToString:signature]) return;
    objc_setAssociatedObject(container, kLGSidebarProbeKey, signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIWindow *window = container.window;
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"[LGSIDEBARPROBE] ios=%@ idiom=%ld window=%@ safeArea=%@ scale=%.1f",
        UIDevice.currentDevice.systemVersion,
        (long)UIDevice.currentDevice.userInterfaceIdiom,
        NSStringFromCGRect(window.bounds),
        NSStringFromUIEdgeInsets(window.safeAreaInsets),
        window.screen.scale];

    for (UIResponder *responder = container; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UISplitViewController.class]) continue;
        UISplitViewController *split = (UISplitViewController *)responder;
        [out appendFormat:@"\n  split=%@ primary=%.1f min=%.1f max=%.1f collapsed=%d displayMode=%ld",
            NSStringFromClass(split.class), split.primaryColumnWidth,
            split.minimumPrimaryColumnWidth, split.maximumPrimaryColumnWidth,
            split.collapsed, (long)split.displayMode];
        break;
    }

    [out appendFormat:@"\n  --- sidebar container ---"];
    LGProbeAppend(out, container, 1, 6);

    [out appendString:@"\n  --- search ---"];
    for (NSString *name in @[@"PSKeyboardNavigationSearchBar",
                             @"PSKeyboardNavigationSearchController",
                             @"PSSearchController",
                             @"PSSearchResultsController"]) {
        [out appendFormat:@"\n    class %@ = %@", name,
            NSClassFromString(name) ? @"present" : @"ABSENT"];
    }

    for (UIResponder *responder = container; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        NSString *controllerName = NSStringFromClass(responder.class);
        if (![controllerName hasPrefix:@"PS"]) continue;
        for (NSString *key in @[@"spotlightSearchController", @"searchController"]) {
            if (![responder respondsToSelector:NSSelectorFromString(key)]) continue;
            id value = nil;
            @try { value = [responder valueForKey:key]; }
            @catch (__unused NSException *exception) { continue; }
            [out appendFormat:@"\n    %@.%@ = %@", controllerName, key,
                value ? NSStringFromClass([value class]) : @"(nil)"];
            if ([value isKindOfClass:UISearchController.class]) {
                UISearchBar *bar = ((UISearchController *)value).searchBar;
                [out appendFormat:@" searchBar=%@ f=%@ active=%d",
                    bar ? NSStringFromClass(bar.class) : @"(nil)",
                    bar ? NSStringFromCGRect(bar.frame) : @"",
                    ((UISearchController *)value).active];
            }
        }
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger found = 0;
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:view.subviews];

        NSString *viewName = NSStringFromClass(view.class);
        BOOL isSearchBar = [view isKindOfClass:UISearchBar.class] ||
                           [viewName containsString:@"SearchBar"];
        if (!isSearchBar) continue;
        found++;

        NSMutableString *chain = [NSMutableString string];
        for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview)
            [chain appendFormat:@"%@ < ", NSStringFromClass(ancestor.class)];

        CGSize fits = CGSizeZero;
        @try { fits = [view sizeThatFits:CGSizeMake(CGRectGetWidth(window.bounds), 0.0)]; }
        @catch (__unused NSException *exception) {}

        [out appendFormat:@"\n    [%lu] %@ f=%@ bounds=%@ hidden=%d alpha=%.2f",
            (unsigned long)found, viewName, NSStringFromCGRect(view.frame),
            NSStringFromCGRect(view.bounds), view.hidden, view.alpha];
        [out appendFormat:@"\n        sizeThatFits=%@ intrinsic=%@ translatesAutoresizing=%d constraints=%lu",
            NSStringFromCGSize(fits),
            NSStringFromCGSize(view.intrinsicContentSize),
            view.translatesAutoresizingMaskIntoConstraints,
            (unsigned long)view.constraints.count];
        [out appendFormat:@"\n        under: %@", chain];
        LGProbeAppend(out, view, 4, 7);
    }
    if (!found) [out appendString:@"\n    no search bar anywhere in the window"];

    LGLog(@"%@", out);
}

static void LGUpdateSettingsSidebar(UIView *container) {
    if (!LGIsSettingsSidebarContainer(container)) {
        if (LGViewIsColumnContainer(container)) LGResetSettingsSidebar(container);
        return;
    }
    objc_setAssociatedObject(container, kLGSidebarAppliedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!container.window || !LGSettingsChromeEnabledForView(container)) return;

    UIView *page = container.superview;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIColor *pageColor = UIColor.groupTableViewBackgroundColor;
#pragma clang diagnostic pop
    if (![page.backgroundColor isEqual:pageColor]) page.backgroundColor = pageColor;

    container.clipsToBounds = NO;

    UIWindow *window = container.window;
    CGFloat safeTop = window.safeAreaInsets.top;
    CGFloat containerTop = [container convertPoint:CGPointZero toView:window].y;
    CGFloat top = MAX(kLGSidebarInset, safeTop - containerTop + kLGSidebarTopGap);

    LGProbeSidebar(container);
    LGEnsureSidebarPressGesture(container);

    for (UIView *sub in container.subviews) {
        if (![sub isKindOfClass:UINavigationBar.class]) continue;
        UINavigationBar *bar = (UINavigationBar *)sub;
        if (@available(iOS 11.0, *)) {
            if (!objc_getAssociatedObject(bar, kLGSidebarLargeTitleKey)) {
                objc_setAssociatedObject(bar, kLGSidebarLargeTitleKey,
                                         @(bar.prefersLargeTitles),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (bar.prefersLargeTitles) bar.prefersLargeTitles = NO;
            for (UINavigationItem *item in bar.items) {
                if (item.largeTitleDisplayMode != UINavigationItemLargeTitleDisplayModeNever)
                    item.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
            }
        }
        for (UIView *child in sub.subviews) {
            if (![NSStringFromClass(child.class)
                    isEqualToString:@"_UINavigationBarLargeTitleView"]) continue;
            if (!child.hidden) child.hidden = YES;
        }
    }

    CGRect bounds = container.bounds;
    CGRect inset = CGRectMake(CGRectGetMinX(bounds) + kLGSidebarInset,
                              CGRectGetMinY(bounds) + top,
                              CGRectGetWidth(bounds) - kLGSidebarInset * 2.0,
                              CGRectGetHeight(bounds) - top - kLGSidebarInset);
    for (UIView *sub in container.subviews) {
        if (!isExactClass(sub, @"UINavigationTransitionView")) continue;
        if (!CGRectEqualToRect(sub.frame, inset)) sub.frame = inset;
        CGFloat radius = LGSidebarCornerRadius(container);
        if (fabs(sub.layer.cornerRadius - radius) > 0.01) {
            sub.layer.cornerRadius = radius;
            if (@available(iOS 13.0, *))
                sub.layer.cornerCurve = kCACornerCurveContinuous;
        }
        if (!sub.layer.masksToBounds) sub.layer.masksToBounds = YES;

        UIColor *border = LGSidebarBorderColor(container);
        if (fabs(sub.layer.borderWidth - kLGSidebarBorderWidth) > 0.01)
            sub.layer.borderWidth = kLGSidebarBorderWidth;
        if (!CGColorEqualToColor(sub.layer.borderColor, border.CGColor))
            sub.layer.borderColor = border.CGColor;

        UITableView *sidebarTable = LGSidebarTableView(sub, YES);
        LGClearBackground(sidebarTable);
        if (sidebarTable.separatorStyle != UITableViewCellSeparatorStyleNone)
            sidebarTable.separatorStyle = UITableViewCellSeparatorStyleNone;
        LGLayoutSidebarPanel(LGEnsureSidebarPanel(container), inset);
    }
}


%hook UISwitchModernVisualElement
- (void)didMoveToSuperview {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchMoves++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchMoves++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchLayouts++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)setAlpha:(CGFloat)alpha {
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchAlphaSets++;
    BOOL suppress = LGSettingsShouldSuppressModernSwitchElement((UIView *)self);
    %orig(suppress ? 0.0 : alpha);
}
%end

%hook UISwitch
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSwitchMoves++;
    LGProfiledInstallSettingsSwitch((UISwitch *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSwitchLayouts++;
    LGProfiledInstallSettingsSwitch((UISwitch *)self);
}
- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    LGPrefsLiquidSwitch *overlay =
        objc_getAssociatedObject(self, kLGSettingsSwitchOverlayKey);
    if (overlay && overlay.isOn != on) [overlay setOn:on animated:animated];
}
%end

%hook _UISlideriOSVisualElement
- (void)didMoveToWindow {
    %orig;
    UISlider *owner = LGSettingsSliderOwnerForVisualElement((UIView *)self);
    if (!owner || [owner isKindOfClass:LGPrefsLiquidSlider.class]) return;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderVisualMoves++;
    objc_setAssociatedObject(owner, kLGSettingsSliderVisualHostKey, self,
                             OBJC_ASSOCIATION_ASSIGN);
    LGProfiledLayoutSettingsSlider(owner);
}
- (void)layoutSubviews {
    %orig;
    UISlider *owner = LGSettingsSliderOwnerForVisualElement((UIView *)self);
    if (!owner || [owner isKindOfClass:LGPrefsLiquidSlider.class]) return;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderVisualLayouts++;
    objc_setAssociatedObject(owner, kLGSettingsSliderVisualHostKey, self,
                             OBJC_ASSOCIATION_ASSIGN);
    LGProfiledInstallSettingsSlider(owner);
}
%end

%hook UISegmentedControl
- (void)didMoveToWindow {
    %orig;
    LGInstallSettingsSegment((UISegmentedControl *)self);
}
- (void)layoutSubviews {
    %orig;
    LGInstallSettingsSegment((UISegmentedControl *)self);
}
- (void)setSelectedSegmentIndex:(NSInteger)index {
    %orig;
    LGInstallSettingsSegment((UISegmentedControl *)self);
}
%end

%hook UISlider
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) {
        if ([self isKindOfClass:LGPrefsLiquidSlider.class]) gLGControlsSliderOverlayMoves++;
        else gLGControlsSliderOwnerMoves++;
    }
    if (![self isKindOfClass:LGPrefsLiquidSlider.class])
        LGProfiledLayoutSettingsSlider((UISlider *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) {
        if ([self isKindOfClass:LGPrefsLiquidSlider.class]) gLGControlsSliderOverlayLayouts++;
        else gLGControlsSliderOwnerLayouts++;
    }
    if (![self isKindOfClass:LGPrefsLiquidSlider.class])
        LGProfiledInstallSettingsSlider((UISlider *)self);
}
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(self, kLGSettingsSliderOverlayKey);
    if (overlay && fabsf(overlay.value - value) > FLT_EPSILON)
        [overlay setValue:value animated:animated];
}
- (void)setMinimumValue:(float)value {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMaximumValue:(float)value {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setEnabled:(BOOL)enabled {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMinimumTrackTintColor:(UIColor *)color {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMaximumTrackTintColor:(UIColor *)color {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] begin class=%s overlay=%d super=%s frame=%s",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class],
                   NSStringFromClass(((UIView *)self).superview.class).UTF8String,
                   NSStringFromCGRect(((UIView *)self).frame).UTF8String);
    return result;
}
- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderTrackingCalls++;
    return result;
}
- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] end class=%s overlay=%d value=%.4f",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class], self.value);
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] cancel class=%s overlay=%d",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class]);
}
%end

%end

%group LiquidAssPreferencesChrome

%hook UIViewControllerWrapperView
- (void)didMoveToWindow {
    %orig;
    LGUpdateSettingsTopFade((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsTopFade((UIView *)self);
}
%end

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    LGHideSettingsNavigationBarBackground((UINavigationBar *)self);
    LGUpdateSettingsBackButton((UINavigationBar *)self);
}
- (void)layoutSubviews {
    %orig;
    LGHideSettingsNavigationBarBackground((UINavigationBar *)self);
    LGUpdateSettingsBackButton((UINavigationBar *)self);
}
%end

%hook PSTableCell
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize result = %orig;
    if (gLGSettingsControlsEnabled &&
        LGSettingsShouldModifyCell((UIView *)self) &&
        result.height >= 44.0 && result.height <= 55.0)
        result.height = LGSettingsCellHeightFor((UIView *)self);
    return result;
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)target
       withHorizontalFittingPriority:(UILayoutPriority)horizontal
             verticalFittingPriority:(UILayoutPriority)vertical {
    CGSize result = %orig;
    if (gLGSettingsControlsEnabled &&
        LGSettingsShouldModifyCell((UIView *)self) &&
        result.height >= 44.0 && result.height <= 55.0)
        result.height = LGSettingsCellHeightFor((UIView *)self);
    return result;
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    LGClearSidebarCellBackground((UITableViewCell *)self);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    BOOL sidebar = gLGSettingsControlsEnabled &&
                   LGViewIsInsideSidebar((UIView *)self);
    %orig(sidebar ? NO : highlighted, animated);
    LGClearSidebarCellBackground((UITableViewCell *)self);
}
- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsCell((UITableViewCell *)self);
    LGClearSidebarCellBackground((UITableViewCell *)self);
    LGUpdateLiquidAssEntryFooter((UITableViewCell *)self);
}
%end

%hook PSSliderTableCell
- (void)layoutSubviews {
    %orig;
    if (gLGSettingsControlsEnabled)
        ((UIView *)self).layer.cornerRadius = 24.5;
}
%end


%hook UISplitViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!gLGSettingsControlsEnabled) return;

    CGFloat wanted = kLGSidebarWidth;
    if (self.minimumPrimaryColumnWidth > wanted)
        self.minimumPrimaryColumnWidth = wanted;
    if (fabs(self.maximumPrimaryColumnWidth - wanted) > 0.5)
        self.maximumPrimaryColumnWidth = wanted;
}

%end


@interface PSKeyboardNavigationSearchBar : UISearchBar
@end

%hook PSKeyboardNavigationSearchBar

- (void)setFrame:(CGRect)frame {
    if (gLGSettingsControlsEnabled && frame.size.width > 1.0 &&
        LGViewIsInsideSidebar((UIView *)self)) {
        CGFloat natural = frame.size.height;
        if (natural < 1.0) {
            natural = [self sizeThatFits:CGSizeMake(frame.size.width, 0.0)].height;
            if (natural < 1.0) natural = self.intrinsicContentSize.height;
        }
        if (natural > 1.0) frame.size.height = round(natural * kLGSearchBarHeightScale);
        CGFloat width = round(frame.size.width * kLGSearchBarWidthScale);
        frame.origin.x += round((frame.size.width - width) * 0.5);
        frame.size.width = width;
    }
    %orig(frame);
}

- (void)layoutSubviews {
    %orig;
    if (!gLGSettingsControlsEnabled || !LGViewIsInsideSidebar((UIView *)self)) return;

    if (!self.showsBookmarkButton) {
        UIImage *mic = nil;
        if (@available(iOS 13.0, *)) {
            for (NSString *name in @[@"microphone", @"mic"]) {
                mic = [UIImage systemImageNamed:name];
                if (mic) break;
            }
        }
        if (mic) {
            [self setImage:mic forSearchBarIcon:UISearchBarIconBookmark
                     state:UIControlStateNormal];
            self.showsBookmarkButton = YES;
        }
    }

    UIOffset leading = UIOffsetMake(kLGSearchFieldIconInset, 0.0);
    UIOffset trailing = UIOffsetMake(-kLGSearchFieldIconInset, 0.0);
    if (!UIOffsetEqualToOffset(
            [self positionAdjustmentForSearchBarIcon:UISearchBarIconSearch], leading)) {
        [self setPositionAdjustment:leading forSearchBarIcon:UISearchBarIconSearch];
    }
    if (self.showsBookmarkButton &&
        !UIOffsetEqualToOffset(
            [self positionAdjustmentForSearchBarIcon:UISearchBarIconBookmark], trailing)) {
        [self setPositionAdjustment:trailing forSearchBarIcon:UISearchBarIconBookmark];
    }
    if (!UIOffsetEqualToOffset(self.searchTextPositionAdjustment, leading)) {
        self.searchTextPositionAdjustment = leading;
    }

}

%end

@interface UISearchBarTextField : UITextField
@end

%hook UISearchBarTextField

- (void)setFrame:(CGRect)frame {
    if (gLGSettingsControlsEnabled && frame.size.height > 1.0 &&
        LGViewIsInsideSidebar((UIView *)self)) {
        CGFloat wanted = round(frame.size.height * kLGSearchFieldHeightScale);
        frame.origin.y -= round((wanted - frame.size.height) * 0.5);
        frame.size.height = wanted;
    }
    %orig(frame);
}

%end

@interface _UISearchBarSearchFieldBackgroundView : UIView
@end

%hook _UISearchBarSearchFieldBackgroundView

- (void)layoutSubviews {
    %orig;
    if (!gLGSettingsControlsEnabled || !LGViewIsInsideSidebar((UIView *)self)) return;
    CGFloat radius = CGRectGetHeight(self.bounds) * 0.5;
    if (radius < 0.5) return;
    if (fabs(self.layer.cornerRadius - radius) > 0.01) {
        self.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *))
            self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if (!self.layer.masksToBounds) self.layer.masksToBounds = YES;
}

%end

%hook UILayoutContainerView

- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsSidebar((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGUpdateSettingsSidebar((UIView *)self);
}

%end

%end

%ctor {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";

    if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

    LGRefreshGlobalControlEnablement();
    gLGControlsDiagnosticsEnabled = NO;
    LGLog(@"global controls ctor bundle=%s enabled=%d",
               bundleIdentifier.UTF8String, gLGSettingsControlsEnabled);
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsPerf] diagnostics enabled bundle=%s",
                   bundleIdentifier.UTF8String);

    %init(LiquidAssGlobalControls);

    if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"])
        %init(LiquidAssPreferencesChrome);

    lgObservePreferenceReload(^{
        LGRefreshGlobalControlEnablement();
        LGLog(@"global controls reload bundle=%s enabled=%d",
                   bundleIdentifier.UTF8String, gLGSettingsControlsEnabled);
    });
}
