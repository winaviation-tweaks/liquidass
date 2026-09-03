#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGCoverSheetState.h"

typedef NS_ENUM(NSInteger, LGCoverSheetMode) {
    LGCoverSheetModeIdle,
    LGCoverSheetModePresentingGlass,
    LGCoverSheetModeDismissing
};

static LGCoverSheetMode sLGCoverSheetMode = LGCoverSheetModeIdle;
static NSHashTable<UIView *> *sLGCoverSheetPanels;
static NSHashTable<UIViewController *> *sLGCoverSheetWallpaperControllers;
static CADisplayLink *sLGCoverSheetDisplayLink;
static const void *kLGCoverSheetGlassKey = &kLGCoverSheetGlassKey;
static const void *kLGCoverSheetWallpaperSnapshotKey =
    &kLGCoverSheetWallpaperSnapshotKey;
static const void *kLGCoverSheetOriginalHiddenKey =
    &kLGCoverSheetOriginalHiddenKey;
static const void *kLGCoverSheetOriginalAlphaKey =
    &kLGCoverSheetOriginalAlphaKey;
static const void *kLGCoverSheetFadeKey = &kLGCoverSheetFadeKey;
static const void *kLGCoverSheetMaskKey = &kLGCoverSheetMaskKey;
static const void *kLGCoverSheetBorderKey = &kLGCoverSheetBorderKey;
static const void *kLGCoverSheetMaskRadiusKey = &kLGCoverSheetMaskRadiusKey;
static const void *kLGCoverSheetMaskOrientationKey =
    &kLGCoverSheetMaskOrientationKey;
static const CGFloat kLGCoverSheetDefaultCornerRadiusPoints = 64.0;
static BOOL sLGCoverSheetCommitEndPresented;
static BOOL sLGCoverSheetLockedPasscodeTriggered;
static BOOL sLGCoverSheetLockedHandoffActive;
static BOOL sLGCoverSheetLockedRollbackCommitted;
static BOOL sLGCoverSheetLockedFirstRollbackDidEnd;
static __weak id sLGCoverSheetLockedHandoffManager;
static BOOL sLGCoverSheetLockedVisualPinActive;
static __weak UIView *sLGCoverSheetLockedVisualPinView;
static CATransform3D sLGCoverSheetLockedVisualPinBaseTransform;
static CGPoint sLGCoverSheetLockedVisualPinOrigin;
static CGPoint sLGCoverSheetLockedVisualPinOffset;
static NSMutableArray<UIView *> *sLGCoverSheetLockedBranchPinViews;
static NSMutableArray<NSValue *> *sLGCoverSheetLockedBranchPinTransforms;
static BOOL sLGCoverSheetLockedBranchPinSawPasscodeVisible;
static BOOL sLGCoverSheetLastKnownLocked;
static BOOL sLGCoverSheetPerformingFade;
static BOOL sLGCoverSheetFadeToHome;
static BOOL sLGCoverSheetBeginDismissalFadeIn;
static dispatch_block_t sLGCoverSheetDeferredDismissalCommit;
static const CFTimeInterval kLGCoverSheetHandoffDuration = 0.20;
static UIDeviceOrientation sLGCoverSheetLastLandscapeOrientation =
    UIDeviceOrientationLandscapeLeft;
static UIDeviceOrientation sLGCoverSheetLastPortraitOrientation =
    UIDeviceOrientationPortrait;

static void LGCoverSheetLogOrientation(UIView *view,
                                       UIDeviceOrientation resolved,
                                       NSString *source,
                                       CGPoint xAxis,
                                       CGPoint yAxis) {
    static UIDeviceOrientation lastResolved = UIDeviceOrientationUnknown;
    static UIDeviceOrientation lastDevice = UIDeviceOrientationUnknown;
    static UIInterfaceOrientation lastInterface = UIInterfaceOrientationUnknown;
    static NSString *lastSource;
    UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    UIInterfaceOrientation interfaceOrientation =
        view.window.windowScene.interfaceOrientation;
    if (resolved == lastResolved && device == lastDevice &&
        interfaceOrientation == lastInterface &&
        [source isEqualToString:lastSource]) {
        return;
    }
    lastResolved = resolved;
    lastDevice = device;
    lastInterface = interfaceOrientation;
    lastSource = [source copy];
    LGLog(@"[coversheet-orientation] source=%@ resolved=%ld device=%ld scene=%ld "
           "xAxis={%.2f,%.2f} yAxis={%.2f,%.2f} bounds=%@ window=%@",
          source, (long)resolved, (long)device, (long)interfaceOrientation,
          xAxis.x, xAxis.y, yAxis.x, yAxis.y,
          NSStringFromCGRect(view.bounds), NSStringFromCGRect(view.window.bounds));
}

static UIDeviceOrientation LGCoverSheetDeviceOrientation(UIView *view) {

    if (view.window) {
        id<UICoordinateSpace> fixedSpace =
            view.window.screen.fixedCoordinateSpace;
        CGRect bounds = view.bounds;
        CGPoint p0 = [view convertPoint:bounds.origin
                      toCoordinateSpace:fixedSpace];
        CGPoint px = [view convertPoint:
            CGPointMake(CGRectGetMaxX(bounds), CGRectGetMinY(bounds))
                      toCoordinateSpace:fixedSpace];
        CGPoint py = [view convertPoint:
            CGPointMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds))
                      toCoordinateSpace:fixedSpace];
        CGPoint xAxis = CGPointMake(px.x - p0.x, px.y - p0.y);
        CGPoint yAxis = CGPointMake(py.x - p0.x, py.y - p0.y);
        BOOL portraitBasis = fabs(xAxis.x) > fabs(xAxis.y) &&
                             fabs(yAxis.y) > fabs(yAxis.x);
        if (portraitBasis && xAxis.x < 0.0 && yAxis.y < 0.0) {
            sLGCoverSheetLastPortraitOrientation =
                UIDeviceOrientationPortraitUpsideDown;
            LGCoverSheetLogOrientation(
                view, UIDeviceOrientationPortraitUpsideDown,
                @"fixed-space-upside-down", xAxis, yAxis);
            return UIDeviceOrientationPortraitUpsideDown;
        }
        if (portraitBasis && xAxis.x > 0.0 && yAxis.y > 0.0) {
            sLGCoverSheetLastPortraitOrientation = UIDeviceOrientationPortrait;
            LGCoverSheetLogOrientation(view, UIDeviceOrientationPortrait,
                                       @"fixed-space-portrait", xAxis, yAxis);
            return UIDeviceOrientationPortrait;
        }
    }

    UIDeviceOrientation deviceOrientation =
        UIDevice.currentDevice.orientation;
    if (CGRectGetWidth(view.bounds) > CGRectGetHeight(view.bounds) &&
        UIDeviceOrientationIsLandscape(deviceOrientation)) {
        sLGCoverSheetLastLandscapeOrientation = deviceOrientation;
        LGCoverSheetLogOrientation(view, deviceOrientation,
                                   @"landscape-bounds-device",
                                   CGPointZero, CGPointZero);
        return deviceOrientation;
    }

    UIInterfaceOrientation interfaceOrientation =
        view.window.windowScene.interfaceOrientation;
    if (interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown) {
        sLGCoverSheetLastPortraitOrientation =
            UIDeviceOrientationPortraitUpsideDown;
        LGCoverSheetLogOrientation(
            view, UIDeviceOrientationPortraitUpsideDown,
            @"window-scene-upside-down", CGPointZero, CGPointZero);
        return UIDeviceOrientationPortraitUpsideDown;
    }
    if (interfaceOrientation == UIInterfaceOrientationPortrait) {
        sLGCoverSheetLastPortraitOrientation = UIDeviceOrientationPortrait;
        LGCoverSheetLogOrientation(view, UIDeviceOrientationPortrait,
                                   @"window-scene-portrait",
                                   CGPointZero, CGPointZero);
        return UIDeviceOrientationPortrait;
    }

    UIDeviceOrientation orientation = deviceOrientation;
    if (UIDeviceOrientationIsPortrait(orientation)) {
        sLGCoverSheetLastPortraitOrientation = orientation;
        LGCoverSheetLogOrientation(view, orientation, @"device-portrait",
                                   CGPointZero, CGPointZero);
        return orientation;
    }
    if (UIDeviceOrientationIsLandscape(orientation)) {
        sLGCoverSheetLastLandscapeOrientation = orientation;
        LGCoverSheetLogOrientation(view, orientation, @"device-landscape",
                                   CGPointZero, CGPointZero);
        return orientation;
    }
    UIDeviceOrientation fallback =
        CGRectGetWidth(view.bounds) > CGRectGetHeight(view.bounds)
        ? sLGCoverSheetLastLandscapeOrientation
        : sLGCoverSheetLastPortraitOrientation;
    LGCoverSheetLogOrientation(view, fallback, @"remembered-fallback",
                               CGPointZero, CGPointZero);
    return fallback;
}

