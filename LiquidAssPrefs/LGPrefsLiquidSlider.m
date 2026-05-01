#import "LGPrefsLiquidSlider.h"
#import "../Shared/LGLiquidMotion.h"
#import "../Shared/LGGlassRenderer.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

void * const kLGPrefsSliderUseLiveCaptureKey = (void *)&kLGPrefsSliderUseLiveCaptureKey;
void * const kLGPrefsSliderExtraCaptureInsetsKey = (void *)&kLGPrefsSliderExtraCaptureInsetsKey;
void * const kLGPrefsSliderLabelCaptureRegionKey = (void *)&kLGPrefsSliderLabelCaptureRegionKey;
void * const kLGPrefsSliderSegmentedKey = (void *)&kLGPrefsSliderSegmentedKey;
void * const kLGPrefsSliderSegmentCountKey = (void *)&kLGPrefsSliderSegmentCountKey;
void * const kLGPrefsSliderSegmentCentersKey = (void *)&kLGPrefsSliderSegmentCentersKey;
void * const kLGPrefsSliderEndpointCentersKey = (void *)&kLGPrefsSliderEndpointCentersKey;

static const CGFloat kLGPrefsSliderContractedThumbWidth = 36.0;
static const CFTimeInterval kLGPrefsSliderTrackingSnapshotInterval = (1.0 / 60.0);

static UIImage *LGTransparentThumbImage(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return nil;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *LGCaptureSliderBackdropImage(UIView *captureView, CGRect captureRect) {
    if (!captureView || CGRectIsEmpty(captureRect)) return nil;
    UIGraphicsBeginImageContextWithOptions(captureRect.size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
    [captureView.layer renderInContext:context];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *LGCompositeSliderCaptureRegion(UIImage *baseImage,
                                               UIView *captureView,
                                               CGRect captureRect,
                                               CGRect regionRectInCapture) {
    if (!baseImage || !captureView || CGRectIsEmpty(captureRect) || CGRectIsEmpty(regionRectInCapture)) return baseImage;
    CGRect clippedRegion = CGRectIntersection(CGRectMake(0.0, 0.0, CGRectGetWidth(captureRect), CGRectGetHeight(captureRect)),
                                              regionRectInCapture);
    if (CGRectIsEmpty(clippedRegion)) return baseImage;

    CGRect regionRectInView = CGRectOffset(clippedRegion, CGRectGetMinX(captureRect), CGRectGetMinY(captureRect));
    UIImage *regionImage = LGCaptureSliderBackdropImage(captureView, regionRectInView);
    if (!regionImage) return baseImage;

    UIGraphicsBeginImageContextWithOptions(baseImage.size, NO, baseImage.scale);
    [baseImage drawAtPoint:CGPointZero];
    [regionImage drawInRect:clippedRegion];
    UIImage *composited = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composited ?: baseImage;
}

static BOOL LGSliderUsesSegmentedMode(UISlider *slider) {
    return [objc_getAssociatedObject(slider, kLGPrefsSliderSegmentedKey) boolValue];
}

static NSInteger LGSliderSegmentCount(UISlider *slider) {
    NSNumber *count = objc_getAssociatedObject(slider, kLGPrefsSliderSegmentCountKey);
    NSInteger segmentCount = MAX(0, count.integerValue);
    if (segmentCount > 0) return segmentCount;
    float range = slider.maximumValue - slider.minimumValue;
    float roundedRange = roundf(range);
    if (fabsf(range - roundedRange) <= 0.001f && roundedRange >= 1.0f && roundedRange <= 24.0f) {
        return (NSInteger)roundedRange;
    }
    return 0;
}

static NSInteger LGSliderSnapPointCount(UISlider *slider) {
    NSInteger segmentCount = LGSliderSegmentCount(slider);
    if (segmentCount <= 0) return 0;
    return segmentCount + 1;
}

static NSArray<NSNumber *> *LGSliderSegmentCenters(UISlider *slider) {
    id value = objc_getAssociatedObject(slider, kLGPrefsSliderSegmentCentersKey);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSArray<NSNumber *> *LGSliderEndpointCenters(UISlider *slider) {
    id value = objc_getAssociatedObject(slider, kLGPrefsSliderEndpointCentersKey);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static CGFloat LGSliderThumbCenterXForValue(UISlider *slider, float value) {
    NSInteger snapPointCount = LGSliderSnapPointCount(slider);
    NSArray<NSNumber *> *segmentCenters = LGSliderSegmentCenters(slider);
    float range = slider.maximumValue - slider.minimumValue;
    if (snapPointCount >= 2 && segmentCenters.count == (NSUInteger)snapPointCount && fabsf(range) > FLT_EPSILON) {
        CGFloat normalized = (value - slider.minimumValue) / range;
        normalized = fmax(0.0, fmin(1.0, normalized));
        NSInteger index = lround(normalized * (CGFloat)(snapPointCount - 1));
        index = MAX(0, MIN(index, snapPointCount - 1));
        return segmentCenters[(NSUInteger)index].doubleValue;
    }
    NSArray<NSNumber *> *endpointCenters = LGSliderEndpointCenters(slider);
    if (endpointCenters.count == 2 && fabsf(range) > FLT_EPSILON) {
        CGFloat normalized = (value - slider.minimumValue) / range;
        normalized = fmax(0.0, fmin(1.0, normalized));
        CGFloat minCenterX = endpointCenters[0].doubleValue;
        CGFloat maxCenterX = endpointCenters[1].doubleValue;
        return minCenterX + ((maxCenterX - minCenterX) * normalized);
    }
    CGRect trackRect = [slider trackRectForBounds:slider.bounds];
    if ([slider isKindOfClass:[LGPrefsLiquidSlider class]]) {
        CGFloat thumbWidth = kLGPrefsSliderContractedThumbWidth;
        CGFloat minCenterX = CGRectGetMinX(trackRect) + thumbWidth * 0.5;
        CGFloat maxCenterX = CGRectGetMaxX(trackRect) - thumbWidth * 0.5;
        if (fabsf(range) <= FLT_EPSILON) return minCenterX;
        CGFloat normalized = (value - slider.minimumValue) / range;
        normalized = fmax(0.0, fmin(1.0, normalized));
        return minCenterX + ((maxCenterX - minCenterX) * normalized);
    }
    CGRect thumbRect = [slider thumbRectForBounds:slider.bounds trackRect:trackRect value:value];
    if (!CGRectIsEmpty(thumbRect)) {
        return CGRectGetMidX(thumbRect);
    }
    return CGRectGetMidX(trackRect);
}

static float LGSliderNearestSegmentValueForCenterX(UISlider *slider, CGFloat centerX) {
    NSInteger snapPointCount = LGSliderSnapPointCount(slider);
    if (snapPointCount < 2) return slider.value;
    float range = slider.maximumValue - slider.minimumValue;
    if (fabsf(range) <= FLT_EPSILON) return slider.minimumValue;
    NSArray<NSNumber *> *segmentCenters = LGSliderSegmentCenters(slider);
    CGFloat bestDistance = CGFLOAT_MAX;
    float bestValue = slider.minimumValue;
    for (NSInteger index = 0; index < snapPointCount; index++) {
        float candidateValue = slider.minimumValue + ((float)index / (float)(snapPointCount - 1)) * range;
        CGFloat candidateCenter = (segmentCenters.count == (NSUInteger)snapPointCount)
            ? segmentCenters[(NSUInteger)index].doubleValue
            : LGSliderThumbCenterXForValue(slider, candidateValue);
        CGFloat distance = fabs(candidateCenter - centerX);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestValue = candidateValue;
        }
    }
    return bestValue;
}

static void LGLogSegmentedSliderSnap(UISlider *slider, NSString *phase, CGFloat centerX, float snappedValue) {
    NSArray<NSNumber *> *segmentCenters = LGSliderSegmentCenters(slider);
    NSArray<NSNumber *> *endpointCenters = LGSliderEndpointCenters(slider);
    LGDebugLog(@"settings segmented slider phase=%@ slider=%p value=%.3f center=%.3f snapped=%.3f min=%.3f max=%.3f points=%ld endpoints=%@ centers=%@",
               phase,
               slider,
               slider.value,
               centerX,
               snappedValue,
               slider.minimumValue,
               slider.maximumValue,
               (long)LGSliderSnapPointCount(slider),
               endpointCenters ?: @[],
               segmentCenters ?: @[]);
}

static UIColor *LGSliderFallbackTrackColor(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
            if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithWhite:1.0 alpha:0.18];
            }
            return [UIColor quaternaryLabelColor];
        }];
    }
    return [[UIColor blackColor] colorWithAlphaComponent:0.14];
}

