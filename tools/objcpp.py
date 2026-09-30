"""Objective-C++ 类型陷阱扫描（Tweak.xm 以 `clang++ -x objective-c++` 编译）。

为什么需要单独一份：`chk.py`（括号/引号配对）与 `audit.py`（调用点早于定义）都是**结构**检查，
抓不到"在 Objective-C 里合法、在 Objective-C++ 里是硬 error"的那一类。这类错每次都要烧掉
一轮 CI（2026-09-24 就因此挂了一次）。

目前覆盖五类已实际踩过的坑：
  A. 函数指针 ↔ void* 的隐式转换
     `[NSValue valueWithPointer:orig]` 其中 orig 是 IMP → C++ 不允许函数指针隐式转 const void*。
  B. `getResourceValue:&x` 这类 out id* 参数（ARC 下走 pass-by-writeback，ObjC++ 更容易踩）。
  C. 条件表达式里混 nil / Nil 与对象指针（`cond ? objExpr : nil`）。
  D. `volatile const char *` 传进**有类型**的形参（如 `stringWithUTF8String:`）：
     丢掉 volatile 限定符在 C++ 里是 ill-formed。传进 `...` 可变参数（%s）反而没事 ——
     所以这个坑只在"有类型形参"处爆，很隐蔽。
  E. **标量 → 对象指针**的强转，ARC 下是硬 error（2026-09-30 真机 CI 实测）：
       Class c = (Class)(uintptr_t)key.unsignedLongLongValue;
       error: cast of 'uintptr_t' (aka 'unsigned long') to 'Class' is disallowed with ARC
     这一类几乎总是"为了把对象指针塞进 NSDictionary 而当键"折腾出来的。
     正确做法是**别做这个往返** —— 用 C 结构体数组存（见 Tweak.xm 第 3c 节）。
     ★ 这条是补写的：当时 preflight 四项全过，错误是 CI 才报出来的 ——
       一个对已知坏样本说 OK 的检查器给的是虚假信心，所以必须连自证样本一起补。

用法：python objcpp.py [Tweak.xm]    A/B/D/E 类有问题时退出码 1；C 类仅提示。
"""
import os
import re
import sys

# 默认目标 = 工程根目录下的 Tweak.xm（相对本脚本自身定位，不写死任何绝对路径，
# 这样工程改名 / 换盘符 / 换机器都不用动这里）
DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "Tweak.xm"))

# 形参是**有类型**的 `const char *`（而非可变参数）的 API —— 传 volatile 指针给它们在 C++ 里
# 会因丢弃 volatile 限定符而编译失败。白名单只收真正会踩到的，宁可少报也不误报。
TYPED_CSTR_APIS = [
    'stringWithUTF8String',
    'stringWithCString',
    'initWithUTF8String',
    'initWithCString',
    'stringWithFileSystemRepresentation',
    'strlen', 'strcmp', 'strncmp', 'strcpy', 'strncpy', 'strdup', 'strstr',
    'fopen', 'open', 'stat', 'access', 'unlink',
]

# E 类：C 标量类型名。出现在 `(对象指针类型)(标量类型)` 里就是 ARC 硬 error。
SCALAR_TYPES = [
    'uintptr_t', 'intptr_t', 'NSUInteger', 'NSInteger', 'size_t', 'ptrdiff_t',
    'unsigned long long', 'unsigned long', 'long long', 'long',
    'unsigned int', 'unsigned short', 'unsigned char', 'signed char',
    'int', 'short', 'char', 'BOOL', 'CGFloat', 'float', 'double',
]
# E 类：对象指针类型（Class / id / Protocol / 任意 `Xxx *`）
OBJ_PTR_TYPE = r'(?:Class|id|Protocol|(?:[A-Za-z_]\w*)\s*\*)'
_RE_E_ARC_CAST = re.compile(
    r'\(\s*' + OBJ_PTR_TYPE + r'\s*\)\s*\(\s*'
    + r'(?:' + '|'.join(re.escape(t) for t in SCALAR_TYPES) + r')\s*\)'
)


