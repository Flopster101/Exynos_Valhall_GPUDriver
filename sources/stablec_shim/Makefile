# stable-C mapper shim + binder interposer (64-bit only).
OUTPUT_DIR ?= out

NDK_SEARCH_PATHS = \
    $(NDK_BUNDLE) \
    $(HOME)/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/linux-x86_64 \
    $(HOME)/Android/android-ndk-*/toolchains/llvm/prebuilt/linux-x86_64 \
    /opt/android-ndk/*/toolchains/llvm/prebuilt/linux-x86_64 \
    /opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64

ifeq ($(NDK_BUNDLE),)
_NDK := $(firstword $(wildcard $(NDK_SEARCH_PATHS)))
else
_NDK := $(NDK_BUNDLE)
endif

ifneq ($(_NDK),)
CXX_64 := $(_NDK)/bin/aarch64-linux-android29-clang++
STRIP  := $(_NDK)/bin/llvm-strip
else
$(error No Android toolchain found. Set NDK_BUNDLE, e.g. \
  NDK_BUNDLE=$$HOME/Android/Sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64)
endif

CXXFLAGS := -O2 -fPIC -fvisibility=hidden -Wall -Wextra -std=c++17 \
    -static-libstdc++ -Wl,--gc-sections
LDFLAGS  := -shared -Wl,--no-undefined

.PHONY: all clean

all: mapper.mali.64.so libbinder_ml.64.so

mapper.mali.64.so: $(OUTPUT_DIR)/mapper.mali.so
	cp $< $@

libbinder_ml.64.so: $(OUTPUT_DIR)/libbinder_ml.so
	cp $< $@

$(OUTPUT_DIR)/mapper.mali.so: src/mapper_shim.cpp src/mapper_mali.map | $(OUTPUT_DIR)
	$(CXX_64) $(CXXFLAGS) $(LDFLAGS) -Wl,--version-script,src/mapper_mali.map \
	    -Wl,-soname,mapper.mali.so -llog -ldl -o $@ $<
	-$(STRIP) $@ 2>/dev/null

$(OUTPUT_DIR)/libbinder_ml.so: src/binder_mali.cpp src/libbinder_ml.map | $(OUTPUT_DIR)
	$(CXX_64) $(CXXFLAGS) $(LDFLAGS) -Wl,--version-script,src/libbinder_ml.map \
	    -Wl,-soname,libbinder_ml.so -llog -ldl -lbinder_ndk -o $@ $<
	-$(STRIP) $@ 2>/dev/null

$(OUTPUT_DIR):
	mkdir -p $(OUTPUT_DIR)

clean:
	rm -rf $(OUTPUT_DIR)
