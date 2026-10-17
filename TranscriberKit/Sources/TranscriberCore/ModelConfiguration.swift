import Foundation

/// The `model.json` file format. Every setting is optional; missing ones take
/// the original ChickenRice pipeline's values (`ChickenRiceDefaults`).
struct ModelConfiguration: Decodable {
    struct Files: Decodable {
        var tokenizer: String?
        var whisperCpp: String?
        var mlx: String?
    }

    struct WhisperCpp: Decodable {
        var encoder: RecognitionModel.WhisperCppEncoder?
    }

    struct Decoding: Decodable {
        var temperatures: [Float]?
        var compressionRatioThreshold: Double?
        var logProbThreshold: Double?
        var noSpeechThreshold: Double?
        var bestOf: Int?
        var repetitionPenalty: Float?
        var suppressBlank: Bool?
        var maxInitialTimestamp: Double?
        var maxNewTokens: Int?
        /// false for models trained without timestamp tokens.
        var timestamps: Bool?
        var noRepeatNgramSize: Int?
    }

    struct VAD: Decodable {
        var model: String?
        var threshold: Double?
        var negThreshold: Double?
        var minSpeechDurationMs: Int?
        var maxSpeechDurationS: Double?
        var minSilenceDurationMs: Int?
        var speechPadMs: Int?
        var splitAtDip: Bool?
    }

    struct Chunking: Decodable {
        var enabled: Bool?
        var targetChunkDurationS: Double?
        var splitWindowFactor: Double?
    }

    struct Segmentation: Decodable {
        var mode: SegmentationSettings.Mode?
        var groupGapMs: Int?
        var groupMaxMs: Int?
        var leadingSilenceMs: Int?
    }

    struct Merge: Decodable {
        var enabled: Bool?
        var maxGapMs: Int?
        var maxDurationMs: Int?
    }

    struct Cleanup: Decodable {
        var dropEllipsisOnly: Bool?
        var collapseRepeats: Bool?
        var appendPeriod: Bool?
    }

    var id: String
    var name: String
    var summary: String?
    var source: String?
    var license: String?
    var language: String
    var task: TranscriptionTask
    var llmMode: RecognitionModel.LLMMode
    var files: Files?
    var whisperCpp: WhisperCpp?
    var decoding: Decoding?
    var vad: VAD?
    var chunking: Chunking?
    var segmentation: Segmentation?
    var merge: Merge?
    var cleanup: Cleanup?

