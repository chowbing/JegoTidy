// ============================================================================
// Tweak.xm — 无忧行 (com.cmi.jegotrip) 界面精简 Tweak
// v1.1（最终版）—— 三条线全部落地；广告规则下沉到类；并把被隐藏广告占的高度交给布局层收掉。
//   收工依据（Shawn 2026-09-30）：**残留留白不影响使用**，不再追 section inset 那一层。
//   未验证项已在 README「验收状态」一节列清（目标 ② 零证据；v1.1 未经真机复核）。
// ============================================================================
// 目标（已与 Shawn 确认）：
//   1) 把「首页 / 目的地 / 流量」这三个 **tab 从导航栏移除**，App 直接落到剩下的 tab；
//   2) 拦掉开屏广告与启动弹窗；
//   3) 清掉剩余的广告/营销位。
//
// 三条线各自的实现位置：
//   ① 移除 tab          → 第 12b 节（JTApplyTabRule / JTFixDrawnTabItems）
//   ② 拦开屏 / 启动弹窗 → 第 7 节（JTClassLooksLikeSplashOrPopup + JTPresentHook 尾部的收尾）
//   ③ 清广告位          → 第 12c 节（JTSweepBlockAds + 定时器）
//
// 使用方式（真机）：
//   **发布版（`ENABLE_DEBUG_UI = 0`，当前）**：装好即用，界面上**没有任何我们的东西** ——
//   没有悬浮按钮、没有日志。规则在启动后自己生效。
//     1) 打开 App 正常用：只剩「电话·消息」「我的」两个 tab，广告位被清掉。
//     2) 出问题怎么办：**在 TrollFools 里把这个插件的注入关掉** → 立刻完全回到原版，
//        不用重新构建、不用重装。（比调试版的"长按 T"更彻底：T 只恢复本次启动。）
//
//   **调试版（把 `ENABLE_DEBUG_UI` 改成 1 重新构建）**：右上角出现两个可拖动小圆点：
//     · 蓝色 JT —— 点 = 抓当前页并复制（含「广告候选汇总」）；长按 = 复制全部诊断
//     · 橙色 T  —— 点 = 手动再应用一次 tab 规则；长按 = **恢复原始 5 个 tab + 恢复所有
//                  被隐藏的广告 + 撤销三类类级覆写 + 停手**（现场后悔药，不用重装重启）
//     排查流程：打开 App 正常用一遍（切 tab、进各页面、把启动弹窗复现一次）→
//     长按 JT → 完整诊断进剪贴板 → 粘贴回来。
//
// 安全设计（每一条都对应上一轮踩过的坑）：
//   · 诊断钩子绝不放在启动路径：%ctor 只装崩溃处理器，其余 dispatch 到主队列。
//   · 查类表一律用 class_copyMethodList 手走父类链，绝不用 class_getInstanceMethod
//     （它会强制 +initialize；在 dyld 阶段全进程扫类曾把目标 App 打崩到完全打不开，
//      且 @try/@catch 救不了 —— 异常在 dispatch_once 里被 libdispatch 边界吞掉）。
//   · 通用 hook 安装器先按"是不是某根类的后代"做廉价预筛，再对每个类做一次
//     class_copyMethodList；否则为全进程几万个类各做一次会卡住启动一两秒。
//   · 启动自愈计数：同一构建连续 3 次启动异常 → 本次不装任何钩子（调试版还会留悬浮按钮）。
//   · 诊断缓冲用滚动窗口 + 显式截断标记，绝不"写满就静默停止"。
//   · 信号处理函数里只用 open/write/snprintf/backtrace_*（异步信号安全）。
//   · v0.3 新增的每处"改界面"都有对应的放弃条件（匹配不上就不动）、幂等保证、
//     以及一个现场可用的撤销入口（调试版的"长按 T"；发布版则是 TrollFools 关闭注入）。
//     详见文件头下面那段。
//
// ---------------------------------------------------------------------------
// v0.3 相对 v0.2 的变更（依据 = 2026-09-30 v0.2b 真机 dump，不是推断）
// ---------------------------------------------------------------------------
// dump 确认的事实：
//   · tab bar 是**系统 UITabBarController**（Path A），5 个 tab，tag = 1000..1004
//   · tabBar = `JegoTabBar`（App 子类化的 UITabBar），frame=(0,849,430,83)，屏宽 430
//   · 自绘图标是 tabBar 的**直接子视图**、类名 `FLAnimatedImageView`，按 x 排在
//     0 / 86 / 172 / 258 / 344（= i × 430/5）；第 k 个 ↔ 第 k 个 tab。
//     第 2 个（x=172）是凸起 55×55 大图标、没有 UILabel。
//   · 5 个 tab 的 VC 类名**全是** `BaseNavigationController`（认不出），
//     `UITabBarItem.title` **全空**（认不出）→ 只能按 `UITabBarItem.tag` 认。
//   · 过滤 `viewControllers` 后**真实 `UITabBarButton` 会跟着变**（5→4 并重排），
//     但**自绘的 5 个 `FLAnimatedImageView` 一个都不动** → 只过滤会留下"幽灵图标"。
//
// 所以 tab 移除做成**两层**：
//   A) 过滤 `viewControllers`（保留 tag 1003/1004）→ 真实按钮正确
//   B) 按槽位隐藏 + 重排自绘图标 → 视觉正确（只做 A 会看到残留图标）
//
// 为什么自绘图标是"隐藏 + 重排"而不是只隐藏：
//   只 `hidden=YES` 的话，保留的两个图标仍在 x=258/344（靠右），左边空三格，看着就是坏的。
//   所以按 n 个保留项重算中心 `x = (k+0.5) × W/n` —— 与系统按钮自己的重排公式一致。
//
// 为什么用**主动扫描 + 定时复检**而不是只靠 `setViewControllers:` 钩子：
//   v0.2 dump 证明启动期的 `setViewControllers:` 在我们装钩子**之前**就调完了
//   （日志里一条 `[TabBar设置]` 都没有）→ 钩子拿不到启动那一次，必须主动扫。
//   定时复检是为了兜住"App 之后按服务端配置重建 tab bar"（`JGTabBarConfigModel`）。
//
// 广告位处理走**定时扫掠视图树**（`JTSweepBlockAds`），不走 `addSubview:` 钩子：
//   `addSubview:` 是热方法，为全 App 每个 UIView 加一次类名判定不值得；而且它只覆盖
//   "被加进来"的那一刻，懒加载 / 复用 / 异步换内容都容易漏。扫掠对"什么时候出现"
//   完全不敏感 —— 广告只要进了视图树，下一秒就被扫到。
//
// ★ 安全底线（每一条都对应一种"会把 App 弄坏"的方式）：
//   · 保留 tag 一个都没匹配上 → **整体放弃**，绝不把 tab 清空
//   · 保留集等于全集（无可移除）→ 什么都不做
//   · 自绘图标数量与预期槽位数不一致 → **不猜**，只记日志
//   · 所有改动**幂等**：状态已经对了就一个字节都不改（否则会和 App 自己的重排打架、闪烁）
//   · 悬浮按钮 T 长按 = **恢复原始 5 个 tab 并停手**（v0.3 的后悔药）
//
// ---------------------------------------------------------------------------
// v0.3.1：修掉 v0.3 首轮真机暴露的「自绘层认错槽位」
// ---------------------------------------------------------------------------
// v0.3 用"把 tabBar 直接子视图按 x 排序，第 k 个 = 第 k 个槽位"来认身份。
// 这个约定**只在原始 5 槽位布局下成立** —— 我们自己按 2 槽位重排过一次之后，
// 排序结果就不再等于原始槽位顺序，于是隐藏的是错的那几个，App 每重排一次结果又变一次。
// **用位置认身份，一旦自己改过位置就自毁。**
// 修法 = **绑定一次**（只在原始布局下绑定，且要求每个槽位都认到视图），之后一直用绑定。
// 顺带把"槽位装饰"的收集范围从 `FLAnimatedImageView` 放宽到**所有按槽位摆放的直接子视图**
// —— tab 2（流量）的凸起装饰是两个普通 `UIView`，原来漏了。
// 完整证据链与推导见第 12b 节 JTBindDrawnSlots 上面的注释。
//
// ---------------------------------------------------------------------------
// v0.3.2：目标 ① 达成，转去定位"残留的凸起装饰"
// ---------------------------------------------------------------------------
// v0.3.1 真机结果：5 个槽位装饰全部 `[隐]`，保留 2 个均分摆放，全程无反复。
// 但导航栏中间仍可见"凸起圆点的上半部分"。**直接子视图清单看不出它是什么**
// （所有槽位装饰都已经 [隐]），所以新增第 6c 节的 tab bar 深挖：
// 子树（深度 3）+ 非视图的 CALayer + tab bar 的兄弟视图，三样一起打，只在长按 JT 时输出。
//
// ---------------------------------------------------------------------------
// v0.3.3：目标 ① 收官，dump 升级为"能直接指向广告位"
// ---------------------------------------------------------------------------
// 用户反馈（v0.3.2 真机）：中间那个圆**已经不见了** —— 目标 ① 到此为止，不再追。
// 新任务：**「我的」页底部的图片广告**要一并清掉。
//
// 上一版的 dump 用来找广告是不够用的，所以这一版**只改诊断、不改行为**：
//   1) dump 上限 8 层/500 节点 → 12 层/1500 节点。
//      「我的」页是表格型长页面，窗口→根VC→容器→表格→cell→contentView→卡片→图片
//      就已经 7 层，横向还有几十个 cell，500 节点会在到达底部广告位之前耗尽。
//      dump 是**用户点一下才跑一次**，加大没有性能风险。
//   2) 每个节点补 **窗口坐标** `win=(x,y,w,h)`。
//      原来只有相对父视图的 frame —— "屏幕底部那条广告"到底是哪个节点，
//      得自己把整条父链的 origin 加一遍，节点一多必然算错，算错就会改错节点。
//   3) 每个节点打标：`★★已知广告位` / `★广告嫌疑` / `[H5]`。
//      `[H5]` 这一条尤其重要 —— 无忧行是原生 + H5 混合，**原生方案对 H5 内部元素完全无效**，
//      H5 里画的广告在原生树上只是个 `WKContentView`。一眼看出"在不在 H5 里"，
//      才能避免白改一版。
//   4) 新增「广告候选汇总」：只挑"已知广告类 / 类名可疑 / 横幅形态图片视图"三类，
//      带窗口坐标单独列一段。★ 它只**报告**，不隐藏 —— 关键词判定误报率高，
//      直接拿它去藏视图，就是把"猜"写进了产品行为里。判定由人做，改由下一版做。
//
// ---------------------------------------------------------------------------
// v0.3.4：两处运营位一起清；并且**隐藏之后把占的高度收掉**
// ---------------------------------------------------------------------------
// v0.3.3 的 dump 给出了两个目标（依据 = 真机截图 + 视图树，不是推断）：
//   · 「我的」页底部：`TBMineBannerCell (14,785,403,155)`，
//     内含 2 个 `TBMineBannerItemCell`（"邀新有礼" / "流量特惠"，各一个 178×100 的 UIImageView）
//   · 「电话/消息」页中部：「境外出行买语音 五折优惠」横幅 —— 对应 `BannerCycleView` / `BannerCycleViewCell`
//     （**这一条是推断**，证据强度与推导写在 `JTClassIsKnownAdView` 上面）
//
// 这一版做三件事：
//   1) 把上面四个类名加进"已知广告位"白名单 → 隐藏。
//   2) ★ **隐藏 ≠ 去掉**：`hidden=YES` 只是不画，布局里那一格还在。
//      「我的」页那条在最后一格（留白在底部，尚可忍），
//      「电话/消息」页那条在**页面中部**（通讯工具和「最近记录」之间），留白一眼就看得出来。
//      所以新增第 12c-2 节的收起机制：按"侵入性从小到大"试四条路
//      （自身约束 → 父视图约束 → contentView 约束 → delegate 的 size 钩子），
//      第一条成功就停；全失败就**如实记「会留白」**，不假装成功。
//      ★ 为什么把 size 钩子排在最后：它是唯一会真正触发重排的，但也是唯一需要**新增钩子**的 ——
//        而"新增钩子"正是本项目翻过两次车的那类改动。前三条件能解决就不装。
//   3) 长按橙色 **T** 现在会**同时**恢复 tab 和我们隐藏过的广告并停手。
//      因为 `BannerCycleView` 是推断出来的，必须有现场后悔药 —— 不能只靠"改代码重装"。
//
// ---------------------------------------------------------------------------
// v1.0（最终版）：广告规则**下沉到类**，不再被 App 重新显示回来
// ---------------------------------------------------------------------------
// v0.3.4 真机的**实测**结论（Shawn 回传的 dump，不是推断）：
//   · 「我的」页广告已消失 ✅
//   · 「电话/消息」页那条横幅**还在** ❌，且留下证据链：
//       [广告收起·页面出现] BannerCycleView → ①自身高度约束→0（原 145）      ← 当时确实收掉了
//       [广告收起·自证]     BannerCycleView 1.5s 后高度已为 0，收起生效
//       [广告收起·定时]     BannerCycleView → 无可用高度约束、也不是 frame 布局 ← 又出现了
//       [广告收起·自证]     BannerCycleViewCell 1.5s 后高度仍为 145 —— 收起未生效
//       [广告收起·自证]     TBMineBannerCell   1.5s 后高度仍为 155 —— 收起未生效
//   第二行"定时"那一轮是**关键证据**：收起只在我们刚刚隐藏它时才会被调用，
//   所以那一刻它一定是 `hidden = NO` —— **App 把隐藏过的广告重新显示回来了。**
//   → 结论：`hidden = YES` 不是一劳永逸的；靠 1 秒一次的扫掠去追是"竞速"，追不上就白干。
//
// v1.0 因此做三件事（第 12c-3 节）：
//   1) **粘性隐藏**：给白名单里的类加 `layoutSubviews` / `setHidden:` 两份覆写，
//      每个布局周期重新断言 `hidden = YES`；App 想设回 NO 的那一刻就压回去。
//      每个类只装一次，装在**子类**上（`class_addMethod`），父实现**按类各存一份**。
//   2) 修掉 ③ 的排他逻辑：原来 `contentView` 约束一改成功就 return，导致 ④ 永远没机会装 ——
//      而实测 ③"改成功"≠"生效"（`BannerCycleViewCell` 高度仍是 145）。现在 ③④ 并行。
//   3) 修正诊断：约束**已经是 0** 时不再误报成"无可用高度约束"（那会把"上一轮已收起"
//      误判成"收不了"，正是上一条被掩盖的原因）。
// 长按 T 的后悔药同步扩展到撤销粘性覆写。
//
// ---------------------------------------------------------------------------
// v1.1：把广告**占的高度**真正收掉（第 12c-4 节）
// ---------------------------------------------------------------------------
// Shawn 真机反馈："图片没有了，但图片所在位置留下了空白。"
// 这正是 v0.3.4 就记录在案的"收起未生效"——隐藏成功，但布局里那一格还在。
//
// 为什么 ①②③④ 都收不掉（v0.3.4 日志已给答案）：
//   内容收到 0，cell 仍是 145 → **cell 的高度不是内容给的，是布局对象给的**。
//     · ①②③ 改的都是内容的高度约束，管不到布局；
//     · ④（`preferredLayoutAttributesFittingAttributes:`）只在**自撑高**模式下才会被调用，
//       固定 `itemSize` 模式下布局根本不问 cell —— 装了也是死的（"声明不是证据"的又一例）。
//
// 唯一能重排的路：**影响 `prepareLayout` 的输入**，即 hook 委托的
// `collectionView:layout:sizeForItemAtIndexPath:`（第 12c-4 节）。它给的尺寸既决定这一格的
// frame，也决定后面所有格的起点 —— 改它才会真正重排。
//
// 三个关键决策（每一条都对应一个会让事情变坏的方式）：
//   1) **返回 0.5pt 而不是 0**：高度 0 的 item 是空矩形，`CGRectIntersectsRect` 返回 NO →
//      退出可见集 → cell 被回收 → `cellForItemAtIndexPath:` 返回 nil → **我们认不出它了**
//      （识别依赖那个 cell 的类名）→ 0/145 来回抖 = 屏幕上看就是闪。0.5pt 非空、肉眼不可见。
//   2) **认身份仍用类名，不记 indexPath**：每个布局周期重新问"那个位置上的 cell 是什么类"，
//      位置变了答案自然跟着变 —— 不会指着无辜的 item 下手。同一个坑不踩第三次。
//   3) **加钩子前先自证**：只有 cell 实际尺寸 ≈ `fl.itemSize`（证明布局确实按 itemSize 定高）
//      才敢加；对不上说明高度另有来源，加钩子会改变整个 collection view 的布局行为 → 宁可不修。
//      （委托自己实现了该方法的情形例外：那是"换掉并转发"，不改变语义。）
// 长按 T 的后悔药再扩展：把 size 覆写换回原实现（`class_addMethod` 上去的那批换成"直通版"，
// 否则恢复后广告会以 0.5pt 被压扁 —— 比不恢复更怪）。
//
// 另外：**发布版关掉调试 UI**（`ENABLE_DEBUG_UI = 0`）—— 去掉右上角那两个圆点和全部取证日志。
// 关掉它们不影响任何规则；现场后悔药由"在 TrollFools 里关闭注入"替代（更彻底且不用重装）。
// 顺带发现并修掉一个命名陷阱：`ENABLE_POPUP_FORENSICS` 名字像"纯取证"，
// 实际却门控着**目标 ② 赖以生效的那个钩子的安装**（拦截动作在 `JTPresentHook` 内部）。
// 现已把"安装"与"日志"拆开，见配置块。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <execinfo.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>

// 不依赖 substrate / ellekit 头文件：直接用 Objective-C runtime 替换方法实现。
// TrollFools 注入的进程内同样可用，同时消掉一类"头文件找不到"的构建失败。

// ============================== 配置 ==============================

#define JT_TAG              "JegoTidy"
#define JT_VERSION          "1.1"
#define JT_BUNDLE_ID        "com.cmi.jegotrip"

// ---- 调试界面 / 取证：发布版一律关掉，改 1 行就能拿回完整调试能力 ----
//
// ★ `ENABLE_DEBUG_UI = 0`（v1.1 最终版）= 没有悬浮按钮、没有取证日志。
//   为什么发布版要关：那两个圆点是**调试 UI**，日常用不该看见；而且它们会一直挂在屏幕上
//   （虽然可拖、可点，但终究是多余的东西）。关掉之后**不影响任何一条规则**：
//     · 启动自愈（连续 3 次启动异常就停手）用的是自己的文件 `wf_launch.txt`，与按钮无关；
//     · 崩溃取证 `wf_crash.log` 走信号处理器，与按钮无关；
//     · 三条规则线全部照常。
//   **失去了什么**：现场后悔药（长按橙色 T 恢复 5 tab + 恢复被隐藏广告 + 撤销类级覆写）。
//   但它有等价替代 —— **在 TrollFools 里把这个插件的注入关掉**即可完全回到原版，
//   不用重新构建、不用重装，而且比 T 更彻底（T 只恢复本次启动，TrollFools 是持久的）。
//   想再拿回按钮/日志：把 `ENABLE_DEBUG_UI` 改成 1，重新构建。
#define ENABLE_DEBUG_UI          0   // ★ 发布版 0 / 调试版 1

#define ENABLE_CRASH_LOG         1   // 崩溃取证（被动，只在真崩的时候写文件）—— 发布版保留
#define ENABLE_FLOAT_BUTTON      ENABLE_DEBUG_UI   // 悬浮按钮（蓝 JT / 橙 T）
#define ENABLE_TABBAR_FORENSICS  ENABLE_DEBUG_UI   // tab bar 构造过程取证（纯日志）
#define ENABLE_OVERLAY_FORENSICS ENABLE_DEBUG_UI   // UIWindow addSubview: 里的广告类取证（纯日志）
#define ENABLE_CLASS_SCAN        ENABLE_DEBUG_UI   // 全进程类名扫描（一次性，+3s 跑，重活）
//
// ★★ `ENABLE_POPUP_FORENSICS` **必须保持 1，它不归 ENABLE_DEBUG_UI 管**（2026-09-30 发现）：
//   它的名字叫"取证"，但它实际门控的是 `presentViewController:` 钩子的**安装**，
//   而**目标 ②（拦开屏/启动弹窗）的拦截动作就在那个钩子内部**（`JTPresentHook` 里的
//   `shouldDismiss` + 延迟 dismiss）。把它关掉 = 目标 ② 静默失效，而且日志上什么都看不出来。
//   v1.1 已把两件事拆开：**安装**看 `(ENABLE_POPUP_BLOCK || ENABLE_POPUP_FORENSICS)`，
//   **日志**看 `ENABLE_POPUP_FORENSICS`。所以现在把它置 0 只丢日志，不会丢功能。
#define ENABLE_POPUP_FORENSICS   1   // 弹窗取证（纯日志；安装与否见上面那条说明）

