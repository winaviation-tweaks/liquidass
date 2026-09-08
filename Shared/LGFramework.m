#import "LGFramework.h"
#import <objc/message.h>

@implementation LGAdjustableBlurView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: CALayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _blurRadius = radius;
    _qualityScale = 0.35;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    [self applyFilters];
    return self;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.layer.cornerRadius = cornerRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyFilters];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyFilters];
}

- (void)setBlurRadius:(CGFloat)blurRadius {
    if (fabs(_blurRadius - blurRadius) <= 0.01) return;
    _blurRadius = blurRadius;
    [self applyFilters];
}

- (void)applyFilters {
    CALayer *layer = self.layer;
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    if (!backdropClass || ![layer isKindOfClass:backdropClass]) return;

    @try {
        [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@(!self.capturesAppIcon) forKey:@"windowServerAware"];
        if (self.capturesAppIcon) {
            [layer setValue:[NSString stringWithFormat:@"dylv.liquidglass.blur.%p", self]
                     forKey:@"groupName"];
        }
        [layer setValue:@(self.qualityScale) forKey:@"scale"];

        NSArray *existing = layer.filters;
        if (existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:@"gaussianBlur"]) {
                NSNumber *radius = nil;
                @try { radius = [existing.firstObject valueForKey:@"inputRadius"]; } @catch (...) {}
                if (radius && fabs(radius.doubleValue - self.blurRadius) < 0.01) return;
            }
        }

        Class filterClass = NSClassFromString(@"CAFilter");
        if (!filterClass) return;
        id filter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterClass, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
        if (filter) {
            [filter setValue:@(self.blurRadius) forKey:@"inputRadius"];
            layer.filters = @[filter];
        }
    } @catch (__unused NSException *exception) {}
}

@end

static UIImage *CreateRadialGlowImage(CGFloat diameter) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.95].CGColor,
                        (id)[UIColor colorWithWhite:1.0 alpha:0.60].CGColor,
                        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
    CGFloat locations[] = {0.0, 0.35, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, locations);

    CGPoint center = CGPointMake(diameter / 2.0, diameter / 2.0);
    CGContextDrawRadialGradient(ctx, gradient, center, 0.0, center, diameter / 2.0, kCGGradientDrawsAfterEndLocation);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@interface LGButtonView ()
@property (nonatomic, assign) NSTimeInterval touchDownTime;
@property (nonatomic, assign) uint64_t touchCycleId;
@end

@interface LGSpecularHighlightView ()
@property (nonatomic, strong) CAGradientLayer *specularRim;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@end

@implementation LGSpecularHighlightView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame cornerRadius:40.0];
}

- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)cornerRadius {
    self = [super initWithFrame:frame];
    if (self) {
        _cornerRadius = cornerRadius;
        _strokeWidth = 1.5;
        _topSpecularOpacity = 0.65;
        _bottomSpecularOpacity = 0.35;
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.specularRim = [CAGradientLayer layer];
        self.specularRim.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:_topSpecularOpacity].CGColor,
                                    (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
                                    (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
                                    (id)[UIColor colorWithWhite:1.0 alpha:_bottomSpecularOpacity].CGColor];
        self.specularRim.locations = @[@0.0, @0.35, @0.65, @1.0];
        self.specularRim.startPoint = CGPointMake(0, 0);
        self.specularRim.endPoint = CGPointMake(1, 1);
        self.rimMask = [CAShapeLayer layer];
        self.rimMask.fillColor = UIColor.clearColor.CGColor;
        self.rimMask.strokeColor = UIColor.whiteColor.CGColor;
        self.rimMask.lineWidth = _strokeWidth;
        self.specularRim.mask = self.rimMask;
        [self.layer addSublayer:self.specularRim];
    }
    return self;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.rimMask.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                  cornerRadius:cornerRadius].CGPath;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.specularRim.frame = self.bounds;
    self.rimMask.lineWidth = self.strokeWidth;
    self.rimMask.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                  cornerRadius:self.cornerRadius].CGPath;
}

@end

@implementation LGButtonView

