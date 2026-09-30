TARGET := iphone:clang:latest:14.0
ARCHS := arm64
TWEAK_NAME := JegoTidy

JegoTidy_FILES := Tweak.xm

# -Wno-error：Theos 默认在编译命令末尾追加 -Werror，会把无害 warning 当 error 掐断构建。
# 本机没有 macOS，每次验证都要走一轮 Actions，代价大，所以把 warning 降级。
# 注意：**真正的 error（未声明函数、类型不匹配等）照样会失败**，-Wno-error 救不了。
JegoTidy_CFLAGS := -fobjc-arc -Wno-error

JegoTidy_LDFLAGS := -framework UIKit -framework Foundation -framework QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# 走 TrollFools 注入，不需要 make install；这条留着只是为了将来真机 ssh 安装方便。
# after-install::
# 	install.exec "killall -9 WorryFree" || true
