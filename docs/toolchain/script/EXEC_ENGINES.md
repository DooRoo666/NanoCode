# 宿主执行引擎分工（实测，最终版）

> 环境：iOS 真机 / Minis.app/Helpers/{nsh, bash.real} / Codex 0.162.1

## 一、核心结论

宿主侧有**两个**执行器，能力**互补**，必须按需选：

| 能力 | nsh（host_exec 默认） | bash.real |
|------|----------------------|-----------|
| 管道 `a \| b` | ✅ | ❌ Bus error |
| 命令替换 `$(...)` | ✅ | ❌ 返回空 |
| 真换行多行脚本 | ❌ 换行变空格 | ✅ 完美 |
| 变量跨行 | ❌（多行时） | ✅ |
| `for/do/done` 跨行 | ❌ | ✅ |
| `if/then/fi` 跨行 | ❌ | ✅ |
| 函数定义 | ⚠️ | ✅ |
| `$((2+3))` 算术 | ❌ | ✅ |
| 真实退出码 `$?` | ✅（单行紧跟） | ✅ |

## 二、选型规则

```
需要管道 / 命令替换  →  host_exec + nsh（分号单行）
需要多行控制流 / 算术 / 函数 / 变量状态  →  bash.real
两者都要  →  多行脚本落文件，用 bash.real 执行；
            文件内避开管道与 $()，改用 nsh 单行分步
```

## 三、bash.real 三种调用姿势（均已实测）

```
# B = bash.real 绝对路径（用 glob 动态定位，不硬编码 UUID）
B=/var/containers/Bundle/Application/*/Minis.app/Helpers/bash.real

# 姿势1：内联（适合短控制流，无管道/无命令替换）
$B -c 'x=5; if [ "$x" -gt 3 ]; then printf "big\n"; fi; for i in 1 2; do printf "i=%s\n" "$i"; done'

# 姿势2：执行脚本文件（推荐，避开引号地狱）
printf '...多行脚本...' > /tmp/s.sh      # 写入: 换行正确(已实测 xxd 验证)
$B /tmp/s.sh

# 姿势3：通过封装脚本
$B /var/mobile/Documents/nsh_run.sh /tmp/s.sh
```

## 四、关键事实（纠错记录）

1. **写文件换行不丢**：`printf 'a\nb\n' > f` 字节完全正确
   （`xxd` 验证 `4c31 0a 4c32 0a`）。丢换行发生在**「nsh 读取并执行脚本」**时。
2. **`sh /tmp/s.sh` 必坏**：`nsh: #!/bin/sh: No such file`——整个脚本被粘成一行。
   **必须用 `bash.real /tmp/s.sh`**。
3. **bash.real 不能碰管道**：`ls | head` → `Bus error: 10`（iOS 禁 fork）。
4. **bash.real 不能用 `$(...)`**：返回空。要取值改用分步写临时文件再读。
5. **codex_exec 底层也是 nsh**（bin/sh → nsh 符号链接），
   其多行"正常"只因逐条独立进程，跨命令不保留变量/退出码。

## 五、宿主侧工具清单与硬限制（实测）

Helpers/ 实际可用命令：`basename cat chmod cp? date dirname du find grep head ln ls nl od readlink realpath sed sort stat tail tarx tee uname uniq wc which xxd` + `nsh bash bash.real codex-sign ca-filetool`。

**关键缺失（踩坑记录）：**
- ❌ **没有 `rm` / `unlink` / `mv`** → 宿主侧**无法删除/移动文件**。
  清理只能用 iSH 侧 `shell_execute`（能看同一路径）或索性不清理。
- ❌ `expr` `tr` `printf`(作外部) `rm` 均不在 PATH；`printf` 是 nsh **内建**（可用）。
- ❌ `bash.real -c 'rm ...'` → **Bus error**（bash.real 只能跑**内建命令**，
  任何外部二进制调用都会 fork 崩溃）。
- ⚠️ `ls glob` 输出可能被 nsh 显示成相对名（`found=bash.real`），
  但 `[ -x $GLOB ]` 与直接 `$GLOB cmd` 均可正常执行——**以 test 为准，别信显示**。

**结论**：bash.real 的可靠用途 = **纯内建 shell 逻辑**（变量/算术/for/if/函数/printf）。
一旦需要外部命令或管道，回到 nsh（host_exec 单行）。

## 六、稳妥模板

```sh
# A. 纯管道/命令替换（host_exec 单行）
ls /var/mobile/Documents | head -3; printf 'rc=%s\n' "$?"

# B. 多行控制流（落文件 + bash.real）
printf 'sum=0\nfor i in 1 2 3; do sum=$((sum+i)); done\nprintf "sum=%%s\\n" "$sum"\n' > /tmp/s.sh; bash.real /tmp/s.sh

# C. 混合：管道结果先落地，再交给 bash.real 读文件做控制流
ls /var/mobile/Documents > /tmp/list.txt; bash.real /tmp/s2.sh   # s2.sh 内 read 逐行处理
```

## 七、致命坑：双层 printf 的 `%` 转义（必看）

用 `printf '...' > f` 写文件、且文件内容里还要 `printf "%s"` 时，
**外层的 `%` 必须写成 `%%`**，否则内层 `%s` 被外层吃掉，结果全空：

```sh
# ❌ 错（文件里变成 printf "sum=\n" "$x"，$x 成多余参数 → 输出空）
printf 'printf "sum=%s\n" "$x"\n' > /tmp/t.sh

# ✅ 对（外层 %% 保留成内层 %）
printf 'printf "sum=%%s\\n" "$x"\n' > /tmp/t.sh
```

判定：写完立即 `xxd /tmp/t.sh | head -2` 看是否 `25 73`（=%s）。
**凡嵌套 printf，一律先 xxd 验字节再执行。**

