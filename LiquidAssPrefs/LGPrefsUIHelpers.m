#import "LGPrefsUIHelpers.h"
#import "LGPrefsDataSupport.h"
#import "../Shared/LGBackButtonSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGGlassMaterialView.h"
#import "../Shared/LGGlassRenderer.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGSharedSupport.h"
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

void * const kLGDefaultValueKey = (void *)&kLGDefaultValueKey;
void * const kLGValueLabelKey = (void *)&kLGValueLabelKey;
void * const kLGDecimalsKey = (void *)&kLGDecimalsKey;
void * const kLGSliderAnimatorKey = (void *)&kLGSliderAnimatorKey;
void * const kLGSliderKey = (void *)&kLGSliderKey;
void * const kLGPreferenceKeyKey = (void *)&kLGPreferenceKeyKey;
void * const kLGMinValueKey = (void *)&kLGMinValueKey;
void * const kLGMaxValueKey = (void *)&kLGMaxValueKey;
void * const kLGControlTitleKey = (void *)&kLGControlTitleKey;
void * const kLGControlSubtitleKey = (void *)&kLGControlSubtitleKey;
void * const kLGControlledByEnabledKey = (void *)&kLGControlledByEnabledKey;

@interface LGTopFadeView : UIView
@end

@interface LGSliderResetAnimator : NSObject
@property (nonatomic, weak) UISlider *slider;
@property (nonatomic, weak) UILabel *valueLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) CGFloat startValue;
@property (nonatomic, assign) CGFloat targetValue;
@property (nonatomic, assign) NSInteger decimals;
@end

@implementation LGSliderResetAnimator

- (void)tick:(CADisplayLink *)link {
    if (!self.slider) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - self.startTime;
    CGFloat t = MIN(MAX(elapsed / 0.42, 0.0), 1.0);
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    CGFloat value = self.startValue + ((self.targetValue - self.startValue) * eased);
    self.slider.value = value;
    if (self.valueLabel) {
        self.valueLabel.text = LGFormatSliderValue(value, self.decimals);
    }
    if (t >= 1.0) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        objc_setAssociatedObject(self.slider, kLGSliderAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

@end

static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction);
static void *kLGRespringBarGlassViewKey = &kLGRespringBarGlassViewKey;
static void *kLGRespringBarBlurViewKey = &kLGRespringBarBlurViewKey;
static void *kLGRespringBarTintViewKey = &kLGRespringBarTintViewKey;
static void *kLGRespringBarBackdropViewKey = &kLGRespringBarBackdropViewKey;
static void *kLGRespringBarLiveReadyKey = &kLGRespringBarLiveReadyKey;
static void *kLGRespringBarMaterialViewKey = &kLGRespringBarMaterialViewKey;
static NSNumber *LGParseLocalizedDecimalString(NSString *rawText);
static void LGDismissOverlayPanel(UIView *overlay, UIView *panel);

static UINavigationBarAppearance *LGMakePrefsTransparentNavigationAppearance(void) {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.shadowColor = UIColor.clearColor;
    return appearance;
}

void LGApplyNavigationBarAppearance(UINavigationItem *navigationItem) {
    UINavigationBarAppearance *appearance = LGMakePrefsTransparentNavigationAppearance();
    navigationItem.standardAppearance = appearance;
    navigationItem.scrollEdgeAppearance = appearance;
    navigationItem.compactAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        navigationItem.compactScrollEdgeAppearance = appearance;
    }
}

