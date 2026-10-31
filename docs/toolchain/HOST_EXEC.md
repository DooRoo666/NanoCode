# host_exec / codex_exec 回显与写法实录（iOS 真机实测）

> 在 Minis.app 的 nsh（forkless, posix_spawn）与 bash.real 委托机制下逐条实测所得。
> 目的：避免"明明命令对却回显错乱 / 丢输出 / 假失败"，一次写对。

---

## 一、结论速查

| 写法 | 是否可靠 | 说明 |
|------|----------|------|
| 单行命令 | ✅ | 一切正常 |
| 多行用真实换行 `\n` 分隔 | ❌ **不可靠** | 换行被吞、行粘连、丢行、`$?` 读错 |
| 多行用 `;` 分隔（单行化） | ✅ | **推荐**，`$?` 完全正确 |
| `echo "rc=$?"`（行尾 $?） | ⚠️ | 后接换行时会粘连，改用 printf + 变量中转 |
| `rc=$?; printf 'rc=%s\n' "$rc"` | ✅ | **推荐**取值方式 |
| `printf '...\n'` | ✅ | 比 `echo` 稳，跨实现一致 |
| `1>&2` | ✅ | 可用（此前误判为不支持） |
| `sleep` | ❌ | 宿主无此二进制，nsh 内建也没有 → 127 或 Bus error |
| `delay` 参数 | ✅ | 需要等待时用 host_exec 的 delay，而不是 sleep |
| shell 函数 `f(){...}` | ❌ | nsh 报 `No such file or directory`，别用函数封装 |
| `for/while/if/case` | ✅ | 会委托 bash.real，可用（但别和真实换行混用） |

---

## 二、三个真实故障（附复现）

### 故障 1：多行命令换行被吞，三条粘成一行

```sh
# 输入（真实换行分隔）
true; echo "r1=$?"
echo "line2"
ls /nope 2>/dev/null; echo "r2=$?"

# 实测输出（错误！）
r1=0 echo line2 ls /nope
r2=0
```

**症状**：`r1=0` 后面直接接到 `echo line2 ls /nope`；`ls /nope` 的 `r2` 应为非 0，却显示 `0`。
**根因**：nsh 在**多行**输入时把后一行的换行当参数拼接，实为委托 bash.real 时的分行缺陷。

### 故障 2：`$?` 捕获错误 + 尾行丢失

```sh
# 输入
false
rc=$?
printf 'captured=%s\n' "$rc"
echo "direct=$?"

# 实测：完全无输出
```

**症状**：多行 + `$?` 组合直接整段失败，或 `false; rc=$?` 读到 `0`（应为 `1`）。
**根因**：同上，换行分隔失效导致 `$?` 读到错误的行上下文。

### 故障 3：`sleep` 直接崩

```sh
sleep 1
# nsh: sleep: No such file or directory   (rc=127)

# 若经 bash.real：
# bash.real: line 1: 1177 Bus error: 10
```

**根因**：宿主根文件系统无 `sleep` 二进制；nsh 内建也没有。
**替代**：需要等待时用 `host_exec` 的 `delay` 参数（工具级等待，不占用 shell）。

---

## 三、正确写法模板

> **总原则：能单行就单行；多步一律 `;` 分隔；取值用 `rc=$?` 中转；输出用 `printf`。**

### ✅ 多步 + 取退出码（单行化 + printf + 变量中转）

```sh
false; rc=$?; printf 'step1_rc=%s\n' "$rc"; true; rc=$?; printf 'step2_rc=%s\n' "$rc"; printf 'end\n'
```

输出：

```
step1_rc=1
step2_rc=0
end
```

### 📋 直接抄：通用脚本骨架（无函数，实测可用）

> ⚠️ **nsh 不支持 shell 函数**（`step(){...}` 会报 `No such file or directory`）。
> 直接用 `printf` 做分隔，别包函数。

```sh
printf '\n== 检查环境 ==\n'; ls /path 2>&1 | head -5; rc=$?; printf 'rc=%s\n' "$rc"; printf '\n== 执行构建 ==\n'; make 2>&1; rc=$?; printf 'rc=%s\n' "$rc"; printf '\n== 完成 ==\n'
```

输出实测：

```
== 检查环境 ==
...
rc=0

== 执行构建 ==
...
rc=0

== 完成 ==
```

要点：全部一条物理行；每步 `printf` 分隔 + `rc=$?` **紧跟其后**（中间不能隔东西）；`$?` 只在紧邻时才可靠。

### ✅ 需要等待

```sh
# 不要 sleep；在工具调用参数里设 delay
```

### ✅ 检查文件是否存在（避免 grep 空结果误导）

```sh
if [ -e /path/x ]; then printf 'YES\n'; else printf 'NO\n'; fi
```

### ✅ stderr 合并

```sh
some_cmd 2>&1; printf 'rc=%s\n' "$?"
```

---

## 四、codex_exec 回显

`codex_exec` 回显是**完整**的：命令 → exec 段 → succeeded 段 → 模型最终回复，逐段可读，无需额外处理。
长任务直接用它，不必担心丢信息。

---

## 五、排查清单

遇到"命令明明对但结果怪"时，依次检查：

1. 是否用了**真实换行**分隔多条命令？→ 改 `;` 单行化
2. 是否行尾直接 `$?`？→ 改 `rc=$?; printf`
3. 是否用了 `sleep`？→ 换 `delay` 参数
4. `$?` 是否为 0 但预期非 0？→ 多半是换行粘连读错行
5. 输出为空？→ 多行 + `$?`，改为分号单行

---

*实测环境：Minis.app / iOS，nsh (posix_spawn) + bash.real 委托。*
