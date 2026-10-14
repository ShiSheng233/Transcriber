import AudioFeatures
import Foundation
import Synchronization
import WhisperDecoding
import whisper

public enum WhisperCppError: Error, Equatable {
    case stateAllocationFailed
    case melRejected(Int32)
    case encodingFailed(Int32)
    case decodingFailed(Int32)
}

/// whisper.cpp as a `WhisperBackend`, through its low-level API only
/// (`whisper_full` is not used; decoding lives in `WhisperDecoding`).
///
/// Decoder states are pooled: allocating one sets up GPU buffers and a KV
/// cache, so a finished session hands its state to the next one. Several
/// sessions can run at once, each with its own state, sharing the weights.
public final class WhisperCppBackend: WhisperBackend {
    private static let threadCount: Int32 = 4

    public let model: WhisperModel
    private let idleStates = Mutex<[StatePointer]>([])

    public init(model: WhisperModel) {
        self.model = model
    }

    deinit {
        idleStates.withLock { states in
            states.forEach { whisper_free_state($0.pointer) }
        }
    }

    public var melBandCount: Int {
        model.info.melBandCount
    }

    public func makeSession(window: LogMelFeatures) throws -> any WhisperDecoderSession {
        let state = try borrowState()
        do {
            try encode(window, with: state.pointer)
        } catch {
            returnState(state)
            throw error
        }
        return WhisperCppSession(backend: self, state: state)
    }

    fileprivate func decode(_ tokens: [Int], afterPrefixOf prefixLength: Int, with state: OpaquePointer) throws -> [Float] {
        let tokenIDs = tokens.map { whisper_token($0) }
        let status = whisper_decode_with_state(
            model.context, state, tokenIDs, Int32(tokenIDs.count), Int32(prefixLength), Self.threadCount
        )
        guard status == 0, let logits = whisper_get_logits_from_state(state) else {
            throw WhisperCppError.decodingFailed(status)
        }
        // whisper.cpp fills only the last token's row.
        let vocabularySize = Int(whisper_n_vocab(model.context))
        let lastRow = logits + (tokenIDs.count - 1) * vocabularySize
        return Array(UnsafeBufferPointer(start: lastRow, count: vocabularySize))
    }

    fileprivate func returnState(_ state: StatePointer) {
        idleStates.withLock { $0.append(state) }
    }

    private func borrowState() throws -> StatePointer {
        if let state = idleStates.withLock({ $0.popLast() }) {
            return state
        }
        guard let pointer = whisper_init_state(model.context) else {
            throw WhisperCppError.stateAllocationFailed
        }
        return StatePointer(pointer: pointer)
    }

    private func encode(_ window: LogMelFeatures, with state: OpaquePointer) throws {
        let melStatus = window.values.withUnsafeBufferPointer { values in
            whisper_set_mel_with_state(
                model.context, state, values.baseAddress, Int32(window.frameCount), Int32(window.melBandCount)
            )
        }
        guard melStatus == 0 else {
            throw WhisperCppError.melRejected(melStatus)
        }
        let encodeStatus = whisper_encode_with_state(model.context, state, 0, Self.threadCount)
        guard encodeStatus == 0 else {
            throw WhisperCppError.encodingFailed(encodeStatus)
        }
    }
}

/// A `whisper_state` pointer that may move between threads; only one session
/// uses it at a time.
struct StatePointer: @unchecked Sendable {
    let pointer: OpaquePointer
}

final class WhisperCppSession: WhisperDecoderSession {
    private let backend: WhisperCppBackend
    private let state: StatePointer

    init(backend: WhisperCppBackend, state: StatePointer) {
        self.backend = backend
        self.state = state
    }

    deinit {
        backend.returnState(state)
    }

    func logits(appending tokens: [Int], afterPrefixOf prefixLength: Int) throws -> [Float] {
        try backend.decode(tokens, afterPrefixOf: prefixLength, with: state.pointer)
    }
}
