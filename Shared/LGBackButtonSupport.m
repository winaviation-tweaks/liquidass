#import "LGBackButtonSupport.h"
#import "LGBannerCaptureSupport.h"
#import "LGGlassMaterialView.h"
#import "LGGlassRenderer.h"
#import "LGHookSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *kLGBackButtonBackdropViewKey = &kLGBackButtonBackdropViewKey;
static void *kLGBackButtonLiveStateKey = &kLGBackButtonLiveStateKey;
static void *kLGBackButtonAnimatorKey = &kLGBackButtonAnimatorKey;
static void *kLGBackButtonLastRefreshTimeKey = &kLGBackButtonLastRefreshTimeKey;

static const CGFloat kLGBackButtonPressScale = 1.14;
static const CGFloat kLGBackButtonPressDuration = 0.3;
static const CGFloat kLGBackButtonPressMass = 0.8;
static const CGFloat kLGBackButtonPressStiffness = 300.0;
static const CGFloat kLGBackButtonPressDamping = 18.0;
static const CGFloat kLGBackButtonPressVelocity = 0.5;
static const CGFloat kLGBackButtonReleaseDuration = 0.5;
static const CGFloat kLGBackButtonReleaseMass = 0.8;
static const CGFloat kLGBackButtonReleaseStiffness = 300.0;
static const CGFloat kLGBackButtonReleaseDamping = 8.5;
static const CGFloat kLGBackButtonReleaseVelocity = 1.35;
static const CGFloat kLGBackButtonSideLength = 44.0;
static const CGFloat kLGBackButtonGlyphSideLength = 24.0;
static const CGFloat kLGLowFallbackBlurRadius = 3.0;
static const CFTimeInterval kLGBackButtonRefreshInterval = 1.0 / 30.0;

@interface LGLowBlurFallbackView : UIView
- (void)lg_configureLowBlurBackdropLayer;
@end

@implementation LGLowBlurFallbackView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    [self lg_configureLowBlurBackdropLayer];
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self lg_configureLowBlurBackdropLayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self lg_configureLowBlurBackdropLayer];
}

- (void)lg_configureLowBlurBackdropLayer {
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {
        [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@YES forKey:@"windowServerAware"];
        if (![layer valueForKey:@"groupName"]) {
            [layer setValue:NSUUID.UUID.UUIDString forKey:@"groupName"];
        }

        Class filterCls = NSClassFromString(@"CAFilter");
        id blurFilter = nil;
        SEL filterSelector = NSSelectorFromString(@"filterWithName:");
        if (filterCls && [filterCls respondsToSelector:filterSelector]) {
            blurFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterCls, filterSelector, @"gaussianBlur");
        }
        if (blurFilter) {
            [blurFilter setValue:@(kLGLowFallbackBlurRadius) forKey:@"inputRadius"];
            [blurFilter setValue:@YES forKey:@"inputNormalizeEdges"];
            layer.filters = @[blurFilter];
        }
    } @catch (NSException *exception) {
        LGDebugLog(@"low blur backdrop configure failed %@ %@", exception.name, exception.reason);
    }
}

@end

UIView *LGMakeLowBlurFallbackView(void) {
    return [[LGLowBlurFallbackView alloc] initWithFrame:CGRectZero];
}

static id LGClampedLowBlurValue(id value, CGFloat radius) {
    if (![value respondsToSelector:@selector(doubleValue)]) return value;
    CGFloat numericValue = [value doubleValue];
    if (numericValue <= radius) return value;
    return @(radius);
}

static NSUInteger LGClampLowBlurOnObject(id object, CGFloat radius) {
    if (!object) return 0;
    NSUInteger changedCount = 0;
    NSArray<NSString *> *candidateKeys = @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"];
    for (NSString *key in candidateKeys) {
        @try {
            id value = [object valueForKey:key];
            id clamped = LGClampedLowBlurValue(value, radius);
            if (clamped != value) {
                [object setValue:clamped forKey:key];
                changedCount++;
            }
        } @catch (NSException *exception) {
            LGDebugLog(@"low blur clamp failed key=%@ %@ %@", key, exception.name, exception.reason);
        }
    }
    return changedCount;
}