static BOOL LGCoverSheetEnabled(void) {
    return lgHostEnabled(@"CoverSheet");
}

static CGFloat LGCoverSheetCornerRadiusPoints(void) {
    return MAX(0.0, LG_prefFloat(@"CoverSheet.CornerRadius",
                                 kLGCoverSheetDefaultCornerRadiusPoints));
}

static BOOL LGCoverSheetUsesLegacyLockedDismissal(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26;
}

static BOOL LGCoverSheetIsEffectivelyLocked(id manager) {
    if (!manager) return NO;
    if (![NSThread isMainThread]) {
        return sLGCoverSheetLastKnownLocked;
    }
    SEL selector = NSSelectorFromString(@"_isEffectivelyLocked");
    if (![manager respondsToSelector:selector]) return NO;
    BOOL locked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, selector);
    sLGCoverSheetLastKnownLocked = locked;
    return locked;
}

static BOOL LGCoverSheetShouldRelaxLockedGate(id manager) {
    return LGCoverSheetEnabled() &&
           LGCoverSheetUsesLegacyLockedDismissal() &&
           LGCoverSheetIsEffectivelyLocked(manager);
}

static UIView *LGCoverSheetSlidingControllerView(id controller) {
    if (!controller || ![controller respondsToSelector:@selector(view)]) {
        return nil;
    }
    id view = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(view));
    return [view isKindOfClass:UIView.class] ? (UIView *)view : nil;
}

static void LGCoverSheetReleaseLockedVisualPin(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGCoverSheetReleaseLockedVisualPin();
        });
        return;
    }
    UIView *view = sLGCoverSheetLockedVisualPinView;
    if (view && sLGCoverSheetLockedVisualPinActive) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        view.layer.sublayerTransform = sLGCoverSheetLockedVisualPinBaseTransform;
        [CATransaction commit];
    }
    sLGCoverSheetLockedVisualPinActive = NO;
    sLGCoverSheetLockedVisualPinView = nil;
    sLGCoverSheetLockedVisualPinBaseTransform = CATransform3DIdentity;
    sLGCoverSheetLockedVisualPinOrigin = CGPointZero;
    sLGCoverSheetLockedVisualPinOffset = CGPointZero;
}

static void LGCoverSheetBeginLockedVisualPin(id controller,
                                              CGRect coverSheetFrame) {
    if (![NSThread isMainThread]) {
        id controllerCopy = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            LGCoverSheetBeginLockedVisualPin(controllerCopy, coverSheetFrame);
        });
        return;
    }
    if (sLGCoverSheetLockedVisualPinActive) return;
    UIView *view = LGCoverSheetSlidingControllerView(controller);
    if (!view) {
        LGLog(@"[coversheet-unlock] visual pin unavailable controller=%@",
              NSStringFromClass([controller class]));
        return;
    }
    sLGCoverSheetLockedVisualPinView = view;
    sLGCoverSheetLockedVisualPinBaseTransform = view.layer.sublayerTransform;
    sLGCoverSheetLockedVisualPinOrigin = coverSheetFrame.origin;
    sLGCoverSheetLockedVisualPinOffset = CGPointZero;
    sLGCoverSheetLockedVisualPinActive = YES;
}

static void LGCoverSheetUpdateLockedVisualPin(CGRect coverSheetFrame) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGCoverSheetUpdateLockedVisualPin(coverSheetFrame);
        });
        return;
    }
    UIView *view = sLGCoverSheetLockedVisualPinView;
    if (!sLGCoverSheetLockedVisualPinActive || !view) return;

    CGFloat dx = sLGCoverSheetLockedVisualPinOrigin.x - coverSheetFrame.origin.x;
    CGFloat dy = sLGCoverSheetLockedVisualPinOrigin.y - coverSheetFrame.origin.y;
    sLGCoverSheetLockedVisualPinOffset = CGPointMake(dx, dy);
    CATransform3D transform = CATransform3DTranslate(
        sLGCoverSheetLockedVisualPinBaseTransform, dx, dy, 0.0);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.layer.sublayerTransform = transform;
    [CATransaction commit];
}

static BOOL LGCoverSheetViewClassContains(UIView *view,
                                          NSString *needle) {
    if (!view || needle.length == 0) return NO;
    return [NSStringFromClass(view.class)
               rangeOfString:needle
                     options:NSCaseInsensitiveSearch].location
           != NSNotFound;
}

static BOOL LGCoverSheetSubtreeContainsPasscode(UIView *root) {
    if (!root) return NO;

    NSMutableArray<UIView *> *stack =
        [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (LGCoverSheetViewClassContains(view, @"Passcode")) {
            return YES;
        }

        if (view.subviews.count) {
            [stack addObjectsFromArray:view.subviews];
        }
    }
    return NO;
}

