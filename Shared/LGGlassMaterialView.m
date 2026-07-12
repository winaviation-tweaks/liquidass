#import "LGGlassMaterialView.h"
#import "../LiquidGlass.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// All CABackdropLayer/CAFilter access goes through NSClassFromString + KVC so
// we never link against private symbols. Group-name buckets quantize the
// material parameters; every view in a bucket commits the same groupName,
// scale and filter stack, so the render server's BackdropGroup cache
// collapses them into a single capture+blur pass.

static Class LGBackdropLayerClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"CABackdropLayer"); });
    return cls;
}

static Class LGCAFilterClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"CAFilter"); });
    return cls;
}

static id LGMakeCAFilter(NSString *name) {
    Class cls = LGCAFilterClass();
    SEL sel = NSSelectorFromString(@"filterWithName:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(Class, SEL, NSString *))objc_msgSend)(cls, sel, name);
}

static void LGFilterSetValue(id filter, id value, NSString *key) {
    if (!filter) return;
    @try {
        [filter setValue:value forKey:key];
    } @catch (NSException *exception) {
        LGDebugLog(@"material filter key %@ rejected: %@", key, exception.reason ?: exception.name);
    }
}

static CGFloat LGMaterialCaptureScale(void) {
    // Part of the server-side group cache key (exact float match), so it must
    // be identical for every layer in a bucket — read once, never per-view.
    static CGFloat scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scale = LG_prefFloat(@"ServerMaterial.CaptureScale", 0.25);
        scale = fmax(0.1, fmin(scale, 1.0));
    });
    return scale;
}

static NSString *LGMaterialGroupName(CGFloat blur, CGFloat saturation, CGFloat brightness, NSString *variant) {
    // Quantize so slider jitter doesn't mint new buckets.
    return [NSString stringWithFormat:@"liquidass.%@.b%ld.s%ld.br%ld",
            variant,
            lround(blur * 2.0),
            lround(saturation * 20.0),
            lround(brightness * 20.0)];
}

@implementation LGGlassMaterialView {
    CAGradientLayer *_specularLayer;
    CAGradientLayer *_rimGradientLayer;
    CAShapeLayer *_rimMaskLayer;
    NSMutableArray<CALayer *> *_rimZoomStrips;
    CALayer *_shapeMaskLayer;
    NSString *_appliedGroupName;
    BOOL _filtersDirty;
    BOOL _registered;
}

static NSHashTable<LGGlassMaterialView *> *LGMaterialViewRegistry(void) {
    static NSHashTable *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSHashTable weakObjectsHashTable]; });
    return registry;
}

+ (Class)layerClass {
    return LGBackdropLayerClass() ?: [CALayer class];
}

+ (void)updateAllSpecularAngles:(CGFloat)angle {
    LGAssertMainThread();
    for (LGGlassMaterialView *view in LGMaterialViewRegistry()) {
        if (!view.window || view.hidden) continue;
        view.specularAngle = angle;
    }
}

+ (BOOL)isSupported {
    return LG_serverMaterialAvailable();
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _cornerRadius = 13.5;
    _blur = 8;
    _saturation = 1.6;
    _brightness = 0.0;
    _specularOpacity = 0.0;
    _rimWidth = 3.0;
    _rimMode = LGGlassRimModeGradient;
    _updateGroup = LGUpdateGroupAll;
    _filtersDirty = YES;

    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = _cornerRadius;
    if (@available(iOS 13.0, *))
        self.layer.cornerCurve = kCACornerCurveContinuous;

    [self _configureBackdropLayer:self.layer zoom:1.0];
    [self _rebuildOverlays];
    [LGMaterialViewRegistry() addObject:self];
    return self;
}

- (void)_configureBackdropLayer:(CALayer *)layer zoom:(CGFloat)zoom {
    if (![layer isKindOfClass:LGBackdropLayerClass()]) return;
    @try {
        [layer setValue:@(LGMaterialCaptureScale()) forKey:@"scale"];
        [layer setValue:@YES forKey:@"reducesCaptureBitDepth"];
        [layer setValue:@YES forKey:@"disablesOccludedBackdropBlurs"];
        if (zoom != 1.0) [layer setValue:@(zoom) forKey:@"zoom"];
    } @catch (NSException *exception) {
        LGDebugLog(@"material backdrop configuration failed %@ %@", exception.name, exception.reason);
    }
}

- (NSArray *)_materialFilters {
    NSMutableArray *filters = [NSMutableArray array];
    if (_blur >= 0.25) {
        id blur = LGMakeCAFilter(@"gaussianBlur");
        LGFilterSetValue(blur, @(_blur), @"inputRadius");
        LGFilterSetValue(blur, @YES, @"inputHardEdges");
        if (blur) [filters addObject:blur];
    }
    if (fabs(_saturation - 1.0) > 0.01) {
        id saturate = LGMakeCAFilter(@"colorSaturate");
        LGFilterSetValue(saturate, @(_saturation), @"inputAmount");
        if (saturate) [filters addObject:saturate];
    }
    if (fabs(_brightness) > 0.01) {
        id brighten = LGMakeCAFilter(@"colorBrightness");
        LGFilterSetValue(brighten, @(_brightness), @"inputAmount");
        if (brighten) [filters addObject:brighten];
    }
    return filters;
}