void LGInstallScrollableStack(UIViewController *controller,
                              CGFloat topInset,
                              CGFloat stackSpacing,
                              UIScrollView *__strong *scrollViewOut,
                              UIStackView *__strong *stackViewOut) {
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:controller.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:scrollView];

    LGTopFadeView *fadeView = [[LGTopFadeView alloc] initWithFrame:CGRectZero];
    fadeView.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:fadeView];

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = stackSpacing;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:topInset],
        [stackView.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
        [stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-112.0],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [fadeView.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [fadeView.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [fadeView.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [fadeView.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.topAnchor constant:16.0],
    ]];

    if (scrollViewOut) *scrollViewOut = scrollView;
    if (stackViewOut) *stackViewOut = stackView;
}

void LGInstallBottomRespringBar(UIViewController *controller, UIView *__strong *respringBarOut) {
    UIView *respringBar = LGMakeRespringBar(controller, @selector(handleRespringPressed), @selector(handleLaterPressed));
    [controller.view addSubview:respringBar];
    UILayoutGuide *guide = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [respringBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [respringBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [respringBar.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0],
    ]];
    if (respringBarOut) *respringBarOut = respringBar;
}

void LGRefreshRespringBarGlass(UIView *respringBar) {
    if (!respringBar) return;
    LGSharedGlassView *glassView = objc_getAssociatedObject(respringBar, kLGRespringBarGlassViewKey);
    UIView *blurView = objc_getAssociatedObject(respringBar, kLGRespringBarBlurViewKey);
    UIView *tintView = objc_getAssociatedObject(respringBar, kLGRespringBarTintViewKey);
    UIColor *customTint = LGCustomTintColorForKey(@"Preferences.RespringBar.CustomTintColor");
    tintView.backgroundColor = customTint ?: [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.04];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.01];
    }];
    BOOL glassEnabled = [LGReadPreference(@"Preferences.RespringBar.Enabled", @NO) boolValue];
    BOOL liveReady = [objc_getAssociatedObject(respringBar, kLGRespringBarLiveReadyKey) boolValue];
    glassView.hidden = !glassEnabled || !liveReady;
    blurView.hidden = glassEnabled && liveReady;
    LGApplyLowBlurRadiusToView(blurView);
    if (!glassEnabled) {
        objc_setAssociatedObject(respringBar, kLGRespringBarLiveReadyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGRemoveLiveBackdropCaptureView(respringBar, kLGRespringBarBackdropViewKey);
        LGGlassMaterialView *material = objc_getAssociatedObject(respringBar, kLGRespringBarMaterialViewKey);
        [material removeFromSuperview];
        objc_setAssociatedObject(respringBar, kLGRespringBarMaterialViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!respringBar.window || respringBar.hidden || CGRectIsEmpty(respringBar.bounds)) return;

    if (LG_serverMaterialAvailable()) {
        LGGlassMaterialView *material = objc_getAssociatedObject(respringBar, kLGRespringBarMaterialViewKey);
        if (!material) {
            material = [[LGGlassMaterialView alloc] initWithFrame:respringBar.bounds];
            material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            material.blur = glassView.blur;
            [respringBar insertSubview:material atIndex:0];
            objc_setAssociatedObject(respringBar, kLGRespringBarMaterialViewKey, material, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LGRemoveLiveBackdropCaptureView(respringBar, kLGRespringBarBackdropViewKey);
        }
        material.frame = respringBar.bounds;
        material.cornerRadius = glassView.cornerRadius;
        glassView.hidden = YES;
        blurView.hidden = YES;
        return;
    }

    CGPoint captureOrigin = CGPointZero;
    CGSize samplingResolution = CGSizeZero;
    if (LGCaptureLiveBackdropTextureForHost(respringBar,
                                            glassView,
                                            kLGRespringBarBackdropViewKey,
                                            &captureOrigin,
                                            &samplingResolution)) {
        objc_setAssociatedObject(respringBar, kLGRespringBarLiveReadyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.hidden = NO;
        blurView.hidden = YES;
        glassView.wallpaperOrigin = captureOrigin;
        glassView.wallpaperSamplingResolution = samplingResolution;
        [glassView updateOrigin];
        [glassView scheduleDraw];
    }
}

void LGScheduleRespringBarGlassRefresh(UIView *respringBar) {
    if (!respringBar) return;
    LGRefreshRespringBarGlass(respringBar);
    dispatch_async(dispatch_get_main_queue(), ^{
        LGRefreshRespringBarGlass(respringBar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGRefreshRespringBarGlass(respringBar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGRefreshRespringBarGlass(respringBar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGRefreshRespringBarGlass(respringBar);
    });
}

void LGPresentSliderValuePrompt(UIViewController *controller, UILabel *valueLabel) {
    if (![valueLabel isKindOfClass:[UILabel class]]) return;

    UISlider *slider = objc_getAssociatedObject(valueLabel, kLGSliderKey);
    NSString *preferenceKey = objc_getAssociatedObject(valueLabel, kLGPreferenceKeyKey);
    NSNumber *minNumber = objc_getAssociatedObject(valueLabel, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(valueLabel, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(valueLabel, kLGDecimalsKey);
    NSString *controlTitle = objc_getAssociatedObject(valueLabel, kLGControlTitleKey);
    if (!slider || !preferenceKey.length || !minNumber || !maxNumber || !decimalsNumber) return;

    NSInteger decimals = decimalsNumber.integerValue;
    CGFloat minValue = minNumber.doubleValue;
    CGFloat maxValue = maxNumber.doubleValue;
    NSString *message = [NSString stringWithFormat:LGLocalized(@"prefs.value_prompt.message"),
                         LGFormatSliderValue(minValue, decimals),
                         LGFormatSliderValue(maxValue, decimals)];

    LGPresentTextInputSheet(controller,
                            (controlTitle.length ? controlTitle : LGLocalized(@"prefs.value_prompt.title")),
                            message,
                            LGFormatSliderValue(slider.value, decimals),
                            LGFormatSliderValue(slider.value, decimals),
                            UIKeyboardTypeDecimalPad,
                            NO,
                            ^(NSString *text) {
        NSNumber *parsedNumber = LGParseLocalizedDecimalString(text ?: @"");
        if (!parsedNumber) return;

        CGFloat rawValue = parsedNumber.doubleValue;
        CGFloat sliderValue = MIN(MAX(rawValue, minValue), maxValue);
        slider.value = sliderValue;
        valueLabel.text = LGFormatSliderValue(rawValue, decimals);
        LGWritePreference(preferenceKey, @(rawValue));
    });
}

void LGAnimateSliderToDefault(UISlider *slider, CGFloat targetValue, UILabel *valueLabel, NSInteger decimals) {
    LGSliderResetAnimator *existing = objc_getAssociatedObject(slider, kLGSliderAnimatorKey);
    if (existing.displayLink) {
        [existing.displayLink invalidate];
        existing.displayLink = nil;
    }

    LGSliderResetAnimator *animator = [LGSliderResetAnimator new];
    animator.slider = slider;
    animator.valueLabel = valueLabel;
    animator.startValue = slider.value;
    animator.targetValue = targetValue;
    animator.decimals = decimals;
    animator.startTime = CACurrentMediaTime();
    animator.displayLink = [CADisplayLink displayLinkWithTarget:animator selector:@selector(tick:)];
    [animator.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(slider, kLGSliderAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:20.0],
        [container.heightAnchor constraintEqualToConstant:20.0],
    ]];

    if ([symbolName isEqualToString:@"lg.lockscreen.stacked"]) {
        UIImageSymbolConfiguration *phoneConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *phoneGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone" withConfiguration:phoneConfig]];
        phoneGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        phoneGlyph.tintColor = tintColor;
        phoneGlyph.contentMode = UIViewContentModeScaleAspectFit;

        UIView *lockBadge = [[UIView alloc] initWithFrame:CGRectZero];
        lockBadge.translatesAutoresizingMaskIntoConstraints = NO;
        lockBadge.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        lockBadge.layer.cornerRadius = 7.0;
        lockBadge.layer.cornerCurve = kCACornerCurveContinuous;

        UIImageSymbolConfiguration *lockConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:8.0 weight:UIImageSymbolWeightBold];
        UIImageView *lockGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill" withConfiguration:lockConfig]];
        lockGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        lockGlyph.tintColor = tintColor;
        lockGlyph.contentMode = UIViewContentModeScaleAspectFit;

        [container addSubview:phoneGlyph];
        [container addSubview:lockBadge];
        [lockBadge addSubview:lockGlyph];
        [NSLayoutConstraint activateConstraints:@[
            [phoneGlyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor constant:-1.0],
            [phoneGlyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [phoneGlyph.widthAnchor constraintEqualToConstant:15.0],
            [phoneGlyph.heightAnchor constraintEqualToConstant:15.0],
            [lockBadge.widthAnchor constraintEqualToConstant:14.0],
            [lockBadge.heightAnchor constraintEqualToConstant:14.0],
            [lockBadge.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [lockBadge.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [lockGlyph.centerXAnchor constraintEqualToAnchor:lockBadge.centerXAnchor],
            [lockGlyph.centerYAnchor constraintEqualToAnchor:lockBadge.centerYAnchor],
        ]];
        return container;
    }

    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:symbolConfig]];
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    glyph.tintColor = tintColor;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    [container addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [glyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];
    return container;
}

UIColor *LGSubpageCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.07];
        }
        return [[UIColor whiteColor] colorWithAlphaComponent:0.76];
    }];
}

UIView *LGMakeSectionDivider(void) {
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.08];
    }];
    divider.layer.cornerRadius = 0.5;
    [NSLayoutConstraint activateConstraints:@[
        [divider.heightAnchor constraintEqualToConstant:1.0]
    ]];
    return divider;
}

