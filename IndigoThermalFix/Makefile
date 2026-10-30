TARGET = IndigoThermalFix.dylib
CC = xcrun -sdk iphoneos clang
ARCHS = -arch arm64 -arch arm64e
MIN_IOS = -miphoneos-version-min=15.0
CFLAGS = -O3 -fobjc-arc -Wall -Wextra -Werror -Wno-error=deprecated-declarations $(MIN_IOS)
FRAMEWORKS = -framework Foundation -framework UIKit -framework Metal -framework MetalKit -framework QuartzCore -framework AVFoundation -framework CoreMedia -framework CoreML
LDFLAGS = -dynamiclib -install_name @rpath/$(TARGET) $(FRAMEWORKS)

all: $(TARGET) test

$(TARGET): Tweak.m
	@echo "Building $(TARGET)..."
	@$(CC) $(ARCHS) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>/dev/null || $(CC) -arch arm64 $(CFLAGS) $(LDFLAGS) $< -o $@
	@codesign -s - --force $@
	@echo "Built and signed $(TARGET)"

test:
	@echo "Running automated verification tests..."
	@python3 test_tweak.py

clean:
	rm -f $(TARGET)

.PHONY: all clean test
