#import "LGPRootListController.h"
#import "LGPSurfaceController.h"
#import "LGPrefsSurfaceCatalog.h"
#import "LGPrefsDataSupport.h"
#import "LGPrefsUIHelpers.h"
#import "../Shared/LGSharedSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>

@interface LGPRootListController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *lg_scrollView;
@property (nonatomic, strong) UIStackView *lg_stackView;
@property (nonatomic, strong) NSArray<UIButton *> *lg_menuButtons;
@property (nonatomic, strong) UIView *lg_respringBar;
@property (nonatomic, strong) UISwitch *lg_globalToggle;
@property (nonatomic, strong) UIButton *lg_safeModeButton;
@property (nonatomic, assign) CFTimeInterval lg_lastFloatingGlassScrollRefreshTime;
@end

static NSString * const kLGRuntimeCacheUsageBytesKey = @"__runtime_cache_usage_bytes";

static NSString *LGFormatRuntimeCacheUsage(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleMemory;
    formatter.allowedUnits = NSByteCountFormatterUseMB | NSByteCountFormatterUseGB | NSByteCountFormatterUseKB;
    formatter.includesUnit = YES;
    formatter.includesCount = YES;
    return [formatter stringFromByteCount:(long long)bytes];
}

@implementation LGPRootListController

- (void)reloadRootLocalizedContent {
    for (UIView *subview in [self.lg_stackView.arrangedSubviews copy]) {
        [self.lg_stackView removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }

    self.title = LGPrefsAppName();
    [self.lg_stackView addArrangedSubview:[self heroCard]];
    [self.lg_stackView addArrangedSubview:LGMakeSectionDivider()];
    UIView *mainSection = [self rootSectionViewWithTitle:LGLocalized(@"prefs.section.main.title")
                                                subtitle:nil];
    UIButton *surfacesButton = (UIButton *)[self navCardWithTitle:LGPrefsSurfaceTitle(LGPrefsSurfaceSurfaces) subtitle:LGPrefsSurfaceSubtitle(LGPrefsSurfaceSurfaces) color:LGPrefsSurfaceTintColor(LGPrefsSurfaceSurfaces) symbolName:LGPrefsSurfaceSymbolName(LGPrefsSurfaceSurfaces) action:@selector(openSurfaces)];
    UIButton *moreOptionsButton = (UIButton *)[self navCardWithTitle:LGPrefsSurfaceTitle(LGPrefsSurfaceMoreOptions) subtitle:LGPrefsSurfaceSubtitle(LGPrefsSurfaceMoreOptions) color:LGPrefsSurfaceTintColor(LGPrefsSurfaceMoreOptions) symbolName:LGPrefsSurfaceSymbolName(LGPrefsSurfaceMoreOptions) action:@selector(handleAboutPressed)];
    UIView *miscSection = [self rootSectionViewWithTitle:LGLocalized(@"prefs.section.misc.title")
                                                subtitle:nil];
    UIButton *respringButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.respring.title") subtitle:LGLocalized(@"prefs.misc.respring.subtitle") color:[UIColor systemOrangeColor] symbolName:@"arrow.counterclockwise.circle.fill" action:@selector(handleRespringPressed)];
    UIButton *safeModeButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.exit_safe_mode.title") subtitle:LGLocalized(@"prefs.misc.exit_safe_mode.subtitle") color:[UIColor systemRedColor] symbolName:@"exclamationmark.circle.fill" action:@selector(handleExitSafeModePressed)];
    self.lg_safeModeButton = safeModeButton;
    UIButton *aboutButton = (UIButton *)[self navCardWithTitle:LGPrefsSurfaceTitle(LGPrefsSurfaceSettings) subtitle:LGPrefsSurfaceSubtitle(LGPrefsSurfaceSettings) color:LGPrefsSurfaceTintColor(LGPrefsSurfaceSettings) symbolName:LGPrefsSurfaceSymbolName(LGPrefsSurfaceSettings) action:@selector(openPrefsSettings)];
    self.lg_menuButtons = @[surfacesButton];
    [self.lg_stackView addArrangedSubview:mainSection];
    [self.lg_stackView addArrangedSubview:[self globalToggleCard]];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:@[surfacesButton]]];
    [self.lg_stackView addArrangedSubview:miscSection];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:@[moreOptionsButton, respringButton, safeModeButton, aboutButton]]];
    [self.lg_stackView addArrangedSubview:[self runtimeCacheFooterView]];
    [self updateMenuAvailability];
    [self updateSafeModeAvailability];
}