static BOOL LGSliderColorLooksTooDarkForAccent(UIColor *color) {
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

static UIColor *LGSliderEffectiveAccentColor(UISlider *slider) {
    NSArray<UIColor *> *candidates = @[
        slider.minimumTrackTintColor ?: UIColor.clearColor,
        slider.window.tintColor ?: UIColor.clearColor,
        slider.superview.tintColor ?: UIColor.clearColor,
        slider.tintColor ?: UIColor.clearColor,
        UIColor.systemBlueColor
    ];
    for (UIColor *candidate in candidates) {
        if (!candidate || candidate == UIColor.clearColor) continue;
        if (LGSliderColorLooksTooDarkForAccent(candidate)) continue;
        return candidate;
    }
    return UIColor.systemBlueColor;
}

static BOOL LGSliderIsDarkMode(UITraitCollection *traitCollection) {
    if (@available(iOS 12.0, *)) {
        return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static UIColor *LGSliderIdleThumbColor(UITraitCollection *traitCollection) {
    (void)traitCollection;
    return UIColor.whiteColor;
}

static UIColor *LGSliderBackdropSheenColor(UITraitCollection *traitCollection) {
    if (LGSliderIsDarkMode(traitCollection)) {
        return [UIColor colorWithWhite:1.0 alpha:0.045];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.12];
}

static UIColor *LGSliderActiveGlassLiftColor(UITraitCollection *traitCollection) {
    if (LGSliderIsDarkMode(traitCollection)) {
        return [UIColor colorWithWhite:1.0 alpha:0.105];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.0];
}

static UIImage *LGApplySliderGlassLiftOverlayInRegion(UIImage *baseImage,
                                                      UIColor *glassLiftColor,
                                                      CGRect localTrackRect,
                                                      CGRect regionRect) {
    if (!baseImage || CGColorGetAlpha(glassLiftColor.CGColor) <= 0.001) return baseImage;
    UIGraphicsBeginImageContextWithOptions(baseImage.size, NO, baseImage.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [baseImage drawAtPoint:CGPointZero];
    if (!CGRectIsNull(regionRect) && !CGRectIsEmpty(regionRect)) {
        CGContextSaveGState(context);
        CGContextClipToRect(context, regionRect);
    }
    UIBezierPath *liftPath = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(localTrackRect, -34.0, -16.0)
                                                        cornerRadius:CGRectGetHeight(localTrackRect) * 3.4];
    [glassLiftColor setFill];
    [liftPath fill];
    if (!CGRectIsNull(regionRect) && !CGRectIsEmpty(regionRect)) {
        CGContextRestoreGState(context);
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image ?: baseImage;
}

static UIImage *LGApplySliderGlassLiftOverlay(UIImage *baseImage,
                                              UIColor *glassLiftColor,
                                              CGRect localTrackRect) {
    return LGApplySliderGlassLiftOverlayInRegion(baseImage, glassLiftColor, localTrackRect, CGRectNull);
}

static UIImage *LGRenderSliderBackdropImage(CGSize size,
                                            UIColor *backgroundColor,
                                            UIColor *trackColor,
                                            UIColor *fillColor,
                                            UIColor *sheenColor,
                                            UIColor *glassLiftColor,
                                            CGRect localTrackRect,
                                            CGFloat fillEndX) {
    if (size.width <= 0.0 || size.height <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [backgroundColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    UIBezierPath *trackPath = [UIBezierPath bezierPathWithRoundedRect:localTrackRect
                                                         cornerRadius:CGRectGetHeight(localTrackRect) * 0.5];
    [trackColor setFill];
    [trackPath fill];

    CGFloat clampedFillEndX = fmax(CGRectGetMinX(localTrackRect), fmin(fillEndX, CGRectGetMaxX(localTrackRect)));
    CGRect fillRect = CGRectMake(CGRectGetMinX(localTrackRect),
                                 CGRectGetMinY(localTrackRect),
                                 clampedFillEndX - CGRectGetMinX(localTrackRect),
                                 CGRectGetHeight(localTrackRect));
    if (fillRect.size.width > 0.0) {
        UIBezierPath *fillPath = [UIBezierPath bezierPathWithRoundedRect:fillRect
                                                            cornerRadius:CGRectGetHeight(fillRect) * 0.5];
        [fillColor setFill];
        [fillPath fill];
    }

    CGContextSetBlendMode(context, kCGBlendModeNormal);
    [sheenColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, fmin(12.0, size.height * 0.35)));

    if (CGColorGetAlpha(glassLiftColor.CGColor) > 0.001) {
        UIBezierPath *liftPath = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(localTrackRect, -34.0, -16.0)
                                                            cornerRadius:CGRectGetHeight(localTrackRect) * 3.4];
        [glassLiftColor setFill];
        [liftPath fill];
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface LGInsetShadowView : UIView
@end

@implementation LGInsetShadowView

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

@interface LGPrefsLiquidSlider ()
@property (nonatomic, strong) LGSharedGlassView *glassThumbView;
@property (nonatomic, strong) LGInsetShadowView *glassInsetShadowView;
@property (nonatomic, strong) UIView *contractedThumbView;
@property (nonatomic, strong) UIImpactFeedbackGenerator *lightFeedbackGenerator;
@property (nonatomic, strong) UIImpactFeedbackGenerator *mediumFeedbackGenerator;
@property (nonatomic, assign) BOOL trackingActive;
@property (nonatomic, assign) BOOL hasPresentedThumbCenter;
@property (nonatomic, assign) CGFloat presentedThumbCenterX;
@property (nonatomic, assign) CGFloat logicalThumbCenterX;
@property (nonatomic, assign) BOOL didTriggerMinHaptic;
@property (nonatomic, assign) BOOL didTriggerMaxHaptic;
@property (nonatomic, assign) CGFloat rubberBandOffset;
@property (nonatomic, assign) CFTimeInterval touchBeganTime;
@property (nonatomic, assign) CGFloat thumbVelocityX;
@property (nonatomic, assign) CGFloat lastTouchX;
@property (nonatomic, assign) CFTimeInterval lastTouchTime;
@property (nonatomic, assign) CGSize currentThumbSize;
@property (nonatomic, assign) CGSize targetThumbSize;
@property (nonatomic, assign) CGSize contractedThumbSize;
@property (nonatomic, assign) CGSize expandedThumbSize;
@property (nonatomic, assign) CGFloat renderedThumbCenterX;
@property (nonatomic, assign) CGSize renderedThumbSize;
@property (nonatomic, assign) CGFloat renderedExpansion;
@property (nonatomic, assign) CGFloat targetExpansion;
@property (nonatomic, assign) BOOL hasRenderedThumbState;
@property (nonatomic, strong) CADisplayLink *thumbDisplayLink;
@property (nonatomic, assign) CFTimeInterval lastDisplayLinkTimestamp;
@property (nonatomic, assign) CFTimeInterval lastSnapshotRefreshTimestamp;
@end

@implementation LGPrefsLiquidSlider

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
    [self stopThumbDisplayLink];
}

- (void)commonInit {
    self.clipsToBounds = NO;
    self.contractedThumbSize = CGSizeMake(kLGPrefsSliderContractedThumbWidth, 24.0);
    self.expandedThumbSize = CGSizeMake(54.0, 34.0);
    self.currentThumbSize = self.contractedThumbSize;
    self.targetThumbSize = self.contractedThumbSize;
    self.renderedThumbSize = self.contractedThumbSize;
    self.renderedExpansion = 0.0;
    self.targetExpansion = 0.0;
    UIImage *clearImage = LGTransparentThumbImage(self.contractedThumbSize);
    [self setThumbImage:clearImage forState:UIControlStateNormal];
    [self setThumbImage:clearImage forState:UIControlStateHighlighted];
    self.thumbTintColor = UIColor.clearColor;
    self.lightFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    self.mediumFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [self ensureGlassThumbView];
    [self ensureContractedThumbView];
    [self updateThumbMaterialColors];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopThumbDisplayLink];
    }
    [self refreshGlassSnapshotIfNeeded:YES];
    [self syncRenderedThumbStateImmediately];
    [self updateGlassThumbFrameAnimated:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self ensureGlassThumbView];
    [self ensureContractedThumbView];
    [self updateThumbMaterialColors];
    if (!self.hasRenderedThumbState) {
        [self syncRenderedThumbStateImmediately];
    }
    [self updateGlassThumbFrameAnimated:NO];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateThumbMaterialColors];
            [self refreshGlassSnapshotIfNeeded:YES];
            [self updateGlassThumbFrameAnimated:NO];
        }
    }
}

