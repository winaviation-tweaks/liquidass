#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "Shared/LGSharedSupport.h"

typedef NS_ENUM(NSInteger, LGUpdateGroup) {
    // keeps each ticker from redrawing everything else
    LGUpdateGroupAll = 0,
    LGUpdateGroupDock,
    LGUpdateGroupFolderIcon,
    LGUpdateGroupFolderOpen,
    LGUpdateGroupContextMenu,
    LGUpdateGroupLockscreen,
    LGUpdateGroupAppLibrary,
    LGUpdateGroupAppIcons,
    LGUpdateGroupWidgets,
};

UIView  *LG_findSubviewOfClass(UIView *root, Class cls);
void     LG_updateAllGlassViewsInTree(UIView *root);
void     LG_registerGlassView(UIView *view, LGUpdateGroup group);
void     LG_unregisterGlassView(UIView *view, LGUpdateGroup group);
void     LG_updateRegisteredGlassViews(LGUpdateGroup group);
BOOL     LG_isFullScreenDevice(void);
UIWindow *LG_getHomescreenWindow(void);
BOOL     LG_hasHomescreenWallpaperAsset(void);
void     LGLog(NSString *format, ...);
UIImage *LG_getWallpaperImage(CGPoint *outOriginInScreenPts);
UIImage *LG_getHomescreenSnapshot(CGPoint *outOriginInScreenPts);
UIImage *LG_getHomescreenIconCompositeSnapshot(CGPoint *outOriginInScreenPts);
UIImage *LG_getContextMenuSnapshot(void);
UIImage *LG_getCachedContextMenuSnapshot(void);
UIImage *LG_getStrictCachedContextMenuSnapshot(void);
BOOL     LG_imageLooksBlack(UIImage *image);
void     LG_cacheContextMenuSnapshot(void);
void     LG_invalidateContextMenuSnapshot(void);
UIImage *LG_getFolderSnapshot(void);
UIImage *LG_getLockscreenSnapshot(void);
UIImage *LG_getRawLockscreenWallpaperImage(void);
CGPoint  LG_getLockscreenWallpaperOrigin(void);
void     LG_cacheFolderSnapshot(void);
void     LG_invalidateFolderSnapshot(void);
void     LG_refreshHomescreenSnapshot(void);
void     LGInvalidateLockscreenSnapshotCache(void);

@interface LiquidGlassView : UIView <MTKViewDelegate>

@property (nonatomic, strong) UIImage *wallpaperImage;
@property (nonatomic, assign) CGPoint wallpaperOrigin;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat bezelWidth;
@property (nonatomic, assign) CGFloat glassThickness;
@property (nonatomic, assign) CGFloat refractionScale;
@property (nonatomic, assign) CGFloat refractiveIndex;
@property (nonatomic, assign) CGFloat specularOpacity;
@property (nonatomic, assign) CGFloat blur;
@property (nonatomic, assign) CGFloat wallpaperScale;
@property (nonatomic, strong) UIImage *shapeMaskImage;
@property (nonatomic, assign) CGSize wallpaperSamplingResolution;
@property (nonatomic, assign) BOOL releasesWallpaperAfterUpload;
@property (nonatomic, assign) LGUpdateGroup updateGroup;

- (instancetype)initWithFrame:(CGRect)frame wallpaper:(UIImage *)wallpaper wallpaperOrigin:(CGPoint)origin;
- (void)updateWallpaperTextureWithPixelWidth:(size_t)width
                                      height:(size_t)height
                              sourcePixelSize:(CGSize)sourcePixelSize
                                     actions:(void (^)(CGContextRef context))actions;
- (void)updateOrigin;
- (void)scheduleDraw;

@end