- (NSArray *)specifiers {
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LGPrefsAppName();
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if ([self respondsToSelector:@selector(table)] && self.table) self.table.hidden = YES;
    self.navigationItem.rightBarButtonItem = LGMakeCircularMenuItem(self, @selector(handleApplyPressed),
                                                                      @selector(handleResetPressed),
                                                                      LGLocalized(@"prefs.button.reset"));
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 32.0, 14.0, &_lg_scrollView, &_lg_stackView);
    self.lg_scrollView.delegate = self;
    LGInstallBottomRespringBar(self, &_lg_respringBar);
    [self reloadRootLocalizedContent];
    LGObservePrefsNotifications(self);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged:)
                                                 name:kLGPrefsLanguageChangedNotification
                                               object:nil];
    [self updateRespringBarAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarStyle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.lg_globalToggle setOn:[self isGlobalEnabled] animated:NO];
    [self updateMenuAvailability];
    [self updateSafeModeAvailability];
    [self updateRespringBarAnimated:NO];
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    LGScheduleRespringBarGlassRefresh(self.lg_respringBar);
    NSString *surface = LGLastSurfaceIdentifier();
    if (self.navigationController.topViewController != self) return;
    if (!surface.length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.navigationController.topViewController != self) return;
        if ([surface isEqualToString:@"Surfaces"]) [self openSurfaces];
        else if ([surface isEqualToString:@"Homescreen"]) [self openHomescreen];
        else if ([surface isEqualToString:@"Lockscreen"]) [self openLockscreen];
        else if ([surface isEqualToString:@"AppLibrary"]) [self openAppLibrary];
        else if ([surface isEqualToString:@"MoreOptions"]) [self openMoreOptions];
        else if ([surface isEqualToString:@"PrefsSettings"]) [self openPrefsSettings];
    });
}

- (void)handleBackPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)performAnimatedPreferenceReset {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGResetAllPreferences();
    });
}

- (BOOL)isGlobalEnabled {
    return [LGReadPreference(@"Global.Enabled", @NO) boolValue];
}

- (void)handleSliderValueLabelTapped:(UITapGestureRecognizer *)gesture {
    LGPresentSliderValuePrompt(self, (UILabel *)gesture.view, nil);
}

- (void)handleSliderInfoPressed:(UIButton *)sender {
    NSString *controlTitle = objc_getAssociatedObject(sender, kLGControlTitleKey);
    NSString *subtitle = objc_getAssociatedObject(sender, kLGControlSubtitleKey);

    LGPresentInfoSheet(self, (controlTitle.length ? controlTitle : LGLocalized(@"prefs.info.title")), subtitle);
}

- (void)updateMenuAvailability {
    BOOL enabled = [self isGlobalEnabled];
    for (UIButton *button in self.lg_menuButtons) {
        button.alpha = enabled ? 1.0 : 0.42;
        button.userInteractionEnabled = enabled;
    }
}

- (void)updateSafeModeAvailability {
    BOOL active = LGBackboardSafeModeActive();
    self.lg_safeModeButton.enabled = active;
    self.lg_safeModeButton.userInteractionEnabled = active;
    self.lg_safeModeButton.alpha = active ? 1.0 : 0.42;
}

- (void)handlePrefsUIRefresh:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    BOOL enabled = [self isGlobalEnabled];
    [self.lg_globalToggle setOn:enabled animated:YES];
    [self updateMenuAvailability];
    [self updateRespringBarAnimated:YES];
}

- (void)handleRespringStateChanged:(NSNotification *)notification {
    (void)notification;
    [self updateRespringBarAnimated:YES];
}

- (void)handleLanguageChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self reloadRootLocalizedContent];
    [self updateRespringBarAnimated:NO];
}

