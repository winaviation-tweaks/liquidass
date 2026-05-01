#import "LGSnapshotCaptureSupport.h"
#import <QuartzCore/QuartzCore.h>

BOOL LGDrawViewHierarchyIntoCurrentContext(UIView *view, CGRect drawRect, BOOL afterUpdates) {
    if (!view) return NO;
    BOOL didDrawHierarchy = [view drawViewHierarchyInRect:drawRect afterScreenUpdates:afterUpdates];
    BOOL usedLayerFallback = NO;
    if (!didDrawHierarchy && !afterUpdates) {
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        usedLayerFallback = YES;
    }
    return didDrawHierarchy || usedLayerFallback;
}

UIImage *LGCaptureViewHierarchySnapshot(UIView *view, CGRect drawRect, CGSize canvasSize, CGFloat scale, BOOL afterUpdates) {
    if (!view || canvasSize.width <= 0.0 || canvasSize.height <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(canvasSize, NO, scale);
    BOOL ok = LGDrawViewHierarchyIntoCurrentContext(view, drawRect, afterUpdates);
    UIImage *snapshot = ok ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    return snapshot;
}
