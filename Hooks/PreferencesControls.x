// massive monolith, will be split in later updates ig

#import "../LiquidAssPrefs/LGPrefsLiquidSlider.h"
#import "../LiquidAssPrefs/LGPrefsLiquidSwitch.h"
#import "../Shared/LGGlassRenderer.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGLiquidMotion.h"
#import "../Shared/LGPrefAccessors.h"
#import "../Shared/LGSharedSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <float.h>
#import <math.h>
#import <objc/runtime.h>

static void *kLGSettingsSwitchOverlayKey = &kLGSettingsSwitchOverlayKey;
static void *kLGSettingsSwitchOwnerOverlayKey = &kLGSettingsSwitchOwnerOverlayKey;
static void *kLGSettingsSwitchOwnerKey = &kLGSettingsSwitchOwnerKey;
static void *kLGSettingsSwitchVisualHostKey = &kLGSettingsSwitchVisualHostKey;
static void *kLGSettingsSwitchRelayoutPendingKey = &kLGSettingsSwitchRelayoutPendingKey;
static void *kLGSettingsSwitchOverlayInstalledKey = &kLGSettingsSwitchOverlayInstalledKey;
static void *kLGSettingsSwitchOwnerDrivenSyncKey = &kLGSettingsSwitchOwnerDrivenSyncKey;
static void *kLGSettingsSliderOverlayKey = &kLGSettingsSliderOverlayKey;
static void *kLGSettingsSliderOwnerOverlayKey = &kLGSettingsSliderOwnerOverlayKey;
static void *kLGSettingsSliderOwnerKey = &kLGSettingsSliderOwnerKey;
static void *kLGSettingsSliderVisualHostKey = &kLGSettingsSliderVisualHostKey;
static void *kLGSettingsSliderRelayoutPendingKey = &kLGSettingsSliderRelayoutPendingKey;
static void *kLGSettingsSliderOwnerDrivenSyncKey = &kLGSettingsSliderOwnerDrivenSyncKey;
static void *kLGSettingsSliderOriginalMinimumTrackTintKey = &kLGSettingsSliderOriginalMinimumTrackTintKey;
static void *kLGSettingsSegmentedGlassPillKey = &kLGSettingsSegmentedGlassPillKey;
static void *kLGSettingsSegmentedGlassTintKey = &kLGSettingsSegmentedGlassTintKey;
static void *kLGSettingsSegmentedGlassInsetShadowKey = &kLGSettingsSegmentedGlassInsetShadowKey;
static void *kLGSettingsSegmentedStockPillKey = &kLGSettingsSegmentedStockPillKey;
static void *kLGSettingsSegmentedGlassActiveKey = &kLGSettingsSegmentedGlassActiveKey;
static void *kLGSettingsSegmentedGlassTouchXKey = &kLGSettingsSegmentedGlassTouchXKey;
static void *kLGSettingsSegmentedGlassVelocityKey = &kLGSettingsSegmentedGlassVelocityKey;
static void *kLGSettingsSegmentedLastTouchXKey = &kLGSettingsSegmentedLastTouchXKey;
static void *kLGSettingsSegmentedLastTouchTimeKey = &kLGSettingsSegmentedLastTouchTimeKey;
static void *kLGSettingsSegmentedDisplayLinkKey = &kLGSettingsSegmentedDisplayLinkKey;
static void *kLGSettingsSegmentedDisplayLinkDriverKey = &kLGSettingsSegmentedDisplayLinkDriverKey;
static void *kLGSettingsSegmentedLastDisplayLinkTimestampKey = &kLGSettingsSegmentedLastDisplayLinkTimestampKey;
static void *kLGSettingsSegmentedObjectScaleKey = &kLGSettingsSegmentedObjectScaleKey;
static void *kLGSettingsSegmentedObjectScaleVelocityKey = &kLGSettingsSegmentedObjectScaleVelocityKey;
static void *kLGSettingsSegmentedScaleXKey = &kLGSettingsSegmentedScaleXKey;
static void *kLGSettingsSegmentedScaleXVelocityKey = &kLGSettingsSegmentedScaleXVelocityKey;
static void *kLGSettingsSegmentedScaleYKey = &kLGSettingsSegmentedScaleYKey;
static void *kLGSettingsSegmentedScaleYVelocityKey = &kLGSettingsSegmentedScaleYVelocityKey;
static void *kLGSettingsSegmentedReleasedKey = &kLGSettingsSegmentedReleasedKey;
static void *kLGSettingsSegmentedReleaseObjectScaleKey = &kLGSettingsSegmentedReleaseObjectScaleKey;
static void *kLGSettingsSegmentedReleaseFrameKey = &kLGSettingsSegmentedReleaseFrameKey;
static void *kLGSettingsSegmentedRenderedCenterXKey = &kLGSettingsSegmentedRenderedCenterXKey;
static void *kLGSettingsSegmentedRenderedWidthKey = &kLGSettingsSegmentedRenderedWidthKey;
static void *kLGSettingsSegmentedRenderedHeightKey = &kLGSettingsSegmentedRenderedHeightKey;
static void *kLGSettingsSegmentedHasRenderedStateKey = &kLGSettingsSegmentedHasRenderedStateKey;
static void *kLGSettingsSegmentedLastActiveStateKey = &kLGSettingsSegmentedLastActiveStateKey;
static void *kLGSettingsSegmentedDeactivateTokenKey = &kLGSettingsSegmentedDeactivateTokenKey;
static void *kLGSettingsSegmentedFadingOutKey = &kLGSettingsSegmentedFadingOutKey;
static void *kLGSettingsTopFadeViewKey = &kLGSettingsTopFadeViewKey;
static const CGFloat kLGSettingsSwitchTrailingInset = 8.0;

@interface UISegmentedControl (LGSettingsSegmentedGlass)
- (void)lg_startSettingsSegmentedDisplayLinkIfNeeded;
- (void)lg_stopSettingsSegmentedDisplayLink;
- (void)lg_handleSettingsSegmentedDisplayLink:(CADisplayLink *)link;
@end

@interface LGSettingsTopFadeView : UIView
@end

static BOOL LGSettingsIsDarkMode(UITraitCollection *traitCollection);
typedef struct {
    CGFloat pillAlpha;
    CGFloat sheenAlpha;
    CGFloat glassLiftAlpha;
    CGFloat tintAlpha;
    CGFloat borderAlpha;
    CGFloat insetShadowAlpha;
    CGFloat shadowOpacity;
    CGFloat shadowRadius;
    CGSize shadowOffset;
} LGSettingsSegmentedAppearance;
static LGSettingsSegmentedAppearance LGSettingsSegmentedAppearanceMake(UITraitCollection *traitCollection);
static UIColor *LGSettingsSegmentedAppearanceTintColor(LGSettingsSegmentedAppearance appearance);
static UIColor *LGSettingsSegmentedAppearanceBorderColor(LGSettingsSegmentedAppearance appearance);

@interface LGSettingsSegmentedInsetShadowView : UIView
@end

@implementation LGSettingsSegmentedInsetShadowView

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

@implementation LGSettingsTopFadeView {
    CAGradientLayer *_gradientLayer;
}

- (void)lg_updateGradientColors {
    UIColor *baseColor = [UIColor systemBackgroundColor];
    _gradientLayer.colors = @[
        (__bridge id)[baseColor colorWithAlphaComponent:0.98].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.55].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.0].CGColor
    ];
    _gradientLayer.locations = @[ @0.0, @0.45, @1.0 ];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _gradientLayer.endPoint = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:_gradientLayer];
    [self lg_updateGradientColors];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = self.bounds;
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

static BOOL LGIsPreferencesApp(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"];
}

static BOOL LGSettingsControlsEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO) && LG_prefBool(@"SettingsControls.Enabled", YES);
}

static BOOL LGSettingsShouldModifyCell(UIView *cell) {
    if ([cell isKindOfClass:%c(PSSegmentTableCell)]) return NO;
    if ([cell isKindOfClass:%c(PSSliderTableCell)]) return NO;
    return YES;
}

static void LGApplySettingsNavigationBarAppearance(UINavigationBar *navigationBar) {
    if (!navigationBar) return;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.shadowColor = UIColor.clearColor;
    navigationBar.standardAppearance = appearance;
    navigationBar.scrollEdgeAppearance = appearance;
    navigationBar.compactAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        navigationBar.compactScrollEdgeAppearance = appearance;
    }
}

static BOOL LGSettingsShouldInstallTopFadeForController(UIViewController *controller) {
    if (!controller) return NO;
    if (!controller.navigationController) return NO;
    if (!controller.isViewLoaded || !controller.view.window) return NO;
    if (controller.navigationController.navigationBarHidden) return NO;
    return YES;
}