- (void)_applyFiltersIfNeeded {
    if (!_filtersDirty) return;
    _filtersDirty = NO;

    NSArray *filters = [self _materialFilters];
    NSString *groupName = LGMaterialGroupName(_blur, _saturation, _brightness, @"mat");
    self.layer.filters = filters.count ? filters : nil;
    if (![_appliedGroupName isEqualToString:groupName]) {
        _appliedGroupName = [groupName copy];
        @try {
            [self.layer setValue:groupName forKey:@"groupName"];
        } @catch (NSException *exception) {
            LGDebugLog(@"material groupName rejected %@", exception.reason ?: exception.name);
        }
    }
    [self _syncRimZoomStripFilters];
}

#pragma mark - Overlays

- (void)_rebuildOverlays {
    [self _rebuildSpecularLayer];
    [self _rebuildRimTreatment];
}

- (void)_rebuildSpecularLayer {
    if (_specularOpacity <= 0.01) {
        [_specularLayer removeFromSuperlayer];
        _specularLayer = nil;
        return;
    }
    if (!_specularLayer) {
        _specularLayer = [CAGradientLayer layer];
        _specularLayer.type = kCAGradientLayerAxial;
        id screen = LGMakeCAFilter(@"screenBlendMode");
        if (screen) _specularLayer.compositingFilter = screen;
        [self.layer addSublayer:_specularLayer];
    }
    UIColor *peak = [UIColor colorWithWhite:1.0 alpha:_specularOpacity * 0.18];
    UIColor *shoulder = [UIColor colorWithWhite:1.0 alpha:_specularOpacity * 0.05];
    _specularLayer.colors = @[(id)UIColor.clearColor.CGColor,
                              (id)shoulder.CGColor,
                              (id)peak.CGColor,
                              (id)shoulder.CGColor,
                              (id)UIColor.clearColor.CGColor];
    _specularLayer.locations = @[@0.0, @0.35, @0.5, @0.65, @1.0];
    [self _applySpecularAngle];
}

- (void)_applySpecularAngle {
    if (!_specularLayer) return;
    // Gradient line through the center along the motion angle; the implicit
    // 0.25s animation smooths the ~15 Hz motion updates server-side.
    CGFloat dx = sin(_specularAngle);
    CGFloat dy = -cos(_specularAngle);
    _specularLayer.startPoint = CGPointMake(0.5 - 0.5 * dx, 0.5 - 0.5 * dy);
    _specularLayer.endPoint = CGPointMake(0.5 + 0.5 * dx, 0.5 + 0.5 * dy);
}

- (void)_rebuildRimTreatment {
    [_rimGradientLayer removeFromSuperlayer];
    _rimGradientLayer = nil;
    _rimMaskLayer = nil;
    for (CALayer *strip in _rimZoomStrips) [strip removeFromSuperlayer];
    [_rimZoomStrips removeAllObjects];

    if (_rimMode == LGGlassRimModeNone || _rimWidth <= 0.1) return;

    if (_rimMode == LGGlassRimModeGradient) {
        _rimGradientLayer = [CAGradientLayer layer];
        _rimGradientLayer.type = kCAGradientLayerAxial;
        _rimGradientLayer.startPoint = CGPointMake(0.2, 0.0);
        _rimGradientLayer.endPoint = CGPointMake(0.8, 1.0);
        _rimGradientLayer.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.40].CGColor,
                                     (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor,
                                     (id)[UIColor colorWithWhite:0.15 alpha:0.10].CGColor,
                                     (id)[UIColor colorWithWhite:1.0 alpha:0.28].CGColor];
        _rimGradientLayer.locations = @[@0.0, @0.35, @0.75, @1.0];
        id screen = LGMakeCAFilter(@"screenBlendMode");
        if (screen) _rimGradientLayer.compositingFilter = screen;
        _rimMaskLayer = [CAShapeLayer layer];
        _rimMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _rimMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _rimGradientLayer.mask = _rimMaskLayer;
        [self.layer addSublayer:_rimGradientLayer];
        return;
    }

    // Zoom strips: thin backdrop slivers whose slightly magnified sampling of
    // the content behind reads as edge refraction. One extra shared group per
    // material bucket (same zoom + groupName across all views in the bucket).
    if (!LGBackdropLayerClass()) return;
    _rimZoomStrips = [NSMutableArray array];
    CGFloat zoom = LG_prefFloat(@"ServerMaterial.RimZoom", 1.06);
    for (NSUInteger i = 0; i < 4; i++) {
        CALayer *strip = [LGBackdropLayerClass() layer];
        strip.masksToBounds = YES;
        [self _configureBackdropLayer:strip zoom:zoom];
        [self.layer addSublayer:strip];
        [_rimZoomStrips addObject:strip];
    }
    [self _syncRimZoomStripFilters];
}