- (void)setValue:(float)value {
    [super setValue:value];
    if (!self.trackingActive && !self.thumbDisplayLink) {
        [self syncRenderedThumbStateImmediately];
    }
    [self updateGlassThumbFrameAnimated:NO];
}

- (void)setValue:(float)value animated:(BOOL)animated {
    [super setValue:value animated:animated];
    if (!self.trackingActive && !self.thumbDisplayLink) {
        [self syncRenderedThumbStateImmediately];
    }
    [self updateGlassThumbFrameAnimated:animated];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL began = [super beginTrackingWithTouch:touch withEvent:event];
    if (!began) return NO;
    self.trackingActive = YES;
    self.hasPresentedThumbCenter = YES;
    self.presentedThumbCenterX = [self resolvedThumbCenterX];
    self.logicalThumbCenterX = self.presentedThumbCenterX;
    self.touchBeganTime = CACurrentMediaTime();
    self.didTriggerMinHaptic = NO;
    self.didTriggerMaxHaptic = NO;
    self.rubberBandOffset = 0.0;
    self.thumbVelocityX = 0.0;
    self.lastTouchX = [touch locationInView:self].x;
    self.lastTouchTime = self.touchBeganTime;
    self.targetThumbSize = self.expandedThumbSize;
    self.targetExpansion = 1.0;
    [self startThumbDisplayLinkIfNeeded];
    [self.lightFeedbackGenerator prepare];
    [self.mediumFeedbackGenerator prepare];
    [self refreshGlassSnapshotIfNeeded:YES];
    [self setThumbExpanded:YES animated:YES];
    [self updateGlassThumbFrameAnimated:NO];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL continued = [super continueTrackingWithTouch:touch withEvent:event];
    CGFloat touchX = [touch locationInView:self].x;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = MAX(now - self.lastTouchTime, 0.001);
    CGFloat rawVelocity = (touchX - self.lastTouchX) / dt;
    self.thumbVelocityX = self.thumbVelocityX * 0.35 + rawVelocity * 0.65;
    self.lastTouchX = touchX;
    self.lastTouchTime = now;
    [self updatePresentedThumbForTouchX:touchX];
    [self updateEdgeHapticsForTouchX:touchX];
    [self updateGlassThumbFrameAnimated:NO];
    return continued;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [super endTrackingWithTouch:touch withEvent:event];
    CFTimeInterval touchDuration = CACurrentMediaTime() - self.touchBeganTime;
    if (touchDuration < 0.15 && touch) {
        CGFloat tapX = [touch locationInView:self].x;
        [self updatePresentedThumbForTouchX:tapX];
    }
    if (LGSliderUsesSegmentedMode(self)) {
        CGFloat snapCenterX = self.hasPresentedThumbCenter ? self.logicalThumbCenterX : [self resolvedThumbCenterX];
        float snappedValue = LGSliderNearestSegmentValueForCenterX(self, snapCenterX);
        LGLogSegmentedSliderSnap(self, @"end", snapCenterX, snappedValue);
        [super setValue:snappedValue animated:NO];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    self.trackingActive = NO;
    self.hasPresentedThumbCenter = NO;
    self.rubberBandOffset = 0.0;
    self.thumbVelocityX = 0.0;
    self.logicalThumbCenterX = 0.0;
    self.targetThumbSize = self.expandedThumbSize;
    self.currentThumbSize = self.expandedThumbSize;
    self.targetExpansion = 0.0;
    [self setThumbExpanded:NO animated:YES];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    if (LGSliderUsesSegmentedMode(self)) {
        CGFloat snapCenterX = self.hasPresentedThumbCenter ? self.logicalThumbCenterX : [self resolvedThumbCenterX];
        float snappedValue = LGSliderNearestSegmentValueForCenterX(self, snapCenterX);
        LGLogSegmentedSliderSnap(self, @"cancel", snapCenterX, snappedValue);
        [super setValue:snappedValue animated:NO];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    self.trackingActive = NO;
    self.hasPresentedThumbCenter = NO;
    self.rubberBandOffset = 0.0;
    self.thumbVelocityX = 0.0;
    self.logicalThumbCenterX = 0.0;
    self.targetThumbSize = self.expandedThumbSize;
    self.currentThumbSize = self.expandedThumbSize;
    self.targetExpansion = 0.0;
    [self setThumbExpanded:NO animated:YES];
}

- (CGRect)glassThumbFrameForCurrentValue {
    CGFloat centerX = self.hasRenderedThumbState ? self.renderedThumbCenterX : [self resolvedThumbCenterX];
    CGSize size = self.hasRenderedThumbState ? self.renderedThumbSize : self.currentThumbSize;
    CGPoint center = CGPointMake(centerX, CGRectGetMidY(self.bounds));
    return CGRectMake(center.x - size.width * 0.5,
                      center.y - size.height * 0.5,
                      size.width,
                      size.height);
}

- (CGFloat)minimumThumbCenterX {
    return LGSliderThumbCenterXForValue(self, self.minimumValue);
}

- (CGFloat)maximumThumbCenterX {
    return LGSliderThumbCenterXForValue(self, self.maximumValue);
}

- (CGFloat)resolvedThumbCenterX {
    if (self.trackingActive && self.hasPresentedThumbCenter) {
        return self.presentedThumbCenterX;
    }
    return LGSliderThumbCenterXForValue(self, self.value);
}

- (CGFloat)rubberBandedCenterXForTouchX:(CGFloat)touchX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    return LGLiquidRubberBandedCenterX(touchX, minX, maxX, 1.24);
}

- (CGFloat)overshootDistanceForTouchX:(CGFloat)touchX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    return LGLiquidOvershootDistance(touchX, minX, maxX);
}

