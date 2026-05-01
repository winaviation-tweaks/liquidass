#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSTimeInterval kFolderOpenDisplayLinkGrace = 0.18;
static const NSInteger kFolderOpenTintTag = 0xF0D0;
static void *kFolderOpenOriginalAlphaKey = &kFolderOpenOriginalAlphaKey;
static void *kFolderOpenAttachedKey = &kFolderOpenAttachedKey;
static void *kFolderOpenGlassKey = &kFolderOpenGlassKey;
static void *kFolderOpenTintKey = &kFolderOpenTintKey;
static void *kFolderOpenResanitizePendingKey = &kFolderOpenResanitizePendingKey;
static void *kFolderOpenBackdropViewKey = &kFolderOpenBackdropViewKey;

static BOOL isInsideOpenFolder(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static UIView *folderOpenContainerForView(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return v;
        v = v.superview;
    }
    return nil;
}

static void stopFolderDisplayLink(void);
static void scheduleFolderDisplayLinkStopIfIdle(void);
static void LGFolderOpenRefreshAllHosts(void);
static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view));
static void LGRestoreFolderOpenHost(UIView *view);
static void LGDetachFolderOpenHost(UIView *view);
static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly);
static BOOL LGIsPrimaryFolderOpenHost(UIView *view);
static void LGStripFolderOpenTintFiltersFromLayerTree(CALayer *layer);

static LGDisplayLinkState sFolderDisplayLinkState = {0};
static NSUInteger sFolderStopGeneration = 0;
LG_ENABLED_BOOL_PREF_FUNC(LGFolderOpenEnabled, "FolderOpen.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGFolderOpenCornerRadius, "FolderOpen.CornerRadius", 38.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenBezelWidth, "FolderOpen.BezelWidth", 38.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenGlassThickness, "FolderOpen.GlassThickness", 100.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenRefractionScale, "FolderOpen.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGFolderOpenRefractiveIndex, "FolderOpen.RefractiveIndex", 4.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenSpecularOpacity, "FolderOpen.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGFolderOpenBlur, "FolderOpen.Blur", 15.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenWallpaperScale, "FolderOpen.WallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGFolderOpenLightTintAlpha, "FolderOpen.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGFolderOpenDarkTintAlpha, "FolderOpen.DarkTintAlpha", 0.0)

static UIColor *folderOpenTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGFolderOpenLightTintAlpha(), LGFolderOpenDarkTintAlpha(), @"FolderOpen.TintOverrideMode");
}

static BOOL LGFolderOpenFilterLooksLikeTintFilter(id filter) {
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

static void LGStripFolderControllerBackgroundMaterialFiltersIfNeeded(UIView *view) {
    if (!view) return;
    if (![NSStringFromClass(view.superview.class) isEqualToString:@"SBFolderControllerBackgroundView"]) return;
    LGStripFolderOpenTintFiltersFromLayerTree(view.layer);
}

static NSArray *LGFolderOpenCleanedFilterArray(NSArray *filters, BOOL *didRemoveAny) {
    if (!filters.count) return filters;
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:filters.count];
    BOOL removed = NO;
    for (id filter in filters) {
        if (LGFolderOpenFilterLooksLikeTintFilter(filter)) {
            removed = YES;
            continue;
        }
        [cleaned addObject:filter];
    }
    if (didRemoveAny) *didRemoveAny = removed;
    return removed ? cleaned : filters;
}

static void LGStripFolderOpenTintFiltersFromLayerTree(CALayer *layer) {
    if (!layer) return;

    BOOL removedMain = NO;
    NSArray *mainFilters = LGFolderOpenCleanedFilterArray(layer.filters, &removedMain);
    if (removedMain) layer.filters = mainFilters;

    @try {
        id rawBackgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([rawBackgroundFilters isKindOfClass:[NSArray class]]) {
            BOOL removedBg = NO;
            NSArray *cleanedBg = LGFolderOpenCleanedFilterArray((NSArray *)rawBackgroundFilters, &removedBg);
            if (removedBg) [layer setValue:cleanedBg forKey:@"backgroundFilters"];
        }
    } @catch (__unused NSException *exception) {
    }

    layer.compositingFilter = nil;

    for (CALayer *sub in layer.sublayers) {
        LGStripFolderOpenTintFiltersFromLayerTree(sub);
    }
}

static void LGStripFolderOpenMaterialFiltersIfNeeded(UIView *view) {
    if (!view) return;
    if (!isInsideOpenFolder(view)) return;
    if (!LGIsPrimaryFolderOpenHost(view)) return;
    LGStripFolderOpenTintFiltersFromLayerTree(view.layer);
}

static void LGScheduleFolderOpenResanitize(UIView *view) {
    if (!view) return;
    if (!isInsideOpenFolder(view)) return;
    if (!LGIsPrimaryFolderOpenHost(view)) return;
    if ([objc_getAssociatedObject(view, kFolderOpenResanitizePendingKey) boolValue]) return;
    objc_setAssociatedObject(view, kFolderOpenResanitizePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, kFolderOpenResanitizePendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!view.window) return;
        LGStripFolderOpenMaterialFiltersIfNeeded(view);
    });
}

static void ensureFolderOpenTintOverlay(UIView *view) {
    UIView *tint = LGEnsureTintOverlayView(view,
                                           kFolderOpenTintKey,
                                           kFolderOpenTintTag,
                                           view.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               folderOpenTintColorForView(view),
                               LGFolderOpenCornerRadius(),
                               view.layer,
                               NO);
    [view bringSubviewToFront:tint];
}

