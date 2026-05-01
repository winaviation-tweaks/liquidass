#import "LGHookSupport.h"
#import "LGSharedSupport.h"
#import <objc/runtime.h>

static const NSInteger kLGMaxTraverseDepth = 128;

BOOL LGHasAncestorClass(UIView *view, Class cls) {
    if (!view || !cls) return NO;
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([ancestor isKindOfClass:cls]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

BOOL LGHasAncestorClassNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return NO;
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:className]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

BOOL LGResponderChainContainsClassNamed(UIResponder *responder, NSString *className) {
    if (!className.length) return NO;
    UIResponder *current = responder;
    while (current) {
        if ([NSStringFromClass(current.class) isEqualToString:className]) return YES;
        current = current.nextResponder;
    }
    return NO;
}

void LGTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root || !block) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray arrayWithObject:@0];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        NSInteger depth = depths.lastObject.integerValue;
        [stack removeLastObject];
        [depths removeLastObject];
        block(view);
        if (depth >= kLGMaxTraverseDepth) continue;
        NSArray<UIView *> *subviews = view.subviews;
        for (UIView *subview in subviews.reverseObjectEnumerator) {
            [stack addObject:subview];
            [depths addObject:@(depth + 1)];
        }
    }
}

UIColor *LGDefaultTintColorForViewWithOverrideKey(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha, NSString *overrideKey) {
    NSString *override = nil;
    if (overrideKey.length) {
        override = LG_prefString(overrideKey, LGTintOverrideSystem);
    }
    if ([override isEqualToString:LGTintOverrideDark]) {
        return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
    }
    if ([override isEqualToString:LGTintOverrideLight]) {
        return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
    }
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
        }
    }
    return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
}

UIColor *LGDefaultTintColorForView(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    return LGDefaultTintColorForViewWithOverrideKey(view, lightAlpha, darkAlpha, nil);
}

NSInteger LGPreferredFramesPerSecondForKey(NSString *key, NSInteger minFPS) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fallback = maxFPS >= 120 ? 120 : 60;
    NSInteger fps = LG_prefInteger(key, fallback);
    if (fps < minFPS) fps = minFPS;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

