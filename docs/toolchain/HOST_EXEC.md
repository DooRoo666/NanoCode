# 宿主侧执行工具选型与铁律（实测）

> 版本：Codex 0.162.1 / provider=nanomuse / model=deepseek-v4.1-flash
> 环境：iOS 真机宿主，nsh（forkless，Minis.app/Helpers/nsh）

## 一、结论（一句话）

**真实执行 → 用 `host_exec`，命令强制 `;` 单行化；
需要推理/改文件 → 才用 `codex_exec`，且不依赖它的命令间状态。**

## 二、为什么不是 codex_exec（关键实证）

`codex-home/bin/sh` 与 `bin/bash` 都是符号链接 → `Minis.app/Helpers/nsh`。
**codex_exec 底层 shell 与 host_exec 是同一个 nsh**，多行"看起来正常"
只是因为 codex 把每条命令**拆成独立进程**执行。后果：

同一脚本 `x=5; echo "val=$x"; false; echo "rc=$?"`

| 工具 | val | rc | 说明 |
|------|-----|-----|------|
| host_exec（分号） | **5** ✓ | **1** ✓ | 状态延续、真实退出码 |
| codex_exec | 空 ✗ | 0 ✗ | 每命令独立 shell，状态不保留 |

→ codex_exec **无法**做 变量→判断→退出码 的真实脚本逻辑。

## 三、host_exec 实测能力边界

| 场景 | 结果 |
|------|------|
| 真换行多行 | ❌ 换行被吞（`echo one\necho two` → `one echo two`） |
| `;` 单行串联 | ✅ 正常 |
| `for f in a b c; do ...; done` 单行 | ✅ 正常 |
| 跨行 `for/do/done` | ❌ 崩（`nsh: do/done: No such file`） |
| `rc=$?` 紧跟目标命令 | ✅ 正确 |
| `printf 'a\nb\n' > file` 写多行文件 | ✅ **换行完整保留**（xxd 已验证）| 
| `echo 'x' >> file` 逐行追加 | ✅ **换行完整保留**（xxd 已验证）| 
| 多行脚本用 `sh 脚本` 执行 | ❌ nsh 读脚本丢换行，全部粘成一行 |
| 多行脚本用 `bash.real 脚本` 执行 | ✅ 变量/算术/for/if/函数/退出码全对 |

注（**已更正**）：**写文件换行从来不会丢**——`printf`/`echo >>` 都正确（`xxd` 确认
`4c31 0a 4c32 0a`）。之前"换行丢失"的假象，是 **nsh 执行时读脚本**丢换行造成的。
**正确姿势：写文件照常用 printf/echo；执行多行脚本必须用 `bash.real`，不能用 `sh`。**
bash.real 只跑内建命令，含外部命令/管道会 Bus error——详见 `script/EXEC_ENGINES.md`。

## 四、铁律（照抄即可）

```
# 1. 永远分号单行，不写真换行
cmd1; rc=$?; printf 'rc=%s\n' "$rc"

# 2. 退出码紧跟目标命令
false; rc=$?; printf 'rc=%s\n' "$rc"     # rc=1 ✓

# 3. 循环必须单行
for f in a b c; do printf 'item=%s\n' "$f"; done

# 4. 用 printf 代替 echo（转义更可控）

# 5. 不跨行 for/do/done、不定义函数、不用 sleep（用 delay）
```

## 五、codex_exec 使用注意（实测）

- 偶发 `wire_api = "chat" is no longer supported` 报错 → **重试即好**，非配置损坏
- 每次夹带大量日志/思考过程，输出需自行提取
- 有 `deprecated: experimental_use_unified_exec_tool` 警告 → codex 内置默认，
  codex-home/config.toml 无 `[features]` 段，**不影响运行，忽略**
- 只读验证类任务可放心；依赖状态的命令一律回 host_exec 跑
