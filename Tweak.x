#import "LiquidGlass.h"
#import "Shared/LGHookSupport.h"
#import <Accelerate/Accelerate.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>
#import "Runtime/LGLiquidGlassRuntime.h"
#import "Runtime/LGSnapshotCaptureSupport.h"

static BOOL LG_isAtLeastiOS16(void);
static CFStringRef const LGInvalidateSnapshotCachesNotification = CFSTR("love.litten.liquidass/InvalidateSnapshotCaches");
void LGRefreshLockSnapshotAfterDelay(NSTimeInterval delay);

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone = 0,
    SBSRelaunchActionOptionsRestartRenderServer = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface UIView (LGHierarchyCapture)
- (BOOL)drawHierarchyInRect:(CGRect)rect afterScreenUpdates:(BOOL)afterUpdates;
@end

@interface PBUISnapshotReplicaView : UIView
@end

static const NSInteger kLGMaxViewTraversalDepth = 96;

static UIView *LG_findSubviewOfClassImpl(UIView *root, Class cls, NSInteger depth) {
    if (!root || !cls || depth > kLGMaxViewTraversalDepth) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = LG_findSubviewOfClassImpl(sub, cls, depth + 1);
        if (found) return found;
    }
    return nil;
}


UIView *LG_findSubviewOfClass(UIView *root, Class cls) {
    return LG_findSubviewOfClassImpl(root, cls, 0);
}

static void LG_updateAllGlassViewsInTreeImpl(UIView *root, int depth) {
    if (!root || depth > kLGMaxViewTraversalDepth) return;
    if (root.hidden || root.alpha <= 0.01f || root.layer.opacity <= 0.01f) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        [(LiquidGlassView *)root updateOrigin];
        return;
    }
    NSArray *subviews = root.subviews;
    for (UIView *sub in subviews)
        LG_updateAllGlassViewsInTreeImpl(sub, depth + 1);
}

void LG_updateAllGlassViewsInTree(UIView *root) {
    LG_updateAllGlassViewsInTreeImpl(root, 0);
}

static NSHashTable *sRegisteredGlassViews[LGUpdateGroupWidgets + 1] = { nil };

void LG_registerGlassView(UIView *view, LGUpdateGroup group) {
    LGAssertMainThread();
    if (!view) return;
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    if (!sRegisteredGlassViews[group])
        sRegisteredGlassViews[group] = [NSHashTable weakObjectsHashTable];
    [sRegisteredGlassViews[group] addObject:view];
}

void LG_unregisterGlassView(UIView *view, LGUpdateGroup group) {
    LGAssertMainThread();
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    [sRegisteredGlassViews[group] removeObject:view];
}

static void LG_updateGlassHashTable(NSHashTable *table) {
    if (!table.count) return;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    for (LiquidGlassView *glass in table) {
        if (!glass.superview) continue;
        if (!glass.window) continue;
        if (glass.hidden || glass.alpha <= 0.01f || glass.layer.opacity <= 0.01f) continue;
        if (CGRectIsEmpty(glass.bounds)) continue;
        if (glass.updateGroup != LGUpdateGroupLockscreen) {
            CGRect approxRect = [glass convertRect:glass.bounds toView:nil];
            if (!CGRectIntersectsRect(CGRectInset(screenBounds, -64.0, -64.0), approxRect)) continue;
        }
        [glass updateOrigin];
    }
}

void LG_updateRegisteredGlassViews(LGUpdateGroup group) {
    LGAssertMainThread();
    if (group == LGUpdateGroupAll) {
        for (NSInteger i = LGUpdateGroupDock; i <= LGUpdateGroupWidgets; i++)
            LG_updateGlassHashTable(sRegisteredGlassViews[i]);
        return;
    }
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    LG_updateGlassHashTable(sRegisteredGlassViews[group]);
}

UIWindow *LG_getHomescreenWindow(void) {
    static __weak UIWindow *sCachedWindow = nil;
    static Class sceneCls, homeCls;
    UIWindow *cached = sCachedWindow;
    if (cached.windowScene) return cached;

    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!homeCls) homeCls = NSClassFromString(@"SBHomeScreenWindow");

    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:sceneCls]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) {
            if ([win isKindOfClass:homeCls]) {
                sCachedWindow = win;
                return win;
            }
        }
    }
    return nil;
}

BOOL LG_isFullScreenDevice(void) {
    static BOOL sCached = NO;
    static BOOL sResult = NO;
    if (!sCached) {
        for (UIWindow *window in LGApplicationWindows(UIApplication.sharedApplication)) {
            if (window.safeAreaInsets.top > 20.0) {
                sResult = YES;
                break;
            }
        }
        if (!sResult) {
            CGFloat h = UIScreen.mainScreen.bounds.size.height;
            CGFloat w = UIScreen.mainScreen.bounds.size.width;
            CGFloat longerSide = MAX(h, w);
            sResult = (longerSide >= 812.0);
        }
        sCached = YES;
    }
    return sResult;
}

static UIWindow *LG_getWallpaperWindow(BOOL secureOnly) {
    static Class wCls, wsCls2, sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!wCls)    wCls    = NSClassFromString(@"_SBWallpaperWindow");
    if (!wsCls2)  wsCls2  = NSClassFromString(@"_SBWallpaperSecureWindow");
    UIWindow *secureFallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (secureOnly) {
                if ([w isKindOfClass:wsCls2]) return w;
            } else {
                if ([w isKindOfClass:wCls]) return w;
                if (!secureFallback && [w isKindOfClass:wsCls2]) secureFallback = w;
            }
        }
    }
    return secureOnly ? nil : secureFallback;
}

static BOOL LG_viewMatchesHierarchyClass(UIView *view, Class cls) {
    if (!view || !cls) return NO;
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    UIResponder *r = view.nextResponder;
    while (r) {
        if ([r isKindOfClass:cls]) return YES;
        r = r.nextResponder;
    }
    return NO;
}

static UIImageView *LG_findImageViewInTree(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIImageView class]] && ((UIImageView *)root).image)
        return (UIImageView *)root;
    for (UIView *sub in root.subviews) {
        UIImageView *found = LG_findImageViewInTree(sub);
        if (found) return found;
    }
    return nil;
}

static void LG_collectViewsOfClass(UIView *root, Class cls, NSMutableArray<UIView *> *results, NSInteger depth) {
    if (!root || !cls || !results || depth > kLGMaxViewTraversalDepth) return;
    if ([root isKindOfClass:cls]) [results addObject:root];
    for (UIView *sub in root.subviews)
        LG_collectViewsOfClass(sub, cls, results, depth + 1);
}

static UIImageView *LG_getWallpaperImageView(UIWindow *win, BOOL lockscreen) {
    static Class replicaCls, staticWpCls, homePosterVCCls, lockPosterVCCls;
    if (!replicaCls)  replicaCls  = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!staticWpCls) staticWpCls = NSClassFromString(@"SBFStaticWallpaperImageView");
    if (!homePosterVCCls) homePosterVCCls = NSClassFromString(@"PBUIPosterHomeViewController");
    if (!lockPosterVCCls) lockPosterVCCls = NSClassFromString(@"PBUIPosterLockViewController");

    Class targetPosterVCCls = lockscreen ? lockPosterVCCls : homePosterVCCls;
    NSMutableArray<UIView *> *replicas = [NSMutableArray array];
    LG_collectViewsOfClass(win, replicaCls, replicas, 0);
    for (UIView *replica in replicas) {
        if (targetPosterVCCls && !LG_viewMatchesHierarchyClass(replica, targetPosterVCCls))
            continue;
        UIImageView *iv = LG_findImageViewInTree(replica);
        if (iv.image) {
            CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
            LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@ match=%@",
                       lockscreen ? @"lockscreen" : @"homescreen",
                       NSStringFromClass(iv.class),
                       NSStringFromCGRect(screenRect),
                       NSStringFromClass(targetPosterVCCls));
            return iv;
        }
    }

    if (!LG_isAtLeastiOS16()) {
        UIView *replica = LG_findSubviewOfClass(win, replicaCls);
        if (replica) {
            UIImageView *iv = LG_findImageViewInTree(replica);
            if (iv.image) {
                CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
                LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@",
                           lockscreen ? @"lockscreen" : @"homescreen",
                           NSStringFromClass(iv.class),
                           NSStringFromCGRect(screenRect));
                return iv;
            }
        }
    }
    UIImageView *iv = (UIImageView *)LG_findSubviewOfClass(win, staticWpCls);
    if (iv.image) {
        CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
        LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@",
                   lockscreen ? @"lockscreen" : @"homescreen",
                   NSStringFromClass(iv.class),
                   NSStringFromCGRect(screenRect));
        return iv;
    }
    return nil;
}

