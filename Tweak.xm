// ============================================================================
// Tweak.xm — 无忧行 (com.cmi.jegotrip) 界面精简 Tweak
// v0.2 探针版（只观测，不修改界面）
// ============================================================================
// 目标（已与 Shawn 确认）：
//   1) 把「首页 / 目的地 / 流量」这三个 **tab 从导航栏移除**，App 直接落到剩下的 tab；
//   2) 拦掉开屏广告与启动弹窗；
//   3) 清掉剩余的广告/营销位。
//
// 为什么这一版仍然是"探针"而不是直接写规则：
//   无忧行是原生 + H5 混合的国产 App，tab bar **很可能不是系统 UITabBarController**
//   而是自绘容器。这两条路线的改法完全不同，猜错就是白跑一轮构建。
//   所以本版不做任何修改，只把"tab 是怎么建出来的"这件事拿到**直接证据**：
//     · 谁调用了 setViewControllers:animated:（含调用栈 = 构造 tab 的那个类）
//     · VC 数组里每一项的类名 + tab 标题 + tag  ← 这一条直接给出"哪个标题对应哪个类"
//     · 当前进程里所有 UITabBarController 的实时状态
//     · 全进程类名扫描（TabBar/容器类、广告/弹窗类）
//     · 所有 presentViewController: 的调用（含首次出现的调用栈）
//     · UIWindow addSubview: 里命中的广告/开屏类
//
// 使用方式（真机）：
//   1) 打开 App，右上角出现蓝色小圆点（可拖动）。
//   2) 进「首页」点一下 → 进「目的地」点一下 → 进「流量」点一下。
//   3) **长按**圆点 → 完整诊断（含上面全部取证）写进剪贴板 → 粘贴回给我。
//   4) 顺便把启动时看到的活动弹窗也复现一次，再长按复制。
//
// 安全设计（每一条都对应上一轮踩过的坑）：
//   · 诊断钩子绝不放在启动路径：%ctor 只装崩溃处理器，其余 dispatch 到主队列。
//   · 查类表一律用 class_copyMethodList 手走父类链，绝不用 class_getInstanceMethod
//     （它会强制 +initialize；在 dyld 阶段全进程扫类曾把目标 App 打崩到完全打不开，
//      且 @try/@catch 救不了 —— 异常在 dispatch_once 里被 libdispatch 边界吞掉）。
//   · 通用 hook 安装器先按"是不是某根类的后代"做廉价预筛，再对每个类做一次
//     class_copyMethodList；否则为全进程几万个类各做一次会卡住启动一两秒。
//   · 启动自愈计数：同一构建连续 3 次启动异常 → 本次只留悬浮按钮、不装任何钩子。
//   · 诊断缓冲用滚动窗口 + 显式截断标记，绝不"写满就静默停止"。
//   · 信号处理函数里只用 open/write/snprintf/backtrace_*（异步信号安全）。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <execinfo.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>

// 不依赖 substrate / ellekit 头文件：直接用 Objective-C runtime 替换方法实现。
// TrollFools 注入的进程内同样可用，同时消掉一类"头文件找不到"的构建失败。

// ============================== 配置 ==============================

#define JT_TAG              "JegoTidy"
#define JT_VERSION          "0.2-probe"
#define JT_BUNDLE_ID        "com.cmi.jegotrip"

#define ENABLE_CRASH_LOG         1   // 崩溃取证
#define ENABLE_FLOAT_BUTTON      1   // 悬浮按钮
#define ENABLE_TABBAR_FORENSICS  1   // tab bar 构造过程取证
#define ENABLE_POPUP_FORENSICS   1   // 弹窗 / 开屏广告取证
#define ENABLE_OVERLAY_FORENSICS 1   // UIWindow addSubview: 里的广告类取证
#define ENABLE_CLASS_SCAN        1   // 全进程类名扫描（一次性，+3s 跑）

#define DUMP_MAX_DEPTH      8
#define DUMP_MAX_NODES      500
#define DIAG_CAP            200000

// ============================== 全局（全部前置，避免"先用后定义"） ==============================

static char gJTCrashLogPath[512] = {0};
static volatile const char *gJTStage = "启动";

static NSMutableString *gJTDiag = nil;
static BOOL             gJTDiagTruncated = NO;

static NSMutableDictionary<NSString *, NSValue *> *gJTOrigVDAMap = nil;
static NSMutableDictionary<NSString *, NSValue *> *gJTOrigSetVCsMap = nil;
static NSMutableDictionary<NSString *, NSValue *> *gJTOrigSetVCsAnimMap = nil;
static NSMutableDictionary<NSString *, NSValue *> *gJTOrigPresentMap = nil;

static SEL gJTSelVDA = NULL;
static SEL gJTSelSetVCs = NULL;
static SEL gJTSelSetVCsAnimated = NULL;
static SEL gJTSelPresent = NULL;

static IMP gJTOrigWindowAddSubview = NULL;
static BOOL gJTWindowHooked = NO;

static NSMutableDictionary<NSString *, NSNumber *> *gJTPresentTally = nil;
static NSMutableDictionary<NSString *, NSString *> *gJTPresentDetail = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gJTOverlaySeen = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gJTClassInterest = nil;

static NSHashTable<UIViewController *> *gJTVCLive = nil;
static NSMutableArray<NSString *>      *gJTSeenVCs = nil;
static __weak UIViewController          *gJTLastVC = nil;

static UIWindow *gJTOverlay = nil;
static UIButton *gJTButton = nil;
static id        gJTBtnHandler = nil;

static NSString *gJTLastTabDesc = nil;

// ============================== 前向声明 ==============================
// .xm 被 clang 当 Objective-C++ 编译：隐式函数声明是**硬 error**（不是 warning），
// -Wno-error 也救不了。所以每个 static 函数在这里先声明一次。
// 新增函数时务必同步补到这里。

static const char *JTStageText(void);
static void JTStageSet(const char *s);
static void JTAppendCrashFile(const char *text);
static void JTSignalHandler(int sig);
static void JTExceptionHandler(NSException *e);
static void JTInitCrashLogPath(void);
static void JTInstallCrashHandlers(void);

static Method JTFindMethodInChain(Class c, SEL sel, Class *outOwner);
static Method JTSafeInstanceMethod(Class c, SEL sel);
static Method JTOwnMethod(Class c, SEL sel);
static BOOL   JTIsDescendantOf(Class c, Class root);
static NSUInteger JTInstallHooksUnderRootClass(const char *rootName, SEL sel, IMP replacement,
                                               NSMutableDictionary<NSString *, NSValue *> *store);
static IMP JTOriginalIMPFor(id self, NSMutableDictionary<NSString *, NSValue *> *store);

static void JTDiag(NSString *fmt, ...);
static NSString *JTDiagSnapshot(void);
static void JTReadBackCrashLog(void);

