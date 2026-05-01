#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGGlassRenderer.h"
#import <QuartzCore/QuartzCore.h>

static void LGPrefsSwitchLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss][Settings] %@", message);
}

static BOOL LGSwitchIsDarkMode(UITraitCollection *traitCollection) {
    if (@available(iOS 12.0, *)) {
        return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static UIColor *LGSwitchOffTrackColor(UITraitCollection *traitCollection) {
    if (LGSwitchIsDarkMode(traitCollection)) {
        return [UIColor colorWithWhite:1.0 alpha:0.18];
    }
    return [UIColor colorWithWhite:0.20 alpha:0.10];
}

static UIColor *LGSwitchBackdropSheenColor(UITraitCollection *traitCollection) {
    if (LGSwitchIsDarkMode(traitCollection)) {
        return [UIColor colorWithWhite:1.0 alpha:0.045];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.12];
}

static UIColor *LGSwitchGlassLiftColor(UITraitCollection *traitCollection) {
    if (LGSwitchIsDarkMode(traitCollection)) {
        return [UIColor colorWithWhite:1.0 alpha:0.14];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.0];
}

static BOOL LGSwitchColorLooksTooDarkForAccent(UIColor *color) {
    if (!color) return YES;
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0.0;
        if ([color getWhite:&white alpha:&a]) {
            r = g = b = white;
        } else {
            return NO;
        }
    }
    return a > 0.01 && r < 0.12 && g < 0.12 && b < 0.12;
}

static UIColor *LGSwitchEffectiveAccentColor(UISwitch *toggle) {
    NSArray<UIColor *> *candidates = @[
        toggle.onTintColor ?: UIColor.clearColor,
        toggle.window.tintColor ?: UIColor.clearColor,
        toggle.superview.tintColor ?: UIColor.clearColor,
        toggle.tintColor ?: UIColor.clearColor,
        UIColor.systemGreenColor
    ];
    for (UIColor *candidate in candidates) {
        if (!candidate || candidate == UIColor.clearColor) continue;
        if (LGSwitchColorLooksTooDarkForAccent(candidate)) continue;
        return candidate;
    }
    return UIColor.systemGreenColor;
}

static UIImage *LGRenderSwitchBackdropImage(CGSize size,
                                            UIColor *backgroundColor,
                                            UIColor *trackColor,
                                            UIColor *fillColor,
                                            UIColor *sheenColor,
                                            UIColor *glassLiftColor,
                                            CGRect localTrackRect,
                                            CGFloat fillEndX,
                                            CGFloat magnification) {
    if (size.width <= 0.0 || size.height <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [backgroundColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    CGFloat scale = fmax(magnification, 0.1);
    CGPoint canvasCenter = CGPointMake(size.width * 0.5, size.height * 0.5);
    CGRect scaledTrackRect = CGRectMake(canvasCenter.x - (CGRectGetWidth(localTrackRect) * scale * 0.5),
                                        canvasCenter.y - (CGRectGetHeight(localTrackRect) * scale * 0.5),
                                        CGRectGetWidth(localTrackRect) * scale,
                                        CGRectGetHeight(localTrackRect) * scale);
    CGFloat scaledFillEndX = CGRectGetMinX(scaledTrackRect) + ((fillEndX - CGRectGetMinX(localTrackRect)) * scale);

    CGFloat radius = CGRectGetHeight(scaledTrackRect) * 0.5;
    UIBezierPath *trackPath = [UIBezierPath bezierPathWithRoundedRect:scaledTrackRect cornerRadius:radius];
    [trackColor setFill];
    [trackPath fill];

    CGFloat clampedFillEndX = fmax(CGRectGetMinX(scaledTrackRect), fmin(scaledFillEndX, CGRectGetMaxX(scaledTrackRect)));
    CGRect fillRect = CGRectMake(CGRectGetMinX(scaledTrackRect),
                                 CGRectGetMinY(scaledTrackRect),
                                 clampedFillEndX - CGRectGetMinX(scaledTrackRect),
                                 CGRectGetHeight(scaledTrackRect));
    if (fillRect.size.width > 0.0) {
        UIBezierPath *fillPath = [UIBezierPath bezierPathWithRoundedRect:fillRect cornerRadius:radius];
        [fillColor setFill];
        [fillPath fill];
    }

    [sheenColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, fmin(12.0, size.height * 0.35)));

    if (CGColorGetAlpha(glassLiftColor.CGColor) > 0.001) {
        UIBezierPath *liftPath = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(scaledTrackRect, -30.0, -14.0)
                                                            cornerRadius:CGRectGetHeight(scaledTrackRect) * 3.0];
        [glassLiftColor setFill];
        [liftPath fill];
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface LGSwitchInsetShadowView : UIView
@end

@implementation LGSwitchInsetShadowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.layer.compositingFilter = @"multiplyBlendMode";
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat shadowRadius = 3.5;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, -1.0, -shadowRadius * 0.5)
                                                    cornerRadius:CGRectGetHeight(self.bounds) * 0.5];
    UIBezierPath *inner = [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.0, shadowRadius * 0.55)
                                                      cornerRadius:CGRectGetHeight(self.bounds) * 0.5] bezierPathByReversingPath];
    [path appendPath:inner];
    self.layer.shadowPath = path.CGPath;
    self.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:1.0].CGColor;
    self.layer.shadowOpacity = 0.18;
    self.layer.shadowRadius = shadowRadius;
    self.layer.shadowOffset = CGSizeMake(0.0, shadowRadius * 0.75);
}

