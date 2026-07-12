#pragma once
#import <UIKit/UIKit.h>
#import "LGSharedSupport.h"

// Render-server-native glass material: a CABackdropLayer with CAFilter
// blur/saturation evaluated by backboardd per composited frame, plus
// client-cheap specular and rim overlay layers. Replaces the live-capture
// (drawViewHierarchyInRect -> Metal) pipeline for dynamic backgrounds.
//
// Views with identical material parameters share one server-side
// capture+blur pass via a common CABackdropLayer groupName.

typedef NS_ENUM(NSInteger, LGGlassRimMode) {
    LGGlassRimModeGradient = 0, // light/dark gradient ring, no extra backdrop groups
    LGGlassRimModeZoom,         // thin zoomed backdrop strips faking edge refraction
    LGGlassRimModeNone,
};

@interface LGGlassMaterialView : UIView

@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat blur;             // gaussianBlur inputRadius, pts
@property (nonatomic, assign) CGFloat saturation;       // colorSaturate inputAmount, default 1.6
@property (nonatomic, assign) CGFloat brightness;       // colorBrightness inputAmount, default 0
@property (nonatomic, assign) CGFloat specularOpacity;  // 0 disables the sheen layer
@property (nonatomic, assign) CGFloat specularAngle;    // radians, driven by motion
@property (nonatomic, assign) CGFloat rimWidth;         // pts, default 3
@property (nonatomic, assign) LGGlassRimMode rimMode;
@property (nonatomic, strong) UIImage *shapeMaskImage;
@property (nonatomic, assign) NSInteger updateGroup;    // LGUpdateGroup; joins the shared registry

// Available when CABackdropLayer + CAFilter exist and the material path
// is not disabled by pref. Callers must fall back to snapshot mode when NO.
+ (BOOL)isSupported;

// Pushes a new motion-driven specular angle to every live instance,
// including those not in an update-group registry. Main thread only.
+ (void)updateAllSpecularAngles:(CGFloat)angle;

// Registry entry points (duck-typed by LG_update/redrawRegisteredGlassViews).
- (void)updateOrigin;
- (void)scheduleDraw;

@end
