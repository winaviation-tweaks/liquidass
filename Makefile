
ifeq ($(filter sim,$(MAKECMDGOALS)),sim)
export TARGET ?= simulator:clang:latest:14.0
export ARCHS ?= x86_64
else
export TARGET ?= iphone:clang:latest:14.0
export ARCHS ?= arm64 arm64e
endif

include $(THEOS)/makefiles/common.mk
include ./locatesim.mk

TWEAK_NAME = liquidass

HOOK_FILES := $(wildcard Hooks/*.x) $(wildcard Hooks/Lockscreen/*.x)
SHARED_FILES := Shared/LGSharedSupport.m Shared/LGHookSupport.m Shared/LGBannerCaptureSupport.m Shared/LGMetalShaderSource.m Shared/LGGlassRenderer.m
RUNTIME_FILES := Runtime/LGLiquidGlassRuntime.m Runtime/LGSnapshotCaptureSupport.m
PREF_CONTROL_FILES := LiquidAssPrefs/LGPrefsLiquidSlider.m LiquidAssPrefs/LGPrefsLiquidSwitch.m

$(TWEAK_NAME)_FILES = Tweak.x $(HOOK_FILES) $(SHARED_FILES) $(RUNTIME_FILES) $(PREF_CONTROL_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit MetalKit

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += LiquidAssPrefs

include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: sim remove release release-all release-rootless release-rootful release-roothide

SET_PLIST_LABEL = python3 -c 'exec("import os, plistlib, sys\nlabel = sys.argv[1]\nfor path in sys.argv[2:]:\n    if not os.path.exists(path):\n        continue\n    with open(path, \"rb\") as f:\n        data = plistlib.load(f)\n    if isinstance(data, dict):\n        entry = data.setdefault(\"entry\", {})\n        if isinstance(entry, dict):\n            entry[\"label\"] = label\n    with open(path, \"wb\") as f:\n        plistlib.dump(data, f)\n    print(\"Updated \" + path)")'

sim:: all
	@rm -f /opt/simject/$(TWEAK_NAME).dylib
	@cp -v .theos/obj/iphone_simulator/debug/$(TWEAK_NAME).dylib /opt/simject
	@cp -v $(PWD)/$(TWEAK_NAME).plist /opt/simject
	@mkdir -p /opt/simject/PreferenceLoader/Preferences
	@mkdir -p /opt/simject/PreferenceBundles
	@rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@cp -vR .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	cp -v $(PWD)/LiquidAssPrefs/Resources/entry.plist /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	if [ -n "$$APP_NAME" ]; then \
		$(SET_PLIST_LABEL) "$$APP_NAME" \
			/opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist \
			/opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist; \
	else \
		echo "No prefs.app_name found; skipping label update"; \
	fi

before-package::
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	if [ -n "$$APP_NAME" ]; then \
		$(SET_PLIST_LABEL) "$$APP_NAME" \
			"$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist" \
			"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist"; \
	else \
		echo "No prefs.app_name found; skipping label update"; \
	fi

remove::
	@rm -f /opt/simject/$(TWEAK_NAME).dylib /opt/simject/$(TWEAK_NAME).plist
	@[ ! -d /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle ] || rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@[ ! -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist ] || rm -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist

release: release-all

release-all: release-rootless release-rootful release-roothide
	@echo "All release builds completed."

release-rootless:
	@echo "Building rootless package..."
	@$(MAKE) clean ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
	@$(MAKE) all ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
	@$(MAKE) package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

release-rootful:
	@echo "Building rootful package..."
	@$(MAKE) clean ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1
	@$(MAKE) all ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1
	@$(MAKE) package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1

release-roothide:
	@echo "Building roothide package..."
	@echo "Note: roothide builds require the roothide Theos fork."
	@$(MAKE) clean ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
	@$(MAKE) all ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
	@$(MAKE) package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide

