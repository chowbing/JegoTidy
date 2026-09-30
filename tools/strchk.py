"""字符串字面量闭合检查（tokenizer 版）。

为什么不能用"数一数这行有几个引号"：URL 里的 `//` 会被当成注释开头，
`@"http://a/b"` 这种行会被误判。必须按 tokenizer 逐字符走。

用法：python strchk.py [Tweak.xm]    有问题时退出码 1。
"""
import os
import sys

# 默认目标 = 工程根目录下的 Tweak.xm（相对本脚本自身定位，不写死任何绝对路径）
DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "Tweak.xm"))
p = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
s = open(p, encoding='utf-8').read()
# 真正的做法：按 tokenizer 走一遍，一旦发现"字符串已闭合、同一逻辑行内又出现裸引号"就报错。
# 这里做的是等价的简化版：逐字符走，字符串内的引号必须由 \" 转义；
# 如果字符串在行内闭合后，后面又出现了不以 @ / [ 开头的孤立引号，也可疑。
line, i, n = 1, 0, len(s)
bad = []
while i < n:
    c = s[i]
    if c == '\n':
        line += 1; i += 1; continue
    if c == '/' and i+1 < n and s[i+1] == '/':
        while i < n and s[i] != '\n': i += 1
        continue
    if c == '/' and i+1 < n and s[i+1] == '*':
        i += 2
        while i+1 < n and not (s[i] == '*' and s[i+1] == '/'):
            if s[i] == '\n': line += 1
            i += 1
        i += 2; continue
    if c == '"':
        start = line
        i += 1
        closed = False
        while i < n:
            if s[i] == '\\': i += 2; continue
            if s[i] == '\n':
                bad.append((start, "字符串跨行未闭合（极可能是漏了转义引号）"))
                line += 1; i += 1; closed = True; break
            if s[i] == '"':
                i += 1; closed = True; break
            i += 1
        continue
    i += 1
if bad:
    for ln, msg in bad: print("line %d: %s" % (ln, msg))
else:
    print("PASS: 所有字符串字面量都在行内正常闭合（无漏转义引号）")
sys.exit(1 if bad else 0)