- (void)updatePresentedThumbForTouchX:(CGFloat)touchX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    CGFloat clampedX = fmax(minX, fmin(touchX, maxX));
    self.hasPresentedThumbCenter = YES;
    self.logicalThumbCenterX = clampedX;
    self.presentedThumbCenterX = [self rubberBandedCenterXForTouchX:touchX];
    if (touchX < minX) {
        self.rubberBandOffset = self.presentedThumbCenterX - minX;
    } else if (touchX > maxX) {
        self.rubberBandOffset = self.presentedThumbCenterX - maxX;
    } else {
        self.rubberBandOffset = 0.0;
    }

    CGFloat range = maxX - minX;
    if (range > 0.0) {
        CGFloat normalized = (clampedX - minX) / range;
        float newValue = self.minimumValue + (float)normalized * (self.maximumValue - self.minimumValue);
        if (fabs(self.value - newValue) > 0.0001f) {
            [super setValue:newValue animated:NO];
            [self sendActionsForControlEvents:UIControlEventValueChanged];
        }
    }

    LGLiquidDragState dragState = LGLiquidDragStateMake(touchX,
                                                        minX,
                                                        maxX,
                                                        self.expandedThumbSize,
                                                        self.thumbVelocityX,
                                                        25.0);
    self.presentedThumbCenterX = dragState.centerX;
    self.targetThumbSize = CGSizeMake(dragState.width, dragState.height);
    self.currentThumbSize = self.targetThumbSize;
}

