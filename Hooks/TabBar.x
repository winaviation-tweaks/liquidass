#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLiquidMotion.h"
#import "../Shared/LGLensRectState.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGSharedSupport.h"

static const void *kLGTabBarPendingDumpKey = &kLGTabBarPendingDumpKey;
static const void *kLGTabBarLastSignatureKey = &kLGTabBarLastSignatureKey;
static const void *kLGTabBarGlassKey = &kLGTabBarGlassKey;
static const void *kLGTabBarStylingKey = &kLGTabBarStylingKey;
static const void *kLGTabBarSelectedHighlightKey = &kLGTabBarSelectedHighlightKey;
static const void *kLGTabBarSelectionGlassKey = &kLGTabBarSelectionGlassKey;
static const void *kLGTabBarSelectionAnimatorKey = &kLGTabBarSelectionAnimatorKey;
static const void *kLGTabBarMotionStateKey = &kLGTabBarMotionStateKey;
static const void *kLGTabBarBlueOverlayKey = &kLGTabBarBlueOverlayKey;
static const void *kLGTabBarBlueContentKey = &kLGTabBarBlueContentKey;
static const void *kLGTabBarAccentColorKey = &kLGTabBarAccentColorKey;
static const void *kLGTabBarOriginalTintKey = &kLGTabBarOriginalTintKey;
static const void *kLGTabBarOriginalBarTintKey = &kLGTabBarOriginalBarTintKey;
static const void *kLGTabBarOriginalBackgroundColorKey =
    &kLGTabBarOriginalBackgroundColorKey;
static const void *kLGTabBarOriginalBackgroundHiddenKey =
    &kLGTabBarOriginalBackgroundHiddenKey;
static const void *kLGTabBarOriginalClipsKey = &kLGTabBarOriginalClipsKey;
static const void *kLGTabBarOriginalMasksKey = &kLGTabBarOriginalMasksKey;
static const void *kLGTabBarRemapOutKey = &kLGTabBarRemapOutKey;
static const void *kLGTabBarAppliedOverhangKey = &kLGTabBarAppliedOverhangKey;
static const void *kLGTabBarGeometryGenerationKey =
    &kLGTabBarGeometryGenerationKey;
static const CGFloat kLGTabBarPortraitHighlightHeight = 54.0;
static const CGFloat kLGTabBarPortraitLensWidth = 94.0;
static const CGFloat kLGTabBarPortraitLensHeight = 72.0;

@interface UITabBarButton : UIControl
@end

@interface LGTabBarMotionState : NSObject
@property (nonatomic, weak) UITabBar *bar;
@property (nonatomic, weak) LGLiveBackdropView *lens;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) CGFloat targetCenterX;
@property (nonatomic, assign) CGFloat targetWidth;
@property (nonatomic, assign) CGFloat targetHeight;
@property (nonatomic, assign) CGFloat renderedCenterX;
@property (nonatomic, assign) CGFloat renderedWidth;
@property (nonatomic, assign) CGFloat renderedHeight;
@property (nonatomic, assign) CGFloat widthVelocity;
@property (nonatomic, assign) CGFloat heightVelocity;
@property (nonatomic, assign) CGFloat velocityX;
@property (nonatomic, assign) CGFloat gestureStartX;
@property (nonatomic, assign) BOOL dragged;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) BOOL awaitingTapDestination;
@property (nonatomic, assign) BOOL awaitingRestingShape;
@property (nonatomic, assign) CGFloat restingTargetWidth;
@property (nonatomic, assign) CGFloat collapseStartDistance;
@property (nonatomic, assign) CFTimeInterval destinationStartTime;
@property (nonatomic, assign) CGFloat lastTouchX;
@property (nonatomic, assign) CFTimeInterval lastTouchTime;
@property (nonatomic, assign) CFTimeInterval lastDisplayTime;
- (void)start;
- (void)stop;
@end

static CGRect LGTabBarPillFrame(UITabBar *bar);
static CGRect LGTabBarPixelAlignedRect(UITabBar *bar, CGRect rect);
static BOOL LGTabBarUsesLandscapeMetrics(UITabBar *bar);
static CGFloat LGTabBarHighlightHeight(UITabBar *bar);
static CGFloat LGTabBarLensWidth(UITabBar *bar);
static CGFloat LGTabBarLensHeight(UITabBar *bar);
static LGLiveBackdropView *LGTabBarSelectionLens(UITabBar *bar);
static LGTabBarMotionState *LGTabBarMotionStateForBar(UITabBar *bar,
                                                       BOOL create);
static void LGPersistTabBarDump(NSString *dump, NSString *reason);
static void LGHookTabBarHostControllers(void);
static UITabBar *LGTabBarForButton(UIView *button);
static BOOL LGIsStockTabBar(UITabBar *bar);
static const CGFloat kLGTabBarLensShapeScale = 0.70;
static const void *kLGTabBarLensPillKey = &kLGTabBarLensPillKey;

static CGRect LGTabBarLensPillRect(LGLiveBackdropView *lens) {
    NSValue *value = objc_getAssociatedObject(lens, kLGTabBarLensPillKey);
    return value ? value.CGRectValue : lens.frame;
}

static CGPoint LGTabBarLensPillCenter(LGLiveBackdropView *lens) {
    CGRect pill = LGTabBarLensPillRect(lens);
    return CGPointMake(CGRectGetMidX(pill), CGRectGetMidY(pill));
}

