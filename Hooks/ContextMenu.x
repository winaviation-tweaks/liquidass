#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kCtxDividerTag    = 0xD171;
static const CGFloat   kCtxCornerRadius  = 22.0;
static const CGFloat   kCtxRowInset      = 16.0;
static const CGFloat   kCtxIconSpacing   = 12.0;
static void *kCtxGlassKey         = &kCtxGlassKey;
static void *kCtxVibranceKey      = &kCtxVibranceKey;
static void *kCtxGapOriginalBgKey = &kCtxGapOriginalBgKey;
static void *kCtxOriginalAlphaKey = &kCtxOriginalAlphaKey;
static void *kCtxOriginalHiddenKey = &kCtxOriginalHiddenKey;
static void *kCtxOriginalRadiusKey = &kCtxOriginalRadiusKey;
static void *kCtxOriginalCurveKey = &kCtxOriginalCurveKey;
static void *kCtxOriginalFrameKey = &kCtxOriginalFrameKey;
static void *kCtxGlowViewKey      = &kCtxGlowViewKey;
static void *kCtxGestureKey       = &kCtxGestureKey;
static void *kCtxCellPillKey      = &kCtxCellPillKey;

@interface _UIContextMenuListView : UIView
@property (nonatomic, readonly) UICollectionView *collectionView;
@end

@interface _UIContextMenuView : UIView
@property (nonatomic, readonly) _UIContextMenuListView *currentListView;
- (void)_handleSelectionGesture:(UIGestureRecognizer *)gesture;
@end

static void ctxRememberVisualState(UIView *view) {
    if (!view) return;
    if (!objc_getAssociatedObject(view, kCtxOriginalAlphaKey)) {
        objc_setAssociatedObject(view, kCtxOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kCtxOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kCtxOriginalRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kCtxOriginalCurveKey, view.layer.cornerCurve ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static void ctxRememberFrame(UIView *view) {
    if (view && !objc_getAssociatedObject(view, kCtxOriginalFrameKey))
        objc_setAssociatedObject(view, kCtxOriginalFrameKey, [NSValue valueWithCGRect:view.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *findDescendantMatching(UIView *root, BOOL (^match)(UIView *v)) {
    for (UIView *sub in root.subviews) {
        if (match(sub)) return sub;
        UIView *found = findDescendantMatching(sub, match);
        if (found) return found;
    }
    return nil;
}

static BOOL isInsideContextMenu(UIView *v) {
    if (!v) return NO;
    static Class containerClass = nil;
    static Class listClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        containerClass = NSClassFromString(@"_UIContextMenuContainerView");
        listClass = NSClassFromString(@"_UIContextMenuListView");
    });
    if (!containerClass && !listClass) return NO;
    int depth = 0;
    for (UIView *p = v.superview; p && depth < 12; p = p.superview, depth++) {
        if ((containerClass && [p isKindOfClass:containerClass]) ||
            (listClass && [p isKindOfClass:listClass])) {
            return YES;
        }
    }
    return NO;
}

static BOOL ctxCellContextViewIsStock(UIView *view) {
    if (!isExactClass(view, @"_UIContextMenuCellContextView")) return NO;
    if (!isExactClass(view.superview, @"_UIContextMenuCell")) return NO;
    return findDescendantMatching(view, ^BOOL(UIView *c) {
        return [c isKindOfClass:[UIStackView class]];
    }) != nil;
}

static BOOL shouldRoundContextMenuSubview(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"LGCtxMenuGlowView")] ||
        [view.superview isKindOfClass:NSClassFromString(@"LGCtxMenuGlowView")]) return NO;
    if ([view isKindOfClass:NSClassFromString(@"LGCtxMenuPillView")]) return NO;
    if ([view isKindOfClass:NSClassFromString(@"LGCtxMenuVibranceView")]) return NO;
    if (isExactClass(view, @"_UIContextMenuCellContextView"))
        return ctxCellContextViewIsStock(view);
    CGSize s = view.bounds.size;
    return s.width >= 20.0 && s.height >= 20.0;
}

static void applyContextMenuRoundedStyle(UIView *view) {
    ctxRememberVisualState(view);
    CGFloat r = kCtxCornerRadius;
    if (isExactClass(view, @"_UIContextMenuCellContentView") ||
        isExactClass(view, @"_UIContextMenuCellContextView")) {
        CGFloat pill = CGRectGetHeight(view.bounds) * 0.5;
        if (pill > 0.0) r = pill;
    }
    if (fabs(view.layer.cornerRadius - r) > 0.5) view.layer.cornerRadius = r;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static BOOL shouldHideContextMenuSeparatorView(UIView *view) {
    if ([view isKindOfClass:[LGLiveBackdropView class]]) return NO;
    if (view.tag == kCtxDividerTag) return NO;
    if ([view isKindOfClass:[UIVisualEffectView class]]) return NO;
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"Separator"]) return YES;
    CGSize s = view.bounds.size;
    BOOL thinH = s.height > 0.0 && s.height <= 2.0 && s.width  >= 24.0;
    BOOL thinV = s.width  > 0.0 && s.width  <= 2.0 && s.height >= 24.0;
    return (thinH || thinV) && (view.backgroundColor || view.layer.backgroundColor);
}

