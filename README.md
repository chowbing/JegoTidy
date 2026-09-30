# JegoTidy — 无忧行界面精简插件

**目标**：把「无忧行」（`com.cmi.jegotrip`，中国移动国际，v8.9.4）的
**「首页 / 目的地 / 流量」三个 tab 从导航栏移除**，并拦掉开屏广告、启动弹窗和页面内营销位。

当前版本：**v0.2 探针版** —— 只观测，不修改任何界面。

---

## 1. 为什么第一版是"探针"而不是直接写规则

要"移除 tab"，得先知道 **tab 是怎么被建出来的**。无忧行是原生 + H5 混合的国产 App，
它的 tab bar 有两种可能，**改法完全不同**：

| 情况 | 改法 | 需要知道什么 |
|---|---|---|
| 系统 `UITabBarController` | 拦 `setViewControllers:`，过滤掉目标 VC | 哪个类、VC 数组长什么样、tab 标题对应哪个类 |
| 自绘容器（国产 App 常见） | 找到容器类，隐藏对应 tab 按钮 + 从内容区摘掉对应子 VC | 容器类名、tab 按钮的类名/文案、内容区的结构 |

猜错就是白跑一轮构建。所以这一版**不做任何修改**，只把"tab 是怎么建出来的"变成**直接证据**。

同类项目的实测教训：
**"改一个变量看 App 有没有反应"每轮只能排除一个假设，几十轮都收敛不了**；
而 dump 一次真实结构是直接证据，一轮就能定规则。

| 轮次 | 产出 | 目的 |
|---|---|---|
| **v0.2** | 探针 dylib（当前） | 抓 tab 构造过程 + 弹窗/开屏 + 三页视图树 |
| v0.3 | 规则 dylib | 按实测类名/标题移除 tab、拦弹窗、清广告位 |
| v0.4 | 调优 | 处理漏网项、H5 页注入 CSS |

---

## 2. 环境与工具链

- 本机 **Windows，无 macOS** → 编译走 GitHub Actions（`macos-latest` runner）。
- 本机 **无 Xcode / 无 Theos** → 本地只做静态审计，不做编译。
- 真机注入：**TrollStore + TrollFools**（选 App → 注入 dylib → 重启生效）。

```bash
# 推送前必跑（本机即可执行）
C:/Users/1107089/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe tools/preflight.py Tweak.xm
```

| 脚本 | 抓什么 |
|---|---|
| `chk.py` | 括号/引号不配对（tokenizer 感知，字符串里的 `}` 不会骗过它） |
| `audit.py` | A 调用点早于定义 · B 全局变量引用早于定义 · C 递归 block 缺 `__block` |
| `strchk.py` | 字符串字面量未闭合 |
| `objcpp.py` | ObjC++ 专属硬错误（`IMP` → `void *` 等） |
| `ips.py` | 崩溃报告解析（`python tools/ips.py crash.ips`） |

**为什么必须跑**：`.xm` 被 clang 当 **Objective-C++** 编译，隐式函数声明、类型不匹配、
`IMP` 隐式转 `void *` 全是**硬 error**，`-Wno-error` 救不了。本机编译不了，
一次推送 = 一轮 Actions，所以本地先把这类错误清掉。

---

## 3. 一次完整迭代怎么做

```
改 Tweak.xm
   ↓  tools/preflight.py 四项全过
GitHub Desktop → Commit to main → Push origin
   ↓
GitHub Actions 自动构建 → 下载 artifact：JegoTidy-dylib、build.log
   ↓
真机 TrollFools → 选「无忧行」→ 注入 JegoTidy.dylib → 重启 App
   ↓
操作 App，抓 dump → 粘贴回对话
```

### 首次推送到 GitHub（GitHub Desktop，只需做一次）

1. 打开 GitHub Desktop → **File → Add local repository…**
2. 目录选 `D:\WorkBuddy AI\无忧行\JegoTidy`
   （它已经是 git 仓库，`main` 分支上已有 1 条提交；如果它提示这不是仓库，是路径选错了，别新建）
3. 顶部/右侧点 **Publish repository**
4. 仓库名填 `JegoTidy`，**勾上 "Keep this code private"**，确认
5. 发布完成后回到仓库，若还显示 **Push origin**，点一下把提交推上去

之后每次改完：GitHub Desktop 里写 commit message → **Commit to main** → **Push origin**。
`.gitignore` 已经把 `.theos/`、`*.dylib`、`build.log` 排除掉，构建产物不会进仓库。

> ⚠️ **「添加本地仓库」和「新建仓库」不要选错（本项目已踩过两次）**
>
> GitHub Desktop 的 **File** 菜单里这两个挨在一起：
>
> - ✅ **Add local repository…（添加本地仓库）** ← 用这个。路径填
>   `D:\WorkBuddy AI\无忧行\JegoTidy`
> - ❌ **New repository…（新建仓库）** ← 别用。如果 Local path 填了
>   `...\无忧行\JegoTidy`、Name 又填 `JegoTidy`，它会在**里面再套一层**
>   `...\JegoTidy\JegoTidy\`，把那个空仓库推上 GitHub。
>   症状：仓库网页上只有 `.gitattributes` 和 `README.md` 两个文件，Actions 不跑。
>
> 判断方法：在项目目录执行 `git remote -v`，**必须**输出
> `https://github.com/chowbing/JegoTidy.git`。没有输出 = 你打开的是那个空壳子仓库。
>
> 已经踩了怎么办：删掉多出来的同名子目录，然后在 GitHub Desktop 里
> **Repository → Remove** 移除那条错误记录（**不要**勾 "Move to Trash"），
> 再用 Add local repository 重新添加正确路径。

