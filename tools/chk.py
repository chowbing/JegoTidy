"""括号 / 引号 / 注释感知的配对检查。

朴素计数器会被字符串字面量与注释里的 `}` 骗过（例如 `@"if (a) { }"`），
所以这里逐字符走一遍，遇到 `//` `/* */` `"` `'` 就整体跳过。

用法：python chk.py [Tweak.xm]    不配对时退出码 1。
"""
import os
import sys

# 默认目标 = 工程根目录下的 Tweak.xm（相对本脚本自身定位，不写死任何绝对路径）
DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "Tweak.xm"))
p = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
s = open(p, encoding='utf-8').read()
stack = []
line = 1
i = 0
n = len(s)
pairs = {')':'(', ']':'[', '}':'{'}
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
        i += 2
        continue
    if c == '"' or c == "'":
        q = c; i += 1
        while i < n:
            if s[i] == '\\': i += 2; continue
            if s[i] == '\n': line += 1
            if s[i] == q: i += 1; break
            i += 1
        continue
    if c in '([{':
        stack.append((c, line))
    elif c in ')]}':
        if not stack:
            print("EXTRA CLOSE", c, "at line", line); sys.exit(1)
        o, ol = stack.pop()
        if o != pairs[c]:
            print("MISMATCH: open", o, "line", ol, "vs close", c, "line", line); sys.exit(1)
    i += 1
if stack:
    print("UNCLOSED:")
    for o, ol in stack[-20:]:
        print("  ", o, "line", ol)
    sys.exit(1)
print("PASS: all (), [], {} balanced")