static UIView *LGCoverSheetFindViewByExactClass(id controller,
                                                 NSString *className) {
    UIView *root = LGCoverSheetSlidingControllerView(controller);
    if (!root || className.length == 0) return nil;

    NSMutableArray<UIView *> *stack =
        [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ([NSStringFromClass(view.class) isEqualToString:className]) {
            return view;
        }

        if (view.subviews.count) {
            [stack addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

static void LGCoverSheetReleaseLockedBranchPins(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGCoverSheetReleaseLockedBranchPins();
        });
        return;
    }

    NSUInteger count = MIN(sLGCoverSheetLockedBranchPinViews.count,
                           sLGCoverSheetLockedBranchPinTransforms.count);
    if (count == 0) {
        sLGCoverSheetLockedBranchPinViews = nil;
        sLGCoverSheetLockedBranchPinTransforms = nil;
        sLGCoverSheetLockedBranchPinSawPasscodeVisible = NO;
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSUInteger index = 0; index < count; index++) {
        UIView *view = sLGCoverSheetLockedBranchPinViews[index];
        NSValue *value = sLGCoverSheetLockedBranchPinTransforms[index];
        if (!view || !value) continue;

        CATransform3D transform = CATransform3DIdentity;
        [value getValue:&transform];
        view.layer.transform = transform;
    }

    [CATransaction commit];

    sLGCoverSheetLockedBranchPinViews = nil;
    sLGCoverSheetLockedBranchPinTransforms = nil;
    sLGCoverSheetLockedBranchPinSawPasscodeVisible = NO;
}

static void LGCoverSheetPinBranch(UIView *branch,
                                  CGPoint offset,
                                  NSUInteger *pinnedCount) {
    if (!branch) return;

    CATransform3D original = branch.layer.transform;
    NSValue *saved =
        [NSValue valueWithBytes:&original
                       objCType:@encode(CATransform3D)];

    [branch.layer removeAnimationForKey:@"transform"];
    branch.layer.transform =
        CATransform3DTranslate(original, offset.x, offset.y, 0.0);

    [sLGCoverSheetLockedBranchPinViews addObject:branch];
    [sLGCoverSheetLockedBranchPinTransforms addObject:saved];

    if (pinnedCount) (*pinnedCount)++;
}

static void LGCoverSheetPinEverythingExceptPasscodePath(
    UIView *root,
    CGPoint offset,
    NSUInteger *pinnedCount) {
    if (!root) return;

    for (UIView *child in root.subviews) {
        if (!child) continue;

        if (LGCoverSheetViewClassContains(child, @"Passcode")) {
            continue;
        }
        if (LGCoverSheetSubtreeContainsPasscode(child)) {
            LGCoverSheetPinEverythingExceptPasscodePath(
                child, offset, pinnedCount);
            continue;
        }
        LGCoverSheetPinBranch(child, offset, pinnedCount);
    }
}

static NSUInteger LGCoverSheetTransferRootPinToNonPasscodeBranches(
    id controller) {
    if (![NSThread isMainThread] ||
        !sLGCoverSheetLockedVisualPinActive) {
        return 0;
    }

    UIView *coverSheet =
        LGCoverSheetFindViewByExactClass(controller, @"CSCoverSheetView");
    if (!coverSheet) {
        LGLog(@"[coversheet-unlock] branch pin unavailable: "
              "CSCoverSheetView not found");
        return 0;
    }

    CGPoint offset = sLGCoverSheetLockedVisualPinOffset;
    if (fabs(offset.x) < 0.5 && fabs(offset.y) < 0.5) {
        LGLog(@"[coversheet-unlock] branch pin unavailable: "
              "root offset={%.1f, %.1f}",
              offset.x, offset.y);
        return 0;
    }

    LGCoverSheetReleaseLockedBranchPins();
    sLGCoverSheetLockedBranchPinViews = [NSMutableArray array];
    sLGCoverSheetLockedBranchPinTransforms = [NSMutableArray array];
    sLGCoverSheetLockedBranchPinSawPasscodeVisible = NO;

    NSUInteger pinnedCount = 0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    LGCoverSheetPinEverythingExceptPasscodePath(
        coverSheet, offset, &pinnedCount);

    [CATransaction commit];

    return pinnedCount;
}

static BOOL LGCoverSheetViewEffectivelyVisible(UIView *view) {
    if (!view || !view.window) return NO;

    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
    }
    return YES;
}

static BOOL LGCoverSheetPasscodeModelVisible(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || window.hidden || window.alpha <= 0.01) continue;

        NSMutableArray<UIView *> *stack =
            [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];

            NSString *className = NSStringFromClass(view.class);
            BOOL passcodeSentinel =
                [className isEqualToString:@"CSPasscodeBackgroundView"] ||
                [className isEqualToString:
                    @"SBUIPasscodeLockViewSimpleFixedDigitKeypad"];

            if (passcodeSentinel &&
                LGCoverSheetViewEffectivelyVisible(view)) {
                return YES;
            }

            if (view.subviews.count) {
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
    return NO;
}

static void LGCoverSheetWatchBranchPinsForPasscodeDismissal(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGCoverSheetWatchBranchPinsForPasscodeDismissal();
        });
        return;
    }

    if (sLGCoverSheetLockedBranchPinViews.count == 0) return;

    BOOL visible = LGCoverSheetPasscodeModelVisible();
    if (visible) {
        if (!sLGCoverSheetLockedBranchPinSawPasscodeVisible) {
            sLGCoverSheetLockedBranchPinSawPasscodeVisible = YES;
        }
    } else if (sLGCoverSheetLockedBranchPinSawPasscodeVisible) {
        LGCoverSheetReleaseLockedBranchPins();
        return;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            LGCoverSheetWatchBranchPinsForPasscodeDismissal();
        });
}

static void LGCoverSheetResetLockedHandoff(BOOL resetTriggered) {
    LGCoverSheetReleaseLockedBranchPins();
    LGCoverSheetReleaseLockedVisualPin();
    if (resetTriggered) {
        sLGCoverSheetLockedPasscodeTriggered = NO;
    }
    sLGCoverSheetLockedHandoffActive = NO;
    sLGCoverSheetLockedRollbackCommitted = NO;
    sLGCoverSheetLockedFirstRollbackDidEnd = NO;
    sLGCoverSheetLockedHandoffManager = nil;
}

static BOOL LGCoverSheetRequestLockedPasscode(id manager, id controller) {
    if (!LGCoverSheetShouldRelaxLockedGate(manager) ||
        sLGCoverSheetLockedPasscodeTriggered) {
        LGLog(@"[coversheet-unlock] skipped relax=%d alreadyTriggered=%d",
              LGCoverSheetShouldRelaxLockedGate(manager),
              sLGCoverSheetLockedPasscodeTriggered);
        return NO;
    }

    SEL selector = NULL;
    for (NSString *name in @[@"_notifyDelegateRequestsUnlock",
                             @"_requestUnlockWithPasscode",
                             @"notifyDelegateRequestsUnlock",
                             @"_notifyDelegateRequestsUnlockWithIntent:"]) {
        SEL candidate = NSSelectorFromString(name);
        if ([manager respondsToSelector:candidate]) { selector = candidate; break; }
    }
    if (!selector) {
        LGLog(@"[coversheet-unlock] passcode request unavailable manager=%@ (%@)",
              NSStringFromClass([manager class]),
              UIDevice.currentDevice.systemVersion);
        return NO;
    }
    LGLog(@"[coversheet-unlock] requesting passcode via %@", NSStringFromSelector(selector));

    sLGCoverSheetLockedPasscodeTriggered = YES;
    sLGCoverSheetLockedHandoffActive = NO;
    sLGCoverSheetLockedRollbackCommitted = NO;
    (void)controller;
    if ([NSStringFromSelector(selector) hasSuffix:@":"])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(manager, selector, 0);
    else
        ((void (*)(id, SEL))objc_msgSend)(manager, selector);
    return YES;
}

static BOOL LGCoverSheetModeUsesGlass(LGCoverSheetMode mode) {
    return mode == LGCoverSheetModePresentingGlass ||
           mode == LGCoverSheetModeDismissing;
}

static void LGCoverSheetConsumeDeferredDismissalCommit(void) {
    dispatch_block_t commit = sLGCoverSheetDeferredDismissalCommit;
    sLGCoverSheetDeferredDismissalCommit = nil;
    if (commit) commit();
}

static UIView *LGCoverSheetWallpaperSnapshot(UIView *panel) {
    return objc_getAssociatedObject(panel,
                                    kLGCoverSheetWallpaperSnapshotKey);
}

