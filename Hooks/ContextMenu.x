#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kContextMenuGlassTag     = 0xBEEF;
static const NSInteger kContextMenuTintTag      = 0xDEAD;
static const NSInteger kContextMenuDividerTag   = 0xD171;
static void *kContextMenuReusableOriginalBackgroundKey = &kContextMenuReusableOriginalBackgroundKey;
static void *kContextMenuOriginalCornerRadiusKey = &kContextMenuOriginalCornerRadiusKey;
static void *kContextMenuOriginalCornerCurveKey = &kContextMenuOriginalCornerCurveKey;
static void *kContextMenuBackdropViewKey = &kContextMenuBackdropViewKey;

static BOOL LGContextMenuColorIsEffectivelyTransparent(UIColor *color) {
    if (!color) return YES;
    CGColorRef cgColor = color.CGColor;
    return CGColorGetAlpha(cgColor) <= 0.001;
}

LG_ENABLED_BOOL_PREF_FUNC(LGContextMenuEnabled, "ContextMenu.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGContextMenuCornerRadius, "ContextMenu.CornerRadius", 22.0)
LG_FLOAT_PREF_FUNC(LGContextMenuBezelWidth, "ContextMenu.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGContextMenuGlassThickness, "ContextMenu.GlassThickness", 100.0)
LG_FLOAT_PREF_FUNC(LGContextMenuRefraction, "ContextMenu.RefractionScale", 1.8)
LG_FLOAT_PREF_FUNC(LGContextMenuRefractiveIndex, "ContextMenu.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGContextMenuSpecular, "ContextMenu.SpecularOpacity", 1.0)
LG_FLOAT_PREF_FUNC(LGContextMenuBlur, "ContextMenu.Blur", 10.0)
LG_FLOAT_PREF_FUNC(LGContextMenuLightTintAlpha, "ContextMenu.LightTintAlpha", 0.8)
LG_FLOAT_PREF_FUNC(LGContextMenuDarkTintAlpha, "ContextMenu.DarkTintAlpha", 0.6)
LG_FLOAT_PREF_FUNC(LGContextMenuWallpaperScale, "ContextMenu.WallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGContextMenuRowInset, "ContextMenu.RowInset", 16.0)
LG_FLOAT_PREF_FUNC(LGContextMenuIconSpacing, "ContextMenu.IconSpacing", 12.0)

static void LGContextMenuRefreshAllHosts(void);
static void LGStyleContextMenuListSubviews(UIView *listView);

static CADisplayLink       *sCtxLink   = nil;
static id                   sCtxTicker = nil;
static NSInteger            sCtxCount  = 0;
static void *kCtxContainerAttachedKey  = &kCtxContainerAttachedKey;
static void *kContextMenuBackdropAlphaKey = &kContextMenuBackdropAlphaKey;

static void startContextMenuLink(void) {
    LGStartDisplayLink(&sCtxLink, &sCtxTicker, LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 30), ^{
        if (LG_prefersLiveCapture(@"ContextMenu.RenderingMode")) LGContextMenuRefreshAllHosts();
        else LG_updateRegisteredGlassViews(LGUpdateGroupContextMenu);
    });
}

static void stopContextMenuLink(void) {
    LGStopDisplayLink(&sCtxLink, &sCtxTicker);
}

static UIView *findDescendantMatching(UIView *root, BOOL (^match)(UIView *view)) {
    if (!root) return nil;
    for (UIView *sub in root.subviews) {
        if (match(sub)) return sub;
        UIView *found = findDescendantMatching(sub, match);
        if (found) return found;
    }
    return nil;
}

static BOOL LGContextMenuCellContextViewIsStock(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuCellContextView"]) return NO;

    UIView *parent = view.superview;
    if (!parent || ![NSStringFromClass(parent.class) isEqualToString:@"_UIContextMenuCell"]) return NO;

    return findDescendantMatching(view, ^BOOL(UIView *candidate) {
        return [candidate isKindOfClass:[UIStackView class]];
    }) != nil;
}

static BOOL shouldRoundContextMenuSubview(UIView *view) {
    NSString *clsName = NSStringFromClass(view.class);
    if ([clsName isEqualToString:@"_UIContextMenuCellContextView"]) {
        return LGContextMenuCellContextViewIsStock(view);
    }

    CGSize size = view.bounds.size;
    if (size.width < 20.0 || size.height < 20.0) return NO;
    if (size.width <= 2.0 || size.height <= 2.0) return NO;
    return YES;
}

static BOOL shouldHideContextMenuSeparatorView(UIView *view) {
    if (!view || [view isKindOfClass:[LiquidGlassView class]]) return NO;
    if (view.tag == kContextMenuTintTag || view.tag == kContextMenuGlassTag || view.tag == kContextMenuDividerTag) return NO;
    if ([view isKindOfClass:[UIVisualEffectView class]]) return NO;

    NSString *clsName = NSStringFromClass(view.class);
    if ([clsName isEqualToString:@"_UIContextMenuReusableSeparatorView"]) return YES;
    if ([clsName containsString:@"Separator"]) {
        return YES;
    }

    CGSize size = view.bounds.size;
    BOOL thinHorizontal = size.height > 0.0 && size.height <= 2.0 && size.width >= 24.0;
    BOOL thinVertical = size.width > 0.0 && size.width <= 2.0 && size.height >= 24.0;
    if (thinHorizontal || thinVertical) {
        if (view.backgroundColor || view.layer.backgroundColor) return YES;
    }
    return NO;
}

static BOOL isContextMenuReusableGapView(UIView *view) {
    if (!view) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"UICollectionReusableView"];
}

static UIColor *contextMenuDividerColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:1.0 alpha:0.16];
    }
    return [UIColor colorWithWhite:0.0 alpha:0.10];
}