- (void)commonInitWithBlurRadius:(CGFloat)blurRadius {
    self.clipsToBounds = NO;
    self.layer.masksToBounds = NO;
    self.backgroundColor = [UIColor clearColor];

    BOOL isCircular = fabs(self.bounds.size.width - self.bounds.size.height) < 1.0;
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    CALayerCornerCurve curve = isCircular ? kCACornerCurveCircular : kCACornerCurveContinuous;

    self.backgroundContainer = [[UIView alloc] initWithFrame:self.bounds];
    self.backgroundContainer.clipsToBounds = NO;
    self.backgroundContainer.layer.cornerRadius = radius;
    self.backgroundContainer.layer.cornerCurve = curve;
    self.backgroundContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    self.backgroundContainer.userInteractionEnabled = NO;
    [self addSubview:self.backgroundContainer];

    CAShapeLayer *containerMask = [CAShapeLayer layer];
    UIBezierPath *maskPath = isCircular ?
        [UIBezierPath bezierPathWithOvalInRect:self.backgroundContainer.bounds] :
        [UIBezierPath bezierPathWithRoundedRect:self.backgroundContainer.bounds cornerRadius:radius];
    containerMask.path = maskPath.CGPath;
    self.backgroundContainer.layer.mask = containerMask;

    self.blurView = [[LGAdjustableBlurView alloc] initWithFrame:self.backgroundContainer.bounds blurRadius:blurRadius];
    self.blurView.qualityScale = 0.35;
    self.blurView.clipsToBounds = NO;
    self.blurView.layer.cornerRadius = radius;
    self.blurView.layer.cornerCurve = curve;
    self.blurView.tag = 996;
    [self.backgroundContainer addSubview:self.blurView];

    self.lgView = [[LGLiveBackdropView alloc] initWithFrame:self.backgroundContainer.bounds
                                                  groupName:nil
                                                 filterType:LGFilterTypeForHostPrefix(@"PrefsButton")];
    self.lgView.clipsToBounds = NO;
    self.lgView.layer.cornerRadius = radius;
    self.lgView.layer.cornerCurve = curve;
    self.lgView.tag = 998;
    [self.backgroundContainer addSubview:self.lgView];

    self.darkTintView = [[UIView alloc] initWithFrame:self.backgroundContainer.bounds];
    self.darkTintView.userInteractionEnabled = NO;
    self.darkTintView.clipsToBounds = NO;
    self.darkTintView.layer.cornerRadius = radius;
    self.darkTintView.layer.cornerCurve = curve;
    self.darkTintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
        return trait.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.06] : [UIColor colorWithWhite:1.0 alpha:0.12];
    }];
    [self.backgroundContainer addSubview:self.darkTintView];

    CGFloat glowDiameter = MAX(self.bounds.size.width, self.bounds.size.height) * 2.2;
    self.innerGlowView = [[UIImageView alloc] initWithImage:CreateRadialGlowImage(glowDiameter)];
    self.innerGlowView.frame = CGRectMake(0, 0, glowDiameter, glowDiameter);
    self.innerGlowView.center = CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0);
    self.innerGlowView.alpha = 0.0;
    [self.backgroundContainer addSubview:self.innerGlowView];

    self.specularRimLayer = [CAGradientLayer layer];
    self.specularRimLayer.frame = self.backgroundContainer.bounds;
    self.specularRimLayer.startPoint = CGPointMake(0, 0);
    self.specularRimLayer.endPoint = CGPointMake(1, 1);
    self.specularRimLayer.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.75].CGColor,
                                     (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
                                     (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
                                     (id)[UIColor colorWithWhite:1.0 alpha:0.75].CGColor];
    self.specularRimLayer.locations = @[@0.0, @0.28, @0.72, @1.0];

    self.specularMaskLayer = [CAShapeLayer layer];
    UIBezierPath *rimPath = isCircular ?
        [UIBezierPath bezierPathWithOvalInRect:self.backgroundContainer.bounds] :
        [UIBezierPath bezierPathWithRoundedRect:self.backgroundContainer.bounds cornerRadius:radius];
    self.specularMaskLayer.path = rimPath.CGPath;
    self.specularMaskLayer.fillColor = [UIColor clearColor].CGColor;
    self.specularMaskLayer.strokeColor = [UIColor whiteColor].CGColor;
    self.specularMaskLayer.lineWidth = 1.2;
    self.specularRimLayer.mask = self.specularMaskLayer;
    [self.backgroundContainer.layer addSublayer:self.specularRimLayer];
}

