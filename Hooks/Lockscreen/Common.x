#import "Common.h"
#import "../../Shared/LGHookSupport.h"
#import "../../Shared/LGBannerCaptureSupport.h"
#import "../../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static UIImage *sCachedLockSnapshot = nil;
static void *kLockAttachedKey = &kLockAttachedKey;
static void *kLockTintKey = &kLockTintKey;
static void *kLockBackdropViewKey = &kLockBackdropViewKey;

static CADisplayLink *sLockLink = nil;
static id sLockTicker = nil;
static NSInteger sLockCount = 0;

static UIView *LGLockscreenHostContainer(UIView *host) {
    if (![host isKindOfClass:[UIVisualEffectView class]]) return host;
    return ((UIVisualEffectView *)host).contentView;
}

BOOL LGIsLockscreenQuickActionsHost(UIView *view);

BOOL LGLockscreenEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"Lockscreen.Enabled", YES); }
CGFloat LGLockscreenCornerRadius(void) { return LG_prefFloat(@"Lockscreen.CornerRadius", 18.5); }
LG_FLOAT_PREF_FUNC(LGLockscreenBezelWidth, "Lockscreen.BezelWidth", 12.0)
LG_FLOAT_PREF_FUNC(LGLockscreenGlassThickness, "Lockscreen.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGLockscreenRefractionScale, "Lockscreen.RefractionScale", 1.2)
LG_FLOAT_PREF_FUNC(LGLockscreenRefractiveIndex, "Lockscreen.RefractiveIndex", 1.0)
LG_FLOAT_PREF_FUNC(LGLockscreenSpecularOpacity, "Lockscreen.SpecularOpacity", 0.8)
LG_FLOAT_PREF_FUNC(LGLockscreenBlur, "Lockscreen.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGLockscreenWallpaperScale, "Lockscreen.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGLockscreenLightTintAlpha, "Lockscreen.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGLockscreenDarkTintAlpha, "Lockscreen.DarkTintAlpha", 0.0)

static UIColor *LGLockscreenTintColorForHost(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    return LGDefaultTintColorForView(view, lightAlpha, darkAlpha);
}

static void LGEnsureLockscreenTintOverlay(UIView *host,
                                          CGFloat cornerRadius,
                                          CGFloat lightTintAlpha,
                                          CGFloat darkTintAlpha) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return;
    UIView *tint = LGEnsureTintOverlayView(container,
                                           kLockTintKey,
                                           0,
                                           container.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               LGLockscreenTintColorForHost(container, lightTintAlpha, darkTintAlpha),
                               cornerRadius,
                               container.layer,
                               NO);
    [container bringSubviewToFront:tint];
}

static void LGStartLockDisplayLink(void) {
    if (!LGLockscreenEnabled()) return;
    LGStartDisplayLink(&sLockLink, &sLockTicker, LGPreferredFramesPerSecondForKey(@"Lockscreen.FPS", 30), ^{
        if (LG_prefersLiveCapture(@"Lockscreen.RenderingMode") ||
            LG_prefersLiveCapture(@"LockscreenQuickActions.RenderingMode")) {
            LGLockscreenRefreshAllHosts();
        } else {
            LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
        }
    });
}

static void LGStopLockDisplayLink(void) {
    LGStopDisplayLink(&sLockLink, &sLockTicker);
}

void LGInvalidateLockscreenSnapshotCache(void) {
    LGAssertMainThread();
    sCachedLockSnapshot = nil;
}

UIImage *LGGetLockscreenSnapshotCached(void) {
    LGAssertMainThread();
    if (!sCachedLockSnapshot)
        sCachedLockSnapshot = LG_getLockscreenSnapshot();
    return sCachedLockSnapshot;
}

void LGRefreshLockSnapshotAfterDelay(NSTimeInterval delay) {
    LGAssertMainThread();
    sCachedLockSnapshot = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sCachedLockSnapshot = LG_getLockscreenSnapshot();
        if (sCachedLockSnapshot)
            LGLockscreenRefreshAllHosts();
    });
}