static CGPoint LG_centeredWallpaperOriginForImage(UIImage *image) {
    if (!image) return CGPointZero;
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    return CGPointMake((screenSize.width - image.size.width) * 0.5,
                       (screenSize.height - image.size.height) * 0.5);
}

static CGRect LG_imageViewDisplayedImageRect(UIImageView *imageView) {
    if (!imageView || !imageView.image) return CGRectZero;
    CGRect bounds = imageView.bounds;
    CGSize imageSize = imageView.image.size;
    if (CGRectIsEmpty(bounds) || imageSize.width <= 0.0 || imageSize.height <= 0.0) return CGRectZero;

    UIViewContentMode mode = imageView.contentMode;
    if (mode == UIViewContentModeScaleToFill) return bounds;

    CGFloat scaleX = bounds.size.width / imageSize.width;
    CGFloat scaleY = bounds.size.height / imageSize.height;
    CGFloat scale = 1.0;

    switch (mode) {
        case UIViewContentModeScaleAspectFit:
            scale = MIN(scaleX, scaleY);
            break;
        case UIViewContentModeScaleAspectFill:
        default:
            scale = MAX(scaleX, scaleY);
            break;
    }

    CGSize fitted = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    CGFloat originX = (bounds.size.width - fitted.width) * 0.5;
    CGFloat originY = (bounds.size.height - fitted.height) * 0.5;
    return CGRectMake(originX, originY, fitted.width, fitted.height);
}

static CGPoint LG_getHomescreenWallpaperOriginForImage(UIImage *image) {
    return LG_centeredWallpaperOriginForImage(image);
}

static __weak UIImage *sCachedSnapshot = nil;
static __weak UIImage *sCachedContextMenuSnapshot = nil;
static BOOL sContextMenuSnapshotCaptureInFlight = NO;
static __weak UIImage *sCachedFolderSnapshot = nil;
static __weak UIImage *sCachedSpringBoardHomeImage = nil;
static __weak UIImage *sCachedSpringBoardLockImage = nil;
static NSDate *sCachedSpringBoardHomeMTime = nil;
static NSDate *sCachedSpringBoardLockMTime = nil;
static NSString *sCachedSpringBoardHomePath = nil;
static NSString *sCachedSpringBoardLockPath = nil;
static NSDate *sObservedLegacyHomeAssetMTime = nil;
static NSDate *sObservedLegacyLockAssetMTime = nil;
static NSString *sObservedLegacyHomeAssetPath = nil;
static NSString *sObservedLegacyLockAssetPath = nil;
static UIImage *sInterceptedWallpaperImage = nil;
static NSCache<NSString *, UIImage *> *sTransientImageCache = nil;

static NSString * const kLGSnapshotImageCacheKey = @"homescreen.snapshot";
static NSString * const kLGContextMenuSnapshotImageCacheKey = @"context.snapshot";
static NSString * const kLGFolderSnapshotImageCacheKey = @"folder.snapshot";
static NSString * const kLGHomeWallpaperImageCacheKey = @"wallpaper.home";
static NSString * const kLGLockWallpaperImageCacheKey = @"wallpaper.lock";

static NSCache<NSString *, UIImage *> *LGTransientImageCache(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sTransientImageCache = [NSCache new];
        sTransientImageCache.countLimit = 8;
        sTransientImageCache.totalCostLimit = 220 * 1024 * 1024;
    });
    return sTransientImageCache;
}

static NSUInteger LGImageMemoryCost(UIImage *image) {
    if (!image) return 0;
    CGImageRef cgImage = image.CGImage;
    if (cgImage) {
        return CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage);
    }
    CGFloat width = image.size.width * MAX(image.scale, 1.0);
    CGFloat height = image.size.height * MAX(image.scale, 1.0);
    return (NSUInteger)lrint(width * height * 4.0);
}

static void LGSetCachedTransientImage(NSString *key, UIImage *image) {
    if (!key.length) return;
    NSCache<NSString *, UIImage *> *cache = LGTransientImageCache();
    if (image) {
        [cache setObject:image forKey:key cost:LGImageMemoryCost(image)];
    } else {
        [cache removeObjectForKey:key];
    }
}

static void LGSetCachedSnapshotImage(UIImage *image) {
    sCachedSnapshot = image;
    LGSetCachedTransientImage(kLGSnapshotImageCacheKey, image);
}

static void LGSetCachedContextMenuSnapshotImage(UIImage *image) {
    sCachedContextMenuSnapshot = image;
    LGSetCachedTransientImage(kLGContextMenuSnapshotImageCacheKey, image);
}

static void LGSetCachedFolderSnapshotImage(UIImage *image) {
    sCachedFolderSnapshot = image;
    LGSetCachedTransientImage(kLGFolderSnapshotImageCacheKey, image);
}

static void LGSetCachedSpringBoardHomeImageValue(UIImage *image) {
    sCachedSpringBoardHomeImage = image;
    LGSetCachedTransientImage(kLGHomeWallpaperImageCacheKey, image);
}

static void LGSetCachedSpringBoardLockImageValue(UIImage *image) {
    sCachedSpringBoardLockImage = image;
    LGSetCachedTransientImage(kLGLockWallpaperImageCacheKey, image);
}

static void LGResetHomescreenSnapshotCaches(void);
static void LGResetLockscreenSnapshotCaches(void);
static void LG_pushSnapshotToAllGlassViews(void);
static void LG_pushLockscreenSnapshotToAllGlassViews(void);
static dispatch_source_t sLegacyWallpaperWatcher = nil;
static int sLegacyWallpaperWatcherFD = -1;
static BOOL sLegacyWallpaperRescanScheduled = NO;
static BOOL sLegacyWallpaperWatcherRestartPending = NO;
static NSUInteger sPendingHomescreenWallpaperRefreshToken = 0;
static NSUInteger sPendingLockscreenWallpaperRefreshToken = 0;
static NSUInteger sPendingPrefsChangeToken = 0;
static BOOL sSnapshotRetryScheduled = NO;
static NSUInteger sSnapshotRetryCount = 0;
static NSUInteger sSnapshotRetryToken = 0;
static const NSUInteger kLGMaxSnapshotRetryCount = 30;
static void LG_trySnapshotWithRetry(void);
static void LG_scheduleHomescreenWallpaperRefresh(NSString *reason, UIImage *image);
static void LG_scheduleLockscreenWallpaperRefresh(NSString *reason);
static void LG_schedulePrefsChanged(void);
static void LG_handlePrefsChanged(void);
static void LG_handleMemoryWarning(void);
static void LG_requestRespring(void);
static UIImage *LG_decodeSpringBoardWallpaperPath(NSString *path);
static void LG_startLegacyWallpaperWatcher(void);
static void LG_stopLegacyWallpaperWatcher(void);
static void LGScheduleBlockAfterDelay(NSTimeInterval delay, dispatch_block_t block);

static BOOL LG_isAtLeastiOS16(void) {
    static BOOL sCachedResult = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCachedResult = [[NSProcessInfo processInfo]
            isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return sCachedResult;
}

static NSString *LG_springBoardWallpaperDirectory(void) {
    static NSString *sResolved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        [candidates addObject:@"/var/mobile/Library/SpringBoard"];

        NSString *home = NSHomeDirectory();
        if (home.length) {
            [candidates addObject:[home stringByAppendingPathComponent:@"Library/SpringBoard"]];

            NSRange containersRange = [home rangeOfString:@"/data/Containers/"];
            if (containersRange.location != NSNotFound) {
                NSString *deviceDataRoot = [home substringToIndex:containersRange.location + @"/data".length];
                [candidates addObject:[deviceDataRoot stringByAppendingPathComponent:@"Library/SpringBoard"]];
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
                sResolved = [path copy];
                break;
            }
        }
    });
    return sResolved;
}

static NSArray<NSString *> *LG_springBoardWallpaperCandidatePaths(BOOL lockscreen) {
    NSString *root = LG_springBoardWallpaperDirectory();
    if (LG_isAtLeastiOS16()) {
        return @[];
    }
    if (lockscreen) {
        return @[
            [root stringByAppendingPathComponent:@"LockBackground.cpbitmap"],
        ];
    }
    return @[
        [root stringByAppendingPathComponent:@"HomeBackground.cpbitmap"],
    ];
}

static NSString *LG_preferredSpringBoardWallpaperPath(BOOL lockscreen) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in LG_springBoardWallpaperCandidatePaths(lockscreen)) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static BOOL LG_equalMaybeNilObjects(id a, id b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    return [a isEqual:b];
}

