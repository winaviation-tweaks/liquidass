#import "LGLiquidGlassRuntime.h"
#import "../Shared/LGBackButtonSupport.h"
#import "../Shared/LGGlassMaterialView.h"
#import "../Shared/LGSharedSupport.h"
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreVideo/CoreVideo.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <objc/runtime.h>
#include <stdatomic.h>

typedef struct {
    vector_float2 resolution;
    vector_float2 screenResolution;
    vector_float2 cardOrigin;
    vector_float2 wallpaperResolution;
    float radius;
    float bezelWidth;
    float glassThickness;
    float refractionScale;
    float refractiveIndex;
    float specularOpacity;
    float specularAngle;
    float blur;
    vector_float2 wallpaperOrigin;
    vector_float2 samplingTransformX;
    vector_float2 samplingTransformY;
    vector_float2 samplingTransformOffset;
    float samplingOrientation;
    float hasShapeMask;
} LGUniforms;

static CMMotionManager *sSpecularMotionManager = nil;
static NSOperationQueue *sSpecularMotionQueue = nil;
static CLLocationManager *sSpecularHeadingManager = nil;
static id sSpecularHeadingDelegate = nil;
static BOOL sSpecularMotionRunning = NO;
static CGFloat sSpecularMotionAngle = 0.0;
static CGFloat sSpecularMotionGyroOffset = 0.0;
static CGFloat sSpecularHeadingRadians = 0.0;
static CFTimeInterval sSpecularHeadingLastUpdate = 0.0;
static CFTimeInterval sSpecularMotionLastSampleTime = 0.0;
static CFTimeInterval sSpecularMotionLastRedraw = 0.0;
static CFTimeInterval sSpecularMotionLastDebugLog = 0.0;
static CFTimeInterval sSpecularMotionLastDrawDebugLog = 0.0;
static void *kLGStockBlurOriginalFiltersKey = &kLGStockBlurOriginalFiltersKey;
static void *kLGStockBlurOriginalBackgroundFiltersKey = &kLGStockBlurOriginalBackgroundFiltersKey;
static void *kLGStockBlurSuppressedKey = &kLGStockBlurSuppressedKey;

@interface LGSpecularHeadingDelegate : NSObject <CLLocationManagerDelegate>
@end

@implementation LGSpecularHeadingDelegate
- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    CLLocationDirection heading = newHeading.trueHeading >= 0.0 ? newHeading.trueHeading : newHeading.magneticHeading;
    if (heading < 0.0) return;
    sSpecularHeadingRadians = heading * (M_PI / 180.0);
    sSpecularHeadingLastUpdate = CACurrentMediaTime();
    if (manager.headingOrientation != CLDeviceOrientationUnknown) return;
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        orientation = UIApplication.sharedApplication.connectedScenes.anyObject
            ? ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).interfaceOrientation
            : UIInterfaceOrientationUnknown;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        orientation = UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
    }
    manager.headingOrientation = orientation;
}

- (BOOL)locationManagerShouldDisplayHeadingCalibration:(CLLocationManager *)manager {
    return NO;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    LGDebugLog(@"[SpecularMotion] heading error: %@ (code %ld)",
               error.localizedDescription, (long)error.code);
}
@end

static BOOL LGSpecularMotionEnabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"Specular.Motion.Enabled", NO);
}

static CGFloat LGSpecularMotionFPS(void) {
    return MAX(1.0, MIN(60.0, LG_prefFloat(@"Specular.Motion.FPS", 30.0)));
}

static CGFloat LGSpecularMotionSensitivity(void) {
    return MAX(0.0, MIN(8.0, LG_prefFloat(@"Specular.Motion.Sensitivity", 1.5)));
}

static CGFloat LGSpecularMotionCurrentAngle(void) {
    return LGSpecularMotionEnabled() ? sSpecularMotionAngle : 0.0;
}

CGFloat LG_currentSpecularMotionAngle(void) {
    return LGSpecularMotionCurrentAngle();
}


static void LGStockBlurSetLayerBackgroundFilters(CALayer *layer, id filters) {
    @try {
        [layer setValue:filters forKey:@"backgroundFilters"];
    } @catch (__unused NSException *exception) {
    }
}