- (void)updateEdgeHapticsForTouchX:(CGFloat)touchX {
    CGFloat minX = [self minimumThumbCenterX];
    CGFloat maxX = [self maximumThumbCenterX];
    CGFloat threshold = 2.0;
    if (touchX <= minX + threshold && !self.didTriggerMinHaptic) {
        self.didTriggerMinHaptic = YES;
        self.didTriggerMaxHaptic = NO;
        [self.lightFeedbackGenerator impactOccurred];
    } else if (touchX >= maxX - threshold && !self.didTriggerMaxHaptic) {
        self.didTriggerMaxHaptic = YES;
        self.didTriggerMinHaptic = NO;
        [self.mediumFeedbackGenerator impactOccurred];
    } else if (touchX > minX + threshold * 2.0 && touchX < maxX - threshold * 2.0) {
        self.didTriggerMinHaptic = NO;
        self.didTriggerMaxHaptic = NO;
    }
}

- (void)ensureGlassThumbView {
    if (self.glassThumbView) return;
    LGEnsureSharedGlassPipelinesReady();
    LGSharedGlassView *glass = [[LGSharedGlassView alloc] initWithFrame:CGRectZero sourceImage:nil sourceOrigin:CGPointZero];
    glass.userInteractionEnabled = NO;
    glass.releasesSourceAfterUpload = YES;
    glass.bezelWidth = 10.0;
    glass.glassThickness = 30.0;
    glass.refractionScale = 1.2;
    glass.refractiveIndex = 1.5;
    glass.specularOpacity = 0.04;
    glass.blur = 0.0;
    glass.sourceScale = 1.0;
    glass.layer.shadowColor = UIColor.blackColor.CGColor;
    glass.layer.shadowOpacity = 0.08;
    glass.layer.shadowRadius = 4.0;
    glass.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    glass.alpha = 0.0;
    glass.hidden = YES;
    self.glassThumbView = glass;
    [self addSubview:glass];

    LGInsetShadowView *insetShadow = [[LGInsetShadowView alloc] initWithFrame:glass.bounds];
    insetShadow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    insetShadow.alpha = 1.0;
    [glass addSubview:insetShadow];
    self.glassInsetShadowView = insetShadow;
}

