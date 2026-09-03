#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLensRectState.h"
#import "../Shared/LGLiveBackdropView.h"

extern BOOL LG_prefBool(NSString *key, BOOL fallback);
extern CGFloat LG_prefFloat(NSString *key, CGFloat fallback);
extern NSString *LG_prefString(NSString *key, NSString *fallback);
extern BOOL LGDebugLoggingEnabled(void);

#define LGClockLog(...) LGLog(__VA_ARGS__)

typedef struct {
    NSUInteger calls;
    NSUInteger applies;
    CFTimeInterval obstacle;
    CFTimeInterval prepare;
    CFTimeInterval publish;
    CFTimeInterval finish;
    CFTimeInterval total;
    CFTimeInterval peak;
    CFTimeInterval started;
} LGClockProfile;

static LGClockProfile sLGClockProfile;

static void LGClockProfileSample(BOOL applied, CFTimeInterval obstacle,
                                 CFTimeInterval prepare, CFTimeInterval publish,
                                 CFTimeInterval finish, CFTimeInterval total) {
    if (!LGDebugLoggingEnabled()) return;
    LGClockProfile *profile = &sLGClockProfile;
    if (profile->started == 0.0) profile->started = CACurrentMediaTime();
    profile->calls++;
    profile->applies += applied;
    profile->obstacle += obstacle;
    profile->prepare += prepare;
    profile->publish += publish;
    profile->finish += finish;
    profile->total += total;
    profile->peak = MAX(profile->peak, total);
    CFTimeInterval now = CACurrentMediaTime();
    if (now - profile->started < 1.0) return;
    double divisor = MAX((NSUInteger)1, profile->applies);
    LGLog(@"[CLKPROF] calls=%lu applies=%lu obstacle=%.3fms prepare=%.3fms publish=%.3fms finish=%.3fms total=%.3fms peak=%.3fms",
          (unsigned long)profile->calls, (unsigned long)profile->applies,
          profile->obstacle * 1000.0 / divisor,
          profile->prepare * 1000.0 / divisor,
          profile->publish * 1000.0 / divisor,
          profile->finish * 1000.0 / divisor,
          profile->total * 1000.0 / divisor, profile->peak * 1000.0);
    *profile = (LGClockProfile){ .started = now };
}





static const char *kLGClockSharedMaskPath =
    "/var/mobile/Library/Accessibility/liquidglass-clock-mask-shared.bin";
static const size_t kLGClockSharedMaskCapacity = 32 * 1024 * 1024;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t capacity;
    uint64_t sequence;
    uint64_t generation;
    uint32_t width;
    uint32_t height;
    uint64_t pixelBytes;
    float imageScale;
    float bezelWidthPoints;
} LGClockSharedMaskHeader;

// backboardd reads this packed alpha mask directly
static void *LGClockSharedMaskMapping(void) {
    static void *mapping = MAP_FAILED;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = sizeof(LGClockSharedMaskHeader) + kLGClockSharedMaskCapacity;
        int fd = open(kLGClockSharedMaskPath, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
        if (fd < 0) {
            LGClockLog(@"mask map open failed path=%s errno=%d", kLGClockSharedMaskPath, errno);
            return;
        }
        if (ftruncate(fd, (off_t)size) == 0) {
            fchmod(fd, 0666);
            mapping = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (mapping == MAP_FAILED)
                LGClockLog(@"mask mmap failed bytes=%zu errno=%d", size, errno);
        } else {
            LGClockLog(@"mask truncate failed bytes=%zu errno=%d", size, errno);
        }
        close(fd);
    });
    return mapping;
}

static CGFloat LGClockBezelWidth(void) {
    return LG_prefFloat(@"Clock.BezelWidth", 12.0);
}

static BOOL LGClockPublishPath(CGPathRef path, CGSize size, CGFloat scale) {
    if (!path || size.width <= 0.0 || size.height <= 0.0) {
        LGClockLog(@"mask publish rejected path=%p size=%@ scale=%.2f",
                   path, NSStringFromCGSize(size), scale);
        return NO;
    }
    uint32_t width = (uint32_t)ceil(size.width * scale);
    uint32_t height = (uint32_t)ceil(size.height * scale);
    size_t bytes = (size_t)width * height;
    if (!bytes || bytes > kLGClockSharedMaskCapacity) {
        LGClockLog(@"mask publish size rejected dims=%ux%u bytes=%zu capacity=%zu",
                   width, height, bytes, kLGClockSharedMaskCapacity);
        return NO;
    }

    static uint8_t *alpha;
    static size_t alphaCapacity;
    if (bytes > alphaCapacity) {
        uint8_t *resized = realloc(alpha, bytes);
        if (!resized) {
            LGClockLog(@"mask alpha allocation failed bytes=%zu", bytes);
            return NO;
        }
        alpha = resized;
        alphaCapacity = bytes;
    }
    memset(alpha, 0, bytes);
    CGContextRef context = CGBitmapContextCreate(alpha, width, height, 8, width,
                                                  NULL, kCGImageAlphaOnly);
    if (!context) {
        LGClockLog(@"mask bitmap context failed dims=%ux%u", width, height);
        return NO;
    }
    CGContextTranslateCTM(context, 0.0, height);
    CGContextScaleCTM(context, scale, -scale);
    CGContextAddPath(context, path);
    CGContextSetGrayFillColor(context, 1.0, 1.0);
    CGContextFillPath(context);
    CGContextRelease(context);

    void *mapping = LGClockSharedMaskMapping();
    if (!mapping || mapping == MAP_FAILED) {
        LGClockLog(@"mask publish has no shared mapping");
        return NO;
    }
    // generation keeps stale async masks from winning
    static uint64_t generation = 0;
    LGClockSharedMaskHeader *header = (LGClockSharedMaskHeader *)mapping;
    uint64_t sequence = __atomic_load_n(&header->sequence, __ATOMIC_RELAXED);
    if (sequence & 1) sequence++;
    __atomic_store_n(&header->sequence, sequence + 1, __ATOMIC_RELEASE);
    header->magic = 0x4c474d34;
    header->version = 1;
    header->capacity = kLGClockSharedMaskCapacity;
    header->generation = ++generation;
    header->width = width;
    header->height = height;
    header->pixelBytes = bytes;
    header->imageScale = scale;
    header->bezelWidthPoints = (float)LGClockBezelWidth();
    memcpy((uint8_t *)mapping + sizeof(*header), alpha, bytes);
    __atomic_store_n(&header->sequence, sequence + 2, __ATOMIC_RELEASE);
    return YES;
}

static BOOL LGClockEnabled(void) {
    return lgHostEnabled(@"Clock");
}

static BOOL LGClockVariableFontEnabled(void) {
    return LG_prefBool(@"Clock.VariableFont.Enabled", YES);
}

static CGFloat LGClockFontScale(void) {
    return LG_prefFloat(@"Clock.VariableFont.SizeScale", 1.4);
}

static const CGFloat kLGClockVerticalOffset = 10.0;

static CGFloat LGClockAxisValue(NSString *axis) {
    if ([axis isEqualToString:@"weight"]) return LG_prefFloat(@"Clock.VariableFont.Weight", 750.0);
    if ([axis isEqualToString:@"width"]) return LG_prefFloat(@"Clock.VariableFont.Width", 100.0);
    if ([axis isEqualToString:@"height"]) return LG_prefFloat(@"Clock.VariableFont.Height", 350.0);
    if ([axis isEqualToString:@"softness"]) return LG_prefFloat(@"Clock.VariableFont.Softness", 56.0);
    return 0.0;
}

static BOOL LGClockIsHost(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if (@available(iOS 16.0, *)) {
        return [name isEqualToString:@"CSProminentTimeView"];
    }
    return [name isEqualToString:@"SBFLockScreenDateView"];
}

static BOOL LGClockIsLegacySystem(void) {
    if (@available(iOS 16.0, *)) return NO;
    return YES;
}

static BOOL LGClockIsLegacyHost(UIView *view) {
    return [NSStringFromClass(view.class) isEqualToString:@"SBFLockScreenDateView"];
}

static BOOL LGClockDateFormatEnabled(void) {
    return LG_prefBool(@"Lockscreen.Clock.DateFormat.Enabled", YES);
}

static void *kLGClockLegacyDateOriginalFrameKey = &kLGClockLegacyDateOriginalFrameKey;

static BOOL LGClockIsDateLabel(UIView *view) {
    if (![view isKindOfClass:UILabel.class]) return NO;
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class);
        if ([name isEqualToString:@"SBFLockScreenDateSubtitleDateView"] ||
            [name isEqualToString:@"CSProminentSubtitleDateView"]) return YES;
    }
    return NO;
}