@end

@interface LGPrefsLiquidSwitch ()
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *contractedThumbView;
@property (nonatomic, strong) LGSharedGlassView *glassThumbView;
@property (nonatomic, strong) LGSwitchInsetShadowView *glassInsetShadowView;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedbackGenerator;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CGFloat renderedProgress;
@property (nonatomic, assign) CGFloat targetProgress;
@property (nonatomic, assign) CGSize renderedThumbSize;
@property (nonatomic, assign) CGSize targetThumbSize;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) BOOL dragMoved;
@property (nonatomic, assign) CGFloat renderedExpansion;
@property (nonatomic, assign) CGFloat targetExpansion;
@property (nonatomic, assign) BOOL hasRenderedState;
@property (nonatomic, assign) CGFloat renderedFillAlpha;
@property (nonatomic, assign) CGFloat targetFillAlpha;
@property (nonatomic, assign) CGFloat fillAnimationStartAlpha;
@property (nonatomic, assign) CFTimeInterval fillAnimationStartTime;
@property (nonatomic, assign) BOOL fillAnimating;
@property (nonatomic, assign) BOOL pendingTapAutoContract;
@property (nonatomic, assign) CFTimeInterval lastDisplayLinkTimestamp;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) BOOL didToggleDuringDrag;
@property (nonatomic, assign) BOOL didSendValueChangedDuringDrag;
@property (nonatomic, assign) BOOL wasOnWhenDragStarted;
@property (nonatomic, assign) CFTimeInterval touchBeganTime;
@property (nonatomic, assign) CGFloat dragStartLocation;
@property (nonatomic, assign) CGFloat dragStartThumbCenterX;
@end

@implementation LGPrefsLiquidSwitch

static CGSize LGSettingsSwitchRestThumbSize(void) {
    return CGSizeMake(36.0, 24.0);
}

static CGSize LGSettingsSwitchExpandedThumbSize(void) {
    return CGSizeMake(54.0, 34.0);
}

static void LGSettingsSwitchScheduleAutoContract(LGPrefsLiquidSwitch *self_) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self_.pressed) return;
        self_.pendingTapAutoContract = NO;
        self_.targetExpansion = 0.0;
        self_.targetThumbSize = LGSettingsSwitchRestThumbSize();
        [self_ startDisplayLinkIfNeeded];
        [self_ refreshGlassBackdrop];
        [self_ updateVisualsAnimated:YES];
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (void)dealloc {
    LGPrefsSwitchLog(@"switch dealloc self=%p displayLink=%p window=%p", self, self.displayLink, self.window);
    [self stopDisplayLink];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(63.0, 28.0);
}

- (CGSize)sizeThatFits:(CGSize)size {
    (void)size;
    return self.intrinsicContentSize;
}

