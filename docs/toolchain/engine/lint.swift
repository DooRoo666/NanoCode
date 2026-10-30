#!/usr/bin/env python3
"""
Swift 源码静态检查 —— 在编译前拦截会导致闪退/黑屏的写法。

背景：iOS 前台 app 必须走 UIApplicationMain 建 runloop。
顶层 print() 编出来的是终端程序，装上去必然闪退或黑屏。
这是实测踩过的坑（HelloSwift 黑屏事件），必须前置拦截。
"""
import re
import sys

RULES = [
    # (规则ID, 严重度, 正则, 说明, 修复建议)
    (
        "NO_UI_ENTRY", "error",
        r"UIApplicationMain",
        None,  # 特殊处理：要求存在
        "必须有 UIApplicationMain(...) 作为程序入口",
    ),
    (
        "TOP_LEVEL_PRINT", "error",
        r"^print\s*\(",
        "顶层 print() 会编出终端程序，装到手机上闪退或黑屏",
        "删掉顶层 print，改成在 AppDelegate 里往 UILabel 显示",
    ),
    (
        "NO_APPDELEGATE", "warn",
        r"UIApplicationDelegate",
        "没有 AppDelegate 通常意味着没有窗口，界面会是黑的",
        "实现 class AppDelegate: UIResponder, UIApplicationDelegate",
    ),
    (
        "NO_WINDOW", "warn",
        r"UIWindow\s*\(",
        "没有创建 UIWindow，app 起来后没有窗口承载界面",
        "在 didFinishLaunching 里创建 UIWindow 并设置 rootViewController",
    ),
    (
        "IMPORT_FOUNDATION_ONLY", "warn",
        r"^import\s+Foundation\s*$",
        "只导入 Foundation 时若用到 UIKit 类型会编译失败",
        "需要界面请 import UIKit",
    ),
    (
        "OBJC_IN_BLOCK", "warn",
        r"\{\s*\[\s*weak\s+self\s*\]",
        "weak self 需要 Objective-C 运行时支持，设备内编译需确认可用",
        "优先用 unowned self 或显式捕获",
    ),
]


def check(source, path="<stdin>"):
    issues = []
    lines = source.splitlines()

    # ---- 入口检查（最关键）----
    if not re.search(r"\bUIApplicationMain\s*\(", source):
        issues.append((
            "error", 1, "NO_UI_ENTRY",
            "没有找到 UIApplicationMain —— 这不是一个可运行的 iOS 图形程序",
            "Swift 顶层代码会编成命令行程序，安装后闪退或黑屏。\n"
            "   请加上：\n"
            "     UIApplicationMain(\n"
            "         CommandLine.argc,\n"
            "         CommandLine.unsafeArgv,\n"
            "         nil,\n"
            "         NSStringFromClass(AppDelegate.self)\n"
            "     )",
        ))

    # ---- 顶层语句检查 ----
    for idx, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        if re.match(r"^print\s*\(", stripped):
            issues.append((
                "error", idx, "TOP_LEVEL_PRINT",
                f"顶层 print()：{stripped[:50]}",
                "终端程序才会用 print 做输出。改用 UILabel 显示内容。",
            ))

    # ---- 结构建议 ----
    if not re.search(r"UIApplicationDelegate", source):
        issues.append((
            "warn", 1, "NO_APPDELEGATE",
            "没有 UIApplicationDelegate 实现",
            "没有 AppDelegate 通常意味着没有窗口，界面会是黑的。",
        ))

    if not re.search(r"UIWindow\s*\(", source):
        issues.append((
            "warn", 1, "NO_WINDOW",
            "没有创建 UIWindow",
            "在 didFinishLaunching 里创建 window 并设置 rootViewController。",
        ))

    if re.search(r"^import\s+UIKit\s*$", source, re.M) is None and \
       re.search(r"\bUI[A-Z]\w+", source):
        issues.append((
            "warn", 1, "MISSING_UIKIT_IMPORT",
            "用到了 UIKit 类型但没有 import UIKit",
            "在文件开头加 import UIKit",
        ))

    return issues


def main():
    if len(sys.argv) < 2:
        print("用法: lint.swift <file.swift>")
        return 2
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        src = f.read()

    issues = check(src, path)
    errors = [i for i in issues if i[0] == "error"]
    warns = [i for i in issues if i[0] == "warn"]

    if not issues:
        print("✓ 源码检查通过，可以编译")
        return 0

    for sev, line, rule, msg, fix in issues:
        mark = "✗" if sev == "error" else "!"
        print(f"{mark} [{rule}] 第 {line} 行: {msg}")
        if fix:
            print(f"    → {fix}")

    print()
    if errors:
        print(f"发现 {len(errors)} 个致命问题、{len(warns)} 个提示 —— 已阻止编译")
        return 1
    print(f"{len(warns)} 个提示，不影响编译")
    return 0


if __name__ == "__main__":
    sys.exit(main())
