#import "LGSharedSupport.h"
#import "LGMetalShaderSource.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>

NSString * const LGPrefsDomain = @"dylv.liquidassprefs";
CFStringRef const LGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
CFStringRef const LGPrefsRespringNotification = CFSTR("dylv.liquidassprefs/Respring");
const char * const LGPrefsChangedNotificationCString = "dylv.liquidassprefs/Reload";
const char * const LGPrefsRespringNotificationCString = "dylv.liquidassprefs/Respring";
const CGFloat LGBannerDefaultCornerRadius = 18.5;
const CGFloat LGBannerDefaultBezelWidth = 18.0;
const CGFloat LGBannerDefaultBlur = 40.0;
const CGFloat LGBannerDefaultDarkTintAlpha = 0.5;
const CGFloat LGBannerDefaultGlassThickness = 150.0;
const CGFloat LGBannerDefaultLightTintAlpha = 0.8;
const CGFloat LGBannerDefaultRefractionScale = 1.5;
const CGFloat LGBannerDefaultRefractiveIndex = 4.0;
const CGFloat LGBannerDefaultSpecularOpacity = 0.6;
const CGFloat LGBannerDefaultWallpaperScale = 1.0;
NSString * const LGBannerWindowClassName = @"SBBannerWindow";
NSString * const LGBannerContentViewClassName = @"BNContentViewControllerView";
NSString * const LGBannerControllerClassName = @"BNContentViewController";
NSString * const LGBannerPresentableControllerClassName = @"SBNotificationPresentableViewController";
NSString * const LGAppLibrarySidebarMarkerClassName = @"_SBHLibraryFrozenSafeAreaInsetsView";
NSString * const LGRenderingModeSnapshot = @"snapshot";
NSString * const LGRenderingModeLiveCapture = @"live_capture";
NSString * const LGTintOverrideSystem = @"system";
NSString * const LGTintOverrideLight = @"light";
NSString * const LGTintOverrideDark = @"dark";
static NSString * const LGPrefsDidReloadInProcessNotification = @"dylv.liquidassprefs.InProcessReload";

static NSDictionary<NSString *, id> *sLGCachedPreferences = nil;
static os_unfair_lock sLGPrefsLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sLGPrefsSetupOnce;
static dispatch_queue_t sLGLogQueue;
static NSFileHandle *sLGLogHandle;
static NSString * const kLGDynamicDefaultPrefix = @"__dynamic_default.";
static void *kLGImageStableCacheKeyAssociation = &kLGImageStableCacheKeyAssociation;

static void LGCloseLogHandle(void) {
    if (!sLGLogHandle) return;
    if (@available(iOS 13.0, *)) {
        [sLGLogHandle closeAndReturnError:nil];
    } else {
        [sLGLogHandle closeFile];
    }
    sLGLogHandle = nil;
}

static void LGCloseLogHandleAtExit(void) {
    if (!sLGLogQueue) {
        LGCloseLogHandle();
        return;
    }
    dispatch_sync(sLGLogQueue, ^{
        LGCloseLogHandle();
    });
}

static NSString *LGLogFilePath(void) {
    static NSString *sPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sPath = @"/tmp/LiquidAss.log";
    });
    return sPath;
}

static void LGAppendLogLine(NSString *line) {
    NSString *path = LGLogFilePath();
    if (!path.length || !line.length) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGLogQueue = dispatch_queue_create("dylv.liquidass.logfile", DISPATCH_QUEUE_SERIAL);
        atexit(LGCloseLogHandleAtExit);
    });

    dispatch_async(sLGLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            NSError *createError = nil;
            [NSData.data writeToFile:path options:NSDataWritingAtomic error:&createError];
            if (createError) {
                NSLog(@"[LiquidAss] log file create failed %@", createError.localizedDescription ?: @"unknown");
                return;
            }
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length) {
            return;
        }

        if (!sLGLogHandle) {
            sLGLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (!sLGLogHandle) {
            NSLog(@"[LiquidAss] log file open failed %@", path);
            return;
        }

        NSError *handleError = nil;
        if (@available(iOS 13.0, *)) {
            [sLGLogHandle seekToEndReturningOffset:nil error:&handleError];
            if (!handleError) {
                [sLGLogHandle writeData:data error:&handleError];
            }
        } else {
            @try {
                [sLGLogHandle seekToEndOfFile];
                [sLGLogHandle writeData:data];
            } @catch (NSException *exception) {
                handleError = [NSError errorWithDomain:@"dylv.liquidass.logfile"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"NSFileHandle exception"}];
            }
        }

        if (handleError) {
            LGCloseLogHandle();
            NSLog(@"[LiquidAss] log file append failed %@", handleError.localizedDescription ?: @"unknown");
        }
    });
}

