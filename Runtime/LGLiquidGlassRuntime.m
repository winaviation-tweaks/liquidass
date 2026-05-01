#import "LGLiquidGlassRuntime.h"
#import "../Shared/LGSharedSupport.h"
#import <CoreVideo/CoreVideo.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
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
    float samplingOrientation;
    float hasShapeMask;
} LGUniforms;

static float LG_samplingOrientationForGlassView(UIView *view, LGUpdateGroup group) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return 1.0f;
    if (group == LGUpdateGroupLockscreen) return 1.0f;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = view.window.windowScene;
        if (scene) return (float)scene.interfaceOrientation;
    }
    return 1.0f;
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
static id<MTLCommandQueue>         sCommandQueues[LGUpdateGroupWidgets + 1];
static NSMapTable *sTextureCache = nil;
static NSMutableDictionary<NSNumber *, MPSImageGaussianBlur *> *sBlurKernelCache = nil;
static id<MTLTexture> sOpaqueMaskTexture = nil;
static dispatch_once_t sRuntimeInitOnce;
static atomic_bool sRuntimeReady = false;

static id<MTLCommandQueue> LGCommandQueueForUpdateGroup(LGUpdateGroup group) {
    NSInteger index = (group >= LGUpdateGroupAll && group <= LGUpdateGroupWidgets) ? group : LGUpdateGroupAll;
    return sCommandQueues[index] ?: sCommandQueues[LGUpdateGroupAll];
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
    }
    NSNumber *key = LGBlurSettingKey(sigma);
    MPSImageGaussianBlur *kernel = sBlurKernelCache[key];
    if (kernel) return kernel;
    kernel = [[MPSImageGaussianBlur alloc] initWithDevice:sDevice sigma:sigma];
    kernel.edgeMode = MPSImageEdgeModeClamp;
    sBlurKernelCache[key] = kernel;
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

        sCommandQueues[LGUpdateGroupAll] = [sDevice newCommandQueue];
        if (!sCommandQueues[LGUpdateGroupAll]) {
            LGLog(@"metal command queue creation failed");
            return;
        }
        for (NSInteger group = LGUpdateGroupDock; group <= LGUpdateGroupWidgets; group++) {
            sCommandQueues[group] = [sDevice newCommandQueue] ?: sCommandQueues[LGUpdateGroupAll];
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
    CGFloat _effectiveTextureScale;
    CGSize _lastLayoutBounds;
    CFTimeInterval _lastDrawSubmissionTime;
    UIImage *_shapeMaskImage;
    id<MTLTexture> _shapeMaskTexture;
    LGZeroCopyBridge *_shapeMaskBridge;
    LGZeroCopyBridge *_wallpaperTextureBridge;
    BOOL _usesExternalWallpaperTexture;
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
    return self;
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
    [self scheduleDraw];
}

- (void)setWallpaperImage:(UIImage *)img {
    if (!_usesExternalWallpaperTexture && _wallpaperImage == img) return;
    _usesExternalWallpaperTexture = NO;
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
    CGRect screenBoundsPx = CGRectMake(0, 0,
                                       UIScreen.mainScreen.bounds.size.width * scale,
                                       UIScreen.mainScreen.bounds.size.height * scale);
    if (!CGRectIntersectsRect(_cachedVisualRectPx, screenBoundsPx)) return;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && metricsChanged) {
        LGDebugLog(@"glass update group=%ld bounds=%@ visualPx=%@ screen=%@ origin=%@ wallpaper=%@",
                   (long)_updateGroup,
                   NSStringFromCGRect(self.bounds),
                   NSStringFromCGRect(_cachedVisualRectPx),
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
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
                                      self.window != nil);
    if (useDirectScreenConversion) {
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
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
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
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (_bgTexture && !_blurredTexture) [self _ensureBlurTexture];
    if (!sPipeline || !_bgTexture || !_blurredTexture) return;
    [self _refreshVisualMetrics];
    CGSize drawableSize = _cachedDrawableSizePx;
    if (drawableSize.width < 1 || drawableSize.height < 1) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!drawable || !passDesc) return;
    id<MTLCommandQueue> commandQueue = LGCommandQueueForUpdateGroup(_updateGroup);
    id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
    if (!cmdBuf) return;

    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width * scale;
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height * scale;

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

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        LGDebugLog(@"glass draw group=%ld screenPx={%.1f %.1f} visualPx=%@ drawable=%@ wallpaperPx=%@ wallpaperOrigin=%@",
                   (long)_updateGroup,
                   screenW, screenH,
                   NSStringFromCGRect(_cachedVisualRectPx),
                   NSStringFromCGSize(drawableSize),
                   NSStringFromCGSize(samplingWallpaperPixelSize),
                   NSStringFromCGPoint(_wallpaperOriginPt));
    }
    float imgW = (float)_bgTexture.width;
    float imgH = (float)_bgTexture.height;
    float fillScale = fmaxf((float)screenW / imgW, (float)screenH / imgH);
    float blurPx = (float)_blur * (float)scale / fillScale;

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
        .specularAngle = 2.2689280f,
        .blur = blurPx,
        .wallpaperOrigin = { (float)(_wallpaperOriginPt.x * scale),
                             (float)(_wallpaperOriginPt.y * scale) },
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
}

- (void)dealloc {
    if (_updateGroup != LGUpdateGroupAll)
        LG_unregisterGlassView(self, _updateGroup);
}

@end
