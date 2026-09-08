include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssBackboardd

LiquidAssBackboardd_FILES     = $(wildcard *.mm)
LiquidAssBackboardd_CFLAGS    = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions
LiquidAssBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
LiquidAssBackboardd_LDFLAGS   = -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LiquidAssBackboardd_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