- (void)commonInit {
    self.onTintColor = UIColor.clearColor;
    self.tintColor = UIColor.clearColor;
    self.thumbTintColor = UIColor.clearColor;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.renderedProgress = self.isOn ? 1.0 : 0.0;
    self.targetProgress = self.renderedProgress;
    self.renderedThumbSize = LGSettingsSwitchRestThumbSize();
    self.targetThumbSize = self.renderedThumbSize;
    self.renderedExpansion = 0.0;
    self.targetExpansion = 0.0;
    self.renderedFillAlpha = self.isOn ? 1.0 : 0.0;
    self.targetFillAlpha = self.renderedFillAlpha;
    self.feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    UIView *trackView = [[UIView alloc] initWithFrame:CGRectZero];
    trackView.userInteractionEnabled = NO;
    self.trackView = trackView;
    [self addSubview:trackView];

    UIView *fillView = [[UIView alloc] initWithFrame:CGRectZero];
    fillView.userInteractionEnabled = NO;
    self.fillView = fillView;
    [trackView addSubview:fillView];

    UIView *contractedThumbView = [[UIView alloc] initWithFrame:CGRectZero];
    contractedThumbView.userInteractionEnabled = NO;
    self.contractedThumbView = contractedThumbView;
    [self addSubview:contractedThumbView];

    LGEnsureSharedGlassPipelinesReady();
    LGSharedGlassView *glass = [[LGSharedGlassView alloc] initWithFrame:CGRectZero sourceImage:nil sourceOrigin:CGPointZero];
    glass.userInteractionEnabled = NO;
    glass.releasesSourceAfterUpload = YES;
    glass.bezelWidth = 6.0;
    glass.glassThickness = 20.0;
    glass.refractionScale = 1.5;
    glass.refractiveIndex = 1.5;
    glass.specularOpacity = 0.04;
    glass.blur = 0.0;
    glass.sourceScale = 1.0;
    glass.alpha = 0.0;
    glass.hidden = YES;
    self.glassThumbView = glass;
    [self addSubview:glass];

    LGSwitchInsetShadowView *insetShadow = [[LGSwitchInsetShadowView alloc] initWithFrame:glass.bounds];
    insetShadow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [glass addSubview:insetShadow];
    self.glassInsetShadowView = insetShadow;

    [self updateMaterialColors];
    [self syncRenderedStateImmediately];
    [self updateVisualsAnimated:NO];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopDisplayLink];
    }
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *subview in self.subviews) {
        if (subview != self.trackView && subview != self.contractedThumbView && subview != self.glassThumbView) {
            subview.alpha = 0.01;
        }
    }
    [self updateMaterialColors];
    if (!self.hasRenderedState) {
        [self syncRenderedStateImmediately];
    }
    [self updateVisualsAnimated:NO];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateMaterialColors];
            [self refreshGlassBackdrop];
            [self updateVisualsAnimated:NO];
        }
    }
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    [super setOn:on animated:animated];
    self.targetProgress = on ? 1.0 : 0.0;
    [self setFillVisible:on animated:animated];
    if (animated && !self.pressed && !self.isDragging && !self.pendingTapAutoContract) {
        self.pendingTapAutoContract = YES;
        self.targetExpansion = 1.0;
        self.targetThumbSize = LGSettingsSwitchExpandedThumbSize();
        LGSettingsSwitchScheduleAutoContract(self);
    }
    if (!animated) {
        [self syncRenderedStateImmediately];
    } else {
        [self startDisplayLinkIfNeeded];
    }
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:animated];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    CGPoint location = [touch locationInView:self];
    self.pressed = YES;
    self.dragMoved = NO;
    self.isDragging = NO;
    self.didToggleDuringDrag = NO;
    self.didSendValueChangedDuringDrag = NO;
    self.wasOnWhenDragStarted = self.isOn;
    self.touchBeganTime = CACurrentMediaTime();
    self.dragStartLocation = location.x;
    self.dragStartThumbCenterX = [self resolvedThumbCenterX];
    self.targetExpansion = 1.0;
    self.targetThumbSize = LGSettingsSwitchExpandedThumbSize();
    [self startDisplayLinkIfNeeded];
    [self.feedbackGenerator prepare];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    if (!touch) return NO;
    CFTimeInterval touchDuration = CACurrentMediaTime() - self.touchBeganTime;
    if (!self.isDragging && touchDuration >= 0.15) {
        self.isDragging = YES;
    }
    CGFloat currentX = [touch locationInView:self].x;
    CGFloat translation = currentX - self.dragStartLocation;
    CGFloat newCenterX = self.dragStartThumbCenterX + translation;
    CGFloat clampedCenterX = [self rubberBandedThumbCenterXForValue:newCenterX];
    CGFloat progress = [self progressForThumbCenterX:clampedCenterX];
    if (fabs(progress - self.targetProgress) > 0.015 || fabs(translation) > 2.0) {
        self.dragMoved = YES;
    }
    self.targetProgress = progress;
    self.renderedProgress = progress;
    self.hasRenderedState = YES;
    [self checkForEdgeToggleAtCenterX:clampedCenterX];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:NO];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    BOOL inside = touch && CGRectContainsPoint(CGRectInset(self.bounds, -10.0, -10.0), [touch locationInView:self]);
    self.pressed = NO;
    self.pendingTapAutoContract = NO;
    CFTimeInterval touchDuration = CACurrentMediaTime() - self.touchBeganTime;
    if (inside) {
        BOOL tappedToggle = touchDuration < 0.15;
        if (tappedToggle) {
            [self.feedbackGenerator impactOccurred];
            BOOL newOn = !self.isOn;
            [super setOn:newOn animated:NO];
            self.targetProgress = newOn ? 1.0 : 0.0;
            [self sendActionsForControlEvents:UIControlEventValueChanged];
            [self setFillVisible:newOn animated:YES];
        } else {
            [self finishDragInteraction];
        }
        if (tappedToggle) {
            self.targetExpansion = 1.0;
            self.targetThumbSize = LGSettingsSwitchExpandedThumbSize();
            self.pendingTapAutoContract = YES;
        } else {
            self.targetExpansion = 0.0;
            self.targetThumbSize = LGSettingsSwitchRestThumbSize();
        }
    } else {
        self.targetExpansion = 0.0;
        self.targetThumbSize = LGSettingsSwitchRestThumbSize();
        self.targetProgress = self.isOn ? 1.0 : 0.0;
        [self setFillVisible:self.isOn animated:YES];
        if (self.didToggleDuringDrag || self.dragMoved || self.isDragging) {
            [self finishDragInteraction];
        }
    }
    self.dragMoved = NO;
    self.isDragging = NO;
    [self startDisplayLinkIfNeeded];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
    if (self.pendingTapAutoContract) {
        LGSettingsSwitchScheduleAutoContract(self);
    }
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    (void)event;
    self.pressed = NO;
    self.dragMoved = NO;
    self.isDragging = NO;
    self.didToggleDuringDrag = NO;
    self.didSendValueChangedDuringDrag = NO;
    self.pendingTapAutoContract = NO;
    self.targetExpansion = 0.0;
    self.targetThumbSize = LGSettingsSwitchRestThumbSize();
    self.targetProgress = self.isOn ? 1.0 : 0.0;
    [self setFillVisible:self.isOn animated:YES];
    [self startDisplayLinkIfNeeded];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
}