static NSString *LGClockCustomDateString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSDateFormatter new]; });
    formatter.locale = [NSLocale autoupdatingCurrentLocale];
    formatter.timeZone = [NSTimeZone localTimeZone];
    NSString *format = LG_prefString(@"Lockscreen.Clock.DateFormat.Format", nil);
    formatter.dateFormat = format.length
        ? format
        : [NSDateFormatter dateFormatFromTemplate:@"EEE MMM d" options:0 locale:formatter.locale];
    NSString *text = [formatter stringFromDate:[NSDate date]] ?: @"";
    text = [text stringByReplacingOccurrencesOfString:@"," withString:@""];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void LGClockApplyDateText(UILabel *label) {
    if (!label || !LGClockIsDateLabel(label)) return;
    static void *kApplying = &kApplying;
    static void *kOriginal = &kOriginal;
    static void *kLastCustom = &kLastCustom;
    if ([objc_getAssociatedObject(label, kApplying) boolValue]) return;

    NSString *lastCustom = objc_getAssociatedObject(label, kLastCustom);
    NSString *original = objc_getAssociatedObject(label, kOriginal);
    if (label.text.length && ![label.text isEqualToString:lastCustom]) {
        objc_setAssociatedObject(label, kOriginal, label.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        original = label.text;
    }
    BOOL custom = LGClockDateFormatEnabled();
    NSString *desired = custom ? LGClockCustomDateString() : original;
    objc_setAssociatedObject(label, kLastCustom, custom ? desired : nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!desired.length || [label.text isEqualToString:desired]) return;
    objc_setAssociatedObject(label, kApplying, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    label.text = desired;
    objc_setAssociatedObject(label, kApplying, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGClockApplyDateTextInView(UIView *root) {
    if (!root) return;
    if ([root isKindOfClass:UILabel.class]) LGClockApplyDateText((UILabel *)root);
    for (UIView *child in root.subviews) LGClockApplyDateTextInView(child);
}

static UIView *LGClockFindDescendantNamed(UIView *root, NSString *className) {
    if (!root || !className.length) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *child in root.subviews) {
        UIView *match = LGClockFindDescendantNamed(child, className);
        if (match) return match;
    }
    return nil;
}

static UIView *LGClockFindLegacyHostInView(UIView *root) {
    if (!root || !LGClockIsLegacySystem()) return nil;
    if (LGClockIsLegacyHost(root)) return root;
    for (UIView *child in root.subviews) {
        UIView *match = LGClockFindLegacyHostInView(child);
        if (match) return match;
    }
    return nil;
}

static UIView *LGClockLegacyHostInWindow(UIWindow *window) {
    return LGClockFindLegacyHostInView(window);
}

static void LGClockPositionLegacyDateSubtitle(UIView *clockHost) {
    if (!clockHost || !LGClockIsLegacyHost(clockHost) || !clockHost.superview) return;
    UIView *subtitle = LGClockFindDescendantNamed(clockHost, @"SBFLockScreenDateSubtitleDateView");
    if (!subtitle || !subtitle.superview) return;
    NSValue *originalFrame = objc_getAssociatedObject(subtitle, kLGClockLegacyDateOriginalFrameKey);
    if (!originalFrame) {
        originalFrame = [NSValue valueWithCGRect:subtitle.frame];
        objc_setAssociatedObject(subtitle, kLGClockLegacyDateOriginalFrameKey,
                                 originalFrame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!LGClockEnabled()) {
        subtitle.frame = originalFrame.CGRectValue;
        return;
    }
    UIView *container = clockHost.superview;
    clockHost.clipsToBounds = NO;
    clockHost.layer.masksToBounds = NO;
    CGRect clockFrame = [container convertRect:clockHost.bounds fromView:clockHost];
    CGRect subtitleFrame = [container convertRect:subtitle.frame fromView:subtitle.superview];
    subtitleFrame.origin.x = round(CGRectGetMidX(clockFrame) - CGRectGetWidth(subtitleFrame) * 0.5);
    subtitleFrame.origin.y = round(CGRectGetMinY(clockFrame) - CGRectGetHeight(subtitleFrame) + 10.0);
    subtitle.frame = [subtitle.superview convertRect:subtitleFrame fromView:container];
    [subtitle.superview bringSubviewToFront:subtitle];
}

static BOOL LGClockLooksLikeTime(NSString *text) {
    if (!text.length || [text rangeOfString:@":"].location == NSNotFound) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    return [text rangeOfCharacterFromSet:digits].location != NSNotFound;
}

static CGPathRef LGClockCreateGlyphPath(CTLineRef line) CF_RETURNS_RETAINED {
    if (!line) return NULL;
    CGMutablePathRef combined = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex runCount = CFArrayGetCount(runs);
    for (CFIndex runIndex = 0; runIndex < runCount; runIndex++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run),
                                                        kCTFontAttributeName);
        CFIndex count = CTRunGetGlyphCount(run);
        if (!font || count <= 0) continue;
        CGGlyph *glyphs = calloc((size_t)count, sizeof(CGGlyph));
        CGPoint *positions = calloc((size_t)count, sizeof(CGPoint));
        if (!glyphs || !positions) {
            free(glyphs);
            free(positions);
            continue;
        }
        CTRunGetGlyphs(run, CFRangeMake(0, count), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, count), positions);
        for (CFIndex index = 0; index < count; index++) {
            CGPathRef glyph = CTFontCreatePathForGlyph(font, glyphs[index], NULL);
            if (!glyph) continue;
            CGAffineTransform translation = CGAffineTransformMakeTranslation(positions[index].x,
                                                                              positions[index].y);
            CGPathAddPath(combined, &translation, glyph);
            CGPathRelease(glyph);
        }
        free(glyphs);
        free(positions);
    }
    return combined;
}

static void LGClockCollectLabels(UIView *root, NSMutableArray<UILabel *> *labels) {
    if ([root isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)root];
    for (UIView *child in root.subviews) LGClockCollectLabels(child, labels);
}

static BOOL LGClockLabelIsInsideClass(UILabel *label, UIView *host, NSString *className) {
    for (UIView *view = label.superview; view && view != host; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:className]) return YES;
    }
    return NO;
}

static UIView *LGClockVisibleSourceViewForLabel(UILabel *label) {
    if (!label) return nil;
    if ([NSStringFromClass(label.class) isEqualToString:@"_UIAnimatingLabel"]) return nil;
    for (UIView *view = label; view; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"SBUILegibilityLabel"]) {
            return view;
        }
    }
    return label;
}

static UILabel *LGClockFindSourceLabel(UIView *host) {
    if (LGClockIsLegacyHost(host)) {
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        for (UIView *child in host.subviews) {
            if ([NSStringFromClass(child.class) isEqualToString:@"SBUILegibilityLabel"]) {
                LGClockCollectLabels(child, labels);
            }
        }
        UILabel *best = nil;
        CGFloat bestScore = -CGFLOAT_MAX;
        for (UILabel *label in labels) {
            NSString *text = label.text.length ? label.text : label.attributedText.string;
            if (!text.length || !LGClockLabelIsInsideClass(label, host, @"SBUILegibilityLabel")) continue;
            CGFloat score = label.font.pointSize;
            if (LGClockLooksLikeTime(text)) score += 1000.0;
            if (score > bestScore) {
                best = label;
                bestScore = score;
            }
        }
        return best;
    }

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LGClockCollectLabels(host, labels);
    UILabel *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UILabel *label in labels) {
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        if (!text.length) continue;
        CGFloat score = label.font.pointSize;
        if (LGClockLooksLikeTime(text)) score += 1000.0;
        if ([NSStringFromClass(label.class) isEqualToString:@"_UIAnimatingLabel"]) score += 200.0;
        if (score > bestScore) {
            best = label;
            bestScore = score;
        }
    }
    return best;
}

static NSString *LGClockLabelSummary(UIView *host) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LGClockCollectLabels(host, labels);
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:labels.count];
    for (UILabel *label in labels) {
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        [rows addObject:[NSString stringWithFormat:@"%@ text=%@ font=%@ %.2f frame=%@ hidden=%d alpha=%.2f",
                         NSStringFromClass(label.class), text ?: @"(nil)",
                         label.font.fontName, label.font.pointSize,
                         NSStringFromCGRect(label.frame), label.hidden, label.alpha]];
    }
    return [rows componentsJoinedByString:@" | "];
}

static UIView *LGClockFindRenderContainer(UIView *host) {
    if (LGClockIsLegacyHost(host)) return host.superview ?: host;

    for (UIView *view = host.superview; view; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"CSProminentDisplayView"]) return view;
    }
    return host;
}

static NSHashTable<UIView *> *LGClockObstacleViews(void) {
    static NSHashTable<UIView *> *views;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ views = [NSHashTable weakObjectsHashTable]; });
    return views;
}

static BOOL LGClockObstacleIsVisible(UIView *view, UIView *container) {
    if (!view.window || view.window != container.window || view.hidden || view.alpha < 0.01) return NO;
    CGRect frame = [view convertRect:view.bounds toView:container];
    NSString *className = NSStringFromClass(view.class);
    BOOL compactObstacle = [className isEqualToString:@"NCNotificationListHeaderTitleView"] ||
                           [className isEqualToString:@"NCNotificationListSectionRevealHintView"];
    CGFloat minimumHeight = compactObstacle ? 24.0 : 48.0;
    return CGRectGetWidth(frame) >= 180.0 && CGRectGetHeight(frame) >= minimumHeight;
}

static CGRect LGClockObstacleFrame(UIView *view, UIView *container) {
    CALayer *presentation = view.layer.presentationLayer;
    CALayer *containerPresentation = container.layer.presentationLayer;
    if (presentation && containerPresentation) {
        CGRect frame = [containerPresentation convertRect:presentation.bounds
                                                 fromLayer:presentation];
        if (!CGRectIsNull(frame) && !CGRectIsInfinite(frame) &&
            CGRectGetWidth(frame) > 0.0 && CGRectGetHeight(frame) > 0.0) {
            return frame;
        }
    }
    return [view convertRect:view.bounds toView:container];
}

