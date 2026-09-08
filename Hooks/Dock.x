#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, LGDockMode) {
    LGDockModeNone = 0,
    LGDockModeRegular,
    LGDockModeFloating,
};

static const void *kDockHomeButtonBorderKey = &kDockHomeButtonBorderKey;

static BOOL dockInsideCategoryStackBackground(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) containsString:@"StackViewBackground"])
            return YES;
    }
    return NO;
}

static LGDockMode dockModeForMaterial(UIView *material) {
    BOOL regular = hasAncestorOfClassName(material, @"SBDockView");
    BOOL floating = hasAncestorOfClassName(material, @"SBFloatingDockPlatterView");
    BOOL exact = isExactClass(material, @"MTMaterialView");
    BOOL stacked = dockInsideCategoryStackBackground(material);
    if (regular || floating)
        LGLog(@"[Dock] candidate class=%@ frame=%@ bounds=%@ scale=%.1f regular=%d floating=%d exact=%d stacked=%d",
              NSStringFromClass(material.class), NSStringFromCGRect(material.frame),
              NSStringFromCGRect(material.bounds), material.window.screen.scale,
              regular, floating, exact, stacked);
    if (!exact || stacked) return LGDockModeNone;

    CGSize size = material.bounds.size;
    if (size.width < 160.0 || size.height < 40.0) {
        if (regular || floating)
            LGLog(@"[Dock] rejected size=%.1fx%.1f", size.width, size.height);
        return LGDockModeNone;
    }

    if (floating && size.width >= size.height * 2.0) {
        return LGDockModeFloating;
    }
    if (regular) {
        return LGDockModeRegular;
    }
    return LGDockModeNone;
}

static BOOL dockIsFullScreenPhone(UIView *material) {
    UIEdgeInsets safeArea = material.window.safeAreaInsets;
    return safeArea.top > 20.0 || safeArea.bottom > 0.0;
}

static void dockUpdateHomeButtonBorder(LGLiveBackdropView *glass,
                                       BOOL needsBorder) {
    CAShapeLayer *border =
        objc_getAssociatedObject(glass, kDockHomeButtonBorderKey);
    if (!needsBorder) {
        [border removeFromSuperlayer];
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, border,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [glass.layer addSublayer:border];
    CGFloat scale = glass.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = 1.0 / MAX(scale, 1.0);
    CGRect borderRect = CGRectInset(glass.bounds, lineWidth * 0.5,
                                    lineWidth * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    border.frame = glass.bounds;
    border.contentsScale = scale;
    border.lineWidth = lineWidth;
    border.path = [UIBezierPath bezierPathWithRect:borderRect].CGPath;
    [CATransaction commit];
}

static void configureDockGlass(UIView *material, LGLiveBackdropView *glass) {

    LGDockMode mode = dockModeForMaterial(material);
    BOOL homeButtonDock = mode == LGDockModeRegular &&
                          !dockIsFullScreenPhone(material);
    glass.lgSpecularEnabledOverride = homeButtonDock ? @NO : nil;
    dockUpdateHomeButtonBorder(glass, homeButtonDock);
    LGLog(@"[Dock] injected mode=%ld homeButton=%d material=%@ glass=%@",
          (long)mode, homeButtonDock, NSStringFromCGRect(material.bounds),
          NSStringFromCGRect(glass.frame));
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGRegisterMaterialHost(@"Dock", 80, ^BOOL(UIView *material) {
        return dockModeForMaterial(material) != LGDockModeNone;
    }, UIEdgeInsetsZero, ^CGFloat(__unused UIView *material) {

        return -1.0;
    }, nil, ^(UIView *material, LGLiveBackdropView *glass) {
        configureDockGlass(material, glass);
    });
}
