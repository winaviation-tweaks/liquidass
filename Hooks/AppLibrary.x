#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>


static void startAppLibDisplayLink(void);
static void stopAppLibDisplayLink(void);
static void LGAppLibraryRefreshAllHosts(void);
static void LGRemoveAppLibraryGlass(UIView *view);
static BOOL isInsideSearchTextField(UIView *view);
static UIView *LGAppLibraryPodHostView(UIView *view);
static void LGAppLibraryPreparePodChildren(UIView *host);
static void LGEnsureAppLibraryTintOverlay(UIView *host, CGFloat cornerRadius, UIColor *tintColor);
static BOOL LGHandleSearchFieldMaterialView(UIView *view, BOOL updateOnly);
static BOOL LGIsAppLibraryFocusIsolationMaterial(UIView *view);
static CGFloat LGResolvedAppLibSearchCornerRadius(UIView *view);

static LGDisplayLinkState sAppLibraryDisplayLinkState = {0};
static void *kAppLibRetryKey = &kAppLibRetryKey;
static void *kAppLibOriginalAlphaKey = &kAppLibOriginalAlphaKey;
static void *kAppLibOriginalCornerRadiusKey = &kAppLibOriginalCornerRadiusKey;
static void *kAppLibOriginalClipsKey = &kAppLibOriginalClipsKey;
static void *kAppLibGlassKey = &kAppLibGlassKey;
static void *kAppLibTintKey = &kAppLibTintKey;
static void *kAppLibFocusResanitizePendingKey = &kAppLibFocusResanitizePendingKey;
static void *kAppLibBackdropViewKey = &kAppLibBackdropViewKey;
static void *kAppLibSearchBackdropViewKey = &kAppLibSearchBackdropViewKey;
LG_ENABLED_BOOL_PREF_FUNC(LGAppLibraryEnabled, "AppLibrary.Enabled", YES)
LG_BOOL_PREF_FUNC(LGAppLibraryUseIconSnapshot, "AppLibrary.CompositeSnapshot", NO)
static CGFloat LGAppLibCornerRadius(void) { return LGDynamicDefaultFloat(@"AppLibrary.CornerRadius", 20.2); }
LG_FLOAT_PREF_FUNC(LGAppLibBezelWidth, "AppLibrary.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGAppLibGlassThickness, "AppLibrary.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGAppLibRefractionScale, "AppLibrary.RefractionScale", 1.8)
LG_FLOAT_PREF_FUNC(LGAppLibRefractiveIndex, "AppLibrary.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGAppLibSpecularOpacity, "AppLibrary.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGAppLibBlur, "AppLibrary.Blur", 25.0)
LG_FLOAT_PREF_FUNC(LGAppLibWallpaperScale, "AppLibrary.WallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGAppLibLightTintAlpha, "AppLibrary.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGAppLibDarkTintAlpha, "AppLibrary.DarkTintAlpha", 0.0)
LG_ENABLED_BOOL_PREF_FUNC(LGAppLibSearchEnabled, "AppLibrary.Search.Enabled", YES)
static CGFloat LGAppLibSearchCornerRadius(void) { return LGDynamicDefaultFloat(@"AppLibrary.SearchCornerRadius", 24.0); }
LG_FLOAT_PREF_FUNC(LGAppLibSearchBezelWidth, "AppLibrary.SearchBezelWidth", 16.0)
LG_FLOAT_PREF_FUNC(LGAppLibSearchGlassThickness, "AppLibrary.SearchGlassThickness", 100.0)
LG_FLOAT_PREF_FUNC(LGAppLibSearchRefractionScale, "AppLibrary.SearchRefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGAppLibSearchRefractiveIndex, "AppLibrary.SearchRefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGAppLibSearchSpecularOpacity, "AppLibrary.SearchSpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGAppLibSearchBlur, "AppLibrary.SearchBlur", 25.0)
LG_FLOAT_PREF_FUNC(LGAppLibSearchWallpaperScale, "AppLibrary.SearchWallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGAppLibSearchLightTintAlpha, "AppLibrary.SearchLightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGAppLibSearchDarkTintAlpha, "AppLibrary.SearchDarkTintAlpha", 0.0)

static BOOL LGAnyAppLibraryGlassEnabled(void) {
    return LGAppLibraryEnabled() || LGAppLibSearchEnabled();
}

static BOOL LGFilterLooksLikeTintFilter(id filter) {
    NSString *name = nil;
    @try {
        name = [filter valueForKey:@"name"];
    } @catch (__unused NSException *exception) {
        name = nil;
    }
    if (![name isKindOfClass:[NSString class]]) return NO;
    NSString *lower = name.lowercaseString;
    return ([lower containsString:@"vibrant"] ||
            [lower containsString:@"colormatrix"]);
}

static NSArray *LGCleanedFilterArray(NSArray *filters, BOOL *didRemoveAny) {
    if (!filters.count) return filters;
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:filters.count];
    BOOL removed = NO;
    for (id filter in filters) {
        if (LGFilterLooksLikeTintFilter(filter)) {
            removed = YES;
            continue;
        }
        [cleaned addObject:filter];
    }
    if (didRemoveAny) *didRemoveAny = removed;
    return removed ? cleaned : filters;
}

