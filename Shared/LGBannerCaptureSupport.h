#pragma once

#import <UIKit/UIKit.h>

@class LiquidGlassView;

void LGRemoveLiveBackdropCaptureView(UIView *host, const void *associationKey);
void LGRemoveServerMaterialForHost(UIView *host, LiquidGlassView *glass);
void LGSetLiveBackdropCaptureUsesModelGeometry(UIView *host, BOOL usesModelGeometry);
BOOL LGCaptureLiveBackdropTextureForHost(UIView *host,
                                         LiquidGlassView *glass,
                                         const void *associationKey,
                                         CGPoint *outOrigin,
                                         CGSize *outSamplingResolution);
BOOL LGApplyRenderingModeToGlassHost(UIView *host,
                                     LiquidGlassView *glass,
                                     NSString *renderingModeKey,
                                     const void *associationKey,
                                     UIImage *snapshot,
                                     CGPoint snapshotOrigin);
BOOL LGShouldRefreshLiveCaptureForHost(UIView *host,
                                       NSString *renderingModeKey,
                                       const void *lastCaptureTimeKey,
                                       CGFloat framesPerSecond,
                                       BOOL hadGlass);
void LGMarkLiveCaptureRefreshedForHost(UIView *host, const void *lastCaptureTimeKey);