static NSString *JTDescribeNode(UIView *v);
static void JTWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *out, NSUInteger idx);
static NSString *JTDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes);
static NSString *JTDumpCurrentScreen(void);
static UIViewController *JTCurrentVC(void);

static void JTCollectTabBars(UIViewController *vc, NSMutableArray *out, NSUInteger depth);
static NSString *JTDescribeTabBar(UITabBarController *tbc);
static NSString *JTDescribeAllTabBars(void);
static NSString *JTDescribeVCArray(NSArray *arr);
static void JTSetVCsHook(id self, SEL _cmd, NSArray *vcs);
static void JTSetVCsAnimatedHook(id self, SEL _cmd, NSArray *vcs, BOOL animated);
static void JTInstallTabBarHooks(void);

static void JTNotePresent(NSString *key, NSArray<NSString *> *stack);
static BOOL JTShouldCapturePresentStack(NSString *key);
static void JTPresentHook(id self, SEL _cmd, id vcToPresent, BOOL animated,
                          __unsafe_unretained id completion);
static void JTInstallPresentHooks(void);

static BOOL JTClassNameInteresting(NSString *n);
static NSString *JTScanClassNames(NSString *pattern, NSUInteger maxOut);
static BOOL JTClassAnswersEverything(Class c);
static NSString *JTScanSelectorOwnersUnderRoot(const char *rootName, NSString *selName,
                                               NSUInteger maxOut);
static void JTScanInterestingClasses(void);

static void JTOverlayAddSubviewHook(id self, SEL _cmd, __unsafe_unretained UIView *v);
static void JTInstallOverlayForensics(void);

static void JTNoteVC(UIViewController *vc);
static void JTViewDidAppearHook(id self, SEL _cmd, BOOL animated);
static void JTInstallViewDidAppearHooks(void);

static NSString *JTGuardFilePath(void);
static int  JTLaunchGuard(void);
static void JTLaunchGuardReset(void);

static void JTInstallFloatButton(void);
static void JTInstallAfterLaunch(void);
static void JTLogTabBarState(NSString *reason);

// ============================== 0. 悬浮按钮的窗口 ==============================

// 只让按钮本身接收触摸，其余区域穿透到 App（否则会挡住整个屏幕）。
@interface JTOverlayWindow : UIWindow
@end

@implementation JTOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil) return nil;
    if ((UIView *)hit == (UIView *)self) return nil;
    UIViewController *rvc = self.rootViewController;
    if (rvc && hit == rvc.view) return nil;
    return hit;
}
@end

@interface JTBtnHandler : NSObject
- (void)flash:(NSString *)text;
- (void)onTap:(UIButton *)sender;
- (void)onLong:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

// ============================== 1. 阶段标记 ==============================

static void JTStageSet(const char *s) {
    gJTStage = s;
}

// gJTStage 是 volatile const char *：传进可变参数（%s）没问题，
// 但传进**有类型**的形参（如 stringWithUTF8String: 的 const char *）在 C++ 里是硬 error
// （丢掉 volatile 属于 ill-formed）。统一收口，避免下次有人"顺手简化"掉。
// 只读一个全局 + 一次强转，天然异步信号安全。
static const char *JTStageText(void) {
    return gJTStage ? (const char *)gJTStage : "?";
}

// ============================== 2. 崩溃取证 ==============================

static void JTAppendCrashFile(const char *text) {
    if (!text || !gJTCrashLogPath[0]) return;
    int fd = open(gJTCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, text, strlen(text));
    close(fd);
}

// 信号处理函数里只允许**异步信号安全**的调用：open/write/close/snprintf/backtrace_*。
// 绝不碰 NSString / NSFileManager / NSLog —— 它们会分配内存，导致二次崩溃。
// 处理完必须恢复默认动作并重新 raise，否则进程带着损坏状态继续跑，会被看门狗当卡死杀掉。
static void JTSignalHandler(int sig) {
    char head[256];
    int n = snprintf(head, sizeof(head), "\n===== SIGNAL %d =====\n阶段: %s\n", sig, JTStageText());
    if (n > 0) JTAppendCrashFile(head);

    void *frames[64];
    int cnt = backtrace(frames, 64);
    if (cnt > 0 && gJTCrashLogPath[0]) {
        int fd = open(gJTCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            backtrace_symbols_fd(frames, cnt, fd);
            close(fd);
        }
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

static void JTExceptionHandler(NSException *e) {
    @try {
        NSString *s = [NSString stringWithFormat:
            @"\n===== NSException =====\n阶段: %s\nname: %@\nreason: %@\nstack:\n%@\n",
            JTStageText(), e.name, e.reason,
            [[e callStackSymbols] componentsJoinedByString:@"\n"]];
        if (gJTCrashLogPath[0]) {
            [s writeToFile:[NSString stringWithUTF8String:gJTCrashLogPath]
                atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *ignored) {
    }
}

static void JTInitCrashLogPath(void) {
    @try {
        NSArray<NSString *> *dirs =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        if (dirs.count == 0) return;
        NSString *p = [dirs[0] stringByAppendingPathComponent:@"wf_crash.log"];
        const char *c = p.UTF8String;
        if (!c) return;
        strncpy(gJTCrashLogPath, c, sizeof(gJTCrashLogPath) - 1);
        gJTCrashLogPath[sizeof(gJTCrashLogPath) - 1] = '\0';
    } @catch (NSException *ignored) {
    }
}

static void JTInstallCrashHandlers(void) {
#if ENABLE_CRASH_LOG
    NSSetUncaughtExceptionHandler(&JTExceptionHandler);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        signal(sigs[i], JTSignalHandler);
    }
#endif
}

// ============================== 3. 安全的运行时查表 ==============================
// class_getInstanceMethod 内部走 lookUpImpOrForward，对**尚未初始化**的类会强制发送
// +initialize。在 dyld 阶段全进程扫类 = 把 App 几百个类挨个初始化一遍，任一类的
// +initialize 抛异常就死在启动前，且 @try/@catch 救不了（异常在 dispatch_once 里被
// libdispatch 边界吞掉变成 std::terminate）。所以查表一律用下面的安全版本。

static Method JTFindMethodInChain(Class c, SEL sel, Class *outOwner) {
    if (outOwner) *outOwner = Nil;
    if (!c || !sel) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {   // class_getSuperclass 是裸指针读，不发消息
        unsigned int n = 0;
        Method *ms = class_copyMethodList(k, &n);
        if (!ms) continue;
        Method found = NULL;
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(ms[i]) == sel) { found = ms[i]; break; }
        }
        free(ms);
        if (found) { if (outOwner) *outOwner = k; return found; }
    }
    return NULL;
}

static Method JTSafeInstanceMethod(Class c, SEL sel) {
    return JTFindMethodInChain(c, sel, NULL);
}

// 只认"这个类**自己**实现的方法"；继承来的返回 NULL。
// method_setImplementation 必须只用在自己的方法上：改父类的 Method 对象会波及所有子类。
static Method JTOwnMethod(Class c, SEL sel) {
    Class owner = Nil;
    Method m = JTFindMethodInChain(c, sel, &owner);
    return (owner == c) ? m : NULL;
}

static BOOL JTIsDescendantOf(Class c, Class root) {
    if (!c || !root) return NO;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        if (k == root) return YES;
    }
    return NO;
}

