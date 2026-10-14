import AudioFeatures
import Foundation
import MediaDecoding
import SpeechDetection
import SubtitlePostProcessing
import TranscriberCore
import WhisperDecoding

/// The original's default path (`smart_split_with_vad`) end to end: decode,
/// outer VAD, smart chunks, per-chunk transcription, post-processing.
public struct TranscriptionPipeline: Sendable {
    public struct Settings: Sendable {
        public var vad: VADSettings
        public var chunking: ChunkingSettings
        public var merge: MergeSettings
        /// Chunks decoded at the same time. Chunks are independent (no
        /// previous-text prompt), so the result does not depend on this.
        public var concurrentChunkCount: Int
        /// Seeds temperature-fallback sampling (combined with the chunk index),
        /// so the same input always gives the same subtitles.
        public var samplingSeed: UInt64

        public init(vad: VADSettings, chunking: ChunkingSettings, merge: MergeSettings, concurrentChunkCount: Int, samplingSeed: UInt64) {
            self.vad = vad
            self.chunking = chunking
            self.merge = merge
            self.concurrentChunkCount = concurrentChunkCount
            self.samplingSeed = samplingSeed
        }

        public static let chickenRice = Settings(
            vad: ChickenRiceDefaults.vad,
            chunking: ChickenRiceDefaults.chunking,
            merge: ChickenRiceDefaults.merge,
            // Measured on an M5 Max: 4 chunks in flight is fastest; 8 is no
            // faster and uses more memory.
            concurrentChunkCount: 4,
            samplingSeed: 0
        )
    }

    public enum Progress: Sendable {
        case decodedAudio(duration: AudioTime)
        case plannedChunks(count: Int)
        case transcribedChunk(index: Int, count: Int)
    }

    private let mediaDecoder = MediaDecoder()
    private let voiceActivityDetector: VoiceActivityDetector
    private let chunkTranscriber: ChunkTranscriber
    private let settings: Settings

    public init(vadModel: WhisperVADModel, segmentGenerator: SegmentGenerator, settings: Settings = .chickenRice) {
        self.settings = settings
        self.voiceActivityDetector = VoiceActivityDetector(model: vadModel, settings: settings.vad)
        self.chunkTranscriber = ChunkTranscriber(
            voiceActivityDetector: voiceActivityDetector,
            segmentGenerator: segmentGenerator,
            spectrogram: LogMelSpectrogram(melBandCount: segmentGenerator.backend.melBandCount, framing: .wholeSignal),
            samplingSeed: settings.samplingSeed
        )
    }

    public func transcribe(fileAt url: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [TimedText] {
        let samples = try mediaDecoder.decodeAudio(at: url)
        progress(.decodedAudio(duration: AudioTime(samples: samples.count)))
        return try await transcribe(samples: samples, progress: progress)
    }

    public func transcribe(samples: [Float], progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [TimedText] {
        let durationSeconds = Double(samples.count) / Double(AudioTime.sampleRate)
        let speech = try voiceActivityDetector.speechSpans(in: samples)
        // infer.py returns nothing when the outer VAD finds no speech at all.
        guard speech.contains(where: { $0.end > $0.start }) else {
            return []
        }

        var chunks = ChunkPlanner.contiguousChunks(
            speech: speech,
            totalDurationSeconds: durationSeconds,
            maximumDurationSeconds: min(settings.chunking.targetChunkDurationSeconds, ChickenRiceDefaults.chunking.targetChunkDurationSeconds),
            splitWindowFactor: settings.chunking.splitWindowFactor
        )
        if chunks.isEmpty {
            chunks = [AudioChunk(index: 0, startSeconds: 0, endSeconds: durationSeconds)]
        }
        progress(.plannedChunks(count: chunks.count))

        let segments = try await transcribeConcurrently(chunks, of: samples, progress: progress)
        return SubtitlePostProcessor.process(segments, settings: settings.merge)
    }

    /// Keeps up to `concurrentChunkCount` chunks in flight and returns their
    /// segments in chunk order, as sequential processing would.
    private func transcribeConcurrently(
        _ chunks: [AudioChunk],
        of samples: [Float],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [TimedText] {
        let chunkTranscriber = chunkTranscriber
        return try await withThrowingTaskGroup(of: (Int, [TimedText]).self) { group in
            var segmentsByChunk = [[TimedText]](repeating: [], count: chunks.count)
            var nextChunk = 0
            func startNextChunk() {
                let chunk = chunks[nextChunk]
                group.addTask {
                    (chunk.index, try chunkTranscriber.transcribe(chunk, of: samples))
                }
                nextChunk += 1
            }

            while nextChunk < min(max(settings.concurrentChunkCount, 1), chunks.count) {
                startNextChunk()
            }
            var finishedCount = 0
            while let (index, segments) = try await group.next() {
                segmentsByChunk[index] = segments
                finishedCount += 1
                progress(.transcribedChunk(index: finishedCount - 1, count: chunks.count))
                if nextChunk < chunks.count {
                    startNextChunk()
                }
            }
            return segmentsByChunk.flatMap { $0 }
        }
    }
}
