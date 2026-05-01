#import "LGPSurfaceController.h"
#import "LGPrefsDataSupport.h"
#import "LGPrefsUIHelpers.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSURL *LGTemporaryPreferencesExportURL(void) {
    NSString *filename = [NSString stringWithFormat:@"liquidass-preferences-%@.json",
                          [[NSUUID UUID].UUIDString lowercaseString]];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}

static void *kLGPanelItemKey = &kLGPanelItemKey;

static BOOL LGItemVisibleForCurrentPreferences(NSDictionary *item) {
    NSString *visibleKey = item[@"visible_key"];
    NSArray *visibleValues = item[@"visible_values"];
    if (!visibleKey.length || visibleValues.count == 0) return YES;

    id fallback = item[@"visible_default"];
    id storedValue = LGReadPreferenceObject(visibleKey, fallback);
    NSString *currentValue = nil;
    if ([storedValue isKindOfClass:[NSString class]]) {
        currentValue = storedValue;
    } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
        currentValue = [storedValue stringValue];
    } else if ([storedValue respondsToSelector:@selector(description)]) {
        currentValue = [storedValue description];
    }
    if (!currentValue.length && [fallback isKindOfClass:[NSString class]]) {
        currentValue = fallback;
    }
    if (!currentValue.length) return NO;
    return [visibleValues containsObject:currentValue];
}

@implementation LGPSurfaceController {
    NSString *_screenTitle;
    NSString *_screenSubtitle;
    NSString *_screenIdentifier;
    UIColor *_accentColor;
    NSArray<NSDictionary *> *_items;
    UIScrollView *_scrollView;
    UIStackView *_contentStack;
    UIScrollView *_jumpScrollView;
    UIStackView *_jumpStack;
    NSMutableDictionary<NSString *, UIView *> *_sectionViews;
    UIView *_respringBar;
    UIView *_scrollTopButton;
    NSLayoutConstraint *_scrollTopBottomConstraint;
    BOOL _scrollTopButtonVisible;
}

- (void)updateVisibleValueControlledItemsAnimated:(BOOL)animated {
    for (UIView *panel in _contentStack.arrangedSubviews) {
        UIStackView *stack = nil;
        for (UIView *subview in panel.subviews) {
            if ([subview isKindOfClass:[UIStackView class]]) {
                stack = (UIStackView *)subview;
                break;
            }
        }
        if (!stack) continue;

        NSArray<UIView *> *arrangedSubviews = stack.arrangedSubviews;
        BOOL hasPanelItems = NO;
        for (UIView *subview in arrangedSubviews) {
            if (objc_getAssociatedObject(subview, kLGPanelItemKey) != nil) {
                hasPanelItems = YES;
                break;
            }
        }
        if (!hasPanelItems) continue;

        for (UIView *subview in arrangedSubviews) {
            NSDictionary *item = objc_getAssociatedObject(subview, kLGPanelItemKey);
            if (!item) continue;
            BOOL visible = LGItemVisibleForCurrentPreferences(item);
            void (^changes)(void) = ^{
                subview.hidden = !visible;
                subview.alpha = visible ? 1.0 : 0.0;
            };
            if (animated) {
                [UIView animateWithDuration:0.16
                                      delay:0.0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                                 animations:changes
                                 completion:nil];
            } else {
                changes();
            }
        }

        NSArray<UIView *> *visibleBodies = [arrangedSubviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *evaluatedObject, NSDictionary *bindings) {
            (void)bindings;
            return objc_getAssociatedObject(evaluatedObject, kLGPanelItemKey) != nil && !evaluatedObject.hidden;
        }]];

        for (NSUInteger i = 0; i < arrangedSubviews.count; i++) {
            UIView *subview = arrangedSubviews[i];
            if (objc_getAssociatedObject(subview, kLGPanelItemKey) != nil) continue;
            BOOL previousVisible = NO;
            BOOL nextVisible = NO;
            for (NSInteger left = (NSInteger)i - 1; left >= 0; left--) {
                UIView *candidate = arrangedSubviews[(NSUInteger)left];
                if (objc_getAssociatedObject(candidate, kLGPanelItemKey) != nil) {
                    previousVisible = !candidate.hidden;
                    break;
                }
            }
            for (NSUInteger right = i + 1; right < arrangedSubviews.count; right++) {
                UIView *candidate = arrangedSubviews[right];
                if (objc_getAssociatedObject(candidate, kLGPanelItemKey) != nil) {
                    nextVisible = !candidate.hidden;
                    break;
                }
            }
            BOOL visible = previousVisible && nextVisible && visibleBodies.count > 1;
            subview.hidden = !visible;
        }
    }
}

