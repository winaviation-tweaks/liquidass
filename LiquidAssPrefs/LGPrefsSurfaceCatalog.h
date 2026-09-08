#pragma once

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString * const LGPrefsSurfaceHomescreen;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceLockscreen;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAppLibrary;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceSurfaces;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceDock;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceFolderIcons;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAppIcons;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceOpenFolder;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceContextMenu;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceBanner;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAlerts;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceControlCenter;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceSearchPill;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceSpotlight;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceWidgets;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAppLibraryPods;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAppLibrarySearch;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceNotifications;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceQuickActions;
FOUNDATION_EXPORT NSString * const LGPrefsSurfacePasscode;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceClock;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceCoverSheet;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceKeyboard;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceTabBar;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceAssistiveTouch;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceVolumeHUD;
FOUNDATION_EXPORT NSString * const LGPrefsSurfacePillHUD;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceGlobalControls;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceMoreOptions;
FOUNDATION_EXPORT NSString * const LGPrefsSurfaceSettings;

BOOL LGPrefsSurfaceIsKnown(NSString *identifier);
NSString *LGPrefsSurfaceTitle(NSString *identifier);
NSString *LGPrefsSurfaceSubtitle(NSString *identifier);
UIColor *LGPrefsSurfaceTintColor(NSString *identifier);
NSString *LGPrefsSurfaceSymbolName(NSString *identifier);
NSArray<NSDictionary *> *LGPrefsSurfaceItems(NSString *identifier);