- (instancetype)initWithFrame:(CGRect)frame symbolName:(NSString *)symbolName blurRadius:(CGFloat)blurRadius {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInitWithBlurRadius:blurRadius];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:21.0 weight:UIImageSymbolWeightSemibold];
        self.glyphImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:config]];
        self.glyphImageView.contentMode = UIViewContentModeCenter;
        self.glyphImageView.tintColor = [UIColor labelColor];
        self.glyphImageView.frame = self.bounds;
        self.glyphImageView.userInteractionEnabled = NO;
        [self addSubview:self.glyphImageView];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title blurRadius:(CGFloat)blurRadius {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInitWithBlurRadius:blurRadius];
        self.titleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.text = title;
        self.titleLabel.tag = 997;
        self.titleLabel.userInteractionEnabled = NO;
        [self addSubview:self.titleLabel];
    }
    return self;
}

- (void)updateLayoutWithFrame:(CGRect)frame {
    self.frame = frame;
    [self updateShapeWithTransform:CGAffineTransformIdentity shiftX:0 shiftY:0];
    if (self.titleLabel) self.titleLabel.frame = self.bounds;
    if (self.glyphImageView) self.glyphImageView.frame = self.bounds;
    if (self.menuAnchorButton) self.menuAnchorButton.frame = self.bounds;
}

- (CGSize)intrinsicContentSize {
    return self.bounds.size.width > 0 ? self.bounds.size : CGSizeMake(44.0, 44.0);
}

- (void)refreshGlass {
    [self.lgView applyFilters];
    [self.blurView applyFilters];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [self unclipHierarchy];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self unclipHierarchy];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self unclipHierarchy];

    BOOL isCircular = fabs(self.bounds.size.width - self.bounds.size.height) < 1.0;
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    CALayerCornerCurve curve = isCircular ? kCACornerCurveCircular : kCACornerCurveContinuous;

    if (self.backgroundContainer && !CGSizeEqualToSize(self.backgroundContainer.bounds.size, self.bounds.size)) {
        self.backgroundContainer.frame = self.bounds;
        self.blurView.frame = self.backgroundContainer.bounds;
        self.lgView.frame = self.backgroundContainer.bounds;
        self.darkTintView.frame = self.backgroundContainer.bounds;
        self.specularRimLayer.frame = self.backgroundContainer.bounds;

        self.backgroundContainer.layer.cornerRadius = radius;
        self.backgroundContainer.layer.cornerCurve = curve;
        self.blurView.layer.cornerRadius = radius;
        self.blurView.layer.cornerCurve = curve;
        self.lgView.layer.cornerRadius = radius;
        self.lgView.layer.cornerCurve = curve;
        self.darkTintView.layer.cornerRadius = radius;
        self.darkTintView.layer.cornerCurve = curve;
    }

    UIBezierPath *path = isCircular ?
        [UIBezierPath bezierPathWithOvalInRect:self.backgroundContainer.bounds] :
        [UIBezierPath bezierPathWithRoundedRect:self.backgroundContainer.bounds cornerRadius:radius];

    if (self.backgroundContainer.layer.mask && [self.backgroundContainer.layer.mask isKindOfClass:[CAShapeLayer class]]) {
        ((CAShapeLayer *)self.backgroundContainer.layer.mask).path = path.CGPath;
    }
    if (self.specularMaskLayer) {
        self.specularMaskLayer.path = path.CGPath;
    }
    if (self.menuAnchorButton) {
        self.menuAnchorButton.frame = self.bounds;
    }
}

- (void)unclipHierarchy {
    self.clipsToBounds = NO;
    self.layer.masksToBounds = NO;
    self.layer.zPosition = 9999;

    UIView *cur = self.superview;
    while (cur) {
        cur.clipsToBounds = NO;
        cur.layer.masksToBounds = NO;
        cur = cur.superview;
    }
}

