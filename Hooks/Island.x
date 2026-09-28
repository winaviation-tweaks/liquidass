#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGLiveBackdropView.h"

// gain map 替换层 LGIslandGainMapLayer：带 renderMode 属性的 CALayer 子类（无自定义渲染，
// 不画黑胶囊）。父类 _SBSystemApertureGainMapView 的 initWithFrame: 会调 [layer setRenderMode:]，
// 所以替换 gain map 的 layerClass 时，这个 layer 必须有 renderMode 属性——之前用普通 CALayer
// 直接 unrecognized selector 崩进安全模式。
@interface LGIslandGainMapLayer : CALayer
@property (nonatomic, copy) NSString *renderMode;
@end
@implementation LGIslandGainMapLayer
@end

// ============================================================================
// 灵动岛液态玻璃。
//
// 岛玻璃 = LGLiveBackdropView（CABackdropLayer 实时采样，
// 不是抓壁纸图）。iOS 17 壁纸是 PosterBoard 远程渲染（CARemoteLayer），CPU 侧
// renderInContext/snapshot 全抓不到（这就是之前一直"黑"的根因）；但 CABackdropLayer
// 是在合成器里采样身后已合成的帧（含远程壁纸），所以能透出壁纸。
//
// "黑岛"的另一半根因：岛容器里 `_blobEnablingBlackFillView`（黑填充）和
// `_gainMapView`（黑渲染 gain map）没藏掉，把身后全遮住了。
//
// 实现要点：
//   ① hook SBSystemApertureContainerView（容器，不是 CurtainView）；
//   ② 按 ivar 名取 4 个子视图：_blobEnablingBlackFillView / _gainMapView /
//      _backgroundGroupingView / _contentClippingView；
//   ③ 藏掉 fill + gainMap（hidden=YES + alpha=0）；
//   ④ 建 LGLiveBackdropView，[clipHost insertSubview:glass atIndex:0]；
//   ⑤ 同步圆角/圆角曲线/masksToBounds。
//
// 本实现：藏黑三层 + 玻璃透壁纸 + rim 高光棱边 + 形变几何同步。
// ============================================================================

static const void *kLGIslandGlassKey     = &kLGIslandGlassKey;
static const void *kLGIslandLastFrameKey = &kLGIslandLastFrameKey;
static const void *kLGIslandLastRadiusKey = &kLGIslandLastRadiusKey;
static const void *kLGIslandRimLayerKey  = &kLGIslandRimLayerKey;
static const void *kLGIslandRimMaskKey   = &kLGIslandRimMaskKey;

static bool sLGIslandApplying = false;

static void LGIslandLog(NSString *fmt, ...) {
    static int count = 0;
    if (count >= 120) return;
    count++;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"island: %@", msg);
}

// 按 ivar 名取子视图：class_getInstanceVariable + object_getIvar + isKindOfClass 校验。
// ⚠️ 沿继承链向上查（锁屏岛容器可能是 SBSystemApertureContainerView 的子类，ivar 声明在
// 父类上；class_getInstanceVariable 只查本类，不查父类）。
static UIView *LGIslandSubviewByIvar(UIView *container, const char *ivarName) {
    if (!container || !ivarName) return nil;
    Class cls = object_getClass(container);
    Ivar ivar = NULL;
    while (cls && !ivar) {
        ivar = class_getInstanceVariable(cls, ivarName);
        if (!ivar) cls = class_getSuperclass(cls);
    }
    if (!ivar) return nil;
    id value = object_getIvar(container, ivar);
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

// 诊断：dump 容器子视图树（类名/frame/hidden/alpha/背景色），budget 限总行数。
static void LGIslandDumpTree(UIView *view, int depth, int *budget) {
    if (!view || depth > 6 || *budget <= 0) return;
    (*budget)--;
    NSMutableString *line = [NSMutableString string];
    for (int i = 0; i < depth; i++) [line appendString:@"  "];
    NSString *bg = @"nil";
    if (view.backgroundColor) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [view.backgroundColor getRed:&r green:&g blue:&b alpha:&a];
        bg = [NSString stringWithFormat:@"%.2f,%.2f,%.2f,%.2f", r, g, b, a];
    }
    [line appendFormat:@"%@ frame=%@ hidden=%d alpha=%.2f bg=%@",
        NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
        view.hidden, view.alpha, bg];
    LGIslandLog(@"%@", line);
    for (UIView *sub in view.subviews) LGIslandDumpTree(sub, depth + 1, budget);
}