- (void)lg_beginExternalPress {
    self.pressed = YES;
    self.pendingTapAutoContract = NO;
    self.targetExpansion = 1.0;
    self.targetThumbSize = LGSettingsSwitchExpandedThumbSize();
    [self startDisplayLinkIfNeeded];
    [self.feedbackGenerator prepare];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
}

- (void)lg_endExternalPressForToggle {
    self.pressed = NO;
    self.pendingTapAutoContract = YES;
    self.targetExpansion = 1.0;
    self.targetThumbSize = LGSettingsSwitchExpandedThumbSize();
    [self startDisplayLinkIfNeeded];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
    LGSettingsSwitchScheduleAutoContract(self);
}

- (void)lg_cancelExternalPress {
    self.pressed = NO;
    self.pendingTapAutoContract = NO;
    self.targetExpansion = 0.0;
    self.targetThumbSize = LGSettingsSwitchRestThumbSize();
    [self startDisplayLinkIfNeeded];
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:YES];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, -10.0, -10.0), point);
}

- (CGRect)trackFrame {
    CGSize size = self.intrinsicContentSize;
    return CGRectMake(floor((CGRectGetWidth(self.bounds) - size.width) * 0.5),
                      floor((CGRectGetHeight(self.bounds) - size.height) * 0.5),
                      size.width,
                      size.height);
}