static void startFolderDisplayLink(void) {
    sFolderStopGeneration++;
    LGStartDisplayLinkState(&sFolderDisplayLinkState, LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 30), ^{
        if (LG_prefersLiveCapture(@"FolderOpen.RenderingMode")) LGFolderOpenRefreshAllHosts();
        else LG_updateRegisteredGlassViews(LGUpdateGroupFolderOpen);
    });
}

static void stopFolderDisplayLink(void) {
    sFolderStopGeneration++;
    LGStopDisplayLinkState(&sFolderDisplayLinkState);
}

static void scheduleFolderDisplayLinkStopIfIdle(void) {
    NSUInteger generation = ++sFolderStopGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderOpenDisplayLinkGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderStopGeneration) return;
        if (sFolderDisplayLinkState.activeCount != 0) return;
        stopFolderDisplayLink();
    });
}

static UIView *LGPrimaryFolderOpenHostForContainer(UIView *container) {
    if (!container) return nil;
    __block UIView *bestView = nil;
    __block CGFloat bestArea = 0.0;
    Class materialCls = NSClassFromString(@"MTMaterialView");
    LGTraverseViews(container, ^(UIView *view) {
        if (view == container) return;
        if (!materialCls || ![view isKindOfClass:materialCls]) return;
        if (view.hidden || view.alpha <= 0.01f || view.layer.opacity <= 0.01f) return;
        CGSize size = view.bounds.size;
        if (size.width < 120.0 || size.height < 120.0) return;
        CGFloat area = size.width * size.height;
        if (area > bestArea) {
            bestArea = area;
            bestView = view;
        }
    });
    return bestView;
}

static BOOL LGIsPrimaryFolderOpenHost(UIView *view) {
    UIView *container = folderOpenContainerForView(view);
    if (!container) return NO;
    return LGPrimaryFolderOpenHostForContainer(container) == view;
}

static void LGRestoreFolderOpenHost(UIView *view) {
    LGRemoveAssociatedSubview(view, kFolderOpenTintKey);

    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kFolderOpenBackdropViewKey);

    NSNumber *originalAlpha = objc_getAssociatedObject(view, kFolderOpenOriginalAlphaKey);
    if (originalAlpha) view.alpha = [originalAlpha doubleValue];
}

static void LGDetachFolderOpenHost(UIView *view) {
    LGRestoreFolderOpenHost(view);
    if (![objc_getAssociatedObject(view, kFolderOpenAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kFolderOpenAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sFolderDisplayLinkState.activeCount = MAX(0, sFolderDisplayLinkState.activeCount - 1);
    if (sFolderDisplayLinkState.activeCount == 0) scheduleFolderDisplayLinkStopIfIdle();
}

static void injectIntoOpenFolder(UIView *host) {
    if (!LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(host);
        return;
    }
    if (!LGIsPrimaryFolderOpenHost(host)) {
        LGDetachFolderOpenHost(host);
        return;
    }

    UIImage *snapshot = LG_getFolderSnapshot();
    if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    if (!snapshot) {
        snapshot = LG_getStrictCachedContextMenuSnapshot();
        if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    }
    if (!snapshot && !LG_prefersLiveCapture(@"FolderOpen.RenderingMode")) {
        NSNumber *originalAlpha = objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey);
        if (originalAlpha) host.alpha = [originalAlpha doubleValue];
        return;
    }

    if (!objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey))
        objc_setAssociatedObject(host, kFolderOpenOriginalAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kFolderOpenGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds
                                             wallpaper:snapshot
                                       wallpaperOrigin:CGPointZero];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupFolderOpen;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kFolderOpenGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (glass.wallpaperImage != snapshot) {
        glass.wallpaperImage = snapshot;
    }

    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    LGStripFolderOpenMaterialFiltersIfNeeded(host);
    ensureFolderOpenTintOverlay(host);
    LGScheduleFolderOpenResanitize(host);
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"FolderOpen.RenderingMode",
                                         kFolderOpenBackdropViewKey,
                                         snapshot,
                                         CGPointZero)) {
        return;
    }

    if (![objc_getAssociatedObject(host, kFolderOpenAttachedKey) boolValue]) {
        objc_setAssociatedObject(host, kFolderOpenAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sFolderDisplayLinkState.activeCount++;
    }
    startFolderDisplayLink();
}

static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view)) {
    if (!block) return;
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (!isInsideOpenFolder(view)) return;
                    block(view);
                });
            }
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) {
            LGTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (!isInsideOpenFolder(view)) return;
                block(view);
            });
        }
    }
}

static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly) {
    if (!view) return;
    LGStripFolderControllerBackgroundMaterialFiltersIfNeeded(view);
    if (!view.window) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!isInsideOpenFolder(view) || !LGIsPrimaryFolderOpenHost(view) || !LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!updateOnly) {
        injectIntoOpenFolder(view);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    ensureFolderOpenTintOverlay(view);
    if (!glass) {
        injectIntoOpenFolder(view);
        return;
    }
    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    LGStripFolderOpenMaterialFiltersIfNeeded(view);
    [glass updateOrigin];
    LGScheduleFolderOpenResanitize(view);
}

static void LGFolderOpenRefreshAllHosts(void) {
    LGFolderOpenForEachMaterialHost(^(UIView *view) {
        LGHandleFolderOpenMaterialView(view, NO);
    });
}

static void LGFolderOpenPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!LGFolderOpenEnabled()) {
            LGFolderOpenForEachMaterialHost(^(UIView *view) {
                LGDetachFolderOpenHost(view);
            });
            stopFolderDisplayLink();
            return;
        }
        LGFolderOpenRefreshAllHosts();
    });
}

%group LGFolderOpenSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, NO);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, YES);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGFolderOpenPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGFolderOpenSpringBoard);
}
