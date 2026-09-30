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

// ★ 一个 selector 只挂**一个类**，所以原 IMP 也是**一个** —— 不是字典。
// 为什么（2026-09-30 真机栈溢出实测，见 JTInstallSingleHook 上面的长注释）：
// 一旦让一个共享 shim 服务多个类，就必须靠"从对象类沿父类链找第一份原 IMP"来转发，
// 而这个查法**无法区分"直接调用"和"[super] 调用"** → 必然无限递归。
// 收敛成"每个 selector 一个原 IMP"之后，转发是常量时间且不可能回到自己。
static IMP gJTOrigVDA = NULL;          // UIViewController.viewDidAppear:
static IMP gJTOrigSetVCs = NULL;       // UITabBarController.setViewControllers:
static IMP gJTOrigSetVCsAnim = NULL;   // UITabBarController.setViewControllers:animated:
static IMP gJTOrigPresent = NULL;      // UIViewController.presentViewController:animated:completion:

// 实际挂上的类名（仅用于诊断输出；挂载失败时保持 nil）
static NSString *gJTHookedVDA = nil;
static NSString *gJTHookedSetVCs = nil;
static NSString *gJTHookedSetVCsAnim = nil;
static NSString *gJTHookedPresent = nil;

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
static UIButton *gJTRmButton = nil;
static id        gJTBtnHandler = nil;

// 「逐个移除 tab」实验的状态（见文件末尾第 14 节）
static NSArray  *gJTSavedVCs = nil;   // 原始 viewControllers
static NSInteger gJTSavedSel = 0;     // 原始 selectedIndex
static int       gJTProbeCursor = 0;  // 0..count-1 逐个试，== count 时只恢复

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
static BOOL   JTInstallSingleHook(const char *className, SEL sel, IMP replacement, IMP *outOrig);

static void JTDiag(NSString *fmt, ...);
static NSString *JTDiagSnapshot(void);
static void JTReadBackCrashLog(void);

static NSString *JTDescribeNode(UIView *v);
static void JTWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *out, NSUInteger idx);
static NSString *JTDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes);
static NSString *JTDumpCurrentScreen(void);
static UIViewController *JTCurrentVC(void);

static NSArray *JTChildrenOf(UIViewController *vc);
static void JTCollectTabBars(UIViewController *vc, NSMutableArray *out, NSUInteger depth);
static void JTCountClasses(UIView *v, NSUInteger depth,
                           NSUInteger *btn, NSUInteger *img, NSUInteger *lbl);
static void JTCollectLabels(UIView *v, NSUInteger depth, NSMutableArray *out);
static NSString *JTVCChainOf(id vc, NSUInteger maxDepth);
static void JTDescribeTabBarSubviews(UITabBar *tb, NSMutableString *s);
static NSString *JTDescribeTabBar(UITabBarController *tbc);
static UITabBarController *JTFindTabBarController(void);
static void JTProbeRemoveTab(void);
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
- (void)onProbe:(UIButton *)sender;
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
//
// ★ 关于 backtrace()：因为处理器现在跑在**备用栈**上（见 JTInstallCrashHandlers），
//   backtrace() 走的是备用栈，拿不到出问题那条栈的帧 —— 它只能证明"处理器确实执行了"。
//   出问题那条栈的完整帧链请以系统生成的 .ips 为准（设置 → 隐私与安全性 → 分析与改进）。
//   本日志真正独有的、.ips 里**没有**的信息是：**阶段标记**（崩在哪一步）。
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

    // ★ 必须给信号处理器一块**独立栈**（sigaltstack + SA_ONSTACK）。
    //   2026-09-30 实测踩到：真机闪退是**栈溢出**（无限递归 511 帧），
    //   而我们的 wf_crash.log **一个字节都没写出来**，最后只能靠系统生成的 .ips 定位。
    //   原因：默认情况下信号处理器跑在**已经耗尽、已经踩到守护页的那条栈**上，
    //   第一条指令就二次 SIGSEGV → 再次进处理器 → 内核直接按默认动作终止进程。
    //   所以"栈溢出"这一最常见的崩溃类型，恰好是原来唯一观测不到的类型。
    //   注意 `signal()` 无法设置 SA_ONSTACK，必须换成 `sigaction()`。
    //   另一个边界：备用栈是**每个线程各自一份**，而 sigaltstack() 只对当前线程生效。
    //   这里在 %ctor 里调用 → 只有主线程有备用栈。子线程崩溃时本日志仍可能写不出来
    //   （这类崩溃请直接看系统 .ips）。主线程崩溃是本项目的主要场景，先覆盖它。
    static char *sAltStack = NULL;
    if (!sAltStack) {
        size_t sz = 128 * 1024;
        sAltStack = (char *)malloc(sz);
        if (sAltStack) {
            stack_t ss;
            memset(&ss, 0, sizeof(ss));
            ss.ss_sp = sAltStack;
            ss.ss_size = sz;
            ss.ss_flags = 0;
            if (sigaltstack(&ss, NULL) != 0) {
                free(sAltStack);
                sAltStack = NULL;
            }
        }
    }

    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = JTSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_ONSTACK;   // ← 关键：在备用栈上运行处理器
        sigaction(sigs[i], &sa, NULL);
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

