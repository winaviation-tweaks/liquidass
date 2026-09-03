

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdio.h>
#import <stdarg.h>
#import <stdint.h>
#import "Shared/LGSharedSupport.h"

#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone                   = 0,
    SBSRelaunchActionOptionsRestartRenderServer    = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition     = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition  = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

static NSString * const kLGRespringNote = @"dylv.liquidassprefs/Respring";
static NSString * const kLGSafeModeNote = @"dylv.liquidass/BackboarddSafeMode";
static const char *kLGSafeModePendingPath =
    "/var/mobile/Library/Accessibility/liquidass-backboardd-alert";
static UIWindow *sLGSafeModeAlertWindow = nil;
static BOOL sLGSavedDiagnosticsThisLaunch = NO;

typedef struct __attribute__((packed)) {
    uint32_t signature;
    uint16_t version;
    uint16_t flags;
    uint16_t compression;
    uint16_t time;
    uint16_t date;
    uint32_t crc;
    uint32_t compressedSize;
    uint32_t size;
    uint16_t nameLength;
    uint16_t extraLength;
} LGZipLocalHeader;

typedef struct __attribute__((packed)) {
    uint32_t signature;
    uint16_t madeBy;
    uint16_t version;
    uint16_t flags;
    uint16_t compression;
    uint16_t time;
    uint16_t date;
    uint32_t crc;
    uint32_t compressedSize;
    uint32_t size;
    uint16_t nameLength;
    uint16_t extraLength;
    uint16_t commentLength;
    uint16_t disk;
    uint16_t internalAttributes;
    uint32_t externalAttributes;
    uint32_t localOffset;
} LGZipCentralHeader;

typedef struct __attribute__((packed)) {
    uint32_t signature;
    uint16_t disk;
    uint16_t centralDisk;
    uint16_t diskEntries;
    uint16_t entries;
    uint32_t centralSize;
    uint32_t centralOffset;
    uint16_t commentLength;
} LGZipEndRecord;

static uint32_t LG_zipCRC32(NSData *data) {
    uint32_t crc = UINT32_MAX;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        crc ^= bytes[index];
        for (NSUInteger bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320u & (uint32_t)-(int32_t)(crc & 1));
    }
    return ~crc;
}

static NSString *LG_latestBackboardCrashPath(void) {
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/var/mobile/Library/Logs/DiagnosticReports",
        @"/Library/Logs/CrashReporter"
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *newestPath = nil;
    NSDate *newestDate = nil;
    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSString *> *enumerator =
            [manager enumeratorAtPath:root];
        for (NSString *relativePath in enumerator) {
            NSString *name = relativePath.lastPathComponent.lowercaseString;
            if (![name containsString:@"backboardd"] ||
                (![[name pathExtension] isEqualToString:@"ips"] &&
                 ![[name pathExtension] isEqualToString:@"crash"])) continue;
            NSString *path = [root stringByAppendingPathComponent:relativePath];
            NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
            NSDate *date = attributes[NSFileModificationDate];
            if (!newestDate || [date compare:newestDate] == NSOrderedDescending) {
                newestDate = date;
                newestPath = path;
            }
        }
    }
    return newestPath;
}