static void restoreContextMenuReusableGapView(UIView *view) {
    if (!view) return;
    UIView *divider = [view viewWithTag:kContextMenuDividerTag];
    [divider removeFromSuperview];
    for (UIView *inner in view.subviews) {
        inner.hidden = NO;
        inner.alpha = 1.0;
        inner.layer.opacity = 1.0f;
    }
    view.hidden = NO;
    view.alpha = 1.0;
    view.layer.opacity = 1.0f;
    UIColor *originalBackground = objc_getAssociatedObject(view, kContextMenuReusableOriginalBackgroundKey);
    if (LGContextMenuColorIsEffectivelyTransparent(originalBackground)) {
        originalBackground = [UIColor separatorColor];
    }
    view.backgroundColor = originalBackground;
}

static void styleContextMenuReusableGapView(UIView *view) {
    if (!view) return;
    if (!LGContextMenuEnabled()) {
        restoreContextMenuReusableGapView(view);
        return;
    }
    UIColor *currentBackground = view.backgroundColor;
    UIColor *storedBackground = objc_getAssociatedObject(view, kContextMenuReusableOriginalBackgroundKey);
    if (!LGContextMenuColorIsEffectivelyTransparent(currentBackground)
        && (LGContextMenuColorIsEffectivelyTransparent(storedBackground) || !storedBackground)) {
        objc_setAssociatedObject(view,
                                 kContextMenuReusableOriginalBackgroundKey,
                                 currentBackground,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = NO;
    view.alpha = 1.0;
    view.backgroundColor = UIColor.clearColor;

    UIView *divider = [view viewWithTag:kContextMenuDividerTag];
    if (!divider) {
        divider = [[UIView alloc] initWithFrame:CGRectZero];
        divider.tag = kContextMenuDividerTag;
        divider.userInteractionEnabled = NO;
        [view addSubview:divider];
    }

    CGFloat inset = MAX(18.0, LGContextMenuRowInset());
    CGFloat lineHeight = 2.0;
    CGFloat width = MAX(0.0, view.bounds.size.width - inset * 2.0);
    CGFloat y = round((view.bounds.size.height - lineHeight) * 0.5);
    divider.frame = CGRectMake(inset, y, width, lineHeight);
    divider.backgroundColor = contextMenuDividerColorForView(view);
    divider.layer.cornerRadius = lineHeight * 0.5;
    divider.layer.masksToBounds = YES;

    for (UIView *inner in view.subviews) {
        if (inner == divider) continue;
        inner.hidden = YES;
        inner.alpha = 0.0;
    }
}

static BOOL LGIsContextMenuCollectionView(UICollectionView *collectionView) {
    if (!collectionView) return NO;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    UIView *view = collectionView;
    while (view) {
        if (menuListCls && [view isKindOfClass:menuListCls]) return YES;
        view = view.superview;
    }
    return NO;
}

static void hideContextMenuSeparators(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (shouldHideContextMenuSeparatorView(sub)) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        } else if (isContextMenuReusableGapView(sub)) {
            styleContextMenuReusableGapView(sub);
        }
        hideContextMenuSeparators(sub);
    }
}

