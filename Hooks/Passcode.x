#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static const CGFloat kPCActiveScale         = 1.16;
static const CGFloat kPCActiveLightTint     = 0.66;
static const CGFloat kPCRestDarkTint        = 0.12;
static const CGFloat kPCBackgroundDarkTint  = 0.2;
static const CGFloat kPCPressMass = 0.8, kPCPressStiff = 300.0, kPCPressDamp = 18.0, kPCPressVel = 0.5, kPCPressDur = 0.3;
static const CGFloat kPCRelMass   = 0.8, kPCRelStiff   = 300.0, kPCRelDamp   = 12.0, kPCRelVel   = 1.0, kPCRelDur   = 0.5;
static const CFTimeInterval kPCMinLightHold = 0.2;

static void *kPCGlassKey          = &kPCGlassKey;
static void *kPCTintKey           = &kPCTintKey;
static void *kPCBgTintKey         = &kPCBgTintKey;
static void *kPCAnimatorKey       = &kPCAnimatorKey;
static void *kPCHostKey           = &kPCHostKey;
static void *kPCHighlightedKey    = &kPCHighlightedKey;
static void *kPCHighlightBeganKey = &kPCHighlightBeganKey;
static void *kPCReleaseTokenKey   = &kPCReleaseTokenKey;
static void *kPCBgColorKey        = &kPCBgColorKey;
static void *kPCBgAlphaKey        = &kPCBgAlphaKey;
static void *kPCBgOpaqueKey       = &kPCBgOpaqueKey;

static BOOL sPasscodeVisible = NO;

#pragma mark - fullscreen backdrop: remove the blur, add a subtle dark tint

static BOOL isPasscodeBackgroundMaterial(UIView *mat) {
    return isExactClass(mat, @"MTMaterialView") &&
           isExactClass(mat.superview, @"CSPasscodeBackgroundView");
}