static void stripTintFiltersFromLayerTree(CALayer *layer) {
    if (!layer) return;

    BOOL removedMain = NO;
    NSArray *mainFilters = LGCleanedFilterArray(layer.filters, &removedMain);
    if (removedMain) layer.filters = mainFilters;

    @try {
        id rawBackgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([rawBackgroundFilters isKindOfClass:[NSArray class]]) {
            BOOL removedBg = NO;
            NSArray *cleanedBg = LGCleanedFilterArray((NSArray *)rawBackgroundFilters, &removedBg);
            if (removedBg) [layer setValue:cleanedBg forKey:@"backgroundFilters"];
        }
    } @catch (__unused NSException *exception) {
    }

    layer.compositingFilter = nil;

    for (CALayer *sub in layer.sublayers) {
        stripTintFiltersFromLayerTree(sub);
    }
}

static void stripFocusMaterialFiltersIfNeeded(UIView *view) {
    stripTintFiltersFromLayerTree(view.layer);
}

static BOOL LGHasDescendantClassNamed(UIView *root, NSString *className) {
    if (!root || className.length == 0) return NO;
    __block BOOL found = NO;
    LGTraverseViews(root, ^(UIView *view) {
        if (found) return;
        if ([NSStringFromClass(view.class) isEqualToString:className]) {
            found = YES;
        }
    });
    return found;
}

static BOOL LGIsSidebarLibraryMarkerView(UIView *view) {
    if (!view) return NO;
    return LGHasDescendantClassNamed(view, LGAppLibrarySidebarMarkerClassName);
}

static BOOL LGContainerHasSidebarLibrarySibling(UIView *container, UIView *excluded) {
    if (!container) return NO;
    for (UIView *sibling in container.subviews) {
        if (sibling == excluded) continue;
        if (LGIsSidebarLibraryMarkerView(sibling)) return YES;
    }
    return NO;
}

static BOOL LGIsAppLibraryFocusIsolationMaterial(UIView *view) {
    static Class focusCls;
    if (!focusCls) focusCls = NSClassFromString(@"SBFFocusIsolationView");
    UIView *focusView = view.superview;
    BOOL directFocusChild = focusCls && [focusView isKindOfClass:focusCls];
    BOOL hasSidebarSibling = directFocusChild && LGContainerHasSidebarLibrarySibling(focusView, view);
    if (!directFocusChild) return NO;
    return hasSidebarSibling;
}

static void LGScheduleFocusResanitize(UIView *view) {
    if (!view) return;
    if ([objc_getAssociatedObject(view, kAppLibFocusResanitizePendingKey) boolValue]) return;
    objc_setAssociatedObject(view, kAppLibFocusResanitizePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, kAppLibFocusResanitizePendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!view.window) return;
        if (!LGIsAppLibraryFocusIsolationMaterial(view)) return;
        stripFocusMaterialFiltersIfNeeded(view);
    });
}

static void startAppLibDisplayLink(void) {
    if (!LGAnyAppLibraryGlassEnabled()) return;
    LGStartDisplayLinkState(&sAppLibraryDisplayLinkState, LGPreferredFramesPerSecondForKey(@"AppLibrary.FPS", 30), ^{
        if (LG_prefersLiveCapture(@"AppLibrary.RenderingMode") ||
            LG_prefersLiveCapture(@"AppLibrary.Search.RenderingMode")) {
            LGAppLibraryRefreshAllHosts();
        } else {
            LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
        }
    });
}
static void stopAppLibDisplayLink(void) {
    LGStopDisplayLinkState(&sAppLibraryDisplayLinkState);
}

