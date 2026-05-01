#import "Common.h"
#import "../../Shared/LGHookSupport.h"
#import "../../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

void LGCleanupLockscreenHost(UIView *host);
void LGAttachLockHostIfNeeded(UIView *view);

static void *kLGPasscodeTintKey = &kLGPasscodeTintKey;
static void *kLGPasscodeButtonTintKey = &kLGPasscodeButtonTintKey;
static void *kLGPasscodeButtonBackgroundColorKey = &kLGPasscodeButtonBackgroundColorKey;
static void *kLGPasscodeButtonAlphaKey = &kLGPasscodeButtonAlphaKey;
static void *kLGPasscodeButtonOpaqueKey = &kLGPasscodeButtonOpaqueKey;
static void *kLGPasscodeButtonHighlightedKey = &kLGPasscodeButtonHighlightedKey;
static void *kLGPasscodeButtonAnimatorKey = &kLGPasscodeButtonAnimatorKey;
static void *kLGPasscodeButtonHostKey = &kLGPasscodeButtonHostKey;
static void *kLGPasscodeButtonHighlightBeganKey = &kLGPasscodeButtonHighlightBeganKey;
static void *kLGPasscodeButtonReleaseTokenKey = &kLGPasscodeButtonReleaseTokenKey;
static void *kLGPasscodeSuppressedAlphaKey = &kLGPasscodeSuppressedAlphaKey;
static void *kLGPasscodeSuppressedHiddenKey = &kLGPasscodeSuppressedHiddenKey;
static BOOL sLGPasscodeVisible = NO;

static LiquidGlassView *LGPasscodeButtonGlassView(UIView *host);
static const CFTimeInterval kLGPasscodeMinimumLightTintHold = 0.2;
static NSString *LGPasscodeRenderingModeKey(void);

static BOOL LGPasscodeEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"Lockscreen.Passcode.Enabled", YES); }
LG_FLOAT_PREF_FUNC(LGPasscodeBackgroundDarkTintAlpha, "Lockscreen.Passcode.BackgroundDarkTintAlpha", 0.2)
LG_FLOAT_PREF_FUNC(LGPasscodeBezelWidth, "Lockscreen.Passcode.BezelWidth", 30.0)
LG_FLOAT_PREF_FUNC(LGPasscodeGlassThickness, "Lockscreen.Passcode.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGPasscodeRefractionScale, "Lockscreen.Passcode.RefractionScale", 1.0)
LG_FLOAT_PREF_FUNC(LGPasscodeRefractiveIndex, "Lockscreen.Passcode.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGPasscodeSpecularOpacity, "Lockscreen.Passcode.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGPasscodeBlur, "Lockscreen.Passcode.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGPasscodeWallpaperScale, "Lockscreen.Passcode.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGPasscodeDarkTintAlpha, "Lockscreen.Passcode.DarkTintAlpha", 0.12)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveScale, "Lockscreen.Passcode.ActiveScale", 1.16)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveLightTintAlpha, "Lockscreen.Passcode.ActiveLightTintAlpha", 0.44)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveSpecularOpacity, "Lockscreen.Passcode.ActiveSpecularOpacity", 1.2)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveBezelWidth, "Lockscreen.Passcode.ActiveBezelWidth", 36.0)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveRefractionScale, "Lockscreen.Passcode.ActiveRefractionScale", 1.12)
LG_FLOAT_PREF_FUNC(LGPasscodeActiveBlur, "Lockscreen.Passcode.ActiveBlur", 2.1)
LG_FLOAT_PREF_FUNC(LGPasscodePressInMass, "Lockscreen.Passcode.PressInMass", 0.8)
LG_FLOAT_PREF_FUNC(LGPasscodePressInStiffness, "Lockscreen.Passcode.PressInStiffness", 300.0)
LG_FLOAT_PREF_FUNC(LGPasscodePressInDamping, "Lockscreen.Passcode.PressInDamping", 18.0)
LG_FLOAT_PREF_FUNC(LGPasscodePressInVelocity, "Lockscreen.Passcode.PressInVelocity", 0.5)
LG_FLOAT_PREF_FUNC(LGPasscodeReleaseMass, "Lockscreen.Passcode.ReleaseMass", 0.8)
LG_FLOAT_PREF_FUNC(LGPasscodeReleaseStiffness, "Lockscreen.Passcode.ReleaseStiffness", 300.0)
LG_FLOAT_PREF_FUNC(LGPasscodeReleaseDamping, "Lockscreen.Passcode.ReleaseDamping", 12.0)
LG_FLOAT_PREF_FUNC(LGPasscodeReleaseVelocity, "Lockscreen.Passcode.ReleaseVelocity", 1.0)
LG_FLOAT_PREF_FUNC(LGPasscodePressInDuration, "Lockscreen.Passcode.PressInDuration", 0.3)
LG_FLOAT_PREF_FUNC(LGPasscodeReleaseDuration, "Lockscreen.Passcode.ReleaseDuration", 0.5)