UIBarButtonItem *LGMakeCircularBackItem(id target, SEL action) {
    LGSharedBackButtonView *container = [[LGSharedBackButtonView alloc] initWithTarget:target action:action];
    return [[UIBarButtonItem alloc] initWithCustomView:container];
}

UIBarButtonItem *LGMakeCircularResetItem(id target, SEL action) {
    LGSharedBackButtonView *container = [[LGSharedBackButtonView alloc] initWithTarget:target
                                                                                action:action
                                                                            symbolName:@"arrow.counterclockwise"];
    container.accessibilityLabel = LGLocalized(@"prefs.button.reset");
    return [[UIBarButtonItem alloc] initWithCustomView:container];
}

void LGRefreshCircularBackItem(UIBarButtonItem *item) {
    UIView *customView = item.customView;
    if ([customView isKindOfClass:[LGSharedBackButtonView class]]) {
        [(LGSharedBackButtonView *)customView setGlassEnabled:LGReadPreference(@"Preferences.BackButton.Enabled", @NO).boolValue];
        [(LGSharedBackButtonView *)customView refreshBackdropAfterScreenUpdates:NO];
    }
}

@implementation LGTopFadeView {
    UIView *_blurView;
    CAGradientLayer *_blurMaskLayer;
    CAGradientLayer *_tintLayer;
}