// 藏幕布（_SBSystemApertureMagiciansCurtainView）：岛的黑色胶囊背景。
// 在容器树里递归找到实例并藏掉——layoutSubviews 频繁触发，每次都会重新藏，
// 可覆盖系统在岛状态变化时的重新显示，无需额外 hook。
static void LGIslandHideCurtainInView(UIView *view, Class curtainCls, int depth) {
    if (!view || depth > 4 || !curtainCls) return;
    if ([view isKindOfClass:curtainCls]) {
        view.hidden = YES;
        view.alpha = 0.0;
    }
    for (UIView *sub in view.subviews) {
        LGIslandHideCurtainInView(sub, curtainCls, depth + 1);
    }
}

// 液态玻璃 rim：胶囊内边缘一圈 conic 渐变高光（顶亮 → 底暗带反光），
// mask 用 stroke 环；glass 层 masksToBounds 会裁掉 stroke 外半，留下内缘 1pt 高光棱边。
static void LGIslandAttachRim(LGLiveBackdropView *glass, CGSize size, CGFloat radius) {
    if (!glass || size.width < 1.0 || size.height < 1.0) return;
    CAGradientLayer *rim = objc_getAssociatedObject(glass, kLGIslandRimLayerKey);
    CAShapeLayer *mask = objc_getAssociatedObject(glass, kLGIslandRimMaskKey);
    if (!rim) {
        rim = [CAGradientLayer layer];
        if (@available(iOS 12.0, *)) rim.type = kCAGradientLayerConic;
        rim.startPoint = CGPointMake(0.5, 0.5);   // 圆心
        rim.endPoint   = CGPointMake(0.5, 0.0);   // 起始角=12点方向，顺时针
        rim.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.55].CGColor,  // 顶部高光
            (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,  // 右侧
            (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,  // 底部最暗
            (id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,  // 左侧/底部反光
            (id)[UIColor colorWithWhite:1.0 alpha:0.55].CGColor   // 闭环回顶部
        ];
        rim.locations = @[@0.0, @0.25, @0.5, @0.75, @1.0];
        rim.masksToBounds = NO;
        mask = [CAShapeLayer layer];
        mask.fillColor   = [UIColor clearColor].CGColor;   // 内部镂空
        mask.strokeColor = [UIColor whiteColor].CGColor;   // stroke 环不透明
        mask.lineWidth   = 2.0;                            // glass 裁剪后内缘 ≈1pt
        rim.mask = mask;
        objc_setAssociatedObject(glass, kLGIslandRimLayerKey, rim,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(glass, kLGIslandRimMaskKey, mask,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [glass.layer addSublayer:rim];
    }
    CGRect frame = CGRectMake(0.0, 0.0, size.width, size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    rim.frame  = frame;
    mask.frame = frame;
    mask.path  = [UIBezierPath bezierPathWithRoundedRect:frame
                                            cornerRadius:radius].CGPath;
    rim.hidden = NO;
    [CATransaction commit];
}

static void LGIslandEnsureGlass(UIView *container) {
    if (sLGIslandApplying) return;
    if (!lgHostEnabled(@"Island")) { LGIslandLog(@"host disabled"); return; }
    if (!container || !container.window) return;
    if (container.bounds.size.width < 1.0 || container.bounds.size.height < 1.0) return;

    UIView *fill     = LGIslandSubviewByIvar(container, "_blobEnablingBlackFillView");
    UIView *gainMap  = LGIslandSubviewByIvar(container, "_gainMapView");
    UIView *clipHost = LGIslandSubviewByIvar(container, "_contentClippingView");
    if (!fill || !gainMap || !clipHost) {
        static int logged = 0;
        if (logged < 3) {
            logged++;
            LGIslandLog(@"subviews missing on %@ fill=%p gainMap=%p clipHost=%p",
                        NSStringFromClass(container.class),
                        (__bridge void *)fill, (__bridge void *)gainMap, (__bridge void *)clipHost);
        }
        return;
    }
    if (CGRectIsEmpty(clipHost.bounds)) return;

    sLGIslandApplying = true;

    // ① 藏黑填充 + 黑 gain map + 幕布（幕布是黑色胶囊背景，
    //    不藏会透过玻璃显出黑胶囊轮廓）。
    fill.hidden = YES;
    fill.alpha = 0.0;
    gainMap.hidden = YES;
    gainMap.alpha = 0.0;
    static Class sLGIslandCurtainClass = nil;
    if (!sLGIslandCurtainClass) sLGIslandCurtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    LGIslandHideCurtainInView(container, sLGIslandCurtainClass, 0);
    // 同时把容器自身的黑底清掉（若容器 backgroundColor 是黑的，同样会透过玻璃显黑）
    if (container.backgroundColor && ![container.backgroundColor isEqual:[UIColor clearColor]]) {
        static int bgLogged = 0;
        if (bgLogged < 3) {
            bgLogged++;
            LGIslandLog(@"container bg=%@ (cleared)", container.backgroundColor);
        }
        container.backgroundColor = [UIColor clearColor];
    }
    // 诊断：dump 容器子视图树（限 2 次，看黑色胶囊到底是哪个视图）
    static int dumpCount = 0;
    if (dumpCount < 2) {
        dumpCount++;
        int budget = 48;
        LGIslandLog(@"dump#%d container=%@", dumpCount, NSStringFromClass(container.class));
        LGIslandDumpTree(container, 1, &budget);
    }

    // ② 玻璃（live backdrop）。
    // 岛专属滤镜 `dylv.liquidglass.island` 优先。但 backboardd 的滤镜是**首次渲染时惰性注册**的，
    // 若干环境（例如未重新编译的旧 backboardd 二进制）尚未注册 island 滤镜，filterWithType 会返回
    // nil → 玻璃无滤镜 = 纯透明。故做兜底：检测滤镜未附上时改用已注册的 banner 滤镜重建，
    // 保证任何环境下岛都能透出壁纸（代价是这类环境下岛的渲染参数跟随 banner）。
    LGLiveBackdropView *glass = objc_getAssociatedObject(clipHost, kLGIslandGlassKey);
    if (!glass) {
        NSString *ft = LGFilterTypeForHostPrefix(@"Island");
        if (!ft.length) ft = LGFilterTypeForHostPrefix(@"Banner");
        if (!ft.length) { sLGIslandApplying = false; return; }
        glass = [[LGLiveBackdropView alloc] initWithFrame:clipHost.bounds
                                                groupName:nil
                                               filterType:ft];
        if (!glass) { sLGIslandApplying = false; return; }
        // Island 滤镜没注册上（filterWithType 拿到 nil）→ 换 banner 滤镜重建
        if (![glass lgFilterAttached]) {
            NSString *fallback = LGFilterTypeForHostPrefix(@"Banner");
            if (fallback.length && ![fallback isEqualToString:ft]) {
                glass = [[LGLiveBackdropView alloc] initWithFrame:clipHost.bounds
                                                        groupName:nil
                                                       filterType:fallback];
                if (!glass) { sLGIslandApplying = false; return; }
            }
        }
        // 参数前缀覆盖：玻璃借用 banner 滤镜，但 prefs 参数（色调/高光/模糊）
        // 改读「灵动岛」前缀 —— 设置里灵动岛页面的滑块由此生效。
        // ⚠️ 用 respondsToSelector + performSelector 而非直接属性赋值：作者新版若无此属性，
        //    本文件照样能编译、岛照样透壁纸，只是滑块不生效（优雅降级）。
        //    （backboardd 渲染参数——厚度/折射——仍跟 banner 滤镜走，见文件头注释。）
        SEL selOverride = NSSelectorFromString(@"setLgPreferencePrefixOverride:");
        if ([glass respondsToSelector:selOverride]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [glass performSelector:selOverride withObject:@"Island"];
#pragma clang diagnostic pop
        }
        objc_setAssociatedObject(clipHost, kLGIslandGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 底部插入：clipHost 是透明裁剪视图，玻璃垫底、岛上内容浮在上面。
        [clipHost insertSubview:glass atIndex:0];
        LGIslandLog(@"glass created in %@ subviews=%lu",
                    NSStringFromClass(clipHost.class),
                    (unsigned long)clipHost.subviews.count);
    }

    // ③ 几何 + 圆角同步（帧变了才重摆）。
    NSValue *lastFrame = objc_getAssociatedObject(clipHost, kLGIslandLastFrameKey);
    NSNumber *lastRadius = objc_getAssociatedObject(clipHost, kLGIslandLastRadiusKey);
    NSValue *curFrame = [NSValue valueWithCGRect:clipHost.bounds];
    CGFloat radius = fill.layer.cornerRadius;
    BOOL frameChanged = !lastFrame || ![lastFrame isEqual:curFrame];
    BOOL radiusChanged = !lastRadius || fabs(lastRadius.doubleValue - radius) > 0.01;

    if (frameChanged || radiusChanged) {
        objc_setAssociatedObject(clipHost, kLGIslandLastFrameKey, curFrame,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(clipHost, kLGIslandLastRadiusKey, @(radius),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glass.frame = clipHost.bounds;
        glass.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *))
            glass.layer.cornerCurve = fill.layer.cornerCurve;
        glass.layer.masksToBounds = YES;
        LGIslandAttachRim(glass, clipHost.bounds.size, radius);
        LGIslandLog(@"glass geometry frame=%@ radius=%.1f fillHidden=%d gainHidden=%d",
                    NSStringFromCGRect(clipHost.bounds), radius,
                    fill.hidden, gainMap.hidden);
    }

    sLGIslandApplying = false;
}

// hook 容器 SBSystemApertureContainerView（不是 CurtainView）。
static void (*origContainerLayoutSubviews)(id, SEL);
static void (*origContainerDidMoveToWindow)(id, SEL);

static void containerLayoutSubviews(id self, SEL _cmd) {
    if (origContainerLayoutSubviews) origContainerLayoutSubviews(self, _cmd);
    LGIslandEnsureGlass((UIView *)self);
}

static void containerDidMoveToWindow(id self, SEL _cmd) {
    if (origContainerDidMoveToWindow) origContainerDidMoveToWindow(self, _cmd);
    LGIslandEnsureGlass((UIView *)self);
}

// ⚠️ 关键：换掉 gain map 的特殊黑色 layer。_SBGainMapView 的 layer 是系统 gain-map 特殊层，靠它渲染
// 黑色胶囊形状；只 hidden=YES 藏视图压不住这个 layer 的黑（dump 树里容器内无一黑视图，但
// 屏幕仍有黑胶囊，根因就在这）。直接把 layerClass 换成普通透明 CALayer，从根上消黑。
static Class (*origGainMapLayerClass)(id, SEL);
static Class gainMapLayerClass(id self, SEL _cmd) {
    return [LGIslandGainMapLayer class];
}

static void LGIslandHookClasses(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = objc_getClass("SBSystemApertureContainerView");
        if (!c) { LGIslandLog(@"container class NOT found"); return; }

        Method m1 = class_getInstanceMethod(c, @selector(layoutSubviews));
        if (m1 && !origContainerLayoutSubviews) {
            origContainerLayoutSubviews = (void (*)(id, SEL))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)containerLayoutSubviews);
        }
        Method m2 = class_getInstanceMethod(c, @selector(didMoveToWindow));
        if (m2 && !origContainerDidMoveToWindow) {
            origContainerDidMoveToWindow = (void (*)(id, SEL))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)containerDidMoveToWindow);
        }
        LGIslandLog(@"hooked %@ layout=%d didMove=%d", NSStringFromClass(c),
                    origContainerLayoutSubviews != NULL, origContainerDidMoveToWindow != NULL);

        // gain map layerClass 替换
        Class gm = objc_getClass("_SBGainMapView");
        if (gm) {
            Method lm = class_getClassMethod(gm, @selector(layerClass));
            if (lm && !origGainMapLayerClass) {
                origGainMapLayerClass = (Class (*)(id, SEL))method_getImplementation(lm);
                method_setImplementation(lm, (IMP)gainMapLayerClass);
            }
            LGIslandLog(@"gainMap %@ layerClass hooked=%d", NSStringFromClass(gm), lm != NULL);
        } else {
            LGIslandLog(@"gainMap class NOT found");
        }
    });
}

%ctor {
    LGIslandHookClasses();
    LGIslandLog(@"ctor ready");
}
