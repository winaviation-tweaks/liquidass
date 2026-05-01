#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static void *kSearchPillOriginalAlphaKey = &kSearchPillOriginalAlphaKey;
static void *kSearchPillOriginalCornerRadiusKey = &kSearchPillOriginalCornerRadiusKey;
static void *kSearchPillOriginalClipsKey = &kSearchPillOriginalClipsKey;
static void *kSearchPillGlassKey = &kSearchPillGlassKey;
static void *kSearchPillTintKey = &kSearchPillTintKey;
static void *kSearchPillRetryKey = &kSearchPillRetryKey;
static void *kSearchPillBackdropViewKey = &kSearchPillBackdropViewKey;
static const NSInteger kSearchPillTintTag = 0x5EA2;

static void LGSearchPillInject(UIView *host);

LG_ENABLED_BOOL_PREF_FUNC(LGSearchPillEnabled, "SearchPill.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGSearchPillBezelWidth, "SearchPill.BezelWidth", 8.0)
LG_FLOAT_PREF_FUNC(LGSearchPillGlassThickness, "SearchPill.GlassThickness", 120.0)
LG_FLOAT_PREF_FUNC(LGSearchPillRefractionScale, "SearchPill.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGSearchPillRefractiveIndex, "SearchPill.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGSearchPillSpecularOpacity, "SearchPill.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGSearchPillBlur, "SearchPill.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGSearchPillWallpaperScale, "SearchPill.WallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGSearchPillLightTintAlpha, "SearchPill.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGSearchPillDarkTintAlpha, "SearchPill.DarkTintAlpha", 0.0)

static BOOL LGIsHomescreenSearchPillMaterialView(UIView *view) {
    if (!view || ![NSStringFromClass(view.class) isEqualToString:@"MTMaterialView"]) return NO;
    return LGHasAncestorClassNamed(view, @"SBFolderScrollAccessoryView");
}

static CGFloat LGSearchPillCornerRadius(void) {
    return LGDynamicDefaultFloat(@"SearchPill.CornerRadius", 15.0);
}

static void LGSearchPillRememberOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kSearchPillOriginalAlphaKey))
        objc_setAssociatedObject(view, kSearchPillOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kSearchPillOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(view, kSearchPillOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGCacheDynamicDefaultFloat(@"SearchPill.CornerRadius", view.layer.cornerRadius);
    }
    if (!objc_getAssociatedObject(view, kSearchPillOriginalClipsKey))
        objc_setAssociatedObject(view, kSearchPillOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSearchPillRestoreOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kSearchPillOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kSearchPillOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kSearchPillOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
    view.backgroundColor = nil;
    view.layer.backgroundColor = nil;
}

static void LGRemoveSearchPillGlass(UIView *view) {
    LGRemoveAssociatedSubview(view, kSearchPillTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kSearchPillGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kSearchPillGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kSearchPillBackdropViewKey);
}

static UIColor *LGSearchPillTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGSearchPillLightTintAlpha(), LGSearchPillDarkTintAlpha(), @"SearchPill.TintOverrideMode");
}

static void LGSearchPillScheduleRetry(UIView *host) {
    if ([objc_getAssociatedObject(host, kSearchPillRetryKey) boolValue]) return;
    objc_setAssociatedObject(host, kSearchPillRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(host, kSearchPillRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (host.window) {
            LGSearchPillInject(host);
        }
    });
}

static void LGSearchPillPrepareHost(UIView *host) {
    LGSearchPillRememberOriginalState(host);
    host.backgroundColor = UIColor.clearColor;
    host.layer.backgroundColor = nil;
    host.alpha = 1.0;
    host.layer.cornerRadius = LGSearchPillCornerRadius();
    host.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *))
        host.layer.cornerCurve = kCACornerCurveContinuous;
    host.clipsToBounds = YES;
}

static void LGSearchPillEnsureTintOverlay(UIView *host) {
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kSearchPillTintKey,
                                           kSearchPillTintTag,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               LGSearchPillTintColorForView(host),
                               LGSearchPillCornerRadius(),
                               host.layer,
                               YES);
    [host bringSubviewToFront:tint];
}

static void LGSearchPillInject(UIView *host) {
    if (!LGIsHomescreenSearchPillMaterialView(host)) return;
    if (!host.window || !LGSearchPillEnabled()) {
        LGRemoveSearchPillGlass(host);
        LGSearchPillRestoreOriginalState(host);
        return;
    }

    UIImage *snapshot = LG_getHomescreenSnapshot(NULL);
    if (!snapshot && !LG_prefersLiveCapture(@"SearchPill.RenderingMode")) {
        LG_refreshHomescreenSnapshot();
        LGSearchPillScheduleRetry(host);
        return;
    }

    LGSearchPillPrepareHost(host);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kSearchPillGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds wallpaper:snapshot wallpaperOrigin:CGPointZero];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupAppLibrary;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kSearchPillGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = snapshot;
    }

    glass.cornerRadius = LGSearchPillCornerRadius();
    glass.bezelWidth = LGSearchPillBezelWidth();
    glass.glassThickness = LGSearchPillGlassThickness();
    glass.refractionScale = LGSearchPillRefractionScale();
    glass.refractiveIndex = LGSearchPillRefractiveIndex();
    glass.specularOpacity = LGSearchPillSpecularOpacity();
    glass.blur = LGSearchPillBlur();
    glass.wallpaperScale = LGSearchPillWallpaperScale();
    glass.updateGroup = LGUpdateGroupAppLibrary;

    LGSearchPillEnsureTintOverlay(host);
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"SearchPill.RenderingMode",
                                         kSearchPillBackdropViewKey,
                                         snapshot,
                                         CGPointZero)) {
        LGSearchPillScheduleRetry(host);
        return;
    }
    objc_setAssociatedObject(host, kSearchPillRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

%group LGSearchPillSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (LGIsHomescreenSearchPillMaterialView(self_)) {
        LGSearchPillInject(self_);
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (LGIsHomescreenSearchPillMaterialView(self_)) {
        LGSearchPillInject(self_);
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGSearchPillSpringBoard);
}
