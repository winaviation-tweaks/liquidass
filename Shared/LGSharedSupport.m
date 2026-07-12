#import "LGSharedSupport.h"
#import "LGMetalShaderSource.h"
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <unistd.h>

NSString * const LGPrefsDomain = @"dylv.liquidassprefs";
CFStringRef const LGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
CFStringRef const LGPrefsRespringNotification = CFSTR("dylv.liquidassprefs/Respring");
const char * const LGPrefsChangedNotificationCString = "dylv.liquidassprefs/Reload";
const char * const LGPrefsRespringNotificationCString = "dylv.liquidassprefs/Respring";
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
NSString * const LGRenderingModeSnapshot = @"snapshot";
NSString * const LGRenderingModeLiveCapture = @"live_capture";
NSString * const LGRenderingModeServer = @"server";
NSString * const LGTintOverrideSystem = @"system";
NSString * const LGTintOverrideLight = @"light";
NSString * const LGTintOverrideDark = @"dark";
static NSString * const LGPrefsDidReloadInProcessNotification = @"dylv.liquidassprefs.InProcessReload";

static NSDictionary<NSString *, id> *sLGCachedPreferences = nil;
static os_unfair_lock sLGPrefsLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sLGPrefsSetupOnce;
static dispatch_once_t sLGPrefsWriteQueueOnce;
static dispatch_queue_t sLGPrefsWriteQueue;
static dispatch_queue_t sLGLogQueue;
static NSFileHandle *sLGLogHandle;
static NSString * const kLGDynamicDefaultPrefix = @"__dynamic_default.";
static void *kLGImageStableCacheKeyAssociation = &kLGImageStableCacheKeyAssociation;
static os_unfair_lock sLGProfileLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *sLGProfileStats = nil;
static NSMutableDictionary<NSString *, NSNumber *> *sLGPendingDynamicDefaultWrites = nil;
static BOOL sLGDynamicDefaultFlushScheduled = NO;
static BOOL sLGAllDayProfilingSessionStarted = NO;
static dispatch_source_t sLGAllDayProfilingTimer = nil;
static CFTimeInterval sLGProfileWindowStart = 0.0;
static CFTimeInterval sLGLastAllDayProfilerHeartbeat = 0.0;
static const CFTimeInterval kLGProfileFlushInterval = 2.0;
static const CFTimeInterval kLGAllDayProfileFlushInterval = 60.0;
static const CFTimeInterval kLGAllDayHeartbeatInterval = 300.0;
static const CFTimeInterval kLGDynamicDefaultFlushDelay = 0.25;
static const unsigned long long kLGLogMaxFileSize = 10ULL * 1024ULL * 1024ULL;

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
        sPath = @"/tmp/LiquidAss.log";
    });
    return sPath;
}

static NSString *LGProfilingLogFilePath(void) {
    return @"/tmp/LiquidAss-profiling.log";
}

static dispatch_queue_t LGPrefsWriteQueue(void) {
    dispatch_once(&sLGPrefsWriteQueueOnce, ^{
        sLGPrefsWriteQueue = dispatch_queue_create("dylv.liquidass.prefswrite", DISPATCH_QUEUE_SERIAL);
    });
    return sLGPrefsWriteQueue;
}

static void LGAppendProfilingLogLine(NSString *line) {
    if (!line.length) return;
    NSString *path = LGProfilingLogFilePath();
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!path.length || !data.length) return;

    static dispatch_queue_t sLGProfilingLogQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGProfilingLogQueue = dispatch_queue_create("dylv.liquidass.profilinglog", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(sLGProfilingLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [NSData.data writeToFile:path atomically:YES];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
            @try { [handle closeFile]; } @catch (__unused NSException *closeException) {}
        }
    });
}

static id LGProfilingJSONObject(id object) {
    if (!object) return @"null";
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] || object == NSNull.null) {
        return object;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
            NSString *stringKey = [key isKindOfClass:[NSString class]] ? key : [[key description] copy];
            if (stringKey.length) dictionary[stringKey] = LGProfilingJSONObject(value);
        }];
        return dictionary;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id value in (NSArray *)object) {
            [array addObject:LGProfilingJSONObject(value)];
        }
        return array;
    }
    if ([object isKindOfClass:[NSDate class]]) {
        return [(NSDate *)object description];
    }
    return [object description] ?: @"";
}

