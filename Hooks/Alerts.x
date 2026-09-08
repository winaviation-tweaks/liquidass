#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLiveBackdropView.h"
#import <objc/runtime.h>

static void *kLGAlertGlassKey = &kLGAlertGlassKey;
static void *kLGAlertSuppressedViewsKey = &kLGAlertSuppressedViewsKey;
static void *kLGAlertActionBackgroundKey = &kLGAlertActionBackgroundKey;
static void *kLGAlertActionPressGestureKey = &kLGAlertActionPressGestureKey;
static void *kLGAlertActionHoverGestureKey = &kLGAlertActionHoverGestureKey;
static void *kLGAlertActionHighlightedKey = &kLGAlertActionHighlightedKey;
static void *kLGAlertActionLabelWidthKey = &kLGAlertActionLabelWidthKey;
static void *kLGAlertActionDestructiveKey = &kLGAlertActionDestructiveKey;
static void *kLGAlertActionBaseFontKey = &kLGAlertActionBaseFontKey;
static void *kLGAlertHeaderLogSignatureKey = &kLGAlertHeaderLogSignatureKey;
static void *kLGAlertHeaderLayoutPendingKey = &kLGAlertHeaderLayoutPendingKey;
static void *kLGAlertHeaderRightInsetKey = &kLGAlertHeaderRightInsetKey;
static void *kLGAlertDescriptionBaseFontKey = &kLGAlertDescriptionBaseFontKey;
static void *kLGAlertActionLogSignatureKey = &kLGAlertActionLogSignatureKey;
static void *kLGAlertHierarchyProbeKey = &kLGAlertHierarchyProbeKey;

static BOOL LGAlertsEnabled(void) {
    return lgHostEnabled(@"Alerts");
}

static UIAlertController *LGAlertControllerForView(UIView *view) {
    if (!view) return nil;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIAlertController class]]) {
            return (UIAlertController *)responder;
        }
    }
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        Ivar ivar = class_getInstanceVariable(object_getClass(ancestor), "_alertController");
        if (ivar) {
            id ctrl = object_getIvar(ancestor, ivar);
            if ([ctrl isKindOfClass:[UIAlertController class]]) return (UIAlertController *)ctrl;
        }
    }
    Ivar contentIvar = class_getInstanceVariable(object_getClass(view), "_actionContentView");
    if (contentIvar) {
        id contentView = object_getIvar(view, contentIvar);
        if (contentView) {
            Ivar ctrlIvar = class_getInstanceVariable(object_getClass(contentView), "_alertController");
            if (ctrlIvar) {
                id ctrl = object_getIvar(contentView, ctrlIvar);
                if ([ctrl isKindOfClass:[UIAlertController class]]) return (UIAlertController *)ctrl;
            }
        }
    }
    return nil;
}

static BOOL LGAlertIsAlertStyle(UIView *view) {
    UIAlertController *controller = LGAlertControllerForView(view);
    if (controller) {
        return controller.preferredStyle == UIAlertControllerStyleAlert;
    }
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) hasPrefix:@"_UIAlertControllerPhoneTVMacView"]) {
            return YES;
        }
    }
    return NO;
}

static UIView *LGAlertFindViewWithClassPrefix(UIView *view, NSString *prefix) {
    if (!view) return nil;
    NSString *className = NSStringFromClass(view.class);
    if ([className hasPrefix:prefix]) return view;
    for (UIView *subview in view.subviews) {
        UIView *match = LGAlertFindViewWithClassPrefix(subview, prefix);
        if (match) return match;
    }
    return nil;
}

static UIView *LGAlertStockChromeView(UIView *view) {
    return LGAlertFindViewWithClassPrefix(
        view, @"_UIAlertControllerPhoneTVMacView");
}

static BOOL LGAlertViewHasBackdropAncestor(UIView *view, UIView *chrome) {
    for (UIView *ancestor = view.superview; ancestor && ancestor != chrome;
         ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) containsString:@"Backdrop"])
            return YES;
    }
    return NO;
}

static void LGAlertCollectStockBackdrops(UIView *root, UIView *chrome,
                                         NSMutableArray<UIView *> *matches) {

    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:LGLiveBackdropView.class]) continue;
        NSString *className = NSStringFromClass(subview.class);
        BOOL stockEffect = [subview isKindOfClass:UIVisualEffectView.class] &&
                           LGAlertViewHasBackdropAncestor(subview, chrome);
        BOOL stockBackdrop = [className containsString:@"VisualEffectBackdrop"];
        if (stockEffect || stockBackdrop) {
            [matches addObject:subview];
            continue;
        }
        LGAlertCollectStockBackdrops(subview, chrome, matches);
    }
}