static CGFloat LGClockNearestObstacleTop(UIView *container, CGRect clockFrame,
                                         UIView **nearestViewOut,
                                         CGRect *nearestFrameOut,
                                         NSUInteger *candidateCountOut) {
    CGFloat nearest = CGFLOAT_MAX;
    UIView *nearestView = nil;
    CGRect nearestFrame = CGRectNull;
    NSUInteger candidateCount = 0;
    CGRect horizontalBand = CGRectInset(clockFrame, -24.0, 0.0);
    for (UIView *view in LGClockObstacleViews().allObjects) {
        if (!LGClockObstacleIsVisible(view, container)) continue;
        CGRect frame = LGClockObstacleFrame(view, container);
        if (CGRectGetMaxX(frame) <= CGRectGetMinX(horizontalBand) ||
            CGRectGetMinX(frame) >= CGRectGetMaxX(horizontalBand)) continue;
        if (CGRectGetMaxY(frame) <= CGRectGetMinY(clockFrame)) continue;
        candidateCount++;
        if (CGRectGetMinY(frame) < nearest) {
            nearest = CGRectGetMinY(frame);
            nearestView = view;
            nearestFrame = frame;
        }
    }
    LGLensRectSlot artwork = {};
    if (container.window &&
        LGLensRectRead(LGLensRectSlotNowPlayingArtwork, &artwork)) {
        CGSize screen = container.window.bounds.size;
        CGRect inWindow = CGRectMake(artwork.originXRatio * screen.width,
                                     artwork.originYRatio * screen.height,
                                     artwork.widthRatio * screen.width,
                                     artwork.heightRatio * screen.height);
        CGRect frame = [container convertRect:inWindow fromView:nil];
        if (CGRectGetWidth(frame) >= 180.0 && CGRectGetHeight(frame) >= 48.0 &&
            CGRectGetMaxX(frame) > CGRectGetMinX(horizontalBand) &&
            CGRectGetMinX(frame) < CGRectGetMaxX(horizontalBand) &&
            CGRectGetMaxY(frame) > CGRectGetMinY(clockFrame)) {
            candidateCount++;
            if (CGRectGetMinY(frame) < nearest) {
                nearest = CGRectGetMinY(frame);
                nearestView = nil;   // no view to name, it is another process
                nearestFrame = frame;
            }
        }
    }

    if (nearestViewOut) *nearestViewOut = nearestView;
    if (nearestFrameOut) *nearestFrameOut = nearestFrame;
    if (candidateCountOut) *candidateCountOut = candidateCount;
    return nearest;
}

static NSString *LGClockVariableFontPath(void) {
#if TARGET_OS_SIMULATOR
    return @"/opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/SFAdaptiveSoftNumeric-VF.otf";
#else
    return jbroot(@"/Library/PreferenceBundles/LiquidAssPrefs.bundle/SFAdaptiveSoftNumeric-VF.otf");
#endif
}

@interface LGClockFontStore : NSObject
@property (nonatomic) CGFontRef graphicsFont;
@property (nonatomic, copy) NSString *postScriptName;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *axisIDs;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSNumber *> *> *axisRanges;
@property (nonatomic, strong) NSCache<NSString *, UIFont *> *cache;
+ (instancetype)shared;
- (UIFont *)fontAtPointSize:(CGFloat)pointSize;
- (UIFont *)fontAtPointSize:(CGFloat)pointSize heightAxis:(CGFloat)heightAxis;
- (CGFloat)minimumHeightAxis;
@end

@implementation LGClockFontStore

+ (instancetype)shared {
    static LGClockFontStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [LGClockFontStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _cache = [NSCache new];
    _cache.countLimit = 64;
    [self loadFont];
    return self;
}

- (void)dealloc {
    if (_graphicsFont) CGFontRelease(_graphicsFont);
}

- (void)loadFont {
    CFTimeInterval start = CACurrentMediaTime();
    NSString *path = LGClockVariableFontPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        LGClockLog(@"font load failed path=%@", path);
        return;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    _graphicsFont = provider ? CGFontCreateWithDataProvider(provider) : NULL;
    if (provider) CGDataProviderRelease(provider);
    if (!_graphicsFont) {
        LGClockLog(@"font decode failed path=%@ bytes=%lu", path, (unsigned long)data.length);
        return;
    }
    _postScriptName = CFBridgingRelease(CGFontCopyPostScriptName(_graphicsFont));
    CFErrorRef error = NULL;
    BOOL registered = CTFontManagerRegisterGraphicsFont(_graphicsFont, &error);
    if (!registered && error) {
        CFIndex code = CFErrorGetCode(error);
        if (code != kCTFontManagerErrorAlreadyRegistered)
            LGClockLog(@"font registration failed ps=%@ error=%@", _postScriptName, error);
    }
    if (error) CFRelease(error);

    CTFontRef probe = CTFontCreateWithGraphicsFont(_graphicsFont, 60.0, NULL, NULL);
    NSArray<NSDictionary *> *axes = probe ? CFBridgingRelease(CTFontCopyVariationAxes(probe)) : nil;
    if (probe) CFRelease(probe);
    NSMutableDictionary *ids = [NSMutableDictionary dictionary];
    NSMutableDictionary *ranges = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in axes) {
        NSString *name = [entry[(id)kCTFontVariationAxisNameKey] lowercaseString];
        NSNumber *identifier = entry[(id)kCTFontVariationAxisIdentifierKey];
        if (!identifier) continue;
        NSString *key = nil;
        switch (identifier.unsignedIntValue) {
            case 'wght': key = @"weight";   break;
            case 'wdth': key = @"width";    break;
            case 'HGHT': key = @"height";   break;
            case 'SOFT': key = @"softness"; break;
            default: break;
        }
        if (!key && name.length) {
            if ([name containsString:@"weight"] || [name containsString:@"wght"]) key = @"weight";
            else if ([name containsString:@"width"] || [name containsString:@"wdth"]) key = @"width";
            else if ([name containsString:@"height"] || [name containsString:@"hght"]) key = @"height";
            else if ([name containsString:@"soft"]) key = @"softness";
        }
        if (!key) continue;
        ids[key] = identifier;
        ranges[key] = @[
            entry[(id)kCTFontVariationAxisMinimumValueKey] ?: @(-CGFLOAT_MAX),
            entry[(id)kCTFontVariationAxisMaximumValueKey] ?: @(CGFLOAT_MAX),
        ];
    }
    _axisIDs = ids;
    _axisRanges = ranges;
    LGClockLog(@"font ready path=%@ ps=%@ bytes=%lu axes=%@ load_ms=%.2f",
               path, _postScriptName, (unsigned long)data.length, ids,
               (CACurrentMediaTime() - start) * 1000.0);
}

- (CGFloat)clampedValueForAxis:(NSString *)axis {
    CGFloat value = LGClockAxisValue(axis);
    NSArray<NSNumber *> *range = self.axisRanges[axis];
    if (range.count == 2) value = MIN(MAX(value, range[0].doubleValue), range[1].doubleValue);
    return value;
}

- (UIFont *)fontAtPointSize:(CGFloat)pointSize {
    return [self fontAtPointSize:pointSize heightAxis:LGClockAxisValue(@"height")];
}

- (CGFloat)minimumHeightAxis {
    NSArray<NSNumber *> *range = self.axisRanges[@"height"];
    return range.count == 2 ? range[0].doubleValue : 100.0;
}

- (UIFont *)fontAtPointSize:(CGFloat)pointSize heightAxis:(CGFloat)heightAxis {
    if (!self.graphicsFont || !self.postScriptName.length) {
        LGClockLog(@"font request unavailable graphics=%p ps=%@ size=%.2f height=%.1f",
                   self.graphicsFont, self.postScriptName, pointSize, heightAxis);
        return nil;
    }
    pointSize = MAX(1.0, pointSize);
    NSString *key = [NSString stringWithFormat:@"%.2f|%.1f|%.1f|%.1f|%.1f",
                     pointSize,
                     [self clampedValueForAxis:@"weight"],
                     [self clampedValueForAxis:@"width"],
                     heightAxis,
                     [self clampedValueForAxis:@"softness"]];
    UIFont *cached = [self.cache objectForKey:key];
    if (cached) return cached;

    NSMutableDictionary *variations = [NSMutableDictionary dictionary];
    [self.axisIDs enumerateKeysAndObjectsUsingBlock:^(NSString *axis, NSNumber *identifier, BOOL *stop) {
        variations[identifier] = @([axis isEqualToString:@"height"]
            ? heightAxis : [self clampedValueForAxis:axis]);
    }];
    NSDictionary *attributes = @{
        (id)kCTFontNameAttribute: self.postScriptName,
        (id)kCTFontVariationAttribute: variations,
    };
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    CTFontRef ctFont = descriptor ? CTFontCreateWithFontDescriptor(descriptor, pointSize, NULL) : NULL;
    if (descriptor) CFRelease(descriptor);
    UIFont *font = CFBridgingRelease(ctFont);
    if (!font)
        LGClockLog(@"font create failed ps=%@ size=%.2f variations=%@", self.postScriptName,
                   pointSize, variations);
    if (font) [self.cache setObject:font forKey:key];
    return font;
}

@end

@interface LGClockState : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) UILabel *sourceLabel;
@property (nonatomic, weak) UIView *visibleSourceView;
@property (nonatomic, strong) UIFont *originalFont;
@property (nonatomic) CGFloat originalLabelAlpha;
@property (nonatomic) BOOL originalLabelHidden;
@property (nonatomic) CGFloat originalVisibleSourceAlpha;
@property (nonatomic) float originalVisibleSourceLayerOpacity;
@property (nonatomic) BOOL originalVisibleSourceHidden;
@property (nonatomic, strong) LGLiveBackdropView *glassView;
@property (nonatomic, strong) UIView *glyphMaskView;
@property (nonatomic, strong) CAShapeLayer *glyphMaskLayer;
@property (nonatomic, weak) UIView *renderContainer;
@property (nonatomic) CGRect originalLabelFrame;
@property (nonatomic) CGSize renderCanvasSize;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL scheduled;
@property (nonatomic) NSUInteger layoutCalls;
@property (nonatomic) NSUInteger appliedChanges;
@property (nonatomic) NSUInteger skippedChanges;
@property (nonatomic) CFTimeInterval sampleStart;
@property (nonatomic, weak) UIView *lastNearestObstacle;
@property (nonatomic) CGFloat lastNearestTop;
@property (nonatomic, copy) NSString *lastRetractionPhase;
@property (nonatomic) CFTimeInterval totalApplyTime;
@property (nonatomic) CFTimeInterval peakApplyTime;
@property (nonatomic, copy) NSString *lastSignature;
@property (nonatomic, copy) NSString *lastFontDiagnostic;
- (void)scheduleApply:(NSString *)reason;
- (void)restore;
@end

