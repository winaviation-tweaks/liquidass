#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

typedef struct {
    NSUInteger calls;
    CFTimeInterval total;
    CFTimeInterval peak;
    CFTimeInterval started;
} LGNotificationProfile;

static LGNotificationProfile sLGNotificationProfile;

static void LGNotificationProfileSample(CFTimeInterval elapsed) {
    if (!LGDebugLoggingEnabled()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (sLGNotificationProfile.started == 0.0) sLGNotificationProfile.started = now;
    sLGNotificationProfile.calls++;
    sLGNotificationProfile.total += elapsed;
    sLGNotificationProfile.peak = MAX(sLGNotificationProfile.peak, elapsed);
    if (now - sLGNotificationProfile.started < 1.0) return;
    LGLog(@"[NOTIFPROF] materialUpdates=%lu avg=%.3fms total=%.3fms peak=%.3fms",
          (unsigned long)sLGNotificationProfile.calls,
          sLGNotificationProfile.total * 1000.0 / MAX((NSUInteger)1, sLGNotificationProfile.calls),
          sLGNotificationProfile.total * 1000.0,
          sLGNotificationProfile.peak * 1000.0);
    sLGNotificationProfile = (LGNotificationProfile){ .started = now };
}

static BOOL LGHasMaterialAncestorBefore(UIView *material, NSString *stopClassName) {
    Class stopCls = NSClassFromString(stopClassName);
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        if (stopCls && [v isKindOfClass:stopCls]) return NO;
        if (materialClass && [v isKindOfClass:materialClass]) return YES;
    }
    return NO;
}

static BOOL LGIsPlatterMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterView")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterView");
}

static UIView *LGPlatterActionButtonAncestor(UIView *material) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name isEqualToString:@"PLPlatterActionButton"] ||
            [name isEqualToString:@"NCNotificationListCellActionButton"])
            return v;
        if (materialClass && [v isKindOfClass:materialClass]) return nil;
    }
    return nil;
}

static BOOL LGIsPlatterActionMaterial(UIView *material) {
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return LGPlatterActionButtonAncestor(material) != nil;
}

static BOOL LGResponderChainContainsClass(UIResponder *responder, NSString *name) {
    Class cls = NSClassFromString(name);
    for (UIResponder *r = responder; r; r = r.nextResponder)
        if (cls && [r isKindOfClass:cls]) return YES;
    return NO;
}

static void *kLGPlatterClassificationKey = &kLGPlatterClassificationKey;

// K.B.: these hooks run for every MTMaterialView layout and every UILabel text change
// in SpringBoard, so the on/off state is cached and refreshed on preference reload
static NSInteger sLGPlatterHostsActive = -1;

static BOOL LGPlatterHostsActive(void) {
    if (sLGPlatterHostsActive < 0) {
        static dispatch_once_t observeOnce;
        dispatch_once(&observeOnce, ^{
            lgObservePreferenceReload(^{ sLGPlatterHostsActive = -1; });
        });
        sLGPlatterHostsActive = (lgHostEnabled(@"Notification") || lgHostEnabled(@"Banner")) ? 1 : 0;
    }
    return sLGPlatterHostsActive == 1;
}

// K.B.: classification only depends on where the view sits, so it is remembered until
// the view moves to a different window or superview
static void *kLGPlatterKindKey = &kLGPlatterKindKey;

typedef NS_ENUM(NSInteger, LGPlatterKind) {
    LGPlatterKindNone = 0,
    LGPlatterKindPlatter,
    LGPlatterKindAction,
};

@interface LGPlatterKindInfo : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic) LGPlatterKind kind;
@property (nonatomic) BOOL topBanner;
@end
@implementation LGPlatterKindInfo @end

static BOOL LGIsTopBannerPresentation(UIView *view) {
    if (!view.window) return NO;
    if ([NSStringFromClass(view.window.class) isEqualToString:@"SBBannerWindow"]) return YES;
    if (hasAncestorOfClassName(view, @"BNContentViewControllerView")) return YES;
    if (LGResponderChainContainsClass(view, @"BNContentViewController")) return YES;
    return LGResponderChainContainsClass(view, @"SBNotificationPresentableViewController");
}

static UIView *LGNotificationAncestor(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class);
        if ([name isEqualToString:@"NCNotificationShortLookView"] ||
            [name isEqualToString:@"NCNotificationLongLookView"] ||
            [name isEqualToString:@"PLPlatterView"]) return ancestor;
    }
    return nil;
}