static NSDictionary<NSString *, id> *LGCopyPreferencesDictionary(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    CFDictionaryRef values = CFPreferencesCopyMultiple(NULL,
                                                       (__bridge CFStringRef)LGPrefsDomain,
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesAnyHost);
    NSDictionary *dictionary = CFBridgingRelease(values);
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return dictionary;
}

static NSString *LGDynamicDefaultKey(NSString *key) {
    if (!key.length) return nil;
    return [kLGDynamicDefaultPrefix stringByAppendingString:key];
}

static void LGPreferencesChanged(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGReloadPreferences();
        [[NSNotificationCenter defaultCenter] postNotificationName:LGPrefsDidReloadInProcessNotification object:nil];
    });
}

static void LGEnsurePreferenceCacheInitialized(void) {
    dispatch_once(&sLGPrefsSetupOnce, ^{
        LGReloadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LGPreferencesChanged,
                                        LGPrefsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

NSString *LGMainBundleIdentifier(void) {
    static NSString *bundleID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundleID = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
    });
    return bundleID;
}

BOOL LGIsSpringBoardProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.springboard"];
}

BOOL LGIsPreferencesProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.Preferences"];
}

BOOL LGIsAtLeastiOS16(void) {
    static BOOL cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return cached;
}

NSArray<UIWindow *> *LGApplicationWindows(UIApplication *app) {
    if (!app) return @[];

    if (@available(iOS 13.0, *)) {
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        return windows;
    }

    NSArray<UIWindow *> *windows = app.windows;
    return [windows isKindOfClass:[NSArray class]] ? windows : @[];
}

CGFloat LGEffectiveBannerBlur(CGFloat configuredBlur) {
    return fmin(80.0, fmax(0.0, configuredBlur) * 2.2);
}

void LGReloadPreferences(void) {
    NSDictionary<NSString *, id> *dictionary = LGCopyPreferencesDictionary();
    os_unfair_lock_lock(&sLGPrefsLock);
    sLGCachedPreferences = dictionary;
    os_unfair_lock_unlock(&sLGPrefsLock);
}

void LGObservePreferenceChanges(dispatch_block_t block) {
    if (!block) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:LGPrefsDidReloadInProcessNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        block();
    }];
}

static id LGPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key];
}

BOOL LGHasExplicitPreferenceValue(NSString *key) {
    if (!key.length) return NO;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key] != nil;
}

BOOL LG_prefBool(NSString *key, BOOL fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return fallback;
}

CGFloat LG_prefFloat(NSString *key, CGFloat fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return (CGFloat)[value doubleValue];
    return fallback;
}

NSInteger LG_prefInteger(NSString *key, NSInteger fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    return fallback;
}

NSString *LG_prefString(NSString *key, NSString *fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return fallback;
}

CGFloat LGDynamicDefaultFloat(NSString *key, CGFloat fallback) {
    NSString *dynamicKey = LGDynamicDefaultKey(key);
    if (!dynamicKey.length) return fallback;
    return LG_prefFloat(dynamicKey, fallback);
}

void LGCacheDynamicDefaultFloat(NSString *key, CGFloat value) {
    if (!key.length) return;
    if (!isfinite(value) || value <= 0.0) return;

    NSString *dynamicKey = LGDynamicDefaultKey(key);
    if (!dynamicKey.length) return;

    CGFloat existing = LG_prefFloat(dynamicKey, -1.0);
    if (fabs(existing - value) <= 0.01) return;

    CFPreferencesSetAppValue((__bridge CFStringRef)dynamicKey,
                             (__bridge CFPropertyListRef)@(value),
                             (__bridge CFStringRef)LGPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    LGReloadPreferences();
}

NSString *LGDefaultRenderingModeForKey(NSString *key) {
    if ([key isEqualToString:@"Banner.RenderingMode"]) {
        return LGRenderingModeLiveCapture;
    }
    return LGRenderingModeSnapshot;
}

BOOL LG_globalEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO);
}

