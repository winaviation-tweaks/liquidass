#import "LGPrefsUIHelpers.h"
#import "LGPrefsDataSupport.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGSharedSupport.h"
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

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

static NSURL *LGTemporaryPreferencesExportURL(void) {
    NSString *filename = [NSString stringWithFormat:@"liquidass-preferences-%@.json",
                          NSUUID.UUID.UUIDString.lowercaseString];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}

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
static void *kLGRespringBarTintViewKey = &kLGRespringBarTintViewKey;
static NSNumber *LGParseLocalizedDecimalString(NSString *rawText);
static void LGDismissOverlayPanel(UIView *overlay, UIView *panel);

static void LGPerformSoftHaptic(void) {
    if (@available(iOS 13.0, *)) {
        UIImpactFeedbackGenerator *generator =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        [generator prepare];
        [generator impactOccurred];
    }
}

@interface LGLiveGlassBarButton : UIView
- (instancetype)initWithTarget:(id)target action:(SEL)action symbolName:(NSString *)symbolName;
- (void)setPrimaryMenu:(UIMenu *)menu;
- (void)refreshGlass;
@end

@implementation LGLiveGlassBarButton {
    LGLiveBackdropView *_glass;
    UIView *_tint;
    UIButton *_button;
    UIImageView *_glyph;
    UIViewPropertyAnimator *_pressAnimator;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action symbolName:(NSString *)symbolName {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, 44.0, 44.0)];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    [self.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [self.heightAnchor constraintEqualToConstant:44.0].active = YES;

    _glass = [[LGLiveBackdropView alloc] initWithFrame:self.bounds groupName:nil
                                             filterType:LGFilterTypeForHostPrefix(@"PrefsButton")];
    _glass.layer.cornerRadius = 22.0;
    _glass.layer.cornerCurve = kCACornerCurveContinuous;
    _glass.layer.masksToBounds = YES;
    [self addSubview:_glass];

    _tint = [[UIView alloc] initWithFrame:self.bounds];
    _tint.userInteractionEnabled = NO;
    _tint.layer.cornerRadius = 22.0;
    _tint.layer.cornerCurve = kCACornerCurveContinuous;
    _tint.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
        return trait.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.06] : [UIColor colorWithWhite:1.0 alpha:0.12];
    }];
    [self addSubview:_tint];

    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = self.bounds;
    [_button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [_button addTarget:self action:@selector(setPressed:) forControlEvents:UIControlEventTouchDown];
    [_button addTarget:self action:@selector(clearPressed:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addSubview:_button];

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightSemibold];
    _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:configuration]];
    _glyph.tintColor = UIColor.labelColor;
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    return self;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(44.0, 44.0); }
- (void)setPrimaryMenu:(UIMenu *)menu {
    _button.menu = menu;
    _button.showsMenuAsPrimaryAction = YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _glass.frame = self.bounds;
    _tint.frame = self.bounds;
    _button.frame = self.bounds;
    _glyph.frame = self.bounds;
    CGFloat radius = CGRectGetHeight(self.bounds) * 0.5;
    _glass.layer.cornerRadius = radius;
    _tint.layer.cornerRadius = radius;
}
- (void)lgAnimatePressed:(BOOL)pressed {
    CALayer *presentation = self.layer.presentationLayer;
    if (presentation) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.transform = CATransform3DGetAffineTransform(presentation.transform);
        [CATransaction commit];
    }
    [_pressAnimator stopAnimation:YES];

    CGFloat mass = 0.8;
    CGFloat stiffness = 300.0;
    CGFloat damping = pressed ? 18.0 : 12.0;
    CGFloat velocity = pressed ? 0.5 : 1.0;
    CGFloat duration = pressed ? 0.3 : 0.5;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass stiffness:stiffness damping:damping
     initialVelocity:CGVectorMake(velocity, velocity)];
    _pressAnimator = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:timing];
    _pressAnimator.interruptible = YES;
    __weak LGLiveGlassBarButton *weakSelf = self;
    [_pressAnimator addAnimations:^{
        LGLiveGlassBarButton *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.transform = pressed ? CGAffineTransformMakeScale(1.16, 1.16) : CGAffineTransformIdentity;
    }];
    [_pressAnimator addCompletion:^(__unused UIViewAnimatingPosition position) {
        LGLiveGlassBarButton *strongSelf = weakSelf;
        if (strongSelf) strongSelf->_pressAnimator = nil;
    }];
    [_pressAnimator startAnimation];
}
- (void)setPressed:(id)sender {
    (void)sender;
    LGPerformSoftHaptic();
    [self lgAnimatePressed:YES];
}
- (void)clearPressed:(id)sender { (void)sender; [self lgAnimatePressed:NO]; }
- (void)refreshGlass { [_glass applyFilters]; }
@end

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
    UIView *glassView = objc_getAssociatedObject(respringBar, kLGRespringBarGlassViewKey);
    UIView *tintView = objc_getAssociatedObject(respringBar, kLGRespringBarTintViewKey);
    tintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.04];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.01];
    }];
    glassView.hidden = NO;
    if ([glassView isKindOfClass:[LGLiveBackdropView class]]) {
        [(LGLiveBackdropView *)glassView applyFilters];
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

void LGPresentSliderValuePrompt(UIViewController *controller,
                                UILabel *valueLabel,
                                void (^commitBlock)(CGFloat value)) {
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
        if (commitBlock) commitBlock(sliderValue);
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
    LGLiveGlassBarButton *button = [[LGLiveGlassBarButton alloc] initWithTarget:target action:action symbolName:@"chevron.left"];
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}

UIBarButtonItem *LGMakeCircularMenuItem(id target, SEL applyAction, SEL resetAction, NSString *resetTitle) {
    __weak id weakTarget = target;
    UIAction *apply = [UIAction actionWithTitle:LGLocalized(@"prefs.button.apply")
                                           image:[UIImage systemImageNamed:@"checkmark"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        (void)action;
        id strongTarget = weakTarget;
        if (strongTarget && [strongTarget respondsToSelector:applyAction]) {
            ((void (*)(id, SEL))objc_msgSend)(strongTarget, applyAction);
        }
    }];
    UIAction *reset = [UIAction actionWithTitle:(resetTitle.length ? resetTitle : LGLocalized(@"prefs.button.reset"))
                                           image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        (void)action;
        id strongTarget = weakTarget;
        if (strongTarget && [strongTarget respondsToSelector:resetAction]) {
            ((void (*)(id, SEL))objc_msgSend)(strongTarget, resetAction);
        }
    }];
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:@[ apply, reset ]];
    LGLiveGlassBarButton *button = [[LGLiveGlassBarButton alloc]
        initWithTarget:nil action:nil symbolName:@"line.3.horizontal"];
    [button setPrimaryMenu:menu];
    button.accessibilityLabel = LGLocalized(@"prefs.button.more");
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:button];
    item.accessibilityLabel = button.accessibilityLabel;
    return item;
}

