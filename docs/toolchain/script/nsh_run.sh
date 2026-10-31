#!/bin/sh
# nsh_run.sh — 在宿主侧用 bash.real 可靠执行多行脚本
#
# 结论（实测定稿）：
#   · 写文件换行不丢：printf 'a\nb\n' > f  /  echo 'x' >> f  都正确
#   · 丢换行的是「nsh 读脚本执行」这一步：sh script.sh  →  全部粘成一行
#   · 解药：用 bash.real 执行脚本（能跑 内建命令 + 控制流 + 算术 + 函数）
#           bash.real 不能跑 外部命令 / 管道 / 命令替换（Bus error）
#
# 用法（宿主侧 host_exec，整条命令仍须单行，用 ; 分隔）：
#   1) printf 'x=5\necho "v=$x"\n' > /tmp/s.sh; bash.real /tmp/s.sh
#   2) sh nsh_run.sh /tmp/s.sh          # 本脚本仅做 bash.real 定位转发
#
# 定位 bash.real（glob 展开，不硬编码 UUID）。注意：本脚本自身被「nsh 读」
# 时也会丢换行，所以**必须由 bash.real 来执行本脚本**，或直接把内容交给
# bash.real -c。本文件主要用于人类阅读与拷贝模板，不保证被 sh 调用可用。

BASHR=/var/containers/Bundle/Application/*/Minis.app/Helpers/bash.real
exec "$BASHR" "$@"