// ---- v0.3 新开的三条线（对应三个目标） ----
#define ENABLE_TAB_RULE          1   // ① 移除「首页 / 目的地 / 流量」三个 tab
#define ENABLE_AD_SWEEP          1   // ③ 定时扫掠视图树，隐藏已确认的广告位
#define ENABLE_POPUP_BLOCK       1   // ② 收掉开屏广告 / 启动弹窗

// v0.3.4：命中广告后**除了隐藏，还把占的高度收掉**。// 为什么需要：只 `hidden=YES` 会在原地留一块空白 ——
// 「我的」页那条在最后一格（留白在底部，尚可忍），
// 「电话/消息」页那条在**页面中部**（通讯工具和最近记录之间），留白一眼就看出来。
// 收起机制见 JTCollapseAdSpace()：先试 Auto Layout 高度约束，再试 frame，全部失败就**如实记日志**。
#define ENABLE_AD_COLLAPSE       1

// v1.0：**粘性隐藏** —— 把"隐藏广告"这条规则从"1 秒追一次"下沉到**类**上。
// 为什么需要（实测，v0.3.4 真机）：`BannerCycleView` 被隐藏后**又被 App 显示回来了**。
// 证据是日志里出现了第二次 `[广告收起·定时] BannerCycleView → …` —— 收起只在我们
// 刚刚隐藏它时才会被调用，所以那一刻它一定是 `hidden = NO`。
// 靠定时扫掠去追是"竞速"：追得上也难看（用户看到的仍是广告），追不上就是没效果。
// 机制见第 12c-3 节：给白名单里的类加 `layoutSubviews` / `setHidden:` 两份覆写。
// 独立开关的理由：它会往 App 的类上加方法（比"改一个视图的 hidden"更深一层），
// 出问题时要能单独关掉而不牵连 ①②③ 三条线。
#define ENABLE_AD_STICKY         1

// v1.1：**按 item 收高度** —— 让"布局"真的把广告那一格收掉（第 12c-4 节）。
// 为什么还需要它（Shawn 真机反馈）：图片没了，但**原位留下一块空白**。
// v0.3.4 的日志已经证明原因：内容（`BannerCycleView`）收到 0，cell 还是 145 ——
// **cell 的高度不是内容给的，是 `UICollectionViewFlowLayout` 的 itemSize 给的**。
// ①②③ 只能改内容；④ 只在自撑高模式下才会被调用。固定 itemSize 模式下布局根本不问 cell。
// 唯一能真正重排的路：影响 `prepareLayout` 的输入 —— 也就是 delegate 的
// `collectionView:layout:sizeForItemAtIndexPath:`。它会**往 App 的 delegate 类上加/换方法**，
// 所以必须有独立开关，出问题能单独关掉。
#define ENABLE_AD_ITEM_COLLAPSE  1

// 保留哪些 tab —— 按 `UITabBarItem.tag`。
// 实测 tag 与 index 一一对应：1000=首页 1001=目的地 1002=流量 1003=电话·消息 1004=我的
// → 保留 1003/1004，移除 1000/1001/1002。
// 若 App 改了 tag，这里一个都匹配不上 → 引擎**整体放弃**并大声记日志（不会把 tab 清空）。
static const NSInteger JTKeepTags[] = { 1003, 1004 };
#define JT_KEEP_TAG_COUNT   (sizeof(JTKeepTags) / sizeof(JTKeepTags[0]))

// 三个 tab 被移除后，启动默认落到哪个 tab（按 tag）。
// 1003 = 电话·消息（保留下来的最左一个）。想改成「我的」就换成 1004。
#define JT_DEFAULT_TAB_TAG  1003

// 广告扫掠参数：限深 / 单窗口节点预算。视图树是几百个节点量级，这两个数是两个数量级的余量。
#define SWEEP_MAX_DEPTH     12
#define SWEEP_NODE_BUDGET   3000
#define SWEEP_INTERVAL_SEC  1.0

// dump 参数（v0.3.3 上调）。
// 为什么上调：v0.3.2 的 500 节点 / 8 层是为"看清 tab bar"定的，而「我的」页是
// 表格型长页面 —— 窗口 → 根VC → 容器 → 表格 → cell → contentView → 卡片 → 图片，
// 光到图片就 7 层，横向还有几十个 cell，500 节点很容易在到达底部广告位之前就耗尽。
// dump 是**用户点一下才跑一次**，不是定时任务，加大没有性能风险。
#define DUMP_MAX_DEPTH      12
#define DUMP_MAX_NODES      1500
#define DIAG_CAP            200000

// 「像广告的图片」判定阈值（只用于**报告**，不用于隐藏）：
// 横幅类广告的形态是"宽、矮、贴边"，这里把宽 ≥150pt、高 ≥30pt、宽高比 1.8~8 的
// 图片视图列为候选。阈值故意放宽 —— 这一步只负责"别漏"，判由人来做。
#define AD_CAND_MIN_W       150.0
#define AD_CAND_MIN_H       30.0
#define AD_CAND_MIN_RATIO   1.8
#define AD_CAND_MAX_RATIO   8.0
#define AD_CAND_MAX_REPORT  20

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

// ---- v0.3 ①：tab 规则引擎的状态（见第 12b 节） ----
// 留底的**原始**全量 viewControllers。必须是"第一次见到的完整那套"，
// 不能每次复检都覆盖 —— 复检是在我们已经改过之后跑的，那时只剩 2 个，
// 把 2 个当原始，长按恢复就永远回不来。
static NSArray  *gJTOrigVCs = nil;
static NSInteger gJTOrigSel = 0;
static BOOL      gJTRuleDisabled = NO;   // 长按 T = 本次启动内停手（后悔药）
static BOOL      gJTRuleApplied  = NO;   // 是否已经应用过一次（决定要不要迁移 selectedIndex）
static NSString *gJTDrawnWarnKey = nil;  // 自绘层绑定失败的日志去重键

// ★ v0.3.1：自绘层的**槽位绑定**（index = 原始槽位，值 = 绑到该槽位的所有直接子视图）。
//   为什么必须绑一次、不能每次按 x 现算 —— 见第 12b 节 JTBindDrawnSlots 上面的长注释。
static NSArray<NSMutableArray<UIView *> *> *gJTDrawnSlots = nil;
static NSString *gJTDrawnStateKey = nil; // 自绘层最终状态的日志去重键

// ---- v0.3 ③：广告扫掠的状态（见第 12c 节） ----
static NSMutableSet<NSString *> *gJTAdLoggedSuspect = nil;  // 只记日志、不动的可疑类
static NSMutableSet<NSString *> *gJTAdLoggedHidden  = nil;  // 已隐藏过、已记过日志的类
static NSMutableDictionary<NSString *, NSNumber *> *gJTSuspectCache = nil;  // 类名 → 可疑判定缓存
static dispatch_source_t         gJTSweepTimer = NULL;

// v0.3.4：后悔药。记录**我们亲手隐藏过的广告视图**，长按 T 时逐个恢复。
// 用 NSHashTable（弱引用）：视图本来就在层级里，我们不该成为它的唯一持有者 ——
// 强引用会让被 App 丢弃的 cell 无法释放（cell 复用 + 我们持有 = 内存只增不减）。
static NSHashTable<UIView *>    *gJTHiddenAdViews = nil;
static BOOL                      gJTAdRuleDisabled = NO;   // 长按 T 后本次启动内不再动广告
static NSMutableSet<NSString *> *gJTAdCollapseLogged = nil; // 收起结果的日志去重（按类名）

// v1.1：⑤「按 item 收高度」的状态（见第 12c-4 节）
static NSMutableSet<NSString *> *gJTAdItemLogged   = nil;   // ⑤ 结果的日志去重
// 弱键 = 列表容器（cv / tv），值 = 上次让它重跑布局的时刻。用 NSMapTable 弱键：
// 容器本来就在层级里，我们不该成为它的唯一持有者。
static NSMapTable<UIScrollView *, NSNumber *> *gJTAdInvalidateLog = nil;
static NSUInteger                gJTAdInvalidateTotal = 0;  // 总量上限，防"布局抖 → 反复 invalidate"

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
static void JTDescribeSubtree(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                              NSUInteger *budget, NSMutableString *s);
static NSString *JTDescribeTabBarDeep(UITabBar *tb, NSUInteger maxDepth);

// v0.3 ① tab 规则引擎（第 12b 节）
static NSArray<NSNumber *> *JTKeepTagList(void);
static NSArray<NSNumber *> *JTRemovedSlotsOf(NSArray *all);
static NSString *JTTagListOf(NSArray *vcs);
static NSInteger JTTagIndexOf(NSArray *vcs, NSInteger tag);
static NSArray<UIView *> *JTSlotDecorationCandidates(UITabBar *tb, CGFloat slotW);
static NSString *JTDescribeSlotViews(NSArray<UIView *> *views);
static BOOL JTDrawnBindingAlive(UITabBar *tb);
static BOOL JTBindDrawnSlots(UITabBar *tb, NSInteger totalSlots);
static NSString *JTDrawnSlotsStateString(void);
static void JTFixDrawnTabItems(UITabBar *tb, NSInteger totalSlots,
                               NSArray<NSNumber *> *removedIdx, NSString *reason);
static void JTApplyTabRule(NSString *reason);
static void JTRestoreTabs(void);
static void JTScheduleTabRuleReapply(void);

// v0.3 ③ 广告扫掠（第 12c 节）
static BOOL JTClassIsKnownAdView(NSString *cn);
static BOOL JTClassLooksLikeAdSuspect(NSString *cn);
// 第 5 节 dump 里要给"广告嫌疑节点"打标，所以这两个判定必须前置声明。
static NSString *JTWindowRectString(UIView *v);
static NSString *JTAdCandidateSummary(UIView *root);
static NSUInteger JTSweepBlockAdsInView(UIView *v, NSUInteger depth, NSUInteger *budget,
                                        NSMutableArray *hiddenNew, NSMutableArray *suspect,
                                        NSMutableArray *collapseLog, NSMutableArray *stickyLog,
                                        NSMutableArray *itemLog);
static void JTSweepBlockAds(NSString *reason);
static void JTStartAdSweepTimer(void);
// v0.3.4：收起占位 + 布局取证 + 后悔药
static NSString *JTCollapseAdSpace(UIView *v);
static NSString *JTDescribeLayoutForView(UIView *v);
static void JTRestoreAds(void);
// v1.0：粘性隐藏（JTRestoreAds 在前、定义在后，必须前置声明）
static NSUInteger JTRemoveStickyHide(void);
// v1.1：按 item 收高度（第 12c-4 节）—— 扫掠在前、定义在后。
// 参数是"列表里的任意视图"（广告横幅或它所在的 cell 都行），函数内部会归一化到 cell。
static NSString *JTAdItemCollapse(UIView *v);
static NSUInteger JTAdItemCollapseUndo(void);

// v0.3 ② 开屏 / 弹窗判定（第 7 节用到）
static BOOL JTClassLooksLikeSplashOrPopup(NSString *cn);

// ============================== 0. 悬浮按钮的窗口（仅调试版） ==============================
// 整节由 `ENABLE_FLOAT_BUTTON` 门控；发布版（`ENABLE_DEBUG_UI = 0`）这个窗口根本不会被创建。

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
- (void)onTabs:(UIButton *)sender;                        // 手动再应用一次 tab 规则
- (void)onTabsRestore:(UILongPressGestureRecognizer *)g;  // 长按 = 恢复原始 5 个 tab 并停手
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

// ============================== 3c. "按类转发父实现"的通用回查 ==============================
//
// 场景：我们用 `class_addMethod` 在**某个类**上新增了一份覆写（只在该类生效），
// 覆写内部要调用"父类原本的实现"。这个父实现**必须按类各存一份**，不能用全局单份 ——
// 反例（真实）：白名单里 4 个是 `UICollectionViewCell` 子类，它们继承的 `layoutSubviews`
// 来自 `UICollectionViewCell`；若统一取 `[UIView layoutSubviews]` 的 IMP 转发，
// 就绕过了 `UICollectionViewCell` 自己的布局逻辑，cell 会画错。
//
// 用法：安装时用 `JTSafeInstanceMethod(cls, sel)` 取父实现存进一张小表（键 = 类），
// 覆写里调用本函数回查。`self` 的实际类可能比安装的类更深（App 有私有子类），
// 所以从 `self` 的类往上找**第一个自己实现了 sel 的类**，那才是安装点。
//
// 与 `[super …]` 的区别：本函数用显式 IMP 调用，不经过消息派发，不可能绕回自己
// （`objc_msgSendSuper` 需要知道安装点的类，而覆写里拿不到；这正是 2026-09-30
// 栈溢出闪退的同一种失效模式）。首次解析后按 `self` 的类缓存，后续只是一次表扫描。
//
// ★★ 为什么用 **C 结构体数组**而不是 `NSMutableDictionary`（2026-09-30 CI 教训）：
//   键是 `Class`，而 `Class` 是**对象指针**。想把它塞进字典就得
//   `@((uintptr_t)cls)`，取出来又要 `(Class)key.unsignedLongLongValue` ——
//   而后者是 **ARC 明令禁止的"整数 → 对象指针"强转**，直接编译失败：
//       error: cast of 'uintptr_t' to 'Class' is disallowed with ARC
//   表项本来就 ≤ 8 个，用定长数组既不需要任何强转，也没有每轮布局的字典分配。
//   （`__unsafe_unretained Class` 在 C 结构体里是合法的 —— 类对象永不释放。）
#define JT_BASE_TABLE_CAP 16

typedef struct {
    __unsafe_unretained Class cls;    // 缓存键 = self 的**实际**类
    IMP                      base;    // 该类对应的父实现
} JTBaseIMPEntry;

typedef struct {
    JTBaseIMPEntry items[JT_BASE_TABLE_CAP];
    NSUInteger     count;
} JTBaseIMPTable;

static void JTBaseIMPTableReset(JTBaseIMPTable *t) {
    if (!t) return;
    t->count = 0;
    for (NSUInteger i = 0; i < JT_BASE_TABLE_CAP; i++) {
        t->items[i].cls  = Nil;
        t->items[i].base = NULL;
    }
}

static IMP JTBaseIMPForOwner(id self, SEL sel, JTBaseIMPTable *table, IMP ourHook) {
    if (!table) return NULL;
    Class c = object_getClass(self);
    if (!c) return NULL;

    // 1) 查缓存：从 self 的类往上，第一个出现在表里的就是安装点
    for (Class k = c; k; k = class_getSuperclass(k)) {
        for (NSUInteger i = 0; i < table->count; i++) {
            if (table->items[i].cls == k) return table->items[i].base;
        }
    }

    // 2) 未命中：解析安装点 —— 从 self 的类往上，第一个"自己实现了 sel"的类
    Class owner = Nil;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        Method m = JTOwnMethod(k, sel);
        if (!m) continue;                                  // 这个类没实现，继续往上
        if (method_getImplementation(m) == ourHook) owner = k;
        break;                                             // 第一个"自己实现"的类就是它
    }
    if (!owner) return NULL;

    Method b = JTSafeInstanceMethod(class_getSuperclass(owner), sel);
    if (!b) return NULL;
    IMP base = method_getImplementation(b);
    // 只在解析成功时缓存 —— 负缓存会让后续永远失败。
    if (base && table->count < JT_BASE_TABLE_CAP) {
        table->items[table->count].cls  = c;
        table->items[table->count].base = base;
        table->count++;
    }
    return base;
}

// 记一条"类 → 父实现"。同类的已有条目会被**更新**（撤销后又重装的情形）。
// 表满返回 NO —— 宁可记不上、如实报错，也不覆盖别人的条目。
static BOOL JTBaseIMPTablePut(JTBaseIMPTable *t, Class c, IMP base) {
    if (!t || !c || !base) return NO;
    for (NSUInteger i = 0; i < t->count; i++) {
        if (t->items[i].cls == c) { t->items[i].base = base; return YES; }
    }
    if (t->count >= JT_BASE_TABLE_CAP) return NO;
    t->items[t->count].cls  = c;
    t->items[t->count].base = base;
    t->count++;
    return YES;
}

// 按类取回父实现；没有返回 NULL。
static IMP JTBaseIMPTableGet(const JTBaseIMPTable *t, Class c) {
    if (!t || !c) return NULL;
    for (NSUInteger i = 0; i < t->count; i++) {
        if (t->items[i].cls == c) return t->items[i].base;
    }
    return NULL;
}