static void LGCoverSheetRemoveWallpaperSnapshot(UIView *panel) {
    UIView *snapshot = LGCoverSheetWallpaperSnapshot(panel);
    [snapshot removeFromSuperview];
    objc_setAssociatedObject(panel, kLGCoverSheetWallpaperSnapshotKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGCoverSheetMatchViewGeometry(UIView *destination,
                                           UIView *source,
                                           UIView *container) {
    if (!destination || !source || !container || CGRectIsEmpty(source.bounds)) {
        return;
    }

    CGRect bounds = source.bounds;
    CGPoint origin = [source convertPoint:bounds.origin toView:container];
    CGPoint xEdge = [source convertPoint:
        CGPointMake(CGRectGetMaxX(bounds), CGRectGetMinY(bounds))
                                  toView:container];
    CGPoint yEdge = [source convertPoint:
        CGPointMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds))
                                  toView:container];
    CGPoint center = [source convertPoint:
        CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))
                                   toView:container];
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) return;

    CGAffineTransform transform = CGAffineTransformMake(
        (xEdge.x - origin.x) / width,
        (xEdge.y - origin.y) / width,
        (yEdge.x - origin.x) / height,
        (yEdge.y - origin.y) / height,
        0.0, 0.0);
    destination.bounds = bounds;
    destination.center = center;
    destination.transform = transform;
}

