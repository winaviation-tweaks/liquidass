#import "Common.h"
#import "../../Shared/LGPrefAccessors.h"

static BOOL LGLockscreenQuickActionsEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"LockscreenQuickActions.Enabled", YES); }
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsBezelWidth, "LockscreenQuickActions.BezelWidth", 12.0)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsGlassThickness, "LockscreenQuickActions.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsRefractionScale, "LockscreenQuickActions.RefractionScale", 1.2)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsRefractiveIndex, "LockscreenQuickActions.RefractiveIndex", 1.0)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsSpecularOpacity, "LockscreenQuickActions.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsBlur, "LockscreenQuickActions.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsWallpaperScale, "LockscreenQuickActions.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsLightTintAlpha, "LockscreenQuickActions.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGLockscreenQuickActionsDarkTintAlpha, "LockscreenQuickActions.DarkTintAlpha", 0.0)

static void LGLockscreenQuickActionsApplyLightAppearance(UIView *view) {
    if (@available(iOS 13.0, *)) {
        view.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        if ([view isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)view).contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }
    }
}

static void LGLockscreenQuickActionsResetHost(UIView *view) {
    if (@available(iOS 13.0, *)) {
        view.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        if ([view isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)view).contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        }
    }
    LGCleanupLockscreenHost(view);
}

BOOL LGIsLockscreenQuickActionsHost(UIView *view) {
    if (![view isKindOfClass:[UIVisualEffectView class]]) return NO;
    if (!view.window) return NO;
    if (@available(iOS 11.0, *)) {
        if (view.window.safeAreaInsets.bottom <= 0.0f) return NO;
    }

    static Class quickActionsCls, effectCls;
    if (!quickActionsCls) quickActionsCls = NSClassFromString(@"CSQuickActionsButton");
    if (!effectCls) effectCls = [UIVisualEffectView class];

    UIView *ancestor = view.superview;
    while (ancestor) {
        if (quickActionsCls && [ancestor isKindOfClass:quickActionsCls]) return YES;
        if (effectCls && [ancestor isKindOfClass:effectCls]) return NO;
        ancestor = ancestor.superview;
    }
    return NO;
}

CGFloat LGLockscreenQuickActionsCornerRadius(UIView *view) {
    CGFloat configured = LG_prefFloat(@"LockscreenQuickActions.CornerRadius", 25.0);
    if (configured > 0.0f) return configured;
    return LGLockscreenResolvedCornerRadius(view, 25.0f);
}

static void LGLockscreenQuickActionsApplyIfNeeded(UIView *view) {
    if (!view.window || !LGLockscreenQuickActionsEnabled() || !LGIsLockscreenQuickActionsHost(view)) {
        LGLockscreenQuickActionsResetHost(view);
        return;
    }

    LGLockscreenQuickActionsApplyLightAppearance(view);
    LGLockscreenInjectGlassWithSettingsAndMode(view,
                                               @"LockscreenQuickActions.RenderingMode",
                                               LGLockscreenQuickActionsCornerRadius(view),
                                               LGLockscreenQuickActionsBezelWidth(),
                                               LGLockscreenQuickActionsGlassThickness(),
                                               LGLockscreenQuickActionsRefractionScale(),
                                               LGLockscreenQuickActionsRefractiveIndex(),
                                               LGLockscreenQuickActionsSpecularOpacity(),
                                               LGLockscreenQuickActionsBlur(),
                                               LGLockscreenQuickActionsWallpaperScale(),
                                               LGLockscreenQuickActionsLightTintAlpha(),
                                               LGLockscreenQuickActionsDarkTintAlpha());
    LGAttachLockHostIfNeeded(view);
}

%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    LGLockscreenQuickActionsApplyIfNeeded((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGLockscreenQuickActionsApplyIfNeeded((UIView *)self);
}

%end
