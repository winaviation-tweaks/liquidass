#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface UIKeyboard : UIView
+ (instancetype)activeKeyboard;
+ (instancetype)activeKeyboardForScreen:(UIScreen *)screen;
+ (CGSize)sizeForInterfaceOrientation:(NSInteger)orientation
                      ignoreInputView:(BOOL)ignoreInputView;
- (BOOL)showPredictionBar;
- (void)_setPreferredHeight:(CGFloat)height;
- (void)updateLayout;
@end

@interface UIKBBackdropView : UIView
@end

@interface UIKBVisualEffectView : UIView
@end

@interface UIKBRenderer : NSObject
- (void)renderBackgroundTraits:(id)traits allowCaching:(BOOL)allowCaching;
@end

@interface UIKBSplitImageView : UIView
@end

@interface UIKeyboardLayoutStar : UIView
@end

@interface UIKBTextStyle : NSObject
- (NSString *)fontName;
@end

static BOOL gLGKeyboardPredictionStateKnown;
static BOOL gLGKeyboardHasPredictionStrip;
static __thread NSUInteger gLGKeyboardSizingDepth;
static const void *kLGKeyboardGlassKey = &kLGKeyboardGlassKey;
static const void *kLGKeyboardSuppressingHiddenKey =
    &kLGKeyboardSuppressingHiddenKey;
static const void *kLGKeyboardRequestedHiddenKey =
    &kLGKeyboardRequestedHiddenKey;
static const void *kLGKeyboardVisualEffectSuppressingHiddenKey =
    &kLGKeyboardVisualEffectSuppressingHiddenKey;
static const void *kLGKeyboardVisualEffectRequestedHiddenKey =
    &kLGKeyboardVisualEffectRequestedHiddenKey;
static const void *kLGKeyboardBorderKey = &kLGKeyboardBorderKey;
static NSHashTable<UIView *> *gLGKeyboardBackdrops;
static NSHashTable<UIView *> *gLGKeyboardVisualEffects;
static NSUInteger gLGKeyboardBackdropLogCount;
static NSMutableSet<NSString *> *gLGKeyboardHookedKeyplaneClasses;
static BOOL gLGKeyboardKeyplaneRefreshScheduled;
static __thread BOOL gLGKeyboardApplyingKeyplaneBounds;
static const CGFloat kLGKeyboardBottomGlassExtra = 10.0;

static CGFloat LGKeyboardCornerRadius(void) {
    return fmin(60.0, fmax(0.0,
        LG_prefFloat(@"Keyboard.CornerRadius",
                     LGKeyboardDefaultCornerRadius)));
}

static CGFloat LGKeyboardTopOverhang(void) {
    return fmin(60.0, fmax(0.0,
        LG_prefFloat(@"Keyboard.Overhang",
                     LGKeyboardDefaultOverhang)));
}

static CGFloat LGKeyboardKeyplaneCompensation(void) {
    return LGKeyboardTopOverhang() * 0.5;
}

static BOOL LGIsRemoteKeyboardWindow(UIWindow *window) {
    if (!window) return NO;

    Class remoteKeyboardWindowClass =
        NSClassFromString(@"UIRemoteKeyboardWindow");
    if (remoteKeyboardWindowClass) {
        return [window isKindOfClass:remoteKeyboardWindowClass];
    }

    return [NSStringFromClass(window.class)
        isEqualToString:@"UIRemoteKeyboardWindow"];
}

static id LGKeyboardSendObject(id target, SEL selector);
static void LGKeyboardScheduleKeyplaneRefresh(void);

static id LGActiveKeyboardForScreen(UIScreen *screen) {
    Class keyboardClass = NSClassFromString(@"UIKeyboard");
    if (!keyboardClass) return nil;

    SEL perScreenSelector =
        NSSelectorFromString(@"activeKeyboardForScreen:");

    if (screen &&
        [keyboardClass respondsToSelector:perScreenSelector]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(
            keyboardClass, perScreenSelector, screen);
    }

    return LGKeyboardSendObject(
        keyboardClass, NSSelectorFromString(@"activeKeyboard"));
}