static void handlePasscodeBackgroundMaterial(UIView *mat) {
    if (!isPasscodeBackgroundMaterial(mat)) return;
    if (!lgHostEnabled(@"Passcode")) return;
    UIView *host = mat.superview;
    UIView *tint = objc_getAssociatedObject(host, kPCBgTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.backgroundColor = [UIColor colorWithWhite:0.0 alpha:kPCBackgroundDarkTint];
        [host addSubview:tint];
        objc_setAssociatedObject(host, kPCBgTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = host.bounds;
    [host bringSubviewToFront:tint];

    lgSuppressStock(mat, @"Passcode", YES);
    lgTrackGlass(tint, @"Passcode", nil);
}

#pragma mark - button host discovery + glass

static UIView *pcButtonHost(UIView *button) {
    UIView *best = nil; CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *sub in button.subviews) {
        if (!isExactClass(sub, @"UIView") || CGRectIsEmpty(sub.bounds)) continue;
        CGFloat w = CGRectGetWidth(sub.bounds), h = CGRectGetHeight(sub.bounds);
        if (w < 40.0 || h < 40.0) continue;
        CGFloat score = fabs(w - h)
                      + fabs(sub.layer.cornerRadius - fmin(w, h) * 0.5)
                      + fabs(sub.alpha - 0.15) * 100.0
                      + sub.subviews.count * 50.0;
        if (score < bestScore) { best = sub; bestScore = score; }
    }
    return best;
}

static UIColor *pcTargetTint(BOOL highlighted) {
    return highlighted
        ? [UIColor colorWithWhite:1.0 alpha:kPCActiveLightTint]
        : [UIColor colorWithWhite:0.0 alpha:kPCRestDarkTint];
}

static CGFloat pcCurrentScale(UIView *v) {
    CALayer *p = v.layer.presentationLayer;
    NSNumber *s = [p valueForKeyPath:@"transform.scale.x"];
    return [s isKindOfClass:[NSNumber class]] ? s.doubleValue : v.transform.a;
}

static void pcSyncPresentation(UIView *v) {
    CGFloat s = pcCurrentScale(v);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [v.layer removeAllAnimations];
    v.transform = CGAffineTransformMakeScale(s, s);
    [CATransaction commit];
}

static void pcApplyVisualState(UIView *host, BOOL highlighted, BOOL animated) {
    if (!host) return;
    UIView *tint = objc_getAssociatedObject(host, kPCTintKey);
    CGAffineTransform target = CGAffineTransformMakeScale(highlighted ? kPCActiveScale : 1.0,
                                                          highlighted ? kPCActiveScale : 1.0);
    void (^stopAnimator)(void) = ^{
        UIViewPropertyAnimator *a = objc_getAssociatedObject(host, kPCAnimatorKey);
        if (a) { [a stopAnimation:YES]; objc_setAssociatedObject(host, kPCAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    };
    void (^changes)(void) = ^{
        host.transform = target;
        tint.backgroundColor = pcTargetTint(highlighted);
    };

    [host.layer removeAllAnimations];
    [tint.layer removeAllAnimations];

    if (!animated) { stopAnimator(); pcSyncPresentation(host); changes(); return; }

    pcSyncPresentation(host);
    stopAnimator();
    CGFloat dur   = highlighted ? kPCPressDur   : kPCRelDur;
    CGFloat mass  = highlighted ? kPCPressMass  : kPCRelMass;
    CGFloat stiff = highlighted ? kPCPressStiff : kPCRelStiff;
    CGFloat damp  = highlighted ? kPCPressDamp  : kPCRelDamp;
    CGFloat vel   = highlighted ? kPCPressVel   : kPCRelVel;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass stiffness:stiff damping:damp initialVelocity:CGVectorMake(vel, vel)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:dur timingParameters:timing];
    animator.interruptible = YES;
    [animator addAnimations:changes];
    [animator startAnimation];
    objc_setAssociatedObject(host, kPCAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void pcRememberBg(UIView *host) {
    if (!objc_getAssociatedObject(host, kPCBgColorKey))
        objc_setAssociatedObject(host, kPCBgColorKey, host.backgroundColor ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(host, kPCBgAlphaKey))
        objc_setAssociatedObject(host, kPCBgAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(host, kPCBgOpaqueKey))
        objc_setAssociatedObject(host, kPCBgOpaqueKey, @(host.opaque), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void pcRestoreBg(UIView *host) {
    id color = objc_getAssociatedObject(host, kPCBgColorKey);
    id alpha = objc_getAssociatedObject(host, kPCBgAlphaKey);
    id opaque = objc_getAssociatedObject(host, kPCBgOpaqueKey);
    if (color)  host.backgroundColor = (color == [NSNull null]) ? nil : color;
    if (alpha)  host.alpha  = [alpha doubleValue];
    if (opaque) host.opaque = [opaque boolValue];
}

static void injectPasscodeButton(UIView *button) {
    if (!lgHostEnabled(@"Passcode")) return;
    UIView *host = pcButtonHost(button);
    if (!host) return;

    UIView *prev = objc_getAssociatedObject(button, kPCHostKey);
    if (prev && prev != host) {
        UIViewPropertyAnimator *a = objc_getAssociatedObject(prev, kPCAnimatorKey);
        if (a) { [a stopAnimation:YES]; objc_setAssociatedObject(prev, kPCAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN); }
        prev.transform = CGAffineTransformIdentity;
        pcRestoreBg(prev);
    }

    pcRememberBg(host);
    host.backgroundColor = UIColor.clearColor;
    host.alpha = 1.0;
    host.opaque = NO;
    host.clipsToBounds = YES;
    CGFloat r = fmin(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds)) * 0.5;
    host.layer.cornerRadius  = r;
    host.layer.cornerCurve   = kCACornerCurveCircular;
    host.layer.masksToBounds = YES;

    LGLiveBackdropView *glass = objc_getAssociatedObject(host, kPCGlassKey);
    BOOL freshInject = NO;
    if (!glass) {
        glass = LGCreateRegisteredGlass(host.bounds, nil, @"Passcode");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kPCGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        freshInject = YES;
    }
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    glass.frame = host.bounds;
    glass.layer.cornerRadius  = r;
    glass.layer.cornerCurve   = kCACornerCurveCircular;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    lgTrackGlass(glass, @"Passcode", nil);

    UIView *tint = objc_getAssociatedObject(host, kPCTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, kPCTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tint.superview != host) [host addSubview:tint];
    tint.frame = host.bounds;
    tint.layer.cornerRadius  = r;
    tint.layer.cornerCurve   = kCACornerCurveCircular;
    tint.layer.masksToBounds = YES;
    [host bringSubviewToFront:tint];

    objc_setAssociatedObject(button, kPCHostKey, host, OBJC_ASSOCIATION_ASSIGN);
    BOOL highlighted = [objc_getAssociatedObject(button, kPCHighlightedKey) boolValue];
    if (freshInject || prev != host) pcApplyVisualState(host, highlighted, NO);
    else tint.backgroundColor = pcTargetTint(highlighted);
}

static void resetPasscodeButton(UIView *button) {
    UIView *host = objc_getAssociatedObject(button, kPCHostKey) ?: pcButtonHost(button);
    if (!host) return;
    UIViewPropertyAnimator *a = objc_getAssociatedObject(host, kPCAnimatorKey);
    if (a) { [a stopAnimation:YES]; objc_setAssociatedObject(host, kPCAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    LGLiveBackdropView *glass = objc_getAssociatedObject(host, kPCGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(host, kPCGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    UIView *tint = objc_getAssociatedObject(host, kPCTintKey);
    [tint removeFromSuperview];
    objc_setAssociatedObject(host, kPCTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    host.transform = CGAffineTransformIdentity;
    pcRestoreBg(host);
    objc_setAssociatedObject(button, kPCHostKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, kPCHighlightedKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void setPasscodeButtonHighlighted(UIView *button, BOOL highlighted) {
    if (!lgHostEnabled(@"Passcode")) {
        resetPasscodeButton(button);
        return;
    }
    UIView *host = objc_getAssociatedObject(button, kPCHostKey) ?: pcButtonHost(button);
    if (!host) return;
    NSNumber *cur = objc_getAssociatedObject(button, kPCHighlightedKey);
    if (cur && cur.boolValue == highlighted) return;
    objc_setAssociatedObject(button, kPCHighlightedKey, @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSUInteger token = [objc_getAssociatedObject(button, kPCReleaseTokenKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(button, kPCReleaseTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (highlighted) {
        objc_setAssociatedObject(button, kPCHighlightBeganKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pcApplyVisualState(host, YES, YES);
        return;
    }

    CFTimeInterval began = [objc_getAssociatedObject(button, kPCHighlightBeganKey) doubleValue];
    CFTimeInterval elapsed = began > 0.0 ? (CACurrentMediaTime() - began) : kPCMinLightHold;
    CFTimeInterval remaining = MAX(0.0, kPCMinLightHold - elapsed);
    if (remaining <= 0.0) { pcApplyVisualState(host, NO, YES); return; }

    __weak UIView *wb = button, *wh = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *sb = wb, *sh = wh;
        if (!sb || !sh) return;
        if ([objc_getAssociatedObject(sb, kPCHighlightedKey) boolValue]) return;
        if ([objc_getAssociatedObject(sb, kPCReleaseTokenKey) unsignedIntegerValue] != token) return;
        pcApplyVisualState(sh, NO, YES);
    });
}

#pragma mark - suppress other lockscreen chrome while the passcode is up

static BOOL isPasscodeSuppressibleRoot(UIView *v) {
    NSString *c = NSStringFromClass(v.class);
    return [c isEqualToString:@"CSQuickActionsButton"]
        || [c isEqualToString:@"CSProminentTimeView"]
        || [c isEqualToString:@"SBFLockScreenDateView"]
        || [c isEqualToString:@"PLPlatterView"]
        || [c isEqualToString:@"NCNotificationListView"]
        || [c isEqualToString:@"NCNotificationCombinedListView"]
        || [c isEqualToString:@"NCNotificationShortLookView"]
        || [c isEqualToString:@"NCNotificationLongLookView"];
}

static void *kPCSuppAlphaKey  = &kPCSuppAlphaKey;
static void *kPCSuppHiddenKey = &kPCSuppHiddenKey;

static void setPasscodeSuppressed(UIView *v, BOOL suppressed) {
    if (suppressed) {
        if (!objc_getAssociatedObject(v, kPCSuppAlphaKey)) {
            objc_setAssociatedObject(v, kPCSuppAlphaKey, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(v, kPCSuppHiddenKey, @(v.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [v.layer removeAllAnimations];
        [UIView animateWithDuration:0.18 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{ v.alpha = 0.0; }
                         completion:^(__unused BOOL fin) { if (sPasscodeVisible) v.hidden = YES; }];
    } else {
        NSNumber *alpha = objc_getAssociatedObject(v, kPCSuppAlphaKey);
        [v.layer removeAllAnimations];
        v.hidden = NO;
        [UIView animateWithDuration:0.2 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{ v.alpha = alpha ? alpha.doubleValue : 1.0; }
                         completion:^(__unused BOOL fin) {
            NSNumber *h = objc_getAssociatedObject(v, kPCSuppHiddenKey);
            if (h) v.hidden = h.boolValue;
        }];
        objc_setAssociatedObject(v, kPCSuppAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(v, kPCSuppHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void applyPasscodeSuppression(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (isPasscodeSuppressibleRoot(v)) { setPasscodeSuppressed(v, sPasscodeVisible); continue; }
            for (UIView *c in v.subviews) [stack addObject:c];
        }
    }
}

static void updatePasscodeVisible(BOOL visible) {
    if (!lgHostEnabled(@"Passcode")) visible = NO;
    if (sPasscodeVisible == visible) return;
    sPasscodeVisible = visible;
    dispatch_async(dispatch_get_main_queue(), ^{ applyPasscodeSuppression(); });
}

static BOOL passcodeBackgroundVisible(UIView *v) {
    return isExactClass(v, @"CSPasscodeBackgroundView") && v.window &&
           !v.hidden && v.alpha > 0.01 && v.layer.opacity > 0.01f;
}

static void restorePasscodeSubtree(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"SBPasscodeNumberPadButton"])
        resetPasscodeButton(view);
    if ([NSStringFromClass(view.class) isEqualToString:@"CSPasscodeBackgroundView"]) {
        UIView *tint = objc_getAssociatedObject(view, kPCBgTintKey);
        [tint removeFromSuperview];
        objc_setAssociatedObject(view, kPCBgTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    for (UIView *sub in [view.subviews copy]) restorePasscodeSubtree(sub);
}

static void restorePasscodeForDisable(void) {
    if (lgHostEnabled(@"Passcode")) return;
    updatePasscodeVisible(NO);
    for (UIWindow *window in UIApplication.sharedApplication.windows)
        restorePasscodeSubtree(window);
}

#pragma mark - hooks

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) handlePasscodeBackgroundMaterial(self_);
}
- (void)layoutSubviews {
    %orig;
    handlePasscodeBackgroundMaterial((UIView *)self);
}
%end

%hook SBPasscodeNumberPadButton
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) injectPasscodeButton(self_);
    else resetPasscodeButton(self_);
}
- (void)layoutSubviews {
    %orig;
    injectPasscodeButton((UIView *)self);
}
- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    setPasscodeButtonHighlighted((UIView *)self, highlighted);
}
%end

%hook CSPasscodeBackgroundView
- (void)didMoveToWindow { %orig; updatePasscodeVisible(passcodeBackgroundVisible((UIView *)self)); }
- (void)layoutSubviews  { %orig; updatePasscodeVisible(passcodeBackgroundVisible((UIView *)self)); }
- (void)setHidden:(BOOL)hidden { %orig; updatePasscodeVisible(passcodeBackgroundVisible((UIView *)self)); }
%end

%ctor {
    lgObservePreferenceReload(^{ restorePasscodeForDisable(); });
}
