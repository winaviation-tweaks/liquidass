#import <UIKit/UIKit.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

extern BOOL LGDebugLoggingEnabled(void);
#define LGFolderLog(...) do { if (LGDebugLoggingEnabled()) LGLog(__VA_ARGS__); } while (0)

static BOOL isFolderIconMaterial(UIView *mat) {
    static Class folderCls, iconCls;
    if (!folderCls) folderCls = NSClassFromString(@"SBFolderIconImageView");
    if (!iconCls)   iconCls   = NSClassFromString(@"SBIconView");
    for (UIView *v = mat.superview; v; v = v.superview) {
        if ([v isKindOfClass:folderCls]) return YES;
        if ([v isKindOfClass:iconCls])   break;
    }
    return NO;
}

static BOOL isOpenFolderMaterial(UIView *mat) {
    if (!hasAncestorOfClassName(mat, @"SBFolderBackgroundView")) return NO;
    CGRect b = mat.bounds;
    return CGRectGetWidth(b) >= 200.0 && CGRectGetHeight(b) >= 200.0;
}

#pragma mark - folder-open coordination

static NSHashTable<UIView *> *sFolderIconGlasses;
static NSHashTable<UIView *> *sFolderIconMaterials;
static NSHashTable<UIView *> *sOpenFolderMaterials;
static __weak UIView *sActiveFolderIconGlass;
static CGPoint sActiveFolderIconCenter;
static BOOL sActiveFolderIconCenterKnown;

static UIView *folderIconGlass(UIView *view) {
    if (!view) return nil;
    UIView *glass = objc_getAssociatedObject(view, kGlassKey);
    if (glass) return glass;
    for (UIView *subview in view.subviews) {
        glass = folderIconGlass(subview);
        if (glass) return glass;
    }
    return nil;
}

CGFloat LGFolderIconCornerRadiusFallback(void) {
    // app icon glass borrows this when its image view exposes no radius
    for (UIView *glass in sFolderIconGlasses.allObjects) {
        CGFloat radius = glass.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    for (UIView *material in sFolderIconMaterials.allObjects) {
        CGFloat radius = material.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    return 0.0;
}

static BOOL anyOpenFolderActive(void) {
    for (UIView *m in sOpenFolderMaterials.allObjects)
        if (m.window) return YES;
    return NO;
}

static void hideFolderIconGlasses(void) {
    LGFolderLog(@"[folder] hide active=%p super=%p window=%p", sActiveFolderIconGlass,
                sActiveFolderIconGlass.superview, sActiveFolderIconGlass.window);
    [sActiveFolderIconGlass.layer removeAllAnimations];
    sActiveFolderIconGlass.alpha = 1.0;
    sActiveFolderIconGlass.hidden = YES;
}

static void fadeInFolderIconGlasses(void) {
    UIView *glass = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (UIView *candidate in sFolderIconGlasses.allObjects) {
        if (!candidate.window) continue;
        CGPoint center = [candidate convertPoint:CGPointMake(CGRectGetMidX(candidate.bounds),
                                                             CGRectGetMidY(candidate.bounds))
                                      toView:candidate.window];
        CGFloat distance = hypot(center.x - sActiveFolderIconCenter.x,
                                 center.y - sActiveFolderIconCenter.y);
        if (!sActiveFolderIconCenterKnown || distance >= nearestDistance) continue;
        nearestDistance = distance;
        glass = candidate;
    }
    LGFolderLog(@"[folder] fade requested active=%p super=%p window=%p open=%d materials=%lu",
                glass, glass.superview, glass.window, anyOpenFolderActive(),
                (unsigned long)sOpenFolderMaterials.allObjects.count);
    if (!glass) return;
    glass.hidden = NO;
    glass.alpha = 0.0;
    [UIView animateWithDuration:0.2 delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ glass.alpha = 1.0; }
                     completion:^(BOOL finished) {
                         LGFolderLog(@"[folder] fade completed active=%p finished=%d alpha=%.2f hidden=%d",
                                     glass, finished, glass.alpha, glass.hidden);
                         sActiveFolderIconGlass = nil;
                         sActiveFolderIconCenterKnown = NO;
                     }];
}

#pragma mark - inject

static void injectFolderIcon(UIView *mat) {
    if (!sFolderIconMaterials) sFolderIconMaterials = [NSHashTable weakObjectsHashTable];
    [sFolderIconMaterials addObject:mat];

    UIView *g = LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"FolderIcon",
                                                    UIEdgeInsetsZero, -1.0, nil);
    if (!g) return;
    if (!sFolderIconGlasses) sFolderIconGlasses = [NSHashTable weakObjectsHashTable];
    [sFolderIconGlasses addObject:g];
    g.hidden = anyOpenFolderActive() && g == sActiveFolderIconGlass;
}