static BOOL LG_noteLegacyWallpaperAssetChange(BOOL lockscreen) {
    if (LG_isAtLeastiOS16()) return NO;

    NSString *path = LG_preferredSpringBoardWallpaperPath(lockscreen);
    NSDate *mtime = nil;
    if (path.length) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        mtime = attrs[NSFileModificationDate];
    }

    NSDate * __strong *observedMTime = lockscreen ? &sObservedLegacyLockAssetMTime : &sObservedLegacyHomeAssetMTime;
    NSString * __strong *observedPath = lockscreen ? &sObservedLegacyLockAssetPath : &sObservedLegacyHomeAssetPath;

    BOOL hadBaseline = (*observedPath != nil) || (*observedMTime != nil);
    BOOL changed = hadBaseline &&
        (!LG_equalMaybeNilObjects(*observedPath, path) || !LG_equalMaybeNilObjects(*observedMTime, mtime));

    *observedPath = [path copy];
    *observedMTime = mtime;
    return changed;
}

static void LG_checkLegacyWallpaperAssetChanges(void) {
    if (!LG_globalEnabled()) return;
    if (LG_isAtLeastiOS16()) return;

    BOOL homeChanged = LG_noteLegacyWallpaperAssetChange(NO);
    BOOL lockChanged = LG_noteLegacyWallpaperAssetChange(YES);

    if (homeChanged)
        LG_scheduleHomescreenWallpaperRefresh(@"legacy-home-asset", nil);
    if (lockChanged)
        LG_scheduleLockscreenWallpaperRefresh(@"legacy-lock-asset");
}

static void LGScheduleLegacyWallpaperWatcherRestart(void) {
    if (sLegacyWallpaperWatcherRestartPending) return;
    sLegacyWallpaperWatcherRestartPending = YES;
    LGScheduleBlockAfterDelay(0.20, ^{
        if (sLegacyWallpaperWatcher || sLegacyWallpaperWatcherFD >= 0) {
            sLegacyWallpaperWatcherRestartPending = NO;
            LGScheduleLegacyWallpaperWatcherRestart();
            return;
        }
        sLegacyWallpaperWatcherRestartPending = NO;
        LG_startLegacyWallpaperWatcher();
    });
}

static void LG_stopLegacyWallpaperWatcher(void) {
    if (!sLegacyWallpaperWatcher) return;
    dispatch_source_cancel(sLegacyWallpaperWatcher);
    sLegacyWallpaperWatcher = nil;
}

static void LG_startLegacyWallpaperWatcher(void) {
    if (LG_isAtLeastiOS16()) return;
    if (sLegacyWallpaperWatcher || sLegacyWallpaperWatcherFD >= 0) return;
    NSString *dir = LG_springBoardWallpaperDirectory();
    if (!dir.length) return;

    sLegacyWallpaperWatcherFD = open(dir.fileSystemRepresentation, O_EVTONLY);
    if (sLegacyWallpaperWatcherFD < 0) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    unsigned long mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_EXTEND |
                         DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK | DISPATCH_VNODE_RENAME |
                         DISPATCH_VNODE_REVOKE;
    sLegacyWallpaperWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                     (uintptr_t)sLegacyWallpaperWatcherFD,
                                                     mask,
                                                     queue);
    if (!sLegacyWallpaperWatcher) {
        close(sLegacyWallpaperWatcherFD);
        sLegacyWallpaperWatcherFD = -1;
        return;
    }

    dispatch_source_set_event_handler(sLegacyWallpaperWatcher, ^{
        unsigned long flags = dispatch_source_get_data(sLegacyWallpaperWatcher);
        if (flags & DISPATCH_VNODE_REVOKE) {
            LGLog(@"legacy wallpaper watcher revoked; restarting");
            LG_stopLegacyWallpaperWatcher();
            LGScheduleLegacyWallpaperWatcherRestart();
            return;
        }
        if (sLegacyWallpaperRescanScheduled) return;
        sLegacyWallpaperRescanScheduled = YES;
        LGScheduleBlockAfterDelay(0.20, ^{
            sLegacyWallpaperRescanScheduled = NO;
            LG_checkLegacyWallpaperAssetChanges();
        });
    });
    dispatch_source_set_cancel_handler(sLegacyWallpaperWatcher, ^{
        if (sLegacyWallpaperWatcherFD >= 0) {
            close(sLegacyWallpaperWatcherFD);
            sLegacyWallpaperWatcherFD = -1;
        }
    });
    dispatch_resume(sLegacyWallpaperWatcher);

    // establish the baseline once the watcher is armed
    LG_checkLegacyWallpaperAssetChanges();
}

BOOL LG_hasHomescreenWallpaperAsset(void) {
    return LG_preferredSpringBoardWallpaperPath(NO) != nil;
}

static UIImage *LG_decodeCPBitmapAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:[NSData class]] || data.length < 24) return nil;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;

    static const size_t kCandidateTrailerBytes[] = { 20, 24, 28, 32 };
    static const size_t kAlignments[] = { 16, 8, 4 };
    size_t width = 0;
    size_t height = 0;
    size_t payloadBytes = 0;
    size_t chosenAlignment = 0;
    size_t chosenTrailerBytes = 0;

    for (size_t trailerIndex = 0; trailerIndex < sizeof(kCandidateTrailerBytes) / sizeof(kCandidateTrailerBytes[0]); trailerIndex++) {
        size_t trailerBytes = kCandidateTrailerBytes[trailerIndex];
        if (length <= trailerBytes) continue;

        uint32_t widthLE = 0;
        uint32_t heightLE = 0;
        memcpy(&widthLE, bytes + length - trailerBytes, sizeof(uint32_t));
        memcpy(&heightLE, bytes + length - trailerBytes + sizeof(uint32_t), sizeof(uint32_t));

        size_t candidateWidth = CFSwapInt32LittleToHost(widthLE);
        size_t candidateHeight = CFSwapInt32LittleToHost(heightLE);
        if (candidateWidth == 0 || candidateHeight == 0 || candidateWidth > 10000 || candidateHeight > 10000) {
            continue;
        }

        for (size_t i = 0; i < sizeof(kAlignments) / sizeof(kAlignments[0]); i++) {
            size_t align = kAlignments[i];
            size_t lineSize = ((candidateWidth + align - 1) / align) * align;
            size_t bytesNeeded = lineSize * candidateHeight * 4;
            if (bytesNeeded <= length - trailerBytes) {
                width = candidateWidth;
                height = candidateHeight;
                payloadBytes = bytesNeeded;
                chosenAlignment = align;
                chosenTrailerBytes = trailerBytes;
                break;
            }
        }
        if (payloadBytes > 0) break;
    }
    if (payloadBytes == 0 || chosenAlignment == 0) return nil;

    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    size_t lineSize = ((width + chosenAlignment - 1) / chosenAlignment) * chosenAlignment;
    if ((lineSize * height * 4) > payloadBytes) return nil;

    vImage_Buffer src = {
        .data = (void *)bytes,
        .height = height,
        .width = width,
        .rowBytes = lineSize * 4,
    };
    vImage_Buffer dst = {
        .data = rgba.mutableBytes,
        .height = height,
        .width = width,
        .rowBytes = width * 4,
    };
    const uint8_t permuteMap[4] = { 2, 1, 0, 3 };
    vImage_Error permuteError = vImagePermuteChannels_ARGB8888(&src, &dst, permuteMap, kvImageNoFlags);
    if (permuteError != kvImageNoError) {
        LGDebugLog(@"cpbitmap permute failed path=%@ error=%ld", path.lastPathComponent, (long)permuteError);
        return nil;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    if (!provider) return nil;
    CGColorSpaceRef colorSpace = LGSharedRGBColorSpace();
    CGImageRef cgImage = CGImageCreate(width,
                                       height,
                                       8,
                                       32,
                                       width * 4,
                                       colorSpace,
                                       kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return nil;

    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:screenScale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    if (LG_imageLooksBlack(image)) {
        LGDebugLog(@"cpbitmap decode rejected as black path=%@ trailer=%zu alignment=%zu", path.lastPathComponent, chosenTrailerBytes, chosenAlignment);
        return nil;
    }
    return image;
}

static UIImage *LG_decodeSpringBoardWallpaperPath(NSString *path) {
    if (!path.length) return nil;
    if ([[path pathExtension].lowercaseString isEqualToString:@"jpg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"jpeg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"png"]) {
        return [UIImage imageWithContentsOfFile:path];
    }
    if ([[path pathExtension].lowercaseString isEqualToString:@"cpbitmap"]) {
        return LG_decodeCPBitmapAtPath(path);
    }
    return nil;
}

static BOOL LG_isCPBitmapPath(NSString *path) {
    return [[[path pathExtension] lowercaseString] isEqualToString:@"cpbitmap"];
}

static UIImage *LG_loadSpringBoardWallpaperImage(BOOL lockscreen) {
    LGAssertMainThread();
    NSString *path = LG_preferredSpringBoardWallpaperPath(lockscreen);
    if (!path) return nil;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];

    if (lockscreen) {
        if (sCachedSpringBoardLockImage &&
            [sCachedSpringBoardLockPath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardLockMTime) || [sCachedSpringBoardLockMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardLockImage;
        }
    } else {
        if (sCachedSpringBoardHomeImage &&
            [sCachedSpringBoardHomePath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardHomeMTime) || [sCachedSpringBoardHomeMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardHomeImage;
        }
    }

    UIImage *image = LG_decodeSpringBoardWallpaperPath(path);
    if (image) {
        NSTimeInterval timestamp = mtime ? mtime.timeIntervalSince1970 : 0.0;
        NSString *cacheKey = [NSString stringWithFormat:@"wallpaper:%@:%0.3f",
                              lockscreen ? @"lock" : @"home",
                              timestamp];
        LGSetImageStableCacheKey(image, [cacheKey stringByAppendingFormat:@":%@", path.lastPathComponent ?: @"(null)"]);
    }

    if (lockscreen) {
        LGSetCachedSpringBoardLockImageValue(image);
        sCachedSpringBoardLockMTime = mtime;
        sCachedSpringBoardLockPath = [path copy];
    } else {
        LGSetCachedSpringBoardHomeImageValue(image);
        sCachedSpringBoardHomeMTime = mtime;
        sCachedSpringBoardHomePath = [path copy];
    }

    if (image) {
        LGLog(@"loaded %@ wallpaper from %@", lockscreen ? @"lockscreen" : @"homescreen", path.lastPathComponent);
    }

    return image;
}

UIImage *LG_getWallpaperImage(CGPoint *outOriginInScreenPts) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        if (outOriginInScreenPts) {
            *outOriginInScreenPts = LG_isCPBitmapPath(assetPath)
                ? LG_centeredWallpaperOriginForImage(asset)
                : LG_getHomescreenWallpaperOriginForImage(asset);
        }
        return asset;
    }
    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return nil;
    UIImageView *iv = LG_getWallpaperImageView(win, NO);
    if (!iv.image) return nil;
    if (outOriginInScreenPts)
        *outOriginInScreenPts = [iv convertPoint:CGPointZero toView:nil];
    return iv.image;
}

