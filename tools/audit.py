"""引用早于定义检查（Tweak.xm 按 Objective-C++ 编译，隐式声明是硬 error）。

三条检查，都是"在 Objective-C 里能过、在 Objective-C++ 里必挂"的同一类问题：

  A. **调用点早于定义/声明** —— 函数名。
  B. **引用早于定义** —— `static` 全局变量（本文件约定全局以 `g[A-Z]` 命名）。
     实测踩过：新写的全局定义在文件后半，而前半的某个函数已经在用它。clang 报
     `use of undeclared identifier`，**硬 error**，一轮 CI 直接报废。
  C. **递归 block 缺少 `__block`** —— `void (^step)(void) = ^{ … step(); … };`
     clang 报 `variable 'step' is uninitialized when captured by block`。
     又是一个硬 error，而且只在"块里调自己"时才出现，肉眼极难发现。

为什么必须机器检查：这三条的共同点是**改动本身看起来完全正确**，
错误只在编译期暴露，而本项目本地没有 macOS —— 代价是一整轮 CI + 一次真机安装。

v2 修：
  v1 用一条复杂正则同时匹配"类型 + 可选模板段 + 函数名"（含 `[^>]*` 贪婪段），
  实测会漏检 —— 例如 `static void WFLog(NSString *fmt, ...) {` 这类**可变参数**定义，
  以及 `WFInstallCrashHandlers()` 里对 `WFLog`（定义在其后）的调用没被报出来。
  而"调用点早于定义"正是它存在的唯一理由，漏检等于没有。
v2 改用更硬的信号：**顶层定义/声明一定从第 0 列开始**（本文件风格如此），
  于是只需一条简单行首正则；再把行内注释与字符串字面量清掉，避免文案里的名字被当调用。
v3（2026-09-24 增）：加上 B、C 两条。
"""
import os
import re
import sys

# 默认目标 = 工程根目录下的 Tweak.xm（相对本脚本自身定位，不写死任何绝对路径，
# 这样工程改名 / 换盘符 / 换机器都不用动这里）
DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "Tweak.xm"))

DEF_RE = re.compile(r'^(?:static\s+|__attribute__\(\(unused\)\)\s+)*[\w][\w \t\*<>,\[\]]*?\b(\w+)\s*\(')
CALL_RE = re.compile(r'(?<![\w.\]:>])\b(\w+)\s*\(')
SKIP = {
    'if', 'for', 'while', 'switch', 'return', 'sizeof', 'typeof', 'do', 'else',
    'defined', 'strcmp', 'memcpy', 'memset', 'snprintf', 'strlcpy', 'strlen',
}

# B: 顶层 static 全局。本文件约定全局名以 g + 大写字母开头（gDiag / gNotifPostTally …）。
GDEF_RE = re.compile(r'^(?:static\s+)?(?:const\s+)?(?:[\w:]+[\s\*]+)+?(g[A-Z]\w*)\s*(?:=|;|\[|\))')

# C: block 变量声明赋值，形如 `__block void (^name)(void) = ^{` 或 `BOOL (^name)(void) = ^BOOL{`
BLOCK_DECL_RE = re.compile(r'^\s*(__block\s+)?[\w<>*]+\s*\(\s*\^\s*(\w+)\s*\)\s*\([^)]*\)\s*=\s*\^')


def strip_code(L):
    """清掉行内注释与字符串字面量，只留可执行代码。"""
    code = re.sub(r'//.*$', '', L)
    code = re.sub(r'@?"(?:[^"\\]|\\.)*"', '""', code)
    code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)
    return code


def scan_block_end(lines, start):
    """从 start 行（含）起按花括号配平找 block 结束行。返回行下标（0 基）。"""
    depth = 0
    for i in range(start, len(lines)):
        code = strip_code(lines[i])
        depth += code.count('{') - code.count('}')
        if i > start and depth <= 0:
            return i
        if i == start and depth <= 0:
            return i          # 声明行没有 {（罕见），当空块处理
    return len(lines) - 1


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    lines = open(path, encoding='utf-8').read().split('\n')

    # ---------- A: 函数定义位置 ----------
    defs = {}
    for i, L in enumerate(lines, 1):
        if not L or L[0] in ' \t/}#':
            continue
        m = DEF_RE.match(L)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i

    # ---------- B: 全局变量定义位置 ----------
    gdefs = {}
    for i, L in enumerate(lines, 1):
        if not L or L[0] in ' \t/}#':
            continue
        m = GDEF_RE.match(L)
        if m and m.group(1) not in gdefs:
            gdefs[m.group(1)] = i
    # 一次性编译成 alternation，避免 7000 行 × 几十个全局的重复搜索
    gref = None
    if gdefs:
        gref = re.compile(r'(?<![\w.>])(' + '|'.join(sorted(gdefs, key=len, reverse=True)) + r')\b')

    # ---------- C: 递归 block ----------
    blocks = []
    for idx, L in enumerate(lines):
        m = BLOCK_DECL_RE.match(L)
        if m:
            blocks.append((idx, m.group(2), bool(m.group(1))))

    problems_a, problems_b, problems_c = [], [], []

    for i, L in enumerate(lines, 1):
        s = L.strip()
        if not s or s.startswith('//') or s.startswith('*') or s.startswith('/*'):
            continue
        code = strip_code(L)
        if L[:1] not in (' ', '\t') and DEF_RE.match(L):
            code_a = ''       # 顶层定义行自身，不查 A
        else:
            code_a = code
        for m in CALL_RE.finditer(code_a):
            n = m.group(1)
            if n in SKIP:
                continue
            if n in defs and defs[n] > i:
                problems_a.append((i, n, defs[n], s[:110]))
        # B
        if gref:
            for m in gref.finditer(code):
                n = m.group(1)
                if gdefs.get(n, 0) > i:
                    problems_b.append((i, n, gdefs[n], s[:110]))

    # C：递归 block 必须在声明行写 __block
    for idx, name, has_block_kw in blocks:
        if has_block_kw:
            continue
        end = scan_block_end(lines, idx)
        body = '\n'.join(strip_code(x) for x in lines[idx + 1:end + 1])
        if re.search(r'(?<![\w.>])' + re.escape(name) + r'\s*\(', body):
            problems_c.append((idx + 1, name, lines[idx].strip()[:110]))

    failed = False
    if problems_a:
        failed = True
        print("=== A. 调用点早于定义/声明（ObjC++ 下会报隐式声明 / 无匹配函数）===")
        for i, n, d, s in problems_a:
            print("  line %-5d calls %-30s (first decl line %d) | %s" % (i, n, d, s))
    if problems_b:
        failed = True
        print("=== B. 全局变量引用早于定义（ObjC++ 下 use of undeclared identifier，硬 error）===")
        for i, n, d, s in problems_b:
            print("  line %-5d uses  %-30s (defined at line %d) | %s" % (i, n, d, s))
        print("  修法：把 `static` 定义上移到第一个引用点之前（通常放在同一族的其它全局旁边）。")
    if problems_c:
        failed = True
        print("=== C. 递归 block 缺少 __block（ObjC++ 下 uninitialized when captured by block）===")
        for i, n, s in problems_c:
            print("  line %-5d block %-24s 在块内调用了自己，声明必须写 `__block` | %s" % (i, n, s))
        print("  修法：`__block void (^name)(void) = ^{ … name(); … };`")

    if failed:
        sys.exit(1)
    print("OK: 被调函数 / 全局变量 / 递归 block 三项均无'引用早于定义'问题")


if __name__ == '__main__':
    main()
