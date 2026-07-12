#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import "../Runtime/LGSnapshotCaptureSupport.h"
#import <math.h>
#import <objc/runtime.h>

static void *kLGCustomViewGlassKey = &kLGCustomViewGlassKey;
static void *kLGCustomViewTintKey = &kLGCustomViewTintKey;
static void *kLGCustomViewBackdropKey = &kLGCustomViewBackdropKey;
static void *kLGCustomViewLastLiveCaptureTimeKey = &kLGCustomViewLastLiveCaptureTimeKey;
static void *kLGCustomViewOriginalBackgroundKey = &kLGCustomViewOriginalBackgroundKey;
static void *kLGCustomViewOriginalLayerBackgroundKey = &kLGCustomViewOriginalLayerBackgroundKey;
static void *kLGCustomViewAttachedKey = &kLGCustomViewAttachedKey;
static const NSInteger kLGCustomViewTintTag = 0xC0570;

static NSArray<NSDictionary<NSString *, NSString *> *> *sLGCustomViewRules;
static NSSet<NSString *> *sLGCustomViewTargetClasses;
static BOOL sLGCustomViewsRuntimeEnabled;
static NSHashTable<UIView *> *sLGCustomViewHosts;
static LGDisplayLinkState sLGCustomViewDisplayLinkState = {0};

LG_ENABLED_BOOL_PREF_FUNC(LGCustomViewsEnabled, "CustomViews.Enabled", NO)

static NSString *LGCustomViewTrimmedString(NSString *string) {
    if (![string isKindOfClass:NSString.class]) return @"";
    return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<NSString *> *LGCustomViewClassList(NSString *string) {
    NSString *trimmed = LGCustomViewTrimmedString(string);
    if (!trimmed.length) return @[];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",\n"];
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    for (NSString *part in [trimmed componentsSeparatedByCharactersInSet:separators]) {
        NSString *name = LGCustomViewTrimmedString(part);
        if (name.length) [classes addObject:name];
    }
    return classes;
}

static NSString *LGCustomViewRuleKey(NSDictionary<NSString *, NSString *> *rule, NSString *suffix) {
    NSString *prefix = rule[@"Prefix"];
    if (!prefix.length || !suffix.length) return nil;
    return [NSString stringWithFormat:@"%@.%@", prefix, suffix];
}

static id LGCustomViewPreferenceObject(NSString *key, id fallback) {
    if (!key.length) return fallback;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)LGPrefsDomain);
    id object = CFBridgingRelease(value);
    return object ?: fallback;
}

static NSArray<NSString *> *LGCustomViewRuleIDs(void) {
    id stored = LGCustomViewPreferenceObject(@"CustomViews.RuleIDs", @[]);
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id value in (NSArray *)stored) {
        NSString *ruleID = LGCustomViewTrimmedString(value);
        if (ruleID.length && ![ids containsObject:ruleID]) [ids addObject:ruleID];
    }
    return [ids copy];
}

static CGFloat LGCustomViewRuleFloat(NSDictionary<NSString *, NSString *> *rule, NSString *suffix, CGFloat fallback) {
    return LG_prefFloat(LGCustomViewRuleKey(rule, suffix), fallback);
}

static BOOL LGCustomViewRuleBool(NSDictionary<NSString *, NSString *> *rule, NSString *suffix, BOOL fallback) {
    return LG_prefBool(LGCustomViewRuleKey(rule, suffix), fallback);
}

static BOOL LGCustomViewClassMatches(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    if (!view) return NO;
    NSString *actual = NSStringFromClass(view.class);
    for (NSString *expected in LGCustomViewClassList(classList)) {
        if ([actual isEqualToString:expected]) return YES;
    }
    return NO;
}

static BOOL LGCustomViewHasDirectChildClass(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    for (UIView *subview in view.subviews) {
        if (LGCustomViewClassMatches(subview, classList)) return YES;
    }
    return NO;
}

static BOOL LGCustomViewHasGrandchildClass(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    for (UIView *child in view.subviews) {
        for (UIView *grandchild in child.subviews) {
            if (LGCustomViewClassMatches(grandchild, classList)) return YES;
        }
    }
    return NO;
}

static BOOL LGCustomViewHasDescendantClass(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    __block BOOL found = NO;
    LGTraverseViews(view, ^(UIView *descendant) {
        if (found || descendant == view) return;
        if (LGCustomViewClassMatches(descendant, classList)) found = YES;
    });
    return found;
}