构建失败先看 `build.log`，`grep -n "error:" build.log`。

**看最后那句的计数**：clang 默认 `-ferror-limit=20`，遇到语义错误会继续往下编译，
所以结尾是 `1 error generated.` 就说明**整个编译单元真的只有这一个错**，修一次就够，
不用靠再跑一轮 CI 去发现下一个。
（例外：`'xxx.h' file not found` 这类 fatal error 会当场中止，那种情况下"只有一个错"
说明不了任何事。）

改完源码先跑 `python tools/preflight.py`，四项全过再推。

### CI 没触发怎么排查（按这个顺序，从便宜到贵）

**1. 仓库里到底有没有那个文件**
在 github.com 打开仓库 → 确认文件列表里有 `.github/workflows/build.yml`。
看不到 = 推送没成功（回 GitHub Desktop 再点一次 **Push origin**）。

**2. Actions 认不认得这个 workflow**
仓库页 → **Actions** 标签 → 看左侧栏有没有 **Build JegoTidy dylib**？

- **有** → 文件没问题，是触发条件或额度问题，看第 3、4 条
- **没有**，或页面写着 *Workflows aren't being run on this repository* → Actions 被关了：
  **Settings → Actions → General → Actions permissions** 选
  *Allow all actions and reusable workflows* → Save

**3. 手动触发一次**
Actions → 左侧选 **Build JegoTidy dylib** → 右侧 **Run workflow** → 分支选 `main` → Run。
能跑起来 = 文件没问题，只是自动触发没生效。

**4. 额度（最容易被忽略的一条）**
**Settings → Billing and plans → Plans and usage → Actions**

个人免费账号的私有仓库每月 2,000 分钟，**但 macOS runner 按 10 倍计费** ——
等于每月只有约 **200 分钟真实 macOS 构建时间**。
额度用完的表现是：run 会创建但**立刻失败**，提示 spending limit。

绕开的办法（按推荐顺序）：

| 办法 | 代价 |
|---|---|
| 等下一个计费周期重置 | 最省事，但要等 |
| 仓库改成 **public** | Actions 对公开仓库**免费且不限量**；代价是代码公开 |
| `runs-on` 改 `ubuntu-latest` | 1 倍计费，但 Linux 交叉编译 iOS 的坑更多（见技能里的说明） |

**5. 分支名**
GitHub Desktop 左下角确认当前分支是 `main` 且已 Push。

---

## 4. v0.2 怎么用（真机操作）

打开 App 后右上角出现蓝色小圆点（可拖动）：

| 操作 | 效果 |
|---|---|
| **点一下** | 抓当前屏幕视图树 + **实时 tab bar 状态**，追加进诊断，并把完整快照写进剪贴板 |
| **长按** | 把累计的完整诊断复制到剪贴板（含全部取证） |
| **拖动** | 移动位置，避免挡住页面元素 |

标准动作（顺序无关，剪贴板每次都写**完整累积快照**，不会互相覆盖）：

1. 打开 App，**先别动** —— 等 5 秒，让启动期的开屏广告/弹窗被抓到
2. 如果启动了活动弹窗，**让它弹一次再关掉**
3. 进「首页」点一下 → 进「目的地」点一下 → 进「流量」点一下
4. **长按**圆点 → 粘贴回对话

---

## 5. v0.2 会抓到哪些东西（这些就是定规则的依据）

| 取证项 | 内容 | 解决什么问题 |
|---|---|---|
| **`setViewControllers:` 调用** | VC 数组（类名 + tab 标题）+ **调用栈** | tab 是哪个类搭的、标题↔类名怎么对应 |
| **TabBar 实时状态** | 每个 VC 的类名 / title / tag / badge；系统 UITabBar 的 items | 即使 hook 装晚了也能补上 |
| **类名扫描（容器/tab）** | 名字含 TabBar/MainTab/Container/Root 的类 + 父类 | 自绘容器叫什么 |
| **反查 selector 归属** | 自己实现 `setViewControllers:` / `setSelectedIndex:` 的 VC 子类（**带对照组剔除万能类**） | 类名不含 Tab 字样的自绘容器 |
| **弹窗取证** | 每一次 `presentViewController:` 的「谁弹了谁」+ 首次调用栈 | 启动弹窗、活动弹窗的类名 |
| **叠加视图取证** | `UIWindow addSubview:` 里命中广告关键词的类 | 直接贴在 window 上的开屏广告 |
| **三页视图树** | 可见节点：类名 / frame / 文案 / a11y id | 广告位和营销模块的具体位置 |
| **VC 类名清单** | App 自己出现过的所有 VC 类名 | 交叉验证 |

