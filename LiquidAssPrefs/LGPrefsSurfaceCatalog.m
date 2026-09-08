#import "LGPrefsSurfaceCatalog.h"
#import "LGPrefsDataSupport.h"
#import "../Shared/LGSharedSupport.h"

NSString * const LGPrefsSurfaceHomescreen = @"Homescreen";
NSString * const LGPrefsSurfaceLockscreen = @"Lockscreen";
NSString * const LGPrefsSurfaceAppLibrary = @"AppLibrary";
NSString * const LGPrefsSurfaceSurfaces = @"Surfaces";
NSString * const LGPrefsSurfaceDock = @"Dock";
NSString * const LGPrefsSurfaceFolderIcons = @"FolderIcons";
NSString * const LGPrefsSurfaceAppIcons = @"AppIcons";
NSString * const LGPrefsSurfaceOpenFolder = @"OpenFolder";
NSString * const LGPrefsSurfaceContextMenu = @"ContextMenu";
NSString * const LGPrefsSurfaceBanner = @"Banner";
NSString * const LGPrefsSurfaceAlerts = @"Alerts";
NSString * const LGPrefsSurfaceControlCenter = @"ControlCenter";
NSString * const LGPrefsSurfaceSearchPill = @"SearchPill";
NSString * const LGPrefsSurfaceSpotlight = @"Spotlight";
NSString * const LGPrefsSurfaceWidgets = @"Widgets";
NSString * const LGPrefsSurfaceAppLibraryPods = @"AppLibraryPods";
NSString * const LGPrefsSurfaceAppLibrarySearch = @"AppLibrarySearch";
NSString * const LGPrefsSurfaceNotifications = @"Notifications";
NSString * const LGPrefsSurfaceQuickActions = @"QuickActions";
NSString * const LGPrefsSurfacePasscode = @"Passcode";
NSString * const LGPrefsSurfaceClock = @"Clock";
NSString * const LGPrefsSurfaceCoverSheet = @"CoverSheet";
NSString * const LGPrefsSurfaceKeyboard = @"Keyboard";
NSString * const LGPrefsSurfaceTabBar = @"TabBar";
NSString * const LGPrefsSurfaceAssistiveTouch = @"AssistiveTouch";
NSString * const LGPrefsSurfaceVolumeHUD = @"VolumeHUD";
NSString * const LGPrefsSurfacePillHUD = @"PillHUD";
NSString * const LGPrefsSurfaceGlobalControls = @"GlobalControls";
NSString * const LGPrefsSurfaceMoreOptions = @"MoreOptions";
NSString * const LGPrefsSurfaceSettings = @"PrefsSettings";

BOOL LGPrefsSurfaceIsKnown(NSString *identifier) {
    return [identifier isEqualToString:LGPrefsSurfaceHomescreen] ||
           [identifier isEqualToString:LGPrefsSurfaceLockscreen] ||
           [identifier isEqualToString:LGPrefsSurfaceAppLibrary] ||
           [identifier isEqualToString:LGPrefsSurfaceSurfaces] ||
           [identifier isEqualToString:LGPrefsSurfaceDock] ||
           [identifier isEqualToString:LGPrefsSurfaceFolderIcons] ||
           [identifier isEqualToString:LGPrefsSurfaceAppIcons] ||
           [identifier isEqualToString:LGPrefsSurfaceOpenFolder] ||
           [identifier isEqualToString:LGPrefsSurfaceContextMenu] ||
           [identifier isEqualToString:LGPrefsSurfaceBanner] ||
           [identifier isEqualToString:LGPrefsSurfaceAlerts] ||
           [identifier isEqualToString:LGPrefsSurfaceControlCenter] ||
           [identifier isEqualToString:LGPrefsSurfaceSearchPill] ||
           [identifier isEqualToString:LGPrefsSurfaceSpotlight] ||
           [identifier isEqualToString:LGPrefsSurfaceWidgets] ||
           [identifier isEqualToString:LGPrefsSurfaceAppLibraryPods] ||
           [identifier isEqualToString:LGPrefsSurfaceAppLibrarySearch] ||
           [identifier isEqualToString:LGPrefsSurfaceNotifications] ||
           [identifier isEqualToString:LGPrefsSurfaceQuickActions] ||
           [identifier isEqualToString:LGPrefsSurfacePasscode] ||
           [identifier isEqualToString:LGPrefsSurfaceClock] ||
           [identifier isEqualToString:LGPrefsSurfaceCoverSheet] ||
           [identifier isEqualToString:LGPrefsSurfaceKeyboard] ||
           [identifier isEqualToString:LGPrefsSurfaceTabBar] ||
           [identifier isEqualToString:LGPrefsSurfaceAssistiveTouch] ||
           [identifier isEqualToString:LGPrefsSurfaceVolumeHUD] ||
           [identifier isEqualToString:LGPrefsSurfacePillHUD] ||
           [identifier isEqualToString:LGPrefsSurfaceGlobalControls] ||
           [identifier isEqualToString:LGPrefsSurfaceMoreOptions] ||
           [identifier isEqualToString:LGPrefsSurfaceSettings];
}