static void restoreContextMenuSeparators(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (shouldHideContextMenuSeparatorView(sub)) {
            sub.hidden = NO;
            sub.alpha = 1.0;
        } else if (isContextMenuReusableGapView(sub)) {
            restoreContextMenuReusableGapView(sub);
        }
        restoreContextMenuSeparators(sub);
    }
}

static UIColor *contextMenuTintColorForView(UIView *view) {
    return LGDefaultTintColorForView(view, LGContextMenuLightTintAlpha(), LGContextMenuDarkTintAlpha());
}

static void rememberContextMenuOriginalCornerStyle(UIView *view) {
    if (!view) return;
    if (!objc_getAssociatedObject(view, kContextMenuOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(view,
                                 kContextMenuOriginalCornerRadiusKey,
                                 @(view.layer.cornerRadius),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (@available(iOS 13.0, *)) {
        if (!objc_getAssociatedObject(view, kContextMenuOriginalCornerCurveKey)) {
            objc_setAssociatedObject(view,
                                     kContextMenuOriginalCornerCurveKey,
                                     view.layer.cornerCurve,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
}

static void restoreContextMenuOriginalCornerStyle(UIView *view) {
    if (!view) return;
    NSNumber *originalRadius = objc_getAssociatedObject(view, kContextMenuOriginalCornerRadiusKey);
    if (!originalRadius) return;
    view.layer.cornerRadius = [originalRadius doubleValue];
    if (@available(iOS 13.0, *)) {
        NSString *originalCurve = objc_getAssociatedObject(view, kContextMenuOriginalCornerCurveKey);
        if (originalCurve) {
            view.layer.cornerCurve = originalCurve;
        }
    }
}

static void applyContextMenuTintStyle(UIView *tintView) {
    if (!tintView) return;
    tintView.backgroundColor = contextMenuTintColorForView(tintView.superview ?: tintView);
    tintView.layer.cornerRadius = LGContextMenuCornerRadius();
    tintView.layer.cornerCurve = kCACornerCurveContinuous;
    tintView.layer.masksToBounds = YES;
}

static void refreshContextMenuTint(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (sub.tag == kContextMenuTintTag)
            applyContextMenuTintStyle(sub);
        refreshContextMenuTint(sub);
    }
}

static void removeContextMenuInjectedSubviews(UIView *root) {
    NSMutableArray<UIView *> *toRemove = [NSMutableArray array];
    LGTraverseViews(root, ^(UIView *view) {
        if ([view isKindOfClass:[LiquidGlassView class]] || view.tag == kContextMenuTintTag || view.tag == kContextMenuDividerTag) {
            [toRemove addObject:view];
        }
    });
    for (UIView *view in toRemove) {
        [view removeFromSuperview];
    }
}

static void restoreContextMenuRoundedSubviews(UIView *listView) {
    if (!listView) return;
    LGTraverseViews(listView, ^(UIView *view) {
        if (view == listView) return;
        if (!shouldRoundContextMenuSubview(view)) return;
        restoreContextMenuOriginalCornerStyle(view);
    });
}


static void relayoutContextMenuCellContent(UIView *contentView) {
    if (!LGContextMenuEnabled()) return;
    if (contentView.bounds.size.width < 40.0 || contentView.bounds.size.height < 20.0) return;

    UIImageView *iconView = (UIImageView *)findDescendantMatching(contentView, ^BOOL(UIView *view) {
        if (![view isKindOfClass:[UIImageView class]]) return NO;
        UIImageView *imageView = (UIImageView *)view;
        return imageView.image && imageView.bounds.size.width > 8.0 && imageView.bounds.size.height > 8.0;
    });
    if (!iconView) return;

    UIView *textView = findDescendantMatching(contentView, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UIStackView class]]) {
            for (UIView *sub in view.subviews)
                if ([sub isKindOfClass:[UILabel class]]) return YES;
        }
        return [view isKindOfClass:[UILabel class]];
    });
    if (!textView || textView == iconView) return;

    CGSize iconSize = iconView.bounds.size;
    if (iconSize.width <= 0.0 || iconSize.height <= 0.0)
        iconSize = CGSizeMake(18.0, 18.0);

    CGFloat iconX = LGContextMenuRowInset();
    CGFloat iconY = round((contentView.bounds.size.height - iconSize.height) * 0.5);
    iconView.frame = CGRectMake(iconX, iconY, iconSize.width, iconSize.height);

    CGRect textFrame = textView.frame;
    CGFloat textX = CGRectGetMaxX(iconView.frame) + LGContextMenuIconSpacing();
    CGFloat maxWidth = contentView.bounds.size.width - textX - LGContextMenuRowInset();
    if (maxWidth < 20.0) return;
    textFrame.origin.x = textX;
    textFrame.size.width = maxWidth;
    textView.frame = CGRectIntegral(textFrame);
}

static void setBackdropHiddenInEffectView(UIView *effectView, BOOL hidden) {
    static Class backdropCls;
    for (UIView *sub in effectView.subviews) {
        if (!backdropCls && [NSStringFromClass(sub.class) containsString:@"Backdrop"])
            backdropCls = sub.class;
        if (backdropCls && [sub isKindOfClass:backdropCls]) {
            if (!objc_getAssociatedObject(sub, kContextMenuBackdropAlphaKey))
                objc_setAssociatedObject(sub, kContextMenuBackdropAlphaKey, @(sub.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSNumber *originalAlpha = objc_getAssociatedObject(sub, kContextMenuBackdropAlphaKey);
            sub.alpha = hidden ? 0.0 : (originalAlpha ? [originalAlpha doubleValue] : 1.0);
            return;
        }
        for (UIView *inner in sub.subviews) {
            if (!backdropCls && [NSStringFromClass(inner.class) containsString:@"Backdrop"])
                backdropCls = inner.class;
            if (backdropCls && [inner isKindOfClass:backdropCls]) {
                if (!objc_getAssociatedObject(inner, kContextMenuBackdropAlphaKey))
                    objc_setAssociatedObject(inner, kContextMenuBackdropAlphaKey, @(inner.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSNumber *originalAlpha = objc_getAssociatedObject(inner, kContextMenuBackdropAlphaKey);
                inner.alpha = hidden ? 0.0 : (originalAlpha ? [originalAlpha doubleValue] : 1.0);
                return;
            }
        }
    }
}

static void injectGlassIntoEffectView(UIVisualEffectView *fxView, int attempt) {
    UIView *container = fxView.contentView;
    LGRemoveLiveBackdropCaptureView(container, kContextMenuBackdropViewKey);

    for (NSInteger i = container.subviews.count - 1; i >= 0; i--) {
        UIView *sub = container.subviews[i];
        if ([sub isKindOfClass:[LiquidGlassView class]] || sub.tag == kContextMenuTintTag)
            [sub removeFromSuperview];
    }

    if (!LGContextMenuEnabled()) return;

    if (container.bounds.size.width < 10 || container.bounds.size.height < 10) {
        // springboard sometimes gives us zero-ish bounds for a bit
        if (attempt >= 10) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (fxView.window) injectGlassIntoEffectView(fxView, attempt + 1);
        });
        return;
    }

    UIImage *wallpaper = LG_getCachedContextMenuSnapshot();
    if (!wallpaper && !LG_prefersLiveCapture(@"ContextMenu.RenderingMode")) return;

    LiquidGlassView *glass = [[LiquidGlassView alloc]
        initWithFrame:container.bounds wallpaper:wallpaper wallpaperOrigin:CGPointZero];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
    glass.cornerRadius    = LGContextMenuCornerRadius();
    glass.blur            = LGContextMenuBlur();
    glass.refractionScale = LGContextMenuRefraction();
    glass.refractiveIndex = LGContextMenuRefractiveIndex();
    glass.bezelWidth      = LGContextMenuBezelWidth();
    glass.glassThickness  = LGContextMenuGlassThickness();
    glass.specularOpacity = LGContextMenuSpecular();
    glass.releasesWallpaperAfterUpload = YES;
    glass.wallpaperScale  = LGContextMenuWallpaperScale();
    glass.updateGroup     = LGUpdateGroupContextMenu;
    [container insertSubview:glass atIndex:0];
    if (!LGApplyRenderingModeToGlassHost(container,
                                         glass,
                                         @"ContextMenu.RenderingMode",
                                         kContextMenuBackdropViewKey,
                                         wallpaper,
                                         CGPointZero)) {
        [glass removeFromSuperview];
        return;
    }

    UIView *tint = [[UIView alloc] initWithFrame:container.bounds];
    tint.tag                    = kContextMenuTintTag;
    tint.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    tint.userInteractionEnabled = NO;
    applyContextMenuTintStyle(tint);
    [container insertSubview:tint aboveSubview:glass];

}

static BOOL LGIsContextMenuContainerEffectView(UIView *view) {
    if (!view) return NO;
    static Class containerCls, listCls;
    if (!containerCls) containerCls = NSClassFromString(@"_UIContextMenuContainerView");
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    return (containerCls && LGHasAncestorClass(view, containerCls))
        || (listCls && LGHasAncestorClass(view, listCls));
}

static void LGContextMenuRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            static Class listCls;
            if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
            if ([view isKindOfClass:[UIVisualEffectView class]]) {
                UIVisualEffectView *fx = (UIVisualEffectView *)view;
                if (!(fx.tag == kContextMenuGlassTag || LGHasAncestorClass(fx, listCls))) return;
                setBackdropHiddenInEffectView(fx, LGContextMenuEnabled());
                if (LGContextMenuEnabled()) injectGlassIntoEffectView(fx, 0);
                else removeContextMenuInjectedSubviews(fx.contentView);
                return;
            }
            if (listCls && [view isKindOfClass:listCls]) {
                LGStyleContextMenuListSubviews(view);
            }
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
}

static void LGContextMenuPrefsChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGContextMenuRefreshAllHosts();
    });
}