// 按类删掉一条（尾部元素填补，保持数组紧凑）。
static void JTBaseIMPTableRemove(JTBaseIMPTable *t, Class c) {
    if (!t || !c) return;
    for (NSUInteger i = 0; i < t->count; i++) {
        if (t->items[i].cls != c) continue;
        t->items[i] = t->items[t->count - 1];
        t->count--;
        return;
    }
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

// 把节点 frame 换算到**窗口坐标**。
//
// ★ 为什么必须加（v0.3.3）：dump 里的 frame 是**相对父视图**的，而用户看到的是
// "屏幕底部有一条广告"。父坐标系里的 (0, 400, 430, 80) 到底是屏幕的哪一块，
// 得自己在脑子里把整条父链的 origin 加一遍 —— 节点一多就会算错，算错就会改错节点。
// 换成窗口坐标后，"y 接近屏幕高、宽接近屏宽、高 60~120" 这种特征一眼可辨。
static NSString *JTWindowRectString(UIView *v) {
    if (!v) return @"";
    @try {
        UIWindow *win = v.window;
        if (!win) return @" win=(无窗口)";
        CGRect r = [v convertRect:v.bounds toView:win];
        return [NSString stringWithFormat:@" win=(%.0f,%.0f,%.0f,%.0f)",
                (double)r.origin.x, (double)r.origin.y,
                (double)r.size.width, (double)r.size.height];
    } @catch (NSException *ignored) {
        return @"";
    }
}

// 判断节点是否落在 H5 里（祖先里有 WKWebView / UIWebView）。
//
// ★ 为什么要标（v0.3.3）：无忧行是原生 + H5 混合。**原生方案对 H5 内部元素完全无效** ——
// H5 里画的广告在原生视图树上只是一个 `WKContentView`，藏它等于藏整个网页。
// 所以 dump 里必须能一眼看出"这条广告在不在 H5 里"，否则会白改一版。
static BOOL JTIsInsideWebView(UIView *v) {
    @try {
        UIView *p = v;
        NSUInteger guard = 0;
        while (p && guard++ < 64) {
            NSString *cn = NSStringFromClass([p class]);
            if ([cn hasPrefix:@"WKWebView"] || [cn hasPrefix:@"WKContentView"] ||
                [cn hasPrefix:@"UIWebView"] || [cn hasPrefix:@"WKScrollView"]) {
                return YES;
            }
            p = p.superview;
        }
    } @catch (NSException *ignored) {
    }
    return NO;
}

static NSString *JTDescribeNode(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    CGRect f = v.frame;
    [s appendFormat:@"%@ (%.0f,%.0f,%.0f,%.0f)",
        NSStringFromClass([v class]),
        (double)f.origin.x, (double)f.origin.y, (double)f.size.width, (double)f.size.height];

    [s appendString:JTWindowRectString(v)];

    NSString *cn = NSStringFromClass([v class]);
    BOOL knownAd = JTClassIsKnownAdView(cn);
    BOOL suspectAd = JTClassLooksLikeAdSuspect(cn);
    if (knownAd) {
        [s appendString:@" ★★已知广告位"];
    } else if (suspectAd) {
        [s appendString:@" ★广告嫌疑"];
    }
    if (JTIsInsideWebView(v)) [s appendString:@" [H5]"];

    // 广告相关节点才补布局取证 —— 它要遍历约束，对上千个普通节点都做没有必要。
    // 这几个字段回答的是"这一格的高度是谁定的"，直接决定下一轮用哪条收起路径。
    if (knownAd || suspectAd) [s appendString:JTDescribeLayoutForView(v)];

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

// ---- 广告候选汇总（v0.3.3）----
//
// 完整 dump 动辄上千行，人眼要在里面找"屏幕底部那条广告"很容易看漏 —— 尤其表格型页面，
// 几十个 cell 的类名高度相似。所以额外做一次**定向收集**：只挑"已知广告类 / 类名可疑 /
// 横幅形态的图片视图"这三类，用窗口坐标列出来。
//
// ★ 这一段只**报告**，不做任何修改。判定由人来做 —— 关键词判定误报率高，
//   直接拿它去藏视图，就是把"猜"写进了产品行为里。
static void JTCollectAdCandidates(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                                  NSUInteger *budget, NSMutableArray<NSString *> *out) {
    if (!v || !budget || *budget == 0) return;
    if (out.count >= AD_CAND_MAX_REPORT) return;
    if (v.hidden || v.alpha < 0.02) return;
    CGRect f = v.frame;
    if (f.size.width < 1.0 || f.size.height < 1.0) return;
    (*budget)--;

    NSString *cn = NSStringFromClass([v class]);
    NSString *why = nil;
    if (JTClassIsKnownAdView(cn)) {
        why = @"已知广告位";
    } else if (JTClassLooksLikeAdSuspect(cn)) {
        why = @"类名嫌疑";
    } else if ([v isKindOfClass:[UIImageView class]]) {
        CGFloat w = f.size.width;
        CGFloat h = f.size.height;
        if (w >= AD_CAND_MIN_W && h >= AD_CAND_MIN_H) {
            CGFloat ratio = w / h;
            if (ratio >= AD_CAND_MIN_RATIO && ratio <= AD_CAND_MAX_RATIO) why = @"横幅图片形态";
        }
    }
    if (why) {
        [out addObject:[NSString stringWithFormat:@"    [%@] %@", why, JTDescribeNode(v)]];
    }

    if (depth >= maxDepth) return;
    for (UIView *sub in v.subviews) {
        if (*budget == 0) break;
        JTCollectAdCandidates(sub, depth + 1, maxDepth, budget, out);
    }
}

static NSString *JTAdCandidateSummary(UIView *root) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];

    // 第一优先：当前 VC 的视图树。
    // 为什么它优先于"遍历窗口"：`JTCurrentVC` 有 `gJTLastVC` 兜底 —— 实测存在
    // "整屏页面由 App 自己的容器呈现、从 UIApplication.windows 这条链走不到" 的情况，
    // 那种时候只有 gJTLastVC 认得出来。
    @try {
        NSUInteger budget = DUMP_MAX_NODES;
        if (root) JTCollectAdCandidates(root, 0, DUMP_MAX_DEPTH, &budget, items);
    } @catch (NSException *ignored) {
    }

    // 兜底：当前 VC 树里零命中时，把**所有可见窗口**再扫一遍。
    // 这一层是给"广告根本不在页面里"准备的 —— 比如独立浮层窗口挂的横幅。
    // 只在零命中时才扫，避免和第一遍的结果重复。
    if (items.count == 0) {
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
                if (w.hidden || w.alpha < 0.02) continue;
                NSUInteger budget = DUMP_MAX_NODES;
                JTCollectAdCandidates(w, 0, DUMP_MAX_DEPTH, &budget, items);
                if (items.count > 0) break;
            }
        } @catch (NSException *ignored) {
        }
    }

    NSMutableString *s = [NSMutableString string];
    if (items.count == 0) {
        [s appendString:@"    (零命中 —— 这条广告既不是已知广告类，也不是原生横幅图片，"
                     "也不在任何可见窗口里。优先怀疑：H5 内绘制、或直接 addSublayer: 的 CALayer)\n"];
        return s;
    }
    for (NSString *line in items) [s appendFormat:@"%@\n", line];
    if (items.count >= AD_CAND_MAX_REPORT) {
        [s appendFormat:@"    …(已到上限 %d 条，可能还有)\n", AD_CAND_MAX_REPORT];
    }
    return s;
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

    // 广告候选汇总：把"最像广告"的节点单独拎出来（带窗口坐标），方便和用户截图对照。
    @try {
        UIViewController *cur = JTCurrentVC();
        UIView *root = cur.view;
        if (!root) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
                if (w.hidden || w.alpha < 0.02) continue;
                root = w;
                break;
            }
        }
        [out appendFormat:@"--- 广告候选汇总（当前页 %@）\n",
            cur ? NSStringFromClass([cur class]) : @"(未定位)"];
        [out appendString:JTAdCandidateSummary(root)];
    } @catch (NSException *e) {
        [out appendFormat:@"(广告候选汇总异常: %@)\n", e.reason];
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
        // ★ 显隐必须打出来：v0.3 首轮就是因为没有这一项，日志里只能看到
        //   "隐藏 1 / 恢复显示 1" 这种无法判断对错的计数，得靠 x 坐标反推。
        [s appendFormat:@"      子[%lu] %@ (%.0f,%.0f,%.0f,%.0f)%@%@%@%@\n",
            (unsigned long)i, NSStringFromClass([sv class]),
            (double)sv.frame.origin.x, (double)sv.frame.origin.y,
            (double)sv.frame.size.width, (double)sv.frame.size.height,
            sv.hidden ? @" [隐]" : @" [显]",
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

// ============================== 6c. tab bar 深挖（v0.3.2） ==============================
//
// 为什么需要它：v0.3.1 之后目标 ① 已经达成 —— tab bar 的**直接子视图**里 5 个槽位装饰
// 全部 `[隐]`，保留的 2 个均分摆放。但用户仍看到"中间残留的凸起圆点上半部分"。
// 说明残留物不在直接子视图里，只剩三种可能，而直接子视图清单**一种都看不出来**：
//   ① 藏在某个容器子视图**里面**（比如 `子[1] UIView (0,0,430,89)` 里）
//   ② 是直接 `addSublayer:` 上去的 **CALayer** —— 既不在 `subviews` 里，也不受 `hidden` 影响
//   ③ 是 tab bar 的**兄弟视图**（挂在 tab bar 的父视图上，不在 tab bar 子树里）
// 所以三样一起打。★ 只在**长按 JT** 时输出 —— 它是定位用的，不该每秒跑。
static void JTDescribeSubtree(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                              NSUInteger *budget, NSMutableString *s) {
    if (!v || depth > maxDepth || !budget || *budget == 0) return;
    (*budget)--;

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    NSString *ownText = nil;
    if ([v isKindOfClass:[UILabel class]]) ownText = ((UILabel *)v).text;

    [s appendFormat:@"\n%@%@%@ (%.0f,%.0f,%.0f,%.0f) α=%.2f%@",
        indent, NSStringFromClass([v class]),
        v.hidden ? @" [隐]" : @" [显]",
        (double)v.frame.origin.x, (double)v.frame.origin.y,
        (double)v.frame.size.width, (double)v.frame.size.height,
        (double)v.alpha,
        ownText.length ? [NSString stringWithFormat:@" 文字=[%@]", ownText] : @""];

    // 非视图的 layer：视图自己的 backing layer 也会出现在父层的 sublayers 里，
    // 用 isKindOfClass:UIView 把它们排掉，剩下的就是**手工 addSublayer:** 上去的装饰 ——
    // 这类东西 `hidden` 管不到，只能靠这条日志发现。
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[UIView class]]) continue;
        [s appendFormat:@"\n%@  ⤷layer %@ (%.0f,%.0f,%.0f,%.0f) hidden=%d",
            indent, NSStringFromClass([l class]),
            (double)l.frame.origin.x, (double)l.frame.origin.y,
            (double)l.frame.size.width, (double)l.frame.size.height,
            l.hidden ? 1 : 0];
    }

    for (UIView *c in v.subviews) JTDescribeSubtree(c, depth + 1, maxDepth, budget, s);
}

static NSString *JTDescribeTabBarDeep(UITabBar *tb, NSUInteger maxDepth) {
    if (!tb) return @"(nil)\n";
    NSMutableString *s = [NSMutableString string];
    NSUInteger budget = 300;

    [s appendString:@"\n  --- tab bar 子树（含隐藏项）---"];
    JTDescribeSubtree(tb, 0, maxDepth, &budget, s);
    if (budget == 0) [s appendString:@"\n  …(节点预算用尽，已截断)"];

    // 兄弟视图：凸起装饰也可能挂在 tab bar 的父视图上（那就不在 tab bar 子树里）
    UIView *sup = tb.superview;
    if (sup) {
        [s appendFormat:@"\n  --- tab bar 的父视图 %@ 的其它子视图 ---",
            NSStringFromClass([sup class])];
        NSUInteger n = 0;
        for (UIView *sib in sup.subviews) {
            if (sib == tb) continue;
            [s appendFormat:@"\n    %@%@ (%.0f,%.0f,%.0f,%.0f)",
                NSStringFromClass([sib class]), sib.hidden ? @" [隐]" : @" [显]",
                (double)sib.frame.origin.x, (double)sib.frame.origin.y,
                (double)sib.frame.size.width, (double)sib.frame.size.height];
            n++;
            if (n > 40) {
                [s appendString:@"\n    …(更多略)"];
                break;
            }
        }
    }
    return s;
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

// ---- v0.3 ②：开屏广告 / 启动弹窗的类名判定 ----
//
// 为什么用**很窄**的词表，而不是通用广告关键词：
//   通用关键词（Ad / Banner / Popup / Activity / Market …）在真实 App 里会命中大量正常业务类，
//   而"误拦"的后果（登录弹窗、权限弹窗、协议弹窗被吃掉 → 功能直接不可用）比"漏拦"严重得多。
//   所以这里只收**几乎不可能是正常业务**的开屏/广告词，并额外加一道业务白名单兜底。
//
// 为什么只拦 presentViewController: 这一路：
//   开屏广告的另一种形态（自绘 view 直接贴在 window 上）不走 present，
//   由第 12c 节的视图树扫掠负责。两路各管一半，不重叠也不留缝。
//
// ★ 本函数只做**判定**，不做动作；判定命中的处理在 JTPresentHook 里（见那里的注释）。
static BOOL JTClassLooksLikeSplashOrPopup(NSString *cn) {
    if (cn.length == 0) return NO;

    // 业务白名单：命中任何一个词就**绝不拦**。
    static NSString * const kNever[] = {
        @"Login", @"Auth", @"Permission", @"Privacy", @"Agreement", @"Protocol",
        @"Alert", @"Toast", @"HUD", @"Keyboard", @"Picker", @"Share", @"Pay",
        @"WebView", @"Browser", @"Photo", @"Camera", @"Scan", @"Call", @"Phone",
    };
    for (unsigned i = 0; i < sizeof(kNever) / sizeof(kNever[0]); i++) {
        if ([cn rangeOfString:kNever[i]].location != NSNotFound) return NO;
    }

    // 明确的开屏 / 广告词。大小写敏感 —— 少命中几个，别多命中一个。
    static NSString * const kYes[] = {
        @"Splash", @"LaunchAd", @"LaunchAD", @"LaunchAdv", @"Advertisement",
        @"AdvertViewController", @"AdvertVC", @"AdViewController", @"AdPopup",
        @"AdDialog", @"Advertise", @"StartupAd", @"GuideAd",
    };
    for (unsigned i = 0; i < sizeof(kYes) / sizeof(kYes[0]); i++) {
        if ([cn rangeOfString:kYes[i]].location != NSNotFound) return YES;
    }
    return NO;
}

static void JTPresentHook(id self, SEL _cmd, id vcToPresent, BOOL animated,
                          __unsafe_unretained id completion) {
    IMP orig = gJTOrigPresent;
    NSString *pcn = vcToPresent ? NSStringFromClass([vcToPresent class]) : nil;
    BOOL shouldDismiss = NO;
    @try {
        // ★ 取证日志与拦截判定**分开**：前者是 `ENABLE_POPUP_FORENSICS`（纯日志，发布版可关），
        //   后者是 `ENABLE_POPUP_BLOCK`（功能）。以前两者混在一个 `#if` 下，
        //   于是"关掉取证"会顺手把目标 ② 一起关掉 —— 见配置块里那段说明。
#if ENABLE_POPUP_FORENSICS
        NSString *key = [NSString stringWithFormat:@"%@ → %@",
                         NSStringFromClass([self class]),
                         vcToPresent ? NSStringFromClass([vcToPresent class]) : @"(nil)"];
        NSArray<NSString *> *stack = nil;
        // `callStackSymbols` 要符号化，很贵 —— 只在"这一类第一次出现"时才抓（见 JTShouldCapturePresentStack）
        if (JTShouldCapturePresentStack(key)) stack = [NSThread callStackSymbols];
        JTNotePresent(key, stack);
#endif
#if ENABLE_POPUP_BLOCK
        if (pcn && JTClassLooksLikeSplashOrPopup(pcn)) shouldDismiss = YES;
#endif
    } @catch (NSException *e) {
    }
    if (orig) {
        // completion 参数用 __unsafe_unretained：ARC 不会去 retain/release 一个栈上的 block
        ((void (*)(id, SEL, id, BOOL, __unsafe_unretained id))orig)(self, _cmd, vcToPresent,
                                                                    animated, completion);
    }
#if ENABLE_POPUP_BLOCK
    if (shouldDismiss) {
        // ★ 先**真的让它弹出来**，再在下一轮 runloop 收掉 —— 而不是"不转发"。
        //   不转发的风险更大：调用方往往在 completion 里推进状态机（"弹窗已展示 → 发下一步请求"），
        //   我们把这次调用吃掉，App 的状态机就可能永久卡住。
        //   代价是可能闪一帧，换来的是 App 状态一定自洽 —— 这个交换在"不可调试的真机"上明显更划算。
        JTDiag(@"[弹窗拦截] 收掉 %@（由 %@ 弹出）", pcn, NSStringFromClass([self class]));
        // 等它把转场动画走完再收 —— 动画途中 dismiss 会触发 UIKit 的
        // "dismiss while a presentation is in progress" 警告，行为也不可预期。
        double delay = animated ? 0.40 : 0.05;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [(UIViewController *)vcToPresent dismissViewControllerAnimated:NO completion:nil];
            } @catch (NSException *e) {
            }
        });
    }
#endif
}

static void JTInstallPresentHooks(void) {
// ★ 条件必须是 **或**：`ENABLE_POPUP_BLOCK`（功能）需要这个钩子，
//   `ENABLE_POPUP_FORENSICS`（日志）也需要。只写 FORENSICS 会让"关掉日志"顺带废掉功能。
#if (ENABLE_POPUP_BLOCK || ENABLE_POPUP_FORENSICS)
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

    // v0.3：页面出现 = "可能出现新广告位"+"可能重建了 tab bar"这两个时刻的交点。
    // 两个函数都是幂等的，重复调用不会改任何东西，所以这里放心调。
    // 节流 0.5s：转场动画里一次可能连续触发多个 viewDidAppear，
    // 而这两个函数都要走视图树 —— 没必要为同一瞬间跑好几遍。
    static CFAbsoluteTime sJTNVLast = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sJTNVLast < 0.5) return;
    sJTNVLast = now;
    // ★ 再 dispatch 一跳，**不在 viewDidAppear 的调用栈里**改 tab bar。
    //   viewDidAppear 处在转场过程中，此刻调 setViewControllers: 属于在 UIKit 的转场中途
    //   改容器结构 —— 现在（只差数量时）大概率没事，但没必要赌。挪到下一轮 runloop，
    //   转场已经结束，行为可预期。
    dispatch_async(dispatch_get_main_queue(), ^{
        JTApplyTabRule(@"页面出现");
        JTSweepBlockAds(@"页面出现");
    });
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
// 规则：同一构建 token 连续 3 次启动都走到这里 → 本次不装任何钩子（调试版还会留悬浮按钮，
// 好让用户仍能长按取到崩溃报告）。
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

// ============================== 12b. tab 规则引擎（v0.3 目标 ①） ==============================
//
// 依据见文件头「v0.3 相对 v0.2 的变更」。四条实测事实决定了这里的每个设计：
//   1. 只能按 `UITabBarItem.tag` 认 tab（类名全是 BaseNavigationController，title 全空）
//   2. 移除必须**两层**：过滤 viewControllers（真实按钮）+ 按槽位处理自绘图标（视觉）
//   3. 启动期 `setViewControllers:` 发生在装钩子之前 → 必须**主动扫**，不能等钩子
//   4. 一切**幂等**：本族函数会被定时复检 / viewDidAppear / 手动按钮反复调用，
//      状态已经对了就一个字节都不改 —— 否则会和 App 自己的重排互相打架，屏幕会闪

static NSArray<NSNumber *> *JTKeepTagList(void) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:JT_KEEP_TAG_COUNT];
    for (NSUInteger i = 0; i < JT_KEEP_TAG_COUNT; i++) [a addObject:@(JTKeepTags[i])];
    return a;
}

// 返回 all 里**要移除的那些下标**（下标基于 all 的顺序）
static NSArray<NSNumber *> *JTRemovedSlotsOf(NSArray *all) {
    NSMutableArray *rm = [NSMutableArray array];
    if (![all isKindOfClass:[NSArray class]]) return rm;
    NSArray<NSNumber *> *keep = JTKeepTagList();
    NSUInteger i = 0;
    for (id o in all) {
        NSInteger tag = 0;
        if ([o isKindOfClass:[UIViewController class]]) {
            @try {
                tag = ((UIViewController *)o).tabBarItem.tag;
            } @catch (NSException *e) {
                tag = 0;
            }
        }
        if (![keep containsObject:@(tag)]) [rm addObject:@(i)];
        i++;
    }
    return rm;
}

static NSString *JTTagListOf(NSArray *vcs) {
    NSMutableArray *a = [NSMutableArray array];
    if ([vcs isKindOfClass:[NSArray class]]) {
        for (id o in vcs) {
            if ([o isKindOfClass:[UIViewController class]]) {
                NSInteger tag = 0;
                @try {
                    tag = ((UIViewController *)o).tabBarItem.tag;
                } @catch (NSException *e) {
                    tag = 0;
                }
                [a addObject:[NSString stringWithFormat:@"%ld:%@", (long)tag,
                              NSStringFromClass([o class])]];
            } else {
                [a addObject:@"<非VC>"];
            }
        }
    }
    return [a componentsJoinedByString:@" "];
}