- (void)_syncRimZoomStripFilters {
    if (!_rimZoomStrips.count) return;
    NSString *groupName = LGMaterialGroupName(_blur, _saturation, _brightness, @"rim");
    for (CALayer *strip in _rimZoomStrips) {
        strip.filters = [self _materialFilters];
        @try {
            [strip setValue:groupName forKey:@"groupName"];
        } @catch (__unused NSException *exception) {
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self _applyFiltersIfNeeded];

    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _specularLayer.frame = bounds;

    if (_rimGradientLayer) {
        _rimGradientLayer.frame = bounds;
        _rimMaskLayer.frame = bounds;
        _rimMaskLayer.lineWidth = _rimWidth;
        CGFloat inset = _rimWidth * 0.5;
        CGFloat radius = MAX(0.0, _cornerRadius - inset);
        _rimMaskLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, inset, inset)
                                                        cornerRadius:radius].CGPath;
    }

    if (_rimZoomStrips.count == 4) {
        CGFloat w = _rimWidth;
        _rimZoomStrips[0].frame = CGRectMake(0, 0, bounds.size.width, w);
        _rimZoomStrips[1].frame = CGRectMake(0, bounds.size.height - w, bounds.size.width, w);
        _rimZoomStrips[2].frame = CGRectMake(0, w, w, bounds.size.height - 2 * w);
        _rimZoomStrips[3].frame = CGRectMake(bounds.size.width - w, w, w, bounds.size.height - 2 * w);
    }

    if (_shapeMaskLayer) _shapeMaskLayer.frame = bounds;
    [CATransaction commit];
}

#pragma mark - Properties

- (void)setCornerRadius:(CGFloat)radius {
    if (fabs(_cornerRadius - radius) < 0.001) return;
    _cornerRadius = radius;
    self.layer.cornerRadius = radius;
    [self setNeedsLayout];
}

- (void)setBlur:(CGFloat)blur {
    if (fabs(_blur - blur) < 0.001) return;
    _blur = blur;
    _filtersDirty = YES;
    [self setNeedsLayout];
}

- (void)setSaturation:(CGFloat)saturation {
    if (fabs(_saturation - saturation) < 0.001) return;
    _saturation = saturation;
    _filtersDirty = YES;
    [self setNeedsLayout];
}

- (void)setBrightness:(CGFloat)brightness {
    if (fabs(_brightness - brightness) < 0.001) return;
    _brightness = brightness;
    _filtersDirty = YES;
    [self setNeedsLayout];
}

- (void)setSpecularOpacity:(CGFloat)opacity {
    if (fabs(_specularOpacity - opacity) < 0.001) return;
    _specularOpacity = opacity;
    [self _rebuildSpecularLayer];
}

- (void)setSpecularAngle:(CGFloat)angle {
    if (fabs(_specularAngle - angle) < 0.0005) return;
    _specularAngle = angle;
    [self _applySpecularAngle];
}

- (void)setRimWidth:(CGFloat)width {
    if (fabs(_rimWidth - width) < 0.001) return;
    _rimWidth = width;
    [self setNeedsLayout];
}

- (void)setRimMode:(LGGlassRimMode)mode {
    if (_rimMode == mode) return;
    _rimMode = mode;
    [self _rebuildRimTreatment];
    [self setNeedsLayout];
}

- (void)setShapeMaskImage:(UIImage *)image {
    if (_shapeMaskImage == image || [_shapeMaskImage isEqual:image]) return;
    _shapeMaskImage = image;
    if (!image) {
        self.layer.mask = nil;
        _shapeMaskLayer = nil;
        return;
    }
    if (!_shapeMaskLayer) {
        _shapeMaskLayer = [CALayer layer];
        self.layer.mask = _shapeMaskLayer;
    }
    _shapeMaskLayer.contents = (id)image.CGImage;
    _shapeMaskLayer.contentsScale = image.scale;
    [self setNeedsLayout];
}

- (void)setUpdateGroup:(NSInteger)group {
    if (_updateGroup == group) return;
    if (_registered)
        LG_unregisterGlassView(self, (LGUpdateGroup)_updateGroup);
    _updateGroup = group;
    _registered = (group != LGUpdateGroupAll);
    if (_registered)
        LG_registerGlassView(self, (LGUpdateGroup)group);
}

#pragma mark - Registry entry points

- (void)updateOrigin {
    // The backdrop samples live content server-side; nothing to recompute.
}

- (void)scheduleDraw {
    // Redraw ticks only carry specular-motion changes for material views.
    self.specularAngle = LG_currentSpecularMotionAngle();
}

- (void)dealloc {
    if (_registered)
        LG_unregisterGlassView(self, (LGUpdateGroup)_updateGroup);
}

@end
