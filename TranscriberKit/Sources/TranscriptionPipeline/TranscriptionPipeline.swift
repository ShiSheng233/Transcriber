import AudioFeatures
import Foundation
import MediaDecoding
import SpeechDetection
import SubtitlePostProcessing
import TranscriberCore
import WhisperDecoding

/// The original's default path (`smart_split_with_vad`) end to end: decode,
/// outer VAD, smart chunks, per-chunk transcription, post-processing.
public struct TranscriptionPipeline {
    public struct Settings: Sendable {
        public var vad: VADSettings
        public var chunking: ChunkingSettings
        public var merge: MergeSettings

        public init(vad: VADSettings, chunking: ChunkingSettings, merge: MergeSettings) {
            self.vad = vad
            self.chunking = chunking
            self.merge = merge
        }

        public static let chickenRice = Settings(
            vad: ChickenRiceDefaults.vad,
            chunking: ChickenRiceDefaults.chunking,
            merge: ChickenRiceDefaults.merge
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
            spectrogram: LogMelSpectrogram(melBandCount: segmentGenerator.backend.melBandCount, framing: .wholeSignal)
        )
    }

    public func transcribe(fileAt url: URL, progress: (Progress) -> Void = { _ in }) throws -> [TimedText] {
        let samples = try mediaDecoder.decodeAudio(at: url)
        progress(.decodedAudio(duration: AudioTime(samples: samples.count)))
        return try transcribe(samples: samples, progress: progress)
    }

    public func transcribe(samples: [Float], progress: (Progress) -> Void = { _ in }) throws -> [TimedText] {
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

        var segments: [TimedText] = []
        for chunk in chunks {
            try Task.checkCancellation()
            segments += try chunkTranscriber.transcribe(chunk, of: samples)
            progress(.transcribedChunk(index: chunk.index, count: chunks.count))
        }
        return SubtitlePostProcessor.process(segments, settings: settings.merge)
    }
}