static NSInteger JTTagIndexOf(NSArray *vcs, NSInteger tag) {
    if (![vcs isKindOfClass:[NSArray class]]) return -1;
    NSUInteger i = 0;
    for (id o in vcs) {
        NSInteger t = -1;
        if ([o isKindOfClass:[UIViewController class]]) {
            @try {
                t = ((UIViewController *)o).tabBarItem.tag;
            } @catch (NSException *e) {
                t = -1;
            }
        }
        if (t == tag) return (NSInteger)i;
        i++;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// ★★ v0.3.1 修复：自绘层必须**绑定一次**，不能每次按 x 排序现算
// ---------------------------------------------------------------------------
// 2026-09-30 v0.3 首轮真机日志里的现象：
//     [tab自绘·+0.3s]   隐藏 3 / 恢复显示 0 / 重排 2    ← 这一遍是对的
//     [tab自绘·页面出现] 隐藏 0 / 恢复显示 0 / 重排 2
//     [tab自绘·+0.8s]   隐藏 1 / 恢复显示 1 / 重排 1    ← 开始把"隐藏/显示"来回翻
//     [tab自绘·定时]     隐藏 1 / 恢复显示 1 / 重排 1
//     [tab自绘·+1.5s]   隐藏 1 / 恢复显示 1 / 重排 0
// 而 +2s 的 tab bar dump 里，三个自绘图标**挤在同一个 x=64**：
//     子[5] FLAnimatedImageView (64,0,86,51)  文字=[目的地]
//     子[6] FLAnimatedImageView (64,-8,86,59)
//     子[7] FLAnimatedImageView (64,0,86,51)  文字=[电话/消息]
//
// 根因（是**我自己的设计错**，不是 App 的）：
//   第一版用"把直接子视图按 x 排序，第 k 个 = 第 k 个槽位"来认槽位。
//   这个约定**只在原始 5 槽位布局下成立**。一旦我们按 2 槽位重排过
//   （把保留项摆到 x=64.5 / 279.5），排序结果就不再等于原始槽位顺序 ——
//   于是 removedIdx {0,1,2} 藏的是**错的那几个**；App 自己每重排一次，
//   排序结果又变一次 → 隐藏/显示来回翻，最终留下一堆叠在一起的图标。
//   **用位置去认身份，一旦自己改过位置就自毁。**
//
// 修法：**绑定一次，之后一直用绑定**。
//   · 只在"原始布局"下绑定：每个候选视图的 center.x 必须落在某个槽位中心附近，
//     且**每个槽位都有**候选（这是明确的放弃条件）
//   · 绑定结果存成 `槽位 → [视图]`，之后永远不再按 x 重新推断身份
//   · 每次使用前校验绑定视图是否还挂在 tabBar 上；掉了一个就整体解绑重绑，
//     重绑失败（布局已不是原始的）→ **放弃并记日志**，不猜
//
// 顺带修掉第二个漏网：v0.3 只收 `FLAnimatedImageView`，但 dump 显示 tab 2（流量）的
// **凸起按钮装饰是两个普通 `UIView`**（子[2] (188,-8,55,4)、子[3] (188,-8,55,55)），
// 它们是 tabBar 的**直接子视图**，不是那个 `FLAnimatedImageView` 的子视图。
// 只藏图标的话，导航栏中间会留下一个 55×55 的凸起装饰。
// → 改成"**所有按槽位摆放的直接子视图**"：排除 `UITabBarButton`（框架自己管，
//   跟着 `viewControllers` 走）、`_UI*`（私有 chrome，如 `_UIBarBackground`）、
//   以及比一个槽位宽得多的整条容器。

// 收集 tabBar 的**直接子视图**里所有"按槽位摆放的装饰"。
// 只在绑定时调用一次，所以这里的过滤可以写得严一点 —— 宁可少收，不要错收。
static NSArray<UIView *> *JTSlotDecorationCandidates(UITabBar *tb, CGFloat slotW) {
    NSMutableArray<UIView *> *a = [NSMutableArray array];
    if (!tb || slotW <= 1.0) return a;
    for (UIView *sv in tb.subviews) {
        NSString *cn = NSStringFromClass([sv class]);
        if (cn.length == 0) continue;
        if ([cn isEqualToString:@"UITabBarButton"]) continue;  // 框架管，跟 viewControllers 走
        if ([cn hasPrefix:@"_UI"]) continue;                   // 私有 chrome（_UIBarBackground 等）
        CGSize sz = sv.frame.size;
        if (sz.width < 1.0 || sz.height < 1.0) continue;       // 零尺寸
        if (sz.width > slotW * 1.6) continue;                  // 比一个槽位宽得多 → 整条容器
        [a addObject:sv];
    }
    return a;
}

// 一行描述一组视图（给日志用）：类名 + 显/隐 + 内含文字 + x
static NSString *JTDescribeSlotViews(NSArray<UIView *> *views) {
    NSMutableArray *parts = [NSMutableArray array];
    for (UIView *v in views) {
        NSMutableArray *texts = [NSMutableArray array];
        JTCollectLabels(v, 0, texts);
        NSString *t = texts.count
            ? [NSString stringWithFormat:@"(%@)", [texts componentsJoinedByString:@"/"]]
            : @"";
        [parts addObject:[NSString stringWithFormat:@"%@%@%@ x=%.0f",
                          NSStringFromClass([v class]),
                          v.hidden ? @"·隐" : @"·显",
                          t, (double)v.frame.origin.x]];
    }
    return [parts componentsJoinedByString:@" + "];
}

// 绑定是否还有效（所有绑定的视图都还挂在 tb 上）
static BOOL JTDrawnBindingAlive(UITabBar *tb) {
    if (!gJTDrawnSlots) return NO;
    for (NSArray<UIView *> *slot in gJTDrawnSlots) {
        for (UIView *v in slot) {
            if (v.superview != tb) return NO;
        }
    }
    return YES;
}

// 尝试绑定（只在原始布局下会成功）。已绑定且仍有效则直接返回 YES。
static BOOL JTBindDrawnSlots(UITabBar *tb, NSInteger totalSlots) {
    if (!tb || totalSlots <= 0) return NO;
    if (JTDrawnBindingAlive(tb)) return YES;

    gJTDrawnSlots = nil;      // 失效就整体解绑，重新来

    CGFloat W = tb.bounds.size.width;
    if (W <= 1.0) W = tb.frame.size.width;
    if (W <= 1.0) return NO;
    CGFloat slotW = W / (CGFloat)totalSlots;

    NSArray<UIView *> *cand = JTSlotDecorationCandidates(tb, slotW);
    NSMutableArray<NSMutableArray<UIView *> *> *slots = [NSMutableArray array];
    for (NSInteger i = 0; i < totalSlots; i++) [slots addObject:[NSMutableArray array]];

    NSUInteger unmatched = 0;
    for (UIView *v in cand) {
        CGFloat cx = v.center.x;
        NSInteger best = -1;
        double bestD = 1e9;
        for (NSInteger i = 0; i < totalSlots; i++) {
            double want = (double)(slotW * ((CGFloat)i + 0.5));
            double d = fabs((double)cx - want);
            if (d < bestD) { bestD = d; best = i; }
        }
        // 容差 = 0.45 个槽宽。落在两个槽位中间（比如装饰线的中点）就不认 —— 宁可不绑。
        if (best >= 0 && bestD <= (double)slotW * 0.45) {
            [slots[(NSUInteger)best] addObject:v];
        } else {
            unmatched++;
        }
    }

    // ★ 放弃条件：必须**每个槽位都有**候选。少一个就说明布局不是我们认识的那套
    //   （App 改了结构，或者我们看到的已经是自己改过之后的状态）→ 不绑、不动。
    NSUInteger covered = 0;
    for (NSMutableArray<UIView *> *s in slots) if (s.count > 0) covered++;
    if (covered < (NSUInteger)totalSlots) {
        NSString *key = [NSString stringWithFormat:@"bind%lu/%ld/u%lu",
                         (unsigned long)covered, (long)totalSlots, (unsigned long)unmatched];
        if (![gJTDrawnWarnKey isEqualToString:key]) {
            gJTDrawnWarnKey = key;
            NSMutableString *sub = [NSMutableString string];
            JTDescribeTabBarSubviews(tb, sub);
            JTDiag(@"[tab自绘] 绑定失败：只认到 %lu/%ld 个槽位（%lu 个候选落不到槽位上）"
                    "→ 本项**不做任何改动**，只记录。当前 tab bar 直接子视图：\n%@",
                   (unsigned long)covered, (long)totalSlots, (unsigned long)unmatched, sub);
        }
        return NO;
    }

    gJTDrawnSlots = [slots copy];
    gJTDrawnWarnKey = nil;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < slots.count; i++) {
        [s appendFormat:@"\n      槽%lu(%lu 个): %@", (unsigned long)i,
         (unsigned long)slots[i].count, JTDescribeSlotViews(slots[i])];
    }
    JTDiag(@"[tab自绘] 已绑定槽位（槽宽 %.1f）：%@", (double)slotW, s);
    return YES;
}

static NSString *JTDrawnSlotsStateString(void) {
    if (!gJTDrawnSlots) return @"(未绑定)";
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger slot = 0; slot < gJTDrawnSlots.count; slot++) {
        NSArray<UIView *> *slotViews = gJTDrawnSlots[slot];
        [s appendFormat:@"\n      槽%lu: %@", (unsigned long)slot,
         JTDescribeSlotViews(slotViews)];
    }
    return s;
}

// 按槽位隐藏/显示 + 把保留的槽位重排到整条宽度上。
// removedIdx 为空数组 = 全部恢复显示并重排回原始槽位（长按 T 的恢复路径）。
//
// 为什么要重排而不是只隐藏：只 hidden=YES 的话，保留的两项仍在原槽位（靠右），
// 左边空着 —— 一眼就是坏的。重排公式 (k+0.5)×W/n 与系统按钮自己的重排一致。
static void JTFixDrawnTabItems(UITabBar *tb, NSInteger totalSlots,
                               NSArray<NSNumber *> *removedIdx, NSString *reason) {
    if (!tb || totalSlots <= 0) return;
    if (!JTBindDrawnSlots(tb, totalSlots)) return;   // 绑定失败时内部已经记过日志

    CGFloat W = tb.bounds.size.width;
    if (W <= 1.0) W = tb.frame.size.width;
    if (W <= 1.0) return;

    NSMutableArray<NSNumber *> *keptSlots = [NSMutableArray array];
    NSUInteger nHide = 0, nShow = 0, nMoved = 0;
    for (NSUInteger slot = 0; slot < gJTDrawnSlots.count; slot++) {
        BOOL rm = [removedIdx containsObject:@(slot)];
        if (!rm) [keptSlots addObject:@(slot)];
        NSArray<UIView *> *slotViews = gJTDrawnSlots[slot];
        for (UIView *v in slotViews) {
            if (rm) {
                if (!v.hidden) { v.hidden = YES; nHide++; }
            } else {
                if (v.hidden) { v.hidden = NO; nShow++; }
            }
        }
    }

    NSUInteger n = keptSlots.count;
    if (n > 0) {
        CGFloat slotW = W / (CGFloat)n;
        for (NSUInteger k = 0; k < n; k++) {
            NSUInteger slot = (NSUInteger)[keptSlots[k] unsignedIntegerValue];
            CGFloat want = slotW * ((CGFloat)k + 0.5);
            NSArray<UIView *> *slotViews = gJTDrawnSlots[slot];
            for (UIView *v in slotViews) {
                CGPoint c = v.center;
                if (fabs((double)(c.x - want)) > 0.5) {
                    c.x = want;
                    v.center = c;
                    nMoved++;
                }
            }
        }
    }

    if (nHide || nShow || nMoved) {
        JTDiag(@"[tab自绘·%@] 隐藏 %lu / 恢复显示 %lu / 重排 %lu（保留 %lu 个槽位）",
               reason, (unsigned long)nHide, (unsigned long)nShow,
               (unsigned long)nMoved, (unsigned long)n);
    }

    // ★ 结果自证：把每个槽位的**最终状态**打出来，且只在状态变化时打一次。
    //   上一轮就是因为没有这一行 —— 日志里只有"隐藏 1 / 恢复显示 1"这种
    //   无法判断对错的计数，得靠 x 坐标反推，白绕了一圈。
    NSString *state = JTDrawnSlotsStateString();
    if (![gJTDrawnStateKey isEqualToString:state]) {
        gJTDrawnStateKey = state;
        JTDiag(@"[tab自绘·结果·%@] %@", reason, state);
    }
}


// 应用规则。**可重复调用**：状态已经对了就一个字节都不改。
// 调用点：启动、定时复检链、每次页面出现（节流）、悬浮按钮 T。
static void JTApplyTabRule(NSString *reason) {
#if ENABLE_TAB_RULE
    if (gJTRuleDisabled) return;
    @try {
        UITabBarController *tbc = JTFindTabBarController();
        if (!tbc) return;   // tab bar 还没建出来 —— 这是常态，不是错误，下次复检再来

        NSArray *cur = tbc.viewControllers;
        if (![cur isKindOfClass:[NSArray class]] || cur.count == 0) return;

        // ---- 第一次见到"完整的那套"时留底 ----
        // 只有"保留集是 cur 的真子集"才认为这是原始全量。不能无条件留底：
        // 复检是在我们已经改过之后跑的，那时 cur 只剩 2 个 —— 把 2 个当原始，
        // 长按恢复就永远回不来（那正是后悔药失效的最隐蔽方式）。
        if (!gJTOrigVCs) {
            NSArray<NSNumber *> *rm = JTRemovedSlotsOf(cur);
            if (rm.count == 0) {
                // ★ 安全底线一：一个都匹配不上（App 可能改了 tag）→ 整体放弃。
                //   绝不"猜一个删掉"，也绝不把 tab 清空。
                JTDiag(@"[tab规则] ★ 保留 tag {%@} 在现有 %lu 个 tab 里一个都没匹配上 → "
                        "本次**不做任何修改**（避免把 tab 清空）。现有：%@",
                       [JTKeepTagList() componentsJoinedByString:@","],
                       (unsigned long)cur.count, JTTagListOf(cur));
                return;
            }
            gJTOrigVCs = [cur copy];
            gJTOrigSel = tbc.selectedIndex;
            JTDiag(@"[tab规则] 已留底：%lu 个 tab，selectedIndex=%ld，将移除下标 {%@}。现有：%@",
                   (unsigned long)gJTOrigVCs.count, (long)gJTOrigSel,
                   [rm componentsJoinedByString:@","], JTTagListOf(gJTOrigVCs));
        }

        // ★★ 自绘层必须**在这里**绑定 —— 也就是在 `setViewControllers:` **之前**。
        //   理由：App 很可能在我们那次 `setViewControllers:` 里就把自绘图标重排成
        //   "只剩 N 个槽位"的样子（实测就是这样）。那时再按"槽位中心"去认身份，
        //   会有一堆图标叠在同一个 x 上 → 认不全 → 绑定失败 → 整项放弃。
        //   现在这一刻 tab bar 还是原始 5 槽位布局，是**唯一**可靠的绑定时机。
        JTBindDrawnSlots(tbc.tabBar, (NSInteger)gJTOrigVCs.count);

        // ---- 按**留底的原始顺序**算保留集 ----
        // 不按 cur 现算：cur 可能已经被我们改过，那样每轮算出来的结果都可能不同。
        NSArray<NSNumber *> *keep = JTKeepTagList();
        NSMutableArray<UIViewController *> *kept = [NSMutableArray array];
        for (id o in gJTOrigVCs) {
            if (![o isKindOfClass:[UIViewController class]]) continue;
            UIViewController *vc = (UIViewController *)o;
            NSInteger tag = 0;
            @try {
                tag = vc.tabBarItem.tag;
            } @catch (NSException *e) {
                tag = 0;
            }
            if ([keep containsObject:@(tag)]) [kept addObject:vc];
        }
        // ★ 安全底线二：一个都不剩，或本来就没得可移 → 什么都不做（绝不清空 tab）
        if (kept.count == 0 || kept.count >= gJTOrigVCs.count) return;

        if (cur.count != kept.count) {
            [tbc setViewControllers:kept animated:NO];
            JTDiag(@"[tab规则·%@] viewControllers %lu → %lu",
                   reason, (unsigned long)cur.count, (unsigned long)kept.count);
        }

        // ---- selectedIndex ----
        // 首次应用：把"停在被移除的那个 tab"迁到默认 tab。
        // 之后**只在越界时才碰** —— 否则每次复检都会把用户刚切到的 tab 拽回默认值
        // （这是"每次切 tab 都被弹回去"这类诡异 bug 的典型成因）。
        NSInteger want = JTTagIndexOf(kept, JT_DEFAULT_TAB_TAG);
        if (want < 0) want = 0;
        NSInteger sel = tbc.selectedIndex;
        BOOL outOfRange = (sel < 0 || sel >= (NSInteger)kept.count);
        if (!gJTRuleApplied) {
            BOOL origRemoved = NO;
            if (gJTOrigSel >= 0 && gJTOrigSel < (NSInteger)gJTOrigVCs.count) {
                UIViewController *orig = (UIViewController *)gJTOrigVCs[(NSUInteger)gJTOrigSel];
                origRemoved = ![kept containsObject:orig];
            }
            if (outOfRange || origRemoved) {
                // 只在**真的改了**的时候记一行"→"；没改就记"保持"，否则日志里会出现
                // "selectedIndex 0 → 0" 这种看起来改了其实没改的行，读日志的人会以为有问题。
                if (tbc.selectedIndex != want) {
                    tbc.selectedIndex = want;
                    JTDiag(@"[tab规则·%@] selectedIndex %ld → %ld（原选中项已被移除或越界）",
                           reason, (long)sel, (long)want);
                } else {
                    JTDiag(@"[tab规则·%@] selectedIndex 保持 %ld"
                            "（原选中项已被移除，但过滤后同一位置正好是保留项）",
                           reason, (long)want);
                }
            }
        } else if (outOfRange) {
            tbc.selectedIndex = want;
            JTDiag(@"[tab规则·%@] selectedIndex 越界（%ld）→ %ld", reason, (long)sel, (long)want);
        }

        // ---- 自绘图标（视觉层）----
        JTFixDrawnTabItems(tbc.tabBar, (NSInteger)gJTOrigVCs.count,
                           JTRemovedSlotsOf(gJTOrigVCs), reason);

        gJTRuleApplied = YES;
    } @catch (NSException *e) {
        JTDiag(@"[tab规则·%@] 异常: %@", reason, e.reason);
    }
#endif
}

// 长按 T = 后悔药：恢复原始 5 个 tab，并在**本次启动内**彻底停手。
// 为什么必须同时停手：复检链还在跑，不停手的话下一次复检会立刻把 tab 又删掉，
// 用户看到的就是"按了没反应"—— 比没有后悔药更糟。
static void JTRestoreTabs(void) {
    @try {
        gJTRuleDisabled = YES;
        UITabBarController *tbc = JTFindTabBarController();
        if (!tbc || !gJTOrigVCs) {
            JTDiag(@"[tab规则] 恢复：没有留底（规则可能从未生效），无事可做");
            return;
        }
        [tbc setViewControllers:gJTOrigVCs animated:NO];
        if (gJTOrigSel >= 0 && gJTOrigSel < (NSInteger)gJTOrigVCs.count) {
            tbc.selectedIndex = gJTOrigSel;
        }
        // 空 removedIdx = 全部恢复显示 + 重排回原始槽位
        JTFixDrawnTabItems(tbc.tabBar, (NSInteger)gJTOrigVCs.count, @[], @"手动恢复");
        gJTRuleApplied = NO;
        JTDiag(@"[tab规则] ★ 已恢复原始 %lu 个 tab，本次启动内不再应用规则"
                "（重开 App 即恢复自动应用）", (unsigned long)gJTOrigVCs.count);
    } @catch (NSException *e) {
        JTDiag(@"[tab规则] 恢复异常: %@", e.reason);
    }
}

static void JTScheduleTabRuleReapply(void) {
#if ENABLE_TAB_RULE
    // 启动期 tab bar 是**分批**建起来的（先 5 个，之后还可能按服务端配置重建），
    // 所以复检不是"等一次"，而是一条逐渐拉长的链。
    // 每次都幂等：改不动就什么都不做，所以这 10 次调用在正常情况下只有前 1~2 次有实际动作。
    static const double kOffsets[] = { 0.3, 0.8, 1.5, 2.5, 4.0, 6.0, 9.0, 13.0, 20.0, 30.0 };
    for (unsigned i = 0; i < sizeof(kOffsets) / sizeof(kOffsets[0]); i++) {
        double d = kOffsets[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JTApplyTabRule([NSString stringWithFormat:@"+%.1fs", d]);
        });
    }
#endif
}

// ============================== 12c. 广告位扫掠（v0.3 目标 ③） ==============================
//
// 机制选择：**定时扫掠窗口视图树**，而不是 hook `addSubview:`。两个理由：
//   · `addSubview:` 是热方法。为全 App 每个 UIView 加一次类名判定不值得，而且它只覆盖
//     "被加进来"的那一刻 —— 懒加载 / cell 复用 / 异步换内容都容易漏。
//   · 扫掠对"什么时候出现"完全不敏感：广告只要进了视图树，下一次扫掠就命中。
//     成本 = 每秒走一遍窗口树（限深 12、单窗口限 3000 节点），对几百个节点的树可以忽略。
//
// ★ 只清**实测确认过**的广告类，不做关键词泛匹配：
//   v0.2 dump 在首页视图树里实测到 `TripOperatingAdCell`(430×259) 与
//   `JegoSuspendedADView`(73×73 右下角悬浮)。
//   关键词泛匹配（Ad / Banner / Market …）会把正常业务视图一起误伤，而"误伤"比"漏清"
//   难查得多 —— 漏清只是少个广告，误伤是功能没了。
//   所以泛匹配**只用来记日志**（下一轮靠日志把类名补进白名单），不参与隐藏。
//
// 已知边界（不假装覆盖）：
//   · 首页被移除后，首页里那两个广告位本来就到不了了 —— 这一节真正有价值的是
//     `JegoSuspendedADView` 这类**跨页悬浮**的广告位。
//   · 扫掠只看原生视图树，管不到 H5/WKWebView 里的广告（那要走注入 CSS，另一条线）。