static NSURL *LG_createDiagnosticsArchive(void) {
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    NSArray<NSString *> *logPaths = @[
        @"/var/mobile/Library/Accessibility/liquidglass.log",
        @"/var/mobile/Library/Accessibility/liquidass-safemode.log"
    ];
    for (NSString *path in logPaths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) [files addObject:@{ @"name": path.lastPathComponent, @"data": data }];
    }
    NSString *crashPath = LG_latestBackboardCrashPath();
    NSData *crashData = crashPath ? [NSData dataWithContentsOfFile:crashPath] : nil;
    if (crashData)
        [files addObject:@{ @"name": crashPath.lastPathComponent, @"data": crashData }];
    if (!files.count) return nil;

    NSMutableData *archive = [NSMutableData data];
    NSMutableArray<NSDictionary *> *centralEntries = [NSMutableArray array];
    for (NSDictionary *file in files) {
        NSData *name = [file[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *data = file[@"data"];
        if (name.length > UINT16_MAX || data.length > UINT32_MAX) continue;
        uint32_t offset = (uint32_t)archive.length;
        uint32_t crc = LG_zipCRC32(data);
        LGZipLocalHeader header = {
            .signature = 0x04034b50, .version = 20,
            .crc = crc, .compressedSize = (uint32_t)data.length,
            .size = (uint32_t)data.length, .nameLength = (uint16_t)name.length
        };
        [archive appendBytes:&header length:sizeof(header)];
        [archive appendData:name];
        [archive appendData:data];
        [centralEntries addObject:@{
            @"name": name, @"crc": @(crc), @"size": @((uint32_t)data.length),
            @"offset": @(offset)
        }];
    }

    uint32_t centralOffset = (uint32_t)archive.length;
    for (NSDictionary *entry in centralEntries) {
        NSData *name = entry[@"name"];
        LGZipCentralHeader header = {
            .signature = 0x02014b50, .madeBy = 20, .version = 20,
            .crc = [entry[@"crc"] unsignedIntValue],
            .compressedSize = [entry[@"size"] unsignedIntValue],
            .size = [entry[@"size"] unsignedIntValue],
            .nameLength = (uint16_t)name.length,
            .localOffset = [entry[@"offset"] unsignedIntValue]
        };
        [archive appendBytes:&header length:sizeof(header)];
        [archive appendData:name];
    }
    uint32_t centralSize = (uint32_t)archive.length - centralOffset;
    LGZipEndRecord end = {
        .signature = 0x06054b50,
        .diskEntries = (uint16_t)centralEntries.count,
        .entries = (uint16_t)centralEntries.count,
        .centralSize = centralSize, .centralOffset = centralOffset
    };
    [archive appendBytes:&end length:sizeof(end)];

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"LiquidAss-Diagnostics-%@.zip",
                      [formatter stringFromDate:NSDate.date]];
    NSString *path = [@"/var/mobile/Documents"
        stringByAppendingPathComponent:name];
    return [archive writeToFile:path atomically:YES] ? [NSURL fileURLWithPath:path] : nil;
}

static void LG_safeModeAlertLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    FILE *file = fopen("/var/mobile/Library/Accessibility/liquidass-safemode.log", "a");
    if (!file) return;
    fprintf(file, "springboard alert: %s\n", message.UTF8String ?: "");
    fclose(file);
}

static void LG_requestRespring(void) {
    static const char * const processNames[] = {
        "chronod",
        "WidgetRenderer_Default",
        "WidgetRenderer_CarPlay",
        "backboardd",
        NULL,
    };

    int pidBufferSize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (pidBufferSize > 0) {
        NSMutableData *pidData = [NSMutableData dataWithLength:(NSUInteger)pidBufferSize];
        int bytesReturned = proc_listpids(PROC_ALL_PIDS, 0,
                                          pidData.mutableBytes, (int)pidData.length);
        if (bytesReturned > 0) {
            pid_t *pids = (pid_t *)pidData.bytes;
            int pidCount = bytesReturned / (int)sizeof(pid_t);
            for (int i = 0; i < pidCount; i++) {
                pid_t pid = pids[i];
                if (pid <= 0 || pid == getpid()) continue;

                char processName[PROC_PIDPATHINFO_MAXSIZE];
                memset(processName, 0, sizeof(processName));
                if (proc_name(pid, processName, sizeof(processName)) <= 0) continue;

                for (NSUInteger nameIndex = 0; processNames[nameIndex]; nameIndex++) {
                    if (strcmp(processName, processNames[nameIndex]) != 0) continue;
                    if (kill(pid, SIGTERM) != 0) {
                        LGLog(@"respring: failed to terminate %s pid %d errno %d",
                              processName, pid, errno);
                    }
                    break;
                }
            }
        }
    }

    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass  = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;

    SBSRelaunchAction *restart =
        [actionClass actionWithReason:@"LiquidAss"
                              options:(SBSRelaunchActionOptionsRestartRenderServer |
                                       SBSRelaunchActionOptionsFadeToBlackTransition)
                            targetURL:nil];
    if (!restart) return;
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restart] withResult:nil];
}

static void LG_respringRequested(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ LG_requestRespring(); });
}

static UIViewController *LG_topPresentedController(UIViewController *controller) {
    while (controller.presentedViewController)
        controller = controller.presentedViewController;
    return controller;
}

static void LG_closeSafeModeAlert(void) {
    sLGSafeModeAlertWindow = nil;
}

