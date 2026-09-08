#pragma once

#import <UIKit/UIKit.h>

UIColor *LGColorFromRGBAHex(NSString *hex);
NSString *LGRGBAHexFromColor(UIColor *color);
UILabel *LGMakeAboutMarkdownLabel(NSString *text, UIFont *font, UIColor *color);
NSString *LGAboutChangelogMarkdownText(NSBundle *bundle, NSString *version);
void LGAppendAboutMarkdownLine(NSString *line, UIStackView *stack);
UIView *LGMakeDonationRow(UIViewController *controller,
                          NSString *name,
                          NSString *network,
                          NSString *symbol,
                          UIColor *color,
                          NSString *address);
UIView *LGMakeDonationCard(UIViewController *controller);
UIView *LGMakeAboutContentView(UIViewController *controller, NSBundle *bundle, NSString *packageVersion);

extern void * const kLGDefaultValueKey;
extern void * const kLGValueLabelKey;
extern void * const kLGDecimalsKey;
extern void * const kLGSliderAnimatorKey;
extern void * const kLGSliderKey;
extern void * const kLGPreferenceKeyKey;
extern void * const kLGMinValueKey;
extern void * const kLGMaxValueKey;
extern void * const kLGControlTitleKey;
extern void * const kLGControlSubtitleKey;
extern void * const kLGControlledByEnabledKey;

UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor);
UIColor *LGSubpageCardBackgroundColor(void);
UIView *LGMakeSectionDivider(void);
void LGApplyNavigationBarAppearance(UINavigationItem *navigationItem);
void LGInstallScrollableStack(UIViewController *controller,
                              CGFloat topInset,
                              CGFloat stackSpacing,
                              UIScrollView *__strong *scrollViewOut,
                              UIStackView *__strong *stackViewOut);
void LGInstallBottomRespringBar(UIViewController *controller, UIView *__strong *respringBarOut);
void LGRefreshRespringBarGlass(UIView *respringBar);
void LGScheduleRespringBarGlassRefresh(UIView *respringBar);
void LGPresentSliderValuePrompt(UIViewController *controller,
                                UILabel *valueLabel,
                                void (^commitBlock)(CGFloat value));
void LGAnimateSliderToDefault(UISlider *slider, CGFloat targetValue, UILabel *valueLabel, NSInteger decimals);
UIBarButtonItem *LGMakeCircularBackItem(id target, SEL action);
void LGRefreshCircularBackItem(UIBarButtonItem *item);
UIBarButtonItem *LGMakeCircularMenuItem(id target, SEL applyAction, SEL resetAction, NSString *resetTitle);
void LGPresentResetConfirmation(UIViewController *controller);
void LGPresentResetConfirmationWithBody(UIViewController *controller, NSString *body, SEL resetSelector);
void LGPresentRespringConfirmation(UIViewController *controller);
void LGPresentReopenSettingsConfirmation(UIViewController *controller);
void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message);
void LGPresentConfirmationSheet(UIViewController *controller,
                                NSString *title,
                                NSString *message,
                                NSString *cancelTitle,
                                NSString *confirmTitle,
                                BOOL destructive,
                                void (^confirmBlock)(void));
void LGPresentTextInputSheet(UIViewController *controller,
                             NSString *title,
                             NSString *message,
                             NSString *initialText,
                             NSString *placeholder,
                             UIKeyboardType keyboardType,
                             BOOL monospaced,
                             void (^applyBlock)(NSString *text));
void LGPresentMultilineTextInputSheet(UIViewController *controller,
                                      NSString *title,
                                      NSString *message,
                                      NSString *initialText,
                                      NSString *placeholder,
                                      void (^applyBlock)(NSString *text));
void LGPresentPreferencesExport(UIViewController *controller);
void LGPresentDiagnosticsExport(UIViewController *controller);
BOOL LGImportPreferencesFromURL(UIViewController *controller, NSURL *url);
void LGPresentThirdPartyRWBEditor(UIViewController *controller);
void LGPresentGlobalControlsExclusionEditor(UIViewController *controller);
void LGPresentTabBarExclusionEditor(UIViewController *controller);