static void *kLGClockStateKey = &kLGClockStateKey;
static void *kLGClockOriginalFontKey = &kLGClockOriginalFontKey;
static void *kLGClockLegacyNotificationOriginalFrameKey = &kLGClockLegacyNotificationOriginalFrameKey;
static void *kLGClockLegacyNotificationPendingKey = &kLGClockLegacyNotificationPendingKey;
static void *kLGClockLegacyNotificationApplyingKey = &kLGClockLegacyNotificationApplyingKey;
static void *kLGClockLegacyNotificationLastRelayoutKey = &kLGClockLegacyNotificationLastRelayoutKey;

static CGFloat LGClockLegacyNotificationGap(void) {
    return 28.0;
}

static BOOL LGClockLegacyShouldShiftNotifications(void) {
    return LGClockIsLegacySystem() && LGClockEnabled();
}

static CGRect LGClockAdjustedLegacyNotificationFrame(UIView *listView, CGRect proposed) {
    if (!listView.window || !LGClockLegacyShouldShiftNotifications()) return proposed;

    static Class listViewClass;
    static dispatch_once_t listViewOnce;
    dispatch_once(&listViewOnce, ^{
        listViewClass = NSClassFromString(@"NCNotificationListView");
    });
    if (listViewClass && [listView.superview isKindOfClass:listViewClass]) return proposed;

    NSValue *original = objc_getAssociatedObject(listView, kLGClockLegacyNotificationOriginalFrameKey);
    if (!original) {
        original = [NSValue valueWithCGRect:proposed];
        objc_setAssociatedObject(listView, kLGClockLegacyNotificationOriginalFrameKey,
                                 original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *container = listView.superview;
    UIView *clockHost = LGClockLegacyHostInWindow(listView.window);
    if (!container || !clockHost) return proposed;
    CGRect clockFrame = [container convertRect:clockHost.bounds fromView:clockHost];
    CGFloat desiredMinY = CGRectGetMaxY(clockFrame) + LGClockLegacyNotificationGap();
    CGRect adjusted = proposed;
    CGFloat delta = desiredMinY - CGRectGetMinY(adjusted);
    CGFloat newHeight = adjusted.size.height - delta;
    if (newHeight <= 120.0 || fabs(delta) <= 0.5) return proposed;
    adjusted.origin.y = desiredMinY;
    adjusted.size.height = newHeight;
    return adjusted;
}

static void LGClockRelayoutLegacyNotificationList(UIView *listView) {
    if (!listView.window) return;
    if ([objc_getAssociatedObject(listView, kLGClockLegacyNotificationApplyingKey) boolValue]) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(listView, kLGClockLegacyNotificationLastRelayoutKey);
    if (last.doubleValue > 0.0 && now - last.doubleValue < (1.0 / 15.0)) return;
    objc_setAssociatedObject(listView, kLGClockLegacyNotificationLastRelayoutKey, @(now),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSValue *original = objc_getAssociatedObject(listView, kLGClockLegacyNotificationOriginalFrameKey);
    CGRect adjusted = LGClockLegacyShouldShiftNotifications()
        ? LGClockAdjustedLegacyNotificationFrame(listView, listView.frame)
        : (original ? original.CGRectValue : listView.frame);
    if (CGRectEqualToRect(adjusted, listView.frame)) return;
    objc_setAssociatedObject(listView, kLGClockLegacyNotificationApplyingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    listView.frame = adjusted;
    objc_setAssociatedObject(listView, kLGClockLegacyNotificationApplyingKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGClockScheduleLegacyNotificationRelayout(UIView *listView) {
    if (!listView.window || !LGClockIsLegacySystem()) return;
    if ([objc_getAssociatedObject(listView, kLGClockLegacyNotificationPendingKey) boolValue]) return;
    objc_setAssociatedObject(listView, kLGClockLegacyNotificationPendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(listView, kLGClockLegacyNotificationPendingKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGClockRelayoutLegacyNotificationList(listView);
    });
}

static NSHashTable<LGClockState *> *LGClockStates(void) {
    static NSHashTable<LGClockState *> *states;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ states = [NSHashTable weakObjectsHashTable]; });
    return states;
}

static void LGClockScheduleKnownStates(NSString *reason) {
    for (LGClockState *state in LGClockStates().allObjects) {
        if (state.host.window) [state scheduleApply:reason];
    }
}

@interface LGClockMotionTracker : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) CFTimeInterval deadline;
+ (instancetype)shared;
- (void)trackMotion;
@end

@implementation LGClockMotionTracker

+ (instancetype)shared {
    static LGClockMotionTracker *tracker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tracker = [LGClockMotionTracker new]; });
    return tracker;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _displayLink.paused = YES;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}

- (void)trackMotion {
    self.deadline = CACurrentMediaTime() + 0.30;
    self.displayLink.paused = NO;
}

- (void)tick:(CADisplayLink *)displayLink {
    if (CACurrentMediaTime() >= self.deadline) {
        displayLink.paused = YES;
        return;
    }
    LGClockScheduleKnownStates(@"motion");
}

@end

static BOOL LGClockIsOurFont(UIFont *font) {
    return [font.fontName containsString:@"SFAdaptiveSoftNumeric"];
}

static UIFont *LGClockAttributedFont(UILabel *label) {
    if (!label.attributedText.length) return nil;
    UIFont *font = [label.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    return font ?: [label.attributedText attribute:(__bridge NSString *)kCTFontAttributeName
                                           atIndex:0 effectiveRange:NULL];
}

static NSString *LGClockFontSummary(UIFont *font) {
    if (!font) return @"nil";
    UIFontDescriptor *descriptor = font.fontDescriptor;
    return [NSString stringWithFormat:@"name=%@ family=%@ size=%.2f traits=%lu variation=%@",
            font.fontName, font.familyName, font.pointSize,
            (unsigned long)descriptor.symbolicTraits,
            descriptor.fontAttributes[(id)kCTFontVariationAttribute] ?: @{}];
}

static BOOL LGClockLabelUsesOurFont(UILabel *label) {
    if (LGClockIsOurFont(label.font)) return YES;
    return LGClockIsOurFont(LGClockAttributedFont(label));
}

@implementation LGClockState

- (instancetype)init {
    self = [super init];
    if (self) _sampleStart = CACurrentMediaTime();
    return self;
}

- (void)scheduleApply:(NSString *)reason {
    self.layoutCalls++;
    if (self.scheduled) {
        if ([reason isEqualToString:@"text"])
            LGClockLog(@"text apply coalesced host=%@ source=%@",
                       NSStringFromClass(self.host.class),
                       self.sourceLabel.text ?: self.sourceLabel.attributedText.string);
        return;
    }
    self.scheduled = YES;
    __weak LGClockState *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGClockState *state = weakSelf;
        if (!state) return;
        state.scheduled = NO;
        [state applyReason:reason];
    });
}