- (void)updateRespringBarAnimated:(BOOL)animated {
    BOOL shouldShow = LGNeedsRespring() && !LGRespringBarDismissed();
    if (!self.lg_respringBar) return;
    LGRefreshRespringBarGlass(self.lg_respringBar);
    if (shouldShow == !self.lg_respringBar.hidden) {
        [self.view layoutIfNeeded];
        if (shouldShow) {
            LGScheduleRespringBarGlassRefresh(self.lg_respringBar);
        }
        return;
    }
    if (shouldShow) {
        self.lg_respringBar.hidden = NO;
        LGRefreshRespringBarGlass(self.lg_respringBar);
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                self.lg_respringBar.alpha = 1.0;
                self.lg_respringBar.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL finished) {
                LGRefreshRespringBarGlass(self.lg_respringBar);
            }];
        } else {
            self.lg_respringBar.alpha = 1.0;
            self.lg_respringBar.transform = CGAffineTransformIdentity;
            LGRefreshRespringBarGlass(self.lg_respringBar);
        }
        LGScheduleRespringBarGlassRefresh(self.lg_respringBar);
    } else {
        void (^hideBlock)(void) = ^{
            self.lg_respringBar.alpha = 0.0;
            self.lg_respringBar.transform = CGAffineTransformMakeTranslation(0.0, 10.0);
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            (void)finished;
            self.lg_respringBar.hidden = YES;
        };
        if (animated) {
            [UIView animateWithDuration:0.18 animations:hideBlock completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.lg_scrollView) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lg_lastFloatingGlassScrollRefreshTime < (1.0 / 30.0)) return;
    self.lg_lastFloatingGlassScrollRefreshTime = now;
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    LGRefreshRespringBarGlass(self.lg_respringBar);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == self.lg_scrollView && !decelerate) {
        LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
        LGRefreshRespringBarGlass(self.lg_respringBar);
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == self.lg_scrollView) {
        LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
        LGRefreshRespringBarGlass(self.lg_respringBar);
    }
}

- (UIView *)globalToggleCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 23.25;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = LGLocalized(@"prefs.control.enabled");
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = LGLocalized(@"prefs.subtitle.global_enabled");
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];

    UISwitch *toggle = [[LGPrefsSwitchClass() alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = [UIColor systemBlueColor];
    toggle.on = [self isGlobalEnabled];
    self.lg_globalToggle = toggle;
    [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISwitch *sender = (UISwitch *)action.sender;
        LGWritePreferenceAndMaybeRequireRespring(@"Global.Enabled", @(sender.isOn));
        [self updateMenuAvailability];
        [self updateRespringBarAnimated:YES];
    }] forControlEvents:UIControlEventValueChanged];

    UIView *headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:titleLabel];
    [headerRow addSubview:toggle];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor],
        [titleLabel.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12.0],
        [toggle.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [toggle.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [toggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:12.0]
    ]];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-13.0],
    ]];
    return card;
}

- (void)applyNavigationBarStyle {
    LGApplyNavigationBarAppearance(self.navigationItem);
}

- (UIView *)runtimeCacheFooterView {
    unsigned long long bytes = 0;
    id storedValue = LGReadPreferenceObject(kLGRuntimeCacheUsageBytesKey, @(0));
    if ([storedValue isKindOfClass:[NSNumber class]]) {
        bytes = [(NSNumber *)storedValue unsignedLongLongValue];
    }

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor tertiaryLabelColor];
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    label.text = [NSString stringWithFormat:LGLocalized(@"prefs.root.runtime_cache_footer"),
                  LGFormatRuntimeCacheUsage(bytes)];

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    [container addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:2.0],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
    ]];
    return container;
}

- (UIView *)heroCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.clearColor;

    UILabel *eyebrow = [[UILabel alloc] initWithFrame:CGRectZero];
    eyebrow.text = LGLocalized(@"prefs.hero.eyebrow");
    eyebrow.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    eyebrow.textColor = [UIColor secondaryLabelColor];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = LGPrefsAppName();
    titleLabel.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBlack];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = LGLocalized(@"prefs.hero.subtitle");
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:eyebrow];
    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:22.0],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [eyebrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [titleLabel.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:10.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22.0],
    ]];
    return card;
}

