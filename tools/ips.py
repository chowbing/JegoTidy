"""解析 iOS 15+ 的 .ips 崩溃报告，按"人读得懂"的顺序打印。

为什么要单独写一个：`.ips` **不是一个 JSON 文件**，是**两个** ——
  第 1 行：小 header（app_name / bundleID / bug_type / os_version / app_version）
  第 2..N 行：body（usedImages / threads / exception / asi / lastExceptionBacktrace）
直接 json.load 整个文件会失败。必须按第一个换行切开分别解析。

用法：
    python ips.py path/to/xxx.ips
    python ips.py path/to/xxx.ips --all      # 连非触发线程一起打
输出顺序刻意按"决定下一步要看什么"排：
  异常类型 → 是不是我们的 dylib → **故障线程判定（栈溢出 / 野指针）** → 本库帧分布
  → 启动到崩溃的时间差 → 完整帧链（imageIndex 已解析成名字）

为什么"栈溢出"要单独判、而且要排在前面：无限递归的**故障帧**跟普通野指针崩溃长得
一模一样（都是 CFAllocatorAllocate / objc_retain），唯一可靠特征是"帧数异常多 +
同一符号重复上百次"。只盯着故障帧会把递归误诊成"某个对象坏了"，然后去查一个根本
没问题的指针。而且递归崩溃的"本库帧分布"会有几百行，会把这个结论淹掉，所以判定
必须排在它前面。
"""
import json
import io
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    show_all = "--all" in sys.argv

    raw = io.open(path, encoding="utf-8", errors="replace").read()
    lines = raw.split("\n")
    hdr = json.loads(lines[0])
    body = json.loads("\n".join(lines[1:]))

    imgs = body.get("usedImages", [])

    def imgname(i):
        try:
            im = imgs[i]
            return im.get("name") or im.get("path", "?").split("/")[-1]
        except Exception:
            return "?"

    print("== 头部 ==")
    for k in ("app_name", "app_version", "build_version", "bundleID", "os_version", "bug_type"):
        if k in hdr:
            print("  %-14s %s" % (k, hdr[k]))
    for k in ("procLaunch", "captureTime", "faultingThread"):
        if k in body:
            print("  %-14s %s" % (k, body[k]))
    print("  exception     %s" % body.get("exception"))
    print("  asi           %s" % body.get("asi"))
    if body.get("termination"):
        print("  termination   %s" % body["termination"])
    print("  lastExceptionBacktrace: %s" % ("有（先看这个）" if body.get("lastExceptionBacktrace") else "无"))

    # 哪些 loaded image 是"注入进 App bundle 的 dylib"（而不是系统库）。
    # 判据：路径在 /Bundle/Application/ 下、以 .dylib 结尾、且不在 /usr/lib 或 /System 下。
    tweaks = []
    for im in imgs:
        p = im.get("path", "")
        if not p.lower().endswith(".dylib"):
            continue
        if "/usr/lib" in p or "/System/" in p or "/preboot/" in p:
            continue
        tweaks.append(im.get("name") or p.split("/")[-1])
    print("  注入的 dylib: %s" % (", ".join(tweaks) if tweaks else "（无 —— tweak 可能没被加载）"))

    # ★ 故障线程的判定放**最前面**，而且先判栈溢出。
    # 顺序很重要：下面"本库帧分布"在递归崩溃里会打出几百行，
    # 把真正的结论淹掉 —— 而结论恰恰是最需要第一眼看到的。
    ft = body.get("faultingThread")
    fth = body["threads"][ft] if isinstance(ft, int) and ft < len(body.get("threads", [])) else None
    is_overflow = False
    if fth and fth.get("frames"):
        fr_all = fth["frames"]
        syms = [f.get("symbol") or ("sub_%s" % f.get("imageOffset")) for f in fr_all]
        counts = {}
        for s in syms:
            counts[s] = counts.get(s, 0) + 1
        top = sorted(counts.items(), key=lambda kv: -kv[1])[:3]
        is_overflow = len(fr_all) >= 150 or (top and top[0][1] >= 40)

        # ★ 栈溢出（无限递归）的判定。
        # 为什么必须单独判：它的**故障帧**长得跟普通野指针崩溃一模一样
        # （CFAllocatorAllocate / objc_retain），唯一可靠的特征是"帧数异常多 + 同一符号重复上百次"。
        # 只看故障帧会把无限递归误诊成"某个对象坏了"，然后去查一个根本没问题的指针。
        # 2026-09-30 实测：主线程 511 帧，两组帧交替 200+ 次。
        if is_overflow:
            print("  ★★ 疑似**栈溢出 / 无限递归**（不是野指针！）：")
            print("     故障线程共 %d 帧，重复最多的符号：" % len(fr_all))
            for s, c in top:
                print("       %-52s ×%d" % (s, c))
            print("     → 判据：帧数异常多 + 同一符号重复几十上百次。")
            print("       先找**互相调用**的两个符号（通常一个是你的库、一个是系统库），")
            print("       而不是去查故障帧里那个 CFAllocatorAllocate —— 那只是栈已经用完时")
            print("       恰好要分配内存而已。共享 shim + [super] 派发是典型成因。")

        # 指针类崩溃：objc_retain/objc_release 做故障帧 = 有东西被当成对象用了。
        s0 = fr_all[0].get("symbol") or ""
        if (not is_overflow) and ("objc_retain" in s0 or "objc_release" in s0
                                 or "objc_storeStrong" in s0):
            print("  ★ 故障帧是 %s —— 这是**指针问题，不是逻辑问题**：" % s0)
            print("    有东西被当成对象 retain/release 了。小地址（如 0x20）说明它不是对象。")
            print("    ★ 注意：objc_retainAutoreleasedReturnValue 会**尾调用** objc_retain，")
            print("      它自己的帧会被省掉 —— 所以直接调用者看起来像 block/叶子帧，")
            print("      真正出问题的那行表达式在**更上层**（通常是被调函数里）。")
            print("      exception=%s" % (body.get("exception") or {}))

    # ★ 本库帧在**全部线程**里的分布。
    # 为什么看这个：如果全进程只有一帧是我们的，而且不在你以为的那个函数里，
    # 那这次崩溃**就不是你正在做的功能**引起的 —— 很多轮误诊都栽在这一点上。
    # 递归崩溃里这个列表可能有几百条，所以只打前 12 条 + 显式说明省略了多少条
    # （绝不静默截断：看不到的部分必须能从输出里看出来）。
    our = set()
    for im in imgs:
        p = (im.get("path") or "").lower()
        if p.endswith(".dylib") and "/usr/lib" not in p and "/system/" not in p and "/preboot/" not in p:
            our.add(im.get("name") or p.split("/")[-1])
    hits = []
    for ti, th in enumerate(body.get("threads", [])):
        for fi, f in enumerate(th.get("frames", [])):
            if imgname(f.get("imageIndex")) in our:
                hits.append((ti, th.get("queue"), bool(th.get("triggered")), fi,
                             f.get("symbol") or ("sub_%s" % f.get("imageOffset"))))
    if hits:
        SHOW = 12
        print("  本库帧共 %d 处（全部线程）%s:"
              % (len(hits), "，下面只列前 %d 处" % SHOW if len(hits) > SHOW else ""))
        for ti, q, trg, fi, sym in hits[:SHOW]:
            print("    thread %-3d %-28s triggered=%-5s #%-2d %s" % (ti, q, trg, fi, sym))
        if len(hits) > SHOW:
            print("    …（另有 %d 处未列出；递归崩溃里这个数字本身就是证据）"
                  % (len(hits) - SHOW))
    else:
        print("  本库帧: 0 处 —— 你的代码在栈上，但没有任何一帧被命名")

    # 启动到崩溃的时间差：<5s 说明死在启动路径（%ctor / +load / dyld init）
    try:
        from datetime import datetime

        def parse(t):
            for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
                try:
                    return datetime.strptime(t.strip(), fmt)
                except ValueError:
                    continue
            raise ValueError(t)

        d = (parse(body["captureTime"]) - parse(body["procLaunch"])).total_seconds()
        print("  启动→崩溃      %.2f 秒%s" % (d, "   ← 死在启动路径！优先查 %ctor / +load" if d < 5 else ""))
    except Exception as e:
        print("  启动→崩溃      (时间解析失败: %s)" % e)

    # 先打 lastExceptionBacktrace（如果有）
    if body.get("lastExceptionBacktrace"):
        print()
        print("== lastExceptionBacktrace（ObjC 异常自己的栈）==")
        for fi, f in enumerate(body["lastExceptionBacktrace"]):
            sym = f.get("symbol") or ("sub_%s" % f.get("imageOffset"))
            print("  #%-3d %-46s [%s]" % (fi, sym, imgname(f.get("imageIndex"))))

    for ti, th in enumerate(body.get("threads", [])):
        triggered = th.get("triggered")
        if not triggered and not show_all and ti != body.get("faultingThread", 0):
            continue
        fr = th.get("frames", [])
        print()
        print("== 线程 %d  queue=%s  triggered=%s  共 %d 帧 ==" % (ti, th.get("queue"), triggered, len(fr)))
        for fi, f in enumerate(fr):
            sym = f.get("symbol") or ("sub_%s" % f.get("imageOffset"))
            off = f.get("symbolLocation")
            extra = "  [%s]" % imgname(f.get("imageIndex")) if f.get("imageIndex") is not None else ""
            if off is not None:
                extra += " +%d" % off
            print("  #%-3d %-46s%s" % (fi, sym, extra))
        print("  ---- 提示：从下往上读；第一个出现你自己库名的帧就是答案 ----")
    return 0


if __name__ == "__main__":
    sys.exit(main())
