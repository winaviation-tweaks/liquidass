include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssRWB

LiquidAssRWB_FILES = $(wildcard *.x) ../Shared/LGSharedSupport.m
LiquidAssRWB_CFLAGS = -fobjc-arc
LiquidAssRWB_FRAMEWORKS = UIKit
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LiquidAssRWB_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
