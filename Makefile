# build for a real device then: make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless/roothide

ifeq ($(filter sim,$(MAKECMDGOALS)),sim)
export TARGET ?= simulator:clang:latest:14.0
export ARCHS ?= x86_64
else
export TARGET ?= iphone:clang:latest:14.0
export ARCHS ?= arm64 arm64e
endif

INSTALL_TARGET_PROCESSES = SpringBoard chronod WidgetRenderer_Default WidgetRenderer_CarPlay
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass
HOOK_FILES := $(wildcard Hooks/*.x) $(wildcard Hooks/Lockscreen/*.x)
SHARED_FILES := Shared/LGSharedSupport.m Shared/LGHookSupport.m Shared/LGBannerCaptureSupport.m Shared/LGMetalShaderSource.m Shared/LGGlassRenderer.m Shared/LGBackButtonSupport.m
RUNTIME_FILES := Runtime/LGLiquidGlassRuntime.m Runtime/LGSnapshotCaptureSupport.m
PREF_CONTROL_FILES := LiquidAssPrefs/LGPrefsLiquidSlider.m LiquidAssPrefs/LGPrefsLiquidSwitch.m
$(TWEAK_NAME)_FILES = Tweak.x $(HOOK_FILES) $(SHARED_FILES) $(RUNTIME_FILES) $(PREF_CONTROL_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit Metal MetalKit Accelerate

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssPrefs
SUBPROJECTS += LiquidAssRWB
include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: sim remove release

sim:: all
	@rm -f /opt/simject/$(TWEAK_NAME).dylib
	@cp -v .theos/obj/iphone_simulator/debug/$(TWEAK_NAME).dylib /opt/simject
	@cp -v $(PWD)/$(TWEAK_NAME).plist /opt/simject
	@rm -f /opt/simject/LiquidAssRWB.dylib
	@cp -v .theos/obj/iphone_simulator/debug/LiquidAssRWB.dylib /opt/simject
	@cp -v $(PWD)/LiquidAssRWB/LiquidAssRWB.plist /opt/simject
	@mkdir -p /opt/simject/PreferenceLoader/Preferences
	@mkdir -p /opt/simject/PreferenceBundles
	@rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@cp -vR .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	cp -v $(PWD)/LiquidAssPrefs/Resources/entry.plist /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist
	@resim
	@pkill -9 -f 'CoreSimulator/.*/ChronoCore.framework/Support/chronod' || true
	@pkill -9 -f 'CoreSimulator/.*/Preferences' || true

before-package::
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist"; \
	fi; \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist"; \
	fi

remove::
	@rm -f /opt/simject/$(TWEAK_NAME).dylib /opt/simject/$(TWEAK_NAME).plist
	@rm -f /opt/simject/LiquidAssRWB.dylib /opt/simject/LiquidAssRWB.plist
	@[ ! -d /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle ] || rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@[ ! -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist ] || rm -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist

# originally i tried to add `release::` here but apparently that keeps breaking for whatever fucking reason so i decided to create `release.sh`
