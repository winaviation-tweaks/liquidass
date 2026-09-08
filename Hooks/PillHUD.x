#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface MTShadowView : UIImageView
@end

@interface SBRingerPillView : UIView
@end

@interface PLPillContentView : UIView
@end

@interface PLPillView : UIView
@end

@interface LGPillHUDVibranceView : UIView
@end

@implementation LGPillHUDVibranceView

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

static const void * const kLGPillHUDGlassKey = &kLGPillHUDGlassKey;
static const void * const kLGPillHUDVibranceKey = &kLGPillHUDVibranceKey;

static BOOL LGPillHUDEnabled(void) {
    return lgHostEnabled(@"PillHUD");
}

static void LGUpdateRingerPillGlass(SBRingerPillView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTShadowView *shadow = nil;
    @try {
        base = [self valueForKey:@"_materialView"];
        shadow = [self valueForKey:@"_shadowView"];
    } @catch (...) {}

    if (!LGPillHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGPillHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        return;
    }

    if (base) base.hidden = YES;

    LGPillHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGPillHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGPillHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (shadow) {
                [self insertSubview:vibrance aboveSubview:shadow];
            } else {
                [self insertSubview:vibrance atIndex:0];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"PillHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGPillHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"PillHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (shadow) {
            [self insertSubview:glass aboveSubview:shadow];
        } else {
            [self insertSubview:glass atIndex:0];
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
}

static void LGUpdatePLPillGlass(PLPillView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTShadowView *shadow = nil;
    UIView *contentView = nil;
    @try {
        base = [self valueForKey:@"_materialView"];
        shadow = [self valueForKey:@"_shadowView"];
        contentView = [self valueForKey:@"_contentView"];
    } @catch (...) {}

    if (!LGPillHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGPillHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        return;
    }

    if (base) base.hidden = YES;

    LGPillHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGPillHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGPillHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (contentView) {
                [self insertSubview:vibrance belowSubview:contentView];
            } else if (shadow) {
                [self insertSubview:vibrance aboveSubview:shadow];
            } else {
                [self insertSubview:vibrance atIndex:0];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"PillHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGPillHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"PillHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (contentView) {
            [self insertSubview:glass belowSubview:contentView];
        } else if (shadow) {
            [self insertSubview:glass aboveSubview:shadow];
        } else {
            [self insertSubview:glass atIndex:0];
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
}

%group LGPillHUDHooks

%hook SBRingerPillView

- (void)layoutSubviews {
    %orig;
    LGUpdateRingerPillGlass(self);
}

%end

%hook PLPillView

- (void)layoutSubviews {
    %orig;
    LGUpdatePLPillGlass(self);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGPillHUDHooks);
    lgObservePreferenceReload(^{
        LGLog(@"PillHUD: Preferences reloaded");
    });
}
