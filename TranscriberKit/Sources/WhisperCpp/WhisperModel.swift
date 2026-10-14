import Foundation
import whisper

/// Owns a whisper.cpp context: the model weights, shared by all decoder states.
///
/// The context is created without a decoding state. Each concurrent decode will
/// own its own `whisper_state`, so one copy of the weights serves several chunks
/// at once (see docs/ARCHITECTURE.md §5.1).
public final class WhisperModel: @unchecked Sendable {
    // @unchecked: after loading, whisper.cpp only reads the context; all
    // mutable decoding data lives in per-decode states.
    let context: OpaquePointer

    public let info: WhisperModelInfo
    public let encoderBackend: WhisperEncoderBackend

    public init(
        contentsOf modelURL: URL,
        encoderBackend: WhisperEncoderBackend = .metal,
        usesGPU: Bool = true
    ) throws(WhisperModelError) {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw .fileNotFound(modelURL)
        }

        var parameters = whisper_context_default_params()
        parameters.use_gpu = usesGPU
        parameters.flash_attn = usesGPU

        let loadedContext: OpaquePointer?
        switch encoderBackend {
        case .metal:
            loadedContext = WhisperModelFileReader.makeContext(fromModelAt: modelURL, parameters: parameters)
        case .coreML:
            // Checked here because, with fallback enabled, whisper.cpp would
            // silently use Metal when the encoder is missing.
            let encoderURL = Self.coreMLEncoderURL(forModelAt: modelURL)
            guard FileManager.default.fileExists(atPath: encoderURL.path) else {
                throw .coreMLEncoderNotFound(encoderURL)
            }
            loadedContext = whisper_init_from_file_with_params_no_state(modelURL.path, parameters)
        }

        guard let loadedContext else {
            throw .loadFailed(modelURL)
        }
        self.context = loadedContext
        self.encoderBackend = encoderBackend
        self.info = WhisperModelInfo(
            typeName: String(cString: whisper_model_type_readable(loadedContext)),
            melBandCount: Int(whisper_model_n_mels(loadedContext)),
            vocabularySize: Int(whisper_model_n_vocab(loadedContext)),
            encoderLayerCount: Int(whisper_model_n_audio_layer(loadedContext)),
            decoderLayerCount: Int(whisper_model_n_text_layer(loadedContext)),
            isMultilingual: whisper_is_multilingual(loadedContext) != 0
        )
    }

    deinit {
        whisper_free(context)
    }

    /// The Core ML encoder whisper.cpp looks for, mirroring
    /// `whisper_get_coreml_path_encoder`: drop the extension and a quantization
    /// suffix such as `-q8_0`, then append `-encoder.mlmodelc`.
    public static func coreMLEncoderURL(forModelAt modelURL: URL) -> URL {
        var stem = modelURL.deletingPathExtension().lastPathComponent
        if let dash = stem.lastIndex(of: "-") {
            let suffix = Array(stem[dash...])
            let isQuantizationSuffix = suffix.count == 5 && suffix[1] == "q" && suffix[3] == "_"
            if isQuantizationSuffix {
                stem = String(stem[..<dash])
            }
        }
        return modelURL.deletingLastPathComponent().appendingPathComponent(stem + "-encoder.mlmodelc")
    }
}
