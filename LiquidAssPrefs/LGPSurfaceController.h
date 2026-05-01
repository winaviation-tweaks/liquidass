#import <UIKit/UIKit.h>

@interface LGPSurfaceController : UIViewController <UIScrollViewDelegate, UIDocumentPickerDelegate>

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray<NSDictionary *> *)items;

@end