// 纯指针比较，不发消息、不触发 +initialize。用于类名扫描时的廉价预筛。
static BOOL JTIsDescendantOf(Class c, Class root) {
    if (!c || !root) return NO;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        if (k == root) return YES;
    }
    return NO;
}

// ============================== 3b. hook 安装器 ==============================
//
// ★★ 这里曾经有一个"挂所有实现了该方法的子类"的通用安装器，2026-09-30 在真机上
//    **栈溢出闪退**，崩溃报告铁证（主线程 511 帧，交替重复 200+ 次）：
//
//      #5  JTOriginalIMPFor(self, map)
//      #6  JTViewDidAppearHook +76          ← 我们的 shim，正在查原 IMP
//      #7  -[UITabBarController viewDidAppear:] +60   ← 转发到了 UIKit 的 tbc 实现
//      #8  JTViewDidAppearHook +128         ← UIKit 里调 [super viewDidAppear:]，又落回我们的 shim
//      #9  -[UITabBarController viewDidAppear:] +60   ← 查表**又**命中 tbc
//      #10 JTViewDidAppearHook +128
//      ...（一直重复到踩穿栈守护页，KERN_PROTECTION_FAILURE）
//
//    完整因果链：
//      1. 我们挂了 UIViewController 和 UITabBarController **两个**类，
//         共用同一个 shim `JTViewDidAppearHook`，原 IMP 存进按类名索引的字典。
//      2. 调用 [tbc viewDidAppear:] → 落到 UITabBarController 的 method → 我们的 shim。
//      3. shim 用 `JTOriginalIMPFor(self, map)` 找原 IMP：**从对象类沿父类链找第一个命中**，
//         第一个就是 "UITabBarController" → 转发到 UIKit 的 tbc 实现。到这一步都对。
//      4. UIKit 的 `-[UITabBarController viewDidAppear:]` 内部调 `[super viewDidAppear:]`。
//         super 派发走的是 **UIViewController** 的 method list → 又是我们的 shim。
//      5. shim 再查表 —— 而它**只知道对象是 tbc 子类**，从对象类往上找第一个命中的
//         仍然是 "UITabBarController" → **又**转发到 UIKit 的 tbc 实现 → 回到第 4 步。
//
//    ★ 根因不是"查表写错了"，而是这个设计**在原理上无法区分"直接调用"和"[super] 调用"**：
//      共享 shim 拿不到"当前执行的是哪个类的 method list 条目"这个信息。
//      换句话说：**只要一个 shim 服务多个类，转发就不可判定**，改键、加特判都是治标。
//
//    ★ 所以改成：**一个 selector 只挂一个类**。原 IMP 唯一，shim 直接用它。
//      终止性可以证明：[super S] 派发到的是**父类**的 method list，而父类我们**没碰**，
//      于是走父类的原始实现；要再回到我们的 shim，必须有一次以该类为起点的 S 派发 ——
//      那在改动前也会发生，App 本来能跑就说明它不会无限递归。
//
//    代价：子类**自己重写**了该方法且**不调用 super** 时我们观测不到。
//      `viewDidAppear:` 这类回调 Apple 明确要求调用 super，绝大多数实现都会调，可接受。
//      （这是"漏一层观测"和"App 完全打不开"之间的取舍，选前者。）
static BOOL JTInstallSingleHook(const char *className, SEL sel, IMP replacement, IMP *outOrig) {
    if (!className || !sel || !replacement) return NO;
    Class c = objc_getClass(className);
    if (!c) return NO;

    // 只认"这个类**自己**实现"的方法。继承来的绝不碰：
    // method_setImplementation 改的是 Method 对象，而继承来的 Method 属于父类，
    // 改了会波及所有兄弟子类。
    Method own = JTOwnMethod(c, sel);
    if (!own) return NO;

    // 幂等：已经装过就绝不二次安装。
    // 二次安装的后果是 method_setImplementation 返回的是**我们自己的 shim**，
    // 于是"原 IMP"变成 shim 自己 → 一调用就自递归。必须挡住。
    if (method_getImplementation(own) == replacement) return NO;

    IMP orig = method_setImplementation(own, replacement);
    if (!orig || orig == replacement) return NO;   // 双保险：拿到的绝不能是自己
    if (outOrig) *outOrig = orig;
    return YES;
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

// 取一个 VC 的子 VC 列表。
//
// ★ 为什么不用 `vc.children`（2026-09-30 CI 实测）：
//   CI 上用的是 Xcode 26.6 的 iPhoneOS26.5 SDK，该 SDK 下 `children` 属性**没有暴露出来**，
//   clang 直接报：
//       Tweak.xm:569:36: error: property 'children' not found on object of type 'UIViewController *'
//   这是**硬 error**，`-Wno-error` 救不了 —— 因为它是"类型系统不认这个成员"，
//   不是"warning 被提升为 error"。本机没有 macOS，一次误判就是一轮 CI。
//
//   所以这里改走 KVC：只依赖 NSObject 的 `valueForKey:`，**编译期不依赖任何头文件声明**，
//   换哪个 SDK 都不会再挂。运行时 UIKit 确实有 children 这个属性，正常能取到；
//   万一取不到（异常或类型不符）就退回 childViewControllers（iOS 17 起标废弃，运行时仍在），
//   再取不到就返回 nil，让上层跳过这棵子树 —— 取证少一层，好过构建挂掉。
//
//   通用教训：**凡是"我不确定某个 SDK 头文件到底声明了没"的成员，一律走运行时取值。**
static NSArray *JTChildrenOf(UIViewController *vc) {
    if (!vc) return nil;
    @try {
        id v = [vc valueForKey:@"children"];
        if ([v isKindOfClass:[NSArray class]]) return (NSArray *)v;
    } @catch (NSException *ignored) {
    }
    @try {
        id v = [vc valueForKey:@"childViewControllers"];
        if ([v isKindOfClass:[NSArray class]]) return (NSArray *)v;
    } @catch (NSException *ignored) {
    }
    return nil;
}

static void JTCollectTabBars(UIViewController *vc, NSMutableArray *out, NSUInteger depth) {
    if (!vc || !out || depth > 10) return;
    if ([vc isKindOfClass:[UITabBarController class]] && ![out containsObject:vc]) {
        [out addObject:vc];
    }
    for (id c in JTChildrenOf(vc)) {
        if ([c isKindOfClass:[UIViewController class]]) {
            JTCollectTabBars((UIViewController *)c, out, depth + 1);
        }
    }
    JTCollectTabBars(vc.presentedViewController, out, depth + 1);
}

// ============================== 6b. tab 识别（2026-09-30 第二轮） ==============================
//
// 为什么需要这一块：第一轮 dump 拿到的信息**不足以决定删哪个 tab**。
//   - 5 个 tab 的 VC 类名全是 `BaseNavigationController`（一模一样）→ 不能按类名认
//   - `UITabBarItem.title` 全是空的 → 不能按标题认
//   - 可见文字是 App 自绘的 `FLAnimatedImageView` 里的 `UILabel`，只有 4 个
//     （首页 / 目的地 / 电话·消息 / 我的），第 5 个（index 2）是凸起大图标、没有文字
// 所以这里补三样东西，用来把 index 和"人看到的那个 tab"对上号：
//   1) 每个 tab 的 VC **子链**（BaseNavigationController > 真正的页面类）
//   2) 每个 item 的 accessibilityLabel（App 常常在这里写了名字）
//   3) tab bar 直接子视图逐条列出（下标 = 自绘顺序 = 视觉从左到右）+ 内含文字

static void JTCountClasses(UIView *v, NSUInteger depth,
                           NSUInteger *btn, NSUInteger *img, NSUInteger *lbl) {
    if (!v || depth > 4) return;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn isEqualToString:@"UITabBarButton"] && btn) (*btn)++;
    if ([cn hasPrefix:@"FLAnimatedImageView"] && img) (*img)++;
    if ([v isKindOfClass:[UILabel class]] && lbl) (*lbl)++;
    for (UIView *c in v.subviews) JTCountClasses(c, depth + 1, btn, img, lbl);
}

