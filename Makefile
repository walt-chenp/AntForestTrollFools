SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := $(shell xcrun --sdk iphoneos --find clang)
TARGET := build/AntForestPort.dylib
SOURCES := PortEntry.m antforest/AntForestManager.m antforest/DebugTool/Tool.m antforest/DebugTool/UIView+Toast.m

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	@mkdir -p build
	$(CLANG) -target arm64e-apple-ios16.0 -isysroot $(SDK) -fobjc-arc -dynamiclib $(SOURCES) -Iantforest -Iantforest/Headers/PSDJsBridge -Iantforest/Headers/PSDJsBridge/Protocol -Iantforest/DebugTool -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -o $@

clean:
	rm -rf build