NSString *LGPrefsSurfaceTitle(NSString *identifier) {
    if ([identifier isEqualToString:LGPrefsSurfaceHomescreen]) return LGLocalized(@"prefs.surface.homescreen.title");
    if ([identifier isEqualToString:LGPrefsSurfaceLockscreen]) return LGLocalized(@"prefs.surface.lockscreen.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrary]) return LGLocalized(@"prefs.surface.app_library.title");
    if ([identifier isEqualToString:LGPrefsSurfaceSurfaces]) return LGLocalized(@"prefs.surface.surfaces.title");
    if ([identifier isEqualToString:LGPrefsSurfaceDock]) return LGLocalized(@"prefs.section.dock.title");
    if ([identifier isEqualToString:LGPrefsSurfaceFolderIcons]) return LGLocalized(@"prefs.section.folder_icons.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAppIcons]) return LGLocalized(@"prefs.section.app_icons.title");
    if ([identifier isEqualToString:LGPrefsSurfaceOpenFolder]) return LGLocalized(@"prefs.section.folder_open.title");
    if ([identifier isEqualToString:LGPrefsSurfaceContextMenu]) return LGLocalized(@"prefs.section.context_menu.title");
    if ([identifier isEqualToString:LGPrefsSurfaceBanner]) return LGLocalized(@"prefs.section.banner.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAlerts]) return LGLocalized(@"prefs.section.alerts.title");
    if ([identifier isEqualToString:LGPrefsSurfaceControlCenter]) return LGLocalized(@"prefs.section.control_center.title");
    if ([identifier isEqualToString:LGPrefsSurfaceSearchPill]) return LGLocalized(@"prefs.section.search_pill.title");
    if ([identifier isEqualToString:LGPrefsSurfaceSpotlight]) return LGLocalized(@"prefs.section.spotlight.title");
    if ([identifier isEqualToString:LGPrefsSurfaceWidgets]) return LGLocalized(@"prefs.section.widgets.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibraryPods]) return LGLocalized(@"prefs.section.category_pods.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrarySearch]) return LGLocalized(@"prefs.section.search_field.title");
    if ([identifier isEqualToString:LGPrefsSurfaceNotifications]) return LGLocalized(@"prefs.section.lockscreen_notifications.title");
    if ([identifier isEqualToString:LGPrefsSurfaceQuickActions]) return LGLocalized(@"prefs.section.lockscreen_quick_actions.title");
    if ([identifier isEqualToString:LGPrefsSurfacePasscode]) return LGLocalized(@"prefs.section.lockscreen_passcode.title");
    if ([identifier isEqualToString:LGPrefsSurfaceClock]) return LGLocalized(@"prefs.section.lockscreen_clock.title");
    if ([identifier isEqualToString:LGPrefsSurfaceCoverSheet]) return LGLocalized(@"prefs.surface.coversheet.title");
    if ([identifier isEqualToString:LGPrefsSurfaceKeyboard]) return LGLocalized(@"prefs.surface.keyboard.title");
    if ([identifier isEqualToString:LGPrefsSurfaceTabBar]) return LGLocalized(@"prefs.surface.tab_bar.title");
    if ([identifier isEqualToString:LGPrefsSurfaceAssistiveTouch]) return LGLocalized(@"prefs.surface.assistive_touch.title");
    if ([identifier isEqualToString:LGPrefsSurfaceVolumeHUD]) return LGLocalized(@"prefs.surface.volume_hud.title");
    if ([identifier isEqualToString:LGPrefsSurfacePillHUD]) return LGLocalized(@"prefs.surface.pill_hud.title");
    if ([identifier isEqualToString:LGPrefsSurfaceGlobalControls]) return LGLocalized(@"prefs.surface.global_controls.title");
    if ([identifier isEqualToString:LGPrefsSurfaceMoreOptions]) return LGLocalized(@"prefs.misc.about.title");
    if ([identifier isEqualToString:LGPrefsSurfaceSettings]) return LGLocalized(@"prefs.misc.prefs_settings.title");
    return @"";
}

NSString *LGPrefsSurfaceSubtitle(NSString *identifier) {

    if ([identifier isEqualToString:LGPrefsSurfaceHomescreen]) return LGLocalized(@"prefs.surface.homescreen.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceLockscreen]) return LGLocalized(@"prefs.surface.lockscreen.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrary]) return LGLocalized(@"prefs.surface.app_library.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceSurfaces]) return LGLocalized(@"prefs.surface.surfaces.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceAssistiveTouch]) return LGLocalized(@"prefs.surface.assistive_touch.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceVolumeHUD]) return LGLocalized(@"prefs.surface.volume_hud.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfacePillHUD]) return LGLocalized(@"prefs.surface.pill_hud.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceMoreOptions]) return LGLocalized(@"prefs.misc.about.subtitle");
    if ([identifier isEqualToString:LGPrefsSurfaceSettings]) return LGLocalized(@"prefs.misc.prefs_settings.subtitle");
    return @"";
}