static void LGUpdateSettingsTopFadeForController(UIViewController *controller) {
    if (!LGSettingsShouldInstallTopFadeForController(controller)) return;
    LGApplySettingsNavigationBarAppearance(controller.navigationController.navigationBar);
    LGSettingsTopFadeView *fadeView = objc_getAssociatedObject(controller, kLGSettingsTopFadeViewKey);
    if (!fadeView) {
        fadeView = [[LGSettingsTopFadeView alloc] initWithFrame:CGRectZero];
        fadeView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [controller.view addSubview:fadeView];
        objc_setAssociatedObject(controller, kLGSettingsTopFadeViewKey, fadeView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [controller.view bringSubviewToFront:fadeView];
    fadeView.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(controller.view.bounds), 100.0);
}

static void LGUpdateSettingsRoundedCellShape(UIView *view) {
    if (!view) return;
    CGFloat cornerRadius = view.layer.cornerRadius;
    if (fabs(cornerRadius - 10.0) > 0.25) return;
    CGFloat height = CGRectGetHeight(view.bounds);
    if (height <= 0.0) return;
    view.layer.cornerRadius = 27.0;
}

static void LGUpdateSettingsRoundedCellSubviews(UIView *root) {
    for (UIView *subview in root.subviews) {
        LGUpdateSettingsRoundedCellShape(subview);
        LGUpdateSettingsRoundedCellSubviews(subview);
    }
}

static void LGUpdateSettingsCellSeparatorInsets(UITableViewCell *cell) {
    if (!cell) return;
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    if ([cell respondsToSelector:@selector(setSeparatorInset:)]) {
        cell.separatorInset = inset;
    }
    if ([cell respondsToSelector:@selector(setLayoutMargins:)]) {
        cell.layoutMargins = inset;
    }
    if ([cell respondsToSelector:@selector(setPreservesSuperviewLayoutMargins:)]) {
        cell.preservesSuperviewLayoutMargins = NO;
    }
}

static void LGLogSettingsSegmentedControlViewTree(UIView *view, NSInteger depth) {
    if (!view || depth > 3) return;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    BOOL selected = NO;
    BOOL highlighted = NO;
    SEL selectedSelector = NSSelectorFromString(@"isSelected");
    SEL highlightedSelector = NSSelectorFromString(@"isHighlighted");
    if ([view respondsToSelector:selectedSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        selected = ((BOOL (*)(id, SEL))[view methodForSelector:selectedSelector])(view, selectedSelector);
#pragma clang diagnostic pop
    }
    if ([view respondsToSelector:highlightedSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        highlighted = ((BOOL (*)(id, SEL))[view methodForSelector:highlightedSelector])(view, highlightedSelector);
#pragma clang diagnostic pop
    }
    LGDebugLog(@"settings segmented view %@class=%@ frame=%@ bounds=%@ alpha=%.2f hidden=%d cr=%.2f bg=%@ subviews=%lu",
               indent,
               NSStringFromClass(view.class),
               NSStringFromCGRect(view.frame),
               NSStringFromCGRect(view.bounds),
               view.alpha,
               view.hidden,
               view.layer.cornerRadius,
               view.backgroundColor,
               (unsigned long)view.subviews.count);
    if (selected || highlighted || view.layer.sublayers.count > 0) {
        LGDebugLog(@"settings segmented meta %@selected=%d highlighted=%d sublayers=%lu",
                   indent,
                   selected,
                   highlighted,
                   (unsigned long)view.layer.sublayers.count);
    }
    for (UIView *subview in view.subviews) {
        LGLogSettingsSegmentedControlViewTree(subview, depth + 1);
    }
}

static void LGProbeSettingsSegmentedControl(UISegmentedControl *control, NSString *phase) {
    if (!control) return;
    BOOL hasLaidOutSegments = NO;
    for (UIView *subview in control.subviews) {
        if (CGRectGetWidth(subview.bounds) > 1.0 || CGRectGetWidth(subview.frame) > 1.0) {
            hasLaidOutSegments = YES;
            break;
        }
    }
    NSNumber *dumpedLaidOutTree = objc_getAssociatedObject(control, @selector(LGProbeSettingsSegmentedControl));
    BOOL shouldDumpTree = hasLaidOutSegments && !dumpedLaidOutTree.boolValue;
    if (shouldDumpTree) {
        objc_setAssociatedObject(control, @selector(LGProbeSettingsSegmentedControl), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSInteger i = 0; i < control.numberOfSegments; i++) {
        NSString *title = [control titleForSegmentAtIndex:i] ?: @"";
        UIImage *image = [control imageForSegmentAtIndex:i];
        [segments addObject:[NSString stringWithFormat:@"{%ld title=%@ image=%d enabled=%d width=%.1f}",
                             (long)i,
                             title,
                             image != nil,
                             [control isEnabledForSegmentAtIndex:i],
                             [control widthForSegmentAtIndex:i]]];
    }

    LGDebugLog(@"settings segmented control phase=%@ control=%p frame=%@ bounds=%@ selected=%ld count=%ld moments=%d tracking=%d highlighted=%d segments=%@",
               phase ?: @"?",
               control,
               NSStringFromCGRect(control.frame),
               NSStringFromCGRect(control.bounds),
               (long)control.selectedSegmentIndex,
               (long)control.numberOfSegments,
               control.momentary,
               control.tracking,
               control.highlighted,
               segments);

    if (shouldDumpTree) {
        LGLogSettingsSegmentedControlViewTree(control, 0);
    }
}

static UIImage *LGCaptureSettingsSegmentedBackdropImage(UIView *captureView, CGRect captureRect) {
    if (!captureView || CGRectIsEmpty(captureRect)) return nil;
    UIGraphicsBeginImageContextWithOptions(captureRect.size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
    [captureView.layer renderInContext:context];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *LGCompositeSettingsSegmentedCaptureRegion(UIImage *baseImage,
                                                          UIView *captureView,
                                                          CGRect captureRect,
                                                          CGRect regionRectInCapture) {
    if (!baseImage || !captureView || CGRectIsEmpty(captureRect) || CGRectIsEmpty(regionRectInCapture)) return baseImage;
    CGRect clippedRegion = CGRectIntersection(CGRectMake(0.0, 0.0, CGRectGetWidth(captureRect), CGRectGetHeight(captureRect)),
                                              regionRectInCapture);
    if (CGRectIsEmpty(clippedRegion)) return baseImage;

    CGRect regionRectInView = CGRectOffset(clippedRegion, CGRectGetMinX(captureRect), CGRectGetMinY(captureRect));
    UIImage *regionImage = LGCaptureSettingsSegmentedBackdropImage(captureView, regionRectInView);
    if (!regionImage) return baseImage;

    UIGraphicsBeginImageContextWithOptions(baseImage.size, NO, baseImage.scale);
    [baseImage drawAtPoint:CGPointZero];
    [regionImage drawInRect:clippedRegion];
    UIImage *composited = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composited ?: baseImage;
}

static UIImage *LGRenderSettingsSegmentedLightModeBackdropImage(CGSize size,
                                                                UIColor *backgroundColor,
                                                                CGRect localPillRect) {
    if (size.width <= 0.0 || size.height <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [backgroundColor setFill];
    CGContextFillRect(context, CGRectMake(0.0, 0.0, size.width, size.height));

    UIBezierPath *pillPath = [UIBezierPath bezierPathWithRoundedRect:localPillRect
                                                        cornerRadius:CGRectGetHeight(localPillRect) * 0.5];
    [[UIColor colorWithWhite:1.0 alpha:0.88] setFill];
    [pillPath fill];

    CGContextSaveGState(context);
    [pillPath addClip];
    CGRect sheenRect = CGRectMake(CGRectGetMinX(localPillRect),
                                  CGRectGetMinY(localPillRect),
                                  CGRectGetWidth(localPillRect),
                                  CGRectGetHeight(localPillRect) * 0.58);
    UIBezierPath *sheenPath = [UIBezierPath bezierPathWithRoundedRect:sheenRect
                                                         cornerRadius:CGRectGetHeight(localPillRect) * 0.5];
    [[UIColor colorWithWhite:1.0 alpha:0.12] setFill];
    [sheenPath fill];
    CGContextRestoreGState(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static NSArray<UIView *> *LGSettingsSegmentedSelectedSegmentViews(UISegmentedControl *control) {
    NSMutableArray<UIView *> *matches = [NSMutableArray array];
    Class segmentClass = NSClassFromString(@"UISegment");
    for (UIView *subview in control.subviews) {
        if (segmentClass && ![subview isKindOfClass:segmentClass]) continue;
        SEL selectedSelector = NSSelectorFromString(@"isSelected");
        if (![subview respondsToSelector:selectedSelector]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        BOOL selected = ((BOOL (*)(id, SEL))[subview methodForSelector:selectedSelector])(subview, selectedSelector);
#pragma clang diagnostic pop
        if (selected) [matches addObject:subview];
    }
    return matches;
}

static void LGSettingsCollectSegmentPayloadViews(UIView *root, NSMutableArray<UIView *> *matches) {
    if (!root) return;
    for (UIView *subview in root.subviews) {
        if (!subview.hidden && subview.alpha > 0.01) {
            if ([subview isKindOfClass:[UILabel class]]) {
                [matches addObject:subview];
            } else if ([subview isKindOfClass:[UIImageView class]] && ((UIImageView *)subview).image) {
                [matches addObject:subview];
            }
        }
        LGSettingsCollectSegmentPayloadViews(subview, matches);
    }
}

static CGFloat LGSettingsSegmentPayloadScore(UIView *payloadView, UIView *segment) {
    if (!payloadView || !segment) return -CGFLOAT_MAX;
    CGRect frameInSegment = [payloadView convertRect:payloadView.bounds toView:segment];
    CGRect visibleFrame = CGRectIntersection(segment.bounds, frameInSegment);
    if (CGRectIsEmpty(visibleFrame)) return -CGFLOAT_MAX;
    CGFloat area = CGRectGetWidth(visibleFrame) * CGRectGetHeight(visibleFrame);
    CGPoint visibleCenter = CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
    CGPoint segmentCenter = CGPointMake(CGRectGetMidX(segment.bounds), CGRectGetMidY(segment.bounds));
    CGFloat distancePenalty = hypot(visibleCenter.x - segmentCenter.x, visibleCenter.y - segmentCenter.y) * 8.0;
    return area - distancePenalty;
}

static UILabel *LGSettingsBestSegmentLabelView(UIView *segment) {
    NSMutableArray<UIView *> *payloadViews = [NSMutableArray array];
    LGSettingsCollectSegmentPayloadViews(segment, payloadViews);
    UILabel *bestLabel = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIView *payloadView in payloadViews) {
        if (![payloadView isKindOfClass:[UILabel class]]) continue;
        CGFloat score = LGSettingsSegmentPayloadScore(payloadView, segment);
        if (score > bestScore) {
            bestScore = score;
            bestLabel = (UILabel *)payloadView;
        }
    }
    return bestLabel;
}

static UIImageView *LGSettingsBestSegmentImageView(UIView *segment) {
    NSMutableArray<UIView *> *payloadViews = [NSMutableArray array];
    LGSettingsCollectSegmentPayloadViews(segment, payloadViews);
    UIImageView *bestImageView = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIView *payloadView in payloadViews) {
        if (![payloadView isKindOfClass:[UIImageView class]]) continue;
        CGFloat score = LGSettingsSegmentPayloadScore(payloadView, segment);
        if (score > bestScore) {
            bestScore = score;
            bestImageView = (UIImageView *)payloadView;
        }
    }
    return bestImageView;
}

static NSArray<UIView *> *LGSettingsSegmentedLightModeProxyContentViews(UIView *captureView,
                                                                        NSArray<UIView *> *selectedSegments) {
    NSMutableArray<UIView *> *proxies = [NSMutableArray array];
    for (UIView *segment in selectedSegments) {
        CGRect segmentFrameInCapture = [segment convertRect:segment.bounds toView:captureView];
        UILabel *bestLabel = LGSettingsBestSegmentLabelView(segment);
        if (bestLabel) {
            CGSize preferredSize = [bestLabel sizeThatFits:CGSizeMake(CGRectGetWidth(segmentFrameInCapture), CGFLOAT_MAX)];
            if (preferredSize.width <= 0.0 || preferredSize.height <= 0.0) {
                preferredSize = [bestLabel convertRect:bestLabel.bounds toView:captureView].size;
            }
            CGRect centeredFrame = CGRectMake(CGRectGetMidX(segmentFrameInCapture) - preferredSize.width * 0.5,
                                              CGRectGetMidY(segmentFrameInCapture) - preferredSize.height * 0.5,
                                              preferredSize.width,
                                              preferredSize.height);
            UILabel *proxy = [[UILabel alloc] initWithFrame:CGRectIntegral(centeredFrame)];
            proxy.text = bestLabel.text;
            proxy.attributedText = bestLabel.attributedText;
            proxy.font = bestLabel.font;
            proxy.textColor = bestLabel.textColor;
            proxy.textAlignment = bestLabel.textAlignment;
            proxy.numberOfLines = bestLabel.numberOfLines;
            proxy.lineBreakMode = bestLabel.lineBreakMode;
            proxy.adjustsFontSizeToFitWidth = bestLabel.adjustsFontSizeToFitWidth;
            proxy.minimumScaleFactor = bestLabel.minimumScaleFactor;
            proxy.backgroundColor = UIColor.clearColor;
            proxy.opaque = NO;
            proxy.userInteractionEnabled = NO;
            [captureView addSubview:proxy];
            [proxies addObject:proxy];
        }

        UIImageView *bestImageView = LGSettingsBestSegmentImageView(segment);
        if (bestImageView && bestImageView.image) {
            CGSize imageSize = bestImageView.image.size;
            CGFloat scale = 1.0;
            if (imageSize.width > CGRectGetWidth(segmentFrameInCapture) && imageSize.width > 0.0) {
                scale = CGRectGetWidth(segmentFrameInCapture) / imageSize.width;
            }
            if (imageSize.height * scale > CGRectGetHeight(segmentFrameInCapture) && imageSize.height > 0.0) {
                scale = CGRectGetHeight(segmentFrameInCapture) / imageSize.height;
            }
            CGSize fittedSize = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
            CGRect centeredFrame = CGRectMake(CGRectGetMidX(segmentFrameInCapture) - fittedSize.width * 0.5,
                                              CGRectGetMidY(segmentFrameInCapture) - fittedSize.height * 0.5,
                                              fittedSize.width,
                                              fittedSize.height);
            UIImageView *proxy = [[UIImageView alloc] initWithFrame:CGRectIntegral(centeredFrame)];
            proxy.image = bestImageView.image;
            proxy.contentMode = bestImageView.contentMode;
            proxy.tintColor = bestImageView.tintColor;
            proxy.userInteractionEnabled = NO;
            [captureView addSubview:proxy];
            [proxies addObject:proxy];
        }
    }
    return proxies;
}

static UIImageView *LGFindSettingsSegmentedStockPill(UISegmentedControl *control) {
    UIImageView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIView *subview in control.subviews) {
        if (![subview isKindOfClass:[UIImageView class]]) continue;
        if (subview.subviews.count != 0) continue;
        CGRect frame = subview.frame;
        if (CGRectGetWidth(frame) < 20.0 || CGRectGetHeight(frame) < CGRectGetHeight(control.bounds) + 4.0) continue;
        CGFloat score = CGRectGetWidth(frame);
        if (CGRectGetMinY(frame) < 0.0) score += 20.0;
        if (CGRectGetHeight(frame) > CGRectGetHeight(control.bounds)) score += 10.0;
        if (score > bestScore) {
            bestScore = score;
            best = (UIImageView *)subview;
        }
    }
    return best;
}

static UIImageView *LGSettingsSegmentedStockPill(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedStockPillKey);
}

static LGSharedGlassView *LGSettingsSegmentedGlassPill(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedGlassPillKey);
}

static UIView *LGSettingsSegmentedGlassTint(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedGlassTintKey);
}

static LGSettingsSegmentedInsetShadowView *LGSettingsSegmentedGlassInsetShadow(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedGlassInsetShadowKey);
}

static void LGSetSettingsSegmentedGlassPill(UISegmentedControl *control, LGSharedGlassView *glass) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedGlassPillKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSetSettingsSegmentedGlassTint(UISegmentedControl *control, UIView *tint) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedGlassTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSetSettingsSegmentedGlassInsetShadow(UISegmentedControl *control, LGSettingsSegmentedInsetShadowView *insetShadow) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedGlassInsetShadowKey, insetShadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSetSettingsSegmentedStockPill(UISegmentedControl *control, UIImageView *pill) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedStockPillKey, pill, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL LGSettingsSegmentedGlassActive(UISegmentedControl *control) {
    return [objc_getAssociatedObject(control, kLGSettingsSegmentedGlassActiveKey) boolValue];
}

static void LGSetSettingsSegmentedGlassActive(UISegmentedControl *control, BOOL active) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedGlassActiveKey, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat LGSettingsSegmentedGlassTouchX(UISegmentedControl *control) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedGlassTouchXKey);
    return value ? value.doubleValue : NAN;
}

static void LGSetSettingsSegmentedGlassTouchX(UISegmentedControl *control, CGFloat x) {
    if (isnan(x)) {
        objc_setAssociatedObject(control, kLGSettingsSegmentedGlassTouchXKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(control, kLGSettingsSegmentedGlassTouchXKey, @(x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static CGFloat LGSettingsSegmentedGlassVelocity(UISegmentedControl *control) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedGlassVelocityKey);
    return value ? value.doubleValue : 0.0;
}

static void LGSetSettingsSegmentedGlassVelocity(UISegmentedControl *control, CGFloat velocity) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedGlassVelocityKey, @(velocity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat LGSettingsSegmentedTargetCenterX(UISegmentedControl *control) {
    UIImageView *stockPill = LGSettingsSegmentedStockPill(control);
    if (!stockPill || stockPill.superview != control) {
        stockPill = LGFindSettingsSegmentedStockPill(control);
        LGSetSettingsSegmentedStockPill(control, stockPill);
    }
    return stockPill ? CGRectGetMidX(stockPill.frame) : CGRectGetMidX(control.bounds);
}

static CGFloat LGSettingsSegmentedSpringValue(UISegmentedControl *control, const void *key, CGFloat fallback) {
    NSNumber *value = objc_getAssociatedObject(control, key);
    return value ? value.doubleValue : fallback;
}

static void LGSetSettingsSegmentedSpringValue(UISegmentedControl *control, const void *key, CGFloat value) {
    objc_setAssociatedObject(control, key, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CADisplayLink *LGSettingsSegmentedDisplayLink(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedDisplayLinkKey);
}

static void LGSetSettingsSegmentedDisplayLink(UISegmentedControl *control, CADisplayLink *link) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id LGSettingsSegmentedDisplayLinkDriver(UISegmentedControl *control) {
    return objc_getAssociatedObject(control, kLGSettingsSegmentedDisplayLinkDriverKey);
}

static void LGSetSettingsSegmentedDisplayLinkDriver(UISegmentedControl *control, id driver) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedDisplayLinkDriverKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat LGSettingsSegmentedObjectScale(UISegmentedControl *control) {
    return LGSettingsSegmentedSpringValue(control, kLGSettingsSegmentedObjectScaleKey, 1.0);
}

static BOOL LGSettingsSegmentedReleased(UISegmentedControl *control) {
    return [objc_getAssociatedObject(control, kLGSettingsSegmentedReleasedKey) boolValue];
}

static void LGSetSettingsSegmentedReleased(UISegmentedControl *control, BOOL released) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedReleasedKey, @(released), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSetSettingsSegmentedReleaseObjectScale(UISegmentedControl *control, CGFloat scale) {
    if (isnan(scale)) {
        objc_setAssociatedObject(control, kLGSettingsSegmentedReleaseObjectScaleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(control, kLGSettingsSegmentedReleaseObjectScaleKey, @(scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static CGRect LGSettingsSegmentedReleaseFrame(UISegmentedControl *control) {
    NSValue *value = objc_getAssociatedObject(control, kLGSettingsSegmentedReleaseFrameKey);
    return value ? value.CGRectValue : CGRectNull;
}

static void LGSetSettingsSegmentedReleaseFrame(UISegmentedControl *control, CGRect frame) {
    if (CGRectIsNull(frame)) {
        objc_setAssociatedObject(control, kLGSettingsSegmentedReleaseFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(control, kLGSettingsSegmentedReleaseFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL LGSettingsSegmentedHasRenderedState(UISegmentedControl *control) {
    return [objc_getAssociatedObject(control, kLGSettingsSegmentedHasRenderedStateKey) boolValue];
}

static void LGSetSettingsSegmentedHasRenderedState(UISegmentedControl *control, BOOL hasState) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedHasRenderedStateKey, @(hasState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat LGSettingsSegmentedRenderedCenterX(UISegmentedControl *control, CGFloat fallback) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedRenderedCenterXKey);
    return value ? value.doubleValue : fallback;
}

static CGFloat LGSettingsSegmentedRenderedWidth(UISegmentedControl *control, CGFloat fallback) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedRenderedWidthKey);
    return value ? value.doubleValue : fallback;
}

static CGFloat LGSettingsSegmentedRenderedHeight(UISegmentedControl *control, CGFloat fallback) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedRenderedHeightKey);
    return value ? value.doubleValue : fallback;
}

static void LGSetSettingsSegmentedRenderedFrameState(UISegmentedControl *control, CGRect frame) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedRenderedCenterXKey, @(CGRectGetMidX(frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(control, kLGSettingsSegmentedRenderedWidthKey, @(CGRectGetWidth(frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(control, kLGSettingsSegmentedRenderedHeightKey, @(CGRectGetHeight(frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGSetSettingsSegmentedHasRenderedState(control, YES);
}

static CGRect LGSettingsSegmentedRenderedFrame(UISegmentedControl *control, CGRect fallbackFrame) {
    if (!LGSettingsSegmentedHasRenderedState(control)) return fallbackFrame;
    CGFloat centerX = LGSettingsSegmentedRenderedCenterX(control, CGRectGetMidX(fallbackFrame));
    CGFloat width = LGSettingsSegmentedRenderedWidth(control, CGRectGetWidth(fallbackFrame));
    CGFloat height = LGSettingsSegmentedRenderedHeight(control, CGRectGetHeight(fallbackFrame));
    return CGRectMake(centerX - width * 0.5,
                      CGRectGetMidY(fallbackFrame) - height * 0.5,
                      width,
                      height);
}

static BOOL LGSettingsSegmentedLastActiveState(UISegmentedControl *control) {
    return [objc_getAssociatedObject(control, kLGSettingsSegmentedLastActiveStateKey) boolValue];
}

static void LGSetSettingsSegmentedLastActiveState(UISegmentedControl *control, BOOL active) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedLastActiveStateKey, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LGSettingsSegmentedFadingOut(UISegmentedControl *control) {
    return [objc_getAssociatedObject(control, kLGSettingsSegmentedFadingOutKey) boolValue];
}

static void LGSetSettingsSegmentedFadingOut(UISegmentedControl *control, BOOL fadingOut) {
    objc_setAssociatedObject(control, kLGSettingsSegmentedFadingOutKey, @(fadingOut), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSInteger LGSettingsSegmentedDeactivateToken(UISegmentedControl *control) {
    NSNumber *value = objc_getAssociatedObject(control, kLGSettingsSegmentedDeactivateTokenKey);
    return value ? value.integerValue : 0;
}

static NSInteger LGAdvanceSettingsSegmentedDeactivateToken(UISegmentedControl *control) {
    NSInteger token = LGSettingsSegmentedDeactivateToken(control) + 1;
    objc_setAssociatedObject(control, kLGSettingsSegmentedDeactivateTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return token;
}

static void LGApplySettingsSegmentedAppearanceToOverlay(LGSettingsSegmentedAppearance appearance,
                                                        LGSharedGlassView *glass,
                                                        UIView *tint,
                                                        LGSettingsSegmentedInsetShadowView *insetShadow) {
    if (!glass || !tint || !insetShadow) return;
    glass.layer.shadowOpacity = appearance.shadowOpacity;
    glass.layer.shadowRadius = appearance.shadowRadius;
    glass.layer.shadowOffset = appearance.shadowOffset;
    tint.backgroundColor = LGSettingsSegmentedAppearanceTintColor(appearance);
    tint.layer.borderColor = LGSettingsSegmentedAppearanceBorderColor(appearance).CGColor;
    insetShadow.alpha = appearance.insetShadowAlpha;
}

static void LGRefreshSettingsSegmentedGlassBackdrop(UISegmentedControl *control, LGSharedGlassView *glass, CGRect pillFrame) {
    UIView *captureView = control.superview ?: control;
    if (!captureView || CGRectIsEmpty(pillFrame)) return;

    BOOL oldGlassHidden = glass.hidden;
    CGFloat oldGlassAlpha = glass.alpha;
    UIImageView *stockPill = LGSettingsSegmentedStockPill(control);
    BOOL oldStockHidden = stockPill.hidden;
    CGFloat oldStockAlpha = stockPill.alpha;
    BOOL lightMode = !LGSettingsIsDarkMode(control.traitCollection);
    NSArray<UIView *> *selectedSegments = nil;
    NSMutableArray<NSNumber *> *selectedSegmentAlphas = nil;
    NSArray<UIView *> *proxyContentViews = nil;

    glass.hidden = YES;
    glass.alpha = 0.0;
    stockPill.hidden = YES;
    stockPill.alpha = 0.0;
    if (lightMode) {
        selectedSegments = LGSettingsSegmentedSelectedSegmentViews(control);
        selectedSegmentAlphas = [NSMutableArray arrayWithCapacity:selectedSegments.count];
        for (UIView *segment in selectedSegments) {
            [selectedSegmentAlphas addObject:@(segment.alpha)];
            segment.alpha = 0.0;
        }
        proxyContentViews = LGSettingsSegmentedLightModeProxyContentViews(captureView, selectedSegments);
    }

    CGRect pillRectInCapture = [control convertRect:pillFrame toView:captureView];
    CGRect captureRect = CGRectInset(pillRectInCapture, -18.0, -18.0);
    captureRect = CGRectIntersection(captureView.bounds, captureRect);
    UIImage *snapshot = nil;
    if (lightMode) {
        CGRect localPillRect = CGRectOffset(pillRectInCapture, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
        UIColor *backgroundColor = captureView.backgroundColor ?: (control.superview.backgroundColor ?: UIColor.systemBackgroundColor);
        snapshot = LGRenderSettingsSegmentedLightModeBackdropImage(captureRect.size, backgroundColor, localPillRect);
        CGRect liveCompositeRect = CGRectInset(localPillRect, -6.0, -4.0);
        snapshot = LGCompositeSettingsSegmentedCaptureRegion(snapshot, captureView, captureRect, liveCompositeRect);
    } else {
        snapshot = LGCaptureSettingsSegmentedBackdropImage(captureView, captureRect);
    }
    CGPoint captureOriginInScreen = [captureView convertPoint:captureRect.origin toView:nil];

    glass.hidden = oldGlassHidden;
    glass.alpha = oldGlassAlpha;
    stockPill.hidden = oldStockHidden;
    stockPill.alpha = oldStockAlpha;
    for (NSUInteger idx = 0; idx < selectedSegments.count; idx++) {
        selectedSegments[idx].alpha = selectedSegmentAlphas[idx].doubleValue;
    }
    for (UIView *proxy in proxyContentViews) {
        [proxy removeFromSuperview];
    }

    glass.sourceImage = snapshot;
    glass.sourceOrigin = captureOriginInScreen;
}

static void LGSetSettingsSegmentedGlassFrame(LGSharedGlassView *glass, UIView *tint, CGRect frame, BOOL animated) {
    if (!glass || !tint) return;
    void (^updates)(void) = ^{
        glass.frame = frame;
        glass.cornerRadius = CGRectGetHeight(frame) * 0.5;
        tint.frame = glass.bounds;
        tint.layer.cornerRadius = CGRectGetHeight(tint.bounds) * 0.5;
        tint.layer.cornerCurve = kCACornerCurveContinuous;
    };
    if (!animated || glass.hidden || glass.alpha < 0.01) {
        [UIView performWithoutAnimation:updates];
        return;
    }
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:updates
                     completion:nil];
}

static CGRect LGSettingsSegmentedGlassDragFrame(UISegmentedControl *control, CGRect stockPillFrame) {
    CGFloat touchX = LGSettingsSegmentedGlassTouchX(control);
    if (isnan(touchX)) return stockPillFrame;
    CGRect releaseFrame = LGSettingsSegmentedReleaseFrame(control);
    BOOL released = LGSettingsSegmentedReleased(control) && !CGRectIsNull(releaseFrame);
    CGRect baseFrame = released ? releaseFrame : stockPillFrame;
    CGFloat minCenterX = CGRectGetWidth(baseFrame) * 0.5 - 3.0;
    CGFloat maxCenterX = CGRectGetWidth(control.bounds) - CGRectGetWidth(baseFrame) * 0.5 + 3.0;
    CGFloat centerX = touchX;
    CGFloat width = CGRectGetWidth(baseFrame);
    CGFloat height = CGRectGetHeight(baseFrame);
    if (!released) {
        LGLiquidDragState dragState = LGLiquidDragStateMake(touchX,
                                                            minCenterX,
                                                            maxCenterX,
                                                            baseFrame.size,
                                                            LGSettingsSegmentedGlassVelocity(control),
                                                            33.0);
        centerX = dragState.centerX;
        width = dragState.width;
        height = dragState.height;
    } else {
        centerX = LGLiquidRubberBandedCenterX(touchX, minCenterX, maxCenterX, 1.24);
    }
    CGFloat minX = -3.0;
    CGFloat maxX = CGRectGetWidth(control.bounds) - width + 3.0;
    CGFloat originX = centerX - width * 0.5;
    if (LGLiquidOvershootDistance(touchX, minCenterX, maxCenterX) <= 0.001) {
        originX = fmax(minX, fmin(originX, maxX));
    }
    return CGRectMake(originX,
                      CGRectGetMidY(baseFrame) - height * 0.5,
                      width,
                      height);
}

static UIView *LGSettingsSegmentedOverlayContainer(UISegmentedControl *control) {
    UIView *start = control.superview ?: control;
    UIView *best = start;
    for (UIView *candidate = start; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIScrollView class]]) break;
        best = candidate;
    }
    return best ?: start;
}

static void LGAllowSettingsSegmentedOverflowFromContainer(UIView *container) {
    for (UIView *candidate = container; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIScrollView class]]) break;
        candidate.clipsToBounds = NO;
        candidate.layer.masksToBounds = NO;
    }
}

static void LGBringSettingsSegmentedLabelsToFront(UISegmentedControl *control, UIView *glass, UIView *tint) {
    Class segmentClass = NSClassFromString(@"UISegment");
    BOOL active = LGSettingsSegmentedGlassActive(control);
    if (glass.superview) {
        [glass.superview bringSubviewToFront:glass];
    }
    if (tint.superview == glass) {
        [glass bringSubviewToFront:tint];
    }
    if (!active) {
        for (UIView *subview in control.subviews) {
            if (segmentClass && [subview isKindOfClass:segmentClass]) {
                [control bringSubviewToFront:subview];
            }
        }
    }
}

static BOOL LGSettingsIsDarkMode(UITraitCollection *traitCollection) {
    if (@available(iOS 12.0, *)) {
        return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static LGSettingsSegmentedAppearance LGSettingsSegmentedAppearanceMake(UITraitCollection *traitCollection) {
    BOOL darkMode = LGSettingsIsDarkMode(traitCollection);
    if (darkMode) {
        return (LGSettingsSegmentedAppearance){
            .pillAlpha = 0.045,
            .sheenAlpha = 0.045,
            .glassLiftAlpha = 0.055,
            .tintAlpha = 0.06,
            .borderAlpha = 0.10,
            .insetShadowAlpha = 0.68,
            .shadowOpacity = 0.10,
            .shadowRadius = 4.0,
            .shadowOffset = {0.0, 1.0},
        };
    }
    return (LGSettingsSegmentedAppearance){
        .pillAlpha = 0.88,
        .sheenAlpha = 0.12,
        .glassLiftAlpha = 0.18,
        .tintAlpha = 0.095,
        .borderAlpha = 0.12,
        .insetShadowAlpha = 1.0,
        .shadowOpacity = 0.08,
        .shadowRadius = 4.0,
        .shadowOffset = {0.0, 1.0},
    };
}

static UIColor *LGSettingsSegmentedAppearanceTintColor(LGSettingsSegmentedAppearance appearance) {
    return [UIColor colorWithWhite:1.0 alpha:appearance.tintAlpha];
}

static UIColor *LGSettingsSegmentedAppearanceBorderColor(LGSettingsSegmentedAppearance appearance) {
    return [UIColor colorWithWhite:1.0 alpha:appearance.borderAlpha];
}

static void LGUpdateSettingsSegmentedControlVisuals(UISegmentedControl *control) {
    if (!control) return;
    UIImageView *stockPill = LGSettingsSegmentedStockPill(control);
    if (!stockPill || stockPill.superview != control) {
        stockPill = LGFindSettingsSegmentedStockPill(control);
    }
    if (!stockPill || stockPill.superview != control) return;

    LGSetSettingsSegmentedStockPill(control, stockPill);
    stockPill.userInteractionEnabled = NO;

    LGSharedGlassView *glass = LGSettingsSegmentedGlassPill(control);
    UIView *tint = LGSettingsSegmentedGlassTint(control);
    LGSettingsSegmentedInsetShadowView *insetShadow = LGSettingsSegmentedGlassInsetShadow(control);
    UIView *container = LGSettingsSegmentedOverlayContainer(control);
    if (!glass) {
        LGEnsureSharedGlassPipelinesReady();
        glass = [[LGSharedGlassView alloc] initWithFrame:CGRectZero sourceImage:nil sourceOrigin:CGPointZero];
        glass.userInteractionEnabled = NO;
        glass.releasesSourceAfterUpload = YES;
        glass.blur = 0.0;
        glass.sourceScale = 1.0;
        glass.layer.shadowColor = UIColor.blackColor.CGColor;
        [container addSubview:glass];
        LGSetSettingsSegmentedGlassPill(control, glass);

        tint = [[UIView alloc] initWithFrame:CGRectZero];
        tint.userInteractionEnabled = NO;
        tint.backgroundColor = UIColor.clearColor;
        tint.layer.borderWidth = 0.75;
        tint.layer.borderColor = UIColor.clearColor.CGColor;
        [glass addSubview:tint];
        LGSetSettingsSegmentedGlassTint(control, tint);

        insetShadow = [[LGSettingsSegmentedInsetShadowView alloc] initWithFrame:glass.bounds];
        insetShadow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        insetShadow.alpha = 1.0;
        [glass addSubview:insetShadow];
        LGSetSettingsSegmentedGlassInsetShadow(control, insetShadow);
    }
    if (glass.superview != container) {
        [glass removeFromSuperview];
        [container addSubview:glass];
    }
    LGAllowSettingsSegmentedOverflowFromContainer(container);

    LGSettingsSegmentedAppearance appearance = LGSettingsSegmentedAppearanceMake(control.traitCollection);
    glass.bezelWidth = 20.0;
    glass.refractionScale = 1.5;
    glass.refractiveIndex = 3.0;
    glass.specularOpacity = 0.6;
    LGApplySettingsSegmentedAppearanceToOverlay(appearance, glass, tint, insetShadow);

    control.clipsToBounds = NO;
    control.layer.cornerRadius = 17.0;

    CGRect pillFrame = stockPill.frame;
    CGRect baseGlassFrame = [control convertRect:pillFrame toView:container];
    if (glass.hidden && glass.alpha < 0.01) {
        glass.frame = baseGlassFrame;
        glass.cornerRadius = CGRectGetHeight(baseGlassFrame) * 0.5;
        tint.frame = glass.bounds;
        tint.layer.cornerRadius = CGRectGetHeight(tint.bounds) * 0.5;
        tint.layer.cornerCurve = kCACornerCurveContinuous;
    }

    BOOL active = LGSettingsSegmentedGlassActive(control);
    BOOL wasActive = LGSettingsSegmentedLastActiveState(control);
    BOOL fadingOut = LGSettingsSegmentedFadingOut(control);
    BOOL hasLiveTouch = !isnan(LGSettingsSegmentedGlassTouchX(control));

    if (active) {
        CGRect localGlassFrame = LGSettingsSegmentedGlassDragFrame(control, pillFrame);
        CGRect renderedLocalFrame = LGSettingsSegmentedRenderedFrame(control, localGlassFrame);
        CGRect glassFrame = [control convertRect:renderedLocalFrame toView:container];
        glass.hidden = NO;
        glass.transform = CGAffineTransformIdentity;
        if (!wasActive) {
            LGSetSettingsSegmentedFadingOut(control, NO);
            [glass.layer removeAllAnimations];
            [UIView performWithoutAnimation:^{
                glass.frame = baseGlassFrame;
                glass.cornerRadius = CGRectGetHeight(baseGlassFrame) * 0.5;
                tint.frame = glass.bounds;
                tint.layer.cornerRadius = CGRectGetHeight(tint.bounds) * 0.5;
                tint.layer.cornerCurve = kCACornerCurveContinuous;
                glass.alpha = 0.0;
            }];
            stockPill.hidden = NO;
            stockPill.alpha = 1.0;
            [UIView animateWithDuration:0.14
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                                 stockPill.alpha = 0.0;
                                 glass.alpha = 1.0;
                             }
                             completion:^(__unused BOOL finished) {
                                 if (LGSettingsSegmentedGlassActive(control)) {
                                     stockPill.hidden = YES;
                                     stockPill.alpha = 0.0;
                                 }
                             }];
        } else {
            stockPill.hidden = YES;
            stockPill.alpha = 0.0;
            glass.alpha = 1.0;
        }
        LGSetSettingsSegmentedGlassFrame(glass, tint, glassFrame, !hasLiveTouch);
        LGRefreshSettingsSegmentedGlassBackdrop(control, glass, renderedLocalFrame);
    } else if (wasActive) {
        LGSetSettingsSegmentedFadingOut(control, YES);
        [glass.layer removeAllAnimations];
        glass.hidden = NO;
        glass.transform = CGAffineTransformIdentity;
        glass.alpha = 1.0;
        stockPill.hidden = NO;
        stockPill.alpha = 0.0;
        [UIView animateWithDuration:0.12
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             glass.frame = baseGlassFrame;
                             glass.cornerRadius = CGRectGetHeight(baseGlassFrame) * 0.5;
                             tint.frame = glass.bounds;
                             tint.layer.cornerRadius = CGRectGetHeight(tint.bounds) * 0.5;
                             tint.layer.cornerCurve = kCACornerCurveContinuous;
                             stockPill.alpha = 1.0;
                             glass.alpha = 0.0;
                         }
                         completion:^(__unused BOOL finished) {
                             if (!LGSettingsSegmentedGlassActive(control)) {
                                 LGSetSettingsSegmentedFadingOut(control, NO);
                                 stockPill.hidden = NO;
                                 stockPill.alpha = 1.0;
                                 glass.hidden = YES;
                                 glass.alpha = 0.0;
                                 glass.transform = CGAffineTransformIdentity;
                             }
                         }];
    } else if (fadingOut) {
        stockPill.hidden = NO;
    } else {
        stockPill.hidden = NO;
        stockPill.alpha = 1.0;
        glass.hidden = YES;
        glass.alpha = 0.0;
        glass.transform = CGAffineTransformIdentity;
    }

    LGSetSettingsSegmentedLastActiveState(control, active);
    LGBringSettingsSegmentedLabelsToFront(control, glass, tint);
    if (!hasLiveTouch) {
        LGDebugLog(@"settings segmented glass control=%p active=%d stockPill=%@ glassFrame=%@ selected=%ld tracking=%d touchX=%.2f",
                   control,
                   active,
                   NSStringFromCGRect(stockPill.frame),
                   NSStringFromCGRect(glass.frame),
                   (long)control.selectedSegmentIndex,
                   control.tracking,
                   LGSettingsSegmentedGlassTouchX(control));
    }
}

static id LGCellSpecifier(id cell) {
    if (!cell) return nil;
    SEL selector = NSSelectorFromString(@"specifier");
    if ([cell respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id specifier = [cell performSelector:selector];
#pragma clang diagnostic pop
        if (specifier) return specifier;
    }
    @try {
        return [cell valueForKey:@"specifier"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL LGSpecifierBoolProperty(id specifier, NSString *key) {
    if (!specifier || !key.length) return NO;
    id value = nil;
    @try {
        value = [specifier propertyForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value ? [value boolValue] : NO;
}

static NSInteger LGSpecifierIntegerProperty(id specifier, NSString *key) {
    if (!specifier || !key.length) return 0;
    id value = nil;
    @try {
        value = [specifier propertyForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value ? [value integerValue] : 0;
}

static NSInteger LGSettingsSliderResolvedSegmentCount(UISlider *owner, id specifier) {
    NSInteger segmentCount = LGSpecifierIntegerProperty(specifier, @"segmentCount");
    if (segmentCount > 0) return segmentCount;
    float range = owner.maximumValue - owner.minimumValue;
    float roundedRange = roundf(range);
    if (fabsf(range - roundedRange) <= 0.001f && roundedRange >= 1.0f && roundedRange <= 24.0f) {
        return (NSInteger)roundedRange;
    }
    return 0;
}

static UISlider *LGSliderOwnerForVisualElement(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UISlider class]]) {
            return (UISlider *)candidate;
        }
    }
    return nil;
}

static id LGOwnerSpecifierForView(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        id specifier = LGCellSpecifier(candidate);
        if (specifier) return specifier;
    }
    return nil;
}

static UISwitch *LGSwitchOwnerForVisualElement(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UISwitch class]]) {
            return (UISwitch *)candidate;
        }
    }
    return nil;
}

static BOOL LGViewIsInsideLiquidSwitch(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[LGPrefsLiquidSwitch class]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL LGViewIsInsideLiquidSlider(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[LGPrefsLiquidSlider class]]) {
            return YES;
        }
    }
    return NO;
}

static LGPrefsLiquidSwitch *LGSettingsSwitchOverlay(UIView *view) {
    return objc_getAssociatedObject(view, kLGSettingsSwitchOverlayKey);
}

static void LGSetSettingsSwitchOverlay(UIView *view, LGPrefsLiquidSwitch *overlay) {
    objc_setAssociatedObject(view, kLGSettingsSwitchOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static LGPrefsLiquidSwitch *LGSettingsSwitchOwnerOverlay(UISwitch *owner) {
    return objc_getAssociatedObject(owner, kLGSettingsSwitchOwnerOverlayKey);
}

static void LGSetSettingsSwitchOwnerOverlay(UISwitch *owner, LGPrefsLiquidSwitch *overlay) {
    objc_setAssociatedObject(owner, kLGSettingsSwitchOwnerOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *LGSettingsSwitchVisualHost(UISwitch *owner) {
    return objc_getAssociatedObject(owner, kLGSettingsSwitchVisualHostKey);
}

static void LGSetSettingsSwitchVisualHost(UISwitch *owner, UIView *host) {
    objc_setAssociatedObject(owner, kLGSettingsSwitchVisualHostKey, host, OBJC_ASSOCIATION_ASSIGN);
}

static UISwitch *LGSettingsSwitchOverlayOwner(LGPrefsLiquidSwitch *overlay) {
    return objc_getAssociatedObject(overlay, kLGSettingsSwitchOwnerKey);
}

static void LGSetSettingsSwitchOverlayOwner(LGPrefsLiquidSwitch *overlay, UISwitch *owner) {
    objc_setAssociatedObject(overlay, kLGSettingsSwitchOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
}

static LGPrefsLiquidSlider *LGSettingsSliderOverlay(UIView *view) {
    return objc_getAssociatedObject(view, kLGSettingsSliderOverlayKey);
}

static void LGSetSettingsSliderOverlay(UIView *view, LGPrefsLiquidSlider *overlay) {
    objc_setAssociatedObject(view, kLGSettingsSliderOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static LGPrefsLiquidSlider *LGSettingsSliderOwnerOverlay(UISlider *owner) {
    return objc_getAssociatedObject(owner, kLGSettingsSliderOwnerOverlayKey);
}

static void LGSetSettingsSliderOwnerOverlay(UISlider *owner, LGPrefsLiquidSlider *overlay) {
    objc_setAssociatedObject(owner, kLGSettingsSliderOwnerOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *LGSettingsSliderVisualHost(UISlider *owner) {
    return objc_getAssociatedObject(owner, kLGSettingsSliderVisualHostKey);
}

static void LGSetSettingsSliderVisualHost(UISlider *owner, UIView *host) {
    objc_setAssociatedObject(owner, kLGSettingsSliderVisualHostKey, host, OBJC_ASSOCIATION_ASSIGN);
}

static UISlider *LGSettingsSliderOverlayOwner(LGPrefsLiquidSlider *overlay) {
    return objc_getAssociatedObject(overlay, kLGSettingsSliderOwnerKey);
}

static void LGSetSettingsSliderOverlayOwner(LGPrefsLiquidSlider *overlay, UISlider *owner) {
    objc_setAssociatedObject(overlay, kLGSettingsSliderOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL LGSettingsSliderIsSegmented(UISlider *owner) {
    LGPrefsLiquidSlider *overlay = LGSettingsSliderOwnerOverlay(owner);
    if (overlay) {
        return [objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentedKey) boolValue];
    }
    return NO;
}

static void LGApplySettingsSegmentedSliderTrackPolicy(UISlider *owner, BOOL segmented) {
    if (!owner) return;
    UIColor *storedMinimumTrackTint = objc_getAssociatedObject(owner, kLGSettingsSliderOriginalMinimumTrackTintKey);
    if (segmented) {
        if (!storedMinimumTrackTint && owner.minimumTrackTintColor) {
            objc_setAssociatedObject(owner, kLGSettingsSliderOriginalMinimumTrackTintKey, owner.minimumTrackTintColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![owner.minimumTrackTintColor isEqual:UIColor.clearColor]) {
            owner.minimumTrackTintColor = UIColor.clearColor;
        }
    } else if (storedMinimumTrackTint) {
        owner.minimumTrackTintColor = storedMinimumTrackTint;
        objc_setAssociatedObject(owner, kLGSettingsSliderOriginalMinimumTrackTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGHideNativeSwitchSubviews(UIView *host) {
    for (UIView *subview in host.subviews) {
        subview.alpha = 0.01;
        subview.hidden = NO;
        subview.userInteractionEnabled = NO;
    }
}

static void LGSetSliderNativeSubviewTreeHiddenState(UIView *view, BOOL keepVisible) {
    view.hidden = NO;
    view.userInteractionEnabled = NO;
    view.alpha = keepVisible ? 1.0 : 0.01;
    for (UIView *subview in view.subviews) {
        BOOL childKeepVisible = keepVisible || [subview isKindOfClass:[UILabel class]];
        LGSetSliderNativeSubviewTreeHiddenState(subview, childKeepVisible);
    }
}

static BOOL LGSettingsSliderHasSpeechRateEndpointIcons(UIView *host) {
    NSInteger matchedCount = 0;
    for (UIView *subview in host.subviews) {
        if (![subview isKindOfClass:[UIImageView class]]) continue;
        NSString *label = subview.accessibilityLabel.lowercaseString ?: @"";
        if ([label isEqualToString:@"increase speed"] || [label isEqualToString:@"decrease speed"]) {
            matchedCount++;
        }
    }
    return matchedCount >= 2;
}

static void LGHideNativeSliderSubviews(UIView *host) {
    for (UIView *subview in host.subviews) {
        BOOL keepVisible = [subview isKindOfClass:[UILabel class]];
        LGSetSliderNativeSubviewTreeHiddenState(subview, keepVisible);
    }
}

static UIView *LGSettingsSliderOverlayContainer(UISlider *owner, UIView *host) {
    UIView *start = owner.superview ?: host;
    UIView *best = start;
    for (UIView *candidate = start; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIScrollView class]]) break;
        best = candidate;
    }
    return best ?: start;
}

static void LGAllowSettingsSliderOverflowFromContainer(UIView *container) {
    for (UIView *candidate = container; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIScrollView class]]) break;
        candidate.clipsToBounds = NO;
        candidate.layer.masksToBounds = NO;
    }
}

static void LGLayoutSettingsSwitchOverlayForOwner(UISwitch *owner) {
    if (!owner) return;
    LGPrefsLiquidSwitch *overlay = LGSettingsSwitchOwnerOverlay(owner);
    if (!overlay || !overlay.superview) return;
    UIView *host = LGSettingsSwitchVisualHost(owner);
    if (!host) return;
    UIView *container = overlay.superview;
    CGRect ownerFrame = [owner convertRect:owner.bounds toView:container];
    CGRect hostFrame = [host convertRect:host.bounds toView:container];
    CGRect overlayFrame = CGRectMake(CGRectGetMinX(ownerFrame) - kLGSettingsSwitchTrailingInset,
                                     CGRectGetMinY(hostFrame),
                                     CGRectGetWidth(owner.bounds) + kLGSettingsSwitchTrailingInset,
                                     CGRectGetHeight(hostFrame));
    overlay.frame = overlayFrame;
    overlay.hidden = owner.hidden;
    overlay.alpha = owner.alpha;
    [container bringSubviewToFront:overlay];
}

static void LGScheduleSettingsSwitchOverlayRelayout(UISwitch *owner) {
    if (!owner) return;
    if ([objc_getAssociatedObject(owner, kLGSettingsSwitchRelayoutPendingKey) boolValue]) return;
    objc_setAssociatedObject(owner, kLGSettingsSwitchRelayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(owner, kLGSettingsSwitchRelayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLayoutSettingsSwitchOverlayForOwner(owner);
    });
}

static void LGLayoutSettingsSliderOverlayForOwner(UISlider *owner) {
    if (!owner) return;
    LGPrefsLiquidSlider *overlay = LGSettingsSliderOwnerOverlay(owner);
    if (!overlay || !overlay.superview) return;
    UIView *host = LGSettingsSliderVisualHost(owner);
    if (!host) return;
    id specifier = LGOwnerSpecifierForView(owner);
    UIView *container = overlay.superview;
    CGRect contentFrame = CGRectNull;
    CGRect labelFrame = CGRectNull;
    for (UIView *subview in host.subviews) {
        if (CGRectIsEmpty(subview.bounds)) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:container];
        if ([subview isKindOfClass:[UILabel class]]) {
            labelFrame = CGRectIsNull(labelFrame) ? frame : CGRectUnion(labelFrame, frame);
            continue;
        }
        contentFrame = CGRectIsNull(contentFrame) ? frame : CGRectUnion(contentFrame, frame);
    }
    if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame)) {
        CGRect ownerFrame = [owner convertRect:owner.bounds toView:container];
        CGRect hostFrame = [host convertRect:host.bounds toView:container];
        contentFrame = CGRectMake(CGRectGetMinX(ownerFrame),
                                  CGRectGetMinY(hostFrame),
                                  CGRectGetWidth(ownerFrame),
                                  CGRectGetHeight(hostFrame));
    }
    if (!CGRectIsNull(labelFrame) && CGRectGetMinX(labelFrame) > CGRectGetMinX(contentFrame)) {
        CGFloat gap = 6.0;
        CGFloat maxX = CGRectGetMinX(labelFrame) - gap;
        if (maxX > CGRectGetMinX(contentFrame)) {
            contentFrame.size.width = maxX - CGRectGetMinX(contentFrame);
        }
    }

    CGFloat extraRightCapture = 0.0;
    if (!CGRectIsNull(labelFrame) && CGRectGetMaxX(labelFrame) > CGRectGetMaxX(contentFrame)) {
        extraRightCapture = CGRectGetMaxX(labelFrame) - CGRectGetMaxX(contentFrame);
    }
    overlay.frame = contentFrame;
    overlay.hidden = owner.hidden;
    overlay.alpha = owner.alpha;
    objc_setAssociatedObject(overlay, kLGPrefsSliderUseLiveCaptureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay,
                             kLGPrefsSliderExtraCaptureInsetsKey,
                             [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0.0, 0.0, 0.0, extraRightCapture + 8.0)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay,
                             kLGPrefsSliderLabelCaptureRegionKey,
                             [NSValue valueWithCGRect:(!CGRectIsNull(labelFrame) && !CGRectIsEmpty(labelFrame)
                                                       ? CGRectInset([overlay convertRect:labelFrame fromView:container], -2.0, -2.0)
                                                       : CGRectZero)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect ownerTrackRect = [owner trackRectForBounds:owner.bounds];
    CGRect ownerMinThumbRect = [owner thumbRectForBounds:owner.bounds trackRect:ownerTrackRect value:owner.minimumValue];
    CGRect ownerMaxThumbRect = [owner thumbRectForBounds:owner.bounds trackRect:ownerTrackRect value:owner.maximumValue];
    CGPoint minCenterInContainer = [owner convertPoint:CGPointMake(CGRectGetMidX(ownerMinThumbRect), CGRectGetMidY(ownerMinThumbRect))
                                                toView:container];
    CGPoint maxCenterInContainer = [owner convertPoint:CGPointMake(CGRectGetMidX(ownerMaxThumbRect), CGRectGetMidY(ownerMaxThumbRect))
                                                toView:container];
    CGPoint minCenterInOverlay = [overlay convertPoint:minCenterInContainer fromView:container];
    CGPoint maxCenterInOverlay = [overlay convertPoint:maxCenterInContainer fromView:container];
    objc_setAssociatedObject(overlay,
                             kLGPrefsSliderEndpointCentersKey,
                             @[ @(minCenterInOverlay.x), @(maxCenterInOverlay.x) ],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentedKey) boolValue]) {
        NSInteger segmentCount = LGSettingsSliderResolvedSegmentCount(owner, specifier);
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey, @(segmentCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSInteger snapPointCount = MAX(0, segmentCount + 1);
        NSMutableArray<NSNumber *> *centers = [NSMutableArray array];
        if (snapPointCount >= 2) {
            float range = owner.maximumValue - owner.minimumValue;
            for (NSInteger index = 0; index < snapPointCount; index++) {
                float value = owner.minimumValue;
                if (fabsf(range) > FLT_EPSILON) {
                    value = owner.minimumValue + ((float)index / (float)(snapPointCount - 1)) * range;
                }
                CGRect ownerThumbRect = [owner thumbRectForBounds:owner.bounds trackRect:ownerTrackRect value:value];
                CGPoint centerInContainer = [owner convertPoint:CGPointMake(CGRectGetMidX(ownerThumbRect), CGRectGetMidY(ownerThumbRect))
                                                         toView:container];
                CGPoint centerInOverlay = [overlay convertPoint:centerInContainer fromView:container];
                [centers addObject:@(centerInOverlay.x)];
            }
        }
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, centers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDebugLog(@"settings slider segment map owner=%p host=%@ min=%.3f max=%.3f points=%ld endpoints=%@ centers=%@",
                   owner,
                   NSStringFromClass(host.class),
                   owner.minimumValue,
                   owner.maximumValue,
                   (long)snapPointCount,
                   @[ @(minCenterInOverlay.x), @(maxCenterInOverlay.x) ],
                   centers);
    } else {
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [container bringSubviewToFront:overlay];
}

static void LGScheduleSettingsSliderOverlayRelayout(UISlider *owner) {
    if (!owner) return;
    if ([objc_getAssociatedObject(owner, kLGSettingsSliderRelayoutPendingKey) boolValue]) return;
    objc_setAssociatedObject(owner, kLGSettingsSliderRelayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(owner, kLGSettingsSliderRelayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLayoutSettingsSliderOverlayForOwner(owner);
    });
}

@interface LGPrefsLiquidSwitch (SettingsOverlay)
- (void)lg_settingsValueChanged;
@end

@interface UISwitch (SettingsOverlay)
- (void)lg_syncSettingsOverlayFromOwner;
@end

@interface LGPrefsLiquidSlider (SettingsOverlay)
- (void)lg_settingsValueChanged;
@end

@interface UISlider (SettingsOverlay)
- (void)lg_syncSettingsSliderOverlayFromOwnerAnimated:(BOOL)animated;
@end

@implementation LGPrefsLiquidSwitch (SettingsOverlay)

- (void)lg_settingsValueChanged {
    UISwitch *owner = LGSettingsSwitchOverlayOwner(self);
    if (!owner) return;
    objc_setAssociatedObject(owner, kLGSettingsSwitchOwnerDrivenSyncKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [owner setOn:self.isOn animated:NO];
    [owner sendActionsForControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(owner, kLGSettingsSwitchOwnerDrivenSyncKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation UISwitch (SettingsOverlay)

- (LGPrefsLiquidSwitch *)lg_settingsOverlay {
    return LGSettingsSwitchOwnerOverlay(self);
}

- (void)lg_syncSettingsOverlayFromOwner {
    if ([objc_getAssociatedObject(self, kLGSettingsSwitchOwnerDrivenSyncKey) boolValue]) return;
    LGPrefsLiquidSwitch *overlay = [self lg_settingsOverlay];
    if (!overlay) return;
    [overlay setOn:self.isOn animated:YES];
}

@end

@implementation LGPrefsLiquidSlider (SettingsOverlay)

- (void)lg_settingsValueChanged {
    UISlider *owner = LGSettingsSliderOverlayOwner(self);
    if (!owner) return;
    objc_setAssociatedObject(owner, kLGSettingsSliderOwnerDrivenSyncKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [owner setValue:self.value animated:NO];
    [owner sendActionsForControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(owner, kLGSettingsSliderOwnerDrivenSyncKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation UISlider (SettingsOverlay)

- (LGPrefsLiquidSlider *)lg_settingsOverlay {
    return LGSettingsSliderOwnerOverlay(self);
}

- (void)lg_syncSettingsSliderOverlayFromOwnerAnimated:(BOOL)animated {
    if ([objc_getAssociatedObject(self, kLGSettingsSliderOwnerDrivenSyncKey) boolValue]) return;
    LGPrefsLiquidSlider *overlay = [self lg_settingsOverlay];
    if (!overlay) return;
    BOOL segmented = LGSettingsSliderIsSegmented(self);
    LGApplySettingsSegmentedSliderTrackPolicy(self, segmented);
    overlay.minimumValue = self.minimumValue;
    overlay.maximumValue = self.maximumValue;
    overlay.minimumTrackTintColor = segmented ? UIColor.clearColor : self.minimumTrackTintColor;
    overlay.maximumTrackTintColor = segmented ? UIColor.clearColor : self.maximumTrackTintColor;
    overlay.enabled = self.enabled;
    [overlay setValue:self.value animated:animated];
    LGLayoutSettingsSliderOverlayForOwner(self);
}

@end

static void LGUpdateSettingsSwitchVisualElement(UIView *host) {
    if (!host) return;
    if (LGViewIsInsideLiquidSwitch(host)) return;
    UISwitch *owner = LGSwitchOwnerForVisualElement(host);
    if (!owner) return;
    if ([owner isKindOfClass:[LGPrefsLiquidSwitch class]]) return;

    LGPrefsLiquidSwitch *overlay = LGSettingsSwitchOverlay(host);
    UIView *container = owner.superview ?: host;
    if (!overlay) {
        overlay = [[LGPrefsLiquidSwitch alloc] initWithFrame:host.bounds];
        overlay.userInteractionEnabled = YES;
        [overlay addTarget:overlay action:@selector(lg_settingsValueChanged) forControlEvents:UIControlEventValueChanged];
        LGSetSettingsSwitchOverlay(host, overlay);
        LGSetSettingsSwitchOwnerOverlay(owner, overlay);
    }
    if (overlay.superview != container) {
        [overlay removeFromSuperview];
        [container addSubview:overlay];
    }

    if (![objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayInstalledKey) boolValue]) {
        [owner addTarget:owner action:@selector(lg_syncSettingsOverlayFromOwner) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(owner, kLGSettingsSwitchOverlayInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    LGSetSettingsSwitchOverlayOwner(overlay, owner);
    LGSetSettingsSwitchVisualHost(owner, host);
    LGLayoutSettingsSwitchOverlayForOwner(owner);
    LGScheduleSettingsSwitchOverlayRelayout(owner);
    if (overlay.isOn != owner.isOn) {
        [overlay setOn:owner.isOn animated:NO];
    }
    host.userInteractionEnabled = NO;
    owner.userInteractionEnabled = NO;
    LGHideNativeSwitchSubviews(host);
    [container bringSubviewToFront:overlay];
}

static void LGUpdateSettingsSliderVisualElement(UIView *host) {
    if (!host) return;
    if (LGViewIsInsideLiquidSlider(host)) return;
    UISlider *owner = LGSliderOwnerForVisualElement(host);
    if (!owner) return;
    if (LGSettingsSliderHasSpeechRateEndpointIcons(host)) return;
    LGPrefsLiquidSlider *overlay = LGSettingsSliderOverlay(host);
    UIView *container = LGSettingsSliderOverlayContainer(owner, host);
    if (!overlay) {
        overlay = [[LGPrefsLiquidSlider alloc] initWithFrame:CGRectZero];
        overlay.userInteractionEnabled = YES;
        [overlay addTarget:overlay action:@selector(lg_settingsValueChanged) forControlEvents:UIControlEventValueChanged];
        LGSetSettingsSliderOverlay(host, overlay);
        LGSetSettingsSliderOwnerOverlay(owner, overlay);
    }
    if (overlay.superview != container) {
        [overlay removeFromSuperview];
        [container addSubview:overlay];
    }

    id specifier = LGOwnerSpecifierForView(owner);
    BOOL segmented = LGSpecifierBoolProperty(specifier, @"isSegmented")
                  || LGSpecifierBoolProperty(specifier, @"locksToSegment")
                  || LGSpecifierBoolProperty(specifier, @"snapsToSegment");
    NSInteger segmentCount = LGSpecifierIntegerProperty(specifier, @"segmentCount");

    LGSetSettingsSliderOverlayOwner(overlay, owner);
    LGSetSettingsSliderVisualHost(owner, host);
    overlay.minimumValue = owner.minimumValue;
    overlay.maximumValue = owner.maximumValue;
    overlay.minimumTrackTintColor = segmented ? UIColor.clearColor : owner.minimumTrackTintColor;
    overlay.maximumTrackTintColor = segmented ? UIColor.clearColor : owner.maximumTrackTintColor;
    overlay.enabled = owner.enabled;
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentedKey, @(segmented), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey, @(segmentCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGApplySettingsSegmentedSliderTrackPolicy(owner, segmented);
    if (fabsf(overlay.value - owner.value) > FLT_EPSILON) {
        [overlay setValue:owner.value animated:NO];
    }
    LGAllowSettingsSliderOverflowFromContainer(container);
    LGLayoutSettingsSliderOverlayForOwner(owner);
    LGScheduleSettingsSliderOverlayRelayout(owner);
    host.userInteractionEnabled = NO;
    owner.userInteractionEnabled = NO;
    LGHideNativeSliderSubviews(host);
    [container bringSubviewToFront:overlay];
}

%group LiquidAssPreferencesControls

%hook UISwitchModernVisualElement

- (void)didMoveToWindow {
    %orig;
    LGUpdateSettingsSwitchVisualElement((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsSwitchVisualElement((UIView *)self);
}

%end

%hook _UISlideriOSVisualElement

- (void)didMoveToWindow {
    %orig;
    LGUpdateSettingsSliderVisualElement((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsSliderVisualElement((UIView *)self);
}

%end

%hook UISwitch

- (void)layoutSubviews {
    %orig;
    LGLayoutSettingsSwitchOverlayForOwner((UISwitch *)self);
    LGScheduleSettingsSwitchOverlayRelayout((UISwitch *)self);
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, kLGSettingsSwitchOwnerDrivenSyncKey) boolValue]) return;
    LGPrefsLiquidSwitch *overlay = LGSettingsSwitchOwnerOverlay(self);
    if (overlay) [overlay setOn:on animated:animated];
}

%end

%hook UISlider

- (void)didMoveToWindow {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

- (void)layoutSubviews {
    %orig;
    LGLayoutSettingsSliderOverlayForOwner((UISlider *)self);
    LGScheduleSettingsSliderOverlayRelayout((UISlider *)self);
}

- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:animated];
}

- (void)setMinimumValue:(float)minimumValue {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

- (void)setMaximumValue:(float)maximumValue {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

- (void)setEnabled:(BOOL)enabled {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

- (void)setMinimumTrackTintColor:(UIColor *)minimumTrackTintColor {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

- (void)setMaximumTrackTintColor:(UIColor *)maximumTrackTintColor {
    %orig;
    [self lg_syncSettingsSliderOverlayFromOwnerAnimated:NO];
}

%end

%hook UISegmentedControl

%new
- (void)lg_startSettingsSegmentedDisplayLinkIfNeeded {
    if (LGSettingsSegmentedDisplayLink((UISegmentedControl *)self) || !self.window) return;
    UISegmentedControl *control = (UISegmentedControl *)self;
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedLastDisplayLinkTimestampKey, 0.0);
    __weak UISegmentedControl *weakControl = control;
    CADisplayLink *link = nil;
    id driver = nil;
    NSInteger preferredFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    LGStartDisplayLink(&link, &driver, preferredFPS, ^{
        UISegmentedControl *strongControl = weakControl;
        if (!strongControl) return;
        CADisplayLink *activeLink = LGSettingsSegmentedDisplayLink(strongControl);
        if (!activeLink) return;
        [strongControl lg_handleSettingsSegmentedDisplayLink:activeLink];
    });
    LGSetSettingsSegmentedDisplayLink(control, link);
    LGSetSettingsSegmentedDisplayLinkDriver(control, driver);
}

%new
- (void)lg_stopSettingsSegmentedDisplayLink {
    UISegmentedControl *control = (UISegmentedControl *)self;
    CADisplayLink *link = LGSettingsSegmentedDisplayLink(control);
    id driver = LGSettingsSegmentedDisplayLinkDriver(control);
    LGStopDisplayLink(&link, &driver);
    LGSetSettingsSegmentedDisplayLink(control, nil);
    LGSetSettingsSegmentedDisplayLinkDriver(control, nil);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedLastDisplayLinkTimestampKey, 0.0);
    LGSetSettingsSegmentedGlassVelocity(control, 0.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedObjectScaleKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedObjectScaleVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleXKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleXVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleYKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleYVelocityKey, 0.0);
    LGSetSettingsSegmentedHasRenderedState(control, NO);
}

%new
- (void)lg_handleSettingsSegmentedDisplayLink:(CADisplayLink *)link {
    UISegmentedControl *control = (UISegmentedControl *)self;
    CGFloat previousTimestamp = LGSettingsSegmentedSpringValue(control, kLGSettingsSegmentedLastDisplayLinkTimestampKey, 0.0);
    CGFloat dt = previousTimestamp > 0.0 ? (CGFloat)(link.timestamp - previousTimestamp) : (1.0 / 60.0);
    dt = fmin(fmax(dt, 1.0 / 240.0), 1.0 / 20.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedLastDisplayLinkTimestampKey, (CGFloat)link.timestamp);

    CGFloat currentVelocityX = LGSettingsSegmentedGlassVelocity(control) * 0.82;
    LGSetSettingsSegmentedGlassVelocity(control, currentVelocityX);
    CGFloat touchX = LGSettingsSegmentedGlassTouchX(control);
    if (LGSettingsSegmentedReleased(control) && !isnan(touchX)) {
        CGFloat targetCenterX = LGSettingsSegmentedTargetCenterX(control);
        CGFloat frameFactor = fmin(fmax(dt * 60.0, 0.35), 1.4);
        CGFloat followLerp = 0.24 * frameFactor;
        touchX += (targetCenterX - touchX) * followLerp;
        LGSetSettingsSegmentedGlassTouchX(control, touchX);
    }
    UIImageView *stockPill = LGSettingsSegmentedStockPill(control);
    if (!stockPill || stockPill.superview != control) {
        stockPill = LGFindSettingsSegmentedStockPill(control);
        LGSetSettingsSegmentedStockPill(control, stockPill);
    }
    if (stockPill) {
        CGRect targetFrame = LGSettingsSegmentedGlassDragFrame(control, stockPill.frame);
        if (!LGSettingsSegmentedHasRenderedState(control)) {
            LGSetSettingsSegmentedRenderedFrameState(control, targetFrame);
        } else {
            LGLiquidRenderedState currentState = LGLiquidRenderedStateMake(LGSettingsSegmentedRenderedCenterX(control, CGRectGetMidX(targetFrame)),
                                                                           CGSizeMake(LGSettingsSegmentedRenderedWidth(control, CGRectGetWidth(targetFrame)),
                                                                                      LGSettingsSegmentedRenderedHeight(control, CGRectGetHeight(targetFrame))));
            LGLiquidRenderedState targetState = LGLiquidRenderedStateMake(CGRectGetMidX(targetFrame), targetFrame.size);
            LGLiquidRenderedState nextState = LGLiquidRenderedStateStep(currentState, targetState, LGSettingsSegmentedGlassActive(control), dt);
            CGRect renderedFrame = CGRectMake(nextState.centerX - nextState.width * 0.5,
                                              CGRectGetMidY(targetFrame) - nextState.height * 0.5,
                                              nextState.width,
                                              nextState.height);
            LGSetSettingsSegmentedRenderedFrameState(control, renderedFrame);
        }
    }
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedObjectScaleKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedObjectScaleVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleYKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleYVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleXKey, 1.0);
    LGSetSettingsSegmentedSpringValue(control, kLGSettingsSegmentedScaleXVelocityKey, 0.0);

    LGUpdateSettingsSegmentedControlVisuals(control);

    if (!LGSettingsSegmentedGlassActive(control)) {
        [self lg_stopSettingsSegmentedDisplayLink];
    }
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        [self lg_stopSettingsSegmentedDisplayLink];
    }
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"didMoveToWindow");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)layoutSubviews {
    %orig;
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"layout");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)setSelectedSegmentIndex:(NSInteger)selectedSegmentIndex {
    %orig;
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"setSelectedSegmentIndex");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, YES);
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"beginTracking");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
    return result;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, YES);
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"continueTracking");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
    return result;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, NO);
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"endTracking");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, NO);
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"cancelTracking");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    LGAdvanceSettingsSegmentedDeactivateToken((UISegmentedControl *)self);
    LGSetSettingsSegmentedReleased((UISegmentedControl *)self, NO);
    LGSetSettingsSegmentedReleaseObjectScale((UISegmentedControl *)self, NAN);
    LGSetSettingsSegmentedReleaseFrame((UISegmentedControl *)self, CGRectNull);
    UIImageView *stockPill = LGSettingsSegmentedStockPill((UISegmentedControl *)self);
    if (!stockPill || stockPill.superview != (UISegmentedControl *)self) {
        stockPill = LGFindSettingsSegmentedStockPill((UISegmentedControl *)self);
        LGSetSettingsSegmentedStockPill((UISegmentedControl *)self, stockPill);
    }
    CGFloat startX = stockPill ? CGRectGetMidX(stockPill.frame) : CGRectGetMidX(((UISegmentedControl *)self).bounds);
    LGSetSettingsSegmentedGlassTouchX((UISegmentedControl *)self, startX);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchXKey, @(startX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchTimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGSetSettingsSegmentedGlassVelocity((UISegmentedControl *)self, 0.0);
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, YES);
    [self lg_startSettingsSegmentedDisplayLinkIfNeeded];
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"touchesBegan");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    UITouch *touch = touches.anyObject;
    if (touch) {
        CGPoint point = [touch locationInView:(UISegmentedControl *)self];
        NSNumber *lastX = objc_getAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchXKey);
        NSNumber *lastTime = objc_getAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchTimeKey);
        CFTimeInterval now = CACurrentMediaTime();
        if (lastX && lastTime) {
            CFTimeInterval dt = MAX(now - lastTime.doubleValue, 0.001);
            CGFloat rawVelocity = (point.x - lastX.doubleValue) / dt;
            CGFloat mixedVelocity = LGSettingsSegmentedGlassVelocity((UISegmentedControl *)self) * 0.35 + rawVelocity * 0.65;
            LGSetSettingsSegmentedGlassVelocity((UISegmentedControl *)self, mixedVelocity);
        }
        LGSetSettingsSegmentedGlassTouchX((UISegmentedControl *)self, point.x);
        objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchXKey, @(point.x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, YES);
    [self lg_startSettingsSegmentedDisplayLinkIfNeeded];
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"touchesMoved");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    LGSharedGlassView *glass = LGSettingsSegmentedGlassPill((UISegmentedControl *)self);
    UIView *container = LGSettingsSegmentedOverlayContainer((UISegmentedControl *)self);
    CGRect releaseFrame = (glass && container) ? [container convertRect:glass.frame toView:(UISegmentedControl *)self] : CGRectNull;
    CGFloat releaseCenterX = CGRectIsNull(releaseFrame) ? CGRectGetMidX(((UISegmentedControl *)self).bounds) : CGRectGetMidX(releaseFrame);
    %orig;
    LGSetSettingsSegmentedGlassVelocity((UISegmentedControl *)self, 0.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedObjectScaleKey, 1.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedObjectScaleVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedScaleXKey, 1.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedScaleXVelocityKey, 0.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedScaleYKey, 1.0);
    LGSetSettingsSegmentedSpringValue((UISegmentedControl *)self, kLGSettingsSegmentedScaleYVelocityKey, 0.0);
    LGSetSettingsSegmentedReleased((UISegmentedControl *)self, YES);
    LGSetSettingsSegmentedReleaseObjectScale((UISegmentedControl *)self, LGSettingsSegmentedObjectScale((UISegmentedControl *)self));
    LGSetSettingsSegmentedReleaseFrame((UISegmentedControl *)self, releaseFrame);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchXKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"touchesEnded");
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, YES);
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
    NSInteger token = LGAdvanceSettingsSegmentedDeactivateToken((UISegmentedControl *)self);
    CGFloat targetCenterX = LGSettingsSegmentedTargetCenterX((UISegmentedControl *)self);
    CGFloat glideDistance = fabs(targetCenterX - releaseCenterX);
    CGFloat holdDuration = fmin(0.36, fmax(0.18, 0.12 + glideDistance / 900.0));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (LGSettingsSegmentedDeactivateToken((UISegmentedControl *)self) != token) return;
        LGSetSettingsSegmentedGlassTouchX((UISegmentedControl *)self, NAN);
        LGSetSettingsSegmentedReleased((UISegmentedControl *)self, NO);
        LGSetSettingsSegmentedReleaseObjectScale((UISegmentedControl *)self, NAN);
        LGSetSettingsSegmentedReleaseFrame((UISegmentedControl *)self, CGRectNull);
        LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, NO);
        [(UISegmentedControl *)self lg_stopSettingsSegmentedDisplayLink];
        LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
    });
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    LGSetSettingsSegmentedGlassTouchX((UISegmentedControl *)self, NAN);
    LGSetSettingsSegmentedGlassVelocity((UISegmentedControl *)self, 0.0);
    LGSetSettingsSegmentedReleased((UISegmentedControl *)self, NO);
    LGSetSettingsSegmentedReleaseObjectScale((UISegmentedControl *)self, NAN);
    LGSetSettingsSegmentedReleaseFrame((UISegmentedControl *)self, CGRectNull);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchXKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((UISegmentedControl *)self, kLGSettingsSegmentedLastTouchTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGSetSettingsSegmentedGlassActive((UISegmentedControl *)self, NO);
    LGAdvanceSettingsSegmentedDeactivateToken((UISegmentedControl *)self);
    [self lg_stopSettingsSegmentedDisplayLink];
    LGProbeSettingsSegmentedControl((UISegmentedControl *)self, @"touchesCancelled");
    LGUpdateSettingsSegmentedControlVisuals((UISegmentedControl *)self);
}

%end

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    LGUpdateSettingsTopFadeForController((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGUpdateSettingsTopFadeForController((UIViewController *)self);
}

%end

%hook PSTableCell

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize original = %orig;
    if (LGSettingsShouldModifyCell((UIView *)self) && original.height >= 44.0 && original.height <= 55.0) {
        original.height = 54.0;
    }
    return original;
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize
          withHorizontalFittingPriority:(UILayoutPriority)horizontalPriority
                verticalFittingPriority:(UILayoutPriority)verticalPriority {
    CGSize original = %orig;
    if (LGSettingsShouldModifyCell((UIView *)self) && original.height >= 44.0 && original.height <= 55.0) {
        original.height = 54.0;
    }
    return original;
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsCellSeparatorInsets((UITableViewCell *)self);
    if (LGSettingsShouldModifyCell((UIView *)self)) {
        LGUpdateSettingsRoundedCellShape((UIView *)self);
        LGUpdateSettingsRoundedCellSubviews((UIView *)self);
    }
}

%end

%hook PSSegmentTableCell

- (void)layoutSubviews {
    %orig;
}

%end

%hook PSSliderTableCell

- (void)layoutSubviews {
    %orig;
    ((UIView *)self).layer.cornerRadius = 24.5;
}

%end

%end

%ctor {
    if (!LGIsPreferencesApp()) return;
    if (!LGSettingsControlsEnabled()) return;
    %init(LiquidAssPreferencesControls);
}