// 通用 hook 安装器。
// 为什么必须挂**每一个自己实现了该方法的类**：只挂基类的话，子类重写了同名方法时
// objc_msgSend 直接落到子类实现上，我们的 hook 永远不会被调用（症状是"日志里连
// 我们自己造的事件都没有"）。原 IMP 按类名存起来，调用时沿父类链找回正确的那份。
static NSUInteger JTInstallHooksUnderRootClass(const char *rootName, SEL sel, IMP replacement,
                                               NSMutableDictionary<NSString *, NSValue *> *store) {
    if (!rootName || !sel || !replacement || !store) return 0;
    Class root = objc_getClass(rootName);
    if (!root) return 0;

    int cnt = objc_getClassList(NULL, 0);
    if (cnt <= 0) return 0;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)cnt);
    if (!all) return 0;
    cnt = objc_getClassList(all, cnt);

    NSUInteger hooked = 0;
    for (int i = 0; i < cnt; i++) {
        Class c = all[i];
        if (!JTIsDescendantOf(c, root)) continue;   // 廉价预筛，避免对几万个类做 copyMethodList
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        if (!ms) continue;
        Method own = NULL;
        for (unsigned int j = 0; j < n; j++) {
            if (method_getName(ms[j]) == sel) { own = ms[j]; break; }
        }
        free(ms);
        if (!own) continue;
        IMP orig = method_setImplementation(own, replacement);
        if (orig) {
            store[NSStringFromClass(c)] = [NSValue valueWithPointer:(const void *)orig];
        }
        hooked++;
    }
    free(all);
    return hooked;
}

static IMP JTOriginalIMPFor(id self, NSMutableDictionary<NSString *, NSValue *> *store) {
    if (!self || !store) return NULL;
    for (Class k = object_getClass(self); k; k = class_getSuperclass(k)) {
        NSValue *v = store[NSStringFromClass(k)];
        if (v) return (IMP)v.pointerValue;   // void* -> IMP 必须显式强转（ObjC++ 下隐式转换是硬 error）
    }
    return NULL;
}

// ============================== 4. 诊断缓冲 ==============================
// 硬规则：**绝不在达到上限后静默停止写入**。
// "写满就不写了"会保留头部丢掉尾部 —— 而轨迹里最有价值的恰恰是最后发生的事。
// 这里用滚动窗口保留最新内容，并显式标记"有内容被丢弃"，
// 否则"只有这些条目"和"只剩这些条目"在日志里长得一模一样，必然误读。

static void JTDiag(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg) return;

    @synchronized (@"JTDiag") {
        if (!gJTDiag) gJTDiag = [NSMutableString string];
        [gJTDiag appendFormat:@"%@\n", msg];
        if (gJTDiag.length > DIAG_CAP) {
            [gJTDiag deleteCharactersInRange:NSMakeRange(0, gJTDiag.length - DIAG_CAP)];
            gJTDiagTruncated = YES;
        }
    }
}

static NSString *JTDiagSnapshot(void) {
    @synchronized (@"JTDiag") {
        NSMutableString *o = [NSMutableString string];
        if (gJTDiagTruncated) [o appendString:@"…(更早的输出已被滚动窗口丢弃)…\n"];
        [o appendString:gJTDiag ? gJTDiag : @""];
        return o;
    }
}

static void JTReadBackCrashLog(void) {
    if (!gJTCrashLogPath[0]) return;
    NSString *p = [NSString stringWithUTF8String:gJTCrashLogPath];
    if (p.length == 0) return;
    NSString *c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (c.length == 0) return;
    JTDiag(@"[上次启动的崩溃报告]\n%@", c);
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

// ============================== 5. 视图树 dump ==============================

static NSString *JTDescribeNode(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    CGRect f = v.frame;
    [s appendFormat:@"%@ (%.0f,%.0f,%.0f,%.0f)",
        NSStringFromClass([v class]),
        (double)f.origin.x, (double)f.origin.y, (double)f.size.width, (double)f.size.height];

    NSString *aid = v.accessibilityIdentifier;
    if (aid.length) [s appendFormat:@" id=%@", aid];

    NSString *txt = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        txt = ((UILabel *)v).text;
    } else if ([v isKindOfClass:[UIButton class]]) {
        txt = [(UIButton *)v titleForState:UIControlStateNormal];
    } else if ([v isKindOfClass:[UITextField class]]) {
        txt = ((UITextField *)v).text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        txt = ((UITextView *)v).text;
    } else if ([v isKindOfClass:[UIImageView class]]) {
        txt = ((UIImageView *)v).accessibilityLabel;
    }
    if (txt.length) {
        NSString *t = [txt stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (t.length > 60) t = [[t substringToIndex:60] stringByAppendingString:@"…"];
        [s appendFormat:@" \"%@\"", t];
    }
    return s;
}

// 只 dump "看得见"的节点：隐藏 / 全透明 / 零尺寸的直接跳过 ——
// 要精简的就是用户看得见的东西，不可见的节点只会把日志灌满。
static void JTWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *out, NSUInteger idx) {
    if (!v || !budget || *budget == 0) return;
    if (v.hidden || v.alpha < 0.02) return;
    CGRect f = v.frame;
    if (f.size.width < 1.0 || f.size.height < 1.0) return;

    (*budget)--;

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    [out appendFormat:@"%@%lu) %@\n", indent, (unsigned long)idx, JTDescribeNode(v)];

    if (depth >= maxDepth) {
        if (v.subviews.count)
            [out appendFormat:@"%@   …深度截断(还有 %lu 个子视图)\n",
                indent, (unsigned long)v.subviews.count];
        return;
    }
    NSUInteger i = 0;
    for (UIView *sub in v.subviews) {
        if (*budget == 0) {
            [out appendFormat:@"%@   …节点预算用尽\n", indent];
            break;
        }
        JTWalkNode(sub, depth + 1, maxDepth, budget, out, i);
        i++;
    }
}

static NSString *JTDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes) {
    if (!root) return @"(空)\n";
    NSUInteger budget = maxNodes;
    NSMutableString *out = [NSMutableString string];
    JTWalkNode(root, 0, maxDepth, &budget, out, 0);
    return out;
}

