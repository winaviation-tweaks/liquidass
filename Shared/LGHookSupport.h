#pragma once

#import <UIKit/UIKit.h>

BOOL LGHasAncestorClass(UIView *view, Class cls);
BOOL LGHasAncestorClassNamed(UIView *view, NSString *className);
BOOL LGResponderChainContainsClassNamed(UIResponder *responder, NSString *className);
void LGTraverseViews(UIView *root, void (^block)(UIView *view));
UIColor *LGDefaultTintColorForView(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha);
UIColor *LGDefaultTintColorForViewWithOverrideKey(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha, NSString *overrideKey);
NSInteger LGPreferredFramesPerSecondForKey(NSString *key, NSInteger minFPS);
typedef struct {
    NSInteger activeCount;
    NSInteger preferredFPS;
    CFTimeInterval lastTickTimestamp;
    __strong CADisplayLink *link;
    __strong id driver;
} LGDisplayLinkState;
UIView *LGEnsureTintOverlayView(UIView *host,
                                const void *associationKey,
                                NSInteger tag,
                                CGRect frame,
                                UIViewAutoresizing autoresizingMask);
void LGConfigureTintOverlayView(UIView *overlay,
                                UIColor *backgroundColor,
                                CGFloat cornerRadius,
                                CALayer *referenceLayer,
                                BOOL masksToBounds);
void LGRemoveAssociatedSubview(UIView *host, const void *associationKey);

void LGStartDisplayLink(CADisplayLink *__strong *linkStorage,
                        id __strong *driverStorage,
                        NSInteger preferredFPS,
                        dispatch_block_t tickBlock);
void LGStopDisplayLink(CADisplayLink *__strong *linkStorage,
                       id __strong *driverStorage);
void LGStartDisplayLinkState(LGDisplayLinkState *state,
                             NSInteger preferredFPS,
                             dispatch_block_t tickBlock);
void LGStopDisplayLinkState(LGDisplayLinkState *state);