static void *kLGSnapshotOriginalOpacityKey = &kLGSnapshotOriginalOpacityKey;

BOOL LG_imageLooksBlack(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    static const size_t kSampleGrid = 5;
    unsigned char px[kSampleGrid * kSampleGrid * 4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(px, kSampleGrid, kSampleGrid, 8, kSampleGrid * 4, LGSharedRGBColorSpace(),
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, kSampleGrid, kSampleGrid), cg);
    CGContextRelease(ctx);
    NSUInteger sampleCount = kSampleGrid * kSampleGrid;
    uint8_t brightestChannel = 0;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        uint8_t r = px[i * 4];
        uint8_t g = px[i * 4 + 1];
        uint8_t b = px[i * 4 + 2];
        brightestChannel = MAX(brightestChannel, MAX(r, MAX(g, b)));
        if (brightestChannel > 1) return NO;
    }
    return YES;
}

static BOOL LG_contextSnapshotLooksIncomplete(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    if (img.scale <= 0.0) return YES;
    if (img.size.width <= 0.0 || img.size.height <= 0.0) return YES;
    if (CGImageGetWidth(cg) == 0 || CGImageGetHeight(cg) == 0) return YES;
    return NO;
}

static void LG_drawWallpaperImageInContext(UIImage *image, CGPoint origin) {
    if (!image) return;
    [image drawInRect:CGRectMake(origin.x, origin.y, image.size.width, image.size.height)];
}

static BOOL LG_drawHomescreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        CGPoint origin = LG_isCPBitmapPath(assetPath)
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
        LG_drawWallpaperImageInContext(asset, origin);
        return YES;
    }

    if (sInterceptedWallpaperImage) {
        [sInterceptedWallpaperImage drawInRect:bounds];
        return YES;
    }

    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win, NO);
    if (iv.image) {
        return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
    }

    static Class secureCls;
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    if (![win isKindOfClass:secureCls]) {
        [win.layer renderInContext:UIGraphicsGetCurrentContext()];
        return YES;
    }

    return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
}

static BOOL LG_drawLockscreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    UIWindow *win = LG_getWallpaperWindow(YES);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win, YES);
    if (LG_isAtLeastiOS16()) {
        if (iv.image) {
            CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
            CGRect screenRect = [iv convertRect:displayedRect toView:nil];
            [iv.image drawInRect:screenRect];
            return YES;
        }
        BOOL drew = LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
        return drew;
    }
    return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
}

void LG_refreshHomescreenSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        LGSetCachedSnapshotImage(nil);
        return;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        UIWindow *win = LG_getWallpaperWindow(NO);
        UIImageView *iv = win ? LG_getWallpaperImageView(win, NO) : nil;
        LGDebugLog(@"refresh homescreen snapshot source=asset file=%@ imageView=%d screen=%@ image=%@ scale=%.2f orientation=%ld",
                   LG_preferredSpringBoardWallpaperPath(NO).lastPathComponent ?: @"(unknown)",
                   iv ? 1 : 0,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
                   NSStringFromCGSize(asset.size),
                   asset.scale,
                   (long)asset.imageOrientation);
        LGSetCachedSnapshotImage(asset);
        return;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LGDebugLog(@"refresh homescreen snapshot source=live-window");
    BOOL ok = LG_drawHomescreenWallpaperInContext(screenSize);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!ok || LG_imageLooksBlack(img)) return;
    LGDebugLog(@"refresh homescreen snapshot live result image=%@ scale=%.2f orientation=%ld",
               NSStringFromCGSize(img.size),
               img.scale,
               (long)img.imageOrientation);
    LGSetCachedSnapshotImage(img);
}