static void injectOpenFolder(UIView *mat) {
    if (!mat.window) {
        [sOpenFolderMaterials removeObject:mat];
        LGRemoveGlassFromMaterial(mat, kGlassKey);
        return;
    }
    if (!LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"OpenFolder",
                                            UIEdgeInsetsZero, -1.0, nil)) {
        [sOpenFolderMaterials removeObject:mat];
        if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
        return;
    }
    if (!sOpenFolderMaterials) sOpenFolderMaterials = [NSHashTable weakObjectsHashTable];
    if (![sOpenFolderMaterials containsObject:mat]) {
        [sOpenFolderMaterials addObject:mat];
        LGFolderLog(@"[folder] open material attached=%p window=%p active=%p count=%lu",
                    mat, mat.window, sActiveFolderIconGlass,
                    (unsigned long)sOpenFolderMaterials.allObjects.count);
        hideFolderIconGlasses();
    }
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        [sFolderIconMaterials removeObject:self_];

        if ([sOpenFolderMaterials containsObject:self_]) {
            [sOpenFolderMaterials removeObject:self_];
            LGFolderLog(@"[folder] open material detached=%p active=%p remaining=%lu",
                        self_, sActiveFolderIconGlass,
                        (unsigned long)sOpenFolderMaterials.allObjects.count);
            LGRemoveGlassFromMaterial(self_, kGlassKey);
            if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
        }
        return;
    }
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
%end

%hook SBFolderIconImageView

- (void)prepareToCrossfadeWithFloatyFolderView:(id)floatyFolderView
                        allowFolderInteraction:(BOOL)allowFolderInteraction {
    %orig;
    UIView *background = nil;
    @try { background = [(UIView *)self valueForKey:@"_backgroundView"]; } @catch (...) {}
    sActiveFolderIconGlass = folderIconGlass(background ?: (UIView *)self);
    LGFolderLog(@"[folder] crossfade icon=%p background=%p active=%p floaty=%p interaction=%d",
                self, background, sActiveFolderIconGlass, floatyFolderView,
                allowFolderInteraction);
    if (!allowFolderInteraction && ((UIView *)self).window) {
        CGRect frame = [(UIView *)self convertRect:((UIView *)self).bounds
                                            toView:((UIView *)self).window];
        sActiveFolderIconCenter = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        sActiveFolderIconCenterKnown = YES;
    }
    hideFolderIconGlasses();
}

- (void)setBackgroundAndIconGridImageAlpha:(CGFloat)alpha {
    %orig;
    UIView *background = nil;
    @try { background = [(UIView *)self valueForKey:@"_backgroundView"]; } @catch (...) {}
    UIView *glass = folderIconGlass(background ?: (UIView *)self);
    if (!glass) return;
    sActiveFolderIconGlass = glass;
    glass.hidden = alpha <= 0.001;
    glass.alpha = alpha;
    LGFolderLog(@"[folder] icon alpha icon=%p glass=%p alpha=%.3f hidden=%d window=%p",
                self, glass, alpha, glass.hidden, glass.window);
}

%end