static void JTCollectLabels(UIView *v, NSUInteger depth, NSMutableArray *out) {
    if (!v || !out || depth > 4) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) [out addObject:t];
    }
    for (UIView *c in v.subviews) JTCollectLabels(c, depth + 1, out);
}

// VC 链：BaseNavigationController > 真正的页面类 > …（最多 maxDepth 层）
// 一律走 KVC，不用点语法 —— 这个 App 的页面类千奇百怪，点语法随时可能碰上
// SDK 没暴露的成员（见 Gotcha 20）。
static NSString *JTVCChainOf(id vc, NSUInteger maxDepth) {
    NSMutableString *s = [NSMutableString string];
    id cur = vc;
    for (NSUInteger i = 0; i < maxDepth && cur; i++) {
        if (i) [s appendString:@" > "];
        [s appendString:NSStringFromClass([cur class])];
        id next = nil;
        @try {
            if ([cur isKindOfClass:[UINavigationController class]]) {
                id vcs = [cur valueForKey:@"viewControllers"];
                if ([vcs isKindOfClass:[NSArray class]] && [(NSArray *)vcs count] > 0) {
                    next = [(NSArray *)vcs lastObject];
                }
            }
            if (!next && [cur isKindOfClass:[UIViewController class]]) {
                NSArray *ch = JTChildrenOf((UIViewController *)cur);
                if (ch.count > 0) next = ch.firstObject;
            }
        } @catch (NSException *ignored) {
        }
        cur = next;
    }
    return s;
}

