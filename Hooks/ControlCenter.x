#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

#pragma mark - taxonomy

static CGFloat sCCSmallModuleRadius = 0.0;

static UIView *ccModuleAncestor(UIView *v) {
    for (UIView *a = v.superview; a; a = a.superview)
        if (isExactClass(a, @"CCUIContentModuleContainerView")) return a;
    return nil;
}

static BOOL ccIsModuleCandidate(UIView *module) {
    CGSize s = module.bounds.size;
    CGFloat mn = fmin(s.width, s.height), mx = fmax(s.width, s.height);
    if (mn < 20.0) return NO;
    return mx <= mn * 1.25;
}

static CGFloat ccModuleCornerRadius(UIView *module) {
    CGFloat h = CGRectGetHeight(module.bounds);
    if (h <= 0.0) return 0.0;
    CGFloat r = h * 0.5;
    if (h < 100.0) { sCCSmallModuleRadius = r; return r; }
    return sCCSmallModuleRadius > 0.0 ? sCCSmallModuleRadius : r;
}

static BOOL ccIsSliderView(UIView *view) {
    Class cc = NSClassFromString(@"CCUIContinuousSliderView");
    Class mru = NSClassFromString(@"MRUContinuousSliderView");
    return view && ((cc && [view isKindOfClass:cc]) || (mru && [view isKindOfClass:mru]));
}

static UIView *ccSliderAncestor(UIView *view);

static BOOL ccIsInsideSlider(UIView *mat) {
    return hasAncestorOfClassName(mat, @"CCUIContinuousSliderView") ||
           hasAncestorOfClassName(mat, @"MRUContinuousSliderView");
}

static BOOL ccHasSBElasticHierarchy(UIView *view) {
    // volume hud reuses cc views so leave its elastic hierarchy alone
    UIView *candidate = view;
    for (NSInteger level = 0; candidate && level < 3; level++, candidate = candidate.superview) {
        NSString *className = NSStringFromClass(candidate.class);
        if ([className hasPrefix:@"SBElastic"]) return YES;
    }
    return NO;
}

static CGFloat ccPillRadius(UIView *v) {
    return fmin(CGRectGetWidth(v.bounds), CGRectGetHeight(v.bounds)) * 0.5;
}

static UIView *ccSliderAncestor(UIView *view) {
    for (UIView *v = view; v; v = v.superview)
        if (ccIsSliderView(v)) return v;
    return nil;
}

static BOOL ccIsSliderFillMaterial(UIView *mat) {
    UIView *slider = ccSliderAncestor(mat);
    if (!slider) return NO;
    for (UIView *v = mat.superview; v && v != slider; v = v.superview)
        if (isExactClass(v, @"UIView") && v.layer.masksToBounds) return YES;
    return NO;
}

static CGFloat ccGlassRadiusForMaterial(UIView *mat) {
    if (ccHasSBElasticHierarchy(mat)) return -1.0;
    if (!isExactClass(mat, @"MTMaterialView")) return -1.0;
    BOOL inModule = hasAncestorOfClassName(mat, @"CCUIContentModuleContainerView");

    if (ccIsInsideSlider(mat)) {
        if (!inModule && !LGMaterialHasGlass(mat, kGlassKey)) return -1.0;
        if (ccIsSliderFillMaterial(mat)) return -1.0;
        UIView *slider = ccSliderAncestor(mat);
        if (!slider) return -1.0;
        if (CGRectGetWidth(slider.bounds) < 30.0 ||
            CGRectGetHeight(slider.bounds) < 30.0) return -1.0;
        return ccPillRadius(slider);
    }

    if (!inModule) {
        UIView *parent = mat.superview;
        BOOL expanded = (isExactClass(parent, @"CCUIContentModuleContentContainer") ||
                         isExactClass(parent, @"CCUIContentModuleContentContainerView")) &&
                        LGMaterialHasGlass(mat, kGlassKey);
        return expanded ? mat.layer.cornerRadius : -1.0;
    }

    CGFloat w = CGRectGetWidth(mat.bounds), h = CGRectGetHeight(mat.bounds);
    if (w < 30.0 || h < 30.0) return -1.0;

    UIView *module = ccModuleAncestor(mat);
    if (module && ccIsModuleCandidate(module)) return ccModuleCornerRadius(module);
    if (w > 100.0 && h < 100.0) return h * 0.5;
    if (h > 100.0 && w < 100.0) return w * 0.5;
    return ccPillRadius(mat);
}

