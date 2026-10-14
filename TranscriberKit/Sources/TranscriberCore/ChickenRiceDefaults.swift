/// Settings the original ChickenRice pipeline (v1.10, commit 6210488) runs with.
///
/// Each value names where it comes from, so a reader can check it against the
/// original without guessing.
public enum ChickenRiceDefaults {
    /// `generation_config.json5` → `vad_parameters`. `neg_threshold` is unset,
    /// so the segmenter uses `threshold - 0.15`.
    public static let vad = VADSettings(
        threshold: 0.5,
        negativeThreshold: nil,
        minimumSpeechDuration: AudioTime(milliseconds: 300),
        maximumSpeechDuration: nil,
        minimumSilenceDuration: AudioTime(milliseconds: 100),
        speechPadding: AudioTime(milliseconds: 200)
    )

    /// `infer.py` → `SmartSplitOptions` defaults (`MAX_SMART_CHUNK_DURATION_S` = 30).
    public static let chunking = ChunkingSettings(
        isEnabled: true,
        targetChunkDurationSeconds: 30,
        splitWindowFactor: 0.4
    )

    /// `infer.py` → `SegmentMergeOptions` defaults.
    public static let merge = MergeSettings(
        isEnabled: true,
        maximumGap: AudioTime(milliseconds: 2_000),
        maximumSegmentDuration: AudioTime(milliseconds: 20_000)
    )

    /// `generation_config.json5` (task, max_initial_timestamp, repetition_penalty),
    /// infer.py's `setdefault`s (beam_size 1, condition_on_previous_text False)
    /// and faster-whisper 1.2.1 defaults for everything else. `max_length` 448
    /// leaves 224 generated tokens after the 3-token prompt.
    public static func decoding(task: TranscriptionTask) -> DecodingSettings {
        DecodingSettings(
            task: task,
            languageCode: "ja",
            temperatures: [0, 0.2, 0.4, 0.6, 0.8, 1],
            compressionRatioThreshold: 2.4,
            logProbabilityThreshold: -1,
            noSpeechThreshold: 0.6,
            bestOf: 5,
            repetitionPenalty: 1.1,
            suppressesBlankStart: true,
            maximumInitialTimestampSeconds: 30,
            maximumGeneratedTokenCount: 224
        )
    }
}
