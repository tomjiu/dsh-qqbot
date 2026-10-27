"""把 clickableLink 改成「非 TTY 时输出纯 URL」。

为什么需要：容器日志不是终端，OSC 8 超链接（ESC ] 8 ; ; URL ESC \\）会原样
留在日志里变成乱码：
    ^[]8;;https://q.qq.com/...^[\https://q.qq.com/...^[]8;;^[\

为什么用正则而不是字面量替换：源文件里写的是 \\u001b 这种转义，
运行时才是真实字节，字面量对不上（上一版就是这么失败的）。
"""
import re
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    text = fh.read()

pattern = re.compile(
    r'export function clickableLink\(url\) \{\s*'
    r'return `[^`]*`;\s*'
    r'\}',
)

# 用函数式替换：replacement 里含反斜杠，subn 的字符串模板会把 \\u 当转义解析炸掉
def build(match):
    return (
        'export function clickableLink(url) {\n'
        '    // 容器日志不是终端，OSC 8 超链接会变成乱码\n'
        '    if (!process.stdout.isTTY)\n'
        '        return String(url);\n'
        '    return `\\u001b]8;;${url}\\u001b\\\\${url}\\u001b]8;;\\u001b\\\\`;\n'
        '}'
    )

new_text, count = pattern.subn(build, text)
if count == 0:
    print('WARN: clickableLink 未匹配，跳过（上游可能已修）')
    sys.exit(0)

with open(path, 'w', encoding='utf-8') as fh:
    fh.write(new_text)
print(f'patched: clickableLink -> plain URL when not a TTY ({count} 处)')