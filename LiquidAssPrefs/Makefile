include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LiquidAssPrefs

PREF_SHARED_FILES := $(wildcard ../Shared/*.m)
PREF_RUNTIME_FILES := $(wildcard ../Runtime/*.m)
PREF_LOCAL_FILES := LGPRootListController.m LGPSurfaceController.m LGPrefsDataSupport.m LGPrefsUIHelpers.m
LiquidAssPrefs_FILES = $(PREF_LOCAL_FILES) $(PREF_SHARED_FILES) $(PREF_RUNTIME_FILES)
LiquidAssPrefs_FRAMEWORKS = UIKit MetalKit MetalPerformanceShaders
LiquidAssPrefs_INSTALL_PATH = /Library/PreferenceBundles
LiquidAssPrefs_CFLAGS = -fobjc-arc -I../Shared -I../Runtime
LiquidAssPrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	cp Resources/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist
	APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' Resources/Localizable.strings | head -n 1); \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" $(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist
ifneq ($(findstring simulator,$(TARGET)),simulator)
	ldid -S $(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/LiquidAssPrefs
endif