static NSUInteger LGClampLowBlurFilterArray(id filters, CGFloat radius) {
    if (![filters respondsToSelector:@selector(count)]) return 0;
    NSUInteger changedCount = 0;
    for (id filter in filters) {
        changedCount += LGClampLowBlurOnObject(filter, radius);
    }
    return changedCount;
}

static NSUInteger LGApplyLowBlurRadiusToLayer(CALayer *layer, CGFloat radius) {
    if (!layer) return 0;
    NSUInteger changedCount = LGClampLowBlurFilterArray(layer.filters, radius);
    @try {
        changedCount += LGClampLowBlurFilterArray([layer valueForKey:@"backgroundFilters"], radius);
    } @catch (NSException *exception) {
        LGDebugLog(@"low blur background filter read failed %@ %@", exception.name, exception.reason);
    }
    for (CALayer *sublayer in layer.sublayers) {
        changedCount += LGApplyLowBlurRadiusToLayer(sublayer, radius);
    }
    return changedCount;
}

void LGApplyLowBlurRadiusToViewWithRadius(UIView *view, CGFloat radius) {
    if (!view) return;
    CGFloat clampedRadius = fmax(0.0, radius);
    dispatch_async(dispatch_get_main_queue(), ^{
        LGApplyLowBlurRadiusToLayer(view.layer, clampedRadius);
    });
}

void LGApplyLowBlurRadiusToView(UIView *view) {
    LGApplyLowBlurRadiusToViewWithRadius(view, kLGLowFallbackBlurRadius);
}

static UIImage *LGCaptureBackButtonFallbackImage(UIView *captureView, CGRect captureRect, BOOL afterScreenUpdates) {
    if (!captureView || CGRectIsEmpty(captureRect)) return nil;
    if (!afterScreenUpdates) {
        UIView *snapshotView = [captureView resizableSnapshotViewFromRect:captureRect
                                                       afterScreenUpdates:NO
                                                            withCapInsets:UIEdgeInsetsZero];
        if (snapshotView) {
            UIGraphicsBeginImageContextWithOptions(captureRect.size, NO, 0.0);
            CGContextRef context = UIGraphicsGetCurrentContext();
            [snapshotView.layer renderInContext:context];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            return image;
        }
    }
    UIGraphicsBeginImageContextWithOptions(captureRect.size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
    BOOL drew = [captureView drawViewHierarchyInRect:captureView.bounds afterScreenUpdates:afterScreenUpdates];
    if (!drew) {
        [captureView.layer renderInContext:context];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

UIView *LGBackButtonPreferredContainerView(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UINavigationBar class]]) return candidate.superview ?: candidate;
        if ([candidate isKindOfClass:[UINavigationController class]]) return ((UINavigationController *)candidate).view ?: candidate;
    }
    if (view.window.rootViewController.view) return view.window.rootViewController.view;
    if (view.window) return view.window;
    return view.superview ?: view;
}

@interface LGSharedBackButtonView ()
@property (nonatomic, strong) LGSharedGlassView *glassView;
@property (nonatomic, strong) LGGlassMaterialView *materialView;
@property (nonatomic, strong) UIView *blurView;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, assign) CGFloat glyphHorizontalOffset;
@property (nonatomic, assign, getter=isGlassEnabled) BOOL glassEnabled;
@end

@implementation LGSharedBackButtonView

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    return [self initWithTarget:target action:action symbolName:@"chevron.left"];
}