- (CGFloat)minimumThumbCenterX {
    CGRect trackFrame = [self trackFrame];
    return CGRectGetMinX(trackFrame) + 20.0;
}

- (CGFloat)maximumThumbCenterX {
    CGRect trackFrame = [self trackFrame];
    return CGRectGetMaxX(trackFrame) - 20.0;
}

- (CGFloat)resolvedThumbCenterX {
    return [self minimumThumbCenterX] + (([self maximumThumbCenterX] - [self minimumThumbCenterX]) * self.renderedProgress);
}

- (CGFloat)progressForTouchX:(CGFloat)touchX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    CGFloat clamped = fmax(minX, fmin(touchX, maxX));
    CGFloat range = maxX - minX;
    if (range <= 0.0) return 0.0;
    return (clamped - minX) / range;
}

- (CGFloat)progressForThumbCenterX:(CGFloat)centerX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    CGFloat range = maxX - minX;
    if (range <= 0.0) return 0.0;
    return (centerX - minX) / range;
}

- (CGFloat)rubberBandedThumbCenterXForValue:(CGFloat)value {
    CGFloat minValue = [self minimumThumbCenterX];
    CGFloat maxValue = [self maximumThumbCenterX];
    if (value < minValue) {
        return minValue - sqrt(minValue - value);
    }
    if (value > maxValue) {
        return maxValue + sqrt(value - maxValue);
    }
    return value;
}

- (void)checkForEdgeToggleAtCenterX:(CGFloat)centerX {
    CGFloat edgeThreshold = 5.0;
    BOOL hitLeftEdge = centerX <= [self minimumThumbCenterX] + edgeThreshold && self.isOn;
    BOOL hitRightEdge = centerX >= [self maximumThumbCenterX] - edgeThreshold && !self.isOn;
    if (!(hitLeftEdge || hitRightEdge)) return;
    BOOL newState = hitRightEdge;
    if (newState == self.isOn) return;
    self.didToggleDuringDrag = YES;
    [self.feedbackGenerator impactOccurred];
    [super setOn:newState animated:NO];
    self.targetProgress = newState ? 1.0 : 0.0;
    [self setFillVisible:newState animated:YES];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    self.didSendValueChangedDuringDrag = YES;
}

