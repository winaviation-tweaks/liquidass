#import "LGPrefsDataSupport.h"
#import "LGPRootListController.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGSharedSupport.h"
#import <notify.h>

NSString * const kLGPrefsUIRefreshNotification = @"LGPrefsUIRefreshNotification";
NSString * const kLGPrefsRespringChangedNotification = @"LGPrefsRespringChangedNotification";
NSString * const kLGLastSurfaceKey = @"LGPrefsLastSurface";
NSString * const kLGPrefsLanguageChangedNotification = @"LGPrefsLanguageChangedNotification";
NSString * const kLGPrefsLanguageKey = @"LGPrefsLanguage";
static NSString * const kLGNeedsRespringKey = @"LGPrefsNeedsRespring";
static NSString * const kLGRespringBarDismissedKey = @"LGPrefsRespringBarDismissed";
static const char *LGInvalidateSnapshotCachesNotificationCString = "love.litten.liquidass/InvalidateSnapshotCaches";
static dispatch_queue_t sLGPrefsWriteQueue;
static dispatch_source_t sLGPrefsSyncTimer;
static NSArray<NSDictionary *> *LGPerSurfaceTintOverrideItems(void);
static NSString * const kLGDynamicDefaultPrefix = @"__dynamic_default.";

static void LGEnsurePreferencesWriteQueueInitialized(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGPrefsWriteQueue = dispatch_queue_create("dylv.liquidass.prefswrite", DISPATCH_QUEUE_SERIAL);
    });
}

static void LGRemovePreferenceWithoutNotify(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             NULL,
                             (__bridge CFStringRef)LGPrefsDomain);
}

static NSArray<NSString *> *LGExportablePreferenceKeys(void) {
    NSMutableOrderedSet<NSString *> *orderedKeys = [NSMutableOrderedSet orderedSet];
    NSArray<NSArray<NSDictionary *> *> *sources = @[
        LGAllSurfaceItems(),
        LGMoreOptionsItems(),
        LGPrefsSettingsItems(),
        LGPrefsControlsItems(),
        LGExperimentalItems(),
        LGCustomViewInjectionItems(),
        LGLiveCaptureItems()
    ];
    for (NSArray<NSDictionary *> *items in sources) {
        for (NSDictionary *item in items) {
            NSString *key = item[@"key"];
            if (key.length) [orderedKeys addObject:key];
        }
    }
    for (NSDictionary *item in LGPerSurfaceTintOverrideItems()) {
        NSString *key = item[@"key"];
        if (key.length) [orderedKeys addObject:key];
    }
    for (NSString *key in LGAllCustomViewPreferenceKeys()) {
        if (key.length) [orderedKeys addObject:key];
    }
    return orderedKeys.array;
}

static void LGSchedulePreferencesSynchronize(void) {
    LGEnsurePreferencesWriteQueueInitialized();

    dispatch_async(sLGPrefsWriteQueue, ^{
        if (!sLGPrefsSyncTimer) {
            sLGPrefsSyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sLGPrefsWriteQueue);
            dispatch_source_t timer = sLGPrefsSyncTimer;
            dispatch_source_set_event_handler(timer, ^{
                CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
                dispatch_source_cancel(timer);
            });
            dispatch_source_set_cancel_handler(timer, ^{
                if (sLGPrefsSyncTimer == timer) {
                    sLGPrefsSyncTimer = nil;
                }
            });
            dispatch_resume(timer);
        }
        dispatch_source_set_timer(sLGPrefsSyncTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(0.02 * NSEC_PER_SEC));
    });
}

static void LGFlushPreferencesSynchronize(void) {
    LGEnsurePreferencesWriteQueueInitialized();

    dispatch_sync(sLGPrefsWriteQueue, ^{
        if (sLGPrefsSyncTimer) {
            dispatch_source_t timer = sLGPrefsSyncTimer;
            sLGPrefsSyncTimer = nil;
            dispatch_source_cancel(timer);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    });
}

static NSBundle *LGActiveLocalizationBundle(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    if (!languageCode.length || [languageCode isEqualToString:@"en"]) {
        return baseBundle;
    }

    NSString *bundlePath = [baseBundle pathForResource:languageCode ofType:@"lproj"];
    if (!bundlePath.length) {
        return baseBundle;
    }

    NSBundle *localizedBundle = [NSBundle bundleWithPath:bundlePath];
    return localizedBundle ?: baseBundle;
}

static NSString *LGDisplayNameForLanguageCode(NSString *languageCode) {
    if (!languageCode.length) return @"";
    if ([languageCode isEqualToString:@"en"]) return @"English";

    NSLocale *displayLocale = [NSLocale currentLocale];
    NSString *localeIdentifier = [NSLocale canonicalLocaleIdentifierFromString:languageCode];
    NSString *name = [displayLocale displayNameForKey:NSLocaleIdentifier value:localeIdentifier];
    if (!name.length) {
        NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:localeIdentifier];
        NSString *baseLanguageCode = components[NSLocaleLanguageCode];
        if (baseLanguageCode.length) {
            name = [displayLocale localizedStringForLanguageCode:baseLanguageCode];
        }
    }
    return name.length ? name : languageCode;
}

static NSArray<NSDictionary *> *LGAvailableLanguageChoices(void) {
    static NSArray<NSDictionary *> *choices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
        NSMutableOrderedSet<NSString *> *codes = [NSMutableOrderedSet orderedSetWithObject:@"en"];
        for (NSString *path in [baseBundle pathsForResourcesOfType:@"lproj" inDirectory:nil]) {
            NSString *languageCode = [[path lastPathComponent] stringByDeletingPathExtension];
            if (languageCode.length && ![languageCode isEqualToString:@"Base"]) {
                [codes addObject:languageCode];
            }
        }

        NSMutableArray<NSDictionary *> *dynamicChoices = [NSMutableArray arrayWithCapacity:codes.count];
        for (NSString *languageCode in codes) {
            [dynamicChoices addObject:@{
                @"value": languageCode,
                @"title": LGDisplayNameForLanguageCode(languageCode)
            }];
        }

        [dynamicChoices sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
            NSString *leftValue = lhs[@"value"];
            NSString *rightValue = rhs[@"value"];
            if ([leftValue isEqualToString:@"en"]) return NSOrderedAscending;
            if ([rightValue isEqualToString:@"en"]) return NSOrderedDescending;
            return [lhs[@"title"] localizedCaseInsensitiveCompare:rhs[@"title"]];
        }];
        choices = [dynamicChoices copy];
    });
    return choices;
}

Class LGPrefsSwitchClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSwitch") ?: [UISwitch class];
}

Class LGPrefsSliderClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSlider") ?: [UISlider class];
}

NSUserDefaults *LGPrefsUIStateDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void LGSynchronizeSurfaceStateDefaults(void) {
    [LGPrefsUIStateDefaults() synchronize];
}

NSString *LGLastSurfaceIdentifier(void) {
    return [LGPrefsUIStateDefaults() stringForKey:kLGLastSurfaceKey];
}

void LGSetLastSurfaceIdentifier(NSString *identifier) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (identifier.length) {
        [defaults setObject:identifier forKey:kLGLastSurfaceKey];
    } else {
        [defaults removeObjectForKey:kLGLastSurfaceKey];
    }
    LGSynchronizeSurfaceStateDefaults();
}

void LGClearLastSurfaceIdentifierIfMatching(NSString *identifier) {
    if (!identifier.length) return;
    NSString *current = LGLastSurfaceIdentifier();
    if ([current isEqualToString:identifier]) {
        LGSetLastSurfaceIdentifier(nil);
    }
}

void LGObservePrefsNotifications(id target) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:target
               selector:@selector(handlePrefsUIRefresh:)
                   name:kLGPrefsUIRefreshNotification
                 object:nil];
    [center addObserver:target
               selector:@selector(handleRespringStateChanged:)
                   name:kLGPrefsRespringChangedNotification
                 object:nil];
}

NSString *LGLocalized(NSString *key) {
    NSBundle *bundle = LGActiveLocalizationBundle();
    NSString *localized = [bundle localizedStringForKey:key value:key table:nil];
    if (localized.length) return localized;
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    return [baseBundle localizedStringForKey:key value:key table:nil];
}

NSString *LGPrefsAppName(void) {
    return LGLocalized(@"prefs.app_name");
}

NSString *LGCurrentPrefsLanguageCode(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    return languageCode.length ? languageCode : @"en";
}

void LGSetCurrentPrefsLanguageCode(NSString *languageCode) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (!languageCode.length || [languageCode isEqualToString:@"en"]) {
        [defaults removeObjectForKey:kLGPrefsLanguageKey];
    } else {
        [defaults setObject:languageCode forKey:kLGPrefsLanguageKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
}

BOOL LGPreferenceRequiresRespring(NSString *key) {
    if (!key.length) return NO;
    static NSSet<NSString *> *respringKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        respringKeys = [NSSet setWithArray:@[
            @"Global.Enabled",
            @"Dock.Enabled",
            @"FolderIcon.Enabled",
            @"FolderOpen.Enabled",
            @"AppIcons.Enabled",
            @"SearchPill.Enabled",
            @"ContextMenu.Enabled",
            @"Banner.Enabled",
            @"Lockscreen.Enabled",
            @"LockscreenQuickActions.Enabled",
            @"Lockscreen.Passcode.Enabled",
            @"Lockscreen.Clock.Enabled",
            @"AppLibrary.Enabled",
            @"AppLibrary.Search.Enabled",
            @"Widgets.Enabled",
            @"ControlCenter.Enabled",
        ]];
    });
    return [respringKeys containsObject:key];
}

BOOL LGNeedsRespring(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGNeedsRespringKey];
}

