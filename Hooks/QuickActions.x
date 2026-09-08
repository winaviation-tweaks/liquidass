#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static void *kQAGlassKey = &kQAGlassKey;
static void *kQABackdropKey = &kQABackdropKey;
static void *kQABackdropAlphaKey = &kQABackdropAlphaKey;
static NSHashTable<UIVisualEffectView *> *sQuickActionHosts;
static void removeQuickActionsGlass(UIVisualEffectView *fx);

static UIView *qaBackdropView(UIView *effectView) {
    for (UIView *sub in effectView.subviews) {
        if ([sub isKindOfClass:[LGLiveBackdropView class]]) continue;
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) return sub;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[LGLiveBackdropView class]]) continue;
            if ([NSStringFromClass(inner.class) containsString:@"Backdrop"]) return inner;
        }
    }
    return nil;
}

static void qaSetBackdropHidden(UIVisualEffectView *effectView) {
    UIView *backdrop = qaBackdropView(effectView);
    if (!backdrop) return;
    if (!objc_getAssociatedObject(effectView, kQABackdropAlphaKey)) {
        objc_setAssociatedObject(effectView, kQABackdropKey, backdrop,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(effectView, kQABackdropAlphaKey, @(backdrop.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    backdrop.alpha = 0.0;
}

static BOOL isQuickActionsHost(UIView *view) {
    if (![view isKindOfClass:[UIVisualEffectView class]] || !view.window) return NO;
    if (view.window.safeAreaInsets.bottom <= 0.0) return NO;
    Class qaCls = NSClassFromString(@"CSQuickActionsButton");
    for (UIView *a = view.superview; a; a = a.superview) {
        if (qaCls && [a isKindOfClass:qaCls]) return YES;
        if ([a isKindOfClass:[UIVisualEffectView class]]) return NO;
    }
    return NO;
}

static void injectQuickActionsGlass(UIVisualEffectView *fx) {
    if (!lgHostEnabled(@"QuickActions")) {
        removeQuickActionsGlass(fx);
        return;
    }
    UIView *container = fx.contentView;
    if (CGRectGetWidth(container.bounds) < 4.0 || CGRectGetHeight(container.bounds) < 4.0) return;

    qaSetBackdropHidden(fx);

    if (@available(iOS 13.0, *)) {
        fx.overrideUserInterfaceStyle        = UIUserInterfaceStyleLight;
        container.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"QuickActions");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(fx, kQAGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    glass.frame               = container.bounds;
    glass.layer.cornerRadius  = fmin(CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds)) * 0.5;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    if (!sQuickActionHosts) sQuickActionHosts = [NSHashTable weakObjectsHashTable];
    [sQuickActionHosts addObject:fx];
    lgTrackGlass(glass, @"QuickActions", nil);
}

static void removeQuickActionsGlass(UIVisualEffectView *fx) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    if (@available(iOS 13.0, *)) {
        fx.overrideUserInterfaceStyle             = UIUserInterfaceStyleUnspecified;
        fx.contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
    UIView *backdrop = objc_getAssociatedObject(fx, kQABackdropKey);
    NSNumber *alpha = objc_getAssociatedObject(fx, kQABackdropAlphaKey);
    if (backdrop && alpha) backdrop.alpha = alpha.doubleValue;
    objc_setAssociatedObject(fx, kQABackdropKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(fx, kQABackdropAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(fx, kQAGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [sQuickActionHosts removeObject:fx];
}

static void LGReconcileQuickActionHosts(void) {
    for (UIVisualEffectView *host in sQuickActionHosts.allObjects) {
        if (lgHostEnabled(@"QuickActions")) injectQuickActionsGlass(host);
        else removeQuickActionsGlass(host);
    }
}

%group LGQuickActionsHooks

%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) { removeQuickActionsGlass((UIVisualEffectView *)self_); return; }
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGQuickActionsHooks);
    lgObservePreferenceReload(^{ LGReconcileQuickActionHosts(); });
}
