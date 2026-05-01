#import "LGPRootListController.h"
#import "LGPSurfaceController.h"
#import "LGPrefsDataSupport.h"
#import "LGPrefsUIHelpers.h"
#import <objc/runtime.h>

@interface LGPRootListController ()
@property (nonatomic, strong) UIScrollView *lg_scrollView;
@property (nonatomic, strong) UIStackView *lg_stackView;
@property (nonatomic, strong) NSArray<UIButton *> *lg_menuButtons;
@property (nonatomic, strong) UIView *lg_respringBar;
@property (nonatomic, strong) UISwitch *lg_globalToggle;
@end

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
                                                subtitle:LGLocalized(@"prefs.section.main.subtitle")];
    UIButton *homescreenButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.homescreen.title") subtitle:LGLocalized(@"prefs.surface.homescreen.subtitle") color:[UIColor systemBlueColor] symbolName:@"apps.iphone" action:@selector(openHomescreen)];
    UIButton *lockscreenButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.lockscreen.title") subtitle:LGLocalized(@"prefs.surface.lockscreen.subtitle") color:[UIColor systemRedColor] symbolName:@"lg.lockscreen.stacked" action:@selector(openLockscreen)];
    UIButton *appLibraryButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.app_library.title") subtitle:LGLocalized(@"prefs.surface.app_library.subtitle") color:[UIColor systemGreenColor] symbolName:@"square.grid.2x2.fill" action:@selector(openAppLibrary)];
    UIView *miscSection = [self rootSectionViewWithTitle:LGLocalized(@"prefs.section.misc.title")
                                                subtitle:LGLocalized(@"prefs.section.misc.subtitle")];
    UIButton *respringButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.respring.title") subtitle:LGLocalized(@"prefs.misc.respring.subtitle") color:[UIColor systemOrangeColor] symbolName:@"arrow.counterclockwise.circle.fill" action:@selector(handleRespringPressed)];
    UIButton *aboutButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.about.title") subtitle:LGLocalized(@"prefs.misc.about.subtitle") color:[UIColor systemGrayColor] symbolName:@"info.circle.fill" action:@selector(handleAboutPressed)];
    self.lg_menuButtons = @[homescreenButton, lockscreenButton, appLibraryButton];
    [self.lg_stackView addArrangedSubview:mainSection];
    [self.lg_stackView addArrangedSubview:[self globalToggleCard]];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:self.lg_menuButtons]];
    [self.lg_stackView addArrangedSubview:miscSection];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:@[respringButton, aboutButton]]];
    [self updateMenuAvailability];
}

- (NSArray *)specifiers {
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LGPrefsAppName();
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if ([self respondsToSelector:@selector(table)] && self.table) self.table.hidden = YES;
    self.navigationItem.rightBarButtonItem = LGMakeTextBarButtonItem(LGLocalized(@"prefs.button.reset_all"), self, @selector(handleResetPressed));
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 32.0, 14.0, &_lg_scrollView, &_lg_stackView);
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
    [self updateRespringBarAnimated:NO];
    NSString *surface = LGLastSurfaceIdentifier();
    if (self.navigationController.topViewController != self) return;
    if (!surface.length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.navigationController.topViewController != self) return;
        if ([surface isEqualToString:@"Homescreen"]) [self openHomescreen];
        else if ([surface isEqualToString:@"Lockscreen"]) [self openLockscreen];
        else if ([surface isEqualToString:@"AppLibrary"]) [self openAppLibrary];
        else if ([surface isEqualToString:@"MoreOptions"]) [self openMoreOptions];
        else if ([surface isEqualToString:@"Experimental"]) [self openMoreOptions];
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
    LGPresentSliderValuePrompt(self, (UILabel *)gesture.view);
}

- (void)handleSliderInfoPressed:(UIButton *)sender {
    NSString *controlTitle = objc_getAssociatedObject(sender, kLGControlTitleKey);
    NSString *subtitle = objc_getAssociatedObject(sender, kLGControlSubtitleKey);
    NSNumber *minNumber = objc_getAssociatedObject(sender, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(sender, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(sender, kLGDecimalsKey);

    NSInteger decimals = decimalsNumber.integerValue;
    NSString *rangeText = (minNumber && maxNumber)
        ? [NSString stringWithFormat:LGLocalized(@"prefs.range_format"),
           LGFormatSliderValue(minNumber.doubleValue, decimals),
           LGFormatSliderValue(maxNumber.doubleValue, decimals)]
        : nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (subtitle.length) [parts addObject:subtitle];
    if (rangeText.length) [parts addObject:rangeText];
    NSString *message = parts.count ? [parts componentsJoinedByString:@"\n\n"] : nil;

    LGPresentInfoSheet(self, (controlTitle.length ? controlTitle : LGLocalized(@"prefs.info.title")), message);
}

- (void)updateMenuAvailability {
    BOOL enabled = [self isGlobalEnabled];
    for (UIButton *button in self.lg_menuButtons) {
        button.alpha = enabled ? 1.0 : 0.42;
        button.userInteractionEnabled = enabled;
    }
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
    if (shouldShow == !self.lg_respringBar.hidden) return;
    if (shouldShow) {
        self.lg_respringBar.hidden = NO;
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                self.lg_respringBar.alpha = 1.0;
                self.lg_respringBar.transform = CGAffineTransformIdentity;
            }];
        } else {
            self.lg_respringBar.alpha = 1.0;
            self.lg_respringBar.transform = CGAffineTransformIdentity;
        }
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

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = subtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];

    [sectionStack addArrangedSubview:titleLabel];
    [sectionStack addArrangedSubview:subtitleLabel];
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

- (void)pushSurfaceTitle:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color identifier:(NSString *)identifier items:(NSArray<NSDictionary *> *)items {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:title
                                                                          subtitle:subtitle
                                                                         tintColor:color
                                                                        identifier:identifier
                                                                             items:items];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openHomescreen { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.homescreen.title") subtitle:LGLocalized(@"prefs.surface.homescreen.subtitle") color:[UIColor systemBlueColor] identifier:@"Homescreen" items:LGHomescreenItems()]; }
- (void)openLockscreen { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.lockscreen.title") subtitle:LGLocalized(@"prefs.surface.lockscreen.subtitle") color:[UIColor systemRedColor] identifier:@"Lockscreen" items:LGLockscreenItems()]; }
- (void)openAppLibrary { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.app_library.title") subtitle:LGLocalized(@"prefs.surface.app_library.subtitle") color:[UIColor systemGreenColor] identifier:@"AppLibrary" items:LGAppLibraryItems()]; }
- (void)openMoreOptions {
    [self pushSurfaceTitle:LGLocalized(@"prefs.misc.about.title")
                  subtitle:LGLocalized(@"prefs.misc.about.subtitle")
                     color:[UIColor systemGrayColor]
                identifier:@"MoreOptions"
                     items:LGMoreOptionsItems()];
}
- (void)handleAboutPressed { [self openMoreOptions]; }

- (void)handleResetPressed {
    LGPresentResetConfirmation(self);
}

- (void)handleRespringPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
    LGPresentRespringConfirmation(self);
}

- (void)handleLaterPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
