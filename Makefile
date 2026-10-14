# Developer tasks for Transcriber. Run `make help` for the list.
#
# Downloads and intermediate build products live in $(TOOLS_DIR), which is
# gitignored; `make clean-tools` removes all of it.

TOOLS_DIR         ?= .build-tools
NCPU              := $(shell sysctl -n hw.ncpu)
CMAKE             ?= $(shell command -v cmake 2>/dev/null || echo uvx cmake)

# whisper.cpp ------------------------------------------------------------------
#
# Built ourselves instead of using the official xcframework, because the
# official build enables Core ML without WHISPER_COREML_ALLOW_FALLBACK, so
# decoding fails whenever no Core ML encoder sits next to the model. Here the
# encoder uses Core ML when an .mlmodelc is present and Metal otherwise.

WHISPER_VERSION     := v1.9.5
DEPLOYMENT_TARGET   := 15.0
WHISPER_SOURCE      := $(TOOLS_DIR)/whisper.cpp-$(WHISPER_VERSION)
WHISPER_BUILD       := $(TOOLS_DIR)/whisper-build
WHISPER_STAGING     := $(TOOLS_DIR)/whisper-staging
WHISPER_XCFRAMEWORK := TranscriberKit/Vendor/whisper.xcframework

WHISPER_CMAKE_FLAGS := \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=$(DEPLOYMENT_TARGET) \
	-DBUILD_SHARED_LIBS=OFF \
	-DWHISPER_BUILD_EXAMPLES=OFF \
	-DWHISPER_BUILD_TESTS=OFF \
	-DWHISPER_BUILD_SERVER=OFF \
	-DWHISPER_COREML=ON \
	-DWHISPER_COREML_ALLOW_FALLBACK=ON \
	-DGGML_METAL=ON \
	-DGGML_METAL_EMBED_LIBRARY=ON \
	-DGGML_METAL_USE_BF16=ON \
	-DGGML_NATIVE=OFF \
	-DGGML_OPENMP=OFF

.PHONY: help whisper-xcframework build test clean-tools

help:
	@echo "make whisper-xcframework  Build whisper.cpp $(WHISPER_VERSION) into $(WHISPER_XCFRAMEWORK)"
	@echo "make build                Build TranscriberKit and transcriber-cli"
	@echo "make test                 Run TranscriberKit tests"
	@echo "make clean-tools          Delete $(TOOLS_DIR) (downloads and intermediates)"

whisper-xcframework: $(WHISPER_XCFRAMEWORK)

$(WHISPER_SOURCE):
	git clone --quiet --depth 1 --branch $(WHISPER_VERSION) https://github.com/ggml-org/whisper.cpp $@

$(WHISPER_XCFRAMEWORK): Tools/whisper-cpp/module.modulemap | $(WHISPER_SOURCE)
	$(CMAKE) -S $(WHISPER_SOURCE) -B $(WHISPER_BUILD) $(WHISPER_CMAKE_FLAGS)
	$(CMAKE) --build $(WHISPER_BUILD) --config Release -j $(NCPU)
	rm -rf $(WHISPER_STAGING)
	mkdir -p $(WHISPER_STAGING)/include
	libtool -static -no_warning_for_no_symbols -o $(WHISPER_STAGING)/libwhisper.a $$(find $(WHISPER_BUILD) -name '*.a')
	cp $(WHISPER_SOURCE)/include/whisper.h $(WHISPER_SOURCE)/ggml/include/*.h $(WHISPER_STAGING)/include/
	cp Tools/whisper-cpp/module.modulemap $(WHISPER_STAGING)/include/
	rm -rf $@
	xcodebuild -create-xcframework -library $(WHISPER_STAGING)/libwhisper.a -headers $(WHISPER_STAGING)/include -output $@

# TranscriberKit ---------------------------------------------------------------

build: $(WHISPER_XCFRAMEWORK)
	swift build --package-path TranscriberKit

test: $(WHISPER_XCFRAMEWORK)
	swift test --package-path TranscriberKit

clean-tools:
	rm -rf $(TOOLS_DIR)