// 扫掠用的"可疑"判定 —— 比第 8 节的 JTClassNameInteresting **更窄**。
// 那个函数是给 addSubview: 用的（只对少数几个被加进 window 的视图做判定，可以宽松）；
// 扫掠会碰到整棵视图树的每一个类，用同一份词表会灌进大量无关类名（Launch/Alert/Float…），
// 把真正要看的广告类淹掉。词表窄一点，日志才读得动。
static BOOL JTClassLooksLikeAdSuspect(NSString *cn) {
    if (cn.length == 0) return NO;
    NSNumber *cached = nil;
    @synchronized (@"JTSuspect") {
        if (!gJTSuspectCache) gJTSuspectCache = [NSMutableDictionary dictionary];
        cached = gJTSuspectCache[cn];
    }
    if (cached) return cached.boolValue;

    static NSString * const kSuspect[] = {
        @"Advert", @"AdBanner", @"AdCell", @"AdView", @"ADView", @"Banner",
        @"Promo", @"Coupon", @"RedPacket", @"Market", @"Splash", @"Popup",
    };
    BOOL hit = NO;
    for (unsigned i = 0; i < sizeof(kSuspect) / sizeof(kSuspect[0]); i++) {
        if ([cn rangeOfString:kSuspect[i]].location != NSNotFound) {
            hit = YES;
            break;
        }
    }
    @synchronized (@"JTSuspect") {
        gJTSuspectCache[cn] = @(hit);
    }
    return hit;
}

// 某个类名是不是**实测确认**的广告视图
static BOOL JTClassIsKnownAdView(NSString *cn) {
    if (cn.length == 0) return NO;
    static NSString * const kKnown[] = {
        @"TripOperatingAdCell",     // 首页运营位广告 cell（实测 430×259）
        @"JegoSuspendedADView",     // 悬浮广告（实测 73×73，右下角）
        // ---- v0.3.4 新增（依据 = 2026-09-30 v0.3.3 真机 dump）----
        @"TBMineBannerCell",        // 「我的」页底部运营位（实测 403×155，内含 2 个 TBMineBannerItemCell：
                                    //   "邀新有礼" / "流量特惠"，各带一个 178×100 的 UIImageView）
        @"TBMineBannerItemCell",    // 上者的两个子项。父 cell 隐藏后它们本来就不可见，
                                    //   一并列入是为了"父 cell 换实现"时不至于漏掉
        @"BannerCycleView",         // 「电话/消息」页「境外出行买语音」横幅（**推断**，见下）
        @"BannerCycleViewCell",     // 上者的宿主 cell
    };
    for (unsigned i = 0; i < sizeof(kKnown) / sizeof(kKnown[0]); i++) {
        if ([cn isEqualToString:kKnown[i]]) return YES;
    }
    return NO;
}

// ★ 关于 `BannerCycleView` / `BannerCycleViewCell` 的**证据强度**（不要当成同等确定）：
//
// 前四个是**实测**：dump 的视图树里直接看到了 `TBMineBannerCell (14,785,403,155)`，
// 它的内容就是"邀新有礼 / 流量特惠"两张图 —— 与截图对得上。
//
// 后两个是**推断**，依据有两条：
//   ① `[广告清理·页面出现]` 这一行出现在**启动后第一次页面出现**时，而启动默认落到的
//      是 tag 1003 = 电话/消息（`JT_DEFAULT_TAB_TAG`）→ 那一刻窗口里只有 CallViewController，
//      所以 `BannerCycleView` / `BannerCycleViewCell` 就在**电话/消息页**上。
//   ② v0.2 dump 里 `BannerCycleView` 出现在首页头部的 `TripHomeHeadView` 里
//      → 它是 App 的**通用横幅轮播组件**，被多个页面复用。
//   而「电话/消息」页上唯一的横幅就是截图里那条"境外出行买语音 五折优惠"。
//
// 推断 ≠ 实测。所以这一条**必须靠下一轮真机 dump 复核**：
// 装完去「电话/消息」页点一下 JT，看 `BannerCycleView` 的 `win=` 坐标是不是正好落在
// 通讯工具卡片和「最近记录」之间。若不是，就把它从白名单里去掉。
// 后悔药：长按 T 会把我们隐藏过的广告**全部恢复**并停手，不用重装。

// ============================== 12c-2. 收起占位（v0.3.4） ==============================
//
// **隐藏 ≠ 去掉。** `hidden=YES` 只是不画，布局里那一格还在 ——
// 「电话/消息」页那条横幅在**页面中部**（通讯工具卡片和「最近记录」之间），
// 只隐藏会在那儿留一块空白，一眼就看得出来。
//
// 收高度有四条路，按"侵入性从小到大"依次试，**第一条成功就停**：
//   ① 视图自身有高度约束                → constant = 0
//   ② 父视图上有约束定死它的高度        → constant = 0
//   ③ cell 的 contentView 上有高度约束  → constant = 0
//   ④ 它是 cell，且类名在广告白名单里    → 给**这个类**加一份
//      `preferredLayoutAttributesFittingAttributes:` 覆写，让它把自己算成 0 高
//      （自撑高 cell 走这条路；**只有这条会真正让下面的内容往上挪**）
// 全部失败 → 如实记「会留白」，不假装成功。
//
// ★ 为什么 ④ 用「类名」认身份，而不是记 indexPath：
//   indexPath 是**位置**。用位置认身份，列表顺序一变就会改到无辜的格子 ——
//   这正是 Gotcha 25 的同一种错误（"用位置认身份，自己一改位置就自毁"）。
//   类名稳定，而且我们本来就只认这几个类。**同一个坑不踩第二次。**
//
// ★ ④ 为什么用 class_addMethod 而不是 method_setImplementation：
//   `TBMineBannerCell` **没有自己实现**这个方法，是从 `UICollectionViewCell` 继承来的；
//   继承来的 Method 属于父类，method_setImplementation 一改就波及全 App 每一个 cell。
//   所以用 class_addMethod 在**子类上新增一份**，只在子类生效；我们的实现内部直接调用
//   父类那份原始 IMP（不走 [super]，避免消息派发绕回自己）。
//
// ★ 父实现**按类各存一份**（见第 3c 节的 `JTBaseIMPTable`），不用全局单份。
static JTBaseIMPTable gJTFittingBaseTable;                 // ④：类 → 父 preferredLayoutAttributesFittingAttributes:
static NSMutableSet<NSString *> *gJTFittingLogged = nil;

static SEL JTFittingSel(void) {
    return NSSelectorFromString(@"preferredLayoutAttributesFittingAttributes:");
}

// ④ 的实现。
// ★ 日志按类去重：基础实现每次都按"内容的自然高度"回答，所以覆写生效后
//   `s.height > 0.5` **每次布局都为真** —— 不去重就会每次布局刷一行，把诊断缓冲冲掉。
static id JTPreferredFittingHook(id self, SEL _cmd, id attrs) {
    id a = attrs;
    IMP base = JTBaseIMPForOwner(self, _cmd, &gJTFittingBaseTable, (IMP)JTPreferredFittingHook);
    if (base) {
        a = ((id (*)(id, SEL, id))base)(self, _cmd, attrs);
    }
    @try {
        if ([a isKindOfClass:[UICollectionViewLayoutAttributes class]]) {
            CGSize s = [(UICollectionViewLayoutAttributes *)a size];
            if (s.height > 0.5) {
                UICollectionViewLayoutAttributes *copy =
                    (UICollectionViewLayoutAttributes *)[a copy];
                copy.size = CGSizeMake(s.width, 0.0);
                @synchronized (@"JTFitLog") {
                    if (!gJTFittingLogged) gJTFittingLogged = [NSMutableSet set];
                    NSString *key = NSStringFromClass([self class]);
                    if (![gJTFittingLogged containsObject:key] && gJTFittingLogged.count < 20) {
                        [gJTFittingLogged addObject:key];
                        JTDiag(@"[广告收起·自撑高] %@ 高度 %.0f → 0（宽 %.0f 保持）",
                               key, (double)s.height, (double)s.width);
                    }
                }
                return copy;
            }
        }
    } @catch (NSException *ignored) {
    }
    return a;
}

// 取证用：这个类在这个方法上是"继承 / 自己实现 / 我们的覆写"
static NSString *JTFittingOwnerDesc(Class c) {
    if (!c) return @"(无)";
    Method own = JTOwnMethod(c, JTFittingSel());
    if (!own) return @"继承";
    return (method_getImplementation(own) == (IMP)JTPreferredFittingHook) ? @"我们的覆写" : @"自己实现";
}

// 给广告 cell 类装上 ④ 的覆写。返回一句人话说明结果。
static NSString *JTInstallFittingOverride(Class adCell) {
#if ENABLE_AD_COLLAPSE
    if (!adCell) return @"类不存在";
    @try {
        SEL sel = JTFittingSel();
        // ★ 父实现取自 `adCell` **自己的**父类链（不是写死 `[UICollectionViewCell class]`）：
        //   万一某个类继承自一个覆写了该方法的中间类，写死父类会取到错的那份。
        Method base = JTSafeInstanceMethod(adCell, sel);
        if (!base) return @"父类链上找不到该方法";

        Method own = JTOwnMethod(adCell, sel);
        if (own) {
            if (method_getImplementation(own) == (IMP)JTPreferredFittingHook) return @"覆写已在";
            // App 自己实现了 —— **不动它**。要动就得为每个类各存一份原 IMP，
            // 而"一个 selector 挂多个类"正是 2026-09-30 栈溢出闪退的成因（第 3b 节）。
            return @"该类自己实现了该方法，跳过（不动它）";
        }
        if (!JTBaseIMPTablePut(&gJTFittingBaseTable, adCell, method_getImplementation(base))) {
            return @"父实现表已满，跳过";
        }

        if (!class_addMethod(adCell, sel, (IMP)JTPreferredFittingHook,
                             method_getTypeEncoding(base))) {
            JTBaseIMPTableRemove(&gJTFittingBaseTable, adCell);
            return @"class_addMethod 失败";
        }
        return @"已加自撑高覆写";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"覆写异常: %@", e.reason];
    }
#else
    return @"ENABLE_AD_COLLAPSE=0，跳过";
#endif
}

// 在 list 里找"把 item 的高度定死"的约束，找到就把 constant 归零，返回原值；没找到返回 0。
// 两个方向都查：约束里 item 可能是 firstItem，也可能是 secondItem。
//
// ★ `foundAlreadyZero`：找到高度约束但 constant 已经是 0 时置 YES。
//   为什么需要它 —— 不加的话"约束已是 0"和"根本没有约束"都返回 0，
//   调用方只能报"无可用高度约束"，把**已经收起过**误报成**收不了**。
//   v0.3.4 真机就踩了这个坑：定时那一轮报 `BannerCycleView → 无可用高度约束`，
//   实际是上一轮已经收到 0，只是 App 又把视图显示回来了。
static CGFloat JTZeroHeightIn(NSArray<NSLayoutConstraint *> *list, id item,
                              BOOL *foundAlreadyZero) {
    if (foundAlreadyZero) *foundAlreadyZero = NO;
    if (!list || !item) return 0.0;
    for (NSLayoutConstraint *c in list) {
        BOOL isHeight = (c.firstAttribute == NSLayoutAttributeHeight) ||
                        (c.secondAttribute == NSLayoutAttributeHeight);
        if (!isHeight) continue;
        if (c.firstItem != item && c.secondItem != item) continue;
        if (c.constant <= 0.5) {
            if (foundAlreadyZero) *foundAlreadyZero = YES;
            continue;   // 继续找 —— 同一个 item 上可能还有另一条非零的高度约束
        }
        CGFloat old = c.constant;
        c.constant = 0.0;
        return old;
    }
    return 0.0;
}

// 把"我们刚隐藏的广告"占的高度收掉。返回一句人话说明用了哪条路。
static NSString *JTCollapseAdSpace(UIView *v) {
#if ENABLE_AD_COLLAPSE
    if (!v) return @"(空)";
    @try {
        BOOL isCell = [v isKindOfClass:[UICollectionViewCell class]] ||
                      [v isKindOfClass:[UITableViewCell class]];
        CGFloat old = 0.0;
        BOOL zeroed = NO;

        old = JTZeroHeightIn(v.constraints, (id)v, &zeroed);
        if (old > 0.0) return [NSString stringWithFormat:@"①自身高度约束→0（原 %.0f）", (double)old];
        if (zeroed) return @"①自身高度约束**已是 0**（上一轮已收起，本轮只是视图被 App 重新显示）";

        UIView *sup = v.superview;
        if (sup) {
            old = JTZeroHeightIn(sup.constraints, (id)v, &zeroed);
            if (old > 0.0) return [NSString stringWithFormat:@"②父视图高度约束→0（原 %.0f）", (double)old];
            if (zeroed) return @"②父视图里指向它的高度约束**已是 0**（上一轮已收起）";
        }

        if (isCell) {
            // ★ ③ 和 ④ **并行**，不是二选一。
            //   实测（v0.3.4）：`BannerCycleViewCell` 走 ③ 把 contentView 的高度约束改成 0 之后，
            //   1.5s 自证显示高度仍是 145 —— **③"改成功"不等于"生效"**：cell 的高度是布局对象
            //   （flow layout 的 itemSize / delegate）给的，contentView 上的约束管不着。
            //   原来 ③ 命中就 return，导致 ④ 永远没机会装。现在两条都试，日志如实写两条结果。
            BOOL z3 = NO;
            id cvObj = [v valueForKey:@"contentView"];
            if ([cvObj isKindOfClass:[UIView class]]) {
                UIView *content = (UIView *)cvObj;
                old = JTZeroHeightIn(content.constraints, (id)content, &z3);
            }

            // ④ 自撑高覆写。只对 UICollectionViewCell 有意义 —— 那个方法定义在 UICollectionViewCell 上，
            //   往 UITableViewCell 子类上加一份类型编码对不上的方法是自找麻烦（虽然不会被调用）。
            //   认身份用的是**类名**，不是 indexPath —— 见本节顶部说明。
            //   注意：只有布局走自撑高（estimatedItemSize 非零）时才会被调用；
            //   不是自撑高时这条路**不会报错也不会生效**，表现为"已加覆写但仍有留白"。
            NSString *fit = [v isKindOfClass:[UICollectionViewCell class]]
                                ? JTInstallFittingOverride([v class])
                                : @"(非 collection cell，④ 不适用)";

            if (old > 0.0) {
                return [NSString stringWithFormat:@"③contentView 高度约束→0（原 %.0f）＋④%@",
                        (double)old, fit];
            }
            if (z3) return [NSString stringWithFormat:@"③contentView 高度约束**已是 0**＋④%@", fit];
            return [NSString stringWithFormat:@"③无 contentView 高度约束＋④%@", fit];
        }

        if (!v.translatesAutoresizingMaskIntoConstraints) {
            CGRect f = v.frame;
            if (f.size.height > 0.5) {
                v.frame = CGRectMake(f.origin.x, f.origin.y, f.size.width, 0.0);
                return [NSString stringWithFormat:@"frame 高度→0（原 %.0f，纯 frame 布局）", (double)f.size.height];
            }
        }
        return @"**确实没有**任何高度约束、也不是 frame 布局（未收起，会留白）";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"收起异常: %@", e.reason];
    }
#else
    return @"ENABLE_AD_COLLAPSE=0，跳过";
#endif
}

// ---- 布局取证：给 dump 用，回答"这一格的高度是谁定的" ----
//
// 为什么需要它：上面四条路里，①②③ 的前提是"有约束"，④ 的前提是"布局走自撑高"。
// 只看到"会留白"这几个字，下一轮还是不知道该往哪走；把约束、布局对象、delegate、
// 以及④那条覆写到底挂上没有一起打出来，下一轮就能直接决定用哪条路。
// **每条诊断都必须自带"下一步怎么做"。**
static NSString *JTDescribeLayoutForView(UIView *v) {
    if (!v) return @"";
    @try {
        NSMutableString *s = [NSMutableString string];
        UIView *sup = v.superview;

        NSUInteger own = 0;
        for (NSLayoutConstraint *c in v.constraints) {
            BOOL isH = (c.firstAttribute == NSLayoutAttributeHeight) ||
                       (c.secondAttribute == NSLayoutAttributeHeight);
            if (isH && (c.firstItem == (id)v || c.secondItem == (id)v)) own++;
        }
        [s appendFormat:@"\n     自身高度约束=%lu", (unsigned long)own];

        NSUInteger supH = 0;
        if (sup) {
            for (NSLayoutConstraint *c in sup.constraints) {
                BOOL isH = (c.firstAttribute == NSLayoutAttributeHeight) ||
                           (c.secondAttribute == NSLayoutAttributeHeight);
                if (isH && (c.firstItem == (id)v || c.secondItem == (id)v)) supH++;
            }
        }
        [s appendFormat:@" 父视图里指向它的高度约束=%lu", (unsigned long)supH];

        [s appendFormat:@" 约束布局=%@", v.translatesAutoresizingMaskIntoConstraints ? @"是" : @"否(frame)"];
        [s appendFormat:@" 所在容器=%@", sup ? NSStringFromClass([sup class]) : @"(无)"];
        if (sup) {
            NSString *kind = @"其它";
            if ([sup isKindOfClass:[UICollectionView class]]) kind = @"UICollectionView";
            else if ([sup isKindOfClass:[UITableView class]]) kind = @"UITableView";
            [s appendFormat:@" 容器类型=%@", kind];
        }
        // ④ 那条路的前提：这个类在 preferredLayoutAttributesFittingAttributes: 上是"继承"还是"自己实现"
        [s appendFormat:@"\n     fitting方法=%@（继承=可加覆写）", JTFittingOwnerDesc([v class])];

        BOOL isCell = [v isKindOfClass:[UICollectionViewCell class]] ||
                      [v isKindOfClass:[UITableViewCell class]];
        if (isCell) {
            UIView *p = sup;
            NSUInteger guard = 0;
            UICollectionView *cv = nil;
            while (p && guard++ < 16) {
                if ([p isKindOfClass:[UICollectionView class]]) { cv = (UICollectionView *)p; break; }
                p = p.superview;
            }
            if (cv) {
                NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)v];
                [s appendFormat:@"\n     indexPath=%@", ip ? [NSString stringWithFormat:@"%ld-%ld", (long)ip.section, (long)ip.item] : @"(不在可见格)"];

                id<UICollectionViewDelegate> d = cv.delegate;
                [s appendFormat:@" 布局对象=%@", cv.collectionViewLayout ? NSStringFromClass([cv.collectionViewLayout class]) : @"(无)"];
                [s appendFormat:@"\n     delegate=%@", d ? NSStringFromClass([d class]) : @"(无)"];
                UICollectionViewFlowLayout *fl = nil;
                if ([cv.collectionViewLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
                    fl = (UICollectionViewFlowLayout *)cv.collectionViewLayout;
                }
                if (fl) {
                    CGSize it = fl.itemSize, est = fl.estimatedItemSize;
                    [s appendFormat:@" itemSize=(%.0f,%.0f) estimatedItemSize=(%.0f,%.0f) 自撑高=%@",
                        (double)it.width, (double)it.height,
                        (double)est.width, (double)est.height,
                        (est.height > 0.5) ? @"是" : @"否"];
                } else {
                    [s appendString:@" (非 FlowLayout，④那条路大概率不适用)"];
                }
            }
        }
        return s;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"\n     (布局取证异常: %@)", e.reason];
    }
}

// ---- 自证：收起到底生效了没有 ----
//
// 为什么要这一步：`JTCollapseAdSpace` 返回的"④已加自撑高覆写"只是一句**声明** ——
// 覆写加上了不等于它被调用过（不是自撑高布局就永远不会被调用）。
// **声明不是证据。** 所以 1.5 秒后回看这个视图的实际高度：
// 归零 = 生效；还有高度 = 没生效。
//
// ★ v1.0 起这条日志的含义变了：v0.3.4 真机上它报了两次"未生效"
//   （`BannerCycleViewCell` / `TBMineBannerCell` 都还是 145/155），
//   而 v1.0 加了粘性隐藏之后**视图本身不会再露出来** ——
//   所以"收起未生效"退化成"原地留一块空白"，不再是"广告还在"。
//   留白仍在时，唯一还没试过的路是 delegate 的 `collectionView:layout:sizeForItemAtIndexPath:`。
//   （1.5s 是为了让布局至少跑完一轮；期间强引用一下这个视图，1.5 秒的持有没有影响。）
static void JTScheduleCollapseVerify(UIView *v, NSString *cn) {
    if (!v || cn.length == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            CGRect f = v.frame;
            if (f.size.height > 0.5) {
                JTDiag(@"[广告收起·自证] %@ 1.5s 后高度仍为 %.0f —— **收起未生效**"
                        "（视图已被粘性隐藏，用户看到的是这里留白，不是广告）；"
                        "剩下唯一没试过的路是 delegate 的 sizeForItemAtIndexPath:",
                       cn, (double)f.size.height);
            } else {
                JTDiag(@"[广告收起·自证] %@ 1.5s 后高度已为 0，收起生效", cn);
            }
        } @catch (NSException *ignored) {
        }
    });
}

