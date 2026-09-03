#import "LGGlassKit.h"
#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import <objc/runtime.h>

#pragma mark - class / ancestry helpers

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return NO;
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([cur isKindOfClass:cls]) return YES;
    return NO;
}

BOOL ancestorNameContains(UIView *v, NSString *sub) {
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([NSStringFromClass(cur.class) containsString:sub]) return YES;
    return NO;
}

BOOL isExactClass(UIView *v, NSString *name) {
    return v && [NSStringFromClass(v.class) isEqualToString:name];
}

#pragma mark - per-host enable prefs

BOOL LGProcessMatchesExclusionList(NSString *list) {
    if (!list.length) return NO;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    NSString *executable =
        NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    NSCharacterSet *separators =
        [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];
    for (NSString *rawEntry in [list componentsSeparatedByCharactersInSet:separators]) {
        NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!entry.length || [entry hasPrefix:@"#"]) continue;
        if ([entry isEqualToString:bundleID] ||
            [entry isEqualToString:executable] ||
            [entry isEqualToString:processName]) return YES;
    }
    return NO;
}

BOOL lgHostEnabled(NSString *prefix) {
    if (!prefix.length) return YES;
    id global = LGGlassPreferenceValue(@"Global.Enabled");
    if (![prefix isEqualToString:@"Global"] && [global isKindOfClass:[NSNumber class]] && ![global boolValue])
        return NO;
    id v = LGGlassPreferenceValue([prefix stringByAppendingString:@".Enabled"]);

    if (!v) {
        static NSDictionary<NSString *, NSString *> *legacyPrefixes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            legacyPrefixes = @{
                @"OpenFolder":   @"FolderOpen",
                @"AppLibSearch": @"AppLibrary.Search",
                @"Passcode":     @"Lockscreen.Passcode",
                @"Clock":        @"Lockscreen.Clock",
                @"QuickActions": @"LockscreenQuickActions",
            };
        });
        NSString *legacy = legacyPrefixes[prefix];
        if (legacy) v = LGGlassPreferenceValue([legacy stringByAppendingString:@".Enabled"]);
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];

    if ([prefix isEqualToString:@"AppIcons"]) return NO;
    return YES;
}

#pragma mark - uniform injection registry

@interface LGGlassRec : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, weak) UIView *glass;
@property (nonatomic, weak) UIView *material;
@end
@implementation LGGlassRec @end

void *kGlassKey = &kGlassKey;

static NSMapTable<UIView *, LGGlassRec *> *sGlassRecs;
static NSMapTable<UIView *, NSString *> *sSuppressed;
static NSMutableArray<void (^)(void)> *sReloadHandlers;

@interface LGMaterialHostRoute : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic) NSInteger priority;
@property (nonatomic, copy) LGMaterialHostMatcher matcher;
@property (nonatomic) UIEdgeInsets outset;
@property (nonatomic, copy) LGMaterialHostCornerRadiusProvider cornerRadiusProvider;
@property (nonatomic, copy) NSString *groupName;
@property (nonatomic, copy) LGMaterialHostPostInstall postInstall;
@end
@implementation LGMaterialHostRoute @end
static NSMutableArray<LGMaterialHostRoute *> *sMaterialHostRoutes;

void lgObservePreferenceReload(void (^handler)(void)) {
    if (!handler) return;
    if (!sReloadHandlers) sReloadHandlers = [NSMutableArray array];
    [sReloadHandlers addObject:[handler copy]];
}

void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material) {
    if (!glass || !prefix.length) return;
    if (!sGlassRecs) sGlassRecs = [NSMapTable weakToStrongObjectsMapTable];
    LGGlassRec *existing = [sGlassRecs objectForKey:glass];
    if (existing) {
        existing.prefix = prefix;
        existing.material = material;
        return;
    }
    LGGlassRec *rec = [LGGlassRec new];
    rec.prefix = prefix; rec.glass = glass; rec.material = material;
    [sGlassRecs setObject:rec forKey:glass];
}

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden) {
    if (!v || !prefix.length) return;
    if (setHidden) v.hidden = YES;
    if (!sSuppressed) sSuppressed = [NSMapTable weakToStrongObjectsMapTable];
    [sSuppressed setObject:prefix forKey:v];
}

#pragma mark - registered material lifecycle

LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix) {
    if (!prefix.length) return nil;
    NSString *filterType = LGFilterTypeForHostPrefix(prefix);
    if (!filterType) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    return [[LGLiveBackdropView alloc]
        initWithFrame:frame
            groupName:groupName
           filterType:filterType];
}

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName) {
    if (!material || !associationKey || !prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (!host) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    if (!lgHostEnabled(prefix)) {
        LGRemoveGlassFromMaterial(material, associationKey);
        return nil;
    }

    NSString *filterType = [NSString stringWithUTF8String:host->filterType];
    LGInjectGlassIntoMaterialGroupType(material, associationKey, outset,
                                       cornerRadius, groupName, filterType);
    LGLiveBackdropView *glass = objc_getAssociatedObject(material, associationKey);
    if (glass) lgTrackGlass(glass, prefix, material);
    return glass;
}

void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall) {
    if (!prefix.length || !matcher ||
        !LGHostDefinitionForPreferencePrefix(prefix.UTF8String)) {
        LGLog(@"router rejected invalid material host prefix=%@", prefix);
        return;
    }
    if (!sMaterialHostRoutes) sMaterialHostRoutes = [NSMutableArray array];
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if ([route.prefix isEqualToString:prefix]) return;
    }
    LGMaterialHostRoute *route = [LGMaterialHostRoute new];
    route.prefix = prefix;
    route.priority = priority;
    route.matcher = [matcher copy];
    route.outset = outset;
    route.cornerRadiusProvider = [cornerRadiusProvider copy];
    route.groupName = groupName;
    route.postInstall = [postInstall copy];
    [sMaterialHostRoutes addObject:route];
    // priority makes one host own each material
    [sMaterialHostRoutes sortUsingComparator:^NSComparisonResult(LGMaterialHostRoute *a,
                                                                   LGMaterialHostRoute *b) {
        if (a.priority == b.priority) return [a.prefix compare:b.prefix];
        return a.priority > b.priority ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static void lgRouteMaterialHost(UIView *material) {
    if (!material.window) {
        LGRemoveGlassFromMaterial(material, kGlassKey);
        return;
    }
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if (!route.matcher(material)) continue;
        CGFloat radius = route.cornerRadiusProvider
            ? route.cornerRadiusProvider(material) : -1.0;
        LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
            material, kGlassKey, route.prefix, route.outset, radius, route.groupName);
        if (glass && route.postInstall) route.postInstall(material, glass);
        return;
    }
}

static void lgReconcileInjectionsForDisable(void) {
    // disabled hosts must restore stock views and remove live glass
    if (sGlassRecs.count) {
        for (UIView *glass in sGlassRecs.keyEnumerator.allObjects) {
            LGGlassRec *r = [sGlassRecs objectForKey:glass];
            if (!r) continue;
            if (!lgHostEnabled(r.prefix)) {
                if (r.material) LGRemoveGlassFromMaterial(r.material, kGlassKey);
                else            [glass removeFromSuperview];
                [sGlassRecs removeObjectForKey:glass];
            }
        }
    }
    for (UIView *v in sSuppressed.keyEnumerator.allObjects) {
        NSString *p = [sSuppressed objectForKey:v];
        if (p && !lgHostEnabled(p)) { v.hidden = NO; [sSuppressed removeObjectForKey:v]; }
    }
}

static void lgEnablePrefsReloadCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                                        const void *obj, CFDictionaryRef info) {
    LGLog(@"prefs Reload received; invalidating SpringBoard host-enable cache");
    LGInvalidateGlassPreferenceCache();

    dispatch_async(dispatch_get_main_queue(), ^{
        lgReconcileInjectionsForDisable();
        LGLog(@"prefs Reload reconciled material hosts; extraHandlers=%lu",
              (unsigned long)sReloadHandlers.count);
        for (void (^handler)(void) in [sReloadHandlers copy]) handler();
    });
}

__attribute__((constructor)) static void lgGlassInitEnableObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgEnablePrefsReloadCallback, CFSTR("dylv.liquidassprefs/Reload"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

#pragma mark - shared material lifecycle

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    lgRouteMaterialHost((UIView *)self);
}

- (void)layoutSubviews { %orig; lgRouteMaterialHost((UIView *)self); }

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

- (void)setFrame:(CGRect)frame   { %orig(frame);  LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setBounds:(CGRect)bounds { %orig(bounds); LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setCenter:(CGPoint)center{ %orig(center); LGResyncGlassGeometry((UIView *)self, kGlassKey); }

%end