static BOOL isContextMenuReusableGapView(UIView *view) {
    return isExactClass(view, @"UICollectionReusableView");
}

static UIColor *contextMenuDividerColor(UIView *view) {
    UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
        return [UIColor colorWithWhite:1.0 alpha:0.16];
    return [UIColor colorWithWhite:0.0 alpha:0.10];
}

static void styleContextMenuReusableGapView(UIView *view) {
    ctxRememberVisualState(view);
    UIColor *bg = view.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.001 &&
        !objc_getAssociatedObject(view, kCtxGapOriginalBgKey))
        objc_setAssociatedObject(view, kCtxGapOriginalBgKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = NO;
    view.alpha  = 1.0;
    view.backgroundColor = UIColor.clearColor;

    UIView *divider = [view viewWithTag:kCtxDividerTag];
    if (!divider) {
        divider = [[UIView alloc] initWithFrame:CGRectZero];
        divider.tag = kCtxDividerTag;
        divider.userInteractionEnabled = NO;
        [view addSubview:divider];
    }
    CGFloat inset = MAX(18.0, kCtxRowInset);
    CGFloat lineHeight = 2.0;
    CGFloat width = MAX(0.0, view.bounds.size.width - inset * 2.0);
    CGFloat y = round((view.bounds.size.height - lineHeight) * 0.5);
    divider.frame = CGRectMake(inset, y, width, lineHeight);
    divider.backgroundColor = contextMenuDividerColor(view);
    divider.layer.cornerRadius  = lineHeight * 0.5;
    divider.layer.masksToBounds = YES;

    for (UIView *inner in view.subviews) {
        if (inner == divider) continue;
        ctxRememberVisualState(inner);
        inner.hidden = YES;
        inner.alpha  = 0.0;
    }
}

static BOOL isContextMenuCutoutShadow(UIView *view) {
    return isExactClass(view, @"_UICutoutShadowView") &&
           isExactClass(view.superview, @"_UIContextMenuListView");
}

static void hideContextMenuSeparators(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (shouldHideContextMenuSeparatorView(sub) ||
            isContextMenuCutoutShadow(sub)) {
            ctxRememberVisualState(sub);
            sub.hidden = YES;
            sub.alpha  = 0.0;
        } else if (isContextMenuReusableGapView(sub)) {
            styleContextMenuReusableGapView(sub);
        }
        hideContextMenuSeparators(sub);
    }
}

static void setBackdropHiddenInEffectView(UIView *effectView) {
    for (UIView *sub in effectView.subviews) {
        if ([sub isKindOfClass:[LGLiveBackdropView class]] ||
            [sub isKindOfClass:NSClassFromString(@"LGCtxMenuVibranceView")]) continue;
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) { ctxRememberVisualState(sub); sub.alpha = 0.0; return; }
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[LGLiveBackdropView class]] ||
                [inner isKindOfClass:NSClassFromString(@"LGCtxMenuVibranceView")]) continue;
            if ([NSStringFromClass(inner.class) containsString:@"Backdrop"]) { ctxRememberVisualState(inner); inner.alpha = 0.0; return; }
        }
    }
}