BOOL LG_prefersLiveCapture(NSString *key) {
    return [LG_prefString(key, LGDefaultRenderingModeForKey(key)) isEqualToString:LGRenderingModeLiveCapture];
}

void LGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message]);
}

void LGDebugLog(NSString *format, ...) {
    if (!LG_prefBool(@"DebugLogging.Enabled", NO)) {
        (void)format;
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    LGLog(@"%@", message);
}

void LGAssertMainThread(void) {
    NSCAssert([NSThread isMainThread], @"liquidass main thread only");
}

CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return sColorSpace;
}

UIImage *LGNormalizedImageForUpload(UIImage *image) {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

NSNumber *LGTextureScaleKey(CGFloat scale) {
    NSInteger milli = (NSInteger)lrint(scale * 1000.0);
    return @(MAX(milli, 1));
}

NSNumber *LGBlurSettingKey(CGFloat blur) {
    NSInteger milli = (NSInteger)lrint(fmax(0.0, blur) * 1000.0);
    return @(MAX(milli, 0));
}

NSString *LGImageStableCacheKey(UIImage *image) {
    if (!image) return nil;
    return objc_getAssociatedObject(image, kLGImageStableCacheKeyAssociation);
}

void LGSetImageStableCacheKey(UIImage *image, NSString *cacheKey) {
    if (!image) return;
    objc_setAssociatedObject(image,
                             kLGImageStableCacheKeyAssociation,
                             [cacheKey copy],
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@implementation LGTextureCacheEntry
@end

@implementation LGBlurVariant
@end

@interface LGZeroCopyBridge ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
@end

@implementation LGZeroCopyBridge

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    CVMetalTextureCacheRef cache = NULL;
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache);
    if (status == kCVReturnSuccess) {
        _textureCache = cache;
    }
    return self;
}

- (void)dealloc {
    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (!_textureCache || !width || !height) return NO;

    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs,
                                          &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) return NO;

    CVMetalTextureRef cvTexture = NULL;
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _textureCache,
                                                       _pixelBuffer,
                                                       nil,
                                                       MTLPixelFormatBGRA8Unorm,
                                                       width,
                                                       height,
                                                       0,
                                                       &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return NO;
    _cvTexture = cvTexture;
    return YES;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer || !_textureCache || !_cvTexture) return nil;

    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t width = CVPixelBufferGetWidth(_pixelBuffer);
    size_t height = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);

    CGContextRef context = CGBitmapContextCreate(data,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 LGSharedRGBColorSpace(),
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!context) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
        return nil;
    }

    if (actions) actions(context);

    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}

- (size_t)bufferWidth {
    return _pixelBuffer ? CVPixelBufferGetWidth(_pixelBuffer) : 0;
}

- (size_t)bufferHeight {
    return _pixelBuffer ? CVPixelBufferGetHeight(_pixelBuffer) : 0;
}

@end

id<MTLLibrary> LGCreateGlassLibrary(id<MTLDevice> device, NSError **error) {
    if (!device) return nil;
    id<MTLLibrary> library = [device newLibraryWithSource:LGGlassMetalSource()
                                                  options:[MTLCompileOptions new]
                                                    error:error];
    return library;
}

id<MTLRenderPipelineState> LGCreateGlassRenderPipeline(id<MTLDevice> device,
                                                       id<MTLLibrary> library,
                                                       NSError **error) {
    if (!device || !library) return nil;
    id<MTLFunction> vertex = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"fragmentShader"];
    if (!vertex || !fragment) return nil;

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    color.blendingEnabled = YES;
    color.rgbBlendOperation = MTLBlendOperationAdd;
    color.alphaBlendOperation = MTLBlendOperationAdd;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return [device newRenderPipelineStateWithDescriptor:descriptor error:error];
}