- (UIView *)rootSectionViewWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *sectionView = [[UIView alloc] initWithFrame:CGRectZero];
    sectionView.backgroundColor = UIColor.clearColor;

    UIStackView *sectionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sectionStack.axis = UILayoutConstraintAxisVertical;
    sectionStack.spacing = 3.0;
    sectionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];

    [sectionStack addArrangedSubview:titleLabel];
    if (subtitle.length) {
        UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitleLabel.text = subtitle;
        subtitleLabel.numberOfLines = 0;
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        [sectionStack addArrangedSubview:subtitleLabel];
    }
    [sectionView addSubview:sectionStack];
    [NSLayoutConstraint activateConstraints:@[
        [sectionStack.topAnchor constraintEqualToAnchor:sectionView.topAnchor constant:4.0],
        [sectionStack.leadingAnchor constraintEqualToAnchor:sectionView.leadingAnchor constant:2.0],
        [sectionStack.trailingAnchor constraintEqualToAnchor:sectionView.trailingAnchor constant:-2.0],
        [sectionStack.bottomAnchor constraintEqualToAnchor:sectionView.bottomAnchor constant:-1.0],
    ]];
    return sectionView;
}

- (UIView *)groupedRootNavPanelForButtons:(NSArray<UIButton *> *)buttons {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 23.25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *button = buttons[i];
        button.backgroundColor = UIColor.clearColor;
        button.layer.cornerRadius = 0.0;
        [stack addArrangedSubview:button];
        if (i + 1 < buttons.count) {
            UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
            dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *divider = LGMakeSectionDivider();
            [dividerRow addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:14.0],
                [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
                [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
            ]];
            [stack addArrangedSubview:dividerRow];
        }
    }

    return card;
}

- (UIView *)navCardWithTitle:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color symbolName:(NSString *)symbolName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = LGSubpageCardBackgroundColor();
    button.layer.cornerRadius = 23.25;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    if (action) {
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }

    UIView *chip = [[UIView alloc] initWithFrame:CGRectZero];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [color colorWithAlphaComponent:0.14];
    chip.layer.cornerRadius = 18.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *glyph = LGMakeNavCardGlyphView(symbolName, color);
    [chip addSubview:glyph];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = subtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chevron setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [button addSubview:chip];
    [button addSubview:titleLabel];
    [button addSubview:subtitleLabel];
    [button addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:82.0],
        [chip.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14.0],
        [chip.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [chip.widthAnchor constraintEqualToConstant:34.0],
        [chip.heightAnchor constraintEqualToConstant:34.0],
        [glyph.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:button.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:12.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-14.0],
        [chevron.widthAnchor constraintEqualToConstant:12.0],
        [chevron.heightAnchor constraintEqualToConstant:20.0],
        [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-14.0],
        [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
    ]];
    return button;
}

- (void)pushSurfaceWithIdentifier:(NSString *)identifier {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGPrefsSurfaceTitle(identifier)
                                                                          subtitle:LGPrefsSurfaceSubtitle(identifier)
                                                                         tintColor:LGPrefsSurfaceTintColor(identifier)
                                                                        identifier:identifier
                                                                             items:LGPrefsSurfaceItems(identifier)];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openHomescreen { [self pushSurfaceWithIdentifier:LGPrefsSurfaceHomescreen]; }
- (void)openLockscreen { [self pushSurfaceWithIdentifier:LGPrefsSurfaceLockscreen]; }
- (void)openAppLibrary { [self pushSurfaceWithIdentifier:LGPrefsSurfaceAppLibrary]; }
- (void)openSurfaces { [self pushSurfaceWithIdentifier:LGPrefsSurfaceSurfaces]; }
- (void)openPrefsSettings { [self pushSurfaceWithIdentifier:LGPrefsSurfaceSettings]; }
- (void)openMoreOptions { [self pushSurfaceWithIdentifier:LGPrefsSurfaceMoreOptions]; }
- (void)handleAboutPressed { [self openMoreOptions]; }

- (void)handleResetPressed {
    LGPresentResetConfirmation(self);
}

- (void)handleApplyPressed {
    LGForceSynchronizePreferences();
}

- (void)handleRespringPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
    LGPresentRespringConfirmation(self);
}

- (void)handleExitSafeModePressed {
    if (!LGBackboardSafeModeActive()) {
        [self updateSafeModeAvailability];
        return;
    }
    LGClearBackboardSafeMode();
    notify_post(LGPrefsRespringNotificationCString);
}

- (void)handleLaterPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