### dump 怎么看

```
--- 窗口#0 level=0 根VC=XXXTabBarController frame=(0,0,390,844)
0) UIWindow (0,0,390,844)
  0) UILayoutContainerView (0,0,390,844)
    0) UITransitionView (0,0,390,844)
      0) XXXHomeViewController (0,0,390,844)
        0) UIScrollView (0,0,390,844)
          0) XXXBannerView (0,16,390,120) id=home_banner
            0) UILabel (12,20,200,20) "限时5折 立即抢购"
```

行首数字 = 它在父视图 `subviews` 里的下标。
只 dump **看得见**的节点（隐藏/全透明/零尺寸的跳过）。

---

## 6. 安全设计（每一条都对应上一轮踩过的坑）

| 机制 | 防的是什么 |
|---|---|
| `%ctor` 只装崩溃处理器，其余全部 `dispatch_async` 到主队列 | 主队列在 `UIApplicationMain` 起 runloop 前**根本不执行**，这是"绝对晚于启动"的结构性保证，比 sleep 秒数可靠 |
| 查类表用 `class_copyMethodList` 手走父类链，**绝不用** `class_getInstanceMethod` | 后者会强制 `+initialize`；dyld 阶段全进程扫类 = 把 App 几百个类挨个初始化一遍，任一类的 `+initialize` 抛异常就死在启动前，且 `@try/@catch` 救不了（异常在 `dispatch_once` 里被 libdispatch 边界吞掉变成 `std::terminate`） |
| 启动自愈计数（同构建连续 3 次启动异常 → 只留按钮不装钩子） | 防"崩到 App 完全打不开、连诊断都拿不到"。换构建 token 自动从 0 开始，修好即恢复 |
| 诊断缓冲滚动窗口 + 显式截断标记 | 防"写满就静默停止"——那会保留头部丢掉尾部；标记是为了让"只有这些条目"和"只剩这些条目"可区分 |
| 每个"自己实现该方法"的类单独挂 hook，原 IMP 按类名存 | 只挂基类对重写了该方法的子类是**瞎的**（`objc_msgSend` 落到子类实现上） |
| **两个 `setViewControllers:` 重载各用独立字典** | 共用一个字典（键都是类名）会互相覆盖 → 转发到错误的 IMP → 参数对不上 + 对方也是我们的 hook → **无限递归** |
| `WFIsDescendantOf` 廉价预筛 | 避免为全进程几万个类各做一次 `class_copyMethodList`，那会卡住启动一两秒 |
| 弹窗取调用栈前先查"是不是新键" | `callStackSymbols` 要符号化，不便宜；present 可能被系统高频调用 |
| 类名扫描放后台队列 | 几万个类跑正则，放主线程会有可见卡顿；这些只读运行时查询天然线程安全 |
| `UIWindow addSubview:` 用 `class_addMethod` 加**自己的**实现 | 直接 `method_setImplementation` 改的是从 UIView 继承来的那份，会波及全 App 每一个 UIView |
| 反查 selector 归属带对照组 | 全进程扫描会返回"对任何 selector 都回答 yes"的万能类，实测同一批五个类能"实现"十几个毫不相关的 selector |
| 信号处理函数里只用 `open/write/snprintf/backtrace_*` | 这些是异步信号安全的；碰 `NSString`/`NSLog` 会分配内存导致二次崩溃 |

---

## 7. 风险与边界

- **合规**：这是给**你自己的设备、你自己的账号、你自己安装的 App** 做界面精简，
  不绕过付费、不伪造请求、不修改服务端数据。但**仍可能违反该 App 的用户协议**，
  风险自负。不要分发改造后的 IPA。
- **越狱检测**：无忧行可能带越狱/注入检测。首次运行如果闪退或弹警告，
  把现象告诉我 —— 崩溃报告会落在 `Caches/wf_crash.log`，下次启动自动读回诊断框。
- **不碰网络层**：v0.3 只做视图层和导航层，不 hook 任何请求/签名/鉴权逻辑。
- **H5 页面**：如果某页实际是 `WKWebView` 渲染的，原生视图树里只有一个 webview，
  隐藏要靠注入 CSS（v0.4）。探针 dump 会明确显示是不是这种情况。
- **移除 tab 的副作用**：如果 App 的其它逻辑引用了被移除的 VC（比如启动时
  `selectedIndex = 0` 指向已删的 tab），需要同步把 `selectedIndex` 重映射到剩下的 tab。
  v0.3 会一并处理。

---

## 8. 目录

```
JegoTidy/
├── Tweak.xm                     探针主源码
├── Makefile / control / *.plist Theos 工程文件
├── .github/workflows/build.yml  CI：macos-latest + Theos + ldid
├── tools/                       静态审计 + 崩溃报告解析
├── docs/rules-spec.md           v0.3 规则引擎设计（tab 移除的两种路径）
└── README.md
```

推送走 **GitHub Desktop 手动操作**，工程内不带任何上传脚本。
`.gitignore` 已排除 `.theos/`、`obj/`、`packages/`、`build.log`、`*.dylib`。