static void LGDumpSubviewsAndLayers(UIView *view, int indent, NSMutableString *out) {
    if (!view) return;
    NSString *ind = [@"" stringByPaddingToLength:indent * 2 withString:@" " startingAtIndex:0];
    CALayer *l = view.layer;
    [out appendFormat:@"%@V[%@]: frame=%@ bounds=%@ clips=%d masks=%d mask=%@ radius=%.1f transform=%@\n",
        ind, NSStringFromClass(view.class), NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
        view.clipsToBounds, l.masksToBounds, l.mask ? NSStringFromClass(l.mask.class) : @"nil",
        l.cornerRadius, NSStringFromCGAffineTransform(view.transform)];

    for (CALayer *sublayer in l.sublayers) {
        if (sublayer.delegate != (id)view) {
            [out appendFormat:@"%@  L[%@]: frame=%@ bounds=%@ masks=%d mask=%@ radius=%.1f\n",
                ind, NSStringFromClass(sublayer.class), NSStringFromCGRect(sublayer.frame), NSStringFromCGRect(sublayer.bounds),
                sublayer.masksToBounds, sublayer.mask ? NSStringFromClass(sublayer.mask.class) : @"nil",
                sublayer.cornerRadius];
        }
    }

    for (UIView *sub in view.subviews) {
        LGDumpSubviewsAndLayers(sub, indent + 1, out);
    }
}