static BOOL LGKeyboardNeedsTopReserve(void) {
    if (!lgHostEnabled(@"Keyboard")) return NO;

    if (gLGKeyboardPredictionStateKnown) {
        return !gLGKeyboardHasPredictionStrip;
    }

    id keyboard = LGActiveKeyboardForScreen(UIScreen.mainScreen);
    SEL predictionSelector = NSSelectorFromString(@"showPredictionBar");
    if (keyboard &&
        [keyboard respondsToSelector:predictionSelector]) {
        BOOL showsPrediction =
            ((BOOL (*)(id, SEL))objc_msgSend)(
                keyboard, predictionSelector);
        return !showsPrediction;
    }

    return NO;
}

static CGSize LGKeyboardReserveSize(CGSize size) {
    if (LGKeyboardNeedsTopReserve() && size.height > 1.0) {

        size.height += LGKeyboardTopOverhang();
    }

    return size;
}

static void LGKeyboardRefreshReportedGeometry(UIScreen *screen) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id keyboard = LGActiveKeyboardForScreen(screen);
        if (!keyboard) return;

        UIView *keyboardView = [keyboard isKindOfClass:UIView.class]
            ? (UIView *)keyboard
            : nil;
        if (!keyboardView) return;

        [keyboardView invalidateIntrinsicContentSize];
        [keyboardView setNeedsLayout];
        [keyboardView.superview setNeedsLayout];
        [keyboardView.window setNeedsLayout];

        SEL updateSelector = NSSelectorFromString(@"updateLayout");
        if ([keyboard respondsToSelector:updateSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(
                keyboard, updateSelector);
        }

        [keyboardView.window layoutIfNeeded];
        LGKeyboardScheduleKeyplaneRefresh();
    });
}

static NSString *LGKeyboardCompactFontName(void) {
    static NSString *postScriptName;
    static CGFontRef compactFont;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableOrderedSet<NSString *> *candidates =
            [NSMutableOrderedSet orderedSet];
        Dl_info info = {0};
        if (dladdr((const void *)&LGKeyboardCompactFontName, &info) != 0 &&
            info.dli_fname) {
            NSString *cursor = [[NSString stringWithUTF8String:info.dli_fname]
                stringByDeletingLastPathComponent];
            for (NSUInteger depth = 0; depth < 8 && cursor.length > 1; depth++) {
                [candidates addObject:[[cursor
                    stringByAppendingPathComponent:
                        @"Library/PreferenceBundles/LiquidAssPrefs.bundle"]
                    stringByAppendingPathComponent:
                        @"SF-Compact-Display-Regular.otf"]];
                NSString *parent = [cursor stringByDeletingLastPathComponent];
                if ([parent isEqualToString:cursor]) break;
                cursor = parent;
            }
        }
        [candidates addObject:jbroot(
            @"/Library/PreferenceBundles/LiquidAssPrefs.bundle/SF-Compact-Display-Regular.otf")];

        NSString *fontPath;
        for (NSString *candidate in candidates) {
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
                fontPath = candidate;
                break;
            }
        }
        NSData *data = fontPath ? [NSData dataWithContentsOfFile:fontPath] : nil;
        CGDataProviderRef provider = data
            ? CGDataProviderCreateWithCFData((__bridge CFDataRef)data) : NULL;
        compactFont = provider ? CGFontCreateWithDataProvider(provider) : NULL;
        if (provider) CGDataProviderRelease(provider);
        if (compactFont) {
            postScriptName = CFBridgingRelease(
                CGFontCopyPostScriptName(compactFont));
            CFErrorRef error = NULL;
            CTFontManagerRegisterGraphicsFont(compactFont, &error);
            if (error) CFRelease(error);
        }
        LGLog(@"[keyboard] compact font path=%@ font=%@",
              fontPath ?: @"(unavailable)",
              postScriptName ?: @"(unavailable)");
    });
    return postScriptName;
}