- (instancetype)initWithTarget:(id)target action:(SEL)action symbolName:(NSString *)symbolName {
    self = [super initWithFrame:CGRectMake(0, 0, kLGBackButtonSideLength, kLGBackButtonSideLength)];
    if (!self) return nil;

    NSString *resolvedSymbolName = symbolName.length ? symbolName : @"chevron.left";
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;
    _glassEnabled = YES;
    _glyphHorizontalOffset = 0.0;

    _glassView = [[LGSharedGlassView alloc] initWithFrame:self.bounds sourceImage:nil sourceOrigin:CGPointZero];
    _glassView.userInteractionEnabled = NO;
    _glassView.releasesSourceAfterUpload = NO;
    _glassView.bezelWidth = 12.0;
    _glassView.glassThickness = 100.0;
    _glassView.refractionScale = 1.5;
    _glassView.refractiveIndex = 1.5;
    _glassView.specularOpacity = 0.03;
    _glassView.blur = 3.0;
    _glassView.sourceScale = 1.0;
    _glassView.cornerRadius = 19.0;
    _glassView.hidden = YES;
    [self addSubview:_glassView];

    _blurView = LGMakeLowBlurFallbackView();
    _blurView.frame = self.bounds;
    _blurView.userInteractionEnabled = NO;
    _blurView.hidden = NO;
    _blurView.layer.cornerRadius = 19.0;
    _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    _blurView.layer.masksToBounds = YES;
    [self addSubview:_blurView];
    LGApplyLowBlurRadiusToView(_blurView);

    _tintView = [[UIView alloc] initWithFrame:self.bounds];
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = LGCustomTintColorForKey(@"Preferences.BackButton.CustomTintColor") ?: [UIColor colorWithWhite:1.0 alpha:0.10];
    _tintView.layer.cornerRadius = 19.0;
    _tintView.layer.cornerCurve = kCACornerCurveContinuous;
    _tintView.layer.borderWidth = 0.75;
    _tintView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.14].CGColor;
    [self addSubview:_tintView];

    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    if (target && action) {
        [_button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        [_button addTarget:self action:@selector(lg_touchDown) forControlEvents:UIControlEventTouchDown];
        [_button addTarget:self action:@selector(lg_touchDragEnter) forControlEvents:UIControlEventTouchDragEnter];
        [_button addTarget:self action:@selector(lg_touchDragExit) forControlEvents:UIControlEventTouchDragExit];
        [_button addTarget:self action:@selector(lg_touchUp) forControlEvents:UIControlEventTouchUpInside];
        [_button addTarget:self action:@selector(lg_touchUp) forControlEvents:UIControlEventTouchUpOutside];
        [_button addTarget:self action:@selector(lg_touchUp) forControlEvents:UIControlEventTouchCancel];
    } else {
        _button.userInteractionEnabled = NO;
    }
    [self addSubview:_button];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightRegular];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:resolvedSymbolName
                                                             withConfiguration:config]];
    _glyphView.tintColor = UIColor.labelColor;
    _glyphView.contentMode = UIViewContentModeCenter;
    _glyphView.userInteractionEnabled = NO;
    [self addSubview:_glyphView];

    [NSLayoutConstraint activateConstraints:@[
        [_button.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_button.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_button.widthAnchor constraintEqualToConstant:kLGBackButtonSideLength],
        [_button.heightAnchor constraintEqualToConstant:kLGBackButtonSideLength],
    ]];

    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kLGBackButtonSideLength, kLGBackButtonSideLength);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && self.isGlassEnabled) {
        [self scheduleBackdropWarmupRefresh];
    }
}