static void LGSetTabBarLensPill(UITabBar *bar, LGLiveBackdropView *lens,
                                CGRect pill) {
    if (!bar || !lens) return;
    objc_setAssociatedObject(lens, kLGTabBarLensPillKey,
                             [NSValue valueWithCGRect:pill],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGSize capture = CGSizeMake(CGRectGetWidth(pill) / kLGTabBarLensShapeScale,
                                CGRectGetHeight(pill) / kLGTabBarLensShapeScale);
    CGPoint centre = CGPointMake(CGRectGetMidX(pill), CGRectGetMidY(pill));
    UIWindow *window = bar.window;
    if (window) {
        CGPoint inWindow = [bar convertPoint:centre toView:window];
        CGFloat half = capture.width * 0.5;
        CGFloat lo = half, hi = CGRectGetWidth(window.bounds) - half;
        if (lo <= hi) {
            CGFloat clamped = MAX(lo, MIN(hi, inWindow.x));
            if (clamped != inWindow.x)
                centre.x = [bar convertPoint:CGPointMake(clamped, inWindow.y)
                                    fromView:window].x;
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    lens.bounds = CGRectMake(0.0, 0.0, capture.width, capture.height);
    lens.center = centre;
    lens.layer.cornerRadius = MIN(capture.width, capture.height) * 0.5;
    lens.layer.masksToBounds = NO;
    lens.clipsToBounds = NO;
    CGRect pillInLens = [bar convertRect:pill toView:lens];
    lens.lgShapeRect = pillInLens;
    lens.lgShapeCornerRadius = CGRectGetHeight(pillInLens) * 0.5;
    [CATransaction commit];
    LGLensRectWrite(LGLensRectSlotTabBarSelection, YES,
                    CGRectGetMinX(pillInLens) / capture.width,
                    CGRectGetMinY(pillInLens) / capture.height,
                    CGRectGetWidth(pillInLens) / capture.width,
                    CGRectGetHeight(pillInLens) / capture.height);
}

static void LGPositionTabBarBlueOverlay(UITabBar *bar,
                                        LGLiveBackdropView *lens);
static UIView *LGTabBarBlueOverlay(UITabBar *bar, BOOL create);
static void LGFinalizeTabBarSelection(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      LGTabBarMotionState *state);

@implementation LGTabBarMotionState

static inline CGFloat LGTabBarSpringStep(CGFloat current,
                                         CGFloat target,
                                         CGFloat *velocity,
                                         CGFloat response,
                                         CGFloat dampingRatio,
                                         CGFloat dt) {
    CGFloat remaining = fmin(fmax(dt, 0.0), 1.0 / 30.0);
    while (remaining > 0.0) {
        CGFloat step = fmin(remaining, 1.0 / 120.0);
        CGFloat omega = 2.0 * M_PI / response;
        CGFloat acceleration =
            (target - current) * omega * omega -
            2.0 * dampingRatio * omega * (*velocity);
        *velocity += acceleration * step;
        current += *velocity * step;
        remaining -= step;
    }
    return current;
}

- (void)start {
    if (self.displayLink) return;
    self.lastDisplayTime = 0.0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastDisplayTime = 0.0;
}

- (void)tick:(CADisplayLink *)link {
    LGLiveBackdropView *lens = self.lens;
    UITabBar *bar = self.bar;
    if (!lens || !bar || lens.hidden) {
        [self stop];
        return;
    }
    CFTimeInterval dt = self.lastDisplayTime > 0.0
        ? link.timestamp - self.lastDisplayTime : 1.0 / 60.0;
    self.lastDisplayTime = link.timestamp;
    LGLiquidRenderedState current =
        LGLiquidRenderedStateMake(self.renderedCenterX,
                                  CGSizeMake(self.renderedWidth,
                                             self.renderedHeight));
    LGLiquidRenderedState target =
        LGLiquidRenderedStateMake(self.targetCenterX,
                                  CGSizeMake(self.targetWidth,
                                             self.targetHeight));
    LGLiquidRenderedState next =
        LGLiquidRenderedStateStep(current, target, self.active, dt);
    CGFloat response = self.active ? 0.155 : 0.135;
    next.width = LGTabBarSpringStep(current.width, target.width,
                                    &_widthVelocity, response, 1.0, dt);
    next.height = LGTabBarSpringStep(current.height, target.height,
                                     &_heightVelocity, response, 1.0, dt);
    self.renderedCenterX = next.centerX;
    self.renderedWidth = next.width;
    self.renderedHeight = next.height;
    CGFloat pillMidY = CGRectGetMidY(LGTabBarPillFrame(bar));
    LGSetTabBarLensPill(bar, lens,
        CGRectMake(next.centerX - next.width * 0.5,
                   pillMidY - next.height * 0.5,
                   next.width, next.height));
    LGPositionTabBarBlueOverlay(bar, lens);

    if (self.awaitingTapDestination) {
        BOOL arrived =
            fabs(next.centerX - self.targetCenterX) < 1.0 &&
            fabs(next.width - LGTabBarLensWidth(bar)) < 1.0 &&
            fabs(next.height - LGTabBarLensHeight(bar)) < 1.0;
        BOOL timedOut =
            CACurrentMediaTime() - self.destinationStartTime > 0.75;
        if (arrived || timedOut) {
            self.awaitingTapDestination = NO;
            self.active = NO;
            self.targetWidth = self.restingTargetWidth;
            self.targetHeight = LGTabBarHighlightHeight(bar);
            self.awaitingRestingShape = YES;
            self.collapseStartDistance =
                hypot(next.width - self.targetWidth,
                      next.height - self.targetHeight);
            self.destinationStartTime = CACurrentMediaTime();
        }
    }
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    if (highlight) {
        highlight.bounds = CGRectMake(0.0, 0.0, next.width, next.height);
        highlight.center = LGTabBarLensPillCenter(lens);
        highlight.layer.cornerRadius = next.height * 0.5;
        highlight.hidden = NO;
    }
    if (self.awaitingRestingShape) {
        CGFloat remaining =
            hypot(next.width - self.targetWidth,
                  next.height - self.targetHeight);
        CGFloat progress = self.collapseStartDistance > 0.001
            ? 1.0 - remaining / self.collapseStartDistance : 1.0;
        progress = fmin(fmax(progress, 0.0), 1.0);
        CGFloat handoff = progress * progress * (3.0 - 2.0 * progress);
        highlight.alpha = handoff;
        lens.alpha = 1.0 - handoff;
        UIView *blueOverlay = LGTabBarBlueOverlay(bar, NO);
        blueOverlay.alpha = 1.0 - handoff;
        BOOL settled =
            fabs(next.centerX - self.targetCenterX) < 0.75 &&
            fabs(next.width - self.targetWidth) < 0.75 &&
            fabs(next.height - self.targetHeight) < 0.75;
        BOOL timedOut =
            CACurrentMediaTime() - self.destinationStartTime > 0.50;
        if (settled || timedOut) {
            self.awaitingRestingShape = NO;
            LGFinalizeTabBarSelection(bar, lens, self);
        }
    }
}

@end


static BOOL LGTabBarAllowed(void) {
    if (!lgHostEnabled(@"TabBar")) return NO;
    static BOOL excluded = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id stored = LGGlassPreferenceValue(@"TabBar.Exclusions");
        NSString *list = [stored isKindOfClass:NSString.class]
            ? (NSString *)stored : @"TikTok\ncom.zhiliaoapp.musically";
        excluded = LGProcessMatchesExclusionList(list);
    });
    return !excluded;
}

static CGFloat LGTabBarRequiredContentHeight(UITabBar *bar) {
    BOOL landscape = LGTabBarUsesLandscapeMetrics(bar);
    return (landscape ? 54.0 : 64.0) + (landscape ? 8.0 : 10.0);
}

static CGFloat LGTabBarAppliedOverhang(UITabBar *bar) {
    return [objc_getAssociatedObject(bar, kLGTabBarAppliedOverhangKey) doubleValue];
}

static CGRect LGTabBarPillFrame(UITabBar *bar) {
    BOOL landscape = LGTabBarUsesLandscapeMetrics(bar);
    const CGFloat height = landscape ? 54.0 : 64.0;
    const CGFloat minimumScreenInset = landscape ? 24.0 : 16.0;
    const CGFloat bottomInset = landscape ? 8.0 : 10.0;
    const CGFloat itemSlotWidth = landscape ? 110.0 : 67.0;
    const CGFloat pillEdgePadding = landscape ? 12.0 : 32.0;
    CGFloat availableWidth =
        MAX(0.0, CGRectGetWidth(bar.bounds) - minimumScreenInset * 2.0);
    NSUInteger itemCount = bar.items.count;
    CGFloat intrinsicWidth = itemCount
        ? itemSlotWidth * itemCount + pillEdgePadding * 2.0
        : availableWidth;
    CGFloat width = MIN(availableWidth, intrinsicWidth);
    CGFloat originX = (CGRectGetWidth(bar.bounds) - width) * 0.5;
    CGFloat safeBottom = bar.safeAreaInsets.bottom;
    CGFloat bottom = CGRectGetHeight(bar.bounds)
                   - (safeBottom > 0.0 ? safeBottom : bottomInset);
    return LGTabBarPixelAlignedRect(
        bar,
        CGRectMake(originX, bottom - height, width, height));
}

static CGRect LGTabBarPixelAlignedRect(UITabBar *bar, CGRect rect) {
    CGFloat scale = bar.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = 1.0;
    CGFloat minX = round(CGRectGetMinX(rect) * scale) / scale;
    CGFloat minY = round(CGRectGetMinY(rect) * scale) / scale;
    CGFloat maxX = round(CGRectGetMaxX(rect) * scale) / scale;
    CGFloat maxY = round(CGRectGetMaxY(rect) * scale) / scale;
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

static BOOL LGTabBarUsesLandscapeMetrics(UITabBar *bar) {
    if (!bar) return NO;
    CGSize size = bar.window ? bar.window.bounds.size : UIScreen.mainScreen.bounds.size;
    return size.width > size.height;
}

static CGFloat LGTabBarHighlightHeight(UITabBar *bar) {
    return LGTabBarUsesLandscapeMetrics(bar)
        ? 48.0 : kLGTabBarPortraitHighlightHeight;
}

static CGFloat LGTabBarLensWidth(UITabBar *bar) {
    return LGTabBarUsesLandscapeMetrics(bar)
        ? 112.0 : kLGTabBarPortraitLensWidth;
}

static CGFloat LGTabBarLensHeight(UITabBar *bar) {
    return LGTabBarUsesLandscapeMetrics(bar)
        ? 62.0 : kLGTabBarPortraitLensHeight;
}

static BOOL LGIsStockTabBar(UITabBar *bar) {
    return bar && [bar isKindOfClass:UITabBar.class];
}

static BOOL LGTabBarCanReceiveTouches(UITabBar *bar) {
    if (!LGTabBarAllowed() || !LGIsStockTabBar(bar) || !bar.window ||
        bar.hidden || bar.alpha < 0.01 || !bar.userInteractionEnabled) return NO;

    for (UIView *view = bar.superview; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01) return NO;
    }

    CGRect windowFrame = [bar convertRect:bar.bounds toView:bar.window];
    return !CGRectIsEmpty(CGRectIntersection(windowFrame, bar.window.bounds));
}

static NSArray<UIView *> *LGStockTabBarButtons(UITabBar *bar) {
    // custom layouts own their button geometry so leave them alone
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    Class buttonClass = objc_getClass("UITabBarButton");
    if (!buttonClass) return buttons;
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:buttonClass]) [buttons addObject:view];
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftX = left.center.x;
        CGFloat rightX = right.center.x;
        if (leftX < rightX) return NSOrderedAscending;
        if (leftX > rightX) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return buttons;
}