UIColor *LGPrefsSurfaceTintColor(NSString *identifier) {
    if ([identifier isEqualToString:LGPrefsSurfaceLockscreen]) return UIColor.systemRedColor;
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrary]) return UIColor.systemGreenColor;
    if ([identifier isEqualToString:LGPrefsSurfaceMoreOptions]) return UIColor.systemIndigoColor;
    if ([identifier isEqualToString:LGPrefsSurfaceSettings]) return UIColor.systemGrayColor;
    if ([identifier isEqualToString:LGPrefsSurfaceKeyboard]) return UIColor.systemOrangeColor;
    if ([identifier isEqualToString:LGPrefsSurfaceTabBar]) return UIColor.systemIndigoColor;
    if ([identifier isEqualToString:LGPrefsSurfaceAssistiveTouch]) return UIColor.systemPurpleColor;
    if ([identifier isEqualToString:LGPrefsSurfaceVolumeHUD]) return UIColor.systemYellowColor;
    if ([identifier isEqualToString:LGPrefsSurfacePillHUD]) return UIColor.systemRedColor;
    if ([identifier isEqualToString:LGPrefsSurfaceGlobalControls]) return UIColor.systemTealColor;
    if ([identifier isEqualToString:LGPrefsSurfaceControlCenter]) return UIColor.systemTealColor;
    return UIColor.systemBlueColor;
}