%group LGContextMenuSpringBoard

%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        if (self_.tag == kContextMenuGlassTag) self_.tag = 0;
        return;
    }

    if (!LGIsContextMenuContainerEffectView(self_)) return;
    setBackdropHiddenInEffectView(self_, LGContextMenuEnabled());

    static Class listCls;
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    if (!LGHasAncestorClass(self_, listCls)) return;
    if (self_.tag == kContextMenuGlassTag) return;
    self_.tag = kContextMenuGlassTag;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self_.window) injectGlassIntoEffectView((UIVisualEffectView *)self_, 0);
    });
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGIsContextMenuContainerEffectView(self_)) return;
    setBackdropHiddenInEffectView(self_, LGContextMenuEnabled());
    static Class listCls;
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    if (LGHasAncestorClass(self_, listCls)) {
        refreshContextMenuTint(self_);
    }
}

%end

%hook UICollectionReusableView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if (!isContextMenuReusableGapView(self_)) return;
    if (!LGHasAncestorClass(self_, menuListCls)) return;
    styleContextMenuReusableGapView(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if (!isContextMenuReusableGapView(self_)) return;
    if (!LGHasAncestorClass(self_, menuListCls)) return;
    styleContextMenuReusableGapView(self_);
}

- (id)preferredLayoutAttributesFittingAttributes:(id)attributes {
    return %orig;
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    if (!LGIsContextMenuCollectionView(self)) return;
    if (LGContextMenuEnabled()) hideContextMenuSeparators(self);
    else restoreContextMenuSeparators(self);
}