#pragma mark - fullscreen backdrop styling

static void *kCCFullscreenBlurCapKey = &kCCFullscreenBlurCapKey;
static void *kCCFullscreenDimViewKey = &kCCFullscreenDimViewKey;
static void *kCCFullscreenMaterialKey = &kCCFullscreenMaterialKey;
static void *kCCFullscreenOverlayRootKey = &kCCFullscreenOverlayRootKey;
static NSHashTable<UIView *> *sCCOverlayRoots;

static CFTimeInterval sCCFullscreenDimSyncDeadline = 0.0;
static CFTimeInterval sCCFullscreenDimSyncHardDeadline = 0.0;

static NSHashTable<UIView *> *ccOverlayRoots(void) {
    if (!sCCOverlayRoots) sCCOverlayRoots = [NSHashTable weakObjectsHashTable];
    return sCCOverlayRoots;
}

static CGFloat ccFullscreenBlurRadius(void) {
    return fmax(0.0, LG_prefFloat(@"ControlCenter.FullscreenBackdropBlurRadius", 8.0));
}

static UIColor *ccColorFromRGBAHex(NSString *hex, NSString *fallback) {
    NSString *source = [hex isKindOfClass:NSString.class] && hex.length ? hex : fallback;
    NSString *value = [[[source ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (value.length != 6 && value.length != 8) {
        NSString *fallbackSource = fallback.length ? fallback : @"#00000033";
        value = [[[fallbackSource stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString] copy];
    }
    if (value.length != 6 && value.length != 8) return [UIColor colorWithWhite:0.0 alpha:0.20];

    unsigned parsed = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexInt:&parsed]) return [UIColor colorWithWhite:0.0 alpha:0.20];

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 1.0;
    if (value.length == 6) {
        red = ((parsed >> 16) & 0xff) / 255.0;
        green = ((parsed >> 8) & 0xff) / 255.0;
        blue = (parsed & 0xff) / 255.0;
    } else {
        red = ((parsed >> 24) & 0xff) / 255.0;
        green = ((parsed >> 16) & 0xff) / 255.0;
        blue = ((parsed >> 8) & 0xff) / 255.0;
        alpha = (parsed & 0xff) / 255.0;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

static UIColor *ccFullscreenDimColor(void) {
    NSString *fallback = @"#00000033";
    return ccColorFromRGBAHex(LG_prefString(@"ControlCenter.FullscreenBackdropDimColor", fallback), fallback);
}

static CGFloat ccFullscreenDimTargetAlpha(void) {
    return CGColorGetAlpha(ccFullscreenDimColor().CGColor);
}

static UIColor *ccFullscreenDimBaseColor(void) {
    UIColor *color = ccFullscreenDimColor();
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
    }
    return [color colorWithAlphaComponent:1.0];
}

static BOOL ccIsBlurRadiusKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    return [key isEqualToString:@"inputRadius"] ||
           [key isEqualToString:@"radius"] ||
           [key isEqualToString:@"inputBlurRadius"] ||
           [key isEqualToString:@"blurRadius"];
}

static id ccClampedBlurRadiusValue(id value, CGFloat radius) {
    if (![value respondsToSelector:@selector(doubleValue)]) return value;
    return [value doubleValue] > radius ? @(radius) : value;
}

static void ccSetBlurCapMarker(id object, BOOL enabled) {
    if (!object) return;
    objc_setAssociatedObject(object,
                             kCCFullscreenBlurCapKey,
                             enabled ? @YES : nil,
                             enabled ? OBJC_ASSOCIATION_RETAIN_NONATOMIC
                                     : OBJC_ASSOCIATION_ASSIGN);
}

static BOOL ccObjectHasBlurCap(id object) {
    return object && [objc_getAssociatedObject(object, kCCFullscreenBlurCapKey) boolValue];
}

static void ccClampBlurFilter(id filter, CGFloat radius) {
    // blur radius keys changed names across ios releases
    if (!filter) return;
    ccSetBlurCapMarker(filter, YES);
    for (NSString *key in @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"]) {
        @try {
            id value = [filter valueForKey:key];
            id clamped = ccClampedBlurRadiusValue(value, radius);
            if (clamped != value) [filter setValue:clamped forKey:key];
        } @catch (__unused NSException *exception) {
        }
    }
}

static void ccSetBlurCapOnFilters(id filters, BOOL enabled, CGFloat radius) {
    if (![filters isKindOfClass:NSArray.class]) return;
    for (id filter in (NSArray *)filters) {
        if (enabled) ccClampBlurFilter(filter, radius);
        else ccSetBlurCapMarker(filter, NO);
    }
}

static void ccAssociateOverlayRootWithFilters(id filters, UIView *overlayRoot) {
    if (![filters isKindOfClass:NSArray.class]) return;
    for (id filter in (NSArray *)filters) {
        objc_setAssociatedObject(filter,
                                 kCCFullscreenOverlayRootKey,
                                 overlayRoot,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

static void ccSetBlurCapOnLayerTree(CALayer *layer, BOOL enabled, CGFloat radius) {
    if (!layer) return;
    ccSetBlurCapMarker(layer, enabled);
    ccSetBlurCapOnFilters(layer.filters, enabled, radius);
    @try {
        ccSetBlurCapOnFilters([layer valueForKey:@"backgroundFilters"], enabled, radius);
    } @catch (__unused NSException *exception) {
    }
    for (CALayer *sublayer in layer.sublayers) {
        ccSetBlurCapOnLayerTree(sublayer, enabled, radius);
    }
}

static void ccClampBlurAnimation(CAAnimation *animation, CGFloat radius) {
    // stock transitions can restore blur after the model value is clamped
    if (!animation) return;

    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in ((CAAnimationGroup *)animation).animations) {
            ccClampBlurAnimation(child, radius);
        }
        return;
    }

    NSString *keyPath = nil;
    @try { keyPath = [animation valueForKey:@"keyPath"]; }
    @catch (__unused NSException *exception) {}
    if (![keyPath isKindOfClass:NSString.class]) return;

    NSString *lower = keyPath.lowercaseString;
    if (![lower containsString:@"radius"] && ![lower containsString:@"blur"]) return;

    if ([animation isKindOfClass:CABasicAnimation.class]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        basic.fromValue = ccClampedBlurRadiusValue(basic.fromValue, radius);
        basic.toValue = ccClampedBlurRadiusValue(basic.toValue, radius);
        basic.byValue = ccClampedBlurRadiusValue(basic.byValue, radius);
    } else if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        if (!keyframe.values.count) return;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:keyframe.values.count];
        for (id value in keyframe.values) {
            [values addObject:ccClampedBlurRadiusValue(value, radius) ?: value];
        }
        keyframe.values = values;
    }
}

static BOOL ccIsFullscreenBackdropMaterial(UIView *material, UIView *overlayRoot) {
    if (!material || !overlayRoot) return NO;
    if (!isExactClass(material, @"MTMaterialView")) return NO;
    if (material.superview != overlayRoot) return NO;

    CGRect bounds = material.bounds;
    if (CGRectGetWidth(bounds) < 100.0 || CGRectGetHeight(bounds) < 100.0) return NO;

    return CGRectContainsRect(CGRectInset(overlayRoot.bounds, -2.0, -2.0), material.frame);
}

static CGFloat ccBlurRadiusFromFilters(id filters) {
    if (![filters isKindOfClass:NSArray.class]) return -1.0;

    CGFloat found = -1.0;
    for (id filter in (NSArray *)filters) {
        for (NSString *key in @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"]) {
            @try {
                id value = [filter valueForKey:key];
                if ([value respondsToSelector:@selector(doubleValue)]) {
                    found = fmax(found, (CGFloat)[value doubleValue]);
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }
    return found;
}

static CGFloat ccPresentedBlurRadiusInLayerTree(CALayer *layer) {
    if (!layer) return -1.0;

    CALayer *sampleLayer = layer.presentationLayer ?: layer;
    CGFloat found = ccBlurRadiusFromFilters(sampleLayer.filters);
    @try {
        found = fmax(found, ccBlurRadiusFromFilters([sampleLayer valueForKey:@"backgroundFilters"]));
    } @catch (__unused NSException *exception) {
    }

    for (CALayer *sublayer in layer.sublayers) {
        found = fmax(found, ccPresentedBlurRadiusInLayerTree(sublayer));
    }
    return found;
}

static CGFloat ccModelBlurRadiusInLayerTree(CALayer *layer) {
    if (!layer) return -1.0;

    CGFloat found = ccBlurRadiusFromFilters(layer.filters);
    @try {
        found = fmax(found, ccBlurRadiusFromFilters([layer valueForKey:@"backgroundFilters"]));
    } @catch (__unused NSException *exception) {
    }
    for (CALayer *sublayer in layer.sublayers) {
        found = fmax(found, ccModelBlurRadiusInLayerTree(sublayer));
    }
    return found;
}

static UIView *ccFullscreenDimView(UIView *backdropMaterial, BOOL create) {
    if (!backdropMaterial) return nil;

    UIView *dimView = objc_getAssociatedObject(backdropMaterial, kCCFullscreenDimViewKey);
    if (!dimView && create) {
        dimView = [[UIView alloc] initWithFrame:backdropMaterial.bounds];
        dimView.userInteractionEnabled = NO;
        dimView.accessibilityElementsHidden = YES;
        dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimView.backgroundColor = UIColor.clearColor;
        dimView.alpha = 0.0;
        dimView.opaque = NO;
        objc_setAssociatedObject(backdropMaterial,
                                 kCCFullscreenDimViewKey,
                                 dimView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return dimView;
}

#pragma mark - fullscreen backdrop diagnostics

static void ccApplyFullscreenBackdropStyle(UIView *overlayRoot) {
    if (!overlayRoot) return;
    [ccOverlayRoots() addObject:overlayRoot];

    BOOL enabled = lgHostEnabled(@"ControlCenter");
    CGFloat radius = ccFullscreenBlurRadius();
    UIView *previousBackdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    UIView *backdropMaterial = nil;

    for (UIView *subview in [overlayRoot.subviews copy]) {
        if (!ccIsFullscreenBackdropMaterial(subview, overlayRoot)) continue;
        if (!backdropMaterial) backdropMaterial = subview;
        ccSetBlurCapOnLayerTree(subview.layer, enabled, radius);
    }

    if (!backdropMaterial) {
        if (previousBackdropMaterial) {
            LGLog(@"[CCFSDBG][target] lost fullscreen material root=%@:%p previous=%@:%p",
                  NSStringFromClass(overlayRoot.class), overlayRoot,
                  NSStringFromClass(previousBackdropMaterial.class), previousBackdropMaterial);
        }
        objc_setAssociatedObject(overlayRoot,
                                 kCCFullscreenMaterialKey,
                                 nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    if (previousBackdropMaterial != backdropMaterial) {
        LGLog(@"[CCFSDBG][target] fullscreen material root=%@:%p material=%@:%p frame=%@ bounds=%@",
              NSStringFromClass(overlayRoot.class), overlayRoot,
              NSStringFromClass(backdropMaterial.class), backdropMaterial,
              NSStringFromCGRect(backdropMaterial.frame), NSStringFromCGRect(backdropMaterial.bounds));
    }

    objc_setAssociatedObject(overlayRoot,
                             kCCFullscreenMaterialKey,
                             backdropMaterial,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(backdropMaterial.layer,
                             kCCFullscreenOverlayRootKey,
                             overlayRoot,
                             OBJC_ASSOCIATION_ASSIGN);
    ccAssociateOverlayRootWithFilters(backdropMaterial.layer.filters, overlayRoot);
    @try {
        ccAssociateOverlayRootWithFilters([backdropMaterial.layer valueForKey:@"backgroundFilters"],
                                          overlayRoot);
    } @catch (__unused NSException *exception) {
    }

    CGFloat targetAlpha = ccFullscreenDimTargetAlpha();
    UIView *dimView = ccFullscreenDimView(backdropMaterial,
                                           enabled && targetAlpha > 0.001);
    if (!dimView) return;

    if (!enabled || targetAlpha <= 0.001) {
        dimView.hidden = YES;
        dimView.backgroundColor = UIColor.clearColor;
        return;
    }

    if (dimView.superview != backdropMaterial) {
        [dimView removeFromSuperview];
        [backdropMaterial addSubview:dimView];
    } else {
        [backdropMaterial bringSubviewToFront:dimView];
    }

    dimView.frame = backdropMaterial.bounds;
    dimView.backgroundColor = ccFullscreenDimBaseColor();
    dimView.hidden = NO;
}

static void ccSyncFullscreenDimForRoot(UIView *overlayRoot) {
    if (!overlayRoot) return;

    UIView *backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    if (!backdropMaterial || backdropMaterial.superview != overlayRoot) {
        ccApplyFullscreenBackdropStyle(overlayRoot);
        backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    }
    if (!backdropMaterial) return;

    UIView *dimView = ccFullscreenDimView(backdropMaterial, NO);
    if (!dimView) return;

    CGFloat targetAlpha = lgHostEnabled(@"ControlCenter")
        ? ccFullscreenDimTargetAlpha()
        : 0.0;
    if (targetAlpha <= 0.001) {
        dimView.alpha = 0.0;
        dimView.hidden = YES;
        return;
    }

    dimView.hidden = NO;

    CGFloat cap = ccFullscreenBlurRadius();
    CGFloat presentedRadius = ccPresentedBlurRadiusInLayerTree(backdropMaterial.layer);
    CGFloat progress = 1.0;
    if (cap > 0.001 && presentedRadius >= 0.0) {
        progress = fmin(1.0, fmax(0.0, presentedRadius / cap));
    }

    dimView.alpha = targetAlpha * progress;
}

static void ccSetFullscreenDimAlpha(UIView *overlayRoot, CGFloat alpha) {
    if (!overlayRoot) return;
    UIView *backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    UIView *dimView = ccFullscreenDimView(backdropMaterial, NO);
    if (!dimView) return;
    dimView.alpha = fmin(1.0, fmax(0.0, alpha));
}

@interface LGCCFullscreenDimSyncDriver : NSObject
@property (nonatomic, weak) UIView *overlayRoot;
@end

static LGCCFullscreenDimSyncDriver *sCCFullscreenDimSyncDriver;
static CADisplayLink *sCCFullscreenDimDisplayLink;

static void ccStopFullscreenDimSync(UIView *overlayRoot);

@implementation LGCCFullscreenDimSyncDriver
- (void)tick:(CADisplayLink *)displayLink {
    (void)displayLink;
    UIView *root = self.overlayRoot;
    if (!root) {
        if (sCCFullscreenDimDisplayLink) sCCFullscreenDimDisplayLink.paused = YES;
        return;
    }

    ccSyncFullscreenDimForRoot(root);

    UIView *material = objc_getAssociatedObject(root, kCCFullscreenMaterialKey);
    CGFloat modelRadius = material ? ccModelBlurRadiusInLayerTree(material.layer) : -1.0;
    CGFloat presentedRadius = material ? ccPresentedBlurRadiusInLayerTree(material.layer) : -1.0;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL settled = (modelRadius >= 0.0 && presentedRadius >= 0.0 &&
                    fabs(modelRadius - presentedRadius) <= 0.025);

    if ((now >= sCCFullscreenDimSyncDeadline && settled) ||
        now >= sCCFullscreenDimSyncHardDeadline) {

        ccSyncFullscreenDimForRoot(root);
        ccStopFullscreenDimSync(root);
    }
}
@end

static void ccStartFullscreenDimSync(UIView *overlayRoot) {
    if (!overlayRoot) return;

    if (!sCCFullscreenDimSyncDriver) {
        sCCFullscreenDimSyncDriver = [LGCCFullscreenDimSyncDriver new];
    }
    sCCFullscreenDimSyncDriver.overlayRoot = overlayRoot;

    if (!sCCFullscreenDimDisplayLink) {
        sCCFullscreenDimDisplayLink = [CADisplayLink displayLinkWithTarget:sCCFullscreenDimSyncDriver
                                                                   selector:@selector(tick:)];
        [sCCFullscreenDimDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                                           forMode:NSRunLoopCommonModes];
    }
    sCCFullscreenDimDisplayLink.paused = NO;
}

static void ccKickFullscreenDimSync(UIView *overlayRoot) {
    if (!overlayRoot) return;
    CFTimeInterval now = CACurrentMediaTime();

    sCCFullscreenDimSyncDeadline = now + 0.18;
    sCCFullscreenDimSyncHardDeadline = now + 1.25;
    ccStartFullscreenDimSync(overlayRoot);
}

static void ccStopFullscreenDimSync(UIView *overlayRoot) {
    (void)overlayRoot;
    if (sCCFullscreenDimDisplayLink) sCCFullscreenDimDisplayLink.paused = YES;
}

static void ccScheduleFullscreenBackdropStyle(UIView *overlayRoot) {
    if (!overlayRoot) return;
    ccApplyFullscreenBackdropStyle(overlayRoot);
    __weak UIView *weakRoot = overlayRoot;
    dispatch_async(dispatch_get_main_queue(), ^{ ccApplyFullscreenBackdropStyle(weakRoot); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ccApplyFullscreenBackdropStyle(weakRoot); });
}

#pragma mark - round-only fills

static void *kCCRoundOriginalRadiusKey = &kCCRoundOriginalRadiusKey;
static void *kCCRoundOriginalCurveKey = &kCCRoundOriginalCurveKey;
static void *kCCRoundOriginalMasksKey = &kCCRoundOriginalMasksKey;
static NSHashTable<UIView *> *sCCRoundedViews;

static NSHashTable<UIView *> *ccRoundedViews(void) {
    if (!sCCRoundedViews) sCCRoundedViews = [NSHashTable weakObjectsHashTable];
    return sCCRoundedViews;
}

static void ccRememberOriginalRoundState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kCCRoundOriginalRadiusKey)) return;

    [ccRoundedViews() addObject:view];
    objc_setAssociatedObject(view, kCCRoundOriginalRadiusKey,
                             @(view.layer.cornerRadius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kCCRoundOriginalCurveKey,
                             view.layer.cornerCurve ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kCCRoundOriginalMasksKey,
                             @(view.layer.masksToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ccRestoreRoundState(UIView *view) {
    if (!view) return;

    NSNumber *radius = objc_getAssociatedObject(view, kCCRoundOriginalRadiusKey);
    id curve = objc_getAssociatedObject(view, kCCRoundOriginalCurveKey);
    NSNumber *masks = objc_getAssociatedObject(view, kCCRoundOriginalMasksKey);
    if (!radius || !curve || !masks) return;

    view.layer.cornerRadius = radius.doubleValue;
    view.layer.cornerCurve = curve == [NSNull null] ? nil : curve;
    view.layer.masksToBounds = masks.boolValue;

    objc_setAssociatedObject(view, kCCRoundOriginalRadiusKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kCCRoundOriginalCurveKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kCCRoundOriginalMasksKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [sCCRoundedViews removeObject:view];
}

static void ccRestoreAllRoundedViews(void) {
    for (UIView *view in ccRoundedViews().allObjects)
        ccRestoreRoundState(view);
}

static void lgRound(UIView *v, CGFloat r) {
    if (!v) return;
    if (!lgHostEnabled(@"ControlCenter") || ccHasSBElasticHierarchy(v)) {
        ccRestoreRoundState(v);
        return;
    }
    if (CGRectGetWidth(v.bounds) < 2.0 || CGRectGetHeight(v.bounds) < 2.0) {
        ccRestoreRoundState(v);
        return;
    }

    ccRememberOriginalRoundState(v);
    if (fabs(v.layer.cornerRadius - r) > 0.5) v.layer.cornerRadius = r;
    v.layer.cornerCurve   = kCACornerCurveContinuous;
    v.layer.masksToBounds = YES;
}

static void ccApplyOrRestoreRound(UIView *view, CGFloat radius, BOOL eligible) {
    if (!eligible || !lgHostEnabled(@"ControlCenter") || ccHasSBElasticHierarchy(view)) {
        ccRestoreRoundState(view);
        return;
    }
    lgRound(view, radius);
}

static void *kCCSliderDumpKey = &kCCSliderDumpKey;

static void ccAppendSliderTree(NSMutableString *out, UIView *view, NSUInteger depth) {
    NSString *pad = [@"" stringByPaddingToLength:depth * 2
                                      withString:@" " startingAtIndex:0];
    CALayer *layer = view.layer;
    [out appendFormat:@"\n%@%@ frame=%@ radius=%.2f masks=%d hidden=%d alpha=%.2f"
                      @" bg=%@ filters=%lu",
        pad, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
        layer.cornerRadius, layer.masksToBounds, view.hidden, view.alpha,
        layer.backgroundColor ? @"set" : @"nil",
        (unsigned long)([layer.filters count] + [layer.backgroundFilters count])];
    if (isExactClass(view, @"MTMaterialView")) {
        [out appendFormat:@" <MATERIAL exactUIViewParent=%d pill=%.2f glass=%d>",
            isExactClass(view.superview, @"UIView"), ccPillRadius(view),
            objc_getAssociatedObject(view, kGlassKey) != nil];
    }
    for (UIView *sub in view.subviews)
        ccAppendSliderTree(out, sub, depth + 1);
}

static void ccDumpSliderHierarchy(UIView *slider, NSString *reason) {
    if (!LGDebugLoggingEnabled() || !slider.window) return;

    NSMutableString *signature = [NSMutableString string];
    [signature appendFormat:@"%.0fx%.0f|", CGRectGetWidth(slider.bounds),
                                           CGRectGetHeight(slider.bounds)];
    for (UIView *child in slider.subviews) {
        [signature appendFormat:@"%@(%lu)", NSStringFromClass(child.class),
                                (unsigned long)child.subviews.count];
    }
    NSString *previous = objc_getAssociatedObject(slider, kCCSliderDumpKey);
    if ([previous isEqualToString:signature]) return;
    objc_setAssociatedObject(slider, kCCSliderDumpKey, signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSMutableString *out = [NSMutableString stringWithFormat:
        @"[CCSLIDER] reason=%@ ios=%@ class=%@ elastic=%d",
        reason, UIDevice.currentDevice.systemVersion,
        NSStringFromClass(slider.class), ccHasSBElasticHierarchy(slider)];
    ccAppendSliderTree(out, slider, 1);

    UIView *parent = slider.superview;
    if (parent) {
        [out appendFormat:@"\n  --- parent %@ %@ ---",
            NSStringFromClass(parent.class), NSStringFromCGRect(parent.frame)];
        for (UIView *sibling in parent.subviews) {
            if (sibling == slider) { [out appendString:@"\n    (this slider)"]; continue; }
            [out appendFormat:@"\n    %@ frame=%@ radius=%.2f hidden=%d",
                NSStringFromClass(sibling.class), NSStringFromCGRect(sibling.frame),
                sibling.layer.cornerRadius, sibling.hidden];
            for (UIView *sub in sibling.subviews)
                [out appendFormat:@"\n      %@ frame=%@ radius=%.2f",
                    NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
                    sub.layer.cornerRadius];
        }
    }
    LGLog(@"%@", out);
}

static void ccRoundMaterialsInSubtree(UIView *view, CGFloat radius,
                                      BOOL eligible, NSUInteger depth) {
    if (depth > 6) return;
    for (UIView *sub in view.subviews) {
        if (isExactClass(sub, @"MTMaterialView")) {
            ccApplyOrRestoreRound(sub, radius, eligible);
            CGFloat glassRadius = ccGlassRadiusForMaterial(sub);
            if (glassRadius >= 0.0 && LGMaterialHasGlass(sub, kGlassKey))
                LGInstallRegisteredGlassInMaterial(sub, kGlassKey, @"ControlCenter",
                                                   UIEdgeInsetsZero, glassRadius, nil);
        } else {
            ccRoundMaterialsInSubtree(sub, radius, eligible, depth + 1);
        }
    }
}

static void roundSliderMaterials(UIView *slider) {
    BOOL eligible = !ccHasSBElasticHierarchy(slider);

    CGFloat radius = ccPillRadius(slider);
    if (radius <= 0.0) return;
    ccRoundMaterialsInSubtree(slider, radius, eligible, 0);

    UIView *parent = slider.superview;
    if (isExactClass(parent, @"CCUIContentModuleContentContainerView")) {
        for (UIView *sibling in parent.subviews) {
            if (sibling == slider || !isExactClass(sibling, @"MTMaterialView")) continue;
            ccApplyOrRestoreRound(sibling, radius, eligible);
        }
    }
}

static void roundToggleFills(UIView *buttonModule) {
    UIView *module = ccModuleAncestor(buttonModule);
    BOOL eligible = module && ccIsModuleCandidate(module) &&
                    !ccHasSBElasticHierarchy(buttonModule) &&
                    !ccHasSBElasticHierarchy(module);
    CGFloat r = eligible ? ccModuleCornerRadius(module) : 0.0;
    for (UIView *child in buttonModule.subviews)
        if (isExactClass(child, @"UIView")) ccApplyOrRestoreRound(child, r, eligible);
}

static void roundModuleContainer(UIView *module) {
    if (!isExactClass(module, @"CCUIContentModuleContainerView")) return;
    BOOL eligible = ccIsModuleCandidate(module) && !ccHasSBElasticHierarchy(module);
    CGFloat r = eligible ? ccModuleCornerRadius(module) : 0.0;
    ccApplyOrRestoreRound(module, r, eligible);
    for (UIView *sub in module.subviews)
        if (isExactClass(sub, @"CCUIContentModuleContentContainer") ||
            isExactClass(sub, @"CCUIContentModuleContentContainerView"))
            ccApplyOrRestoreRound(sub, r, eligible);
}

static void ccRefreshContentContainerGlass(UIView *container) {
    for (UIView *material in container.subviews) {
        if (!isExactClass(material, @"MTMaterialView") ||
            !LGMaterialHasGlass(material, kGlassKey)) continue;
        CGFloat radius = ccGlassRadiusForMaterial(material);
        if (radius >= 0.0)
            LGInstallRegisteredGlassInMaterial(material, kGlassKey, @"ControlCenter",
                                               UIEdgeInsetsZero, radius, nil);
    }
}

#pragma mark - hooks

%hook CCUIContentModuleContainerView
- (void)layoutSubviews { %orig; roundModuleContainer((UIView *)self); }
- (void)didMoveToWindow { %orig; roundModuleContainer((UIView *)self); }
%end

%hook CCUIContentModuleContentContainerView
- (void)layoutSubviews { %orig; ccRefreshContentContainerGlass((UIView *)self); }
%end

%hook CCUIContentModuleContentContainer
- (void)layoutSubviews { %orig; ccRefreshContentContainerGlass((UIView *)self); }
%end

%hook CCUIButtonModuleView
- (void)layoutSubviews { %orig; roundToggleFills((UIView *)self); }
- (void)didMoveToWindow { %orig; roundToggleFills((UIView *)self); }
%end

%hook CCUIContinuousSliderView
- (void)layoutSubviews {
    %orig;
    roundSliderMaterials((UIView *)self);
    ccDumpSliderHierarchy((UIView *)self, @"layout");
}
- (void)didMoveToWindow {
    %orig;
    roundSliderMaterials((UIView *)self);
    ccDumpSliderHierarchy((UIView *)self, @"window");
}
%end

%hook MRUContinuousSliderView
- (void)layoutSubviews {
    %orig;
    roundSliderMaterials((UIView *)self);
    ccDumpSliderHierarchy((UIView *)self, @"layout");
}
- (void)didMoveToWindow {
    %orig;
    roundSliderMaterials((UIView *)self);
    ccDumpSliderHierarchy((UIView *)self, @"window");
}
%end

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccScheduleFullscreenBackdropStyle(root);

    ccSetFullscreenDimAlpha(root, 0.0);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

%end

%hook CAFilter

- (void)setValue:(id)value forKey:(NSString *)key {
    UIView *overlayRoot = nil;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && ccIsBlurRadiusKey(key)) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
    }
    %orig(value, key);
    if (overlayRoot) ccKickFullscreenDimSync(overlayRoot);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    UIView *overlayRoot = nil;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [keyPath isKindOfClass:NSString.class]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (ccIsBlurRadiusKey(lastKey)) {
            overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
            value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
        }
    }
    %orig(value, keyPath);
    if (overlayRoot) ccKickFullscreenDimSync(overlayRoot);
}

%end

%hook CALayer

- (void)setFilters:(NSArray *)filters {
    UIView *overlayRoot = nil;
    CGFloat incomingBlurRadius = -1.0;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter")) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        incomingBlurRadius = ccBlurRadiusFromFilters(filters);
        ccAssociateOverlayRootWithFilters(filters, overlayRoot);
        ccSetBlurCapOnFilters(filters, YES, ccFullscreenBlurRadius());
    }
    %orig(filters);

    if (overlayRoot && incomingBlurRadius >= 0.0) {
        ccKickFullscreenDimSync(overlayRoot);
    }
}

- (void)setValue:(id)value forKey:(NSString *)key {
    UIView *overlayRoot = nil;
    CGFloat incomingBlurRadius = -1.0;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [key isEqualToString:@"backgroundFilters"]) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        incomingBlurRadius = ccBlurRadiusFromFilters(value);
        ccAssociateOverlayRootWithFilters(value, overlayRoot);
        ccSetBlurCapOnFilters(value, YES, ccFullscreenBlurRadius());
    }
    %orig(value, key);
    if (overlayRoot && incomingBlurRadius >= 0.0) {
        ccKickFullscreenDimSync(overlayRoot);
    }
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [keyPath isKindOfClass:NSString.class]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (ccIsBlurRadiusKey(lastKey)) {
            value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
        }
    }
    %orig(value, keyPath);
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter")) {
        ccClampBlurAnimation(animation, ccFullscreenBlurRadius());
    }
    %orig(animation, key);
}

%end

%ctor {
    lgObservePreferenceReload(^{
        if (!lgHostEnabled(@"ControlCenter")) ccRestoreAllRoundedViews();
        for (UIView *root in ccOverlayRoots().allObjects) {
            ccApplyFullscreenBackdropStyle(root);
            ccKickFullscreenDimSync(root);
        }
    });

    LGRegisterMaterialHost(@"ControlCenter", 110, ^BOOL(UIView *material) {
        return ccGlassRadiusForMaterial(material) >= 0.0;
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return ccGlassRadiusForMaterial(material);
    }, nil, nil);
}
