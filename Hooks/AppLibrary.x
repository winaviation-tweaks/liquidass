#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static BOOL isAppLibrarySearchMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"SBHSearchTextField")) return NO;
    Class materialClass = NSClassFromString(@"MTMaterialView");
    Class searchClass = NSClassFromString(@"SBHSearchTextField");
    for (UIView *view = material.superview; view; view = view.superview) {
        if (searchClass && [view isKindOfClass:searchClass]) return YES;
        if (materialClass && [view isKindOfClass:materialClass]) return NO;
    }
    return YES;
}

static void injectAppLibraryPod(UIView *pod) {
    CGRect bounds = pod.bounds;
    if (CGRectGetWidth(bounds) < 2.0 || CGRectGetHeight(bounds) < 2.0) return;
    CGFloat radius = pod.layer.cornerRadius > 0.0
        ? pod.layer.cornerRadius
        : 20.0;
    LGInstallRegisteredGlassInMaterial(pod, kGlassKey, @"AppLibrary",
                                       UIEdgeInsetsZero, radius, nil);
}

%group LGAppLibraryHooks

%hook SBHLibraryCategoryPodBackgroundView
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (!view.window) {
        LGRemoveGlassFromMaterial(view, kGlassKey);
        return;
    }
    injectAppLibraryPod(view);
}
- (void)layoutSubviews {
    %orig;
    injectAppLibraryPod((UIView *)self);
}
- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}
%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGAppLibraryHooks);
    LGRegisterMaterialHost(@"AppLibSearch", 90, ^BOOL(UIView *material) {
        return isAppLibrarySearchMaterial(material);
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return CGRectGetHeight(material.bounds) * 0.5;
    }, nil, nil);
}