static NSString *LGProfilingJSONStringForObject(id object) {
    id jsonObject = LGProfilingJSONObject(object);
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObject
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data.length) return [jsonObject description] ?: @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static uint64_t LGCurrentResidentMemoryBytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(),
                                     MACH_TASK_BASIC_INFO,
                                     (task_info_t)&info,
                                     &count);
    if (result != KERN_SUCCESS) return 0;
    return (uint64_t)info.resident_size;
}

static NSString *LGThermalStateString(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
        default: return [NSString stringWithFormat:@"unknown(%ld)", (long)state];
    }
}

static BOOL LGAllDayProfilingEnabled(void) {
    return LG_prefBool(@"AllDayProfiling.Enabled", NO);
}

static void LGAppendAllDayProfilerHeartbeat(NSString *reason) {
    if (!LGAllDayProfilingEnabled()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if ([reason isEqualToString:@"thermal-change"] && now - sLGLastAllDayProfilerHeartbeat < 5.0) return;
    sLGLastAllDayProfilerHeartbeat = now;

    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    CGFloat batteryPercent = device.batteryLevel >= 0.0f ? device.batteryLevel * 100.0f : -1.0f;
    uint64_t residentBytes = LGCurrentResidentMemoryBytes();
    LGAppendProfilingLogLine([NSString stringWithFormat:
        @"[LiquidAssProfiler] heartbeat date=%@ reason=%@ uptime=%.1fs resident=%.1fMB thermal=%@ battery=%.0f%% batteryState=%ld appState=%ld\n",
        [NSDate date],
        reason ?: @"timer",
        NSProcessInfo.processInfo.systemUptime,
        (double)residentBytes / (1024.0 * 1024.0),
        LGThermalStateString(NSProcessInfo.processInfo.thermalState),
        batteryPercent,
        (long)device.batteryState,
        (long)UIApplication.sharedApplication.applicationState]);
}

void LGStartAllDayProfilingSession(NSString *version, NSString *buildTimestamp) {
    if (sLGAllDayProfilingSessionStarted || !LGAllDayProfilingEnabled()) return;
    sLGAllDayProfilingSessionStarted = YES;

    NSString *processName = NSProcessInfo.processInfo.processName ?: @"unknown";
    NSString *osVersion = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"unknown";
    NSDictionary<NSString *, id> *preferences = LGCopyPreferencesDictionary();
    NSString *preferencesJSON = LGProfilingJSONStringForObject(preferences);
    LGAppendProfilingLogLine([NSString stringWithFormat:
        @"\n[LiquidAssProfiler] session-start date=%@ pid=%d process=%@ version=%@ built=%@ uptime=%.1fs os=%@\n",
        [NSDate date],
        getpid(),
        processName,
        version ?: @"unknown",
        buildTimestamp ?: @"unknown",
        NSProcessInfo.processInfo.systemUptime,
        osVersion]);
    LGAppendProfilingLogLine(@"[LiquidAssProfiler] preferences-begin\n");
    LGAppendProfilingLogLine([preferencesJSON stringByAppendingString:@"\n"]);
    LGAppendProfilingLogLine(@"[LiquidAssProfiler] preferences-end\n");
    LGAppendAllDayProfilerHeartbeat(@"session-start");

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    sLGAllDayProfilingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(sLGAllDayProfilingTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLGAllDayHeartbeatInterval * NSEC_PER_SEC)),
                              (uint64_t)(kLGAllDayHeartbeatInterval * NSEC_PER_SEC),
                              (uint64_t)(10.0 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(sLGAllDayProfilingTimer, ^{
        LGAppendAllDayProfilerHeartbeat(@"timer");
    });
    dispatch_resume(sLGAllDayProfilingTimer);

    [[NSNotificationCenter defaultCenter] addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                                                      object:NSProcessInfo.processInfo
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *note) {
        LGAppendAllDayProfilerHeartbeat(@"thermal-change");
    }];
}