- (void)ensureContractedThumbView {
    if (self.contractedThumbView) return;
    UIView *thumb = [[UIView alloc] initWithFrame:CGRectZero];
    thumb.userInteractionEnabled = NO;
    thumb.backgroundColor = LGSliderIdleThumbColor(self.traitCollection);
    thumb.layer.shadowColor = UIColor.blackColor.CGColor;
    thumb.layer.shadowOpacity = 0.12;
    thumb.layer.shadowRadius = 5.0;
    thumb.layer.shadowOffset = CGSizeZero;
    self.contractedThumbView = thumb;
    [self addSubview:thumb];
}

- (void)updateThumbMaterialColors {
    BOOL darkMode = LGSliderIsDarkMode(self.traitCollection);
    self.contractedThumbView.backgroundColor = LGSliderIdleThumbColor(self.traitCollection);
    self.contractedThumbView.layer.shadowOpacity = 0.12;
    self.contractedThumbView.layer.shadowRadius = 5.0;
    self.glassThumbView.specularOpacity = darkMode ? 0.02 : 0.0;
    self.glassThumbView.layer.shadowOpacity = darkMode ? 0.12 : 0.08;
    self.glassThumbView.layer.shadowRadius = darkMode ? 7.0 : 4.0;
    self.glassThumbView.layer.shadowOffset = darkMode ? CGSizeMake(0.0, 2.0) : CGSizeMake(0.0, 1.0);
    self.glassThumbView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.glassInsetShadowView.alpha = darkMode ? 0.68 : 1.0;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hitRect = CGRectInset(self.bounds, -18.0, -14.0);
    return CGRectContainsPoint(hitRect, point);
}