BOOL LGRespringBarDismissed(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGRespringBarDismissedKey];
}

void LGSetRespringBarDismissed(BOOL dismissed) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:dismissed forKey:kLGRespringBarDismissedKey];
    LGSynchronizeSurfaceStateDefaults();
}

void LGSetNeedsRespring(BOOL needsRespring) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:needsRespring forKey:kLGNeedsRespringKey];
    if (!needsRespring) {
        [defaults setBool:NO forKey:kLGRespringBarDismissedKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsRespringChangedNotification object:nil];
}

void LGForceSynchronizePreferences(void) {
    LGFlushPreferencesSynchronize();
}

void LGPostInvalidateSnapshotCachesNotification(void) {
    notify_post(LGInvalidateSnapshotCachesNotificationCString);
}

NSNumber *LGReadPreference(NSString *key, NSNumber *fallback) {
    id obj = LGReadPreferenceObject(key, fallback);
    return [obj isKindOfClass:[NSNumber class]] ? obj : fallback;
}

id LGReadPreferenceObject(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)LGPrefsDomain);
    id obj = CFBridgingRelease(value);
    return obj ?: fallback;
}

void LGWritePreference(NSString *key, NSNumber *value) {
    LGWritePreferenceObject(key, value);
}

void LGWritePreferenceObject(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)LGPrefsDomain);
    notify_post(LGPrefsChangedNotificationCString);
    LGSchedulePreferencesSynchronize();
}

void LGWritePreferenceAndMaybeRequireRespring(NSString *key, NSNumber *value) {
    LGWritePreference(key, value);
    if (LGPreferenceRequiresRespring(key)) {
        LGSetRespringBarDismissed(NO);
        LGSetNeedsRespring(YES);
    }
}

void LGRemovePreference(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             NULL,
                             (__bridge CFStringRef)LGPrefsDomain);
    notify_post(LGPrefsChangedNotificationCString);
    LGSchedulePreferencesSynchronize();
}

NSDictionary *LGSwitchSetting(NSString *key, NSString *title, NSString *subtitle, BOOL fallback) {
    return @{
        @"type": @"switch",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback)
    };
}

NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle) {
    return @{
        @"type": @"section",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @""
    };
}

static NSDictionary *LGSpacerSetting(CGFloat height, CGFloat afterSpacing) {
    return @{
        @"type": @"section",
        @"title": @"",
        @"subtitle": @"",
        @"height": @(height),
        @"after_spacing": @(afterSpacing)
    };
}

static NSDictionary *LGAboutContentSetting(void) {
    return @{
        @"type": @"about_content"
    };
}

NSDictionary *LGNavSetting(NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @""
    };
}

static NSDictionary *LGKeyedNavSetting(NSString *key, NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @"",
        @"default": @""
    };
}

NSDictionary *LGMenuSetting(NSString *key, NSString *title, NSString *subtitle, NSString *fallback, NSArray<NSDictionary *> *choices) {
    return @{
        @"type": @"menu",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"default": fallback ?: @"",
        @"choices": choices ?: @[]
    };
}

NSDictionary *LGStringSetting(NSString *key, NSString *title, NSString *subtitle, NSString *fallback, NSString *placeholder) {
    return @{
        @"type": @"string",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"default": fallback ?: @"",
        @"placeholder": placeholder ?: @""
    };
}

NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle,
                              CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return @{
        @"type": @"slider",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback),
        @"min": @(min),
        @"max": @(max),
        @"decimals": @(decimals)
    };
}

static NSDictionary *LGSettingControlledByKey(NSDictionary *item, NSString *enabledKey, id enabledDefault) {
    NSMutableDictionary *copy = [item mutableCopy];
    if (enabledKey.length) copy[@"enabled_key"] = enabledKey;
    if (enabledDefault) copy[@"enabled_default"] = enabledDefault;
    return [copy copy];
}

static NSDictionary *LGSettingVisibleForKeyValues(NSDictionary *item, NSString *visibleKey, id visibleDefault, NSArray *visibleValues) {
    NSMutableDictionary *copy = [item mutableCopy];
    if (visibleKey.length) copy[@"visible_key"] = visibleKey;
    if (visibleDefault) copy[@"visible_default"] = visibleDefault;
    if (visibleValues.count) copy[@"visible_values"] = visibleValues;
    return [copy copy];
}

NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback) {
    NSMutableDictionary *item = [LGSwitchSetting(key,
                                                 LGLocalized(@"prefs.control.enabled"),
                                                 LGLocalized(@"prefs.subtitle.enabled"),
                                                 fallback) mutableCopy];
    item[@"controls_following_panel"] = @YES;
    return [item copy];
}

static NSArray<NSDictionary *> *LGRenderingModeOptions(void) {
    NSMutableArray *options = [NSMutableArray arrayWithObjects:
        @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
        @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")},
        nil];
    if (LG_serverMaterialAvailable()) {
        [options addObject:@{@"value": LGRenderingModeServer, @"title": LGLocalized(@"prefs.rendering.server.title")}];
    }
    return options;
}

NSDictionary *LGGlassRenderingModeSetting(NSString *key) {
    return LGMenuSetting(key,
                         LGLocalized(@"prefs.control.rendering_method"),
                         LGLocalized(@"prefs.subtitle.rendering_method"),
                         LGRenderingModeSnapshot,
                         LGRenderingModeOptions());
}

NSDictionary *LGGlassRenderingModeSettingWithFallback(NSString *key, NSString *fallback) {
    return LGMenuSetting(key,
                         LGLocalized(@"prefs.control.rendering_method"),
                         LGLocalized(@"prefs.subtitle.rendering_method"),
                         fallback ?: LGRenderingModeSnapshot,
                         LGRenderingModeOptions());
}

static const CGFloat kLGUniversalBezelMax = 50.0f;
static const CGFloat kLGUniversalBlurMax = 50.0f;
static const CGFloat kLGUniversalCornerRadiusMax = 100.0f;
static const CGFloat kLGUniversalThicknessMax = 200.0f;
static const CGFloat kLGUniversalTintMax = 1.0f;
static const CGFloat kLGUniversalRefractiveIndexMax = 5.0f;
static const CGFloat kLGUniversalRefractionMax = 5.0f;
static const CGFloat kLGUniversalSpecularMax = 1.0f;
static const CGFloat kLGUniversalQualityMax = 1.0f;

NSDictionary *LGGlassBezelSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.bezel_width"), LGLocalized(@"prefs.subtitle.bezel_width"), fallback, min, kLGUniversalBezelMax, decimals);
}

NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.blur"), LGLocalized(@"prefs.subtitle.blur"), fallback, min, kLGUniversalBlurMax, decimals);
}

NSDictionary *LGGlassCornerRadiusSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key,
                           LGLocalized(@"prefs.control.corner_radius"),
                           LGLocalized(@"prefs.subtitle.corner_radius"),
                           LGCornerRadiusDefaultForKey(key, fallback),
                           min,
                           kLGUniversalCornerRadiusMax,
                           decimals);
}

CGFloat LGCornerRadiusDefaultForKey(NSString *key, CGFloat fallback) {
    return LGDynamicDefaultFloat(key, fallback);
}

NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.glass_thickness"), LGLocalized(@"prefs.subtitle.glass_thickness"), fallback, min, kLGUniversalThicknessMax, decimals);
}

NSDictionary *LGGlassLightTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.light_tint_alpha"), LGLocalized(@"prefs.subtitle.light_tint_alpha"), fallback, min, kLGUniversalTintMax, decimals);
}

NSDictionary *LGGlassDarkTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.dark_tint_alpha"), LGLocalized(@"prefs.subtitle.dark_tint_alpha"), fallback, min, kLGUniversalTintMax, decimals);
}

NSDictionary *LGGlassCustomTintColorSetting(NSString *key) {
    return LGStringSetting(key,
                           LGLocalized(@"prefs.control.custom_tint_color"),
                           LGLocalized(@"prefs.subtitle.custom_tint_color"),
                           @"",
                           @"#RRGGBBAA");
}

NSDictionary *LGGlassTintOverrideSettingWithFallback(NSString *key, NSString *title, NSString *fallback) {
    return LGMenuSetting(key,
                         title ?: @"",
                         @"",
                         fallback ?: LGTintOverrideSystem,
                         @[
                             @{@"value": LGTintOverrideSystem, @"title": LGLocalized(@"prefs.tint_override.system.title")},
                             @{@"value": LGTintOverrideLight, @"title": LGLocalized(@"prefs.tint_override.light.title")},
                             @{@"value": LGTintOverrideDark, @"title": LGLocalized(@"prefs.tint_override.dark.title")}
                         ]);
}

NSDictionary *LGGlassTintOverrideSetting(NSString *key, NSString *title) {
    return LGGlassTintOverrideSettingWithFallback(key, title, LGTintOverrideSystem);
}