static UIViewController *JTCurrentVC(void) {
    UIViewController *best = nil;
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
            if (w.hidden || w.alpha < 0.02) continue;
            UIViewController *vc = w.rootViewController;
            if (!vc) continue;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UIViewController *t = ((UINavigationController *)vc).visibleViewController;
                if (t) vc = t;
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                UIViewController *t = ((UITabBarController *)vc).selectedViewController;
                if (t) vc = t;
            }
            if (vc.view && vc.view.window) best = vc;
        }
    } @catch (NSException *ignored) {
    }
    if (best) return best;
    @synchronized (@"JTVC") {
        return gJTLastVC;
    }
}

static NSString *JTDumpCurrentScreen(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"===== 屏幕 dump %@ =====\n", [NSDate date]];

    @try {
        NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
        [out appendFormat:@"窗口总数=%lu\n", (unsigned long)wins.count];
        NSUInteger wi = 0;
        for (UIWindow *w in wins) {
            if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
            if (w.hidden || w.alpha < 0.02) continue;
            UIViewController *rvc = w.rootViewController;
            [out appendFormat:@"--- 窗口#%lu level=%.0f 根VC=%@ frame=(%.0f,%.0f,%.0f,%.0f)\n",
                (unsigned long)wi, (double)w.windowLevel,
                rvc ? NSStringFromClass([rvc class]) : @"(无)",
                (double)w.frame.origin.x, (double)w.frame.origin.y,
                (double)w.frame.size.width, (double)w.frame.size.height];
            NSUInteger budget = DUMP_MAX_NODES;
            JTWalkNode(w, 0, DUMP_MAX_DEPTH, &budget, out, 0);
            wi++;
        }
    } @catch (NSException *e) {
        [out appendFormat:@"(窗口遍历异常: %@)\n", e.reason];
    }

    // 补一份"当前 VC"的视图树。
    // 实测教训：App 的整屏页面常常由自己的容器呈现，UIApplication.windows 的
    // root -> presented -> child 这条链**到不了**那个页面。所以两条路都走。
    @try {
        UIViewController *cur = JTCurrentVC();
        if (cur && cur.view) {
            [out appendFormat:@"--- 当前VC %@ 的视图树\n", NSStringFromClass([cur class])];
            NSUInteger budget = DUMP_MAX_NODES;
            JTWalkNode(cur.view, 0, DUMP_MAX_DEPTH, &budget, out, 0);
        } else {
            [out appendString:@"(当前VC 未定位到)\n"];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"(当前VC dump 异常: %@)\n", e.reason];
    }

    // tab bar 的实时状态每次都带上 —— 这是本次任务的核心信息
    [out appendString:JTDescribeAllTabBars()];
    return out;
}

// ============================== 6. TabBar 取证（本次任务的核心） ==============================

static void JTCollectTabBars(UIViewController *vc, NSMutableArray *out, NSUInteger depth) {
    if (!vc || !out || depth > 10) return;
    if ([vc isKindOfClass:[UITabBarController class]] && ![out containsObject:vc]) {
        [out addObject:vc];
    }
    for (UIViewController *c in vc.children) JTCollectTabBars(c, out, depth + 1);
    JTCollectTabBars(vc.presentedViewController, out, depth + 1);
}

static NSString *JTDescribeTabBar(UITabBarController *tbc) {
    NSMutableString *s = [NSMutableString string];
    if (!tbc) return @"(nil)\n";
    [s appendFormat:@"  TabBarController %@  selectedIndex=%ld  VC数=%lu\n",
        NSStringFromClass([tbc class]), (long)tbc.selectedIndex,
        (unsigned long)tbc.viewControllers.count];

    NSUInteger i = 0;
    for (UIViewController *vc in tbc.viewControllers) {
        UITabBarItem *it = vc.tabBarItem;
        [s appendFormat:@"    [%lu] %@   title=%@  tag=%ld  badge=%@\n",
            (unsigned long)i, NSStringFromClass([vc class]),
            it.title ?: @"(无)", (long)it.tag, it.badgeValue ?: @"(无)"];
        i++;
    }

    // 系统 UITabBar 的 items（自绘 tab bar 时这里可能是空的或与上面不一致）
    UITabBar *tb = tbc.tabBar;
    if (tb) {
        [s appendFormat:@"    系统 UITabBar: %@ frame=(%.0f,%.0f,%.0f,%.0f) items=%lu\n",
            NSStringFromClass([tb class]),
            (double)tb.frame.origin.x, (double)tb.frame.origin.y,
            (double)tb.frame.size.width, (double)tb.frame.size.height,
            (unsigned long)tb.items.count];
        NSUInteger j = 0;
        for (UITabBarItem *it in tb.items) {
            [s appendFormat:@"      item[%lu] title=%@ tag=%ld\n",
                (unsigned long)j, it.title ?: @"(无)", (long)it.tag];
            j++;
        }
    }
    return s;
}

static NSString *JTDescribeAllTabBars(void) {
    NSMutableArray *found = [NSMutableArray array];
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
            JTCollectTabBars(w.rootViewController, found, 0);
        }
        // 窗口树到不了的地方，用我们自己登记的 VC 兜底（实测过这条路是必要的）
        @synchronized (@"JTVC") {
            if (gJTVCLive) {
                for (UIViewController *vc in gJTVCLive.allObjects) {
                    if ([vc isKindOfClass:[UITabBarController class]] && ![found containsObject:vc]) {
                        [found addObject:vc];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"(TabBar 遍历异常: %@)\n", e.reason];
    }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"===== TabBar 取证：找到 %lu 个 UITabBarController =====\n",
        (unsigned long)found.count];
    if (found.count == 0) {
        [out appendString:@"  (没有系统 UITabBarController → tab bar 极可能是自绘容器，"
                      @"看下面的类名扫描和视图树)\n"];
    }
    for (UITabBarController *t in found) [out appendString:JTDescribeTabBar(t)];
    return out;
}

static NSString *JTDescribeVCArray(NSArray *arr) {
    NSMutableString *s = [NSMutableString string];
    if (![arr isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"<非数组: %@>", arr ? NSStringFromClass([arr class]) : @"nil"];
    }
    NSUInteger i = 0;
    for (id o in arr) {
        if ([o isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)o;
            [s appendFormat:@"[%lu]%@(tab=%@)", (unsigned long)i,
                NSStringFromClass([vc class]), vc.tabBarItem.title ?: @"-"];
        } else {
            [s appendFormat:@"[%lu]<%@>", (unsigned long)i,
                o ? NSStringFromClass([o class]) : @"nil"];
        }
        i++;
        if (i > 20) { [s appendString:@"..."]; break; }
    }
    return s;
}

