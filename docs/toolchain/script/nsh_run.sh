#!/bin/sh
# nsh_run.sh —— host_exec 多行可靠执行封装
#
# 背景：host_exec 的 nsh 层会把命令里的真实换行(\n)当成空格，
# 导致多行命令被拼成一条、变量丢失、$? 读错行、甚至整体无输出。
# 本脚本把"多行"在写入时压成一条用 ';' 分隔的单行，再交给 sh 执行，
# 从而绕开 nsh 的换行吞并问题。
#
# 用法：
#   sh nsh_run.sh script.nsh        # 执行文件里的多行脚本
#   或把命令逐行写进文件后调用
#
# 写法约定（为保证可靠）：
#   - 每行用 ';' 结尾或依赖下面的拼接
#   - 取退出码要 rc=$?; 紧跟其后，不要跨行
#   - 输出用 printf '...\n' 而非裸 echo

set -e
src="$1"
[ -f "$src" ] || { printf '用法: sh nsh_run.sh <script-file>\n'; exit 2; }

# 把非空、非注释行用 ';' 连接成一条命令
joined=$(awk 'BEGIN{ORS=""} /^[[:space:]]*($|#)/{next} {gsub(/^[ \t]+|[ \t]+$/,""); print $0 ";"}' "$src")
[ -z "$joined" ] && { printf '空脚本\n'; exit 0; }

printf '== 执行 ==\n'
sh -c "$joined"
printf '== rc=%s ==\n' "$?"