static void LGTrimLogFileIfNeeded(NSString *path, NSUInteger incomingLength) {
    if (!path.length || incomingLength == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary<NSFileAttributeKey, id> *attributes = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long currentSize = attributes.fileSize;
    if (currentSize + incomingLength <= kLGLogMaxFileSize) return;

    LGCloseLogHandle();

    NSData *existingData = [NSData dataWithContentsOfFile:path];
    NSUInteger keepLength = (NSUInteger)MIN((unsigned long long)existingData.length, kLGLogMaxFileSize / 2ULL);
    NSData *tailData = keepLength > 0 ? [existingData subdataWithRange:NSMakeRange(existingData.length - keepLength, keepLength)] : NSData.data;
    NSMutableData *trimmedData = [NSMutableData data];
    NSString *marker = [NSString stringWithFormat:@"[LiquidAss] log truncated at %@\n", [NSDate date]];
    NSData *markerData = [marker dataUsingEncoding:NSUTF8StringEncoding];
    if (markerData.length) [trimmedData appendData:markerData];
    if (tailData.length) [trimmedData appendData:tailData];
    [trimmedData writeToFile:path atomically:YES];
}

static void LGAppendLogLine(NSString *line, BOOL capped) {
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
        if (capped) {
            LGTrimLogFileIfNeeded(path, data.length);
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

static void LGScheduleDynamicDefaultFlush(void) {
    dispatch_queue_t queue = LGPrefsWriteQueue();
    dispatch_async(queue, ^{
        if (sLGDynamicDefaultFlushScheduled) return;
        sLGDynamicDefaultFlushScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLGDynamicDefaultFlushDelay * NSEC_PER_SEC)),
                       queue, ^{
            NSDictionary<NSString *, NSNumber *> *pending = [sLGPendingDynamicDefaultWrites copy];
            sLGPendingDynamicDefaultWrites = nil;
            sLGDynamicDefaultFlushScheduled = NO;
            if (!pending.count) return;

            for (NSString *key in pending) {
                NSNumber *value = pending[key];
                if (!key.length || !value) continue;
                CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                         (__bridge CFPropertyListRef)value,
                                         (__bridge CFStringRef)LGPrefsDomain);
            }
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        });
    });
}

static NSString *LGDynamicDefaultKey(NSString *key) {
    if (!key.length) return nil;
    return [kLGDynamicDefaultPrefix stringByAppendingString:key];
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

NSArray<UIWindow *> *LGApplicationWindows(UIApplication *app) {
    if (!app) return @[];

    if (@available(iOS 13.0, *)) {
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        return windows;
    }

    NSArray<UIWindow *> *windows = [app windows];
    return [windows isKindOfClass:[NSArray class]] ? windows : @[];
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

CGFloat LGDynamicDefaultFloat(NSString *key, CGFloat fallback) {
    NSString *dynamicKey = LGDynamicDefaultKey(key);
    if (!dynamicKey.length) return fallback;
    return LG_prefFloat(dynamicKey, fallback);
}

void LGCacheDynamicDefaultFloat(NSString *key, CGFloat value) {
    if (!key.length) return;
    if (!isfinite(value) || value <= 0.0) return;

    NSString *dynamicKey = LGDynamicDefaultKey(key);
    if (!dynamicKey.length) return;

    CGFloat existing = LG_prefFloat(dynamicKey, -1.0);
    if (fabs(existing - value) <= 0.01) return;

    NSNumber *boxedValue = @(value);
    os_unfair_lock_lock(&sLGPrefsLock);
    NSMutableDictionary<NSString *, id> *mutablePrefs = [sLGCachedPreferences mutableCopy] ?: [NSMutableDictionary dictionary];
    mutablePrefs[dynamicKey] = boxedValue;
    sLGCachedPreferences = [mutablePrefs copy];
    os_unfair_lock_unlock(&sLGPrefsLock);

    dispatch_async(LGPrefsWriteQueue(), ^{
        if (!sLGPendingDynamicDefaultWrites) {
            sLGPendingDynamicDefaultWrites = [NSMutableDictionary dictionary];
        }
        sLGPendingDynamicDefaultWrites[dynamicKey] = boxedValue;
        LGScheduleDynamicDefaultFlush();
    });
}

NSString *LGDefaultRenderingModeForKey(NSString *key) {
    if ([key isEqualToString:@"Banner.RenderingMode"] ||
        [key isEqualToString:@"ControlCenter.RenderingMode"] ||
        ([key hasPrefix:@"CustomViews.Rule."] && [key hasSuffix:@".RenderingMode"])) {
        // Dynamic backgrounds: prefer the render-server material over the
        // per-frame capture pipeline whenever the CA private API is present.
        return LG_serverMaterialAvailable() ? LGRenderingModeServer : LGRenderingModeLiveCapture;
    }
    return LGRenderingModeSnapshot;
}

BOOL LG_globalEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO);
}