static BOOL LGCustomViewHasSiblingClass(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    for (UIView *sibling in view.superview.subviews) {
        if (sibling != view && LGCustomViewClassMatches(sibling, classList)) return YES;
    }
    return NO;
}

static BOOL LGCustomViewHasAncestorClassList(UIView *view, NSString *classList) {
    if (!classList.length) return YES;
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if (LGCustomViewClassMatches(ancestor, classList)) return YES;
    }
    return NO;
}

static BOOL LGCustomViewMatchesRule(UIView *view, NSDictionary<NSString *, NSString *> *rule) {
    if (!LGCustomViewClassMatches(view, rule[@"TargetClass"])) return NO;
    if (!LGCustomViewClassMatches(view.superview, rule[@"ParentClass"])) return NO;
    if (!LGCustomViewClassMatches(view.superview.superview, rule[@"GrandparentClass"])) return NO;
    if (!LGCustomViewHasAncestorClassList(view, rule[@"AncestorClass"])) return NO;
    if (!LGCustomViewHasDirectChildClass(view, rule[@"ChildClass"])) return NO;
    if (!LGCustomViewHasGrandchildClass(view, rule[@"GrandchildClass"])) return NO;
    if (!LGCustomViewHasDescendantClass(view, rule[@"DescendantClass"])) return NO;
    if (!LGCustomViewHasSiblingClass(view, rule[@"SiblingClass"])) return NO;
    return YES;
}

static void LGCustomViewReloadRules(void) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rules = [NSMutableArray array];
    NSMutableSet<NSString *> *targets = [NSMutableSet set];
    for (NSString *ruleID in LGCustomViewRuleIDs()) {
        NSString *prefix = [@"CustomViews.Rule." stringByAppendingString:ruleID];
        if (!LG_prefBool([prefix stringByAppendingString:@".Enabled"], NO)) continue;
        NSString *target = LGCustomViewTrimmedString(LG_prefString([prefix stringByAppendingString:@".TargetClass"], @""));
        if (!target.length) continue;
        NSMutableDictionary<NSString *, NSString *> *rule = [NSMutableDictionary dictionary];
        rule[@"ID"] = ruleID;
        rule[@"Prefix"] = prefix;
        for (NSString *suffix in @[@"TargetClass", @"ParentClass", @"GrandparentClass", @"AncestorClass", @"ChildClass", @"GrandchildClass", @"DescendantClass", @"SiblingClass"]) {
            NSString *value = LGCustomViewTrimmedString(LG_prefString([NSString stringWithFormat:@"%@.%@", prefix, suffix], @""));
            rule[suffix] = value ?: @"";
        }
        for (NSString *targetClass in LGCustomViewClassList(target)) {
            [targets addObject:targetClass];
        }
        [rules addObject:[rule copy]];
    }
    sLGCustomViewRules = [rules copy];
    sLGCustomViewTargetClasses = [targets copy];
    sLGCustomViewsRuntimeEnabled = LG_globalEnabled() && LGCustomViewsEnabled() && sLGCustomViewRules.count > 0;
}

static BOOL LGCustomViewShouldSkipView(UIView *view) {
    if (!view) return YES;
    if ([view isKindOfClass:LiquidGlassView.class]) return YES;
    if (view.tag == kLGCustomViewTintTag) return YES;
    NSString *className = NSStringFromClass(view.class);
    return [className hasPrefix:@"LG"] || [className containsString:@"LiquidGlass"];
}

static NSDictionary<NSString *, NSString *> *LGCustomViewMatchingRule(UIView *view) {
    if (!sLGCustomViewsRuntimeEnabled || LGCustomViewShouldSkipView(view)) return nil;
    if (![sLGCustomViewTargetClasses containsObject:NSStringFromClass(view.class)]) return nil;
    for (NSDictionary<NSString *, NSString *> *rule in sLGCustomViewRules) {
        if (LGCustomViewMatchesRule(view, rule)) return rule;
    }
    return nil;
}