static UIImage *LGPasscodeCircleMaskImage(CGSize size) {
    if (size.width <= 0.0 || size.height <= 0.0) return nil;
    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGRect rect = (CGRect){CGPointZero, size};
    [[UIColor clearColor] setFill];
    UIRectFill(rect);
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:rect] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static NSString *LGPasscodeRenderingModeKey(void) {
    return LGHasExplicitPreferenceValue(@"Lockscreen.Passcode.RenderingMode")
        ? @"Lockscreen.Passcode.RenderingMode"
        : @"Lockscreen.RenderingMode";
}

static BOOL LGIsPasscodeSuppressibleRoot(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass(view.class);
    return [className isEqualToString:@"CSQuickActionsButton"]
        || [className isEqualToString:@"CSProminentTimeView"]
        || [className isEqualToString:@"SBFLockScreenDateView"]
        || [className isEqualToString:@"PLPlatterView"]
        || [className isEqualToString:@"NCNotificationListView"]
        || [className isEqualToString:@"NCNotificationCombinedListView"]
        || [className isEqualToString:@"NCNotificationShortLookView"]
        || [className isEqualToString:@"NCNotificationLongLookView"];
}

static void LGSetPasscodeSuppressedState(UIView *view, BOOL suppressed) {
    if (!view) return;
    if (suppressed) {
        if (!objc_getAssociatedObject(view, kLGPasscodeSuppressedAlphaKey)) {
            objc_setAssociatedObject(view, kLGPasscodeSuppressedAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kLGPasscodeSuppressedHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [view.layer removeAllAnimations];
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            view.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            if (sLGPasscodeVisible) {
                view.hidden = YES;
            }
        }];
    } else {
        NSNumber *alpha = objc_getAssociatedObject(view, kLGPasscodeSuppressedAlphaKey);
        [view.layer removeAllAnimations];
        view.hidden = NO;
        CGFloat targetAlpha = alpha ? alpha.doubleValue : 1.0;
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            view.alpha = targetAlpha;
        } completion:^(__unused BOOL finished) {
            NSNumber *restoredHidden = objc_getAssociatedObject(view, kLGPasscodeSuppressedHiddenKey);
            if (restoredHidden) view.hidden = restoredHidden.boolValue;
        }];
        objc_setAssociatedObject(view, kLGPasscodeSuppressedAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, kLGPasscodeSuppressedHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void LGApplyPasscodeBackdropSuppressionState(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return;
    LGDebugLog(@"passcode visible apply suppressed=%d", sLGPasscodeVisible);
    for (UIWindow *window in LGApplicationWindows(app)) {
        if (!window) continue;
        LGTraverseViews(window, ^(UIView *view) {
            if (!LGIsPasscodeSuppressibleRoot(view)) return;
            LGDebugLog(@"passcode suppress target class=%@ hidden=%d alpha=%.2f frame=%@",
                       NSStringFromClass(view.class),
                       view.hidden,
                       view.alpha,
                       NSStringFromCGRect(view.frame));
            LGSetPasscodeSuppressedState(view, sLGPasscodeVisible);
        });
    }
}

static void LGUpdatePasscodeVisible(BOOL visible) {
    if (sLGPasscodeVisible == visible) return;
    sLGPasscodeVisible = visible;
    LGLog(@"passcode visible state=%d", visible);
    dispatch_async(dispatch_get_main_queue(), ^{
        LGApplyPasscodeBackdropSuppressionState();
    });
}

static BOOL LGIsPasscodeBackgroundMaterialView(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"MTMaterialView"]) return NO;
    UIView *parent = view.superview;
    return [NSStringFromClass(parent.class) isEqualToString:@"CSPasscodeBackgroundView"];
}