BOOL LG_prefersLiveCapture(NSString *key) {
    return [LG_prefString(key, LGDefaultRenderingModeForKey(key)) isEqualToString:LGRenderingModeLiveCapture];
}

BOOL LG_serverMaterialAvailable(void) {
    static BOOL classesPresent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classesPresent = NSClassFromString(@"CABackdropLayer") != nil &&
                         NSClassFromString(@"CAFilter") != nil;
    });
    return classesPresent && LG_prefBool(@"ServerMaterial.Enabled", YES);
}

BOOL LG_prefersServerMaterial(NSString *key) {
    if (!LG_serverMaterialAvailable()) return NO;
    return [LG_prefString(key, LGDefaultRenderingModeForKey(key)) isEqualToString:LGRenderingModeServer];
}

void LGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message], YES);
}

void LGDebugLog(NSString *format, ...) {
    if (!LG_prefBool(@"DebugLogging.Enabled", NO)) {
        (void)format;
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message], NO);
}

void LGAssertMainThread(void) {
    NSCAssert([NSThread isMainThread], @"liquidass main thread only");
}

BOOL LGProfilingEnabled(void) {
    return LG_prefBool(@"DebugProfiling.Enabled", NO) || LGAllDayProfilingEnabled();
}

CFTimeInterval LGProfileBegin(void) {
    if (!LGProfilingEnabled()) return 0.0;
    return CACurrentMediaTime();
}