// 这个 hook 是整个探针里**信号最强**的一处：
// App 自己构造 tab 的时候，会把它真实的 VC 数组交到这里 —— 类名 + 标题 + 顺序全都有，
// 再加上调用栈就指明了"是哪个类在负责搭 tab"。比猜类名可靠一个数量级。
//
// ★ 注意两个重载必须各用**独立的**原实现字典。
//   UITabBarController 同时自己实现了 setViewControllers: 和 setViewControllers:animated:，
//   如果共用一个字典（键都是类名），后挂的那个会把前一个的条目覆盖掉 ——
//   于是 setViewControllers: 的 hook 会转发到 animated 版那份 IMP，
//   参数个数都对不上，而且对方也是我们的 hook → **无限递归，必崩**。
static void JTSetVCsHook(id self, SEL _cmd, NSArray *vcs) {
    @try {
        JTDiag(@"[TabBar设置] %@ setViewControllers: → %@",
               NSStringFromClass([self class]), JTDescribeVCArray(vcs));
        NSArray<NSString *> *st = [NSThread callStackSymbols];
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < st.count && i < 10; i++) [s appendFormat:@"\n      %@", st[i]];
        JTDiag(@"[TabBar设置] 调用栈:%@", s);
    } @catch (NSException *e) {
    }
    IMP orig = JTOriginalIMPFor(self, gJTOrigSetVCsMap);
    if (orig) ((void (*)(id, SEL, NSArray *))orig)(self, _cmd, vcs);
}

static void JTSetVCsAnimatedHook(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    @try {
        JTDiag(@"[TabBar设置] %@ setViewControllers:animated: → %@",
               NSStringFromClass([self class]), JTDescribeVCArray(vcs));
        NSArray<NSString *> *st = [NSThread callStackSymbols];
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < st.count && i < 10; i++) [s appendFormat:@"\n      %@", st[i]];
        JTDiag(@"[TabBar设置] 调用栈:%@", s);
    } @catch (NSException *e) {
    }
    IMP orig = JTOriginalIMPFor(self, gJTOrigSetVCsAnimMap);
    if (orig) ((void (*)(id, SEL, NSArray *, BOOL))orig)(self, _cmd, vcs, animated);
}

static void JTInstallTabBarHooks(void) {
#if ENABLE_TABBAR_FORENSICS
    @try {
        if (!gJTOrigSetVCsMap) gJTOrigSetVCsMap = [NSMutableDictionary dictionary];
        if (!gJTOrigSetVCsAnimMap) gJTOrigSetVCsAnimMap = [NSMutableDictionary dictionary];
        if (!gJTSelSetVCs) gJTSelSetVCs = NSSelectorFromString(@"setViewControllers:");
        if (!gJTSelSetVCsAnimated)
            gJTSelSetVCsAnimated = NSSelectorFromString(@"setViewControllers:animated:");

        NSUInteger a = JTInstallHooksUnderRootClass("UITabBarController", gJTSelSetVCs,
                                                    (IMP)JTSetVCsHook, gJTOrigSetVCsMap);
        NSUInteger b = JTInstallHooksUnderRootClass("UITabBarController", gJTSelSetVCsAnimated,
                                                    (IMP)JTSetVCsAnimatedHook, gJTOrigSetVCsAnimMap);
        JTDiag(@"[TabBar钩子] setViewControllers: 挂 %lu 个，setViewControllers:animated: 挂 %lu 个",
               (unsigned long)a, (unsigned long)b);
    } @catch (NSException *e) {
        JTDiag(@"[TabBar钩子] 安装异常: %@", e.reason);
    }
#endif
}

// 只在内容变化时记录，避免刷屏
static void JTLogTabBarState(NSString *reason) {
    @try {
        NSString *desc = JTDescribeAllTabBars();
        if (gJTLastTabDesc && [gJTLastTabDesc isEqualToString:desc]) return;
        gJTLastTabDesc = desc;
        JTDiag(@"[TabBar状态·%@]\n%@", reason, desc);
    } @catch (NSException *e) {
    }
}

// ============================== 7. 弹窗 / 开屏广告取证 ==============================
// 记录"谁弹了谁"。去重键 = 弹出方类名 + 被弹方类名：
// 只用被弹方类名做键的话，两个不同的弹出方会被当成同一个事件，只留第一条 ——
// 而"第一条"很可能是我们自己造的，真正要看的那条反而被丢掉。

static void JTNotePresent(NSString *key, NSArray<NSString *> *stack) {
    if (key.length == 0) return;

    NSMutableString *stackStr = [NSMutableString string];
    for (NSUInteger i = 0; stack && i < stack.count && i < 8; i++) {
        [stackStr appendFormat:@"\n      %@", stack[i]];
    }

    BOOL first = NO;
    NSUInteger count = 0;
    @synchronized (@"JTPresent") {
        if (!gJTPresentTally) gJTPresentTally = [NSMutableDictionary dictionary];
        if (!gJTPresentDetail) gJTPresentDetail = [NSMutableDictionary dictionary];
        count = [gJTPresentTally[key] unsignedIntegerValue] + 1;
        gJTPresentTally[key] = @(count);
        if (gJTPresentDetail[key] == nil && gJTPresentDetail.count < 60) {
            gJTPresentDetail[key] = [stackStr copy];
            first = YES;
        }
    }
    if (first) {
        JTDiag(@"[弹窗] %@  (首次) 栈:%@", key, stackStr);
    } else if (count <= 3) {
        JTDiag(@"[弹窗] %@  第 %lu 次", key, (unsigned long)count);
    }
}

// callStackSymbols 不便宜，而 present 可能被系统高频调用。
// 先只查一次"这个键是不是新的"（短临界区），确认需要调用栈了再去取 ——
// 否则每一次 present 都做一遍符号化，会把主线程拖慢。
static BOOL JTShouldCapturePresentStack(NSString *key) {
    @synchronized (@"JTPresent") {
        if (!gJTPresentDetail) gJTPresentDetail = [NSMutableDictionary dictionary];
        return (gJTPresentDetail[key] == nil) && (gJTPresentDetail.count < 60);
    }
}

static void JTPresentHook(id self, SEL _cmd, id vcToPresent, BOOL animated,
                          __unsafe_unretained id completion) {
    @try {
        NSString *key = [NSString stringWithFormat:@"%@ → %@",
                         NSStringFromClass([self class]),
                         vcToPresent ? NSStringFromClass([vcToPresent class]) : @"(nil)"];
        NSArray<NSString *> *stack = nil;
        if (JTShouldCapturePresentStack(key)) stack = [NSThread callStackSymbols];
        JTNotePresent(key, stack);
    } @catch (NSException *e) {
    }
    IMP orig = JTOriginalIMPFor(self, gJTOrigPresentMap);
    if (orig) {
        // completion 参数用 __unsafe_unretained：ARC 不会去 retain/release 一个栈上的 block
        ((void (*)(id, SEL, id, BOOL, __unsafe_unretained id))orig)(self, _cmd, vcToPresent,
                                                                    animated, completion);
    }
}

