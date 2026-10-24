# Theos CI 自检工程：最小的 SpringBoard tweak。
# 它存在的意义只有一个——证明「CI 里真的能跑 Theos 并产出可安装的 deb」。
# 换成你自己的工程时，保持同样的三件套：Makefile / control / 源码。

TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HelloTweak
HelloTweak_FILES = Tweak.x
HelloTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