- (void)applyReason:(NSString *)reason {
    UIView *host = self.host;
    if (!host.window) return;
    CFTimeInterval start = CACurrentMediaTime();
    UILabel *label = LGClockFindSourceLabel(host);
    if (label != self.sourceLabel) {
        [self restore];
        self.sourceLabel = label;
        self.visibleSourceView = LGClockVisibleSourceViewForLabel(label);
        self.originalVisibleSourceAlpha = self.visibleSourceView.alpha;
        self.originalVisibleSourceLayerOpacity = self.visibleSourceView.layer.opacity;
        self.originalVisibleSourceHidden = self.visibleSourceView.hidden;
        UIFont *savedFont = objc_getAssociatedObject(label, kLGClockOriginalFontKey);
        if (!savedFont && !LGClockIsOurFont(label.font)) {
            savedFont = label.font;
            objc_setAssociatedObject(label, kLGClockOriginalFontKey,
                                     savedFont, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        self.originalFont = savedFont ?: label.font;
        self.originalLabelAlpha = label.alpha;
        self.originalLabelHidden = label.hidden;
        self.originalLabelFrame = label.frame;
        LGClockLog(@"source host=%@ label=%@ frame=%@ bounds=%@ text=%@ directFont={%@} attributedFont={%@} savedFont={%@} savedAssociated=%d variablePref=%d",
                   NSStringFromClass(host.class), NSStringFromClass(label.class),
                   NSStringFromCGRect(label.frame), NSStringFromCGRect(label.bounds),
                   label.text ?: label.attributedText.string,
                   LGClockFontSummary(label.font), LGClockFontSummary(LGClockAttributedFont(label)),
                   LGClockFontSummary(self.originalFont), savedFont != nil,
                   LGClockVariableFontEnabled());
    }
    if (!label) {
        LGClockLog(@"source missing host=%@ frame=%@ bounds=%@ subviews=%lu",
                   NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
                   NSStringFromCGRect(host.bounds), (unsigned long)host.subviews.count);
        LGClockLog(@"source candidates %@", LGClockLabelSummary(host));
        return;
    }

    UIView *visibleSourceView = self.visibleSourceView ?: LGClockVisibleSourceViewForLabel(label);

    BOOL enabled = LGClockEnabled();
    BOOL variableFontEnabled = LGClockVariableFontEnabled();
    UIView *renderContainer = LGClockFindRenderContainer(host);
    CGRect sourceRect = variableFontEnabled
        ? [host convertRect:host.bounds toView:renderContainer]
        : [label convertRect:label.bounds toView:renderContainer];
    UIView *nearestObstacle = nil;
    CGRect nearestObstacleFrame = CGRectNull;
    NSUInteger obstacleCandidates = 0;
    CGFloat nearestTop = LGClockNearestObstacleTop(renderContainer, sourceRect,
                                                   &nearestObstacle,
                                                   &nearestObstacleFrame,
                                                   &obstacleCandidates);
    CFTimeInterval profileObstacleEnd = CACurrentMediaTime();
    if (nearestTop != CGFLOAT_MAX) nearestTop = round(nearestTop * 2.0) * 0.5;
    NSString *signature = [NSString stringWithFormat:@"%d|%d|%@|%.2f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f",
                           enabled, variableFontEnabled, label.text ?: label.attributedText.string,
                           self.originalFont.pointSize,
                           variableFontEnabled ? LGClockAxisValue(@"weight") : 0.0,
                           variableFontEnabled ? LGClockAxisValue(@"width") : 0.0,
                           variableFontEnabled ? LGClockAxisValue(@"height") : 0.0,
                           variableFontEnabled ? LGClockAxisValue(@"softness") : 0.0,
                           nearestTop, LGClockBezelWidth(),
                           CGRectGetMinX(sourceRect), CGRectGetMinY(sourceRect),
                           CGRectGetWidth(sourceRect), CGRectGetHeight(sourceRect)];
    BOOL fontStateMatches = enabled ? (self.glassView != nil)
                                    : !LGClockLabelUsesOurFont(label);
    if ([signature isEqualToString:self.lastSignature] && fontStateMatches) {
        self.skippedChanges++;
        CFTimeInterval end = CACurrentMediaTime();
        LGClockProfileSample(NO, profileObstacleEnd - start, 0.0, 0.0,
                             end - profileObstacleEnd, end - start);
        [self emitSummaryIfNeeded];
        return;
    }
    self.lastSignature = signature;
    self.applying = YES;
    CFTimeInterval profilePrepareEnd = profileObstacleEnd;
    CFTimeInterval profilePublishEnd = profileObstacleEnd;
    CFTimeInterval profilePublishDuration = 0.0;
    if (!enabled) {
        if (self.originalFont) label.font = self.originalFont;
        label.alpha = self.originalLabelAlpha;
        label.hidden = self.originalLabelHidden;
        visibleSourceView.hidden = self.originalVisibleSourceHidden;
        visibleSourceView.alpha = self.originalVisibleSourceAlpha;
        visibleSourceView.layer.opacity = self.originalVisibleSourceLayerOpacity;
        self.glassView.maskView = nil;
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.glyphMaskView = nil;
        self.glyphMaskLayer = nil;
    } else {
        CGFloat sourceSize = self.originalFont.pointSize;
        CGFloat pointSize = variableFontEnabled ? sourceSize * LGClockFontScale() : sourceSize;
        LGClockFontStore *fontStore = variableFontEnabled ? [LGClockFontStore shared] : nil;
        CGFloat requestedHeightAxis = variableFontEnabled ? LGClockAxisValue(@"height") : 0.0;
        UIFont *font = variableFontEnabled
            ? [fontStore fontAtPointSize:pointSize heightAxis:requestedHeightAxis]
            : self.originalFont;
        if (!font) {
            LGClockLog(@"render font unavailable variable=%d original=%@ %.2f text=%@",
                       variableFontEnabled, self.originalFont.fontName,
                       self.originalFont.pointSize,
                       label.text ?: label.attributedText.string);
        }
        if (font) {
            NSString *text = label.text.length ? label.text : label.attributedText.string;
            NSDictionary *measureAttributes = @{ (__bridge id)kCTFontAttributeName: font };
            NSAttributedString *measureString = [[NSAttributedString alloc] initWithString:text ?: @""
                                                                                attributes:measureAttributes];
            CTLineRef measureLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)measureString);
            CGRect requestedGlyphBounds = measureLine
                ? CTLineGetBoundsWithOptions(measureLine, kCTLineBoundsUseGlyphPathBounds) : CGRectZero;
            if (measureLine) CFRelease(measureLine);
            CGFloat requestedContentHeight = ceil(CGRectGetHeight(requestedGlyphBounds) + 24.0);
            CGFloat availableHeight = nearestTop == CGFLOAT_MAX
                ? requestedContentHeight
                : MAX(1.0, nearestTop - CGRectGetMinY(sourceRect) - 10.0);
            CGFloat minimumHeightAxis = 0.0;
            CGRect minimumGlyphBounds = requestedGlyphBounds;
            CGFloat minimumContentHeight = requestedContentHeight;
            CGFloat resolvedHeightAxis = 0.0;
            if (variableFontEnabled) {
                minimumHeightAxis = fontStore.minimumHeightAxis;
                UIFont *minimumFont = [fontStore fontAtPointSize:pointSize
                                                      heightAxis:minimumHeightAxis];
                NSDictionary *minimumAttributes = minimumFont
                    ? @{ (__bridge id)kCTFontAttributeName: minimumFont } : @{};
                NSAttributedString *minimumString = [[NSAttributedString alloc]
                    initWithString:text ?: @"" attributes:minimumAttributes];
                CTLineRef minimumLine = minimumFont
                    ? CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)minimumString)
                    : NULL;
                minimumGlyphBounds = minimumLine
                    ? CTLineGetBoundsWithOptions(minimumLine, kCTLineBoundsUseGlyphPathBounds)
                    : requestedGlyphBounds;
                if (minimumLine) CFRelease(minimumLine);
                minimumContentHeight = ceil(CGRectGetHeight(minimumGlyphBounds) + 24.0);
                resolvedHeightAxis = requestedHeightAxis;
                if (availableHeight < requestedContentHeight) {
                    CGFloat heightRange = MAX(1.0, requestedContentHeight - minimumContentHeight);
                    CGFloat ratio = MAX(0.0, MIN(1.0,
                        (availableHeight - minimumContentHeight) / heightRange));
                    resolvedHeightAxis = minimumHeightAxis +
                        (requestedHeightAxis - minimumHeightAxis) * ratio;
                    font = [fontStore fontAtPointSize:pointSize heightAxis:resolvedHeightAxis] ?: font;
                }
            }
            NSString *fontDiagnostic = [NSString stringWithFormat:
                @"host=%@ label=%p text=%@ variable=%d source={%@} attributed={%@} original={%@} render={%@} renderIsCustom=%d sourceSize=%.2f scale=%.3f axes=%@ requested[w=%.1f wd=%.1f h=%.1f soft=%.1f] resolvedHeight=%.1f availableHeight=%.1f reason=%@",
                NSStringFromClass(host.class), label, text, variableFontEnabled,
                LGClockFontSummary(label.font), LGClockFontSummary(LGClockAttributedFont(label)),
                LGClockFontSummary(self.originalFont), LGClockFontSummary(font),
                LGClockIsOurFont(font), sourceSize, LGClockFontScale(), fontStore.axisIDs ?: @{},
                LGClockAxisValue(@"weight"), LGClockAxisValue(@"width"),
                requestedHeightAxis, LGClockAxisValue(@"softness"), resolvedHeightAxis,
                availableHeight, reason];
            if (![fontDiagnostic isEqualToString:self.lastFontDiagnostic]) {
                self.lastFontDiagnostic = fontDiagnostic;
                LGClockLog(@"font decision %@", fontDiagnostic);
            }
            NSDictionary *attributes = @{ (__bridge id)kCTFontAttributeName: font };
            NSAttributedString *string = [[NSAttributedString alloc] initWithString:text ?: @""
                                                                          attributes:attributes];
            CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
            CGRect glyphBounds = line
                ? CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds)
                : CGRectZero;
            CGFloat advance = line ? (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL) : 0.0;
            CGPathRef glyphPath = LGClockCreateGlyphPath(line);
            if (line) CFRelease(line);
            if (!glyphPath || CGRectIsEmpty(glyphBounds))
                LGClockLog(@"glyph path unavailable text=%@ font=%@ %.2f bounds=%@ path=%p",
                           text, font.fontName, font.pointSize,
                           NSStringFromCGRect(glyphBounds), glyphPath);

            CGFloat horizontalPadding = 20.0;
            CGFloat verticalPadding = 12.0;
            CGFloat canvasWidth = ceil(MAX(advance, CGRectGetWidth(glyphBounds)) + horizontalPadding * 2.0);
            CGFloat contentHeight = ceil(CGRectGetHeight(glyphBounds) + verticalPadding * 2.0);
            canvasWidth = MAX(canvasWidth, CGRectGetWidth(self.originalLabelFrame));
            CGFloat requestedCanvasHeight = MAX(requestedContentHeight,
                                                CGRectGetHeight(self.originalLabelFrame));
            self.renderCanvasSize = CGSizeMake(MAX(self.renderCanvasSize.width, canvasWidth),
                                               MAX(self.renderCanvasSize.height, requestedCanvasHeight));
            canvasWidth = self.renderCanvasSize.width;
            CGFloat renderHeight = self.renderCanvasSize.height;
            BOOL minimumPhase = !variableFontEnabled || resolvedHeightAxis <= minimumHeightAxis + 0.5;
            NSString *retractionPhase = minimumPhase ? @"translate" : @"axis";
            CGFloat verticalOverflow = nearestTop == CGFLOAT_MAX || !minimumPhase
                ? 0.0 : MAX(0.0, contentHeight - availableHeight);
            CGFloat surfaceTop = CGRectGetMinY(sourceRect) - verticalOverflow
                               + kLGClockVerticalOffset;
            CGFloat glyphOriginY = 0.0;
            CGFloat surfaceHeight = renderHeight;
            if (!variableFontEnabled) {
                CGFloat lineHeight = font.ascender - font.descender;
                CGFloat baseline = (CGRectGetHeight(sourceRect) - lineHeight) * 0.5
                                 + font.ascender;
                surfaceTop = CGRectGetMinY(sourceRect) - verticalPadding;
                surfaceHeight = CGRectGetHeight(sourceRect) + verticalPadding * 2.0;
                glyphOriginY = baseline - CGRectGetMaxY(glyphBounds);
            }
            CGRect labelFrame = CGRectMake(CGRectGetMidX(sourceRect) - canvasWidth * 0.5,
                                           surfaceTop, canvasWidth, surfaceHeight);
            LGLiveBackdropView *glass = self.glassView;
            if (!glass) {
                glass = [[LGLiveBackdropView alloc] initWithFrame:labelFrame
                                                       groupName:nil
                                                      filterType:LGFilterTypeForHostPrefix(@"Clock")];
                glass.userInteractionEnabled = NO;
                glass.backgroundColor = UIColor.clearColor;
                self.glassView = glass;
            }
            if (glass.superview != renderContainer) {
                [glass removeFromSuperview];
                [renderContainer addSubview:glass];
            }
            self.renderContainer = renderContainer;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [glass.layer removeAllAnimations];
            glass.layer.bounds = (CGRect){ CGPointZero, labelFrame.size };
            glass.layer.position = CGPointMake(CGRectGetMidX(labelFrame), CGRectGetMidY(labelFrame));
            glass.clipsToBounds = NO;
            glass.layer.masksToBounds = NO;
            UIView *maskView = self.glyphMaskView;
            CAShapeLayer *maskLayer = self.glyphMaskLayer;
            if (!maskView) {
                maskView = [[UIView alloc] initWithFrame:glass.bounds];
                maskView.backgroundColor = UIColor.clearColor;
                maskLayer = [CAShapeLayer layer];
                maskLayer.fillColor = UIColor.whiteColor.CGColor;
                maskLayer.actions = @{ @"path": NSNull.null, @"bounds": NSNull.null,
                                       @"position": NSNull.null };
                [maskView.layer addSublayer:maskLayer];
                self.glyphMaskView = maskView;
                self.glyphMaskLayer = maskLayer;
            }
            maskView.layer.bounds = glass.bounds;
            maskView.layer.position = CGPointMake(CGRectGetMidX(glass.bounds),
                                                  CGRectGetMidY(glass.bounds));
            maskLayer.frame = maskView.bounds;
            if (glyphPath) {
                CGFloat left = floor((canvasWidth - CGRectGetWidth(glyphBounds)) * 0.5);
                CGAffineTransform transform = CGAffineTransformMake(1.0, 0.0, 0.0, -1.0,
                    left - CGRectGetMinX(glyphBounds),
                    glyphOriginY + verticalPadding + CGRectGetMaxY(glyphBounds));
                CGPathRef normalizedPath = CGPathCreateCopyByTransformingPath(glyphPath, &transform);
                maskLayer.path = normalizedPath;
                profilePrepareEnd = CACurrentMediaTime();
                CFTimeInterval profilePublishStart = profilePrepareEnd;
                BOOL published = LGClockPublishPath(normalizedPath, glass.bounds.size, 1.0);
                profilePublishEnd = CACurrentMediaTime();
                profilePublishDuration = profilePublishEnd - profilePublishStart;
                if (!published)
                    LGClockLog(@"mask publish failed reason=%@ text=%@ glass=%@ path=%@",
                               reason, text, NSStringFromCGRect(glass.bounds),
                               NSStringFromCGRect(CGPathGetBoundingBox(normalizedPath)));
                [glass lgInvalidateFilterContents];
                CGPathRelease(normalizedPath);
                CGPathRelease(glyphPath);
            }
            glass.maskView = maskView;
            [CATransaction commit];
            BOOL filterReady = glass.lgFilterAttached;
            label.alpha = filterReady ? 0.0 : self.originalLabelAlpha;
            label.hidden = self.originalLabelHidden;
            if (visibleSourceView && visibleSourceView != label) {
                visibleSourceView.hidden = filterReady ? YES : self.originalVisibleSourceHidden;
                visibleSourceView.alpha = filterReady ? 0.0 : self.originalVisibleSourceAlpha;
                visibleSourceView.layer.opacity = filterReady ? 0.0 : self.originalVisibleSourceLayerOpacity;
            }
            renderContainer.clipsToBounds = NO;
            renderContainer.layer.masksToBounds = NO;
            [renderContainer bringSubviewToFront:glass];
            if (LGDebugLoggingEnabled()) {
            CGRect glassWindowFrame = glass.window
                ? [glass convertRect:glass.bounds toView:glass.window] : CGRectNull;
            BOOL obstacleChanged = nearestObstacle != self.lastNearestObstacle;
            BOOL nearestJumped = self.lastNearestTop != 0.0 && nearestTop != CGFLOAT_MAX &&
                fabs(nearestTop - self.lastNearestTop) > 4.0;
            BOOL phaseChanged = ![retractionPhase isEqualToString:self.lastRetractionPhase];
            if (obstacleChanged || nearestJumped || phaseChanged) {
                CALayer *obstaclePresentation = nearestObstacle.layer.presentationLayer;
                CGRect obstacleWindowFrame = nearestObstacle.window
                    ? [nearestObstacle convertRect:nearestObstacle.bounds
                                            toView:nearestObstacle.window] : CGRectNull;
                LGClockLog(@"retraction event reason=%@ phase=%@ phaseChanged=%d candidates=%lu obstacleChanged=%d nearestJump=%.1f obstacle=%@ model=%@ present=%@ container=%@ window=%@ source=%@",
                           reason, retractionPhase, phaseChanged,
                           (unsigned long)obstacleCandidates, obstacleChanged,
                           self.lastNearestTop == 0.0 || nearestTop == CGFLOAT_MAX
                               ? 0.0 : nearestTop - self.lastNearestTop,
                           nearestObstacle ? NSStringFromClass(nearestObstacle.class) : @"none",
                           NSStringFromCGRect(nearestObstacleFrame),
                           NSStringFromCGRect(obstaclePresentation ? obstaclePresentation.frame : CGRectNull),
                           NSStringFromCGRect(nearestObstacle.superview
                               ? [nearestObstacle convertRect:nearestObstacle.bounds
                                                       toView:nearestObstacle.superview] : CGRectNull),
                           NSStringFromCGRect(obstacleWindowFrame),
                           NSStringFromCGRect(sourceRect));
            }
            self.lastNearestObstacle = nearestObstacle;
            self.lastNearestTop = nearestTop == CGFLOAT_MAX ? 0.0 : nearestTop;
            self.lastRetractionPhase = retractionPhase;
            if (!CGRectIsNull(glassWindowFrame) &&
                fabs(CGRectGetMinY(glassWindowFrame) - CGRectGetMinY(glass.frame)) > 12.0) {
                NSMutableArray<NSString *> *chain = [NSMutableArray array];
                for (UIView *ancestor = glass; ancestor; ancestor = ancestor.superview) {
                    CGRect windowFrame = ancestor.window
                        ? [ancestor convertRect:ancestor.bounds toView:ancestor.window] : CGRectNull;
                    CALayer *presentation = ancestor.layer.presentationLayer;
                    [chain addObject:[NSString stringWithFormat:@"%@ model=%@ present=%@ window=%@ transform=%@",
                                      NSStringFromClass(ancestor.class),
                                      NSStringFromCGRect(ancestor.frame),
                                      NSStringFromCGRect(presentation ? presentation.frame : CGRectNull),
                                      NSStringFromCGRect(windowFrame),
                                      NSStringFromCGAffineTransform(ancestor.transform)]];
                }
                LGClockLog(@"ancestor mismatch %@", [chain componentsJoinedByString:@" <- "]);
            }
            }
        }
    }
    self.applying = NO;
    self.appliedChanges++;
    CFTimeInterval elapsed = CACurrentMediaTime() - start;
    self.totalApplyTime += elapsed;
    self.peakApplyTime = MAX(self.peakApplyTime, elapsed);
    if (profilePrepareEnd == profileObstacleEnd) profilePrepareEnd = start + elapsed;
    CFTimeInterval finishStart = profilePublishDuration > 0.0
        ? profilePublishEnd : profilePrepareEnd;
    (void)finishStart;
    LGClockProfileSample(YES, profileObstacleEnd - start,
                         profilePrepareEnd - profileObstacleEnd,
                         profilePublishDuration,
                         MAX(0.0, start + elapsed - finishStart), elapsed);
    [self emitSummaryIfNeeded];
}

