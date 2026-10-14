# Developer tasks for Transcriber. Run `make help` for the list.
#
# Downloads and intermediate build products live in $(TOOLS_DIR), which is
# gitignored; `make clean-tools` removes all of it.

TOOLS_DIR         ?= .build-tools
NCPU              := $(shell sysctl -n hw.ncpu)
CMAKE             ?= $(shell command -v cmake 2>/dev/null || echo uvx cmake)

# Keep uv's package cache and any Python it installs inside $(TOOLS_DIR).
export UV_CACHE_DIR          := $(abspath $(TOOLS_DIR))/uv-cache
export UV_PYTHON_INSTALL_DIR := $(abspath $(TOOLS_DIR))/uv-python

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

.PHONY: help whisper-xcframework whisper-models whisper-models-q8_0 vad-model parity-fixtures build test clean-tools

help:
	@echo "make whisper-xcframework  Build whisper.cpp $(WHISPER_VERSION) into $(WHISPER_XCFRAMEWORK)"
	@echo "make whisper-models       Download and convert the Whisper models into $(MODELS_DIR)/whisper"
	@echo "make whisper-models-q8_0  Optional: q8_0 variants (not built by default)"
	@echo "make vad-model            Convert the ASMR VAD to Core ML into $(MODELS_DIR)/vad"
	@echo "make parity-fixtures      Regenerate test fixtures from the original Python pipeline"
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

# Whisper models ---------------------------------------------------------------
#
# Hugging Face checkpoints are converted to float16 ggml with our own converter
# (see Tools/model-conversion/convert_whisper_to_ggml.py for why). The app uses
# them at their original precision; whisper-models-q8_0 builds optional
# quantized variants with whisper.cpp's quantize tool and is not part of the
# default build. A -q8_0 file shares its Core ML encoder name with the f16 file.

MODELS_DIR          := Models
DOWNLOADS_DIR       := $(TOOLS_DIR)/downloads
HUGGING_FACE        := https://huggingface.co
GGML_CONVERTER      := Tools/model-conversion/convert_whisper_to_ggml.py

OPENAI_WHISPER_COMMIT := 86098128c0b4f24f0e2aa2994de830614b474227
MEL_FILTERS           := $(DOWNLOADS_DIR)/mel_filters.npz

WHISPER_TOOLS_BUILD := $(TOOLS_DIR)/whisper-tools-build
WHISPER_QUANTIZE    := $(WHISPER_TOOLS_BUILD)/bin/whisper-quantize

WHISPER_MODELS := chickenrice-v0.2 whisper-ja-1.5b

$(MEL_FILTERS):
	mkdir -p $(@D)
	curl -fsSL -o $@ https://raw.githubusercontent.com/openai/whisper/$(OPENAI_WHISPER_COMMIT)/whisper/assets/mel_filters.npz

$(WHISPER_QUANTIZE): | $(WHISPER_SOURCE)
	$(CMAKE) -S $(WHISPER_SOURCE) -B $(WHISPER_TOOLS_BUILD) -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF -DWHISPER_BUILD_TESTS=OFF
	$(CMAKE) --build $(WHISPER_TOOLS_BUILD) --config Release --target whisper-quantize -j $(NCPU)

# $(1): model name, $(2): Hugging Face repo, $(3): pinned revision
define whisper_model
$(DOWNLOADS_DIR)/$(1)/%:
	mkdir -p $$(@D)
	curl -fL --retry 3 -C - -o $$@.partial $(HUGGING_FACE)/$(2)/resolve/$(3)/$$*
	mv $$@.partial $$@

$(MODELS_DIR)/whisper/$(1).bin: $(GGML_CONVERTER) $(MEL_FILTERS) \
		$(DOWNLOADS_DIR)/$(1)/config.json $(DOWNLOADS_DIR)/$(1)/vocab.json $(DOWNLOADS_DIR)/$(1)/model.safetensors
	uv run --script $(GGML_CONVERTER) $(DOWNLOADS_DIR)/$(1) $(MEL_FILTERS) $$@

$(MODELS_DIR)/whisper/$(1)-q8_0.bin: $(MODELS_DIR)/whisper/$(1).bin $(WHISPER_QUANTIZE)
	$(WHISPER_QUANTIZE) $$< $$@ q8_0
endef

