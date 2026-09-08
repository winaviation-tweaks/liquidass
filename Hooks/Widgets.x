#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static const CGFloat kWidgetCornerRadius = 20.2;
static void *kWidgetGlassKey = &kWidgetGlassKey;

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

static UIViewController *widgetNearestStackController(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder)
        if ([NSStringFromClass(r.class) isEqualToString:@"SBHWidgetStackViewController"] &&
            [r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
    return nil;
}

static BOOL widgetHasAncestorNamedWithinDepth(UIView *view, NSString *name, NSInteger maxDepth) {
    NSInteger depth = 0;
    for (UIView *a = view.superview; a && depth < maxDepth; a = a.superview, depth++)
        if ([NSStringFromClass(a.class) isEqualToString:name]) return YES;
    return NO;
}

static BOOL widgetSubtreeContainsClass(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return YES;
    for (UIView *sub in view.subviews)
        if (widgetSubtreeContainsClass(sub, name)) return YES;
    return NO;
}

static UIView *widgetFindDescendantNamed(UIView *view, NSString *name) {
    for (UIView *sub in view.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:name]) return sub;
        UIView *found = widgetFindDescendantNamed(sub, name);
        if (found) return found;
    }
    return nil;
}

static BOOL isWidgetGlassHostContainer(UIView *view) {

    if (!isExactClass(view, @"UIView")) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;
    if (!widgetNearestStackController(view)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBFTouchPassThroughView", 8)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBIconView", 10)) return NO;
    for (UIView *sub in view.subviews) {
        if (!isExactClass(sub, @"UIView") && !isExactClass(sub, @"BSUIScrollView")) continue;
        UIView *scroll = isExactClass(sub, @"BSUIScrollView") ? sub
                       : widgetFindDescendantNamed(sub, @"BSUIScrollView");
        if (scroll && widgetSubtreeContainsClass(scroll, @"SBHWidgetContainerView")) return YES;
    }
    return NO;
}

static UIView *widgetAncestorContainerHost(UIView *view) {
    NSInteger depth = 0;
    for (UIView *a = view; a && depth < 12; a = a.superview, depth++)
        if (isWidgetGlassHostContainer(a)) return a;
    return nil;
}

static BOOL isWidgetStackBackgroundMaterial(UIView *mat) {

    if (!isExactClass(mat, @"MTMaterialView")) return NO;
    UIView *parent = mat.superview;
    if (!isExactClass(parent, @"UIView")) return NO;
    UIViewController *vc = widgetNearestStackController(parent);
    if (!vc) return NO;
    return vc.view == parent || parent.superview == vc.view;
}

static void removeWidgetGlass(UIView *container) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    if (!glass) return;
    [glass removeFromSuperview];
    objc_setAssociatedObject(container, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void injectWidgetGlass(UIView *container) {
    if (!lgHostEnabled(@"Widgets")) { removeWidgetGlass(container); return; }
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"Widgets");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(container, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    else if (container.subviews.firstObject != glass) [container sendSubviewToBack:glass];
    glass.frame = container.bounds;
    glass.layer.cornerRadius  = kWidgetCornerRadius;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    container.layer.cornerRadius  = kWidgetCornerRadius;
    container.layer.cornerCurve   = kCACornerCurveContinuous;
    container.layer.masksToBounds = YES;
    container.clipsToBounds       = YES;
    lgTrackGlass(glass, @"Widgets", nil);
}

%group LGWidgetsHooks

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window && lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)setHidden:(BOOL)hidden {
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_)) {
        hidden = YES;
        lgSuppressStock(self_, @"Widgets", NO);
    }
    %orig(hidden);
}
%end

%hook CHUISAvocadoHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (id)screenshotManager {
    if (self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook CHUISWidgetHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContent {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContentIfNecessary {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (id)_snapshotImageFromURL:(id)arg1 {
    if (self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook BSUIScrollView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    UIView *host = widgetAncestorContainerHost(self_);
    if (!host) return;
    if (!self_.window) { removeWidgetGlass(host); return; }
    injectWidgetGlass(host);
}
- (void)layoutSubviews {
    %orig;
    UIView *host = widgetAncestorContainerHost((UIView *)self);
    if (host) injectWidgetGlass(host);
}
%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGWidgetsHooks);
}
