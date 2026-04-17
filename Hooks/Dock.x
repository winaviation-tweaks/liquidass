#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kDockTintTag       = 0xD0CC;

typedef NS_ENUM(NSInteger, LGDockMode) {
    LGDockModeNone = 0,
    LGDockModeRegular,
    LGDockModeFloating,
};

static void LGDockRefreshAllHosts(void);

static CADisplayLink *sDockLink = nil;
static id sDockTicker = nil;
static NSInteger sDockCount = 0;

LG_ENABLED_BOOL_PREF_FUNC(LGDockEnabled, "Dock.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGDockCornerRadiusHomeButton, "Dock.CornerRadiusHomeButton", 0.0)
LG_FLOAT_PREF_FUNC(LGDockCornerRadiusFullScreen, "Dock.CornerRadiusFullScreen", 34.0)
LG_FLOAT_PREF_FUNC(LGDockCornerRadiusFloating, "Dock.CornerRadiusFloating", 30.5)
LG_FLOAT_PREF_FUNC(LGDockBezelWidth, "Dock.BezelWidth", 30.0)
LG_FLOAT_PREF_FUNC(LGDockGlassThickness, "Dock.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGDockRefractionScale, "Dock.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGDockRefractiveIndex, "Dock.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGDockSpecularOpacity, "Dock.SpecularOpacity", 0.5)
LG_FLOAT_PREF_FUNC(LGDockBlur, "Dock.Blur", 10.0)
LG_FLOAT_PREF_FUNC(LGDockWallpaperScale, "Dock.WallpaperScale", 0.25)
LG_FLOAT_PREF_FUNC(LGDockLightTintAlpha, "Dock.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGDockDarkTintAlpha, "Dock.DarkTintAlpha", 0.0)

static BOOL isInsideCategoryStackBackground(UIView *view) {
    UIView *v = view;
    while (v) {
        NSString *name = NSStringFromClass(v.class);
        if (name && [name containsString:@"StackViewBackground"]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL LGHasFloatingDockWindow(void) {
    static Class floatingWindowCls;
    if (!floatingWindowCls) floatingWindowCls = NSClassFromString(@"SBFloatingDockWindow");
    if (!floatingWindowCls) return NO;

    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if ([window isKindOfClass:floatingWindowCls]) return YES;
            }
        }
        return NO;
    }

    for (UIWindow *window in LGApplicationWindows(app))
        if ([window isKindOfClass:floatingWindowCls]) return YES;
    return NO;
}

static BOOL isInsideRegularDock(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBDockView");
    return LGHasAncestorClass(view, cls);
}

static BOOL isInsideFloatingDock(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFloatingDockPlatterView");
    return LGHasAncestorClass(view, cls);
}

static BOOL isReasonableDockMaterialBounds(CGRect bounds) {
    return bounds.size.width >= 60.0 && bounds.size.height >= 40.0;
}

static void *kDockRetryKey = &kDockRetryKey;
static void *kDockAttachedKey = &kDockAttachedKey;
static void *kDockModeKey = &kDockModeKey;
static void *kDockTintKey = &kDockTintKey;
static void *kDockGlassKey = &kDockGlassKey;
static void *kDockOriginalFrameKey = &kDockOriginalFrameKey;
static void *kDockOriginalSuperviewClipsKey = &kDockOriginalSuperviewClipsKey;
static void *kDockBackdropViewKey = &kDockBackdropViewKey;

static LGDockMode LGResolveDockModeForView(UIView *view) {
    if (isInsideCategoryStackBackground(view)) return LGDockModeNone;
    if (!isReasonableDockMaterialBounds(view.bounds)) return LGDockModeNone;
    BOOL insideFloating = isInsideFloatingDock(view);
    BOOL insideRegular = isInsideRegularDock(view);
    if (!insideFloating && !insideRegular) return LGDockModeNone;
    if (insideFloating && LGHasFloatingDockWindow()) return LGDockModeFloating;
    if (insideRegular) return LGDockModeRegular;
    if (insideFloating) return LGDockModeFloating;
    return LGDockModeNone;
}

static void startDockDisplayLink(void) {
    LGStartDisplayLink(&sDockLink, &sDockTicker, LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 30), ^{
        if (LG_prefersLiveCapture(@"Dock.RenderingMode")) LGDockRefreshAllHosts();
        else LG_updateRegisteredGlassViews(LGUpdateGroupDock);
    });
}

static void stopDockDisplayLink(void) {
    LGStopDisplayLink(&sDockLink, &sDockTicker);
}

static BOOL LGDockNeedsLegacyPadding(LGDockMode mode) {
    if (mode != LGDockModeRegular) return NO;
    if (!LGIsAtLeastiOS16()) return NO;
    return !LG_isFullScreenDevice();
}

static CGRect LGDockOverlayFrameForHost(UIView *host, LGDockMode mode) {
    return host.bounds;
}

static void LGRestoreDockHostFrameIfNeeded(UIView *host) {
    if (!host) return;
    NSValue *originalFrameValue = objc_getAssociatedObject(host, kDockOriginalFrameKey);
    if (originalFrameValue) {
        host.frame = originalFrameValue.CGRectValue;
        objc_setAssociatedObject(host, kDockOriginalFrameKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    UIView *superview = host.superview;
    NSNumber *originalSuperviewClips = objc_getAssociatedObject(host, kDockOriginalSuperviewClipsKey);
    if (superview && originalSuperviewClips) {
        superview.clipsToBounds = originalSuperviewClips.boolValue;
        superview.layer.masksToBounds = superview.clipsToBounds;
        objc_setAssociatedObject(host, kDockOriginalSuperviewClipsKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void LGApplyDockHostPaddingIfNeeded(UIView *host, LGDockMode mode) {
    if (!host) return;
    if (!LGDockNeedsLegacyPadding(mode)) {
        LGRestoreDockHostFrameIfNeeded(host);
        return;
    }

    UIView *superview = host.superview;
    if (!superview) return;

    objc_setAssociatedObject(host, kDockOriginalFrameKey, [NSValue valueWithCGRect:host.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(host, kDockOriginalSuperviewClipsKey)) {
        objc_setAssociatedObject(host, kDockOriginalSuperviewClipsKey, @(superview.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static const CGFloat kLegacyDockHorizontalPadding = 8.0;
    static const CGFloat kLegacyDockBottomPadding = 8.0;
    CGRect frame = host.frame;
    frame.origin.x -= kLegacyDockHorizontalPadding;
    frame.size.width += (kLegacyDockHorizontalPadding * 2.0);
    frame.size.height += kLegacyDockBottomPadding;
    host.frame = frame;

    superview.clipsToBounds = NO;
    superview.layer.masksToBounds = NO;
}

static UIColor *dockTintColorForView(UIView *view) {
    return LGDefaultTintColorForView(view, LGDockLightTintAlpha(), LGDockDarkTintAlpha());
}

static void ensureDockTintOverlay(UIView *host) {
    if (!host) return;
    LGDockMode mode = (LGDockMode)[objc_getAssociatedObject(host, kDockModeKey) integerValue];
    CGRect overlayFrame = LGDockOverlayFrameForHost(host, mode);
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kDockTintKey,
                                           kDockTintTag,
                                           overlayFrame,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    tint.frame = overlayFrame;
    LGConfigureTintOverlayView(tint,
                               dockTintColorForView(host),
                               host.layer.cornerRadius,
                               host.layer,
                               NO);
    [host bringSubviewToFront:tint];
}

static void removeDockOverlays(UIView *host) {
    if (!host) return;
    LGRemoveAssociatedSubview(host, kDockTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kDockGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kDockGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(host, kDockBackdropViewKey);
    LGRestoreDockHostFrameIfNeeded(host);
}

static void injectIntoDock(UIView *self_) {
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    NSNumber *modeNumber = objc_getAssociatedObject(self_, kDockModeKey);
    LGDockMode mode = (LGDockMode)modeNumber.integerValue;
    if (mode == LGDockModeNone) return;
    LGApplyDockHostPaddingIfNeeded(self_, mode);

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper && !LG_prefersLiveCapture(@"Dock.RenderingMode")) {
        LGDebugLog(@"dock inject bail reason=no-snapshot mode=snapshot");
        if ([objc_getAssociatedObject(self_, kDockRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kDockRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kDockRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoDock(self_);
        });
        return;
    }

    LiquidGlassView *glass = objc_getAssociatedObject(self_, kDockGlassKey);
    CGRect glassFrame = LGDockOverlayFrameForHost(self_, mode);

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:glassFrame wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        [self_ addSubview:glass];
        objc_setAssociatedObject(self_, kDockGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = wallpaper;
        if (glass.superview != self_) {
            [glass removeFromSuperview];
            [self_ addSubview:glass];
        }
    }

    glass.frame = glassFrame;
    glass.cornerRadius    = (mode == LGDockModeFloating)
        ? LGDockCornerRadiusFloating()
        : (LG_isFullScreenDevice() ? LGDockCornerRadiusFullScreen() : LGDockCornerRadiusHomeButton());
    glass.bezelWidth      = LGDockBezelWidth();
    glass.glassThickness  = LGDockGlassThickness();
    glass.refractionScale = LGDockRefractionScale();
    glass.refractiveIndex = LGDockRefractiveIndex();
    glass.specularOpacity = LGDockSpecularOpacity();
    glass.blur            = LGDockBlur();
    glass.wallpaperScale  = LGDockWallpaperScale();
    glass.updateGroup     = LGUpdateGroupDock;
    if (!LGApplyRenderingModeToGlassHost(self_,
                                         glass,
                                         @"Dock.RenderingMode",
                                         kDockBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        LGDebugLog(@"dock inject bail reason=rendering-mode-failed mode=%@",
                   LG_prefString(@"Dock.RenderingMode", LGDefaultRenderingModeForKey(@"Dock.RenderingMode")));
        objc_setAssociatedObject(self_, kDockRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    ensureDockTintOverlay(self_);
    objc_setAssociatedObject(self_, kDockRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGDockRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (isInsideCategoryStackBackground(view)) {
                        removeDockOverlays(view);
                        return;
                    }
                    LGDockMode mode = LGResolveDockModeForView(view);
                    if (mode == LGDockModeNone) return;
                    objc_setAssociatedObject(view, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    injectIntoDock(view);
                    ensureDockTintOverlay(view);
                });
            }
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) {
            LGTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (isInsideCategoryStackBackground(view)) {
                    removeDockOverlays(view);
                    return;
                }
                LGDockMode mode = LGResolveDockModeForView(view);
                if (mode == LGDockModeNone) return;
                objc_setAssociatedObject(view, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                injectIntoDock(view);
                ensureDockTintOverlay(view);
            });
        }
    }
}

static void LGDockPrefsChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGDockRefreshAllHosts();
    });
}

%group LGDockSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    if (isInsideCategoryStackBackground(self_)) {
        removeDockOverlays(self_);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    if (!self_.window) {
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    LGDockMode mode = LGResolveDockModeForView(self_);
    if (mode == LGDockModeNone) return;
    objc_setAssociatedObject(self_, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self_.backgroundColor       = [UIColor clearColor];
    self_.layer.backgroundColor = nil;
    self_.layer.contents        = nil;
    injectIntoDock(self_);
    ensureDockTintOverlay(self_);
    dispatch_async(dispatch_get_main_queue(), ^{
        ensureDockTintOverlay(self_);
    });
    if (![objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kDockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sDockCount++;
        startDockDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    if (isInsideCategoryStackBackground(self_)) {
        removeDockOverlays(self_);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    LGDockMode mode = (LGDockMode)[objc_getAssociatedObject(self_, kDockModeKey) integerValue];
    if (mode == LGDockModeNone) {
        mode = LGResolveDockModeForView(self_);
        if (mode != LGDockModeNone) {
            objc_setAssociatedObject(self_, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            self_.backgroundColor = [UIColor clearColor];
            self_.layer.backgroundColor = nil;
            self_.layer.contents = nil;
            injectIntoDock(self_);
            ensureDockTintOverlay(self_);
            if (![objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
                objc_setAssociatedObject(self_, kDockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                sDockCount++;
                startDockDisplayLink();
            }
        }
    }
    if (mode == LGDockModeNone) return;
    self_.backgroundColor       = [UIColor clearColor];
    self_.layer.backgroundColor = nil;
    for (UIView *sub in self_.subviews)
        if ([sub isKindOfClass:[LiquidGlassView class]])
            [(LiquidGlassView *)sub updateOrigin];
    ensureDockTintOverlay(self_);
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    UIView *self_ = (UIView *)self;
    if (!newWindow && [objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kDockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        sDockCount = MAX(0, sDockCount - 1);
        if (sDockCount == 0) stopDockDisplayLink();
    }
    %orig;
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGDockPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGDockSpringBoard);
}