static BOOL LGPasscodeBackgroundViewVisible(UIView *view) {
    if (!view) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"CSPasscodeBackgroundView"]
        && view.window
        && !view.hidden
        && view.alpha > 0.01
        && view.layer.opacity > 0.01f;
}

static void LGResetPasscodeBackgroundHost(UIView *host) {
    if (!host) return;
    LGRemoveAssociatedSubview(host, kLGPasscodeTintKey);
}

static void LGApplyPasscodeBackgroundIfNeeded(UIView *view) {
    if (!LGIsPasscodeBackgroundMaterialView(view)) return;

    UIView *host = view.superview;
    if (!host) return;

    if (!LGPasscodeEnabled()) {
        LGDebugLog(@"passcode background disabled host=%@", NSStringFromClass(host.class));
        LGResetPasscodeBackgroundHost(host);
        return;
    }

    LGDebugLog(@"passcode background apply material=%@ host=%@ frame=%@",
               NSStringFromClass(view.class),
               NSStringFromClass(host.class),
               NSStringFromCGRect(host.frame));

    UIView *tint = LGEnsureTintOverlayView(host,
                                           kLGPasscodeTintKey,
                                           0,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               [UIColor colorWithWhite:0.0 alpha:LGPasscodeBackgroundDarkTintAlpha()],
                               0.0,
                               host.layer,
                               NO);
    [host bringSubviewToFront:tint];
    [view removeFromSuperview];
}

static UIView *LGPasscodeButtonBackgroundHost(UIView *button) {
    if (!button) return nil;

    UIView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *subview in button.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"UIView"]) continue;
        if (CGRectIsEmpty(subview.bounds)) continue;
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width < 40.0 || height < 40.0) continue;

        CGFloat score = fabs(width - height);
        score += fabs(subview.layer.cornerRadius - MIN(width, height) * 0.5);
        score += fabs(subview.alpha - 0.15) * 100.0;
        score += subview.subviews.count * 50.0;
        LGDebugLog(@"passcode host candidate class=%@ frame=%@ bounds=%@ alpha=%.2f cr=%.2f subviews=%lu score=%.2f",
                   NSStringFromClass(subview.class),
                   NSStringFromCGRect(subview.frame),
                   NSStringFromCGRect(subview.bounds),
                   subview.alpha,
                   subview.layer.cornerRadius,
                   (unsigned long)subview.subviews.count,
                   score);
        if (score < bestScore) {
            best = subview;
            bestScore = score;
        }
    }

    if (best) {
        LGDebugLog(@"passcode host selected frame=%@ bounds=%@ alpha=%.2f cr=%.2f score=%.2f",
                   NSStringFromCGRect(best.frame),
                   NSStringFromCGRect(best.bounds),
                   best.alpha,
                   best.layer.cornerRadius,
                   bestScore);
    } else {
        LGDebugLog(@"passcode host selected none button=%@", NSStringFromClass(button.class));
    }
    return best;
}