def strip_noise(line):
    line = re.sub(r'//.*$', '', line)
    line = re.sub(r'@?"(?:[^"\\]|\\.)*"', '""', line)
    return line


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    lines = open(path, encoding='utf-8').read().split('\n')

    # A. 收集声明为函数指针类型的变量名（IMP / SEL 不算，IMP 是函数指针）
    funcptr_vars = set()
    # D. 收集声明为 volatile 的变量名（任何类型；重点是指针）
    volatile_vars = set()
    for L in lines:
        code = strip_noise(L)
        for m in re.finditer(r'\bIMP\s+(\w+)\s*[=;]', code):
            funcptr_vars.add(m.group(1))
        for m in re.finditer(r'\bvolatile\b[^=;()]*?\b(\w+)\s*(?:=[^;]*)?;', code):
            volatile_vars.add(m.group(1))

    problems = []
    notes = []
    for i, L in enumerate(lines, 1):
        code = strip_noise(L)
        s = L.strip()

        # A. valueWithPointer: 直接传函数指针变量，且没有强转
        for m in re.finditer(r'valueWithPointer\s*:\s*([A-Za-z_]\w*)', code):
            name = m.group(1)
            if name in funcptr_vars:
                problems.append((i, 'A 函数指针→void*', s,
                                 '改为 [NSValue valueWithPointer:(const void *)%s]' % name))

        # B. getResourceValue: / getPromisedItemResourceValue: 的 out id*
        if re.search(r'\bget(?:PromisedItem)?ResourceValue\s*:\s*&', code):
            problems.append((i, 'B out id* 参数', s,
                             'ARC pass-by-writeback，改用 fileExistsAtPath:isDirectory:'))

        # D. volatile 变量传进**已知有类型形参**的 API（不是可变参数）。
        #    判定必须精确：`%s` 这类可变参数传 volatile 指针完全合法，若一律报错就是误报，
        #    而一个会误报的 FAIL 级检查会训练人忽略它 —— 比没有更差。
        #    所以只认一份"形参确实是 const char *"的 API 白名单。
        for name in volatile_vars:
            for api in TYPED_CSTR_APIS:
                pat = re.escape(api) + r'\s*:?\s*\(?\s*([A-Za-z_]\w*)\s*[\)\];,]'
                for m in re.finditer(pat, code):
                    if m.group(1) != name:
                        continue
                    pre = code[:m.start()]
                    if re.search(r'\(\s*(?:const\s+)?(?:char|void|unsigned\s+char)\s*\*\s*\)\s*$', pre):
                        continue          # 已显式强转
                    problems.append((i, 'D volatile 限定符被丢弃', s,
                                     '%s 的形参是 const char*，传 volatile 指针在 C++ 里是硬 error；'
                                     '改用 WFStageText() 这类收口函数，或显式 (const char *)%s'
                                     % (api, name)))

        # E. 标量 → 对象指针 的强转（ARC 下是硬 error）
        #    `(Class)(uintptr_t)x` / `(id)(NSUInteger)x` / `(SomeType *)(intptr_t)x`
        #    → error: cast of 'uintptr_t' to 'Class' is disallowed with ARC
        #    只认"操作数**本身就是一个标量类型名**"这一种精确形态，零误报。
        #    （操作数是表达式的情形无法静态判定，宁可漏报也不误报 ——
        #      一个会误报的 FAIL 级检查会训练人忽略它，比没有更差。）
        m = _RE_E_ARC_CAST.search(code)
        if m:
            problems.append((i, 'E 标量→对象指针（ARC 禁止）', s,
                             'ARC 不允许整数→对象指针强转。不要做这个往返：'
                             '把 Class 存进 NSDictionary 就得这么转 → 改用 C 结构体数组存'
                             '（见 Tweak.xm 第 3c 节 JTBaseIMPTable）'))

        # C. 三元里混 nil / Nil（仅提示）
        if re.search(r'\?[^?;]*:\s*(?:nil|Nil)\b', code):
            notes.append((i, 'C 三元混 nil', s))
    if problems:
        print("=== Objective-C++ 类型陷阱（Objective-C 下合法，ObjC++ 下是硬 error）===")
        for i, kind, s, fix in problems:
            print("  line %-5d [%s] %s" % (i, kind, s[:96]))
            print("            → %s" % fix)
        sys.exit(1)
    if notes:
        # C 类只是"值得复核"，不判失败：`cond ? (UIView *)x : nil` 两个分支能收敛到 UIView*，
        # 在 C++ 里合法（nullptr 可转任意对象指针），本文件已有两处这样写且长期编译通过。
        print("=== 提示（不判失败，仅建议复核）===")
        for i, kind, s in notes:
            print("  line %-5d [%s] %s" % (i, kind, s[:96]))
    print("OK: 未发现已知的 Objective-C++ 类型陷阱")


if __name__ == '__main__':
    main()