void LGRefreshCircularBackItem(UIBarButtonItem *item) {
    if ([item.customView isKindOfClass:[LGLiveGlassBarButton class]]) {
        [(LGLiveGlassBarButton *)item.customView refreshGlass];
    }
}

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
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:LGLocalized(@"prefs.reset_confirm.title")
                         message:(body.length ? body : LGLocalized(@"prefs.reset_confirm.body"))
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.reset")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
        if (resetSelector && [controller respondsToSelector:resetSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, resetSelector);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LGResetAllPreferences();
            });
        }
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

void LGPresentRespringConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:LGLocalized(@"prefs.respring_confirm.title")
                         message:LGLocalized(@"prefs.respring_confirm.body")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.later")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.respring")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        LGSetNeedsRespring(NO);
        notify_post(LGPrefsRespringNotificationCString);
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

void LGPresentReopenSettingsConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:LGLocalized(@"prefs.reopen_settings.title")
                         message:LGLocalized(@"prefs.reopen_settings.body")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.later")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.reopen_settings")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LGForceSynchronizePreferences();
            exit(0);
        });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message) {
    if (!controller.view.window) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:(title.length ? title : LGLocalized(@"prefs.info.title"))
                         message:(message.length ? message : @"")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:LGLocalized(@"prefs.button.ok")
                  style:UIAlertActionStyleDefault
                handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

void LGPresentConfirmationSheet(UIViewController *controller,
                                NSString *title,
                                NSString *message,
                                NSString *cancelTitle,
                                NSString *confirmTitle,
                                BOOL destructive,
                                void (^confirmBlock)(void)) {
    if (!controller.view.window) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:(title.length ? title : @"")
                         message:(message.length ? message : @"")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:(cancelTitle.length ? cancelTitle : LGLocalized(@"prefs.button.cancel"))
                  style:UIAlertActionStyleCancel
                handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:(confirmTitle.length ? confirmTitle : LGLocalized(@"prefs.button.ok"))
                  style:(destructive ? UIAlertActionStyleDestructive
                                     : UIAlertActionStyleDefault)
                handler:^(__unused UIAlertAction *action) {
        if (confirmBlock) confirmBlock();
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
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

    LGLiveBackdropView *glassView = [[LGLiveBackdropView alloc]
        initWithFrame:CGRectZero groupName:nil
        filterType:LGFilterTypeForHostPrefix(@"PrefsButton")];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.userInteractionEnabled = NO;
    glassView.layer.cornerRadius = 26.0;
    [card addSubview:glassView];
    objc_setAssociatedObject(card, kLGRespringBarGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *tintView = [[UIView alloc] initWithFrame:CGRectZero];
    tintView.translatesAutoresizingMaskIntoConstraints = NO;
    tintView.userInteractionEnabled = NO;
    tintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
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
UIColor *LGColorFromRGBAHex(NSString *hex) {
    NSString *value = [[hex ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (value.length != 6 && value.length != 8) return UIColor.clearColor;

    unsigned parsed = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&parsed]) return UIColor.clearColor;

    CGFloat red, green, blue, alpha;
    if (value.length == 6) {
        red = ((parsed >> 16) & 0xff) / 255.0;
        green = ((parsed >> 8) & 0xff) / 255.0;
        blue = (parsed & 0xff) / 255.0;
        alpha = 1.0;
    } else {
        red = ((parsed >> 24) & 0xff) / 255.0;
        green = ((parsed >> 16) & 0xff) / 255.0;
        blue = ((parsed >> 8) & 0xff) / 255.0;
        alpha = (parsed & 0xff) / 255.0;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

NSString *LGRGBAHexFromColor(UIColor *color) {
    CGFloat red = 1.0, green = 1.0, blue = 1.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#FFFFFF00";
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)lrint(red * 255.0), (int)lrint(green * 255.0),
            (int)lrint(blue * 255.0), (int)lrint(alpha * 255.0)];
}

UILabel *LGMakeAboutMarkdownLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.numberOfLines = 0;
    label.font = font;
    label.textColor = color;
    return label;
}

static NSString *LGLatestBundledChangelogPath(NSBundle *bundle) {
    NSString *directoryPath = [bundle pathForResource:@"changelogs" ofType:nil];
    if (!directoryPath.length) return nil;

    NSArray<NSString *> *filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:nil];
    NSMutableArray<NSString *> *markdownFilenames = [NSMutableArray array];
    for (NSString *filename in filenames) {
        if ([filename.pathExtension isEqualToString:@"md"]) [markdownFilenames addObject:filename];
    }
    if (!markdownFilenames.count) return nil;
    [markdownFilenames sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        return [[first stringByDeletingPathExtension] localizedStandardCompare:[second stringByDeletingPathExtension]];
    }];
    return [directoryPath stringByAppendingPathComponent:markdownFilenames.lastObject];
}

NSString *LGAboutChangelogMarkdownText(NSBundle *bundle, NSString *version) {
    NSString *path = version.length ? [bundle pathForResource:version ofType:@"md" inDirectory:@"changelogs"] : nil;
    if (!path.length) path = LGLatestBundledChangelogPath(bundle);
    return path.length ? ([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"") : @"";
}

void LGAppendAboutMarkdownLine(NSString *line, UIStackView *stack) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
        spacer.translatesAutoresizingMaskIntoConstraints = NO;
        [spacer.heightAnchor constraintEqualToConstant:4.0].active = YES;
        [stack addArrangedSubview:spacer];
        return;
    }

    NSUInteger headingLevel = 0;
    while (headingLevel < trimmed.length && [trimmed characterAtIndex:headingLevel] == '#') headingLevel++;
    if (headingLevel > 0 && headingLevel < trimmed.length && [trimmed characterAtIndex:headingLevel] == ' ') {
        NSString *heading = [[trimmed substringFromIndex:headingLevel + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [stack addArrangedSubview:LGMakeAboutMarkdownLabel(heading,
                                                            [UIFont systemFontOfSize:headingLevel == 1 ? 20.0 : 17.0 weight:UIFontWeightBold],
                                                            UIColor.labelColor)];
        return;
    }

    BOOL isBullet = [trimmed hasPrefix:@"- "] || [trimmed hasPrefix:@"* "];
    NSString *body = isBullet ? [trimmed substringFromIndex:2] : trimmed;
    if (!isBullet) {
        [stack addArrangedSubview:LGMakeAboutMarkdownLabel(body,
                                                            [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular],
                                                            UIColor.labelColor)];
        return;
    }

    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *bullet = LGMakeAboutMarkdownLabel(@"•", [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], UIColor.secondaryLabelColor);
    UILabel *label = LGMakeAboutMarkdownLabel(body, [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular], UIColor.labelColor);
    [row addSubview:bullet];
    [row addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [bullet.topAnchor constraintEqualToAnchor:row.topAnchor constant:1.0],
        [bullet.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [bullet.widthAnchor constraintEqualToConstant:18.0],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor],
        [label.leadingAnchor constraintEqualToAnchor:bullet.trailingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];
    [stack addArrangedSubview:row];
}

UIView *LGMakeDonationRow(UIViewController *controller,
                          NSString *name,
                          NSString *network,
                          NSString *symbol,
                          UIColor *color,
                          NSString *address) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    __weak UIViewController *weakController = controller;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        (void)action;
        if (!address.length) return;
        UIPasteboard.generalPasteboard.string = address;
        LGPresentInfoSheet(weakController, @"Copied", @"Wallet address copied to clipboard.");
    }] forControlEvents:UIControlEventTouchUpInside];

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.userInteractionEnabled = NO;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:body];

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = symbol;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = color;
    badge.layer.cornerRadius = 14.0;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;

    UILabel *nameLabel = LGMakeAboutMarkdownLabel(name, [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold], UIColor.labelColor);
    UILabel *networkLabel = LGMakeAboutMarkdownLabel(network, [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium], UIColor.secondaryLabelColor);
    UILabel *addressLabel = LGMakeAboutMarkdownLabel(address, [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular], UIColor.tertiaryLabelColor);
    addressLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    addressLabel.numberOfLines = 1;

    UIImageView *copyIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]];
    copyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    copyIcon.tintColor = UIColor.tertiaryLabelColor;
    copyIcon.contentMode = UIViewContentModeScaleAspectFit;

    UIView *titleRow = [[UIView alloc] initWithFrame:CGRectZero];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [titleRow addSubview:nameLabel];
    [titleRow addSubview:networkLabel];
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, addressLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3.0;
    [body addSubview:badge];
    [body addSubview:textStack];
    [body addSubview:copyIcon];

    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:button.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
        [badge.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [badge.centerYAnchor constraintEqualToAnchor:body.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:28.0],
        [badge.heightAnchor constraintEqualToConstant:28.0],
        [copyIcon.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [copyIcon.centerYAnchor constraintEqualToAnchor:body.centerYAnchor],
        [copyIcon.widthAnchor constraintEqualToConstant:18.0],
        [copyIcon.heightAnchor constraintEqualToConstant:18.0],
        [nameLabel.topAnchor constraintEqualToAnchor:titleRow.topAnchor],
        [nameLabel.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [nameLabel.bottomAnchor constraintEqualToAnchor:titleRow.bottomAnchor],
        [networkLabel.firstBaselineAnchor constraintEqualToAnchor:nameLabel.firstBaselineAnchor],
        [networkLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:nameLabel.trailingAnchor constant:8.0],
        [networkLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],
        [textStack.topAnchor constraintEqualToAnchor:body.topAnchor constant:10.0],
        [textStack.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12.0],
        [textStack.trailingAnchor constraintEqualToAnchor:copyIcon.leadingAnchor constant:-12.0],
        [textStack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-10.0],
    ]];
    return button;
}

