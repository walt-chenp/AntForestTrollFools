SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := $(shell xcrun --sdk iphoneos --find clang)
LIPO := $(shell xcrun --sdk iphoneos --find lipo)
IOS_DEPLOYMENT_TARGET ?= 14.0
TARGET ?= build/AntForestPort-v2.5-iOS14.dylib
ARM64_TARGET ?= $(TARGET:.dylib=-arm64.dylib)
ARM64E_TARGET ?= $(TARGET:.dylib=-arm64e.dylib)
SOURCES := PortEntry.m antforest/AntForestManager.m antforest/DebugTool/Tool.m antforest/DebugTool/UIView+Toast.m

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	@mkdir -p build
	$(CLANG) -target arm64-apple-ios$(IOS_DEPLOYMENT_TARGET) -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -o $(ARM64_TARGET)
	$(CLANG) -target arm64e-apple-ios$(IOS_DEPLOYMENT_TARGET) -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -o $(ARM64E_TARGET)
	$(LIPO) -create $(ARM64_TARGET) $(ARM64E_TARGET) -output $@
	rm -f $(ARM64_TARGET) $(ARM64E_TARGET)

clean:
	rm -rf build