// ---- 后悔药：把我们隐藏过的广告全部恢复，并停手 ----
// 和 tab 规则的"长按 T 恢复"是同一个思路：现场可撤销，不用重装不用重启。
// 必须同时**停手** —— 复检链还在每秒跑，不停手的话下一次扫掠会立刻又把它藏回去，
// 用户看到的是"按了没反应"。
//
// ★ 注意 ④ 那条"自撑高覆写"是**加在类上的**，没法按视图撤销。
//   所以停手之外还得把它**中和掉**：把记录过的类上的覆写恢复成父类实现。
//   做不到"删掉方法"，但可以把 IMP 换回父类那份 —— 效果一样（等价于没覆写过）。
static void JTRestoreAds(void) {
    @try {
        gJTAdRuleDisabled = YES;
        NSUInteger n = 0;
        if (gJTHiddenAdViews) {
            for (UIView *v in gJTHiddenAdViews.allObjects) {
                v.hidden = NO;
                n++;
            }
            [gJTHiddenAdViews removeAllObjects];
        }

        // 中和 ④：把广告 cell 类上的自撑高覆写换回**各自的**父类实现
        NSUInteger undone = 0;
        if (gJTFittingBaseTable.count > 0) {
            SEL sel = JTFittingSel();
            // 表在循环里**不动**，循环结束才 Reset —— 所以可以直接按下标遍历，
            // 不需要"先拷出类名再按名字回查"那一圈（那还会多一次 NSStringFromClass 分配）。
            for (NSUInteger i = 0; i < gJTFittingBaseTable.count; i++) {
                Class c = gJTFittingBaseTable.items[i].cls;
                IMP base = gJTFittingBaseTable.items[i].base;
                if (!c || !base) continue;
                Method own = JTOwnMethod(c, sel);
                if (!own) continue;
                if (method_getImplementation(own) != (IMP)JTPreferredFittingHook) continue;
                method_setImplementation(own, base);
                undone++;
            }
            JTBaseIMPTableReset(&gJTFittingBaseTable);
            [gJTFittingLogged removeAllObjects];
        }

        // 中和粘性隐藏（第 12c-3 节）：把 layoutSubviews / setHidden: 的覆写换回父类实现。
        // ★ 必须在 gJTAdRuleDisabled = YES **之后**调用 —— 两个覆写内部都会先查这个开关，
        //   开关没置位就换 IMP，会出现"换回去的瞬间又被旧覆写压回 hidden=YES"的窗口。
        NSUInteger unsticky = JTRemoveStickyHide();

        // 中和 ⑤（按 item 收高度，第 12c-4 节）：把委托类上的 size 覆写换回原实现 /
        // 把 class_addMethod 加上去的那批换成"直通版"。
        // ★ 不做这一步的话，长按 T 之后广告回来了却被布局压成 0.5pt —— 比不恢复更怪。
        NSUInteger itemUndone = JTAdItemCollapseUndo();

        JTDiag(@"[广告恢复·手动] 已恢复 %lu 个视图，撤销 %lu 个自撑高覆写、%lu 个粘性覆写、"
                "%lu 个 item 收高度覆写；本次启动内不再隐藏广告（重开 App 才恢复自动）",
               (unsigned long)n, (unsigned long)undone, (unsigned long)unsticky,
               (unsigned long)itemUndone);
    } @catch (NSException *e) {
    }
}

// ============================== 12c-3. 粘性隐藏（v1.0） ==============================
//
// **实测**（2026-09-30 v0.3.4 真机）：`BannerCycleView` 在页面出现时被隐藏，之后**又变成了 [显]**。
// 证据：日志里出现了**第二次** `[广告收起·定时] BannerCycleView → …`，
// 而收起只在"我们刚刚隐藏它"时才会被调用 → 那一刻它一定是 `hidden = NO`。
//
// 也就是说：**`hidden = YES` 不是一劳永逸的，App 会把它重新显示回来**
// （cell 复用/重建、轮播刷新、服务端下发新素材都可能）。
// 靠 1 秒一次的扫掠去追是"竞速"：追得上也难看（用户看到的仍是广告），追不上就是现在这样。
//
// 正确做法：**把规则下沉到类上**。给白名单里的类加两份覆写：
//   · `layoutSubviews` —— 每个布局周期重新断言 `hidden = YES`（兜"新建的 cell 默认不隐藏"）
//   · `setHidden:`     —— App 把它设回 NO 的**那一刻**就压回去（兜"App 显式重新显示"）
// 两条路互补，任一条装上就有粘性；两条都装不上（App 自己实现了同名方法）就**如实记日志**。
//
// 和 ④ 一样：用 `class_addMethod` 加在**子类**上（`layoutSubviews` / `setHidden:` 都是
// `UIView` 的方法，改继承来的 Method 会波及全 App 每一个视图），并直接调用父类原始 IMP。
//
// ★★ 父类 IMP 必须**按类各存一份**，不能用一个全局。
//    白名单里 4 个是 `UICollectionViewCell` 子类，它们实际继承的 `layoutSubviews`
//    **来自 `UICollectionViewCell` 而不是 `UIView`**。如果统一取 `[UIView layoutSubviews]`
//    的 IMP 去转发，就会**绕过 UICollectionViewCell 自己的布局逻辑** —— cell 会画错。
//    所以：安装时用 `JTSafeInstanceMethod(c, sel)`（沿 c 的父类链取"真正会被调用的那份"），
//    存进以**类**为键的定长表；调用时按 `self` 的实际类回查（复用第 3c 节的通用回查）。
//
// ★ 停手开关必须在**覆写内部**检查：长按 T 之后 `gJTAdRuleDisabled = YES`，
//   覆写立刻变成直通（否则"恢复"会被自己的覆写压回去 —— 用户看到的是"按了没反应"）。
//   `JTRestoreAds` 也确实是**先**置位、**后**恢复，顺序不能反。
static JTBaseIMPTable gJTStickyLayoutTable;                // 类 → 父 layoutSubviews
static JTBaseIMPTable gJTStickyHiddenTable;                // 类 → 父 setHidden:
static NSMutableSet<NSString *> *gJTStickyDone = nil;      // 已尝试过粘性隐藏的类（日志去重）

static void JTStickyLayoutSubviewsHook(id self, SEL _cmd) {
    IMP base = JTBaseIMPForOwner(self, _cmd, &gJTStickyLayoutTable, (IMP)JTStickyLayoutSubviewsHook);
    if (base) {
        ((void (*)(id, SEL))base)(self, _cmd);
    }
    if (gJTAdRuleDisabled) return;
    UIView *v = (UIView *)self;
    // 只在"确实还是显示状态"时才写 —— 否则每次布局都写一遍 hidden，
    // 有可能把父视图反复标脏（这是唯一可能引起布局循环的写法，必须挡住）。
    if (!v.hidden) v.hidden = YES;
}

static void JTStickySetHiddenHook(id self, SEL _cmd, BOOL hidden) {
    // App 设 NO 就压成 YES；设 YES 原样放行。停手时一律放行。
    if (!gJTAdRuleDisabled) hidden = YES;
    IMP base = JTBaseIMPForOwner(self, _cmd, &gJTStickyHiddenTable, (IMP)JTStickySetHiddenHook);
    if (base) {
        ((void (*)(id, SEL, BOOL))base)(self, _cmd, hidden);
    }
}

// 给一个类装粘性隐藏。返回一句人话说明结果（两个方法各自的结果）。
static NSString *JTInstallStickyHide(Class c) {
#if ENABLE_AD_STICKY
    if (!c) return @"类不存在";
    @try {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];

        // ① layoutSubviews
        // ★ 父实现取自 `c` 自己的父类链（`JTSafeInstanceMethod(c, …)`），不是 `[UIView class]`。
        //   `o1 == NULL` 时这个 Method 一定来自某个祖先，正是我们要转发的目标。
        SEL s1 = @selector(layoutSubviews);
        Method b1 = JTSafeInstanceMethod(c, s1);
        Method o1 = JTOwnMethod(c, s1);
        if (!b1) {
            [parts addObject:@"layoutSubviews:找不到父实现"];
        } else if (o1) {
            [parts addObject:(method_getImplementation(o1) == (IMP)JTStickyLayoutSubviewsHook)
                                ? @"layoutSubviews:已在" : @"layoutSubviews:App 自己实现，跳过"];
        } else {
            if (!JTBaseIMPTablePut(&gJTStickyLayoutTable, c, method_getImplementation(b1))) {
                [parts addObject:@"layoutSubviews:父实现表已满，跳过"];
            } else {
                BOOL ok = class_addMethod(c, s1, (IMP)JTStickyLayoutSubviewsHook,
                                          method_getTypeEncoding(b1));
                if (!ok) JTBaseIMPTableRemove(&gJTStickyLayoutTable, c);
                [parts addObject:ok ? @"layoutSubviews:已加" : @"layoutSubviews:addMethod 失败"];
            }
        }

        // ② setHidden:
        SEL s2 = @selector(setHidden:);
        Method b2 = JTSafeInstanceMethod(c, s2);
        Method o2 = JTOwnMethod(c, s2);
        if (!b2) {
            [parts addObject:@"setHidden:找不到父实现"];
        } else if (o2) {
            [parts addObject:(method_getImplementation(o2) == (IMP)JTStickySetHiddenHook)
                                ? @"setHidden:已在" : @"setHidden:App 自己实现，跳过"];
        } else {
            if (!JTBaseIMPTablePut(&gJTStickyHiddenTable, c, method_getImplementation(b2))) {
                [parts addObject:@"setHidden:父实现表已满，跳过"];
            } else {
                BOOL ok = class_addMethod(c, s2, (IMP)JTStickySetHiddenHook,
                                          method_getTypeEncoding(b2));
                if (!ok) JTBaseIMPTableRemove(&gJTStickyHiddenTable, c);
                [parts addObject:ok ? @"setHidden:已加" : @"setHidden:addMethod 失败"];
            }
        }

        return [parts componentsJoinedByString:@" | "];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"粘性隐藏异常: %@", e.reason];
    }
#else
    return @"ENABLE_AD_STICKY=0，跳过";
#endif
}

// 撤销粘性隐藏：把两个覆写换回**各自的**父类实现。
// （不删方法 —— 运行时不支持；换回父类 IMP 与"没覆写过"等价。）
// ★ 换回去之后还要把缓存的父实现表清掉、并把"已装类名"集合清空 ——
//   否则之后重新安装会被静默跳过（`gJTStickyDone` 里已经有这个类名了）。
static NSUInteger JTRemoveStickyHide(void) {
    NSUInteger undone = 0;
    @try {
        SEL s1 = @selector(layoutSubviews);
        SEL s2 = @selector(setHidden:);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        if (gJTStickyDone) [names addObjectsFromArray:gJTStickyDone.allObjects];
        for (NSString *n in names) {
            Class c = objc_getClass(n.UTF8String);
            if (!c) continue;

            Method m1 = JTOwnMethod(c, s1);
            IMP b1 = JTBaseIMPTableGet(&gJTStickyLayoutTable, c);
            if (m1 && b1 && method_getImplementation(m1) == (IMP)JTStickyLayoutSubviewsHook) {
                method_setImplementation(m1, b1);
                undone++;
            }
            Method m2 = JTOwnMethod(c, s2);
            IMP b2 = JTBaseIMPTableGet(&gJTStickyHiddenTable, c);
            if (m2 && b2 && method_getImplementation(m2) == (IMP)JTStickySetHiddenHook) {
                method_setImplementation(m2, b2);
                undone++;
            }
        }
        JTBaseIMPTableReset(&gJTStickyLayoutTable);
        JTBaseIMPTableReset(&gJTStickyHiddenTable);
        [gJTStickyDone removeAllObjects];   // 恢复之后允许重新安装
    } @catch (NSException *e) {
    }
    return undone;
}

// ============================== 12c-4. 按 item 收高度（v1.1） ==============================
//
// 要解决的问题（Shawn 真机反馈）：**图片没了，但原位留下一块空白。**
//
// 为什么 ①②③④ 都收不掉 —— v0.3.4 的日志已经给了答案：
//     [广告收起·页面出现] BannerCycleView     → ①自身高度约束→0（原 145）
//     [广告收起·自证]     BannerCycleView     1.5s 后高度已为 0，收起生效   ← 内容侧成功了
//     [广告收起·自证]     BannerCycleViewCell 1.5s 后高度仍为 145 —— 收起未生效
//     [广告收起·自证]     TBMineBannerCell    1.5s 后高度仍为 155 —— 收起未生效
// 内容收到 0，cell 还是 145 → **cell 的高度不是内容给的，是布局给的**。
//   · ①②③ 改的都是"内容的高度约束"，管不到布局；
//   · ④（`preferredLayoutAttributesFittingAttributes:`）**只在自撑高模式下才会被调用** ——
//     固定尺寸模式下布局根本不问 cell，装了也是死的（"声明不是证据"的又一例）。
//
// 真正能重排的路只有一条：**影响 `prepareLayout` 的输入** —— 也就是让布局在算这一格的
// 尺寸时拿到一个小值。这个"输入"在两个容器上各有各的 API：
//   · `UICollectionView` → delegate 的 `collectionView:layout:sizeForItemAtIndexPath:`
//   · `UITableView`      → dataSource 的 `tableView:heightForRowAtIndexPath:`
// 两条路**同构**（改的都是"布局要的那个尺寸"，都会连带把后面所有格子的起点往前挪），
// 所以下面两份实现几乎是照抄的，只是 API 名不同。两份各有独立开关（同一个宏），
// 出问题能一起关掉。
//
// ★★ 为什么返回 0.5pt 而不是 0：
//   高度 0 的 item 在 `layoutAttributesForElementsInRect:` 里是**空矩形**，
//   `CGRectIntersectsRect` 对空矩形返回 NO → 这个 item 不进可见集 → cell 被回收 →
//   `cellForItemAtIndexPath:` 返回 nil → **我们就认不出它了**（识别依赖那个 cell 的类名）
//   → 下一轮布局又给回 145 → 0/145 来回抖，屏幕上看就是闪。
//   0.5pt 是非空矩形，cell 会一直存在，识别稳定；肉眼不可见。
//
// ★★ 身份怎么认 —— "记下 indexPath" 在这里**不违反** Gotcha 25：
//   Gotcha 25 说的是"**靠位置推断身份**会自毁"。这里不是靠位置推断，而是**记录来自真实 cell**：
//   扫掠时我们手里正拿着那个 cell，问它自己的类名、问它自己在哪个 indexPath，把这个二元组记下来。
//   布局跑的时候（`prepareLayout` 阶段 cell 可能还没建、也可能已滚出可见区）
//   `cellForItemAtIndexPath:` 往往返回 nil —— 那就查这份记录。
//   而且**永远优先信实时 cell**：只要拿得到 cell 就用它；实时答案说"这里不是广告"时
//   还会**顺手把记录删掉**（自愈）。→ 位置变了最多 1 秒（下一次扫掠）就纠正过来，
//   而且我们从不"猜"任何位置。**同一个坑不踩第三次。**
//
// ★ 加钩子前的**自证门槛**：只有当"布局确实按固定尺寸定高"时才敢加。
//   拿 cell 的实际尺寸和布局声明的尺寸（`fl.itemSize` / `tv.rowHeight`）比一比，
//   对不上说明高度另有来源（自定义布局 / 自撑高 / 别处实现），这时加钩子会**改变整个列表
//   的布局行为** —— 宁可不修，也不冒险。（委托/数据源自己实现了该方法的情形例外：
//   那是"换掉并转发"，不改变语义。）

#define JT_AD_ITEM_MIN_SIZE  0.5

// ---------- 共用：容器定位 / 身份记录 / 布局重跑节流 ----------

// 从 cell 往上找就近的**列表容器**：UICollectionView 或 UITableView。
// 为什么从 superview 开始走：cell 自己不是容器，父链上才有。
// 为什么"就近"：`TBMineBannerItemCell` 那种嵌在横幅里的小轮播，就近找到的是**内层**容器 ——
// 正是我们要收的那一个；一路走到最外层会收错容器。
static BOOL JTNearestListContainer(UIView *v, UICollectionView **outCV, UITableView **outTV) {
    if (outCV) *outCV = nil;
    if (outTV) *outTV = nil;
    UIView *p = v ? v.superview : nil;
    NSUInteger guard = 0;
    while (p && guard++ < 32) {
        if ([p isKindOfClass:[UICollectionView class]]) {
            if (outCV) *outCV = (UICollectionView *)p;
            return YES;
        }
        if ([p isKindOfClass:[UITableView class]]) {
            if (outTV) *outTV = (UITableView *)p;
            return YES;
        }
        p = p.superview;
    }
    return NO;
}

// 容器 → { 广告所在的 indexPath }。弱键：容器本来就在层级里，我们不该成为它的唯一持有者。
static NSMapTable<UIScrollView *, NSMutableSet<NSIndexPath *> *> *gJTAdItemIndexes = nil;

static NSMutableSet<NSIndexPath *> *JTAdIndexSet(UIScrollView *sv, BOOL create) {
    if (!sv) return nil;
    if (!gJTAdItemIndexes) {
        if (!create) return nil;
        gJTAdItemIndexes = [NSMapTable weakToStrongObjectsMapTable];
    }
    NSMutableSet *s = [gJTAdItemIndexes objectForKey:sv];
    if (!s && create) {
        s = [NSMutableSet set];
        [gJTAdItemIndexes setObject:s forKey:sv];
    }
    return s;
}

// ★ 下面三个都有"无锁快速路径"：`gJTAdItemIndexes` 只被赋值一次、指向的对象永不释放，
//   所以裸读它是安全的。为什么要加：`JTIsAdItemAt` 是**每个 item、每次布局**都要走一遍的，
//   而绝大多数 item 都不是广告 —— 为了它们每个都去抢一次 `@synchronized` 不值得。
static void JTRecordAdIndex(UIScrollView *sv, NSIndexPath *ip) {
    if (!sv || !ip) return;
    @synchronized (@"JTAdItemIdx") {
        NSMutableSet *s = JTAdIndexSet(sv, YES);
        if (s && s.count < 64) [s addObject:ip];   // 上限：宁可少记，也不要无限增长
    }
}

static void JTUnrecordAdIndex(UIScrollView *sv, NSIndexPath *ip) {
    if (!sv || !ip) return;
    if (!gJTAdItemIndexes) return;                 // 无锁快速路径：一张记录都没有
    @synchronized (@"JTAdItemIdx") {
        NSMutableSet *s = JTAdIndexSet(sv, NO);
        if (s) [s removeObject:ip];
    }
}

static BOOL JTIsRecordedAdIndex(UIScrollView *sv, NSIndexPath *ip) {
    if (!sv || !ip) return NO;
    if (!gJTAdItemIndexes) return NO;              // 无锁快速路径
    @synchronized (@"JTAdItemIdx") {
        NSMutableSet *s = JTAdIndexSet(sv, NO);
        return s ? [s containsObject:ip] : NO;
    }
}

// 某个位置上的 cell（cv / tv 各一套 API，包一层省得每处都写两遍）
static UIView *JTListCellAt(UIScrollView *sv, NSIndexPath *ip) {
    @try {
        if ([sv isKindOfClass:[UICollectionView class]]) {
            return [(UICollectionView *)sv cellForItemAtIndexPath:ip];
        }
        if ([sv isKindOfClass:[UITableView class]]) {
            return [(UITableView *)sv cellForRowAtIndexPath:ip];
        }
    } @catch (NSException *ignored) {
    }
    return nil;
}

// ★ 认身份的唯一入口。**实时 cell 优先**，记录兜底，且实时答案说"不是"时顺手清记录（自愈）。
static BOOL JTIsAdItemAt(UIScrollView *sv, NSIndexPath *ip) {
    if (!sv || !ip) return NO;
    UIView *c = JTListCellAt(sv, ip);
    if (c) {
        BOOL isAd = JTClassIsKnownAdView(NSStringFromClass([c class]));
        if (!isAd) JTUnrecordAdIndex(sv, ip);   // 那个位置已经不是广告了 → 记录作废
        return isAd;
    }
    // 布局阶段拿不到 cell 是**常态**（prepareLayout 时 cell 可能还没建 / 已滚出可见区）
    return JTIsRecordedAdIndex(sv, ip);
}

