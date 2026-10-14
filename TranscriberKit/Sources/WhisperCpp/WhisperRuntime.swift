import Foundation
import whisper

/// Build information and logging for the linked whisper.cpp library.
public enum WhisperRuntime {
    public static var version: String {
        String(cString: whisper_version())
    }

    /// Enabled CPU features and backends, as reported by ggml.
    public static var systemInfo: String {
        String(cString: whisper_print_system_info())
    }

    /// whisper.cpp and ggml log every shader compile, model load and decoder
    /// state at info level. Keep errors only. Idempotent.
    public static func reduceLoggingToErrors() {
        _ = loggingConfigured
    }

    private static let loggingConfigured: Void = {
        let callback: ggml_log_callback = { level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else {
                return
            }
            let message = String(cString: text)
            // With the Core ML encoder off, every decoder state reports that it
            // found no Core ML model before falling back to Metal: expected.
            if message.contains("Core ML model") {
                return
            }
            FileHandle.standardError.write(Data(message.utf8))
        }
        ggml_log_set(callback, nil)
        whisper_log_set(callback, nil)
    }()
}
