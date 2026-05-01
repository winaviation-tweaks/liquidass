#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString * const kLGPrefsUIRefreshNotification;
FOUNDATION_EXPORT NSString * const kLGPrefsRespringChangedNotification;
FOUNDATION_EXPORT NSString * const kLGLastSurfaceKey;
FOUNDATION_EXPORT NSString * const kLGPrefsLanguageChangedNotification;
FOUNDATION_EXPORT NSString * const kLGPrefsLanguageKey;

Class LGPrefsSwitchClass(void);
Class LGPrefsSliderClass(void);

NSString *LGLocalized(NSString *key);
NSString *LGPrefsAppName(void);
NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals);
NSString *LGCurrentPrefsLanguageCode(void);
void LGSetCurrentPrefsLanguageCode(NSString *languageCode);

NSUserDefaults *LGPrefsUIStateDefaults(void);
void LGSynchronizeSurfaceStateDefaults(void);
NSString *LGLastSurfaceIdentifier(void);
void LGSetLastSurfaceIdentifier(NSString *identifier);
void LGClearLastSurfaceIdentifierIfMatching(NSString *identifier);
void LGObservePrefsNotifications(id target);

BOOL LGPreferenceRequiresRespring(NSString *key);
BOOL LGNeedsRespring(void);
BOOL LGRespringBarDismissed(void);
void LGSetRespringBarDismissed(BOOL dismissed);
void LGSetNeedsRespring(BOOL needsRespring);
void LGPostInvalidateSnapshotCachesNotification(void);
void LGForceSynchronizePreferences(void);

NSNumber *LGReadPreference(NSString *key, NSNumber *fallback);
void LGWritePreference(NSString *key, NSNumber *value);
void LGWritePreferenceAndMaybeRequireRespring(NSString *key, NSNumber *value);
id LGReadPreferenceObject(NSString *key, id fallback);
void LGWritePreferenceObject(NSString *key, id value);
void LGRemovePreference(NSString *key);

NSDictionary *LGSwitchSetting(NSString *key, NSString *title, NSString *subtitle, BOOL fallback);
NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle);
NSDictionary *LGNavSetting(NSString *title, NSString *subtitle, NSString *action);
NSDictionary *LGMenuSetting(NSString *key, NSString *title, NSString *subtitle, NSString *fallback, NSArray<NSDictionary *> *choices);
NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle,
                              CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback);
NSDictionary *LGGlassBezelSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassCornerRadiusSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassLightTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassDarkTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassTintOverrideSetting(NSString *key, NSString *title);
NSDictionary *LGGlassTintOverrideSettingWithFallback(NSString *key, NSString *title, NSString *fallback);
NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSDictionary *LGGlassQualitySetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
NSInteger LGMaximumSupportedFPS(void);
NSDictionary *LGScopedFPSSliderSetting(NSString *key);

NSArray<NSDictionary *> *LGDockItems(void);
NSArray<NSDictionary *> *LGFolderItems(void);
NSArray<NSDictionary *> *LGAppIconItems(void);
NSArray<NSDictionary *> *LGSearchPillItems(void);
NSArray<NSDictionary *> *LGContextMenuItems(void);
NSArray<NSDictionary *> *LGLockscreenItems(void);
NSArray<NSDictionary *> *LGAppLibraryItems(void);
NSArray<NSDictionary *> *LGWidgetItems(void);
NSArray<NSDictionary *> *LGHomescreenItems(void);
NSArray<NSDictionary *> *LGAllSurfaceItems(void);
NSArray<NSDictionary *> *LGExperimentalItems(void);
NSArray<NSDictionary *> *LGMoreOptionsItems(void);

NSString *LGExportPreferencesJSONString(void);
BOOL LGImportPreferencesJSONString(NSString *jsonString, NSError **error);

void LGResetAllPreferences(void);
void LGResetPreferencesForKeys(NSArray<NSString *> *keys);
CGFloat LGCornerRadiusDefaultForKey(NSString *key, CGFloat fallback);