static void LGRemoveTabBarInjection(UITabBar *bar) {
    if (!bar) return;
    BOOL injected =
        [objc_getAssociatedObject(bar, kLGTabBarStylingKey) boolValue] ||
        objc_getAssociatedObject(bar, kLGTabBarGlassKey) ||
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey) ||
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey) ||
        objc_getAssociatedObject(bar, kLGTabBarBlueOverlayKey);
    if (!injected) return;

    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    [state stop];
    state.active = NO;
    state.awaitingTapDestination = NO;
    state.awaitingRestingShape = NO;

    NSArray<NSValue *> *keys = @[
        [NSValue valueWithPointer:kLGTabBarGlassKey],
        [NSValue valueWithPointer:kLGTabBarSelectedHighlightKey],
        [NSValue valueWithPointer:kLGTabBarSelectionGlassKey],
        [NSValue valueWithPointer:kLGTabBarBlueOverlayKey]
    ];
    for (NSValue *keyValue in keys) {
        const void *key = keyValue.pointerValue;
        UIView *view = objc_getAssociatedObject(bar, key);
        [view removeFromSuperview];
        objc_setAssociatedObject(bar, key, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    Class backgroundClass = objc_getClass("_UIBarBackground");
    for (UIView *view in bar.subviews) {
        if (backgroundClass && [view isKindOfClass:backgroundClass]) {
            NSNumber *originalHidden = objc_getAssociatedObject(
                bar, kLGTabBarOriginalBackgroundHiddenKey);
            if (originalHidden) view.hidden = originalHidden.boolValue;
            break;
        }
    }
    id storedTint = objc_getAssociatedObject(bar, kLGTabBarOriginalBarTintKey);
    if (storedTint) {
        bar.barTintColor = storedTint == NSNull.null ? nil : storedTint;
        id storedBg = objc_getAssociatedObject(bar, kLGTabBarOriginalBackgroundColorKey);
        bar.backgroundColor = storedBg == NSNull.null ? nil : storedBg;
        objc_setAssociatedObject(bar, kLGTabBarOriginalBarTintKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundColorKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
    NSNumber *originalClips =
        objc_getAssociatedObject(bar, kLGTabBarOriginalClipsKey);
    NSNumber *originalMasks =
        objc_getAssociatedObject(bar, kLGTabBarOriginalMasksKey);
    if (originalClips) bar.clipsToBounds = originalClips.boolValue;
    if (originalMasks) bar.layer.masksToBounds = originalMasks.boolValue;
    objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundHiddenKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarOriginalClipsKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarOriginalMasksKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarStylingKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGCollectTabBarContentViews(UIView *root,
                                        NSMutableArray<UIView *> *content,
                                        NSUInteger depth) {
    if (!root || depth > 5) return;
    for (UIView *view in root.subviews) {
        NSString *className = NSStringFromClass(view.class);
        if ([className isEqualToString:@"UITabBarSwappableImageView"] ||
            [className isEqualToString:@"UITabBarButtonLabel"]) {
            [content addObject:view];
        }
        LGCollectTabBarContentViews(view, content, depth + 1);
    }
}

static BOOL LGTabBarButtonGeometryIsConstraintManaged(UIView *button) {
    if (!button) return YES;
    if (!button.translatesAutoresizingMaskIntoConstraints) return YES;

    Class autoresizing = NSClassFromString(@"NSAutoresizingMaskLayoutConstraint");
    for (NSLayoutConstraint *constraint in button.superview.constraints) {
        if (autoresizing && [constraint isKindOfClass:autoresizing]) continue;
        if (constraint.firstItem == button) return YES;
    }
    for (NSLayoutConstraint *constraint in button.constraints) {
        if (autoresizing && [constraint isKindOfClass:autoresizing]) continue;
        if (constraint.firstItem == button &&
            (constraint.firstAttribute == NSLayoutAttributeWidth ||
             constraint.firstAttribute == NSLayoutAttributeHeight)) return YES;
    }
    return NO;
}

static void LGCenterStockTabBarButtonContent(UIView *button) {
    if (LGTabBarButtonGeometryIsConstraintManaged(button)) return;
    NSMutableArray<UIView *> *content = [NSMutableArray array];
    LGCollectTabBarContentViews(button, content, 0);
    if (!content.count) return;

    CGRect contentBounds = CGRectNull;
    for (UIView *view in content) {
        CGRect rect = [view.superview convertRect:view.frame toView:button];
        contentBounds = CGRectIsNull(contentBounds)
            ? rect : CGRectUnion(contentBounds, rect);
    }
    if (CGRectIsNull(contentBounds)) return;

    CGFloat offset = CGRectGetMidY(button.bounds) - CGRectGetMidY(contentBounds);
    if (fabs(offset) < 0.01) return;
    for (UIView *view in content) {
        CGPoint center = view.center;
        center.y += offset;
        view.center = center;
    }
}

static UIImage *LGTabBarContentMaskImage(UITabBar *bar, CGRect pillFrame) {
    if (CGRectIsEmpty(pillFrame)) return nil;
    UIGraphicsBeginImageContextWithOptions(pillFrame.size, NO,
                                           UIScreen.mainScreen.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    for (UIView *button in LGStockTabBarButtons(bar)) {
        NSMutableArray<UIView *> *content = [NSMutableArray array];
        LGCollectTabBarContentViews(button, content, 0);
        for (UIView *view in content) {
            if (view.hidden || view.alpha < 0.01) continue;
            CGRect rect = [view convertRect:view.bounds toView:bar];
            CGContextSaveGState(context);
            CGContextTranslateCTM(context,
                                  CGRectGetMinX(rect) - CGRectGetMinX(pillFrame),
                                  CGRectGetMinY(rect) - CGRectGetMinY(pillFrame));
            [view.layer renderInContext:context];
            CGContextRestoreGState(context);
        }
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIColor *LGTabBarAccentColor(UITabBar *bar) {
    UIColor *stored = objc_getAssociatedObject(bar, kLGTabBarAccentColorKey);
    if (stored) return stored;

    UIColor *accent = bar.tintColor;
    if (!accent) {
        if (@available(iOS 13.0, *)) {
            UITabBarItemStateAppearance *selected =
                bar.standardAppearance.stackedLayoutAppearance.selected;
            accent = selected.iconColor;
            if (!accent) {
                id titleColor = selected.titleTextAttributes[NSForegroundColorAttributeName];
                if ([titleColor isKindOfClass:[UIColor class]]) accent = titleColor;
            }
        }
    }
    return accent ?: UIColor.systemBlueColor;
}

static UIView *LGTabBarBlueOverlay(UITabBar *bar, BOOL create) {
    UIView *overlay = objc_getAssociatedObject(bar, kLGTabBarBlueOverlayKey);
    if (overlay || !create) return overlay;

    overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.userInteractionEnabled = NO;
    overlay.clipsToBounds = YES;
    overlay.hidden = YES;
    overlay.alpha = 0.0;
    if (@available(iOS 13.0, *)) {
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
    }

    UIView *blueContent = [[UIView alloc] initWithFrame:CGRectZero];
    blueContent.userInteractionEnabled = NO;
    blueContent.backgroundColor = LGTabBarAccentColor(bar);
    [overlay addSubview:blueContent];
    objc_setAssociatedObject(overlay, kLGTabBarBlueContentKey, blueContent,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar addSubview:overlay];
    objc_setAssociatedObject(bar, kLGTabBarBlueOverlayKey, overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return overlay;
}

static void LGRebuildTabBarBlueMask(UITabBar *bar) {
    // this mask colors only glyph pixels covered by the moving lens
    UIView *overlay = LGTabBarBlueOverlay(bar, YES);
    UIView *blueContent =
        objc_getAssociatedObject(overlay, kLGTabBarBlueContentKey);
    blueContent.backgroundColor = LGTabBarAccentColor(bar);
    CGRect pillFrame = LGTabBarPillFrame(bar);
    UIImage *maskImage = LGTabBarContentMaskImage(bar, pillFrame);
    CALayer *mask = [CALayer layer];
    mask.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(pillFrame),
                            CGRectGetHeight(pillFrame));
    mask.contents = (__bridge id)maskImage.CGImage;
    mask.contentsScale = maskImage.scale;
    blueContent.layer.mask = mask;
}

static void LGPositionTabBarBlueOverlay(UITabBar *bar,
                                        LGLiveBackdropView *lens) {
    UIView *overlay = LGTabBarBlueOverlay(bar, NO);
    if (!overlay || !lens) return;
    CGRect pillFrame = LGTabBarPillFrame(bar);
    CGRect overlayPill = LGTabBarLensPillRect(lens);
    overlay.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(overlayPill),
                                CGRectGetHeight(overlayPill));
    overlay.center = LGTabBarLensPillCenter(lens);
    overlay.layer.cornerRadius = CGRectGetHeight(overlayPill) * 0.5;
    UIView *blueContent =
        objc_getAssociatedObject(overlay, kLGTabBarBlueContentKey);
    blueContent.frame = CGRectMake(CGRectGetMinX(pillFrame) -
                                       CGRectGetMinX(overlay.frame),
                                   CGRectGetMinY(pillFrame) -
                                       CGRectGetMinY(overlay.frame),
                                   CGRectGetWidth(pillFrame),
                                   CGRectGetHeight(pillFrame));
}

static void LGStyleStockTabBar(UITabBar *bar) {
    if (!LGTabBarAllowed()) {
        LGRemoveTabBarInjection(bar);
        return;
    }
    if (!LGIsStockTabBar(bar) || !bar.window ||
        [objc_getAssociatedObject(bar, kLGTabBarStylingKey) boolValue]) return;

    objc_setAssociatedObject(bar, kLGTabBarStylingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(bar, kLGTabBarOriginalClipsKey,
                             @(bar.clipsToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bar, kLGTabBarOriginalMasksKey,
                             @(bar.layer.masksToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (bar.clipsToBounds) bar.clipsToBounds = NO;
    if (bar.layer.masksToBounds) bar.layer.masksToBounds = NO;

    UIView *stockBackground = nil;
    Class backgroundClass = objc_getClass("_UIBarBackground");
    for (UIView *view in bar.subviews) {
        if (backgroundClass && [view isKindOfClass:backgroundClass]) {
            stockBackground = view;
            break;
        }
    }
    if (stockBackground) {
        objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundHiddenKey,
                                 @(stockBackground.hidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        stockBackground.hidden = YES;
    }

    if (object_getClass(bar) == objc_getClass("UITabBar")) {
        UIColor *clear = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.0];
        if (!objc_getAssociatedObject(bar, kLGTabBarOriginalBarTintKey)) {
            objc_setAssociatedObject(bar, kLGTabBarOriginalBarTintKey,
                                     bar.barTintColor ?: NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundColorKey,
                                     bar.backgroundColor ?: NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!CGColorEqualToColor(bar.barTintColor.CGColor, clear.CGColor))
            bar.barTintColor = clear;
        if (!CGColorEqualToColor(bar.backgroundColor.CGColor, clear.CGColor))
            bar.backgroundColor = clear;
    }

    CGRect pillFrame = LGTabBarPillFrame(bar);
    const CGFloat height = CGRectGetHeight(pillFrame);

    LGLiveBackdropView *glass = objc_getAssociatedObject(bar, kLGTabBarGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(pillFrame, nil, @"TabBar");
        if (glass) {
            glass.userInteractionEnabled = NO;
            [bar insertSubview:glass atIndex:0];
            objc_setAssociatedObject(bar, kLGTabBarGlassKey, glass,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (glass && !CGRectEqualToRect(glass.frame, pillFrame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        glass.frame = pillFrame;
        [glass.layer setNeedsDisplay];
        [CATransaction commit];
        [glass applyFilters];
        NSUInteger generation =
            [objc_getAssociatedObject(bar, kLGTabBarGeometryGenerationKey)
                unsignedIntegerValue] + 1;
        objc_setAssociatedObject(bar, kLGTabBarGeometryGenerationKey,
                                 @(generation),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UITabBar *weakBar = bar;
        __weak LGLiveBackdropView *weakGlass = glass;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UITabBar *strongBar = weakBar;
            LGLiveBackdropView *strongGlass = weakGlass;
            if (!strongBar || !strongGlass.window ||
                [objc_getAssociatedObject(strongBar,
                    kLGTabBarGeometryGenerationKey) unsignedIntegerValue] !=
                    generation) return;
            [strongGlass.layer setNeedsDisplay];
            [strongGlass applyFilters];
        });
    }
    if (glass && fabs(glass.layer.cornerRadius - height * 0.5) > 0.01)
        glass.layer.cornerRadius = height * 0.5;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;

    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    if (buttons.count) {
        UIView *highlight =
            objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
        if (!highlight) {
            highlight = [[UIView alloc] initWithFrame:CGRectZero];
            highlight.userInteractionEnabled = NO;
            highlight.layer.masksToBounds = YES;
            if (@available(iOS 13.0, *)) {
                highlight.layer.cornerCurve = kCACornerCurveContinuous;
            }
            if (glass) [bar insertSubview:highlight aboveSubview:glass];
            else [bar insertSubview:highlight atIndex:0];
            objc_setAssociatedObject(bar, kLGTabBarSelectedHighlightKey,
                                     highlight,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        LGTabBarMotionState *motion = LGTabBarMotionStateForBar(bar, NO);
        BOOL transitioning = motion &&
            (motion.active || motion.awaitingTapDestination ||
             motion.awaitingRestingShape);
        NSUInteger selectedIndex = [bar.items indexOfObjectIdenticalTo:bar.selectedItem];
        if (selectedIndex != NSNotFound && selectedIndex < buttons.count) {
            BOOL dark = bar.traitCollection.userInterfaceStyle ==
                        UIUserInterfaceStyleDark;
            if (!transitioning) {
                UIView *selectedButton = buttons[selectedIndex];
                CGRect buttonFrame = [selectedButton.superview
                    convertRect:selectedButton.frame toView:bar];
                CGRect highlightBounds = CGRectMake(0.0, 0.0,
                                                    CGRectGetWidth(buttonFrame),
                                                    LGTabBarHighlightHeight(bar));
                CGPoint highlightCenter = CGPointMake(CGRectGetMidX(buttonFrame),
                                                      CGRectGetMidY(pillFrame));
                if (!CGRectEqualToRect(highlight.bounds, highlightBounds))
                    highlight.bounds = highlightBounds;
                if (!CGPointEqualToPoint(highlight.center, highlightCenter))
                    highlight.center = highlightCenter;
                if (fabs(highlight.layer.cornerRadius -
                         LGTabBarHighlightHeight(bar) * 0.5) > 0.01)
                    highlight.layer.cornerRadius = LGTabBarHighlightHeight(bar) * 0.5;
                highlight.backgroundColor =
                    [UIColor colorWithWhite:dark ? 1.0 : 0.0
                                      alpha:dark ? 0.10 : 0.06];
                highlight.alpha = 1.0;
                highlight.hidden = NO;
            } else {
                highlight.hidden = NO;
                if (!motion.awaitingRestingShape) highlight.alpha = 0.0;
            }
        } else {
            highlight.hidden = YES;
        }
    }

    objc_setAssociatedObject(bar, kLGTabBarStylingKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static UITabBar *LGTabBarForButton(UIView *button) {
    for (UIView *view = button.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UITabBar class]]) return (UITabBar *)view;
    }
    return nil;
}



static BOOL LGTabBarRemapButtonFrame(UIView *button, CGRect *frame) {
    if (!button || !LGTabBarAllowed()) return NO;
    UITabBar *bar = LGTabBarForButton(button);
    if (!bar || !LGIsStockTabBar(bar) || !bar.window) return NO;
    if (!objc_getAssociatedObject(bar, kLGTabBarGlassKey)) return NO;

    CGFloat barWidth = CGRectGetWidth(bar.bounds);
    if (barWidth < 1.0) return NO;

    NSValue *previous = objc_getAssociatedObject(button, kLGTabBarRemapOutKey);
    if (previous && CGRectEqualToRect(previous.CGRectValue, *frame)) return NO;

    CGRect pill = CGRectInset(LGTabBarPillFrame(bar), 4.0, 0.0);
    if (CGRectIsEmpty(pill)) return NO;
    CGFloat scale = CGRectGetWidth(pill) / barWidth;

    CGRect mapped = *frame;
    mapped.origin.x = CGRectGetMinX(pill) + CGRectGetMinX(*frame) * scale;
    mapped.size.width = CGRectGetWidth(*frame) * scale;
    CGFloat height = MAX(1.0, CGRectGetHeight(*frame) - LGTabBarAppliedOverhang(bar));
    mapped.size.height = height;
    mapped.origin.y = CGRectGetMidY(pill) - height * 0.5;

    objc_setAssociatedObject(button, kLGTabBarRemapOutKey,
                             [NSValue valueWithCGRect:mapped],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    *frame = mapped;
    return YES;
}

static void LGStopTabBarSelectionAnimation(LGLiveBackdropView *lens) {
    UIViewPropertyAnimator *animator =
        objc_getAssociatedObject(lens, kLGTabBarSelectionAnimatorKey);
    [animator stopAnimation:YES];
    objc_setAssociatedObject(lens, kLGTabBarSelectionAnimatorKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static LGLiveBackdropView *LGTabBarSelectionLens(UITabBar *bar) {
    if (!LGTabBarAllowed() || !LGIsStockTabBar(bar)) return nil;
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (lens) return lens;

    lens = LGCreateRegisteredGlass(CGRectZero, nil, @"TabBarSelection");
    if (!lens) return nil;
    lens.userInteractionEnabled = NO;
    lens.hidden = YES;
    lens.alpha = 0.0;
    lens.lgSpecularEnabledOverride = @NO;
    lens.layer.masksToBounds = NO;
    if (@available(iOS 13.0, *)) lens.layer.cornerCurve = kCACornerCurveContinuous;

    LGLiveBackdropView *base = objc_getAssociatedObject(bar, kLGTabBarGlassKey);
    if (base) [bar insertSubview:lens aboveSubview:base];
    else [bar insertSubview:lens atIndex:0];
    objc_setAssociatedObject(bar, kLGTabBarSelectionGlassKey, lens,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return lens;
}

static CGRect LGTabBarLensFrameForButton(UITabBar *bar, UIView *button) {
    CGRect buttonFrame = [button.superview convertRect:button.frame toView:bar];
    CGRect pillFrame = LGTabBarPillFrame(bar);
    const CGFloat height = LGTabBarLensHeight(bar);
    const CGFloat width = LGTabBarLensWidth(bar);
    CGFloat centerX = CGRectGetMidX(buttonFrame);
    centerX = MIN(CGRectGetMaxX(pillFrame) - width * 0.5,
                  MAX(CGRectGetMinX(pillFrame) + width * 0.5, centerX));
    return CGRectMake(centerX - width * 0.5,
                      CGRectGetMidY(pillFrame) - height * 0.5,
                      width, height);
}

static LGTabBarMotionState *LGTabBarMotionStateForBar(UITabBar *bar,
                                                       BOOL create) {
    LGTabBarMotionState *state =
        objc_getAssociatedObject(bar, kLGTabBarMotionStateKey);
    if (!state && create) {
        state = [LGTabBarMotionState new];
        state.bar = bar;
        objc_setAssociatedObject(bar, kLGTabBarMotionStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL LGTabBarMotionRange(UITabBar *bar, CGFloat *minimum,
                                CGFloat *maximum) {
    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    if (!buttons.count) return NO;
    UIView *first = buttons.firstObject;
    UIView *last = buttons.lastObject;
    CGRect firstFrame = [first.superview convertRect:first.frame toView:bar];
    CGRect lastFrame = [last.superview convertRect:last.frame toView:bar];
    if (minimum) *minimum = CGRectGetMidX(firstFrame);
    if (maximum) *maximum = CGRectGetMidX(lastFrame);
    return YES;
}

static void LGBeginTabBarLiquidMotion(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      UITabBarButton *button,
                                      UITouch *touch) {
    // one display link owns drag spring and release travel
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, YES);
    [state stop];
    CGRect frame = LGTabBarLensFrameForButton(bar, button);
    CGRect buttonFrame =
        [button.superview convertRect:button.frame toView:bar];
    CGFloat centerX = CGRectGetMidX(frame);
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    CGFloat restingCenterX = highlight
        ? highlight.center.x : CGRectGetMidX(buttonFrame);
    CGFloat restingWidth = highlight && CGRectGetWidth(highlight.bounds) > 0.0
        ? CGRectGetWidth(highlight.bounds) : CGRectGetWidth(buttonFrame);
    state.bar = bar;
    state.lens = lens;
    state.generation += 1;
    state.awaitingTapDestination = NO;
    state.awaitingRestingShape = NO;
    state.active = YES;
    state.targetCenterX = centerX;
    state.targetWidth = LGTabBarLensWidth(bar);
    state.targetHeight = LGTabBarLensHeight(bar);
    state.renderedCenterX = restingCenterX;
    state.renderedWidth = restingWidth;
    state.renderedHeight = LGTabBarHighlightHeight(bar);
    state.widthVelocity = 0.0;
    state.heightVelocity = 0.0;
    state.velocityX = 0.0;
    state.gestureStartX = touch ? [touch locationInView:bar].x : centerX;
    state.lastTouchX = state.gestureStartX;
    state.dragged = NO;
    state.lastTouchTime = CACurrentMediaTime();
    CGFloat restingHeight = LGTabBarHighlightHeight(bar);
    LGSetTabBarLensPill(bar, lens,
        CGRectMake(restingCenterX - restingWidth * 0.5,
                   CGRectGetMidY(LGTabBarPillFrame(bar)) - restingHeight * 0.5,
                   restingWidth, restingHeight));
    [state start];
}

static void LGShowTabBarSelectionLens(UITabBarButton *button, UITouch *touch) {
    if (!LGTabBarAllowed()) return;
    UITabBar *bar = LGTabBarForButton(button);
    if (!LGIsStockTabBar(bar)) return;
    LGStyleStockTabBar(bar);

    LGLiveBackdropView *lens = LGTabBarSelectionLens(bar);
    if (!lens) return;
    LGStopTabBarSelectionAnimation(lens);

    [bar bringSubviewToFront:lens];
    LGSetTabBarLensPill(bar, lens, LGTabBarLensFrameForButton(bar, button));
    lens.hidden = NO;
    lens.alpha = 1.0;
    lens.transform = CGAffineTransformIdentity;
    lens.backgroundColor = UIColor.clearColor;
    UIView *selectedHighlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    selectedHighlight.hidden = NO;
    selectedHighlight.alpha = 0.0;
    if (!objc_getAssociatedObject(bar, kLGTabBarOriginalTintKey)) {
        objc_setAssociatedObject(bar, kLGTabBarOriginalTintKey,
                                 bar.tintColor ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(bar, kLGTabBarAccentColorKey,
                             bar.tintColor ?: UIColor.systemBlueColor,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *neutralTint = bar.unselectedItemTintColor;
    if (!neutralTint) {
        neutralTint = [UIColor colorWithWhite:
            bar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
                ? 0.65 : 0.35 alpha:1.0];
    }
    bar.tintColor = neutralTint;
    LGBeginTabBarLiquidMotion(bar, lens, button, touch);
    LGRebuildTabBarBlueMask(bar);
    UIView *blueOverlay = LGTabBarBlueOverlay(bar, YES);
    LGPositionTabBarBlueOverlay(bar, lens);
    [bar bringSubviewToFront:blueOverlay];

    [bar bringSubviewToFront:lens];
    blueOverlay.hidden = NO;
    blueOverlay.alpha = 0.0;
    blueOverlay.transform = CGAffineTransformIdentity;

    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.12
                                                  curve:UIViewAnimationCurveEaseOut
                                             animations:nil];
    [animator addAnimations:^{
        blueOverlay.alpha = 1.0;
    }];
    objc_setAssociatedObject(lens, kLGTabBarSelectionAnimatorKey, animator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [animator startAnimation];
}

static void LGMoveTabBarSelectionLens(UITabBarButton *button, UITouch *touch) {
    UITabBar *bar = LGTabBarForButton(button);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (!lens || lens.hidden) return;

    CGPoint point = [touch locationInView:bar];
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, YES);
    if (fabs(point.x - state.gestureStartX) > 4.0) state.dragged = YES;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = MAX(now - state.lastTouchTime, 0.001);
    CGFloat rawVelocity = (point.x - state.lastTouchX) / dt;
    state.velocityX = LGLiquidFilteredVelocity(state.velocityX, rawVelocity);
    state.lastTouchX = point.x;
    state.lastTouchTime = now;

    CGFloat minimum = 0.0, maximum = 0.0;
    if (!LGTabBarMotionRange(bar, &minimum, &maximum)) return;
    LGLiquidDragState drag = LGLiquidDragStateMake(
        point.x, minimum, maximum,
        CGSizeMake(LGTabBarLensWidth(bar), LGTabBarLensHeight(bar)),
        state.velocityX, 58.0);
    state.active = YES;
    state.targetCenterX = drag.centerX;
    state.targetWidth = drag.width;
    state.targetHeight = drag.height;
    [state start];
}

static UITabBarButton *LGNearestTabBarButton(UITabBar *bar, CGFloat centerX) {
    UITabBarButton *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (UIView *view in LGStockTabBarButtons(bar)) {
        CGRect frame = [view.superview convertRect:view.frame toView:bar];
        CGFloat distance = fabs(CGRectGetMidX(frame) - centerX);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = (UITabBarButton *)view;
        }
    }
    return nearest;
}

static void LGCommitTabBarSelectionAtLens(UITabBarButton *trackingButton,
                                          UITouch *touch) {
    UITabBar *bar = LGTabBarForButton(trackingButton);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    CGPoint touchInBar = touch ? [touch locationInView:bar] : CGPointZero;
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"[TABBAR INTERACTION] bar=%p tracking=%p touch=%@ lens=%p "
         "lensHidden=%d lensFrame=%@ selectedBefore=%p\n",
        bar, trackingButton, NSStringFromCGPoint(touchInBar), lens,
        lens.hidden, NSStringFromCGRect(LGTabBarLensPillRect(lens)), bar.selectedItem];
    if (!lens || lens.hidden) {
        [log appendString:@"result=aborted-no-visible-lens\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }

    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    UITabBarButton *target = state && !state.dragged
        ? trackingButton : LGNearestTabBarButton(bar, LGTabBarLensPillCenter(lens).x);
    if (!target) {
        [log appendString:@"result=aborted-no-nearest-button\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }

    BOOL originalWillCommit =
        target == trackingButton &&
        CGRectContainsPoint(trackingButton.bounds,
                            [touch locationInView:trackingButton]);

    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    NSUInteger index = [buttons indexOfObjectIdenticalTo:target];
    [buttons enumerateObjectsUsingBlock:^(UIView *button, NSUInteger buttonIndex,
                                          __unused BOOL *stop) {
        CGRect frame = [button.superview convertRect:button.frame toView:bar];
        [log appendFormat:@"button[%lu]=%p frame=%@ centerX=%.2f%@\n",
            (unsigned long)buttonIndex, button, NSStringFromCGRect(frame),
            CGRectGetMidX(frame), button == target ? @" TARGET" : @""];
    }];
    [log appendFormat:
        @"target=%p targetIndex=%@ itemCount=%lu delegate=%p/%@ "
         "originalWillCommit=%d\n",
        target, index == NSNotFound ? @"NSNotFound" :
            [NSString stringWithFormat:@"%lu", (unsigned long)index],
        (unsigned long)bar.items.count, bar.delegate,
        NSStringFromClass([bar.delegate class]), originalWillCommit];
    if (originalWillCommit) {
        [log appendString:@"result=native-original-button\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }
    if (index == NSNotFound || index >= bar.items.count) {
        [log appendString:@"result=aborted-index-item-mismatch\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }
    UITabBarItem *item = bar.items[index];

    id delegate = bar.delegate;
    if ([delegate isKindOfClass:[UITabBarController class]]) {
        UITabBarController *controller = (UITabBarController *)delegate;
        NSString *initialLog = [log copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            controller.selectedIndex = index;
            NSString *result = [initialLog stringByAppendingFormat:
                @"result=deferred-controller-index selectedAfter=%p "
                 "controllerIndexAfter=%lu\n",
                bar.selectedItem, (unsigned long)controller.selectedIndex];
            LGPersistTabBarDump(result, @"interaction-release");
        });
        return;
    }

    NSString *initialLog = [log copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        bar.selectedItem = item;
        SEL didSelect = @selector(tabBar:didSelectItem:);
        BOOL calledDelegate = [delegate respondsToSelector:didSelect];
        if (calledDelegate) {
            ((void (*)(id, SEL, UITabBar *, UITabBarItem *))objc_msgSend)(
                delegate, didSelect, bar, item);
        }
        NSString *result = [initialLog stringByAppendingFormat:
            @"result=deferred-standalone delegateCallback=%d selectedAfter=%p\n",
            calledDelegate, bar.selectedItem];
        LGPersistTabBarDump(result, @"interaction-release");
    });
}

static void LGFinalizeTabBarSelection(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      LGTabBarMotionState *state) {
    if (!bar || !lens || lens.hidden) return;
    UIView *blueOverlay = LGTabBarBlueOverlay(bar, NO);
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    lens.alpha = 0.0;
    lens.hidden = YES;
    lens.backgroundColor = UIColor.clearColor;
    highlight.alpha = 1.0;
    highlight.hidden = NO;
    if (blueOverlay) {
        blueOverlay.hidden = YES;
        blueOverlay.alpha = 0.0;
        blueOverlay.transform = CGAffineTransformIdentity;
    }
    [CATransaction commit];
    id originalTint =
        objc_getAssociatedObject(bar, kLGTabBarOriginalTintKey);
    bar.tintColor = originalTint == NSNull.null ? nil : originalTint;
    objc_setAssociatedObject(bar, kLGTabBarOriginalTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarAccentColorKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    [state stop];
    LGStyleStockTabBar(bar);
}

static void LGHideTabBarSelectionLens(UITabBarButton *button) {
    UITabBar *bar = LGTabBarForButton(button);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (!lens || lens.hidden) return;
    LGStopTabBarSelectionAnimation(lens);
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    BOOL isTap = state && !state.dragged;
    UITabBarButton *nearest = isTap
        ? button : LGNearestTabBarButton(bar, LGTabBarLensPillCenter(lens).x);
    CGRect frame = nearest
        ? [nearest.superview convertRect:nearest.frame toView:bar]
        : CGRectZero;
    if (state) {

        state.active = isTap;
        state.targetCenterX = nearest ? CGRectGetMidX(frame)
                                      : LGTabBarLensPillCenter(lens).x;
        state.targetWidth = isTap ? LGTabBarLensWidth(bar)
                                  : (nearest ? CGRectGetWidth(frame)
                                             : state.renderedWidth);
        state.targetHeight = isTap ? LGTabBarLensHeight(bar)
                                   : LGTabBarHighlightHeight(bar);
        state.velocityX = 0.0;
        state.awaitingTapDestination = isTap;
        state.awaitingRestingShape = !isTap;
        state.restingTargetWidth = nearest ? CGRectGetWidth(frame)
                                           : state.renderedWidth;
        if (!isTap) {
            state.collapseStartDistance =
                hypot(state.renderedWidth - state.targetWidth,
                      state.renderedHeight - state.targetHeight);
        }
        state.destinationStartTime = CACurrentMediaTime();
        [state start];
    }

}

static void LGPersistTabBarDump(NSString *dump, NSString *reason) {
    if (!dump.length) return;
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"liquidass-tabbar.plist"];
    NSArray *existing = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray *entries = [existing isKindOfClass:[NSArray class]]
        ? [existing mutableCopy] : [NSMutableArray array];
    [entries addObject:@{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"pid": @(getpid()),
        @"reason": reason ?: @"unknown",
        @"dump": dump,
    }];
    while (entries.count > 12) [entries removeObjectAtIndex:0];
    [entries writeToFile:path atomically:YES];
}

static NSString *LGTabBarColorDescription(UIColor *color) {
    if (!color) return @"nil";
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)", r, g, b, a];
    }
    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&a]) {
        return [NSString stringWithFormat:@"white(%.3f,%.3f)", white, a];
    }
    return color.description ?: @"unknown";
}

static void LGAppendTabBarViewTree(NSMutableString *output, UIView *view,
                                   NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 5 || *visited >= 120) return;
    (*visited)++;

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger index = 0; index < depth; index++) [indent appendString:@"  "];

    CGRect windowFrame = CGRectNull;
    if (view.window) {
        @try {
            windowFrame = [view convertRect:view.bounds toView:view.window];
        } @catch (__unused NSException *exception) {}
    }

    CALayer *layer = view.layer;
    NSString *maskClass = layer.mask ? NSStringFromClass(layer.mask.class) : @"nil";
    [output appendFormat:
        @"%@[%lu] %@ %p frame=%@ bounds=%@ window=%@ alpha=%.3f hidden=%d "
         "opaque=%d user=%d bg=%@ layer=%@ radius=%.2f curve=%@ masks=%d "
         "mask=%@ subviews=%lu constraints=%lu autoresize=0x%lx\n",
        indent, (unsigned long)depth, NSStringFromClass(view.class), view,
        NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
        NSStringFromCGRect(windowFrame), view.alpha, view.hidden, view.opaque,
        view.userInteractionEnabled, LGTabBarColorDescription(view.backgroundColor),
        NSStringFromClass(layer.class), layer.cornerRadius,
        layer.cornerCurve ?: @"nil", layer.masksToBounds, maskClass,
        (unsigned long)view.subviews.count, (unsigned long)view.constraints.count,
        (unsigned long)view.autoresizingMask];

    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        [output appendFormat:@"%@  control state=0x%lx enabled=%d selected=%d "
                              "highlighted=%d label=%@\n",
            indent, (unsigned long)control.state, control.enabled, control.selected,
            control.highlighted, control.accessibilityLabel ?: @"nil"];
    }

    for (UIView *subview in view.subviews) {
        LGAppendTabBarViewTree(output, subview, depth + 1, visited);
        if (*visited >= 120) break;
    }
}

static NSString *LGTabBarSignature(UITabBar *bar) {
    NSMutableString *signature = [NSMutableString stringWithFormat:
        @"%@|%@|%@|%.3f|%lu|",
        NSStringFromCGRect(bar.frame), NSStringFromCGRect(bar.bounds),
        NSStringFromUIEdgeInsets(bar.safeAreaInsets), bar.alpha,
        (unsigned long)bar.items.count];
    for (UITabBarItem *item in bar.items) {
        [signature appendFormat:@"%p:%ld:%d:%@|", item, (long)item.tag,
         item.enabled, item == bar.selectedItem ? @"selected" : @"normal"];
    }
    for (UIView *subview in bar.subviews) {
        [signature appendFormat:@"%@:%@:%d:%.2f|", NSStringFromClass(subview.class),
         NSStringFromCGRect(subview.frame), subview.hidden, subview.alpha];
    }
    return signature;
}

static void LGDumpTabBar(UITabBar *bar, NSString *reason) {
    if (!bar.window) return;

    NSString *signature = LGTabBarSignature(bar);
    NSString *previous = objc_getAssociatedObject(bar, kLGTabBarLastSignatureKey);
    if ([previous isEqualToString:signature]) return;
    objc_setAssociatedObject(bar, kLGTabBarLastSignatureKey, signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIWindow *window = bar.window;
    id scrollEdgeAppearance = nil;
    if ([bar respondsToSelector:NSSelectorFromString(@"scrollEdgeAppearance")]) {
        @try { scrollEdgeAppearance = [bar valueForKey:@"scrollEdgeAppearance"]; }
        @catch (__unused NSException *exception) {}
    }
    NSMutableString *dump = [NSMutableString stringWithFormat:
        @"[TABBAR] reason=%@ process=%@ os=%@ bar=%p class=%@ window=%p/%@ "
         "windowBounds=%@ screenScale=%.2f frame=%@ bounds=%@ safe=%@ "
         "layoutMargins=%@ intrinsic=%@ standardAppearance=%p scrollEdgeAppearance=%p "
         "items=%lu selected=%p\n",
        reason ?: @"unknown", NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        UIDevice.currentDevice.systemVersion, bar, NSStringFromClass(bar.class),
        window, NSStringFromClass(window.class), NSStringFromCGRect(window.bounds),
        window.screen.scale, NSStringFromCGRect(bar.frame), NSStringFromCGRect(bar.bounds),
        NSStringFromUIEdgeInsets(bar.safeAreaInsets),
        NSStringFromUIEdgeInsets(bar.layoutMargins),
        NSStringFromCGSize(bar.intrinsicContentSize), bar.standardAppearance,
        scrollEdgeAppearance, (unsigned long)bar.items.count, bar.selectedItem];

    [bar.items enumerateObjectsUsingBlock:^(UITabBarItem *item, NSUInteger index,
                                            __unused BOOL *stop) {
        [dump appendFormat:
            @"  item[%lu]=%p title=%@ tag=%ld enabled=%d selected=%d badge=%@ "
             "image=%@ selectedImage=%@ accessibility=%@\n",
            (unsigned long)index, item, item.title ?: @"nil", (long)item.tag,
            item.enabled, item == bar.selectedItem, item.badgeValue ?: @"nil",
            item.image.description ?: @"nil", item.selectedImage.description ?: @"nil",
            item.accessibilityLabel ?: @"nil"];
    }];

    NSUInteger visited = 0;
    LGAppendTabBarViewTree(dump, bar, 0, &visited);
    if (visited >= 120) [dump appendString:@"  ... hierarchy truncated at 120 views\n"];
    LGLog(@"%@", dump);
    LGPersistTabBarDump(dump, reason);
}

static void LGScheduleTabBarDump(UITabBar *bar, NSString *reason) {

    (void)bar;
    (void)reason;
    return;

    if (!bar.window || [objc_getAssociatedObject(bar, kLGTabBarPendingDumpKey) boolValue])
        return;
    objc_setAssociatedObject(bar, kLGTabBarPendingDumpKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITabBar *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBar *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, kLGTabBarPendingDumpKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGDumpTabBar(strongBar, reason);
    });
}

%hook UITabBar

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (LGTabBarCanReceiveTouches(self) &&
        CGRectContainsPoint(LGTabBarPillFrame(self), point)) {
        for (UIView *button in LGStockTabBarButtons(self)) {
            if (button.hidden || button.alpha < 0.01 ||
                !button.userInteractionEnabled ||
                ([button isKindOfClass:UIControl.class] &&
                 !((UIControl *)button).enabled)) continue;
            CGRect frame = [button.superview convertRect:button.frame toView:self];
            if (CGRectContainsPoint(frame, point)) return button;
        }
    }
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (LGTabBarCanReceiveTouches(self) &&
        CGRectContainsPoint(LGTabBarPillFrame(self), point)) return YES;
    return %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGHookTabBarHostControllers();
        LGStyleStockTabBar(self);
        LGScheduleTabBarDump(self, @"didMoveToWindow");
    }
}

- (void)layoutSubviews {
    %orig;
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"layoutSubviews");
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (self.window) LGStyleStockTabBar(self);
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fitted = %orig;
    if (!LGTabBarAllowed() || !LGIsStockTabBar(self)) return fitted;
    CGFloat content = fitted.height - self.safeAreaInsets.bottom;
    CGFloat overhang = MAX(0.0, LGTabBarRequiredContentHeight(self) - content);
    objc_setAssociatedObject(self, kLGTabBarAppliedOverhangKey, @(overhang),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    fitted.height += overhang;
    return fitted;
}


- (void)setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)animated {
    %orig(items, animated);
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"setItems");
}

- (void)setSelectedItem:(UITabBarItem *)item {
    %orig(item);
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"setSelectedItem");
}

%end

static void LGRefreshTabBarsInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class]) {
        LGStyleStockTabBar((UITabBar *)view);
    }
    for (UIView *subview in view.subviews) LGRefreshTabBarsInView(subview);
}


static NSMutableDictionary<NSString *, NSValue *> *g_tabBarHostOrigs;

static void LGHookedHostDidLayout(id self, SEL _cmd) {
    IMP orig = NULL;
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        NSValue *stored = g_tabBarHostOrigs[NSStringFromClass(cls)];
        if (stored) { orig = (IMP)stored.pointerValue; break; }
    }
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    if (!LGTabBarAllowed()) return;
    if (![self respondsToSelector:@selector(view)]) return;
    UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(view));
    if (view) LGRefreshTabBarsInView(view);
}

static void LGHookTabBarHostControllers(void) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_tabBarHostOrigs = [NSMutableDictionary dictionary];
        names = @[
            @"Sileo.TabBarController",
            @"MusicApplication.TabBarController",
            @"PHSTabBarController",
            @"WATabBarController",
            @"FBTabNavigationViewController",
            @"LineUtilUIComponents.RootTabBarController",
            @"LineHomeTab.FriendTabViewController",
            @"MainTabBar_Community.CommunityTabViewController",
            @"Rooms.RoomsRootViewController",
            @"Inbox_RedditInbox.InboxActivityViewController",
            @"SubredditWidgets.SubredditWrapperViewController",
            @"Deezer.CurrentUserLibraryRootViewController",
            @"Deezer.MiniPlayerViewController",
            @"HomePageModule.HomeVerticalLandingPageViewController",
            @"EngagementModule.MyEbayLandingViewController",
            @"SearchModule.SearchResultsViewController",
            @"IGChainingFeedViewController",
            @"IGSundialFeedViewController",
        ];
    });
    for (NSString *name in names) {
        if (g_tabBarHostOrigs[name]) continue;
        Class cls = NSClassFromString(name);
        if (!cls) continue;   // framework not loaded yet, retried later
        SEL selector = @selector(viewDidLayoutSubviews);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        IMP orig = method_getImplementation(method);
        if (!class_addMethod(cls, selector, (IMP)LGHookedHostDidLayout,
                             method_getTypeEncoding(method))) {
            orig = method_setImplementation(method, (IMP)LGHookedHostDidLayout);
        }
        if (orig) g_tabBarHostOrigs[name] = [NSValue valueWithPointer:orig];
    }
}

%ctor {
    LGHookTabBarHostControllers();
    lgObservePreferenceReload(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                LGRefreshTabBarsInView(window);
            }
        });
    });
}

%hook UITabBarButton

- (void)setFrame:(CGRect)frame {
    CGRect mapped = frame;
    %orig(LGTabBarRemapButtonFrame(self, &mapped) ? mapped : frame);
}

- (void)layoutSubviews {
    %orig;
    UITabBar *bar = LGTabBarForButton(self);
    if (LGTabBarAllowed() && LGIsStockTabBar(bar))
        LGCenterStockTabBarButtonContent(self);
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (tracking && LGTabBarAllowed())
        LGShowTabBarSelectionLens(self, touch);
    return tracking;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (!LGTabBarAllowed()) return tracking;
    LGTabBarMotionState *state =
        LGTabBarMotionStateForBar(LGTabBarForButton(self), NO);
    if (tracking || state.active) LGMoveTabBarSelectionLens(self, touch);
    return tracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    if (!LGTabBarAllowed()) return;
    LGCommitTabBarSelectionAtLens(self, touch);
    LGHideTabBarSelectionLens(self);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    if (LGTabBarAllowed()) LGHideTabBarSelectionLens(self);
}

%end

static const CGFloat kLGZoomControlTabBarGap = 5.0;

static UITabBar *LGFindTabBarInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class]) return (UITabBar *)view;
    for (UIView *subview in view.subviews) {
        UITabBar *found = LGFindTabBarInView(subview);
        if (found) return found;
    }
    return nil;
}

@interface PXCuratedLibraryZoomLevelControl : UIView
@end

%hook PXCuratedLibraryZoomLevelControl

- (void)layoutSubviews {
    %orig;
    if (!LGTabBarAllowed()) return;
    UIView *host = self.superview;
    if (!host || !self.window) return;
    UITabBar *bar = LGFindTabBarInView(self.window);
    if (!bar || bar.hidden || !LGIsStockTabBar(bar)) return;

    CGFloat lift = 0.0;
    for (UIView *sub in bar.subviews)
        lift = MIN(lift, CGRectGetMinY(sub.frame));
    CGRect barTop = bar.bounds;
    barTop.origin.y += lift;
    barTop.size.height -= lift;
    CGRect barInHost = [host convertRect:barTop fromView:bar];
    CGFloat wanted = CGRectGetMinY(barInHost) - kLGZoomControlTabBarGap
                   - CGRectGetHeight(self.frame);

    CGFloat shift = wanted - CGRectGetMinY(self.frame);
    if (fabs(shift) < 0.5) return;
    CGRect box = host.frame;
    box.origin.y += shift;
    host.frame = box;
}

%end