// 让布局重跑一次。**必须节流**：我们自己也在动布局（隐藏 cell），
// 不节流会出现"invalidate → 布局 → 我们又 invalidate"的抖动。
static void JTInvalidateListOnce(UIScrollView *sv) {
    if (!sv) return;
    @synchronized (@"JTAdInvalidate") {
        if (!gJTAdInvalidateLog) gJTAdInvalidateLog = [NSMapTable weakToStrongObjectsMapTable];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *prev = [gJTAdInvalidateLog objectForKey:sv];
        if (prev && (now - prev.doubleValue) < 0.5) return;   // 同一个容器 0.5s 内只来一次
        if (gJTAdInvalidateTotal >= 20) return;               // 全局总量上限
        [gJTAdInvalidateLog setObject:@(now) forKey:sv];
        gJTAdInvalidateTotal++;
    }
    @try {
        if ([sv isKindOfClass:[UICollectionView class]]) {
            [((UICollectionView *)sv).collectionViewLayout invalidateLayout];
        } else if ([sv isKindOfClass:[UITableView class]]) {
            // 表格没有 invalidateLayout；beginUpdates/endUpdates 会强制重新问一遍行高。
            UITableView *t = (UITableView *)sv;
            [t beginUpdates];
            [t endUpdates];
        }
    } @catch (NSException *ignored) {
    }
}

// 布局层尺寸钩子被**真正调用**的次数。
// ★ 这是"钩子装上了"（声明）和"钩子被问了"（证据）之间的那条证据 —— 必须打出来。
static NSUInteger gJTAdSizeHookCalls = 0;
static NSUInteger gJTAdRowHookCalls  = 0;

// ⑤ 的自证（定义在后，先声明）
static void JTScheduleItemCollapseVerify(UIScrollView *sv, UIView *cell);

// ---------- collection view 那条路 ----------

// 委托类 → 原 `collectionView:layout:sizeForItemAtIndexPath:` 实现（仅"委托自己实现"的情形）
static JTBaseIMPTable             gJTAdSizeBaseTable;
static NSMutableSet<NSString *>  *gJTAdSizeHookDone = nil;   // 已处理过的委托类（只装一次 + 日志去重）
static Class                      gJTAdSizeNoBaseCls[8];     // 我们 class_addMethod 装上去的委托类
static NSUInteger                 gJTAdSizeNoBaseCount = 0;

static BOOL JTAdSizeHasNoBase(Class c) {
    if (!c) return NO;
    for (NSUInteger i = 0; i < gJTAdSizeNoBaseCount; i++) {
        if (gJTAdSizeNoBaseCls[i] == c) return YES;
    }
    return NO;
}

// 撤销时换上的直通版：永远返回 `layout.itemSize`（= 布局原本的行为），不再收任何尺寸。
// 为什么不删方法：运行时不支持删。换成直通版与"没插过手"等价。
// 非 FlowLayout 的情形不会出现 —— 安装前的门槛就要求必须是 FlowLayout（见 JTInstallAdSizeHook）。
static CGSize JTAdSizePassThrough(id self, SEL _cmd, UICollectionView *cv,
                                  UICollectionViewLayout *layout, NSIndexPath *ip) {
    (void)self; (void)_cmd; (void)cv; (void)ip;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        return ((UICollectionViewFlowLayout *)layout).itemSize;
    }
    return CGSizeZero;
}

// ⑤ 的实现体。签名必须和 `-collectionView:layout:sizeForItemAtIndexPath:` 完全一致。
static CGSize JTAdSizeHook(id self, SEL _cmd, UICollectionView *cv,
                           UICollectionViewLayout *layout, NSIndexPath *ip) {
    gJTAdSizeHookCalls++;

    // ---- 先算出"原本的尺寸" ----
    CGSize sz = CGSizeZero;
    BOOL have = NO;

    IMP base = JTBaseIMPForOwner(self, _cmd, &gJTAdSizeBaseTable, (IMP)JTAdSizeHook);
    if (base) {
        // 委托（或它的某个祖先）本来就实现了这个方法 → 转发给那一份
        sz = ((CGSize (*)(id, SEL, id, id, id))base)(self, _cmd, cv, layout, ip);
        have = YES;
    } else if (JTAdSizeHasNoBase(object_getClass(self))) {
        // 是我们 class_addMethod 加上去的 → 布局原本会用 layout.itemSize
        if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
            sz = ((UICollectionViewFlowLayout *)layout).itemSize;
            have = YES;
        }
    }
    if (!have) return CGSizeZero;      // 拿不准就什么都不改（宁可留白，不可乱改布局）
    if (gJTAdRuleDisabled) return sz;  // 长按 T 之后一律放行
    if (!JTIsAdItemAt(cv, ip)) return sz;

    BOOL horizontal = NO;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        horizontal = (((UICollectionViewFlowLayout *)layout).scrollDirection
                      == UICollectionViewScrollDirectionHorizontal);
    }
    return horizontal ? CGSizeMake(JT_AD_ITEM_MIN_SIZE, sz.height)
                      : CGSizeMake(sz.width, JT_AD_ITEM_MIN_SIZE);
}

// 给 cv 的 delegate 装上/换掉 size 钩子。返回一句人话说明结果。
static NSString *JTInstallAdSizeHook(UICollectionView *cv, UIView *cell, BOOL *installed) {
#if ENABLE_AD_ITEM_COLLAPSE
    if (installed) *installed = NO;
    if (!cv) return @"不在 collection view 里，不适用";
    @try {
        UICollectionViewLayout *lay = cv.collectionViewLayout;
        if (![lay isKindOfClass:[UICollectionViewFlowLayout class]]) {
            return [NSString stringWithFormat:@"布局是 %@（非 FlowLayout）→ size 方法不会被问，不适用",
                    lay ? NSStringFromClass([lay class]) : @"(无)"];
        }
        UICollectionViewFlowLayout *fl = (UICollectionViewFlowLayout *)lay;
        if (fl.estimatedItemSize.width > 0.5 || fl.estimatedItemSize.height > 0.5) {
            return @"自撑高布局（estimatedItemSize 非零）→ 由 ④ 负责，这里跳过";
        }

        id delegate = cv.delegate;
        if (!delegate) return @"无 delegate，不适用";
        Class dcls = object_getClass(delegate);
        NSString *dname = NSStringFromClass(dcls);

        @synchronized (@"JTAdSize") {
            if (!gJTAdSizeHookDone) gJTAdSizeHookDone = [NSMutableSet set];
            if ([gJTAdSizeHookDone containsObject:dname]) {
                if (installed) *installed = YES;
                return [NSString stringWithFormat:@"%@ 已装过", dname];
            }
        }

        SEL sel = @selector(collectionView:layout:sizeForItemAtIndexPath:);
        Method own = JTOwnMethod(dcls, sel);

        if (own) {
            // 委托**自己实现**了 → 换掉，原实现按类存一份（不改变语义，只是插一层）
            if (method_getImplementation(own) == (IMP)JTAdSizeHook) {
                if (installed) *installed = YES;
                return [NSString stringWithFormat:@"%@ 已是我们的实现", dname];
            }
            if (!JTBaseIMPTablePut(&gJTAdSizeBaseTable, dcls, method_getImplementation(own))) {
                return @"父实现表已满，跳过";
            }
            method_setImplementation(own, (IMP)JTAdSizeHook);
            @synchronized (@"JTAdSize") { [gJTAdSizeHookDone addObject:dname]; }
            if (installed) *installed = YES;
            return [NSString stringWithFormat:@"换掉 %@ 自己的实现（转发给原实现）", dname];
        }

        // 委托**没有**实现 → 只能 class_addMethod 加上去。
        // ★★ 但加之前必须自证"布局确实是按 itemSize 定高的"：拿 cell 的实际尺寸和 itemSize 比。
        //    对不上说明高度另有来源（自定义布局子类 / 别处实现），这时加钩子会**改变整个
        //    collection view 的布局行为** —— 宁可不修，也不冒险。
        if (!cell) return @"拿不到 cell，无法自证，跳过";
        BOOL horizontal = (fl.scrollDirection == UICollectionViewScrollDirectionHorizontal);
        CGFloat want = horizontal ? fl.itemSize.width  : fl.itemSize.height;
        CGFloat got  = horizontal ? cell.frame.size.width : cell.frame.size.height;
        if (want <= 0.5 || fabs(got - want) > 1.0) {
            return [NSString stringWithFormat:
                    @"**不敢加**：cell 尺寸 %.0f ≠ itemSize %.0f（方向=%@）→ 高度另有来源",
                    (double)got, (double)want, horizontal ? @"横" : @"纵"];
        }

        // 类型编码：返回值是结构体，三个参数都是对象。
        // 用 @encode(CGSize) 而不是写死 "{CGSize=dd}" —— arm64 上是 dd，但不写死更稳。
        char enc[64];
        snprintf(enc, sizeof(enc), "%s@:@@@", @encode(CGSize));
        if (!class_addMethod(dcls, sel, (IMP)JTAdSizeHook, enc)) {
            return [NSString stringWithFormat:@"class_addMethod 失败（%@）", dname];
        }
        if (gJTAdSizeNoBaseCount < 8) gJTAdSizeNoBaseCls[gJTAdSizeNoBaseCount++] = dcls;
        @synchronized (@"JTAdSize") { [gJTAdSizeHookDone addObject:dname]; }
        if (installed) *installed = YES;
        return [NSString stringWithFormat:@"给 %@ 加上（未实现过，默认取 itemSize=%.0f）",
                dname, (double)want];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"异常: %@", e.reason];
    }
#else
    if (installed) *installed = NO;
    return @"ENABLE_AD_ITEM_COLLAPSE=0，跳过";
#endif
}

// ---------- table view 那条路（与 cv 同构，只是 API 不同） ----------

static JTBaseIMPTable             gJTRowHBaseTable;
static NSMutableSet<NSString *>  *gJTRowHookDone = nil;
static Class                      gJTRowNoBaseCls[8];
static NSUInteger                 gJTRowNoBaseCount = 0;

static BOOL JTRowHasNoBase(Class c) {
    if (!c) return NO;
    for (NSUInteger i = 0; i < gJTRowNoBaseCount; i++) {
        if (gJTRowNoBaseCls[i] == c) return YES;
    }
    return NO;
}

// 直通版：永远返回 `tv.rowHeight`（= 表格原本的行为）。
static CGFloat JTRowHeightPassThrough(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    (void)self; (void)_cmd; (void)ip;
    return tv ? tv.rowHeight : 0.0;
}

static CGFloat JTRowHeightHook(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    gJTAdRowHookCalls++;

    CGFloat h = 0.0;
    BOOL have = NO;

    IMP base = JTBaseIMPForOwner(self, _cmd, &gJTRowHBaseTable, (IMP)JTRowHeightHook);
    if (base) {
        h = ((CGFloat (*)(id, SEL, id, id))base)(self, _cmd, tv, ip);
        have = YES;
    } else if (JTRowHasNoBase(object_getClass(self))) {
        h = tv ? tv.rowHeight : 0.0;
        have = YES;
    }
    if (!have) return 0.0;
    if (gJTAdRuleDisabled) return h;
    if (!JTIsAdItemAt(tv, ip)) return h;
    return JT_AD_ITEM_MIN_SIZE;
}

// ★ 装在哪一个对象上 —— 不赌 API 归属：
//   `tableView:heightForRowAtIndexPath:` 是 **UITableViewDelegate** 的方法（UIKit 问的是 delegate），
//   但真机上「谁是 delegate / 谁是 dataSource」常有意外（有人只设 dataSource，有人两者都是同一个 VC）。
//   所以按这个顺序选目标：**谁已经实现了就换谁** → 都没有就加在 delegate 上（delegate 为空才退回 dataSource）。
//   这样不管 UIKit 实际问的是哪一个，都能命中；代价最多是给没被问的那个对象加一个无害的方法。
static id JTRowHookTarget(UITableView *tv, SEL sel, Method *outOwn) {
    if (outOwn) *outOwn = NULL;
    id dg = tv.delegate;
    id ds = tv.dataSource;
    Method m = dg ? JTOwnMethod(object_getClass(dg), sel) : NULL;
    if (m) { if (outOwn) *outOwn = m; return dg; }
    m = ds ? JTOwnMethod(object_getClass(ds), sel) : NULL;
    if (m) { if (outOwn) *outOwn = m; return ds; }
    return dg ? dg : ds;
}

static NSString *JTInstallRowHeightHook(UITableView *tv, UIView *cell, BOOL *installed) {
#if ENABLE_AD_ITEM_COLLAPSE
    if (installed) *installed = NO;
    if (!tv) return @"不在 table view 里，不适用";
    @try {
        // 自撑高表格：行高由 cell 自己的约束决定 → ①②③ 就够，这里不该插手
        if (tv.estimatedRowHeight > 0.5) {
            return @"自撑高表格（estimatedRowHeight 非零）→ 由 ①②③ 负责，这里跳过";
        }
        if (tv.rowHeight <= 0.5) {
            // UITableViewAutomaticDimension 是 -1：行高不是固定值 → 高度另有来源
            return [NSString stringWithFormat:@"行高不是固定值（rowHeight=%.0f）→ 高度另有来源，跳过",
                    (double)tv.rowHeight];
        }

        SEL sel = @selector(tableView:heightForRowAtIndexPath:);
        Method own = NULL;
        id target = JTRowHookTarget(tv, sel, &own);
        if (!target) return @"既无 delegate 也无 dataSource，不适用";
        Class dcls = object_getClass(target);
        NSString *dname = NSStringFromClass(dcls);

        @synchronized (@"JTAdRow") {
            if (!gJTRowHookDone) gJTRowHookDone = [NSMutableSet set];
            if ([gJTRowHookDone containsObject:dname]) {
                if (installed) *installed = YES;
                return [NSString stringWithFormat:@"%@ 已装过", dname];
            }
        }

        if (own) {
            if (method_getImplementation(own) == (IMP)JTRowHeightHook) {
                if (installed) *installed = YES;
                return [NSString stringWithFormat:@"%@ 已是我们的实现", dname];
            }
            if (!JTBaseIMPTablePut(&gJTRowHBaseTable, dcls, method_getImplementation(own))) {
                return @"父实现表已满，跳过";
            }
            method_setImplementation(own, (IMP)JTRowHeightHook);
            @synchronized (@"JTAdRow") { [gJTRowHookDone addObject:dname]; }
            if (installed) *installed = YES;
            return [NSString stringWithFormat:@"换掉 %@ 自己的行高实现（转发给原实现）", dname];
        }

        // 目标没实现 → 加之前同样要自证"行高确实由 rowHeight 决定"
        if (!cell) return @"拿不到 cell，无法自证，跳过";
        CGFloat want = tv.rowHeight;
        CGFloat got  = cell.frame.size.height;
        if (fabs(got - want) > 1.0) {
            return [NSString stringWithFormat:
                    @"**不敢加**：cell 高 %.0f ≠ rowHeight %.0f → 高度另有来源",
                    (double)got, (double)want];
        }

        char enc[32];
        snprintf(enc, sizeof(enc), "%s@:@@", @encode(CGFloat));
        // ↑ 编码格式 = "<返回类型> @: <参数…>"。这里返回 CGFloat（arm64 上 @encode 是 "d"），
        //   参数是 tv 和 ip 两个对象 → "d@:@@"。
        //   ★ cv 那条路是三个参数（cv、layout、ip）→ "%s@:@@@"。两边差一个 @，写错会静默装不上。
        if (!class_addMethod(dcls, sel, (IMP)JTRowHeightHook, enc)) {
            return [NSString stringWithFormat:@"class_addMethod 失败（%@）", dname];
        }
        if (gJTRowNoBaseCount < 8) gJTRowNoBaseCls[gJTRowNoBaseCount++] = dcls;
        @synchronized (@"JTAdRow") { [gJTRowHookDone addObject:dname]; }
        if (installed) *installed = YES;
        return [NSString stringWithFormat:@"给 %@ 加上（未实现过，默认取 rowHeight=%.0f）",
                dname, (double)want];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"异常: %@", e.reason];
    }
#else
    if (installed) *installed = NO;
    return @"ENABLE_AD_ITEM_COLLAPSE=0，跳过";
#endif
}

// ---------- ⑤ 的入口 ----------

// 从 v 往上找**它所在的列表 cell**（v 自己就可能已经是 cell）。
// 为什么需要：白名单里既有 cell（`TBMineBannerCell` / `BannerCycleViewCell`）也有
// cell **内部**的横幅（`BannerCycleView`）。扫掠是逐个视图走的，撞到内部横幅时
// 拿到的不是 cell —— 而布局只认 cell 的位置，所以必须先归一化到 cell。
static UIView *JTEnclosingListCell(UIView *v) {
    UIView *p = v;
    NSUInteger guard = 0;
    while (p && guard++ < 32) {
        if ([p isKindOfClass:[UICollectionViewCell class]]) return p;
        if ([p isKindOfClass:[UITableViewCell class]]) return p;
        p = p.superview;
    }
    return nil;
}

// 只处理列表 cell（cv / tv 各一条路）。返回 nil = 这一节不适用。
static NSString *JTAdItemCollapse(UIView *v) {
    if (!v) return nil;
    UIView *cell = JTEnclosingListCell(v);
    if (!cell) return @"不在列表 cell 里，不适用";
    UICollectionView *cv = nil;
    UITableView *tv = nil;
    if (!JTNearestListContainer(cell, &cv, &tv)) return @"列表 cell 不在容器里，不适用";

    // ★ 先把"这个位置是广告"记下来 —— 布局跑的时候不一定拿得到 cell，
    //   钩子需要这份来自**真实 cell** 的权威答案兜底（见本节开头关于 Gotcha 25 的说明）。
    if (cv) {
        JTRecordAdIndex(cv, [cv indexPathForCell:(UICollectionViewCell *)cell]);
        BOOL installed = NO;
        NSString *r = JTInstallAdSizeHook(cv, cell, &installed);
        if (installed) {
            JTInvalidateListOnce(cv);
            JTScheduleItemCollapseVerify(cv, cell);
        }
        return r;
    }
    JTRecordAdIndex(tv, [tv indexPathForCell:(UITableViewCell *)cell]);
    BOOL installed = NO;
    NSString *r = JTInstallRowHeightHook(tv, cell, &installed);
    if (installed) {
        JTInvalidateListOnce(tv);
        JTScheduleItemCollapseVerify(tv, cell);
    }
    return r;
}

// ⑤ 的自证：布局重跑之后，这一格真的矮了吗？和下一格之间还剩多少空白？
// **声明不是证据** —— "钩子装上了"不等于"item 收掉了"。1.5s 后回看**布局的实际几何**
// （cv 用 `layoutAttributesForItemAtIndexPath:`，tv 用 `rectForRowAtIndexPath:`；
//  两者都是内容坐标系，且对不可见的格也有效）。
static void JTScheduleItemCollapseVerify(UIScrollView *sv, UIView *cell) {
    if (!sv || !cell) return;
    __weak UIScrollView *weakSV = sv;
    NSString *cn = NSStringFromClass([cell class]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIScrollView *s = weakSV;
            if (!s) return;
            BOOL isCV = [s isKindOfClass:[UICollectionView class]];

            NSIndexPath *ip = nil;
            if (isCV) ip = [(UICollectionView *)s indexPathForCell:(UICollectionViewCell *)cell];
            else      ip = [(UITableView *)s indexPathForCell:(UITableViewCell *)cell];
            if (!ip) {
                JTDiag(@"[广告item·自证] %@ 已不在可见格，无法回看（布局多半已重排）", cn);
                return;
            }

            CGFloat now = 0.0;
            CGFloat gap = -1.0;
            BOOL horizontal = NO;

            if (isCV) {
                UICollectionViewLayout *lay = ((UICollectionView *)s).collectionViewLayout;
                UICollectionViewLayoutAttributes *a = [lay layoutAttributesForItemAtIndexPath:ip];
                if (!a) {
                    JTDiag(@"[广告item·自证] %@ 拿不到布局属性，无法回看", cn);
                    return;
                }
                if ([lay isKindOfClass:[UICollectionViewFlowLayout class]]) {
                    horizontal = (((UICollectionViewFlowLayout *)lay).scrollDirection
                                  == UICollectionViewScrollDirectionHorizontal);
                }
                now = horizontal ? a.frame.size.width : a.frame.size.height;
                NSIndexPath *nx = [NSIndexPath indexPathForItem:(ip.item + 1) inSection:ip.section];
                UICollectionViewLayoutAttributes *b = [lay layoutAttributesForItemAtIndexPath:nx];
                if (b) {
                    gap = horizontal ? (b.frame.origin.x - CGRectGetMaxX(a.frame))
                                     : (b.frame.origin.y - CGRectGetMaxY(a.frame));
                }
            } else {
                UITableView *t = (UITableView *)s;
                CGRect r1 = [t rectForRowAtIndexPath:ip];
                now = r1.size.height;
                NSInteger rows = [t numberOfRowsInSection:ip.section];
                if (ip.row + 1 < rows) {
                    NSIndexPath *nx = [NSIndexPath indexPathForRow:(ip.row + 1) inSection:ip.section];
                    CGRect r2 = [t rectForRowAtIndexPath:nx];
                    gap = r2.origin.y - CGRectGetMaxY(r1);
                }
            }

            NSString *calls = [NSString stringWithFormat:@"size 钩子共被调用 %lu 次、行高钩子 %lu 次",
                               (unsigned long)gJTAdSizeHookCalls, (unsigned long)gJTAdRowHookCalls];
            if (now <= 1.0 && gap >= 0.0 && gap <= 1.0) {
                JTDiag(@"[广告item·自证] %@ 布局层已收起：%.1fpt、与下一格间距 %.1fpt ✅（%@）",
                       cn, (double)now, (double)gap, calls);
            } else if (now <= 1.0) {
                JTDiag(@"[广告item·自证] %@ 已收到 %.1fpt，但**与下一格还有 %.1fpt 空白**"
                        "（多半是 section inset / 行间距占的，下一步收这个；%@）",
                       cn, (double)now, (double)gap, calls);
            } else {
                JTDiag(@"[广告item·自证] %@ 仍是 %.0fpt —— **布局层没收到**"
                        "（%@；没被问 = 钩子没生效，被问了还这样 = 高度另有来源。把本行发我）",
                       cn, (double)now, calls);
            }
        } @catch (NSException *ignored) {
        }
    });
}