static void JTInstallPresentHooks(void) {
#if ENABLE_POPUP_FORENSICS
    @try {
        if (!gJTOrigPresentMap) gJTOrigPresentMap = [NSMutableDictionary dictionary];
        if (!gJTSelPresent)
            gJTSelPresent = NSSelectorFromString(@"presentViewController:animated:completion:");
        NSUInteger n = JTInstallHooksUnderRootClass("UIViewController", gJTSelPresent,
                                                    (IMP)JTPresentHook, gJTOrigPresentMap);
        JTDiag(@"[弹窗钩子] presentViewController:animated:completion: 挂 %lu 个",
               (unsigned long)n);
    } @catch (NSException *e) {
        JTDiag(@"[弹窗钩子] 安装异常: %@", e.reason);
    }
#endif
}

// ============================== 8. UIWindow addSubview: 取证 ==============================
// 开屏广告经常是直接贴在 window 上的自绘视图，不走 presentViewController:，
// 所以必须从这一层抓。addSubview: 是从 UIView 继承来的热方法，直接
// method_setImplementation 会改到父类那份、波及全 App 每一个 UIView ——
// 必须用 class_addMethod 给 UIWindow **自己**加一个实现去遮蔽父类（见下方）。
// 另外每个类名都要做一次"感不感兴趣"的判定，所以结果必须缓存，否则每次
// addSubview: 都跑一遍字符串匹配，会把启动拖垮。

static BOOL JTClassNameInteresting(NSString *n) {
    if (n.length == 0) return NO;
    NSNumber *cached = nil;
    @synchronized (@"JTInterest") {
        if (!gJTClassInterest) gJTClassInterest = [NSMutableDictionary dictionary];
        cached = gJTClassInterest[n];
    }
    if (cached) return cached.boolValue;

    // 大小写敏感，避免 "Header"/"Shadow"/"Load" 这类被误命中
    NSArray<NSString *> *kws = @[ @"Advert", @"Banner", @"Splash", @"Launch", @"Promo",
                                  @"Market", @"Guide", @"Overlay", @"Dialog", @"Alert",
                                  @"Activity", @"Popup", @"Float", @"AD", @"AdView",
                                  @"AdBanner", @"RedPacket", @"Coupon", @"Mask" ];
    BOOL hit = NO;
    for (NSString *k in kws) {
        if ([n rangeOfString:k].location != NSNotFound) { hit = YES; break; }
    }
    @synchronized (@"JTInterest") {
        gJTClassInterest[n] = @(hit);
    }
    return hit;
}

static void JTOverlayAddSubviewHook(id self, SEL _cmd, __unsafe_unretained UIView *v) {
    @try {
        if (v) {
            NSString *child = NSStringFromClass([v class]);
            if (JTClassNameInteresting(child)) {
                NSString *parent = NSStringFromClass([self class]);
                NSString *key = [NSString stringWithFormat:@"%@ ⊃ %@", parent, child];
                BOOL first = NO;
                @synchronized (@"JTOverlay") {
                    if (!gJTOverlaySeen) gJTOverlaySeen = [NSMutableDictionary dictionary];
                    if (gJTOverlaySeen[key] == nil && gJTOverlaySeen.count < 60) {
                        gJTOverlaySeen[key] = @1;
                        first = YES;
                    }
                }
                if (first) {
                    JTDiag(@"[叠加视图] %@  frame=%@", key, NSStringFromCGRect(v.frame));
                }
            }
        }
    } @catch (NSException *e) {
    }
    if (gJTOrigWindowAddSubview) {
        ((void (*)(id, SEL, __unsafe_unretained UIView *))gJTOrigWindowAddSubview)(self, _cmd, v);
    }
}

static void JTInstallOverlayForensics(void) {
#if ENABLE_OVERLAY_FORENSICS
    @try {
        if (gJTWindowHooked) return;
        Class wc = objc_getClass("UIWindow");
        if (!wc) return;
        SEL sel = NSSelectorFromString(@"addSubview:");
        Method m = JTSafeInstanceMethod(wc, sel);   // 注意：这里是继承来的 UIView 实现
        if (!m) return;
        IMP inherited = method_getImplementation(m);
        if (class_addMethod(wc, sel, (IMP)JTOverlayAddSubviewHook, "v@:@")) {
            // 加上了 = UIWindow 原本没有自己的实现 → 转发给继承来的那份
            gJTOrigWindowAddSubview = inherited;
        } else {
            // UIWindow 自己已经有实现 → 替换它自己的，并保留它自己的原实现
            Method own = JTOwnMethod(wc, sel);
            if (own) gJTOrigWindowAddSubview = method_setImplementation(own, (IMP)JTOverlayAddSubviewHook);
        }
        gJTWindowHooked = YES;
        JTDiag(@"[叠加钩子] UIWindow addSubview: 已挂载");
    } @catch (NSException *e) {
        JTDiag(@"[叠加钩子] 安装异常: %@", e.reason);
    }
#endif
}

// ============================== 9. 全进程类名扫描 ==============================
// 注意：这里匹配的是**类名**，不是"谁实现了某个 selector"。
// 后者会返回一堆"万能类"（对任何 selector 都回答 yes）的噪声，前者不会。
// 只读 class_getName / class_getSuperclass，都不发消息、不触发 +initialize。

static NSString *JTScanClassNames(NSString *pattern, NSUInteger maxOut) {
    NSMutableString *out = [NSMutableString string];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0 error:nil];
    if (!re) return @"  (正则无效)\n";

    int cnt = objc_getClassList(NULL, 0);
    if (cnt <= 0) return @"  (取不到类表)\n";
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)cnt);
    if (!all) return @"  (内存不足)\n";
    cnt = objc_getClassList(all, cnt);

    NSUInteger hit = 0;
    NSUInteger total = 0;
    for (int i = 0; i < cnt; i++) {
        Class c = all[i];
        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if (!n) continue;
        total++;
        if (hit >= maxOut) continue;
        if ([re numberOfMatchesInString:n options:0 range:NSMakeRange(0, n.length)] == 0) continue;
        Class sup = class_getSuperclass(c);
        NSString *supName = sup ? [NSString stringWithUTF8String:class_getName(sup)] : @"(根类)";
        [out appendFormat:@"  %@  ←  %@\n", n, supName];
        hit++;
    }
    free(all);
    [out appendFormat:@"  (命中 %lu / 共扫 %lu 个类%s)\n", (unsigned long)hit, (unsigned long)total,
        hit >= maxOut ? "，已达输出上限，可能还有更多" : ""];
    return out;
}

// 全进程反查 selector 会返回"万能类"——对任何 selector 都回答 yes 的类。
// 实测过：十几个毫不相关的 selector 全返回同样那五个类，一个类不可能实现十二个无关方法，
// 那只是噪声。用**一个确定不存在的 selector 做对照组**把它们挑出来。
static BOOL JTClassAnswersEverything(Class c) {
    static SEL probe = NULL;
    if (!probe) probe = NSSelectorFromString(@"wf_nonexistent_probe_xyz_123:");
    return JTSafeInstanceMethod(c, probe) != NULL;
}