static void LGDumpButtonHierarchy(UIView *view) {
    @try {
        NSMutableString *str = [NSMutableString string];
        [str appendFormat:@"\n=== LGButtonView Hierarchy Dump ===\n"];
        [str appendFormat:@"--- Button Tree ---\n"];
        LGDumpSubviewsAndLayers(view, 0, str);

        [str appendFormat:@"--- Layer Superlayers ---\n"];
        CALayer *curLayer = view.layer;
        int layerDepth = 0;
        while (curLayer) {
            [str appendFormat:@"Layer[%d]: %@, frame=%@, bounds=%@, masks=%d, mask=%@, cornerRadius=%.1f, zPos=%.1f\n",
                layerDepth, NSStringFromClass(curLayer.class), NSStringFromCGRect(curLayer.frame), NSStringFromCGRect(curLayer.bounds),
                curLayer.masksToBounds, curLayer.mask ? NSStringFromClass(curLayer.mask.class) : @"nil",
                curLayer.cornerRadius, curLayer.zPosition];
            curLayer = curLayer.superlayer;
            layerDepth++;
        }

        [str appendFormat:@"--- View Superviews ---\n"];
        UIView *cur = view.superview;
        int depth = 1;
        while (cur) {
            [str appendFormat:@"Super[%d]: %@, frame: %@, bounds: %@, clips: %d, masks: %d, hasMaskLayer: %d, zPos: %.1f\n",
                depth, NSStringFromClass(cur.class), NSStringFromCGRect(cur.frame), NSStringFromCGRect(cur.bounds),
                cur.clipsToBounds, cur.layer.masksToBounds, (cur.layer.mask != nil), cur.layer.zPosition];
            cur = cur.superview;
            depth++;
        }

        if (view.superview) {
            [str appendFormat:@"--- Siblings in Superview (%@) ---\n", NSStringFromClass(view.superview.class)];
            for (UIView *sib in view.superview.subviews) {
                [str appendFormat:@"Sibling: %@, frame: %@, hidden: %d, alpha: %.2f, zPos: %.1f\n",
                    NSStringFromClass(sib.class), NSStringFromCGRect(sib.frame), sib.hidden, sib.alpha, sib.layer.zPosition];
            }
        }

        [str writeToFile:@"/var/tmp/button_obstruction_dump.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
}

- (void)updateShapeWithTransform:(CGAffineTransform)transform shiftX:(CGFloat)shiftX shiftY:(CGFloat)shiftY {
    self.backgroundContainer.transform = transform;
    if (self.glyphImageView) {
        self.glyphImageView.transform = transform;
    }
    if (self.titleLabel) {
        self.titleLabel.transform = transform;
    }
}

- (void)updateGlowPositionWithTouchPoint:(CGPoint)point shiftX:(CGFloat)shiftX shiftY:(CGFloat)shiftY {
    CGFloat cx = self.bounds.size.width / 2.0;
    CGFloat cy = self.bounds.size.height / 2.0;

    CGFloat dx = point.x - (cx + shiftX);
    CGFloat dy = point.y - (cy + shiftY);

    CGFloat R = MAX(self.bounds.size.width, self.bounds.size.height) * 0.5;
    CGFloat dist = sqrt(dx * dx + dy * dy);
    if (dist > R && dist > 0.001) {
        dx = (dx / dist) * R;
        dy = (dy / dist) * R;
    }

    self.innerGlowView.center = CGPointMake(cx + dx, cy + dy);
}

- (void)setPrimaryMenu:(UIMenu *)menu {
    _primaryMenu = menu;
    if (menu) {
        if (!self.menuAnchorButton) {
            self.menuAnchorButton = [UIButton buttonWithType:UIButtonTypeCustom];
            self.menuAnchorButton.frame = self.bounds;
            self.menuAnchorButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.menuAnchorButton.backgroundColor = [UIColor clearColor];
            self.menuAnchorButton.clipsToBounds = NO;
            self.menuAnchorButton.layer.masksToBounds = NO;
            [self.menuAnchorButton addTarget:self action:@selector(lg_menuButtonTouchDown) forControlEvents:UIControlEventTouchDown];
            [self.menuAnchorButton addTarget:self action:@selector(lg_menuButtonTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [self.menuAnchorButton addTarget:self action:@selector(lg_menuButtonTouchMoved:forEvent:) forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
            [self addSubview:self.menuAnchorButton];
            [self bringSubviewToFront:self.menuAnchorButton];
        }
        self.menuAnchorButton.menu = menu;
        self.menuAnchorButton.showsMenuAsPrimaryAction = YES;
    } else {
        [self.menuAnchorButton removeFromSuperview];
        self.menuAnchorButton = nil;
    }
}

- (void)lg_menuButtonTouchDown {
    [self handleTouchDownAtPoint:CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0)];
    uint64_t currentCycle = self.touchCycleId;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.isPressed && self.touchCycleId == currentCycle) {
            [self handleTouchEnded];
        }
    });
}

- (void)lg_menuButtonTouchUp {
    [self handleTouchEnded];
}

- (void)lg_menuButtonTouchMoved:(UIButton *)sender forEvent:(UIEvent *)event {
    UITouch *touch = [[event allTouches] anyObject];
    if (touch) {
        [self handleTouchMovedToPoint:[touch locationInView:self]];
    }
}

- (void)presentMenu {
    if (!self.primaryMenu) return;
    if (self.menuAnchorButton && self.menuAnchorButton.contextMenuInteraction && [self.menuAnchorButton.contextMenuInteraction respondsToSelector:@selector(_presentMenuAtLocation:)]) {
        CGPoint center = CGPointMake(CGRectGetMidX(self.menuAnchorButton.bounds), CGRectGetMidY(self.menuAnchorButton.bounds));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(self.menuAnchorButton.contextMenuInteraction, @selector(_presentMenuAtLocation:), center);
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    [self handleTouchDownAtPoint:point];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    [self handleTouchMovedToPoint:point];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    CGFloat dx = point.x - self.touchStartPoint.x;
    CGFloat dy = point.y - self.touchStartPoint.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);

    [self handleTouchEnded];

    if (dist < 55.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.actionHandler) {
                self.actionHandler();
            } else if (self.primaryMenu) {
                [self presentMenu];
            } else {
                [self sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
    } else {
        [self cancelTrackingWithEvent:event];
    }
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self handleTouchCancelled];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isPressed) {
        return CGRectContainsPoint(CGRectInset(self.bounds, -90.0, -90.0), point);
    }
    return [super pointInside:point withEvent:event];
}