static void LGSyncAppLibraryDisplayLink(void) {
    if (LGAnyAppLibraryGlassEnabled()) startAppLibDisplayLink();
    else stopAppLibDisplayLink();
}

static void LGAppLibraryRememberOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kAppLibOriginalAlphaKey))
        objc_setAssociatedObject(view, kAppLibOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kAppLibOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(view, kAppLibOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isInsideSearchTextField(view)) {
            CGFloat searchRadius = CGRectGetHeight(view.bounds) * 0.5;
            if (searchRadius > 0.0) {
                LGCacheDynamicDefaultFloat(@"AppLibrary.SearchCornerRadius", searchRadius);
            }
        } else {
            LGCacheDynamicDefaultFloat(@"AppLibrary.CornerRadius", view.layer.cornerRadius);
        }
    }
    if (!objc_getAssociatedObject(view, kAppLibOriginalClipsKey))
        objc_setAssociatedObject(view, kAppLibOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGAppLibraryRestoreOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kAppLibOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kAppLibOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kAppLibOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
}

static void LGRemoveAppLibraryGlass(UIView *view) {
    LGRemoveAssociatedSubview(view, kAppLibTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kAppLibGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kAppLibGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kAppLibBackdropViewKey);
    LGRemoveLiveBackdropCaptureView(view, kAppLibSearchBackdropViewKey);
}

static UIColor *LGAppLibraryTintColorForView(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    NSString *overrideKey = nil;
    if (lightAlpha == LGAppLibSearchLightTintAlpha() && darkAlpha == LGAppLibSearchDarkTintAlpha()) {
        overrideKey = @"AppLibrary.Search.TintOverrideMode";
    } else {
        overrideKey = @"AppLibrary.TintOverrideMode";
    }
    return LGDefaultTintColorForViewWithOverrideKey(view, lightAlpha, darkAlpha, overrideKey);
}

static void LGEnsureAppLibraryTintOverlay(UIView *host, CGFloat cornerRadius, UIColor *tintColor) {
    if (!host) return;
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kAppLibTintKey,
                                           0,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               tintColor,
                               cornerRadius,
                               host.layer,
                               NO);
    [host bringSubviewToFront:tint];
}

static UIView *LGAppLibraryPodHostView(UIView *view) {
    UIView *host = view.superview;
    if (!host) return view;
    if ([host isKindOfClass:[UIView class]] &&
        CGRectGetWidth(host.bounds) >= CGRectGetWidth(view.bounds) &&
        CGRectGetHeight(host.bounds) >= CGRectGetHeight(view.bounds)) {
        return host;
    }
    return view;
}

static void LGAppLibraryPreparePodChildren(UIView *host) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"SBHLibraryCategoryPodBackgroundView"]) {
            sub.backgroundColor = [UIColor clearColor];
            sub.layer.backgroundColor = nil;
            sub.alpha = 0.01;
            sub.hidden = NO;
        }
    }
}

static void LGAppLibraryScheduleRetry(UIView *view, dispatch_block_t block) {
    if ([objc_getAssociatedObject(view, kAppLibRetryKey) boolValue]) return;
    objc_setAssociatedObject(view, kAppLibRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (block) block();
    });
}

static void LGAppLibraryPrepareHost(UIView *host, CGFloat cornerRadius) {
    LGAppLibraryRememberOriginalState(host);
    host.backgroundColor = [UIColor clearColor];
    host.layer.backgroundColor = nil;
    host.layer.cornerRadius = cornerRadius;
    host.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *))
        host.layer.cornerCurve = kCACornerCurveContinuous;
    host.clipsToBounds = YES;
}

static CGFloat LGResolvedAppLibSearchCornerRadius(UIView *view) {
    if (LGHasExplicitPreferenceValue(@"AppLibrary.SearchCornerRadius")) {
        return LGAppLibSearchCornerRadius();
    }
    CGFloat radius = CGRectGetHeight(view.bounds) * 0.5;
    if (radius > 0.0) {
        LGCacheDynamicDefaultFloat(@"AppLibrary.SearchCornerRadius", radius);
        return radius;
    }
    return LGAppLibSearchCornerRadius();
}