$(eval $(call whisper_model,chickenrice-v0.2,chickenrice0721/whisper-large-v2-translate-zh-v0.2-st,cc6f01704d188c6ed2d1ab84b83734f964c9a45a))
$(eval $(call whisper_model,whisper-ja-1.5b,efwkjn/whisper-ja-1.5B,72c13fb7b6cc2a831780cdd79cd1a829e77bab02))

WHISPER_MODEL_FILES := $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/whisper/$(model).bin)

whisper-models: $(WHISPER_MODEL_FILES)
	cd $(MODELS_DIR)/whisper && shasum -a 256 $(notdir $(WHISPER_MODEL_FILES)) > SHA256SUMS

whisper-models-q8_0: $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/whisper/$(model)-q8_0.bin)

# VAD model --------------------------------------------------------------------
#
# TransWithAI's ASMR VAD ships only as ONNX; convert_vad_to_coreml.py goes
# ONNX -> PyTorch -> Core ML and fails if the result drifts from ONNX Runtime.

VAD_REPO        := TransWithAI/Whisper-Vad-EncDec-ASMR-onnx
VAD_REVISION    := 6ac29e2cbf2f4f8e9b639861766a8639dd666e9c
VAD_ONNX        := $(DOWNLOADS_DIR)/whisper-vad-asmr/model.onnx
VAD_CONVERTER   := Tools/model-conversion/convert_vad_to_coreml.py
VAD_MLPACKAGE   := $(MODELS_DIR)/vad/whisper-vad-asmr.mlpackage

$(VAD_ONNX):
	mkdir -p $(@D)
	curl -fL --retry 3 -C - -o $@.partial $(HUGGING_FACE)/$(VAD_REPO)/resolve/$(VAD_REVISION)/model.onnx
	mv $@.partial $@

$(VAD_MLPACKAGE): $(VAD_CONVERTER) $(VAD_ONNX)
	mkdir -p $(@D)
	uv run --script $(VAD_CONVERTER) $(VAD_ONNX) $@ | tee $(MODELS_DIR)/vad/conversion-report.json

vad-model: $(VAD_MLPACKAGE)

# Parity fixtures --------------------------------------------------------------
#
# Reference data for TranscriberKit tests, produced by the original ChickenRice
# code (pinned below) and the libraries it uses. Fixtures are committed; this
# target only needs to run when the reference changes.

CHICKENRICE_REPO    := https://github.com/TransWithAI/Faster-Whisper-TransWithAI-ChickenRice
CHICKENRICE_COMMIT  := 62104884d8553be1c30bc88c157d82b2b8d0792b
CHICKENRICE_SOURCE  := $(TOOLS_DIR)/chickenrice-$(CHICKENRICE_COMMIT)
CHICKENRICE_PACKAGE := $(CHICKENRICE_SOURCE)/src/faster_whisper_transwithai_chickenrice

TEST_FIXTURES := TranscriberKit/Tests

$(CHICKENRICE_SOURCE):
	git clone --quiet $(CHICKENRICE_REPO) $@
	git -C $@ checkout --quiet $(CHICKENRICE_COMMIT)

parity-fixtures: | $(CHICKENRICE_SOURCE) $(VAD_ONNX)
	uv run --script Tools/parity/make_mel_fixture.py $(TEST_FIXTURES)/AudioFeaturesTests/Fixtures
	uv run --script Tools/parity/make_segmenter_fixture.py \
		$(CHICKENRICE_PACKAGE)/vad_manager.py $(TEST_FIXTURES)/SpeechDetectionTests/Fixtures/segmenter-cases.json
	uv run --script Tools/parity/make_vad_fixture.py \
		$(VAD_ONNX) $(TEST_FIXTURES)/SpeechDetectionTests/Fixtures
	uv run --script Tools/parity/make_postprocessing_fixture.py $(CHICKENRICE_PACKAGE)/infer.py \
		$(TEST_FIXTURES)/TranscriptionPipelineTests/Fixtures/chunk-cases.json \
		$(TEST_FIXTURES)/SubtitlePostProcessingTests/Fixtures/postprocessing-cases.json
	uv run --script Tools/parity/make_subtitle_fixture.py $(CHICKENRICE_PACKAGE)/infer.py \
		$(TEST_FIXTURES)/SubtitleExportTests/Fixtures

# TranscriberKit ---------------------------------------------------------------

build: $(WHISPER_XCFRAMEWORK)
	swift build --package-path TranscriberKit

test: $(WHISPER_XCFRAMEWORK)
	swift test --package-path TranscriberKit

clean-tools:
	rm -rf $(TOOLS_DIR)
