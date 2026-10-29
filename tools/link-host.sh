#!/bin/sh
# 在 iSH 侧执行：把宿主的 nyxian 下载目录链进工作区（宿主不认 iSH 的 /var/minis）
mkdir -p /var/minis/workspace/NanoCode/tmp
ln -sfn /private/var/mobile/Documents/nyxian /var/minis/workspace/NanoCode/tmp/nyxian
ls -l /var/minis/workspace/NanoCode/tmp/