static void LGAppLibraryConfigureGlass(LiquidGlassView *glass,
                                       CGFloat cornerRadius,
                                       CGFloat bezelWidth,
                                       CGFloat glassThickness,
                                       CGFloat refractionScale,
                                       CGFloat refractiveIndex,
                                       CGFloat specularOpacity,
                                       CGFloat blur,
                                       CGFloat wallpaperScale) {
    glass.cornerRadius = cornerRadius;
    glass.bezelWidth = bezelWidth;
    glass.glassThickness = glassThickness;
    glass.refractionScale = refractionScale;
    glass.refractiveIndex = refractiveIndex;
    glass.specularOpacity = specularOpacity;
    glass.blur = blur;
    glass.wallpaperScale = wallpaperScale;
    glass.updateGroup = LGUpdateGroupAppLibrary;
}

static UIImage *LGAppLibraryCompositeSnapshot(CGPoint *outOrigin) {
    if (!LGAppLibraryUseIconSnapshot()) {
        return LG_getHomescreenSnapshot(outOrigin);
    }
    if (outOrigin) *outOrigin = CGPointZero;
    UIImage *snapshot = LG_getStrictCachedContextMenuSnapshot();
    if (snapshot) return snapshot;
    LG_cacheContextMenuSnapshot();
    snapshot = LG_getStrictCachedContextMenuSnapshot();
    return snapshot ?: LG_getContextMenuSnapshot();
}

static void injectIntoAppLibrary(UIView *self_) {
    UIView *host = LGAppLibraryPodHostView(self_);
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(host);
        return;
    }
    startAppLibDisplayLink();

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LGAppLibraryCompositeSnapshot(&wallpaperOrigin);
    if (!snapshot && !LG_prefersLiveCapture(@"AppLibrary.RenderingMode")) {
        LGAppLibraryRestoreOriginalState(host);
        LGAppLibraryScheduleRetry(host, ^{
            injectIntoAppLibrary(self_);
        });
        return;
    }

    LGAppLibraryPrepareHost(host, LGAppLibCornerRadius());

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppLibGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:host.bounds wallpaper:snapshot wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kAppLibGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = snapshot;
    }
    LGAppLibraryConfigureGlass(glass,
                               LGAppLibCornerRadius(),
                               LGAppLibBezelWidth(),
                               LGAppLibGlassThickness(),
                               LGAppLibRefractionScale(),
                               LGAppLibRefractiveIndex(),
                               LGAppLibSpecularOpacity(),
                               LGAppLibBlur(),
                               LGAppLibWallpaperScale());
    LGAppLibraryPreparePodChildren(host);
    LGEnsureAppLibraryTintOverlay(host,
                                  LGAppLibCornerRadius(),
                                  LGAppLibraryTintColorForView(host,
                                                               LGAppLibLightTintAlpha(),
                                                               LGAppLibDarkTintAlpha()));
    objc_setAssociatedObject(host, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"AppLibrary.RenderingMode",
                                         kAppLibBackdropViewKey,
                                         snapshot,
                                         wallpaperOrigin)) {
        LGAppLibraryScheduleRetry(host, ^{
            injectIntoAppLibrary(self_);
        });
        return;
    }
}