- (void)lg_updateGradientColors {
    UIColor *maskColor = UIColor.blackColor;
    _blurMaskLayer.colors = @[
        (__bridge id)[maskColor colorWithAlphaComponent:1.0].CGColor,
        (__bridge id)[maskColor colorWithAlphaComponent:0.96].CGColor,
        (__bridge id)[maskColor colorWithAlphaComponent:0.78].CGColor,
        (__bridge id)[maskColor colorWithAlphaComponent:0.34].CGColor,
        (__bridge id)[maskColor colorWithAlphaComponent:0.10].CGColor,
        (__bridge id)[maskColor colorWithAlphaComponent:0.0].CGColor
    ];
    _blurMaskLayer.locations = @[ @0.0, @0.34, @0.62, @0.82, @0.94, @1.0 ];

    UIColor *baseColor = [UIColor systemBackgroundColor];
    _tintLayer.colors = @[
        (__bridge id)[baseColor colorWithAlphaComponent:0.86].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.74].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.42].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.14].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.0].CGColor
    ];
    _tintLayer.locations = @[ @0.0, @0.36, @0.68, @0.90, @1.0 ];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _blurView = LGMakeLowBlurFallbackView();
    _blurView.userInteractionEnabled = NO;
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blurView];
    LGApplyLowBlurRadiusToView(_blurView);

    _blurMaskLayer = [CAGradientLayer layer];
    _blurMaskLayer.startPoint = CGPointMake(0.5, 0.0);
    _blurMaskLayer.endPoint = CGPointMake(0.5, 1.0);
    _blurView.layer.mask = _blurMaskLayer;

    _tintLayer = [CAGradientLayer layer];
    _tintLayer.startPoint = CGPointMake(0.5, 0.0);
    _tintLayer.endPoint = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:_tintLayer];
    [self lg_updateGradientColors];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _blurView.frame = self.bounds;
    _blurMaskLayer.frame = self.bounds;
    _tintLayer.frame = self.bounds;
    LGApplyLowBlurRadiusToView(_blurView);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self lg_updateGradientColors];
        }
    } else {
        [self lg_updateGradientColors];
    }
}

@end

static NSNumber *LGParseLocalizedDecimalString(NSString *rawText) {
    NSString *trimmed = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return nil;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [NSLocale currentLocale];
    NSNumber *parsedNumber = [formatter numberFromString:trimmed];
    if (parsedNumber) return parsedNumber;

    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    return @([normalized doubleValue]);
}