static id LGKeyboardValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id LGKeyboardSendObject(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static UIView *LGKeyboardCurrentKeyplaneView(void) {
    Class implClass = NSClassFromString(@"UIKeyboardImpl");
    id impl = LGKeyboardSendObject(implClass,
                                   NSSelectorFromString(@"activeInstance"));
    if (!impl) {
        impl = LGKeyboardSendObject(implClass,
                                    NSSelectorFromString(@"sharedInstance"));
    }

    id layout = LGKeyboardSendObject(impl,
                                     NSSelectorFromString(@"activeLayout"));
    id keyplane = LGKeyboardSendObject(
        layout, NSSelectorFromString(@"currentKeyplaneView"));
    return [keyplane isKindOfClass:UIView.class] ? (UIView *)keyplane : nil;
}

static CGFloat LGKeyboardTargetKeyplaneBoundsY(void) {
    return LGKeyboardNeedsTopReserve()
        ? -LGKeyboardKeyplaneCompensation()
        : 0.0;
}

static BOOL LGKeyboardIsDirectKeyplaneAtlas(UIView *view) {
    if (!view || !view.superview) return NO;
    return [NSStringFromClass(view.class)
                isEqualToString:@"UIKBSplitImageView"] &&
           [NSStringFromClass(view.superview.class)
                isEqualToString:@"UIKBKeyplaneView"];
}

static void LGKeyboardNormalizeKeyplaneAtlasFrames(UIView *keyplane) {
    if (!keyplane || !LGKeyboardNeedsTopReserve()) return;

    // moving keyplane bounds must not move its baked image atlas twice
    CGFloat keyplaneBoundsY = keyplane.bounds.origin.y;
    if (fabs(keyplaneBoundsY) < 0.01) return;

    for (UIView *child in keyplane.subviews) {
        if (!LGKeyboardIsDirectKeyplaneAtlas(child)) continue;

        CGRect frame = child.frame;

        if (fabs(frame.origin.y - keyplaneBoundsY) < 0.51) {
            frame.origin.y -= keyplaneBoundsY;
            child.frame = frame;
        }
    }
}

static void LGKeyboardCallOriginalKeyplaneSetBounds(UIView *keyplane,
                                                     CGRect bounds) {
    SEL originalSelector =
        NSSelectorFromString(@"lg_keyboard_original_setBounds:");
    if ([keyplane respondsToSelector:originalSelector]) {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(
            keyplane, originalSelector, bounds);
    }
}

static void LGKeyboardApplyKeyplaneBoundsOffset(UIView *keyplane) {
    if (!keyplane || gLGKeyboardApplyingKeyplaneBounds) return;

    CGRect bounds = keyplane.bounds;
    CGFloat targetY = LGKeyboardTargetKeyplaneBoundsY();
    if (fabs(bounds.origin.y - targetY) < 0.01) return;

    bounds.origin.y = targetY;
    gLGKeyboardApplyingKeyplaneBounds = YES;
    LGKeyboardCallOriginalKeyplaneSetBounds(keyplane, bounds);
    gLGKeyboardApplyingKeyplaneBounds = NO;
}

static void LGKeyboardKeyplaneSetBounds(id object, SEL selector,
                                         CGRect bounds) {
    UIView *keyplane = [object isKindOfClass:UIView.class]
        ? (UIView *)object
        : nil;
    if (!keyplane) return;

    bounds.origin.y = LGKeyboardTargetKeyplaneBoundsY();
    LGKeyboardCallOriginalKeyplaneSetBounds(keyplane, bounds);
}

static void LGKeyboardKeyplaneLayoutSubviews(id object, SEL selector) {
    SEL originalSelector =
        NSSelectorFromString(@"lg_keyboard_original_layoutSubviews");
    if ([object respondsToSelector:originalSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(object, originalSelector);
    }

    UIView *keyplane = [object isKindOfClass:UIView.class]
        ? (UIView *)object
        : nil;
    LGKeyboardApplyKeyplaneBoundsOffset(keyplane);
    LGKeyboardNormalizeKeyplaneAtlasFrames(keyplane);
}

static void LGKeyboardInstallKeyplaneHooks(UIView *keyplane) {
    if (!keyplane) return;

    // keyplane classes vary so hook each concrete class once
    Class keyplaneClass = object_getClass(keyplane);
    NSString *className = NSStringFromClass(keyplaneClass);
    if (!keyplaneClass || !className.length ||
        [gLGKeyboardHookedKeyplaneClasses containsObject:className]) {
        LGKeyboardApplyKeyplaneBoundsOffset(keyplane);
        LGKeyboardNormalizeKeyplaneAtlasFrames(keyplane);
        return;
    }

    @synchronized (gLGKeyboardHookedKeyplaneClasses) {
        if ([gLGKeyboardHookedKeyplaneClasses containsObject:className]) {
            LGKeyboardApplyKeyplaneBoundsOffset(keyplane);
            LGKeyboardNormalizeKeyplaneAtlasFrames(keyplane);
            return;
        }

        SEL setBoundsSelector = @selector(setBounds:);
        Method setBoundsMethod =
            class_getInstanceMethod(keyplaneClass, setBoundsSelector);
        if (!setBoundsMethod) return;

        IMP originalSetBounds = method_getImplementation(setBoundsMethod);
        const char *setBoundsTypes = method_getTypeEncoding(setBoundsMethod);
        SEL originalSetBoundsSelector =
            NSSelectorFromString(@"lg_keyboard_original_setBounds:");
        class_addMethod(keyplaneClass, originalSetBoundsSelector,
                        originalSetBounds, setBoundsTypes);

        if (!class_addMethod(keyplaneClass, setBoundsSelector,
                             (IMP)LGKeyboardKeyplaneSetBounds,
                             setBoundsTypes)) {
            Method directSetBoundsMethod =
                class_getInstanceMethod(keyplaneClass, setBoundsSelector);
            method_setImplementation(directSetBoundsMethod,
                                     (IMP)LGKeyboardKeyplaneSetBounds);
        }

        SEL layoutSelector = @selector(layoutSubviews);
        Method layoutMethod =
            class_getInstanceMethod(keyplaneClass, layoutSelector);
        if (layoutMethod) {
            IMP originalLayout = method_getImplementation(layoutMethod);
            const char *layoutTypes = method_getTypeEncoding(layoutMethod);
            SEL originalLayoutSelector =
                NSSelectorFromString(@"lg_keyboard_original_layoutSubviews");
            class_addMethod(keyplaneClass, originalLayoutSelector,
                            originalLayout, layoutTypes);

            if (!class_addMethod(keyplaneClass, layoutSelector,
                                 (IMP)LGKeyboardKeyplaneLayoutSubviews,
                                 layoutTypes)) {
                Method directLayoutMethod =
                    class_getInstanceMethod(keyplaneClass, layoutSelector);
                method_setImplementation(directLayoutMethod,
                                         (IMP)LGKeyboardKeyplaneLayoutSubviews);
            }
        }

        [gLGKeyboardHookedKeyplaneClasses addObject:className];
        LGLog(@"[keyboard] hooked runtime keyplane class=%@ offset=%.2f",
              className, LGKeyboardKeyplaneCompensation());
    }

    LGKeyboardApplyKeyplaneBoundsOffset(keyplane);
    LGKeyboardNormalizeKeyplaneAtlasFrames(keyplane);
}

static void LGKeyboardRefreshCurrentKeyplane(void) {
    UIView *keyplane = LGKeyboardCurrentKeyplaneView();
    LGKeyboardInstallKeyplaneHooks(keyplane);
}

static void LGKeyboardScheduleKeyplaneRefresh(void) {
    if (gLGKeyboardKeyplaneRefreshScheduled) return;
    gLGKeyboardKeyplaneRefreshScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        gLGKeyboardKeyplaneRefreshScheduled = NO;
        LGKeyboardRefreshCurrentKeyplane();
    });
}