- (void)emitSummaryIfNeeded {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.sampleStart < 2.0) return;
    LGClockLog(@"perf host=%@ layouts=%lu applies=%lu skips=%lu total_ms=%.3f peak_ms=%.3f",
               NSStringFromClass(self.host.class), (unsigned long)self.layoutCalls,
               (unsigned long)self.appliedChanges, (unsigned long)self.skippedChanges,
               self.totalApplyTime * 1000.0, self.peakApplyTime * 1000.0);
    self.layoutCalls = 0;
    self.appliedChanges = 0;
    self.skippedChanges = 0;
    self.totalApplyTime = 0;
    self.peakApplyTime = 0;
    self.sampleStart = now;
}

- (void)restore {
    if (LGDebugLoggingEnabled())
        LGClockLog(@"restore begin state=%p host=%p source=%p enabled=%d applying=%d scheduled=%d text=%@ direct={%@} attributed={%@} stateCached={%@} associatedCached={%@} glass=%p alpha=%.2f hidden=%d",
                   self, self.host, self.sourceLabel, LGClockEnabled(), self.applying,
                   self.scheduled, self.sourceLabel.text ?: self.sourceLabel.attributedText.string,
                   LGClockFontSummary(self.sourceLabel.font), LGClockFontSummary(LGClockAttributedFont(self.sourceLabel)),
                   LGClockFontSummary(self.originalFont),
                   LGClockFontSummary(objc_getAssociatedObject(self.sourceLabel, kLGClockOriginalFontKey)),
                   self.glassView, self.sourceLabel.alpha, self.sourceLabel.hidden);
    if (self.sourceLabel && !self.applying) {
        self.applying = YES;
        if (self.originalFont) self.sourceLabel.font = self.originalFont;
        self.sourceLabel.alpha = self.originalLabelAlpha;
        self.sourceLabel.hidden = self.originalLabelHidden;
        self.applying = NO;
    }
    if (LGDebugLoggingEnabled() && self.sourceLabel)
        LGClockLog(@"restore applied state=%p source=%p direct={%@} attributed={%@} alpha=%.2f hidden=%d",
                   self, self.sourceLabel, LGClockFontSummary(self.sourceLabel.font),
                   LGClockFontSummary(LGClockAttributedFont(self.sourceLabel)),
                   self.sourceLabel.alpha, self.sourceLabel.hidden);
    if (self.visibleSourceView) {
        self.visibleSourceView.hidden = self.originalVisibleSourceHidden;
        self.visibleSourceView.alpha = self.originalVisibleSourceAlpha;
        self.visibleSourceView.layer.opacity = self.originalVisibleSourceLayerOpacity;
    }
    self.glassView.maskView = nil;
    [self.glassView removeFromSuperview];
    self.glassView = nil;
    self.glyphMaskView = nil;
    self.glyphMaskLayer = nil;
    self.renderContainer = nil;
    self.sourceLabel = nil;
    self.visibleSourceView = nil;
    self.originalFont = nil;
    self.renderCanvasSize = CGSizeZero;
    self.lastSignature = nil;
    self.lastFontDiagnostic = nil;
}