static NSArray<NSDictionary *> *LGPerSurfaceTintOverrideItems(void) {
    return @[
        LGGlassTintOverrideSetting(@"Dock.TintOverrideMode", LGLocalized(@"prefs.section.dock.title")),
        LGGlassTintOverrideSetting(@"FolderIcon.TintOverrideMode", LGLocalized(@"prefs.section.folder_icons.title")),
        LGGlassTintOverrideSetting(@"FolderOpen.TintOverrideMode", LGLocalized(@"prefs.section.folder_open.title")),
        LGGlassTintOverrideSetting(@"AppIcons.TintOverrideMode", LGLocalized(@"prefs.section.app_icons.title")),
        LGGlassTintOverrideSetting(@"ContextMenu.TintOverrideMode", LGLocalized(@"prefs.section.context_menu.title")),
        LGGlassTintOverrideSetting(@"Banner.TintOverrideMode", LGLocalized(@"prefs.section.banner.title")),
        LGGlassTintOverrideSetting(@"ControlCenter.TintOverrideMode", LGLocalized(@"prefs.section.control_center.title")),
        LGGlassTintOverrideSetting(@"SearchPill.TintOverrideMode", LGLocalized(@"prefs.section.search_pill.title")),
        LGGlassTintOverrideSetting(@"Widgets.TintOverrideMode", LGLocalized(@"prefs.section.widgets.title")),
        LGGlassTintOverrideSetting(@"Lockscreen.TintOverrideMode", LGLocalized(@"prefs.section.lockscreen_notifications.title")),
        LGGlassTintOverrideSetting(@"LockscreenQuickActions.TintOverrideMode", LGLocalized(@"prefs.section.lockscreen_quick_actions.title")),
        LGGlassTintOverrideSettingWithFallback(@"Lockscreen.Clock.TintOverrideMode", LGLocalized(@"prefs.section.lockscreen_clock.title"), LGTintOverrideLight),
        LGGlassTintOverrideSetting(@"AppLibrary.TintOverrideMode", LGLocalized(@"prefs.section.category_pods.title")),
        LGGlassTintOverrideSetting(@"AppLibrary.Search.TintOverrideMode", LGLocalized(@"prefs.section.search_field.title")),
    ];
}

static NSDictionary *LGDisplayLinkSurfaceSwitch(NSString *key, NSString *title) {
    return LGSwitchSetting(key,
                           title ?: @"",
                           LGLocalized(@"prefs.misc.display_link_surface.subtitle"),
                           YES);
}

static NSArray<NSDictionary *> *LGPerSurfaceDisplayLinkItems(void) {
    return @[
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.Dock.Enabled", LGLocalized(@"prefs.section.dock.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.FolderOpen.Enabled", LGLocalized(@"prefs.section.folder_open.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.ContextMenu.Enabled", LGLocalized(@"prefs.section.context_menu.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.Banner.Enabled", LGLocalized(@"prefs.section.banner.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.ControlCenter.Enabled", LGLocalized(@"prefs.section.control_center.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.Widgets.Enabled", LGLocalized(@"prefs.section.widgets.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.AppLibrary.Enabled", LGLocalized(@"prefs.surface.app_library.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.Lockscreen.Enabled", LGLocalized(@"prefs.surface.lockscreen.title")),
        LGDisplayLinkSurfaceSwitch(@"DisplayLink.LockscreenClock.Enabled", LGLocalized(@"prefs.section.lockscreen_clock.title")),
    ];
}

NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refractive_index"), LGLocalized(@"prefs.subtitle.refractive_index"), fallback, min, kLGUniversalRefractiveIndexMax, decimals);
}

NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refraction"), LGLocalized(@"prefs.subtitle.refraction"), fallback, min, kLGUniversalRefractionMax, decimals);
}

NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.specular"), LGLocalized(@"prefs.subtitle.specular"), fallback, min, kLGUniversalSpecularMax, decimals);
}

NSDictionary *LGGlassQualitySetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.quality"), LGLocalized(@"prefs.subtitle.quality"), fallback, min, kLGUniversalQualityMax, decimals);
}

NSInteger LGMaximumSupportedFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    if (maxFPS <= 0) maxFPS = 60;
    return maxFPS >= 120 ? 120 : 60;
}

NSDictionary *LGScopedFPSSliderSetting(NSString *key) {
    NSInteger maxFPS = LGMaximumSupportedFPS();
    NSInteger defaultFPS = (30 + maxFPS) / 2;
    NSString *subtitle = maxFPS >= 120
        ? LGLocalized(@"prefs.subtitle.fps_limit_120")
        : LGLocalized(@"prefs.subtitle.fps_limit_60");
    return LGSliderSetting(key, LGLocalized(@"prefs.control.fps_limit"), subtitle, defaultFPS, 1.0, (CGFloat)maxFPS, 0);
}

NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals) {
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%ldf", (long)decimals], value];
}

static NSString *LGSurfaceGroupSortTitle(NSArray<NSDictionary *> *items) {
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            if (title.length) return title;
        }
    }
    NSString *title = items.firstObject[@"title"];
    return title ?: @"";
}

static NSArray<NSDictionary *> *LGSurfaceItemsBySortingSectionGroups(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSDictionary *> *leadingItems = [NSMutableArray array];
    NSMutableArray<NSArray<NSDictionary *> *> *groups = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *currentGroup = nil;
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            NSString *subtitle = item[@"subtitle"];
            if (!title.length && !subtitle.length) {
                if (currentGroup) {
                    [currentGroup addObject:item];
                } else {
                    [leadingItems addObject:item];
                }
                continue;
            }
            if (currentGroup.count) {
                [groups addObject:[currentGroup copy]];
            }
            currentGroup = [NSMutableArray arrayWithObject:item];
            continue;
        }
        if (currentGroup) {
            [currentGroup addObject:item];
        } else {
            [leadingItems addObject:item];
        }
    }
    if (currentGroup.count) {
        [groups addObject:[currentGroup copy]];
    }

    NSArray<NSArray<NSDictionary *> *> *sortedGroups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSDictionary *> *lhs,
                                                                                                               NSArray<NSDictionary *> *rhs) {
        NSString *leftTitle = LGSurfaceGroupSortTitle(lhs);
        NSString *rightTitle = LGSurfaceGroupSortTitle(rhs);
        NSComparisonResult result = [leftTitle localizedCaseInsensitiveCompare:rightTitle];
        if (result != NSOrderedSame) return result;
        return [leftTitle compare:rightTitle];
    }];
    NSMutableArray<NSDictionary *> *sortedItems = [leadingItems mutableCopy];
    for (NSArray<NSDictionary *> *group in sortedGroups) {
        [sortedItems addObjectsFromArray:group];
    }
    return [sortedItems copy];
}