static void JTDescribeTabBarSubviews(UITabBar *tb, NSMutableString *s) {
    if (!tb) return;
    NSUInteger btn = 0, img = 0, lbl = 0;
    JTCountClasses(tb, 0, &btn, &img, &lbl);
    [s appendFormat:@"    自绘清单: UITabBarButton=%lu  FLAnimatedImageView=%lu  UILabel=%lu  直接子视图=%lu\n",
        (unsigned long)btn, (unsigned long)img, (unsigned long)lbl,
        (unsigned long)tb.subviews.count];

    NSUInteger i = 0;
    for (UIView *sv in tb.subviews) {
        NSString *aid = sv.accessibilityIdentifier;
        NSString *alb = sv.accessibilityLabel;
        NSMutableArray *texts = [NSMutableArray array];
        JTCollectLabels(sv, 0, texts);
        [s appendFormat:@"      子[%lu] %@ (%.0f,%.0f,%.0f,%.0f)%@%@%@\n",
            (unsigned long)i, NSStringFromClass([sv class]),
            (double)sv.frame.origin.x, (double)sv.frame.origin.y,
            (double)sv.frame.size.width, (double)sv.frame.size.height,
            aid.length ? [NSString stringWithFormat:@" id=%@", aid] : @"",
            alb.length ? [NSString stringWithFormat:@" label=%@", alb] : @"",
            texts.count ? [NSString stringWithFormat:@" 文字=[%@]",
                           [texts componentsJoinedByString:@"/"]] : @""];
        i++;
    }
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
        [s appendFormat:@"    [%lu] %@   title=%@  tag=%ld  badge=%@  a11y=%@\n",
            (unsigned long)i, NSStringFromClass([vc class]),
            it.title ?: @"(无)", (long)it.tag, it.badgeValue ?: @"(无)",
            it.accessibilityLabel ?: @"(无)"];
        [s appendFormat:@"        链: %@\n", JTVCChainOf(vc, 4)];
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
            [s appendFormat:@"      item[%lu] title=%@ tag=%ld a11y=%@\n",
                (unsigned long)j, it.title ?: @"(无)", (long)it.tag,
                it.accessibilityLabel ?: @"(无)"];
            j++;
        }
        JTDescribeTabBarSubviews(tb, s);
    }
    return s;
}