@end

static LGClockState *LGClockStateForHost(UIView *host, BOOL create) {
    if (!LGClockIsHost(host)) return nil;
    LGClockState *state = objc_getAssociatedObject(host, kLGClockStateKey);
    if (!state && create) {
        state = [LGClockState new];
        state.host = host;
        [LGClockStates() addObject:state];
        objc_setAssociatedObject(host, kLGClockStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGClockLog(@"host attached class=%@ frame=%@ bounds=%@ window=%@",
                   NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
                   NSStringFromCGRect(host.bounds), NSStringFromClass(host.window.class));
    }
    return state;
}

static void LGClockSourceFontDidChange(UILabel *label, UIFont *candidate, NSString *reason) {
    UIView *host = label.superview;
    while (host && !LGClockIsHost(host)) host = host.superview;
    if (!host) return;

    UIFont *attributedFont = LGClockAttributedFont(label);
    UIFont *font = candidate ?: attributedFont ?: label.font;
    if (!LGClockEnabled()) {
        if (LGDebugLoggingEnabled())
            LGClockLog(@"font event passive-disabled reason=%@ label=%p host=%p text=%@ candidate={%@} direct={%@} attributed={%@} alpha=%.2f hidden=%d stack=%@",
                       reason, label, host, label.text ?: label.attributedText.string,
                       LGClockFontSummary(candidate), LGClockFontSummary(label.font),
                       LGClockFontSummary(attributedFont), label.alpha, label.hidden,
                       NSThread.callStackSymbols);
        return;
    }

    LGClockState *state = LGClockStateForHost(host, YES);
    UIFont *associatedFont = objc_getAssociatedObject(label, kLGClockOriginalFontKey);
    if (LGDebugLoggingEnabled())
        LGClockLog(@"font event reason=%@ label=%p host=%p window=%@ enabled=%d variable=%d applying=%d sourceMatch=%d text=%@ candidate={%@} direct={%@} attributed={%@} stateCached={%@} associatedCached={%@} glass=%p alpha=%.2f hidden=%d stack=%@",
                   reason, label, host, NSStringFromClass(host.window.class),
                   LGClockEnabled(), LGClockVariableFontEnabled(), state.applying,
                   state.sourceLabel == label, label.text ?: label.attributedText.string,
                   LGClockFontSummary(candidate), LGClockFontSummary(label.font),
                   LGClockFontSummary(attributedFont), LGClockFontSummary(state.originalFont),
                   LGClockFontSummary(associatedFont), state.glassView,
                   label.alpha, label.hidden, NSThread.callStackSymbols);
    if (state.applying || !font || LGClockIsOurFont(font)) {
        if (LGDebugLoggingEnabled())
            LGClockLog(@"font capture rejected reason=%@ applying=%d missing=%d custom=%d selected={%@}",
                       reason, state.applying, font == nil, LGClockIsOurFont(font),
                       LGClockFontSummary(font));
        return;
    }

    UIFont *previous = state.originalFont;
    state.originalFont = font;
    objc_setAssociatedObject(label, kLGClockOriginalFontKey,
                             font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGClockLog(@"font capture accepted reason=%@ enabled=%d label=%p previous={%@} selected={%@} direct={%@} attributed={%@}",
               reason, LGClockEnabled(), label,
               LGClockFontSummary(previous), LGClockFontSummary(font),
               LGClockFontSummary(label.font), LGClockFontSummary(attributedFont));
}

static void LGClockSourceTextDidChange(UILabel *label) {
    UIView *host = label.superview;
    while (host && !LGClockIsHost(host)) host = host.superview;
    if (!host) {
        if (LGDebugLoggingEnabled() && LGClockLooksLikeTime(label.text ?: label.attributedText.string))
            LGClockLog(@"time update has no host label=%@ text=%@ font=%@ %.2f window=%@",
                       NSStringFromClass(label.class), label.text ?: label.attributedText.string,
                       label.font.fontName, label.font.pointSize,
                       NSStringFromClass(label.window.class));
        return;
    }
    if (!LGClockEnabled()) {
        if (LGDebugLoggingEnabled())
            LGClockLog(@"time event passive-disabled label=%p text=%@ direct={%@} attributed={%@} host=%p window=%@ alpha=%.2f hidden=%d",
                       label, label.text ?: label.attributedText.string,
                       LGClockFontSummary(label.font), LGClockFontSummary(LGClockAttributedFont(label)),
                       host, NSStringFromClass(host.window.class), label.alpha, label.hidden);
        return;
    }

    LGClockState *state = LGClockStateForHost(host, YES);
    if (state.applying) {
        [state scheduleApply:@"text-after-apply"];
        return;
    }
    LGClockSourceFontDidChange(label, nil, @"text");
    LGClockLog(@"time update label=%@ text=%@ font=%@ %.2f host=%@ stateSource=%@",
               NSStringFromClass(label.class), label.text ?: label.attributedText.string,
               label.font.fontName, label.font.pointSize, NSStringFromClass(host.class),
               state.sourceLabel.text ?: state.sourceLabel.attributedText.string);
    [state scheduleApply:@"text"];
}

static void LGClockHostDidMove(UIView *host) {
    LGClockState *state = LGClockStateForHost(host, LGClockEnabled() && host.window != nil);
    if (!LGClockEnabled()) {
        if (LGDebugLoggingEnabled())
            LGClockLog(@"host move passive-disabled host=%p window=%@ existingState=%p labels=%@",
                       host, NSStringFromClass(host.window.class), state, LGClockLabelSummary(host));
        [state restore];
        objc_setAssociatedObject(host, kLGClockStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!host.window) {
        [state restore];
        objc_setAssociatedObject(host, kLGClockStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    [state scheduleApply:@"window"];
}

static void LGClockHostDidLayout(UIView *host) {
    if (!LGClockEnabled()) return;
    [LGClockStateForHost(host, YES) scheduleApply:@"layout"];
}

static void LGClockRefreshWindows(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (LGClockIsDateLabel(view)) LGClockApplyDateText((UILabel *)view);
            if (LGClockIsHost(view)) {
                LGClockState *state = LGClockStateForHost(view, LGClockEnabled());
                if (LGClockEnabled()) [state scheduleApply:@"prefs"];
                else [state restore];
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

static void LGClockReconcilePreferenceReload(void) {
    NSArray<LGClockState *> *states = LGClockStates().allObjects;
    BOOL enabled = LGClockEnabled();
    LGClockLog(@"prefs reconcile enabled=%d states=%lu", enabled,
               (unsigned long)states.count);
    if (enabled) {
        LGClockRefreshWindows();
        return;
    }
    for (LGClockState *state in states) {
        UIView *host = state.host;
        LGClockLog(@"prefs disable restoring state=%p host=%p source=%p hostWindow=%@ sourceText=%@ sourceDirect={%@} sourceAttributed={%@} cached={%@} associated={%@} glass=%p",
                   state, host, state.sourceLabel, NSStringFromClass(host.window.class),
                   state.sourceLabel.text ?: state.sourceLabel.attributedText.string,
                   LGClockFontSummary(state.sourceLabel.font),
                   LGClockFontSummary(LGClockAttributedFont(state.sourceLabel)),
                   LGClockFontSummary(state.originalFont),
                   LGClockFontSummary(objc_getAssociatedObject(state.sourceLabel, kLGClockOriginalFontKey)),
                   state.glassView);
        [state restore];
        if (LGClockIsLegacyHost(host)) LGClockPositionLegacyDateSubtitle(host);
    }
}

static void LGClockObstacleDidChange(UIView *view) {
    if (view) [LGClockObstacleViews() addObject:view];
    LGClockScheduleKnownStates(@"obstacle");
    [[LGClockMotionTracker shared] trackMotion];
}

void LGScheduleClockRecoveryRefreshForPresentationChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ LGClockRefreshWindows(); });
}

@interface MRUArtworkView : UIView
@end

static UIImageView *LGArtworkImageView(UIView *artworkView) {
    Ivar ivar = class_getInstanceVariable([artworkView class], "_artworkImageView");
    if (ivar) {
        id value = object_getIvar(artworkView, ivar);
        if ([value isKindOfClass:UIImageView.class]) return value;
    }
    for (UIView *sub in artworkView.subviews.reverseObjectEnumerator) {
        if (![sub isKindOfClass:UIImageView.class] || sub.hidden) continue;
        if (sub.contentMode == UIViewContentModeScaleAspectFit &&
            sub.layer.cornerRadius > 0.5 && sub.clipsToBounds) {
            return (UIImageView *)sub;
        }
    }
    return nil;
}

static BOOL LGIsCoverSheetArtworkView(UIView *artworkView) {
    return hasAncestorOfClassName(artworkView,
                                  @"MediaRemoteUI.CoverSheetBackgroundView") ||
           hasAncestorOfClassName(artworkView, @"CoverSheetBackgroundView");
}

static void LGPublishArtworkRect(UIView *artworkView) {
    if (!LGIsCoverSheetArtworkView(artworkView)) return;

    UIWindow *window = artworkView.window;
    UIImageView *image = LGArtworkImageView(artworkView);
    BOOL visible = window && image && !image.hidden && image.alpha > 0.01 &&
                   !artworkView.hidden && artworkView.alpha > 0.01 &&
                   image.image != nil && lgHostEnabled(@"Clock");
    if (!visible) {
        LGLensRectWrite(LGLensRectSlotNowPlayingArtwork, NO, 0.f, 0.f, 0.f, 0.f);
        return;
    }

    CGRect rect = [image convertRect:image.bounds toView:window];
    CGSize screen = window.bounds.size;
    if (screen.width < 1.0 || screen.height < 1.0) return;
    LGLensRectWrite(LGLensRectSlotNowPlayingArtwork, YES,
                    CGRectGetMinX(rect) / screen.width,
                    CGRectGetMinY(rect) / screen.height,
                    CGRectGetWidth(rect) / screen.width,
                    CGRectGetHeight(rect) / screen.height);
}

%group LGNowPlayingArtwork

%hook MRUArtworkView

- (void)layoutSubviews {
    %orig;
    LGPublishArtworkRect((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGPublishArtworkRect((UIView *)self);
}

- (void)dealloc {
    if (LGIsCoverSheetArtworkView((UIView *)self))
        LGLensRectWrite(LGLensRectSlotNowPlayingArtwork, NO, 0.f, 0.f, 0.f, 0.f);
    %orig;
}

%end

%end

%group LGClockRewrite

%hook _UIAnimatingLabel
- (void)setFont:(UIFont *)font {
    if (LGDebugLoggingEnabled() && LGClockLooksLikeTime(((UILabel *)self).text ?: ((UILabel *)self).attributedText.string))
        LGClockLog(@"setFont entering label=%p supplied={%@} currentDirect={%@} currentAttributed={%@}",
                   self, LGClockFontSummary(font), LGClockFontSummary(((UILabel *)self).font),
                   LGClockFontSummary(LGClockAttributedFont((UILabel *)self)));
    %orig(font);
    LGClockSourceFontDidChange((UILabel *)self, font, @"setFont");
}
- (void)setText:(NSString *)text {
    %orig(text);
    if (LGClockIsDateLabel((UIView *)self)) {
        LGClockApplyDateText((UILabel *)self);
        return;
    }
    LGClockSourceTextDidChange((UILabel *)self);
}
- (void)setAttributedText:(NSAttributedString *)text {
    %orig(text);
    if (LGClockIsDateLabel((UIView *)self)) {
        LGClockApplyDateText((UILabel *)self);
        return;
    }
    LGClockSourceTextDidChange((UILabel *)self);
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig(text);
    if (LGClockIsDateLabel((UIView *)self)) {
        LGClockApplyDateText((UILabel *)self);
        return;
    }
    if (LGClockIsLegacySystem() &&
        LGClockLabelIsInsideClass((UILabel *)self, nil, @"SBUILegibilityLabel")) {
        LGClockSourceTextDidChange((UILabel *)self);
    }
}
- (void)setAttributedText:(NSAttributedString *)text {
    %orig(text);
    if (LGClockIsDateLabel((UIView *)self)) {
        LGClockApplyDateText((UILabel *)self);
        return;
    }
    if (LGClockIsLegacySystem() &&
        LGClockLabelIsInsideClass((UILabel *)self, nil, @"SBUILegibilityLabel")) {
        LGClockSourceTextDidChange((UILabel *)self);
    }
}
%end

%hook CSProminentTimeView
- (void)didMoveToWindow { %orig; LGClockHostDidMove((UIView *)self); }
- (void)layoutSubviews { %orig; LGClockHostDidLayout((UIView *)self); }
%end

%hook SBFLockScreenDateView
- (void)didMoveToWindow {
    %orig;
    UIView *host = (UIView *)self;
    if (LGClockIsLegacySystem()) {
        LGClockApplyDateTextInView(host);
        LGClockPositionLegacyDateSubtitle(host);
    }
    LGClockHostDidMove(host);
}
- (void)layoutSubviews {
    %orig;
    UIView *host = (UIView *)self;
    if (LGClockIsLegacySystem()) {
        LGClockApplyDateTextInView(host);
        LGClockPositionLegacyDateSubtitle(host);
    }
    LGClockHostDidLayout(host);
}
%end

%hook SBFLockScreenDateSubtitleDateView
- (void)didMoveToWindow {
    %orig;
    if (LGClockIsLegacySystem()) {
        LGClockApplyDateTextInView((UIView *)self);
        UIView *host = ((UIView *)self).superview;
        while (host && !LGClockIsLegacyHost(host)) host = host.superview;
        LGClockPositionLegacyDateSubtitle(host);
    }
}
- (void)layoutSubviews {
    %orig;
    if (LGClockIsLegacySystem()) {
        LGClockApplyDateTextInView((UIView *)self);
        UIView *host = ((UIView *)self).superview;
        while (host && !LGClockIsLegacyHost(host)) host = host.superview;
        LGClockPositionLegacyDateSubtitle(host);
    }
}
%end

%hook PLPlatterView
- (void)didMoveToWindow { %orig; LGClockObstacleDidChange((UIView *)self); }
- (void)layoutSubviews { %orig; LGClockObstacleDidChange((UIView *)self); }
%end

%hook NCNotificationShortLookView
- (void)didMoveToWindow { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
- (void)layoutSubviews { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
%end

%hook NCNotificationLongLookView
- (void)didMoveToWindow { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
- (void)layoutSubviews { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
%end

%hook NCNotificationListSectionRevealHintView
- (void)didMoveToWindow { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
- (void)layoutSubviews { %orig; if (LGClockIsLegacySystem()) LGClockObstacleDidChange((UIView *)self); }
%end

%hook NCNotificationListHeaderTitleView
- (void)didMoveToWindow { %orig; LGClockObstacleDidChange((UIView *)self); }
- (void)layoutSubviews { %orig; LGClockObstacleDidChange((UIView *)self); }
%end

%hook NCNotificationListView
- (void)setFrame:(CGRect)frame {
    UIView *listView = (UIView *)self;
    if (![objc_getAssociatedObject(listView, kLGClockLegacyNotificationApplyingKey) boolValue]) {
        frame = LGClockAdjustedLegacyNotificationFrame(listView, frame);
    }
    %orig(frame);
}
- (void)setContentOffset:(CGPoint)offset {
    %orig(offset);
    LGClockObstacleDidChange(nil);
}
- (void)didMoveToWindow {
    %orig;
    LGClockScheduleLegacyNotificationRelayout((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGClockScheduleLegacyNotificationRelayout((UIView *)self);
}
%end

%hook NCNotificationStructuredListViewController
- (void)viewWillLayoutSubviews {
    %orig;
    if (LGClockIsLegacySystem()) {
        UIView *listView = LGClockFindDescendantNamed(((UIViewController *)self).view,
                                                       @"NCNotificationListView");
        LGClockScheduleLegacyNotificationRelayout(listView);
    }
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (LGClockIsLegacySystem()) {
        UIView *listView = LGClockFindDescendantNamed(((UIViewController *)self).view,
                                                       @"NCNotificationListView");
        LGClockScheduleLegacyNotificationRelayout(listView);
    }
}
%end

%end

%ctor {
    if (objc_getClass("MRUArtworkView")) %init(LGNowPlayingArtwork);

    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    LGClockLog(@"rewrite ctor os=%@ sim=%d font=%@ hostModern=%@ hostLegacy=%@ animLabel=%@ enabled=%d variable=%d",
               UIDevice.currentDevice.systemVersion, TARGET_OS_SIMULATOR,
               LGClockVariableFontPath(), NSClassFromString(@"CSProminentTimeView"),
               NSClassFromString(@"SBFLockScreenDateView"), NSClassFromString(@"_UIAnimatingLabel"),
               LGClockEnabled(), LGClockVariableFontEnabled());
    [LGClockFontStore shared];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"LGLiveBackdropViewFilterDidAttach"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
                    LGClockRefreshWindows();
                }];
    lgObservePreferenceReload(^{ LGClockReconcilePreferenceReload(); });
    %init(LGClockRewrite);
}
