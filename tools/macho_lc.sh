#!/private/var/containers/Bundle/Application/5593ECD4-90C1-4C7B-85CE-58387BC3BBFF/Minis.app/Helpers/bash.real
# 解析 Mach-O 加载命令，输出 LC_BUILD_VERSION / 依赖 dylib 路径
# 用法: macho_lc.sh <可执行文件> [--deps]
P="$1"
MODE="$2"
# 读前 8 字节判断 magic（hex）
H=$(xxd -l 8 "$P")
M=${H%% *}
case "$M" in
  cffaedfe) E=1 ;;   # 小端 64 位
  cefaedfe) E=0 ;;   # 大端 64 位（少见）
  *) echo "unsupported magic $M"; exit 1 ;;
esac
# 读头部字段：ncmds at 0x10, sizeofcmds at 0x14
NCMDS=$(hexdec 0x$(xxd -s 16 -l 4 -p "$P"))
SZCMDS=$(hexdec 0x$(xxd -s 20 -l 4 -p "$P"))
echo "ncmds=$NCMDS sizeofcmds=$SZCMDS"
OFF=32
I=0
while [ $I -lt $NCMDS ]; do
  C=$(hexdec 0x$(xxd -s $OFF -l 4 -p "$P"))
  CS=$(hexdec 0x$(xxd -s $((OFF+4)) -l 4 -p "$P"))
  case "$C" in
    50) # LC_BUILD_VERSION
      PLAT=$(hexdec 0x$(xxd -s $((OFF+8)) -l 4 -p "$P"))
      MINO=$(hexdec 0x$(xxd -s $((OFF+12)) -l 4 -p "$P"))
      SDKV=$(hexdec 0x$(xxd -s $((OFF+16)) -l 4 -p "$P"))
      echo "LC_BUILD_VERSION plat=$PLAT minos=$((MINO>>16)).$(((MINO>>8)&255)) sdk=$((SDKV>>16)).$(((SDKV>>8)&255))" ;;
    37) # LC_VERSION_MIN_IPHONEOS
      V=$(hexdec 0x$(xxd -s $((OFF+8)) -l 4 -p "$P"))
      echo "LC_VERSION_MIN_IPHONEOS ver=$((V>>16)).$(((V>>8)&255))" ;;
    12) # LC_LOAD_DYLIB
      NOFF=$(hexdec 0x$(xxd -s $((OFF+8)) -l 4 -p "$P"))
      LEN=$(hexdec 0x$(xxd -s $((OFF+NOFF)) -l 4 -p "$P"))
      STR=$(xxd -s $((OFF+NOFF+4)) -l $((LEN-4)) -p "$P")
      echo "LOAD_DYLIB $(hexutf8 "$STR")" ;;
    31|25) # LC_RPATH / LC_LOAD_WEAK_DYLIB
      NOFF=$(hexdec 0x$(xxd -s $((OFF+8)) -l 4 -p "$P"))
      LEN=$(hexdec 0x$(xxd -s $((OFF+NOFF)) -l 4 -p "$P"))
      STR=$(xxd -s $((OFF+NOFF+4)) -l $((LEN-4)) -p "$P")
      [ "$C" = "31" ] && echo "RPATH $(hexutf8 "$STR")" || echo "WEAK_DYLIB $(hexutf8 "$STR")" ;;
  esac
  OFF=$((OFF+CS))
  I=$((I+1))
done
