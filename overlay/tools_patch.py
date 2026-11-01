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
    new_code = '''        // nanoMuse-toolreg: 宿主层执行能力。这两个工具此前只被定义、从未注册，
        // 模型完全看不到它们。host_exec 走 posix_spawn + 随包 nsh，
        // codex_exec 走随包 codex-sign，都是无 fork 实现，iOS 沙盒下可用。
        if includeHostTools {
            tools.append(
                AgentToolDefinition(
                    name: NanoMuseHostShellTool.toolName,
                    description: "在 iOS 宿主进程执行 shell 命令（nsh，无 fork，不依赖 iSH）。可用随包 helper：bash.real/ls/cat/grep/sed/xxd/tar 等。支持管道、重定向、&&、||、$VAR、$()、通配符、cd。不支持子 shell ( ) 与后台 & 。需要真正的 Linux 环境（apk/git/python）时改用 shell_execute。",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "工具调用摘要，5-10词，给用户看，用用户的语言"),
                        "command": AgentToolParam(type: .string, description: "要执行的命令，例如 ls -l /private/var/mobile/Documents"),
                        "timeout": AgentToolParam(type: .integer, description: "超时秒数，默认 60"),
                    ],
                    required: ["tool_title", "command"],
                    propertyOrdering: ["tool_title", "command", "timeout"]
                )
            )
            tools.append(
                AgentToolDefinition(
                    name: NanoMuseCodexTool.toolName,
                    description: "调用随包 Codex 编码代理，在指定工作区里读写文件、执行命令并返回结果。适合多步编码任务。",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "工具调用摘要，5-10词，给用户看，用用户的语言"),
                        "prompt": AgentToolParam(type: .string, description: "交给 Codex 的任务，尽量具体"),
                        "workspace": AgentToolParam(type: .string, description: "允许操作的工作目录绝对路径，默认 /root/work"),
                        "timeout": AgentToolParam(type: .integer, description: "超时秒数，默认 900"),
                    ],
                    required: ["tool_title", "prompt"],
                    propertyOrdering: ["tool_title", "prompt", "workspace", "timeout"]
                )
            )
        }
        if includeMemoryTools {'''
    return patch(f, old, new_code, "schema 注册")

def patch_switch(root):
    f = f"{root}/{CONC}"
    old = '        case "file_read":'
    new_code = '''        // nanoMuse-toolreg: 宿主工具执行分支。没有这段，host_exec/codex_exec
        // 会被 SSE 的 default 兜底当成普通 shell 工具，永远走不到真实实现。
        case NanoMuseHostShellTool.toolName:
            let hostArgs = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
            let hostCmd = hostArgs["command"] as? String ?? ""
            let hostTimeout = (hostArgs["timeout"] as? NSNumber)?.doubleValue ?? 60
            let hostOut = await NanoMuseHostShellTool.execute(command: hostCmd, timeout: hostTimeout)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = hostOut.text
            }
            toolOutput = hostOut.text
            toolSuccess = hostOut.exitCode == 0
        case NanoMuseCodexTool.toolName:
            let codexArgs = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
            let codexPrompt = codexArgs["prompt"] as? String ?? ""
            let codexWs = codexArgs["workspace"] as? String ?? "/root/work"
            let codexTimeout = (codexArgs["timeout"] as? NSNumber)?.doubleValue ?? 900
            let codexOut = await NanoMuseCodexTool.execute(prompt: codexPrompt, workspace: codexWs, timeout: codexTimeout)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = codexOut.text
            }
            toolOutput = codexOut.text
            toolSuccess = codexOut.exitCode == 0
        case "file_read":'''
    return patch(f, old, new_code, "并发执行分支")

def patch_sse(root):
    f = f"{root}/{SSE}"
    ok = 0
    # 1) 工具卡片类型判定：default 会把宿主工具误判成普通 shell
    ok += patch(f,
        '                    case "shell_execute": .shellTool(command: "")',
        '''                    case "shell_execute": .shellTool(command: "")
                    // nanoMuse-toolreg: 宿主工具用 shellTool 卡片呈现。
                    // command 填工具名而非空串 —— shellTool 卡片会把 command 当作
                    // 标题原文显示，空串时只剩通用的 "shell"，看不出是 host 层还是
                    // Codex 子代理。填名字后卡片直接标出 HOST / CODEX。
                    case NanoMuseHostShellTool.toolName:
                        .shellTool(command: "host_exec")
                    case NanoMuseCodexTool.toolName:
                        .shellTool(command: "codex_exec")''',
        "SSE 卡片类型")

    # 2) 正文预览：toolInputPreview 已经会优先读 tool_title 作描述，但 preview
    #    正文对这两个工具没有分支，会落到 default 显示整段 JSON。补上专属分支，
    #    让卡片正文显示真正要执行的东西（host 的 command / codex 的 task）。
    ok += patch(f,
        '''        let desc = extractPartialStringValue("tool_title", from: json)''',
        '''        // nanoMuse-toolreg: host_exec / codex_exec 没有 tool_summary 字段，
        // tool_title 是模型给的语义摘要，直接当描述用。
        let desc = extractPartialStringValue("tool_title", from: json)''',
        "preview 读 tool_title")
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

def patch_dedupe(root):
    f = f"{root}/Agent/Chat/AIChatViewModel.swift"
    old = '        let tools = NanoMusePromptDiet.tools(makeAgentTools()) // nanoMuse: browser_use worded densely'
    new_code = '''        // nanoMuse-toolreg: Provider gateways require unique function names.
        // Keep the first definition when built-in and host tool registries overlap.
        var tools = NanoMusePromptDiet.tools(makeAgentTools()) // nanoMuse: browser_use worded densely
        var seenToolNames = Set<String>()
        tools = tools.filter { seenToolNames.insert($0.name).inserted }'''
    return patch(f, old, new_code, "Provider 工具名去重")

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    print(f"== 接入 host_exec / codex_exec → {root} ==")
    n = 0
    n += patch_schema(root)
    n += patch_flag(root)
    n += patch_dedupe(root)
    n += patch_switch(root)
    n += patch_sse(root)
    print(f"== 完成，改动 {n} 处 ==")
    return 0 if n >= 0 else 1

if __name__ == "__main__":
    sys.exit(main())
