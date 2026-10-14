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
export HF_HOME               := $(abspath $(TOOLS_DIR))/huggingface

# Large downloads resume after dropped connections (-C - with retries on every
# error); verify_sha256 then checks the assembled file before it is used.
DOWNLOAD := curl -fL --retry 20 --retry-all-errors --retry-delay 5 -C -
verify_sha256 = echo "$(1)  $(2)" | shasum -a 256 -c -

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

.PHONY: FORCE help whisper-xcframework ffmpeg-xcframeworks whisper-models whisper-models-q8_0 mlx-models vad-model parity-fixtures baseline-a ours parity-report build test clean-tools

help:
	@echo "make whisper-xcframework  Build whisper.cpp $(WHISPER_VERSION) into $(WHISPER_XCFRAMEWORK)"
	@echo "make ffmpeg-xcframeworks  Build FFmpeg $(FFMPEG_VERSION) (LGPL, audio decoding only) into TranscriberKit/Vendor"
	@echo "make whisper-models       Download and convert the Whisper models into $(MODELS_DIR)/whisper"
	@echo "make whisper-models-q8_0  Optional: q8_0 variants (not built by default)"
	@echo "make mlx-models           Convert the Whisper models to MLX (original precision) into $(MODELS_DIR)/mlx"
	@echo "make vad-model            Convert the ASMR VAD to Core ML into $(MODELS_DIR)/vad"
	@echo "make parity-fixtures      Regenerate test fixtures from the original Python pipeline"
	@echo "make baseline-a           Run the original Python pipeline on $(PARITY_MEDIA) into $(BASELINE_A_DIR)"
	@echo "make ours                 Run our pipeline on $(PARITY_MEDIA) into $(OURS_DIR)"
	@echo "make parity-report        Compare $(OURS_DIR) with $(BASELINE_A_DIR) (CER, BLEU, timing)"
	@echo "make build                Build TranscriberKit and transcriber-cli"
	@echo "make test                 Run TranscriberKit tests"
	@echo "make clean-tools          Delete $(TOOLS_DIR) (downloads and intermediates)"

whisper-xcframework: $(WHISPER_XCFRAMEWORK)

$(WHISPER_SOURCE):
	git clone --quiet --depth 1 --branch $(WHISPER_VERSION) https://github.com/ggml-org/whisper.cpp $@

