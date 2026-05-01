#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

typedef struct {
    CGFloat centerX;
    CGFloat width;
    CGFloat height;
    CGFloat rubberBandOffset;
} LGLiquidDragState;

typedef struct {
    CGFloat centerX;
    CGFloat width;
    CGFloat height;
} LGLiquidRenderedState;

static inline CGFloat LGLiquidRubberBandedCenterX(CGFloat touchX, CGFloat minX, CGFloat maxX, CGFloat factor) {
    if (touchX < minX) {
        return minX - sqrt(minX - touchX) * factor;
    }
    if (touchX > maxX) {
        return maxX + sqrt(touchX - maxX) * factor;
    }
    return touchX;
}

static inline CGFloat LGLiquidOvershootDistance(CGFloat touchX, CGFloat minX, CGFloat maxX) {
    if (touchX < minX) return minX - touchX;
    if (touchX > maxX) return touchX - maxX;
    return 0.0;
}

static inline LGLiquidDragState LGLiquidDragStateMake(CGFloat touchX,
                                                      CGFloat minX,
                                                      CGFloat maxX,
                                                      CGSize baseSize,
                                                      CGFloat velocity,
                                                      CGFloat minHeight) {
    LGLiquidDragState state;
    state.centerX = LGLiquidRubberBandedCenterX(touchX, minX, maxX, 1.24);
    state.width = baseSize.width;
    state.height = baseSize.height;
    state.rubberBandOffset = 0.0;

    if (touchX < minX) {
        state.rubberBandOffset = state.centerX - minX;
    } else if (touchX > maxX) {
        state.rubberBandOffset = state.centerX - maxX;
    }

    CGFloat overshoot = LGLiquidOvershootDistance(touchX, minX, maxX);
    CGFloat normalizedVelocity = fmin(fabs(velocity) / 900.0, 1.0);
    CGFloat motionStretch = pow(normalizedVelocity, 0.71);
    CGFloat directionalBias = velocity >= 0.0 ? 1.0 : -1.0;
    CGFloat overshootBias = fmin(overshoot / 16.0, 1.0);
    CGFloat widthBoost = 19.5 * motionStretch + 5.8 * overshootBias;
    CGFloat heightReduction = 5.4 * motionStretch + 1.8 * overshootBias;
    CGFloat xShift = directionalBias * (5.1 * motionStretch + 2.4 * overshootBias);

    state.centerX += xShift;
    state.width += widthBoost;
    state.height = fmax(minHeight, state.height - heightReduction);
    return state;
}

static inline LGLiquidRenderedState LGLiquidRenderedStateMake(CGFloat centerX, CGSize size) {
    LGLiquidRenderedState state;
    state.centerX = centerX;
    state.width = size.width;
    state.height = size.height;
    return state;
}

static inline LGLiquidRenderedState LGLiquidRenderedStateStep(LGLiquidRenderedState current,
                                                              LGLiquidRenderedState target,
                                                              BOOL active,
                                                              CGFloat dt) {
    CGFloat frameFactor = fmin(fmax(dt * 60.0, 0.35), 1.4);
    CGFloat centerLerp = (active ? 0.21 : 0.14) * frameFactor;
    CGFloat sizeLerp = (active ? 0.25 : 0.15) * frameFactor;
    current.centerX += (target.centerX - current.centerX) * centerLerp;
    current.width += (target.width - current.width) * sizeLerp;
    current.height += (target.height - current.height) * sizeLerp;
    return current;
}