- (void)dealloc {
    UIViewPropertyAnimator *animator = objc_getAssociatedObject(self, kLGBackButtonAnimatorKey);
    [animator stopAnimation:YES];
    objc_setAssociatedObject(self, kLGBackButtonAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [self cleanupBackdropCapture];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = CGRectGetHeight(self.bounds);
    self.materialView.frame = self.bounds;
    self.materialView.cornerRadius = side * 0.5;
    self.glassView.frame = self.bounds;
    self.glassView.cornerRadius = side * 0.5;
    self.blurView.frame = self.bounds;
    self.blurView.layer.cornerRadius = side * 0.5;
    LGApplyLowBlurRadiusToView(self.blurView);
    self.tintView.frame = self.glassView.bounds;
    self.tintView.backgroundColor = LGCustomTintColorForKey(@"Preferences.BackButton.CustomTintColor") ?: [UIColor colorWithWhite:1.0 alpha:0.10];
    self.tintView.layer.cornerRadius = side * 0.5;
    self.glyphView.frame = CGRectMake(floor((CGRectGetWidth(self.bounds) - kLGBackButtonGlyphSideLength) * 0.5) + self.glyphHorizontalOffset,
                                      floor((CGRectGetHeight(self.bounds) - kLGBackButtonGlyphSideLength) * 0.5),
                                      kLGBackButtonGlyphSideLength,
                                      kLGBackButtonGlyphSideLength);
}

- (void)setGlassEnabled:(BOOL)glassEnabled {
    if (_glassEnabled == glassEnabled) return;
    _glassEnabled = glassEnabled;
    BOOL liveReady = [objc_getAssociatedObject(self, kLGBackButtonLiveStateKey) boolValue];
    self.glassView.hidden = self.materialView != nil || !glassEnabled || !liveReady;
    self.blurView.hidden = self.materialView != nil || (glassEnabled && liveReady);
    LGApplyLowBlurRadiusToView(self.blurView);
    if (!glassEnabled) {
        objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kLGBackButtonLastRefreshTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        [self cleanupBackdropCapture];
        [self lg_removeServerMaterial];
    } else {
        [self scheduleBackdropWarmupRefresh];
    }
}

- (void)lg_touchDown {
    [self setPressed:YES];
}

- (void)lg_touchDragEnter {
    [self setPressed:YES];
}

- (void)lg_touchDragExit {
    [self setPressed:NO];
}

- (void)lg_touchUp {
    [self setPressed:NO];
}

- (void)lg_syncPresentationTransform {
    CALayer *presentation = self.layer.presentationLayer;
    if (!presentation) return;
    self.transform = CATransform3DGetAffineTransform(presentation.transform);
}

- (void)setPressed:(BOOL)pressed {
    CGAffineTransform targetTransform = pressed
        ? CGAffineTransformMakeScale(kLGBackButtonPressScale, kLGBackButtonPressScale)
        : CGAffineTransformIdentity;
    CGFloat duration = pressed ? kLGBackButtonPressDuration : kLGBackButtonReleaseDuration;
    CGFloat mass = pressed ? kLGBackButtonPressMass : kLGBackButtonReleaseMass;
    CGFloat stiffness = pressed ? kLGBackButtonPressStiffness : kLGBackButtonReleaseStiffness;
    CGFloat damping = pressed ? kLGBackButtonPressDamping : kLGBackButtonReleaseDamping;
    CGFloat velocity = pressed ? kLGBackButtonPressVelocity : kLGBackButtonReleaseVelocity;

    UIViewPropertyAnimator *existingAnimator = objc_getAssociatedObject(self, kLGBackButtonAnimatorKey);
    if (existingAnimator) {
        [self lg_syncPresentationTransform];
        [existingAnimator stopAnimation:YES];
        objc_setAssociatedObject(self, kLGBackButtonAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass
        stiffness:stiffness
        damping:damping
        initialVelocity:CGVectorMake(velocity, velocity)];
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:timing];
    animator.interruptible = YES;
    [animator addAnimations:^{
        self.transform = targetTransform;
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition finalPosition) {
        self.transform = targetTransform;
        objc_setAssociatedObject(self, kLGBackButtonAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }];
    [animator startAnimation];
    objc_setAssociatedObject(self, kLGBackButtonAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)cleanupBackdropCapture {
    LGRemoveLiveBackdropCaptureView(self, kLGBackButtonBackdropViewKey);
}

- (void)lg_ensureServerMaterial {
    if (!self.materialView) {
        LGGlassMaterialView *material = [[LGGlassMaterialView alloc] initWithFrame:self.bounds];
        material.blur = self.glassView.blur;
        material.rimWidth = 2.0;
        [self insertSubview:material atIndex:0];
        self.materialView = material;
        [self cleanupBackdropCapture];
    }
    self.materialView.frame = self.bounds;
    self.materialView.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    self.glassView.hidden = YES;
    self.blurView.hidden = YES;
}

- (void)lg_removeServerMaterial {
    if (!self.materialView) return;
    [self.materialView removeFromSuperview];
    self.materialView = nil;
}

- (void)refreshBackdropAfterScreenUpdates:(BOOL)afterScreenUpdates force:(BOOL)force {
    if (!self.isGlassEnabled) return;
    if (!self.window || CGRectIsEmpty(self.bounds)) return;

    if (LG_serverMaterialAvailable()) {
        [self lg_ensureServerMaterial];
        return;
    }
    [self lg_removeServerMaterial];

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRefresh = objc_getAssociatedObject(self, kLGBackButtonLastRefreshTimeKey);
    if (!force && lastRefresh && (now - lastRefresh.doubleValue) < kLGBackButtonRefreshInterval) return;
    objc_setAssociatedObject(self,
                             kLGBackButtonLastRefreshTimeKey,
                             @(now),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL liveReady = [objc_getAssociatedObject(self, kLGBackButtonLiveStateKey) boolValue];
    self.glassView.hidden = !liveReady;
    self.blurView.hidden = liveReady;
    LGApplyLowBlurRadiusToView(self.blurView);

    CGPoint captureOrigin = CGPointZero;
    CGSize samplingResolution = CGSizeZero;
    if (LGCaptureLiveBackdropTextureForHost(self,
                                            self.glassView,
                                            kLGBackButtonBackdropViewKey,
                                            &captureOrigin,
                                            &samplingResolution)) {
        objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.glassView.hidden = NO;
        self.blurView.hidden = YES;
        self.glassView.wallpaperOrigin = captureOrigin;
        self.glassView.wallpaperSamplingResolution = samplingResolution;
        [self.glassView updateOrigin];
        [self.glassView scheduleDraw];
        return;
    }

    NSNumber *hadLive = objc_getAssociatedObject(self, kLGBackButtonLiveStateKey);
    objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hadLive.boolValue) {
        self.glassView.hidden = NO;
        self.blurView.hidden = YES;
        [self.glassView updateOrigin];
        [self.glassView scheduleDraw];
        return;
    }

    UIView *captureView = LGBackButtonPreferredContainerView(self);
    BOOL oldHidden = self.hidden;
    CGFloat oldAlpha = self.alpha;
    self.hidden = YES;
    self.alpha = 0.0;
    CGRect captureRect = [self convertRect:self.bounds toView:captureView];
    captureRect = CGRectInset(captureRect, -18.0, -18.0);
    captureRect = CGRectIntersection(captureView.bounds, captureRect);
    UIImage *snapshot = LGCaptureBackButtonFallbackImage(captureView, captureRect, afterScreenUpdates);
    CGPoint origin = [captureView convertPoint:captureRect.origin toView:nil];
    self.hidden = oldHidden;
    self.alpha = oldAlpha;
    if (!snapshot) {
        self.glassView.hidden = YES;
        self.blurView.hidden = NO;
        LGApplyLowBlurRadiusToView(self.blurView);
        return;
    }
    self.glassView.hidden = NO;
    self.blurView.hidden = YES;
    objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.glassView.sourceImage = snapshot;
    self.glassView.sourceOrigin = origin;
    self.glassView.wallpaperSamplingResolution = CGSizeZero;
    [self.glassView updateOrigin];
    [self.glassView scheduleDraw];
}

- (void)refreshBackdropAfterScreenUpdates:(BOOL)afterScreenUpdates {
    [self refreshBackdropAfterScreenUpdates:afterScreenUpdates force:NO];
}

- (void)scheduleBackdropWarmupRefresh {
    [self refreshBackdropAfterScreenUpdates:NO force:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshBackdropAfterScreenUpdates:YES force:YES];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBackdropAfterScreenUpdates:YES force:YES];
    });
}

@end
