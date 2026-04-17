#pragma once

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

FOUNDATION_EXPORT NSString * const LGPrefsDomain;
FOUNDATION_EXPORT CFStringRef const LGPrefsChangedNotification;
FOUNDATION_EXPORT CFStringRef const LGPrefsRespringNotification;
FOUNDATION_EXPORT const char * const LGPrefsChangedNotificationCString;
FOUNDATION_EXPORT const char * const LGPrefsRespringNotificationCString;

NSString *LGMainBundleIdentifier(void);
BOOL LGIsSpringBoardProcess(void);
BOOL LGIsPreferencesProcess(void);
BOOL LGIsAtLeastiOS16(void);
NSArray<UIWindow *> *LGApplicationWindows(UIApplication *app);

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
FOUNDATION_EXPORT NSString * const LGRenderingModeSnapshot;
FOUNDATION_EXPORT NSString * const LGRenderingModeLiveCapture;
CGFloat LGEffectiveBannerBlur(CGFloat configuredBlur);

BOOL LG_prefBool(NSString *key, BOOL fallback);
CGFloat LG_prefFloat(NSString *key, CGFloat fallback);
NSInteger LG_prefInteger(NSString *key, NSInteger fallback);
NSString *LG_prefString(NSString *key, NSString *fallback);
NSString *LGDefaultRenderingModeForKey(NSString *key);
BOOL LG_globalEnabled(void);
BOOL LG_prefersLiveCapture(NSString *key);
void LGReloadPreferences(void);
void LGObservePreferenceChanges(dispatch_block_t block);

void LGLog(NSString *format, ...);
void LGDebugLog(NSString *format, ...);
void LGAssertMainThread(void);

CGColorSpaceRef LGSharedRGBColorSpace(void);
UIImage *LGNormalizedImageForUpload(UIImage *image);
NSNumber *LGTextureScaleKey(CGFloat scale);
NSNumber *LGBlurSettingKey(CGFloat blur);

@interface LGTextureCacheEntry : NSObject
@property (nonatomic, strong) id<MTLTexture> bgTexture;
@property (nonatomic, strong) id bridge;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *blurVariants;
@end

@interface LGBlurVariant : NSObject
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, assign) float bakedBlurRadius;
@end

@interface LGZeroCopyBridge : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions;
@end

id<MTLLibrary> LGCreateGlassLibrary(id<MTLDevice> device, NSError **error);
id<MTLRenderPipelineState> LGCreateGlassRenderPipeline(id<MTLDevice> device,
                                                       id<MTLLibrary> library,
                                                       NSError **error);
BOOL LGCreateGlassBlurPipelines(id<MTLDevice> device,
                                id<MTLLibrary> library,
                                id<MTLComputePipelineState> __strong *outHorizontal,
                                id<MTLComputePipelineState> __strong *outVertical,
                                NSError **error);
