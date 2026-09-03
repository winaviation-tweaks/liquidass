#import "LGSharedSupport.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <unistd.h>

static const char *kLGBackboardSafeModeStatePath =
    "/var/mobile/Library/Accessibility/liquidass-backboardd-guard.bin";
static const char *kLGBackboardSafeModePendingPath =
    "/var/mobile/Library/Accessibility/liquidass-backboardd-alert";

typedef struct {
    uint32_t magic;
    uint32_t version;
    int64_t bootTime;
    uint64_t lastStartMilliseconds;
    uint32_t rapidStarts;
    uint32_t disabled;
} LGBackboardSafeModeState;

BOOL LGBackboardSafeModeActive(void) {
    NSData *data = [NSData dataWithContentsOfFile:
        [NSString stringWithUTF8String:kLGBackboardSafeModeStatePath]];
    if (data.length != sizeof(LGBackboardSafeModeState)) return NO;

    LGBackboardSafeModeState state = {};
    [data getBytes:&state length:sizeof(state)];
    if (state.magic != 0x4c47534d || state.version != 1 || !state.disabled) return NO;

    struct timeval bootTime = {};
    size_t size = sizeof(bootTime);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != 0) return NO;
    return state.bootTime == (int64_t)bootTime.tv_sec;
}

void LGClearBackboardSafeMode(void) {
    unlink(kLGBackboardSafeModeStatePath);
    unlink(kLGBackboardSafeModePendingPath);
}

__attribute__((weak)) int __isOSVersionAtLeast(int major, int minor, int patch) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != major) return version.majorVersion > major;
    if (version.minorVersion != minor) return version.minorVersion > minor;
    return version.patchVersion >= patch;
}

NSString * const LGPrefsDomain = @"dylv.liquidassprefs";
CFStringRef const LGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
CFStringRef const LGPrefsRespringNotification = CFSTR("dylv.liquidassprefs/Respring");
const char * const LGPrefsChangedNotificationCString = "dylv.liquidassprefs/Reload";
const char * const LGPrefsRespringNotificationCString = "dylv.liquidassprefs/Respring";
const CGFloat LGKeyboardDefaultCornerRadius = 28.0;
const CGFloat LGKeyboardDefaultOverhang = 20.0;
const CGFloat LGKeyboardDefaultKeyRadius = 10.0;
const CGFloat LGBannerDefaultCornerRadius = 18.5;
const CGFloat LGBannerDefaultBezelWidth = 18.0;
const CGFloat LGBannerDefaultBlur = 40.0;
const CGFloat LGBannerDefaultDarkTintAlpha = 0.5;
const CGFloat LGBannerDefaultGlassThickness = 150.0;
const CGFloat LGBannerDefaultLightTintAlpha = 0.8;
const CGFloat LGBannerDefaultRefractionScale = 1.5;
const CGFloat LGBannerDefaultRefractiveIndex = 4.0;
const CGFloat LGBannerDefaultSpecularOpacity = 0.6;
const CGFloat LGBannerDefaultWallpaperScale = 1.0;
NSString * const LGBannerWindowClassName = @"SBBannerWindow";
NSString * const LGBannerContentViewClassName = @"BNContentViewControllerView";
NSString * const LGBannerControllerClassName = @"BNContentViewController";
NSString * const LGBannerPresentableControllerClassName = @"SBNotificationPresentableViewController";
NSString * const LGAppLibrarySidebarMarkerClassName = @"_SBHLibraryFrozenSafeAreaInsetsView";
NSString * const LGTintOverrideSystem = @"system";
NSString * const LGTintOverrideLight = @"light";
NSString * const LGTintOverrideDark = @"dark";
static NSString * const LGPrefsDidReloadInProcessNotification = @"dylv.liquidassprefs.InProcessReload";

static NSDictionary<NSString *, id> *sLGCachedPreferences = nil;
static os_unfair_lock sLGPrefsLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sLGPrefsSetupOnce;
static dispatch_queue_t sLGLogQueue;
static NSFileHandle *sLGLogHandle;
static void *kLGImageStableCacheKeyAssociation = &kLGImageStableCacheKeyAssociation;

static NSDictionary<NSString *, id> *LGCopyPreferencesDictionary(void);

static void LGCloseLogHandle(void) {
    if (!sLGLogHandle) return;
    if (@available(iOS 13.0, *)) {
        [sLGLogHandle closeAndReturnError:nil];
    } else {
        [sLGLogHandle closeFile];
    }
    sLGLogHandle = nil;
}

static void LGCloseLogHandleAtExit(void) {
    if (!sLGLogQueue) {
        LGCloseLogHandle();
        return;
    }
    dispatch_sync(sLGLogQueue, ^{
        LGCloseLogHandle();
    });
}

static NSString *LGLogFilePath(void) {
    static NSString *sPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if TARGET_OS_SIMULATOR
        sPath = @"/tmp/liquidglass.log";
#else

        if ([NSBundle.mainBundle.bundleIdentifier
                isEqualToString:@"com.apple.mobilesafari"]) {
            NSString *temporaryDirectory = NSTemporaryDirectory();
            sPath = [temporaryDirectory
                stringByAppendingPathComponent:@"liquidglass.log"];
        } else {
            sPath = @"/var/mobile/Library/Accessibility/liquidglass.log";
        }
#endif
    });
    return sPath;
}

