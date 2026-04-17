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

static NSBundle *LGActiveLocalizationBundle(void) {
    NSString *languageCode = [LGStandardDefaults() stringForKey:kLGPrefsLanguageKey];
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

NSUserDefaults *LGStandardDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void LGSynchronizeSurfaceStateDefaults(void) {
    [LGStandardDefaults() synchronize];
}

NSString *LGLastSurfaceIdentifier(void) {
    return [LGStandardDefaults() stringForKey:kLGLastSurfaceKey];
}

void LGSetLastSurfaceIdentifier(NSString *identifier) {
    NSUserDefaults *defaults = LGStandardDefaults();
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
    NSString *languageCode = [LGStandardDefaults() stringForKey:kLGPrefsLanguageKey];
    return languageCode.length ? languageCode : @"en";
}

void LGSetCurrentPrefsLanguageCode(NSString *languageCode) {
    NSUserDefaults *defaults = LGStandardDefaults();
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
    return [key isEqualToString:@"Global.Enabled"] || [key hasSuffix:@".Enabled"];
}

BOOL LGNeedsRespring(void) {
    return [LGStandardDefaults() boolForKey:kLGNeedsRespringKey];
}

BOOL LGRespringBarDismissed(void) {
    return [LGStandardDefaults() boolForKey:kLGRespringBarDismissedKey];
}

void LGSetRespringBarDismissed(BOOL dismissed) {
    NSUserDefaults *defaults = LGStandardDefaults();
    [defaults setBool:dismissed forKey:kLGRespringBarDismissedKey];
    LGSynchronizeSurfaceStateDefaults();
}

void LGSetNeedsRespring(BOOL needsRespring) {
    NSUserDefaults *defaults = LGStandardDefaults();
    [defaults setBool:needsRespring forKey:kLGNeedsRespringKey];
    if (!needsRespring) {
        [defaults setBool:NO forKey:kLGRespringBarDismissedKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsRespringChangedNotification object:nil];
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
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    notify_post(LGPrefsChangedNotificationCString);
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

NSDictionary *LGNavSetting(NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @""
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

NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback) {
    NSMutableDictionary *item = [LGSwitchSetting(key,
                                                 LGLocalized(@"prefs.control.enabled"),
                                                 LGLocalized(@"prefs.subtitle.enabled"),
                                                 fallback) mutableCopy];
    item[@"controls_following_panel"] = @YES;
    return [item copy];
}

NSDictionary *LGGlassRenderingModeSetting(NSString *key) {
    return LGMenuSetting(key,
                         LGLocalized(@"prefs.control.rendering_method"),
                         LGLocalized(@"prefs.subtitle.rendering_method"),
                         LGRenderingModeSnapshot,
                         @[
                             @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                             @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                         ]);
}

NSDictionary *LGGlassRenderingModeSettingWithFallback(NSString *key, NSString *fallback) {
    return LGMenuSetting(key,
                         LGLocalized(@"prefs.control.rendering_method"),
                         LGLocalized(@"prefs.subtitle.rendering_method"),
                         fallback ?: LGRenderingModeSnapshot,
                         @[
                             @{@"value": LGRenderingModeSnapshot, @"title": LGLocalized(@"prefs.rendering.snapshot.title")},
                             @{@"value": LGRenderingModeLiveCapture, @"title": LGLocalized(@"prefs.rendering.live_capture.title")}
                         ]);
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
    return LGSliderSetting(key, LGLocalized(@"prefs.control.corner_radius"), LGLocalized(@"prefs.subtitle.corner_radius"), fallback, min, kLGUniversalCornerRadiusMax, decimals);
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
    return LGSliderSetting(key, LGLocalized(@"prefs.control.fps_limit"), subtitle, defaultFPS, 30.0, (CGFloat)maxFPS, 0);
}

NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals) {
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%ldf", (long)decimals], value];
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
        LGGlassRefractiveIndexSetting(@"Dock.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Dock.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Dock.SpecularOpacity", 0.5, 0.0, 1.0, 2),
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
        LGGlassRefractiveIndexSetting(@"FolderIcon.RefractiveIndex", 2.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"FolderIcon.RefractionScale", 2.0, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderIcon.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"FolderIcon.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.folder_open.title"), LGLocalized(@"prefs.section.folder_open.subtitle")),
        LGGlassEnabledSetting(@"FolderOpen.Enabled", YES),
        LGGlassBezelSetting(@"FolderOpen.BezelWidth", 24.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"FolderOpen.Blur", 25.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"FolderOpen.CornerRadius", 38.0, 0.0, 60.0, 1),
        LGGlassDarkTintSetting(@"FolderOpen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"FolderOpen.GlassThickness", 100.0, 0.0, 200.0, 1),
        LGGlassLightTintSetting(@"FolderOpen.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"FolderOpen.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"FolderOpen.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderOpen.SpecularOpacity", 0.8, 0.0, 1.0, 2),
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
        LGGlassRefractiveIndexSetting(@"AppIcons.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppIcons.RefractionScale", 1.2, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppIcons.SpecularOpacity", 0.8, 0.0, 1.0, 2),
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
        LGGlassRefractiveIndexSetting(@"SearchPill.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"SearchPill.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"SearchPill.SpecularOpacity", 0.8, 0.0, 1.0, 2),
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
        LGGlassRefractiveIndexSetting(@"ContextMenu.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"ContextMenu.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGSliderSetting(@"ContextMenu.RowInset", LGLocalized(@"prefs.control.row_inset"), LGLocalized(@"prefs.subtitle.row_inset"), 16.0, 0.0, 30.0, 1),
        LGGlassSpecularSetting(@"ContextMenu.SpecularOpacity", 1.0, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"ContextMenu.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGLockscreenItems(void) {
    return @[
        LGScopedFPSSliderSetting(@"Lockscreen.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_notifications.title"), LGLocalized(@"prefs.section.lockscreen_notifications.subtitle")),
        LGGlassEnabledSetting(@"Lockscreen.Enabled", YES),
        LGGlassBezelSetting(@"Lockscreen.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"Lockscreen.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"Lockscreen.CornerRadius", 18.5, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"Lockscreen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"Lockscreen.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"Lockscreen.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"Lockscreen.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Lockscreen.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"Lockscreen.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Lockscreen.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_quick_actions.title"), LGLocalized(@"prefs.section.lockscreen_quick_actions.subtitle")),
        LGGlassEnabledSetting(@"LockscreenQuickActions.Enabled", YES),
        LGGlassBezelSetting(@"LockscreenQuickActions.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"LockscreenQuickActions.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"LockscreenQuickActions.CornerRadius", 25.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"LockscreenQuickActions.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"LockscreenQuickActions.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"LockscreenQuickActions.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"LockscreenQuickActions.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"LockscreenQuickActions.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"LockscreenQuickActions.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"LockscreenQuickActions.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

NSArray<NSDictionary *> *LGAppLibraryItems(void) {
    return @[
        LGScopedFPSSliderSetting(@"AppLibrary.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.category_pods.title"), LGLocalized(@"prefs.section.category_pods.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Enabled", YES),
        LGGlassBlurSetting(@"AppLibrary.Blur", 25.0, 0.0, 40.0, 1),
        LGGlassBezelSetting(@"AppLibrary.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.CornerRadius", 20.2, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.LightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"AppLibrary.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.WallpaperScale", 0.1, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.search_field.title"), LGLocalized(@"prefs.section.search_field.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Search.Enabled", YES),
        LGGlassBezelSetting(@"AppLibrary.SearchBezelWidth", 16.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"AppLibrary.SearchBlur", 25.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.SearchCornerRadius", 24.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.SearchDarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.SearchGlassThickness", 100.0, 0.0, 180.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.SearchLightTintAlpha", 0.1, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"AppLibrary.SearchRefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.SearchRefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SearchSpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.SearchWallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
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
        LGGlassRefractiveIndexSetting(@"Widgets.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Widgets.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Widgets.SpecularOpacity", 0.8, 0.0, 1.0, 2),
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
    [items addObject:LGGlassRefractiveIndexSetting(@"Banner.RefractiveIndex", LGBannerDefaultRefractiveIndex, 0.0, 5.0, 2)];
    [items addObject:LGGlassRefractionSetting(@"Banner.RefractionScale", LGBannerDefaultRefractionScale, 0.0, 5.0, 2)];
    [items addObject:LGGlassSpecularSetting(@"Banner.SpecularOpacity", LGBannerDefaultSpecularOpacity, 0.0, 1.0, 2)];
    [items addObjectsFromArray:LGSearchPillItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.widgets.title"), LGLocalized(@"prefs.section.widgets.subtitle"))];
    [items addObjectsFromArray:LGWidgetItems()];
    [items addObjectsFromArray:LGAppIconItems()];
    return [items copy];
}

NSArray<NSDictionary *> *LGAllSurfaceItems(void) {
    static NSArray<NSDictionary *> *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
        [all addObject:LGSwitchSetting(@"Global.Enabled", LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.global_enabled"), NO)];
        [all addObjectsFromArray:LGHomescreenItems()];
        [all addObjectsFromArray:LGLockscreenItems()];
        [all addObjectsFromArray:LGAppLibraryItems()];
        items = [all copy];
    });
    return items;
}

NSArray<NSDictionary *> *LGExperimentalItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.experimental_rendering.title"),
                         LGLocalized(@"prefs.section.experimental_rendering.subtitle")),
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
        LGSectionSetting(LGLocalized(@"prefs.section.experimental_features.title"),
                         LGLocalized(@"prefs.section.experimental_features.subtitle")),
        LGSwitchSetting(@"Lockscreen.Clock.Enabled",
                        LGLocalized(@"prefs.misc.lockscreen_clock.title"),
                        LGLocalized(@"prefs.misc.lockscreen_clock.subtitle"),
                        NO),
        LGSwitchSetting(@"SettingsControls.Enabled",
                        LGLocalized(@"prefs.misc.settings_controls.title"),
                        LGLocalized(@"prefs.misc.settings_controls.subtitle"),
                        NO),
    ];
}

NSArray<NSDictionary *> *LGMoreOptionsItems(void) {
    return @[
        LGMenuSetting(kLGPrefsLanguageKey,
                      LGLocalized(@"prefs.misc.language.title"),
                      @"",
                      @"en",
                      LGAvailableLanguageChoices()),
        LGSectionSetting(LGLocalized(@"prefs.misc.options_section.title"),
                         LGLocalized(@"prefs.misc.options_section.subtitle")),
        LGSwitchSetting(@"AppLibrary.CompositeSnapshot",
                        LGLocalized(@"prefs.misc.app_library_composite.title"),
                        LGLocalized(@"prefs.misc.app_library_composite.subtitle"),
                        NO),
        LGSwitchSetting(@"DebugLogging.Enabled",
                        LGLocalized(@"prefs.misc.debug_logging.title"),
                        LGLocalized(@"prefs.misc.debug_logging.subtitle"),
                        NO),
        LGNavSetting(LGLocalized(@"prefs.misc.experimental.title"),
                     LGLocalized(@"prefs.misc.experimental.subtitle"),
                     @"openExperimental"),
    ];
}

void LGResetAllPreferences(void) {
    for (NSDictionary *item in LGAllSurfaceItems()) {
        NSString *key = item[@"key"];
        if (!key.length) continue;
        if ([key isEqualToString:@"Global.Enabled"]) continue;
        LGRemovePreference(key);
    }
    for (NSDictionary *item in LGMoreOptionsItems()) {
        NSString *key = item[@"key"];
        if (!key.length) continue;
        LGRemovePreference(key);
    }
    for (NSDictionary *item in LGExperimentalItems()) {
        NSString *key = item[@"key"];
        if (!key.length) continue;
        LGRemovePreference(key);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    [LGStandardDefaults() removeObjectForKey:kLGPrefsLanguageKey];
    LGSynchronizeSurfaceStateDefaults();
    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
    notify_post(LGPrefsChangedNotificationCString);
}