static void LGAlertSuppressStockBackdrops(UIAlertController *controller,
                                           UIView *chrome) {
    NSMutableArray<UIView *> *matches = [NSMutableArray array];
    LGAlertCollectStockBackdrops(chrome, chrome, matches);

    NSMutableArray<NSDictionary *> *states =
        objc_getAssociatedObject(controller, kLGAlertSuppressedViewsKey);
    if (!states) {
        states = [NSMutableArray array];
        objc_setAssociatedObject(controller, kLGAlertSuppressedViewsKey, states,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *view in matches) {
        BOOL remembered = NO;
        for (NSDictionary *state in states) {
            if (state[@"view"] == view) {
                remembered = YES;
                break;
            }
        }
        if (!remembered) {
            [states addObject:@{
                @"view": view,
                @"hidden": @(view.hidden),
                @"alpha": @(view.alpha)
            }];
        }
        view.hidden = YES;
        view.alpha = 0.0;
    }
}

static void LGAlertRestoreStockBackdrops(UIAlertController *controller) {
    NSArray<NSDictionary *> *states =
        objc_getAssociatedObject(controller, kLGAlertSuppressedViewsKey);
    for (NSDictionary *state in states) {
        UIView *view = state[@"view"];
        if (!view) continue;
        view.hidden = [state[@"hidden"] boolValue];
        view.alpha = [state[@"alpha"] doubleValue];
    }
    objc_setAssociatedObject(controller, kLGAlertSuppressedViewsKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGAlertRemoveNativeGlass(UIAlertController *controller) {
    LGLiveBackdropView *glass =
        objc_getAssociatedObject(controller, kLGAlertGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(controller, kLGAlertGlassKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    LGAlertRestoreStockBackdrops(controller);
}

static void LGAlertInstallNativeGlass(UIAlertController *controller) {
    if (!LGAlertsEnabled() ||
        controller.preferredStyle != UIAlertControllerStyleAlert) {
        LGAlertRemoveNativeGlass(controller);
        return;
    }

    UIView *chrome = LGAlertStockChromeView(controller.view);
    if (!chrome || !chrome.window || CGRectIsEmpty(chrome.bounds)) return;

    LGLiveBackdropView *glass =
        objc_getAssociatedObject(controller, kLGAlertGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(chrome.bounds, nil, @"Alerts");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(controller, kLGAlertGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != chrome) [chrome insertSubview:glass atIndex:0];
    glass.frame = chrome.bounds;
    glass.layer.cornerRadius = 35.0;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    LGAlertSuppressStockBackdrops(controller, chrome);
}

static BOOL LGAlertColorLooksRed(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
    CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, alpha = 0.0;
    if ([resolved getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha])
        return saturation > 0.35 && brightness > 0.35 && (hue < 0.08 || hue > 0.92);
    CGFloat red = 0.0, green = 0.0, blue = 0.0;
    return [resolved getRed:&red green:&green blue:&blue alpha:&alpha] &&
           red > 0.5 && red > green * 1.25 && red > blue * 1.10;
}

static BOOL LGAlertActionLabelIsDestructive(UILabel *label, UIView *representation) {
    NSNumber *stored = objc_getAssociatedObject(label, kLGAlertActionDestructiveKey);
    if (stored) return stored.boolValue;
    BOOL destructive = LGAlertColorLooksRed(label.textColor, label.traitCollection) ||
                       LGAlertColorLooksRed(label.highlightedTextColor, label.traitCollection);
    for (UIView *view = label; !destructive && view; view = view.superview) {
        destructive = LGAlertColorLooksRed(view.tintColor, view.traitCollection);
        if (view == representation) break;
    }
    objc_setAssociatedObject(label, kLGAlertActionDestructiveKey, @(destructive),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return destructive;
}

static UIStackView *LGAlertHorizontalActionStack(UIView *view) {
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIStackView.class]) {
            UIStackView *stack = (UIStackView *)ancestor;
            if (stack.axis == UILayoutConstraintAxisHorizontal) return stack;
        }
        if ([NSStringFromClass(ancestor.class)
                hasPrefix:@"_UIAlertControllerPhoneTVMacView"]) break;
    }
    return nil;
}

static BOOL LGAlertActionUsesHorizontalSlot(UIView *view) {
    CGFloat representationWidth = CGRectGetWidth(view.bounds);
    if (representationWidth > 0.0 && representationWidth < 200.0) return YES;
    if (LGAlertHorizontalActionStack(view)) return YES;

    UIView *actionView = nil;
    UIView *chrome = nil;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className isEqualToString:@"_UIAlertControllerActionView"])
            actionView = ancestor;
        if ([className hasPrefix:@"_UIAlertControllerPhoneTVMacView"]) {
            chrome = ancestor;
            break;
        }
    }
    CGFloat actionWidth = CGRectGetWidth(actionView.bounds);
    CGFloat chromeWidth = CGRectGetWidth(chrome.bounds);
    return actionWidth > 0.0 && chromeWidth > 0.0 &&
           actionWidth < chromeWidth * 0.75;
}

static void LGAlertStyleActionLabels(UIView *root, UIView *representation) {
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)subview;
            UIView *background = objc_getAssociatedObject(
                representation, kLGAlertActionBackgroundKey);
            CGFloat centerOffset = background
                ? CGRectGetMidX(background.frame) -
                  CGRectGetMidX(representation.bounds)
                : 0.0;
            label.transform = CGAffineTransformMakeTranslation(centerOffset, 0.0);
            UIColor *textColor = LGAlertActionLabelIsDestructive(label, representation)
                ? UIColor.systemRedColor : UIColor.labelColor;
            label.alpha = 1.0;
            label.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
            label.tintColor = textColor;
            label.textColor = textColor;
            label.highlightedTextColor = textColor;
            UIFont *baseFont = objc_getAssociatedObject(label,
                                                        kLGAlertActionBaseFontKey);
            if (!baseFont) {
                baseFont = label.font;
                objc_setAssociatedObject(label, kLGAlertActionBaseFontKey,
                                         baseFont,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            label.font = [UIFont systemFontOfSize:MAX(1.0,
                baseFont.pointSize - 1.5) weight:UIFontWeightSemibold];
            label.numberOfLines = 1;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.adjustsFontSizeToFitWidth = NO;
            label.layer.filters = nil;
            label.layer.compositingFilter = nil;
            if (!objc_getAssociatedObject(label, kLGAlertActionLabelWidthKey)) {
                CGFloat inset = LGAlertActionUsesHorizontalSlot(representation)
                    ? 16.0 : 64.0;
                NSLayoutConstraint *width = [label.widthAnchor
                    constraintLessThanOrEqualToAnchor:representation.widthAnchor
                    constant:-inset];
                width.priority = UILayoutPriorityRequired - 1.0;
                width.active = YES;
                objc_setAssociatedObject(label, kLGAlertActionLabelWidthKey,
                    width, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        LGAlertStyleActionLabels(subview, representation);
    }
}

static void LGAlertHideActionSeparators(UIView *root) {
    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class)
             isEqualToString:@"_UIInterfaceActionVibrantSeparatorView"]) {
            subview.hidden = YES;
            subview.alpha = 0.0;
            continue;
        }
        LGAlertHideActionSeparators(subview);
    }
}