@interface LGCtxMenuVibranceView : UIView
- (void)applyVibranceFilters;
@end

@implementation LGCtxMenuVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.cornerRadius = kCtxCornerRadius;
        self.layer.masksToBounds = YES;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyVibranceFilters];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyVibranceFilters];
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@YES forKey:@"windowServerAware"];
        [layer setValue:@(1.0) forKey:@"scale"];

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static void injectGlassIntoContextEffectView(UIVisualEffectView *fx, int attempt) {
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (isExactClass(fx.superview, @"_UIContextMenuHeaderView")) return;
    UIView *container = fx.contentView;

    if (CGRectGetWidth(container.bounds) < 10.0 || CGRectGetHeight(container.bounds) < 10.0) {
        if (attempt >= 10) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (fx.window) injectGlassIntoContextEffectView(fx, attempt + 1);
        });
        return;
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kCtxGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"ContextMenu");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(fx, kCtxGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    glass.frame                = container.bounds;
    glass.layer.cornerRadius   = kCtxCornerRadius;
    glass.layer.cornerCurve    = kCACornerCurveContinuous;
    glass.layer.masksToBounds  = YES;
    [glass applyFilters];

    LGCtxMenuVibranceView *vibrance = objc_getAssociatedObject(fx, kCtxVibranceKey);
    if (!vibrance) {
        vibrance = [[LGCtxMenuVibranceView alloc] initWithFrame:container.bounds];
        if (vibrance) {
            vibrance.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [container insertSubview:vibrance aboveSubview:glass];
            objc_setAssociatedObject(fx, kCtxVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (vibrance) {
        if (vibrance.superview != container) {
            [container insertSubview:vibrance aboveSubview:glass];
        }
        vibrance.frame               = container.bounds;
        vibrance.layer.cornerRadius  = kCtxCornerRadius;
        vibrance.layer.cornerCurve   = kCACornerCurveContinuous;
        vibrance.layer.masksToBounds = YES;
        [vibrance applyVibranceFilters];
    }
}

static void removeGlassFromContextEffectView(UIVisualEffectView *fx) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kCtxGlassKey);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(fx, kCtxGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    LGCtxMenuVibranceView *vibrance = objc_getAssociatedObject(fx, kCtxVibranceKey);
    if (vibrance) {
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(fx, kCtxVibranceKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void relayoutContextMenuCellContent(UIView *contentView) {
    if (contentView.bounds.size.width < 40.0 || contentView.bounds.size.height < 20.0) return;

    UIImageView *iconView = (UIImageView *)findDescendantMatching(contentView, ^BOOL(UIView *v) {
        if (![v isKindOfClass:[UIImageView class]]) return NO;
        UIImageView *iv = (UIImageView *)v;
        return iv.image && iv.bounds.size.width > 8.0 && iv.bounds.size.height > 8.0;
    });
    if (!iconView) return;

    UIView *textView = findDescendantMatching(contentView, ^BOOL(UIView *v) {
        if ([v isKindOfClass:[UIStackView class]]) {
            for (UIView *sub in v.subviews)
                if ([sub isKindOfClass:[UILabel class]]) return YES;
        }
        return [v isKindOfClass:[UILabel class]];
    });
    if (!textView || textView == (UIView *)iconView) return;

    CGSize iconSize = iconView.bounds.size;
    if (iconSize.width <= 0.0 || iconSize.height <= 0.0) iconSize = CGSizeMake(18.0, 18.0);

    CGFloat iconY = round((contentView.bounds.size.height - iconSize.height) * 0.5);
    ctxRememberFrame(iconView);
    iconView.frame = CGRectMake(kCtxRowInset, iconY, iconSize.width, iconSize.height);

    CGRect textFrame = textView.frame;
    CGFloat textX    = CGRectGetMaxX(iconView.frame) + kCtxIconSpacing;
    CGFloat maxWidth = contentView.bounds.size.width - textX - kCtxRowInset;
    if (maxWidth < 20.0) return;
    textFrame.origin.x   = textX;
    textFrame.size.width = maxWidth;
    ctxRememberFrame(textView);
    textView.frame = CGRectIntegral(textFrame);
}

static void restoreContextMenuSubtree(UIView *view) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(view, kCtxGlassKey);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(view, kCtxGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    UIView *vibrance = objc_getAssociatedObject(view, kCtxVibranceKey);
    if (vibrance) {
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(view, kCtxVibranceKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSNumber *alpha = objc_getAssociatedObject(view, kCtxOriginalAlphaKey);
    if (alpha) {
        view.alpha = alpha.doubleValue;
        view.hidden = [objc_getAssociatedObject(view, kCtxOriginalHiddenKey) boolValue];
        view.layer.cornerRadius = [objc_getAssociatedObject(view, kCtxOriginalRadiusKey) doubleValue];
        NSString *curve = objc_getAssociatedObject(view, kCtxOriginalCurveKey);
        view.layer.cornerCurve = curve.length ? curve : kCACornerCurveCircular;
        objc_setAssociatedObject(view, kCtxOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, kCtxOriginalHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, kCtxOriginalRadiusKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, kCtxOriginalCurveKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSValue *frame = objc_getAssociatedObject(view, kCtxOriginalFrameKey);
    if (frame) { view.frame = frame.CGRectValue; objc_setAssociatedObject(view, kCtxOriginalFrameKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    UIColor *background = objc_getAssociatedObject(view, kCtxGapOriginalBgKey);
    if (background) { view.backgroundColor = background; objc_setAssociatedObject(view, kCtxGapOriginalBgKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    UIView *divider = [view viewWithTag:kCtxDividerTag];
    [divider removeFromSuperview];
    UIView *glow = objc_getAssociatedObject(view, kCtxGlowViewKey);
    if (glow) {
        [glow removeFromSuperview];
        objc_setAssociatedObject(view, kCtxGlowViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    UIGestureRecognizer *g = objc_getAssociatedObject(view, kCtxGestureKey);
    if (g) {
        [view removeGestureRecognizer:g];
        objc_setAssociatedObject(view, kCtxGestureKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    UIView *pill = objc_getAssociatedObject(view, kCtxCellPillKey);
    if (pill) {
        [pill removeFromSuperview];
        objc_setAssociatedObject(view, kCtxCellPillKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    for (UIView *sub in [view.subviews copy]) restoreContextMenuSubtree(sub);
}

static void restoreContextMenusForDisable(void) {
    if (lgHostEnabled(@"ContextMenu")) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows)
        restoreContextMenuSubtree(window);
}

static void ctxRoundSubtree(UIView *v) {
    if (shouldRoundContextMenuSubview(v)) applyContextMenuRoundedStyle(v);
    for (UIView *c in v.subviews) ctxRoundSubtree(c);
}

static void ctxHideBackdropsInSubtree(UIView *v) {
    if ([v isKindOfClass:[UIVisualEffectView class]]) setBackdropHiddenInEffectView(v);
    for (UIView *c in v.subviews) ctxHideBackdropsInSubtree(c);
}

static void styleContextMenuListSubviews(UIView *listView) {
    hideContextMenuSeparators(listView);
    for (UIView *sub in listView.subviews) ctxRoundSubtree(sub);
}

static UIImage *LGCtxMenuCreateGlowImage(CGFloat diameter) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.60].CGColor,
                        (id)[UIColor colorWithWhite:1.0 alpha:0.32].CGColor,
                        (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
                        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
    CGFloat locations[] = {0.0, 0.32, 0.68, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, locations);

    CGPoint center = CGPointMake(diameter * 0.5, diameter * 0.5);
    CGContextDrawRadialGradient(ctx, gradient, center, 0.0, center, diameter * 0.5, kCGGradientDrawsAfterEndLocation);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static UIImage *LGCtxMenuCachedGlowImage(void) {
    static UIImage *s_glowImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_glowImage = LGCtxMenuCreateGlowImage(280.0);
    });
    return s_glowImage;
}

@interface LGCtxMenuGlowView : UIView
@property (nonatomic, strong) UIImageView *glowImageView;
@property (nonatomic, assign) BOOL isTracking;
- (void)handleTouchDownAtPoint:(CGPoint)pt;
- (void)handleTouchMovedToPoint:(CGPoint)pt;
- (void)handleTouchEnded;
- (void)resetGlowImmediately;
- (void)updateLayoutWithBounds:(CGRect)bounds cornerRadius:(CGFloat)radius;
@end

@implementation LGCtxMenuGlowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerRadius = kCtxCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        CGFloat diameter = 280.0;
        self.glowImageView = [[UIImageView alloc] initWithImage:LGCtxMenuCachedGlowImage()];
        self.glowImageView.bounds = CGRectMake(0, 0, diameter, diameter);
        self.glowImageView.userInteractionEnabled = NO;
        self.glowImageView.alpha = 0.0;
        self.glowImageView.hidden = YES;
        [self addSubview:self.glowImageView];
    }
    return self;
}

static CGFloat LGCtxMenuGlowTargetAlpha(UIView *view) {
    UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return 0.55;
    }
    return 0.40;
}

- (void)updateLayoutWithBounds:(CGRect)bounds cornerRadius:(CGFloat)radius {
    self.frame = bounds;
    CGFloat r = radius > 0.0 ? radius : kCtxCornerRadius;
    self.layer.cornerRadius = r;
    self.layer.cornerCurve = kCACornerCurveContinuous;
}

- (void)handleTouchDownAtPoint:(CGPoint)pt {
    self.isTracking = YES;
    [self.glowImageView.layer removeAllAnimations];
    self.glowImageView.center = pt;
    self.glowImageView.hidden = NO;
    CGFloat targetAlpha = LGCtxMenuGlowTargetAlpha(self);
    self.glowImageView.alpha = targetAlpha;
}

- (void)handleTouchMovedToPoint:(CGPoint)pt {
    self.glowImageView.center = pt;
    CGFloat targetAlpha = LGCtxMenuGlowTargetAlpha(self);
    if (!self.isTracking || self.glowImageView.hidden || self.glowImageView.alpha < (targetAlpha * 0.9)) {
        self.isTracking = YES;
        self.glowImageView.hidden = NO;
        self.glowImageView.alpha = targetAlpha;
    }
}

- (void)handleTouchEnded {
    self.isTracking = NO;
    [UIView animateWithDuration:0.25 delay:0.04 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
        self.glowImageView.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (!self.isTracking && self.glowImageView.alpha == 0.0) {
            self.glowImageView.hidden = YES;
        }
    }];
}

- (void)resetGlowImmediately {
    self.isTracking = NO;
    [self.glowImageView.layer removeAllAnimations];
    self.glowImageView.alpha = 0.0;
    self.glowImageView.hidden = YES;
}

@end

@interface LGCtxMenuGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedDelegate;
@end

@implementation LGCtxMenuGestureDelegate
+ (instancetype)sharedDelegate {
    static LGCtxMenuGestureDelegate *d = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        d = [[LGCtxMenuGestureDelegate alloc] init];
    });
    return d;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}
@end

static LGCtxMenuGlowView *LGCtxMenuEnsureGlowView(UIView *listView) {
    if (!listView) return nil;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
    if (!glow) {
        glow = [[LGCtxMenuGlowView alloc] initWithFrame:listView.bounds];
        objc_setAssociatedObject(listView, kCtxGlowViewKey, glow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *bg = nil;
        for (UIView *sub in listView.subviews) {
            if ([sub isKindOfClass:[UIVisualEffectView class]]) {
                bg = sub;
                break;
            }
        }
        if (bg) {
            [listView insertSubview:glow aboveSubview:bg];
        } else {
            [listView insertSubview:glow atIndex:0];
        }
    } else {
        [glow updateLayoutWithBounds:listView.bounds cornerRadius:listView.layer.cornerRadius];
    }
    return glow;
}

@interface LGCtxMenuPillView : UIView
@property (nonatomic, assign) BOOL isShowing;
- (void)showWithAnimation:(BOOL)animated;
- (void)hideWithAnimation:(BOOL)animated;
- (void)updateLayoutWithBounds:(CGRect)bounds;
@end

@implementation LGCtxMenuPillView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.alpha = 0.0;
        self.hidden = YES;
    }
    return self;
}

static UIColor *LGCtxMenuPillColor(UIView *view) {
    UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {

        return [UIColor colorWithWhite:1.0 alpha:0.18];
    } else {

        return [UIColor colorWithWhite:0.0 alpha:0.10];
    }
}

- (void)updateLayoutWithBounds:(CGRect)bounds {
    CGRect targetFrame = CGRectInset(bounds, 6.0, 2.5);
    if (!CGRectEqualToRect(self.frame, targetFrame)) {
        self.frame = targetFrame;
    }
    CGFloat radius = CGRectGetHeight(targetFrame) * 0.5;
    if (fabs(self.layer.cornerRadius - radius) > 0.5) {
        self.layer.cornerRadius = radius;
    }
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.backgroundColor = LGCtxMenuPillColor(self);
}

- (void)showWithAnimation:(BOOL)animated {
    self.isShowing = YES;
    [self.layer removeAllAnimations];
    self.backgroundColor = LGCtxMenuPillColor(self);
    self.hidden = NO;
    if (animated) {
        [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
            self.alpha = 1.0;
        } completion:nil];
    } else {
        self.alpha = 1.0;
    }
}

- (void)hideWithAnimation:(BOOL)animated {
    self.isShowing = NO;
    if (animated) {
        [UIView animateWithDuration:0.20 delay:0.02 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
            self.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (!self.isShowing && self.alpha == 0.0) {
                self.hidden = YES;
            }
        }];
    } else {
        [self.layer removeAllAnimations];
        self.alpha = 0.0;
        self.hidden = YES;
    }
}

@end

static LGCtxMenuPillView *LGCtxCellEnsurePillView(UIView *cell) {
    if (!cell) return nil;
    LGCtxMenuPillView *pill = objc_getAssociatedObject(cell, kCtxCellPillKey);
    if (!pill) {
        pill = [[LGCtxMenuPillView alloc] initWithFrame:CGRectInset(cell.bounds, 6.0, 2.5)];
        objc_setAssociatedObject(cell, kCtxCellPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell insertSubview:pill atIndex:0];
    }
    [pill updateLayoutWithBounds:cell.bounds];
    return pill;
}

%group LGContextMenuHooks

%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) { removeGlassFromContextEffectView((UIVisualEffectView *)self_); return; }
    if (!isInsideContextMenu(self_)) return;
    if (!lgHostEnabled(@"ContextMenu")) { restoreContextMenuSubtree(self_); return; }
    setBackdropHiddenInEffectView(self_);
    if (!hasAncestorOfClassName(self_, @"_UIContextMenuListView")) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self_.window) injectGlassIntoContextEffectView((UIVisualEffectView *)self_, 0);
    });
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideContextMenu(self_)) return;
    if (!lgHostEnabled(@"ContextMenu")) { restoreContextMenuSubtree(self_); return; }
    setBackdropHiddenInEffectView(self_);
    if (hasAncestorOfClassName(self_, @"_UIContextMenuListView"))
        injectGlassIntoContextEffectView((UIVisualEffectView *)self_, 10);
}
%end

%hook UICollectionReusableView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isContextMenuReusableGapView(self_)) return;
    if (!hasAncestorOfClassName(self_, @"_UIContextMenuListView")) return;
    if (!lgHostEnabled(@"ContextMenu")) { restoreContextMenuSubtree(self_); return; }
    styleContextMenuReusableGapView(self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isContextMenuReusableGapView(self_)) return;
    if (!hasAncestorOfClassName(self_, @"_UIContextMenuListView")) return;
    if (lgHostEnabled(@"ContextMenu")) styleContextMenuReusableGapView(self_);
    else restoreContextMenuSubtree(self_);
}
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    if (hasAncestorOfClassName((UIView *)self, @"_UIContextMenuListView") && lgHostEnabled(@"ContextMenu"))
        hideContextMenuSeparators((UIView *)self);
}
%end

