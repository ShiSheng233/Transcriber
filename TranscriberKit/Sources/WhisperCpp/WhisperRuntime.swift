import whisper

/// Build information about the linked whisper.cpp library.
public enum WhisperRuntime {
    public static var version: String {
        String(cString: whisper_version())
    }

    /// Enabled CPU features and backends, as reported by ggml.
    public static var systemInfo: String {
        String(cString: whisper_print_system_info())
    }
}