%end

%hook _UIContextMenuContainerView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) {
        if (![objc_getAssociatedObject(self, kCtxContainerAttachedKey) boolValue]) {
            objc_setAssociatedObject(self, kCtxContainerAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LG_cacheContextMenuSnapshot();
            sCtxCount++;
            startContextMenuLink();
        }
    } else {
        if ([objc_getAssociatedObject(self, kCtxContainerAttachedKey) boolValue]) {
            objc_setAssociatedObject(self, kCtxContainerAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sCtxCount = MAX(0, sCtxCount - 1);
            if (sCtxCount == 0) stopContextMenuLink();
            LG_invalidateContextMenuSnapshot();
        }
    }
}

- (void)layoutSubviews {
    %orig;
    LGTraverseViews((UIView *)self, ^(UIView *view) {
        if (![view isKindOfClass:[UIVisualEffectView class]]) return;
        setBackdropHiddenInEffectView(view, LGContextMenuEnabled());
    });
}

%end

static void LGStyleContextMenuListSubviews(UIView *listView) {
    if (!listView) return;
    if (!LGContextMenuEnabled()) {
        restoreContextMenuSeparators(listView);
        restoreContextMenuRoundedSubviews(listView);
        removeContextMenuInjectedSubviews(listView);
        return;
    }
    hideContextMenuSeparators(listView);
    refreshContextMenuTint(listView);
    LGTraverseViews(listView, ^(UIView *view) {
        if (view == listView) return;
        if (!shouldRoundContextMenuSubview(view)) return;
        rememberContextMenuOriginalCornerStyle(view);
        view.layer.cornerRadius = LGContextMenuCornerRadius();
        if (@available(iOS 13.0, *))
            view.layer.cornerCurve = kCACornerCurveContinuous;
    });
}

%hook _UIContextMenuListView

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!LGContextMenuEnabled()) {
        LGStyleContextMenuListSubviews((UIView *)self);
        return;
    }
    if ([subview isKindOfClass:[UIView class]]
        && ![subview isKindOfClass:[UIVisualEffectView class]]
        && shouldRoundContextMenuSubview(subview)) {
        rememberContextMenuOriginalCornerStyle(subview);
        subview.layer.cornerRadius = LGContextMenuCornerRadius();
        if (@available(iOS 13.0, *))
            subview.layer.cornerCurve = kCACornerCurveContinuous;
    }
    LGStyleContextMenuListSubviews((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGStyleContextMenuListSubviews((UIView *)self);
}

%end

%hook _UIContextMenuCellContentView

- (void)layoutSubviews {
    %orig;
    relayoutContextMenuCellContent((UIView *)self);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGContextMenuPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGContextMenuSpringBoard);
}
