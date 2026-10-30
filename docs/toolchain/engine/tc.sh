#!/bin/sh
# NanoCode 工具链管理器 —— 本体零内置，工具按需下载
# 用法: tc.sh list | status | install <name> | install-all | verify | path <name>
# 注册表驱动，换自己的工具只改 registry/tools.json
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")
export NANOCODE_ROOT="$ROOT"
export NANOCODE_BASE="${NANOCODE_BASE:-$ROOT/tools}"
export NANOCODE_REGISTRY="${NANOCODE_REGISTRY:-$ROOT/registry/tools.json}"

PY=python3
command -v $PY >/dev/null 2>&1 || PY=python

exec $PY "$DIR/tcmgr.py" "$@"