NSArray<NSDictionary *> *LGDockItems(void) {
    return @[
        LGGlassEnabledSetting(@"Dock.Enabled", YES),
        LGGlassBezelSetting(@"Dock.BezelWidth", 30.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"Dock.Blur", 10.0, 0.0, 30.0, 1),
        LGSliderSetting(@"Dock.CornerRadiusFloating", LGLocalized(@"prefs.control.floating_radius"), LGLocalized(@"prefs.subtitle.floating_radius"), 30.5, 0.0, kLGUniversalCornerRadiusMax, 1),
        LGSliderSetting(@"Dock.CornerRadiusFullScreen", LGLocalized(@"prefs.control.full_screen_radius"), LGLocalized(@"prefs.subtitle.full_screen_radius"), 34.0, 0.0, kLGUniversalCornerRadiusMax, 1),
        LGGlassThicknessSetting(@"Dock.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassDarkTintSetting(@"Dock.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGSliderSetting(@"Dock.CornerRadiusHomeButton", LGLocalized(@"prefs.control.home_button_radius"), LGLocalized(@"prefs.subtitle.home_button_radius"), 0.0, 0.0, kLGUniversalCornerRadiusMax, 1),
        LGGlassLightTintSetting(@"Dock.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"Dock.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"Dock.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Dock.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Dock.SpecularOpacity", 0.3, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Dock.WallpaperScale", 0.25, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGFolderItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.folder_icons.title"), LGLocalized(@"prefs.section.folder_icons.subtitle")),
        LGGlassEnabledSetting(@"FolderIcon.Enabled", YES),
        LGGlassBezelSetting(@"FolderIcon.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"FolderIcon.Blur", 3.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"FolderIcon.CornerRadius", 13.5, 0.0, 24.0, 1),
        LGGlassThicknessSetting(@"FolderIcon.GlassThickness", 90.0, 0.0, 160.0, 1),
        LGGlassDarkTintSetting(@"FolderIcon.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassLightTintSetting(@"FolderIcon.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"FolderIcon.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"FolderIcon.RefractiveIndex", 2.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"FolderIcon.RefractionScale", 2.0, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderIcon.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"FolderIcon.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.folder_open.title"), LGLocalized(@"prefs.section.folder_open.subtitle")),
        LGGlassEnabledSetting(@"FolderOpen.Enabled", YES),
        LGGlassBezelSetting(@"FolderOpen.BezelWidth", 38.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"FolderOpen.Blur", 15.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"FolderOpen.CornerRadius", 38.0, 0.0, 60.0, 1),
        LGGlassDarkTintSetting(@"FolderOpen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"FolderOpen.GlassThickness", 100.0, 0.0, 200.0, 1),
        LGGlassLightTintSetting(@"FolderOpen.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"FolderOpen.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"FolderOpen.RefractiveIndex", 4.0, 1.0, 5.0, 2),
        LGGlassRefractionSetting(@"FolderOpen.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderOpen.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"FolderOpen.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGAppIconItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.app_icons.title"), LGLocalized(@"prefs.section.app_icons.subtitle")),
        LGGlassEnabledSetting(@"AppIcons.Enabled", NO),
        LGGlassBezelSetting(@"AppIcons.BezelWidth", 14.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"AppIcons.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"AppIcons.CornerRadius", 13.5, 0.0, 24.0, 1),
        LGGlassThicknessSetting(@"AppIcons.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassDarkTintSetting(@"AppIcons.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassLightTintSetting(@"AppIcons.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"AppIcons.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"AppIcons.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppIcons.RefractionScale", 1.2, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppIcons.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppIcons.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGSearchPillItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.search_pill.title"), LGLocalized(@"prefs.section.search_pill.subtitle")),
        LGGlassEnabledSetting(@"SearchPill.Enabled", YES),
        LGGlassBezelSetting(@"SearchPill.BezelWidth", 8.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"SearchPill.Blur", 3.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"SearchPill.CornerRadius", 15.0, 0.0, 30.0, 1),
        LGGlassThicknessSetting(@"SearchPill.GlassThickness", 120.0, 0.0, 200.0, 1),
        LGGlassDarkTintSetting(@"SearchPill.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassLightTintSetting(@"SearchPill.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"SearchPill.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"SearchPill.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"SearchPill.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"SearchPill.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"SearchPill.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGContextMenuItems(void) {
    return @[
        LGGlassEnabledSetting(@"ContextMenu.Enabled", YES),
        LGGlassBezelSetting(@"ContextMenu.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"ContextMenu.Blur", 10.0, 0.0, 25.0, 1),
        LGGlassCornerRadiusSetting(@"ContextMenu.CornerRadius", 22.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"ContextMenu.DarkTintAlpha", 0.6, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"ContextMenu.GlassThickness", 100.0, 0.0, 200.0, 1),
        LGSliderSetting(@"ContextMenu.IconSpacing", LGLocalized(@"prefs.control.icon_spacing"), LGLocalized(@"prefs.subtitle.icon_spacing"), 12.0, 0.0, 24.0, 1),
        LGGlassLightTintSetting(@"ContextMenu.LightTintAlpha", 0.8, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"ContextMenu.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"ContextMenu.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"ContextMenu.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGSliderSetting(@"ContextMenu.RowInset", LGLocalized(@"prefs.control.row_inset"), LGLocalized(@"prefs.subtitle.row_inset"), 16.0, 0.0, 30.0, 1),
        LGGlassSpecularSetting(@"ContextMenu.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"ContextMenu.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGLockscreenItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        LGScopedFPSSliderSetting(@"Lockscreen.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_notifications.title"), LGLocalized(@"prefs.section.lockscreen_notifications.subtitle")),
        LGGlassEnabledSetting(@"Lockscreen.Enabled", YES),
        LGGlassBezelSetting(@"Lockscreen.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"Lockscreen.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"Lockscreen.CornerRadius", 18.5, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"Lockscreen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"Lockscreen.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"Lockscreen.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"Lockscreen.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"Lockscreen.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Lockscreen.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"Lockscreen.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Lockscreen.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_quick_actions.title"), LGLocalized(@"prefs.section.lockscreen_quick_actions.subtitle")),
        LGGlassEnabledSetting(@"LockscreenQuickActions.Enabled", YES),
        LGGlassBezelSetting(@"LockscreenQuickActions.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"LockscreenQuickActions.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"LockscreenQuickActions.CornerRadius", 25.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"LockscreenQuickActions.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"LockscreenQuickActions.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"LockscreenQuickActions.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"LockscreenQuickActions.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"LockscreenQuickActions.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"LockscreenQuickActions.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"LockscreenQuickActions.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"LockscreenQuickActions.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_passcode.title"), LGLocalized(@"prefs.section.lockscreen_passcode.subtitle")),
        LGGlassEnabledSetting(@"Lockscreen.Passcode.Enabled", YES),
        LGGlassBezelSetting(@"Lockscreen.Passcode.BezelWidth", 30.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"Lockscreen.Passcode.Blur", 3.0, 0.0, 20.0, 1),
        LGGlassThicknessSetting(@"Lockscreen.Passcode.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassDarkTintSetting(@"Lockscreen.Passcode.DarkTintAlpha", 0.12, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"Lockscreen.Passcode.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"Lockscreen.Passcode.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Lockscreen.Passcode.RefractionScale", 1.0, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Lockscreen.Passcode.SpecularOpacity", 0.6, 0.0, 1.5, 2),
        LGGlassQualitySetting(@"Lockscreen.Passcode.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSliderSetting(@"Lockscreen.Passcode.BackgroundDarkTintAlpha",
                        LGLocalized(@"prefs.control.background_dark_tint_alpha"),
                        LGLocalized(@"prefs.subtitle.background_dark_tint_alpha"),
                        0.2,
                        0.0,
                        1.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ActiveScale",
                        LGLocalized(@"prefs.control.active_scale"),
                        LGLocalized(@"prefs.subtitle.active_scale"),
                        1.16,
                        1.0,
                        1.4,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ActiveLightTintAlpha",
                        LGLocalized(@"prefs.control.active_light_tint_alpha"),
                        LGLocalized(@"prefs.subtitle.active_light_tint_alpha"),
                        0.44,
                        0.0,
                        1.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.PressInMass",
                        LGLocalized(@"prefs.control.press_in_mass"),
                        LGLocalized(@"prefs.subtitle.press_in_mass"),
                        0.8,
                        0.1,
                        5.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.PressInStiffness",
                        LGLocalized(@"prefs.control.press_in_stiffness"),
                        LGLocalized(@"prefs.subtitle.press_in_stiffness"),
                        300.0,
                        1.0,
                        1000.0,
                        1),
        LGSliderSetting(@"Lockscreen.Passcode.PressInDamping",
                        LGLocalized(@"prefs.control.press_in_damping"),
                        LGLocalized(@"prefs.subtitle.press_in_damping"),
                        18.0,
                        0.0,
                        100.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.PressInVelocity",
                        LGLocalized(@"prefs.control.press_in_velocity"),
                        LGLocalized(@"prefs.subtitle.press_in_velocity"),
                        0.5,
                        0.0,
                        5.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.PressInDuration",
                        LGLocalized(@"prefs.control.press_in_duration"),
                        LGLocalized(@"prefs.subtitle.press_in_duration"),
                        0.3,
                        0.0,
                        2.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ReleaseMass",
                        LGLocalized(@"prefs.control.release_mass"),
                        LGLocalized(@"prefs.subtitle.release_mass"),
                        0.8,
                        0.1,
                        5.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ReleaseStiffness",
                        LGLocalized(@"prefs.control.release_stiffness"),
                        LGLocalized(@"prefs.subtitle.release_stiffness"),
                        300.0,
                        1.0,
                        1000.0,
                        1),
        LGSliderSetting(@"Lockscreen.Passcode.ReleaseDamping",
                        LGLocalized(@"prefs.control.release_damping"),
                        LGLocalized(@"prefs.subtitle.release_damping"),
                        12.0,
                        0.0,
                        100.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ReleaseVelocity",
                        LGLocalized(@"prefs.control.release_velocity"),
                        LGLocalized(@"prefs.subtitle.release_velocity"),
                        1.0,
                        0.0,
                        5.0,
                        2),
        LGSliderSetting(@"Lockscreen.Passcode.ReleaseDuration",
                        LGLocalized(@"prefs.control.release_duration"),
                        LGLocalized(@"prefs.subtitle.release_duration"),
                        0.5,
                        0.0,
                        2.0,
                        2),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_clock.title"), LGLocalized(@"prefs.section.lockscreen_clock.subtitle")),
        LGGlassEnabledSetting(@"Lockscreen.Clock.Enabled", YES),
    ]];

    [items addObject:LGGlassBezelSetting(@"Lockscreen.Clock.BezelWidth", 24.0, 0.0, 50.0, 1)];
    [items addObject:LGGlassBlurSetting(@"Lockscreen.Clock.Blur", 3.0, 0.0, 50.0, 1)];
    [items addObject:LGGlassLightTintSetting(@"Lockscreen.Clock.LightTintAlpha", 0.3, 0.0, 1.0, 2)];
    [items addObject:LGGlassDarkTintSetting(@"Lockscreen.Clock.DarkTintAlpha", 0.0, 0.0, 1.0, 2)];
    [items addObject:LGGlassCustomTintColorSetting(@"Lockscreen.Clock.CustomTintColor")];
    [items addObject:LGGlassThicknessSetting(@"Lockscreen.Clock.GlassThickness", 150.0, 0.0, 200.0, 1)];
    [items addObject:LGGlassRefractiveIndexSetting(@"Lockscreen.Clock.RefractiveIndex", 1.5, 0.0, 5.0, 2)];
    [items addObject:LGGlassRefractionSetting(@"Lockscreen.Clock.RefractionScale", 1.5, 0.0, 5.0, 2)];
    [items addObject:LGGlassSpecularSetting(@"Lockscreen.Clock.SpecularOpacity", 0.6, 0.0, 1.0, 2)];
    [items addObject:LGGlassQualitySetting(@"Lockscreen.Clock.WallpaperScale", 1.0, 0.1, 1.0, 2)];
    [items addObject:LGSliderSetting(@"Lockscreen.Clock.VerticalOffset",
                                     LGLocalized(@"prefs.control.clock_vertical_offset"),
                                     LGLocalized(@"prefs.subtitle.clock_vertical_offset"),
                                     0.0,
                                     0.0,
                                     120.0,
                                     1)];
    [items addObject:LGSliderSetting(@"Lockscreen.Clock.DateVerticalOffset",
                                     LGLocalized(@"prefs.control.date_vertical_offset"),
                                     LGLocalized(@"prefs.subtitle.date_vertical_offset"),
                                     0.0,
                                     0.0,
                                     120.0,
                                     1)];
    [items addObject:LGSpacerSetting(8.0, 0.0)];
    if (LGIsAtLeastiOS16()) {
        [items addObject:LGSettingControlledByKey(LGSwitchSetting(@"Lockscreen.Clock.VariableFont.Enabled",
                                                                  LGLocalized(@"prefs.control.variable_font"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font"),
                                                                  YES),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
        [items addObject:LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Weight",
                                                                  LGLocalized(@"prefs.control.variable_font_weight"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font_weight"),
                                                                  750.0,
                                                                  1.0,
                                                                  1000.0,
                                                                  0),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
        [items addObject:LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.SizeScale",
                                                                  LGLocalized(@"prefs.control.variable_font_size"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font_size"),
                                                                  1.4,
                                                                  0.8,
                                                                  2.0,
                                                                  2),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
        [items addObject:LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Width",
                                                                  LGLocalized(@"prefs.control.variable_font_width"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font_width"),
                                                                  100.0,
                                                                  60.0,
                                                                  100.0,
                                                                  0),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
        [items addObject:LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Height",
                                                                  LGLocalized(@"prefs.control.variable_font_height"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font_height"),
                                                                  350.0,
                                                                  100.0,
                                                                  500.0,
                                                                  0),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
        [items addObject:LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Softness",
                                                                  LGLocalized(@"prefs.control.variable_font_softness"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font_softness"),
                                                                  56.0,
                                                                  0.0,
                                                                  100.0,
                                                                  0),
                                                 @"Lockscreen.Clock.Enabled",
                                                 @YES)];
    }

    if (!LGIsAtLeastiOS16()) {
        NSMutableDictionary *legacyFontStyleItem = [LGSettingControlledByKey(LGMenuSetting(@"Lockscreen.Clock.LegacyFontStyle",
                                                                                            LGLocalized(@"prefs.control.font_style"),
                                                                                            LGLocalized(@"prefs.subtitle.font_style"),
                                                                                            @"current",
                                                                                            @[
                                                                                                @{@"value": @"current", @"title": LGLocalized(@"prefs.font_style.current.title")},
                                                                                                @{@"value": @"rounded", @"title": LGLocalized(@"prefs.font_style.rounded.title")},
                                                                                                @{@"value": @"ios26", @"title": LGLocalized(@"prefs.control.variable_font")}
                                                                                            ]),
                                                             @"Lockscreen.Clock.Enabled",
                                                             @YES) mutableCopy];
        legacyFontStyleItem[@"reload_on_change"] = @YES;
        [items addObject:[legacyFontStyleItem copy]];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.LegacyFontWeight",
                                                                                                LGLocalized(@"prefs.control.font_weight"),
                                                                                                LGLocalized(@"prefs.subtitle.font_weight"),
                                                                                                UIFontWeightHeavy,
                                                                                                0.0,
                                                                                                1.0,
                                                                                                2),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"current", @"rounded"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.LegacySizeBoost",
                                                                                                LGLocalized(@"prefs.control.size_boost"),
                                                                                                LGLocalized(@"prefs.subtitle.size_boost"),
                                                                                                1.05,
                                                                                                0.8,
                                                                                                1.3,
                                                                                                2),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"current", @"rounded"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.LegacyEmbolden",
                                                                                                LGLocalized(@"prefs.control.embolden"),
                                                                                                LGLocalized(@"prefs.subtitle.embolden"),
                                                                                                0.35,
                                                                                                0.0,
                                                                                                1.0,
                                                                                                2),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"current", @"rounded"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Weight",
                                                                                                LGLocalized(@"prefs.control.variable_font_weight"),
                                                                                                LGLocalized(@"prefs.subtitle.variable_font_weight"),
                                                                                                750.0,
                                                                                                1.0,
                                                                                                1000.0,
                                                                                                0),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"ios26"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.SizeScale",
                                                                                                LGLocalized(@"prefs.control.variable_font_size"),
                                                                                                LGLocalized(@"prefs.subtitle.variable_font_size"),
                                                                                                1.4,
                                                                                                0.8,
                                                                                                2.0,
                                                                                                2),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"ios26"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Width",
                                                                                                LGLocalized(@"prefs.control.variable_font_width"),
                                                                                                LGLocalized(@"prefs.subtitle.variable_font_width"),
                                                                                                100.0,
                                                                                                60.0,
                                                                                                100.0,
                                                                                                0),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"ios26"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Height",
                                                                                                LGLocalized(@"prefs.control.variable_font_height"),
                                                                                                LGLocalized(@"prefs.subtitle.variable_font_height"),
                                                                                                350.0,
                                                                                                100.0,
                                                                                                500.0,
                                                                                                0),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                      @"Lockscreen.Clock.LegacyFontStyle",
                                                      @"current",
                                                      @[@"ios26"])];
        [items addObject:LGSettingVisibleForKeyValues(LGSettingControlledByKey(LGSliderSetting(@"Lockscreen.Clock.VariableFont.Softness",
                                                                                                LGLocalized(@"prefs.control.variable_font_softness"),
                                                                                                LGLocalized(@"prefs.subtitle.variable_font_softness"),
                                                                                                56.0,
                                                                                                0.0,
                                                                                                100.0,
                                                                                                0),
                                                                               @"Lockscreen.Clock.Enabled",
                                                                               @YES),
                                                     @"Lockscreen.Clock.LegacyFontStyle",
                                                     @"current",
                                                     @[@"ios26"])];
    }

    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_date_label.title"),
                                      LGLocalized(@"prefs.section.lockscreen_date_label.subtitle"))];
    NSMutableDictionary *dateFormatEnabled = [LGSwitchSetting(@"Lockscreen.Clock.DateFormat.Enabled",
                                                             LGLocalized(@"prefs.control.date_format_enabled"),
                                                             LGLocalized(@"prefs.subtitle.date_format_enabled"),
                                                             YES) mutableCopy];
    dateFormatEnabled[@"controls_following_panel"] = @YES;
    [items addObject:[dateFormatEnabled copy]];
    [items addObject:LGSettingControlledByKey(LGStringSetting(@"Lockscreen.Clock.DateFormat.Format",
                                                             LGLocalized(@"prefs.control.date_format"),
                                                             LGLocalized(@"prefs.subtitle.date_format"),
                                                             @"EEE MMM d",
                                                             @"EEE MMM d"),
                                             @"Lockscreen.Clock.DateFormat.Enabled",
                                             @YES)];

    return LGSurfaceItemsBySortingSectionGroups(items);
}

NSArray<NSDictionary *> *LGAppLibraryItems(void) {
    return LGSurfaceItemsBySortingSectionGroups(@[
        LGScopedFPSSliderSetting(@"AppLibrary.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.category_pods.title"), LGLocalized(@"prefs.section.category_pods.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Enabled", YES),
        LGGlassBlurSetting(@"AppLibrary.Blur", 25.0, 0.0, 40.0, 1),
        LGGlassBezelSetting(@"AppLibrary.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.CornerRadius", 20.2, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"AppLibrary.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"AppLibrary.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.WallpaperScale", 0.1, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.search_field.title"), LGLocalized(@"prefs.section.search_field.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Search.Enabled", YES),
        LGGlassBezelSetting(@"AppLibrary.SearchBezelWidth", 16.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"AppLibrary.SearchBlur", 25.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.SearchCornerRadius", 24.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.SearchDarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.SearchGlassThickness", 100.0, 0.0, 180.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.SearchLightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"AppLibrary.Search.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"AppLibrary.SearchRefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.SearchRefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SearchSpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.SearchWallpaperScale", 0.1, 0.1, 1.0, 2),
    ]);
}

NSArray<NSDictionary *> *LGWidgetItems(void) {
    return @[
        LGGlassEnabledSetting(@"Widgets.Enabled", NO),
        LGGlassBezelSetting(@"Widgets.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"Widgets.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"Widgets.CornerRadius", 20.2, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"Widgets.DarkTintAlpha", 0.3, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"Widgets.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassLightTintSetting(@"Widgets.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(@"Widgets.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"Widgets.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Widgets.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Widgets.SpecularOpacity", 0.6, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Widgets.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGHomescreenItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [items addObject:LGScopedFPSSliderSetting(@"Homescreen.FPS")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.dock.title"), LGLocalized(@"prefs.section.dock.subtitle"))];
    [items addObjectsFromArray:LGDockItems()];
    [items addObjectsFromArray:LGFolderItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.context_menu.title"), LGLocalized(@"prefs.section.context_menu.subtitle"))];
    [items addObjectsFromArray:LGContextMenuItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.banner.title"), LGLocalized(@"prefs.section.banner.subtitle"))];
    [items addObject:LGGlassEnabledSetting(@"Banner.Enabled", YES)];
    [items addObject:LGGlassBezelSetting(@"Banner.BezelWidth", LGBannerDefaultBezelWidth, 0.0, 50.0, 1)];
    [items addObject:LGGlassBlurSetting(@"Banner.Blur", LGBannerDefaultBlur, 0.0, 50.0, 1)];
    [items addObject:LGGlassCornerRadiusSetting(@"Banner.CornerRadius", LGBannerDefaultCornerRadius, 0.0, 100.0, 1)];
    [items addObject:LGGlassDarkTintSetting(@"Banner.DarkTintAlpha", LGBannerDefaultDarkTintAlpha, 0.0, 1.0, 2)];
    [items addObject:LGGlassThicknessSetting(@"Banner.GlassThickness", LGBannerDefaultGlassThickness, 0.0, 200.0, 1)];
    [items addObject:LGGlassLightTintSetting(@"Banner.LightTintAlpha", LGBannerDefaultLightTintAlpha, 0.0, 1.0, 2)];
    [items addObject:LGGlassCustomTintColorSetting(@"Banner.CustomTintColor")];
    [items addObject:LGGlassRefractiveIndexSetting(@"Banner.RefractiveIndex", LGBannerDefaultRefractiveIndex, 0.0, 5.0, 2)];
    [items addObject:LGGlassRefractionSetting(@"Banner.RefractionScale", LGBannerDefaultRefractionScale, 0.0, 5.0, 2)];
    [items addObject:LGGlassSpecularSetting(@"Banner.SpecularOpacity", LGBannerDefaultSpecularOpacity, 0.0, 1.0, 2)];
    [items addObjectsFromArray:LGSearchPillItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.widgets.title"), LGLocalized(@"prefs.section.widgets.subtitle"))];
    [items addObjectsFromArray:LGWidgetItems()];
    [items addObjectsFromArray:LGAppIconItems()];
    return LGSurfaceItemsBySortingSectionGroups(items);
}

NSArray<NSDictionary *> *LGAllSurfaceItems(void) {
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    [all addObject:LGSwitchSetting(@"Global.Enabled", LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.global_enabled"), NO)];
    [all addObjectsFromArray:LGHomescreenItems()];
    [all addObjectsFromArray:LGLockscreenItems()];
    [all addObjectsFromArray:LGAppLibraryItems()];
    return [all copy];
}

NSArray<NSDictionary *> *LGExperimentalItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.misc.custom_views.title"),
                         LGLocalized(@"prefs.misc.custom_views.subtitle")),
        LGNavSetting(LGLocalized(@"prefs.misc.custom_views.title"),
                     LGLocalized(@"prefs.misc.custom_views.subtitle"),
                     @"openCustomViewInjection"),
        LGSectionSetting(@"", @""),
        LGSectionSetting(LGLocalized(@"prefs.section.control_center.title"),
                         LGLocalized(@"prefs.section.control_center.subtitle")),
        LGGlassEnabledSetting(@"ControlCenter.Enabled", YES),
        LGGlassBezelSetting(@"ControlCenter.BezelWidth", 18.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"ControlCenter.Blur", 10.0, 0.0, 50.0, 1),
        LGGlassThicknessSetting(@"ControlCenter.GlassThickness", 120.0, 0.0, 200.0, 1),
        LGGlassCustomTintColorSetting(@"ControlCenter.CustomTintColor"),
        LGGlassRefractiveIndexSetting(@"ControlCenter.RefractiveIndex", 1.2, 0.0, 5.0, 2),
        LGGlassRefractionSetting(@"ControlCenter.RefractionScale", 1.35, 0.0, 5.0, 2),
        LGGlassSpecularSetting(@"ControlCenter.SpecularOpacity", 0.55, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"ControlCenter.WallpaperScale", 0.25, 0.1, 1.0, 2),
        LGSliderSetting(@"ControlCenter.LiveCaptureBudget",
                        LGLocalized(@"prefs.control_center.live_capture_budget.title"),
                        LGLocalized(@"prefs.control_center.live_capture_budget.subtitle"),
                        2.0,
                        1.0,
                        4.0,
                        0),
        LGSliderSetting(@"ControlCenter.FullscreenBackdropBlurRadius",
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.title"),
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.subtitle"),
                        8.0,
                        0.0,
                        30.0,
                        1),
        LGSectionSetting(LGLocalized(@"prefs.section.motion_highlights.title"),
                         LGLocalized(@"prefs.section.motion_highlights.subtitle")),
        LGSwitchSetting(@"Specular.Motion.Enabled",
                        LGLocalized(@"prefs.control.motion_highlights"),
                        LGLocalized(@"prefs.subtitle.motion_highlights"),
                        NO),
        LGSliderSetting(@"Specular.Motion.FPS",
                        LGLocalized(@"prefs.control.motion_highlights_fps"),
                        LGLocalized(@"prefs.subtitle.motion_highlights_fps"),
                        30.0,
                        1.0,
                        60.0,
                        0),
        LGSliderSetting(@"Specular.Motion.Sensitivity",
                        LGLocalized(@"prefs.control.motion_highlights_sensitivity"),
                        LGLocalized(@"prefs.subtitle.motion_highlights_sensitivity"),
                        1.5,
                        0.0,
                        8.0,
                        2),
        LGSectionSetting(LGLocalized(@"prefs.section.experimental_rendering.title"),
                         LGLocalized(@"prefs.section.experimental_rendering.subtitle")),
        LGNavSetting(LGLocalized(@"prefs.misc.live_capture.title"),
                     LGLocalized(@"prefs.misc.live_capture.subtitle"),
                     @"openLiveCaptureConfiguration"),
        LGSpacerSetting(8.0, 0.0),
        LGMenuSetting(@"Dock.RenderingMode",
                      LGLocalized(@"prefs.section.dock.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"FolderIcon.RenderingMode",
                      LGLocalized(@"prefs.section.folder_icons.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"FolderOpen.RenderingMode",
                      LGLocalized(@"prefs.section.folder_open.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"AppIcons.RenderingMode",
                      LGLocalized(@"prefs.section.app_icons.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"ContextMenu.RenderingMode",
                      LGLocalized(@"prefs.section.context_menu.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"Banner.RenderingMode",
                      LGLocalized(@"prefs.section.banner.title"),
                      @"",
                      LGRenderingModeLiveCapture,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"ControlCenter.RenderingMode",
                      LGLocalized(@"prefs.section.control_center.title"),
                      @"",
                      LGRenderingModeLiveCapture,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"SearchPill.RenderingMode",
                      LGLocalized(@"prefs.section.search_pill.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"Widgets.RenderingMode",
                      LGLocalized(@"prefs.section.widgets.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"Lockscreen.RenderingMode",
                      LGLocalized(@"prefs.section.lockscreen_notifications.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"Lockscreen.Passcode.RenderingMode",
                      LGLocalized(@"prefs.section.lockscreen_passcode.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"Lockscreen.Clock.RenderingMode",
                      LGLocalized(@"prefs.section.lockscreen_clock.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"LockscreenQuickActions.RenderingMode",
                      LGLocalized(@"prefs.section.lockscreen_quick_actions.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"AppLibrary.RenderingMode",
                      LGLocalized(@"prefs.section.category_pods.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
        LGMenuSetting(@"AppLibrary.Search.RenderingMode",
                      LGLocalized(@"prefs.section.search_field.title"),
                      @"",
                      LGRenderingModeSnapshot,
                      @[
                          @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                          @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                      ]),
    ];
}

static NSString *LGCustomViewRulePrefix(NSString *ruleID) {
    if (![ruleID isKindOfClass:NSString.class] || !ruleID.length) return nil;
    return [@"CustomViews.Rule." stringByAppendingString:ruleID];
}

static NSDictionary *LGLiveCaptureFPSSlider(NSString *key, NSString *title, CGFloat fallback);

NSArray<NSString *> *LGCustomViewRuleIDs(void) {
    id stored = LGReadPreferenceObject(@"CustomViews.RuleIDs", @[]);
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id value in (NSArray *)stored) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length && ![ids containsObject:trimmed]) [ids addObject:trimmed];
    }
    return [ids copy];
}

static void LGSetCustomViewRuleIDs(NSArray<NSString *> *ruleIDs) {
    LGWritePreferenceObject(@"CustomViews.RuleIDs", ruleIDs ?: @[]);
}

NSString *LGCreateCustomViewRule(void) {
    NSString *ruleID = [NSUUID UUID].UUIDString.lowercaseString;
    NSMutableArray<NSString *> *ids = [LGCustomViewRuleIDs() mutableCopy] ?: [NSMutableArray array];
    [ids addObject:ruleID];
    LGSetCustomViewRuleIDs(ids);

    NSString *prefix = LGCustomViewRulePrefix(ruleID);
    LGWritePreferenceObject([prefix stringByAppendingString:@".Enabled"], @YES);
    LGWritePreferenceObject([prefix stringByAppendingString:@".Name"], [NSString stringWithFormat:LGLocalized(@"prefs.custom_views.rule_format"), (long)ids.count]);
    LGWritePreferenceObject([prefix stringByAppendingString:@".RenderingMode"], LGRenderingModeLiveCapture);
    return ruleID;
}

static NSArray<NSString *> *LGCustomViewRulePreferenceKeys(NSString *ruleID) {
    NSString *prefix = LGCustomViewRulePrefix(ruleID);
    if (!prefix.length) return @[];
    return @[
        [prefix stringByAppendingString:@".Name"],
        [prefix stringByAppendingString:@".Enabled"],
        [prefix stringByAppendingString:@".TargetClass"],
        [prefix stringByAppendingString:@".ParentClass"],
        [prefix stringByAppendingString:@".GrandparentClass"],
        [prefix stringByAppendingString:@".AncestorClass"],
        [prefix stringByAppendingString:@".ChildClass"],
        [prefix stringByAppendingString:@".GrandchildClass"],
        [prefix stringByAppendingString:@".DescendantClass"],
        [prefix stringByAppendingString:@".SiblingClass"],
        [prefix stringByAppendingString:@".ClearBackground"],
        [prefix stringByAppendingString:@".RenderingMode"],
        [prefix stringByAppendingString:@".LiveCaptureFPS"],
        [prefix stringByAppendingString:@".TintOverrideMode"],
        [prefix stringByAppendingString:@".BezelWidth"],
        [prefix stringByAppendingString:@".Blur"],
        [prefix stringByAppendingString:@".CornerRadius"],
        [prefix stringByAppendingString:@".GlassThickness"],
        [prefix stringByAppendingString:@".LightTintAlpha"],
        [prefix stringByAppendingString:@".DarkTintAlpha"],
        [prefix stringByAppendingString:@".CustomTintColor"],
        [prefix stringByAppendingString:@".RefractiveIndex"],
        [prefix stringByAppendingString:@".RefractionScale"],
        [prefix stringByAppendingString:@".SpecularOpacity"],
        [prefix stringByAppendingString:@".WallpaperScale"],
    ];
}

NSArray<NSString *> *LGAllCustomViewPreferenceKeys(void) {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:@"CustomViews.RuleIDs"];
    for (NSString *ruleID in LGCustomViewRuleIDs()) {
        [keys addObjectsFromArray:LGCustomViewRulePreferenceKeys(ruleID)];
    }
    return [keys copy];
}

void LGDeleteCustomViewRule(NSString *ruleID) {
    if (![ruleID isKindOfClass:NSString.class] || !ruleID.length) return;
    NSMutableArray<NSString *> *ids = [LGCustomViewRuleIDs() mutableCopy] ?: [NSMutableArray array];
    [ids removeObject:ruleID];
    LGSetCustomViewRuleIDs(ids);
    for (NSString *key in LGCustomViewRulePreferenceKeys(ruleID)) {
        LGRemovePreference(key);
    }
}

static NSDictionary *LGCustomViewRuleNavSetting(NSString *ruleID, NSUInteger index) {
    NSString *prefix = LGCustomViewRulePrefix(ruleID);
    NSString *name = LGReadPreferenceObject([prefix stringByAppendingString:@".Name"], @"");
    NSString *target = LGReadPreferenceObject([prefix stringByAppendingString:@".TargetClass"], @"");
    NSString *title = [name isKindOfClass:NSString.class] && name.length
        ? name
        : [NSString stringWithFormat:LGLocalized(@"prefs.custom_views.rule_format"), (long)index + 1];
    NSString *subtitle = [target isKindOfClass:NSString.class] && target.length
        ? target
        : LGLocalized(@"prefs.custom_views.rule_empty.subtitle");
    return @{
        @"type": @"nav",
        @"title": title,
        @"subtitle": subtitle,
        @"action": @"openCustomViewRule:",
        @"rule_id": ruleID ?: @""
    };
}

static NSDictionary *LGCustomViewAddRuleSetting(void) {
    return @{
        @"type": @"nav",
        @"title": LGLocalized(@"prefs.custom_views.add_rule.title"),
        @"subtitle": LGLocalized(@"prefs.custom_views.add_rule.subtitle"),
        @"action": @"addCustomViewRule:"
    };
}

static NSDictionary *LGCustomViewClassFiltersSetting(NSString *(^key)(NSString *suffix)) {
    NSMutableArray<NSDictionary *> *fields = [NSMutableArray array];
    void (^addField)(NSString *, NSString *, NSString *) = ^(NSString *suffix, NSString *titleKey, NSString *placeholder) {
        [fields addObject:@{
            @"key": key(suffix),
            @"title": LGLocalized(titleKey),
            @"placeholder": placeholder ?: @"",
        }];
    };
    addField(@"TargetClass", @"prefs.custom_views.target_class.title", @"MTMaterialView");
    addField(@"ParentClass", @"prefs.custom_views.parent_class.title", @"");
    addField(@"GrandparentClass", @"prefs.custom_views.grandparent_class.title", @"");
    addField(@"AncestorClass", @"prefs.custom_views.ancestor_class.title", @"");
    addField(@"ChildClass", @"prefs.custom_views.child_class.title", @"");
    addField(@"GrandchildClass", @"prefs.custom_views.grandchild_class.title", @"");
    addField(@"DescendantClass", @"prefs.custom_views.descendant_class.title", @"");
    addField(@"SiblingClass", @"prefs.custom_views.sibling_class.title", @"");

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        NSString *fieldKey = field[@"key"];
        if (fieldKey.length) [keys addObject:fieldKey];
    }
    return @{
        @"type": @"custom_class_filters",
        @"title": LGLocalized(@"prefs.custom_views.class_filters.title"),
        @"subtitle": LGLocalized(@"prefs.custom_views.class_filters.subtitle"),
        @"fields": fields,
        @"keys": keys,
    };
}

NSArray<NSDictionary *> *LGCustomViewRuleItems(NSString *ruleID) {
    NSString *prefix = LGCustomViewRulePrefix(ruleID);
    if (!prefix.length) return @[];
    NSString *(^key)(NSString *) = ^NSString *(NSString *suffix) {
        return [NSString stringWithFormat:@"%@.%@", prefix, suffix];
    };
    return @[
        LGSectionSetting(LGLocalized(@"prefs.custom_views.rule_details.title"),
                         LGLocalized(@"prefs.custom_views.rule.subtitle")),
        LGStringSetting(key(@"Name"),
                        LGLocalized(@"prefs.custom_views.rule_name.title"),
                        LGLocalized(@"prefs.custom_views.rule_name.subtitle"),
                        @"",
                        LGLocalized(@"prefs.custom_views.rule_name.placeholder")),
        LGSwitchSetting(key(@"Enabled"),
                        LGLocalized(@"prefs.control.enabled"),
                        LGLocalized(@"prefs.custom_views.rule_enabled.subtitle"),
                        NO),
        LGCustomViewClassFiltersSetting(key),
        LGSectionSetting(@"", @""),
        LGSectionSetting(LGLocalized(@"prefs.custom_views.appearance.title"),
                         LGLocalized(@"prefs.custom_views.appearance.subtitle")),
        LGSwitchSetting(key(@"ClearBackground"),
                        LGLocalized(@"prefs.custom_views.clear_background.title"),
                        LGLocalized(@"prefs.custom_views.clear_background.subtitle"),
                        YES),
        LGGlassRenderingModeSettingWithFallback(key(@"RenderingMode"), LGRenderingModeLiveCapture),
        LGLiveCaptureFPSSlider(key(@"LiveCaptureFPS"), LGLocalized(@"prefs.control.fps_limit"), 20.0),
        LGGlassTintOverrideSetting(key(@"TintOverrideMode"), LGLocalized(@"prefs.control.tint_override")),
        LGGlassBezelSetting(key(@"BezelWidth"), 16.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(key(@"Blur"), 8.0, 0.0, 30.0, 1),
        LGGlassCornerRadiusSetting(key(@"CornerRadius"), 18.0, 0.0, 80.0, 1),
        LGGlassThicknessSetting(key(@"GlassThickness"), 100.0, 0.0, 200.0, 1),
        LGGlassLightTintSetting(key(@"LightTintAlpha"), 0.1, 0.0, 1.0, 2),
        LGGlassDarkTintSetting(key(@"DarkTintAlpha"), 0.0, 0.0, 1.0, 2),
        LGGlassCustomTintColorSetting(key(@"CustomTintColor")),
        LGGlassRefractiveIndexSetting(key(@"RefractiveIndex"), 1.5, 1.0, 5.0, 2),
        LGGlassRefractionSetting(key(@"RefractionScale"), 1.5, 0.5, 5.0, 2),
        LGGlassSpecularSetting(key(@"SpecularOpacity"), 0.5, 0.0, 1.0, 2),
        LGGlassQualitySetting(key(@"WallpaperScale"), 0.25, 0.1, 1.0, 2),
        LGSectionSetting(@"", @""),
        LGNavSetting(LGLocalized(@"prefs.custom_views.delete_rule.title"),
                     LGLocalized(@"prefs.custom_views.delete_rule.subtitle"),
                     @"deleteCustomViewRule"),
    ];
}

NSArray<NSDictionary *> *LGCustomViewInjectionItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        LGSectionSetting(LGLocalized(@"prefs.custom_views.general.title"),
                         LGLocalized(@"prefs.custom_views.general.subtitle")),
        LGGlassEnabledSetting(@"CustomViews.Enabled", NO),
        LGSectionSetting(@"", @""),
        LGSectionSetting(LGLocalized(@"prefs.custom_views.rules.title"),
                         LGLocalized(@"prefs.custom_views.rules.subtitle")),
    ]];
    NSArray<NSString *> *ruleIDs = LGCustomViewRuleIDs();
    [items addObject:LGCustomViewAddRuleSetting()];
    for (NSUInteger i = 0; i < ruleIDs.count; i++) {
        [items addObject:LGCustomViewRuleNavSetting(ruleIDs[i], i)];
    }
    return [items copy];
}

static NSDictionary *LGLiveCaptureFPSSlider(NSString *key, NSString *title, CGFloat fallback) {
    return LGSliderSetting(key,
                           title ?: @"",
                           LGLocalized(@"prefs.live_capture.fps.subtitle"),
                           fallback,
                           1.0,
                           30.0,
                           0);
}

NSArray<NSDictionary *> *LGLiveCaptureItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.live_capture_general.title"),
                         LGLocalized(@"prefs.section.live_capture_general.subtitle")),
        LGSliderSetting(@"LiveCapture.ScaleFactor",
                        LGLocalized(@"prefs.live_capture.scale_factor.title"),
                        LGLocalized(@"prefs.live_capture.scale_factor.subtitle"),
                        0.35,
                        0.10,
                        1.00,
                        2),
        LGSliderSetting(@"LiveCapture.MinimumScale",
                        LGLocalized(@"prefs.live_capture.minimum_scale.title"),
                        LGLocalized(@"prefs.live_capture.minimum_scale.subtitle"),
                        0.55,
                        0.10,
                        2.00,
                        2),
        LGSliderSetting(@"LiveCapture.MaximumScale",
                        LGLocalized(@"prefs.live_capture.maximum_scale.title"),
                        LGLocalized(@"prefs.live_capture.maximum_scale.subtitle"),
                        1.00,
                        0.10,
                        3.00,
                        2),
        LGSliderSetting(@"LiveCapture.MaximumPixels",
                        LGLocalized(@"prefs.live_capture.maximum_pixels.title"),
                        LGLocalized(@"prefs.live_capture.maximum_pixels.subtitle"),
                        180000.0,
                        20000.0,
                        600000.0,
                        0),
        LGSectionSetting(LGLocalized(@"prefs.section.live_capture_fps.title"),
                         LGLocalized(@"prefs.section.live_capture_fps.subtitle")),
        LGLiveCaptureFPSSlider(@"Dock.LiveCaptureFPS", LGLocalized(@"prefs.section.dock.title"), 22.0),
        LGLiveCaptureFPSSlider(@"FolderOpen.LiveCaptureFPS", LGLocalized(@"prefs.section.folder_open.title"), 22.0),
        LGLiveCaptureFPSSlider(@"ContextMenu.LiveCaptureFPS", LGLocalized(@"prefs.section.context_menu.title"), 25.0),
        LGLiveCaptureFPSSlider(@"Banner.LiveCaptureFPS", LGLocalized(@"prefs.section.banner.title"), 25.0),
        LGLiveCaptureFPSSlider(@"Widgets.LiveCaptureFPS", LGLocalized(@"prefs.section.widgets.title"), 18.0),
        LGLiveCaptureFPSSlider(@"AppLibrary.LiveCaptureFPS", LGLocalized(@"prefs.surface.app_library.title"), 22.0),
        LGLiveCaptureFPSSlider(@"Lockscreen.LiveCaptureFPS", LGLocalized(@"prefs.surface.lockscreen.title"), 20.0),
        LGLiveCaptureFPSSlider(@"ControlCenter.LiveCaptureFPS", LGLocalized(@"prefs.section.control_center.title"), 22.0),
    ];
}

NSArray<NSDictionary *> *LGPrefsSettingsItems(void) {
    return @[
        LGMenuSetting(kLGPrefsLanguageKey,
                      LGLocalized(@"prefs.misc.language.title"),
                      @"",
                      @"en",
                      LGAvailableLanguageChoices()),
        LGSpacerSetting(2.0, 0.0),
        LGAboutContentSetting(),
    ];
}

NSArray<NSDictionary *> *LGPrefsControlsItems(void) {
    return @[
        LGSwitchSetting(@"Preferences.BackButton.Enabled",
                        LGLocalized(@"prefs.misc.preferences_back_button.title"),
                        LGLocalized(@"prefs.misc.preferences_back_button.subtitle"),
                        NO),
        LGGlassCustomTintColorSetting(@"Preferences.BackButton.CustomTintColor"),
        LGSwitchSetting(@"Preferences.GoToTop.Enabled",
                        LGLocalized(@"prefs.misc.preferences_go_to_top.title"),
                        LGLocalized(@"prefs.misc.preferences_go_to_top.subtitle"),
                        NO),
        LGGlassCustomTintColorSetting(@"Preferences.GoToTop.CustomTintColor"),
        LGSwitchSetting(@"Preferences.RespringBar.Enabled",
                        LGLocalized(@"prefs.misc.preferences_respring_bar.title"),
                        LGLocalized(@"prefs.misc.preferences_respring_bar.subtitle"),
                        NO),
        LGGlassCustomTintColorSetting(@"Preferences.RespringBar.CustomTintColor"),
    ];
}

NSArray<NSDictionary *> *LGMoreOptionsItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        LGSectionSetting(LGLocalized(@"prefs.section.surface_tint_override.title"),
                         LGLocalized(@"prefs.section.surface_tint_override.subtitle")),
        ({
            NSMutableDictionary *item = [LGSwitchSetting(@"Tint.Override.PerSurfaceEnabled",
                                                         LGLocalized(@"prefs.control.enabled"),
                                                         LGLocalized(@"prefs.misc.tint_override_per_surface.subtitle"),
                                                         NO) mutableCopy];
            item[@"controls_following_panel"] = @YES;
            [item copy];
        }),
    ]];

    if ([LGReadPreference(@"Tint.Override.PerSurfaceEnabled", @NO) boolValue]) {
        [items addObjectsFromArray:LGPerSurfaceTintOverrideItems()];
    }

    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.display_link_toggle.title"),
                                      LGLocalized(@"prefs.section.display_link_toggle.subtitle"))];
    [items addObject:({
        NSMutableDictionary *item = [LGSwitchSetting(@"DisplayLink.PerSurfaceEnabled",
                                                     LGLocalized(@"prefs.control.enabled"),
                                                     LGLocalized(@"prefs.misc.display_link_toggle.subtitle"),
                                                     NO) mutableCopy];
        item[@"controls_following_panel"] = @YES;
        [item copy];
    })];

    if ([LGReadPreference(@"DisplayLink.PerSurfaceEnabled", @NO) boolValue]) {
        [items addObjectsFromArray:LGPerSurfaceDisplayLinkItems()];
    }

    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.options_section.title"),
                                      LGLocalized(@"prefs.misc.options_section.subtitle"))];
    [items addObject:LGSwitchSetting(@"AppLibrary.CompositeSnapshot",
                                     LGLocalized(@"prefs.misc.app_library_composite.title"),
                                     LGLocalized(@"prefs.misc.app_library_composite.subtitle"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"SettingsControls.Enabled",
                        LGLocalized(@"prefs.misc.settings_controls.title"),
                        LGLocalized(@"prefs.misc.settings_controls.subtitle"),
                        YES),
        @"Global.Enabled",
        @NO)];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.section.preferences.title"),
                                  LGLocalized(@"prefs.section.preferences.subtitle"),
                                  @"openPreferencesControls")];
    [items addObject:LGKeyedNavSetting(@"RWB.ThirdPartyBundleIDs",
                                       LGLocalized(@"prefs.misc.rwb_third_party.title"),
                                       LGLocalized(@"prefs.misc.rwb_third_party.subtitle"),
                                       @"editThirdPartyAppRWB")];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.invalidate_caches.title"),
                                  LGLocalized(@"prefs.misc.invalidate_caches.subtitle"),
                                  @"invalidateSnapshotCaches")];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.experimental.title"),
                                  LGLocalized(@"prefs.misc.experimental.subtitle"),
                                  @"openExperimental")];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.debugging_section.title"),
                                      LGLocalized(@"prefs.misc.debugging_section.subtitle"))];
    [items addObject:LGSwitchSetting(@"DebugLogging.Enabled",
                                     LGLocalized(@"prefs.misc.debug_logging.title"),
                                     LGLocalized(@"prefs.misc.debug_logging.subtitle"),
                                     NO)];
    [items addObject:LGSwitchSetting(@"DebugProfiling.Enabled",
                                     LGLocalized(@"prefs.misc.debug_profiling.title"),
                                     LGLocalized(@"prefs.misc.debug_profiling.subtitle"),
                                     NO)];
    [items addObject:LGSwitchSetting(@"AllDayProfiling.Enabled",
                                     LGLocalized(@"prefs.misc.all_day_profiling.title"),
                                     LGLocalized(@"prefs.misc.all_day_profiling.subtitle"),
                                     NO)];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.import_export_section.title"),
                                      LGLocalized(@"prefs.misc.import_export_section.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.export_prefs.title"),
                                  LGLocalized(@"prefs.misc.export_prefs.subtitle"),
                                  @"exportPreferences")];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.import_prefs.title"),
                                  LGLocalized(@"prefs.misc.import_prefs.subtitle"),
                                  @"importPreferences")];

    return [items copy];
}