NSString *LGPrefsSurfaceSymbolName(NSString *identifier) {
    if ([identifier isEqualToString:LGPrefsSurfaceHomescreen]) return @"apps.iphone";
    if ([identifier isEqualToString:LGPrefsSurfaceLockscreen]) return @"lg.lockscreen.stacked";
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrary]) return @"square.grid.2x2.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceSurfaces]) return @"square.grid.2x2.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceDock]) return @"rectangle.bottomthird.inset.filled";
    if ([identifier isEqualToString:LGPrefsSurfaceFolderIcons]) return @"folder.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceAppIcons]) return @"app.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceOpenFolder]) return @"folder";
    if ([identifier isEqualToString:LGPrefsSurfaceContextMenu]) return @"ellipsis.circle";
    if ([identifier isEqualToString:LGPrefsSurfaceBanner]) return @"rectangle.topthird.inset.filled";
    if ([identifier isEqualToString:LGPrefsSurfaceAlerts]) return @"exclamationmark.bubble.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceControlCenter]) return @"switch.2";
    if ([identifier isEqualToString:LGPrefsSurfaceSearchPill]) return @"magnifyingglass";
    if ([identifier isEqualToString:LGPrefsSurfaceSpotlight]) return @"magnifyingglass.circle.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceWidgets]) return @"rectangle.3.group.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibraryPods]) return @"square.grid.2x2.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrarySearch]) return @"magnifyingglass";
    if ([identifier isEqualToString:LGPrefsSurfaceNotifications]) return @"bell.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceQuickActions]) return @"flashlight.on.fill";
    if ([identifier isEqualToString:LGPrefsSurfacePasscode]) return @"circle.grid.3x3.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceClock]) return @"clock.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceCoverSheet]) return @"hand.draw.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceKeyboard]) return @"keyboard.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceTabBar]) return @"rectangle.bottomthird.inset.filled";
    if ([identifier isEqualToString:LGPrefsSurfaceAssistiveTouch]) return @"hand.tap.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceVolumeHUD]) return @"speaker.wave.3.fill";
    if ([identifier isEqualToString:LGPrefsSurfacePillHUD]) return @"bell.badge.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceGlobalControls]) return @"slider.horizontal.3";
    if ([identifier isEqualToString:LGPrefsSurfaceMoreOptions]) return @"ellipsis.circle.fill";
    if ([identifier isEqualToString:LGPrefsSurfaceSettings]) return @"info.circle.fill";
    return @"circle";
}