// 在某个根类的后代里，找出"自己实现了某个 selector"的类。
// 只限制在 UIViewController 后代里扫，是为了把代价压下来：全进程几万个类各做一次
// class_copyMethodList 会明显拖慢，而 tab 容器必然是 UIViewController 后代。
static NSString *JTScanSelectorOwnersUnderRoot(const char *rootName, NSString *selName,
                                               NSUInteger maxOut) {
    NSMutableString *out = [NSMutableString string];
    Class root = objc_getClass(rootName);
    SEL sel = NSSelectorFromString(selName);
    if (!root || !sel) return @"  (根类或 selector 无效)\n";

    int cnt = objc_getClassList(NULL, 0);
    if (cnt <= 0) return @"  (取不到类表)\n";
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)cnt);
    if (!all) return @"  (内存不足)\n";
    cnt = objc_getClassList(all, cnt);

    NSUInteger hit = 0;
    NSUInteger universal = 0;
    for (int i = 0; i < cnt; i++) {
        Class c = all[i];
        if (!JTIsDescendantOf(c, root)) continue;
        if (!JTOwnMethod(c, sel)) continue;              // 只认自己实现的
        if (JTClassAnswersEverything(c)) { universal++; continue; }
        if (hit >= maxOut) continue;
        Class sup = class_getSuperclass(c);
        NSString *supName = sup ? [NSString stringWithUTF8String:class_getName(sup)] : @"(根类)";
        [out appendFormat:@"  %@  ←  %@\n",
            [NSString stringWithUTF8String:class_getName(c)], supName];
        hit++;
    }
    free(all);
    [out appendFormat:@"  (命中 %lu 个%s；另剔除 %lu 个万能类)\n",
        (unsigned long)hit, hit >= maxOut ? "，已达输出上限" : "", (unsigned long)universal];
    return out;
}

static void JTScanInterestingClasses(void) {
#if ENABLE_CLASS_SCAN
    @try {
        JTDiag(@"[类名扫描·容器/tab 候选]\n%@",
               JTScanClassNames(@".*(TabBar|Tabbar|TabBarController|RootViewController|"
                                @"MainViewController|ContainerViewController|MainTab|"
                                @"RootTab|HomeViewController).*", 80));
        JTDiag(@"[类名扫描·广告/弹窗候选]\n%@",
               JTScanClassNames(@".*(Advert|Banner|Splash|Promo|Market|Guide|Overlay|"
                                @"Dialog|Alert|Activity|Popup|Coupon|RedPacket).*", 80));
        // 自绘 tab 容器可能类名完全不含 Tab 字样，只能从"谁自己实现了 setViewControllers:"
        // 反查。带上对照组剔除万能类，否则结果会是噪声。
        JTDiag(@"[反查·自己实现 setViewControllers: 的 UIViewController 子类]\n%@",
               JTScanSelectorOwnersUnderRoot("UIViewController", @"setViewControllers:", 60));
        JTDiag(@"[反查·自己实现 setSelectedIndex: 的 UIViewController 子类]\n%@",
               JTScanSelectorOwnersUnderRoot("UIViewController", @"setSelectedIndex:", 60));
    } @catch (NSException *e) {
        JTDiag(@"[类名扫描] 异常: %@", e.reason);
    }
#endif
}

// ============================== 10. 页面出现时登记 ==============================

static void JTNoteVC(UIViewController *vc) {
    if (!vc) return;
    NSString *cls = NSStringFromClass([vc class]);
    if (cls.length == 0) return;
    if ([cls hasPrefix:@"JT"]) return;                        // 我们自己的
    if ([cls hasPrefix:@"_UI"] || [cls hasPrefix:@"UI"]) return;
    if ([cls hasPrefix:@"SwiftUI"]) return;

    @synchronized (@"JTVC") {
        if (!gJTVCLive) gJTVCLive = [NSHashTable weakObjectsHashTable];
        if (!gJTSeenVCs) gJTSeenVCs = [NSMutableArray array];
        [gJTVCLive addObject:vc];
        gJTLastVC = vc;
        if (![gJTSeenVCs containsObject:cls] && gJTSeenVCs.count < 150) {
            [gJTSeenVCs addObject:cls];
        }
    }
}

static void JTViewDidAppearHook(id self, SEL _cmd, BOOL animated) {
    IMP orig = JTOriginalIMPFor(self, gJTOrigVDAMap);   // 先转发原实现，保证 App 行为完全不变
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            JTNoteVC((UIViewController *)self);
        }
    } @catch (NSException *ignored) {
    }
}

static void JTInstallViewDidAppearHooks(void) {
    @try {
        if (!gJTOrigVDAMap) gJTOrigVDAMap = [NSMutableDictionary dictionary];
        if (!gJTSelVDA) gJTSelVDA = NSSelectorFromString(@"viewDidAppear:");
        NSUInteger n = JTInstallHooksUnderRootClass("UIViewController", gJTSelVDA,
                                                    (IMP)JTViewDidAppearHook, gJTOrigVDAMap);
        JTDiag(@"[钩子] viewDidAppear: 挂载 %lu 个实现", (unsigned long)n);
    } @catch (NSException *e) {
        JTDiag(@"[钩子] 安装异常: %@", e.reason);
    }
}

// ============================== 11. 启动自愈计数 ==============================
// 最难受的失败不是崩溃，是"崩到 App 完全打不开"—— 那样连诊断都拿不到。
// 规则：同一构建 token 连续 3 次启动都走到这里 → 本次不装任何钩子，只留悬浮按钮。
// token 变了（= 重新构建过）自动从 0 开始，所以修好后无需手动清文件。

static NSString *JTGuardFilePath(void) {
    @try {
        NSArray<NSString *> *dirs =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        if (dirs.count == 0) return nil;
        return [dirs[0] stringByAppendingPathComponent:@"wf_launch.txt"];
    } @catch (NSException *ignored) {
        return nil;
    }
}

