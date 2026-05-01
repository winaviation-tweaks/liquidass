#import <UIKit/UIKit.h>

@interface LGPrefsLiquidSwitch : UISwitch
- (void)lg_beginExternalPress;
- (void)lg_endExternalPressForToggle;
- (void)lg_cancelExternalPress;
@end