%hook _UIContextMenuContainerView
- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) ctxHideBackdropsInSubtree((UIView *)self);
    else restoreContextMenuSubtree((UIView *)self);
}
%end

%hook _UIContextMenuListView

%new
- (void)lg_handleContextMenuPress:(UILongPressGestureRecognizer *)gesture {
    if (!lgHostEnabled(@"ContextMenu")) return;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(self_, kCtxGlowViewKey);
    if (!glow) return;

    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        if (gesture.numberOfTouches > 0) {
            CGPoint pt = [gesture locationInView:self_];
            if (state == UIGestureRecognizerStateBegan) {
                [glow handleTouchDownAtPoint:pt];
            } else {
                [glow handleTouchMovedToPoint:pt];
            }
        }
    } else if (state == UIGestureRecognizerStateEnded ||
               state == UIGestureRecognizerStateCancelled ||
               state == UIGestureRecognizerStateFailed) {
        [glow handleTouchEnded];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(self, kCtxGlowViewKey);
    if (!glow) glow = LGCtxMenuEnsureGlowView((UIView *)self);
    if (glow) [glow handleTouchDownAtPoint:[t locationInView:(UIView *)self]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(self, kCtxGlowViewKey);
    if (glow) [glow handleTouchMovedToPoint:[t locationInView:(UIView *)self]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(self, kCtxGlowViewKey);
    if (glow) [glow handleTouchEnded];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(self, kCtxGlowViewKey);
    if (glow) [glow handleTouchEnded];
}

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        LGCtxMenuGlowView *glow = objc_getAssociatedObject(self_, kCtxGlowViewKey);
        [glow resetGlowImmediately];
        return;
    }
    if (!lgHostEnabled(@"ContextMenu")) return;

    if (!objc_getAssociatedObject(self_, kCtxGestureKey)) {
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(lg_handleContextMenuPress:)];
        press.minimumPressDuration = 0.0;
        press.cancelsTouchesInView = NO;
        press.delaysTouchesBegan = NO;
        press.delaysTouchesEnded = NO;
        press.delegate = [LGCtxMenuGestureDelegate sharedDelegate];
        [self_ addGestureRecognizer:press];
        objc_setAssociatedObject(self_, kCtxGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGCtxMenuEnsureGlowView(self_);
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) { restoreContextMenuSubtree((UIView *)self); return; }
    if ([subview isKindOfClass:NSClassFromString(@"LGCtxMenuGlowView")]) return;
    if (subview.tag == kCtxDividerTag) return;

    if (![subview isKindOfClass:[UIVisualEffectView class]] && shouldRoundContextMenuSubview(subview))
        applyContextMenuRoundedStyle(subview);
    styleContextMenuListSubviews((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) {
        styleContextMenuListSubviews((UIView *)self);
        LGCtxMenuEnsureGlowView((UIView *)self);
    } else {
        restoreContextMenuSubtree((UIView *)self);
    }
}

- (void)highlightItemAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (!indexPath) return;
    UICollectionView *cv = nil;
    if ([self respondsToSelector:@selector(collectionView)]) {
        cv = [self collectionView];
    }
    if (cv) {
        UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
        if (cell) {
            LGCtxMenuPillView *pill = LGCtxCellEnsurePillView(cell);
            [pill showWithAnimation:YES];
        }
    }
}