UIView *LGMakeDonationCard(UIViewController *controller) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 23.25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *headerStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    headerStack.axis = UILayoutConstraintAxisVertical;
    headerStack.spacing = 3.0;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerStack];
    [headerStack addArrangedSubview:LGMakeAboutMarkdownLabel(@"Donate", [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold], UIColor.labelColor)];
    [headerStack addArrangedSubview:LGMakeAboutMarkdownLabel(@"Crypto only for now. Tap a row to copy the address.", [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium], UIColor.secondaryLabelColor)];
    [stack addArrangedSubview:header];

    NSArray<NSDictionary *> *methods = @[
        @{@"name": @"BTC", @"network": @"Bitcoin", @"symbol": @"B", @"color": UIColor.systemOrangeColor, @"address": @"bc1qlv830emqsffqslns2e3kglkgcdnlag0nfnyj4k"},
        @{@"name": @"ETH", @"network": @"Ethereum", @"symbol": @"E", @"color": UIColor.systemIndigoColor, @"address": @"0x6245EF47c749D1b5c2830b145cB943a8aD826bea"},
        @{@"name": @"LTC", @"network": @"Litecoin", @"symbol": @"L", @"color": UIColor.systemGrayColor, @"address": @"ltc1q7j6vlgvymxdtwm46u0n22h7m4890cexfp22vfm"},
        @{@"name": @"DOGE", @"network": @"Dogecoin", @"symbol": @"D", @"color": UIColor.systemYellowColor, @"address": @"D76nuR1HWSymSLhFYYhkfpc4JHg1HjvgWD"},
        @{@"name": @"SOL", @"network": @"Solana", @"symbol": @"S", @"color": UIColor.systemPurpleColor, @"address": @"F1rH3PSMHFHXbGLGQiWXGLRaahfYoVULUwhsvrewM37W"},
        @{@"name": @"TRX", @"network": @"Tron", @"symbol": @"T", @"color": UIColor.systemRedColor, @"address": @"TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX"},
        @{@"name": @"USDC", @"network": @"Polygon", @"symbol": @"U", @"color": UIColor.systemBlueColor, @"address": @"0x6245EF47c749D1b5c2830b145cB943a8aD826bea"},
        @{@"name": @"USDT", @"network": @"Tron TRC-20", @"symbol": @"U", @"color": UIColor.systemGreenColor, @"address": @"TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX"},
    ];
    for (NSUInteger index = 0; index < methods.count; index++) {
        NSDictionary *method = methods[index];
        [stack addArrangedSubview:LGMakeDonationRow(controller, method[@"name"], method[@"network"], method[@"symbol"], method[@"color"], method[@"address"])];
        if (index + 1 == methods.count) continue;
        UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
        dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
        UIView *divider = LGMakeSectionDivider();
        [dividerRow addSubview:divider];
        [NSLayoutConstraint activateConstraints:@[
            [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:54.0],
            [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
            [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
        ]];
        [stack addArrangedSubview:dividerRow];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [headerStack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16.0],
        [headerStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [headerStack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [headerStack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-13.0],
    ]];
    return card;
}

UIView *LGMakeAboutContentView(UIViewController *controller, NSBundle *bundle, NSString *packageVersion) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = UIColor.clearColor;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 7.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    UIImage *icon = [UIImage imageNamed:@"original" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) icon = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 19.0;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:82.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:82.0].active = YES;

    UILabel *nameLabel = LGMakeAboutMarkdownLabel(LGLocalized(@"prefs.app_name"), [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold], UIColor.labelColor);
    nameLabel.textAlignment = NSTextAlignmentCenter;
    UILabel *subtitleLabel = LGMakeAboutMarkdownLabel(LGLocalized(@"prefs.hero.subtitle"), [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium], UIColor.secondaryLabelColor);
    subtitleLabel.textAlignment = NSTextAlignmentCenter;

    UIView *markdownCard = [[UIView alloc] initWithFrame:CGRectZero];
    markdownCard.translatesAutoresizingMaskIntoConstraints = NO;
    markdownCard.backgroundColor = LGSubpageCardBackgroundColor();
    markdownCard.layer.cornerRadius = 23.25;
    markdownCard.layer.cornerCurve = kCACornerCurveContinuous;
    markdownCard.layer.masksToBounds = YES;
    UIStackView *markdownStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    markdownStack.axis = UILayoutConstraintAxisVertical;
    markdownStack.alignment = UIStackViewAlignmentFill;
    markdownStack.spacing = 7.0;
    markdownStack.translatesAutoresizingMaskIntoConstraints = NO;
    [markdownCard addSubview:markdownStack];

    NSString *markdownText = LGAboutChangelogMarkdownText(bundle, packageVersion);
    if (markdownText.length) {
        for (NSString *line in [markdownText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            LGAppendAboutMarkdownLine(line, markdownStack);
        }
    } else {
        [markdownStack addArrangedSubview:LGMakeAboutMarkdownLabel([NSString stringWithFormat:@"No changelog found for %@.", packageVersion], [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular], UIColor.secondaryLabelColor)];
    }

    UIView *donationCard = LGMakeDonationCard(controller);
    [stack addArrangedSubview:iconView];
    [stack addArrangedSubview:nameLabel];
    [stack addArrangedSubview:subtitleLabel];
    [stack setCustomSpacing:18.0 afterView:subtitleLabel];
    [stack addArrangedSubview:markdownCard];
    [stack setCustomSpacing:12.0 afterView:markdownCard];
    [stack addArrangedSubview:donationCard];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:18.0],
        [nameLabel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-18.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:22.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-22.0],
        [markdownCard.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [markdownCard.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [donationCard.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [donationCard.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [markdownStack.topAnchor constraintEqualToAnchor:markdownCard.topAnchor constant:16.0],
        [markdownStack.leadingAnchor constraintEqualToAnchor:markdownCard.leadingAnchor constant:16.0],
        [markdownStack.trailingAnchor constraintEqualToAnchor:markdownCard.trailingAnchor constant:-16.0],
        [markdownStack.bottomAnchor constraintEqualToAnchor:markdownCard.bottomAnchor constant:-16.0],
    ]];
    return container;
}

void LGPresentThirdPartyRWBEditor(UIViewController *controller) {
    id storedValue = LGReadPreferenceObject(@"RWB.ThirdPartyBundleIDs", LGRWBDefaultWidgetBundleIDsText());
    NSString *existing = [storedValue isKindOfClass:[NSString class]]
        ? storedValue
        : LGRWBDefaultWidgetBundleIDsText();
    LGPresentMultilineTextInputSheet(controller,
                                     LGLocalized(@"prefs.misc.rwb_third_party.title"),
                                     LGLocalized(@"prefs.misc.rwb_third_party.editor_body"),
                                     existing,
                                     LGLocalized(@"prefs.misc.rwb_third_party.placeholder"),
                                     ^(NSString *text) {
        NSMutableOrderedSet<NSString *> *lines = [NSMutableOrderedSet orderedSet];
        [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] enumerateObjectsUsingBlock:^(NSString *rawLine, NSUInteger idx, BOOL *stop) {
            (void)idx;
            (void)stop;
            NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length) [lines addObject:line];
        }];
        NSString *normalized = [lines.array componentsJoinedByString:@"\n"];

        LGWritePreferenceObject(@"RWB.ThirdPartyBundleIDs", normalized);
    });
}