static BOOL LGIsKeyboardBackdrop(UIView *view) {
    return [NSStringFromClass(view.class) isEqualToString:@"UIKBBackdropView"] &&
           [NSStringFromClass(view.superview.class)
               isEqualToString:@"UIKBInputBackdropView"];
}

static void LGKeyboardSetStockHidden(UIView *stock, BOOL hidden) {
    objc_setAssociatedObject(stock, kLGKeyboardSuppressingHiddenKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    stock.hidden = hidden;
    objc_setAssociatedObject(stock, kLGKeyboardSuppressingHiddenKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGRemoveKeyboardGlass(UIView *stock) {
    LGLiveBackdropView *glass =
        objc_getAssociatedObject(stock, kLGKeyboardGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(stock, kLGKeyboardGlassKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    LGKeyboardSetStockHidden(
        stock,
        [objc_getAssociatedObject(stock, kLGKeyboardRequestedHiddenKey)
            boolValue]);
}

static NSArray<UIView *> *LGKeyboardBackdropsInWindow(UIWindow *window) {
    if (!LGIsRemoteKeyboardWindow(window)) return @[];

    NSMutableArray<UIView *> *backdrops = [NSMutableArray array];
    for (UIView *candidate in gLGKeyboardBackdrops.allObjects) {
        if (candidate.window == window && LGIsKeyboardBackdrop(candidate)) {
            [backdrops addObject:candidate];
        }
    }
    return backdrops;
}

static CGRect LGKeyboardMergedBackdropFrame(NSArray<UIView *> *backdrops,
                                            UIView *container) {
    CGRect frame = CGRectNull;
    for (UIView *backdrop in backdrops) {
        CGRect converted = [backdrop.superview convertRect:backdrop.frame
                                                    toView:container];
        frame = CGRectIsNull(frame) ? converted : CGRectUnion(frame, converted);
    }
    return CGRectIsNull(frame) ? CGRectZero : CGRectIntegral(frame);
}

static NSString *LGKeyboardBackdropSummary(NSArray<UIView *> *backdrops) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIView *view in backdrops) {
        [parts addObject:[NSString stringWithFormat:@"%@ frame=%@ bounds=%@ hidden=%d",
            NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
            NSStringFromCGRect(view.bounds), view.hidden]];
    }
    return [parts componentsJoinedByString:@"; "];
}

static void LGUpdateKeyboardBorder(LGLiveBackdropView *glass) {
    CAShapeLayer *border = objc_getAssociatedObject(glass, kLGKeyboardBorderKey);
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        objc_setAssociatedObject(glass, kLGKeyboardBorderKey, border,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [glass.layer addSublayer:border];
    CGFloat scale = glass.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = 1.0 / MAX(scale, 1.0);
    CGRect borderRect = CGRectInset(glass.bounds, lineWidth * 0.5,
                                    lineWidth * 0.5);
    CGFloat radius = MAX(0.0, glass.layer.cornerRadius - lineWidth * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    border.frame = glass.bounds;
    border.contentsScale = scale;
    border.lineWidth = lineWidth;
    border.path = [UIBezierPath bezierPathWithRoundedRect:borderRect
                                              cornerRadius:radius].CGPath;
    [CATransaction commit];
}

static void LGUpdateKeyboardGlass(UIView *stock) {
    if (!LGIsKeyboardBackdrop(stock) || !stock.superview) return;

    if (!LGIsRemoteKeyboardWindow(stock.window)) {
        LGRemoveKeyboardGlass(stock);
        return;
    }

    if (!lgHostEnabled(@"Keyboard")) {
        LGRemoveKeyboardGlass(stock);
        return;
    }

    NSArray<UIView *> *backdrops = LGKeyboardBackdropsInWindow(stock.window);
    if (!backdrops.count) backdrops = @[ stock ];
    UIView *primary = stock;
    for (UIView *candidate in backdrops) {
        if (CGRectGetHeight(candidate.bounds) > CGRectGetHeight(primary.bounds)) {
            primary = candidate;
        }
    }

    if (stock != primary) {
        LGRemoveKeyboardGlass(stock);
        LGKeyboardSetStockHidden(stock, YES);
        return;
    }

    UIView *container = primary.superview;
    if (!container) return;
    CGRect mergedFrame = LGKeyboardMergedBackdropFrame(backdrops, container);
    if (CGRectIsEmpty(mergedFrame)) {
        mergedFrame = [primary.superview convertRect:primary.frame toView:container];
    }
    BOOL hasPredictionStrip = NO;
    for (UIView *backdrop in backdrops) {
        if (backdrop != primary &&
            CGRectGetHeight(backdrop.bounds) > 1.0) {
            hasPredictionStrip = YES;
            break;
        }
    }
    BOOL predictionStateChanged =
        !gLGKeyboardPredictionStateKnown ||
        gLGKeyboardHasPredictionStrip != hasPredictionStrip;

    gLGKeyboardPredictionStateKnown = YES;
    gLGKeyboardHasPredictionStrip = hasPredictionStrip;

    if (predictionStateChanged) {
        LGKeyboardRefreshReportedGeometry(stock.window.screen);
    }
    if (!hasPredictionStrip) {
        container.clipsToBounds = NO;
        container.layer.masksToBounds = NO;

        LGKeyboardScheduleKeyplaneRefresh();
    }

    mergedFrame.size.height += LGKeyboardTopOverhang() + kLGKeyboardBottomGlassExtra;

    if (gLGKeyboardBackdropLogCount++ < 4) {
        LGLog(@"[keyboard] backdrop merge count=%lu prediction=%d primary=%p container=%@ merged=%@ members=[%@]",
              (unsigned long)backdrops.count, hasPredictionStrip, primary,
              NSStringFromClass(container.class), NSStringFromCGRect(mergedFrame),
              LGKeyboardBackdropSummary(backdrops));
    }

    LGLiveBackdropView *glass =
        objc_getAssociatedObject(primary, kLGKeyboardGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(mergedFrame, nil, @"Keyboard");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.lgSpecularEnabledOverride = @NO;
        [container addSubview:glass];
        objc_setAssociatedObject(primary, kLGKeyboardGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"Keyboard", nil);
    } else if (glass.superview != container) {
        [glass removeFromSuperview];
        [container addSubview:glass];
    }

    glass.frame = mergedFrame;
    glass.layer.mask = nil;
    glass.layer.cornerRadius = LGKeyboardCornerRadius();
    glass.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    LGUpdateKeyboardBorder(glass);
    glass.alpha = primary.alpha;
    glass.hidden =
        [objc_getAssociatedObject(primary, kLGKeyboardRequestedHiddenKey)
            boolValue];
    for (UIView *backdrop in backdrops) {
        if (backdrop != primary) LGRemoveKeyboardGlass(backdrop);
        LGKeyboardSetStockHidden(backdrop, YES);
    }
}

static void LGKeyboardSetVisualEffectHidden(UIView *effectView, BOOL hidden) {
    objc_setAssociatedObject(effectView,
                             kLGKeyboardVisualEffectSuppressingHiddenKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    effectView.hidden = hidden;
    objc_setAssociatedObject(effectView,
                             kLGKeyboardVisualEffectSuppressingHiddenKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGUpdateKeyboardVisualEffect(UIView *effectView) {
    if (!effectView.window) return;
    BOOL requestedHidden =
        [objc_getAssociatedObject(effectView,
                                  kLGKeyboardVisualEffectRequestedHiddenKey)
            boolValue];

    LGKeyboardSetVisualEffectHidden(effectView,
                                    lgHostEnabled(@"Keyboard") ? YES : requestedHidden);
}

%hook UIKBBackdropView

- (void)didMoveToWindow {
    %orig;
    if (LGIsRemoteKeyboardWindow(self.window)) {
        [gLGKeyboardBackdrops addObject:self];
        LGUpdateKeyboardGlass(self);
    } else {
        [gLGKeyboardBackdrops removeObject:self];
        LGRemoveKeyboardGlass(self);
    }
}

- (void)layoutSubviews {
    %orig;
    LGUpdateKeyboardGlass(self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    LGUpdateKeyboardGlass(self);
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    LGUpdateKeyboardGlass(self);
}

- (void)setHidden:(BOOL)hidden {
    if ([objc_getAssociatedObject(self, kLGKeyboardSuppressingHiddenKey)
            boolValue]) {
        %orig(hidden);
        return;
    }

    objc_setAssociatedObject(self, kLGKeyboardRequestedHiddenKey, @(hidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGLiveBackdropView *glass =
        objc_getAssociatedObject(self, kLGKeyboardGlassKey);
    if (glass && lgHostEnabled(@"Keyboard") &&
        LGIsRemoteKeyboardWindow(self.window)) {
        glass.hidden = hidden;
        %orig(YES);
        return;
    }
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);
    LGLiveBackdropView *glass =
        objc_getAssociatedObject(self, kLGKeyboardGlassKey);
    glass.alpha = alpha;
}

%end

%hook UIKBVisualEffectView

- (void)didMoveToWindow {
    %orig;
    [gLGKeyboardVisualEffects addObject:self];
    LGUpdateKeyboardVisualEffect(self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateKeyboardVisualEffect(self);
}

- (void)setHidden:(BOOL)hidden {
    if ([objc_getAssociatedObject(self,
                                  kLGKeyboardVisualEffectSuppressingHiddenKey)
            boolValue]) {
        %orig(hidden);
        return;
    }

    objc_setAssociatedObject(self, kLGKeyboardVisualEffectRequestedHiddenKey,
                             @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (lgHostEnabled(@"Keyboard")) {
        %orig(YES);
        return;
    }
    %orig(hidden);
}

%end

%hook UIKBRenderer

- (void)renderBackgroundTraits:(id)traits allowCaching:(BOOL)allowCaching {
    id geometry = LGKeyboardValue(traits, @"geometry");
    SEL radiusGetter = NSSelectorFromString(@"roundRectRadius");
    SEL radiusSetter = NSSelectorFromString(@"setRoundRectRadius:");
    BOOL changesRadius = lgHostEnabled(@"Keyboard") && geometry &&
        [geometry respondsToSelector:radiusGetter] &&
        [geometry respondsToSelector:radiusSetter];
    CGFloat stockRadius = 0.0;
    if (changesRadius) {
        stockRadius = ((CGFloat (*)(id, SEL))objc_msgSend)(geometry,
                                                          radiusGetter);
        CGFloat radius = fmin(23.0, fmax(0.0,
            LG_prefFloat(@"Keyboard.KeyRadius",
                         LGKeyboardDefaultKeyRadius)));
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(geometry, radiusSetter,
                                                   radius);
    }
    @try {
        %orig(traits, allowCaching);
    } @finally {
        if (changesRadius) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(geometry, radiusSetter,
                                                       stockRadius);
        }
    }
}

%end

%hook UIKeyboard

- (void)layoutSubviews {
    %orig;
    LGKeyboardScheduleKeyplaneRefresh();
}

+ (CGSize)sizeForInterfaceOrientation:(NSInteger)orientation
                      ignoreInputView:(BOOL)ignoreInputView {
    BOOL outermost = gLGKeyboardSizingDepth++ == 0;

    CGSize size = %orig(orientation, ignoreInputView);

    gLGKeyboardSizingDepth--;

    if (outermost) {
        size = LGKeyboardReserveSize(size);
    }

    return size;
}

- (CGSize)intrinsicContentSize {
    BOOL outermost = gLGKeyboardSizingDepth++ == 0;

    CGSize size = %orig;

    gLGKeyboardSizingDepth--;

    if (outermost) {
        size = LGKeyboardReserveSize(size);
    }

    return size;
}

%end

%hook UIKBSplitImageView

- (void)setFrame:(CGRect)frame {
    if (LGKeyboardNeedsTopReserve() &&
        LGKeyboardIsDirectKeyplaneAtlas(self)) {
        CGFloat parentBoundsY = self.superview.bounds.origin.y;
        if (fabs(parentBoundsY) > 0.01 &&
            fabs(frame.origin.y - parentBoundsY) < 0.51) {
            frame.origin.y -= parentBoundsY;
        }
    }
    %orig(frame);
}

- (void)setCenter:(CGPoint)center {
    if (LGKeyboardNeedsTopReserve() &&
        LGKeyboardIsDirectKeyplaneAtlas(self)) {
        CGFloat parentBoundsY = self.superview.bounds.origin.y;
        CGFloat stockCenterY = CGRectGetHeight(self.bounds) * 0.5;
        CGFloat mirroredCenterY = stockCenterY + parentBoundsY;
        if (fabs(parentBoundsY) > 0.01 &&
            fabs(center.y - mirroredCenterY) < 0.51) {
            center.y -= parentBoundsY;
        }
    }
    %orig(center);
}

%end

%hook UIKeyboardLayoutStar

- (void)layoutSubviews {
    %orig;

    LGKeyboardRefreshCurrentKeyplane();
    LGKeyboardNormalizeKeyplaneAtlasFrames(LGKeyboardCurrentKeyplaneView());
    LGKeyboardScheduleKeyplaneRefresh();
}

%end

%hook UIKBTextStyle

- (NSString *)fontName {
    NSString *stockName = %orig;
    if (!lgHostEnabled(@"Keyboard") ||
        [stockName rangeOfString:@"Keycaps"
                         options:NSCaseInsensitiveSearch].location ==
            NSNotFound) {
        return stockName;
    }

    return LGKeyboardCompactFontName() ?: stockName;
}

%end

%ctor {
    gLGKeyboardBackdrops = [NSHashTable weakObjectsHashTable];
    gLGKeyboardVisualEffects = [NSHashTable weakObjectsHashTable];
    gLGKeyboardHookedKeyplaneClasses = [NSMutableSet set];
    LGLog(@"[keyboard] ctor process=%@ bundle=%@ backdrop=%d visualEffect=%d",
          NSProcessInfo.processInfo.processName,
          NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
          NSClassFromString(@"UIKBBackdropView") != Nil,
          NSClassFromString(@"UIKBVisualEffectView") != Nil);
    lgObservePreferenceReload(^{
        LGKeyboardRefreshReportedGeometry(UIScreen.mainScreen);
        for (UIView *stock in gLGKeyboardBackdrops.allObjects) {
            LGUpdateKeyboardGlass(stock);
        }
        for (UIView *effectView in gLGKeyboardVisualEffects.allObjects) {
            LGUpdateKeyboardVisualEffect(effectView);
        }
        LGKeyboardScheduleKeyplaneRefresh();
    });
}