static void hideGlassViews(UIView *root, NSMutableArray *list) {
    if ([root isKindOfClass:[LiquidGlassView class]]) {
        objc_setAssociatedObject(root, kLGSnapshotOriginalOpacityKey,
                                 @(root.layer.opacity),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        root.layer.opacity = 0.0f;
        [CATransaction commit];
        [list addObject:root];
        return;
    }
    for (UIView *sub in root.subviews) hideGlassViews(sub, list);
}

static BOOL LGWindowContainsContextMenuViews(UIWindow *window) {
    if (!window) return NO;
    static Class containerCls, listCls;
    if (!containerCls) containerCls = NSClassFromString(@"_UIContextMenuContainerView");
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    if ((containerCls && LG_findSubviewOfClass(window, containerCls)) ||
        (listCls && LG_findSubviewOfClass(window, listCls))) {
        return YES;
    }
    return NO;
}

static BOOL LGWindowHasContextMenuController(UIWindow *window) {
    if (!window) return NO;
    static Class actionsOnlyVCCls, menuVCCls;
    if (!actionsOnlyVCCls) actionsOnlyVCCls = NSClassFromString(@"_UIContextMenuActionsOnlyViewController");
    if (!menuVCCls) menuVCCls = NSClassFromString(@"_UIContextMenuViewController");

    UIViewController *root = window.rootViewController;
    if (!root) return NO;
    if ((actionsOnlyVCCls && [root isKindOfClass:actionsOnlyVCCls]) ||
        (menuVCCls && [root isKindOfClass:menuVCCls])) {
        return YES;
    }

    UIViewController *presented = root.presentedViewController;
    while (presented) {
        if ((actionsOnlyVCCls && [presented isKindOfClass:actionsOnlyVCCls]) ||
            (menuVCCls && [presented isKindOfClass:menuVCCls])) {
            return YES;
        }
        presented = presented.presentedViewController;
    }
    return NO;
}

static BOOL LG_isContextMenuWindow(UIWindow *window) {
    if (!window) return NO;

    static Class actionsWindowCls;
    if (!actionsWindowCls) actionsWindowCls = NSClassFromString(@"_UIContextMenuActionsWindow");
    if (actionsWindowCls && [window isKindOfClass:actionsWindowCls]) return YES;

    if (LGWindowHasContextMenuController(window)) return YES;
    if (LGWindowContainsContextMenuViews(window)) return YES;
    return NO;
}

static BOOL LG_isWallpaperWindow(UIWindow *window) {
    static Class wallpaperCls, secureCls;
    if (!wallpaperCls) wallpaperCls = NSClassFromString(@"_SBWallpaperWindow");
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    return [window isKindOfClass:wallpaperCls] || [window isKindOfClass:secureCls];
}

static void LG_collectSnapshotWindows(NSMutableArray<UIWindow *> *hiddenWindows,
                                      NSMutableArray<UIWindow *> *renderWindows) {
    [hiddenWindows removeAllObjects];
    [renderWindows removeAllObjects];

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01f || window.layer.opacity <= 0.01f) continue;
            if (LG_isContextMenuWindow(window)) {
                window.hidden = YES;
                [hiddenWindows addObject:window];
                continue;
            }
            if (!LG_isWallpaperWindow(window))
                [renderWindows addObject:window];
        }
    }

    [renderWindows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void LG_hideGlassViewsInWindows(NSArray<UIWindow *> *windows, NSMutableArray<UIView *> *hiddenViews) {
    [hiddenViews removeAllObjects];
    for (UIWindow *window in windows)
        hideGlassViews(window, hiddenViews);
}

static void LG_restoreSnapshotVisibility(NSArray<UIView *> *hiddenViews, NSArray<UIWindow *> *hiddenWindows) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *view in hiddenViews) {
        NSNumber *originalOpacity = objc_getAssociatedObject(view, kLGSnapshotOriginalOpacityKey);
        view.layer.opacity = originalOpacity ? (float)[originalOpacity doubleValue] : 1.0f;
        objc_setAssociatedObject(view, kLGSnapshotOriginalOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [CATransaction commit];
    for (UIWindow *window in hiddenWindows) window.hidden = NO;
}

static UIViewController *LG_topPresentedViewController(UIViewController *controller) {
    UIViewController *top = controller;
    while (top.presentedViewController)
        top = top.presentedViewController;
    return top;
}

static BOOL sTodayViewVisible = NO;

static void LGResetHomescreenSnapshotCaches(void) {
    LGSetCachedSnapshotImage(nil);
    LGSetCachedContextMenuSnapshotImage(nil);
    LGSetCachedFolderSnapshotImage(nil);
    LGSetCachedSpringBoardHomeImageValue(nil);
    sCachedSpringBoardHomeMTime = nil;
    sCachedSpringBoardHomePath = nil;
    sSnapshotRetryToken++;
    sSnapshotRetryScheduled = NO;
    sSnapshotRetryCount = 0;
    LGClearGlassTextureCache();
}

static void LGResetLockscreenSnapshotCaches(void) {
    LGSetCachedSpringBoardLockImageValue(nil);
    sCachedSpringBoardLockMTime = nil;
    sCachedSpringBoardLockPath = nil;
    LGInvalidateLockscreenSnapshotCache();
}

static void LGScheduleBlockAfterDelay(NSTimeInterval delay, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   block);
}

static void LGWarmTransientSnapshotsAfterDelay(NSTimeInterval delay) {
    LGScheduleBlockAfterDelay(delay, ^{
        if (!LG_globalEnabled()) return;
        if (!LG_getFolderSnapshot()) LG_cacheFolderSnapshot();
        if (!LG_getStrictCachedContextMenuSnapshot()) LG_cacheContextMenuSnapshot();
    });
}

static BOOL LG_isTodayViewControllerVisible(void) {
    if (sTodayViewVisible) return YES;

    static Class todayCls;
    if (!todayCls) todayCls = NSClassFromString(@"SBTodayViewController");
    if (!todayCls) return NO;

    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha <= 0.01f) continue;
                UIViewController *root = window.rootViewController;
                if (!root) continue;
                UIViewController *top = LG_topPresentedViewController(root);
                if ([top isKindOfClass:todayCls]) return YES;
            }
        }
        return NO;
    }

    for (UIWindow *window in LGApplicationWindows(app)) {
        if (window.hidden || window.alpha <= 0.01f) continue;
        UIViewController *root = window.rootViewController;
        if (!root) continue;
        UIViewController *top = LG_topPresentedViewController(root);
        if ([top isKindOfClass:todayCls]) return YES;
    }
    return NO;
}

static UIView *LG_contextSnapshotTargetView(UIWindow *homescreenWindow) {
    if (!homescreenWindow) return nil;
    static Class rootFolderCls, homeScreenCls, folderContainerCls;
    if (!rootFolderCls) rootFolderCls = NSClassFromString(@"SBRootFolderView");
    if (!homeScreenCls) homeScreenCls = NSClassFromString(@"SBHomeScreenView");
    if (!folderContainerCls) folderContainerCls = NSClassFromString(@"SBFolderContainerView");

    UIView *rootFolderView = rootFolderCls ? LG_findSubviewOfClass(homescreenWindow, rootFolderCls) : nil;
    if (rootFolderView) return rootFolderView;
    UIView *homeScreenView = homeScreenCls ? LG_findSubviewOfClass(homescreenWindow, homeScreenCls) : nil;
    if (homeScreenView) return homeScreenView;
    return folderContainerCls ? LG_findSubviewOfClass(homescreenWindow, folderContainerCls) : nil;
}