static id LGStockBlurGetLayerBackgroundFilters(CALayer *layer) {
    @try {
        return [layer valueForKey:@"backgroundFilters"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void LGStockBlurSuppressLayerTree(CALayer *layer, CALayer *excludedLayer, BOOL suppressed) {
    if (!layer || layer == excludedLayer) return;

    if (suppressed) {
        if (!objc_getAssociatedObject(layer, kLGStockBlurSuppressedKey)) {
            objc_setAssociatedObject(layer,
                                     kLGStockBlurOriginalFiltersKey,
                                     layer.filters ?: [NSNull null],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id backgroundFilters = LGStockBlurGetLayerBackgroundFilters(layer);
            objc_setAssociatedObject(layer,
                                     kLGStockBlurOriginalBackgroundFiltersKey,
                                     backgroundFilters ?: [NSNull null],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(layer, kLGStockBlurSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        layer.filters = nil;
        LGStockBlurSetLayerBackgroundFilters(layer, nil);
        layer.compositingFilter = nil;
    } else if (objc_getAssociatedObject(layer, kLGStockBlurSuppressedKey)) {
        id filters = objc_getAssociatedObject(layer, kLGStockBlurOriginalFiltersKey);
        id backgroundFilters = objc_getAssociatedObject(layer, kLGStockBlurOriginalBackgroundFiltersKey);
        layer.filters = (filters == [NSNull null]) ? nil : filters;
        LGStockBlurSetLayerBackgroundFilters(layer, (backgroundFilters == [NSNull null]) ? nil : backgroundFilters);
        objc_setAssociatedObject(layer, kLGStockBlurOriginalFiltersKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(layer, kLGStockBlurOriginalBackgroundFiltersKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(layer, kLGStockBlurSuppressedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    for (CALayer *sublayer in layer.sublayers) {
        LGStockBlurSuppressLayerTree(sublayer, excludedLayer, suppressed);
    }
}

static void LGSpecularMotionStop(void) {
    if (!sSpecularMotionRunning) return;
    LGDebugLog(@"[SpecularMotion] stopping device motion and heading updates");
    [sSpecularMotionManager stopDeviceMotionUpdates];
    [sSpecularHeadingManager stopUpdatingHeading];
    sSpecularMotionRunning = NO;
    sSpecularMotionGyroOffset = 0.0;
    sSpecularHeadingLastUpdate = 0.0;
    sSpecularMotionLastSampleTime = 0.0;
}

static void LGSpecularMotionConfigure(void) {
    if (!LGSpecularMotionEnabled()) {
        LGDebugLog(@"[SpecularMotion] configure called but motion disabled — stopping");
        LGSpecularMotionStop();
        return;
    }
    if (!sSpecularMotionManager) {
        sSpecularMotionManager = [CMMotionManager new];
        sSpecularMotionQueue = [NSOperationQueue mainQueue];
        LGDebugLog(@"[SpecularMotion] created CMMotionManager");
    }
    if (!sSpecularHeadingManager && [CLLocationManager headingAvailable]) {
        sSpecularHeadingManager = [CLLocationManager new];
        sSpecularHeadingDelegate = [LGSpecularHeadingDelegate new];
        sSpecularHeadingManager.delegate = sSpecularHeadingDelegate;
        sSpecularHeadingManager.headingFilter = 1.0;
        LGDebugLog(@"[SpecularMotion] created CLLocationManager headingAvailable=1 servicesEnabled=%d auth=%ld",
                   [CLLocationManager locationServicesEnabled],
                   (long)sSpecularHeadingManager.authorizationStatus);
    } else if (![CLLocationManager headingAvailable]) {
        LGDebugLog(@"[SpecularMotion] headingAvailable=NO; falling back to gravity angle");
    }
    if (!sSpecularMotionManager.deviceMotionAvailable) {
        LGDebugLog(@"[SpecularMotion] deviceMotionAvailable=NO — cannot start");
        return;
    }

    NSTimeInterval interval = 1.0 / LGSpecularMotionFPS();
    sSpecularMotionManager.deviceMotionUpdateInterval = interval;
    LGDebugLog(@"[SpecularMotion] configure: fps=%.1f interval=%.4fs sensitivity=%.2f alreadyRunning=%d",
               LGSpecularMotionFPS(), interval, LGSpecularMotionSensitivity(), sSpecularMotionRunning);
    if (sSpecularMotionRunning) return;

    sSpecularMotionRunning = YES;
    LGDebugLog(@"[SpecularMotion] starting device motion updates");
    if (sSpecularHeadingManager) {
        [sSpecularHeadingManager startUpdatingHeading];
        LGDebugLog(@"[SpecularMotion] starting heading updates");
    }
    __weak CMMotionManager *weakManager = sSpecularMotionManager;
    [sSpecularMotionManager startDeviceMotionUpdatesToQueue:sSpecularMotionQueue
                                                withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (error) {
            LGDebugLog(@"[SpecularMotion] CMDeviceMotion error: %@ (code %ld) — stopping",
                       error.localizedDescription, (long)error.code);
            LGSpecularMotionStop();
            return;
        }
        if (!motion) {
            LGDebugLog(@"[SpecularMotion] nil motion object received — stopping");
            LGSpecularMotionStop();
            return;
        }
        if (!LGSpecularMotionEnabled()) {
            LGDebugLog(@"[SpecularMotion] pref disabled mid-flight — stopping");
            LGSpecularMotionStop();
            return;
        }
        CGFloat sensitivity = LGSpecularMotionSensitivity();
        CMAcceleration gravity = motion.gravity;
        CMRotationRate rotation = motion.rotationRate;
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval sampleTime = motion.timestamp > 0.0 ? motion.timestamp : now;
        CFTimeInterval dt = sSpecularMotionLastSampleTime > 0.0
            ? MAX(1.0 / 120.0, MIN(0.1, sampleTime - sSpecularMotionLastSampleTime))
            : (1.0 / LGSpecularMotionFPS());
        sSpecularMotionLastSampleTime = sampleTime;

        CGFloat planeX = gravity.x;
        CGFloat planeY = -gravity.y;
        CGFloat tiltMagnitude = MIN(1.0, hypot(planeX, planeY) / 0.65);
        CGFloat gravityAngle = atan2(planeX, planeY);
        BOOL hasFreshHeading = sSpecularHeadingLastUpdate > 0.0 && now - sSpecularHeadingLastUpdate <= 5.0;
        CGFloat compassAngle = hasFreshHeading ? sSpecularHeadingRadians : gravityAngle;
        CGFloat gyroSpin = rotation.y - rotation.x + rotation.z * 0.35;
        CGFloat response = 0.75 + sensitivity * 0.85;
        sSpecularMotionGyroOffset += gyroSpin * dt * response;
        sSpecularMotionGyroOffset *= MAX(0.0, 1.0 - dt * 3.6);

        CGFloat headingWeight = hasFreshHeading ? 1.0 : tiltMagnitude;
        CGFloat target = -compassAngle * headingWeight * response + sSpecularMotionGyroOffset;
        CGFloat prevAngle = sSpecularMotionAngle;
        CGFloat diff = target - sSpecularMotionAngle;
        while (diff >  M_PI) diff -= 2.0 * M_PI;
        while (diff < -M_PI) diff += 2.0 * M_PI;
        sSpecularMotionAngle = sSpecularMotionAngle + diff * 0.34;

        CGFloat fps = LGSpecularMotionFPS();
        CFTimeInterval sinceLast = now - sSpecularMotionLastRedraw;
        BOOL willRedraw = sinceLast >= 1.0 / fps;

        if (now - sSpecularMotionLastDebugLog >= 0.25) {
            sSpecularMotionLastDebugLog = now;
            LGDebugLog(@"[SpecularMotion] headingFresh=%d heading=%.3f gravity={%.3f,%.3f,%.3f} rotation={%.3f,%.3f,%.3f} "
                       @"tiltMag=%.3f gravityAngle=%.3f compassAngle=%.3f gyroOffset=%.3f target=%.3f "
                       @"prev=%.3f smoothed=%.3f delta=%.3f dt=%.3f | sinceLast=%.4fs fps=%.1f willRedraw=%d",
                       hasFreshHeading, sSpecularHeadingRadians,
                       gravity.x, gravity.y, gravity.z,
                       rotation.x, rotation.y, rotation.z,
                       tiltMagnitude, gravityAngle, compassAngle, sSpecularMotionGyroOffset, target,
                       prevAngle, sSpecularMotionAngle, sSpecularMotionAngle - prevAngle,
                       dt, sinceLast, fps, willRedraw);
        }

        if (willRedraw) {
            sSpecularMotionLastRedraw = now;
            LG_redrawRegisteredGlassViews(LGUpdateGroupAll);
            [LGGlassMaterialView updateAllSpecularAngles:sSpecularMotionAngle];
        }

        CMMotionManager *manager = weakManager;
        if (manager && fabs(manager.deviceMotionUpdateInterval - (1.0 / fps)) > 0.001) {
            LGDebugLog(@"[SpecularMotion] correcting update interval: was %.4f want %.4f",
                       manager.deviceMotionUpdateInterval, 1.0 / fps);
            manager.deviceMotionUpdateInterval = 1.0 / fps;
        }
    }];
}

__attribute__((constructor))
static void LGSpecularMotionInit(void) {
    if (!LGIsSpringBoardProcess() && !LGIsPreferencesProcess()) return;
    LGDebugLog(@"[SpecularMotion] init — process eligible, scheduling configure on main queue");
    dispatch_async(dispatch_get_main_queue(), ^{
        LGDebugLog(@"[SpecularMotion] initial configure (enabled=%d)", LGSpecularMotionEnabled());
        LGSpecularMotionConfigure();
        LGObservePreferenceChanges(^{
            dispatch_async(dispatch_get_main_queue(), ^{
                LGDebugLog(@"[SpecularMotion] pref changed — reconfiguring (enabled=%d)", LGSpecularMotionEnabled());
                LGSpecularMotionConfigure();
            });
        });
    });
}

static float LG_samplingOrientationForGlassView(__unused UIView *view, __unused LGUpdateGroup group) {
    return 1.0f;
}

typedef struct {
    vector_float2 x;
    vector_float2 y;
    vector_float2 offset;
    BOOL fixedCoordinateSpace;
    BOOL sourceLooksFixedScreen;
    BOOL swapsAxes;
    UIInterfaceOrientation interfaceOrientation;
    UIDeviceOrientation deviceOrientation;
} LGSamplingTransform;

static CGRect LG_fixedScreenCoordinateBounds(void) {
    if (@available(iOS 8.0, *)) {
        id<UICoordinateSpace> space = UIScreen.mainScreen.fixedCoordinateSpace;
        if (space && !CGRectIsEmpty(space.bounds)) return space.bounds;
    }
    return UIScreen.mainScreen.bounds;
}

static UIInterfaceOrientation LG_interfaceOrientationForGlassView(UIView *view) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = view.window.windowScene;
        if (scene) return scene.interfaceOrientation;
    }
    return UIInterfaceOrientationUnknown;
}

static CGRect LG_screenCoordinateBoundsForGlassView(UIView *view) {
    if (@available(iOS 8.0, *)) {
        id<UICoordinateSpace> space = UIScreen.mainScreen.coordinateSpace;
        if (space) return space.bounds;
    }
    return UIScreen.mainScreen.bounds;
}

static CGFloat LGAspectError(CGSize a, CGSize b) {
    if (a.width <= 1.0 || a.height <= 1.0 || b.width <= 1.0 || b.height <= 1.0) return CGFLOAT_MAX;
    CGFloat aspectA = a.width / a.height;
    CGFloat aspectB = b.width / b.height;
    return fabs(log(MAX(aspectA, 0.0001) / MAX(aspectB, 0.0001)));
}

static BOOL LG_samplingSourceLooksFixedScreen(CGSize sourcePixelSize, CGRect currentBounds, CGRect fixedBounds, CGFloat scale) {
    if (CGSizeEqualToSize(sourcePixelSize, CGSizeZero)) return NO;
    CGSize currentPixelSize = CGSizeMake(CGRectGetWidth(currentBounds) * scale,
                                         CGRectGetHeight(currentBounds) * scale);
    CGSize fixedPixelSize = CGSizeMake(CGRectGetWidth(fixedBounds) * scale,
                                       CGRectGetHeight(fixedBounds) * scale);
    if (fabs(currentPixelSize.width - fixedPixelSize.width) < 1.0 &&
        fabs(currentPixelSize.height - fixedPixelSize.height) < 1.0) {
        return NO;
    }

    CGFloat currentError = LGAspectError(sourcePixelSize, currentPixelSize);
    CGFloat fixedError = LGAspectError(sourcePixelSize, fixedPixelSize);
    return fixedError + 0.01 < currentError;
}

static BOOL LG_imageUsesFixedScreenSampling(UIImage *image) {
    NSString *cacheKey = LGImageStableCacheKey(image);
    return [cacheKey hasPrefix:@"wallpaper:home:"] ||
        [cacheKey hasPrefix:@"wallpaper:lock:"] ||
        [cacheKey hasPrefix:@"wallpaper:home-flat"] ||
        [cacheKey hasPrefix:@"wallpaper:lock-flat"];
}

static LGSamplingTransform LG_samplingTransformForGlassView(UIView *view,
                                                            CGSize sourcePixelSize,
                                                            BOOL usesExternalWallpaperTexture,
                                                            BOOL usesFixedScreenSampling) {
    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    CGRect currentBounds = LG_screenCoordinateBoundsForGlassView(view);
    CGRect fixedBounds = LG_fixedScreenCoordinateBounds();
    LGSamplingTransform transform = {
        .x = { 1.0f, 0.0f },
        .y = { 0.0f, 1.0f },
        .offset = { 0.0f, 0.0f },
        .fixedCoordinateSpace = NO,
        .sourceLooksFixedScreen = NO,
        .swapsAxes = NO,
        .interfaceOrientation = LG_interfaceOrientationForGlassView(view),
        .deviceOrientation = UIDevice.currentDevice.orientation,
    };

    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return transform;
    if (usesExternalWallpaperTexture) return transform;
    transform.sourceLooksFixedScreen = LG_samplingSourceLooksFixedScreen(sourcePixelSize, currentBounds, fixedBounds, scale);
    if (!usesFixedScreenSampling && !transform.sourceLooksFixedScreen) {
        return transform;
    }

    if (@available(iOS 8.0, *)) {
        id<UICoordinateSpace> currentSpace = UIScreen.mainScreen.coordinateSpace;
        id<UICoordinateSpace> fixedSpace = UIScreen.mainScreen.fixedCoordinateSpace;
        if (!currentSpace || !fixedSpace) return transform;

        CGPoint p0 = [currentSpace convertPoint:CGPointZero toCoordinateSpace:fixedSpace];
        CGPoint px = [currentSpace convertPoint:CGPointMake(1.0, 0.0) toCoordinateSpace:fixedSpace];
        CGPoint py = [currentSpace convertPoint:CGPointMake(0.0, 1.0) toCoordinateSpace:fixedSpace];
        vector_float2 xAxis = (vector_float2){ (float)(px.x - p0.x), (float)(px.y - p0.y) };
        vector_float2 yAxis = (vector_float2){ (float)(py.x - p0.x), (float)(py.y - p0.y) };
        BOOL swapsAxes = fabsf(xAxis.y) > 0.5f || fabsf(yAxis.x) > 0.5f;
        transform.swapsAxes = swapsAxes;
        if (!usesFixedScreenSampling && !swapsAxes) return transform;

        transform.x = xAxis;
        transform.y = yAxis;
        transform.offset = (vector_float2){ (float)(p0.x * scale), (float)(p0.y * scale) };
        transform.fixedCoordinateSpace = YES;
    }
    return transform;
}

static vector_float2 LGApplySamplingTransform(LGSamplingTransform transform, vector_float2 screenPx) {
    return transform.offset + screenPx.x * transform.x + screenPx.y * transform.y;
}

static NSString *LGFormatSamplePoint(NSString *name,
                                     vector_float2 screenPx,
                                     LGSamplingTransform transform,
                                     vector_float2 wallpaperOriginPx,
                                     CGSize sourcePixelSize) {
    vector_float2 mappedPx = LGApplySamplingTransform(transform, screenPx);
    vector_float2 imgPx = mappedPx - wallpaperOriginPx;
    CGFloat sourceW = MAX(sourcePixelSize.width, 1.0);
    CGFloat sourceH = MAX(sourcePixelSize.height, 1.0);
    return [NSString stringWithFormat:@"%@ screen={%.1f,%.1f} mapped={%.1f,%.1f} img={%.1f,%.1f} uv={%.3f,%.3f}",
            name,
            screenPx.x, screenPx.y,
            mappedPx.x, mappedPx.y,
            imgPx.x, imgPx.y,
            imgPx.x / (float)sourceW,
            imgPx.y / (float)sourceH];
}

static NSInteger LG_defaultPreferredFPS(void) {
    NSInteger maxFPS = 60;
    if ([UIScreen mainScreen].maximumFramesPerSecond > 0) {
        maxFPS = [UIScreen mainScreen].maximumFramesPerSecond >= 120 ? 120 : 60;
    }
    return (30 + maxFPS) / 2;
}

static NSInteger LG_preferredFPSForUpdateGroup(LGUpdateGroup group) {
    switch (group) {
        case LGUpdateGroupDock:
        case LGUpdateGroupFolderIcon:
        case LGUpdateGroupAppIcons:
        case LGUpdateGroupWidgets:
        case LGUpdateGroupFolderOpen:
        case LGUpdateGroupContextMenu:
            return MAX(30, LG_prefInteger(@"Homescreen.FPS", LG_defaultPreferredFPS()));
        case LGUpdateGroupAppLibrary:
            return MAX(30, LG_prefInteger(@"AppLibrary.FPS", LG_defaultPreferredFPS()));
        case LGUpdateGroupLockscreen:
            return MAX(30, LG_prefInteger(@"Lockscreen.FPS", LG_defaultPreferredFPS()));
        case LGUpdateGroupAll:
        default:
            return MAX(30, LG_defaultPreferredFPS());
    }
}

static id<MTLDevice>               sDevice;
static id<MTLRenderPipelineState>  sPipeline;
static id<MTLCommandQueue>         sCommandQueue;
static NSMapTable *sTextureCache = nil;
static NSMutableDictionary<NSNumber *, MPSImageGaussianBlur *> *sBlurKernelCache = nil;
static NSMutableArray<NSNumber *> *sBlurKernelLRUKeys = nil;
static id<MTLTexture> sOpaqueMaskTexture = nil;
static dispatch_once_t sRuntimeInitOnce;
static atomic_bool sRuntimeReady = false;
static const NSUInteger kLGBlurKernelCacheLimit = 16;

static id<MTLCommandQueue> LGCommandQueueForUpdateGroup(__unused LGUpdateGroup group) {
    return sCommandQueue;
}

static BOOL LGEnsureRuntimeReady(void) {
    LGPrewarmPipelines();
    return atomic_load_explicit(&sRuntimeReady, memory_order_acquire);
}

static void LG_clearTextureCache(void) {
    sTextureCache = [NSMapTable weakToStrongObjectsMapTable];
}

void LGClearGlassTextureCache(void) {
    LG_clearTextureCache();
    [sBlurKernelCache removeAllObjects];
    [sBlurKernelLRUKeys removeAllObjects];
}

static LGTextureCacheEntry *LG_getCacheForImage(UIImage *image, CGFloat scale) {
    NSDictionary *variants = [sTextureCache objectForKey:image];
    return variants[LGTextureScaleKey(scale)];
}

static void LG_setCacheForImage(UIImage *image, CGFloat scale, LGTextureCacheEntry *cache) {
    NSMutableDictionary *variants = [sTextureCache objectForKey:image];
    if (!variants) {
        variants = [NSMutableDictionary dictionary];
        [sTextureCache setObject:variants forKey:image];
    }
    variants[LGTextureScaleKey(scale)] = cache;
}

static MPSImageGaussianBlur *LGGaussianBlurKernelForSigma(float sigma) {
    if (!sBlurKernelCache) {
        sBlurKernelCache = [NSMutableDictionary dictionary];
        sBlurKernelLRUKeys = [NSMutableArray array];
    }
    NSNumber *key = LGBlurSettingKey(sigma);
    MPSImageGaussianBlur *kernel = sBlurKernelCache[key];
    if (kernel) {
        [sBlurKernelLRUKeys removeObject:key];
        [sBlurKernelLRUKeys addObject:key];
        return kernel;
    }
    while (sBlurKernelCache.count >= kLGBlurKernelCacheLimit && sBlurKernelLRUKeys.count > 0) {
        NSNumber *oldestKey = sBlurKernelLRUKeys.firstObject;
        [sBlurKernelCache removeObjectForKey:oldestKey];
        [sBlurKernelLRUKeys removeObjectAtIndex:0];
    }
    kernel = [[MPSImageGaussianBlur alloc] initWithDevice:sDevice sigma:sigma];
    kernel.edgeMode = MPSImageEdgeModeClamp;
    sBlurKernelCache[key] = kernel;
    [sBlurKernelLRUKeys addObject:key];
    return kernel;
}

void LGPrewarmPipelines(void) {
    dispatch_once(&sRuntimeInitOnce, ^{
        sDevice = MTLCreateSystemDefaultDevice();
        if (!sDevice) {
            LGLog(@"metal init failed no default device");
            return;
        }

        NSError *err = nil;
        id<MTLLibrary> lib = LGCreateGlassLibrary(sDevice, &err);
        if (!lib) {
            LGLog(@"metal library build failed %@", err.localizedDescription ?: @"unknown");
            return;
        }

        sPipeline = LGCreateGlassRenderPipeline(sDevice, lib, &err);
        if (!sPipeline) {
            LGLog(@"metal render pipeline build failed %@", err.localizedDescription ?: @"unknown");
            return;
        }

        sCommandQueue = [sDevice newCommandQueue];
        if (!sCommandQueue) {
            LGLog(@"metal command queue creation failed");
            return;
        }

        LG_clearTextureCache();

        MTLTextureDescriptor *maskDesc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                              width:1
                                                             height:1
                                                          mipmapped:NO];
        maskDesc.usage = MTLTextureUsageShaderRead;
        sOpaqueMaskTexture = [sDevice newTextureWithDescriptor:maskDesc];
        if (sOpaqueMaskTexture) {
            uint32_t pixel = 0xFFFFFFFFu;
            [sOpaqueMaskTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                                  mipmapLevel:0
                                    withBytes:&pixel
                                  bytesPerRow:sizeof(pixel)];
        }

        atomic_store_explicit(&sRuntimeReady, true, memory_order_release);
    });
}

@implementation LiquidGlassView {
    id<MTLTexture> _bgTexture;
    id<MTLTexture> _blurredTexture;
    LGTextureCacheEntry *_cacheEntry;
    MTKView *_mtkView;
    BOOL _needsBlurBake;
    float _lastBakedBlurRadius;
    CGPoint _wallpaperOriginPt;
    CGSize _sourceWallpaperPixelSize;
    CGRect _cachedVisualRectPx;
    CGSize _cachedDrawableSizePx;
    float _cachedVisualScale;
    BOOL _hasCachedVisualMetrics;
    BOOL _drawScheduled;
    BOOL _usesModelLayerVisualMetrics;
    CGFloat _effectiveTextureScale;
    CGSize _lastLayoutBounds;
    CFTimeInterval _lastDrawSubmissionTime;
    UIImage *_shapeMaskImage;
    id<MTLTexture> _shapeMaskTexture;
    LGZeroCopyBridge *_shapeMaskBridge;
    BOOL _systemBlurFallbackEnabled;
    UIView *_systemBlurFallbackView;
    UIImageView *_systemBlurFallbackMaskView;
    __weak UIView *_stockBlurSuppressionHost;
    __weak UIView *_appliedStockBlurSuppressionHost;
    BOOL _stockBlurSuppressionApplied;
    LGZeroCopyBridge *_wallpaperTextureBridge;
    BOOL _usesExternalWallpaperTexture;
    BOOL _usesFixedScreenSampling;
    NSString *_sourceCacheKey;
    NSString *_lastIPadSamplingDiagnosticSignature;
    CFTimeInterval _lastIPadSamplingDiagnosticTime;
}

- (instancetype)initWithFrame:(CGRect)frame wallpaper:(UIImage *)wallpaper wallpaperOrigin:(CGPoint)origin {
    LGAssertMainThread();
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _cornerRadius = 13.5;
    _bezelWidth = 14;
    _glassThickness = 80;
    _refractionScale = 1.2;
    _refractiveIndex = 1.0;
    _specularOpacity = 0.8;
    _blur = 8;
    _wallpaperScale = 1.0;
    _wallpaperSamplingResolution = CGSizeZero;
    _systemBlurFallbackEnabled = NO;
    _updateGroup = LGUpdateGroupAll;
    _wallpaperOriginPt = origin;
    _needsBlurBake = YES;
    _lastBakedBlurRadius = -1;
    _effectiveTextureScale = -1;
    _lastLayoutBounds = CGSizeZero;
    _lastDrawSubmissionTime = 0;

    if (!LGEnsureRuntimeReady()) return nil;

    _mtkView = [[MTKView alloc] initWithFrame:self.bounds device:sDevice];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _mtkView.framebufferOnly = NO;
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.paused = YES;
    _mtkView.enableSetNeedsDisplay = NO;
    _mtkView.opaque = NO;
    _mtkView.layer.opaque = NO;
    _mtkView.delegate = self;
    [self addSubview:_mtkView];

    self.clipsToBounds = YES;
    self.layer.cornerRadius = _cornerRadius;
    if (@available(iOS 13.0, *))
        self.layer.cornerCurve = kCACornerCurveContinuous;

    _wallpaperImage = wallpaper;
    _usesFixedScreenSampling = LG_imageUsesFixedScreenSampling(wallpaper);
    _sourceCacheKey = [LGImageStableCacheKey(wallpaper) copy];
    return self;
}


- (void)_ensureSystemBlurFallbackView {
    if (_systemBlurFallbackView) return;
    _systemBlurFallbackView = LGMakeLowBlurFallbackView();
    _systemBlurFallbackView.frame = self.bounds;
    _systemBlurFallbackView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _systemBlurFallbackView.userInteractionEnabled = NO;
    _systemBlurFallbackView.hidden = YES;
    [self insertSubview:_systemBlurFallbackView belowSubview:_mtkView];
}

- (void)_syncSystemBlurFallbackMask {
    if (!_systemBlurFallbackView) return;
    if (!_shapeMaskImage) {
        _systemBlurFallbackView.maskView = nil;
        _systemBlurFallbackMaskView = nil;
        return;
    }
    if (!_systemBlurFallbackMaskView) {
        _systemBlurFallbackMaskView = [[UIImageView alloc] initWithFrame:_systemBlurFallbackView.bounds];
        _systemBlurFallbackMaskView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _systemBlurFallbackView.maskView = _systemBlurFallbackMaskView;
    }
    _systemBlurFallbackMaskView.frame = _systemBlurFallbackView.bounds;
    _systemBlurFallbackMaskView.image = _shapeMaskImage;
}

- (void)_syncSystemBlurFallbackVisibility {
    BOOL visible = NO;
    if (!visible) {
        if (_stockBlurSuppressionApplied && _appliedStockBlurSuppressionHost && _appliedStockBlurSuppressionHost != self) {
            LGStockBlurSuppressLayerTree(_appliedStockBlurSuppressionHost.layer, self.layer, NO);
        }
        _appliedStockBlurSuppressionHost = nil;
        _stockBlurSuppressionApplied = NO;
    }
    _systemBlurFallbackView.hidden = !visible;
}

- (UIImage *)shapeMaskImage {
    return _shapeMaskImage;
}

- (void)setReleasesWallpaperAfterUpload:(BOOL)releases {
    _releasesWallpaperAfterUpload = releases;
    if (releases && (_bgTexture || _cacheEntry))
        _wallpaperImage = nil;
}

- (void)setCornerRadius:(CGFloat)r {
    if (fabs(_cornerRadius - r) < 0.001f) return;
    _cornerRadius = r;
    self.layer.cornerRadius = r;
    [self scheduleDraw];
}

- (void)setBlur:(CGFloat)b {
    if (fabs(_blur - b) < 0.001f) return;
    _blur = b;
    _needsBlurBake = YES;
    [self scheduleDraw];
}

- (void)setWallpaperSamplingResolution:(CGSize)resolution {
    if (CGSizeEqualToSize(_wallpaperSamplingResolution, resolution)) return;
    _wallpaperSamplingResolution = resolution;
    [self scheduleDraw];
}

- (void)setBezelWidth:(CGFloat)value {
    if (fabs(_bezelWidth - value) < 0.001f) return;
    _bezelWidth = value;
    [self scheduleDraw];
}

- (void)setGlassThickness:(CGFloat)value {
    if (fabs(_glassThickness - value) < 0.001f) return;
    _glassThickness = value;
    [self scheduleDraw];
}

- (void)setRefractionScale:(CGFloat)value {
    if (fabs(_refractionScale - value) < 0.001f) return;
    _refractionScale = value;
    [self scheduleDraw];
}

- (void)setRefractiveIndex:(CGFloat)value {
    if (fabs(_refractiveIndex - value) < 0.001f) return;
    _refractiveIndex = value;
    [self scheduleDraw];
}

- (void)setSpecularOpacity:(CGFloat)value {
    if (fabs(_specularOpacity - value) < 0.001f) return;
    _specularOpacity = value;
    [self scheduleDraw];
}

- (void)_reloadShapeMaskTexture {
    UIImage *image = LGNormalizedImageForUpload(_shapeMaskImage);
    _shapeMaskTexture = nil;
    _shapeMaskBridge = nil;
    if (!image || !sDevice) return;

    NSUInteger w = MAX((NSUInteger)1, (NSUInteger)lrint(image.size.width * image.scale));
    NSUInteger h = MAX((NSUInteger)1, (NSUInteger)lrint(image.size.height * image.scale));
    LGZeroCopyBridge *bridge = [[LGZeroCopyBridge alloc] initWithDevice:sDevice];
    if (![bridge setupBufferWithWidth:w height:h]) return;

    id<MTLTexture> texture = [bridge renderWithActions:^(CGContextRef ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    }];
    if (!texture) return;
    _shapeMaskBridge = bridge;
    _shapeMaskTexture = texture;
}

- (void)setShapeMaskImage:(UIImage *)image {
    if (_shapeMaskImage == image || [_shapeMaskImage isEqual:image]) return;
    _shapeMaskImage = image;
    [self _reloadShapeMaskTexture];
    [self _syncSystemBlurFallbackMask];
    [self scheduleDraw];
}

- (void)setSystemBlurFallbackEnabled:(BOOL)enabled {
    if (_systemBlurFallbackEnabled == enabled) return;
    _systemBlurFallbackEnabled = enabled;
    [self _syncSystemBlurFallbackVisibility];
    [self scheduleDraw];
}

- (UIView *)stockBlurSuppressionHost {
    return _stockBlurSuppressionHost;
}

- (void)setStockBlurSuppressionHost:(UIView *)host {
    if (_stockBlurSuppressionHost == host) return;
    UIView *oldHost = _stockBlurSuppressionHost;
    if (oldHost && oldHost != self) {
        LGStockBlurSuppressLayerTree(oldHost.layer, self.layer, NO);
    }
    if (_appliedStockBlurSuppressionHost && _appliedStockBlurSuppressionHost != oldHost && _appliedStockBlurSuppressionHost != self) {
        LGStockBlurSuppressLayerTree(_appliedStockBlurSuppressionHost.layer, self.layer, NO);
    }
    _appliedStockBlurSuppressionHost = nil;
    _stockBlurSuppressionApplied = NO;
    _stockBlurSuppressionHost = host;
    [self _syncSystemBlurFallbackVisibility];
    [self scheduleDraw];
}


- (void)setWallpaperImage:(UIImage *)img {
    if (!_usesExternalWallpaperTexture && _wallpaperImage == img) return;
    _usesExternalWallpaperTexture = NO;
    _usesFixedScreenSampling = LG_imageUsesFixedScreenSampling(img);
    _sourceCacheKey = [LGImageStableCacheKey(img) copy];
    _wallpaperTextureBridge = nil;
    _cacheEntry = nil;
    _wallpaperImage = img;
    [self _reloadTexture];
    [self scheduleDraw];
}

- (CGPoint)wallpaperOrigin {
    return _wallpaperOriginPt;
}

- (void)setWallpaperOrigin:(CGPoint)origin {
    if (fabs(_wallpaperOriginPt.x - origin.x) < 0.001f &&
        fabs(_wallpaperOriginPt.y - origin.y) < 0.001f) {
        return;
    }
    _wallpaperOriginPt = origin;
    [self scheduleDraw];
}

- (BOOL)usesModelLayerVisualMetrics {
    return _usesModelLayerVisualMetrics;
}

- (void)setUsesModelLayerVisualMetrics:(BOOL)usesModelLayerVisualMetrics {
    if (_usesModelLayerVisualMetrics == usesModelLayerVisualMetrics) return;
    _usesModelLayerVisualMetrics = usesModelLayerVisualMetrics;
    _hasCachedVisualMetrics = NO;
    [self scheduleDraw];
}

- (void)setWallpaperScale:(CGFloat)scale {
    CGFloat clamped = fmax(0.1, fmin(scale, 1.0));
    if (fabs(_wallpaperScale - clamped) < 0.001f) return;
    CGFloat previousEffectiveScale = _effectiveTextureScale;
    _wallpaperScale = clamped;
    _effectiveTextureScale = -1;
    if (_usesExternalWallpaperTexture) {
        _needsBlurBake = YES;
        _lastBakedBlurRadius = -1;
        [self scheduleDraw];
        return;
    }
    if (self.wallpaperImage) {
        NSUInteger srcW = (NSUInteger)(self.wallpaperImage.size.width * self.wallpaperImage.scale);
        NSUInteger srcH = (NSUInteger)(self.wallpaperImage.size.height * self.wallpaperImage.scale);
        CGFloat nextEffectiveScale = [self _recommendedInternalTextureScaleForSourceWidth:srcW height:srcH];
        if (fabs(previousEffectiveScale - nextEffectiveScale) > 0.001f || !_bgTexture) {
            [self _reloadTexture];
        }
    } else {
        [self _reloadTexture];
    }
    [self scheduleDraw];
}

- (void)setUpdateGroup:(LGUpdateGroup)group {
    if (_updateGroup == group) return;
    if (_updateGroup != LGUpdateGroupAll)
        LG_unregisterGlassView(self, _updateGroup);
    _updateGroup = group;
    if (_updateGroup != LGUpdateGroupAll)
        LG_registerGlassView(self, _updateGroup);
}

- (void)updateOrigin {
    if (!_mtkView.superview) return;
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
    BOOL metricsChanged = [self _refreshVisualMetrics];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect screenBounds = LG_screenCoordinateBoundsForGlassView(self);
    CGRect screenBoundsPx = CGRectMake(CGRectGetMinX(screenBounds) * scale,
                                       CGRectGetMinY(screenBounds) * scale,
                                       CGRectGetWidth(screenBounds) * scale,
                                       CGRectGetHeight(screenBounds) * scale);
    if (!CGRectIntersectsRect(_cachedVisualRectPx, screenBoundsPx)) return;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && metricsChanged) {
        LGDebugLog(@"glass update group=%ld bounds=%@ visualPx=%@ screen=%@ origin=%@ wallpaper=%@",
                   (long)_updateGroup,
                   NSStringFromCGRect(self.bounds),
                   NSStringFromCGRect(_cachedVisualRectPx),
                   NSStringFromCGSize(screenBounds.size),
                   NSStringFromCGPoint(_wallpaperOriginPt),
                   self.wallpaperImage ? NSStringFromCGSize(self.wallpaperImage.size) : @"(null)");
    }
    if (!metricsChanged && !_needsBlurBake) return;
    [self scheduleDraw];
}

- (void)scheduleDraw {
    if (!_mtkView.superview) return;
    if (_drawScheduled) return;
    _drawScheduled = YES;
    CFTimeInterval now = CACurrentMediaTime();
    NSInteger preferredFPS = MAX(30, LG_preferredFPSForUpdateGroup(_updateGroup));
    CFTimeInterval earliest = _lastDrawSubmissionTime + (1.0 / (CFTimeInterval)preferredFPS);
    CFTimeInterval delay = MAX(0.0, earliest - now);
    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_drawScheduled = NO;
        if (!self->_mtkView.superview) return;
        if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
        self->_lastDrawSubmissionTime = CACurrentMediaTime();
        [self _syncSystemBlurFallbackVisibility];
        [self->_mtkView draw];
    };
    if (delay > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), block);
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (BOOL)_refreshVisualMetrics {
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect visualRect;
    BOOL useDirectScreenConversion = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
                                      _updateGroup != LGUpdateGroupLockscreen &&
                                      _updateGroup != LGUpdateGroupFolderOpen &&
                                      self.window != nil);
    if (_usesModelLayerVisualMetrics) {
        CGRect rectInSuperview = self.frame;
        if (self.superview) {
            CALayer *layer = self.layer;
            CGSize size = layer.bounds.size;
            CGPoint anchor = layer.anchorPoint;
            CGPoint position = layer.position;
            rectInSuperview = CGRectMake(position.x - size.width * anchor.x,
                                         position.y - size.height * anchor.y,
                                         size.width,
                                         size.height);
        }
        CGRect screenRect = self.window.windowScene
            ? [self.superview convertRect:rectInSuperview toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self.superview convertRect:rectInSuperview toView:nil];
        visualRect = CGRectMake(screenRect.origin.x * scale,
                                screenRect.origin.y * scale,
                                screenRect.size.width * scale,
                                screenRect.size.height * scale);
    } else if (useDirectScreenConversion) {
        CGRect screenRect = self.window.windowScene
            ? [self convertRect:self.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self convertRect:self.bounds toView:nil];
        visualRect = CGRectMake(screenRect.origin.x * scale,
                                screenRect.origin.y * scale,
                                screenRect.size.width * scale,
                                screenRect.size.height * scale);
    } else if (self.window) {
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
        CALayer *windowLayer = self.window.layer.presentationLayer ?: self.window.layer;
        CGRect windowScreenRect = self.window.windowScene
            ? [self.window convertRect:self.window.bounds
                     toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self.window convertRect:self.window.bounds toView:nil];
        if (pres != windowLayer) {
            CGRect vr = pres.bounds;
            CALayer *cur = pres;
            while (cur && cur != windowLayer) {
                CALayer *up = cur.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                vr = [cur convertRect:vr toLayer:upPres];
                cur = upPres;
            }
            visualRect = CGRectMake((windowScreenRect.origin.x + vr.origin.x) * scale,
                                    (windowScreenRect.origin.y + vr.origin.y) * scale,
                                    vr.size.width * scale,
                                    vr.size.height * scale);
        } else {
            CGRect screenRect = self.window.windowScene
                ? [self convertRect:self.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
                : [self convertRect:self.bounds toView:nil];
            visualRect = CGRectMake(screenRect.origin.x * scale,
                                    screenRect.origin.y * scale,
                                    screenRect.size.width * scale,
                                    screenRect.size.height * scale);
        }
    } else {
        CALayer *baseLayer = self.layer;
        CALayer *pres = baseLayer.presentationLayer ?: baseLayer;
        if (pres == baseLayer) {
            CGRect nullRect = CGRectNull;
            CGSize drawableSize = _mtkView.drawableSize;
            if (_hasCachedVisualMetrics
                && CGRectEqualToRect(_cachedVisualRectPx, nullRect)
                && fabs(_cachedDrawableSizePx.width - drawableSize.width) < 0.5f
                && fabs(_cachedDrawableSizePx.height - drawableSize.height) < 0.5f) {
                return NO;
            }
            _cachedVisualRectPx = nullRect;
            _cachedDrawableSizePx = drawableSize;
            _cachedVisualScale = 1.0f;
            _hasCachedVisualMetrics = YES;
            return YES;
        }
        CALayer *root = pres;
        while (root.superlayer)
            root = root.superlayer.presentationLayer ?: root.superlayer;

        if (root != pres) {
            CGRect vr = pres.bounds;
            CALayer *cur = pres;
            while (cur && cur != root) {
                CALayer *up = cur.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                vr = [cur convertRect:vr toLayer:upPres];
                cur = upPres;
            }
            visualRect = CGRectMake(vr.origin.x * scale,
                                    vr.origin.y * scale,
                                    vr.size.width * scale,
                                    vr.size.height * scale);
        } else {
            CGPoint orig = [self convertPoint:CGPointZero toView:nil];
            visualRect = CGRectMake(orig.x * scale,
                                    orig.y * scale,
                                    self.bounds.size.width * scale,
                                    self.bounds.size.height * scale);
        }
    }

    CGSize drawableSize = _mtkView.drawableSize;
    float drawableW = self.bounds.size.width * scale;
    float visualScale = (drawableW > 0.0f) ? (CGRectGetWidth(visualRect) / drawableW) : 1.0f;

    if (_hasCachedVisualMetrics
        && fabs(CGRectGetMinX(_cachedVisualRectPx) - CGRectGetMinX(visualRect)) < 0.5f
        && fabs(CGRectGetMinY(_cachedVisualRectPx) - CGRectGetMinY(visualRect)) < 0.5f
        && fabs(CGRectGetWidth(_cachedVisualRectPx) - CGRectGetWidth(visualRect)) < 0.5f
        && fabs(CGRectGetHeight(_cachedVisualRectPx) - CGRectGetHeight(visualRect)) < 0.5f
        && fabs(_cachedDrawableSizePx.width - drawableSize.width) < 0.5f
        && fabs(_cachedDrawableSizePx.height - drawableSize.height) < 0.5f
        && fabs(_cachedVisualScale - visualScale) < 0.001f) {
        return NO;
    }

    _cachedVisualRectPx = visualRect;
    _cachedDrawableSizePx = drawableSize;
    _cachedVisualScale = visualScale;
    _hasCachedVisualMetrics = YES;
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self _syncSystemBlurFallbackVisibility];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize boundsSize = self.bounds.size;
    CGSize drawableSize = CGSizeMake(MAX(1.0, floor(boundsSize.width * scale)),
                                     MAX(1.0, floor(boundsSize.height * scale)));
    if (!CGSizeEqualToSize(_mtkView.drawableSize, drawableSize)) {
        _mtkView.drawableSize = drawableSize;
        _hasCachedVisualMetrics = NO;
    }
    if (!CGSizeEqualToSize(_lastLayoutBounds, boundsSize)) {
        _lastLayoutBounds = boundsSize;
        [self scheduleDraw];
    }
}

- (CGFloat)_recommendedInternalTextureScaleForSourceWidth:(NSUInteger)srcW height:(NSUInteger)srcH {
    CGFloat userScale = fmax(0.1, fmin(_wallpaperScale, 1.0));
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGFloat viewMaxPx = MAX(self.bounds.size.width, self.bounds.size.height) * screenScale;
    CGFloat sourceMaxPx = MAX((CGFloat)srcW, (CGFloat)srcH);
    if (viewMaxPx <= 1.0 || sourceMaxPx <= 1.0) return userScale;

    CGFloat adaptiveScale = (viewMaxPx * 2.4) / sourceMaxPx;
    adaptiveScale = fmax(0.16, fmin(adaptiveScale, 1.0));
    CGFloat groupCap = 1.0;
    switch (_updateGroup) {
        case LGUpdateGroupAppIcons: groupCap = 0.28; break;
        case LGUpdateGroupFolderIcon: groupCap = 0.28; break;
        case LGUpdateGroupWidgets: groupCap = 0.34; break;
        case LGUpdateGroupAppLibrary: groupCap = 0.30; break;
        case LGUpdateGroupDock: groupCap = 0.42; break;
        case LGUpdateGroupContextMenu: groupCap = 0.42; break;
        case LGUpdateGroupFolderOpen: groupCap = 0.42; break;
        case LGUpdateGroupLockscreen: groupCap = 0.65; break;
        default: break;
    }
    return fmin(fmin(userScale, adaptiveScale), groupCap);
}

- (void)updateWallpaperTextureWithPixelWidth:(size_t)width
                                      height:(size_t)height
                              sourcePixelSize:(CGSize)sourcePixelSize
                                     actions:(void (^)(CGContextRef context))actions {
    LGAssertMainThread();
    if (!width || !height) return;
    if (!LGEnsureRuntimeReady()) return;

    if (!_wallpaperTextureBridge) {
        _wallpaperTextureBridge = [[LGZeroCopyBridge alloc] initWithDevice:sDevice];
    }

    size_t currentWidth = [_wallpaperTextureBridge bufferWidth];
    size_t currentHeight = [_wallpaperTextureBridge bufferHeight];
    if (currentWidth != width || currentHeight != height) {
        if (![_wallpaperTextureBridge setupBufferWithWidth:width height:height]) return;
        _blurredTexture = nil;
    }

    id<MTLTexture> texture = [_wallpaperTextureBridge renderWithActions:actions];
    if (!texture) return;

    _usesExternalWallpaperTexture = YES;
    _usesFixedScreenSampling = NO;
    _sourceCacheKey = [NSString stringWithFormat:@"live:%zux%zu", width, height];
    _wallpaperImage = nil;
    _cacheEntry = nil;
    _bgTexture = texture;
    _sourceWallpaperPixelSize = !CGSizeEqualToSize(sourcePixelSize, CGSizeZero)
        ? sourcePixelSize
        : CGSizeMake((CGFloat)width, (CGFloat)height);
    _needsBlurBake = YES;
    _lastBakedBlurRadius = -1;
    [self scheduleDraw];
}

- (void)_reloadTexture {
    if (_usesExternalWallpaperTexture) return;
    UIImage *image = LGNormalizedImageForUpload(self.wallpaperImage);
    if (!image) return;
    NSUInteger srcW = (NSUInteger)(image.size.width * image.scale);
    NSUInteger srcH = (NSUInteger)(image.size.height * image.scale);
    CGFloat textureScale = [self _recommendedInternalTextureScaleForSourceWidth:srcW height:srcH];
    _effectiveTextureScale = textureScale;
    _sourceWallpaperPixelSize = CGSizeMake(srcW, srcH);
    NSUInteger w = MAX((NSUInteger)1, (NSUInteger)lrint(srcW * textureScale));
    NSUInteger h = MAX((NSUInteger)1, (NSUInteger)lrint(srcH * textureScale));
    if (!w || !h) return;

    LGTextureCacheEntry *cached = LG_getCacheForImage(image, textureScale);
    if (cached) {
        _cacheEntry = cached;
        _bgTexture = cached.bgTexture;
        LGBlurVariant *variant = cached.blurVariants[LGBlurSettingKey(_blur)];
        _blurredTexture = variant.texture;
        if (variant.texture) {
            _needsBlurBake = NO;
            _lastBakedBlurRadius = variant.bakedBlurRadius;
        } else {
            _needsBlurBake = YES;
            _lastBakedBlurRadius = -1;
        }
        if (_releasesWallpaperAfterUpload)
            _wallpaperImage = nil;
        return;
    }

    LGZeroCopyBridge *bridge = [[LGZeroCopyBridge alloc] initWithDevice:sDevice];
    if (![bridge setupBufferWithWidth:w height:h]) return;

    _bgTexture = [bridge renderWithActions:^(CGContextRef ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    }];
    if (!_bgTexture) return;

    MTLTextureDescriptor *rd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:w height:h mipmapped:NO];
    rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurredTexture = nil;

    LGTextureCacheEntry *entry = [LGTextureCacheEntry new];
    entry.bgTexture = _bgTexture;
    entry.bridge = bridge;
    entry.blurVariants = [NSMutableDictionary dictionary];
    _cacheEntry = entry;
    LG_setCacheForImage(image, textureScale, entry);

    _needsBlurBake = YES;
    _lastBakedBlurRadius = -1;
    if (_releasesWallpaperAfterUpload)
        _wallpaperImage = nil;
}

- (void)_runBlurPassesWithRadius:(float)radius commandBuffer:(id<MTLCommandBuffer>)cmdBuf {
    if (!_bgTexture || !_blurredTexture) return;

    if (radius < 0.5f) {
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        if (!blit) return;
        [blit copyFromTexture:_bgTexture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(_bgTexture.width, _bgTexture.height, 1)
                    toTexture:_blurredTexture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        return;
    }

    float sigma = MAX(radius * 0.5f, 0.1f);
    MPSImageGaussianBlur *blur = LGGaussianBlurKernelForSigma(sigma);
    [blur encodeToCommandBuffer:cmdBuf sourceTexture:_bgTexture destinationTexture:_blurredTexture];
}

- (void)_ensureBlurTexture {
    if (_blurredTexture || !_bgTexture) return;
    MTLTextureDescriptor *rd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:_bgTexture.width
                                                         height:_bgTexture.height
                                                      mipmapped:NO];
    rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurredTexture = [sDevice newTextureWithDescriptor:rd];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _hasCachedVisualMetrics = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    CFTimeInterval profileStart = 0.0;
    BOOL shouldProfile = (_updateGroup == LGUpdateGroupLockscreen);
    if (shouldProfile) profileStart = LGProfileBegin();
    [self _syncSystemBlurFallbackVisibility];
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (_bgTexture && !_blurredTexture) [self _ensureBlurTexture];
    if (!sPipeline || !_bgTexture || !_blurredTexture) {
        if (shouldProfile) LGProfileEnd(@"lockscreen.draw", profileStart);
        return;
    }
    [self _refreshVisualMetrics];
    CGSize drawableSize = _cachedDrawableSizePx;
    if (drawableSize.width < 1 || drawableSize.height < 1) {
        if (shouldProfile) LGProfileEnd(@"lockscreen.draw", profileStart);
        return;
    }
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!drawable || !passDesc) {
        if (shouldProfile) LGProfileEnd(@"lockscreen.draw", profileStart);
        return;
    }
    id<MTLCommandQueue> commandQueue = LGCommandQueueForUpdateGroup(_updateGroup);
    id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
    if (!cmdBuf) {
        if (shouldProfile) LGProfileEnd(@"lockscreen.draw", profileStart);
        return;
    }

    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect screenBounds = LG_screenCoordinateBoundsForGlassView(self);
    CGFloat screenW = CGRectGetWidth(screenBounds) * scale;
    CGFloat screenH = CGRectGetHeight(screenBounds) * scale;

    float visOriginX = CGRectGetMinX(_cachedVisualRectPx);
    float visOriginY = CGRectGetMinY(_cachedVisualRectPx);
    float visW = CGRectGetWidth(_cachedVisualRectPx);
    float visH = CGRectGetHeight(_cachedVisualRectPx);
    float visualScale = _cachedVisualScale;
    float samplingOrientation = LG_samplingOrientationForGlassView(self, _updateGroup);
    CGSize samplingWallpaperPixelSize =
        !CGSizeEqualToSize(_wallpaperSamplingResolution, CGSizeZero)
            ? _wallpaperSamplingResolution
            : _sourceWallpaperPixelSize;
    LGSamplingTransform samplingTransform =
        LG_samplingTransformForGlassView(self,
                                         samplingWallpaperPixelSize,
                                         _usesExternalWallpaperTexture,
                                         _usesFixedScreenSampling);

    float imgW = (float)_bgTexture.width;
    float imgH = (float)_bgTexture.height;
    float samplingW = (float)samplingWallpaperPixelSize.width;
    float samplingH = (float)samplingWallpaperPixelSize.height;
    float fillScale = (_usesExternalWallpaperTexture && samplingW > 1.0f && samplingH > 1.0f)
        ? fmaxf(samplingW / imgW, samplingH / imgH)
        : fmaxf((float)screenW / imgW, (float)screenH / imgH);
    float blurPx = (float)_blur * (float)scale / fillScale;

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        CGRect fixedBounds = LG_fixedScreenCoordinateBounds();
        vector_float2 wallpaperOriginPx = {
            (float)(_wallpaperOriginPt.x * scale),
            (float)(_wallpaperOriginPt.y * scale)
        };
        vector_float2 topLeft = { visOriginX, visOriginY };
        vector_float2 center = { visOriginX + visW * 0.5f, visOriginY + visH * 0.5f };
        vector_float2 bottomCenter = { visOriginX + visW * 0.5f, visOriginY + visH };
        vector_float2 bottomRight = { visOriginX + visW, visOriginY + visH };
        NSString *sourceKey = _sourceCacheKey ?: @"(none)";
        NSString *signature = [NSString stringWithFormat:@"%ld|%@|%.0f,%.0f,%.0f,%.0f|%.0f,%.0f|%.0f,%.0f|%.0f,%.0f|%d|%d|%d|%d|%ld|%ld",
                               (long)_updateGroup,
                               sourceKey,
                               visOriginX, visOriginY, visW, visH,
                               samplingW, samplingH,
                               samplingTransform.offset.x, samplingTransform.offset.y,
                               samplingTransform.x.y, samplingTransform.y.x,
                               _usesExternalWallpaperTexture ? 1 : 0,
                               _usesFixedScreenSampling ? 1 : 0,
                               samplingTransform.sourceLooksFixedScreen ? 1 : 0,
                               samplingTransform.fixedCoordinateSpace ? 1 : 0,
                               (long)samplingTransform.interfaceOrientation,
                               (long)samplingTransform.deviceOrientation];
        CFTimeInterval now = CACurrentMediaTime();
        BOOL shouldLogDiagnostic = ![_lastIPadSamplingDiagnosticSignature isEqualToString:signature] ||
            (now - _lastIPadSamplingDiagnosticTime) >= 1.5;
        if (shouldLogDiagnostic) {
            _lastIPadSamplingDiagnosticSignature = [signature copy];
            _lastIPadSamplingDiagnosticTime = now;
            LGDebugLog(@"ipad sampling diag group=%ld view=%@ source=%@ external=%d fixedSource=%d fixedGuess=%d fixedMap=%d swapsAxes=%d interface=%ld device=%ld currentBounds=%@ fixedBounds=%@ visualPx=%@ drawable=%@ bgTex={%.0f,%.0f} sourcePx=%@ screenPx={%.1f,%.1f} originPt=%@ originPx={%.1f,%.1f} mapX={%.2f,%.2f} mapY={%.2f,%.2f} mapO={%.1f,%.1f} fill=%.3f %@ | %@ | %@ | %@",
                       (long)_updateGroup,
                       NSStringFromClass(self.class),
                       sourceKey,
                       _usesExternalWallpaperTexture ? 1 : 0,
                       _usesFixedScreenSampling ? 1 : 0,
                       samplingTransform.sourceLooksFixedScreen ? 1 : 0,
                       samplingTransform.fixedCoordinateSpace ? 1 : 0,
                       samplingTransform.swapsAxes ? 1 : 0,
                       (long)samplingTransform.interfaceOrientation,
                       (long)samplingTransform.deviceOrientation,
                       NSStringFromCGRect(screenBounds),
                       NSStringFromCGRect(fixedBounds),
                       NSStringFromCGRect(_cachedVisualRectPx),
                       NSStringFromCGSize(drawableSize),
                       imgW, imgH,
                       NSStringFromCGSize(samplingWallpaperPixelSize),
                       screenW, screenH,
                       NSStringFromCGPoint(_wallpaperOriginPt),
                       wallpaperOriginPx.x, wallpaperOriginPx.y,
                       samplingTransform.x.x, samplingTransform.x.y,
                       samplingTransform.y.x, samplingTransform.y.y,
                       samplingTransform.offset.x, samplingTransform.offset.y,
                       fillScale,
                       LGFormatSamplePoint(@"tl", topLeft, samplingTransform, wallpaperOriginPx, samplingWallpaperPixelSize),
                       LGFormatSamplePoint(@"center", center, samplingTransform, wallpaperOriginPx, samplingWallpaperPixelSize),
                       LGFormatSamplePoint(@"bottomCenter", bottomCenter, samplingTransform, wallpaperOriginPx, samplingWallpaperPixelSize),
                       LGFormatSamplePoint(@"bottomRight", bottomRight, samplingTransform, wallpaperOriginPx, samplingWallpaperPixelSize));
        }
    }

    if ((_needsBlurBake || blurPx != _lastBakedBlurRadius) && _cacheEntry) {
        LGBlurVariant *variant = _cacheEntry.blurVariants[LGBlurSettingKey(_blur)];
        if (variant.texture) {
            _blurredTexture = variant.texture;
            _lastBakedBlurRadius = variant.bakedBlurRadius;
            _needsBlurBake = NO;
        }
    }

    if (_needsBlurBake || blurPx != _lastBakedBlurRadius) {
        [self _ensureBlurTexture];
        [self _runBlurPassesWithRadius:blurPx commandBuffer:cmdBuf];
        _lastBakedBlurRadius = blurPx;
        _needsBlurBake = NO;
        LGTextureCacheEntry *entry = _cacheEntry;
        if (entry) {
            LGBlurVariant *variant = [LGBlurVariant new];
            variant.texture = _blurredTexture;
            variant.bakedBlurRadius = blurPx;
            entry.blurVariants[LGBlurSettingKey(_blur)] = variant;
        }
    }

    CGFloat specularAngleForDraw = LGSpecularMotionCurrentAngle();
    CFTimeInterval motionDrawLogNow = CACurrentMediaTime();
    if (LGSpecularMotionEnabled() && motionDrawLogNow - sSpecularMotionLastDrawDebugLog >= 0.5) {
        sSpecularMotionLastDrawDebugLog = motionDrawLogNow;
        LGDebugLog(@"[SpecularMotion] drawInMTKView group=%ld specularAngle=%.4f (%.1f°) opacity=%.2f",
                   (long)_updateGroup,
                   specularAngleForDraw,
                   specularAngleForDraw * (180.0 / M_PI),
                   _specularOpacity);
    }

    id<MTLRenderCommandEncoder> enc =
        [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    LGUniforms u = {
        .resolution = { visW, visH },
        .screenResolution = { (float)screenW, (float)screenH },
        .cardOrigin = { visOriginX, visOriginY },
        .wallpaperResolution = { (float)samplingWallpaperPixelSize.width,
                                 (float)samplingWallpaperPixelSize.height },
        .radius = (float)(_cornerRadius * scale * visualScale),
        .bezelWidth = (float)(_bezelWidth * scale * visualScale),
        .glassThickness = (float)_glassThickness,
        .refractionScale = (float)_refractionScale,
        .refractiveIndex = (float)_refractiveIndex,
        .specularOpacity = (float)_specularOpacity,
        .specularAngle = (float)specularAngleForDraw,
        .blur = blurPx,
        .wallpaperOrigin = { (float)(_wallpaperOriginPt.x * scale),
                             (float)(_wallpaperOriginPt.y * scale) },
        .samplingTransformX = samplingTransform.x,
        .samplingTransformY = samplingTransform.y,
        .samplingTransformOffset = samplingTransform.offset,
        .samplingOrientation = samplingOrientation,
        .hasShapeMask = _shapeMaskTexture ? 1.0f : 0.0f,
    };
    [enc setRenderPipelineState:sPipeline];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:_blurredTexture atIndex:0];
    [enc setFragmentTexture:(_shapeMaskTexture ?: sOpaqueMaskTexture) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
    if (shouldProfile) LGProfileEnd(@"lockscreen.draw", profileStart);
}

- (void)dealloc {
    UIView *suppressionHost = _appliedStockBlurSuppressionHost ?: _stockBlurSuppressionHost ?: self.superview;
    if (_stockBlurSuppressionApplied && suppressionHost && suppressionHost != self) {
        LGStockBlurSuppressLayerTree(suppressionHost.layer, self.layer, NO);
    }
    if (_updateGroup != LGUpdateGroupAll)
        LG_unregisterGlassView(self, _updateGroup);
}

@end