static void LGDismissOverlayPanel(UIView *overlay, UIView *panel) {
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 0.0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

void LGPresentResetConfirmation(UIViewController *controller) {
    LGPresentResetConfirmationWithBody(controller, LGLocalized(@"prefs.reset_confirm.body"), NSSelectorFromString(@"performAnimatedPreferenceReset"));
}

void LGPresentResetConfirmationWithBody(UIViewController *controller, NSString *body, SEL resetSelector) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACE];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACE;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reset_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = body.length ? body : LGLocalized(@"prefs.reset_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor systemBlueColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [resetButton setTitle:LGLocalized(@"prefs.button.reset") forState:UIControlStateNormal];
    [resetButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    resetButton.backgroundColor = [UIColor tertiarySystemFillColor];
    resetButton.layer.cornerRadius = 23.0;
    resetButton.layer.cornerCurve = kCACornerCurveContinuous;
    resetButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, resetButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [resetButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [resetButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
        if (resetSelector && [controller respondsToSelector:resetSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, resetSelector);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LGResetAllPreferences();
            });
        }
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentRespringConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACF];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACF;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.respring_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    respringButton.translatesAutoresizingMaskIntoConstraints = NO;
    [respringButton setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [respringButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    respringButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    respringButton.backgroundColor = [UIColor systemBlueColor];
    respringButton.layer.cornerRadius = 23.0;
    respringButton.layer.cornerCurve = kCACornerCurveContinuous;
    respringButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, respringButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [respringButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [respringButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGSetNeedsRespring(NO);
        notify_post(LGPrefsRespringNotificationCString);
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentInvalidateCachesConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD0];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD0;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.invalidate_caches_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.invalidate_caches_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor tertiarySystemFillColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *invalidateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    invalidateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [invalidateButton setTitle:LGLocalized(@"prefs.button.invalidate") forState:UIControlStateNormal];
    [invalidateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    invalidateButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    invalidateButton.backgroundColor = [UIColor systemBlueColor];
    invalidateButton.layer.cornerRadius = 23.0;
    invalidateButton.layer.cornerCurve = kCACornerCurveContinuous;
    invalidateButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, invalidateButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [invalidateButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [invalidateButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGPostInvalidateSnapshotCachesNotification();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentReopenSettingsConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD2];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD2;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reopen_settings.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.reopen_settings.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *reopenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    reopenButton.translatesAutoresizingMaskIntoConstraints = NO;
    [reopenButton setTitle:LGLocalized(@"prefs.button.reopen_settings") forState:UIControlStateNormal];
    [reopenButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reopenButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    reopenButton.backgroundColor = [UIColor systemBlueColor];
    reopenButton.layer.cornerRadius = 23.0;
    reopenButton.layer.cornerCurve = kCACornerCurveContinuous;
    reopenButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, reopenButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [reopenButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [reopenButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LGForceSynchronizePreferences();
            exit(0);
        });
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD3];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD3;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : LGLocalized(@"prefs.info.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *okButton = [UIButton buttonWithType:UIButtonTypeSystem];
    okButton.translatesAutoresizingMaskIntoConstraints = NO;
    [okButton setTitle:LGLocalized(@"prefs.button.ok") forState:UIControlStateNormal];
    [okButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    okButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    okButton.backgroundColor = [UIColor systemBlueColor];
    okButton.layer.cornerRadius = 23.0;
    okButton.layer.cornerCurve = kCACornerCurveContinuous;
    okButton.layer.masksToBounds = YES;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:okButton];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [okButton.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [okButton.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [okButton.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [okButton.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [okButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [okButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentConfirmationSheet(UIViewController *controller,
                                NSString *title,
                                NSString *message,
                                NSString *cancelTitle,
                                NSString *confirmTitle,
                                BOOL destructive,
                                void (^confirmBlock)(void)) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD5];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD5;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : @"";
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:(cancelTitle.length ? cancelTitle : LGLocalized(@"prefs.button.cancel")) forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor tertiarySystemFillColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [confirmButton setTitle:(confirmTitle.length ? confirmTitle : LGLocalized(@"prefs.button.ok")) forState:UIControlStateNormal];
    [confirmButton setTitleColor:(destructive ? [UIColor systemRedColor] : [UIColor whiteColor]) forState:UIControlStateNormal];
    confirmButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    confirmButton.backgroundColor = destructive ? [UIColor tertiarySystemFillColor] : [UIColor systemBlueColor];
    confirmButton.layer.cornerRadius = 23.0;
    confirmButton.layer.cornerCurve = kCACornerCurveContinuous;
    confirmButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, confirmButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [confirmButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];
    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];
    [confirmButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
        if (confirmBlock) confirmBlock();
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentTextInputSheet(UIViewController *controller,
                             NSString *title,
                             NSString *message,
                             NSString *initialText,
                             NSString *placeholder,
                             UIKeyboardType keyboardType,
                             BOOL monospaced,
                             void (^applyBlock)(NSString *text)) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD6];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD6;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : @"";
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIView *textContainer = [[UIView alloc] initWithFrame:CGRectZero];
    textContainer.translatesAutoresizingMaskIntoConstraints = NO;
    textContainer.backgroundColor = [UIColor tertiarySystemFillColor];
    textContainer.layer.cornerRadius = 18.0;
    textContainer.layer.cornerCurve = kCACornerCurveContinuous;
    textContainer.layer.masksToBounds = YES;

    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.backgroundColor = UIColor.clearColor;
    textField.font = monospaced ? [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightMedium] : [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    textField.textColor = [UIColor labelColor];
    textField.text = initialText ?: @"";
    textField.placeholder = placeholder ?: @"";
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.keyboardType = keyboardType;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.smartDashesType = UITextSmartDashesTypeNo;
    textField.smartQuotesType = UITextSmartQuotesTypeNo;
    textField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    textField.spellCheckingType = UITextSpellCheckingTypeNo;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor tertiarySystemFillColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [applyButton setTitle:LGLocalized(@"prefs.button.apply") forState:UIControlStateNormal];
    [applyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    applyButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    applyButton.backgroundColor = [UIColor systemBlueColor];
    applyButton.layer.cornerRadius = 23.0;
    applyButton.layer.cornerCurve = kCACornerCurveContinuous;
    applyButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, applyButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:textContainer];
    [textContainer addSubview:textField];
    [panel.contentView addSubview:buttonRow];

    NSLayoutConstraint *panelCenterYConstraint = [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        panelCenterYConstraint,
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [textContainer.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:16.0],
        [textContainer.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [textContainer.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [textContainer.heightAnchor constraintEqualToConstant:48.0],
        [textField.topAnchor constraintEqualToAnchor:textContainer.topAnchor],
        [textField.leadingAnchor constraintEqualToAnchor:textContainer.leadingAnchor constant:14.0],
        [textField.trailingAnchor constraintEqualToAnchor:textContainer.trailingAnchor constant:-14.0],
        [textField.bottomAnchor constraintEqualToAnchor:textContainer.bottomAnchor],
        [buttonRow.topAnchor constraintEqualToAnchor:textContainer.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [applyButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    __block id keyboardWillChangeObserver = nil;
    __block id keyboardWillHideObserver = nil;
    __weak UIView *weakOverlay = overlay;
    __weak UIVisualEffectView *weakPanel = panel;
    __weak UIViewController *weakController = controller;
    __weak UITextField *weakTextField = textField;

    void (^cleanupObservers)(void) = ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        if (keyboardWillChangeObserver) {
            [center removeObserver:keyboardWillChangeObserver];
            keyboardWillChangeObserver = nil;
        }
        if (keyboardWillHideObserver) {
            [center removeObserver:keyboardWillHideObserver];
            keyboardWillHideObserver = nil;
        }
    };

    keyboardWillChangeObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        UIView *strongOverlay = weakOverlay;
        UIVisualEffectView *strongPanel = weakPanel;
        UIViewController *strongController = weakController;
        if (!strongOverlay || !strongPanel || !strongController) return;

        CGRect keyboardFrameScreen = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGRect keyboardFrame = [strongController.view convertRect:keyboardFrameScreen fromView:nil];
        NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        UIViewAnimationOptions options = (([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) & UIViewAnimationOptionCurveEaseInOut);

        [strongOverlay layoutIfNeeded];
        CGRect panelFrame = [strongPanel.superview convertRect:strongPanel.frame toView:strongController.view];
        CGFloat overlap = CGRectGetMaxY(panelFrame) - CGRectGetMinY(keyboardFrame) + 18.0;
        panelCenterYConstraint.constant = overlap > 0.0 ? -(overlap + 8.0) : 0.0;

        [UIView animateWithDuration:duration
                              delay:0.0
                            options:options | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            [strongOverlay layoutIfNeeded];
        } completion:nil];
    }];

    keyboardWillHideObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        UIView *strongOverlay = weakOverlay;
        if (!strongOverlay) return;
        NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        UIViewAnimationOptions options = (([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) & UIViewAnimationOptionCurveEaseInOut);
        panelCenterYConstraint.constant = 0.0;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:options | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            [strongOverlay layoutIfNeeded];
        } completion:nil];
    }];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextField resignFirstResponder];
        cleanupObservers();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];
    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextField resignFirstResponder];
        cleanupObservers();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];
    [applyButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextField resignFirstResponder];
        cleanupObservers();
        if (applyBlock) applyBlock(textField.text ?: @"");
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        [textField becomeFirstResponder];
    }];
}

void LGPresentMultilineTextInputSheet(UIViewController *controller,
                                      NSString *title,
                                      NSString *message,
                                      NSString *initialText,
                                      NSString *placeholder,
                                      void (^applyBlock)(NSString *text)) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD4];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD4;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : @"";
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIView *textContainer = [[UIView alloc] initWithFrame:CGRectZero];
    textContainer.translatesAutoresizingMaskIntoConstraints = NO;
    textContainer.backgroundColor = [UIColor tertiarySystemFillColor];
    textContainer.layer.cornerRadius = 20.0;
    textContainer.layer.cornerCurve = kCACornerCurveContinuous;
    textContainer.layer.masksToBounds = YES;

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.backgroundColor = UIColor.clearColor;
    textView.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    textView.textColor = [UIColor labelColor];
    textView.textContainerInset = UIEdgeInsetsMake(12.0, 10.0, 12.0, 10.0);
    textView.autocorrectionType = UITextAutocorrectionTypeNo;
    textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textView.smartDashesType = UITextSmartDashesTypeNo;
    textView.smartQuotesType = UITextSmartQuotesTypeNo;
    textView.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    textView.spellCheckingType = UITextSpellCheckingTypeNo;
    textView.keyboardType = UIKeyboardTypeASCIICapable;
    textView.text = initialText ?: @"";

    UILabel *placeholderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    placeholderLabel.text = placeholder.length ? placeholder : @"";
    placeholderLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    placeholderLabel.textColor = [UIColor tertiaryLabelColor];
    placeholderLabel.numberOfLines = 0;
    placeholderLabel.userInteractionEnabled = NO;
    placeholderLabel.hidden = textView.text.length > 0;

    [textContainer addSubview:textView];
    [textContainer addSubview:placeholderLabel];

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor tertiarySystemFillColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [applyButton setTitle:LGLocalized(@"prefs.button.apply") forState:UIControlStateNormal];
    [applyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    applyButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    applyButton.backgroundColor = [UIColor systemBlueColor];
    applyButton.layer.cornerRadius = 23.0;
    applyButton.layer.cornerCurve = kCACornerCurveContinuous;
    applyButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, applyButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:textContainer];
    [panel.contentView addSubview:buttonRow];

    NSLayoutConstraint *panelCenterYConstraint = [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        panelCenterYConstraint,
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [textContainer.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:16.0],
        [textContainer.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [textContainer.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [textContainer.heightAnchor constraintEqualToConstant:158.0],
        [textView.topAnchor constraintEqualToAnchor:textContainer.topAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:textContainer.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:textContainer.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:textContainer.bottomAnchor],
        [placeholderLabel.topAnchor constraintEqualToAnchor:textContainer.topAnchor constant:12.0],
        [placeholderLabel.leadingAnchor constraintEqualToAnchor:textContainer.leadingAnchor constant:14.0],
        [placeholderLabel.trailingAnchor constraintEqualToAnchor:textContainer.trailingAnchor constant:-14.0],
        [buttonRow.topAnchor constraintEqualToAnchor:textContainer.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [applyButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    void (^syncPlaceholder)(void) = ^{
        placeholderLabel.hidden = textView.text.length > 0;
    };
    syncPlaceholder();

    __block id textDidChangeObserver = nil;
    __block id keyboardWillChangeObserver = nil;
    __block id keyboardWillHideObserver = nil;
    __weak UIView *weakOverlay = overlay;
    __weak UIVisualEffectView *weakPanel = panel;
    __weak UIViewController *weakController = controller;
    __weak UITextView *weakTextView = textView;

    void (^cleanupObservers)(void) = ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        if (textDidChangeObserver) {
            [center removeObserver:textDidChangeObserver];
            textDidChangeObserver = nil;
        }
        if (keyboardWillChangeObserver) {
            [center removeObserver:keyboardWillChangeObserver];
            keyboardWillChangeObserver = nil;
        }
        if (keyboardWillHideObserver) {
            [center removeObserver:keyboardWillHideObserver];
            keyboardWillHideObserver = nil;
        }
    };

    textDidChangeObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UITextViewTextDidChangeNotification
                                                          object:textView
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
        syncPlaceholder();
    }];

    keyboardWillChangeObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        UIView *strongOverlay = weakOverlay;
        UIVisualEffectView *strongPanel = weakPanel;
        UIViewController *strongController = weakController;
        if (!strongOverlay || !strongPanel || !strongController) return;

        CGRect keyboardFrameScreen = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGRect keyboardFrame = [strongController.view convertRect:keyboardFrameScreen fromView:nil];
        NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        UIViewAnimationOptions options = (([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) & UIViewAnimationOptionCurveEaseInOut);

        [strongOverlay layoutIfNeeded];
        CGRect panelFrame = [strongPanel.superview convertRect:strongPanel.frame toView:strongController.view];
        CGFloat overlap = CGRectGetMaxY(panelFrame) - CGRectGetMinY(keyboardFrame) + 18.0;
        panelCenterYConstraint.constant = overlap > 0.0 ? -(overlap + 8.0) : 0.0;

        [UIView animateWithDuration:duration
                              delay:0.0
                            options:options | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            [strongOverlay layoutIfNeeded];
        } completion:nil];
    }];

    keyboardWillHideObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        UIView *strongOverlay = weakOverlay;
        if (!strongOverlay) return;
        NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        UIViewAnimationOptions options = (([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) & UIViewAnimationOptionCurveEaseInOut);
        panelCenterYConstraint.constant = 0.0;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:options | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            [strongOverlay layoutIfNeeded];
        } completion:nil];
    }];
    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextView resignFirstResponder];
        cleanupObservers();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextView resignFirstResponder];
        cleanupObservers();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [applyButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        [weakTextView resignFirstResponder];
        cleanupObservers();
        if (applyBlock) applyBlock(textView.text ?: @"");
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        [textView becomeFirstResponder];
    }];
}

