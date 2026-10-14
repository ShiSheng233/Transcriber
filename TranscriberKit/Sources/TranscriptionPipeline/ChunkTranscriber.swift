import AudioFeatures
import SpeechDetection
import TranscriberCore
import WhisperDecoding

/// Transcribes one chunk the way the original does: faster-whisper's
/// `transcribe(chunk, vad_filter=True)` (inner VAD, speech joined, decoded,
/// times mapped back), then infer.py's collection into millisecond segments
/// shifted by the chunk start and kept inside the chunk.
struct ChunkTranscriber {
    let voiceActivityDetector: VoiceActivityDetector
    let segmentGenerator: SegmentGenerator
    let spectrogram: LogMelSpectrogram

    func transcribe(_ chunk: AudioChunk, of samples: [Float]) throws -> [TimedText] {
        let chunkSamples = Array(samples[chunk.sampleRange(inAudioOfLength: samples.count)])
        guard !chunkSamples.isEmpty else {
            return []
        }

        let speech = try voiceActivityDetector.speechSpans(in: chunkSamples)
        guard !speech.isEmpty else {
            return []  // faster-whisper decodes an empty signal: no segments
        }
        let timeline = SpeechTimeline(spans: speech)
        let features = spectrogram.features(for: SpeechTimeline.joinedSpeech(from: chunkSamples, spans: speech))
        var generator = SystemRandomNumberGenerator()
        let decoded = try segmentGenerator.segments(for: features, generator: &generator)

        return decoded.compactMap { segment in
            let start = timeline.originalTime(segment.start, isEnd: false)
            let end = timeline.originalTime(segment.end, isEnd: true)
            return collected(start: start, end: end, text: segment.text, in: chunk)
        }
    }

    /// infer.py `_transcribe_smart_chunks`: `chunk_offset_ms + int(round(t * 1000))`,
    /// dropped when it starts at or after the chunk end, clipped to the chunk end.
    private func collected(start: Double, end: Double, text: String, in chunk: AudioChunk) -> TimedText? {
        let chunkEnd = chunk.endBoundary
        let segmentStart = chunk.startOffset + Self.milliseconds(start)
        let segmentEnd = min(chunk.startOffset + Self.milliseconds(end), chunkEnd)
        guard segmentStart < chunkEnd, segmentEnd > segmentStart else {
            return nil
        }
        return TimedText(start: segmentStart, end: segmentEnd, text: text.pythonStripped)
    }

    private static func milliseconds(_ seconds: Double) -> AudioTime {
        AudioTime(milliseconds: Int((seconds * 1_000).rounded(.toNearestOrEven)))
    }
}