    func model(in directory: URL) -> RecognitionModel {
        let files = files ?? Files()
        let decodingDefaults = ChickenRiceDefaults.decoding(task: task)
        let vadDefaults = ChickenRiceDefaults.vad
        let chunkingDefaults = ChickenRiceDefaults.chunking
        let mergeDefaults = ChickenRiceDefaults.merge
        let segmentationDefaults = SegmentationSettings.chunks
        let cleanupDefaults = TextCleanupSettings.none
        let decoding = decoding

        return RecognitionModel(
            id: id,
            displayName: name,
            summary: summary ?? "",
            source: source,
            license: license,
            llmMode: llmMode,
            directory: directory,
            files: .init(
                tokenizer: directory.appendingPathComponent(files.tokenizer ?? "tokenizer.json"),
                whisperCpp: (files.whisperCpp ?? "ggml.bin").isEmpty ? nil : directory.appendingPathComponent(files.whisperCpp ?? "ggml.bin"),
                mlx: (files.mlx ?? "mlx").isEmpty ? nil : directory.appendingPathComponent(files.mlx ?? "mlx", isDirectory: true)
            ),
            whisperCppEncoder: whisperCpp?.encoder ?? .metal,
            decoding: DecodingSettings(
                task: task,
                languageCode: language,
                temperatures: decoding?.temperatures ?? decodingDefaults.temperatures,
                compressionRatioThreshold: decoding?.compressionRatioThreshold ?? decodingDefaults.compressionRatioThreshold,
                logProbabilityThreshold: decoding?.logProbThreshold ?? decodingDefaults.logProbabilityThreshold,
                noSpeechThreshold: decoding?.noSpeechThreshold ?? decodingDefaults.noSpeechThreshold,
                bestOf: decoding?.bestOf ?? decodingDefaults.bestOf,
                repetitionPenalty: decoding?.repetitionPenalty ?? decodingDefaults.repetitionPenalty,
                suppressesBlankStart: decoding?.suppressBlank ?? decodingDefaults.suppressesBlankStart,
                maximumInitialTimestampSeconds: decoding?.maxInitialTimestamp ?? decodingDefaults.maximumInitialTimestampSeconds,
                maximumGeneratedTokenCount: decoding?.maxNewTokens ?? decodingDefaults.maximumGeneratedTokenCount,
                usesTimestamps: decoding?.timestamps ?? decodingDefaults.usesTimestamps,
                noRepeatNgramSize: decoding?.noRepeatNgramSize ?? decodingDefaults.noRepeatNgramSize
            ),
            vadModelName: vad?.model ?? "whisper-vad-asmr",
            vad: VADSettings(
                threshold: vad?.threshold ?? vadDefaults.threshold,
                negativeThreshold: vad?.negThreshold ?? vadDefaults.negativeThreshold,
                minimumSpeechDuration: vad?.minSpeechDurationMs.map { AudioTime(milliseconds: $0) } ?? vadDefaults.minimumSpeechDuration,
                maximumSpeechDuration: vad?.maxSpeechDurationS.map { AudioTime(seconds: $0) } ?? vadDefaults.maximumSpeechDuration,
                minimumSilenceDuration: vad?.minSilenceDurationMs.map { AudioTime(milliseconds: $0) } ?? vadDefaults.minimumSilenceDuration,
                speechPadding: vad?.speechPadMs.map { AudioTime(milliseconds: $0) } ?? vadDefaults.speechPadding,
                splitsAtProbabilityDip: vad?.splitAtDip ?? vadDefaults.splitsAtProbabilityDip
            ),
            chunking: ChunkingSettings(
                isEnabled: chunking?.enabled ?? chunkingDefaults.isEnabled,
                targetChunkDurationSeconds: chunking?.targetChunkDurationS ?? chunkingDefaults.targetChunkDurationSeconds,
                splitWindowFactor: chunking?.splitWindowFactor ?? chunkingDefaults.splitWindowFactor
            ),
            segmentation: SegmentationSettings(
                mode: segmentation?.mode ?? segmentationDefaults.mode,
                groupGap: segmentation?.groupGapMs.map { AudioTime(milliseconds: $0) } ?? segmentationDefaults.groupGap,
                groupMaximumDuration: segmentation?.groupMaxMs.map { AudioTime(milliseconds: $0) } ?? segmentationDefaults.groupMaximumDuration,
                leadingSilence: segmentation?.leadingSilenceMs.map { AudioTime(milliseconds: $0) } ?? segmentationDefaults.leadingSilence
            ),
            merge: MergeSettings(
                isEnabled: merge?.enabled ?? mergeDefaults.isEnabled,
                maximumGap: merge?.maxGapMs.map { AudioTime(milliseconds: $0) } ?? mergeDefaults.maximumGap,
                maximumSegmentDuration: merge?.maxDurationMs.map { AudioTime(milliseconds: $0) } ?? mergeDefaults.maximumSegmentDuration
            ),
            cleanup: TextCleanupSettings(
                dropsEllipsisOnlyLines: cleanup?.dropEllipsisOnly ?? cleanupDefaults.dropsEllipsisOnlyLines,
                collapsesRepeats: cleanup?.collapseRepeats ?? cleanupDefaults.collapsesRepeats,
                appendsPeriod: cleanup?.appendPeriod ?? cleanupDefaults.appendsPeriod
            )
        )
    }
}