// ⑤ 的后悔药：把两类覆写都换回原实现。返回撤销条数。
static NSUInteger JTAdItemCollapseUndo(void) {
    NSUInteger undone = 0;
    @try {
        // ---- 1) collection view 那条路 ----
        SEL s1 = @selector(collectionView:layout:sizeForItemAtIndexPath:);
        for (NSUInteger i = 0; i < gJTAdSizeBaseTable.count; i++) {
            Class c = gJTAdSizeBaseTable.items[i].cls;
            IMP base = gJTAdSizeBaseTable.items[i].base;
            if (!c || !base) continue;
            Method own = JTOwnMethod(c, s1);
            if (!own) continue;
            if (method_getImplementation(own) != (IMP)JTAdSizeHook) continue;
            method_setImplementation(own, base);
            undone++;
        }
        JTBaseIMPTableReset(&gJTAdSizeBaseTable);

        // 我们 class_addMethod 加上去的那批 → 换成"永远返回 itemSize"的直通版，
        // 而不是删方法（运行时不支持删）。这样等价于没插过手。
        // ★ 必须做：否则长按 T 恢复广告之后，布局仍把广告格收成 0.5pt，
        //   用户看到的是"广告回来了但被压扁"——比没恢复更怪。
        for (NSUInteger i = 0; i < gJTAdSizeNoBaseCount; i++) {
            Class c = gJTAdSizeNoBaseCls[i];
            if (!c) continue;
            Method own = JTOwnMethod(c, s1);
            if (own && method_getImplementation(own) == (IMP)JTAdSizeHook) {
                method_setImplementation(own, (IMP)JTAdSizePassThrough);
                undone++;
            }
        }
        gJTAdSizeNoBaseCount = 0;

        // ---- 2) table view 那条路（同构） ----
        SEL s2 = @selector(tableView:heightForRowAtIndexPath:);
        for (NSUInteger i = 0; i < gJTRowHBaseTable.count; i++) {
            Class c = gJTRowHBaseTable.items[i].cls;
            IMP base = gJTRowHBaseTable.items[i].base;
            if (!c || !base) continue;
            Method own = JTOwnMethod(c, s2);
            if (!own) continue;
            if (method_getImplementation(own) != (IMP)JTRowHeightHook) continue;
            method_setImplementation(own, base);
            undone++;
        }
        JTBaseIMPTableReset(&gJTRowHBaseTable);
        for (NSUInteger i = 0; i < gJTRowNoBaseCount; i++) {
            Class c = gJTRowNoBaseCls[i];
            if (!c) continue;
            Method own = JTOwnMethod(c, s2);
            if (own && method_getImplementation(own) == (IMP)JTRowHeightHook) {
                method_setImplementation(own, (IMP)JTRowHeightPassThrough);
                undone++;
            }
        }
        gJTRowNoBaseCount = 0;

        // ---- 3) 清状态，允许之后重新安装 ----
        if (gJTAdSizeHookDone) [gJTAdSizeHookDone removeAllObjects];
        if (gJTRowHookDone) [gJTRowHookDone removeAllObjects];
        if (gJTAdItemIndexes) [gJTAdItemIndexes removeAllObjects];
        if (gJTAdInvalidateLog) [gJTAdInvalidateLog removeAllObjects];
        gJTAdInvalidateTotal = 0;
        gJTAdSizeHookCalls = 0;
        gJTAdRowHookCalls = 0;
    } @catch (NSException *e) {
    }
    return undone;
}

static NSUInteger JTSweepBlockAdsInView(UIView *v, NSUInteger depth, NSUInteger *budget,
                                        NSMutableArray *hiddenNew, NSMutableArray *suspect,
                                        NSMutableArray *collapseLog, NSMutableArray *stickyLog,
                                        NSMutableArray *itemLog) {
    if (!v || depth > (NSUInteger)SWEEP_MAX_DEPTH || !budget || *budget == 0) return 0;
    (*budget)--;
    NSUInteger acted = 0;
    NSString *cn = NSStringFromClass([v class]);

    if (JTClassIsKnownAdView(cn)) {
        // ★ 第 12c-4 节的 ⑤ **必须放在 `!v.hidden` 判断之外**：
        //   粘性隐藏（第 12c-3 节）会在**布局周期里**就把新建/复用的广告 cell 设成 hidden，
        //   等我们这一秒扫到它时 `v.hidden` 早就是 YES 了。若把 ⑤ 放在 `!v.hidden` 里面，
        //   那份"这个 indexPath 上是广告"的记录**永远补不上**，布局层的钩子就永远拿不到答案
        //   → 表现就是"钩子装上了、却一点用都没有"（最难查的一种）。
        //   ⑤ 自己是幂等的（装过就返回"已装过"），所以每秒调一次是零成本。
        NSString *itemHow = JTAdItemCollapse(v);
        if (itemHow) {
            @synchronized (@"JTAdLog") {
                if (!gJTAdItemLogged) gJTAdItemLogged = [NSMutableSet set];
                NSString *key = [NSString stringWithFormat:@"%@|%@", cn, itemHow];
                if (![gJTAdItemLogged containsObject:key] && gJTAdItemLogged.count < 40) {
                    [gJTAdItemLogged addObject:key];
                    [itemLog addObject:[NSString stringWithFormat:@"%@ → %@", cn, itemHow]];
                }
            }
        }

        if (!v.hidden) {
            v.hidden = YES;
            acted++;
            if (!gJTHiddenAdViews) gJTHiddenAdViews = [NSHashTable weakObjectsHashTable];
            [gJTHiddenAdViews addObject:v];

            // ① 先上"粘性隐藏"：把规则下沉到**类**上。
            //    实测 App 会把隐藏过的广告重新显示回来（见第 12c-3 节），
            //    只靠 1 秒一次的扫掠是竞速，赢不了。每个类只装一次。
            @synchronized (@"JTAdLog") {
                if (!gJTStickyDone) gJTStickyDone = [NSMutableSet set];
                if (![gJTStickyDone containsObject:cn] && gJTStickyDone.count < 40) {
                    [gJTStickyDone addObject:cn];
                    Class k = NSClassFromString(cn);
                    NSString *r = JTInstallStickyHide(k);
                    [stickyLog addObject:[NSString stringWithFormat:@"%@ → %@", cn, r]];
                }
            }

            // ② 再收高度 —— 只隐藏会在页面中部留一块空白（见第 12c-2 节）
            NSString *how = JTCollapseAdSpace(v);
            BOOL firstForThis = NO;
            @synchronized (@"JTAdLog") {
                if (!gJTAdCollapseLogged) gJTAdCollapseLogged = [NSMutableSet set];
                NSString *key = [NSString stringWithFormat:@"%@|%@", cn, how];
                if (![gJTAdCollapseLogged containsObject:key] && gJTAdCollapseLogged.count < 40) {
                    [gJTAdCollapseLogged addObject:key];
                    [collapseLog addObject:[NSString stringWithFormat:@"%@ → %@", cn, how]];
                    firstForThis = YES;
                }
            }
            // 每个类只安排一次自证，避免每秒重复排
            if (firstForThis) JTScheduleCollapseVerify(v, cn);

            // 日志只在"某个类第一次被隐藏"时打一次 —— 否则 App 一旦把广告重新显示出来，
            // 我们就每秒刷一行，把真正有用的信息挤出诊断缓冲。
            @synchronized (@"JTAdLog") {
                if (!gJTAdLoggedHidden) gJTAdLoggedHidden = [NSMutableSet set];
                if (![gJTAdLoggedHidden containsObject:cn] && gJTAdLoggedHidden.count < 40) {
                    [gJTAdLoggedHidden addObject:cn];
                    [hiddenNew addObject:cn];
                }
            }
        }
    } else if (JTClassLooksLikeAdSuspect(cn)) {
        // 只是"可疑" —— **不动它**，只记一次类名，供下一轮补白名单
        @synchronized (@"JTAdLog") {
            if (!gJTAdLoggedSuspect) gJTAdLoggedSuspect = [NSMutableSet set];
            if (![gJTAdLoggedSuspect containsObject:cn] && gJTAdLoggedSuspect.count < 80) {
                [gJTAdLoggedSuspect addObject:cn];
                [suspect addObject:cn];
            }
        }
    }

    for (UIView *c in v.subviews) {
        if (*budget == 0) break;
        acted += JTSweepBlockAdsInView(c, depth + 1, budget, hiddenNew, suspect, collapseLog, stickyLog, itemLog);
    }
    return acted;
}

static void JTSweepBlockAds(NSString *reason) {
#if ENABLE_AD_SWEEP
    @try {
        if (gJTAdRuleDisabled) return;   // 长按 T 之后本次启动不再动广告

        UIApplication *app = [UIApplication sharedApplication];
        // 后台不扫：一是没必要，二是往非活跃界面写 hidden 没意义，还可能干扰 App 自己的状态恢复
        if (!app || app.applicationState != UIApplicationStateActive) return;

        NSMutableArray *hiddenNew = [NSMutableArray array];
        NSMutableArray *suspect = [NSMutableArray array];
        NSMutableArray *collapseLog = [NSMutableArray array];
        NSMutableArray *stickyLog = [NSMutableArray array];
        NSMutableArray *itemLog = [NSMutableArray array];
        NSUInteger acted = 0;
        for (UIWindow *w in app.windows) {
            if ([w isKindOfClass:[JTOverlayWindow class]]) continue;
            NSUInteger budget = SWEEP_NODE_BUDGET;
            acted += JTSweepBlockAdsInView(w, 0, &budget, hiddenNew, suspect, collapseLog, stickyLog, itemLog);
        }
        if (hiddenNew.count > 0) {
            JTDiag(@"[广告清理·%@] 隐藏 %lu 个（本次新命中类：%@）",
                   reason, (unsigned long)acted, [hiddenNew componentsJoinedByString:@", "]);
        }
        if (stickyLog.count > 0) {
            JTDiag(@"[广告粘性·%@] 规则已下沉到类（%@）",
                   reason, [stickyLog componentsJoinedByString:@" | "]);
        }
        if (collapseLog.count > 0) {
            JTDiag(@"[广告收起·%@] 收高度的结果：%@",
                   reason, [collapseLog componentsJoinedByString:@" | "]);
        }
        if (itemLog.count > 0) {
            JTDiag(@"[广告item·%@] 让布局层收掉这一格：%@",
                   reason, [itemLog componentsJoinedByString:@" | "]);
        }
        if (suspect.count > 0) {
            JTDiag(@"[广告清理·%@] 可疑但**未处理**的类（下一轮据此补白名单）：%@",
                   reason, [suspect componentsJoinedByString:@", "]);
        }
    } @catch (NSException *e) {
    }
#endif
}

static void JTStartAdSweepTimer(void) {
    // ★ 注意这里的条件：定时器同时服务 tab 规则和广告扫掠两件事，
    //   所以只要**任一**开着就必须起 —— 挂在 ENABLE_AD_SWEEP 下面会让
    //   "关掉广告扫掠" 顺带把 tab 规则的漂移保护也一起关掉（一个很难注意到的耦合）。
#if (ENABLE_AD_SWEEP || ENABLE_TAB_RULE)
    if (gJTSweepTimer) return;
    // 用 dispatch_source 而不是 NSTimer：NSTimer 受 runloop mode 影响 ——
    // 滚动 UITableView 时默认 mode 不跑定时器，滑动期间广告会短暂露出来；
    // dispatch_source 挂在主队列上，不受 runloop mode 影响。
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    if (!t) {
        JTDiag(@"[维护] 定时器创建失败 —— 本次只有启动那一次处理");
        return;
    }
    uint64_t interval = (uint64_t)(SWEEP_INTERVAL_SEC * (double)NSEC_PER_SEC);
    uint64_t leeway = (uint64_t)(0.3 * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, leeway);
    // ★ 这个定时器同时兜两件事，因为两者的"被 App 撤销"方式是同一个：
    //   ① tab 规则里的**自绘图标层**（App 可能在旋转 / 服务端配置刷新时自己重排，
    //      把我们已经摆好的图标挪回 5 槽位 —— 那时图标还是可见的，只是位置错乱，
    //      而启动复检链 +30s 就结束了，光靠它兜不住）
    //   ② 广告扫掠（App 可能把广告重新显示出来）
    //   两个函数都幂等：状态对了就什么都不做，所以每秒调一次在正常情况下是零成本。
    dispatch_source_set_event_handler(t, ^{
        UIApplication *app = [UIApplication sharedApplication];
        if (!app || app.applicationState != UIApplicationStateActive) return;
#if ENABLE_TAB_RULE
        JTApplyTabRule(@"定时");
#endif
#if ENABLE_AD_SWEEP
        JTSweepBlockAds(@"定时");
#endif
    });
    dispatch_resume(t);
    gJTSweepTimer = t;
    JTDiag(@"[维护] 定时复检已启动（每 %.1f 秒一次：tab 规则 + 广告扫掠，仅前台）",
           SWEEP_INTERVAL_SEC);
#endif
}


// ============================== 12. 悬浮按钮（仅调试版） ==============================
// ★ 发布版（`ENABLE_DEBUG_UI = 0`）不创建这个窗口 —— 界面上看不到任何我们的东西。
//   下面这一节 + 第 0 节的窗口类，只有把 `ENABLE_DEBUG_UI` 改成 1 重新构建后才存在。
//   发布版想要"撤销"，用 TrollFools 关掉注入即可（比下面的长按 T 更彻底）。

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
        // tab bar 深挖：目标 ① 达成后仍可能有"看不出出处"的装饰物留在导航栏上，
        // 而**直接子视图清单看不出这件事**（v0.3.1 实测：直接子视图全 [隐]，
        // 用户仍看到残留凸起）。所以子树 / 非视图 layer / 兄弟视图三样一起打。
        UITabBarController *tbc = JTFindTabBarController();
        if (tbc && tbc.tabBar) {
            JTDiag(@"[tabBar深挖·长按]%@", JTDescribeTabBarDeep(tbc.tabBar, 3));
        }
        NSString *snap = JTDiagSnapshot();
        UIPasteboard.generalPasteboard.string = snap;
        [self flash:[NSString stringWithFormat:@"ALL %lu", (unsigned long)snap.length]];
    } @catch (NSException *e) {
        [self flash:@"err"];
    }
}

// T 按钮（原 RM）：**手动再应用一次 tab 规则**。
// 为什么需要手动入口：启动期的复检链只覆盖到 +30s。之后如果 App 按服务端配置
// （`JGTabBarConfigModel`）重建了 tab bar，或者规则第一次因为"tab 还没建出来"没赶上，
// 点一下就能立刻收干净 —— 不用重装、不用重启。
- (void)onTabs:(UIButton *)sender {
    @try {
        gJTRuleDisabled = NO;          // 手动点 = 明确的"我要规则生效"，解除停手
        JTApplyTabRule(@"手动");
        JTLogTabBarState(@"手动应用规则");
        UIPasteboard.generalPasteboard.string = JTDiagSnapshot();
        [self flash:@"T"];
    } @catch (NSException *e) {
        [self flash:@"err"];
    }
}

// 长按 T = **恢复**：原始 5 个 tab 复原 + 我们隐藏过的广告全部恢复，并在本次启动内停手。
// 这是"后悔药"：规则一旦误判（比如「流量」其实不是我们以为的那个 index，
// 或者 `BannerCycleView` 其实不是「电话/消息」页那条横幅），
// 不用重装、不用重启，长按一下就回到原样，同时把诊断写进剪贴板供排查。
- (void)onTabsRestore:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try {
        JTRestoreTabs();
        JTRestoreAds();
        JTLogTabBarState(@"手动恢复");
        UIPasteboard.generalPasteboard.string = JTDiagSnapshot();
        [self flash:@"复原"];
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

        // 第二个按钮 T（原 RM）：tab 规则的手动入口。
        // 单独一个按钮、单独一种颜色 —— 混进 JT 按钮的手势里会误触，
        // 而误触会真的改 tab bar（虽然可恢复，但会让人以为 App 出问题了）。
        // 点 = 再应用一次规则；长按 = 恢复原始 5 个 tab 并停手。
        UIButton *rm = [UIButton buttonWithType:UIButtonTypeCustom];
        rm.frame = CGRectMake(0, 0, 44, 44);
        rm.backgroundColor = [UIColor colorWithRed:0.72 green:0.28 blue:0.10 alpha:0.80];
        rm.layer.cornerRadius = 22.0;
        rm.layer.masksToBounds = YES;
        rm.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
        [rm setTitle:@"T" forState:UIControlStateNormal];
        [rm setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        rm.center = CGPointMake(w.bounds.size.width - 34.0, 182.0);
        [rm addTarget:h action:@selector(onTabs:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp2 =
            [[UILongPressGestureRecognizer alloc] initWithTarget:h action:@selector(onTabsRestore:)];
        lp2.minimumPressDuration = 0.6;
        [rm addGestureRecognizer:lp2];
        [w.rootViewController.view addSubview:rm];

        w.hidden = NO;

        gJTOverlay = w;
        gJTButton = b;
        gJTRmButton = rm;
        gJTBtnHandler = h;   // 必须持有：target-action 不 retain target
        JTDiag(@"[悬浮按钮] 已安装（JT=抓取当前页/长按全量；T=手动应用 tab 规则/长按恢复 tab+广告）");
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

    // ---------------- v0.3 的三条线 ----------------
    // 顺序有讲究：先应用 tab 规则（它会重建 tab bar 的 VC 数组），再启动广告扫掠
    // （它会走一遍视图树，这时 tab bar 已经是最终形态，日志里看到的才是有意义的现场）。

    JTStageSet("应用:tab 规则");
    JTApplyTabRule(@"启动");
    JTScheduleTabRuleReapply();

    JTStageSet("应用:广告扫掠");
    JTSweepBlockAds(@"启动");
    JTStartAdSweepTimer();

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
    // 纯诊断（结果只进诊断缓冲、靠悬浮按钮读出来）→ 发布版连这一次调度都不必发生。
#if ENABLE_CLASS_SCAN
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        JTScanInterestingClasses();
    });
#endif

    JTStageSet("安装完成");
    JTDiag(@"[启动] %s %s 已加载", JT_TAG, JT_VERSION);
    // 一行总览：哪个钩子真的挂上了。挂载失败时这里是"无"，而各安装器自己的那行会说明原因 ——
    // 两处对不上就说明有问题，不用去翻中间几十行日志。
    JTDiag(@"[钩子总览] viewDidAppear=%@ | setViewControllers=%@ | setViewControllers:animated=%@ | present=%@",
           gJTHookedVDA ?: @"无", gJTHookedSetVCs ?: @"无",
           gJTHookedSetVCsAnim ?: @"无", gJTHookedPresent ?: @"无");
    JTDiag(@"[用法] JT: 点=抓当前页并复制 / 长按=复制全部诊断。"
            "T: 点=手动应用 tab 规则 / 长按=恢复原始 tab + 恢复被隐藏的广告 + 停手。");

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