NSArray<NSDictionary *> *LGPrefsSurfaceItems(NSString *identifier) {
    if ([identifier isEqualToString:LGPrefsSurfaceSurfaces]) return @[
        LGGlassQualitySetting(@"Global.Quality", 1.0, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.surface.group.home.title"), LGLocalized(@"prefs.surface.group.home.subtitle")),
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceDock), @"surface_identifier": LGPrefsSurfaceDock },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceFolderIcons), @"surface_identifier": LGPrefsSurfaceFolderIcons },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceOpenFolder), @"surface_identifier": LGPrefsSurfaceOpenFolder },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceAppIcons), @"surface_identifier": LGPrefsSurfaceAppIcons },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceContextMenu), @"surface_identifier": LGPrefsSurfaceContextMenu },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceBanner), @"surface_identifier": LGPrefsSurfaceBanner },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceAlerts), @"surface_identifier": LGPrefsSurfaceAlerts },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceControlCenter), @"surface_identifier": LGPrefsSurfaceControlCenter },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceSearchPill), @"surface_identifier": LGPrefsSurfaceSearchPill },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceSpotlight), @"surface_identifier": LGPrefsSurfaceSpotlight },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceWidgets), @"surface_identifier": LGPrefsSurfaceWidgets },
        LGSectionSetting(LGLocalized(@"prefs.surface.group.lock.title"), LGLocalized(@"prefs.surface.group.lock.subtitle")),
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceNotifications), @"surface_identifier": LGPrefsSurfaceNotifications },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceQuickActions), @"surface_identifier": LGPrefsSurfaceQuickActions },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfacePasscode), @"surface_identifier": LGPrefsSurfacePasscode },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceClock), @"surface_identifier": LGPrefsSurfaceClock },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceCoverSheet), @"surface_identifier": LGPrefsSurfaceCoverSheet },
        LGSectionSetting(LGLocalized(@"prefs.surface.group.library.title"), LGLocalized(@"prefs.surface.group.library.subtitle")),
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceAppLibraryPods), @"surface_identifier": LGPrefsSurfaceAppLibraryPods },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceAppLibrarySearch), @"surface_identifier": LGPrefsSurfaceAppLibrarySearch },
        LGSectionSetting(LGLocalized(@"prefs.surface.group.system.title"), LGLocalized(@"prefs.surface.group.system.subtitle")),
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceGlobalControls), @"surface_identifier": LGPrefsSurfaceGlobalControls },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceKeyboard), @"surface_identifier": LGPrefsSurfaceKeyboard },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceTabBar), @"surface_identifier": LGPrefsSurfaceTabBar },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceAssistiveTouch), @"surface_identifier": LGPrefsSurfaceAssistiveTouch },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfaceVolumeHUD), @"surface_identifier": LGPrefsSurfaceVolumeHUD },
        @{ @"type": @"nav", @"title": LGPrefsSurfaceTitle(LGPrefsSurfacePillHUD), @"surface_identifier": LGPrefsSurfacePillHUD },
    ];
    if ([identifier isEqualToString:LGPrefsSurfaceDock]) return LGDockItems();
    if ([identifier isEqualToString:LGPrefsSurfaceFolderIcons]) return LGRendererItemsForHostPrefix(@"FolderIcon");
    if ([identifier isEqualToString:LGPrefsSurfaceAppIcons]) return LGAppIconItems();
    if ([identifier isEqualToString:LGPrefsSurfaceOpenFolder]) return LGRendererItemsForHostPrefix(@"OpenFolder");
    if ([identifier isEqualToString:LGPrefsSurfaceContextMenu]) return LGContextMenuItems();
    if ([identifier isEqualToString:LGPrefsSurfaceBanner]) return LGRendererItemsForHostPrefix(@"Banner");
    if ([identifier isEqualToString:LGPrefsSurfaceAlerts]) return LGRendererItemsForHostPrefix(@"Alerts");
    if ([identifier isEqualToString:LGPrefsSurfaceControlCenter]) return LGControlCenterItems();
    if ([identifier isEqualToString:LGPrefsSurfaceSearchPill]) return LGSearchPillItems();
    if ([identifier isEqualToString:LGPrefsSurfaceSpotlight]) return LGRendererItemsForHostPrefix(@"Spotlight");
    if ([identifier isEqualToString:LGPrefsSurfaceWidgets]) return LGWidgetItems();
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibraryPods]) return LGRendererItemsForHostPrefix(@"AppLibrary");
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrarySearch]) return LGRendererItemsForHostPrefix(@"AppLibSearch");
    if ([identifier isEqualToString:LGPrefsSurfaceNotifications]) return LGRendererItemsForHostPrefix(@"Notification");
    if ([identifier isEqualToString:LGPrefsSurfaceQuickActions]) return LGRendererItemsForHostPrefix(@"QuickActions");
    if ([identifier isEqualToString:LGPrefsSurfacePasscode]) return LGRendererItemsForHostPrefix(@"Passcode");
    if ([identifier isEqualToString:LGPrefsSurfaceClock]) return LGClockItems();
    if ([identifier isEqualToString:LGPrefsSurfaceCoverSheet]) return LGRendererItemsForHostPrefix(@"CoverSheet");
    if ([identifier isEqualToString:LGPrefsSurfaceKeyboard]) return LGKeyboardItems();
    if ([identifier isEqualToString:LGPrefsSurfaceTabBar]) return LGTabBarItems();
    if ([identifier isEqualToString:LGPrefsSurfaceAssistiveTouch]) return LGRendererItemsForHostPrefix(@"AssistiveTouch");
    if ([identifier isEqualToString:LGPrefsSurfaceVolumeHUD]) return LGRendererItemsForHostPrefix(@"VolumeHUD");
    if ([identifier isEqualToString:LGPrefsSurfacePillHUD]) return LGRendererItemsForHostPrefix(@"PillHUD");
    if ([identifier isEqualToString:LGPrefsSurfaceGlobalControls]) return LGGlobalControlsItems();
    if ([identifier isEqualToString:LGPrefsSurfaceHomescreen]) return LGHomescreenItems();
    if ([identifier isEqualToString:LGPrefsSurfaceLockscreen]) return LGLockscreenItems();
    if ([identifier isEqualToString:LGPrefsSurfaceAppLibrary]) return LGAppLibraryItems();
    if ([identifier isEqualToString:LGPrefsSurfaceMoreOptions]) return LGMoreOptionsItems();
    if ([identifier isEqualToString:LGPrefsSurfaceSettings]) return LGPrefsSettingsItems();
    return @[];
}