- (void)finishDragInteraction {
    if (!self.didToggleDuringDrag) {
        BOOL newOn = self.targetProgress >= 0.5;
        if (newOn != self.isOn) {
            [self.feedbackGenerator impactOccurred];
            [super setOn:newOn animated:NO];
            [self sendActionsForControlEvents:UIControlEventValueChanged];
        }
        [self setFillVisible:newOn animated:YES];
    } else if (!self.didSendValueChangedDuringDrag && self.isOn != self.wasOnWhenDragStarted) {
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    self.targetProgress = self.isOn ? 1.0 : 0.0;
    self.didToggleDuringDrag = NO;
    self.didSendValueChangedDuringDrag = NO;
}

- (void)syncRenderedStateImmediately {
    self.renderedProgress = self.targetProgress;
    self.renderedThumbSize = self.targetThumbSize;
    self.renderedExpansion = self.targetExpansion;
    self.renderedFillAlpha = self.targetFillAlpha;
    self.fillAnimating = NO;
    self.hasRenderedState = YES;
}

- (void)setFillVisible:(BOOL)visible animated:(BOOL)animated {
    CGFloat nextTarget = visible ? 1.0 : 0.0;
    if (fabs(self.targetFillAlpha - nextTarget) < 0.001 && (!animated || !self.fillAnimating)) return;
    self.targetFillAlpha = nextTarget;
    if (animated) {
        self.fillAnimationStartAlpha = self.renderedFillAlpha;
        self.fillAnimationStartTime = CACurrentMediaTime();
        self.fillAnimating = YES;
        [self startDisplayLinkIfNeeded];
    } else {
        self.renderedFillAlpha = nextTarget;
        self.fillAnimating = NO;
    }
}

- (void)startDisplayLinkIfNeeded {
    if (self.displayLink || !self.window) return;
    self.lastDisplayLinkTimestamp = 0.0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastDisplayLinkTimestamp = 0.0;
}

- (void)handleDisplayLink:(CADisplayLink *)link {
    CFTimeInterval dt = self.lastDisplayLinkTimestamp > 0.0 ? (link.timestamp - self.lastDisplayLinkTimestamp) : (1.0 / 60.0);
    self.lastDisplayLinkTimestamp = link.timestamp;
    CGFloat frameFactor = fmin(MAX(dt * 60.0, 0.35), 1.4);
    CGFloat progressLerp = (self.pressed ? 0.34 : 0.22) * frameFactor;
    CGFloat sizeLerp = (self.pressed ? 0.36 : 0.24) * frameFactor;
    BOOL expanding = self.targetExpansion > self.renderedExpansion;
    CGFloat expansionLerp = ((self.pressed || expanding) ? 0.42 : 0.14) * frameFactor;
    if (!self.hasRenderedState) {
        [self syncRenderedStateImmediately];
    } else {
        self.renderedProgress += (self.targetProgress - self.renderedProgress) * progressLerp;
        self.renderedThumbSize = CGSizeMake(self.renderedThumbSize.width + (self.targetThumbSize.width - self.renderedThumbSize.width) * sizeLerp,
                                            self.renderedThumbSize.height + (self.targetThumbSize.height - self.renderedThumbSize.height) * sizeLerp);
        self.renderedExpansion += (self.targetExpansion - self.renderedExpansion) * expansionLerp;
    }
    if (self.fillAnimating) {
        CFTimeInterval elapsed = CACurrentMediaTime() - self.fillAnimationStartTime;
        CGFloat t = fmax(0.0, fmin(elapsed / 0.1, 1.0));
        CGFloat eased = t * t * (3.0 - (2.0 * t));
        self.renderedFillAlpha = self.fillAnimationStartAlpha + ((self.targetFillAlpha - self.fillAnimationStartAlpha) * eased);
        if (t >= 1.0) {
            self.renderedFillAlpha = self.targetFillAlpha;
            self.fillAnimating = NO;
        }
    }
    [self refreshGlassBackdrop];
    [self updateVisualsAnimated:NO];

    BOOL settledProgress = fabs(self.targetProgress - self.renderedProgress) < 0.002;
    BOOL settledWidth = fabs(self.targetThumbSize.width - self.renderedThumbSize.width) < 0.05;
    BOOL settledHeight = fabs(self.targetThumbSize.height - self.renderedThumbSize.height) < 0.05;
    BOOL settledExpansion = fabs(self.targetExpansion - self.renderedExpansion) < 0.01;
    if (!self.pressed && !self.pendingTapAutoContract && settledProgress && settledWidth && settledHeight && settledExpansion && !self.fillAnimating) {
        self.renderedProgress = self.targetProgress;
        self.renderedThumbSize = self.targetThumbSize;
        self.renderedExpansion = self.targetExpansion;
        [self stopDisplayLink];
    }
}

- (void)updateMaterialColors {
    UIColor *accent = LGSwitchEffectiveAccentColor(self);
    BOOL darkMode = LGSwitchIsDarkMode(self.traitCollection);
    self.trackView.backgroundColor = LGSwitchOffTrackColor(self.traitCollection);
    self.fillView.backgroundColor = [accent colorWithAlphaComponent:darkMode ? 0.78 : 0.92];

    self.contractedThumbView.backgroundColor = UIColor.whiteColor;
    self.contractedThumbView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.contractedThumbView.layer.shadowOpacity = 0.12;
    self.contractedThumbView.layer.shadowRadius = 5.0;
    self.contractedThumbView.layer.shadowOffset = CGSizeZero;

    self.glassThumbView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.glassThumbView.layer.shadowOpacity = darkMode ? 0.12 : 0.08;
    self.glassThumbView.layer.shadowRadius = darkMode ? 7.0 : 4.0;
    self.glassThumbView.layer.shadowOffset = darkMode ? CGSizeMake(0.0, 2.0) : CGSizeMake(0.0, 1.0);
    self.glassThumbView.specularOpacity = darkMode ? 0.02 : 0.0;
    self.glassInsetShadowView.alpha = darkMode ? 0.68 : 1.0;
}

- (void)refreshGlassBackdrop {
    if (!self.window) return;
    CGRect trackFrame = [self trackFrame];
    CGRect captureRect = CGRectInset(trackFrame, -20.0, -20.0);
    UIColor *backgroundColor = self.superview.backgroundColor ?: (self.window.backgroundColor ?: [UIColor systemBackgroundColor]);
    UIColor *trackColor = LGSwitchOffTrackColor(self.traitCollection);
    UIColor *baseFillColor = self.fillView.backgroundColor ?: LGSwitchEffectiveAccentColor(self);
    UIColor *sheenColor = LGSwitchBackdropSheenColor(self.traitCollection);
    UIColor *liftColor = LGSwitchGlassLiftColor(self.traitCollection);
    CGRect localTrackRect = CGRectOffset(trackFrame, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
    UIColor *fillColor = [baseFillColor colorWithAlphaComponent:self.renderedFillAlpha];
    CGFloat fillEndX = CGRectGetMaxX(localTrackRect);
    UIImage *image = LGRenderSwitchBackdropImage(captureRect.size, backgroundColor, trackColor, fillColor, sheenColor, liftColor, localTrackRect, fillEndX, 0.75);
    self.glassThumbView.sourceImage = image;
    self.glassThumbView.sourceOrigin = [self convertPoint:captureRect.origin toView:nil];
    [self.glassThumbView scheduleDraw];
}

- (void)updateVisualsAnimated:(BOOL)animated {
    CGRect trackFrame = [self trackFrame];
    self.trackView.frame = trackFrame;
    self.trackView.layer.cornerRadius = CGRectGetHeight(trackFrame) * 0.5;

    self.fillView.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(trackFrame), CGRectGetHeight(trackFrame));
    self.fillView.layer.cornerRadius = CGRectGetHeight(self.fillView.bounds) * 0.5;
    self.fillView.alpha = self.renderedFillAlpha;

    CGFloat centerX = [self resolvedThumbCenterX];
    CGRect contractedFrame = CGRectMake(centerX - 18.0,
                                        CGRectGetMidY(trackFrame) - 12.0,
                                        36.0,
                                        24.0);
    CGRect glassFrame = CGRectMake(centerX - self.renderedThumbSize.width * 0.5,
                                   CGRectGetMidY(trackFrame) - self.renderedThumbSize.height * 0.5,
                                   self.renderedThumbSize.width,
                                   self.renderedThumbSize.height);

    self.contractedThumbView.layer.cornerRadius = 12.0;
    self.glassThumbView.cornerRadius = CGRectGetHeight(glassFrame) * 0.5;
    self.glassThumbView.hidden = NO;
    self.contractedThumbView.hidden = NO;
    (void)animated;
    CGFloat expansion = fmax(0.0, fmin(self.renderedExpansion, 1.0));
    CGFloat visualExpansion = expansion * expansion * (3.0 - (2.0 * expansion));
    CGFloat contractedScale = 1.0 + (0.06 * visualExpansion);
    CGFloat glassScale = 0.92 + (0.08 * visualExpansion);
    self.contractedThumbView.frame = contractedFrame;
    self.glassThumbView.frame = glassFrame;
    self.glassThumbView.alpha = visualExpansion;
    self.contractedThumbView.alpha = 1.0 - visualExpansion;
    self.glassThumbView.transform = CGAffineTransformMakeScale(glassScale, glassScale);
    self.contractedThumbView.transform = CGAffineTransformMakeScale(contractedScale, contractedScale);
    self.glassThumbView.hidden = visualExpansion < 0.01;
    self.contractedThumbView.hidden = visualExpansion > 0.99;
}

@end