static void LGPresentExclusionEditor(UIViewController *controller,
                                     NSString *key,
                                     NSString *title,
                                     NSString *body,
                                     NSString *placeholder,
                                     NSString *defaults) {
    id storedValue = LGReadPreferenceObject(key, defaults);
    NSString *existing = [storedValue isKindOfClass:NSString.class] ? storedValue : defaults;
    LGPresentMultilineTextInputSheet(controller, title, body, existing, placeholder,
                                     ^(NSString *text) {
        NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];
        NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];
        for (NSString *rawEntry in [text componentsSeparatedByCharactersInSet:separators]) {
            NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (entry.length) [entries addObject:entry];
        }
        LGWritePreferenceObject(key, [entries.array componentsJoinedByString:@"\n"]);
    });
}

void LGPresentGlobalControlsExclusionEditor(UIViewController *controller) {
    LGPresentExclusionEditor(controller, @"GlobalControls.Exclusions",
                             LGLocalized(@"prefs.global_controls.exclusions.title"),
                             LGLocalized(@"prefs.global_controls.exclusions.body"),
                             LGLocalized(@"prefs.global_controls.exclusions.placeholder"),
                             @"NewTerm\nFilza\nTikTok\nDiscord\ncom.spotify.client");
}

void LGPresentTabBarExclusionEditor(UIViewController *controller) {
    LGPresentExclusionEditor(controller, @"TabBar.Exclusions",
                             LGLocalized(@"prefs.tab_bar.exclusions.title"),
                             LGLocalized(@"prefs.tab_bar.exclusions.body"),
                             LGLocalized(@"prefs.tab_bar.exclusions.placeholder"),
                             @"TikTok\ncom.zhiliaoapp.musically");
}

