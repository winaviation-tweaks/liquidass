#pragma once
#import <UIKit/UIKit.h>

@class LGLiveBackdropView;

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName);
BOOL ancestorNameContains(UIView *v, NSString *sub);

BOOL isExactClass(UIView *v, NSString *name);

BOOL lgHostEnabled(NSString *prefix);

BOOL LGProcessMatchesExclusionList(NSString *list);

void lgObservePreferenceReload(void (^handler)(void));

extern void *kGlassKey;

void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material);

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden);

LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix);

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName);

typedef BOOL (^LGMaterialHostMatcher)(UIView *material);
typedef CGFloat (^LGMaterialHostCornerRadiusProvider)(UIView *material);
typedef void (^LGMaterialHostPostInstall)(UIView *material,
                                          LGLiveBackdropView *glass);
void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall);
