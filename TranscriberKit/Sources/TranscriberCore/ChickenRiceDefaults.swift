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
}