// 找当前活着的 UITabBarController。两条路都走：
// 窗口树（root → presented → children）常常到不了 App 自己的容器，
// 所以再用我们自己登记的 VC 兜底 —— 这一点第一轮已经实测验证过是必要的。
static UITabBarController *JTFindTabBarController(void) {
    NSMutableArray *found = [NSMutableArray array];
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
            JTCollectTabBars(w.rootViewController, found, 0);
        }
        @synchronized (@"JTVC") {
            if (gJTVCLive) {
                for (UIViewController *vc in gJTVCLive.allObjects) {
                    if ([vc isKindOfClass:[UITabBarController class]] && ![found containsObject:vc]) {
                        [found addObject:vc];
                    }
                }
            }
        }
    } @catch (NSException *ignored) {
    }
    // 不用三元：`cond ? (Typed *)x : nil` 在 ObjC++ 下会把结果类型推成 id，
    // 虽然能过，但正是 objcpp.py 盯着的那类"ObjC 合法、ObjC++ 危险"的写法。显式分支最稳。
    if (found.count == 0) return nil;
    return (UITabBarController *)found[0];
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
    IMP orig = gJTOrigSetVCs;          // 先抓快照，避免转发途中被改写
    @try {
        JTDiag(@"[TabBar设置] %@ setViewControllers: → %@",
               NSStringFromClass([self class]), JTDescribeVCArray(vcs));
        NSArray<NSString *> *st = [NSThread callStackSymbols];
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < st.count && i < 10; i++) [s appendFormat:@"\n      %@", st[i]];
        JTDiag(@"[TabBar设置] 调用栈:%@", s);
    } @catch (NSException *e) {
    }
    if (orig) ((void (*)(id, SEL, NSArray *))orig)(self, _cmd, vcs);
}

static void JTSetVCsAnimatedHook(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    IMP orig = gJTOrigSetVCsAnim;
    @try {
        JTDiag(@"[TabBar设置] %@ setViewControllers:animated: → %@",
               NSStringFromClass([self class]), JTDescribeVCArray(vcs));
        NSArray<NSString *> *st = [NSThread callStackSymbols];
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < st.count && i < 10; i++) [s appendFormat:@"\n      %@", st[i]];
        JTDiag(@"[TabBar设置] 调用栈:%@", s);
    } @catch (NSException *e) {
    }
    if (orig) ((void (*)(id, SEL, NSArray *, BOOL))orig)(self, _cmd, vcs, animated);
}

static void JTInstallTabBarHooks(void) {
#if ENABLE_TABBAR_FORENSICS
    @try {
        if (!gJTSelSetVCs) gJTSelSetVCs = NSSelectorFromString(@"setViewControllers:");
        if (!gJTSelSetVCsAnimated)
            gJTSelSetVCsAnimated = NSSelectorFromString(@"setViewControllers:animated:");

        // 两个 selector 各自独立：各自一个 shim、各自一个原 IMP 全局。
        // （曾经共用一个按类名索引的字典 → 后者覆盖前者 → 参数个数错位 + 互相递归。）
        BOOL a = JTInstallSingleHook("UITabBarController", gJTSelSetVCs,
                                     (IMP)JTSetVCsHook, &gJTOrigSetVCs);
        BOOL b = JTInstallSingleHook("UITabBarController", gJTSelSetVCsAnimated,
                                     (IMP)JTSetVCsAnimatedHook, &gJTOrigSetVCsAnim);
        if (a) gJTHookedSetVCs = @"UITabBarController";
        if (b) gJTHookedSetVCsAnim = @"UITabBarController";

        JTDiag(@"[TabBar钩子] setViewControllers: %@ | setViewControllers:animated: %@",
               a ? @"已挂 UITabBarController" : @"未挂（该类未自己实现，或已挂过）",
               b ? @"已挂 UITabBarController" : @"未挂（该类未自己实现，或已挂过）");
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
    IMP orig = gJTOrigPresent;
    @try {
        NSString *key = [NSString stringWithFormat:@"%@ → %@",
                         NSStringFromClass([self class]),
                         vcToPresent ? NSStringFromClass([vcToPresent class]) : @"(nil)"];
        NSArray<NSString *> *stack = nil;
        if (JTShouldCapturePresentStack(key)) stack = [NSThread callStackSymbols];
        JTNotePresent(key, stack);
    } @catch (NSException *e) {
    }
    if (orig) {
        // completion 参数用 __unsafe_unretained：ARC 不会去 retain/release 一个栈上的 block
        ((void (*)(id, SEL, id, BOOL, __unsafe_unretained id))orig)(self, _cmd, vcToPresent,
                                                                    animated, completion);
    }
}

static void JTInstallPresentHooks(void) {
#if ENABLE_POPUP_FORENSICS
    @try {
        if (!gJTSelPresent)
            gJTSelPresent = NSSelectorFromString(@"presentViewController:animated:completion:");
        BOOL ok = JTInstallSingleHook("UIViewController", gJTSelPresent,
                                      (IMP)JTPresentHook, &gJTOrigPresent);
        if (ok) gJTHookedPresent = @"UIViewController";
        JTDiag(@"[弹窗钩子] presentViewController:animated:completion: %@",
               ok ? @"已挂 UIViewController" : @"未挂（该类未自己实现，或已挂过）");
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
    IMP orig = gJTOrigVDA;   // 唯一且正确的原 IMP；常量时间，不做父类链查找
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);   // 先转发，App 行为完全不变
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            JTNoteVC((UIViewController *)self);
        }
    } @catch (NSException *ignored) {
    }
}