- (void)reloadLocalizedContent {
    if ([_screenIdentifier isEqualToString:@"Homescreen"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.homescreen.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.homescreen.subtitle") copy];
        _accentColor = [UIColor systemBlueColor];
        _items = [LGHomescreenItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"Lockscreen"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.lockscreen.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.lockscreen.subtitle") copy];
        _accentColor = [UIColor systemRedColor];
        _items = [LGLockscreenItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"AppLibrary"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.app_library.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.app_library.subtitle") copy];
        _accentColor = [UIColor systemGreenColor];
        _items = [LGAppLibraryItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"MoreOptions"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.about.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.about.subtitle") copy];
        _accentColor = [UIColor systemGrayColor];
        _items = [LGMoreOptionsItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"Experimental"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.experimental.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.experimental.subtitle") copy];
        _accentColor = [UIColor systemOrangeColor];
        _items = [LGExperimentalItems() copy];
    }
    self.title = _screenTitle;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray<NSDictionary *> *)items {
    self = [super init];
    if (!self) return nil;
    _screenTitle = [title copy];
    _screenSubtitle = [subtitle copy];
    _screenIdentifier = [identifier copy];
    _accentColor = tintColor ?: [UIColor systemBlueColor];
    _items = [items copy];
    self.title = title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self configureCustomBackButton];
    self.navigationItem.rightBarButtonItem = LGMakeTextBarButtonItem(LGLocalized(@"prefs.button.reset"), self, @selector(handleResetPressed));
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 23.25, 12.0, &_scrollView, &_contentStack);
    _scrollView.delegate = self;
    LGInstallBottomRespringBar(self, &_respringBar);
    _scrollTopButton = [self makeScrollTopButton];
    [self.view addSubview:_scrollTopButton];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    _scrollTopBottomConstraint = [_scrollTopButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollTopButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        _scrollTopBottomConstraint,
    ]];

    [self reloadVisibleSettings];
    LGObservePrefsNotifications(self);
    [self updateRespringBarAnimated:NO];
    _scrollTopButtonVisible = NO;
    [self updateScrollTopButtonAnimated:NO];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged:)
                                                 name:kLGPrefsLanguageChangedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarStyle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_screenIdentifier.length) {
        LGSetLastSurfaceIdentifier(_screenIdentifier);
    }
    LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
}

- (void)configureCustomBackButton {
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = LGMakeCircularBackItem(self, @selector(handleBackPressed));
}

- (void)applyNavigationBarStyle {
    LGApplyNavigationBarAppearance(self.navigationItem);
}

- (void)handleBackPressed {
    LGClearLastSurfaceIdentifierIfMatching(_screenIdentifier);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)handleResetPressed {
    LGPresentResetConfirmationWithBody(self, [self resetConfirmationBodyText], @selector(performAnimatedSurfacePreferenceReset));
}

- (void)performAnimatedPreferenceReset {
    [self animateVisibleControlsToDefaults];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGResetAllPreferences();
    });
}

- (NSArray<NSString *> *)currentPreferenceKeys {
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *item in _items) {
        NSString *key = item[@"key"];
        if (!key.length) continue;
        [keys addObject:key];
    }
    return keys.array;
}

- (NSString *)resetConfirmationBodyText {
    NSString *scope = _screenTitle.length ? _screenTitle.lowercaseString : LGLocalized(@"prefs.button.reset");
    return [NSString stringWithFormat:LGLocalized(@"prefs.reset_confirm.surface_body_format"), scope];
}

- (void)performAnimatedSurfacePreferenceReset {
    [self animateVisibleControlsToDefaults];
    NSArray<NSString *> *keys = [self currentPreferenceKeys];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGResetPreferencesForKeys(keys);
    });
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

- (void)openExperimental {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.misc.experimental.title")
                                                                          subtitle:LGLocalized(@"prefs.misc.experimental.subtitle")
                                                                         tintColor:[UIColor systemOrangeColor]
                                                                        identifier:@"Experimental"
                                                                             items:LGExperimentalItems()];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)invalidateSnapshotCaches {
    LGPresentInvalidateCachesConfirmation(self);
}