static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.alpha = 0.0;
    card.hidden = YES;
    card.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    LGSharedGlassView *glassView = [[LGSharedGlassView alloc] initWithFrame:CGRectZero sourceImage:nil sourceOrigin:CGPointZero];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.userInteractionEnabled = NO;
    glassView.releasesSourceAfterUpload = NO;
    glassView.bezelWidth = 24.0;
    glassView.glassThickness = 100.0;
    glassView.refractionScale = 1.5;
    glassView.refractiveIndex = 1.5;
    glassView.specularOpacity = 0.8;
    glassView.blur = 5.0;
    glassView.sourceScale = 1.0;
    glassView.cornerRadius = 26.0;
    glassView.hidden = YES;
    [card addSubview:glassView];
    objc_setAssociatedObject(card, kLGRespringBarGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *blurView = LGMakeLowBlurFallbackView();
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.userInteractionEnabled = NO;
    [card addSubview:blurView];
    LGApplyLowBlurRadiusToView(blurView);
    objc_setAssociatedObject(card, kLGRespringBarBlurViewKey, blurView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *tintView = [[UIView alloc] initWithFrame:CGRectZero];
    tintView.translatesAutoresizingMaskIntoConstraints = NO;
    tintView.userInteractionEnabled = NO;
    UIColor *customTint = LGCustomTintColorForKey(@"Preferences.RespringBar.CustomTintColor");
    tintView.backgroundColor = customTint ?: [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.04];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.01];
    }];
    [card addSubview:tintView];
    objc_setAssociatedObject(card, kLGRespringBarTintViewKey, tintView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_bar.title");
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = LGLocalized(@"prefs.respring_bar.subtitle");
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitleLabel.numberOfLines = 2;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor systemBlueColor];
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:target action:respringAction forControlEvents:UIControlEventTouchUpInside];

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.06];
    }];
    laterButton.layer.cornerRadius = 14.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    [laterButton addTarget:target action:laterAction forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [glassView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [glassView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [glassView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [glassView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [blurView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [tintView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [tintView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [tintView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [tintView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    UIStackView *buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisVertical;
    buttonStack.spacing = 7.0;
    [buttonStack addArrangedSubview:button];
    [buttonStack addArrangedSubview:laterButton];

    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [card addSubview:buttonStack];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        [buttonStack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [buttonStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [buttonStack.widthAnchor constraintEqualToConstant:96.0],
        [button.widthAnchor constraintEqualToConstant:82.0],
        [button.heightAnchor constraintEqualToConstant:28.0],
        [laterButton.widthAnchor constraintEqualToConstant:82.0],
        [laterButton.heightAnchor constraintEqualToConstant:28.0],
    ]];
    LGRefreshRespringBarGlass(card);
    return card;
}