static void JTInstallViewDidAppearHooks(void) {
    @try {
        if (!gJTSelVDA) gJTSelVDA = NSSelectorFromString(@"viewDidAppear:");
        // ★ 只挂 UIViewController 自己。**不要**挂子类 —— 见 JTInstallSingleHook 上面的注释，
        //   那正是 2026-09-30 栈溢出闪退的原因（UIKit 的 [super viewDidAppear:] 会回到我们的 shim）。
        BOOL ok = JTInstallSingleHook("UIViewController", gJTSelVDA,
                                      (IMP)JTViewDidAppearHook, &gJTOrigVDA);
        if (ok) gJTHookedVDA = @"UIViewController";
        JTDiag(@"[钩子] viewDidAppear: %@",
               ok ? @"已挂 UIViewController" : @"未挂（该类未自己实现，或已挂过）");
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

// ============================== 12b. 「逐个移除 tab」实验 ==============================
//
// 为什么做成"点一下试一个"，而不是直接写死 v0.3 的移除规则：
//
// 未知 1 —— **「流量」对应哪个 index 还没确认。**
//   第一轮 dump 里 5 个 tab 的 VC 类名**全是** BaseNavigationController，
//   UITabBarItem.title 全是空，可见文字只有 4 个（首页/目的地/电话·消息/我的），
//   剩下 index 2 是凸起大图标、没有文字。只能靠"移除它、看屏幕上哪个消失"来确定。
//
// 未知 2 —— **过滤 viewControllers 之后，App 自绘的图标会不会跟着走。**
//   JegoTabBar 是 App 自己子类化的 UITabBar，那 5 个 FLAnimatedImageView 是它自绘的，
//   真正的 UITabBarButton 在下面一层。如果自绘图标不跟着 items 重建，
//   光过滤 viewControllers 会留下"幽灵图标"，v0.3 就得换一条路（直接操作自绘子视图）。
//   这一条直接决定实现路径，必须实测。
//
// 做成"每次只移除一个 + 每次先完整恢复"的顺序实验，一轮同时回答这两个问题。
// 关键安全属性：**只在点击时发生** —— 不动启动路径，试错了重新打开 App 就恢复，
// 所以任何一步都不可能把"App 能正常打开"这个已经拿到的成果弄丢。
static void JTProbeRemoveTab(void) {
    @try {
        UITabBarController *tbc = JTFindTabBarController();
        if (!tbc) {
            JTDiag(@"[实验] 找不到 UITabBarController");
            return;
        }

        // 第一次点击时记录原始状态；之后每次实验都从这里恢复，保证每次都从干净状态开始
        if (!gJTSavedVCs) {
            gJTSavedVCs = [tbc.viewControllers copy];
            gJTSavedSel = tbc.selectedIndex;
            JTDiag(@"[实验] 已记录原始状态：%lu 个 tab，selectedIndex=%ld",
                   (unsigned long)gJTSavedVCs.count, (long)gJTSavedSel);
        }
        if (gJTSavedVCs.count == 0) {
            JTDiag(@"[实验] 原始 viewControllers 为空，无法实验");
            return;
        }

        // 1) 先完整恢复
        [tbc setViewControllers:gJTSavedVCs animated:NO];
        if (gJTSavedSel < (NSInteger)gJTSavedVCs.count) tbc.selectedIndex = gJTSavedSel;
        JTDiag(@"\n===== [实验] 恢复后 =====\n%@", JTDescribeTabBar(tbc));

        int idx = gJTProbeCursor;
        gJTProbeCursor++;
        if (gJTProbeCursor > (int)gJTSavedVCs.count) gJTProbeCursor = 0;

        if (idx < (int)gJTSavedVCs.count) {
            NSMutableArray *m = [gJTSavedVCs mutableCopy];
            [m removeObjectAtIndex:(NSUInteger)idx];
            [tbc setViewControllers:m animated:NO];
            if (tbc.selectedIndex >= (NSInteger)m.count) tbc.selectedIndex = 0;
            JTDiag(@"[实验] ★ 本次只移除 index=%d（%lu → %lu 个 tab）。"
                    "请看屏幕上哪个 tab 消失了。", idx,
                   (unsigned long)gJTSavedVCs.count, (unsigned long)m.count);
        } else {
            JTDiag(@"[实验] ★ 本次不做移除，只把 tab 恢复成原始的 %lu 个。",
                   (unsigned long)gJTSavedVCs.count);
        }

        // 2) 立刻 + 0.8 秒后各 dump 一次。
        //    自绘图标如果是"等下一轮 layout 才重建"，只有延后那次能看出来 ——
        //    这正是未知 2 的判据。
        JTDiag(@"[实验] 移除后（立即）\n%@", JTDescribeTabBar(tbc));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITabBarController *t2 = JTFindTabBarController();
            if (t2) JTDiag(@"[实验] 移除后（+0.8s）\n%@", JTDescribeTabBar(t2));
        });
    } @catch (NSException *e) {
        JTDiag(@"[实验] 异常: %@", e.reason);
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

// RM 按钮：逐个移除 tab 的实验入口。
// 每点一次：先恢复原状 → 只移除一个 index → 记录 → 把诊断写进剪贴板。
// 连点 6 次（5 个 tab + 1 次纯恢复）就把 5 个 index 全试完。
- (void)onProbe:(UIButton *)sender {
    @try {
        JTProbeRemoveTab();
        UIPasteboard.generalPasteboard.string = JTDiagSnapshot();
        int shown = (gJTProbeCursor == 0) ? (int)gJTSavedVCs.count : gJTProbeCursor - 1;
        [self flash:[NSString stringWithFormat:@"-%d", shown]];
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

        // 第二个按钮 RM：逐个移除 tab 的实验入口。
        // 单独一个按钮、单独一种颜色 —— 混进 JT 按钮的手势里会误触，
        // 而误触会真的改 tab bar（虽然可恢复，但会让人以为 App 出问题了）。
        UIButton *rm = [UIButton buttonWithType:UIButtonTypeCustom];
        rm.frame = CGRectMake(0, 0, 44, 44);
        rm.backgroundColor = [UIColor colorWithRed:0.72 green:0.28 blue:0.10 alpha:0.80];
        rm.layer.cornerRadius = 22.0;
        rm.layer.masksToBounds = YES;
        rm.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [rm setTitle:@"RM" forState:UIControlStateNormal];
        [rm setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        rm.center = CGPointMake(w.bounds.size.width - 34.0, 182.0);
        [rm addTarget:h action:@selector(onProbe:) forControlEvents:UIControlEventTouchUpInside];
        [w.rootViewController.view addSubview:rm];

        w.hidden = NO;

        gJTOverlay = w;
        gJTButton = b;
        gJTRmButton = rm;
        gJTBtnHandler = h;   // 必须持有：target-action 不 retain target
        JTDiag(@"[悬浮按钮] 已安装（JT=抓取/长按，RM=逐个移除 tab 实验）");
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
    // 一行总览：哪个钩子真的挂上了。挂载失败时这里是"无"，而各安装器自己的那行会说明原因 ——
    // 两处对不上就说明有问题，不用去翻中间几十行日志。
    JTDiag(@"[钩子总览] viewDidAppear=%@ | setViewControllers=%@ | setViewControllers:animated=%@ | present=%@",
           gJTHookedVDA ?: @"无", gJTHookedSetVCs ?: @"无",
           gJTHookedSetVCsAnim ?: @"无", gJTHookedPresent ?: @"无");
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
