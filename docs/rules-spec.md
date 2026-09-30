# v0.3 规则设计（等 v0.2 的 dump 回来后再定稿）

这份文档定义"移除 tab、拦弹窗、清广告位"三条线的具体做法。
v0.2 的 dump 回来后，把实测类名/标题填进规则表即可。

---

## 一、移除「首页 / 目的地 / 流量」三个 tab

**先看 v0.2 的哪一条证据**，再决定走哪条路：

| dump 里的现象 | 结论 | 走哪条路 |
|---|---|---|
| 有 `setViewControllers:animated:` 调用记录 | 系统 `UITabBarController` | **路径 A** |
| TabBar 实时状态里 VC 数 = 页面数，title 能对上「首页/目的地/流量」 | 系统 `UITabBarController` | **路径 A** |
| 「TabBar 取证：找到 0 个 UITabBarController」+ 反查命中了某个容器类 | 自绘容器 | **路径 B** |
| 视图树里有横向排列的按钮，文案是「首页」「目的地」「流量」 | 自绘 tab bar | **路径 B** |

### 路径 A：系统 UITabBarController

拦 `setViewControllers:animated:`，把目标 VC 从数组里滤掉，再转发：

```objc
static void new_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    NSMutableArray *kept = [NSMutableArray array];
    for (UIViewController *vc in vcs) {
        if (WFIsTargetTab(vc)) continue;      // 首页/目的地/流量 → 丢
        [kept addObject:vc];
    }
    if (kept.count == 0) kept = [vcs mutableCopy];   // ★ 兜底：不能把 tab 清空
    // 转发（调用已保存的原 IMP）
}
```

**三个必须处理的坑：**

1. **不能把 tab 清空**。如果三个目标恰好是全部 tab，App 会白屏。
   上面那条 `if (kept.count == 0)` 是必须的。
2. **`selectedIndex` 要重映射**。App 可能在别处写死 `selectedIndex = 0` 或
   `selectedViewController = homeVC`。需要一并拦 `setSelectedIndex:` /
   `setSelectedViewController:`，把索引映射到过滤后的数组。
3. **`tabBarItem` 在 VC 上**。判断"这个 VC 是不是首页"要用
   `vc.tabBarItem.title`（实测值，不猜），而不是类名 —— 除非 dump 证明类名稳定。

### 路径 B：自绘容器

自绘 tab 一般由两部分组成，**必须两边同时处理**，只做一半会留下"点了没反应"或"按钮还在"：

1. **tab 按钮**：在容器视图里按文案/类名找到那三个按钮，隐藏（`hidden = YES`）
   或从父视图移除。**只隐藏不重排**会留下空位，需要按实测的布局方式决定要不要重排。
2. **内容区**：容器通常持有一个 `viewControllers` 数组 + 一个当前索引。
   要拦它的 `setViewControllers:` / `setSelectedIndex:`（v0.2 的反查就是为此），
   把目标 VC 摘掉并重映射索引。

自绘容器的布局常常是 `UIStackView` 或手算 frame。如果是 `UIStackView`，
隐藏 arranged subview 会自动重排（这是最省事的情况）。

### 两路共用的判断函数

```objc
// 判断标准来自 v0.2 的实测值，不是猜的
static BOOL WFIsTargetTab(UIViewController *vc) {
    NSString *title = vc.tabBarItem.title ?: @"";
    if ([title isEqualToString:@"首页"] || [title isEqualToString:@"目的地"] ||
        [title isEqualToString:@"流量"]) return YES;
    NSString *cls = NSStringFromClass([vc class]);
    return [cls isEqualToString:@"<实测类名1>"] || ...;   // 类名兜底
}
```

---

## 二、拦开屏广告与启动弹窗

v0.2 会给出「谁弹了谁」的清单。拦法按弹窗来源分三类：

| 来源 | 拦法 |
|---|---|
| `presentViewController:` | 已 hook。命中黑名单就**不转发**给原实现，直接 return |
| window 上的自绘视图 | 在 `addSubview:` hook 里命中就 `removeFromSuperview` 或 `hidden = YES` |
| 延迟弹出的（定时器触发） | 同上，但 hook 要一直在位；另外可以在 `viewDidAppear:` 后定时清理一次 |

**关键约束：不能拦错。** 只拦 dump 里实测到的、确认是广告/活动的类。
按类名关键词猜（"Promo"、"Activity"）很容易误伤正常功能（比如「我的活动」订单页）。

**必须保留"兜底放行"**：如果黑名单为空，或某个弹窗类名不在表里，
一律按原样放行 —— 宁可漏拦，不可误拦。

---

## 三、清页面内广告/营销位

按 v0.2 视图树的实测结果，逐条加规则。**从一条开始，不要一次全上** ——
一次性上多条规则，出问题无法归因是哪一条。

### 隐藏 vs 移除

| 方式 | 效果 | 风险 |
|---|---|---|
| `hidden = YES` | 安全，App 逻辑不受影响 | **布局保留空间 → 留白** |
| `removeFromSuperview` | 空间回收，页面真正变紧凑 | App 后续重布局若还引用它，可能出问题 |

**默认 `hidden`，只有留白明显时才升级到 `removeFromSuperview`。**

### 按文案命中时要向上找卡片祖先

直接隐藏一个 UILabel 会留下空白块，比不删还难看。要向上找"看起来像卡片"的祖先
（有背景色/圆角/阴影，且尺寸明显大于 label），隐藏那一层。

### 列表类模块（推荐商品）

`UITableView` / `UICollectionView` 的 cell 隐藏没用 —— 行数由 dataSource 决定。
这类要 hook 数据源（`numberOfRowsInSection:` 等），**并且要单独确认**：
是"要删的模块在它的数据里"，还是整张表都该删。

---

## 四、重入与刷新

App 会自己重建视图树（下拉刷新、切 tab 回来、数据回填）。规则不能只应用一次。
三个时机都要覆盖：

1. `viewDidAppear:` 后立即应用一次
2. `+1.5s / +4s` 延迟复检（数据回填通常在这之后）
3. 页面根视图的 `addSubview:` 被调用时增量应用一次

每条规则做**幂等判断**：已经处理过的不要再动，避免和 App 的布局打架。

---

## 五、H5 页面（如果是）

v0.2 的 dump 会直接告诉我们是哪种情况：

- 大量原生视图 → 原生页面，走上面几节
- 只有一个 `WKWebView` 顶着整个页面 → H5 页面，注入 CSS

```objc
NSString *css = @"[class*=banner],[class*=recommend]{display:none !important;}";
NSString *js = [NSString stringWithFormat:
    @"var s=document.createElement('style');s.innerHTML='%@';"
    @"document.documentElement.appendChild(s);", css];
```

选择器要用**属性包含匹配**（`[class*=xxx]`）而不是精确类名 —— H5 改版后精确类名会失效。

---

## 六、绝对不做的事

- 不 hook 任何网络请求 / 签名 / 鉴权逻辑
- 不伪造数据、不绕过付费
- 不修改服务端可见的任何状态
- 只做**视图层与导航层的显示与隐藏**