- (void)unHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (!indexPath) return;
    UICollectionView *cv = nil;
    if ([self respondsToSelector:@selector(collectionView)]) {
        cv = [self collectionView];
    }
    if (cv) {
        UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
        if (cell) {
            LGCtxMenuPillView *pill = objc_getAssociatedObject(cell, kCtxCellPillKey);
            if (pill) [pill hideWithAnimation:YES];
        }
    }
}

%end

%hook _UIContextMenuView

- (void)_handleSelectionGesture:(UIGestureRecognizer *)gesture {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (!gesture) return;

    UIView *targetListView = nil;
    if ([self respondsToSelector:@selector(currentListView)]) {
        targetListView = (UIView *)[self currentListView];
    }
    if (!targetListView) {
        for (UIView *sub in ((UIView *)self).subviews) {
            if ([sub isKindOfClass:NSClassFromString(@"_UIContextMenuListView")]) {
                targetListView = sub;
                break;
            }
        }
    }
    if (!targetListView || !targetListView.window) return;

    LGCtxMenuGlowView *glow = objc_getAssociatedObject(targetListView, kCtxGlowViewKey);
    if (!glow) {
        glow = LGCtxMenuEnsureGlowView(targetListView);
    }
    if (!glow) return;

    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        if (gesture.numberOfTouches > 0) {
            CGPoint pt = [gesture locationInView:targetListView];
            if (state == UIGestureRecognizerStateBegan) {
                [glow handleTouchDownAtPoint:pt];
            } else {
                [glow handleTouchMovedToPoint:pt];
            }
        }
    } else if (state == UIGestureRecognizerStateEnded ||
               state == UIGestureRecognizerStateCancelled ||
               state == UIGestureRecognizerStateFailed) {
        [glow handleTouchEnded];
    }
}

