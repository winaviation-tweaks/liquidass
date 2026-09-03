#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"

static const void *kLGSpotlightOriginalTextTransformKey =
    &kLGSpotlightOriginalTextTransformKey;

static void LGUpdateSpotlightTextField(UIView *view) {
    NSValue *original = objc_getAssociatedObject(
        view, kLGSpotlightOriginalTextTransformKey);
    if (!lgHostEnabled(@"Spotlight")) {
        if (original) {
            view.transform = original.CGAffineTransformValue;
            objc_setAssociatedObject(view,
                                     kLGSpotlightOriginalTextTransformKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    if (!original) {
        objc_setAssociatedObject(
            view, kLGSpotlightOriginalTextTransformKey,
            [NSValue valueWithCGAffineTransform:view.transform],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.transform = CGAffineTransformTranslate(
        [objc_getAssociatedObject(view,
            kLGSpotlightOriginalTextTransformKey) CGAffineTransformValue],
        0.0, -5.0);
}

static void LGUpdateSpotlightGlass(UIView *view) {
    if (!lgHostEnabled(@"Spotlight") || !view.window || CGRectIsEmpty(view.bounds)) {
        LGRemoveGlassFromMaterial(view, kGlassKey);
        return;
    }
    CGFloat radius = CGRectGetHeight(view.bounds) * 0.5;
    LGInstallRegisteredGlassInMaterial(view, kGlassKey, @"Spotlight",
                                       UIEdgeInsetsZero, radius, nil);
}

%group LGSpotlightHooks

%hook SPUIHeaderBlurView

- (void)didMoveToWindow {
    %orig;
    LGUpdateSpotlightGlass((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSpotlightGlass((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

%end

%hook SPUITextField

- (void)didMoveToWindow {
    %orig;
    LGUpdateSpotlightTextField((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSpotlightTextField((UIView *)self);
}

%end

%end

%ctor {
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:
            (NSOperatingSystemVersion){16, 0, 0}]) {
        %init(LGSpotlightHooks);
    }
}
