#import "LGBackButtonSupport.h"
#import "LGBannerCaptureSupport.h"
#import "LGGlassRenderer.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static void *kLGBackButtonBackdropViewKey = &kLGBackButtonBackdropViewKey;
static void *kLGBackButtonLiveStateKey = &kLGBackButtonLiveStateKey;
static void *kLGBackButtonDisplayLinkKey = &kLGBackButtonDisplayLinkKey;
static void *kLGBackButtonLastTimestampKey = &kLGBackButtonLastTimestampKey;

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
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, assign) CGFloat lg_scaleValue;
@property (nonatomic, assign) CGFloat lg_scaleTarget;
@property (nonatomic, assign) CGFloat lg_scaleVelocity;
@end

@implementation LGSharedBackButtonView

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithFrame:CGRectMake(0, 0, 38, 38)];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;
    _lg_scaleValue = 1.0;
    _lg_scaleTarget = 1.0;
    _lg_scaleVelocity = 0.0;

    _glassView = [[LGSharedGlassView alloc] initWithFrame:self.bounds sourceImage:nil sourceOrigin:CGPointZero];
    _glassView.userInteractionEnabled = NO;
    _glassView.releasesSourceAfterUpload = NO;
    _glassView.bezelWidth = 12.0;
    _glassView.glassThickness = 100.0;
    _glassView.refractionScale = 1.5;
    _glassView.refractiveIndex = 1.5;
    _glassView.specularOpacity = 0.03;
    _glassView.blur = 5.0;
    _glassView.sourceScale = 1.0;
    _glassView.cornerRadius = 19.0;
    [self addSubview:_glassView];

    _tintView = [[UIView alloc] initWithFrame:self.bounds];
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _tintView.layer.cornerRadius = 19.0;
    _tintView.layer.cornerCurve = kCACornerCurveContinuous;
    _tintView.layer.borderWidth = 0.75;
    _tintView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.14].CGColor;
    [_glassView addSubview:_tintView];

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
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightSemibold];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:config]];
    _glyphView.tintColor = UIColor.labelColor;
    _glyphView.contentMode = UIViewContentModeCenter;
    _glyphView.userInteractionEnabled = NO;
    [self addSubview:_glyphView];

    [NSLayoutConstraint activateConstraints:@[
        [_button.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_button.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_button.widthAnchor constraintEqualToConstant:38.0],
        [_button.heightAnchor constraintEqualToConstant:38.0],
    ]];

    return self;
}

- (void)dealloc {
    [self lg_stopScaleDisplayLink];
    [self cleanupBackdropCapture];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = CGRectGetHeight(self.bounds);
    self.glassView.frame = self.bounds;
    self.glassView.cornerRadius = side * 0.5;
    self.tintView.frame = self.glassView.bounds;
    self.tintView.layer.cornerRadius = side * 0.5;
    self.glyphView.frame = CGRectMake(floor((CGRectGetWidth(self.bounds) - 22.0) * 0.5) - 1.0,
                                      floor((CGRectGetHeight(self.bounds) - 22.0) * 0.5),
                                      22.0,
                                      22.0);
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

- (CGFloat)lg_currentScale {
    return self.lg_scaleValue;
}

- (void)lg_applyScaleValue {
    self.transform = CGAffineTransformMakeScale(self.lg_scaleValue, self.lg_scaleValue);
}

- (void)lg_stopScaleDisplayLink {
    CADisplayLink *displayLink = objc_getAssociatedObject(self, kLGBackButtonDisplayLinkKey);
    if (!displayLink) return;
    [displayLink invalidate];
    objc_setAssociatedObject(self, kLGBackButtonDisplayLinkKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, kLGBackButtonLastTimestampKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

- (void)lg_tickScaleDisplayLink:(CADisplayLink *)displayLink {
    NSNumber *lastValue = objc_getAssociatedObject(self, kLGBackButtonLastTimestampKey);
    CFTimeInterval lastTimestamp = lastValue ? lastValue.doubleValue : 0.0;
    CFTimeInterval rawDt = lastTimestamp > 0.0 ? fmin(displayLink.timestamp - lastTimestamp, 0.05) : (1.0 / 60.0);
    objc_setAssociatedObject(self, kLGBackButtonLastTimestampKey, @(displayLink.timestamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat stiffness = 320.0;
    CGFloat damping = 16.0;
    CGFloat remaining = (CGFloat)rawDt;
    const CGFloat maxSubstep = (1.0 / 120.0);
    while (remaining > 0.0) {
        CGFloat stepDt = fmin(remaining, maxSubstep);
        CGFloat force = (self.lg_scaleTarget - self.lg_scaleValue) * stiffness;
        CGFloat dampingForce = self.lg_scaleVelocity * damping;
        self.lg_scaleVelocity += (force - dampingForce) * stepDt;
        self.lg_scaleValue += self.lg_scaleVelocity * stepDt;
        remaining -= stepDt;
    }

    if (fabs(self.lg_scaleTarget - self.lg_scaleValue) < 0.0001 && fabs(self.lg_scaleVelocity) < 0.001) {
        self.lg_scaleValue = self.lg_scaleTarget;
        self.lg_scaleVelocity = 0.0;
        [self lg_applyScaleValue];
        [self lg_stopScaleDisplayLink];
        return;
    }

    [self lg_applyScaleValue];
}

- (void)setPressed:(BOOL)pressed {
    self.lg_scaleTarget = pressed ? 1.14 : 1.0;
    if (!objc_getAssociatedObject(self, kLGBackButtonDisplayLinkKey)) {
        CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(lg_tickScaleDisplayLink:)];
        [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, kLGBackButtonDisplayLinkKey, displayLink, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kLGBackButtonLastTimestampKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

- (void)cleanupBackdropCapture {
    LGRemoveLiveBackdropCaptureView(self, kLGBackButtonBackdropViewKey);
}

- (void)refreshBackdropAfterScreenUpdates:(BOOL)afterScreenUpdates {
    if (!self.window || CGRectIsEmpty(self.bounds)) return;

    CGPoint captureOrigin = CGPointZero;
    CGSize samplingResolution = CGSizeZero;
    if (LGCaptureLiveBackdropTextureForHost(self,
                                            self.glassView,
                                            kLGBackButtonBackdropViewKey,
                                            &captureOrigin,
                                            &samplingResolution)) {
        objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.glassView.wallpaperOrigin = captureOrigin;
        self.glassView.wallpaperSamplingResolution = samplingResolution;
        [self.glassView updateOrigin];
        [self.glassView scheduleDraw];
        return;
    }

    NSNumber *hadLive = objc_getAssociatedObject(self, kLGBackButtonLiveStateKey);
    objc_setAssociatedObject(self, kLGBackButtonLiveStateKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hadLive.boolValue) {
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
    self.glassView.sourceImage = snapshot;
    self.glassView.sourceOrigin = origin;
    self.glassView.wallpaperSamplingResolution = CGSizeZero;
    [self.glassView updateOrigin];
    [self.glassView scheduleDraw];
}

@end
