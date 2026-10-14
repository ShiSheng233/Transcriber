import Foundation
import whisper

/// Loads a ggml file through whisper.cpp's reader callbacks instead of by path.
///
/// whisper.cpp looks for a Core ML encoder next to the model *path*. A context
/// created from a reader has no path, so it never finds one and, with
/// WHISPER_COREML_ALLOW_FALLBACK, runs the encoder on Metal.
enum WhisperModelFileReader {
    static func makeContext(
        fromModelAt modelURL: URL,
        parameters: whisper_context_params
    ) -> OpaquePointer? {
        guard let file = fopen(modelURL.path, "rb") else {
            return nil
        }

        // whisper.cpp calls `close` on both the success and the failure path.
        var loader = whisper_model_loader(
            context: UnsafeMutableRawPointer(file),
            read: { context, output, byteCount in
                guard let context, let output else { return 0 }
                return fread(output, 1, byteCount, context.assumingMemoryBound(to: FILE.self))
            },
            eof: { context in
                guard let context else { return true }
                return feof(context.assumingMemoryBound(to: FILE.self)) != 0
            },
            close: { context in
                guard let context else { return }
                fclose(context.assumingMemoryBound(to: FILE.self))
            }
        )
        return whisper_init_with_params_no_state(&loader, parameters)
    }
}