static BOOL LGCustomViewsAnyLiveRuleEnabled(void) {
    if (!sLGCustomViewsRuntimeEnabled) return NO;
    for (NSDictionary<NSString *, NSString *> *rule in sLGCustomViewRules) {
        NSString *renderingModeKey = LGCustomViewRuleKey(rule, @"RenderingMode");
        NSString *mode = LG_prefString(renderingModeKey, LGDefaultRenderingModeForKey(renderingModeKey));
        if ([mode isEqualToString:LGRenderingModeLiveCapture]) return YES;
    }
    return NO;
}

static CGFloat LGCustomViewsMinimumLiveFPS(void) {
    CGFloat fps = CGFLOAT_MAX;
    for (NSDictionary<NSString *, NSString *> *rule in sLGCustomViewRules) {
        NSString *renderingModeKey = LGCustomViewRuleKey(rule, @"RenderingMode");
        NSString *mode = LG_prefString(renderingModeKey, LGDefaultRenderingModeForKey(renderingModeKey));
        if (![mode isEqualToString:LGRenderingModeLiveCapture]) continue;
        fps = MIN(fps, MAX(1.0, LGCustomViewRuleFloat(rule, @"LiveCaptureFPS", 20.0)));
    }
    return fps == CGFLOAT_MAX ? 20.0 : fps;
}

static NSHashTable<UIView *> *LGCustomViewHostRegistry(void) {
    if (!sLGCustomViewHosts) sLGCustomViewHosts = [NSHashTable weakObjectsHashTable];
    return sLGCustomViewHosts;
}

static void LGCustomViewDisplayLinkTick(void);

static void LGCustomViewStartDisplayLinkIfNeeded(void) {
    if (sLGCustomViewDisplayLinkState.link || !LGCustomViewsAnyLiveRuleEnabled()) return;
    NSInteger fps = LGPreferredLiveCaptureFramesPerSecond(LGCustomViewsMinimumLiveFPS());
    LGStartDisplayLinkStateWithPreferenceKey(&sLGCustomViewDisplayLinkState,
                                             fps,
                                             @"DisplayLink.CustomViews.Enabled",
                                             ^{
        NSInteger nextFPS = LGPreferredLiveCaptureFramesPerSecond(LGCustomViewsMinimumLiveFPS());
        LGSetDisplayLinkStatePreferredFPS(&sLGCustomViewDisplayLinkState, nextFPS);
        LGCustomViewDisplayLinkTick();
    });
}

static void LGCustomViewStopDisplayLinkIfNeeded(void) {
    if (LGCustomViewHostRegistry().allObjects.count > 0 && LGCustomViewsAnyLiveRuleEnabled()) return;
    LGStopDisplayLinkState(&sLGCustomViewDisplayLinkState);
}