- (void)exportPreferences {
    NSString *jsonString = LGExportPreferencesJSONString();
    if (!jsonString.length) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    NSURL *exportURL = LGTemporaryPreferencesExportURL();
    NSError *writeError = nil;
    if (![jsonString writeToURL:exportURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           writeError.localizedDescription ?: LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[exportURL] applicationActivities:nil];
    if (activityController.popoverPresentationController) {
        activityController.popoverPresentationController.sourceView = self.view;
        activityController.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:activityController animated:YES completion:nil];
}

- (void)importPreferences {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)editThirdPartyAppRWB {
    NSString *existing = [LGReadPreferenceObject(@"RWB.ThirdPartyBundleIDs", @"") isKindOfClass:[NSString class]]
        ? LGReadPreferenceObject(@"RWB.ThirdPartyBundleIDs", @"")
        : @"";
    LGPresentMultilineTextInputSheet(self,
                                     LGLocalized(@"prefs.misc.rwb_third_party.title"),
                                     LGLocalized(@"prefs.misc.rwb_third_party.editor_body"),
                                     existing,
                                     LGLocalized(@"prefs.misc.rwb_third_party.placeholder"),
                                     ^(NSString *text) {
        NSMutableOrderedSet<NSString *> *lines = [NSMutableOrderedSet orderedSet];
        [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] enumerateObjectsUsingBlock:^(NSString *rawLine, NSUInteger idx, BOOL *stop) {
            (void)idx;
            (void)stop;
            NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!line.length) return;
            [lines addObject:line];
        }];
        NSString *normalized = [[lines array] componentsJoinedByString:@"\n"];
        if (normalized.length) {
            LGWritePreferenceObject(@"RWB.ThirdPartyBundleIDs", normalized);
        } else {
            LGRemovePreference(@"RWB.ThirdPartyBundleIDs");
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSString *jsonString = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&readError];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!jsonString.length) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           readError.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_read"));
        return;
    }

    NSError *error = nil;
    if (!LGImportPreferencesJSONString(jsonString, &error)) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           error.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_invalid"));
        return;
    }

    [self reloadLocalizedContent];
    [self reloadVisibleSettings];
    [self updateRespringBarAnimated:NO];
    LGPresentInfoSheet(self,
                       LGLocalized(@"prefs.misc.import_prefs.title"),
                       LGLocalized(@"prefs.import_prefs.success"));
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handlePrefsUIRefresh:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self animateVisibleControlsToDefaults];
}

- (void)handleRespringStateChanged:(NSNotification *)notification {
    (void)notification;
    [self updateRespringBarAnimated:YES];
}

- (void)handleLanguageChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self reloadLocalizedContent];
    [self reloadVisibleSettings];
    [self updateRespringBarAnimated:NO];
}

