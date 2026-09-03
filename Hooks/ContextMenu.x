#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static const NSInteger kCtxDividerTag    = 0xD171;
static const CGFloat   kCtxCornerRadius  = 22.0;
static const CGFloat   kCtxRowInset      = 16.0;
static const CGFloat   kCtxIconSpacing   = 12.0;
static void *kCtxGlassKey         = &kCtxGlassKey;
static void *kCtxGapOriginalBgKey = &kCtxGapOriginalBgKey;
static void *kCtxOriginalAlphaKey = &kCtxOriginalAlphaKey;
static void *kCtxOriginalHiddenKey = &kCtxOriginalHiddenKey;
static void *kCtxOriginalRadiusKey = &kCtxOriginalRadiusKey;
static void *kCtxOriginalCurveKey = &kCtxOriginalCurveKey;
static void *kCtxOriginalFrameKey = &kCtxOriginalFrameKey;

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
    return hasAncestorOfClassName(v, @"_UIContextMenuContainerView") ||
           hasAncestorOfClassName(v, @"_UIContextMenuListView");
}

static BOOL ctxCellContextViewIsStock(UIView *view) {
    if (!isExactClass(view, @"_UIContextMenuCellContextView")) return NO;
    if (!isExactClass(view.superview, @"_UIContextMenuCell")) return NO;
    return findDescendantMatching(view, ^BOOL(UIView *c) {
        return [c isKindOfClass:[UIStackView class]];
    }) != nil;
}

static BOOL shouldRoundContextMenuSubview(UIView *view) {
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
        if ([sub isKindOfClass:[LGLiveBackdropView class]]) continue;
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) { ctxRememberVisualState(sub); sub.alpha = 0.0; return; }
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[LGLiveBackdropView class]]) continue;
            if ([NSStringFromClass(inner.class) containsString:@"Backdrop"]) { ctxRememberVisualState(inner); inner.alpha = 0.0; return; }
        }
    }
}

static void injectGlassIntoContextEffectView(UIVisualEffectView *fx, int attempt) {
    if (!lgHostEnabled(@"ContextMenu")) return;
    if (isExactClass(fx.superview, @"_UIContextMenuHeaderView")) return;
    UIView *container = fx.contentView;
    // springboard sometimes gives us zero-ish bounds for a bit
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
}

static void removeGlassFromContextEffectView(UIVisualEffectView *fx) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kCtxGlassKey);
    if (!glass) return;
    [glass removeFromSuperview];
    objc_setAssociatedObject(fx, kCtxGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
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
    [glass removeFromSuperview];
    objc_setAssociatedObject(view, kCtxGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
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

#pragma mark - hooks

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
- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!lgHostEnabled(@"ContextMenu")) { restoreContextMenuSubtree((UIView *)self); return; }
    if (![subview isKindOfClass:[UIVisualEffectView class]] && shouldRoundContextMenuSubview(subview))
        applyContextMenuRoundedStyle(subview);
    if (lgHostEnabled(@"ContextMenu")) styleContextMenuListSubviews((UIView *)self);
    else restoreContextMenuSubtree((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) styleContextMenuListSubviews((UIView *)self);
    else restoreContextMenuSubtree((UIView *)self);
}
%end

%hook _UIContextMenuCell
- (void)setHighlighted:(BOOL)highlighted { %orig(lgHostEnabled(@"ContextMenu") ? NO : highlighted); }
- (void)setSelected:(BOOL)selected { %orig(lgHostEnabled(@"ContextMenu") ? NO : selected); }
%end

%hook _UIContextMenuCellContentView
- (void)layoutSubviews {
    %orig;
    if (lgHostEnabled(@"ContextMenu")) relayoutContextMenuCellContent((UIView *)self);
    else restoreContextMenuSubtree((UIView *)self);
}
%end

%ctor {
    lgObservePreferenceReload(^{ restoreContextMenusForDisable(); });
}