static void LGCustomViewAttachHostIfNeeded(UIView *host) {
    if (!host) return;
    if ([objc_getAssociatedObject(host, kLGCustomViewAttachedKey) boolValue]) return;
    objc_setAssociatedObject(host, kLGCustomViewAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [LGCustomViewHostRegistry() addObject:host];
    sLGCustomViewDisplayLinkState.activeCount++;
    LGDisplayLinkStateDidChangeActivity(&sLGCustomViewDisplayLinkState);
    LGCustomViewStartDisplayLinkIfNeeded();
}

static void LGCustomViewDetachHostIfNeeded(UIView *host) {
    if (!host) return;
    if (![objc_getAssociatedObject(host, kLGCustomViewAttachedKey) boolValue]) return;
    objc_setAssociatedObject(host, kLGCustomViewAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(host, kLGCustomViewLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [LGCustomViewHostRegistry() removeObject:host];
    sLGCustomViewDisplayLinkState.activeCount = MAX(0, sLGCustomViewDisplayLinkState.activeCount - 1);
    LGDisplayLinkStateDidChangeActivity(&sLGCustomViewDisplayLinkState);
    LGCustomViewStopDisplayLinkIfNeeded();
}

static CGFloat LGCustomViewCornerRadius(UIView *host, NSDictionary<NSString *, NSString *> *rule) {
    CGFloat fallback = host.layer.cornerRadius > 0.0 ? host.layer.cornerRadius : 18.0;
    return LGDynamicDefaultFloat(LGCustomViewRuleKey(rule, @"CornerRadius"), fallback);
}

static void LGCustomViewRememberOriginalState(UIView *host) {
    if (!objc_getAssociatedObject(host, kLGCustomViewOriginalBackgroundKey)) {
        objc_setAssociatedObject(host, kLGCustomViewOriginalBackgroundKey, host.backgroundColor ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(host, kLGCustomViewOriginalLayerBackgroundKey)) {
        id layerBackground = host.layer.backgroundColor ? (__bridge id)host.layer.backgroundColor : NSNull.null;
        objc_setAssociatedObject(host, kLGCustomViewOriginalLayerBackgroundKey, layerBackground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGCustomViewRestoreOriginalState(UIView *host) {
    id background = objc_getAssociatedObject(host, kLGCustomViewOriginalBackgroundKey);
    if (background) host.backgroundColor = background == NSNull.null ? nil : background;
    id layerBackground = objc_getAssociatedObject(host, kLGCustomViewOriginalLayerBackgroundKey);
    if (layerBackground) host.layer.backgroundColor = layerBackground == NSNull.null ? nil : (__bridge CGColorRef)layerBackground;
}

static void LGCustomViewRemove(UIView *host) {
    LGCustomViewDetachHostIfNeeded(host);
    LGRemoveAssociatedSubview(host, kLGCustomViewTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kLGCustomViewGlassKey);
    LGRemoveServerMaterialForHost(host, glass);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kLGCustomViewGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(host, kLGCustomViewBackdropKey);
    LGCustomViewRestoreOriginalState(host);
}

static void LGCustomViewApply(UIView *host) {
    if (!host.window || CGRectIsEmpty(host.bounds)) {
        if (objc_getAssociatedObject(host, kLGCustomViewGlassKey)) LGCustomViewRemove(host);
        else LGCustomViewDetachHostIfNeeded(host);
        return;
    }
    NSDictionary<NSString *, NSString *> *rule = LGCustomViewMatchingRule(host);
    if (!rule) {
        if (objc_getAssociatedObject(host, kLGCustomViewGlassKey)) LGCustomViewRemove(host);
        else LGCustomViewDetachHostIfNeeded(host);
        return;
    }

    LGCustomViewRememberOriginalState(host);
    if (LGCustomViewRuleBool(rule, @"ClearBackground", YES)) {
        host.backgroundColor = UIColor.clearColor;
        host.layer.backgroundColor = nil;
    }
    host.layer.masksToBounds = YES;
    host.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) host.layer.cornerCurve = kCACornerCurveContinuous;

    CGPoint snapshotOrigin = CGPointZero;
    UIImage *snapshot = LG_getHomescreenSnapshot(&snapshotOrigin);
    if (!snapshot) snapshot = LG_getWallpaperImage(&snapshotOrigin);

    NSString *renderingModeKey = LGCustomViewRuleKey(rule, @"RenderingMode");
    NSString *renderingMode = LG_prefString(renderingModeKey, LGDefaultRenderingModeForKey(renderingModeKey));
    BOOL prefersLiveCapture = [renderingMode isEqualToString:LGRenderingModeLiveCapture];
    BOOL prefersServer = [renderingMode isEqualToString:LGRenderingModeServer] && LG_serverMaterialAvailable();

    LiquidGlassView *glass = objc_getAssociatedObject(host, kLGCustomViewGlassKey);
    BOOL hadGlass = glass != nil;
    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds wallpaper:snapshot wallpaperOrigin:snapshotOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupAll;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kLGCustomViewGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.frame = host.bounds;
        if (!prefersLiveCapture && !prefersServer) {
            glass.wallpaperImage = snapshot;
        }
    }

    CGFloat cornerRadius = LGCustomViewCornerRadius(host, rule);
    glass.cornerRadius = cornerRadius;
    glass.bezelWidth = LGCustomViewRuleFloat(rule, @"BezelWidth", 16.0);
    glass.glassThickness = LGCustomViewRuleFloat(rule, @"GlassThickness", 100.0);
    glass.refractionScale = LGCustomViewRuleFloat(rule, @"RefractionScale", 1.5);
    glass.refractiveIndex = LGCustomViewRuleFloat(rule, @"RefractiveIndex", 1.5);
    glass.specularOpacity = LGCustomViewRuleFloat(rule, @"SpecularOpacity", 0.5);
    glass.blur = LGCustomViewRuleFloat(rule, @"Blur", 8.0);
    glass.wallpaperScale = LGCustomViewRuleFloat(rule, @"WallpaperScale", 0.25);
    glass.updateGroup = LGUpdateGroupAll;

    UIView *tint = LGEnsureTintOverlayView(host,
                                           kLGCustomViewTintKey,
                                           kLGCustomViewTintTag,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    UIColor *customTint = LGCustomTintColorForKey(LGCustomViewRuleKey(rule, @"CustomTintColor"));
    UIColor *tintColor = customTint ?: LGDefaultTintColorForViewWithOverrideKey(host,
                                                                                LGCustomViewRuleFloat(rule, @"LightTintAlpha", 0.1),
                                                                                LGCustomViewRuleFloat(rule, @"DarkTintAlpha", 0.0),
                                                                                LGCustomViewRuleKey(rule, @"TintOverrideMode"));
    LGConfigureTintOverlayView(tint, tintColor, cornerRadius, host.layer, YES);
    [host bringSubviewToFront:tint];

    if (prefersServer) {
        LGCustomViewDetachHostIfNeeded(host);
        if (LGApplyRenderingModeToGlassHost(host,
                                            glass,
                                            renderingModeKey,
                                            kLGCustomViewBackdropKey,
                                            snapshot,
                                            snapshotOrigin)) {
            return;
        }
        // material unavailable at attach time; fall through to snapshot
    } else if (prefersLiveCapture) {
        LGRemoveServerMaterialForHost(host, glass);
        LGCustomViewAttachHostIfNeeded(host);
        CGFloat fps = MAX(1.0, LGCustomViewRuleFloat(rule, @"LiveCaptureFPS", 20.0));
        if (!LGShouldRefreshLiveCaptureForHost(host,
                                               renderingModeKey,
                                               kLGCustomViewLastLiveCaptureTimeKey,
                                               fps,
                                               hadGlass)) {
            [glass updateOrigin];
            return;
        }

        CGPoint captureOrigin = CGPointZero;
        CGSize samplingResolution = CGSizeZero;
        BOOL liveOK = LGCaptureLiveBackdropTextureForHost(host,
                                                          glass,
                                                          kLGCustomViewBackdropKey,
                                                          &captureOrigin,
                                                          &samplingResolution);
        if (liveOK) {
            glass.wallpaperOrigin = captureOrigin;
            glass.wallpaperSamplingResolution = samplingResolution;
            [glass updateOrigin];
            LGMarkLiveCaptureRefreshedForHost(host, kLGCustomViewLastLiveCaptureTimeKey);
            return;
        }
        LGRemoveLiveBackdropCaptureView(host, kLGCustomViewBackdropKey);
    } else {
        LGCustomViewDetachHostIfNeeded(host);
        LGRemoveLiveBackdropCaptureView(host, kLGCustomViewBackdropKey);
        LGRemoveServerMaterialForHost(host, glass);
    }

    if (snapshot) {
        glass.wallpaperImage = snapshot;
        glass.wallpaperOrigin = snapshotOrigin;
        glass.wallpaperSamplingResolution = CGSizeZero;
        [glass updateOrigin];
        [glass scheduleDraw];
    }
}

static void LGCustomViewDisplayLinkTick(void) {
    NSArray<UIView *> *hosts = LGCustomViewHostRegistry().allObjects;
    if (!hosts.count) {
        LGCustomViewStopDisplayLinkIfNeeded();
        return;
    }
    for (UIView *host in hosts) {
        LGCustomViewApply(host);
    }
}

static void LGCustomViewScanVisibleWindows(void) {
    for (UIWindow *window in LGApplicationWindows(UIApplication.sharedApplication)) {
        LGTraverseViews(window, ^(UIView *view) {
            if ([sLGCustomViewTargetClasses containsObject:NSStringFromClass(view.class)] ||
                objc_getAssociatedObject(view, kLGCustomViewGlassKey)) {
                LGCustomViewApply(view);
            }
        });
    }
}

%group LGCustomViews

%hook UIView

- (void)didMoveToWindow {
    %orig;
    LGCustomViewApply((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGCustomViewApply((UIView *)self);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess() && !LGIsPreferencesProcess()) return;
    LGCustomViewReloadRules();
    LGObservePreferenceChanges(^{
        LGCustomViewReloadRules();
        LGCustomViewScanVisibleWindows();
        LGCustomViewStartDisplayLinkIfNeeded();
        LGCustomViewStopDisplayLinkIfNeeded();
    });
    %init(LGCustomViews);
}
