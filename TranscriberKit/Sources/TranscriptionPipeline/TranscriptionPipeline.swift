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
        public var segmentation: SegmentationSettings
        public var merge: MergeSettings
        public var cleanup: TextCleanupSettings
        /// Chunks decoded at the same time. Chunks are independent (no
        /// previous-text prompt), so the result does not depend on this.
        public var concurrentChunkCount: Int
        /// Seeds temperature-fallback sampling (combined with the chunk index),
        /// so the same input always gives the same subtitles.
        public var samplingSeed: UInt64

        public init(
            vad: VADSettings,
            chunking: ChunkingSettings,
            segmentation: SegmentationSettings = .chunks,
            merge: MergeSettings,
            cleanup: TextCleanupSettings = .none,
            concurrentChunkCount: Int,
            samplingSeed: UInt64
        ) {
            self.vad = vad
            self.chunking = chunking
            self.segmentation = segmentation
            self.merge = merge
            self.cleanup = cleanup
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

        /// Everything a model's configuration sets, with the app's concurrency.
        public init(model: RecognitionModel, concurrentChunkCount: Int) {
            self.init(
                vad: model.vad,
                chunking: model.chunking,
                segmentation: model.segmentation,
                merge: model.merge,
                cleanup: model.cleanup,
                concurrentChunkCount: concurrentChunkCount,
                samplingSeed: Settings.chickenRice.samplingSeed
            )
        }
    }

    /// Choices that do not depend on the model, made per file.
    public struct Options: Sendable {
        public var timestampHandling: MediaDecoder.TimestampHandling

        public init(timestampHandling: MediaDecoder.TimestampHandling = .followTimestamps) {
            self.timestampHandling = timestampHandling
        }
    }

    public enum Progress: Sendable {
        /// `timestampJumps`: holes and overlaps in the file's audio timeline.
        case decodedAudio(duration: AudioTime, timestampJumps: [AudioTimestampJump])
        /// The outer VAD pass: speech spans and their total length.
        case detectedSpeech(spanCount: Int, speechDuration: AudioTime)
        case plannedChunks(count: Int)
        /// `completed` chunks of `count` are done; `chunk` is the one that just
        /// finished, with its subtitles before merging and cleanup (a preview).
        case transcribedChunk(completed: Int, count: Int, chunk: AudioChunk, segments: [TimedText])
        /// Subtitles after merging.
        case postProcessed(segmentCount: Int)
    }

    private let voiceActivityDetector: VoiceActivityDetector
    private let chunkTranscriber: ChunkTranscriber
    private let groupTranscriber: GroupTranscriber
    private let settings: Settings

    public init(vadModel: WhisperVADModel, segmentGenerator: SegmentGenerator, settings: Settings = .chickenRice) {
        self.settings = settings
        self.voiceActivityDetector = VoiceActivityDetector(model: vadModel, settings: settings.vad)
        let spectrogram = LogMelSpectrogram(melBandCount: segmentGenerator.backend.melBandCount, framing: .wholeSignal)
        self.chunkTranscriber = ChunkTranscriber(
            voiceActivityDetector: voiceActivityDetector,
            segmentGenerator: segmentGenerator,
            spectrogram: spectrogram,
            samplingSeed: settings.samplingSeed
        )
        self.groupTranscriber = GroupTranscriber(
            segmentGenerator: segmentGenerator,
            spectrogram: spectrogram,
            leadingSilence: settings.segmentation.leadingSilence,
            samplingSeed: settings.samplingSeed
        )
    }

    public func transcribe(
        fileAt url: URL,
        options: Options = Options(),
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [TimedText] {
        let audio = try MediaDecoder(timestampHandling: options.timestampHandling).decodeAudio(at: url)
        progress(.decodedAudio(duration: audio.duration, timestampJumps: audio.timestampJumps))
        return try await transcribe(samples: audio.samples, progress: progress)
    }

    public func transcribe(samples: [Float], progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [TimedText] {
        let speech = try voiceActivityDetector.speechSpans(in: samples)
        let speechSamples = speech.reduce(0) { $0 + max(($1.end - $1.start).samples, 0) }
        progress(.detectedSpeech(spanCount: speech.count, speechDuration: AudioTime(samples: speechSamples)))
        // infer.py returns nothing when the outer VAD finds no speech at all.
        guard speech.contains(where: { $0.end > $0.start }) else {
            return []
        }

        let segments: [TimedText]
        switch settings.segmentation.mode {
        case .chunks:
            segments = try await transcribeInChunks(samples: samples, speech: speech, progress: progress)
        case .vadGroups:
            let groups = SpeechGrouper.groups(speech, settings: settings.segmentation)
            progress(.plannedChunks(count: groups.count))
            let groupTranscriber = groupTranscriber
            segments = try await transcribeConcurrently(groups, progress: progress) { group in
                try groupTranscriber.transcribe(group, of: samples)
            }
        }
        let subtitles = SubtitleTextCleanup.apply(
            SubtitlePostProcessor.process(segments, settings: settings.merge),
            settings: settings.cleanup
        )
        progress(.postProcessed(segmentCount: subtitles.count))
        return subtitles
    }

    /// ChickenRice: up to 30 s chunks cut at silences, each transcribed with
    /// its own inner VAD and timestamps.
    private func transcribeInChunks(
        samples: [Float],
        speech: [SpeechSpan],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [TimedText] {
        let durationSeconds = Double(samples.count) / Double(AudioTime.sampleRate)

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

        let chunkTranscriber = chunkTranscriber
        return try await transcribeConcurrently(chunks, progress: progress) { chunk in
            try chunkTranscriber.transcribe(chunk, of: samples)
        }
    }

    /// Keeps up to `concurrentChunkCount` chunks in flight and returns their
    /// segments in chunk order, as sequential processing would.
    private func transcribeConcurrently(
        _ chunks: [AudioChunk],
        progress: @escaping @Sendable (Progress) -> Void,
        transcribe: @escaping @Sendable (AudioChunk) throws -> [TimedText]
    ) async throws -> [TimedText] {
        return try await withThrowingTaskGroup(of: (Int, [TimedText]).self) { group in
            var segmentsByChunk = [[TimedText]](repeating: [], count: chunks.count)
            var nextChunk = 0
            func startNextChunk() {
                let chunk = chunks[nextChunk]
                group.addTask {
                    (chunk.index, try transcribe(chunk))
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
                progress(.transcribedChunk(completed: finishedCount, count: chunks.count, chunk: chunks[index], segments: segments))
                if nextChunk < chunks.count {
                    startNextChunk()
                }
            }
            return segmentsByChunk.flatMap { $0 }
        }
    }
}