%end

static UIView *ctxFindEnclosingListView(UIView *view) {
    UIView *cur = view.superview;
    while (cur) {
        if ([cur isKindOfClass:NSClassFromString(@"_UIContextMenuListView")]) {
            return cur;
        }
        cur = cur.superview;
    }
    return nil;
}

%hook _UIContextMenuCell

- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) {
        LGCtxMenuPillView *pill = objc_getAssociatedObject(self, kCtxCellPillKey);
        if (pill) {
            [pill updateLayoutWithBounds:((UIView *)self).bounds];
        }
    }
}

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        LGCtxMenuPillView *pill = objc_getAssociatedObject(self_, kCtxCellPillKey);
        if (pill) [pill hideWithAnimation:NO];
        return;
    }
    if (lgHostEnabled(@"ContextMenu")) {
        LGCtxCellEnsurePillView(self_);
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuPillView *pill = LGCtxCellEnsurePillView((UIView *)self);
    [pill showWithAnimation:NO];

    UITouch *t = [touches anyObject];
    if (!t) return;
    UIView *listView = ctxFindEnclosingListView((UIView *)self);
    if (!listView || !listView.window) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
    if (!glow) glow = LGCtxMenuEnsureGlowView(listView);
    if (glow) [glow handleTouchDownAtPoint:[t locationInView:listView]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    UIView *listView = ctxFindEnclosingListView((UIView *)self);
    if (!listView || !listView.window) return;
    LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
    if (glow) [glow handleTouchMovedToPoint:[t locationInView:listView]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuPillView *pill = objc_getAssociatedObject(self, kCtxCellPillKey);
    if (pill && !((UICollectionViewCell *)self).isSelected) {
        [pill hideWithAnimation:YES];
    }
    UIView *listView = ctxFindEnclosingListView((UIView *)self);
    if (listView) {
        LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
        if (glow) [glow handleTouchEnded];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuPillView *pill = objc_getAssociatedObject(self, kCtxCellPillKey);
    if (pill) [pill hideWithAnimation:YES];
    UIView *listView = ctxFindEnclosingListView((UIView *)self);
    if (listView) {
        LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
        if (glow) [glow handleTouchEnded];
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig(lgHostEnabled(@"ContextMenu") ? NO : highlighted);
    if (!lgHostEnabled(@"ContextMenu")) return;
    LGCtxMenuPillView *pill = LGCtxCellEnsurePillView((UIView *)self);
    if (highlighted) {
        [pill showWithAnimation:YES];
        UIView *listView = ctxFindEnclosingListView((UIView *)self);
        if (listView && listView.window) {
            LGCtxMenuGlowView *glow = objc_getAssociatedObject(listView, kCtxGlowViewKey);
            if (!glow) glow = LGCtxMenuEnsureGlowView(listView);
            if (glow && !glow.isTracking) {
                CGPoint cellMid = CGPointMake(CGRectGetMidX(((UIView *)self).bounds), CGRectGetMidY(((UIView *)self).bounds));
                CGPoint pt = [listView convertPoint:cellMid fromView:(UIView *)self];
                [glow handleTouchDownAtPoint:pt];
            }
        }
    } else {
        [pill hideWithAnimation:YES];
    }
}

- (void)setSelected:(BOOL)selected {
    %orig(lgHostEnabled(@"ContextMenu") ? NO : selected);
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (selected) {
        LGCtxMenuPillView *pill = LGCtxCellEnsurePillView((UIView *)self);
        [pill showWithAnimation:NO];
    }
}

%end

%hook _UIContextMenuCellContentView
- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) relayoutContextMenuCellContent((UIView *)self);
    else restoreContextMenuSubtree((UIView *)self);
}
%end

%end

%ctor {
    if (LGIsExcludedSystemProcess()) return;
    %init(LGContextMenuHooks);
    lgObservePreferenceReload(^{ restoreContextMenusForDisable(); });
}