static UIImage *LG_captureTargetViewSnapshot(UIView *targetView, CGFloat scale, CGPoint *outOrigin) {
    if (!targetView || !targetView.window) return nil;

    CGRect targetRect = [targetView.window convertRect:targetView.bounds fromView:targetView];
    if (outOrigin) *outOrigin = targetRect.origin;
    UIImage *snapshot = LGCaptureViewHierarchySnapshot(targetView, targetView.bounds, targetView.bounds.size, scale, NO);
    if ((!snapshot || LG_imageLooksBlack(snapshot)) && targetView.window) {
        snapshot = LGCaptureViewHierarchySnapshot(targetView, targetView.bounds, targetView.bounds.size, scale, YES);
    }
    if (!snapshot || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_captureWindowSnapshot(UIWindow *window, CGSize screenSize, CGFloat scale) {
    if (!window) return nil;

    UIImage *snapshot = LGCaptureViewHierarchySnapshot(window, window.bounds, screenSize, scale, NO);
    if ((!snapshot || LG_imageLooksBlack(snapshot)) && window) {
        snapshot = LGCaptureViewHierarchySnapshot(window, window.bounds, screenSize, scale, YES);
    }
    if (!snapshot || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_composeHomescreenWallpaperAndIcons(UIImage *iconsSnapshot,
                                                      CGPoint iconsOrigin,
                                                      CGSize screenSize,
                                                      CGFloat scale) {
    if (!iconsSnapshot) return nil;

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LG_drawWallpaperImageInContext(wallpaper, wallpaperOrigin);
    [iconsSnapshot drawAtPoint:iconsOrigin];
    UIImage *composite = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composite;
}

static UIImage *LG_captureBroadContextComposite(NSArray<UIWindow *> *renderWindows, CGSize screenSize, CGFloat scale) {
    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    LG_drawHomescreenWallpaperInContext(screenSize);
    for (UIWindow *window in renderWindows) {
        if (!LGDrawViewHierarchyIntoCurrentContext(window, window.bounds, NO)) {
            [window.layer renderInContext:ctx];
        }
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static UIImage *LG_captureTodayViewComposite(UIWindow *homescreenWindow,
                                             NSArray<UIWindow *> *renderWindows,
                                             CGSize screenSize,
                                             CGFloat scale) {
    UIImage *base = LG_captureWindowSnapshot(homescreenWindow, screenSize, scale);
    if (!base) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, NO, scale);
    [base drawAtPoint:CGPointZero];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (UIWindow *window in renderWindows) {
        if (window == homescreenWindow) continue;
        if (!LGDrawViewHierarchyIntoCurrentContext(window, window.bounds, NO)) {
            [window.layer renderInContext:ctx];
        }
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static BOOL LG_contextSnapshotIsUsable(UIImage *snapshot) {
    if (!snapshot) return NO;
    if (LG_imageLooksBlack(snapshot)) return NO;
    if (!LG_hasHomescreenWallpaperAsset() && LG_contextSnapshotLooksIncomplete(snapshot)) return NO;
    return YES;
}

static UIImage *LG_captureContextMenuSnapshotWithHiddenGlass(BOOL hideGlass) {
    if (!LG_globalEnabled()) return nil;
    if (sContextMenuSnapshotCaptureInFlight) {
        return sCachedContextMenuSnapshot ?: sCachedSnapshot;
    }
    sContextMenuSnapshotCaptureInFlight = YES;
    CFTimeInterval start = CACurrentMediaTime();

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    NSMutableArray *hiddenViews = [NSMutableArray array];
    NSMutableArray *hiddenWindows = [NSMutableArray array];
    NSMutableArray *renderWindows = [NSMutableArray array];
    LG_collectSnapshotWindows(hiddenWindows, renderWindows);
    if (hideGlass) {
        LG_hideGlassViewsInWindows(renderWindows, hiddenViews);
    } else {
        [hiddenViews removeAllObjects];
    }

    UIImage *snap = nil;
    BOOL todayViewVisible = LG_isTodayViewControllerVisible();
    NSString *mode = todayViewVisible ? @"today" : @"homescreen";
    if (todayViewVisible) {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        if (homescreenWindow) {
            snap = LG_captureTodayViewComposite(homescreenWindow, renderWindows, screenSize, scale);
        }
    } else {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        UIView *targetView = LG_contextSnapshotTargetView(homescreenWindow);
        if (targetView && targetView.window) {
            CGPoint iconsOrigin = CGPointZero;
            UIImage *iconsSnap = LG_captureTargetViewSnapshot(targetView, scale, &iconsOrigin);
            snap = LG_composeHomescreenWallpaperAndIcons(iconsSnap, iconsOrigin, screenSize, scale);
        }
    }

    if (!snap) {
        NSMutableArray<NSString *> *windowNames = [NSMutableArray array];
        for (UIWindow *window in renderWindows) {
            [windowNames addObject:NSStringFromClass(window.class)];
        }
        LGDebugLog(@"snapshot capture fallback hideGlass=%d mode=%@ windows=%@", hideGlass, mode, windowNames);
        snap = LG_captureBroadContextComposite(renderWindows, screenSize, scale);
    }

    if (hideGlass || hiddenWindows.count > 0)
        LG_restoreSnapshotVisibility(hiddenViews, hiddenWindows);
    CFTimeInterval elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    LGDebugLog(@"snapshot capture done hideGlass=%d mode=%@ ok=%d usable=%d elapsed=%.1fms size=%@",
               hideGlass,
               mode,
               snap ? 1 : 0,
               LG_contextSnapshotIsUsable(snap) ? 1 : 0,
               elapsedMs,
               snap ? NSStringFromCGSize(snap.size) : @"(null)");
    sContextMenuSnapshotCaptureInFlight = NO;
    return snap;
}

void LG_cacheContextMenuSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    if (sCachedContextMenuSnapshot) return;
    if (sContextMenuSnapshotCaptureInFlight) return;
    // hold a menu-safe snapshot only while the menu is coming in
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(YES);
    if (LG_contextSnapshotIsUsable(snapshot)) {
        LGSetCachedContextMenuSnapshotImage(snapshot);
    }
}

void LG_invalidateContextMenuSnapshot(void) {
    LGAssertMainThread();
    LGSetCachedContextMenuSnapshotImage(nil);
}

UIImage *LG_getCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (sCachedContextMenuSnapshot) return sCachedContextMenuSnapshot;
    return sCachedSnapshot ?: LG_getContextMenuSnapshot();
}

UIImage *LG_getStrictCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedContextMenuSnapshot;
}

UIImage *LG_getContextMenuSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return nil;
    if (sContextMenuSnapshotCaptureInFlight) return sCachedContextMenuSnapshot ?: sCachedSnapshot;
    return LG_captureContextMenuSnapshotWithHiddenGlass(YES);
}

UIImage *LG_getHomescreenSnapshot(CGPoint *outOriginInScreenPts) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    if (!sCachedSnapshot) LG_refreshHomescreenSnapshot();
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset && outOriginInScreenPts) {
        *outOriginInScreenPts = LG_isCPBitmapPath(LG_preferredSpringBoardWallpaperPath(NO))
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
    } else if (outOriginInScreenPts) {
        *outOriginInScreenPts = CGPointZero;
    }
    return sCachedSnapshot;
}

UIImage *LG_getHomescreenIconCompositeSnapshot(CGPoint *outOriginInScreenPts) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale = UIScreen.mainScreen.scale;
    UIWindow *homescreenWindow = LG_getHomescreenWindow();
    UIView *targetView = LG_contextSnapshotTargetView(homescreenWindow);
    UIImage *iconsSnapshot = nil;
    CGPoint iconsOrigin = CGPointZero;
    if (targetView && targetView.window) {
        iconsSnapshot = LG_captureTargetViewSnapshot(targetView, scale, &iconsOrigin);
    }

    UIImage *composite = LG_composeHomescreenWallpaperAndIcons(iconsSnapshot, iconsOrigin, screenSize, scale);
    if (!composite) {
        composite = LG_getHomescreenSnapshot(outOriginInScreenPts);
        return composite;
    }

    if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
    return composite;
}

void LG_cacheFolderSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    CFTimeInterval start = CACurrentMediaTime();
    LGDebugLog(@"folder snapshot cache begin");
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(NO);
    LGSetCachedFolderSnapshotImage(LG_contextSnapshotIsUsable(snapshot) ? snapshot : nil);
    CFTimeInterval elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    LGDebugLog(@"folder snapshot cache end success=%d elapsed=%.1fms size=%@",
               sCachedFolderSnapshot ? 1 : 0,
               elapsedMs,
               sCachedFolderSnapshot ? NSStringFromCGSize(sCachedFolderSnapshot.size) : @"(null)");
}

void LG_invalidateFolderSnapshot(void) {
    LGAssertMainThread();
    LGDebugLog(@"folder snapshot invalidated");
    LGSetCachedFolderSnapshotImage(nil);
    LG_invalidateContextMenuSnapshot();
}

UIImage *LG_getFolderSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedFolderSnapshot;
}

UIImage *LG_getLockscreenSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (!LG_isAtLeastiOS16()) {
        UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
        if (asset) return asset;

        UIWindow *win = LG_getWallpaperWindow(YES);
        UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
        if (iv.image) {
            LGLog(@"loaded lockscreen wallpaper from imageView fallback");
            return iv.image;
        }
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    BOOL ok = LG_drawLockscreenWallpaperInContext(screenSize);
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    LGLog(@"lockscreen snapshot result ok=%d size=%@ scale=%.2f",
          ok ? 1 : 0,
          snap ? NSStringFromCGSize(snap.size) : @"(null)",
          snap ? snap.scale : 0.0);
    return snap;
}

UIImage *LG_getRawLockscreenWallpaperImage(void) {
    if (!LG_globalEnabled()) return nil;

    if (!LG_isAtLeastiOS16()) {
        UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
        if (asset) return asset;
    }

    UIWindow *win = LG_getWallpaperWindow(YES);
    UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
    if (iv.image)
        return iv.image;

    return nil;
}

CGPoint LG_getLockscreenWallpaperOrigin(void) {
    if (!LG_globalEnabled()) return CGPointZero;
    if (LG_isAtLeastiOS16()) {
        return CGPointZero;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
    if (asset) {
        return LG_centeredWallpaperOriginForImage(asset);
    }
    UIWindow *win = LG_getWallpaperWindow(YES);
    UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
    if (iv.image) {
        CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
        CGRect screenRect = [iv convertRect:displayedRect toView:nil];
        return screenRect.origin;
    }
    return CGPointZero;
}

static void LG_preferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_schedulePrefsChanged();
    });
}

static void LG_respringRequested(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_requestRespring();
    });
}

static void LG_invalidateSnapshotCachesRequested(CFNotificationCenterRef center,
                                                 void *observer,
                                                 CFStringRef name,
                                                 const void *object,
                                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLog(@"snapshot cache invalidation requested");
        LGSetCachedSnapshotImage(nil);
        LG_invalidateFolderSnapshot();
        LG_invalidateContextMenuSnapshot();
        LGInvalidateLockscreenSnapshotCache();
        LG_trySnapshotWithRetry();
        if (!LG_getFolderSnapshot()) LG_cacheFolderSnapshot();
        LGRefreshLockSnapshotAfterDelay(0.0);
    });
}