void LGDetachLockHostIfNeeded(UIView *view) {
    LGAssertMainThread();
    if (![objc_getAssociatedObject(view, kLockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kLockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sLockCount = MAX(0, sLockCount - 1);
    if (sLockCount == 0) LGStopLockDisplayLink();
}

void LGRemoveLockscreenGlass(UIView *host) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return;
    LGRemoveAssociatedSubview(container, kLockTintKey);
    LGRemoveLiveBackdropCaptureView(container, kLockBackdropViewKey);
    for (UIView *sub in [container.subviews copy]) {
        if ([sub isKindOfClass:[LiquidGlassView class]]) [sub removeFromSuperview];
    }
}

void LGCleanupLockscreenHost(UIView *host) {
    LGRemoveLockscreenGlass(host);
    LGDetachLockHostIfNeeded(host);
}

void LGAttachLockHostIfNeeded(UIView *view) {
    LGAssertMainThread();
    if ([objc_getAssociatedObject(view, kLockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kLockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sLockCount++;
    LGStartLockDisplayLink();
}

CGFloat LGLockscreenResolvedCornerRadius(UIView *view, CGFloat fallback) {
    if (!view) return fallback;
    if (view.layer.cornerRadius > 0.0f) return view.layer.cornerRadius;
    if (view.superview.layer.cornerRadius > 0.0f) return view.superview.layer.cornerRadius;
    return fallback;
}

LiquidGlassView *LGLockscreenEnsureConfiguredGlass(UIView *host,
                                                   CGPoint wallpaperOrigin,
                                                   LGUpdateGroup updateGroup,
                                                   CGFloat cornerRadius,
                                                   CGFloat bezelWidth,
                                                   CGFloat glassThickness,
                                                   CGFloat refractionScale,
                                                   CGFloat refractiveIndex,
                                                   CGFloat specularOpacity,
                                                   CGFloat blur,
                                                   CGFloat wallpaperScale,
                                                   CGFloat lightTintAlpha,
                                                   CGFloat darkTintAlpha) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return nil;

    LiquidGlassView *glass = nil;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[LiquidGlassView class]]) {
            glass = (LiquidGlassView *)sub;
            break;
        }
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:container.bounds wallpaper:nil wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [container insertSubview:glass atIndex:0];
    } else {
        glass.wallpaperOrigin = wallpaperOrigin;
        glass.userInteractionEnabled = NO;
    }

    glass.cornerRadius    = cornerRadius;
    glass.bezelWidth      = bezelWidth;
    glass.glassThickness  = glassThickness;
    glass.refractionScale = refractionScale;
    glass.refractiveIndex = refractiveIndex;
    glass.specularOpacity = specularOpacity;
    glass.blur            = blur;
    glass.wallpaperScale  = wallpaperScale;
    glass.updateGroup     = updateGroup;
    LGEnsureLockscreenTintOverlay(host, cornerRadius, lightTintAlpha, darkTintAlpha);
    return glass;
}

void LGLockscreenInjectGlassWithSettings(UIView *host,
                                         CGFloat cornerRadius,
                                         CGFloat bezelWidth,
                                         CGFloat glassThickness,
                                         CGFloat refractionScale,
                                         CGFloat refractiveIndex,
                                         CGFloat specularOpacity,
                                         CGFloat blur,
                                         CGFloat wallpaperScale,
                                         CGFloat lightTintAlpha,
                                         CGFloat darkTintAlpha) {
    LGLockscreenInjectGlassWithSettingsAndMode(host,
                                               @"Lockscreen.RenderingMode",
                                               cornerRadius,
                                               bezelWidth,
                                               glassThickness,
                                               refractionScale,
                                               refractiveIndex,
                                               specularOpacity,
                                               blur,
                                               wallpaperScale,
                                               lightTintAlpha,
                                               darkTintAlpha);
}

void LGLockscreenInjectGlassWithSettingsAndMode(UIView *host,
                                                NSString *renderingModeKey,
                                                CGFloat cornerRadius,
                                                CGFloat bezelWidth,
                                                CGFloat glassThickness,
                                                CGFloat refractionScale,
                                                CGFloat refractiveIndex,
                                                CGFloat specularOpacity,
                                                CGFloat blur,
                                                CGFloat wallpaperScale,
                                                CGFloat lightTintAlpha,
                                                CGFloat darkTintAlpha) {
    UIImage *wallpaper = LGGetLockscreenSnapshotCached();
    if (!wallpaper && !LG_prefersLiveCapture(renderingModeKey)) {
        LGDebugLog(@"lockscreen inject bail reason=no-snapshot key=%@ host=%@",
                   renderingModeKey,
                   host ? NSStringFromClass(host.class) : @"(null)");
        return;
    }
    CGPoint wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    LGLockscreenInjectGlassWithImageAndSettings(host,
                                                wallpaper,
                                                wallpaperOrigin,
                                                LGUpdateGroupLockscreen,
                                                cornerRadius,
                                                bezelWidth,
                                                glassThickness,
                                                refractionScale,
                                                refractiveIndex,
                                                specularOpacity,
                                                blur,
                                                wallpaperScale,
                                                lightTintAlpha,
                                                darkTintAlpha);
}

void LGLockscreenInjectGlassWithImageAndSettings(UIView *host,
                                                 UIImage *wallpaper,
                                                 CGPoint wallpaperOrigin,
                                                 LGUpdateGroup updateGroup,
                                                 CGFloat cornerRadius,
                                                 CGFloat bezelWidth,
                                                 CGFloat glassThickness,
                                                 CGFloat refractionScale,
                                                 CGFloat refractiveIndex,
                                                 CGFloat specularOpacity,
                                                 CGFloat blur,
                                                 CGFloat wallpaperScale,
                                                 CGFloat lightTintAlpha,
                                                 CGFloat darkTintAlpha) {
    if (!LGLockscreenEnabled()) {
        LGDebugLog(@"lockscreen inject bail reason=disabled host=%@",
                   host ? NSStringFromClass(host.class) : @"(null)");
        LGCleanupLockscreenHost(host);
        return;
    }

    if (!wallpaper) {
        LGDebugLog(@"lockscreen inject bail reason=no-wallpaper host=%@",
                   host ? NSStringFromClass(host.class) : @"(null)");
        return;
    }

    LiquidGlassView *glass = LGLockscreenEnsureConfiguredGlass(host,
                                                               wallpaperOrigin,
                                                               updateGroup,
                                                               cornerRadius,
                                                               bezelWidth,
                                                               glassThickness,
                                                               refractionScale,
                                                               refractiveIndex,
                                                               specularOpacity,
                                                               blur,
                                                               wallpaperScale,
                                                               lightTintAlpha,
                                                               darkTintAlpha);
    if (!glass) return;

    UIView *container = LGLockscreenHostContainer(host);
    NSString *resolvedRenderingModeKey = LGIsLockscreenQuickActionsHost(host)
        ? @"LockscreenQuickActions.RenderingMode"
        : @"Lockscreen.RenderingMode";
    if (!LGApplyRenderingModeToGlassHost(container ?: host,
                                         glass,
                                         resolvedRenderingModeKey,
                                         kLockBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        LGDebugLog(@"lockscreen inject bail reason=rendering-mode-failed key=%@ host=%@",
                   resolvedRenderingModeKey,
                   host ? NSStringFromClass(host.class) : @"(null)");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [glass updateOrigin]; });
}

void LGLockscreenInjectGlass(UIView *host, CGFloat cornerRadius) {
    LGLockscreenInjectGlassWithSettings(host,
                                        cornerRadius,
                                        LGLockscreenBezelWidth(),
                                        LGLockscreenGlassThickness(),
                                        LGLockscreenRefractionScale(),
                                        LGLockscreenRefractiveIndex(),
                                        LGLockscreenSpecularOpacity(),
                                        LGLockscreenBlur(),
                                        LGLockscreenWallpaperScale(),
                                        LGLockscreenLightTintAlpha(),
                                        LGLockscreenDarkTintAlpha());
}
