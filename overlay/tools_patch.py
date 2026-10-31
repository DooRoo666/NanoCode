#!/usr/bin/env python3
"""把 host_exec / codex_exec 真正接进 agent 工具链。

现状（实测）：两个工具的实现文件都在，但只被定义、从未注册：
  - makeAgentTools() 的数组里没有它们
  - ConcurrentTools 的 switch 里没有分支
  - SSEStream 走 default 兜底，被当成普通 shell 工具
结果：模型根本不知道有这两个工具。

本补丁幂等：已打过就跳过。
"""
import sys, pathlib

MARK = "nanoMuse-toolreg"

def patch(path, old, new, label):
    p = pathlib.Path(path)
    if not p.exists():
        print(f"  SKIP {label}: 文件不存在 {path}"); return False
    s = p.read_text(encoding="utf-8")
    if MARK in s and new.strip()[:40] in s:
        print(f"  OK   {label}: 已打过"); return False
    if old not in s:
        print(f"  FAIL {label}: 锚点没找到"); return False
    p.write_text(s.replace(old, new, 1), encoding="utf-8")
    print(f"  PATCH {label}"); return True

DEF = "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"
CONC = "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
SSE = "Agent/Chat/AIChatViewModel+SSEStream.swift"

def patch_schema(root):
    f = f"{root}/{DEF}"
    old = "        if includeMemoryTools {"
    new = '''        // nanoMuse-toolreg: 宿主层执行能力。这两个工具此前只被定义、从未注册，
        // 模型完全看不到它们。host_exec 走 posix_spawn + 随包 nsh，
        // codex_exec 走随包 codex-sign，都是无 fork 实现，iOS 沙盒下可用。
        if includeHostTools {
            tools.append(
                AgentToolDefinition(
                    name: NanoMuseHostShellTool.toolName,
                    description: "在 iOS 宿主进程外执行 shell 命令（nsh，无 iSH）。"
                        + "可用随包 helper：bash.real/ls/cat/grep/sed/xxd/tar 等。"
                        + "支持管道、重定向、&&、||、$VAR、$()、通配符、cd。"
                        + "不支持子 shell ( ) 和后台 & 。"
                        + "需要真正的 Linux 环境（apk/git/python）时改用 shell_execute。",
                    parameters: [
                        AgentToolParam(name: "command", type: .string,
                            description: "要执行的命令，例如 `ls -l /private/var/mobile/Documents`"),
                        AgentToolParam(name: "timeout", type: .number,
                            description: "超时秒数，默认 60"),
                    ]
                )
            )
            tools.append(
                AgentToolDefinition(
                    name: NanoMuseCodexTool.toolName,
                    description: "调用随包 Codex 编码代理，在指定工作区里读写文件、执行命令并返回结果。",
                    parameters: [
                        AgentToolParam(name: "prompt", type: .string,
                            description: "交给 Codex 的任务，尽量具体"),
                        AgentToolParam(name: "workspace", type: .string,
                            description: "允许操作的工作目录绝对路径"),
                        AgentToolParam(name: "timeout", type: .number,
                            description: "超时秒数，默认 900"),
                    ]
                )
            )
        }
        if includeMemoryTools {'''
    return patch(f, old, new, "schema 注册")

def patch_switch(root):
    f = f"{root}/{CONC}"
    old = '        case "file_read":'
    new = '''        // nanoMuse-toolreg: 宿主工具执行分支。没有这段，host_exec/codex_exec
        // 会被 SSE 的 default 兜底当成普通 shell 工具，永远走不到真实实现。
        case NanoMuseHostShellTool.toolName:
            let cmd = tu.input["command"] as? String ?? ""
            let t = (tu.input["timeout"] as? Double) ?? 60
            let out = await NanoMuseHostShellTool.execute(command: cmd, timeout: t)
            toolOutput = out.text
            toolSuccess = out.exitCode == 0
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = out.text
            }
        case NanoMuseCodexTool.toolName:
            let prompt = tu.input["prompt"] as? String ?? ""
            let ws = tu.input["workspace"] as? String ?? "/root/work"
            let t = (tu.input["timeout"] as? Double) ?? 900
            let out = await NanoMuseCodexTool.execute(
                prompt: prompt, workspace: ws, timeout: t
            )
            toolOutput = out.text
            toolSuccess = out.exitCode == 0
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = out.text
            }
        case "file_read":'''
    return patch(f, old, new, "并发执行分支")

def patch_sse(root):
    f = f"{root}/{SSE}"
    ok = 0
    # 1) 工具卡片类型判定：default 会把宿主工具误判成普通 shell
    ok += patch(f,
        '                    case "shell_execute": .shellTool(command: "")',
        '''                    case "shell_execute": .shellTool(command: "")
                    // nanoMuse-toolreg: 宿主工具用 shellTool 卡片呈现，
                    // 但没有 command 参数可解析，标题走工具名本身。
                    case NanoMuseHostShellTool.toolName,
                         NanoMuseCodexTool.toolName: .shellTool(command: "")''',
        "SSE 卡片类型")
    return ok

def patch_flag(root):
    f = f"{root}/{DEF}"
    # makeAgentTools 的签名里加 includeHostTools 开关（默认开）
    import re, pathlib
    p = pathlib.Path(f)
    s = p.read_text()
    if "includeHostTools: Bool" in s:
        print("  OK   includeHostTools: 已存在"); return 0
    m = re.search(r'func makeAgentTools\(([^)]*)\)', s)
    if not m:
        print("  FAIL includeHostTools: 找不到 makeAgentTools 签名"); return 0
    existing = m.group(1).strip()
    # 原来可能没有参数（空括号），此时不能加逗号
    sep = ",\n                           " if existing else "\n                           "
    s = s[:m.start(1)] + existing + sep + "includeHostTools: Bool = true" + s[m.end(1):]
    p.write_text(s)
    print("  PATCH includeHostTools 开关")
    return 1

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    print(f"== 接入 host_exec / codex_exec → {root} ==")
    n = 0
    n += patch_schema(root)
    n += patch_flag(root)
    n += patch_switch(root)
    n += patch_sse(root)
    print(f"== 完成，改动 {n} 处 ==")
    return 0 if n >= 0 else 1

if __name__ == "__main__":
    sys.exit(main())