static void LGCoverSheetCaptureWallpaperSnapshots(void) {
    for (UIView *panel in sLGCoverSheetPanels.allObjects) {
        UIView *parent = panel.superview;
        if (!parent || !panel.window) continue;

        LGCoverSheetRemoveWallpaperSnapshot(panel);

        UIView *source = nil;
        CGFloat sourceWindowLevel = -CGFLOAT_MAX;
        for (UIViewController *controller in
                 sLGCoverSheetWallpaperControllers.allObjects) {
            UIView *candidate = controller.viewIfLoaded;
            if (!candidate.window || candidate.hidden ||
                candidate.alpha <= 0.001) {
                continue;
            }
            CGFloat level = candidate.window.windowLevel;
            if (!source || level > sourceWindowLevel) {
                source = candidate;
                sourceWindowLevel = level;
            }
        }
        if (!source) source = panel;

        UIView *snapshot = [source snapshotViewAfterScreenUpdates:NO];
        if (!snapshot) continue;
        LGCoverSheetMatchViewGeometry(snapshot, source, parent);
        snapshot.autoresizingMask = UIViewAutoresizingNone;
        snapshot.userInteractionEnabled = NO;
        [parent insertSubview:snapshot belowSubview:panel];
        objc_setAssociatedObject(panel, kLGCoverSheetWallpaperSnapshotKey,
                                 snapshot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGCoverSheetAddOpacityFade(UIView *view, CGFloat targetAlpha) {
    if (!view) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.alpha = targetAlpha;
    [CATransaction commit];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.toValue = @(targetAlpha);
    fade.duration = kLGCoverSheetHandoffDuration;
    fade.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseOut];
    [view.layer addAnimation:fade forKey:@"dylv.coversheet.fadeIn"];
}

static void LGCoverSheetRegisterWallpaperController(UIViewController *controller) {
    if (!controller) return;
    if (!sLGCoverSheetWallpaperControllers) {
        sLGCoverSheetWallpaperControllers = [NSHashTable weakObjectsHashTable];
    }
    [sLGCoverSheetWallpaperControllers addObject:controller];
}

static void LGCoverSheetUpdateBottomCornerMask(LGLiveBackdropView *glass) {
    if (!glass || CGRectIsEmpty(glass.bounds)) return;
    // the layer transform rotates this local bottom edge into place
    CAShapeLayer *mask =
        objc_getAssociatedObject(glass, kLGCoverSheetMaskKey);
    if (!mask) {
        mask = [CAShapeLayer layer];
        mask.fillColor = UIColor.blackColor.CGColor;
        objc_setAssociatedObject(glass, kLGCoverSheetMaskKey, mask,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glass.layer.mask = mask;
    }
    CAShapeLayer *border =
        objc_getAssociatedObject(glass, kLGCoverSheetBorderKey);
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        objc_setAssociatedObject(glass, kLGCoverSheetBorderKey, border,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [glass.layer addSublayer:border];
    }
    UIDeviceOrientation orientation = LGCoverSheetDeviceOrientation(glass);
    NSNumber *maskedOrientation =
        objc_getAssociatedObject(glass, kLGCoverSheetMaskOrientationKey);
    CGFloat cornerRadius = LGCoverSheetCornerRadiusPoints();
    NSNumber *maskedRadius =
        objc_getAssociatedObject(glass, kLGCoverSheetMaskRadiusKey);
    if (CGRectEqualToRect(mask.frame, glass.bounds) && mask.path &&
        CGRectEqualToRect(border.frame, glass.bounds) && border.path &&
        maskedOrientation.unsignedIntegerValue == (NSUInteger)orientation &&
        fabs(maskedRadius.doubleValue - cornerRadius) < 0.01) {
        return;
    }

    CGFloat scale = glass.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = 1.0 / MAX(scale, 1.0);

    UIRectCorner roundedCorners =
        UIRectCornerBottomLeft | UIRectCornerBottomRight;
    UIBezierPath *maskPath = [UIBezierPath
        bezierPathWithRoundedRect:glass.bounds
               byRoundingCorners:roundedCorners
                     cornerRadii:CGSizeMake(cornerRadius, cornerRadius)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = glass.bounds;
    mask.path = maskPath.CGPath;
    border.frame = glass.bounds;
    border.contentsScale = scale;
    border.lineWidth = lineWidth;
    border.path = maskPath.CGPath;
    [CATransaction commit];
    objc_setAssociatedObject(glass, kLGCoverSheetMaskOrientationKey,
                             @((NSUInteger)orientation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, kLGCoverSheetMaskRadiusKey,
                             @(cornerRadius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static LGLiveBackdropView *LGCoverSheetEnsureGlass(UIView *panel) {
    UIView *parent = panel.superview;
    if (!parent) return nil;

    LGLiveBackdropView *glass =
        objc_getAssociatedObject(panel, kLGCoverSheetGlassKey);
    if (glass && !CGRectIsEmpty(glass.bounds) && !CGRectIsEmpty(panel.bounds)) {
        BOOL glassLandscape = CGRectGetWidth(glass.bounds) >
                              CGRectGetHeight(glass.bounds);
        BOOL panelLandscape = CGRectGetWidth(panel.bounds) >
                              CGRectGetHeight(panel.bounds);
        if (glassLandscape != panelLandscape) {

            [glass removeFromSuperview];
            objc_setAssociatedObject(panel, kLGCoverSheetGlassKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
            glass = nil;
        }
    }
    if (!glass) {
        glass = LGCreateRegisteredGlass(panel.frame, nil, @"CoverSheet");
        glass.autoresizingMask = UIViewAutoresizingNone;
        glass.userInteractionEnabled = NO;
        glass.backgroundColor = UIColor.clearColor;
        glass.layer.cornerRadius = 0.0;
        glass.layer.masksToBounds = NO;
        glass.hidden = YES;
        objc_setAssociatedObject(panel, kLGCoverSheetGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) {
        [glass removeFromSuperview];
    }

    [parent insertSubview:glass belowSubview:panel];
    return glass;
}

static void LGCoverSheetSyncGlassGeometry(UIView *panel,
                                          LGLiveBackdropView *glass) {
    if (!panel || !glass || glass.superview != panel.superview) return;

    // presentation geometry keeps the glass attached during interactive pulls
    CALayer *modelLayer = panel.layer;
    CALayer *sourceLayer = modelLayer.presentationLayer ?: modelLayer;
    BOOL modelLandscape = CGRectGetWidth(modelLayer.bounds) >
                          CGRectGetHeight(modelLayer.bounds);
    BOOL presentationLandscape = CGRectGetWidth(sourceLayer.bounds) >
                                 CGRectGetHeight(sourceLayer.bounds);
    if (modelLandscape != presentationLandscape) {

        sourceLayer = modelLayer;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glass.layer.anchorPoint = sourceLayer.anchorPoint;
    glass.layer.bounds = sourceLayer.bounds;
    glass.layer.position = sourceLayer.position;
    glass.layer.transform = sourceLayer.transform;
    [CATransaction commit];
    if (LGCoverSheetModeUsesGlass(sLGCoverSheetMode) &&
        [NSThread isMainThread]) {
        [CATransaction flush];
    }

    LGCoverSheetUpdateBottomCornerMask(glass);

    if (LGCoverSheetModeUsesGlass(sLGCoverSheetMode)) {

        CGPoint captureOrigin = glass.frame.origin;
        if (glass.window) {
            CGPoint windowOriginInGlass =
                [glass convertPoint:glass.window.bounds.origin
                           fromView:glass.window];
            captureOrigin = CGPointMake(-windowOriginInGlass.x,
                                        -windowOriginInGlass.y);
        }
        CGFloat width = CGRectGetWidth(glass.bounds);
        CGFloat height = CGRectGetHeight(glass.bounds);
        CGFloat scale = glass.window.screen.scale;
        if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
        UIDeviceOrientation deviceOrientation =
            LGCoverSheetDeviceOrientation(glass);
        if (width > height && !UIDeviceOrientationIsLandscape(deviceOrientation)) {

            deviceOrientation = sLGCoverSheetLastLandscapeOrientation;
        } else if (UIDeviceOrientationIsLandscape(deviceOrientation)) {
            sLGCoverSheetLastLandscapeOrientation = deviceOrientation;
        }
        LGCoverSheetWriteSharedState(
            true,
            width > 0.0 ? captureOrigin.x / width : 0.0,
            height > 0.0 ? captureOrigin.y / height : 0.0,
            scale, (uint32_t)deviceOrientation);
    }
}

@interface LGCoverSheetDisplayLinkTarget : NSObject
- (void)lg_coverSheetDisplayLinkTick:(CADisplayLink *)displayLink;
@end

@implementation LGCoverSheetDisplayLinkTarget
- (void)lg_coverSheetDisplayLinkTick:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (!LGCoverSheetModeUsesGlass(sLGCoverSheetMode)) return;
    for (UIView *panel in sLGCoverSheetPanels.allObjects) {
        LGLiveBackdropView *glass =
            objc_getAssociatedObject(panel, kLGCoverSheetGlassKey);
        if (glass && !glass.hidden) {
            LGCoverSheetSyncGlassGeometry(panel, glass);
        }
    }
}
@end

static LGCoverSheetDisplayLinkTarget *sLGCoverSheetDisplayLinkTarget;

static void LGCoverSheetSetDisplayLinkActive(BOOL active) {
    if (active) {
        if (sLGCoverSheetDisplayLink) return;
        if (!sLGCoverSheetDisplayLinkTarget) {
            sLGCoverSheetDisplayLinkTarget =
                [LGCoverSheetDisplayLinkTarget new];
        }
        sLGCoverSheetDisplayLink =
            [CADisplayLink displayLinkWithTarget:sLGCoverSheetDisplayLinkTarget
                                         selector:@selector(lg_coverSheetDisplayLinkTick:)];
        [sLGCoverSheetDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                       forMode:NSRunLoopCommonModes];
    } else {
        [sLGCoverSheetDisplayLink invalidate];
        sLGCoverSheetDisplayLink = nil;
    }
}

static CGFloat LGCoverSheetRestorePanelVisibility(UIView *panel) {
    NSNumber *originalHidden =
        objc_getAssociatedObject(panel, kLGCoverSheetOriginalHiddenKey);
    NSNumber *originalAlpha =
        objc_getAssociatedObject(panel, kLGCoverSheetOriginalAlphaKey);
    CGFloat alpha = originalAlpha ? originalAlpha.doubleValue : panel.alpha;
    if (originalHidden) panel.hidden = originalHidden.boolValue;
    objc_setAssociatedObject(panel, kLGCoverSheetOriginalHiddenKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(panel, kLGCoverSheetOriginalAlphaKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    return alpha;
}

static void LGCoverSheetCrossfadeToLockscreen(UIView *panel,
                                               LGLiveBackdropView *glass) {
    if (objc_getAssociatedObject(panel, kLGCoverSheetFadeKey)) {
        return;
    }
    CGFloat targetAlpha = LGCoverSheetRestorePanelVisibility(panel);
    glass.hidden = NO;
    glass.alpha = 1.0;
    LGCoverSheetAddOpacityFade(panel, targetAlpha);
    NSArray<UIViewController *> *wallpaperControllers =
        sLGCoverSheetWallpaperControllers.allObjects;
    for (UIViewController *controller in wallpaperControllers) {
        UIView *wallpaperView = controller.view;
        if (!wallpaperView.window || wallpaperView.hidden) continue;
        LGCoverSheetAddOpacityFade(wallpaperView, wallpaperView.alpha);
    }
    objc_setAssociatedObject(panel, kLGCoverSheetFadeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIView animateWithDuration:kLGCoverSheetHandoffDuration
                          delay:0.0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        glass.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        glass.hidden = YES;
        glass.alpha = 1.0;
        objc_setAssociatedObject(panel, kLGCoverSheetFadeKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }];
}

static void LGCoverSheetCrossfadeToHome(UIView *panel,
                                        LGLiveBackdropView *glass) {
    if (objc_getAssociatedObject(panel, kLGCoverSheetFadeKey)) {
        return;
    }

    objc_setAssociatedObject(panel, kLGCoverSheetFadeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    panel.hidden = YES;
    glass.hidden = NO;
    glass.alpha = 1.0;
    UIView *snapshot = LGCoverSheetWallpaperSnapshot(panel);
    snapshot.hidden = NO;
    snapshot.alpha = 1.0;
    [UIView animateWithDuration:kLGCoverSheetHandoffDuration
                          delay:0.0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        glass.alpha = 0.0;
        snapshot.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        CGFloat alpha = LGCoverSheetRestorePanelVisibility(panel);
        panel.alpha = alpha;
        glass.hidden = YES;
        glass.alpha = 1.0;
        LGCoverSheetRemoveWallpaperSnapshot(panel);
        objc_setAssociatedObject(panel, kLGCoverSheetFadeKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGCoverSheetConsumeDeferredDismissalCommit();
    }];
}

static void LGCoverSheetSyncPanel(UIView *panel) {
    if (!panel) return;
    if (!LGCoverSheetEnabled()) {
        [panel.layer removeAllAnimations];
        CGFloat alpha = LGCoverSheetRestorePanelVisibility(panel);
        panel.alpha = alpha;
        LGLiveBackdropView *glass =
            objc_getAssociatedObject(panel, kLGCoverSheetGlassKey);
        [glass removeFromSuperview];
        LGCoverSheetRemoveWallpaperSnapshot(panel);
        objc_setAssociatedObject(panel, kLGCoverSheetGlassKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(panel, kLGCoverSheetFadeKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    LGLiveBackdropView *glass = LGCoverSheetEnsureGlass(panel);
    if (!glass) return;
    LGCoverSheetSyncGlassGeometry(panel, glass);
    BOOL beginDismissalFadeIn =
        sLGCoverSheetBeginDismissalFadeIn &&
        sLGCoverSheetMode == LGCoverSheetModeDismissing;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (LGCoverSheetModeUsesGlass(sLGCoverSheetMode)) {
        if (!objc_getAssociatedObject(panel,
                                      kLGCoverSheetOriginalHiddenKey)) {
            objc_setAssociatedObject(
                panel, kLGCoverSheetOriginalHiddenKey, @(panel.hidden),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(
                panel, kLGCoverSheetOriginalAlphaKey, @(panel.alpha),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        panel.hidden = YES;
        glass.alpha = 1.0;
        if (beginDismissalFadeIn) {
            [glass.layer removeAnimationForKey:
                @"dylv.coversheet.dismissalFadeIn"];
            CABasicAnimation *fadeIn =
                [CABasicAnimation animationWithKeyPath:@"opacity"];
            fadeIn.fromValue = @0.0;
            fadeIn.toValue = @1.0;
            fadeIn.duration = kLGCoverSheetHandoffDuration;
            fadeIn.timingFunction = [CAMediaTimingFunction
                functionWithName:kCAMediaTimingFunctionEaseOut];
            [glass.layer addAnimation:fadeIn
                               forKey:@"dylv.coversheet.dismissalFadeIn"];
        }

        glass.hidden = NO;
        UIView *snapshot = LGCoverSheetWallpaperSnapshot(panel);
        snapshot.hidden =
            sLGCoverSheetMode != LGCoverSheetModeDismissing;
    } else {
        if (sLGCoverSheetPerformingFade) {
            [CATransaction commit];
            if (sLGCoverSheetFadeToHome) {
                LGCoverSheetCrossfadeToHome(panel, glass);
            } else {
                LGCoverSheetCrossfadeToLockscreen(panel, glass);
            }
            return;
        }
        if (objc_getAssociatedObject(panel, kLGCoverSheetFadeKey)) {
            [CATransaction commit];
            return;
        }
        CGFloat alpha = LGCoverSheetRestorePanelVisibility(panel);
        panel.alpha = alpha;
        glass.hidden = YES;
        glass.alpha = 1.0;
        LGCoverSheetRemoveWallpaperSnapshot(panel);
    }
    [CATransaction commit];
}

static void LGCoverSheetSetMode(LGCoverSheetMode mode) {
    if (!LGCoverSheetEnabled()) mode = LGCoverSheetModeIdle;
    LGCoverSheetMode previousMode = sLGCoverSheetMode;
    sLGCoverSheetMode = mode;
    sLGCoverSheetBeginDismissalFadeIn =
        mode == LGCoverSheetModeDismissing &&
        previousMode != LGCoverSheetModeDismissing;
    BOOL enteringIdle = mode == LGCoverSheetModeIdle;
    BOOL fadeToLockscreen =
        enteringIdle &&
        previousMode == LGCoverSheetModePresentingGlass &&
        sLGCoverSheetCommitEndPresented;
    sLGCoverSheetFadeToHome =
        enteringIdle &&
        previousMode == LGCoverSheetModeDismissing &&
        !sLGCoverSheetCommitEndPresented;
    sLGCoverSheetPerformingFade =
        fadeToLockscreen || sLGCoverSheetFadeToHome;
    sLGCoverSheetCommitEndPresented = NO;
    if (!LGCoverSheetModeUsesGlass(mode)) {
        LGCoverSheetWriteSharedState(false, 0.0f, 0.0f, 0.0f, 0u);
    }
    LGCoverSheetSetDisplayLinkActive(
        LGCoverSheetModeUsesGlass(mode));
    for (UIView *panel in sLGCoverSheetPanels.allObjects) {
        LGCoverSheetSyncPanel(panel);
    }
    sLGCoverSheetBeginDismissalFadeIn = NO;
    sLGCoverSheetPerformingFade = NO;
    sLGCoverSheetFadeToHome = NO;
}

%hook SBCoverSheetPanelBackgroundContainerView

- (void)didMoveToWindow {
    %orig;
    UIView *panel = (UIView *)self;
    if (!sLGCoverSheetPanels) {
        sLGCoverSheetPanels = [NSHashTable weakObjectsHashTable];
    }
    if (panel.window) {
        [sLGCoverSheetPanels addObject:panel];
        LGCoverSheetSyncPanel(panel);
    } else {
        LGLiveBackdropView *glass =
            objc_getAssociatedObject(panel, kLGCoverSheetGlassKey);
        [glass removeFromSuperview];
        LGCoverSheetRemoveWallpaperSnapshot(panel);
        objc_setAssociatedObject(panel, kLGCoverSheetGlassKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        [sLGCoverSheetPanels removeObject:panel];
    }
}

- (void)layoutSubviews {
    %orig;
    LGCoverSheetSyncPanel((UIView *)self);
}

%end

%hook PBUIPosterWallpaperRemoteViewController

- (void)viewDidLoad {
    %orig;
    if (LGCoverSheetEnabled())
        LGCoverSheetRegisterWallpaperController((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (LGCoverSheetEnabled())
        LGCoverSheetRegisterWallpaperController((UIViewController *)self);
}

%end


static void LGCoverSheetProbeCapabilities(id manager) {
    if (!LGDebugLoggingEnabled()) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *selectors = @[
            @"_isEffectivelyLocked",
            @"coverSheetSlidingViewControllerShouldAllowDismissal:",
            @"coverSheetSlidingViewControllerDidPassRubberBandThreshold:",
            @"_prepareForRubberBandDismissalTransitionForSlidingViewController:",
            @"coverSheetSlidingViewController:committingToEndPresented:",
            @"coverSheetSlidingViewController:prepareForPresentationTransitionForUserGesture:",
            @"coverSheetSlidingViewController:animationTickedWithProgress:velocity:coverSheetFrame:gestureActive:forPresentationValue:",
            @"coverSheetSlidingViewController:animationTickedWithProgress:coverSheetFrame:gestureActive:forPresentationValue:",
            @"_notifyDelegateRequestsUnlock",
        ];
        NSMutableString *out = [NSMutableString stringWithFormat:
            @"[CSSWIPE] probe ios=%@ manager=%@ legacyPath=%d enabled=%d",
            UIDevice.currentDevice.systemVersion,
            manager ? NSStringFromClass([manager class]) : @"nil",
            LGCoverSheetUsesLegacyLockedDismissal(), LGCoverSheetEnabled()];
        for (NSString *name in selectors) {
            [out appendFormat:@"\n  %@ = %d", name,
                [manager respondsToSelector:NSSelectorFromString(name)]];
        }

        [out appendString:@"\n  --- actual delegate selectors ---"];
        for (Class cls = [manager class]; cls && cls != NSObject.class;
             cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                if ([name containsString:@"animationTicked"] ||
                    [name containsString:@"coverSheetSlidingViewController"] ||
                    [name containsString:@"RubberBand"] ||
                    [name containsString:@"Unlock"] ||
                    [name containsString:@"unlock"] ||
                    [name containsString:@"asscode"] ||
                    [name containsString:@"uthenticat"]) {
                    [out appendFormat:@"\n    %@ %@", NSStringFromClass(cls), name];
                }
            }
            free(methods);
        }
        LGLog(@"%@", out);
    });
}

static void LGCoverSheetTrace(id manager, NSString *event, NSString *detail) {
    if (!LGDebugLoggingEnabled()) return;
    LGCoverSheetProbeCapabilities(manager);
    LGLog(@"[CSSWIPE] %@ relax=%d locked=%d mode=%d handoff=%d rollback=%d "
          @"firstRollbackEnded=%d pin=%d passcode=%d%@%@",
          event, LGCoverSheetShouldRelaxLockedGate(manager),
          LGCoverSheetIsEffectivelyLocked(manager), (int)sLGCoverSheetMode,
          sLGCoverSheetLockedHandoffActive, sLGCoverSheetLockedRollbackCommitted,
          sLGCoverSheetLockedFirstRollbackDidEnd,
          sLGCoverSheetLockedVisualPinActive, sLGCoverSheetLockedPasscodeTriggered,
          detail.length ? @" " : @"", detail ?: @"");
}

static void LGCoverSheetHandleAnimationTick(id self, id controller, double progress,
                                            CGRect coverSheetFrame,
                                            BOOL gestureActive,
                                            BOOL forPresentationValue,
                                            void (^callOrig)(void)) {
    BOOL terminalModelTick =
        sLGCoverSheetLockedHandoffActive &&
        !forPresentationValue && !gestureActive && progress >= 0.999;
    BOOL shouldBeginLogicalRollback =
        terminalModelTick && !sLGCoverSheetLockedRollbackCommitted;
    BOOL shouldBeginVisualPin =
        terminalModelTick && !sLGCoverSheetLockedVisualPinActive;

    if (sLGCoverSheetLockedHandoffActive &&
        sLGCoverSheetLockedRollbackCommitted &&
        forPresentationValue && !gestureActive) {
        return;
    }

    if (LGDebugLoggingEnabled()) {
        static BOOL lastHandoff, lastRollback, lastPin;
        static BOOL seenFirstTick;
        if (!seenFirstTick || lastHandoff != sLGCoverSheetLockedHandoffActive ||
            lastRollback != sLGCoverSheetLockedRollbackCommitted ||
            lastPin != sLGCoverSheetLockedVisualPinActive) {
            seenFirstTick = YES;
            lastHandoff = sLGCoverSheetLockedHandoffActive;
            lastRollback = sLGCoverSheetLockedRollbackCommitted;
            lastPin = sLGCoverSheetLockedVisualPinActive;
            LGCoverSheetTrace(self, @"tick",
                [NSString stringWithFormat:
                    @"progress=%.3f gesture=%d forPresentation=%d "
                    @"frame=%@ terminal=%d beginRollback=%d beginPin=%d",
                    progress, gestureActive, forPresentationValue,
                    NSStringFromCGRect(coverSheetFrame), terminalModelTick,
                    shouldBeginLogicalRollback, shouldBeginVisualPin]);
        }
    }

    if (shouldBeginVisualPin) {
        LGCoverSheetBeginLockedVisualPin(controller, coverSheetFrame);
    }

    callOrig();

    if (sLGCoverSheetLockedVisualPinActive) {
        LGCoverSheetUpdateLockedVisualPin(coverSheetFrame);
    }

    if (shouldBeginLogicalRollback &&
        !sLGCoverSheetLockedRollbackCommitted) {
        SEL commitSelector = NSSelectorFromString(
            @"coverSheetSlidingViewController:committingToEndPresented:");
        if ([(id)self respondsToSelector:commitSelector]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(
                self, commitSelector, controller, YES);
        } else {
            LGLog(@"[coversheet-unlock] logical rollback selector unavailable");
            LGCoverSheetResetLockedHandoff(YES);
        }
    }

    
}

static void LGCoverSheetHandleTransitionEnd(id self, id controller,
                                            NSString *source,
                                            void (^callOrig)(void)) {
    LGCoverSheetTrace(self, @"transitionEnd", source);
    BOOL trackingRollback =
        sLGCoverSheetLockedHandoffActive &&
        sLGCoverSheetLockedRollbackCommitted;

    if (!trackingRollback) {
        callOrig();
        return;
    }

    BOOL singlePhase = [source isEqualToString:@"cleanupPresentation"];
    if (!singlePhase && !sLGCoverSheetLockedFirstRollbackDidEnd) {
        sLGCoverSheetLockedFirstRollbackDidEnd = YES;
        callOrig();
        return;
    }
    callOrig();

    sLGCoverSheetLockedHandoffActive = NO;
    sLGCoverSheetLockedRollbackCommitted = NO;
    sLGCoverSheetLockedFirstRollbackDidEnd = NO;
    sLGCoverSheetLockedHandoffManager = nil;
    sLGCoverSheetCommitEndPresented = YES;
    LGCoverSheetSetMode(LGCoverSheetModeIdle);
    id managerCopy = (id)self;
    id controllerCopy = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGCoverSheetRequestLockedPasscode(managerCopy, controllerCopy);

        NSUInteger transferred =
            LGCoverSheetTransferRootPinToNonPasscodeBranches(controllerCopy);
        LGCoverSheetReleaseLockedVisualPin();

        if (transferred > 0) {
            LGCoverSheetWatchBranchPinsForPasscodeDismissal();
        }
    });
}

%hook SBCoverSheetPresentationManager

- (BOOL)coverSheetSlidingViewControllerShouldAllowDismissal:(id)controller {
    BOOL original = %orig;
    LGCoverSheetTrace(self, @"shouldAllowDismissal",
                      [NSString stringWithFormat:@"orig=%d", original]);
    if (LGCoverSheetShouldRelaxLockedGate(self)) {
        return YES;
    }
    return original;
}

- (void)coverSheetSlidingViewControllerDidPassRubberBandThreshold:(id)controller {
    LGCoverSheetTrace(self, @"didPassRubberBandThreshold", nil);
    if (LGCoverSheetShouldRelaxLockedGate(self)) {
        return;
    }
    %orig;
}

- (void)_prepareForRubberBandDismissalTransitionForSlidingViewController:(id)controller {
    LGCoverSheetTrace(self, @"prepareForRubberBandDismissal", nil);
    if (LGCoverSheetShouldRelaxLockedGate(self)) {
        return;
    }
    %orig;
}

- (void)coverSheetSlidingViewController:(id)controller
prepareForPresentationTransitionForUserGesture:(BOOL)userGesture {
    %orig;
    (void)controller;
    LGCoverSheetTrace(self, @"prepareForPresentation",
                      [NSString stringWithFormat:@"userGesture=%d", userGesture]);
    if (LGCoverSheetEnabled() && userGesture) {
        LGCoverSheetSetMode(LGCoverSheetModePresentingGlass);
    }
}

- (void)coverSheetSlidingViewController:(id)controller
prepareForDismissalTransitionForReversingTransition:(BOOL)reversing
                         forUserGesture:(BOOL)userGesture {
    BOOL relaxed = LGCoverSheetShouldRelaxLockedGate(self);
    LGCoverSheetTrace(self, @"prepareForDismissal",
                      [NSString stringWithFormat:@"userGesture=%d reversing=%d relaxed=%d",
                                                 userGesture, reversing, relaxed]);
    if (relaxed) {
        LGCoverSheetResetLockedHandoff(YES);
    } else if (LGCoverSheetEnabled() && userGesture) {
        LGCoverSheetCaptureWallpaperSnapshots();
    }

    %orig;
    (void)controller;
    (void)reversing;

    if (LGCoverSheetEnabled() && userGesture) {
        LGCoverSheetSetMode(LGCoverSheetModeDismissing);
    }
}

- (void)coverSheetSlidingViewController:(id)controller
             animationTickedWithProgress:(double)progress
                                velocity:(double)velocity
                        coverSheetFrame:(CGRect)coverSheetFrame
                           gestureActive:(BOOL)gestureActive
                 forPresentationValue:(BOOL)forPresentationValue {
    (void)velocity;
    LGCoverSheetHandleAnimationTick(self, controller, progress, coverSheetFrame,
                                    gestureActive, forPresentationValue, ^{
        %orig;
    });
}

- (void)coverSheetSlidingViewController:(id)controller
             animationTickedWithProgress:(double)progress
                        coverSheetFrame:(CGRect)coverSheetFrame
                           gestureActive:(BOOL)gestureActive
                 forPresentationValue:(BOOL)forPresentationValue {
    LGCoverSheetHandleAnimationTick(self, controller, progress, coverSheetFrame,
                                    gestureActive, forPresentationValue, ^{
        %orig;
    });
}

- (void)coverSheetSlidingViewControllerDidEndTransition:(id)controller {
    LGCoverSheetHandleTransitionEnd(self, controller, @"didEndTransition", ^{
        %orig;
    });
}

- (void)coverSheetSlidingViewControllerCleanupPresentationTransition:(id)controller {
    LGCoverSheetHandleTransitionEnd(self, controller, @"cleanupPresentation", ^{
        %orig;
    });
}

- (void)willUIUnlockWithPendingUnlockRequest:(BOOL)pending {
    if (!LGCoverSheetIsEffectivelyLocked(self)) {
        LGCoverSheetResetLockedHandoff(YES);
    }
    %orig;
    (void)pending;
}

- (void)coverSheetSlidingViewController:(id)controller
               committingToEndPresented:(BOOL)endPresented {
    if (!LGCoverSheetEnabled()) {
        %orig;
        sLGCoverSheetCommitEndPresented = NO;
        LGCoverSheetSetMode(LGCoverSheetModeIdle);
        LGCoverSheetConsumeDeferredDismissalCommit();
        return;
    }

    BOOL completedDismissal =
        sLGCoverSheetMode == LGCoverSheetModeDismissing && !endPresented;

    if (LGCoverSheetShouldRelaxLockedGate(self) && !endPresented) {
        sLGCoverSheetLockedHandoffActive = YES;
        sLGCoverSheetLockedRollbackCommitted = NO;
        sLGCoverSheetLockedFirstRollbackDidEnd = NO;
        sLGCoverSheetLockedHandoffManager = (id)self;
        return;
    }

    if (sLGCoverSheetLockedHandoffActive && endPresented) {
        if (sLGCoverSheetLockedRollbackCommitted) {
            return;
        }

        sLGCoverSheetLockedRollbackCommitted = YES;
        %orig;
        sLGCoverSheetCommitEndPresented = YES;
        return;
    }

    BOOL hasFrozenWallpaper = NO;
    if (completedDismissal) {
        for (UIView *panel in sLGCoverSheetPanels.allObjects) {
            if (LGCoverSheetWallpaperSnapshot(panel)) {
                hasFrozenWallpaper = YES;
                break;
            }
        }
    }

    if (completedDismissal && hasFrozenWallpaper) {
        id manager = self;
        id slidingController = controller;
        sLGCoverSheetDeferredDismissalCommit = [^{
            %orig(slidingController, endPresented);
            (void)manager;
        } copy];
        sLGCoverSheetCommitEndPresented = endPresented;
        LGCoverSheetSetMode(LGCoverSheetModeIdle);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)((kLGCoverSheetHandoffDuration + 0.05) *
                                    NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                LGCoverSheetConsumeDeferredDismissalCommit();
            });
        return;
    }

    %orig;
    (void)controller;
    sLGCoverSheetCommitEndPresented = endPresented;
    LGCoverSheetSetMode(LGCoverSheetModeIdle);
}


- (void)_setCoverSheetPresented:(BOOL)presented
                 forcePresented:(BOOL)forcePresented
                       animated:(BOOL)animated
                 withCompletion:(id)completion {
    BOOL fastTerminal =
        sLGCoverSheetLockedHandoffActive &&
        sLGCoverSheetLockedRollbackCommitted &&
        presented && forcePresented && animated;

    if (fastTerminal) {
        %orig(presented, forcePresented, NO, completion);
        return;
    }

    %orig;
}

- (void)_setCoverSheetPresented:(BOOL)presented
                 forcePresented:(BOOL)forcePresented
                       animated:(BOOL)animated
                        options:(NSUInteger)options
                 withCompletion:(id)completion {
    BOOL fastTerminal =
        sLGCoverSheetLockedHandoffActive &&
        sLGCoverSheetLockedRollbackCommitted &&
        presented && forcePresented && animated;

    if (fastTerminal) {
        %orig(presented, forcePresented, NO, options, completion);
        return;
    }

    %orig;
}

%end

%hook SBCoverSheetPrimarySlidingViewController

- (void)_commitTransitionToAppeared:(BOOL)appeared animated:(BOOL)animated {
    BOOL fastPhase1 =
        sLGCoverSheetLockedHandoffActive &&
        !sLGCoverSheetLockedRollbackCommitted &&
        !appeared && animated;

    if (!fastPhase1) {
        %orig;
        return;
    }

    id manager = sLGCoverSheetLockedHandoffManager;
    SEL commitSelector = NSSelectorFromString(
        @"coverSheetSlidingViewController:committingToEndPresented:");

    if (!manager || ![(id)manager respondsToSelector:commitSelector]) {
        LGLog(@"[coversheet-unlock] phase 1 accelerator unavailable; "
              "use normal animation");
        %orig;
        return;
    }
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(
        manager, commitSelector, (id)self, YES);

    if (!sLGCoverSheetLockedRollbackCommitted) {
        LGLog(@"[coversheet-unlock] phase 1 logical commit rejected; "
              "use normal animation");
        %orig;
        return;
    }

    %orig(appeared, NO);
}

%end

%ctor {
    sLGCoverSheetPanels = [NSHashTable weakObjectsHashTable];
    sLGCoverSheetWallpaperControllers = [NSHashTable weakObjectsHashTable];
    lgObservePreferenceReload(^{
        if (!LGCoverSheetEnabled()) {
            sLGCoverSheetMode = LGCoverSheetModeIdle;
            sLGCoverSheetCommitEndPresented = NO;
            LGCoverSheetResetLockedHandoff(YES);
            sLGCoverSheetPerformingFade = NO;
            sLGCoverSheetFadeToHome = NO;
            sLGCoverSheetBeginDismissalFadeIn = NO;
            LGCoverSheetSetDisplayLinkActive(NO);
            LGCoverSheetWriteSharedState(false, 0.0f, 0.0f, 0.0f, 0u);
            LGCoverSheetConsumeDeferredDismissalCommit();
        }
        for (UIView *panel in sLGCoverSheetPanels.allObjects) {
            LGCoverSheetSyncPanel(panel);
        }
    });
}