- (void)startThumbDisplayLinkIfNeeded {
    if (self.thumbDisplayLink || !self.window) return;
    self.lastDisplayLinkTimestamp = 0.0;
    self.thumbDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleThumbDisplayLink:)];
    [self.thumbDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopThumbDisplayLink {
    [self.thumbDisplayLink invalidate];
    self.thumbDisplayLink = nil;
    self.lastDisplayLinkTimestamp = 0.0;
    self.lastSnapshotRefreshTimestamp = 0.0;
}

- (void)syncRenderedThumbStateImmediately {
    self.renderedThumbCenterX = [self resolvedThumbCenterX];
    self.renderedThumbSize = self.trackingActive ? self.targetThumbSize : self.currentThumbSize;
    self.renderedExpansion = self.targetExpansion;
    self.hasRenderedThumbState = YES;
}

- (void)handleThumbDisplayLink:(CADisplayLink *)link {
    CFTimeInterval dt = self.lastDisplayLinkTimestamp > 0.0 ? (link.timestamp - self.lastDisplayLinkTimestamp) : (1.0 / 60.0);
    self.lastDisplayLinkTimestamp = link.timestamp;
    CGFloat frameFactor = fmin(MAX(dt * 60.0, 0.35), 1.4);
    BOOL expanding = self.targetExpansion > self.renderedExpansion;
    CGFloat expansionLerp = ((self.trackingActive || expanding) ? 0.30 : 0.10) * frameFactor;
    CGFloat targetCenterX = [self resolvedThumbCenterX];
    CGSize targetSize = self.trackingActive ? self.targetThumbSize : self.currentThumbSize;
    if (!self.hasRenderedThumbState) {
        [self syncRenderedThumbStateImmediately];
    } else {
        LGLiquidRenderedState currentState = LGLiquidRenderedStateMake(self.renderedThumbCenterX, self.renderedThumbSize);
        LGLiquidRenderedState targetState = LGLiquidRenderedStateMake(targetCenterX, targetSize);
        LGLiquidRenderedState nextState = LGLiquidRenderedStateStep(currentState, targetState, self.trackingActive, dt);
        self.renderedThumbCenterX = nextState.centerX;
        self.renderedThumbSize = CGSizeMake(nextState.width, nextState.height);
        self.renderedExpansion += (self.targetExpansion - self.renderedExpansion) * expansionLerp;
    }
    [self refreshGlassSnapshotIfNeeded:YES];
    [self updateGlassThumbFrameAnimated:NO];

    BOOL settledCenter = fabs(targetCenterX - self.renderedThumbCenterX) < 0.08;
    BOOL settledWidth = fabs(targetSize.width - self.renderedThumbSize.width) < 0.08;
    BOOL settledHeight = fabs(targetSize.height - self.renderedThumbSize.height) < 0.08;
    BOOL settledExpansion = fabs(self.targetExpansion - self.renderedExpansion) < 0.01;
    if (!self.trackingActive && settledCenter && settledWidth && settledHeight && settledExpansion) {
        self.renderedThumbCenterX = targetCenterX;
        self.renderedThumbSize = targetSize;
        self.renderedExpansion = self.targetExpansion;
        [self stopThumbDisplayLink];
    }
}

- (void)refreshGlassSnapshotIfNeeded:(BOOL)force {
    if (!self.window) return;
    if (!force && self.glassThumbView.sourceImage) return;
    CFTimeInterval now = CACurrentMediaTime();
    if ((self.trackingActive || self.thumbDisplayLink) && self.lastSnapshotRefreshTimestamp > 0.0) {
        if ((now - self.lastSnapshotRefreshTimestamp) < kLGPrefsSliderTrackingSnapshotInterval) {
            return;
        }
    }
    UIView *captureView = self.superview ?: self;
    CGRect sliderRectInCapture = [self convertRect:self.bounds toView:captureView];
    CGRect captureRect = CGRectInset(sliderRectInCapture, -20.0, -20.0);
    NSValue *insetsValue = objc_getAssociatedObject(self, kLGPrefsSliderExtraCaptureInsetsKey);
    if (insetsValue) {
        UIEdgeInsets insets = [insetsValue UIEdgeInsetsValue];
        captureRect = UIEdgeInsetsInsetRect(captureRect, UIEdgeInsetsMake(-insets.top, -insets.left, -insets.bottom, -insets.right));
    }
    captureRect = CGRectIntersection(captureView.bounds, captureRect);
    CGPoint captureOriginInScreen = [captureView convertPoint:captureRect.origin toView:nil];
    CGRect trackRect = [self trackRectForBounds:self.bounds];
    CGRect trackRectInCapture = CGRectOffset(trackRect, CGRectGetMinX(sliderRectInCapture) - CGRectGetMinX(captureRect),
                                             CGRectGetMinY(sliderRectInCapture) - CGRectGetMinY(captureRect));
    CGFloat trackMinX = CGRectGetMinX(trackRectInCapture);
    CGFloat trackMaxX = CGRectGetMaxX(trackRectInCapture);
    CGFloat valueRange = self.maximumValue - self.minimumValue;
    CGFloat normalizedValue = valueRange > 0.0 ? ((self.value - self.minimumValue) / valueRange) : 0.0;
    normalizedValue = fmax(0.0, fmin(1.0, normalizedValue));
    CGFloat presentedCenterX = (self.hasRenderedThumbState ? self.renderedThumbCenterX : [self resolvedThumbCenterX]);
    CGFloat presentedFillEndX = presentedCenterX + CGRectGetMinX(sliderRectInCapture) - CGRectGetMinX(captureRect);
    CGFloat snapZone = fmin(34.0, CGRectGetWidth(trackRectInCapture) * 0.20);
    CGFloat fillEndX = presentedFillEndX;
    if (normalizedValue <= 0.0001) {
        fillEndX = trackMinX;
    } else if (normalizedValue >= 0.9999) {
        fillEndX = trackMaxX;
    } else if (presentedFillEndX < trackMinX + snapZone) {
        CGFloat t = fmax(0.0, fmin((presentedFillEndX - trackMinX) / snapZone, 1.0));
        CGFloat eased = t * t;
        fillEndX = trackMinX + (presentedFillEndX - trackMinX) * eased;
    } else if (presentedFillEndX > trackMaxX - snapZone) {
        CGFloat t = fmax(0.0, fmin((trackMaxX - presentedFillEndX) / snapZone, 1.0));
        CGFloat eased = t * t;
        fillEndX = trackMaxX - (trackMaxX - presentedFillEndX) * eased;
    }
    UIColor *backgroundColor = captureView.backgroundColor ?: (self.superview.backgroundColor ?: [UIColor systemBackgroundColor]);
    UIColor *trackColor = self.maximumTrackTintColor ?: LGSliderFallbackTrackColor();
    UIColor *fillColor = LGSliderEffectiveAccentColor(self);
    UIColor *sheenColor = LGSliderBackdropSheenColor(self.traitCollection);
    UIColor *glassLiftColor = LGSliderActiveGlassLiftColor(self.traitCollection);
    BOOL segmented = LGSliderUsesSegmentedMode(self);
    UIImage *snapshot = nil;
    BOOL wasHidden = self.hidden;
    CGFloat previousAlpha = self.alpha;
    if (segmented) {
        fillColor = UIColor.clearColor;
        fillEndX = CGRectGetMinX(trackRectInCapture);
        snapshot = LGRenderSliderBackdropImage(captureRect.size, backgroundColor, trackColor, fillColor, sheenColor, glassLiftColor,
                                               trackRectInCapture, fillEndX);
        CGRect segmentRegion = CGRectInset(trackRectInCapture, -14.0, -12.0);
        self.hidden = YES;
        self.alpha = 0.0;
        snapshot = LGCompositeSliderCaptureRegion(snapshot, captureView, captureRect, segmentRegion);
        self.hidden = wasHidden;
        self.alpha = previousAlpha;
        snapshot = LGApplySliderGlassLiftOverlay(snapshot, glassLiftColor, trackRectInCapture);
    } else {
        snapshot = LGRenderSliderBackdropImage(captureRect.size, backgroundColor, trackColor, fillColor, sheenColor, glassLiftColor,
                                               trackRectInCapture, fillEndX);
    }
    if ([objc_getAssociatedObject(self, kLGPrefsSliderUseLiveCaptureKey) boolValue]) {
        NSValue *labelRegionValue = objc_getAssociatedObject(self, kLGPrefsSliderLabelCaptureRegionKey);
        CGRect labelRegion = labelRegionValue ? [labelRegionValue CGRectValue] : CGRectZero;
        if (!CGRectIsEmpty(labelRegion)) {
            labelRegion = CGRectOffset(labelRegion,
                                       CGRectGetMinX(sliderRectInCapture) - CGRectGetMinX(captureRect),
                                       CGRectGetMinY(sliderRectInCapture) - CGRectGetMinY(captureRect));
        }
        self.hidden = YES;
        self.alpha = 0.0;
        snapshot = LGCompositeSliderCaptureRegion(snapshot, captureView, captureRect, labelRegion);
        self.hidden = wasHidden;
        self.alpha = previousAlpha;
        snapshot = LGApplySliderGlassLiftOverlayInRegion(snapshot, glassLiftColor, trackRectInCapture, labelRegion);
    }
    if (!snapshot) return;
    self.lastSnapshotRefreshTimestamp = now;
    self.glassThumbView.sourceOrigin = captureOriginInScreen;
    self.glassThumbView.sourceImage = snapshot;
    [self.glassThumbView scheduleDraw];
}

- (void)setThumbExpanded:(BOOL)expanded animated:(BOOL)animated {
    CGSize nextSize = expanded ? self.expandedThumbSize : self.contractedThumbSize;
    self.currentThumbSize = nextSize;
    self.targetThumbSize = nextSize;
    self.targetExpansion = expanded ? 1.0 : 0.0;
    if (expanded || self.hasRenderedThumbState) {
        [self startThumbDisplayLinkIfNeeded];
    }
    self.glassThumbView.cornerRadius = nextSize.height * 0.5;
    [self refreshGlassSnapshotIfNeeded:expanded];
    (void)animated;
    [self updateGlassThumbFrameAnimated:NO];
}

- (void)updateGlassThumbFrameAnimated:(BOOL)animated {
    [self ensureGlassThumbView];
    [self ensureContractedThumbView];
    if (!self.trackingActive && !self.thumbDisplayLink) {
        [self syncRenderedThumbStateImmediately];
    }
    CGRect frame = [self glassThumbFrameForCurrentValue];
    CGRect contractedFrame = CGRectInset(frame,
                                         (frame.size.width - self.contractedThumbSize.width) * 0.5,
                                         (frame.size.height - self.contractedThumbSize.height) * 0.5);
    self.glassThumbView.cornerRadius = CGRectGetHeight(frame) * 0.5;
    (void)animated;
    CGFloat expansion = fmax(0.0, fmin(self.renderedExpansion, 1.0));
    CGFloat visualExpansion = expansion * expansion * (3.0 - (2.0 * expansion));
    CGFloat contractedScale = 1.0 + (0.08 * visualExpansion);
    CGFloat glassScale = 0.92 + (0.08 * visualExpansion);
    CGFloat stretchExcess = fmax(0.0, frame.size.width - self.expandedThumbSize.width);
    CGFloat motionSquash = fmin(0.10, visualExpansion * 0.028 + stretchExcess * 0.0032);
    CGFloat glassScaleX = glassScale - motionSquash * 0.95;
    CGFloat glassScaleY = glassScale + motionSquash * 0.55;
    self.glassThumbView.frame = frame;
    self.contractedThumbView.frame = contractedFrame;
    self.glassThumbView.alpha = visualExpansion;
    self.contractedThumbView.alpha = 1.0 - visualExpansion;
    self.glassThumbView.transform = CGAffineTransformMakeScale(glassScaleX, glassScaleY);
    self.contractedThumbView.transform = CGAffineTransformMakeScale(contractedScale, contractedScale);
    self.contractedThumbView.layer.cornerRadius = CGRectGetHeight(contractedFrame) * 0.5;
    self.glassThumbView.shapeMaskImage = nil;
    self.glassThumbView.hidden = visualExpansion < 0.01;
    self.contractedThumbView.hidden = visualExpansion > 0.99;
    if (self.trackingActive || fabs(self.rubberBandOffset) > 0.001) {
        [self.glassThumbView updateOrigin];
    }
}

@end
