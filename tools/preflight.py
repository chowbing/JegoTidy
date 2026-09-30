"""推送前一次性跑完全部静态预检，并且**先自证检查器本身没瞎**。

为什么要有自证这一步（2026-09-24 的教训）：
  调用点检查脚本 v1 因为正则写得过窄，漏掉了 `static void WFLog(NSString *fmt, ...)`
  这类可变参数定义，于是它本该抓到的"调用早于定义"一次都没报 —— 但每次都打印 OK。
  一个对坏文件也说 OK 的检查器，比没有检查器更糟：它给的是**虚假信心**。
  所以本脚本先拿一份故意写坏的文件喂给每个检查器，**必须报错才算通过**，
  再用真文件跑一遍。

用法：
    python preflight.py [Tweak.xm]
退出码 0 = 全部通过（含自证）；1 = 有真问题或检查器失灵。
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
# 默认目标 = 工程根目录下的 Tweak.xm（相对本脚本自身定位，不写死任何绝对路径）
DEFAULT = os.path.normpath(os.path.join(HERE, os.pardir, "Tweak.xm"))

# 故意写坏的样本，每份只针对一个检查器的一条规则
BAD_OBJCPP = """\
static void f(void) {
    IMP orig = (IMP)0;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"k"] = [NSValue valueWithPointer:orig];
}
"""
BAD_VOLATILE = """\
static volatile const char *gS = "x";
static void f(void) {
    NSString *a = [NSString stringWithUTF8String:gS];
}
"""
BAD_AUDIT = """\
static void caller(void) {
    later(1);
}
static void later(int x) {
    (void)x;
}
"""
BAD_PAIRS = """\
static void f(void) {
    if (1) {
}
"""
# v3 新增：全局变量引用早于定义（我同一轮踩了两次）
BAD_GLOBAL = """\
static void user(void) {
    gFlag = YES;
}
static BOOL gFlag = NO;
"""
# v3 新增：递归 block 缺 __block
BAD_RECUR_BLOCK = """\
static void f(void) {
    void (^step)(void) = ^{
        step();
    };
}
"""

SELF_TESTS = [
    ("objcpp.py", BAD_OBJCPP, "A 函数指针→void*"),
    ("objcpp.py", BAD_VOLATILE, "D volatile 限定符被丢弃"),
    ("audit.py", BAD_AUDIT, "调用点早于定义"),
    ("audit.py", BAD_GLOBAL, "全局引用早于定义"),
    ("audit.py", BAD_RECUR_BLOCK, "递归 block 缺 __block"),
    ("chk.py", BAD_PAIRS, "括号"),
]


def run(script, target):
    r = subprocess.run([PY, os.path.join(HERE, script), target],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.isfile(target):
        print("找不到目标文件：%s" % target)
        return 1

    print("=" * 62)
    print("第 0 步：自证检查器（用故意写坏的文件，必须报错）")
    print("=" * 62)
    blind = []
    tmpdir = tempfile.mkdtemp(prefix="preflight_")
    for script, bad_src, what in SELF_TESTS:
        bad_path = os.path.join(tmpdir, "bad_" + script.replace(".py", ".m"))
        with open(bad_path, "w", encoding="utf-8") as fh:
            fh.write(bad_src)
        code, out = run(script, bad_path)
        if code == 0:
            blind.append((script, what))
            print("  [失灵] %-12s 对坏样本仍返回 0 —— 它抓不到「%s」" % (script, what))
        else:
            first = [l for l in out.splitlines() if l.strip()][:1]
            print("  [OK]   %-12s 已抓到「%s」%s"
                  % (script, what, (" | " + first[0][:70]) if first else ""))
    if blind:
        print("\n检查器失灵，先修检查器，不要看真文件的结果。")
        return 1

    print()
    print("=" * 62)
    print("第 1 步：对 %s 跑全部预检" % os.path.basename(target))
    print("=" * 62)
    failed = []
    for script in ("chk.py", "audit.py", "strchk.py", "objcpp.py"):
        code, out = run(script, target)
        tag = "PASS" if code == 0 else "FAIL"
        print("\n----- %s [%s] -----" % (script, tag))
        for line in out.splitlines():
            print("  " + line)
        if code != 0:
            failed.append(script)

    print()
    if failed:
        print("结果：不通过 -> %s" % ", ".join(failed))
        print("不要推送。clang 停在第一个硬错误，修完一个不代表只剩一个 —— 修完再跑一遍本脚本。")
        return 1
    print("结果：四项全过（objcpp 的 C 类提示仅供参考，不影响判定）。可以推送。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
