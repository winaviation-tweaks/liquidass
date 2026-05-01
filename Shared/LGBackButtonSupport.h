#pragma once

#import <UIKit/UIKit.h>

@class LGSharedBackButtonView;

UIView *LGBackButtonPreferredContainerView(UIView *view);

@interface LGSharedBackButtonView : UIView

- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)setPressed:(BOOL)pressed;
- (void)refreshBackdropAfterScreenUpdates:(BOOL)afterScreenUpdates;
- (void)cleanupBackdropCapture;

@end