static void LG_showSafeModeAlertIfNeeded(void) {
    BOOL pending = access(kLGSafeModePendingPath, F_OK) == 0;
    BOOL safeMode = LGBackboardSafeModeActive();
    LG_safeModeAlertLog(@"show requested pending=%d safeMode=%d existing=%@",
                        pending, safeMode, sLGSafeModeAlertWindow);
    if ((!pending && !safeMode) || sLGSafeModeAlertWindow) return;

    if (pending && !sLGSavedDiagnosticsThisLaunch) {
        sLGSavedDiagnosticsThisLaunch = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSURL *archiveURL = LG_createDiagnosticsArchive();
            LG_safeModeAlertLog(@"saved archive=%@", archiveURL.path);
        });
    }

    UIViewController *root = nil;
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            LG_safeModeAlertLog(@"scene=%@ class=%@ state=%ld",
                                scene.session.persistentIdentifier,
                                NSStringFromClass(scene.class),
                                (long)scene.activationState);
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UIWindow *visibleKeyWindow = nil;
            for (UIWindow *candidate in windowScene.windows) {
                NSString *className = NSStringFromClass(candidate.class);
                LG_safeModeAlertLog(@"window scene=%@ class=%@ level=%.1f hidden=%d alpha=%.2f key=%d frame=%@",
                                    scene.session.persistentIdentifier, className,
                                    candidate.windowLevel, candidate.hidden, candidate.alpha,
                                    candidate.isKeyWindow, NSStringFromCGRect(candidate.frame));
                if (candidate.hidden || candidate.alpha <= 0.0 ||
                    !candidate.rootViewController) continue;
                if (candidate.isKeyWindow) visibleKeyWindow = candidate;
                if (![className containsString:@"SBCoverSheetWindow"]) continue;
                LG_safeModeAlertLog(@"selected coversheet scene=%@ window=%@",
                                    scene.session.persistentIdentifier, candidate);
                window = candidate;
                root = LG_topPresentedController(candidate.rootViewController);
                break;
            }
            if (!window && visibleKeyWindow) {
                LG_safeModeAlertLog(@"selected visible key window scene=%@ class=%@ window=%@",
                                    scene.session.persistentIdentifier,
                                    NSStringFromClass(visibleKeyWindow.class),
                                    visibleKeyWindow);
                window = visibleKeyWindow;
                root = LG_topPresentedController(visibleKeyWindow.rootViewController);
            }
            if (window) break;
        }
    }
    if (!window) {
        LG_safeModeAlertLog(@"no visible presentation host yet; retrying");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ LG_showSafeModeAlertIfNeeded(); });
        return;
    }
    sLGSafeModeAlertWindow = window;
    LG_safeModeAlertLog(@"presentation host scene=%@ level=%.1f hidden=%d key=%d root=%@ frame=%@",
                        window.windowScene.session.persistentIdentifier,
                        window.windowLevel, window.hidden, window.isKeyWindow,
                        root,
                        NSStringFromCGRect(window.frame));

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Liquid (Gl)ass Safe Mode"
        message:@"Liquid (Gl)ass has detected a backboardd crash loop and disabled the core tweak. Please go to [Settings > Liquid (Gl)ass > More Options], scroll down and use [Export Logs] then share the crash logs to @winaviation on Discord or u/WinsAviation on Reddit."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        LG_closeSafeModeAlert();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Exit Safe Mode"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        LGClearBackboardSafeMode();
        LG_closeSafeModeAlert();
        LG_requestRespring();
    }]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        LG_safeModeAlertLog(@"presentation check rootWindow=%@ overlay=%@ expected=%@",
                            root.view.window, sLGSafeModeAlertWindow, window);
        if (!root.view.window || sLGSafeModeAlertWindow != window) {
            LG_safeModeAlertLog(@"presentation aborted");
            LG_closeSafeModeAlert();
            return;
        }
        [root presentViewController:alert animated:YES completion:^{
            LG_safeModeAlertLog(@"presentation completed alertWindow=%@ alertViewWindow=%@ frame=%@",
                                alert.view.window, alert.view.window,
                                NSStringFromCGRect(alert.view.frame));
            unlink(kLGSafeModePendingPath);
        }];
    });
}

static void LG_safeModeTriggered(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ LG_showSafeModeAlertIfNeeded(); });
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LG_respringRequested, (__bridge CFStringRef)kLGRespringNote,
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LG_safeModeTriggered,
                                    (__bridge CFStringRef)kLGSafeModeNote,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ LG_showSafeModeAlertIfNeeded(); });
}