static void LGAppendLogLine(NSString *line) {
    NSString *path = LGLogFilePath();
    if (!path.length || !line.length) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGLogQueue = dispatch_queue_create("dylv.liquidass.logfile", DISPATCH_QUEUE_SERIAL);
        atexit(LGCloseLogHandleAtExit);
    });

    dispatch_async(sLGLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            NSError *createError = nil;
            [NSData.data writeToFile:path options:NSDataWritingAtomic error:&createError];
            if (createError) {
                NSLog(@"[LiquidAss] log file create failed %@", createError.localizedDescription ?: @"unknown");
                return;
            }
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length) {
            return;
        }
        if (!sLGLogHandle) {
            sLGLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (!sLGLogHandle) {
            NSLog(@"[LiquidAss] log file open failed %@", path);
            return;
        }

        NSError *handleError = nil;
        if (@available(iOS 13.0, *)) {
            [sLGLogHandle seekToEndReturningOffset:nil error:&handleError];
            if (!handleError) {
                [sLGLogHandle writeData:data error:&handleError];
            }
        } else {
            @try {
                [sLGLogHandle seekToEndOfFile];
                [sLGLogHandle writeData:data];
            } @catch (NSException *exception) {
                handleError = [NSError errorWithDomain:@"dylv.liquidass.logfile"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"NSFileHandle exception"}];
            }
        }

        if (handleError) {
            LGCloseLogHandle();
            NSLog(@"[LiquidAss] log file append failed %@", handleError.localizedDescription ?: @"unknown");
        }
    });
}

static NSDictionary<NSString *, id> *LGCopyPreferencesDictionary(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    CFDictionaryRef values = CFPreferencesCopyMultiple(NULL,
                                                       (__bridge CFStringRef)LGPrefsDomain,
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesAnyHost);
    NSDictionary *dictionary = CFBridgingRelease(values);
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return dictionary;
}

static void LGPreferencesChanged(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGReloadPreferences();
        [[NSNotificationCenter defaultCenter] postNotificationName:LGPrefsDidReloadInProcessNotification object:nil];
    });
}

static void LGEnsurePreferenceCacheInitialized(void) {
    dispatch_once(&sLGPrefsSetupOnce, ^{
        LGReloadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LGPreferencesChanged,
                                        LGPrefsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

NSString *LGMainBundleIdentifier(void) {
    static NSString *bundleID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundleID = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
    });
    return bundleID;
}

BOOL LGIsSpringBoardProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.springboard"];
}

BOOL LGIsPreferencesProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.Preferences"];
}

BOOL LGIsAtLeastiOS16(void) {
    static BOOL cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return cached;
}

NSString *LGRWBDefaultWidgetBundleIDsText(void) {
    static NSString *text;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        text = [@[
            @"com.apple.mobiletimer.WorldClockWidget",
            @"com.apple.mobilecal.CalendarWidgetExtension",
            @"com.apple.mobilemail.MailWidgetExtension",
            @"com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension",
            @"com.apple.reminders.WidgetExtension",
            @"com.apple.weather.widget",
            @"com.apple.Fitness.FitnessWidget",
            @"com.apple.Passbook.PassbookWidgets",
            @"com.apple.Health.Sleep.SleepWidgetExtension",
            @"com.apple.tips.TipsSwift",
            @"com.apple.Music.MusicWidgets",
            @"com.apple.gamecenter.widgets.extension",
            @"com.apple.tv.TVWidgetExtension",
            @"com.apple.news.widget",
            @"com.apple.Maps.GeneralMapsWidget",
        ] componentsJoinedByString:@"\n"];
    });
    return text;
}

CGFloat LGEffectiveBannerBlur(CGFloat configuredBlur) {
    return fmin(80.0, fmax(0.0, configuredBlur) * 2.2);
}

void LGReloadPreferences(void) {
    NSDictionary<NSString *, id> *dictionary = LGCopyPreferencesDictionary();
    os_unfair_lock_lock(&sLGPrefsLock);
    sLGCachedPreferences = dictionary;
    os_unfair_lock_unlock(&sLGPrefsLock);
}

void LGObservePreferenceChanges(dispatch_block_t block) {
    if (!block) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:LGPrefsDidReloadInProcessNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        block();
    }];
}

static id LGPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key];
}

BOOL LGHasExplicitPreferenceValue(NSString *key) {
    if (!key.length) return NO;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key] != nil;
}

BOOL LG_prefBool(NSString *key, BOOL fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return fallback;
}

CGFloat LG_prefFloat(NSString *key, CGFloat fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return (CGFloat)[value doubleValue];
    return fallback;
}

NSInteger LG_prefInteger(NSString *key, NSInteger fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    return fallback;
}

NSString *LG_prefString(NSString *key, NSString *fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return fallback;
}

BOOL LG_globalEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO);
}

BOOL LGDebugLoggingEnabled(void) {
    return LG_prefBool(@"Debug.Logging.Enabled", NO);
}

void LGLog(NSString *format, ...) {
    if (!LGDebugLoggingEnabled()) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message]);
}

CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return sColorSpace;
}

UIImage *LGNormalizedImageForUpload(UIImage *image) {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

NSNumber *LGTextureScaleKey(CGFloat scale) {
    NSInteger milli = (NSInteger)lrint(scale * 1000.0);
    return @(MAX(milli, 1));
}

NSNumber *LGBlurSettingKey(CGFloat blur) {
    NSInteger milli = (NSInteger)lrint(fmax(0.0, blur) * 1000.0);
    return @(MAX(milli, 0));
}

NSString *LGImageStableCacheKey(UIImage *image) {
    if (!image) return nil;
    return objc_getAssociatedObject(image, kLGImageStableCacheKeyAssociation);
}

void LGSetImageStableCacheKey(UIImage *image, NSString *cacheKey) {
    if (!image) return;
    objc_setAssociatedObject(image,
                             kLGImageStableCacheKeyAssociation,
                             [cacheKey copy],
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}
