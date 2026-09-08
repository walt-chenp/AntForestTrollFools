SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := $(shell xcrun --sdk iphoneos --find clang)
LIPO := $(shell xcrun --sdk iphoneos --find lipo)
TARGET := build/AntForestPort-Ocean.dylib
IOS14_TARGET := build/AntForestPort-Ocean-iOS14.dylib
ARM64_TARGET := build/AntForestPort-arm64.dylib
ARM64E_TARGET := build/AntForestPort-arm64e.dylib
SOURCES := PortEntry.m antforest/AntForestManager.m antforest/StepSimulator.m antforest/DebugTool/Tool.m antforest/DebugTool/UIView+Toast.m

.PHONY: all clean test ios14

all: $(TARGET) $(IOS14_TARGET)

test:
	sh tests/check_water_gift_recheck.sh
	sh tests/check_reward_patrol_paths.sh
	sh tests/check_ocean_task_paths.sh
	sh tests/check_manor_automation_paths.sh
	sh tests/check_farm_task_paths.sh

$(TARGET): $(SOURCES)
	@mkdir -p build
	$(CLANG) -target arm64-apple-ios15.0 -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework WebKit -o build/AntForestPort-arm64-ios15.dylib
	$(CLANG) -target arm64e-apple-ios15.0 -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework WebKit -o build/AntForestPort-arm64e-ios15.dylib
	$(LIPO) -create build/AntForestPort-arm64-ios15.dylib build/AntForestPort-arm64e-ios15.dylib -output $@
	rm -f build/AntForestPort-arm64-ios15.dylib build/AntForestPort-arm64e-ios15.dylib

$(IOS14_TARGET): $(SOURCES)
	@mkdir -p build
	$(CLANG) -target arm64-apple-ios14.0 -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework WebKit -o build/AntForestPort-arm64-ios14.dylib
	$(CLANG) -target arm64e-apple-ios14.0 -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework WebKit -o build/AntForestPort-arm64e-ios14.dylib
	$(LIPO) -create build/AntForestPort-arm64-ios14.dylib build/AntForestPort-arm64e-ios14.dylib -output $@
	rm -f build/AntForestPort-arm64-ios14.dylib build/AntForestPort-arm64e-ios14.dylib

clean:
	rm -rf build