static void LG_requestRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) {
        return;
    }

    SBSRelaunchAction *restartAction =
        [actionClass actionWithReason:@"LiquidAssPrefs"
                              options:(SBSRelaunchActionOptionsRestartRenderServer |
                                       SBSRelaunchActionOptionsFadeToBlackTransition)
                            targetURL:nil];
    if (!restartAction) {
        return;
    }

    LGLog(@"respring requested");
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;

    LGReloadPreferences();
    LGLog(@"loaded into %@", LGMainBundleIdentifier() ?: @"(unknown)");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LGPrewarmPipelines();
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_startLegacyWallpaperWatcher();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            LG_handleMemoryWarning();
        }];
    });
    LGObservePreferenceChanges(^{
        LG_preferencesChanged(NULL, NULL, NULL, NULL, NULL);
    });
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_respringRequested,
                                    LGPrefsRespringNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_invalidateSnapshotCachesRequested,
                                    LGInvalidateSnapshotCachesNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void LG_pushWallpaperToTree(UIView *root) {
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        LiquidGlassView *glass = (LiquidGlassView *)root;
        CGPoint wallpaperOrigin = CGPointZero;
        if (sCachedSnapshot) (void)LG_getHomescreenSnapshot(&wallpaperOrigin);
        glass.wallpaperImage = nil;
        glass.wallpaperImage = sCachedSnapshot;
        glass.wallpaperOrigin = wallpaperOrigin;
        [glass updateOrigin];
        return;
    }
    for (UIView *sub in root.subviews) LG_pushWallpaperToTree(sub);
}

static void LG_pushConfiguredBackdropToTree(UIView *root, LGUpdateGroup group, UIImage *image) {
    if (!root || !image) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        LiquidGlassView *glass = (LiquidGlassView *)root;
        if (glass.updateGroup == group) {
            glass.wallpaperImage = nil;
            glass.wallpaperImage = image;
            if (group == LGUpdateGroupLockscreen)
                glass.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
            [glass updateOrigin];
        }
        return;
    }
    for (UIView *sub in root.subviews)
        LG_pushConfiguredBackdropToTree(sub, group, image);
}

static void LG_pushSnapshotToAllGlassViews(void) {
    if (!sCachedSnapshot) return;
    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            LG_pushWallpaperToTree(window);
    }
}

static void LG_pushLockscreenSnapshotToAllGlassViews(void) {
    if (!LG_globalEnabled()) return;
    UIImage *lockImage = LG_getLockscreenSnapshot();
    if (!lockImage) return;

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            LG_pushConfiguredBackdropToTree(window, LGUpdateGroupLockscreen, lockImage);
    }
}

static BOOL LGPushCurrentLockscreenSnapshotToAllGlassViews(void) {
    if (!LG_globalEnabled()) return NO;
    UIImage *lockImage = LG_getLockscreenSnapshot();
    if (!lockImage) return NO;

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            LG_pushConfiguredBackdropToTree(window, LGUpdateGroupLockscreen, lockImage);
        }
    }
    return YES;
}

static void LG_scheduleHomescreenWallpaperRefresh(NSString *reason, UIImage *image) {
    if (!LG_globalEnabled()) return;
    if (image) sInterceptedWallpaperImage = image;
    LGResetHomescreenSnapshotCaches();
    NSUInteger token = ++sPendingHomescreenWallpaperRefreshToken;
    LGDebugLog(@"homescreen wallpaper refresh scheduled reason=%@", reason ?: @"(unknown)");
    LGScheduleBlockAfterDelay(0.30, ^{
        if (!LG_globalEnabled()) return;
        if (token != sPendingHomescreenWallpaperRefreshToken) return;
        LGDebugLog(@"homescreen wallpaper refresh begin reason=%@", reason ?: @"(unknown)");
        LG_refreshHomescreenSnapshot();
        if (sCachedSnapshot) {
            LG_pushSnapshotToAllGlassViews();
            LGWarmTransientSnapshotsAfterDelay(0.12);
        } else {
            LG_trySnapshotWithRetry();
        }
    });
}

static void LG_scheduleLockscreenWallpaperRefreshAttempt(NSString *reason,
                                                         NSUInteger token,
                                                         NSTimeInterval delay,
                                                         BOOL allowRetry) {
    LGScheduleBlockAfterDelay(delay, ^{
        if (!LG_globalEnabled()) return;
        if (token != sPendingLockscreenWallpaperRefreshToken) return;
        LGDebugLog(@"lockscreen wallpaper refresh begin reason=%@ delay=%.2f",
                   reason ?: @"(unknown)",
                   delay);
        LGResetLockscreenSnapshotCaches();
        BOOL pushed = LGPushCurrentLockscreenSnapshotToAllGlassViews();
        LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
        if (!pushed && allowRetry && token == sPendingLockscreenWallpaperRefreshToken) {
            LG_scheduleLockscreenWallpaperRefreshAttempt(reason, token, 0.85, NO);
        }
    });
}

static void LG_scheduleLockscreenWallpaperRefresh(NSString *reason) {
    if (!LG_globalEnabled()) return;
    LGResetLockscreenSnapshotCaches();
    NSUInteger token = ++sPendingLockscreenWallpaperRefreshToken;
    LGDebugLog(@"lockscreen wallpaper refresh scheduled reason=%@", reason ?: @"(unknown)");
    LG_scheduleLockscreenWallpaperRefreshAttempt(reason, token, 0.28, YES);
}

static void LG_schedulePrefsChanged(void) {
    NSUInteger token = ++sPendingPrefsChangeToken;
    LGScheduleBlockAfterDelay(0.10, ^{
        if (token != sPendingPrefsChangeToken) return;
        LG_handlePrefsChanged();
    });
}

static void LG_handlePrefsChanged(void) {
    LGAssertMainThread();
    LGReloadPreferences();
    LGLog(@"preferences changed");
    LGResetHomescreenSnapshotCaches();
    sInterceptedWallpaperImage = nil;
    LGResetLockscreenSnapshotCaches();

    if (!LG_globalEnabled()) return;

    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        LG_pushSnapshotToAllGlassViews();
    } else {
        LG_trySnapshotWithRetry();
    }
    LG_pushLockscreenSnapshotToAllGlassViews();
    LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
    LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
    LG_updateRegisteredGlassViews(LGUpdateGroupDock);
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderIcon);
    LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}

static void LG_handleMemoryWarning(void) {
    LGAssertMainThread();
    LGLog(@"memory warning clearing caches");
    LGResetHomescreenSnapshotCaches();
    LGResetLockscreenSnapshotCaches();
    sInterceptedWallpaperImage = nil;
}

static void LG_trySnapshotWithRetry(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    if (sCachedSnapshot) return;
    if (sSnapshotRetryScheduled) return;
    if (sSnapshotRetryCount >= kLGMaxSnapshotRetryCount) {
        LGDebugLog(@"homescreen snapshot retry capped count=%lu", (unsigned long)sSnapshotRetryCount);
        return;
    }
    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        sSnapshotRetryCount = 0;
        LG_pushSnapshotToAllGlassViews();
        return;
    }
    sSnapshotRetryCount++;
    sSnapshotRetryScheduled = YES;
    NSUInteger token = sSnapshotRetryToken;
    NSTimeInterval delay = MIN(8.0, 2.0 * pow(1.35, (double)MAX((NSInteger)sSnapshotRetryCount - 1, 0)));
    LGScheduleBlockAfterDelay(delay, ^{
        if (token != sSnapshotRetryToken) return;
        sSnapshotRetryScheduled = NO;
        LG_trySnapshotWithRetry();
    });
}

static void *kLGReplicaObservedImageKey = &kLGReplicaObservedImageKey;
static void *kLGReplicaObservedImageViewKey = &kLGReplicaObservedImageViewKey;
static void *kLGReplicaRoleKey = &kLGReplicaRoleKey;

typedef NS_ENUM(NSInteger, LGReplicaWallpaperRole) {
    LGReplicaWallpaperRoleNone = 0,
    LGReplicaWallpaperRoleHome,
    LGReplicaWallpaperRoleLock,
};

static UIView *LGWallpaperReplicaAncestorForView(UIView *view) {
    static Class replicaCls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    });
    UIView *ancestor = view;
    while (ancestor) {
        if (replicaCls && [ancestor isKindOfClass:replicaCls]) return ancestor;
        ancestor = ancestor.superview;
    }
    return nil;
}