void LGPresentPreferencesExport(UIViewController *controller) {
    NSString *jsonString = LGExportPreferencesJSONString();
    if (!jsonString.length) {
        LGPresentInfoSheet(controller,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    NSError *writeError = nil;
    NSURL *exportURL = LGTemporaryPreferencesExportURL();
    if (![jsonString writeToURL:exportURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        LGPresentInfoSheet(controller,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           writeError.localizedDescription ?: LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[exportURL] applicationActivities:nil];
    UIPopoverPresentationController *popover = activityController.popoverPresentationController;
    if (popover) {
        popover.sourceView = controller.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                        CGRectGetMidY(controller.view.bounds), 1.0, 1.0);
    }
    [controller presentViewController:activityController animated:YES completion:nil];
}

static NSURL *LGRawLogExportURL(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Library/Accessibility/liquidglass.log",
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"liquidglass.log"],
        @"/tmp/liquidglass.log",
    ];
    for (NSString *path in candidates) {
        if (![manager isReadableFileAtPath:path]) continue;
        NSNumber *size = [manager attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size.unsignedLongLongValue == 0) continue;

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *name = [NSString stringWithFormat:@"LiquidAss-liquidglass-%@.log",
                                                    [formatter stringFromDate:NSDate.date]];
        NSString *destination =
            [NSTemporaryDirectory() stringByAppendingPathComponent:name];
        [manager removeItemAtPath:destination error:nil];
        if ([manager copyItemAtPath:path toPath:destination error:nil])
            return [NSURL fileURLWithPath:destination];
        return [NSURL fileURLWithPath:path];
    }
    return nil;
}

void LGPresentDiagnosticsExport(UIViewController *controller) {
    NSString *directory = @"/var/mobile/Documents";
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *newestPath = nil;
    NSDate *newestDate = nil;
    for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
        if (![name hasPrefix:@"LiquidAss-Diagnostics-"] ||
            ![name.pathExtension.lowercaseString isEqualToString:@"zip"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *date = [manager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (!newestDate || [date compare:newestDate] == NSOrderedDescending) {
            newestDate = date;
            newestPath = path;
        }
    }
    NSURL *archiveURL = newestPath.length ? [NSURL fileURLWithPath:newestPath] : nil;
    NSURL *rawLogURL = LGRawLogExportURL();

    NSURL *exportURL = (!LGBackboardSafeModeActive() && rawLogURL)
        ? rawLogURL : archiveURL;
    if (!exportURL) exportURL = rawLogURL;
    if (!exportURL) {
        LGPresentInfoSheet(controller,
                           LGLocalized(@"prefs.misc.export_logs.title"),
                           LGLocalized(@"prefs.export_logs.none"));
        return;
    }

    UIActivityViewController *activityController = [[UIActivityViewController alloc]
        initWithActivityItems:@[exportURL]
        applicationActivities:nil];
    UIPopoverPresentationController *popover = activityController.popoverPresentationController;
    if (popover) {
        popover.sourceView = controller.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                        CGRectGetMidY(controller.view.bounds), 1.0, 1.0);
    }
    [controller presentViewController:activityController animated:YES completion:nil];
}

BOOL LGImportPreferencesFromURL(UIViewController *controller, NSURL *url) {
    if (!url) return NO;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSString *jsonString = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&readError];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!jsonString.length) {
        LGPresentInfoSheet(controller,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           readError.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_read"));
        return NO;
    }

    NSError *importError = nil;
    if (!LGImportPreferencesJSONString(jsonString, &importError)) {
        LGPresentInfoSheet(controller,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           importError.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_invalid"));
        return NO;
    }
    return YES;
}