UIView *LGEnsureTintOverlayView(UIView *host,
                                const void *associationKey,
                                NSInteger tag,
                                CGRect frame,
                                UIViewAutoresizing autoresizingMask) {
    if (!host || !associationKey) return nil;
    UIView *overlay = objc_getAssociatedObject(host, associationKey);
    if (!overlay) {
        overlay = [[UIView alloc] initWithFrame:frame];
        overlay.userInteractionEnabled = NO;
        overlay.tag = tag;
        overlay.autoresizingMask = autoresizingMask;
        [host addSubview:overlay];
        objc_setAssociatedObject(host, associationKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    overlay.frame = frame;
    return overlay;
}

void LGConfigureTintOverlayView(UIView *overlay,
                                UIColor *backgroundColor,
                                CGFloat cornerRadius,
                                CALayer *referenceLayer,
                                BOOL masksToBounds) {
    if (!overlay) return;
    overlay.backgroundColor = backgroundColor;
    overlay.hidden = (backgroundColor == nil);
    overlay.layer.cornerRadius = cornerRadius;
    overlay.layer.masksToBounds = masksToBounds;
    if (@available(iOS 13.0, *)) {
        if ([referenceLayer respondsToSelector:@selector(cornerCurve)]) {
            overlay.layer.cornerCurve = referenceLayer.cornerCurve;
        }
    }
}

void LGRemoveAssociatedSubview(UIView *host, const void *associationKey) {
    if (!host || !associationKey) return;
    UIView *view = objc_getAssociatedObject(host, associationKey);
    [view removeFromSuperview];
    objc_setAssociatedObject(host, associationKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

@interface LGDisplayLinkDriver : NSObject
@property (nonatomic, copy) dispatch_block_t tickBlock;
- (instancetype)initWithTickBlock:(dispatch_block_t)tickBlock;
- (void)tick:(CADisplayLink *)displayLink;
@end

@implementation LGDisplayLinkDriver

- (instancetype)initWithTickBlock:(dispatch_block_t)tickBlock {
    self = [super init];
    if (!self) return nil;
    _tickBlock = [tickBlock copy];
    return self;
}

- (void)tick:(__unused CADisplayLink *)displayLink {
    if (self.tickBlock) self.tickBlock();
}

@end

@interface LGSharedDisplayLinkHub : NSObject
- (void)tick:(CADisplayLink *)displayLink;
@end

static CADisplayLink *sSharedDisplayLink = nil;
static LGSharedDisplayLinkHub *sSharedDisplayLinkHub = nil;
static NSMutableArray<NSValue *> *sSharedDisplayLinkStates = nil;

static NSInteger LGSharedDisplayLinkMaximumFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    return maxFPS > 0 ? maxFPS : 60;
}

static void LGStopSharedDisplayLinkIfIdle(void) {
    if (sSharedDisplayLinkStates.count > 0) return;
    [sSharedDisplayLink invalidate];
    sSharedDisplayLink = nil;
    sSharedDisplayLinkHub = nil;
}

static void LGReconfigureSharedDisplayLinkFPS(void) {
    if (!sSharedDisplayLink) return;
    NSInteger highestFPS = 0;
    for (NSValue *value in sSharedDisplayLinkStates) {
        LGDisplayLinkState *state = value.pointerValue;
        if (!state || state->link != sSharedDisplayLink) continue;
        highestFPS = MAX(highestFPS, state->preferredFPS);
    }
    if (highestFPS <= 0) {
        [sSharedDisplayLink invalidate];
        sSharedDisplayLink = nil;
        sSharedDisplayLinkHub = nil;
        return;
    }
    NSInteger cappedFPS = MIN(MAX(highestFPS, 1), LGSharedDisplayLinkMaximumFPS());
    if ([sSharedDisplayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        sSharedDisplayLink.preferredFramesPerSecond = cappedFPS;
    }
}

@implementation LGSharedDisplayLinkHub

- (void)tick:(CADisplayLink *)displayLink {
    NSArray<NSValue *> *states = [sSharedDisplayLinkStates copy];
    for (NSValue *value in states) {
        LGDisplayLinkState *state = value.pointerValue;
        if (!state || state->link != sSharedDisplayLink) continue;

        NSInteger preferredFPS = MAX(state->preferredFPS, 1);
        CFTimeInterval minimumInterval = 1.0 / (CFTimeInterval)preferredFPS;
        if (state->lastTickTimestamp > 0.0) {
            CFTimeInterval delta = displayLink.timestamp - state->lastTickTimestamp;
            if (delta + 0.0005 < minimumInterval) continue;
        }
        state->lastTickTimestamp = displayLink.timestamp;

        LGDisplayLinkDriver *driver = state->driver;
        if (driver) [driver tick:displayLink];
    }
}

@end

static void LGEnsureSharedDisplayLink(void) {
    if (!sSharedDisplayLinkStates) {
        sSharedDisplayLinkStates = [NSMutableArray array];
    }
    if (sSharedDisplayLink) return;
    sSharedDisplayLinkHub = [LGSharedDisplayLinkHub new];
    sSharedDisplayLink = [CADisplayLink displayLinkWithTarget:sSharedDisplayLinkHub selector:@selector(tick:)];
    [sSharedDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

void LGStartDisplayLink(CADisplayLink *__strong *linkStorage,
                        id __strong *driverStorage,
                        NSInteger preferredFPS,
                        dispatch_block_t tickBlock) {
    LGAssertMainThread();
    if (!linkStorage || !driverStorage || *linkStorage) return;
    LGDisplayLinkDriver *driver = [[LGDisplayLinkDriver alloc] initWithTickBlock:tickBlock];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick:)];
    if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        link.preferredFramesPerSecond = preferredFPS;
    }
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    *driverStorage = driver;
    *linkStorage = link;
}

void LGStopDisplayLink(CADisplayLink *__strong *linkStorage,
                       id __strong *driverStorage) {
    LGAssertMainThread();
    if (!linkStorage || !*linkStorage) return;
    [*linkStorage invalidate];
    *linkStorage = nil;
    if (driverStorage) *driverStorage = nil;
}

void LGStartDisplayLinkState(LGDisplayLinkState *state,
                             NSInteger preferredFPS,
                             dispatch_block_t tickBlock) {
    LGAssertMainThread();
    if (!state) return;
    if (state->link) return;
    LGEnsureSharedDisplayLink();
    LGDisplayLinkDriver *driver = [[LGDisplayLinkDriver alloc] initWithTickBlock:tickBlock];
    state->driver = driver;
    state->preferredFPS = MIN(MAX(preferredFPS, 1), LGSharedDisplayLinkMaximumFPS());
    state->lastTickTimestamp = 0.0;
    state->link = sSharedDisplayLink;
    [sSharedDisplayLinkStates addObject:[NSValue valueWithPointer:state]];
    LGReconfigureSharedDisplayLinkFPS();
}

void LGStopDisplayLinkState(LGDisplayLinkState *state) {
    LGAssertMainThread();
    if (!state) return;
    if (!state->link) return;
    for (NSInteger index = sSharedDisplayLinkStates.count - 1; index >= 0; index--) {
        LGDisplayLinkState *candidate = sSharedDisplayLinkStates[index].pointerValue;
        if (candidate == state) {
            [sSharedDisplayLinkStates removeObjectAtIndex:index];
        }
    }
    state->link = nil;
    state->driver = nil;
    state->preferredFPS = 0;
    state->lastTickTimestamp = 0.0;
    LGReconfigureSharedDisplayLinkFPS();
    LGStopSharedDisplayLinkIfIdle();
}