static void injectIntoSearchBar(UIView *self_) {
    if (!LGAppLibSearchEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        return;
    }
    startAppLibDisplayLink();

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LGAppLibraryCompositeSnapshot(&wallpaperOrigin);
    if (!snapshot && !LG_prefersLiveCapture(@"AppLibrary.Search.RenderingMode")) {
        LGAppLibraryRestoreOriginalState(self_);
        LGAppLibraryScheduleRetry(self_, ^{
            injectIntoSearchBar(self_);
        });
        return;
    }

    CGFloat searchCornerRadius = LGResolvedAppLibSearchCornerRadius(self_);
    LGAppLibraryPrepareHost(self_, searchCornerRadius);

    LiquidGlassView *glass = objc_getAssociatedObject(self_, kAppLibGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:self_.bounds wallpaper:snapshot wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [self_ insertSubview:glass atIndex:0];
        objc_setAssociatedObject(self_, kAppLibGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = snapshot;
    }
    LGAppLibraryConfigureGlass(glass,
                               searchCornerRadius,
                               LGAppLibSearchBezelWidth(),
                               LGAppLibSearchGlassThickness(),
                               LGAppLibSearchRefractionScale(),
                               LGAppLibSearchRefractiveIndex(),
                               LGAppLibSearchSpecularOpacity(),
                               LGAppLibSearchBlur(),
                               LGAppLibSearchWallpaperScale());
    LGEnsureAppLibraryTintOverlay(self_,
                                  searchCornerRadius,
                                  LGAppLibraryTintColorForView(self_,
                                                               LGAppLibSearchLightTintAlpha(),
                                                               LGAppLibSearchDarkTintAlpha()));
    objc_setAssociatedObject(self_, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (!LGApplyRenderingModeToGlassHost(self_,
                                         glass,
                                         @"AppLibrary.Search.RenderingMode",
                                         kAppLibSearchBackdropViewKey,
                                         snapshot,
                                         wallpaperOrigin)) {
        LGAppLibraryScheduleRetry(self_, ^{
            injectIntoSearchBar(self_);
        });
        return;
    }
}

static void LGAppLibraryRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            if ([NSStringFromClass(view.class) isEqualToString:@"SBHLibraryCategoryPodBackgroundView"]) {
                injectIntoAppLibrary(view);
                return;
            }
            if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")] && isInsideSearchTextField(view)) {
                injectIntoSearchBar(view);
            }
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
}

static void LGAppLibraryPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGSyncAppLibraryDisplayLink();
        LGAppLibraryRefreshAllHosts();
    });
}

static BOOL isInsideSearchTextField(UIView *view) {
    UIView *v = view.superview;
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBHSearchTextField");
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL LGHandleSearchFieldMaterialView(UIView *view, BOOL updateOnly) {
    if (!isInsideSearchTextField(view)) return NO;
    if (!view.window || !LGAppLibSearchEnabled()) {
        LGRemoveAppLibraryGlass(view);
        LGAppLibraryRestoreOriginalState(view);
        return YES;
    }
    if (updateOnly) {
        LiquidGlassView *glass = objc_getAssociatedObject(view, kAppLibGlassKey);
        [glass updateOrigin];
        LGAppLibraryPrepareHost(view, LGResolvedAppLibSearchCornerRadius(view));
        return YES;
    }
    injectIntoSearchBar(view);
    LGAppLibraryPrepareHost(view, LGResolvedAppLibSearchCornerRadius(view));
    return YES;
}

%group LGAppLibrarySpringBoard

%hook SBHLibraryCategoryPodBackgroundView

- (void)drawRect:(CGRect)rect {
    if (LGAppLibraryEnabled()) return;
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }

    injectIntoAppLibrary(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }
    injectIntoAppLibrary(self_);
}

%end

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (LGHandleSearchFieldMaterialView(self_, NO)) return;

    if (!self_.window) return;
    if (!LGAnyAppLibraryGlassEnabled()) return;
    static Class focusCls, podCls;
    if (!focusCls) focusCls = NSClassFromString(@"SBFFocusIsolationView");
    if (!podCls)   podCls   = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    UIView *v = self_.superview;
    while (v) {
        if ([v isKindOfClass:focusCls] && LGIsAppLibraryFocusIsolationMaterial(self_)) {
            stripFocusMaterialFiltersIfNeeded(self_);
            LGScheduleFocusResanitize(self_);
            return;
        }
        if ([v isKindOfClass:podCls]) return;
        v = v.superview;
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;

    if (LGHandleSearchFieldMaterialView(self_, YES)) return;

    if (!LGAnyAppLibraryGlassEnabled()) return;
    static Class focusCls2, podCls2;
    if (!focusCls2) focusCls2 = NSClassFromString(@"SBFFocusIsolationView");
    if (!podCls2)   podCls2   = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    UIView *v = self_.superview;
    while (v) {
        if ([v isKindOfClass:focusCls2] && LGIsAppLibraryFocusIsolationMaterial(self_)) {
            stripFocusMaterialFiltersIfNeeded(self_);
            LGScheduleFocusResanitize(self_);
            return;
        }
        if ([v isKindOfClass:podCls2]) return;
        v = v.superview;
    }
}

%end

%hook BSUIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!sAppLibraryDisplayLinkState.link) LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGAppLibraryPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        LGSyncAppLibraryDisplayLink();
    });
    %init(LGAppLibrarySpringBoard);
}
