#!/bin/sh
# nsh_run.sh — 宿主侧可靠执行多行脚本 / 命令
#
# ⚠️ 本脚本**必须由 bash.real 调用**，不能用 sh 调用：
#      B=$(realpath /var/containers/Bundle/Application/*/Minis.app/Helpers/bash.real)
#      "$B" nsh_run.sh /tmp/my.sh
#    原因：nsh 读脚本会丢换行（第一轮实测），宿主也没有 /bin/sh，
#          且 sandbox 禁止 shebang 执行（第二轮实测）。
#
# 用法：
#   "$B" nsh_run.sh /tmp/my.sh        # 跑脚本文件
#   "$B" -c 'echo hi'                 # 跑内联命令（不经过本脚本）

P=$(realpath /var/containers/Bundle/Application/*/Minis.app/Helpers/bash.real 2>/dev/null)
if [ -z "$P" ]; then
  printf 'nsh_run: bash.real 未找到（Minis.app 路径变了？）\n' >&2
  exit 127
fi

if [ -n "$1" ] && [ -f "$1" ]; then
  exec "$P" "$@"
fi

# 无文件参数：从 stdin 读，落到临时文件再交给 bash.real
T="/tmp/_nshrun_$$.sh"
cat > "$T"
exec "$P" "$T"
