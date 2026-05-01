// creds to OwnGoalStudio's Remove Widget Background

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL kIsEnabled = YES;
static BOOL kIsEnabledForSystemWidgets = YES;
static BOOL kIsEnabledForMaterialView = NO;
static BOOL kForceDarkMode = YES;
static CGFloat kMaxWidgetWidth = 140.0;
static CGFloat kMaxWidgetHeight = 140.0;
static NSSet<NSString *> *kWidgetBundleIdentifiers = nil;

static NSArray<NSString *> *RWBParseThirdPartyBundleIDs(NSString *rawText) {
    if (![rawText isKindOfClass:[NSString class]] || rawText.length == 0) return @[];
    NSMutableOrderedSet<NSString *> *bundleIDs = [NSMutableOrderedSet orderedSet];
    [[rawText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] enumerateObjectsUsingBlock:^(NSString *rawLine, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) return;
        [bundleIDs addObject:line];
    }];
    return bundleIDs.array;
}

static void RWBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAssRWB] %@", body);
}

static void ReloadPrefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"dylv.liquidassprefs"];
    });

    NSDictionary *settings = prefs.dictionaryRepresentation ?: @{};
    NSNumber *globalEnabled = settings[@"Global.Enabled"];
    NSNumber *widgetEnabled = settings[@"Widgets.Enabled"];
    kIsEnabled = (globalEnabled ? globalEnabled.boolValue : NO) && (widgetEnabled ? widgetEnabled.boolValue : NO);
    kIsEnabledForSystemWidgets = YES;
    kIsEnabledForMaterialView = NO;
    kForceDarkMode = YES;
    kMaxWidgetWidth = 140.0;
    kMaxWidgetHeight = 140.0;

    NSMutableOrderedSet<NSString *> *bundleIDs = [NSMutableOrderedSet orderedSetWithArray:@[
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
        @"com.apple.Maps.GeneralMapsWidget"
    ]];
    [bundleIDs addObjectsFromArray:RWBParseThirdPartyBundleIDs(settings[@"RWB.ThirdPartyBundleIDs"])];
    kWidgetBundleIdentifiers = [NSSet setWithArray:bundleIDs.array];

    RWBLog(@"reload enabled=%d maxWidth=%.1f maxHeight=%.1f bundleCount=%lu", kIsEnabled, kMaxWidgetWidth, kMaxWidgetHeight, (unsigned long)kWidgetBundleIdentifiers.count);
}

static void RWBReloadPrefsCallback(CFNotificationCenterRef __unused center,
                                   void * __unused observer,
                                   CFStringRef __unused name,
                                   const void * __unused object,
                                   CFDictionaryRef __unused userInfo) {
    ReloadPrefs();
}

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetScene : UIWindowScene
@property (nonatomic, copy, readonly) CHSWidget *widget;
@end

@interface CHUISAvocadoWindowScene : UIWindowScene
@property (nonatomic, copy, readonly) CHSWidget *widget;
@end

@interface UIWindow (LiquidAssRWB)
@property (nonatomic, strong) NSNumber *rwb_shouldHideBackground;
@end

@interface RBLayer : CALayer
@end

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface SBHWidgetStackViewController : UIViewController
@end

@interface WGWidgetListItemViewController : UIViewController
@end

@interface CHSMutableScreenshotPresentationAttributes : NSObject
@end

@interface CHSScreenshotPresentationAttributes : NSObject
@end

static BOOL ShouldHandleWidget(NSString *bundleIdentifier) {
    return kIsEnabled && bundleIdentifier.length > 0 && [kWidgetBundleIdentifiers containsObject:bundleIdentifier];
}

%group RWBSpringBoard

%hook CHUISAvocadoHostViewController

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (id)screenshotManager {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return nil;
    return %orig;
}

%end

%hook CHUISWidgetHostViewController

- (unsigned long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (void)_updatePersistedSnapshotContent {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (void)_updatePersistedSnapshotContentIfNecessary {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (id)_snapshotImageFromURL:(id)arg1 {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return nil;
    return %orig;
}

%end

%hook SBHWidgetStackViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabledForMaterialView) return;
    UIView *firstChild = ((UIViewController *)self).view.subviews.firstObject;
    firstChild = firstChild.subviews.firstObject;
    if ([NSStringFromClass(firstChild.class) isEqualToString:@"MTMaterialView"]) {
        firstChild.alpha = 0.0;
    }
}

%end

%hook WGWidgetListItemViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabledForMaterialView) return;
    UIView *firstChild = ((UIViewController *)self).view.subviews.firstObject;
    if ([NSStringFromClass(firstChild.class) isEqualToString:@"MTMaterialView"]) {
        firstChild.alpha = 0.0;
    }
}