void LGProfileEnd(NSString *key, CFTimeInterval startTime) {
    if (startTime <= 0.0 || !key.length || !LGProfilingEnabled()) return;

    BOOL debugProfiling = LG_prefBool(@"DebugProfiling.Enabled", NO);
    BOOL allDayProfiling = LGAllDayProfilingEnabled();
    CFTimeInterval flushInterval = allDayProfiling ? kLGAllDayProfileFlushInterval : kLGProfileFlushInterval;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - startTime;
    if (elapsed < 0.0) elapsed = 0.0;

    NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *snapshot = nil;
    CFTimeInterval windowDuration = 0.0;

    os_unfair_lock_lock(&sLGProfileLock);
    if (!sLGProfileStats) {
        sLGProfileStats = [NSMutableDictionary dictionary];
    }
    if (sLGProfileWindowStart <= 0.0) {
        sLGProfileWindowStart = now;
    }

    NSMutableDictionary<NSString *, NSNumber *> *bucket = sLGProfileStats[key];
    if (!bucket) {
        bucket = [@{@"count": @0, @"total": @0.0, @"max": @0.0} mutableCopy];
        sLGProfileStats[key] = bucket;
    }

    NSUInteger count = bucket[@"count"].unsignedIntegerValue + 1;
    double total = bucket[@"total"].doubleValue + elapsed;
    double maxValue = MAX(bucket[@"max"].doubleValue, elapsed);
    bucket[@"count"] = @(count);
    bucket[@"total"] = @(total);
    bucket[@"max"] = @(maxValue);

    windowDuration = now - sLGProfileWindowStart;
    if (windowDuration >= flushInterval && sLGProfileStats.count > 0) {
        snapshot = [sLGProfileStats copy];
        [sLGProfileStats removeAllObjects];
        sLGProfileWindowStart = now;
    }
    os_unfair_lock_unlock(&sLGProfileLock);

    if (!snapshot.count || windowDuration <= 0.0) return;

    NSArray<NSString *> *sortedKeys = [snapshot keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary<NSString *, NSNumber *> *lhs,
                                                                                                     NSDictionary<NSString *, NSNumber *> *rhs) {
        return [rhs[@"total"] compare:lhs[@"total"]];
    }];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:sortedKeys.count];
    for (NSString *bucketKey in sortedKeys) {
        NSDictionary<NSString *, NSNumber *> *stats = snapshot[bucketKey];
        double totalMs = stats[@"total"].doubleValue * 1000.0;
        double maxMs = stats[@"max"].doubleValue * 1000.0;
        NSUInteger countValue = stats[@"count"].unsignedIntegerValue;
        double avgMs = countValue > 0 ? totalMs / (double)countValue : 0.0;
        double cps = windowDuration > 0.0 ? (double)countValue / windowDuration : 0.0;
        [parts addObject:[NSString stringWithFormat:@"%@ avg=%.2fms max=%.2fms count=%lu cps=%.1f total=%.2fms",
                          bucketKey,
                          avgMs,
                          maxMs,
                          (unsigned long)countValue,
                          cps,
                          totalMs]];
    }
    NSString *summary = [parts componentsJoinedByString:@" | "];
    if (debugProfiling) {
        LGLog(@"profile window=%.2fs %@", windowDuration, summary);
    }
    if (allDayProfiling) {
        LGAppendProfilingLogLine([NSString stringWithFormat:
            @"[LiquidAssProfiler] profile date=%@ window=%.2fs %@\n",
            [NSDate date],
            windowDuration,
            summary]);
    }
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

@implementation LGTextureCacheEntry
@end

@implementation LGBlurVariant
@end

@interface LGZeroCopyBridge ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
@end

@implementation LGZeroCopyBridge

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    CVMetalTextureCacheRef cache = NULL;
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache);
    if (status == kCVReturnSuccess) {
        _textureCache = cache;
    }
    return self;
}

- (void)dealloc {
    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (!_textureCache || !width || !height) return NO;

    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs,
                                          &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) return NO;

    CVMetalTextureRef cvTexture = NULL;
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _textureCache,
                                                       _pixelBuffer,
                                                       nil,
                                                       MTLPixelFormatBGRA8Unorm,
                                                       width,
                                                       height,
                                                       0,
                                                       &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return NO;
    _cvTexture = cvTexture;
    return YES;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer || !_textureCache || !_cvTexture) return nil;

    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t width = CVPixelBufferGetWidth(_pixelBuffer);
    size_t height = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);

    CGContextRef context = CGBitmapContextCreate(data,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 LGSharedRGBColorSpace(),
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!context) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
        return nil;
    }

    if (actions) actions(context);

    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}

- (size_t)bufferWidth {
    return _pixelBuffer ? CVPixelBufferGetWidth(_pixelBuffer) : 0;
}

- (size_t)bufferHeight {
    return _pixelBuffer ? CVPixelBufferGetHeight(_pixelBuffer) : 0;
}

@end

id<MTLLibrary> LGCreateGlassLibrary(id<MTLDevice> device, NSError **error) {
    if (!device) return nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    id<MTLLibrary> library = [device newLibraryWithSource:LGGlassMetalSource()
                                                  options:options
                                                    error:error];
    return library;
}

id<MTLRenderPipelineState> LGCreateGlassRenderPipeline(id<MTLDevice> device,
                                                       id<MTLLibrary> library,
                                                       NSError **error) {
    if (!device || !library) return nil;
    id<MTLFunction> vertex = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"fragmentShader"];
    if (!vertex || !fragment) return nil;

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    color.blendingEnabled = YES;
    color.rgbBlendOperation = MTLBlendOperationAdd;
    color.alphaBlendOperation = MTLBlendOperationAdd;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return [device newRenderPipelineStateWithDescriptor:descriptor error:error];
}