- (void)updateRespringBarAnimated:(BOOL)animated {
    BOOL shouldShow = LGNeedsRespring() && !LGRespringBarDismissed();
    if (!_respringBar) return;
    _scrollTopBottomConstraint.constant = shouldShow ? -108.0 : -12.0;
    if (shouldShow == !_respringBar.hidden) {
        if (animated && !_scrollTopButton.hidden) {
            [UIView animateWithDuration:0.22 animations:^{
                [self.view layoutIfNeeded];
            }];
        } else {
            [self.view layoutIfNeeded];
        }
        return;
    }
    if (shouldShow) {
        _respringBar.hidden = NO;
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                _respringBar.alpha = 1.0;
                _respringBar.transform = CGAffineTransformIdentity;
                [self.view layoutIfNeeded];
            }];
        } else {
            _respringBar.alpha = 1.0;
            _respringBar.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
        }
    } else {
        void (^hideBlock)(void) = ^{
            _respringBar.alpha = 0.0;
            _respringBar.transform = CGAffineTransformMakeTranslation(0.0, 10.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            (void)finished;
            _respringBar.hidden = YES;
        };
        if (animated) {
            [UIView animateWithDuration:0.18 animations:hideBlock completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (UIView *)makeScrollTopButton {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    container.alpha = 0.0;
    container.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    UIVisualEffectView *blurView =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 19.0;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.75;
    blurView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.20].CGColor;
    [container addSubview:blurView];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.go_to_top") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"chevron.up" withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 12.0, 0.0, 12.0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -6.0);
    [button addTarget:self action:@selector(handleScrollTopPressed) forControlEvents:UIControlEventTouchUpInside];
    [blurView.contentView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:116.0],
        [container.heightAnchor constraintEqualToConstant:38.0],
        [blurView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
    ]];
    return container;
}

- (CGFloat)scrollTopRevealThreshold {
    UIView *targetSection = _sectionViews[LGLocalized(@"prefs.section.folder_icons.title")];
    if (!targetSection) {
        NSArray<NSDictionary *> *sections = [self sectionItems];
        NSString *fallbackTitle = sections.count > 1 ? sections[1][@"title"] : sections.firstObject[@"title"];
        if (fallbackTitle.length) {
            targetSection = _sectionViews[fallbackTitle];
        }
    }
    if (targetSection) {
        CGRect targetRect = [_contentStack convertRect:targetSection.frame toView:_scrollView];
        CGFloat topInset = _scrollView.adjustedContentInset.top;
        return MAX(120.0, CGRectGetMinY(targetRect) - topInset - 24.0);
    }
    return 220.0;
}

- (void)updateScrollTopButtonAnimated:(BOOL)animated {
    if (!_scrollTopButton || !_scrollView) return;
    BOOL shouldShow = _scrollView.contentOffset.y >= [self scrollTopRevealThreshold];
    if (shouldShow == _scrollTopButtonVisible) return;
    _scrollTopButtonVisible = shouldShow;
    if (shouldShow) {
        _scrollTopButton.hidden = NO;
        void (^showBlock)(void) = ^{
            _scrollTopButton.alpha = 1.0;
            _scrollTopButton.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
        };
        if (animated) {
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [UIView animateWithDuration:0.22
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                             animations:showBlock
                             completion:nil];
        } else {
            showBlock();
        }
    } else {
        void (^hideBlock)(void) = ^{
            _scrollTopButton.alpha = 0.0;
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            if (!_scrollTopButtonVisible) {
                _scrollTopButton.hidden = YES;
            }
        };
        if (animated) {
            [UIView animateWithDuration:0.20
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:hideBlock
                             completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (void)handleScrollTopPressed {
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    [_scrollView setContentOffset:CGPointMake(0.0, -topInset) animated:YES];
}

- (void)reloadVisibleSettings {
    _sectionViews = [NSMutableDictionary dictionary];
    for (UIView *subview in [_contentStack.arrangedSubviews copy]) {
        [_contentStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    [_contentStack addArrangedSubview:[self heroCard]];
    [_contentStack addArrangedSubview:LGMakeSectionDivider()];
    UIView *jumpView = [self jumpToViewIfNeeded];
    if (jumpView) {
        [_contentStack addArrangedSubview:jumpView];
    }
    NSUInteger index = 0;
    while (index < _items.count) {
        NSDictionary *item = _items[index];
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"section"]) {
            NSString *sectionTitle = item[@"title"] ?: @"";
            NSString *sectionSubtitle = item[@"subtitle"] ?: @"";
            if (!sectionTitle.length && !sectionSubtitle.length) {
                UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                spacer.backgroundColor = UIColor.clearColor;
                spacer.translatesAutoresizingMaskIntoConstraints = NO;
                [spacer.heightAnchor constraintEqualToConstant:18.0].active = YES;
                [_contentStack addArrangedSubview:spacer];
                index += 1;
                continue;
            }
            [_contentStack addArrangedSubview:[self sectionViewForItem:item]];
            NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
            index += 1;
            while (index < _items.count && ![_items[index][@"type"] isEqualToString:@"section"]) {
                [groupItems addObject:_items[index]];
                index += 1;
            }
            if (groupItems.count) {
                [self appendSurfaceGroupItems:groupItems];
            }
            continue;
        }

        NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
        while (index < _items.count && ![_items[index][@"type"] isEqualToString:@"section"]) {
            [groupItems addObject:_items[index]];
            index += 1;
        }
        if (groupItems.count) {
            [self appendSurfaceGroupItems:groupItems];
        }
    }
    [self updateVisibleValueControlledItemsAnimated:NO];
    [self updateScrollTopButtonAnimated:NO];
}

- (void)updatePanelsControlledByEnabledKey:(NSString *)enabledKey enabled:(BOOL)enabled animated:(BOOL)animated {
    if (!enabledKey.length) return;
    for (UIView *panel in _contentStack.arrangedSubviews) {
        NSString *controllerKey = objc_getAssociatedObject(panel, kLGControlledByEnabledKey);
        if (![controllerKey isEqualToString:enabledKey]) continue;
        panel.userInteractionEnabled = enabled;
        void (^changes)(void) = ^{
            panel.alpha = enabled ? 1.0 : 0.42;
        };
        if (animated) {
            [UIView animateWithDuration:0.18
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:changes
                             completion:nil];
        } else {
            changes();
        }
    }
}

- (void)animateVisibleControlsToDefaults {
    for (UIView *card in _contentStack.arrangedSubviews) {
        for (UIView *subview in [self lg_allSubviewsOfView:card]) {
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *toggle = (UISwitch *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(toggle, kLGDefaultValueKey);
                NSString *preferenceKey = objc_getAssociatedObject(toggle, kLGPreferenceKeyKey);
                if ([preferenceKey isEqualToString:@"Global.Enabled"]) {
                    continue;
                }
                if (defaultValue) {
                    BOOL enabled = [defaultValue boolValue];
                    [toggle setOn:enabled animated:YES];
                    if ([objc_getAssociatedObject(toggle, kLGControlledByEnabledKey) boolValue]) {
                        [self updatePanelsControlledByEnabledKey:preferenceKey enabled:enabled animated:YES];
                    }
                }
            } else if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(slider, kLGDefaultValueKey);
                UILabel *valueLabel = objc_getAssociatedObject(slider, kLGValueLabelKey);
                NSNumber *decimalsNumber = objc_getAssociatedObject(slider, kLGDecimalsKey);
                if (defaultValue) {
                    float targetValue = [defaultValue floatValue];
                    NSInteger decimals = decimalsNumber ? [decimalsNumber integerValue] : 0;
                    LGAnimateSliderToDefault(slider, targetValue, valueLabel, decimals);
                }
            }
        }
    }
}

- (NSArray<UIView *> *)lg_allSubviewsOfView:(UIView *)view {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        [result addObject:subview];
        [result addObjectsFromArray:[self lg_allSubviewsOfView:subview]];
    }
    return result;
}

- (UIView *)heroCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = _screenTitle;
    titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = _screenSubtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectZero];
    accentBar.translatesAutoresizingMaskIntoConstraints = NO;
    accentBar.backgroundColor = [_accentColor colorWithAlphaComponent:0.9];
    accentBar.layer.cornerRadius = 2.0;

    [card addSubview:accentBar];
    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [accentBar.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [accentBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [accentBar.widthAnchor constraintEqualToConstant:36.0],
        [accentBar.heightAnchor constraintEqualToConstant:4.0],
        [titleLabel.topAnchor constraintEqualToAnchor:accentBar.bottomAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0],
    ]];
    return card;
}

- (NSArray<NSDictionary *> *)sectionItems {
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSDictionary *item in _items) {
        if ([item[@"type"] isEqualToString:@"section"] && [item[@"title"] length]) {
            [sections addObject:item];
        }
    }
    return [sections copy];
}

- (UIView *)jumpToViewIfNeeded {
    NSArray<NSDictionary *> *sections = [self sectionItems];
    if (sections.count < 2) return nil;

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.jump_to.title");
    titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];

    _jumpScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _jumpScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpScrollView.showsHorizontalScrollIndicator = NO;
    _jumpScrollView.alwaysBounceHorizontal = YES;
    _jumpScrollView.backgroundColor = UIColor.clearColor;

    _jumpStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _jumpStack.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpStack.axis = UILayoutConstraintAxisHorizontal;
    _jumpStack.spacing = 10.0;
    [_jumpScrollView addSubview:_jumpStack];

    [container addSubview:titleLabel];
    [container addSubview:_jumpScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:2.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-2.0],
        [_jumpScrollView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [_jumpScrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_jumpScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [_jumpScrollView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [_jumpScrollView.heightAnchor constraintEqualToConstant:38.0],
        [_jumpStack.topAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.topAnchor],
        [_jumpStack.leadingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.leadingAnchor],
        [_jumpStack.trailingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.trailingAnchor],
        [_jumpStack.bottomAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.bottomAnchor],
        [_jumpStack.heightAnchor constraintEqualToAnchor:_jumpScrollView.frameLayoutGuide.heightAnchor],
    ]];

    for (NSDictionary *section in sections) {
        NSString *title = section[@"title"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:_accentColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [_accentColor colorWithAlphaComponent:(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.16 : 0.10)];
        button.layer.cornerRadius = 19.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 14.0, 0.0, 14.0);
        [button.heightAnchor constraintEqualToConstant:38.0].active = YES;
        [button addTarget:self action:@selector(handleJumpChipPressed:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, @selector(handleJumpChipPressed:), title, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [_jumpStack addArrangedSubview:button];
    }

    return container;
}

- (void)handleJumpChipPressed:(UIButton *)sender {
    NSString *title = objc_getAssociatedObject(sender, _cmd);
    if (title.length) {
        [self jumpToSectionNamed:title];
    }
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

- (void)jumpToSectionNamed:(NSString *)title {
    UIView *sectionView = _sectionViews[title];
    if (!sectionView || !_scrollView) return;
    CGRect targetRect = [_contentStack convertRect:sectionView.frame toView:_scrollView];
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    CGFloat targetY = MAX(-topInset, CGRectGetMinY(targetRect) - 12.0);
    [_scrollView setContentOffset:CGPointMake(0.0, targetY) animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _scrollView) {
        [self updateScrollTopButtonAnimated:YES];
        LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
    }
}

- (UIView *)sectionViewForItem:(NSDictionary *)item {
    UIView *sectionView = [[UIView alloc] initWithFrame:CGRectZero];
    sectionView.backgroundColor = UIColor.clearColor;
    NSString *sectionTitleText = item[@"title"];
    if (sectionTitleText.length) {
        _sectionViews[sectionTitleText] = sectionView;
    }

    UIStackView *sectionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sectionStack.axis = UILayoutConstraintAxisVertical;
    sectionStack.spacing = 3.0;
    sectionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *sectionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionTitle.text = item[@"title"];
    sectionTitle.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];

    UILabel *sectionSubtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionSubtitle.text = item[@"subtitle"];
    sectionSubtitle.numberOfLines = 0;
    sectionSubtitle.textColor = [UIColor secondaryLabelColor];
    sectionSubtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];

    [sectionStack addArrangedSubview:sectionTitle];
    [sectionStack addArrangedSubview:sectionSubtitle];
    [sectionView addSubview:sectionStack];
    [NSLayoutConstraint activateConstraints:@[
        [sectionStack.topAnchor constraintEqualToAnchor:sectionView.topAnchor constant:4.0],
        [sectionStack.leadingAnchor constraintEqualToAnchor:sectionView.leadingAnchor constant:2.0],
        [sectionStack.trailingAnchor constraintEqualToAnchor:sectionView.trailingAnchor constant:-2.0],
        [sectionStack.bottomAnchor constraintEqualToAnchor:sectionView.bottomAnchor constant:-1.0],
    ]];
    return sectionView;
}

- (UILabel *)controlTitleLabelForItem:(NSDictionary *)item {
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = item[@"title"];
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    return titleLabel;
}

- (UILabel *)controlSubtitleLabelWithText:(NSString *)text {
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = text;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    return subtitleLabel;
}

- (UIView *)controlHeaderRowWithTitleLabel:(UILabel *)titleLabel
                            accessoryViews:(NSArray<UIView *> *)accessoryViews
                                   spacing:(CGFloat)spacing {
    UIView *headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:titleLabel];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor].active = YES;
    [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor].active = YES;
    [titleLabel.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor].active = YES;

    UIView *rightmostView = nil;
    for (UIView *accessoryView in accessoryViews) {
        [headerRow addSubview:accessoryView];
        accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
        [accessoryView.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor].active = YES;
        if (!rightmostView) {
            [accessoryView.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
        } else {
            [accessoryView.trailingAnchor constraintEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        }
        rightmostView = accessoryView;
    }

    if (rightmostView) {
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        [rightmostView.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:spacing].active = YES;
    } else {
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
    }

    return headerRow;
}

- (UISwitch *)configuredToggleForItem:(NSDictionary *)item {
    UISwitch *toggle = [[LGPrefsSwitchClass() alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = _accentColor;
    toggle.on = [LGReadPreference(item[@"key"], item[@"default"]) boolValue];
    objc_setAssociatedObject(toggle, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(toggle, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISwitch *sender = (UISwitch *)action.sender;
        if ([item[@"key"] isEqualToString:@"SettingsControls.Enabled"]) {
            LGWritePreference(item[@"key"], @(sender.isOn));
            LGPresentReopenSettingsConfirmation(self);
        } else {
            LGWritePreferenceAndMaybeRequireRespring(item[@"key"], @(sender.isOn));
            [self handleRespringStateChanged:nil];
        }
        if ([item[@"key"] isEqualToString:@"Tint.Override.PerSurfaceEnabled"]) {
            [self reloadLocalizedContent];
            [self reloadVisibleSettings];
        }
        if ([item[@"controls_following_panel"] boolValue]) {
            [self updatePanelsControlledByEnabledKey:item[@"key"] enabled:sender.isOn animated:YES];
        }
    }] forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(toggle, kLGControlledByEnabledKey, item[@"controls_following_panel"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return toggle;
}

- (UIButton *)sliderInfoButtonForItem:(NSDictionary *)item
                             subtitle:(NSString *)subtitle
                             minValue:(CGFloat)minValue
                             maxValue:(CGFloat)maxValue
                             decimals:(NSInteger)decimals {
    UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *infoConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    [infoButton setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig] forState:UIControlStateNormal];
    [infoButton setTintColor:[UIColor tertiaryLabelColor]];
    objc_setAssociatedObject(infoButton, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [infoButton addTarget:self action:@selector(handleSliderInfoPressed:) forControlEvents:UIControlEventTouchUpInside];
    [infoButton.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [infoButton.heightAnchor constraintEqualToConstant:18.0].active = YES;
    return infoButton;
}

- (UILabel *)sliderValueLabelForStoredValue:(NSNumber *)stored
                                   decimals:(NSInteger)decimals
                                       item:(NSDictionary *)item
                                   subtitle:(NSString *)subtitle
                                   minValue:(CGFloat)minValue
                                   maxValue:(CGFloat)maxValue
                                     slider:(UISlider *)slider {
    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.text = LGFormatSliderValue([stored doubleValue], decimals);
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    valueLabel.textColor = _accentColor;
    valueLabel.userInteractionEnabled = YES;
    objc_setAssociatedObject(slider, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kLGValueLabelKey, valueLabel, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGSliderKey, slider, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(valueLabel, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [valueLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSliderValueLabelTapped:)]];
    return valueLabel;
}

- (NSString *)menuSelectionTitleForItem:(NSDictionary *)item {
    NSString *key = item[@"key"];
    NSString *currentValue = nil;
    if ([key isEqualToString:kLGPrefsLanguageKey]) {
        currentValue = LGCurrentPrefsLanguageCode();
    } else {
        id storedValue = LGReadPreferenceObject(key, item[@"default"]);
        if ([storedValue isKindOfClass:[NSString class]]) {
            currentValue = storedValue;
        } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
            currentValue = [storedValue stringValue];
        } else {
            currentValue = [[storedValue description] copy];
        }
    }
    for (NSDictionary *choice in item[@"choices"]) {
        if ([choice[@"value"] isEqual:currentValue]) {
            return choice[@"title"];
        }
    }
    for (NSDictionary *choice in item[@"choices"]) {
        if ([choice[@"value"] isEqual:item[@"default"]]) {
            return choice[@"title"];
        }
    }
    return @"";
}

- (UIMenu *)menuForItem:(NSDictionary *)item
           currentValue:(NSString *)currentValue
             menuButton:(UIButton *)menuButton
            titleUpdate:(void (^)(NSString *newTitle))applyMenuSelectionTitle {
    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakMenuButton = menuButton;
    __block NSString *selectedValue = [currentValue copy];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (NSDictionary *choice in item[@"choices"]) {
        NSString *value = choice[@"value"];
        NSString *title = choice[@"title"];
        if (!value.length || !title.length) continue;
        UIAction *action = [UIAction actionWithTitle:title
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction * _Nonnull actionObj) {
            (void)actionObj;
            if ([item[@"key"] isEqualToString:kLGPrefsLanguageKey]) {
                LGSetCurrentPrefsLanguageCode(value);
                selectedValue = [LGCurrentPrefsLanguageCode() copy];
            } else {
                LGWritePreferenceObject(item[@"key"], value);
                selectedValue = [value copy];
                if (LGPreferenceRequiresRespring(item[@"key"])) {
                    LGSetRespringBarDismissed(NO);
                    LGSetNeedsRespring(YES);
                }
            }
            applyMenuSelectionTitle(title);
            __strong typeof(weakSelf) strongSelf = weakSelf;
            UIButton *strongMenuButton = weakMenuButton;
            if (strongSelf && strongMenuButton) {
                strongMenuButton.menu = [strongSelf menuForItem:item
                                                   currentValue:selectedValue
                                                     menuButton:strongMenuButton
                                                    titleUpdate:applyMenuSelectionTitle];
                if ([item[@"reload_on_change"] boolValue]) {
                    [strongSelf updateVisibleValueControlledItemsAnimated:YES];
                }
                [strongSelf updateRespringBarAnimated:YES];
            }
        }];
        if ([action respondsToSelector:@selector(setState:)]) {
            action.state = [value isEqualToString:selectedValue] ? UIMenuElementStateOn : UIMenuElementStateOff;
        }
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
}

- (UIView *)menuControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    menuButton.showsMenuAsPrimaryAction = YES;
    menuButton.tintColor = _accentColor;
    menuButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    menuButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    menuButton.backgroundColor = UIColor.clearColor;
    menuButton.layer.cornerRadius = 0.0;

    NSString *selectedTitle = [self menuSelectionTitleForItem:item];
    __block NSString *currentValue = [item[@"key"] isEqualToString:kLGPrefsLanguageKey]
        ? LGCurrentPrefsLanguageCode()
        : [[LGReadPreferenceObject(item[@"key"], item[@"default"]) description] copy];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = selectedTitle;
        config.image = [UIImage systemImageNamed:@"chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 6.0;
        config.baseForegroundColor = _accentColor;
        config.background.backgroundColor = UIColor.clearColor;
        config.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
        menuButton.configuration = config;
    } else {
        [menuButton setTitle:selectedTitle forState:UIControlStateNormal];
        [menuButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
        menuButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        menuButton.imageEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -6.0);
    }

    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakMenuButton = menuButton;
    void (^applyMenuSelectionTitle)(NSString *) = ^(NSString *newTitle) {
        if (!newTitle.length) return;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UIButton *strongMenuButton = weakMenuButton;
        if (!strongSelf || !strongMenuButton) return;
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *updatedConfig = strongMenuButton.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
            updatedConfig.title = newTitle;
            updatedConfig.image = [UIImage systemImageNamed:@"chevron.down"];
            updatedConfig.imagePlacement = NSDirectionalRectEdgeTrailing;
            updatedConfig.imagePadding = 6.0;
            updatedConfig.baseForegroundColor = strongSelf->_accentColor;
            updatedConfig.background.backgroundColor = UIColor.clearColor;
            updatedConfig.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
            strongMenuButton.configuration = updatedConfig;
        } else {
            [strongMenuButton setTitle:newTitle forState:UIControlStateNormal];
        }
    };

    menuButton.menu = [self menuForItem:item
                           currentValue:currentValue
                             menuButton:menuButton
                            titleUpdate:applyMenuSelectionTitle];

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[menuButton]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    NSString *subtitle = item[@"subtitle"];
    if (subtitle.length) {
        [stack addArrangedSubview:[self controlSubtitleLabelWithText:subtitle]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)switchControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[[self configuredToggleForItem:item]]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:[self controlSubtitleLabelWithText:item[@"subtitle"]]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)sliderControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    NSNumber *stored = LGReadPreference(item[@"key"], item[@"default"]);
    CGFloat minValue = [item[@"min"] doubleValue];
    CGFloat maxValue = [item[@"max"] doubleValue];
    NSInteger decimals = [item[@"decimals"] integerValue];
    NSString *subtitle = item[@"subtitle"];

    UISlider *slider = [[LGPrefsSliderClass() alloc] initWithFrame:CGRectZero];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = [stored doubleValue];
    slider.minimumTrackTintColor = _accentColor;

    UILabel *valueLabel = [self sliderValueLabelForStoredValue:stored
                                                      decimals:decimals
                                                          item:item
                                                      subtitle:subtitle
                                                      minValue:minValue
                                                      maxValue:maxValue
                                                        slider:slider];
    UIButton *infoButton = [self sliderInfoButtonForItem:item
                                                subtitle:subtitle
                                                minValue:minValue
                                                maxValue:maxValue
                                                decimals:decimals];
    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[valueLabel, infoButton]
                                                     spacing:8.0];

    NSString *preferenceKey = item[@"key"];
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        valueLabel.text = LGFormatSliderValue(sender.value, decimals);
    }] forControlEvents:UIControlEventValueChanged];
    UIControlEvents commitEvents = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel;
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        CGFloat value = sender.value;
        valueLabel.text = LGFormatSliderValue(value, decimals);
        LGWritePreference(preferenceKey, @(value));
    }] forControlEvents:commitEvents];

    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:slider];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)navControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    NSString *actionName = item[@"action"];
    if (actionName.length) {
        SEL action = NSSelectorFromString(actionName);
        if ([self respondsToSelector:action]) {
            [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        }
    }

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.userInteractionEnabled = NO;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [chevron.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [chevron.heightAnchor constraintEqualToConstant:20.0].active = YES;

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[chevron]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:[self controlSubtitleLabelWithText:item[@"subtitle"]]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];

    [button addSubview:body];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:button.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
    ]];
    return button;
}

