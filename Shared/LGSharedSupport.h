#pragma once

#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

FOUNDATION_EXPORT NSString * const LGPrefsDomain;
FOUNDATION_EXPORT CFStringRef const LGPrefsChangedNotification;
FOUNDATION_EXPORT CFStringRef const LGPrefsRespringNotification;
FOUNDATION_EXPORT const char * const LGPrefsChangedNotificationCString;
FOUNDATION_EXPORT const char * const LGPrefsRespringNotificationCString;

NSString *LGMainBundleIdentifier(void);
BOOL LGIsSpringBoardProcess(void);
BOOL LGIsPreferencesProcess(void);
BOOL LGIsAtLeastiOS16(void);
BOOL LGBackboardSafeModeActive(void);
void LGClearBackboardSafeMode(void);

NSString *LGRWBDefaultWidgetBundleIDsText(void);

#define LG_BOOL_PREF_FUNC(name, key, fallback) \
    static BOOL name(void) { return LG_prefBool(@key, fallback); }
#define LG_ENABLED_BOOL_PREF_FUNC(name, key, fallback) \
    static BOOL name(void) { return LG_globalEnabled() && LG_prefBool(@key, fallback); }
#define LG_FLOAT_PREF_FUNC(name, key, fallback) \
    static CGFloat name(void) { return LG_prefFloat(@key, fallback); }

FOUNDATION_EXPORT const CGFloat LGKeyboardDefaultCornerRadius;
FOUNDATION_EXPORT const CGFloat LGKeyboardDefaultOverhang;
FOUNDATION_EXPORT const CGFloat LGKeyboardDefaultKeyRadius;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultCornerRadius;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultBezelWidth;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultBlur;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultDarkTintAlpha;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultGlassThickness;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultLightTintAlpha;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultRefractionScale;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultRefractiveIndex;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultSpecularOpacity;
FOUNDATION_EXPORT const CGFloat LGBannerDefaultWallpaperScale;
FOUNDATION_EXPORT NSString * const LGBannerWindowClassName;
FOUNDATION_EXPORT NSString * const LGBannerContentViewClassName;
FOUNDATION_EXPORT NSString * const LGBannerControllerClassName;
FOUNDATION_EXPORT NSString * const LGBannerPresentableControllerClassName;
FOUNDATION_EXPORT NSString * const LGAppLibrarySidebarMarkerClassName;
FOUNDATION_EXPORT NSString * const LGTintOverrideSystem;
FOUNDATION_EXPORT NSString * const LGTintOverrideLight;
FOUNDATION_EXPORT NSString * const LGTintOverrideDark;

CGFloat LGEffectiveBannerBlur(CGFloat configuredBlur);

BOOL LG_prefBool(NSString *key, BOOL fallback);
CGFloat LG_prefFloat(NSString *key, CGFloat fallback);
NSInteger LG_prefInteger(NSString *key, NSInteger fallback);
NSString *LG_prefString(NSString *key, NSString *fallback);
BOOL LGHasExplicitPreferenceValue(NSString *key);
BOOL LG_globalEnabled(void);
void LGReloadPreferences(void);
void LGObservePreferenceChanges(dispatch_block_t block);

BOOL LGDebugLoggingEnabled(void);
void LGLog(NSString *format, ...);

CGColorSpaceRef LGSharedRGBColorSpace(void);
UIImage *LGNormalizedImageForUpload(UIImage *image);
NSNumber *LGTextureScaleKey(CGFloat scale);
NSNumber *LGBlurSettingKey(CGFloat blur);
NSString *LGImageStableCacheKey(UIImage *image);
void LGSetImageStableCacheKey(UIImage *image, NSString *cacheKey);
