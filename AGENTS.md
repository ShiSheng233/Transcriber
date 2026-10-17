# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex and others) when working with code in this repository. `CLAUDE.md` is a symlink to it.

Transcriber is a native macOS (AppKit, macOS 15+, arm64 only) subtitle generator. It ports the inference pipeline of [Faster-Whisper-TransWithAI-ChickenRice](https://github.com/TransWithAI/Faster-Whisper-TransWithAI-ChickenRice) v1.10 to Apple Silicon, and adds an LLM step at the end for polishing or translation (any OpenAI-compatible API). `docs/ARCHITECTURE.md` (Chinese) is the design source of truth: decisions, module table, parity results and roadmap. Read it before structural changes.

## Commands

Build-related work goes through the root `Makefile` (`make help`), not standalone shell scripts. Downloads and intermediates live in `.build-tools/` (`make clean-tools`). Rules are written so that deleting `.build-tools/` does not make the vendored frameworks or `Models/` look out of date.

```sh
# One-time prerequisites (gitignored outputs in TranscriberKit/Vendor/)
make whisper-xcframework      # whisper.cpp v1.9.5, Metal + Core ML with fallback
make ffmpeg-xcframeworks      # FFmpeg 9.0.2, LGPL, audio decoding only, dynamic frameworks

# Models (gitignored, into Models/<model>/; several GB each)
make whisper-models mlx-models vad-model
make coreml-encoders          # whisper-ja's encoder as Core ML (Neural Engine), used when model.json asks for it

# Package build and tests
make build                    # swift build --package-path TranscriberKit
make test                     # swift test  --package-path TranscriberKit
swift test --package-path TranscriberKit --filter SpeechSegmenterTests   # single suite or test
make test-app                 # app ViewModel tests (TranscriberTests, unhosted: the app never launches)

# App
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber -configuration Debug build

# CLI (reads ./Models by default; --models-directory to override)
swift run --package-path TranscriberKit transcriber-cli models
swift run --package-path TranscriberKit transcriber-cli transcribe --model chickenrice-v0.2 <media...>

# Parity against the original Python pipeline
make parity-fixtures          # regenerate unit-test fixtures from the pinned original source
make baseline-a && make ours && make parity-report   # media in ParityMedia/, outputs in Parity/
```

Tests use Swift Testing (`import Testing`). Tests that need converted models are gated with `.enabled(if:)` on files in `Models/`, so they skip silently when `Models/` is empty. Never write tests or debug checks that drive the real app, its UserDefaults or the Keychain: one such check once overwrote the user's stored API key. `TranscriberTests` compiles only the app files that do not import AppKit (listed in the project's membership exception for that target; add new ViewModel files there) and never `APIKeyStore.swift`: inject `UserDefaults(suiteName:)` and an in-memory `APIKeyStoring`.

## Architecture

There are two layers with one-way dependencies:

- **`Transcriber/` (app target):** AppKit MVVM. Views are `NSViewController`/`NSView` and only lay out, forward user actions and `render()`. ViewModels are `@Observable @MainActor` classes with `private(set)` state and verb-named intent methods, and they don't import AppKit. Views subscribe through `Shared/ObservationBinder` (a `withObservationTracking` wrapper). `App/AppEnvironment` is the composition root that creates and injects services. `MainWindowController` assembles child controllers. ViewModels never hold each other.
- **`TranscriberKit/` (local Swift package):** services and domain, no AppKit. `TranscriberCore` holds `Sendable` value types (`AudioTime` counts 16 kHz samples, so never pass raw ms or sample `Int`s across modules). The `transcriber-cli` executable exercises the same modules headlessly.

Pipeline (`TranscriptionPipeline`, mirrors the original `infer.py`): FFmpeg decode → outer VAD (Core ML ASMR VAD) → chunk planning → inner VAD stitching (`SpeechTimeline`) → recognition → time mapping → post-processing (`SubtitlePostProcessing`) → export (`SubtitleExport`), with an optional `LLMTranslation` step. `JobQueue` (actor) runs jobs through the `queued → loadingModel → … → completed | failed | cancelled` state machine and replays and streams the activity log.

Key design points that span files:

- **We own the decode loop.** `whisper_full` is deliberately not used because it can't match faster-whisper. `WhisperDecoding` implements CTranslate2/faster-whisper behaviour once: tokenizer, logits processors, sampling, temperature fallback, segment splitting and the seek loop. The `WhisperBackend` protocol (encode a batch of windows, decode one step) is implemented by `WhisperCpp` (ggml on Metal; all `whisper_*` C interop stays inside this module) and `WhisperMLX` (a mlx-swift port of mlx-whisper). When behaviours differ, CTranslate2 wins over OpenAI/mlx-whisper (see ARCHITECTURE §5.2).
- **Models are data, never hard-coded.** Each model folder has a `model.json` copied from `ModelConfigurations/` (format in `ModelConfigurations/README.md`). It sets the task token, language, decoding, VAD, segmentation, merge, cleanup and `llm_mode`, and missing values fall back to `ChickenRiceDefaults`. `ModelCatalog` scans the models directory, and the user picks a model in the main toolbar. Adding a model means adding a JSON file plus a Makefile conversion rule, with no Swift changes unless the pipeline lacks a capability. anime-whisper shows the no-timestamp path (`segmentation.mode = vad_groups`).
- **Parity first.** Defaults reproduce the original pipeline, and improvements go behind toggles. Deterministic modules are checked exactly against fixtures generated from the pinned original source (`Tools/parity/`, `make parity-fixtures`). Recognition output is compared statistically (CER/BLEU/timing). Comments must explain any quirk kept for parity, and every original default lives in `ChickenRiceDefaults` with its source location.
- **Precision and backend defaults are measured.** Models stay at their training precision (ChickenRice bf16, whisper-ja f16), and Metal flash attention is off by default because it changes ChickenRice's timestamps. whisper.cpp with 4 parallel chunks is the current default backend.
- **Two lanes, one model.** `JobQueue` recognizes one file at a time (the queue's or an editor re-transcription, behind one gate) and hands each file's LLM step to a second lane that runs one step at a time, so the next file is recognized meanwhile. The model stays loaded while files wait and is unloaded once none do, and on quit. ggml's Metal device asserts at process exit if buffers are still alive.

## Code rules (ARCHITECTURE §2)

Names state intent and units. Use one primary type per file, with the file named after it (`Type+Purpose.swift` for extensions). No magic numbers. Algorithms are pure functions on value types. Inject dependencies through `init`, and only add protocols at module boundaries. Each module has its own typed `Error` enum, and errors become user-facing text only in ViewModels. Long tasks support cancellation. No force unwraps outside tests.

## Repo conventions

- `Models/`, `TranscriberKit/Vendor/`, `.build-tools/`, `ParityMedia/`, `Parity/` and `build/` are gitignored. All upstream sources and models are pinned to a commit or SHA-256 in the Makefile.
- Commit messages are a short imperative subject in sentence case with no prefix (e.g. "Unload the speech model before the language model step"), with one commit per module or change.
- The app is distributed directly with Developer ID and notarization, with no sandbox. Models are not bundled. Releases go through `make release` / `make release-publish` (GitHub Release plus the Homebrew cask in `../homebrew-tap`, template `Packaging/transcriber.rb.in`); the checklist is `docs/RELEASING.md`.
