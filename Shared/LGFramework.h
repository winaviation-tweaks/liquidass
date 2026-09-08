#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "LGLiveBackdropView.h"

@interface LGAdjustableBlurView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat blurRadius;
@property (nonatomic, assign) CGFloat qualityScale;
@property (nonatomic, assign) BOOL capturesAppIcon;
- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius;
- (void)applyFilters;
@end

@interface LGSpecularHighlightView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat strokeWidth;
@property (nonatomic, assign) CGFloat topSpecularOpacity;
@property (nonatomic, assign) CGFloat bottomSpecularOpacity;
- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)cornerRadius;
@end

@interface LGButtonView : UIControl

@property (nonatomic, strong) UIView *backgroundContainer;
@property (nonatomic, strong) LGAdjustableBlurView *blurView;
@property (nonatomic, strong) LGLiveBackdropView *lgView;
@property (nonatomic, strong) UIView *darkTintView;
@property (nonatomic, strong) UIImageView *innerGlowView;
@property (nonatomic, strong) CAGradientLayer *specularRimLayer;
@property (nonatomic, strong) CAShapeLayer *specularMaskLayer;
@property (nonatomic, strong) UIImageView *glyphImageView;
@property (nonatomic, strong) UILabel *titleLabel;

@property (nonatomic, assign) BOOL isPressed;
@property (nonatomic, assign) CGPoint touchStartPoint;
@property (nonatomic, copy) void (^actionHandler)(void);
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, strong) UIMenu *primaryMenu;
@property (nonatomic, strong) UIButton *menuAnchorButton;

- (void)setPrimaryMenu:(UIMenu *)menu;
- (void)presentMenu;

- (instancetype)initWithFrame:(CGRect)frame
                    symbolName:(NSString *)symbolName
                    blurRadius:(CGFloat)blurRadius;

- (instancetype)initWithFrame:(CGRect)frame
                        title:(NSString *)title
                    blurRadius:(CGFloat)blurRadius;

- (void)updateLayoutWithFrame:(CGRect)frame;
- (void)refreshGlass;
- (void)handleTouchDownAtPoint:(CGPoint)point;
- (void)handleTouchMovedToPoint:(CGPoint)point;
- (void)handleTouchEnded;
- (void)handleTouchCancelled;

@end

@interface LGLiquidBlockerGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
@end