static UIColor *LGForcedPlatterTextColor(UIView *view) {
    if (!view || !LGPlatterHostsActive()) return nil;
    if (LGIsTopBannerPresentation(view))
        return lgHostEnabled(@"Banner") &&
               view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight
            ? UIColor.blackColor : nil;
    if (!lgHostEnabled(@"Notification") || !LGNotificationAncestor(view)) return nil;
    return [LGGlassPreferenceValue(@"Notification.LabelColor") isEqual:@"black"]
        ? UIColor.blackColor : UIColor.whiteColor;
}

static NSAttributedString *LGAttributedTextWithColor(NSAttributedString *text, UIColor *color) {
    if (!color) return text;
    if (!text.length) return text;
    NSMutableAttributedString *copy = [text mutableCopy];
    [copy addAttribute:NSForegroundColorAttributeName
                 value:color
                 range:NSMakeRange(0, copy.length)];
    return copy;
}

static void LGDisableLockscreenStackDimming(id controller) {
    // stack dimming belongs to notifications and not top banners
    if (!controller || LGIsTopBannerPresentation([controller isKindOfClass:[UIViewController class]]
                                                   ? ((UIViewController *)controller).view : nil)) return;
    @try {
        id preview = [controller valueForKey:@"viewForPreview"];
        UIView *dimming = [preview valueForKey:@"stackDimmingOverlayView"];
        if (!dimming) {
            id contentSizeManager = [controller valueForKey:@"contentSizeManagingView"];
            dimming = [contentSizeManager valueForKey:@"stackDimmingView"];
        }
        if (dimming) dimming.hidden = lgHostEnabled(@"Notification");
    } @catch (__unused NSException *exception) {

    }
}

static CGFloat LGActionButtonRadius(UIView *material) {
    UIView *button = LGPlatterActionButtonAncestor(material) ?: material;
    if (button.layer.cornerRadius > 0.5) return button.layer.cornerRadius;
    if (material.layer.cornerRadius > 0.5) return material.layer.cornerRadius;
    return CGRectGetHeight(button.bounds) * 0.5;
}

static void LGUpdatePlatterGlass(UIView *material) {
    // one platter class serves banners notifications and action buttons

    if (!material.window) return;
    // K.B.: both hosts off means nothing to install, and prefs reload removes old glass
    if (!LGPlatterHostsActive()) return;
    CFTimeInterval start = CACurrentMediaTime();

    LGPlatterKindInfo *info = objc_getAssociatedObject(material, kLGPlatterKindKey);
    if (!info || info.window != material.window || info.superview != material.superview) {
        info = [LGPlatterKindInfo new];
        info.window = material.window;
        info.superview = material.superview;
        if (LGIsPlatterMaterial(material)) {
            info.kind = LGPlatterKindPlatter;
            info.topBanner = LGIsTopBannerPresentation(material);
        } else if (LGIsPlatterActionMaterial(material)) {
            info.kind = LGPlatterKindAction;
        } else {
            info.kind = LGPlatterKindNone;
        }
        objc_setAssociatedObject(material, kLGPlatterKindKey, info,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (info.kind == LGPlatterKindPlatter) {
        NSString *prefix = info.topBanner ? @"Banner" : @"Notification";
        NSString *previous = objc_getAssociatedObject(material, kLGPlatterClassificationKey);
        if (previous && ![previous isEqualToString:prefix]) {
            LGRemoveGlassFromMaterial(material, kGlassKey);
        }
        if (![previous isEqualToString:prefix]) {
            objc_setAssociatedObject(material, kLGPlatterClassificationKey, prefix,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        LGInstallRegisteredGlassInMaterial(material, kGlassKey, prefix,
                                           UIEdgeInsetsZero, -1.0, nil);
    } else if (info.kind == LGPlatterKindAction) {

        LGInstallRegisteredGlassInMaterial(material, kGlassKey, @"Notification",
                                           UIEdgeInsetsZero,
                                           LGActionButtonRadius(material), nil);
    }
    LGNotificationProfileSample(CACurrentMediaTime() - start);
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) LGUpdatePlatterGlass(self_);
}
- (void)layoutSubviews {
    %orig;
    LGUpdatePlatterGlass((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (forced) color = forced;
    %orig(color);
}
- (void)setAttributedText:(NSAttributedString *)text {
    text = LGAttributedTextWithColor(text, LGForcedPlatterTextColor((UIView *)self));
    %orig(text);
}
- (void)didMoveToWindow {
    %orig;
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
%end

%hook NCNotificationShortLookViewController
- (void)viewDidLoad {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
%end