static BOOL LGAlertViewIsInsideControllerChrome(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className hasPrefix:@"_UIAlertControllerPhoneTVMacView"] ||
            [className isEqualToString:@"_UIAlertControllerView"] ||
            [className isEqualToString:
                @"_UIAlertControllerInterfaceActionGroupView"]) return YES;
    }
    return NO;
}

static void LGAlertFindNearestActionBelowY(UIView *root, UIWindow *window,
                                           CGFloat lowerBound,
                                           CGFloat *nearestTop,
                                           NSMutableArray<NSString *> *diagnostics) {
    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class)
                isEqualToString:@"_UIInterfaceActionCustomViewRepresentationView"] &&
            !subview.hidden && subview.alpha > 0.0) {
            UIView *pill = objc_getAssociatedObject(subview,
                                                     kLGAlertActionBackgroundKey);
            UIView *geometryView = pill ?: subview;
            CGFloat top = CGRectGetMinY([geometryView
                convertRect:geometryView.bounds toView:window]);
            if (diagnostics) {
                [diagnostics addObject:[NSString stringWithFormat:
                    @"rep=%p repWin=%@ pill=%p pillWin=%@ selectedTop=%.2f",
                    subview,
                    NSStringFromCGRect([subview convertRect:subview.bounds toView:window]),
                    pill,
                    pill ? NSStringFromCGRect([pill convertRect:pill.bounds toView:window]) : @"nil",
                    top]];
            }
            if (top >= lowerBound && top < *nearestTop) *nearestTop = top;
        }
        LGAlertFindNearestActionBelowY(subview, window, lowerBound, nearestTop,
                                       diagnostics);
    }
}

static void LGAlertStyleHeaderLabels(UIView *headerScrollView);

