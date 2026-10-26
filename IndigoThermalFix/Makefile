TARGET = IndigoThermalFix.dylib
CC = xcrun -sdk iphoneos clang
ARCHS = -arch arm64 -arch arm64e
MIN_IOS = -miphoneos-version-min=15.0
CFLAGS = -O3 -fobjc-arc -Wall $(MIN_IOS)
FRAMEWORKS = -framework Foundation -framework UIKit -framework MetalKit -framework QuartzCore
LDFLAGS = -dynamiclib -install_name @rpath/$(TARGET) $(FRAMEWORKS)

all: $(TARGET)

$(TARGET): Tweak.m
	@echo "Building $(TARGET)..."
	@$(CC) $(ARCHS) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>/dev/null || $(CC) -arch arm64 $(CFLAGS) $(LDFLAGS) $< -o $@
	@codesign -s - --force $@
	@echo "Built and signed $(TARGET)"

clean:
	rm -f $(TARGET)

.PHONY: all clean