%end

%end

%group RWB

%hook UIWindow

%property (nonatomic, strong) NSNumber *rwb_shouldHideBackground;

- (UIWindow *)initWithWindowScene:(UIWindowScene *)scene {
    if ([scene isKindOfClass:%c(CHUISAvocadoWindowScene)]) {
        CHUISAvocadoWindowScene *avocadoScene = (CHUISAvocadoWindowScene *)scene;
        if (ShouldHandleWidget(avocadoScene.widget.extensionBundleIdentifier)) {
            self.rwb_shouldHideBackground = @YES;
        }
    } else if ([scene isKindOfClass:%c(CHUISWidgetScene)]) {
        CHUISWidgetScene *widgetScene = (CHUISWidgetScene *)scene;
        if (ShouldHandleWidget(widgetScene.widget.extensionBundleIdentifier)) {
            self.rwb_shouldHideBackground = @YES;
        }
    }
    UIWindow *window = %orig;
    if (window && kIsEnabled && kForceDarkMode) {
        [window setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    }
    return window;
}

%end

%hook CHUISWidgetScene

- (unsigned long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook CHSMutableScreenshotPresentationAttributes

- (long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook CHSScreenshotPresentationAttributes

- (long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook UIView

- (void)layoutSubviews {
    %orig;
    if (!kIsEnabled) return;
    if (![NSStringFromClass([self class]) containsString:@"UIHostingView"]) {
        self.backgroundColor = UIColor.clearColor;
    }
}

%end

%hook RBLayer

- (void)display {
    UIView *view = (UIView *)self.delegate;

    if (kIsEnabled && [view isKindOfClass:[UIView class]] && view.window.rwb_shouldHideBackground.boolValue) {
        NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
        threadDict[@"rwb_shouldHideBackground"] = @YES;
        if (@available(iOS 17, *)) {
            if (self.opaque) self.opaque = NO;
        }

        %orig;

        [threadDict removeObjectForKey:@"rwb_shouldHideBackground"];
        if (@available(iOS 17, *)) {
            [threadDict removeObjectForKey:@"rwb_didSkipFirstN"];
        } else {
            [threadDict removeObjectForKey:@"rwb_didSkipFirst"];
        }
        return;
    }

    %orig;
}

%end

%end

%group RWB_15

%hook RBShape

- (void)setRect:(CGRect)rect {
    if (kIsEnabled && [NSThread currentThread].threadDictionary[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            %orig(CGRectZero);
            return;
        }
    }
    %orig;
}

%end

%hook UISCurrentUserInterfaceStyleValue

- (long long)userInterfaceStyle {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%end

%group RWB_16

%hook RBShape

- (void)setRect:(CGRect)rect {
    NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
    if (kIsEnabled && threadDict[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            if ([threadDict[@"rwb_didSkipFirst"] boolValue]) {
                %orig(CGRectZero);
                return;
            }
            threadDict[@"rwb_didSkipFirst"] = @YES;
        }
    }
    %orig;
}

%end

%end

%group RWB_17

%hook RBShape

- (void)setRect:(CGRect)rect {
    NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
    if (kIsEnabled && threadDict[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            NSNumber *firstN = threadDict[@"rwb_didSkipFirstN"];
            if ([firstN intValue] > 1) {
                %orig(CGRectZero);
                return;
            }
            int newN = firstN ? [firstN intValue] + 1 : 0;
            threadDict[@"rwb_didSkipFirstN"] = @(newN);
            if (newN == 1) {
                %orig(CGRectZero);
                return;
            }
        }
    }
    %orig;
}

%end

%end

%ctor {
    ReloadPrefs();
    if (!kIsEnabled) return;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    RWBReloadPrefsCallback,
                                    CFSTR("dylv.liquidassprefs/Reload"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        RWBLog(@"initialized in SpringBoard");
        %init(RWBSpringBoard);
    } else if ([bundleIdentifier isEqualToString:@"com.apple.chronod"] ||
               [bundleIdentifier hasPrefix:@"com.apple.chrono.WidgetRenderer-"]) {
        RWBLog(@"initialized in chronod/widget renderer");
        %init(RWB);
        if (@available(iOS 17, *)) {
            %init(RWB_17);
        } else if (@available(iOS 16, *)) {
            %init(RWB_16);
        } else {
            %init(RWB_15);
        }
    }
}