NSString *LGExportPreferencesJSONString(void) {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    for (NSString *key in LGExportablePreferenceKeys()) {
        id value = LGReadPreferenceObject(key, nil);
        if (!value) continue;
        preferences[key] = value;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"format"] = @"liquidass-prefs";
    payload[@"version"] = @"1";
    payload[@"preferences"] = preferences;
    NSString *languageCode = LGCurrentPrefsLanguageCode();
    if (languageCode.length) {
        payload[@"ui_language"] = languageCode;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

BOOL LGImportPreferencesJSONString(NSString *jsonString, NSError **error) {
    if (!jsonString.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }

    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSString *format = payload[@"format"];
    NSString *version = payload[@"version"];
    if (![format isKindOfClass:[NSString class]] ||
        ![format isEqualToString:@"liquidass-prefs"] ||
        ![version isKindOfClass:[NSString class]] ||
        ![version isEqualToString:@"1"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *preferences = payload[@"preferences"];
    if (![preferences isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:LGExportablePreferenceKeys()];
    __block NSUInteger importedCount = 0;
    [preferences enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]]) return;
        if (![allowedKeys containsObject:key] && ![(NSString *)key hasPrefix:@"CustomViews.Rule."]) return;
        if (!obj || obj == [NSNull null]) {
            LGRemovePreference(key);
        } else {
            LGWritePreferenceObject(key, obj);
        }
        importedCount += 1;
    }];

    NSString *languageCode = payload[@"ui_language"];
    if ([languageCode isKindOfClass:[NSString class]] && languageCode.length) {
        LGSetCurrentPrefsLanguageCode(languageCode);
    }

    LGFlushPreferencesSynchronize();
    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
    notify_post(LGPrefsChangedNotificationCString);

    if (importedCount == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }
    return YES;
}

void LGResetAllPreferences(void) {
    CFArrayRef allKeys = CFPreferencesCopyKeyList((__bridge CFStringRef)LGPrefsDomain,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost);
    NSArray *keys = CFBridgingRelease(allKeys);
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        LGRemovePreferenceWithoutNotify((NSString *)key);
    }
    LGFlushPreferencesSynchronize();
    [LGPrefsUIStateDefaults() removeObjectForKey:kLGPrefsLanguageKey];
    LGSynchronizeSurfaceStateDefaults();
    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
    notify_post(LGPrefsChangedNotificationCString);
}

void LGResetPreferencesForKeys(NSArray<NSString *> *keys) {
    if (![keys isKindOfClass:[NSArray class]] || keys.count == 0) return;

    NSMutableOrderedSet<NSString *> *uniqueKeys = [NSMutableOrderedSet orderedSet];
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if (![(NSString *)key length]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        [uniqueKeys addObject:(NSString *)key];
    }
    if (uniqueKeys.count == 0) return;

    for (NSString *key in uniqueKeys) {
        LGRemovePreferenceWithoutNotify(key);
    }

    LGFlushPreferencesSynchronize();
    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    notify_post(LGPrefsChangedNotificationCString);
}