- (void)handleTouchDownAtPoint:(CGPoint)point {
    self.isPressed = YES;
    self.touchStartPoint = point;
    self.touchDownTime = CACurrentMediaTime();
    self.touchCycleId++;

    [self unclipHierarchy];
    LGDumpButtonHierarchy(self);

    if (self.navigationController && self.navigationController.interactivePopGestureRecognizer) {
        self.navigationController.interactivePopGestureRecognizer.enabled = NO;
    }

    if (@available(iOS 13.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        [feedback prepare];
        [feedback impactOccurred];
    }

    [self updateGlowPositionWithTouchPoint:point shiftX:0 shiftY:0];

    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:1.2 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        CGAffineTransform pressTransform = CGAffineTransformMakeScale(1.10, 1.10);
        [self updateShapeWithTransform:pressTransform shiftX:0 shiftY:0];
        self.innerGlowView.transform = CGAffineTransformIdentity;
        self.innerGlowView.alpha = 0.90;
    } completion:nil];
}

- (void)handleTouchMovedToPoint:(CGPoint)point {
    if (!self.isPressed) {
        self.isPressed = YES;
        self.touchStartPoint = point;
        self.touchDownTime = CACurrentMediaTime();
        self.touchCycleId++;
    }

    [self unclipHierarchy];

    CGFloat dx = point.x - self.touchStartPoint.x;
    CGFloat dy = point.y - self.touchStartPoint.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);

    CGFloat shiftX = 0;
    CGFloat shiftY = 0;
    CGAffineTransform transform = CGAffineTransformIdentity;

    if (dist > 0.5) {
        CGFloat angle = atan2(dy, dx);

        CGFloat maxShift = 28.0;
        CGFloat pullFactor = 1.0 - (1.0 / ((dist * 0.025) + 1.0));
        CGFloat currentShift = pullFactor * maxShift;

        shiftX = cos(angle) * currentShift;
        shiftY = sin(angle) * currentShift;

        CGFloat stretchFactor = 1.10 * (1.0 + (pullFactor * 0.28));
        CGFloat squashFactor = 1.10 * (1.0 - (pullFactor * 0.08));

        transform = CGAffineTransformMakeTranslation(shiftX, shiftY);
        transform = CGAffineTransformRotate(transform, angle);
        transform = CGAffineTransformScale(transform, stretchFactor, squashFactor);
        transform = CGAffineTransformRotate(transform, -angle);
    } else {
        transform = CGAffineTransformMakeScale(1.10, 1.10);
    }

    [self updateShapeWithTransform:transform shiftX:shiftX shiftY:shiftY];
    [self updateGlowPositionWithTouchPoint:point shiftX:shiftX shiftY:shiftY];

    CGFloat scaleSpread = 1.0 + MIN(dist * 0.006, 0.45);
    self.innerGlowView.transform = CGAffineTransformMakeScale(scaleSpread, scaleSpread);
    self.innerGlowView.alpha = MIN(0.90 + (dist * 0.003), 1.0);
}

- (void)handleTouchEnded {
    if (!self.isPressed) return;
    self.isPressed = NO;

    if (self.navigationController && self.navigationController.interactivePopGestureRecognizer) {
        self.navigationController.interactivePopGestureRecognizer.enabled = YES;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.touchDownTime;
    NSTimeInterval minPressDuration = 0.12;
    NSTimeInterval delay = (elapsed < minPressDuration) ? (minPressDuration - elapsed) : 0.0;

    uint64_t currentCycle = self.touchCycleId;
    void (^performBounceRelease)(void) = ^{
        if (self.touchCycleId != currentCycle || self.isPressed) return;
        [UIView animateWithDuration:0.52 delay:0 usingSpringWithDamping:0.44 initialSpringVelocity:1.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            [self updateShapeWithTransform:CGAffineTransformIdentity shiftX:0 shiftY:0];
            self.innerGlowView.transform = CGAffineTransformIdentity;
            self.innerGlowView.alpha = 0.0;
        } completion:nil];
    };

    if (delay > 0.001) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), performBounceRelease);
    } else {
        performBounceRelease();
    }
}

- (void)handleTouchCancelled {
    [self handleTouchEnded];
}

@end

@implementation LGLiquidBlockerGesture

- (instancetype)init {
    self = [super initWithTarget:nil action:nil];
    if (self) {
        self.delegate = self;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesEnded = NO;
        self.delaysTouchesBegan = NO;
    }
    return self;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
    return YES;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end