static void LGAlertScheduleHeaderStyle(UIView *headerScrollView) {
    if (!LGAlertsEnabled() || !LGAlertIsAlertStyle(headerScrollView)) return;
    if (!headerScrollView.window ||
        [objc_getAssociatedObject(headerScrollView,
                                  kLGAlertHeaderLayoutPendingKey) boolValue]) return;
    objc_setAssociatedObject(headerScrollView, kLGAlertHeaderLayoutPendingKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.01 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(headerScrollView, kLGAlertHeaderLayoutPendingKey,
                                 nil, OBJC_ASSOCIATION_ASSIGN);
        if (headerScrollView.window) LGAlertStyleHeaderLabels(headerScrollView);
    });
}

static void LGAlertStyleHeaderLabels(UIView *headerScrollView) {
    if (!LGAlertsEnabled() || !LGAlertIsAlertStyle(headerScrollView)) return;
    for (UIView *child in headerScrollView.subviews) {
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        for (UIView *grandchild in child.subviews) {
            if (![grandchild isKindOfClass:UILabel.class]) continue;
            UILabel *label = (UILabel *)grandchild;
            label.transform = CGAffineTransformIdentity;
            label.textAlignment = NSTextAlignmentLeft;
            objc_setAssociatedObject(label, kLGAlertHeaderRightInsetKey,
                                     @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [labels addObject:label];
        }
        [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
            CGFloat ay = CGRectGetMinY(a.frame);
            CGFloat by = CGRectGetMinY(b.frame);
            if (ay < by) return NSOrderedAscending;
            if (ay > by) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        if (labels.count >= 2) {
            UILabel *title = labels.firstObject;
            UILabel *description = labels[1];
            UIFont *baseDescriptionFont = objc_getAssociatedObject(
                description, kLGAlertDescriptionBaseFontKey);
            if (!baseDescriptionFont) {
                baseDescriptionFont = description.font;
                objc_setAssociatedObject(description,
                    kLGAlertDescriptionBaseFontKey, baseDescriptionFont,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            description.font = [baseDescriptionFont
                fontWithSize:baseDescriptionFont.pointSize + 2.0];
            if (CGRectIsEmpty(title.bounds) || CGRectIsEmpty(description.bounds)) {
                LGAlertScheduleHeaderStyle(headerScrollView);
                continue;
            }
            UIWindow *window = headerScrollView.window;
            if (window) {
                CGFloat titleBottom = CGRectGetMaxY([title convertRect:title.bounds
                                                               toView:window]);
                CGFloat actionTop = CGFLOAT_MAX;
                NSMutableArray<NSString *> *actionDiagnostics = [NSMutableArray array];
                LGAlertFindNearestActionBelowY(window, window, titleBottom, &actionTop,
                                               actionDiagnostics);
                CGFloat shiftY = 0.0;
                if (actionTop < CGFLOAT_MAX) {
                    CGRect titleInParent = [title convertRect:title.bounds
                                                       toView:description.superview];
                    CGPoint actionInParent = [description.superview
                        convertPoint:CGPointMake(0.0, actionTop) fromView:window];
                    CGFloat minimumTop = CGRectGetMaxY(titleInParent) + 4.0;
                    CGFloat maximumBottom = actionInParent.y - 8.0;
                    CGFloat height = CGRectGetHeight(description.bounds);
                    CGFloat targetCenter = minimumTop +
                        (maximumBottom - minimumTop) * 0.5;
                    targetCenter = MAX(minimumTop + height * 0.5,
                        MIN(targetCenter, maximumBottom - height * 0.5));
                    shiftY = targetCenter - CGRectGetMidY(description.frame);
                    description.transform = CGAffineTransformMakeTranslation(7.5, shiftY);
                } else {
                    description.transform = CGAffineTransformMakeTranslation(7.5, 0.0);
                }
                NSString *signature = [NSString stringWithFormat:
                    @"header=%p child=%p childWin=%@ title='%@' titleFrame=%@ titleWin=%@ "
                     "description='%@' descriptionFrame=%@ descriptionWin=%@ actionTop=%.2f "
                     "shiftY=%.2f actions=%@",
                    headerScrollView, child,
                    NSStringFromCGRect([child convertRect:child.bounds toView:window]),
                    title.text, NSStringFromCGRect(title.frame),
                    NSStringFromCGRect([title convertRect:title.bounds toView:window]),
                    description.text, NSStringFromCGRect(description.frame),
                    NSStringFromCGRect([description convertRect:description.bounds toView:window]),
                    actionTop, shiftY, actionDiagnostics];
                NSString *previous = objc_getAssociatedObject(headerScrollView,
                    kLGAlertHeaderLogSignatureKey);
                if (![previous isEqualToString:signature]) {
                    LGLog(@"[alert-layout] %@", signature);
                    objc_setAssociatedObject(headerScrollView,
                        kLGAlertHeaderLogSignatureKey, signature,
                        OBJC_ASSOCIATION_COPY_NONATOMIC);
                }
            } else {
                description.transform = CGAffineTransformMakeTranslation(7.5, 0.0);
            }
        }
        if (labels.count > 0)
            labels.firstObject.transform = CGAffineTransformMakeTranslation(7.5, 0.0);
    }
}

static void LGAlertInvalidateActionHierarchy(UIView *representation) {
    BOOL isAlert = LGAlertIsAlertStyle(representation);
    for (UIView *ancestor = representation; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIStackView.class]) {
            UIStackView *stack = (UIStackView *)ancestor;
            if (isAlert) {
                BOOL horizontalPair =
                    stack.axis == UILayoutConstraintAxisHorizontal &&
                    stack.arrangedSubviews.count == 2;
                stack.layoutMargins = horizontalPair
                    ? UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0)
                    : UIEdgeInsetsMake(16.0, 0.0, 16.0, 0.0);
                stack.layoutMarginsRelativeArrangement = YES;
                stack.spacing = stack.arrangedSubviews.count > 1 ? 8.0 : 0.0;
            } else {
                stack.layoutMargins = UIEdgeInsetsZero;
                stack.layoutMarginsRelativeArrangement = NO;
                stack.spacing = 0.0;
            }
        }
        [ancestor invalidateIntrinsicContentSize];
        [ancestor setNeedsUpdateConstraints];
        [ancestor setNeedsLayout];
        if ([NSStringFromClass(ancestor.class)
             hasPrefix:@"_UIAlertControllerPhoneTVMacView"]) {
            LGAlertHideActionSeparators(ancestor);
            break;
        }
    }
}

static void LGAlertSuppressNativeActionHighlight(UIView *root);

static UIColor *LGAlertActionBackgroundColor(UIView *view, BOOL highlighted) {
    BOOL dark = view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat white = dark ? 1.0 : 0.0;
    CGFloat alpha = highlighted ? (dark ? 0.24 : 0.18)
                                  : (dark ? 0.14 : 0.10);
    return [UIColor colorWithWhite:white alpha:alpha];
}

static void LGAlertStyleActionRepresentation(UIView *representation) {
    if (!LGAlertsEnabled() || !representation.window) return;
    UIView *background =
        objc_getAssociatedObject(representation, kLGAlertActionBackgroundKey);
    if (!background) {
        background = [[UIView alloc] initWithFrame:CGRectZero];
        background.userInteractionEnabled = NO;
        background.layer.cornerCurve = kCACornerCurveContinuous;
        [representation insertSubview:background atIndex:0];
        objc_setAssociatedObject(representation, kLGAlertActionBackgroundKey,
                                 background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL horizontalPair = LGAlertActionUsesHorizontalSlot(representation);
    CGFloat leftInset = 16.0;
    CGFloat rightInset = 16.0;
    if (horizontalPair) {
        UIView *container = representation.superview;
        CGFloat slotMinX = CGRectGetMinX(representation.frame);
        CGFloat slotMaxX = CGRectGetMaxX(representation.frame);
        CGFloat containerWidth = CGRectGetWidth(container.bounds);
        leftInset = slotMinX <= 1.0 ? 16.0 : 0.0;
        rightInset = slotMaxX >= containerWidth - 1.0 ? 16.0 : 0.0;
    }
    CGFloat slotHeight = CGRectGetHeight(representation.bounds);
    CGFloat pillHeight = (slotHeight > 0.0 && slotHeight < 48.0) ? slotHeight : 48.0;
    CGFloat y = (slotHeight > pillHeight) ? (slotHeight - pillHeight) * 0.5 : 0.0;
    background.frame = CGRectMake(leftInset, y,
        MAX(0.0, CGRectGetWidth(representation.bounds) - leftInset - rightInset),
        pillHeight);
    background.layer.cornerRadius = CGRectGetHeight(background.bounds) * 0.5;
    background.layer.masksToBounds = YES;
    BOOL highlighted = [objc_getAssociatedObject(representation,
                                                  kLGAlertActionHighlightedKey) boolValue];
    background.alpha = 1.0;
    background.backgroundColor = LGAlertActionBackgroundColor(representation,
                                                               highlighted);
    NSMutableArray<NSString *> *ancestry = [NSMutableArray array];
    for (UIView *ancestor = representation; ancestor; ancestor = ancestor.superview) {
        CGRect windowFrame = ancestor.window
            ? [ancestor convertRect:ancestor.bounds toView:ancestor.window]
            : CGRectZero;
        NSString *extra = [ancestor isKindOfClass:UIStackView.class]
            ? [NSString stringWithFormat:@" axis=%ld arranged=%lu spacing=%.2f margins=%@",
                (long)((UIStackView *)ancestor).axis,
                (unsigned long)((UIStackView *)ancestor).arrangedSubviews.count,
                ((UIStackView *)ancestor).spacing,
                NSStringFromUIEdgeInsets(((UIStackView *)ancestor).layoutMargins)]
            : @"";
        [ancestry addObject:[NSString stringWithFormat:
            @"%@:%p bounds=%@ window=%@%@",
            NSStringFromClass(ancestor.class), ancestor,
            NSStringFromCGRect(ancestor.bounds), NSStringFromCGRect(windowFrame),
            extra]];
        if ([NSStringFromClass(ancestor.class)
                hasPrefix:@"_UIAlertControllerPhoneTVMacView"]) break;
    }
    NSString *signature = [NSString stringWithFormat:
        @"representation=%p horizontal=%d result=%@ ancestry=%@",
        representation, horizontalPair, NSStringFromCGRect(background.frame),
        ancestry];
    NSString *previous = objc_getAssociatedObject(representation,
                                                   kLGAlertActionLogSignatureKey);
    if (![previous isEqualToString:signature]) {
        LGLog(@"[alert-action-layout] %@", signature);
        objc_setAssociatedObject(representation, kLGAlertActionLogSignatureKey,
                                 signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    representation.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
    LGAlertSuppressNativeActionHighlight(representation);
    LGAlertStyleActionLabels(representation, representation);
}

static void LGAlertAnimateActionOpacity(UIView *representation, CGFloat opacity,
                                        NSTimeInterval duration) {
    UIView *background = objc_getAssociatedObject(representation,
                                                   kLGAlertActionBackgroundKey);
    if (!background) return;
    BOOL highlighted = opacity < 1.0;
    objc_setAssociatedObject(representation, kLGAlertActionHighlightedKey,
                             @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *color = LGAlertActionBackgroundColor(representation, highlighted);
    if (duration <= 0.0) {
        [background.layer removeAllAnimations];
        background.alpha = 1.0;
        background.backgroundColor = color;
        return;
    }
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         background.alpha = 1.0;
                         background.backgroundColor = color;
                     }
                     completion:nil];
}

static void LGAlertSuppressNativeActionHighlight(UIView *root) {
    root.backgroundColor = UIColor.clearColor;
    root.layer.backgroundColor = nil;
    UIView *customBackground =
        objc_getAssociatedObject(root, kLGAlertActionBackgroundKey);
    for (UIView *subview in root.subviews) {
        if (subview == customBackground) continue;
        NSString *className = NSStringFromClass(subview.class);
        if ([className localizedCaseInsensitiveContainsString:@"highlight"] ||
            [className localizedCaseInsensitiveContainsString:@"selection"] ||
            [className localizedCaseInsensitiveContainsString:@"pressed"]) {
            subview.hidden = YES;
            subview.alpha = 0.0;
            continue;
        }
        LGAlertSuppressNativeActionHighlight(subview);
    }
}

static NSString *LGAlertResponderChainDescription(UIResponder *responder) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIResponder *current = responder; current && parts.count < 32;
         current = current.nextResponder) {
        [parts addObject:[NSString stringWithFormat:@"%@:%p",
            NSStringFromClass(current.class), current]];
    }
    return [parts componentsJoinedByString:@" -> "];
}

static void LGAlertAppendViewHierarchy(UIView *view, UIWindow *referenceWindow,
                                       NSUInteger depth, NSUInteger *nodeCount,
                                       NSMutableString *dump) {
    if (!view || depth > 16 || *nodeCount >= 700) return;
    (*nodeCount)++;
    CGRect windowFrame = referenceWindow
        ? [view convertRect:view.bounds toView:referenceWindow] : CGRectZero;
    CGRect screenFrame = view.window
        ? [view convertRect:view.bounds toView:nil] : CGRectZero;
    UIResponder *next = view.nextResponder;
    [dump appendFormat:@"\n%*s%@:%p frame=%@ bounds=%@ win=%@ screen=%@ "
                        "alpha=%.3f hidden=%d opaque=%d clips=%d interaction=%d "
                        "corner=%.2f masks=%d next=%@:%p subviews=%lu",
        (int)(depth * 2), "", NSStringFromClass(view.class), view,
        NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
        NSStringFromCGRect(windowFrame), NSStringFromCGRect(screenFrame),
        view.alpha, view.hidden, view.opaque, view.clipsToBounds,
        view.userInteractionEnabled, view.layer.cornerRadius,
        view.layer.masksToBounds, NSStringFromClass(next.class), next,
        (unsigned long)view.subviews.count];
    for (UIView *subview in view.subviews)
        LGAlertAppendViewHierarchy(subview, referenceWindow, depth + 1,
                                   nodeCount, dump);
}

static void LGAlertProbeHierarchy(UIAlertController *controller, NSString *reason) {
    if (!controller) return;
    if ([objc_getAssociatedObject(controller, kLGAlertHierarchyProbeKey) boolValue] &&
        ![reason isEqualToString:@"appear"]) return;
    objc_setAssociatedObject(controller, kLGAlertHierarchyProbeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *root = controller.view;
    UIWindow *alertWindow = root.window;
    NSMutableString *dump = [NSMutableString stringWithFormat:
        @"[alert-probe] reason=%@ os=%@ process=%@ controller=%@:%p "
         "style=%ld view=%@:%p frame=%@ bounds=%@ window=%@:%p level=%.2f "
         "key=%d responder=%@ parent=%@:%p presenting=%@:%p presented=%@:%p",
        reason, UIDevice.currentDevice.systemVersion,
        NSProcessInfo.processInfo.processName,
        NSStringFromClass(controller.class), controller,
        (long)controller.preferredStyle, NSStringFromClass(root.class), root,
        NSStringFromCGRect(root.frame), NSStringFromCGRect(root.bounds),
        NSStringFromClass(alertWindow.class), alertWindow, alertWindow.windowLevel,
        alertWindow.isKeyWindow, LGAlertResponderChainDescription(root),
        NSStringFromClass(controller.parentViewController.class),
        controller.parentViewController,
        NSStringFromClass(controller.presentingViewController.class),
        controller.presentingViewController,
        NSStringFromClass(controller.presentedViewController.class),
        controller.presentedViewController];

    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;
    [dump appendFormat:@"\nWINDOWS count=%lu", (unsigned long)windows.count];
    for (UIWindow *window in windows) {
        [dump appendFormat:@"\n  %@:%p frame=%@ bounds=%@ level=%.2f key=%d "
                            "hidden=%d alpha=%.3f root=%@:%p",
            NSStringFromClass(window.class), window,
            NSStringFromCGRect(window.frame), NSStringFromCGRect(window.bounds),
            window.windowLevel, window.isKeyWindow, window.hidden, window.alpha,
            NSStringFromClass(window.rootViewController.class),
            window.rootViewController];
    }

    NSUInteger nodeCount = 0;
    [dump appendString:@"\nALERT_SUBTREE"];
    LGAlertAppendViewHierarchy(root, alertWindow, 0, &nodeCount, dump);
    [dump appendFormat:@"\n[alert-probe-end] nodes=%lu chrome=%@:%p",
        (unsigned long)nodeCount,
        NSStringFromClass(LGAlertStockChromeView(root).class),
        LGAlertStockChromeView(root)];
    LGLog(@"%@", dump);
}

%group LGAlertsSpringBoard

%hook UILabel

- (CGRect)textRectForBounds:(CGRect)bounds
     limitedToNumberOfLines:(NSInteger)numberOfLines {
    if ([objc_getAssociatedObject(self, kLGAlertHeaderRightInsetKey) boolValue])
        bounds.size.width = MAX(0.0, bounds.size.width - 7.5);
    return %orig(bounds, numberOfLines);
}

- (void)drawTextInRect:(CGRect)rect {
    if ([objc_getAssociatedObject(self, kLGAlertHeaderRightInsetKey) boolValue])
        rect.size.width = MAX(0.0, rect.size.width - 7.5);
    %orig(rect);
}

%end

%hook _UIInterfaceActionGroupHeaderScrollView

- (void)didMoveToWindow {
    %orig;
    if (LGAlertsEnabled() && LGAlertIsAlertStyle((UIView *)self))
        LGAlertStyleHeaderLabels((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled() && LGAlertIsAlertStyle((UIView *)self))
        LGAlertStyleHeaderLabels((UIView *)self);
}

%end

%hook _UIInterfaceActionCustomViewRepresentationView

- (CGSize)intrinsicContentSize {
    CGSize size = %orig;
    if (LGAlertsEnabled()) {
        if (LGAlertIsAlertStyle((UIView *)self)) {
            size.height = 48.0;
        } else {
            size.height = MAX(size.height, 57.0);
        }
    }
    return size;
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fitted = %orig;
    if (LGAlertsEnabled()) {
        if (LGAlertIsAlertStyle((UIView *)self)) {
            fitted.height = 48.0;
        } else {
            fitted.height = MAX(fitted.height, 57.0);
        }
    }
    return fitted;
}

%new
- (void)lg_alertActionPressChanged:(UILongPressGestureRecognizer *)gesture {
    if (!LGAlertsEnabled()) return;
    UIView *view = (UIView *)self;
    CGPoint point = [gesture locationInView:view];
    BOOL active = (gesture.state == UIGestureRecognizerStateBegan ||
                   gesture.state == UIGestureRecognizerStateChanged) &&
                  CGRectContainsPoint(view.bounds, point);
    LGAlertSuppressNativeActionHighlight(view);
    LGAlertAnimateActionOpacity(view, active ? 0.25 : 1.0,
                                active ? 0.0 : 0.10);
}

%new
- (void)lg_alertActionHoverChanged:(UIHoverGestureRecognizer *)gesture {
    if (!LGAlertsEnabled()) return;
    CGFloat opacity = gesture.state == UIGestureRecognizerStateBegan ||
                      gesture.state == UIGestureRecognizerStateChanged
        ? 0.25 : 1.0;
    LGAlertAnimateActionOpacity((UIView *)self, opacity,
                                opacity < 1.0 ? 0.0 : 0.08);
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (!LGAlertsEnabled()) return;
    if (view.window) {
        LGAlertInvalidateActionHierarchy(view);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (view.window) LGAlertInvalidateActionHierarchy(view);
        });
    }
    if (!objc_getAssociatedObject(view, kLGAlertActionPressGestureKey)) {
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(lg_alertActionPressChanged:)];
        press.minimumPressDuration = 0.0;
        press.cancelsTouchesInView = NO;
        press.delaysTouchesBegan = NO;
        press.delaysTouchesEnded = NO;
        press.delegate = (id<UIGestureRecognizerDelegate>)self;
        [view addGestureRecognizer:press];
        objc_setAssociatedObject(view, kLGAlertActionPressGestureKey, press,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(view, kLGAlertActionHoverGestureKey)) {
        if (@available(iOS 13.0, *)) {
            UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc]
                initWithTarget:self action:@selector(lg_alertActionHoverChanged:)];
            hover.delegate = (id<UIGestureRecognizerDelegate>)self;
            [view addGestureRecognizer:hover];
            objc_setAssociatedObject(view, kLGAlertActionHoverGestureKey, hover,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    LGAlertStyleActionRepresentation(view);
}

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled()) LGAlertStyleActionRepresentation((UIView *)self);
}

%end

%hook _UIAlertControllerActionView

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled())
        LGAlertSuppressNativeActionHighlight((UIView *)self);
}

