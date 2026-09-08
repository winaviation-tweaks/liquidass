#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface CCUIContinuousSliderView : UIControl
@end

@interface SBElasticSliderView : CCUIContinuousSliderView
@end

@interface SBElasticVolumeSliderView : SBElasticSliderView
@end

@interface SBElasticSliderMaterialWrapperView : UIView {
    MTMaterialView *_captureOnlyMaterialView;
    MTMaterialView *_baseMaterialView;
    UIView *_shadowView;
    UIView *_sliderWrapperView;
    UIView *_maskView;
    SBElasticVolumeSliderView *_sliderView;
}
- (void)_setContinuousCornerRadius:(double)radius;
@end

@interface LGVolumeHUDVibranceView : UIView
@end

@implementation LGVolumeHUDVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;

static BOOL LGVolumeHUDEnabled(void) {
    return lgHostEnabled(@"VolumeHUD");
}

static UIView *LGVolumeHUDSliderBackground(UIView *slider) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *subview in slider.subviews)
        if ([subview isKindOfClass:materialClass]) return subview;
    return nil;
}

static void LGUpdateVolumeHUDGlass(SBElasticSliderMaterialWrapperView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTMaterialView *cap = nil;
    UIView *shadow = nil;
    UIView *sliderWrapper = nil;
    UIView *sliderView = nil;
    @try {
        base = [self valueForKey:@"_baseMaterialView"];
        cap = [self valueForKey:@"_captureOnlyMaterialView"];
        shadow = [self valueForKey:@"_shadowView"];
        sliderWrapper = [self valueForKey:@"_sliderWrapperView"];
        sliderView = [self valueForKey:@"_sliderView"];
    } @catch (...) {}

    if (!LGVolumeHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGVolumeHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        if (cap) cap.hidden = NO;
        if (shadow) shadow.hidden = NO;
        LGVolumeHUDSliderBackground(sliderView).hidden = NO;
        return;
    }

    if (base) base.hidden = YES;
    if (cap) cap.hidden = YES;
    if (shadow) shadow.hidden = YES;

    LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (sliderWrapper) {
                [self insertSubview:vibrance belowSubview:sliderWrapper];
            } else {
                [self addSubview:vibrance];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGVolumeHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (sliderWrapper) {
            [self insertSubview:glass belowSubview:sliderWrapper];
        } else {
            [self addSubview:glass];
        }
    }

    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (sliderWrapper) {
        sliderWrapper.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderWrapper.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderWrapper.layer.masksToBounds = YES;
    }

    if (sliderView) {
        LGVolumeHUDSliderBackground(sliderView).hidden = YES;
        sliderView.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderView.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderView.layer.masksToBounds = YES;
    }
}

%group LGVolumeHUDHooks

%hook SBElasticSliderMaterialWrapperView

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (instancetype)initWithSliderView:(id)sliderView {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (void)layoutSubviews {
    %orig;
    LGUpdateVolumeHUDGlass(self);
}

- (void)_setContinuousCornerRadius:(double)radius {
    if (LGVolumeHUDEnabled()) {
        CGFloat pillRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;
        %orig((double)pillRadius);
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (glass) {
            glass.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                glass.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
        LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (vibrance) {
            vibrance.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                vibrance.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
    } else {
        %orig;
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGVolumeHUDHooks);
    lgObservePreferenceReload(^{

        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