- (UIView *)controlBodyForItem:(NSDictionary *)item {
    UILabel *titleLabel = [self controlTitleLabelForItem:item];
    if ([item[@"type"] isEqualToString:@"nav"]) {
        return [self navControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"menu"]) {
        return [self menuControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"switch"]) {
        return [self switchControlBodyForItem:item titleLabel:titleLabel];
    }
    return [self sliderControlBodyForItem:item titleLabel:titleLabel];
}

- (UIView *)groupedPanelForItems:(NSArray<NSDictionary *> *)items {
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

    for (NSUInteger i = 0; i < items.count; i++) {
        UIView *body = [self controlBodyForItem:items[i]];
        objc_setAssociatedObject(body, kLGPanelItemKey, items[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stack addArrangedSubview:body];
        if (i + 1 < items.count) {
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

- (void)appendSurfaceGroupItems:(NSArray<NSDictionary *> *)items {
    if (!items.count) return;
    NSUInteger startIndex = 0;
    NSDictionary *fpsItem = nil;
    NSDictionary *enabledItem = nil;

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        NSString *type = candidate[@"type"];
        NSString *key = candidate[@"key"];
        if ([type isEqualToString:@"slider"] && [key hasSuffix:@".FPS"]) {
            fpsItem = candidate;
            startIndex += 1;
        }
    }

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        if ([candidate[@"type"] isEqualToString:@"switch"]
            && [candidate[@"controls_following_panel"] boolValue]) {
            enabledItem = candidate;
            startIndex += 1;
        }
    }

    if (fpsItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[fpsItem]]];
    }

    if (enabledItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[enabledItem]]];
    }

    if (startIndex >= items.count) return;

    NSArray<NSDictionary *> *panelItems = [items subarrayWithRange:NSMakeRange(startIndex, items.count - startIndex)];
    UIView *panel = [self groupedPanelForItems:panelItems];
    NSString *controllerKey = enabledItem[@"key"];
    id controllerDefault = enabledItem[@"default"];
    if (!controllerKey.length) {
        controllerKey = panelItems.firstObject[@"enabled_key"];
        controllerDefault = panelItems.firstObject[@"enabled_default"];
    }
    BOOL enabled = controllerKey.length ? [LGReadPreference(controllerKey, controllerDefault ?: @YES) boolValue] : YES;
    if (controllerKey.length) {
        objc_setAssociatedObject(panel, kLGControlledByEnabledKey, controllerKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    panel.alpha = enabled ? 1.0 : 0.42;
    panel.userInteractionEnabled = enabled;
    [_contentStack addArrangedSubview:panel];
}

@end