%end

%hook _UIInterfaceActionVibrantSeparatorView

- (void)didMoveToWindow {
    %orig;
    if (LGAlertsEnabled() &&
        LGAlertViewIsInsideControllerChrome((UIView *)self)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha = 0.0;
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled() &&
        LGAlertViewIsInsideControllerChrome((UIView *)self)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha = 0.0;
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGAlertsEnabled() &&
        LGAlertViewIsInsideControllerChrome((UIView *)self)) hidden = YES;
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    if (LGAlertsEnabled() &&
        LGAlertViewIsInsideControllerChrome((UIView *)self)) alpha = 0.0;
    %orig(alpha);
}

%end

%hook _UIAlertControlleriOSActionSheetCancelBackgroundView

- (void)didMoveToWindow {
    %orig;
    if (LGAlertsEnabled()) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha = 0.0;
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled()) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha = 0.0;
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGAlertsEnabled()) hidden = YES;
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    if (LGAlertsEnabled()) alpha = 0.0;
    %orig(alpha);
}

%end

%hook _UIAlertControllerInterfaceActionGroupView

- (void)layoutSubviews {
    %orig;
    if (LGAlertsEnabled()) {
        UIView *view = (UIView *)self;
        if (@available(iOS 13.0, *)) {
            view.layer.cornerCurve = kCACornerCurveContinuous;
        }
    }
}

%end

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (LGAlertsEnabled())
        LGAlertProbeHierarchy((UIAlertController *)self, @"appear");
    LGAlertInstallNativeGlass((UIAlertController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (LGAlertsEnabled() &&
        !LGAlertStockChromeView(((UIAlertController *)self).view))
        LGAlertProbeHierarchy((UIAlertController *)self, @"missing-chrome");
    LGAlertInstallNativeGlass((UIAlertController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGAlertRemoveNativeGlass((UIAlertController *)self);
}

%end

%end

%ctor {
    %init(LGAlertsSpringBoard);
}
