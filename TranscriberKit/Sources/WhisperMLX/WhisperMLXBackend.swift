import AudioFeatures
import Foundation
import MLX
import MLXNN
import WhisperDecoding

public enum WhisperMLXError: Error, Equatable {
    case missingWeights(URL)
}

/// Whisper on MLX as a `WhisperBackend`. Loads models converted with
/// mlx-whisper's convert() (`make mlx-models`) and computes in the weights'
/// own precision (bfloat16 for ChickenRice).
///
/// Up to `slotCount` windows decode at once, batched into shared forward
/// passes (see `DecoderSlotBatch` and `BatchingCoordinator`); further
/// sessions wait for a free slot.
public final class WhisperMLXBackend: WhisperBackend, @unchecked Sendable {
    /// Rows in every decoding step. Fixed, so results do not depend on how
    /// many chunks run at once: a different row count changes the matrix
    /// kernels' rounding, which was enough to change ChickenRice's output.
    /// Four was also the fastest setting measured on an M5 Max.
    public static let slotCount = 4

    // @unchecked: the network is only read after loading, slots are handed
    // out under `slotLock`, and MLX work is serialized by the coordinator.
    private let network: WhisperNetwork
    private let dtype: DType
    private let configuration: WhisperMLXConfiguration
    private let coordinator: BatchingCoordinator
    private let slotLock = NSCondition()
    private var freeSlots: [Int]

    public init(modelDirectory: URL) throws {
        let configuration = try WhisperMLXConfiguration.load(from: modelDirectory)
        let weightsURL = modelDirectory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw WhisperMLXError.missingWeights(weightsURL)
        }
        // alignment_heads is metadata for word timestamps, not a parameter.
        let weights = try loadArrays(url: weightsURL).filter { $0.key != "alignment_heads" }
        let dtype = weights["decoder.token_embedding.weight"]?.dtype ?? .float16

        let network = WhisperNetwork(configuration: configuration, dtype: dtype)
        try network.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(network)

        let slotCount = Self.slotCount
        let batch = DecoderSlotBatch(
            decoder: network.decoder,
            slotCount: slotCount,
            contextLength: configuration.textContextLength,
            audioContextLength: configuration.audioContextLength,
            stateSize: configuration.textStateSize,
            dtype: dtype
        )
        self.network = network
        self.dtype = dtype
        self.configuration = configuration
        self.coordinator = BatchingCoordinator(batch: batch)
        self.freeSlots = Array((0..<slotCount).reversed())
        self.batch = batch
    }

    private let batch: DecoderSlotBatch

    public var melBandCount: Int {
        configuration.melBandCount
    }

    public func makeSession(window: LogMelFeatures) throws -> any WhisperDecoderSession {
        let slot = borrowSlot()
        coordinator.run {
            // LogMelFeatures is band major; the encoder takes [batch, frames, bands].
            let mel = MLXArray(window.values, [1, window.melBandCount, window.frameCount])
                .transposed(0, 2, 1)
                .asType(dtype)
            let audioFeatures = network.encoder(mel)
            batch.load(audioFeatures: audioFeatures, into: slot)
        }
        coordinator.sessionStarted()
        return WhisperMLXSession(slot: slot, coordinator: coordinator) { [weak self] in
            self?.returnSlot(slot)
        }
    }

    private func borrowSlot() -> Int {
        slotLock.lock()
        defer { slotLock.unlock() }
        while freeSlots.isEmpty {
            slotLock.wait()
        }
        return freeSlots.removeLast()
    }

    private func returnSlot(_ slot: Int) {
        slotLock.withLock {
            freeSlots.append(slot)
            slotLock.signal()
        }
    }
}

/// One encoded window decoding in a batch slot.
final class WhisperMLXSession: WhisperDecoderSession {
    private let slot: Int
    private let coordinator: BatchingCoordinator
    private let onEnd: () -> Void

    init(slot: Int, coordinator: BatchingCoordinator, onEnd: @escaping () -> Void) {
        self.slot = slot
        self.coordinator = coordinator
        self.onEnd = onEnd
    }

    deinit {
        coordinator.sessionEnded()
        onEnd()
    }

    /// Feeds the tokens one at a time; with a key/value cache this gives the
    /// same result as feeding them together, and every step can be batched.
    func logits(appending tokens: [Int], afterPrefixOf prefixLength: Int) throws -> [Float] {
        var logits: [Float] = []
        for (offset, token) in tokens.enumerated() {
            logits = coordinator.logits(for: .init(slot: slot, token: token, position: prefixLength + offset))
        }
        return logits
    }
}