# The source is fetched inside the recipe, so deleting $(TOOLS_DIR) does not
# make an existing xcframework look out of date.
$(WHISPER_XCFRAMEWORK): Tools/whisper-cpp/module.modulemap
	$(MAKE) $(WHISPER_SOURCE)
	$(CMAKE) -S $(WHISPER_SOURCE) -B $(WHISPER_BUILD) $(WHISPER_CMAKE_FLAGS)
	$(CMAKE) --build $(WHISPER_BUILD) --config Release -j $(NCPU)
	rm -rf $(WHISPER_STAGING)
	mkdir -p $(WHISPER_STAGING)/include
	libtool -static -no_warning_for_no_symbols -o $(WHISPER_STAGING)/libwhisper.a $$(find $(WHISPER_BUILD) -name '*.a')
	cp $(WHISPER_SOURCE)/include/whisper.h $(WHISPER_SOURCE)/ggml/include/*.h $(WHISPER_STAGING)/include/
	cp Tools/whisper-cpp/module.modulemap $(WHISPER_STAGING)/include/
	rm -rf $@
	xcodebuild -create-xcframework -library $(WHISPER_STAGING)/libwhisper.a -headers $(WHISPER_STAGING)/include -output $@

# FFmpeg -----------------------------------------------------------------------
#
# Audio is decoded and resampled with FFmpeg, like the original (PyAV): the
# same libswresample conversion to 16 kHz mono s16 keeps samples identical.
# LGPL build (no --enable-gpl), dynamic frameworks, audio decoding only.

FFMPEG_VERSION      := 9.0.2
FFMPEG_SOURCE       := $(TOOLS_DIR)/ffmpeg-$(FFMPEG_VERSION)
FFMPEG_INSTALL      := $(TOOLS_DIR)/ffmpeg-install
FFMPEG_FRAMEWORKS   := $(TOOLS_DIR)/ffmpeg-frameworks
FFMPEG_LIBRARIES    := avutil swresample avcodec avformat
FFMPEG_XCFRAMEWORKS := $(foreach library,$(FFMPEG_LIBRARIES),TranscriberKit/Vendor/lib$(library).xcframework)

comma := ,
empty :=
space := $(empty) $(empty)
comma_separated = $(subst $(space),$(comma),$(strip $(1)))

FFMPEG_DEMUXERS := aac ac3 aiff amr ape asf avi caf dts eac3 flac flv matroska mov mp3 mpegps mpegts ogg tta w64 wav wv
FFMPEG_DECODERS := aac aac_latm ac3 alac amrnb amrwb ape dca eac3 flac mlp mp1 mp1float mp2 mp2float mp3 mp3float opus \
	pcm_alaw pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_u8 \
	truehd tta vorbis wavpack wmalossless wmapro wmav1 wmav2
FFMPEG_PARSERS  := aac aac_latm ac3 dca flac mlp mpegaudio opus vorbis

FFMPEG_CONFIGURE_FLAGS := \
	--prefix=$(abspath $(FFMPEG_INSTALL)) \
	--arch=arm64 --target-os=darwin --cc=clang \
	--extra-cflags=-mmacosx-version-min=$(DEPLOYMENT_TARGET) \
	--extra-ldflags="-mmacosx-version-min=$(DEPLOYMENT_TARGET) -Wl,-headerpad_max_install_names" \
	--install-name-dir=@rpath \
	--enable-shared --disable-static --enable-pic \
	--disable-programs --disable-doc --disable-network --disable-autodetect --enable-zlib \
	--disable-everything --disable-avdevice --disable-avfilter --disable-swscale \
	--enable-protocol=file \
	--enable-demuxer=$(call comma_separated,$(FFMPEG_DEMUXERS)) \
	--enable-decoder=$(call comma_separated,$(FFMPEG_DECODERS)) \
	--enable-parser=$(call comma_separated,$(FFMPEG_PARSERS))

ffmpeg-xcframeworks: $(FFMPEG_XCFRAMEWORKS)

$(FFMPEG_SOURCE):
	mkdir -p $(TOOLS_DIR)
	curl -fsSL https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$(FFMPEG_VERSION).tar.gz | tar -xz -C $(TOOLS_DIR)
	mv $(TOOLS_DIR)/FFmpeg-n$(FFMPEG_VERSION) $@

$(FFMPEG_INSTALL)/.installed: | $(FFMPEG_SOURCE)
	cd $(FFMPEG_SOURCE) && ./configure $(FFMPEG_CONFIGURE_FLAGS)
	$(MAKE) -C $(FFMPEG_SOURCE) -j $(NCPU) install
	touch $@

# Packages lib$(1).dylib as a versioned macOS framework and repoints its
# references to the other FFmpeg libraries at their frameworks.
define ffmpeg_framework
$(FFMPEG_FRAMEWORKS)/lib$(1).framework: $(FFMPEG_INSTALL)/.installed Tools/ffmpeg/lib$(1).modulemap
	rm -rf $$@
	mkdir -p $$@/Versions/A/Headers $$@/Versions/A/Modules $$@/Versions/A/Resources
	cp -L $(FFMPEG_INSTALL)/lib/lib$(1).dylib $$@/Versions/A/lib$(1)
	cp -R $(FFMPEG_INSTALL)/include/lib$(1)/. $$@/Versions/A/Headers/
	cp Tools/ffmpeg/lib$(1).modulemap $$@/Versions/A/Modules/module.modulemap
	plutil -create xml1 $$@/Versions/A/Resources/Info.plist
	plutil -insert CFBundleExecutable -string lib$(1) $$@/Versions/A/Resources/Info.plist
	plutil -insert CFBundleIdentifier -string org.ffmpeg.lib$(1) $$@/Versions/A/Resources/Info.plist
	plutil -insert CFBundlePackageType -string FMWK $$@/Versions/A/Resources/Info.plist
	plutil -insert CFBundleShortVersionString -string $(FFMPEG_VERSION) $$@/Versions/A/Resources/Info.plist
	plutil -insert CFBundleVersion -string $(FFMPEG_VERSION) $$@/Versions/A/Resources/Info.plist
	install_name_tool -id @rpath/lib$(1).framework/Versions/A/lib$(1) $$@/Versions/A/lib$(1)
	for dependency in $(filter-out $(1),$(FFMPEG_LIBRARIES)); do \
		old=$$$$(otool -L $$@/Versions/A/lib$(1) | awk "/@rpath\/lib$$$$dependency\./ {print \$$$$1}"); \
		[ -z "$$$$old" ] || install_name_tool -change $$$$old @rpath/lib$$$$dependency.framework/Versions/A/lib$$$$dependency $$@/Versions/A/lib$(1) || exit 1; \
	done
	ln -s A $$@/Versions/Current
	ln -s Versions/Current/lib$(1) $$@/lib$(1)
	ln -s Versions/Current/Headers $$@/Headers
	ln -s Versions/Current/Modules $$@/Modules
	ln -s Versions/Current/Resources $$@/Resources
	codesign --force --sign - $$@

TranscriberKit/Vendor/lib$(1).xcframework: $(FFMPEG_FRAMEWORKS)/lib$(1).framework
	rm -rf $$@
	xcodebuild -create-xcframework -framework $$(abspath $$<) -output $$@
endef

$(foreach library,$(FFMPEG_LIBRARIES),$(eval $(call ffmpeg_framework,$(library))))

# Whisper models ---------------------------------------------------------------
#
# Hugging Face checkpoints are converted to ggml at their original precision
# with our own converter (see Tools/model-conversion/convert_whisper_to_ggml.py):
# ChickenRice was trained and published in bfloat16, whisper-ja-1.5B in float16.
# whisper-models-q8_0 builds optional
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

# $(1): model name, $(2): Hugging Face repo, $(3): pinned revision,
# $(4): SHA-256 of model.safetensors at that revision, $(5): ggml weight type
define whisper_model
$(DOWNLOADS_DIR)/$(1)/%:
	mkdir -p $$(@D)
	$(DOWNLOAD) -o $$@.partial $(HUGGING_FACE)/$(2)/resolve/$(3)/$$*
	mv $$@.partial $$@

$(DOWNLOADS_DIR)/$(1)/model.safetensors:
	mkdir -p $$(@D)
	$(DOWNLOAD) -o $$@.partial $(HUGGING_FACE)/$(2)/resolve/$(3)/model.safetensors
	$$(call verify_sha256,$(4),$$@.partial)
	mv $$@.partial $$@

# Inputs are fetched inside the recipe, so deleting the downloads after
# conversion does not make the converted model look out of date.
$(MODELS_DIR)/whisper/$(1).bin: $(GGML_CONVERTER)
	$(MAKE) $(MEL_FILTERS) $(DOWNLOADS_DIR)/$(1)/config.json $(DOWNLOADS_DIR)/$(1)/vocab.json $(DOWNLOADS_DIR)/$(1)/model.safetensors
	uv run --script $(GGML_CONVERTER) $(DOWNLOADS_DIR)/$(1) $(MEL_FILTERS) $$@ --weight-type $(5)

# The Swift decoder reads token ids and text from the model's own tokenizer.json.
$(MODELS_DIR)/whisper/$(1).tokenizer.json:
	$(MAKE) $(DOWNLOADS_DIR)/$(1)/tokenizer.json
	mkdir -p $$(@D)
	cp $(DOWNLOADS_DIR)/$(1)/tokenizer.json $$@

$(MODELS_DIR)/whisper/$(1)-q8_0.bin: $(MODELS_DIR)/whisper/$(1).bin $(WHISPER_QUANTIZE)
	$(WHISPER_QUANTIZE) $$< $$@ q8_0
endef

$(eval $(call whisper_model,chickenrice-v0.2,chickenrice0721/whisper-large-v2-translate-zh-v0.2-st,cc6f01704d188c6ed2d1ab84b83734f964c9a45a,0abdde18518f3902913e4e2124145fb7d4635ebba88fd5c035b71819ec328ad0,bf16))
$(eval $(call whisper_model,whisper-ja-1.5b,efwkjn/whisper-ja-1.5B,72c13fb7b6cc2a831780cdd79cd1a829e77bab02,0bf92cf794ebb2cef2699c24dc71184be6a1ac133cc3c64f228ea08173d0155f,f16))

WHISPER_MODEL_FILES := $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/whisper/$(model).bin $(MODELS_DIR)/whisper/$(model).tokenizer.json)

whisper-models: $(WHISPER_MODEL_FILES)
	cd $(MODELS_DIR)/whisper && shasum -a 256 $(notdir $(WHISPER_MODEL_FILES)) > SHA256SUMS

whisper-models-q8_0: $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/whisper/$(model)-q8_0.bin)

# MLX models -------------------------------------------------------------------
#
# Converted with mlx-whisper's own convert() (hf_to_pt path) at a pinned
# mlx-examples commit, through convert_whisper_to_mlx.py so ChickenRice can stay
# bfloat16. It drops proj_out like whisper.cpp does; our ggml converter has
# already verified it is tied for both models.

MLX_EXAMPLES_COMMIT := 796f5b53cab69a3d48a44233ce21aae889e94a08
# mlx-whisper itself comes from the same commit: PyPI's 0.4.3 still loads
# weights.safetensors while convert.py at this commit writes model.safetensors.
MLX_WHISPER_PACKAGE := mlx-whisper @ git+https://github.com/ml-explore/mlx-examples@$(MLX_EXAMPLES_COMMIT)\#subdirectory=whisper
MLX_CONVERTER       := $(DOWNLOADS_DIR)/mlx-examples-$(MLX_EXAMPLES_COMMIT)/convert.py
MLX_MODEL_FILES     := $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/mlx/$(model)/model.safetensors $(MODELS_DIR)/mlx/$(model)/tokenizer.json)

$(MLX_CONVERTER):
	mkdir -p $(@D)
	curl -fsSL -o $@ https://raw.githubusercontent.com/ml-explore/mlx-examples/$(MLX_EXAMPLES_COMMIT)/whisper/convert.py

# $(1): model name, $(2): MLX dtype (the checkpoint's own precision)
define mlx_model
$(MODELS_DIR)/mlx/$(1)/model.safetensors:
	$(MAKE) $(MLX_CONVERTER) $(DOWNLOADS_DIR)/$(1)/config.json $(DOWNLOADS_DIR)/$(1)/model.safetensors
	uv run --no-project --python 3.12 --with "$(MLX_WHISPER_PACKAGE)" \
		python Tools/model-conversion/convert_whisper_to_mlx.py $(MLX_CONVERTER) $(DOWNLOADS_DIR)/$(1) $$(@D) $(2)

$(MODELS_DIR)/mlx/$(1)/tokenizer.json: $(MODELS_DIR)/whisper/$(1).tokenizer.json
	mkdir -p $$(@D)
	cp $$< $$@
endef

$(eval $(call mlx_model,chickenrice-v0.2,bfloat16))
$(eval $(call mlx_model,whisper-ja-1.5b,float16))

mlx-models: $(MLX_MODEL_FILES)

# VAD model --------------------------------------------------------------------
#
# TransWithAI's ASMR VAD ships only as ONNX; convert_vad_to_coreml.py goes
# ONNX -> PyTorch -> Core ML and fails if the result drifts from ONNX Runtime.

VAD_REPO        := TransWithAI/Whisper-Vad-EncDec-ASMR-onnx
VAD_REVISION    := 6ac29e2cbf2f4f8e9b639861766a8639dd666e9c
VAD_SHA256      := cd47513515766d57f740e3094440dbbca9ab87e026b9cf21540d7ad588c0e047
VAD_ONNX        := $(DOWNLOADS_DIR)/whisper-vad-asmr/model.onnx
VAD_CONVERTER   := Tools/model-conversion/convert_vad_to_coreml.py
VAD_MLPACKAGE   := $(MODELS_DIR)/vad/whisper-vad-asmr.mlpackage
VAD_MLMODELC    := $(MODELS_DIR)/vad/whisper-vad-asmr.mlmodelc

$(VAD_ONNX):
	mkdir -p $(@D)
	$(DOWNLOAD) -o $@.partial $(HUGGING_FACE)/$(VAD_REPO)/resolve/$(VAD_REVISION)/model.onnx
	$(call verify_sha256,$(VAD_SHA256),$@.partial)
	mv $@.partial $@

$(VAD_MLPACKAGE): $(VAD_CONVERTER) $(VAD_ONNX)
	mkdir -p $(@D)
	uv run --script $(VAD_CONVERTER) $(VAD_ONNX) $@ | tee $(MODELS_DIR)/vad/conversion-report.json

# Compiled once here for development; the app compiles the package on the user's Mac.
$(VAD_MLMODELC): $(VAD_MLPACKAGE)
	rm -rf $@
	xcrun coremlcompiler compile $< $(@D) >/dev/null

vad-model: $(VAD_MLMODELC)

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
	uv run --script Tools/parity/make_decode_fixture.py $(TEST_FIXTURES)/MediaDecodingTests/Fixtures
	$(MAKE) $(foreach model,$(WHISPER_MODELS),$(MODELS_DIR)/whisper/$(model).tokenizer.json)
	cp $(MODELS_DIR)/whisper/chickenrice-v0.2.tokenizer.json $(MODELS_DIR)/whisper/whisper-ja-1.5b.tokenizer.json \
		$(TEST_FIXTURES)/WhisperDecodingTests/Fixtures/
	uv run --script Tools/parity/make_tokenizer_fixture.py $(TEST_FIXTURES)/WhisperDecodingTests/Fixtures/tokenizer-cases.json \
		$(foreach model,$(WHISPER_MODELS),$(model)=$(MODELS_DIR)/whisper/$(model).tokenizer.json)

# Baseline A: the original pipeline ---------------------------------------------
#
# Runs the pinned original infer.py, unmodified, with the arguments of its
# .bat launchers and the officially published CTranslate2 models. On a Mac it
# runs on the CPU; compute type is fixed to float32 because "auto" would pick
# int8/int16 on CPU, while users run float16/bfloat16 on a GPU.
# Media and outputs are the user's own files and stay out of git.

PARITY_MEDIA    ?= ParityMedia
BASELINE_A_DIR  ?= Parity/baseline-a
# float32 by default; e.g. int8_float32 (what CPU users get) measures the original's own variation.
BASELINE_COMPUTE_TYPE ?= float32
CT2_DIR         := $(TOOLS_DIR)/ct2
BASELINE_TASKS  := translate transcribe
CT2_MODEL_FILES := config.json preprocessor_config.json tokenizer.json vocabulary.json model.bin

ORIGINAL_DEPENDENCIES := --with faster-whisper==1.2.1 --with "av>=11,<16" --with ctranslate2 --with onnxruntime \
	--with "transformers>=4.45,<5" --with pyjson5 --with librosa
ORIGINAL_ARGUMENTS := --audio_suffixes="mp3,wav,flac,m4a,aac,ogg,wma,mp4,mkv,avi,mov,webm,flv,wmv" \
	--sub_formats="srt,vtt,lrc" --device=cpu --compute_type=$(BASELINE_COMPUTE_TYPE) --overwrite --log_level=INFO

# $(1): local name, $(2): repo, $(3): revision, $(4): SHA-256 of model.bin
define ct2_model
$(CT2_DIR)/$(1)/%:
	mkdir -p $$(@D)
	$(DOWNLOAD) -o $$@.partial $(HUGGING_FACE)/$(2)/resolve/$(3)/$$*
	mv $$@.partial $$@

$(CT2_DIR)/$(1)/model.bin:
	mkdir -p $$(@D)
	$(DOWNLOAD) -o $$@.partial $(HUGGING_FACE)/$(2)/resolve/$(3)/model.bin
	$$(call verify_sha256,$(4),$$@.partial)
	mv $$@.partial $$@
endef

$(eval $(call ct2_model,translate,chickenrice0721/whisper-large-v2-translate-zh-v0.2-st-ct2,2a896581429aa8100eaa5586bc36a5b3011871bc,d9ede0107bf5eef437db3625216e2395aebafd0a72967c5583c6234659d18273))
$(eval $(call ct2_model,transcribe,TransWithAI/whisper-ja-1.5B-ct2,1527314b14da5bdf0d14e7328649d4fa26840188,01041dbc312122f6f0f5ef6dd89f2ad7dc0bba7b746e8e1bc3c4f04f0af0befd))

$(DOWNLOADS_DIR)/whisper-vad-asmr/model_metadata.json:
	mkdir -p $(@D)
	$(DOWNLOAD) -o $@ $(HUGGING_FACE)/$(VAD_REPO)/resolve/$(VAD_REVISION)/model_metadata.json

baseline-a: $(foreach task,$(BASELINE_TASKS),$(addprefix $(CT2_DIR)/$(task)/,$(CT2_MODEL_FILES))) \
		$(VAD_ONNX) $(DOWNLOADS_DIR)/whisper-vad-asmr/model_metadata.json | $(CHICKENRICE_SOURCE)
	mkdir -p $(CHICKENRICE_SOURCE)/models
	ln -sf $(abspath $(VAD_ONNX)) $(CHICKENRICE_SOURCE)/models/whisper_vad.onnx
	ln -sf $(abspath $(DOWNLOADS_DIR)/whisper-vad-asmr/model_metadata.json) $(CHICKENRICE_SOURCE)/models/whisper_vad_metadata.json
	for task in $(BASELINE_TASKS); do \
		cd $(abspath $(CHICKENRICE_SOURCE)) && uv run --no-project --python 3.12 $(ORIGINAL_DEPENDENCIES) \
			python infer.py $(ORIGINAL_ARGUMENTS) --task=$$task \
			--model_name_or_path=$(abspath $(CT2_DIR))/$$task \
			--output_dir=$(abspath $(BASELINE_A_DIR))/$$task \
			$(abspath $(PARITY_MEDIA)) || exit 1; \
	done

# Our pipeline on the same media, and the comparison --------------------------

OURS_DIR        ?= Parity/ours
TRANSCRIBER_CLI := TranscriberKit/.build/release/transcriber-cli
MEDIA_SUFFIXES  := mp3 wav flac m4a aac ogg wma mp4 mkv avi mov webm flv wmv
PARITY_FILES     = $(foreach suffix,$(MEDIA_SUFFIXES),$(shell find $(PARITY_MEDIA) -type f -iname '*.$(suffix)' 2>/dev/null))

$(TRANSCRIBER_CLI): FORCE
	swift build --package-path TranscriberKit -c release --product transcriber-cli

ours: $(TRANSCRIBER_CLI)
	for task in $(BASELINE_TASKS); do \
		$(TRANSCRIBER_CLI) transcribe --task $$task --output-directory $(OURS_DIR)/$$task $(PARITY_FILES) 2>/dev/null || exit 1; \
	done

parity-report:
	for task in $(BASELINE_TASKS); do \
		echo "== $$task"; \
		uv run --script Tools/parity/compare_subtitles.py $(BASELINE_A_DIR)/$$task $(OURS_DIR)/$$task || exit 1; \
	done

FORCE:

# TranscriberKit ---------------------------------------------------------------

build: $(WHISPER_XCFRAMEWORK)
	swift build --package-path TranscriberKit

test: $(WHISPER_XCFRAMEWORK)
	swift test --package-path TranscriberKit

clean-tools:
	rm -rf $(TOOLS_DIR)