static void LGRememberPasscodeButtonBackgroundState(UIView *view) {
    if (!view) return;
    if (!objc_getAssociatedObject(view, kLGPasscodeButtonBackgroundColorKey)) {
        objc_setAssociatedObject(view, kLGPasscodeButtonBackgroundColorKey, view.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(view, kLGPasscodeButtonAlphaKey)) {
        objc_setAssociatedObject(view, kLGPasscodeButtonAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(view, kLGPasscodeButtonOpaqueKey)) {
        objc_setAssociatedObject(view, kLGPasscodeButtonOpaqueKey, @(view.opaque), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGRestorePasscodeButtonBackgroundState(UIView *view) {
    if (!view) return;
    id color = objc_getAssociatedObject(view, kLGPasscodeButtonBackgroundColorKey);
    id alpha = objc_getAssociatedObject(view, kLGPasscodeButtonAlphaKey);
    id opaque = objc_getAssociatedObject(view, kLGPasscodeButtonOpaqueKey);
    view.backgroundColor = color == [NSNull null] ? nil : color;
    if ([alpha isKindOfClass:[NSNumber class]]) view.alpha = [alpha doubleValue];
    if ([opaque isKindOfClass:[NSNumber class]]) view.opaque = [opaque boolValue];
    LiquidGlassView *glass = LGPasscodeButtonGlassView(view);
    if (glass) glass.shapeMaskImage = nil;
}

static LiquidGlassView *LGPasscodeButtonGlassView(UIView *host) {
    if (!host) return nil;
    for (UIView *subview in host.subviews) {
        if ([subview isKindOfClass:[LiquidGlassView class]]) {
            return (LiquidGlassView *)subview;
        }
    }
    return nil;
}

static UIView *LGPasscodeStoredButtonHost(UIView *button) {
    return objc_getAssociatedObject(button, kLGPasscodeButtonHostKey);
}

static void LGSetPasscodeStoredButtonHost(UIView *button, UIView *host) {
    objc_setAssociatedObject(button, kLGPasscodeButtonHostKey, host, OBJC_ASSOCIATION_ASSIGN);
}

static UIViewPropertyAnimator *LGPasscodeButtonAnimator(UIView *host) {
    return objc_getAssociatedObject(host, kLGPasscodeButtonAnimatorKey);
}

static void LGSetPasscodeButtonAnimator(UIView *host, UIViewPropertyAnimator *animator) {
    objc_setAssociatedObject(host, kLGPasscodeButtonAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat LGPasscodeCurrentScale(UIView *view) {
    if (!view) return 1.0;
    CALayer *presentation = view.layer.presentationLayer;
    NSNumber *value = [presentation valueForKeyPath:@"transform.scale.x"];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value.doubleValue;
    }
    return view.transform.a;
}

static void LGSyncPasscodePresentationState(UIView *view) {
    if (!view) return;
    CGFloat currentScale = LGPasscodeCurrentScale(view);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [view.layer removeAllAnimations];
    view.transform = CGAffineTransformMakeScale(currentScale, currentScale);
    [CATransaction commit];
}

static UIColor *LGPasscodeButtonTargetTint(BOOL highlighted) {
    return highlighted
        ? [UIColor colorWithWhite:1.0 alpha:LGPasscodeActiveLightTintAlpha()]
        : [UIColor colorWithWhite:0.0 alpha:LGPasscodeDarkTintAlpha()];
}

static CGFloat LGPasscodeButtonTargetScale(BOOL highlighted) {
    return highlighted ? LGPasscodeActiveScale() : 1.0;
}

static CGFloat LGPasscodeButtonTargetSpecular(BOOL highlighted) {
    return highlighted ? LGPasscodeActiveSpecularOpacity() : LGPasscodeSpecularOpacity();
}

static CGFloat LGPasscodeButtonTargetBezel(BOOL highlighted) {
    return highlighted ? LGPasscodeActiveBezelWidth() : LGPasscodeBezelWidth();
}

static CGFloat LGPasscodeButtonTargetRefraction(BOOL highlighted) {
    return highlighted ? LGPasscodeActiveRefractionScale() : LGPasscodeRefractionScale();
}

static CGFloat LGPasscodeButtonTargetBlur(BOOL highlighted) {
    return highlighted ? LGPasscodeActiveBlur() : LGPasscodeBlur();
}

static void LGApplyPasscodeButtonVisualState(UIView *host, BOOL highlighted, BOOL animated) {
    if (!host) return;

    UIView *tint = objc_getAssociatedObject(host, kLGPasscodeButtonTintKey);
    LiquidGlassView *glass = LGPasscodeButtonGlassView(host);
    UIColor *targetTint = LGPasscodeButtonTargetTint(highlighted);
    CGAffineTransform targetTransform = CGAffineTransformMakeScale(LGPasscodeButtonTargetScale(highlighted),
                                                                  LGPasscodeButtonTargetScale(highlighted));
    CGFloat targetSpecular = LGPasscodeButtonTargetSpecular(highlighted);
    CGFloat targetBezel = LGPasscodeButtonTargetBezel(highlighted);
    CGFloat targetRefraction = LGPasscodeButtonTargetRefraction(highlighted);
    CGFloat targetBlur = LGPasscodeButtonTargetBlur(highlighted);

    [host.layer removeAllAnimations];
    [tint.layer removeAllAnimations];
    LGDebugLog(@"passcode highlight state=%d tint=%@ glass=%@ spec=%.2f bezel=%.2f refr=%.2f blur=%.2f animated=%d",
               highlighted,
               targetTint,
               glass,
               targetSpecular,
               targetBezel,
               targetRefraction,
               targetBlur,
               animated);

    void (^stopAnimator)(void) = ^{
        UIViewPropertyAnimator *animator = LGPasscodeButtonAnimator(host);
        if (animator) {
            LGDebugLog(@"passcode animator stop host=%@ highlighted=%d", NSStringFromClass(host.class), highlighted);
            [animator stopAnimation:YES];
            LGSetPasscodeButtonAnimator(host, nil);
        }
    };

    void (^changes)(void) = ^{
        host.transform = targetTransform;
        tint.backgroundColor = targetTint;
        if (glass) {
            glass.specularOpacity = targetSpecular;
            glass.bezelWidth = targetBezel;
            glass.refractionScale = targetRefraction;
            glass.blur = targetBlur;
        }
    };

    if (!animated) {
        stopAnimator();
        LGSyncPasscodePresentationState(host);
        LGDebugLog(@"passcode visual immediate scale=%.3f", LGPasscodeCurrentScale(host));
        changes();
        return;
    }

    LGSyncPasscodePresentationState(host);
    stopAnimator();

    CGFloat duration = highlighted ? LGPasscodePressInDuration() : LGPasscodeReleaseDuration();
    CGFloat currentScale = LGPasscodeCurrentScale(host);
    CGFloat mass = highlighted ? LGPasscodePressInMass() : LGPasscodeReleaseMass();
    CGFloat stiffness = highlighted ? LGPasscodePressInStiffness() : LGPasscodeReleaseStiffness();
    CGFloat damping = highlighted ? LGPasscodePressInDamping() : LGPasscodeReleaseDamping();
    CGFloat velocity = highlighted ? LGPasscodePressInVelocity() : LGPasscodeReleaseVelocity();
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass
        stiffness:stiffness
        damping:damping
        initialVelocity:CGVectorMake(velocity, velocity)];
    LGDebugLog(@"passcode animator start highlighted=%d currentScale=%.3f targetScale=%.3f duration=%.3f mass=%.3f stiffness=%.3f damping=%.3f velocity=%.3f",
               highlighted,
               currentScale,
               LGPasscodeButtonTargetScale(highlighted),
               duration,
               mass,
               stiffness,
               damping,
               velocity);
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:timing];
    animator.interruptible = YES;
    [animator addAnimations:changes];
    [animator addCompletion:^(__unused UIViewAnimatingPosition finalPosition) {
        LGDebugLog(@"passcode animator complete highlighted=%d finalScale=%.3f",
                   highlighted,
                   LGPasscodeCurrentScale(host));
    }];
    [animator startAnimation];
    LGSetPasscodeButtonAnimator(host, animator);
}

static void LGResetPasscodeButton(UIView *button) {
    UIView *host = LGPasscodeStoredButtonHost(button);
    if (!host) host = LGPasscodeButtonBackgroundHost(button);
    if (!host) return;
    LGDebugLog(@"passcode reset host=%@ frame=%@",
               NSStringFromClass(host.class),
               NSStringFromCGRect(host.frame));
    UIViewPropertyAnimator *animator = LGPasscodeButtonAnimator(host);
    if (animator) {
        [animator stopAnimation:YES];
        LGSetPasscodeButtonAnimator(host, nil);
    }
    LGCleanupLockscreenHost(host);
    LGRemoveAssociatedSubview(host, kLGPasscodeButtonTintKey);
    host.transform = CGAffineTransformIdentity;
    LGRestorePasscodeButtonBackgroundState(host);
    objc_setAssociatedObject(button, kLGPasscodeButtonHighlightedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, kLGPasscodeButtonHighlightBeganKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, kLGPasscodeButtonReleaseTokenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGSetPasscodeStoredButtonHost(button, nil);
}

static void LGInjectPasscodeButtonIfNeeded(UIView *button) {
    UIView *host = LGPasscodeButtonBackgroundHost(button);
    if (!host) {
        LGDebugLog(@"passcode inject skipped no host button=%@", NSStringFromClass(button.class));
        return;
    }

    if (!button.window || !LGPasscodeEnabled()) {
        LGDebugLog(@"passcode inject disabled window=%d enabled=%d",
                   button.window != nil,
                   LGPasscodeEnabled());
        LGResetPasscodeButton(button);
        return;
    }

    UIView *previousHost = LGPasscodeStoredButtonHost(button);
    if (previousHost && previousHost != host) {
        LGDebugLog(@"passcode host changed old=%@ new=%@",
                   NSStringFromCGRect(previousHost.frame),
                   NSStringFromCGRect(host.frame));
        UIViewPropertyAnimator *oldAnimator = LGPasscodeButtonAnimator(previousHost);
        if (oldAnimator) {
            [oldAnimator stopAnimation:YES];
            LGSetPasscodeButtonAnimator(previousHost, nil);
        }
        LGCleanupLockscreenHost(previousHost);
        LGRemoveAssociatedSubview(previousHost, kLGPasscodeButtonTintKey);
        previousHost.transform = CGAffineTransformIdentity;
        LGRestorePasscodeButtonBackgroundState(previousHost);
    }

    LGRememberPasscodeButtonBackgroundState(host);
    host.backgroundColor = UIColor.clearColor;
    host.alpha = 1.0;
    host.opaque = NO;
    host.clipsToBounds = YES;
    host.layer.masksToBounds = YES;
    CGFloat cornerRadius = MIN(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds)) * 0.5;
    host.layer.cornerRadius = cornerRadius;
    host.layer.cornerCurve = kCACornerCurveCircular;
    LGLockscreenInjectGlassWithSettingsAndMode(host,
                                               LGPasscodeRenderingModeKey(),
                                               cornerRadius,
                                               LGPasscodeBezelWidth(),
                                               LGPasscodeGlassThickness(),
                                               LGPasscodeRefractionScale(),
                                               LGPasscodeRefractiveIndex(),
                                               LGPasscodeSpecularOpacity(),
                                               LGPasscodeBlur(),
                                               LGPasscodeWallpaperScale(),
                                               0.0,
                                               0.0);
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kLGPasscodeButtonTintKey,
                                           0,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               [UIColor colorWithWhite:0.0 alpha:LGPasscodeDarkTintAlpha()],
                               cornerRadius,
                               host.layer,
                               NO);
    tint.layer.cornerCurve = kCACornerCurveCircular;
    [host bringSubviewToFront:tint];
    LiquidGlassView *glass = LGPasscodeButtonGlassView(host);
    if (glass) {
        glass.shapeMaskImage = LGPasscodeCircleMaskImage(host.bounds.size);
    }
    BOOL alreadyInjected = previousHost == host && LGPasscodeButtonGlassView(host) && tint != nil;
    LGSetPasscodeStoredButtonHost(button, host);
    if (!alreadyInjected) {
        BOOL highlighted = [objc_getAssociatedObject(button, kLGPasscodeButtonHighlightedKey) boolValue];
        LGApplyPasscodeButtonVisualState(host, highlighted, NO);
    } else {
        LGDebugLog(@"passcode inject reuse host=%@ frame=%@ transform=%@",
                   NSStringFromClass(host.class),
                   NSStringFromCGRect(host.frame),
                   NSStringFromCGAffineTransform(host.transform));
    }
    LGDebugLog(@"passcode inject host=%@ frame=%@ cr=%.2f tint=%@ glass=%@",
               NSStringFromClass(host.class),
               NSStringFromCGRect(host.frame),
               cornerRadius,
               tint.backgroundColor,
               LGPasscodeButtonGlassView(host));
    LGAttachLockHostIfNeeded(host);
}

static void LGSetPasscodeButtonHighlighted(UIView *button, BOOL highlighted) {
    UIView *host = LGPasscodeButtonBackgroundHost(button);
    if (!host) {
        LGDebugLog(@"passcode highlight skipped no host state=%d", highlighted);
        return;
    }
    NSNumber *current = objc_getAssociatedObject(button, kLGPasscodeButtonHighlightedKey);
    if (current && current.boolValue == highlighted) {
        LGDebugLog(@"passcode highlight redundant state=%d", highlighted);
        return;
    }
    LGDebugLog(@"passcode highlight transition old=%@ new=%d", current, highlighted);
    objc_setAssociatedObject(button, kLGPasscodeButtonHighlightedKey, @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (highlighted) {
        objc_setAssociatedObject(button, kLGPasscodeButtonHighlightBeganKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSNumber *token = @([objc_getAssociatedObject(button, kLGPasscodeButtonReleaseTokenKey) unsignedIntegerValue] + 1);
        objc_setAssociatedObject(button, kLGPasscodeButtonReleaseTokenKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGApplyPasscodeButtonVisualState(host, YES, YES);
        return;
    }

    CFTimeInterval began = [objc_getAssociatedObject(button, kLGPasscodeButtonHighlightBeganKey) doubleValue];
    CFTimeInterval elapsed = began > 0.0 ? (CACurrentMediaTime() - began) : kLGPasscodeMinimumLightTintHold;
    CFTimeInterval remaining = MAX(0.0, kLGPasscodeMinimumLightTintHold - elapsed);
    NSNumber *token = @([objc_getAssociatedObject(button, kLGPasscodeButtonReleaseTokenKey) unsignedIntegerValue] + 1);
    objc_setAssociatedObject(button, kLGPasscodeButtonReleaseTokenKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (remaining <= 0.0) {
        LGApplyPasscodeButtonVisualState(host, NO, YES);
        return;
    }

    LGDebugLog(@"passcode light tint hold remaining=%.3f", remaining);
    __weak UIView *weakButton = button;
    __weak UIView *weakHost = host;
    NSUInteger tokenValue = token.unsignedIntegerValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongButton = weakButton;
        UIView *strongHost = weakHost;
        if (!strongButton || !strongHost) return;
        NSNumber *currentHighlighted = objc_getAssociatedObject(strongButton, kLGPasscodeButtonHighlightedKey);
        NSNumber *currentToken = objc_getAssociatedObject(strongButton, kLGPasscodeButtonReleaseTokenKey);
        if (currentHighlighted.boolValue) return;
        if (currentToken.unsignedIntegerValue != tokenValue) return;
        LGApplyPasscodeButtonVisualState(strongHost, NO, YES);
    });
}

%hook MTMaterialView

- (void)didMoveToSuperview {
    %orig;
    LGApplyPasscodeBackgroundIfNeeded((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGApplyPasscodeBackgroundIfNeeded((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyPasscodeBackgroundIfNeeded((UIView *)self);
}

%end

%hook SBPasscodeNumberPadButton

- (void)didMoveToWindow {
    %orig;
    LGInjectPasscodeButtonIfNeeded((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGInjectPasscodeButtonIfNeeded((UIView *)self);
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    LGSetPasscodeButtonHighlighted((UIView *)self, highlighted);
}

%end

%hook CSPasscodeBackgroundView

- (void)didMoveToWindow {
    %orig;
    LGUpdatePasscodeVisible(LGPasscodeBackgroundViewVisible((UIView *)self));
}

- (void)layoutSubviews {
    %orig;
    LGUpdatePasscodeVisible(LGPasscodeBackgroundViewVisible((UIView *)self));
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    LGUpdatePasscodeVisible(LGPasscodeBackgroundViewVisible((UIView *)self));
}

%end