static int JTLaunchGuard(void) {
    @try {
        NSString *p = JTGuardFilePath();
        if (!p) return 0;
        NSString *token = [NSString stringWithUTF8String:__DATE__ " " __TIME__];
        NSString *content = [NSString stringWithContentsOfFile:p
                                                     encoding:NSUTF8StringEncoding error:nil];
        NSArray<NSString *> *parts = content ? [content componentsSeparatedByString:@"\n"] : @[];
        NSString *oldToken = parts.count > 0 ? parts[0] : @"";
        int cnt = parts.count > 1 ? [parts[1] intValue] : 0;
        if (![oldToken isEqualToString:token]) cnt = 0;   // 新构建 → 重置
        cnt++;
        [[NSString stringWithFormat:@"%@\n%d", token, cnt]
            writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return (cnt >= 3) ? 1 : 0;
    } @catch (NSException *ignored) {
        return 0;
    }
}

// 只有"装了钩子且活过 20 秒"才清零。跳过安装时**不清零**，
// 否则会变成"崩一次、好一次"的交替振荡，反而更难查。
static void JTLaunchGuardReset(void) {
    @try {
        NSString *p = JTGuardFilePath();
        if (!p) return;
        NSString *token = [NSString stringWithUTF8String:__DATE__ " " __TIME__];
        [[NSString stringWithFormat:@"%@\n0", token]
            writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *ignored) {
    }
}

// ============================== 12. 悬浮按钮 ==============================

@implementation JTBtnHandler

- (void)flash:(NSString *)text {
    UIButton *b = gJTButton;
    if (!b) return;
    static NSInteger sToken = 0;
    sToken++;
    NSInteger mine = sToken;
    NSString *old = [b titleForState:UIControlStateNormal] ?: @"JT";
    [b setTitle:text forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (mine == sToken) [b setTitle:old forState:UIControlStateNormal];
    });
}

- (void)onTap:(UIButton *)sender {
    @try {
        NSString *dump = JTDumpCurrentScreen();
        UIViewController *cur = JTCurrentVC();
        JTDiag(@"\n[抓取] 当前VC=%@\n%@", cur ? NSStringFromClass([cur class]) : @"(未定位)", dump);
        // 剪贴板永远写**完整累积快照**，不是本次这一段 ——
        // 否则后一次抓取会覆盖掉前一次的证据。
        UIPasteboard.generalPasteboard.string = JTDiagSnapshot();
        [self flash:[NSString stringWithFormat:@"%lu", (unsigned long)dump.length]];
    } @catch (NSException *e) {
        [self flash:@"err"];
        JTDiag(@"[抓取] 异常: %@", e.reason);
    }
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try {
        // 长按那一刻才生成文本（而不是提前冻结），保证拿到的是最新、最全的
        JTLogTabBarState(@"长按");
        NSString *snap = JTDiagSnapshot();
        UIPasteboard.generalPasteboard.string = snap;
        [self flash:[NSString stringWithFormat:@"ALL %lu", (unsigned long)snap.length]];
    } @catch (NSException *e) {
        [self flash:@"err"];
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIButton *b = gJTButton;
    if (!b) return;
    if (g.state == UIGestureRecognizerStateChanged ||
        g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:b.superview];
        CGPoint c = b.center;
        c.x += t.x;
        c.y += t.y;
        [g setTranslation:CGPointZero inView:b.superview];
        CGFloat w = b.superview.bounds.size.width;
        CGFloat h = b.superview.bounds.size.height;
        c.x = MAX(24.0, MIN(w - 24.0, c.x));
        c.y = MAX(24.0, MIN(h - 24.0, c.y));
        b.center = c;
    }
}

@end

static void JTInstallFloatButton(void) {
#if ENABLE_FLOAT_BUTTON
    if (gJTOverlay) return;
    @try {
        JTOverlayWindow *w = [[JTOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 100.0;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[UIViewController alloc] init];
        w.rootViewController.view.backgroundColor = [UIColor clearColor];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 44, 44);
        b.backgroundColor = [UIColor colorWithRed:0.0 green:0.44 blue:0.75 alpha:0.78];
        b.layer.cornerRadius = 22.0;
        b.layer.masksToBounds = YES;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
        [b setTitle:@"JT" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.center = CGPointMake(w.bounds.size.width - 34.0, 130.0);

        JTBtnHandler *h = [[JTBtnHandler alloc] init];
        [b addTarget:h action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:h action:@selector(onLong:)];
        lp.minimumPressDuration = 0.6;
        [b addGestureRecognizer:lp];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:h action:@selector(onPan:)];
        [b addGestureRecognizer:pan];

        [w.rootViewController.view addSubview:b];
        w.hidden = NO;

        gJTOverlay = w;
        gJTButton = b;
        gJTBtnHandler = h;   // 必须持有：target-action 不 retain target
        JTDiag(@"[悬浮按钮] 已安装");
    } @catch (NSException *e) {
        JTDiag(@"[悬浮按钮] 安装异常: %@", e.reason);
    }
#endif
}

// ============================== 13. 启动流程 ==============================

static void JTInstallAfterLaunch(void) {
    JTStageSet("安装:启动自愈检查");
    int guard = JTLaunchGuard();

    if (guard != 0) {
        JTStageSet("自愈:本次跳过钩子");
        JTDiag(@"[自愈] 同一构建已连续 3 次启动异常 —— 本次不安装任何钩子，"
                "App 保持可用。改代码重新构建后自动恢复。");
        JTReadBackCrashLog();       // 让用户仍能长按拿到上次崩溃报告
        JTInstallFloatButton();
        return;
    }

    JTReadBackCrashLog();

    JTStageSet("安装:viewDidAppear钩子");
    JTInstallViewDidAppearHooks();

    JTStageSet("安装:TabBar钩子");
    JTInstallTabBarHooks();

    JTStageSet("安装:弹窗钩子");
    JTInstallPresentHooks();

    JTStageSet("安装:叠加视图钩子");
    JTInstallOverlayForensics();

    JTStageSet("安装:悬浮按钮");
    JTInstallFloatButton();

    // tab bar 在启动后才搭起来，所以要多次复检；内容没变就不重复记录。
    JTLogTabBarState(@"安装后立即");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ JTLogTabBarState(@"+2s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ JTLogTabBarState(@"+6s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ JTLogTabBarState(@"+12s"); });

    // 类名扫描是一次性重活（几万个类跑正则），既不放启动路径，也不放主线程 ——
    // 它只做 objc_getClassList / class_getName / class_getSuperclass 这些只读运行时查询，
    // 天然线程安全；JTDiag 内部有锁，可以安全地在后台写。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        JTScanInterestingClasses();
    });

    JTStageSet("安装完成");
    JTDiag(@"[启动] %s %s 已加载", JT_TAG, JT_VERSION);
    JTDiag(@"[用法] 点圆点=抓当前页并复制；长按圆点=复制全部诊断");

    // 活过 20 秒才算"启动成功"，此时才清零计数
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JTLaunchGuardReset();
        JTDiag(@"[自愈] 启动存活确认，计数已清零");
    });
}

// %ctor 只做三件事：算路径、装崩溃处理器、把其余全部 dispatch 到主队列。
// 主队列在 UIApplicationMain 启动 runloop 之前**根本不会执行**，
// 这是"绝对晚于启动"的结构性保证，比任何 sleep 秒数都可靠。
%ctor {
    @autoreleasepool {
        JTStageSet("ctor:开始");
        JTInitCrashLogPath();
        JTInstallCrashHandlers();
        dispatch_async(dispatch_get_main_queue(), ^{
            JTStageSet("主队列:安装");
            JTInstallAfterLaunch();
        });
    }
}