static LGReplicaWallpaperRole LGConfigureWallpaperReplicaView(UIView *replicaView) {
    if (!replicaView || !replicaView.window) return LGReplicaWallpaperRoleNone;

    static Class replicaCls, homePosterVCCls, lockPosterVCCls;
    if (!replicaCls) replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!homePosterVCCls) homePosterVCCls = NSClassFromString(@"PBUIPosterHomeViewController");
    if (!lockPosterVCCls) lockPosterVCCls = NSClassFromString(@"PBUIPosterLockViewController");
    if (!LG_viewMatchesHierarchyClass(replicaView, replicaCls)) return LGReplicaWallpaperRoleNone;

    UIImageView *imageView = LG_findImageViewInTree(replicaView);
    if (!imageView.image) return LGReplicaWallpaperRoleNone;

    LGReplicaWallpaperRole role = LGReplicaWallpaperRoleNone;
    if (LG_viewMatchesHierarchyClass(replicaView, homePosterVCCls)) {
        role = LGReplicaWallpaperRoleHome;
    } else if (LG_viewMatchesHierarchyClass(replicaView, lockPosterVCCls)) {
        role = LGReplicaWallpaperRoleLock;
    }
    if (role == LGReplicaWallpaperRoleNone) return role;

    objc_setAssociatedObject(replicaView, kLGReplicaObservedImageViewKey, imageView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(replicaView, kLGReplicaRoleKey, @(role), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return role;
}

static void LGClearWallpaperReplicaState(UIView *replicaView) {
    objc_setAssociatedObject(replicaView, kLGReplicaObservedImageKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(replicaView, kLGReplicaObservedImageViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(replicaView, kLGReplicaRoleKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGHandleWallpaperReplicaView(UIView *replicaView) {
    if (!LG_globalEnabled() || !replicaView.window) return;
    UIImageView *imageView = objc_getAssociatedObject(replicaView, kLGReplicaObservedImageViewKey);
    LGReplicaWallpaperRole role = [objc_getAssociatedObject(replicaView, kLGReplicaRoleKey) integerValue];
    if (!imageView || !imageView.window || role == LGReplicaWallpaperRoleNone) {
        role = LGConfigureWallpaperReplicaView(replicaView);
        imageView = objc_getAssociatedObject(replicaView, kLGReplicaObservedImageViewKey);
    }
    UIImage *image = imageView.image;
    if (!image) return;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (image.size.width < screen.width * 0.5) return;

    UIImage *lastImage = objc_getAssociatedObject(replicaView, kLGReplicaObservedImageKey);
    if (role == LGReplicaWallpaperRoleHome) {
        BOOL sameImage = (sInterceptedWallpaperImage == image);
        if (lastImage != image || !sameImage || !sCachedSnapshot) {
            LG_scheduleHomescreenWallpaperRefresh(@"poster-home-image", image);
            objc_setAssociatedObject(replicaView, kLGReplicaObservedImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (role == LGReplicaWallpaperRoleLock) {
        if (lastImage != image || !sCachedSpringBoardLockImage) {
            LG_scheduleLockscreenWallpaperRefresh(@"poster-lock-image");
            objc_setAssociatedObject(replicaView, kLGReplicaObservedImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
}

%hook PBUISnapshotReplicaView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) {
        LGClearWallpaperReplicaState((UIView *)self);
        return;
    }
    LGConfigureWallpaperReplicaView((UIView *)self);
    LGHandleWallpaperReplicaView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (!objc_getAssociatedObject(self, kLGReplicaObservedImageViewKey)) {
        LGConfigureWallpaperReplicaView((UIView *)self);
        LGHandleWallpaperReplicaView((UIView *)self);
    }
}

%end

%hook UIImageView

- (void)setImage:(UIImage *)image {
    %orig;
    UIView *replicaView = LGWallpaperReplicaAncestorForView((UIView *)self);
    if (!replicaView || !replicaView.window) return;
    UIImageView *observedImageView = objc_getAssociatedObject(replicaView, kLGReplicaObservedImageViewKey);
    if (observedImageView != (UIImageView *)self) {
        LGConfigureWallpaperReplicaView(replicaView);
    }
    LGHandleWallpaperReplicaView(replicaView);
}

%end

%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_trySnapshotWithRetry();
    NSArray<NSNumber *> *delays = @[@0.12, @0.28, @0.55];
    for (NSNumber *delayNumber in delays) {
        LGScheduleBlockAfterDelay(delayNumber.doubleValue, ^{
            if (!LG_globalEnabled()) return;
            if (!LG_getFolderSnapshot())
                LG_cacheFolderSnapshot();
        });
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    UIViewController *vc = (UIViewController *)self;
    UIInterfaceOrientation beforeOrientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        if (vc.view.window.windowScene)
            beforeOrientation = vc.view.window.windowScene.interfaceOrientation;
    }
    LGDebugLog(@"homescreen rotation will size=%@ beforeOrientation=%ld screen=%@ snapshot=%@",
               NSStringFromCGSize(size),
               (long)beforeOrientation,
               NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
               sCachedSnapshot ? NSStringFromCGSize(sCachedSnapshot.size) : @"(null)");
    %orig;
    if (![coordinator respondsToSelector:@selector(animateAlongsideTransition:completion:)]) return;
    [coordinator animateAlongsideTransition:^(__unused id context) {
        UIInterfaceOrientation duringOrientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            if (vc.view.window.windowScene)
                duringOrientation = vc.view.window.windowScene.interfaceOrientation;
        }
        LGDebugLog(@"homescreen rotation alongside orientation=%ld screen=%@",
                   (long)duringOrientation,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size));
    } completion:^(__unused id context) {
        if (LG_globalEnabled()) {
            LGSetCachedSnapshotImage(nil);
            LG_invalidateFolderSnapshot();
            LG_invalidateContextMenuSnapshot();
            LG_refreshHomescreenSnapshot();
            if (sCachedSnapshot) {
                LG_pushSnapshotToAllGlassViews();
            } else {
                LG_trySnapshotWithRetry();
            }
        }
        UIInterfaceOrientation afterOrientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            if (vc.view.window.windowScene)
                afterOrientation = vc.view.window.windowScene.interfaceOrientation;
        }
        CGPoint origin = CGPointZero;
        UIImage *snapshot = LG_getHomescreenSnapshot(&origin);
        LGDebugLog(@"homescreen rotation done orientation=%ld screen=%@ snapshot=%@ origin=%@",
                   (long)afterOrientation,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
                   snapshot ? NSStringFromCGSize(snapshot.size) : @"(null)",
                   NSStringFromCGPoint(origin));
    }];
}
%end

%hook SBTodayViewController
- (void)viewWillAppear:(BOOL)animated {
    sTodayViewVisible = YES;
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sTodayViewVisible = YES;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    LGScheduleBlockAfterDelay(0.10, ^{
        if (!LG_globalEnabled()) return;
        LG_cacheFolderSnapshot();
        LG_cacheContextMenuSnapshot();
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    sTodayViewVisible = NO;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    LGScheduleBlockAfterDelay(0.10, ^{
        if (!LG_globalEnabled()) return;
        LG_trySnapshotWithRetry();
        if (!LG_getFolderSnapshot())
            LG_cacheFolderSnapshot();
    });
}
%end

static BOOL LG_shouldCacheSnapshotsForLongPress(UIGestureRecognizer *gesture) {
    UIView *view = gesture.view;
    if (!view || !view.window) return NO;

    static Class sbIconViewCls;
    static Class sbFolderIconImageViewCls;
    static Class sbIconListViewCls;
    if (!sbIconViewCls) sbIconViewCls = NSClassFromString(@"SBIconView");
    if (!sbFolderIconImageViewCls) sbFolderIconImageViewCls = NSClassFromString(@"SBFolderIconImageView");
    if (!sbIconListViewCls) sbIconListViewCls = NSClassFromString(@"SBIconListView");

    UIView *v = view;
    BOOL foundIconishView = NO;
    while (v) {
        if ((sbIconViewCls && [v isKindOfClass:sbIconViewCls]) ||
            (sbFolderIconImageViewCls && [v isKindOfClass:sbFolderIconImageViewCls])) {
            foundIconishView = YES;
        }
        if (foundIconishView && sbIconListViewCls && [v isKindOfClass:sbIconListViewCls]) {
            BOOL matchesResponderChain =
                LGResponderChainContainsClassNamed(view, @"SBIconController") ||
                LGResponderChainContainsClassNamed(view, @"SBHomeScreenViewController") ||
                LGResponderChainContainsClassNamed(view, @"SBFolderViewController") ||
                LGResponderChainContainsClassNamed(view, @"SBAppLibraryViewController");
            NSString *rootName = NSStringFromClass(view.window.rootViewController.class);
            BOOL matchesRootController =
                [rootName isEqualToString:@"SBHomeScreenViewController"] ||
                [rootName isEqualToString:@"SBRootFolderController"] ||
                [rootName isEqualToString:@"SBAppLibraryViewController"];
            return matchesResponderChain || matchesRootController;
        }
        v = v.superview;
    }
    return NO;
}

%hook UILongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state != UIGestureRecognizerStateBegan) return;
    if (!LG_shouldCacheSnapshotsForLongPress(self)) return;
    LGDebugLog(@"long press snapshot warmup");
    LG_cacheFolderSnapshot();
    LG_cacheContextMenuSnapshot();
}
%end
